import AppKit
import NeuralSheetCore
import SwiftUI

/// The main window's AppKit side: holds the `NSWindow` for the pieces that need one (the dialogs,
/// the popup menus) and hosts the display link that drives the model.
///
/// The window is an ordinary resizable macOS window -- the layout reflows and the timeline and
/// the sidebar scroll -- with a minimum size the chrome still fits in (``minContentSize``). The
/// frame is the system's to remember. One per `MainView`; ``MainWindowHost`` hands it the window
/// once the view is in one.
@MainActor @Observable final class MainWindowController {
    /// The smallest content the top bar, the toolbar, the status bar and a few sidebar strips
    /// still fit in.
    static let minContentSize = CGSize(width: 960, height: 560)

    /// The size a fresh window opens at, when the system has nothing remembered for it.
    static let defaultContentSize = CGSize(width: 1280, height: 800)

    @ObservationIgnored private(set) weak var window: NSWindow?

    // MARK: - Attaching

    /// Once, when the view lands in its window.
    func attach(_ window: NSWindow) {
        guard self.window !== window else { return }

        self.window = window
    }

    func detach() {
        window = nil
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
