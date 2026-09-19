import AppKit
import NeuralSheetCore
import SwiftUI

/// The window (`NeuralNoteMainView`, inventory §1.2): top bar over a full-height sidebar beside the
/// toolbar, the timeline and the status bar, laid out to whatever size the window is -- the
/// sidebar keeps its width, the timeline takes the rest -- with the overlays on top in the order the
/// original stacked them: the model panel (centred on the timeline), the update notice above the
/// status bar, the instrument picker off the sidebar; the settings menu opens in its own window
/// under the gear.
///
/// Also where the app's window-bound pieces are installed: the dialogs, the shortcuts, the display
/// link, the session restore and the launch-time update check.
struct MainView: View {
    let model: AppModel
    let persistence: Persistence

    @State private var windowController = MainWindowController()
    @State private var shortcuts: KeyboardShortcuts
    @State private var settingsMenu = SettingsMenuController()

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
        .onAppear(perform: appear)
        .onDisappear(perform: disappear)
    }

    // MARK: - Composition

    /// The status bar belongs to the column right of the sidebar (`VisualizationPanel::resized`),
    /// and the sidebar runs to the bottom of the window with its master panel.
    private var composition: some View {
        VStack(spacing: 0) {
            TopBar(model: model, onSettings: openSettingsMenu)

            HStack(spacing: 0) {
                Sidebar(model: model)

                VStack(spacing: 0) {
                    Toolbar(model: model)

                    TimelineView(model: model)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .overlay {
                            ModelPanelOverlay(model: model)
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

    /// The gear: the settings menu in its own window under the button (§11.3).
    private func openSettingsMenu() {
        guard let window = windowController.window else { return }

        settingsMenu.open(in: window, model: model)
    }

    // MARK: - Lifecycle

    /// The dialogs first, so a session whose file has gone bad can say so; then the session,
    /// the autosave, the shortcuts and the once-per-launch update check.
    private func appear() {
        Dialogs.install(on: model) { [windowController] in windowController.window }
        // A turn later, once the window is on screen: shown now it would be an app-modal alert
        // rather than a sheet, and an app-modal alert stalls the engine's own retries.
        DispatchQueue.main.async {
            model.presentAudioStartFailureIfAny()
        }
        persistence.restoreOnce()
        persistence.start()
        shortcuts.install()

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
        settingsMenu.close()
    }
}
