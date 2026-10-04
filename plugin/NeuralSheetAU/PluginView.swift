import NeuralSheetCore
import SwiftUI

/// The plugin's window in the host: the name, the version and the rate the host runs it at, then
/// the capture (sub-issue B): Record, Arm and Stop, the elapsed time while capturing, and the
/// take's waveform, duration and Clear once it stops. The roll, the transport and the MIDI come
/// in the later sub-issues.
struct PluginView: View {
    let model: PluginViewModel

    var body: some View {
        VStack(spacing: 16) {
            VStack(spacing: 4) {
                Text("NeuralSheet")
                    .font(.largeTitle.weight(.semibold))
                Text("Version \(model.version) · \(rateText)")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }

            if let capture = model.capture {
                CaptureControls(capture: capture, model: model)
            }

            if model.models.isEmpty {
                NoModelNotice(model: model)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
        .onAppear(perform: model.refreshModels)
    }

    private var rateText: String {
        guard let rate = model.sampleRate else { return "Sample rate: —" }
        return "Sample rate: \(rate.formatted(.number.precision(.fractionLength(0)))) Hz"
    }
}

/// Record / Arm / Stop, the status line, and the take.
private struct CaptureControls: View {
    let capture: CaptureSession
    let model: PluginViewModel

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 8) {
                Button("Record", systemImage: "record.circle", action: model.record)
                    .disabled(isCapturing)
                Button("Arm", systemImage: "play.circle", action: model.arm)
                    .disabled(capture.phase != .idle)
                Button("Stop", systemImage: "stop.circle", action: model.stop)
                    .disabled(capture.phase == .idle)
                    .keyboardShortcut(.cancelAction)
            }
            .controlSize(.large)

            if let status {
                Text(status)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }

            if let take = capture.capturedTake {
                VStack(spacing: 8) {
                    TakeWaveform(take: take)
                        .frame(height: 126)
                        .clipShape(.rect(cornerRadius: 6))
                    HStack {
                        Text("Take: \(TimeFormat.transport(take.duration))")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Clear", action: model.clear)
                    }
                }
            }
        }
        .frame(maxWidth: 720)
    }

    private var isCapturing: Bool {
        if case .capturing = capture.phase { return true }
        return false
    }

    /// What the capture is doing; nil once a take is shown.
    private var status: String? {
        switch capture.phase {
        case .idle:
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
        .frame(maxWidth: 720)
        .background(.quaternary, in: .rect(cornerRadius: 8))
    }
}
