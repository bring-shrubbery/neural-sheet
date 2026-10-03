import Accelerate
import Foundation

extension PitchTracker {
    /// The per-frame measurement for one pitch (pitch curves design §2, Measurement and Cost):
    /// the Goertzel magnitude of every (candidate, harmonic) frequency, as the dot product of a
    /// frame with a precomputed Hann-windowed cos and sin row.
    ///
    /// The rows are one matrix, so a run of frames is one `vDSP_mmul` rather than a few hundred
    /// dot products each; built once per pitch and shared by every note at it, since the rows
    /// depend on nothing else.
    struct GoertzelBank {
        /// One measured frame: the deviation in cents, the share of the frame's energy the
        /// harmonics at that deviation hold, and whether that share clears the gate.
        struct Frame: Equatable {
            var cents: Float
            var confidence: Float = 0
            var reliable: Bool
        }

        /// Frames per matrix product: bounds the scratch to about a megabyte however long the note.
        static let chunk = 256

        let harmonicCount: Int
        /// `window` rows × `columns`: for candidate `c` and harmonic `h`, column `2(cH + h)` is
        /// `hann[n]·cos(ωn)` and the next `hann[n]·sin(ωn)`.
        let table: [Float]
        /// `hann[n]²`: a frame's windowed energy is its squares dotted with this.
        let hannSquared: [Float]
        /// What one sinusoid's `|X|²` at its own frequency is to its windowed energy,
        /// `(Σw)² / (2 Σw²)` (Parseval), so a frame whose energy is all in the measured
        /// harmonics scores 1.
        let sinusoidGain: Float
        var columns: Int { 2 * PitchTracker.candidateCount * harmonicCount }

        init(pitch: Int) {
            let f0 = 440.0 * pow(2.0, Double(pitch - 69) / 12)
            let topRatio = pow(2.0, PitchTracker.maximumCents / 1200)
            // Only harmonics that stay clear of Nyquist at the highest candidate, so every
            // candidate sums the same harmonics and none is favoured by an aliased one.
            let ceiling = 0.475 * PitchTracker.sampleRate
            let harmonicCount = max(1, min(PitchTracker.harmonics, Int(ceiling / (f0 * topRatio))))
            self.harmonicCount = harmonicCount

            let window = PitchTracker.window
            var hann = [Float](repeating: 0, count: window)
            vDSP_hann_window(&hann, vDSP_Length(window), Int32(vDSP_HANN_NORM))

            let columns = 2 * PitchTracker.candidateCount * harmonicCount
            var table = [Float](repeating: 0, count: window * columns)

            for candidate in 0..<PitchTracker.candidateCount {
                let cents = (Double(candidate) - Double(PitchTracker.candidateCount / 2)) * PitchTracker.candidateStep

                for harmonic in 0..<harmonicCount {
                    let frequency = Double(harmonic + 1) * f0 * pow(2.0, cents / 1200)
                    let omega = 2 * Double.pi * frequency / PitchTracker.sampleRate
                    let column = 2 * (candidate * harmonicCount + harmonic)

                    for n in 0..<window {
                        let phase = omega * Double(n)
                        table[n * columns + column] = hann[n] * Float(cos(phase))
                        table[n * columns + column + 1] = hann[n] * Float(sin(phase))
                    }
                }
            }

            self.table = table
            self.hannSquared = hann.map { $0 * $0 }
            let sum = hann.reduce(0, +)
            self.sinusoidGain = sum * sum / (2 * hannSquared.reduce(0, +))
        }

        /// `frameCount` frames from `startSeconds`, each centred on its time, 10 ms apart. A
        /// window reaching past either end of the take reads zeros there.
        func measure(mono16k: [Float], startSeconds: Double, frameCount: Int) -> [Frame] {
            let window = PitchTracker.window
            let columns = self.columns
            var frames: [Frame] = []
            frames.reserveCapacity(frameCount)

            var samples = [Float](repeating: 0, count: Self.chunk * window)
            var products = [Float](repeating: 0, count: Self.chunk * columns)
            var sums = [Float](repeating: 0, count: PitchTracker.candidateCount)
            var squares = [Float](repeating: 0, count: window)

            var first = 0

            while first < frameCount {
                let count = min(Self.chunk, frameCount - first)

                for row in 0..<count {
                    let seconds = startSeconds + Double(first + row) * PitchTracker.frameSeconds
                    let start = Int((seconds * PitchTracker.sampleRate).rounded()) - window / 2
                    copyWindow(from: mono16k, start: start, into: &samples, row: row)
                }

                vDSP_mmul(samples, 1, table, 1, &products, 1,
                          vDSP_Length(count), vDSP_Length(columns), vDSP_Length(window))

                for row in 0..<count {
                    let energy = windowedEnergy(samples: samples, row: row, squares: &squares)
                    frames.append(frame(products: products, row: row, energy: energy, sums: &sums))
                }

                first += count
            }

            return frames
        }

