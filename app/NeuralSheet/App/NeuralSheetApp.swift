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
    /// they can be rolled back when a device refuses; the menu re-reads them off the model after
    /// every choice.
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
        .defaultSize(width: MainWindowController.defaultContentSize.width,
                     height: MainWindowController.defaultContentSize.height)
        // The content's minimum frame is the window's minimum; there is no maximum.
        .windowResizability(.contentMinSize)
        .commands {
            appMenu(model: model)
            fileMenu(model: model)
            viewMenu(model: model)
            audioMenu(model: model)
        }

        // ⌘, and the app menu's "Settings…", for free.
        Settings {
            SettingsView(model: model, audioDevices: audioMenu)
        }
    }

    // MARK: - App and View menus

    /// "Check for Updates…" where macOS apps keep it, under About.
    private func appMenu(model: AppModel) -> some Commands {
        CommandGroup(after: .appInfo) {
            Button("Check for Updates…") {
                model.checkForUpdates(explicit: true)
            }
        }
    }

    /// Export MIDI…, which the toolbar used to hold as a button beside the tempo field: the two
    /// export settings are asked for in a dialog on the way to the save panel. Only once there is
    /// a finished transcription.
    private func fileMenu(model: AppModel) -> some Commands {
        CommandGroup(after: .saveItem) {
            Divider()

            Button("Export MIDI…") {
                model.requestExport()
            }
            .keyboardShortcut("e", modifiers: [.command, .shift])
            .disabled(!model.canExport)
        }
    }

    /// Reset Zoom, which the gear menu used to hold: horizontal back to 1, vertical back to
    /// automatic. ⌘0, as every other app has it.
    private func viewMenu(model: AppModel) -> some Commands {
        CommandMenu("View") {
            Button("Reset Zoom") {
                model.resetZoom()
            }
            .keyboardShortcut("0", modifiers: .command)
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
                deviceRows(devices: audioMenu.inputs, chosen: audioMenu.input) { device in
                    model.setInputDevice(device)
                    audioMenu.input = model.inputDevice
                }
            }

            Menu("Output") {
                deviceRows(devices: audioMenu.outputs, chosen: audioMenu.output) { device in
                    model.setOutputDevice(device)
                    audioMenu.output = model.outputDevice
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

/// What the Audio menu and Settings → Audio show: the hardware lists, re-read from the HAL every
/// time the menu bar starts being tracked (and when the Audio tab appears) so a device plugged in
/// since the last look is offered, and the devices last put on the engine.
@Observable final class AudioMenuState {
    var inputs: [AudioDevice] = AudioDevices.inputs()
    var outputs: [AudioDevice] = AudioDevices.outputs()
    var input: AudioDevice?
    var output: AudioDevice?

    @ObservationIgnored private var observer: NSObjectProtocol?

    init() {
        observer = NotificationCenter.default.addObserver(
            forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refresh()
            }
        }
    }

    func refresh() {
        let inputs = AudioDevices.inputs()
        let outputs = AudioDevices.outputs()

        if inputs != self.inputs { self.inputs = inputs }
        if outputs != self.outputs { self.outputs = outputs }
    }
}

/// The standalone quits with its window, as the JUCE one did.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
