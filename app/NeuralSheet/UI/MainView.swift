import AppKit
import NeuralSheetCore
import SwiftUI

/// The window (`NeuralNoteMainView`, inventory §1.2), rebuilt from SwiftUI's own pieces (native
/// chrome design §2): a split view with the mixer in the sidebar, the timeline or the score in
/// the detail beside the inspector, and the window's toolbar carrying the tabs and their actions,
/// laid out to whatever size the window is. The no-model notice sits on the piano roll, the
/// transport floats over the detail. The settings are a window of their own (⌘,).
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
                // Manage Versions… (versions design §2), on its own view: one view carries one
                // sheet.
                .sheet(isPresented: Binding(get: { model.isManageVersionsPresented },
                                            set: { if !$0 { model.closeManageVersions() } })) {
                    ManageVersionsSheet(model: model)
                }

            composition
                // Export Audio…'s progress (audio export design §2). On the composition rather
                // than beside the MIDI export's sheet: one view carries one sheet.
                .sheet(isPresented: Binding(get: { model.audioRender != nil },
                                            set: { if !$0 { model.cancelAudioExport() } })) {
                    RenderProgressSheet(model: model)
                }
        }
        .frame(minWidth: MainWindowController.minContentSize.width,
               minHeight: MainWindowController.minContentSize.height)
        .navigationTitle(model.projectTitle)
        .navigationSubtitle(StatusText.subtitle(model))
        .background(MainWindowHost(controller: windowController, model: model))
        .sheet(isPresented: Binding(get: { model.isExportDialogPresented },
                                    set: { model.isExportDialogPresented = $0 })) {
            ExportDialog(model: model)
        }
        .onAppear(perform: appear)
        .onDisappear(perform: disappear)
    }

    // MARK: - Composition

    /// A split view (native chrome design §2): the mixer in the system's floating sidebar, the
    /// timeline or the score in the detail with the inspector on its right, and the window's
    /// toolbar over both. The transport floats in glass over the bottom of the detail, the
    /// vertical zoom over the roll's corner.
    private var composition: some View {
        NavigationSplitView {
            MixerSidebar(model: model)
                .navigationSplitViewColumnWidth(SidebarMetrics.width)
        } detail: {
            detail
                .inspector(isPresented: Binding(get: { model.isInspectorShown }, set: { model.isInspectorShown = $0 })) {
                    InspectorView(model: model)
                        .inspectorColumnWidth(min: 250, ideal: 280, max: 360)
                }
        }
        .toolbar {
            MainToolbar(model: model,
                        isInspectorShown: Binding(get: { model.isInspectorShown }, set: { model.isInspectorShown = $0 }))
        }
    }

    private var detail: some View {
        // The timeline stays in the hierarchy under the score, so its zoom, scroll and pitch
        // range survive a visit to the Score tab. Time runs left to right whatever the language:
        // the timeline and the score keep their direction under a right-to-left system language
        // (localization design §2); the menus and Settings follow the system.
        ZStack {
            TimelineView(model: model)
                .opacity(model.workspace == .score ? 0 : 1)
                .allowsHitTesting(model.workspace != .score)
                .accessibilityHidden(model.workspace == .score)
                .environment(\.layoutDirection, .leftToRight)

            if model.workspace == .score {
                ScoreTabView(model: model)
                    .environment(\.layoutDirection, .leftToRight)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.bgRoot)
        .overlay {
            if model.workspace == .transcribe, model.needsModelNotice {
                NoModelNotice(model: model)
                    .padding(.leading, TimelineMetrics.gutterWidth)
                    .padding(.top, TimelineMetrics.pianoRollY)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            // Above the transport, so the two never meet in a narrow detail.
            if model.workspace != .score {
                ZoomCapsule(model: model)
                    .padding(.trailing, 16)
                    .padding(.bottom, 84)
            }
        }
        .overlay(alignment: .bottom) {
            TransportCapsule(model: model)
                .padding(.bottom, 18)
        }
    }

    // MARK: - Lifecycle

    /// The dialogs first, then the settings autosave and the shortcuts.
    private func appear() {
        Dialogs.install(on: model) { [windowController] in windowController.window }
        Dialogs.installConfirm(on: model) { [windowController] in windowController.window }
        Dialogs.installNumber(on: model) { [windowController] in windowController.window }
        Dialogs.installText(on: model) { [windowController] in windowController.window }
        Dialogs.installProjectDialogs(on: model) { [windowController] in windowController.window }
        Dialogs.installMIDIImportChoice(on: model) { [windowController] in windowController.window }

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
            model.presentSoundBankFailureIfAny()
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
