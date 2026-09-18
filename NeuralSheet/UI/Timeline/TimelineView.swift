import SwiftUI

/// The timeline block for the SwiftUI composition: gutter, keyboard and the scrolling waveform,
/// ruler and piano roll, sized to whatever frame it is given. AppKit underneath, because this is
/// the one part of the window that scrolls and animates every frame.
struct TimelineView: NSViewRepresentable {
    let model: AppModel

    @Environment(\.uiScale) private var scale

    init(model: AppModel) {
        self.model = model
    }

    func makeNSView(context: Context) -> TimelineContainerView {
        TimelineContainerView(model: model, scale: scale)
    }

    func updateNSView(_ view: TimelineContainerView, context: Context) {
        view.scale = scale
    }
}
