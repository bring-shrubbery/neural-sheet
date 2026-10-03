import AppKit
import NeuralSheetCore
import SwiftUI

@main
struct NeuralSheetApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    /// Created once with the app: it owns the audio engine, and a second instance would open a
    /// second one.
    @State private var model: AppModel

    /// Keeps the settings on disk in step with the model, for the app's lifetime.
    @State private var persistence: Persistence

    /// What the Audio menu shows as chosen. The engine's own properties are not observable, and
    /// they can be rolled back when a device refuses; the menu re-reads them off the model after
    /// every choice.
    @State private var audioMenu = AudioMenuState()

    /// What the File menu's Open Recent shows.
    @State private var recents: RecentProjects

    init() {
        FontRegistry.registerBundledFonts()

        let model = AppModel()
        _model = State(initialValue: model)
        _persistence = State(initialValue: Persistence(model: model))
        _recents = State(initialValue: RecentProjects(model: model))
        AppDelegate.model = model
    }

    var body: some Scene {
        // First, so it is the window SwiftUI opens at launch; the project window opens from it.
        Window("Welcome to NeuralSheet", id: "welcome") {
            WelcomeView(model: model, recents: recents)
        }
        .windowResizability(.contentSize)
        .windowStyle(.hiddenTitleBar)
        .defaultPosition(.center)

        Window("NeuralSheet", id: "main") {
            MainView(model: model, persistence: persistence)
        }
        .defaultSize(width: MainWindowController.defaultContentSize.width,
                     height: MainWindowController.defaultContentSize.height)
        // The content's minimum frame is the window's minimum; there is no maximum.
        .windowResizability(.contentMinSize)
        // The welcome window is what a launch shows; the project window opens from it, never
        // from restoration.
        .restorationBehavior(.disabled)
        .commands {
            appMenu(model: model)
            fileMenu(model: model)
            editMenu(model: model)
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
                model.checkForUpdates()
            }
            .disabled(!model.updates.canCheckForUpdates)
        }
    }

    /// The document commands (projects design §5.7). Export MIDI…, Export MusicXML… and Export PDF… only once there
    /// is a finished transcription.
    @CommandsBuilder
    private func fileMenu(model: AppModel) -> some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Project") { model.newProject() }
                .keyboardShortcut("n", modifiers: .command)
                .disabled(!model.canChangeProject)

            Button("Open…") { model.openProjectFromPanel() }
                .keyboardShortcut("o", modifiers: .command)
                .disabled(!model.canChangeProject)

            Menu("Open Recent") {
                ForEach(recents.urls, id: \.self) { url in
                    Button(url.deletingPathExtension().lastPathComponent) {
                        model.openProject(url: url)
                    }
                    .help(url.deletingLastPathComponent().path)
                }

                if !recents.urls.isEmpty {
                    Divider()
                }

                Button("Clear Menu") { recents.clear() }
                    .disabled(recents.urls.isEmpty)
            }
            .disabled(!model.canChangeProject)
        }

        CommandGroup(replacing: .saveItem) {
            // SwiftUI's own Close lives in the group this replaces; `performClose` still asks the
            // window's delegate, so the project window's veto applies and the welcome window's
            // close quits.
            Button("Close") { NSApp.keyWindow?.performClose(nil) }
                .keyboardShortcut("w", modifiers: .command)

            Divider()

            Button("Save") { model.saveProject() }
                .keyboardShortcut("s", modifiers: .command)
                .disabled(!model.canSaveProject)

            Button("Save As…") { model.saveProjectAs() }
                .keyboardShortcut("s", modifiers: [.command, .shift])
                .disabled(!model.canSaveProject)

            Button("Revert to Saved…") { model.revertProject() }
                .disabled(!model.canRevertProject)

            Divider()

            Button("Export MIDI…") { model.requestExport() }
                .keyboardShortcut("e", modifiers: [.command, .shift])
                .disabled(!model.canExport)

            Button("Export MusicXML…") { model.exportMusicXML() }
                .keyboardShortcut("e", modifiers: [.command, .shift, .option])
                .disabled(!model.canExport)

            Button("Export PDF…") { model.exportPDF() }
                .keyboardShortcut("p", modifiers: [.command, .shift, .option])
                .disabled(!model.canExport)
        }
    }

    // MARK: - View menu

    /// The three tabs (⌘1, ⌘2, ⌘3; Edit and Score only once there is a finished transcription),
    /// Show Confidence (⌥⌘C), and Reset Zoom, which the gear menu used to hold: horizontal back to
    /// 1, vertical back to automatic. ⌘0, as every other app has it.
    private func viewMenu(model: AppModel) -> some Commands {
        CommandMenu("View") {
            Button("Transcribe") { model.setWorkspace(.transcribe) }
                .keyboardShortcut("1", modifiers: .command)

            Button("Edit") { model.setWorkspace(.edit) }
                .keyboardShortcut("2", modifiers: .command)
                .disabled(!model.canEdit)

            Button("Score") { model.setWorkspace(.score) }
                .keyboardShortcut("3", modifiers: .command)
                .disabled(!model.canEdit)

            Divider()

            // A checkmark toggle, as the Audio menu's devices are; remembered in the global
            // settings (confidence design §2).
            Toggle("Show Confidence", isOn: Binding(get: { model.showsConfidence },
                                                    set: { model.showsConfidence = $0 }))
                .keyboardShortcut("c", modifiers: [.command, .option])

            Divider()

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
