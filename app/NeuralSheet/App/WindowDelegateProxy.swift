import AppKit

/// Stands in front of the delegate SwiftUI gives its window, answering `windowShouldClose` itself
/// and forwarding every other message to the original (projects design §5.3). SwiftUI's delegate
/// is kept weakly: `window.delegate` never retained it, so whatever owned it before the swap
/// still does, and a strong reference here would only risk a cycle through the scene. The proxy
/// is installed by `MainWindowController.attach` and taken down by `detach`.
final class WindowDelegateProxy: NSObject, NSWindowDelegate {
    /// Written once in `init` and read from the two nonisolated overrides; a weak read is
    /// runtime-synchronised.
    nonisolated(unsafe) private(set) weak var original: NSWindowDelegate?
    private let shouldClose: (NSWindow) -> Bool

    init(original: NSWindowDelegate?, shouldClose: @escaping (NSWindow) -> Bool) {
        self.original = original
        self.shouldClose = shouldClose
    }

    nonisolated override func responds(to selector: Selector!) -> Bool {
        super.responds(to: selector) || (original?.responds(to: selector) ?? false)
    }

    nonisolated override func forwardingTarget(for selector: Selector!) -> Any? {
        original
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        shouldClose(sender)
    }
}
