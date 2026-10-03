import AVFoundation
import Foundation
import NeuralSheetCore

/// File → Export Audio…'s render (audio export design §2): the transcription, or the mix as heard,
/// through an `AVAudioEngine` of its own in offline manual rendering mode, faster than real time,
/// into an `AVAudioFile` block by block.
///
/// ```
/// source node (take, one buffer behind) ────────────────────────▶ mainMixer ─▶ (manual output)
/// synths ─▶ (offline bank's sub-mix) ─▶ masterMixer ─────────────▶
/// ```
///
/// The graph is the live one's shape, built from the same ``InstrumentSynthBank`` and
/// ``NoteScheduler`` code with instances of its own, and set through the same ``MixLaw``; it never
/// shares a node, a scheduler or a synth with ``PlaybackEngine``, so playback goes on while a file
/// renders. The bank is built with `live: false`: no MIDI output, no click, no meters.
///
/// Threading: ``render(_:to:progress:isCancelled:)`` is synchronous and belongs to whatever thread
/// calls it -- a detached task -- which creates the engine, renders and tears it down. It polls
/// `isCancelled` once per block.
nonisolated enum OfflineRenderer {
    /// What a render needs, snapshotted on the main actor.
    struct Job: @unchecked Sendable {
        var spec: RenderSpec
        /// The take, at its own device rate: the render rate.
        var take: SourceAudio
        /// The transcription's notes; the click is never among them.
        var notes: [NoteEvent]
        var mixer: InstrumentMixerState
        var soundBankURL: URL?
        /// The live controls, for *Original + MIDI as heard*.
        var mix: Double
        var masterGainDb: Double
        var stereoSplit: Bool
    }

    enum Failure: Error, LocalizedError {
        case format
        case engine(Error)
        case render

        var errorDescription: String? {
            switch self {
            case .format: String(localized: "The audio format is not available.", comment: "Alert body: Export Audio… could not set up the format")
            case let .engine(error): PlaybackEngine.describe(error)
            case .render: String(localized: "The offline render failed.", comment: "Alert body: Export Audio… failed while rendering")
            }
        }
    }

    /// Renders `job` into `url`. True when the file is whole; false when cancelled, with the
    /// partial file removed. A throw removes it too.
    static func render(_ job: Job, to url: URL, progress: (Double) -> Void,
                       isCancelled: () -> Bool = { Task.isCancelled }) throws -> Bool {
        let rate = job.take.deviceRate
        let channels = 2

        let file: AVAudioFile
        do {
            file = try AVAudioFile(forWriting: url, settings: job.spec.format.fileSettings(sampleRate: rate, channels: channels),
                                   commonFormat: .pcmFormatFloat32, interleaved: false)
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw error
        }

        do {
            let finished = job.spec.what == .original
                ? try writeOriginal(job, rate: rate, into: file, progress: progress, isCancelled: isCancelled)
                : try renderGraph(job, rate: rate, into: file, progress: progress, isCancelled: isCancelled)

            if !finished { try? FileManager.default.removeItem(at: url) }

            return finished
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw error
        }
    }

    // MARK: - Original only

    /// The take's channels inside the range, at unity, no engine: there is nothing to mix.
    private static func writeOriginal(_ job: Job, rate: Double, into file: AVAudioFile, progress: (Double) -> Void,
                                      isCancelled: () -> Bool) throws -> Bool {
        let take = job.take
        let range = frames(of: job.spec.range, rate: rate, clampedTo: take.frameCount)
        let block = RenderTail.blockFrames

        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(block)),
              let outputs = buffer.floatChannelData
        else { throw Failure.format }

        var position = range.lowerBound

        while position < range.upperBound {
            if isCancelled() { return false }

            let count = min(block, range.upperBound - position)

            for channel in 0..<Int(file.processingFormat.channelCount) {
                outputs[channel].update(from: take.base(ofChannel: min(channel, take.channelCount - 1)) + position,
                                        count: count)
            }

            buffer.frameLength = AVAudioFrameCount(count)
            try file.write(from: buffer)

            position += count
            progress(Double(position - range.lowerBound) / Double(max(range.count, 1)))
        }

        return true
    }

    // MARK: - MIDI only, and the mix as heard

    private static func renderGraph(_ job: Job, rate: Double, into file: AVAudioFile, progress: (Double) -> Void,
                                    isCancelled: () -> Bool) throws -> Bool {
        let block = RenderTail.blockFrames

        guard let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2) else { throw Failure.format }

        let engine = AVAudioEngine()

        do {
            // Before anything is attached: the output node's format is the bank's render rate.
            try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: AVAudioFrameCount(block))
        } catch {
            throw Failure.engine(error)
        }

        let masterMixer = AVAudioMixerNode()
        engine.attach(masterMixer)

        let bank = InstrumentSynthBank(engine: engine, mixTarget: masterMixer, live: false)
        defer { engine.stop() }

        // MIDI only is the synth at full and the master at 0 dB; as heard is the live controls
        // (audio export design §2). MUTE is the speakers', not the mix's, so it is left out.
        let notes = job.notes.filter { (0...NoteEvent.drumProgram).contains($0.program) }
        let gains = job.spec.what == .midi
            ? MixLaw.resolve(mix: 1, masterGainDb: 0, muted: false, stereoSplit: false, hasNotes: true)
            : MixLaw.resolve(mix: job.mix, masterGainDb: job.masterGainDb, muted: false, stereoSplit: job.stereoSplit,
                             hasNotes: !notes.isEmpty)

        if let soundBank = job.soundBankURL { bank.setSoundBank(url: soundBank) }
        bank.apply(mixer: job.mixer)
        for program in Set(notes.map(\.program)).sorted() { bank.ensureInstrument(program: program) }
        bank.scheduler.swap(notes: notes)
        // A range that starts inside a held note sounds it from the first block, as a seek would.
        bank.scheduler.seek(toSeconds: job.spec.range.lowerBound)
        bank.synthGain = gains.synth
        masterMixer.outputVolume = gains.master

        let range = frames(of: job.spec.range, rate: rate, clampedTo: job.take.frameCount)
        let end = Int((job.spec.transportEnd(notes: notes.map { ($0.startTime, $0.endTime) }) * rate).rounded())
        let transportEnd = min(max(end, range.lowerBound), range.upperBound)
        let source = OfflineSource(take: job.spec.what.includesOriginal ? job.take : nil, bank: bank, rate: rate,
                                   rangeFrames: range, transportEnd: transportEnd,
                                   sourceGain: job.spec.what.includesOriginal ? gains.source : 0)
        let node = AVAudioSourceNode(format: format, renderBlock: source.makeRenderBlock())

        engine.attach(node)
        engine.connect(engine.mainMixerNode, to: engine.outputNode, format: format)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        engine.connect(masterMixer, to: engine.mainMixerNode, format: format)
        node.pan = gains.stereoSplit ? -1 : 0
        masterMixer.pan = gains.stereoSplit ? 1 : 0

        do {
            engine.prepare()
            try engine.start()
        } catch {
            throw Failure.engine(error)
        }

        // The body is the transport's run: the range, or to the last note-off for MIDI only.
        let writer = TailedWriter(file: file, bodyFrames: transportEnd - range.lowerBound, maxTailFrames: RenderTail.maxFrames(sampleRate: rate))

        guard let buffer = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat,
                                            frameCapacity: AVAudioFrameCount(block))
        else { throw Failure.format }

        // The first block is the buffer of lead: its MIDI is scheduled into the next, and its take
        // read lies before the range. It is rendered and dropped.
        var lead = true

        while !writer.isDone {
            if isCancelled() { return false }

            let status: AVAudioEngineManualRenderingStatus
            do {
                status = try engine.renderOffline(AVAudioFrameCount(block), to: buffer)
            } catch {
                throw Failure.engine(error)
            }

            switch status {
            case .success:
                if lead {
                    lead = false
                } else {
                    try writer.write(buffer)
                    progress(writer.progress)
                }
            case .cannotDoInCurrentContext:
                continue
            case .error, .insufficientDataFromInputNode:
                throw Failure.render
            @unknown default:
                throw Failure.render
            }
        }

        return true
    }

    /// `seconds` as take frames at `rate`, inside the take.
    private static func frames(of seconds: ClosedRange<Double>, rate: Double, clampedTo count: Int) -> Range<Int> {
        let lower = min(max(Int((seconds.lowerBound * rate).rounded()), 0), count)
        let upper = min(max(Int((seconds.upperBound * rate).rounded()), lower), count)

        return lower..<upper
    }
}

