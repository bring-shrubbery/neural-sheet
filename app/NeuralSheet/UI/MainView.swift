import AppKit
import NeuralSheetCore
import SwiftUI

/// The window (`NeuralNoteMainView`, inventory §1.2): top bar over the tab strip over a
/// full-height sidebar beside the toolbar, the timeline and the status bar, laid out to whatever
/// size the window is -- the sidebar keeps its width, the timeline takes the rest -- with the
/// overlays on top in the order the original stacked them: the no-model notice (centred on the
/// piano roll), the instrument picker off the sidebar. The settings are a window of their own (⌘,).
///
/// Also where the app's window-bound pieces are installed: the dialogs, the shortcuts and the
/// display link.
struct MainView: View {
    let model: AppModel
    let persistence: Persistence

    @State private var windowController: MainWindowController
    @State private var shortcuts: KeyboardShortcuts
    @State private var tracker: ProjectTracker

    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow

    init(model: AppModel, persistence: Persistence) {
        self.model = model
        self.persistence = persistence
        _shortcuts = State(initialValue: KeyboardShortcuts(model: model))

        let controller = MainWindowController()
        _windowController = State(initialValue: controller)
        _tracker = State(initialValue: ProjectTracker(model: model, windowController: controller))
    }

    // MARK: - Body

    var body: some View {
        ZStack(alignment: .topLeading) {
            Theme.bgRoot

            composition

            if model.isInstrumentMenuOpen {
                InstrumentMenuOverlay(model: model)
            }
        }
        .frame(minWidth: MainWindowController.minContentSize.width,
               minHeight: MainWindowController.minContentSize.height)
        .navigationTitle(model.projectTitle)
        .background(MainWindowHost(controller: windowController, model: model))
        .sheet(isPresented: Binding(get: { model.isExportDialogPresented },
                                    set: { model.isExportDialogPresented = $0 })) {
            ExportDialog(model: model)
        }
        .onAppear(perform: appear)
        .onDisappear(perform: disappear)
    }

    // MARK: - Composition

    /// The status bar belongs to the column right of the sidebar (`VisualizationPanel::resized`),
    /// and the sidebar runs to the bottom of the window with its master panel.
    private var composition: some View {
        VStack(spacing: 0) {
            TopBar(model: model)
            TabStrip(model: model)

            HStack(spacing: 0) {
                Sidebar(model: model)

                VStack(spacing: 0) {
                    if model.workspace == .edit {
                        EditToolbar(model: model)
                    } else {
                        Toolbar(model: model)
                    }

                    TimelineView(model: model)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .overlay {
                            if model.workspace == .transcribe, model.needsModelNotice {
                                NoModelNotice(model: model)
                                    .padding(.leading, TimelineMetrics.gutterWidth)
                                    .padding(.top, TimelineMetrics.pianoRollY)
                            }
                        }

                    StatusBar(model: model)
                }
            }
            .frame(maxHeight: .infinity)
        }
    }

    // MARK: - Lifecycle

    /// The dialogs first, then the settings autosave and the shortcuts.
    private func appear() {
        Dialogs.install(on: model) { [windowController] in windowController.window }
        Dialogs.installConfirm(on: model) { [windowController] in windowController.window }
        Dialogs.installProjectDialogs(on: model) { [windowController] in windowController.window }

        windowController.shouldClose = { window in model.handleWindowClose(window) }

        model.showProjectWindow = { [openWindow, dismissWindow] in
            openWindow(id: "main")
            dismissWindow(id: "welcome")
        }
        model.showWelcomeWindow = { [openWindow] in
            openWindow(id: "welcome")
        }

        if let url = model.pendingOpenURL {
            model.pendingOpenURL = nil
            model.openProject(url: url)
        }
        // A turn later, once the window is on screen: shown now it would be an app-modal alert
        // rather than a sheet, and an app-modal alert stalls the engine's own retries.
        DispatchQueue.main.async {
            model.presentAudioStartFailureIfAny()
        }
        persistence.start()
        tracker.start()
        shortcuts.install { [windowController] in windowController.window }
    }

    private func disappear() {
        shortcuts.uninstall()
        windowController.detach()
    }
}
