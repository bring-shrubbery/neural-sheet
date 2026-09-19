import NeuralSheetCore
import SwiftUI

/// The tabs of the Settings window, and which is on show. The main window can ask for one -- the
/// no-model notice opens the Model tab -- by setting `AppModel.settingsTab` before opening it.
enum SettingsTab: String, CaseIterable, Identifiable {
    case general
    case model
    case audio

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: "General"
        case .model: "Model"
        case .audio: "Audio"
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .model: "waveform.badge.magnifyingglass"
        case .audio: "speaker.wave.2"
        }
    }
}

/// The Settings window (⌘,): a standard macOS settings window with the preferences that used to
/// hang off the gear menu, the transcription model that used to be a panel over the piano roll,
/// and the audio devices the Audio menu also offers.
struct SettingsView: View {
    @Bindable var model: AppModel
    let audioDevices: AudioMenuState

    var body: some View {
        TabView(selection: $model.settingsTab) {
            Tab(SettingsTab.general.title, systemImage: SettingsTab.general.symbol, value: .general) {
                GeneralSettingsView(model: model)
            }

            Tab(SettingsTab.model.title, systemImage: SettingsTab.model.symbol, value: .model) {
                ModelSettingsView(model: model)
            }

            Tab(SettingsTab.audio.title, systemImage: SettingsTab.audio.symbol, value: .audio) {
                AudioSettingsView(model: model, devices: audioDevices)
            }
        }
        .scenePadding()
        .frame(width: 520)
    }
}
