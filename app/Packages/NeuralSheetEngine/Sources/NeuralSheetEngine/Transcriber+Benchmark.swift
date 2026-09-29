// The per-phase timing of muscriptor.cpp's cpp/bench/bench.cpp, which times a single
// chunk's conditioning, prefill and decode steps against `Model` rather than through the
// public API.
//
// It lives in the library rather than in `engine-bench` because `Model` and
// `ConditioningFrontEnd` are internal: making them public to time them would widen the
// engine's surface for the benefit of a benchmark. `package` is exactly the visibility
// this needs -- the executable is in this package and nothing outside it can see any of
// it. The library still prints nothing; `engine-bench` formats these numbers.

import Foundation

/// One chunk's phase timings, in milliseconds.
package struct PhaseTimings: Sendable {
    package var conditioningMilliseconds: Double

    /// The opening pass over the whole prefix: 502 positions for an unconditioned chunk.
    package var prefillMilliseconds: Double

    /// One entry per decode step, in the order they ran, so a caller can take whichever
    /// statistic it wants rather than one this file chose.
    package var decodeMilliseconds: [Double]
}

extension Transcriber {
    /// Times one chunk's three phases without assembling any notes.
    ///
    /// The tokens are decoded greedily from the model's own argmax, as a real chunk's are,
    /// so the timings are of the work transcription actually does; nothing is compared
    /// against anything, which is what the oracle suites are for.
    ///
    /// This leaves the model mid-sequence. That is safe -- every chunk of `transcribe`
    /// starts with a `reset` -- but it means the call is a measurement, not a step in a
    /// transcription.
    ///
    /// It also times the model as the last `transcribe` left it configured: the conditioning
    /// rows and the forbidden mask of that call's instrument selection, which lengthen the
    /// prefix and mask the logits. A benchmark of the unconditional path measures a transcriber
    /// nothing has transcribed through yet, or one whose last run selected nothing.
    ///
    /// - Parameters:
    ///   - samples: The whole signal; `chunk` selects the window, zero-padded as usual.
    ///   - chunk: Which 5 s window to time.
    ///   - steps: Decode steps to run after the prefill.
    package func measurePhases(samples: [Float], chunk: Int = 0, steps: Int) throws -> PhaseTimings {
        try Transcriber.mappingFailures {
            let clock = ContinuousClock()
            model.reset()
            fillChunk(from: samples, index: chunk)

            let conditioningStart = clock.now
            let conditioning = try frontEnd.encodeAudio(chunkBuffer)
            let conditioningMilliseconds = Transcriber.milliseconds(clock.now - conditioningStart)

            let prefillStart = clock.now
            var logits = try model.prefill(
                conditioning: conditioning, frameCount: melFrames,
                tokens: [Int32(model.hparams.initialTokenID)])
            let prefillMilliseconds = Transcriber.milliseconds(clock.now - prefillStart)

            var decodeMilliseconds: [Double] = []
            decodeMilliseconds.reserveCapacity(steps)

            for _ in 0 ..< steps {
                let next = Model.argmax(logits)
                let start = clock.now
                logits = try model.decode(token: next)
                decodeMilliseconds.append(Transcriber.milliseconds(clock.now - start))
            }

            return PhaseTimings(
                conditioningMilliseconds: conditioningMilliseconds,
                prefillMilliseconds: prefillMilliseconds,
                decodeMilliseconds: decodeMilliseconds)
        }
    }

    /// A `Duration` in milliseconds. `components` rather than
    /// `Double(duration / .milliseconds(1))` because that division is itself a `Duration`
    /// operation and rounds to the nanosecond.
    package static func milliseconds(_ duration: Duration) -> Double {
        let (seconds, attoseconds) = duration.components
        return Double(seconds) * 1000 + Double(attoseconds) / 1e15
    }
}
