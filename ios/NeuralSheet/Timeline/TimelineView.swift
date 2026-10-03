import SwiftUI

/// The touch timeline for SwiftUI (sub-issue E): keyboard, waveform strip, ruler, chord lane and
/// roll, sized to whatever frame it is given. UIKit underneath, because this is the part of the
/// screen that scrolls and animates every frame, as the Mac's `TimelineView` is AppKit. It
/// watches the model itself, so SwiftUI only hands it its frame.
struct TimelineView: UIViewRepresentable {
    let model: MobileModel

    func makeUIView(context: Context) -> TimelineTouchView {
        TimelineTouchView(model: model)
    }

    func updateUIView(_ view: TimelineTouchView, context: Context) {}
}
