// Ported from muscriptor.cpp's cpp/src/stft.cpp and cpp/include/muscriptor/stft.hpp,
// with vDSP's real FFT in place of pffft: Accelerate ships with the system, so the port
// drops a vendored transform, and the framing that has to match PyTorch is unchanged.

import Accelerate

/// Short-time Fourier transform magnitudes, the front half of the mel front-end.
///
/// Reproduces `torch.stft(x, n_fft, hop_length, win_length=n_fft, window=window,
/// center=True, pad_mode="reflect", normalized=False, onesided=True).abs()`. The
/// checkpoint's `power` is 1.0, so these are magnitudes and not powers: squaring them
/// is a plausible-looking error that survives every shape check.
///
/// Everything is F32, as the reference keeps the whole conditioning path in F32 even
/// when the transformer runs in F16.
struct STFT {
    let nFFT: Int
    let hopLength: Int

    /// The coefficients the transform applies, so a test can assert on them rather than
    /// on a copy from the GGUF. The reference's window is a *periodic* Hann (the
    /// denominator is `n_fft`, not `n_fft - 1`) that has been through F16, so it is read
    /// from `cond.stft_window` and never regenerated.
    let window: [Float]

    var nFreq: Int { nFFT / 2 + 1 }

    /// vDSP's setup, built once. `vDSP.FFT` is a class, so a copy of this struct shares
    /// it; the transform is out-of-place and the setup is read-only, which is why
    /// `magnitudes` can stay non-mutating.
    private let fft: vDSP.FFT<DSPSplitComplex>

    /// `.internalError` when `nFFT` is not a power of two of at least 32, when
    /// `hopLength` is not positive, or when the window is the wrong length.
    ///
    /// The reference's own floor is pffft's `nFFT % 32 == 0`. This narrows it to powers of
    /// two, because vDSP's radix-2 real FFT takes only those; `log2n >= 5` keeps the multiple
    /// of 32 the reference asked for and is our own choice rather than a vDSP minimum. Every
    /// checkpoint uses 2048, so nothing this build reads is excluded by either.
    init(nFFT: Int, hopLength: Int, window: [Float]) throws {
        guard nFFT >= 32, nFFT & (nFFT - 1) == 0 else {
            throw TranscriberError.internalError(
                "stft cannot transform n_fft = \(nFFT); it needs a power of two of at least 32")
        }

        guard hopLength > 0 else {
            throw TranscriberError.internalError("stft needs a positive hop_length, got \(hopLength)")
        }

        guard window.count == nFFT else {
            throw TranscriberError.internalError(
                "stft window has \(window.count) coefficients, expected n_fft = \(nFFT)")
        }

        // Only a size vDSP has already rejected above can fail here, but the initialiser
        // is failable, so the impossible case gets the same error as the rest.
        guard let setup = vDSP.FFT(
            log2n: vDSP_Length(nFFT.trailingZeroBitCount), radix: .radix2, ofType: DSPSplitComplex.self)
        else {
            throw TranscriberError.internalError("vDSP cannot transform n_fft = \(nFFT)")
        }

        self.nFFT = nFFT
        self.hopLength = hopLength
        self.window = window
        fft = setup
    }

    /// Frames emitted for `sampleCount` of input. Centre padding adds `nFFT / 2` to each
    /// end, so the padded length is `sampleCount + nFFT` and the count collapses to
    /// `1 + sampleCount / hopLength` — one more than the audio actually covers, which is
    /// why `ConditioningFrontEnd` masks the last frame away.
    func frameCount(sampleCount: Int) -> Int {
        sampleCount < 0 ? 0 : 1 + sampleCount / hopLength
    }

    /// Magnitudes as `[frameCount(samples.count)][nFreq]` row-major, the layout the
    /// conditioning front-end takes and the one the reference dumps.
    ///
    /// `.internalError` when the input is shorter than `nFFT / 2 + 1` samples, the point
    /// below which reflect padding has nothing left to reflect. In the pipeline this
    /// cannot happen: chunks are zero-padded to a fixed five seconds.
    func magnitudes(_ samples: [Float]) throws -> [Float] {
        let pad = nFFT / 2
        let count = samples.count

        guard count >= pad + 1 else {
            throw TranscriberError.internalError(
                "stft needs at least \(pad + 1) samples to reflect-pad, got \(count)")
        }

        let padded = reflectPadded(samples)
        let frames = frameCount(sampleCount: count)
        let bins = nFreq
        var out = [Float](repeating: 0, count: frames * bins)
        let workspace = Workspace(nFFT: nFFT)

        padded.withUnsafeBufferPointer { source in
            window.withUnsafeBufferPointer { coefficients in
                out.withUnsafeMutableBufferPointer { destination in
                    for frame in 0 ..< frames {
                        transform(
                            source.baseAddress! + frame * hopLength, coefficients.baseAddress!,
                            into: destination.baseAddress! + frame * bins, using: workspace)
                    }
                }
            }
        }

        return out
    }

