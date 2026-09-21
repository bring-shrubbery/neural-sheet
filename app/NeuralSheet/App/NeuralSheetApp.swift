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

    /// The document commands (projects design §5.7). Close is SwiftUI's own ⌘W, which asks the
    /// window's delegate. Export MIDI… only once there is a finished transcription.
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
        }
    }

    // MARK: - Edit menu

    /// Undo/Redo and the note commands. A text field that has the keyboard keeps its own undo,
    /// select-all and delete: the actions go down the responder chain in that case, as the
    /// system items would have.
    ///
    /// Undo, Redo and Select All are always enabled and route when chosen: which responder has
    /// the keyboard is not observable, so a `disabled` that read it would go stale the moment a
    /// field took focus, and ⌘Z would be dead inside it. Outside the Edit tab, with no field
    /// focused, they do nothing; the model guards its side too. The items whose enablement is
    /// model state alone stay disabled outside the Edit tab.
    @CommandsBuilder
    private func editMenu(model: AppModel) -> some Commands {
        CommandGroup(replacing: .undoRedo) {
            Button(model.undoMenuTitle) {
                if Self.textFieldHasFocus {
                    NSApp.sendAction(Selector(("undo:")), to: nil, from: nil)
                } else if model.workspace == .edit {
                    model.undo()
                }
            }
            .keyboardShortcut("z", modifiers: .command)

            Button(model.redoMenuTitle) {
                if Self.textFieldHasFocus {
                    NSApp.sendAction(Selector(("redo:")), to: nil, from: nil)
                } else if model.workspace == .edit {
                    model.redo()
                }
            }
            .keyboardShortcut("z", modifiers: [.command, .shift])
        }

        // Cut, Copy and Paste route like Undo: a field's own while one is being typed in, the
        // selection's in the Edit tab. What the pasteboard holds is not observable either, so
        // Paste stays enabled and does nothing when there are no notes on it.
        CommandGroup(replacing: .pasteboard) {
            Button("Cut") {
                if Self.textFieldHasFocus {
                    NSApp.sendAction(#selector(NSText.cut(_:)), to: nil, from: nil)
                } else if model.workspace == .edit {
                    model.cutSelection()
                }
            }
            .keyboardShortcut("x", modifiers: .command)

            Button("Copy") {
                if Self.textFieldHasFocus {
                    NSApp.sendAction(#selector(NSText.copy(_:)), to: nil, from: nil)
                } else if model.workspace == .edit {
                    model.copySelection()
                }
            }
            .keyboardShortcut("c", modifiers: .command)

            Button("Paste") {
                if Self.textFieldHasFocus {
                    NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: nil)
                } else if model.workspace == .edit {
                    model.paste()
                }
            }
            .keyboardShortcut("v", modifiers: .command)

            Divider()

            Button("Delete") { model.deleteSelection() }
                .disabled(model.workspace != .edit || model.editor.selection.isEmpty)

            Button("Select All") {
                if Self.textFieldHasFocus {
                    NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil)
                } else if model.workspace == .edit {
                    model.selectAll()
                }
            }
            .keyboardShortcut("a", modifiers: .command)

            Button("Deselect All") { model.deselectAll() }
                .keyboardShortcut("a", modifiers: [.command, .shift])
                .disabled(model.workspace != .edit)

            Divider()

            Button("Quantize") { model.quantizeSelectionOrAll() }
                .keyboardShortcut("u", modifiers: .command)
                .disabled(model.workspace != .edit)

            Button("Revert to Transcription…") { model.revertToTranscription() }
                .disabled(model.workspace != .edit || !model.hasEdits)
        }
    }

    /// Whether a text field is being typed in; the menu's shortcuts then belong to it.
    private static var textFieldHasFocus: Bool {
        let responder = NSApp.keyWindow?.firstResponder

        return responder is NSText || responder is NSTextField
    }

    // MARK: - View menu

    /// The two tabs (⌘1, ⌘2; Edit only once there is a finished transcription) and Reset Zoom,
    /// which the gear menu used to hold: horizontal back to 1, vertical back to automatic. ⌘0, as
    /// every other app has it.
    private func viewMenu(model: AppModel) -> some Commands {
        CommandMenu("View") {
            Button("Transcribe") { model.setWorkspace(.transcribe) }
                .keyboardShortcut("1", modifiers: .command)

            Button("Edit") { model.setWorkspace(.edit) }
                .keyboardShortcut("2", modifiers: .command)
                .disabled(!model.canEdit)

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
