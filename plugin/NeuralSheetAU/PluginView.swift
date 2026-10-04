import NeuralSheetCore
import SwiftUI

/// The plugin's window in the host: the name, the version and the rate the host runs it at; the
/// capture (sub-issue B): Record, Arm and Stop; the transcription (sub-issue C): the model, the
/// instruments, Stems, Transcribe and its progress; and the roll below, the take's waveform with
/// the notes as they stream in. The transport and the MIDI come in the later sub-issues.
struct PluginView: View {
    let model: PluginViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("NeuralSheet")
                    .font(.title2.weight(.semibold))
                Text("Version \(model.version) · \(rateText)")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                Spacer()
            }

            if let capture = model.capture {
                HStack(spacing: 16) {
                    CaptureButtons(capture: capture, model: model)
                    Divider().frame(height: 20)
                    TranscribeControls(model: model)
                }
                .controlSize(.large)

                StatusLine(capture: capture, model: model)
            }

            if model.models.isEmpty {
                NoModelNotice(model: model)
            }

            TakeArea(model: model)
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.background)
        .onAppear(perform: model.refreshModels)
    }

    private var rateText: String {
        guard let rate = model.sampleRate else { return "Sample rate: —" }
        return "Sample rate: \(rate.formatted(.number.precision(.fractionLength(0)))) Hz"
    }
}

/// Record / Arm / Stop.
private struct CaptureButtons: View {
    let capture: CaptureSession
    let model: PluginViewModel

    var body: some View {
        HStack(spacing: 8) {
            Button("Record", systemImage: "record.circle", action: model.record)
                .disabled(isCapturing || model.transcription.isRunning)
            Button("Arm", systemImage: "play.circle", action: model.arm)
                .disabled(capture.phase != .idle || model.transcription.isRunning)
            Button("Stop", systemImage: "stop.circle", action: model.stop)
                .disabled(capture.phase == .idle)
                .keyboardShortcut(.cancelAction)
        }
    }

    private var isCapturing: Bool {
        if case .capturing = capture.phase { return true }
        return false
    }
}

/// What the capture or the run is doing, and the take's length with Clear.
private struct StatusLine: View {
    let capture: CaptureSession
    let model: PluginViewModel

    var body: some View {
        HStack(spacing: 12) {
            if let run = model.transcription.run {
                ProgressView(value: Double(run.progress))
                    .frame(width: 160)
                Text(runText(run))
            } else if let failure = model.transcription.failure {
                Text(failure)
                    .foregroundStyle(.red)
            } else if let text = captureText {
                Text(text)
            }

            Spacer()

            if let take = capture.capturedTake, capture.phase == .idle {
                Text("Take: \(TimeFormat.transport(take.duration))")
                Button("Clear", action: model.clear)
                    .disabled(model.transcription.isRunning)
            }
        }
        .monospacedDigit()
        .foregroundStyle(.secondary)
        .frame(minHeight: 22)
    }

    private func runText(_ run: PluginTranscription.Run) -> String {
        if run.cancelLatched { return "Cancelling…" }

        switch run.phase {
        case .separating: return "Separating stems"
        case .transcribing(stem: nil): return "Transcribing"
        case let .transcribing(stem: stem?): return "Transcribing \(StemNames.displayNames[stem])"
        }
    }

    /// What the capture is doing, or the last run's result once a take is shown.
    private var captureText: String? {
        switch capture.phase {
        case .idle:
            if let summary = model.transcription.summary {
                let seconds = summary.seconds.formatted(.number.precision(.fractionLength(1)))
                return "\(summary.notes) notes in \(seconds) s"
            }
            return capture.capturedTake == nil ? "Record now, or arm to record when the host plays." : nil
        case .armed:
            return "Armed: recording starts when the host plays."
        case .capturing:
            return "Recording \(TimeFormat.transport(capture.elapsed))"
        }
    }
}

/// No transcription model in the group container: the plugin downloads nothing itself, so it
/// says where the app downloads them and opens the app.
private struct NoModelNotice: View {
    let model: PluginViewModel

    var body: some View {
        VStack(spacing: 8) {
            Text("Download models in NeuralSheet › Settings › Model")
                .font(.headline)
            HStack(spacing: 8) {
                Button("Open NeuralSheet", action: model.openApp)
                Button("Check Again", action: model.refreshModels)
            }
            if model.appMissing {
                Text("NeuralSheet is not installed.")
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity)
        .background(.quaternary, in: .rect(cornerRadius: 8))
    }
}

/// The take and its notes in the roll, once there is a take.
private struct TakeArea: View {
    let model: PluginViewModel

    var body: some View {
        if let content = model.rollContent {
            PluginRoll(content: content)
                .frame(minHeight: 200, maxHeight: .infinity)
                .clipShape(.rect(cornerRadius: 6))
        }
    }
}