    /// `torch.stft(center=True, pad_mode="reflect")` mirrors `nFFT / 2` samples onto each
    /// end, and the reflection excludes the edge sample itself: the left pad runs
    /// `x[pad] … x[1]` and the right pad `x[n - 2] … x[n - 1 - pad]`.
    private func reflectPadded(_ samples: [Float]) -> [Float] {
        let pad = nFFT / 2
        let count = samples.count
        var padded = [Float](repeating: 0, count: count + 2 * pad)

        padded.withUnsafeMutableBufferPointer { destination in
            samples.withUnsafeBufferPointer { source in
                (destination.baseAddress! + pad).update(from: source.baseAddress!, count: count)

                for i in 0 ..< pad {
                    destination[i] = source[pad - i]
                    destination[pad + count + i] = source[count - 2 - i]
                }
            }
        }

        return padded
    }

    /// One frame: window it, transform it, and write the `nFreq` one-sided magnitudes at
    /// torch's scale.
    private func transform(
        _ source: UnsafePointer<Float>, _ coefficients: UnsafePointer<Float>,
        into row: UnsafeMutablePointer<Float>, using workspace: Workspace
    ) {
        let half = nFFT / 2
        vDSP_vmul(source, 1, coefficients, 1, workspace.windowed, 1, vDSP_Length(nFFT))

        // vDSP's real transform takes the even samples as the real part and the odd ones
        // as the imaginary part of a half-length complex vector, which is what `ctoz`
        // does when it is handed the frame reinterpreted as interleaved complex.
        workspace.windowed.withMemoryRebound(to: DSPComplex.self, capacity: half) { interleaved in
            vDSP_ctoz(interleaved, 2, &workspace.input, 1, vDSP_Length(half))
        }

        fft.forward(input: workspace.input, output: &workspace.spectrum)

        // The real transform returns `half` complex slots for `half + 1` bins: DC and
        // Nyquist are both purely real and vDSP hides them in `real[0]` and `imag[0]`.
        // Taking the modulus of all `half` slots first gets bins 1 … half - 1 right and
        // leaves a meaningless value in slot 0, which the two assignments then replace.
        vDSP_zvabs(&workspace.spectrum, 1, row, 1, vDSP_Length(half))
        row[half] = abs(workspace.spectrum.imagp[0])
        row[0] = abs(workspace.spectrum.realp[0])

        // vDSP scales a real forward transform by two relative to the DFT torch computes.
        var halfScale = Float(0.5)
        vDSP_vsmul(row, 1, &halfScale, row, 1, vDSP_Length(half + 1))
    }

    /// The buffers the frame loop reuses. vDSP wants the even and odd samples in separate
    /// arrays, and allocating four of them per frame would cost more than the transform.
    /// A class so `deinit` frees them on every path out of `magnitudes`.
    private final class Workspace {
        let windowed: UnsafeMutablePointer<Float>
        var input: DSPSplitComplex
        var spectrum: DSPSplitComplex

        init(nFFT: Int) {
            let half = nFFT / 2

            // Zeroed rather than left raw: every buffer is fully overwritten before it is
            // read, but vDSP reads and writes these through C, which is no place to be
            // relying on that.
            func buffer(_ capacity: Int) -> UnsafeMutablePointer<Float> {
                let pointer = UnsafeMutablePointer<Float>.allocate(capacity: capacity)
                pointer.initialize(repeating: 0, count: capacity)
                return pointer
            }

            windowed = buffer(nFFT)
            input = DSPSplitComplex(realp: buffer(half), imagp: buffer(half))
            spectrum = DSPSplitComplex(realp: buffer(half), imagp: buffer(half))
        }

        deinit {
            windowed.deallocate()
            input.realp.deallocate()
            input.imagp.deallocate()
            spectrum.realp.deallocate()
            spectrum.imagp.deallocate()
        }
    }
}
