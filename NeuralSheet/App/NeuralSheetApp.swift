import AppKit
import NeuralSheetCore
import SwiftUI

@main
struct NeuralSheetApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    /// Created once with the app: it owns the audio engine, and a second instance would open a
    /// second one.
    @State private var model: AppModel

    /// Keeps the settings and the session on disk in step with the model, for the app's lifetime.
    @State private var persistence: Persistence

    /// What the Audio menu shows as chosen. The engine's own properties are not observable, and
    /// they can be rolled back when a device refuses; the menu re-reads them after every choice.
    @State private var audioMenu = AudioMenuState()

    init() {
        FontRegistry.registerBundledFonts()

        let model = AppModel()
        _model = State(initialValue: model)
        _persistence = State(initialValue: Persistence(model: model))
    }

    var body: some Scene {
        Window("NeuralSheet", id: "main") {
            MainView(model: model, persistence: persistence)
        }
        // The size is the settings' (`editorScale`), applied by `MainWindowController` as the
        // window opens; SwiftUI's own restoration would put back whatever the last close left.
        .defaultSize(width: MainWindowController.canvas.width * model.settings.editorScale,
                     height: MainWindowController.canvas.height * model.settings.editorScale)
        .restorationBehavior(.disabled)
        .windowResizability(.contentSize)
        .commands {
            audioMenu(model: model)
        }
    }

    // MARK: - Audio menu

    /// Spec §7 deviation 7: the standalone's way of choosing the microphone and the output, in
    /// place of JUCE's Options dialog. A choice is applied to the engine at once -- an input
    /// device is what the next take records from, and the engine rebuilds its graph for it now
    /// rather than when the Record button is pressed.
    private func audioMenu(model: AppModel) -> some Commands {
        CommandMenu("Audio") {
            Menu("Input") {
                deviceRows(devices: AudioDevices.inputs(), chosen: audioMenu.input) { device in
                    model.engine.inputDevice = device
                    audioMenu.input = model.engine.inputDevice
                }
            }

            Menu("Output") {
                deviceRows(devices: AudioDevices.outputs(), chosen: audioMenu.output) { device in
                    model.engine.outputDevice = device
                    audioMenu.output = model.engine.outputDevice
                }
            }
        }
    }

    /// "System Default", a separator, then every device: the chosen one ticked, the default when
    /// nothing has been chosen.
    @ViewBuilder
    private func deviceRows(devices: [AudioDevice],
                            chosen: AudioDevice?,
                            choose: @escaping (AudioDevice?) -> Void) -> some View {
        Toggle("System Default", isOn: Binding(get: { chosen == nil }, set: { _ in choose(nil) }))

        Divider()

        ForEach(devices) { device in
            Toggle(device.name, isOn: Binding(get: { chosen == device }, set: { _ in choose(device) }))
        }
    }
}

/// The devices the Audio menu last put the engine on.
@Observable final class AudioMenuState {
    var input: AudioDevice?
    var output: AudioDevice?
}

/// The standalone quits with its window, as the JUCE one did.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
