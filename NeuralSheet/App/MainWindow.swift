import AppKit
import NeuralSheetCore
import SwiftUI

/// The window's shape (`NnEditorConstrainer`, `NeuralNoteEditor`, inventory §1.1): a 1280 x 800
/// canvas at a fixed aspect, resizable between 0.5x and 2x -- less on a display that cannot hold
/// 2x -- whose scale is restored from the global settings when the window opens and written back
/// when it closes. Also where the display link that drives the model lives.
///
/// One per `MainView`; ``MainWindowHost`` hands it the `NSWindow` once the view is in one.
@MainActor @Observable final class MainWindowController {
    static let canvas = CGSize(width: 1280, height: 800)
    static let minScale = 0.5
    static let maxScale = 2.0

    /// How much of a display's usable area the window may take, by side.
    static let displayWidthFraction = 0.99
    static let displayHeightFraction = 0.90

    /// A scale within this of the persisted one is not rewritten (`PluginEditor.cpp:96`).
    static let persistTolerance = 0.0005

    /// The settings menu's presets.
    static let presetScales: [Double] = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0]

    @ObservationIgnored private let model: AppModel
    @ObservationIgnored private(set) weak var window: NSWindow?
    @ObservationIgnored private var persistedScale: Double

    /// The scale the window opened at, or the preset last chosen: the content's ideal size.
    /// Changed nowhere else, because SwiftUI resizes a `contentSize` window whenever the content's
    /// ideal size changes, and a canvas that never reflows has no business changing it.
    private(set) var idealScale: Double
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    /// The largest scale the window's display holds, for the view's maximum frame. SwiftUI owns
    /// the window's `contentMaxSize` -- it rewrites it on every layout -- so the limit has to
    /// reach the window through the content's own maximum size (`windowResizability(.contentSize)`).
    private(set) var maxScaleForDisplay = MainWindowController.maxScale

    init(model: AppModel) {
        self.model = model
        persistedScale = model.settings.editorScale
        idealScale = persistedScale
    }

    // MARK: - Attaching

    /// Once, when the view lands in its window: the constraints go on, and the persisted scale is
    /// applied.
    func attach(_ window: NSWindow) {
        guard self.window !== window else { return }

        detach()
        self.window = window

        // The title bar is the window's, not the canvas's: with a full-size content view the
        // content's height would include it, and the aspect and the scale would both be off by it.
        window.styleMask.remove(.fullSizeContentView)

        window.contentAspectRatio = NSSize(width: Self.canvas.width, height: Self.canvas.height)
        applyMaximumSizeForCurrentDisplay()

        // The scale is reloaded once per window, so a window opened after the file changed honours
        // what it now holds. Applied once SwiftUI has finished sizing the window it has just
        // shown: set any earlier, the scene's own sizing pass overrides it.
        model.settings = GlobalSettings.load(from: model.paths.globalSettings)
        persistedScale = model.settings.editorScale
        idealScale = clampScale(persistedScale)

        DispatchQueue.main.async { [weak self, weak window] in
            guard let self, let window, self.window === window else { return }

            self.setScale(self.persistedScale)
        }

        observers = [
            observe(NSWindow.didChangeScreenNotification, object: window) { [weak self] in
                self?.applyMaximumSizeForCurrentDisplay()
                self?.clampToDisplay()
            },
            observe(NSWindow.willCloseNotification, object: window) { [weak self] in
                self?.persistScale()
            },
            observe(NSApplication.willTerminateNotification) { [weak self] in
                self?.persistScale()
            },
        ]
    }

    func detach() {
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }

        observers = []
        window = nil
    }

    // MARK: - Scale

    /// `min(width / 1280, height / 800)` of the content now: the tighter side, since the aspect
    /// correction rounds to whole pixels and the two need not agree.
    var appliedScale: Double {
        guard let content = window?.contentView?.bounds.size, content.width > 0, content.height > 0 else {
            return persistedScale
        }

        return min(content.width / Self.canvas.width, content.height / Self.canvas.height)
    }

    /// The largest scale the window's display holds: 99 % of its usable width, 90 % of its
    /// usable height, and never more than 2x.
    func maxScaleForCurrentDisplay() -> Double {
        let screen = window?.screen ?? NSScreen.main

        guard let area = screen?.visibleFrame, area.width > 0, area.height > 0 else {
            return Self.maxScale
        }

        let fitWidth = area.width * Self.displayWidthFraction / Self.canvas.width
        let fitHeight = area.height * Self.displayHeightFraction / Self.canvas.height

        return min(fitWidth, fitHeight, Self.maxScale)
    }

    /// `max(0.5, min(requested, maxForDisplay))`: the minimum wins even on a display too small
    /// for it -- a window clipped at the bottom beats one whose text is unreadable.
    func clampScale(_ scale: Double) -> Double {
        max(Self.minScale, min(scale, maxScaleForCurrentDisplay()))
    }

    /// Settings → Window size: applied clamped, and what was applied is what is stored.
    func applyScale(_ scale: Double) {
        idealScale = clampScale(scale)
        setScale(scale)
        persistScale()
    }

    /// The corner resizer's drag: the scale the requested content size asks for, from whichever
    /// side is tighter, clamped and applied. Not persisted here -- the drag's end does that, as the
    /// constrainer's `resizeEnd` did.
    func resize(toContentSize size: NSSize) {
        let requested = min(size.width / Self.canvas.width, size.height / Self.canvas.height)

        setScale(requested)
    }

    /// Resizes the content to `scale`, clamped, keeping the window's top-left where it is.
    private func setScale(_ scale: Double) {
        guard let window else { return }

        let clamped = clampScale(scale)
        let size = NSSize(width: (Self.canvas.width * clamped).rounded(),
                          height: (Self.canvas.height * clamped).rounded())

        let current = window.frame
        var frame = window.frameRect(forContentRect: NSRect(origin: .zero, size: size))
        frame.origin = NSPoint(x: current.minX, y: current.maxY - frame.height)

        if let screen = window.screen {
            frame = window.constrainFrameRect(frame, to: screen)
        }

        window.setFrame(frame, display: true)
    }

    /// Writes the applied scale back unless it is within tolerance of what was read.
    func persistScale() {
        let scale = appliedScale

        guard abs(scale - persistedScale) >= Self.persistTolerance else { return }

        persistedScale = scale
        model.setEditorScale(scale)
        // Written here and now rather than left to the settings observer: the window closing is
        // often the app quitting, and a deferred write would not land.
        model.saveGlobalSettings()
    }

    // MARK: - Display rule

    /// Publishes the display's limit for the view's maximum frame, as an aspect-consistent pair
    /// so the window cannot be stretched past what the display holds on either side.
    private func applyMaximumSizeForCurrentDisplay() {
        let maxScale = max(maxScaleForCurrentDisplay(), Self.minScale)

        if maxScale != maxScaleForDisplay {
            maxScaleForDisplay = maxScale
        }
    }

    /// After a move to a smaller display, a window past the new maximum is brought back to it.
    private func clampToDisplay() {
        let scale = appliedScale
        let clamped = clampScale(scale)

        if abs(clamped - scale) >= Self.persistTolerance, clamped < scale {
            setScale(clamped)
        }
    }

    private func observe(_ name: Notification.Name,
                         object: Any? = nil,
                         _ body: @escaping @MainActor () -> Void) -> NSObjectProtocol {
        NotificationCenter.default.addObserver(forName: name, object: object, queue: .main) { _ in
            MainActor.assumeIsolated(body)
        }
    }
}

