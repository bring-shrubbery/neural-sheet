import SwiftUI

/// Settings → Audio: the microphone and the output, the same choice the Audio menu offers (spec
/// §7 deviation 7). A pick is applied to the engine at once; the engine can refuse a device and
/// roll back, so what the pickers show is re-read off the model after every choice.
struct AudioSettingsView: View {
    let model: AppModel
    let devices: AudioMenuState

    var body: some View {
        Form {
            Section {
                devicePicker("Input", devices: devices.inputs, chosen: devices.input) { device in
                    model.setInputDevice(device)
                    devices.input = model.inputDevice
                }

                devicePicker("Output", devices: devices.outputs, chosen: devices.output) { device in
                    model.setOutputDevice(device)
                    devices.output = model.outputDevice
                }
            } footer: {
                Text("System Default follows whatever macOS has selected in Sound settings.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        // The hardware may have changed since the window was last looked at.
        .onAppear(perform: devices.refresh)
    }

    /// "System Default", then every device; the chosen one selected, the default when nothing has
    /// been chosen. Selection by id: a device that has gone since the list was read is nothing.
    private func devicePicker(_ title: String,
                              devices: [AudioDevice],
                              chosen: AudioDevice?,
                              choose: @escaping (AudioDevice?) -> Void) -> some View {
        let selection = Binding<AudioDevice.ID?>(
            get: { chosen?.id },
            set: { id in choose(devices.first { $0.id == id }) })

        return Picker(title, selection: selection) {
            Text("System Default").tag(AudioDevice.ID?.none)

            Divider()

            ForEach(devices) { device in
                Text(device.name).tag(AudioDevice.ID?.some(device.id))
            }
        }
    }
}
