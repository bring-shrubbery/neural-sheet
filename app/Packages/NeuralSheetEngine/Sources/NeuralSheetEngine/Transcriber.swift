// Ported from `Transcriber` and `Transcriber::Impl` in muscriptor.cpp's
// cpp/src/transcriber.cpp, with the public shape of
// cpp/include/muscriptor/transcriber.hpp: `load`, `backendName`, `chunkCount` and the
// chunk loop of `Impl::transcribe`. The options plumbing is in Transcriber+Configure.

import Foundation

/// Audio in, notes out: chunking, the mel front-end, the transformer, greedy decoding,
/// the MT3 decode state machine, prelude forcing and note assembly.
///
/// The seam is deliberately the C++ library's: 16 kHz mono float32 of the whole signal
/// in, notes out. Decoding a file, resampling it, writing MIDI and choosing a thread are
/// the caller's, which is what keeps this type free of Foundation's media frameworks and
/// buildable for iOS.
///
/// A transcriber owns a model, and a model owns a KV cache, so **one call at a time**:
/// nothing here is synchronised, and `transcribe` blocks for seconds to minutes. It is
/// created, used and dropped inside one run on that run's thread.
public final class Transcriber {
    /// The only sample rate this model accepts.
    public static let sampleRate = 16_000

    /// Audio window the model consumes at a time, in samples and in seconds.
    public static let segmentSamples = 80_000
    public static let segmentDuration = 5.0

    /// Upper bound on tokens per chunk, matching the reference's `max_gen_len`.
    public static let maxTokensPerChunk = 2000

    /// The `muscriptor.format_version` this build loads; any other value is
    /// `.unsupportedCheckpointVersion`. Taken from `Hparams` rather than written twice.
    public static let checkpointFormatVersion = Hparams.formatVersion

    let model: Model

    /// Built from the mapping the weights came out of, so the checkpoint is opened once.
    let frontEnd: ConditioningFrontEnd

    /// Mel frames one chunk produces: centre padding yields one more than it covers.
    let melFrames: Int

    /// The decode state machine and the note assembly, kept across chunks because every
    /// cross-boundary rule -- tie prologues, overlap trimming, the withheld tail -- needs
    /// the previous chunk's state. Both are reset at the top of `transcribe`.
    var tracker = OpenNoteTracker()
    var assembler = NoteAssembler()

    /// One segment, refilled per chunk rather than reallocated: the model is handed a full
    /// window whatever the signal's length is. @see fillChunk
    var chunkBuffer: [Float]

    /// Loads a checkpoint and brings up a backend. Blocking, and seconds for a large
    /// model: it maps a hundred megabytes and widens three embedding tables.
    ///
    /// Every failure arrives as a `TranscriberError`, including one the layers below did
    /// not think to name, so a host has exactly one error type to translate.
    /// `.unsupportedArchitecture` when the checkpoint is not 16 kHz at 10 ms: both numbers
    /// are baked into the segment length and into the decode state machine's ticks, so a
    /// checkpoint that disagrees cannot be run, only rejected.
    public init(url: URL, options: LoadOptions = LoadOptions()) throws {
        let (model, frontEnd) = try Transcriber.mappingFailures { () -> (Model, ConditioningFrontEnd) in
            let model = try Model.load(
                url: url, useGPU: options.useGPU, contextSize: Transcriber.requiredContextSize)

            let hparams = model.hparams

            guard hparams.sampleRate == Transcriber.sampleRate,
                hparams.frameRate == Vocabulary.frameRate,
                hparams.hopLength == Transcriber.sampleRate / Vocabulary.frameRate
            else {
                throw TranscriberError.unsupportedArchitecture(
                    "checkpoint is \(hparams.sampleRate) Hz at \(hparams.frameRate) frames/s, hop "
                        + "\(hparams.hopLength); this build reads \(Transcriber.sampleRate) Hz at "
                        + "\(Vocabulary.frameRate) frames/s, hop \(Transcriber.sampleRate / Vocabulary.frameRate)")
            }

            return (model, try ConditioningFrontEnd(file: model.file, weights: model.weights, hparams: hparams))
        }

        self.model = model
        self.frontEnd = frontEnd
        melFrames = Transcriber.melFrames(hopLength: model.hparams.hopLength)
        chunkBuffer = [Float](repeating: 0, count: Transcriber.segmentSamples)
    }

    /// Backend in use: `"CPU"` or `"Metal"`. These names are stable, unlike a device's own.
    public var backendName: String { model.backendName }

    /// Number of 5 s chunks a signal of `sampleCount` samples is split into: a partial
    /// tail is a whole chunk, zero-padded.
    public static func chunkCount(sampleCount: Int) -> Int {
        guard sampleCount > 0 else { return 0 }
        return (sampleCount + segmentSamples - 1) / segmentSamples
    }