// MARK: - Host view

/// An invisible view in the root of `MainView` that does two things once it is in a window: hands
/// the window to the controller, and runs the display link that ticks the model (§11.5) -- the
/// transport mirror, the recording length, the meters and the notice's expiry.
struct MainWindowHost: NSViewRepresentable {
    let controller: MainWindowController
    let model: AppModel

    func makeNSView(context: Context) -> HostView {
        HostView(controller: controller, model: model)
    }

    func updateNSView(_ nsView: HostView, context: Context) {}

    static func dismantleNSView(_ nsView: HostView, coordinator: ()) {
        nsView.stopDisplayLink()
    }

    final class HostView: NSView {
        private let controller: MainWindowController
        private let model: AppModel
        private var displayLink: CADisplayLink?

        init(controller: MainWindowController, model: AppModel) {
            self.controller = controller
            self.model = model
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) is not supported")
        }

        override var isOpaque: Bool { false }

        /// Nothing here takes a click.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()

            guard let window else {
                stopDisplayLink()
                return
            }

            controller.attach(window)
            startDisplayLink()
        }

        private func startDisplayLink() {
            guard displayLink == nil else { return }

            let link = displayLink(target: self, selector: #selector(tick(_:)))
            // `.common`, so the meters and the playhead keep moving through a menu or a drag.
            link.add(to: .main, forMode: .common)
            displayLink = link
        }

        func stopDisplayLink() {
            displayLink?.invalidate()
            displayLink = nil
        }

        @objc private func tick(_ link: CADisplayLink) {
            let dt = link.targetTimestamp - link.timestamp

            model.displayLinkTick(dt: dt > 0 && dt < 1 ? dt : 1.0 / 60.0)
        }
    }
}
