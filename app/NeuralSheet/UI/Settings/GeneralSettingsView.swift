import NeuralSheetCore
import SwiftUI

/// Settings → General: the tooltips switch and what the MIDI writer does with more instruments
/// than the file has channels (inventory §11.3), plus the update check.
struct GeneralSettingsView: View {
    @Bindable var model: AppModel

    var body: some View {
        Form {
            Section {
                Toggle("Show tooltips", isOn: $model.settings.tooltipsVisible)
            }

            Section {
                Picker("When a MIDI export has too many instruments:", selection: $model.settings.midiOverflowMode) {
                    Text("Reuse the last channels").tag(MidiOverflowMode.reuseChannels)
                    Text("Drop the extra instruments").tag(MidiOverflowMode.dropExtraInstruments)
                }
                .pickerStyle(.radioGroup)
            } footer: {
                Text("A MIDI file has 16 channels, one of which is reserved for drums.")
                    .foregroundStyle(.secondary)
            }

            Section {
                LabeledContent("Updates") {
                    Button("Check for Updates…") {
                        model.checkForUpdates(explicit: true)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}
