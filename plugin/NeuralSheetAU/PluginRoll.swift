import SwiftUI

/// ``PluginRollView`` in the SwiftUI view, its playhead on the transport's position.
struct PluginRoll: NSViewRepresentable {
    let content: PluginRollContent

    /// Seconds into the take, read every frame while the playhead moves; nil hides it.
    let playheadSeconds: () -> Double?

    /// Changes with anything that moves the playhead (a transport command, the host starting or
    /// stopping), so the roll wakes its display link.
    let transportState: Int

    func makeNSView(context: Context) -> PluginRollView {
        PluginRollView(frame: .zero)
    }

    func updateNSView(_ view: PluginRollView, context: Context) {
        view.playheadSeconds = playheadSeconds

        if view.content != content {
            view.update(content)
        } else {
            view.wakePlayhead()
        }
    }
}
