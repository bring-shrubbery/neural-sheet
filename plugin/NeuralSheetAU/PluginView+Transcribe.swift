import NeuralSheetCore
import SwiftUI

/// The model, the instruments, Stems (while the Demucs weights are installed), and Transcribe,
/// which turns into Cancel while a run goes: the Transcribe toolbar of the app, in the plugin.
struct TranscribeControls: View {
    @Bindable var model: PluginViewModel

    var body: some View {
        HStack(spacing: 8) {
            Picker("Model", selection: sizeBinding) {
                ForEach(model.models.transcription, id: \.self) { size in
                    Text(size.displayName).tag(Optional(size))
                }
            }
            .labelsHidden()
            .fixedSize()
            .disabled(model.models.isEmpty || model.transcription.isRunning)

            InstrumentsMenu(model: model)
                .disabled(model.transcription.isRunning)

            if model.models.stemsInstalled {
                Toggle("Stems", isOn: $model.separateStems)
                    .toggleStyle(.button)
                    .disabled(model.transcription.isRunning)
            }

            if model.transcription.isRunning {
                Button("Cancel", systemImage: "xmark.circle", action: model.cancelTranscription)
                    .disabled(model.transcription.run?.cancelLatched ?? false)
            } else {
                Button("Transcribe", systemImage: "waveform.badge.magnifyingglass", action: model.transcribe)
                    .disabled(!model.canTranscribe)
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    /// The pick, shown as the size a run would use when nothing is picked.
    private var sizeBinding: Binding<ModelSize?> {
        Binding(get: { model.size }, set: { model.pickedSize = $0 })
    }
}

/// Automatic, or the instruments the decoder is held to, as the app's instrument picker offers
/// them.
private struct InstrumentsMenu: View {
    let model: PluginViewModel

    var body: some View {
        Menu(title) {
            Toggle("Automatic", isOn: Binding(get: { model.selectedGroups.isEmpty },
                                              set: { _ in model.toggle(nil) }))
            Divider()
            ForEach(Instruments.all, id: \.program) { info in
                if let group = info.group {
                    Toggle(info.name, isOn: Binding(get: { model.selectedGroups.contains(group) },
                                                    set: { _ in model.toggle(group) }))
                }
            }
        }
        .fixedSize()
    }

    private var title: String {
        switch model.selectedGroups.count {
        case 0: "Automatic"
        case 1: Instruments.all.first { $0.group == model.selectedGroups[0] }?.name ?? "1 instrument"
        case let count: "\(count) instruments"
        }
    }
}
