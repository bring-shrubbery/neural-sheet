import NeuralSheetCore
import SwiftUI

/// Settings → Audio: the microphone and the output, the same choice the Audio menu offers (spec
/// §7 deviation 7). A pick is applied to the engine at once; the engine can refuse a device and
/// roll back, so what the pickers show is re-read off the model after every choice. Below them
/// the sound bank the MIDI plays through, the count-in and the click while recording (click
/// design §2).
struct AudioSettingsView: View {
    @Bindable var model: AppModel
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

            Section {
                LabeledContent("Sound bank") {
                    HStack {
                        Text(model.soundBankName ?? "System (General MIDI)")
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .foregroundStyle(.secondary)

                        Button("Choose…", action: model.chooseSoundBank)

                        Button("Reset", action: model.resetSoundBank)
                            .disabled(model.settings.soundBankPath == nil)
                    }
                }
            } footer: {
                Text("A SoundFont (.sf2) or DLS (.dls) file the MIDI and the click play through.")
                    .foregroundStyle(.secondary)
            }

            Section {
                Picker("Count-in", selection: $model.settings.countInBars) {
                    ForEach(GlobalSettings.countInChoices, id: \.self) { bars in
                        Text(Self.countInLabel(bars)).tag(bars)
                    }
                }

                Toggle("Click while recording", isOn: $model.settings.clickWhileRecording)
            } footer: {
                Text("The count-in plays a click at the project's tempo and meter, then starts the take on the next downbeat.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        // The hardware may have changed since the window was last looked at.
        .onAppear(perform: devices.refresh)
    }

    private static func countInLabel(_ bars: Int) -> String {
        switch bars {
        case 0: "Off"
        case 1: "1 bar"
        default: "\(bars) bars"
        }
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
