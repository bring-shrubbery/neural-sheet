import AppKit
import SwiftUI

/// A transparent layer over a SwiftUI view that takes secondary presses only -- SwiftUI has no
/// right-click gesture. `hitTest` answers itself for a right button, or a Control-click, and
/// nothing otherwise, so every other event reaches whatever is under it. Reports the press in
/// window coordinates with the window, so the caller can hang a panel from it.
struct RightClickCatcher: NSViewRepresentable {
    let onRightClick: (NSWindow, CGPoint) -> Void

    func makeNSView(context: Context) -> CatcherView {
        let view = CatcherView()
        view.onRightClick = onRightClick

        return view
    }

    func updateNSView(_ view: CatcherView, context: Context) {
        view.onRightClick = onRightClick
    }

    final class CatcherView: NSView {
        var onRightClick: ((NSWindow, CGPoint) -> Void)?

        /// Only for the event being dispatched when it is a secondary press; `point` is in the
        /// superview's coordinates, as AppKit hands it.
        override func hitTest(_ point: NSPoint) -> NSView? {
            guard let event = NSApp.currentEvent, Self.isSecondary(event),
                  bounds.contains(convert(point, from: superview))
            else { return nil }

            return self
        }

        override func rightMouseDown(with event: NSEvent) {
            report(event)
        }

        /// Control-click, the trackpad's secondary click on some settings.
        override func mouseDown(with event: NSEvent) {
            guard event.modifierFlags.contains(.control) else { return super.mouseDown(with: event) }

            report(event)
        }

        private func report(_ event: NSEvent) {
            guard let window else { return }

            onRightClick?(window, event.locationInWindow)
        }

        private static func isSecondary(_ event: NSEvent) -> Bool {
            switch event.type {
            case .rightMouseDown, .rightMouseUp, .rightMouseDragged:
                return true
            case .leftMouseDown, .leftMouseUp, .leftMouseDragged:
                return event.modifierFlags.contains(.control)
            default:
                return false
            }
        }
    }
}