/// Writes the rendered blocks: the body whole, then the tail until the first block whose peak is
/// under −90 dBFS or 2 s of it, whichever comes first (audio export design §2).
private nonisolated final class TailedWriter {
    let file: AVAudioFile
    let bodyFrames: Int
    let maxTailFrames: Int
    private(set) var written = 0
    private(set) var isDone = false

    init(file: AVAudioFile, bodyFrames: Int, maxTailFrames: Int) {
        self.file = file
        self.bodyFrames = max(bodyFrames, 0)
        self.maxTailFrames = maxTailFrames
    }

    /// 0…1 by the body's frames; the tail is the last sliver.
    var progress: Double {
        bodyFrames > 0 ? min(Double(written) / Double(bodyFrames), 1) : 1
    }

    func write(_ buffer: AVAudioPCMBuffer) throws {
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return }

        // The part of the block past the body is the tail; once it has decayed the file ends
        // before it, so a straddling block keeps only its body.
        let bodyPart = min(max(bodyFrames - written, 0), frames)
        var count = frames

        if bodyPart < frames, RenderTail.isSilent(peak: Self.peak(of: buffer, from: bodyPart, to: frames)) {
            count = bodyPart
            isDone = true
        }

        let limit = bodyFrames + maxTailFrames
        count = min(count, limit - written)

        if count > 0 {
            buffer.frameLength = AVAudioFrameCount(count)
            try file.write(from: buffer)
            buffer.frameLength = AVAudioFrameCount(frames)
            written += count
        }

        if written >= limit { isDone = true }
    }

    private static func peak(of buffer: AVAudioPCMBuffer, from start: Int, to end: Int) -> Float {
        guard let channels = buffer.floatChannelData else { return 0 }

        var peak: Float = 0

        for channel in 0..<Int(buffer.format.channelCount) {
            let data = channels[channel]
            for i in start..<end { peak = max(peak, abs(data[i])) }
        }

        return peak
    }
}