    /// Transcribes a whole signal. Blocking, seconds to minutes; never call it from an
    /// audio thread.
    ///
    /// - Parameters:
    ///   - samples: 16 kHz mono float32, the entire signal. An empty signal yields no
    ///     notes and no callbacks at all.
    ///   - options: Decode-time configuration; a bad selection is `.invalidArgument`.
    ///   - onUpdate: Called synchronously on this thread once per chunk and once at the
    ///     end. Returning false cancels, and `transcribe` then throws `.cancelled`.
    /// - Returns: Every note, sorted by (onset, isDrum, program, pitch, offset).
    public func transcribe(
        samples: [Float], options: TranscribeOptions = TranscribeOptions(),
        onUpdate: ((TranscriptionUpdate) -> Bool)? = nil
    ) throws -> [Note] {
        try Transcriber.mappingFailures {
            try run(samples: samples, options: options, onUpdate: onUpdate)
        }
    }

    /// The chunk loop proper. @see transcribe
    private func run(
        samples: [Float], options: TranscribeOptions, onUpdate: ((TranscriptionUpdate) -> Bool)?
    ) throws -> [Note] {
        // At the top, not the bottom: a previous call that was cancelled or threw must not
        // leave open notes for this one to inherit.
        tracker.reset()
        assembler.reset()

        try configure(options)

        let chunks = Transcriber.chunkCount(sampleCount: samples.count)

        for chunk in 0 ..< chunks {
            fillChunk(from: samples, index: chunk)

            // The tail is zero-padded and the padding is *not* masked away: the conditioner
            // is handed a full segment, so the model sees the trailing silence as audio.
            // That is what the reference does, and "improving" it would change every note
            // near the end of a signal.
            let conditioning = try frontEnd.encodeAudio(chunkBuffer)

            let boundary = ChunkBoundary(
                seekTime: Double(chunk) * Transcriber.segmentDuration,
                nextSeekTime: chunk + 1 < chunks
                    ? Double(chunk + 1) * Transcriber.segmentDuration : nil)

            // Feed the boundary before reading open keys: it settles a previous chunk that
            // ended mid-prologue, and only then is `openKeys` the decoder's own view.
            try assembler.apply(tracker.feed(boundary: boundary), chunkIndex: chunk)

            var prompt: [Int32] = []

            if chunk > 0 && options.preludeForcing {
                prompt = Vocabulary.tieSectionTokenIDs(openKeys: tracker.openKeys)
            }

            // Clamped rather than allowed to overflow. A pathological prologue eats into
            // the generation budget, which is the right trade: the reference treats running
            // out without an EOS as a warning, not a failure.
            let prefix = melFrames + 1 + model.instrumentRows.count
            let budget = model.contextSize - prefix - 1

            guard budget > prompt.count else {
                throw TranscriberError.contextOverflow
            }

            let tokens = try model.generate(
                conditioning: conditioning, frameCount: melFrames,
                maxTokens: min(Transcriber.maxTokensPerChunk, budget), eosID: Vocabulary.eosID,
                prompt: prompt)

            for token in tokens {
                if token == Vocabulary.eosID {
                    break
                }

                try assembler.apply(tracker.feed(token: token), chunkIndex: chunk)
            }

            if let onUpdate {
                // One chunk late: a note is only final once the following chunk has decoded,
                // so releasing it now would mean correcting it later.
                let ready = chunk > 0 ? assembler.closedIn(chunkIndex: chunk - 1) : []

                let update = TranscriptionUpdate(
                    newNotes: ready,
                    // Chunks 0 through chunk-1 have been released, and each of them closed
                    // only notes ending inside its own window.
                    finalizedThrough: Double(chunk) * Transcriber.segmentDuration,
                    progress: Float(chunk + 1) / Float(chunks))

                if !onUpdate(update) {
                    throw TranscriberError.cancelled
                }
            }
        }

        if chunks > 0 {
            try assembler.apply(tracker.finish(), chunkIndex: chunks - 1)

            if let onUpdate {
                // The withheld tail. Notes `finish()` closes were open throughout, so nothing
                // can have opened on their channel to trim an earlier chunk's -- this call
                // cannot invalidate anything already reported.
                let update = TranscriptionUpdate(
                    newNotes: assembler.closedIn(chunkIndex: chunks - 1),
                    // An under-claim: the last chunk has no window past it, so a note there
                    // may end fractionally later. Claiming less than is known costs a host
                    // nothing; claiming more would cost it a note.
                    finalizedThrough: Double(chunks) * Transcriber.segmentDuration,
                    progress: 1)

                if !onUpdate(update) {
                    throw TranscriberError.cancelled
                }
            }
        }

        return assembler.finalize()
    }
}
