import AppKit
import NeuralSheetCore
import SwiftUI

/// The window (`NeuralNoteMainView`, inventory §1.2): the 1280 x 800 canvas -- top bar over a
/// full-height sidebar beside the toolbar, the timeline and the status bar -- drawn at one scale
/// and never reflowed, with the overlays on top in the order the original stacked them: the model
/// panel (centred on the piano roll), the update notice above the status bar, the instrument
/// picker off the sidebar, and the settings menu under the gear.
///
/// The scale is `min(width / 1280, height / 800)` of whatever the window gives, injected as
/// `\.uiScale`; ``MainWindowController`` keeps the window at the canvas's aspect so the two agree
/// to a pixel. Also where the app's window-bound pieces are installed: the dialogs, the shortcuts,
/// the display link, the session restore and the launch-time update check.
struct MainView: View {
    let model: AppModel
    let persistence: Persistence

    @State private var windowController: MainWindowController
    @State private var shortcuts: KeyboardShortcuts
    @State private var isSettingsMenuOpen = false

    init(model: AppModel, persistence: Persistence) {
        self.model = model
        self.persistence = persistence
        _windowController = State(initialValue: MainWindowController(model: model))
        _shortcuts = State(initialValue: KeyboardShortcuts(model: model))
    }

    // MARK: - Authored layout (`nn::metrics`)

    enum Layout {
        static let canvas = MainWindowController.canvas
        static let topBarHeight: CGFloat = 54
        static let sidebarWidth: CGFloat = SidebarMetrics.width
        static let toolbarHeight: CGFloat = Toolbar.Metrics.height
        static let statusBarHeight: CGFloat = StatusBar.Metrics.height

        /// The timeline block: everything right of the sidebar between the toolbar and the status bar.
        static let timeline = CGRect(x: sidebarWidth,
                                     y: topBarHeight + toolbarHeight,
                                     width: canvas.width - sidebarWidth,
                                     height: canvas.height - topBarHeight - toolbarHeight - statusBarHeight)

        /// The piano roll: the timeline's viewport less the gutter column, the waveform and the ruler.
        static let pianoRoll = CGRect(x: timeline.minX + TimelineMetrics.gutterWidth,
                                      y: timeline.minY + TimelineMetrics.pianoRollY,
                                      width: timeline.width - TimelineMetrics.gutterWidth,
                                      height: timeline.height - TimelineMetrics.pianoRollY)

        /// `VisualizationPanel::_layOutTranscribeButton`: the model panel centred on the roll.
        static var modelPanelAnchor: CGPoint {
            CGPoint(x: pianoRoll.midX - ModelPanelMetrics.width / 2,
                    y: pianoRoll.midY - ModelPanelMetrics.idealHeight / 2)
        }
    }

    // MARK: - Body

    var body: some View {
        GeometryReader { proxy in
            let k = Self.scale(for: proxy.size)
            let s = Scaled(k: k)

            ZStack(alignment: .topLeading) {
                Theme.bgRoot

                ZStack(alignment: .topLeading) {
                    composition

                    ModelPanelOverlay(model: model, anchor: Layout.modelPanelAnchor)

                    if let notice = model.updateNotice {
                        UpdateNoticeView(model: model, notice: notice)
                    }

                    if model.isInstrumentMenuOpen {
                        InstrumentMenuOverlay(model: model)
                    }

                    if isSettingsMenuOpen {
                        SettingsMenuOverlay(model: model,
                                            onWindowScale: windowController.applyScale,
                                            onClose: { isSettingsMenuOpen = false })
                    }
                }
                .frame(width: s(Layout.canvas.width), height: s(Layout.canvas.height), alignment: .topLeading)
                .clipped()
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
            .environment(\.uiScale, k)
            // The corner grip sits in window pixels over everything, as the editor's own child did.
            .overlay(alignment: .bottomTrailing) {
                CornerResizer(controller: windowController)
                    .frame(width: CornerResizer.size, height: CornerResizer.size)
            }
        }
        // The window's limits (§1.1), which `windowResizability(.contentSize)` reads off the
        // content: 0.5x up to what the display holds.
        .frame(minWidth: Layout.canvas.width * MainWindowController.minScale,
               idealWidth: (Layout.canvas.width * windowController.idealScale).rounded(),
               maxWidth: (Layout.canvas.width * windowController.maxScaleForDisplay).rounded(),
               minHeight: Layout.canvas.height * MainWindowController.minScale,
               idealHeight: (Layout.canvas.height * windowController.idealScale).rounded(),
               maxHeight: (Layout.canvas.height * windowController.maxScaleForDisplay).rounded())
        .background(MainWindowHost(controller: windowController, model: model))
        .onAppear(perform: appear)
        .onDisappear(perform: disappear)
    }

    /// `min(w / 1280, h / 800)`: the tighter side, so the canvas never runs past the window.
    static func scale(for size: CGSize) -> CGFloat {
        guard size.width > 0, size.height > 0 else { return 1 }

        return min(size.width / Layout.canvas.width, size.height / Layout.canvas.height)
    }

    // MARK: - Composition

    /// The status bar belongs to the column right of the sidebar (`VisualizationPanel::resized`),
    /// and the sidebar runs to the bottom of the window with its master panel.
    private var composition: some View {
        VStack(spacing: 0) {
            TopBar(model: model, onSettings: { isSettingsMenuOpen = true })

            HStack(spacing: 0) {
                Sidebar(model: model)

                VStack(spacing: 0) {
                    Toolbar(model: model)

                    TimelineView(model: model)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)

                    StatusBar(model: model, automaticNorm: automaticVerticalZoom)
                }
            }
            .frame(maxHeight: .infinity)
        }
    }

    /// `VisualizationPanel::_applyVerticalZoom` for the slider's readout while the zoom is
    /// automatic: the norm that fits the transcription's octaves in the roll's height. The roll is
    /// always 528 authored pixels tall, so this is the timeline's own figure without a round trip.
    private var automaticVerticalZoom: Double {
        let status = model.statusLine
        let content = PianoRollRange.displayRange(notes: status.lowest, highest: status.highest, minSemitones: 0)

        return ZoomMath.normForFit(visibleHeight: Double(Layout.pianoRoll.height), semitones: content.count)
    }

    // MARK: - Lifecycle

    /// The dialogs first, so a session whose file has gone bad can say so; then the session,
    /// the autosave, the shortcuts and the once-per-launch update check.
    private func appear() {
        Dialogs.install(on: model) { [windowController] in windowController.window }
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
        isSettingsMenuOpen = false
    }
}