        /// One frame's samples into its row of the scratch, zeros where the take has none.
        private func copyWindow(from mono16k: [Float], start: Int, into samples: inout [Float], row: Int) {
            let window = PitchTracker.window
            let offset = row * window
            let low = max(start, 0)
            let high = min(start + window, mono16k.count)

            samples.withUnsafeMutableBufferPointer { buffer in
                let base = buffer.baseAddress! + offset

                guard low < high else {
                    base.update(repeating: 0, count: window)
                    return
                }

                if low > start { base.update(repeating: 0, count: low - start) }

                mono16k.withUnsafeBufferPointer { source in
                    (base + (low - start)).update(from: source.baseAddress! + low, count: high - low)
                }

                if high < start + window { (base + (high - start)).update(repeating: 0, count: start + window - high) }
            }
        }

        /// `Σ (x[n] w[n])²` over one row of the scratch.
        private func windowedEnergy(samples: [Float], row: Int, squares: inout [Float]) -> Float {
            let window = PitchTracker.window
            var energy: Float = 0

            samples.withUnsafeBufferPointer { buffer in
                vDSP_vsq(buffer.baseAddress! + row * window, 1, &squares, 1, vDSP_Length(window))
            }
            vDSP_dotpr(squares, 1, hannSquared, 1, &energy, vDSP_Length(window))

            return energy
        }

        /// The harmonic sum per candidate from the frame's dot products and its parabolic argmax
        /// in cents; reliable when the harmonics at the best candidate hold at least
        /// ``minimumHarmonicity`` of the frame's energy.
        private func frame(products: [Float], row: Int, energy: Float, sums: inout [Float]) -> Frame {
            let base = row * columns

            for candidate in 0..<PitchTracker.candidateCount {
                var sum: Float = 0

                for harmonic in 0..<harmonicCount {
                    let column = base + 2 * (candidate * harmonicCount + harmonic)
                    let re = products[column]
                    let im = products[column + 1]
                    sum += (re * re + im * im).squareRoot() / Float(harmonic + 1)
                }

                sums[candidate] = sum
            }

            var best = 0

            for candidate in 1..<PitchTracker.candidateCount where sums[candidate] > sums[best] {
                best = candidate
            }

            // A parabola through the peak and its neighbours puts the deviation between candidates.
            var position = Float(best)

            if best > 0, best < PitchTracker.candidateCount - 1 {
                let left = sums[best - 1]
                let centre = sums[best]
                let right = sums[best + 1]
                let denominator = left - 2 * centre + right

                if denominator < 0 {
                    position += 0.5 * (left - right) / denominator
                }
            }

            let cents = (position - Float(PitchTracker.candidateCount / 2)) * Float(PitchTracker.candidateStep)
            let limit = Float(PitchTracker.maximumCents)

            // The design's peak-to-mean ratio over the candidates cannot work at 40 ms: the
            // window's main lobe (±50 Hz) is wider than ±200 ¢ below about 450 Hz, so even a clean
            // sine scores ~2 at A4 and ~1 at A2. The share of the frame's energy the harmonics
            // hold separates a line from noise or a mix instead: ~1 against ~0.05.
            var harmonic: Float = 0

            for h in 0..<harmonicCount {
                let column = base + 2 * (best * harmonicCount + h)
                harmonic += products[column] * products[column] + products[column + 1] * products[column + 1]
            }

            let confidence = energy > 0 ? harmonic / (sinusoidGain * energy) : 0
            let reliable = confidence >= PitchTracker.minimumHarmonicity

            return Frame(cents: min(max(cents, -limit), limit), confidence: confidence, reliable: reliable)
        }
    }
}
