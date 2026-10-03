import AppKit
import NeuralSheetCore
import SwiftUI

/// The app. Started from `main.swift`, which serves the command-line tool first when asked to.
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
    @State private var audioMenu: AudioMenuState

    /// What the File menu's Open Recent shows.
    @State private var recents: RecentProjects

    init() {
        FontRegistry.registerBundledFonts()

        let model = AppModel()
        _model = State(initialValue: model)
        _persistence = State(initialValue: Persistence(model: model))
        _recents = State(initialValue: RecentProjects(model: model))
        _audioMenu = State(initialValue: AudioMenuState(model: model))
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

        // File → Batch Transcribe… (batch and CLI design §2): one window, beside the project's.
        Window("Batch Transcribe", id: "batch") {
            BatchWindow(model: model)
        }
        .defaultSize(width: 720, height: 640)
        .restorationBehavior(.disabled)

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

    /// The document commands (projects design §5.7). Import MIDI… only over a take (MIDI import
    /// design §2); Export MIDI…, Export MusicXML… and Export PDF… only once there is a finished
    /// transcription.
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

            Divider()

            // Over the take, as the transcription or added to it (MIDI import design §2).
            Button("Import MIDI…") { model.importMIDI() }
                .keyboardShortcut("i", modifiers: [.command, .option])
                .disabled(!model.canImportMIDI)

            Divider()

            BatchTranscribeMenuItem()
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

            Divider()

            Button("Export Audio…") { model.exportAudio() }
                .keyboardShortcut("e", modifiers: [.command, .option])
                .disabled(!model.canExportAudio)

            Button("Export Stems…") { model.exportStems() }
                .disabled(!model.canExportStems)
        }
    }

    // MARK: - View menu

    /// The three tabs (⌘1, ⌘2, ⌘3; Edit and Score only once there is a finished transcription),
    /// Show Confidence (⌥⌘C), Show Pitch Curves, and Reset Zoom, which the gear menu used to hold: horizontal back to
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

            // Pitch curves design §2: on by default, remembered in the global settings; no key,
            // as ⌥⌘P is Track Pitch.
            Toggle("Show Pitch Curves", isOn: Binding(get: { model.showsPitchCurves },
                                                      set: { model.showsPitchCurves = $0 }))

            Divider()

            Button("Reset Zoom") {
                model.resetZoom()
            }
            .keyboardShortcut("0", modifiers: .command)
        }
    }

    // MARK: - Audio menu

    /// Spec §7 deviation 7: the standalone's way of choosing the microphone and the output, in
    /// place of JUCE's Options dialog, and the MIDI output beside them (MIDI out design §2). A choice is applied to the engine at once -- an input
    /// device is what the next take records from, and the engine rebuilds its graph for it now
    /// rather than when the Record button is pressed. The inputs end with System Audio and the
    /// apps producing audio now (system audio design §2).
    private func audioMenu(model: AppModel) -> some Commands {
        CommandMenu("Audio") {
            Menu("Input") {
                inputRows { input in
                    model.setRecordingInput(input)
                    audioMenu.input = model.recordingInput
                }
            }

            Menu("Output") {
                deviceRows(devices: audioMenu.outputs, chosen: audioMenu.output) { device in
                    model.setOutputDevice(device)
                    audioMenu.output = model.outputDevice
                }
            }

            Menu("MIDI Output") {
                midiOutputRows(model: model)
            }
        }
    }

    /// "None", a separator, every CoreMIDI destination (the chosen one ticked), a separator, then
    /// the synth mute (MIDI out design §2). The list is the model's, re-read as the menu bar
    /// starts tracking and on CoreMIDI's setup changes.
    @ViewBuilder
    private func midiOutputRows(model: AppModel) -> some View {
        let chosen = model.midiOutDestination

        Toggle("None", isOn: Binding(get: { chosen == nil }, set: { _ in model.setMidiDestination(nil) }))

        Divider()

        ForEach(model.midiDestinations) { destination in
            Toggle(destination.name, isOn: Binding(get: { chosen == destination },
                                                   set: { _ in model.setMidiDestination(destination) }))
        }

        Divider()

        Toggle("Mute Built-in Synth While Sending", isOn: Binding(get: { model.midiOutMutesSynth },
                                                                set: { model.midiOutMutesSynth = $0 }))
    }

    /// The output's rows, below, with System Audio and one row per app after a second separator
    /// (system audio design §2). An app is ticked by its bundle id, whichever process it is now.
    @ViewBuilder
    private func inputRows(choose: @escaping (RecordingInput?) -> Void) -> some View {
        let chosen = audioMenu.input

        Toggle("System Default", isOn: Binding(get: { chosen == nil }, set: { _ in choose(nil) }))

        Divider()

        ForEach(audioMenu.inputs) { device in
            Toggle(device.name, isOn: Binding(get: { chosen == .device(device) },
                                              set: { _ in choose(.device(device)) }))
        }

        Divider()

        ForEach(audioMenu.tapInputs, id: \.self) { input in
            Toggle(AudioMenuState.title(of: input),
                   isOn: Binding(get: { chosen.map { input.isSameChoice(as: $0) } ?? false },
                                 set: { _ in choose(input) }))
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

/// File → Batch Transcribe…: a view of its own so it can reach `openWindow`.
private struct BatchTranscribeMenuItem: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Batch Transcribe…") { openWindow(id: "batch") }
    }
}

/// What the Audio menu and Settings → Audio show: the hardware lists and the apps producing audio,
/// re-read from the HAL every time the menu bar starts being tracked (and when the Audio tab
/// appears) so a device plugged in or an app started since the last look is offered, and the
/// input and output in effect on the engine.
@Observable final class AudioMenuState {
    var inputs: [AudioDevice] = AudioDevices.inputs()
    var outputs: [AudioDevice] = AudioDevices.outputs()
    var apps: [ProcessTap.RunningApp] = ProcessTap.runningApps()
    var input: RecordingInput?
    var output: AudioDevice?

    /// Read again on every refresh: the input can change without a pick -- a refused permission
    /// or a quit app sends it back to a device (system audio design §2).
    @ObservationIgnored private weak var model: AppModel?

    @ObservationIgnored private var observer: NSObjectProtocol?

    init(model: AppModel) {
        self.model = model
        input = model.recordingInput
        output = model.outputDevice

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
        let apps = ProcessTap.runningApps()

        if inputs != self.inputs { self.inputs = inputs }
        if outputs != self.outputs { self.outputs = outputs }
        if apps != self.apps { self.apps = apps }

        if let model {
            // The MIDI destinations are the model's own list; CoreMIDI is asked again here too.
            model.refreshMidiDestinations()

            if model.recordingInput != input { input = model.recordingInput }
            if model.outputDevice != output { output = model.outputDevice }
        }
    }

    /// System Audio, then one input per app producing audio, NeuralSheet left out. The chosen app
    /// stays on the list while it is quiet, so its tick has somewhere to be.
    var tapInputs: [RecordingInput] {
        var rows = apps.map { RecordingInput.app(bundleID: $0.bundleID, pid: $0.pid, name: $0.name) }

        if case .app = input, let input, !rows.contains(where: { $0.isSameChoice(as: input) }) {
            rows.append(input)
        }

        return [.systemAudio] + rows
    }

    /// A tap input's row: "System Audio", or the app's name.
    static func title(of input: RecordingInput) -> String {
        switch input {
        case .device(let device): device.name
        case .systemAudio: String(localized: "System Audio", comment: "Audio menu and Settings → Audio: record what the Mac plays")
        case .app(_, _, let name): name
        }
    }
}
