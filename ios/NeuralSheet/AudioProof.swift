import AVFoundation
import Foundation
import NeuralSheetCore
import Observation

/// Temporary (sub-issue B): proves the shared audio layer runs on iOS. "Play test take" plays the
/// bundled sine take under three piano notes through the scheduler and the synth bank; "Record 3 s"
/// records through ``Recorder`` and reports what came back. Everything it learns goes to the
/// console as `NeuralSheet proof:` lines. Launched with `-audioProof play`, `record` or both in
/// order (`record,play`), it runs on its own, for the simulator. Goes when the Transcribe screen (D) arrives.
@Observable
final class AudioProof {
    private(set) var status = "Idle"
    private(set) var busy = false

    @ObservationIgnored private lazy var engine = PlaybackEngine()
    @ObservationIgnored private lazy var recorder = Recorder(engine: engine, paths: .standard)

    /// Runs what the launch arguments ask for, if anything.
    func runFromLaunchArguments() async {
        let arguments = ProcessInfo.processInfo.arguments

        guard let index = arguments.firstIndex(of: "-audioProof"), index + 1 < arguments.count else { return }

        for step in arguments[index + 1].split(separator: ",") {
            switch step {
            case "play": await playTestTake()
            case "record": await record()
            default: report("unknown proof step \(step)")
            }
        }
    }

    func playTestTake() async {
        guard !busy else { return }
        busy = true
        defer { busy = false }

        guard let url = Bundle.main.url(forResource: "test-take", withExtension: "wav") else {
            report("no test-take.wav in the bundle")
            return
        }

        do {
            try engine.start()
        } catch {
            report("engine refused to start: \(PlaybackEngine.describe(error))")
        }

        let bank = InstrumentSynthBank.systemSoundBankURL
        report(
            "engine running=\(engine.isRunning) rate=\(engine.sampleRate) ioBuffer=\(engine.ioBufferFrames) "
                + "sessionError=\(engine.lastDeviceError.map(PlaybackEngine.describe) ?? "none") "
                + "bank=\(bank?.lastPathComponent ?? "none (fallback tone)")")

        let source: SourceAudio

        do {
            source = try AudioFileLoader.load(url: url, deviceRate: engine.sampleRate)
        } catch {
            report("could not load the test take: \(error)")
            return
        }

        report("take \(source.channelCount) ch, \(source.frameCount) frames at \(source.deviceRate) Hz, \(source.duration) s")

        engine.setSource(source)

        // Piano, C4 E4 G4, a half second apart and held to 2.5 s.
        let notes = [60, 64, 67].enumerated().map { index, pitch in
            NoteEvent(startTime: 0.5 + 0.5 * Double(index), endTime: 2.5, pitch: pitch, program: 0)
        }

        engine.synthBank.ensureInstrument(program: 0)
        engine.synthBank.scheduler.swap(notes: notes)
        engine.refreshGains()
        engine.play()

        status = "Playing"

        for _ in 0..<14 {
            try? await Task.sleep(for: .milliseconds(250))
            report(
                String(
                    format: "t=%.2f playing=%@ master=%.1f dB piano=%.1f dB rendered=%llu",
                    engine.playheadSeconds, engine.isPlaying ? "yes" : "no", engine.masterLevelDb,
                    engine.synthBank.levelDb(program: 0), engine.synthBank.renderedFrames))
        }

        engine.stop()
        report("playback done")
    }

    func record() async {
        guard !busy else { return }
        busy = true
        defer { busy = false }

        if Recorder.microphoneAuthorization == .notDetermined {
            let granted = await withCheckedContinuation { continuation in
                Recorder.requestMicrophoneAccess { continuation.resume(returning: $0) }
            }
            report("microphone access granted=\(granted)")
        }

        do {
            try engine.start()
        } catch {
            report("engine refused to start: \(PlaybackEngine.describe(error))")
        }

        let session = AVAudioSession.sharedInstance()
        report(
            "session inputAvailable=\(session.isInputAvailable) inputs=\(session.currentRoute.inputs.map(\.portName)) "
                + "permission=\(Recorder.microphoneAuthorization.rawValue) rate=\(session.sampleRate)")

        do {
            try recorder.start()
        } catch {
            report("recorder refused: \(error); input format \(engine.inputFormat)")
            return
        }

        report("recording from \(engine.inputFormat)")
        status = "Recording"

        try? await Task.sleep(for: .seconds(3))

        let received = recorder.hasReceivedInput
        let seconds = recorder.durationSeconds
        let take = recorder.stop()

        if let take {
            let peak = (0..<take.channelCount).map { channel -> Float in
                let base = take.base(ofChannel: channel)
                return (0..<take.frameCount).reduce(Float(0)) { max($0, abs(base[$1])) }
            }.max() ?? 0

            report(
                "recorded \(take.frameCount) samples per channel (\(take.channelCount) ch at \(take.deviceRate) Hz), "
                    + "\(take.mono16k.count) at 16 kHz, \(String(format: "%.2f", seconds)) s, peak \(peak), "
                    + "input arrived=\(received)")
        } else {
            report(
                "no take: input arrived=\(received), error=\(recorder.lastError.map { "\($0)" } ?? "none (empty take)")")
        }
    }

    private func report(_ line: String) {
        status = line
        print("NeuralSheet proof: \(line)")
    }
}
