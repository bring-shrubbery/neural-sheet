import SwiftUI

/// ``PluginRollView`` in the SwiftUI view.
struct PluginRoll: NSViewRepresentable {
    let content: PluginRollContent

    func makeNSView(context: Context) -> PluginRollView {
        PluginRollView(frame: .zero)
    }

    func updateNSView(_ view: PluginRollView, context: Context) {
        if view.content != content {
            view.update(content)
        }
    }
}
