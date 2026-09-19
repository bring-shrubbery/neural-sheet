import AppKit
import NeuralSheetCore
import SwiftUI

/// The window (`NeuralNoteMainView`, inventory §1.2): top bar over the tab strip over a
/// full-height sidebar beside the toolbar, the timeline and the status bar, laid out to whatever
/// size the window is -- the sidebar keeps its width, the timeline takes the rest -- with the
/// overlays on top in the order the original stacked them: the no-model notice (centred on the
/// piano roll), the update notice above the status bar, the instrument picker off the sidebar.
/// The settings are a window of their own (⌘,).
///
/// Also where the app's window-bound pieces are installed: the dialogs, the shortcuts, the display
/// link, the session restore and the launch-time update check.
struct MainView: View {
    let model: AppModel
    let persistence: Persistence

    @State private var windowController = MainWindowController()
    @State private var shortcuts: KeyboardShortcuts

    init(model: AppModel, persistence: Persistence) {
        self.model = model
        self.persistence = persistence
        _shortcuts = State(initialValue: KeyboardShortcuts(model: model))
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
                        .overlay(alignment: .bottomTrailing) {
                            if let notice = model.updateNotice {
                                UpdateNoticeView(model: model, notice: notice)
                            }
                        }

                    StatusBar(model: model)
                }
            }
            .frame(maxHeight: .infinity)
        }
    }

    // MARK: - Lifecycle

    /// The dialogs first, so a session whose file has gone bad can say so; then the session,
    /// the autosave, the shortcuts and the once-per-launch update check.
    private func appear() {
        Dialogs.install(on: model) { [windowController] in windowController.window }
        Dialogs.installConfirm(on: model) { [windowController] in windowController.window }
        // A turn later, once the window is on screen: shown now it would be an app-modal alert
        // rather than a sheet, and an app-modal alert stalls the engine's own retries.
        DispatchQueue.main.async {
            model.presentAudioStartFailureIfAny()
        }
        persistence.restoreOnce()
        persistence.start()
        shortcuts.install { [windowController] in windowController.window }

        if !Self.hasCheckedForUpdates {
            Self.hasCheckedForUpdates = true
            model.checkForUpdates(explicit: false)
        }
    }

    /// The original checked once per editor open; a SwiftUI view can appear more than once per
    /// window, and one request per launch is what a courtesy check should cost.
    private static var hasCheckedForUpdates = false

    private func disappear() {
        shortcuts.uninstall()
        windowController.detach()
    }
}
