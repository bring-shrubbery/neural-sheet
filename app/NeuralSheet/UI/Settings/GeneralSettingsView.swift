import NeuralSheetCore
import SwiftUI

/// Settings → General: the tooltips switch and Check for Updates. The MIDI overflow rule
/// (inventory §11.3) is an export setting, asked for in the export dialog.
struct GeneralSettingsView: View {
    @Bindable var model: AppModel

    var body: some View {
        Form {
            Section {
                Toggle("Show tooltips", isOn: $model.settings.tooltipsVisible)
            }

            Section {
                LabeledContent("Updates") {
                    Button("Check for Updates…") {
                        model.checkForUpdates()
                    }
                    .disabled(!model.updates.canCheckForUpdates)
                }
            }
        }
        .formStyle(.grouped)
    }
}
