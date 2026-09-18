import AppKit
import Combine
import NeuralSheetCore
import SwiftUI
import UniformTypeIdentifiers

/// A minimal harness over ``AppModel``, enough to run the load → transcribe → play path end to
/// end. Task 20 replaces it with the real composition.
struct MainView: View {
    let model: AppModel
    @State private var alert: (title: String, body: String)?
    @State private var isAlertShown = false

    /// Stands in for the window's display link until Task 20 wires one.
    private let tick = Timer.publish(every: 1.0 / 60.0, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Button("Load…", action: load)
                    .disabled(model.state == .recording || model.state == .processing)
                Button(model.state == .recording ? "Stop" : "Record", action: model.toggleRecord)
                    .disabled(!model.canRecord)
                Button(model.transcribeLabel, action: model.launchTranscription)
                    .disabled(!model.canTranscribe)
                Button("Cancel", action: model.cancelTranscription)
                    .disabled(model.state != .processing)
                Button(model.isPlaying ? "Pause" : "Play", action: model.togglePlay)
                    .disabled(!model.state.canPlay)
                Button("Start", action: model.goToStart)
                    .disabled(!model.state.canPlay)
                Button("Clear", action: model.clear)
                    .disabled(model.state == .empty || model.state == .processing)
                Button("Export MIDI…", action: model.exportMidi)
                    .disabled(!model.canExport)
            }

            Text(
                "state: \(model.state.rawValue)   notes: \(model.notes.count)   "
                    + "progress: \(Int((model.transcriptionProgress * 100).rounded()))%"
                    + (model.cancelLatched ? " (cancelling)" : "")
            )
            .font(.system(.body, design: .monospaced))

            Text(
                "\(model.timeReadout.position) / \(model.timeReadout.total)   "
                    + "finalized: \(TimeFormat.seconds2(model.finalizedThrough)) s   "
                    + "master: \(TimeFormat.decibels(model.masterLevelDb)) dB   "
                    + "model: \(model.modelSize?.displayName ?? "none")"
            )
            .font(.system(.body, design: .monospaced))

            let status = model.statusLine
            Text(
                "\(status.instruments) instruments · \(status.notes) notes"
                    + (status.lowest.map { " · \(TimeFormat.pitchName($0)) - \(TimeFormat.pitchName(status.highest ?? $0))" } ?? "")
                    + (model.droppedFileName.map { " · \($0)" } ?? "")
            )
            .font(.system(.body, design: .monospaced))

            ForEach(model.mixer.entries, id: \.program) { entry in
                Text(
                    "\(entry.info.name): \(entry.noteCount) notes   "
                        + "level \(TimeFormat.decibels(model.instrumentLevelDb(program: entry.program))) dB"
                )
                .font(.system(.caption, design: .monospaced))
            }

            Spacer()
        }
        .padding()
        .frame(minWidth: 720, minHeight: 320)
        .onAppear {
            model.presentError = { title, body in
                alert = (title, body)
                isAlertShown = true
            }
        }
        .onReceive(tick) { _ in
            model.displayLinkTick(dt: 1.0 / 60.0)
        }
        .alert(alert?.title ?? "", isPresented: $isAlertShown, presenting: alert) { _ in
            Button("OK") {}
        } message: { alert in
            Text(alert.body)
        }
    }

    private func load() {
        let panel = NSOpenPanel()
        panel.title = "Select Audio File"
        panel.allowedContentTypes = AudioFileLoader.acceptedExtensions.compactMap { UTType(filenameExtension: $0) }
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false

        guard panel.runModal() == .OK, let url = panel.url else { return }

        model.loadAudio(url: url)
    }
}
