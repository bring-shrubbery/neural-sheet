import SwiftUI

/// The touch timeline for SwiftUI (sub-issue E): keyboard, waveform strip, ruler, chord lane and
/// roll, sized to whatever frame it is given. UIKit underneath, because this is the part of the
/// screen that scrolls and animates every frame, as the Mac's `TimelineView` is AppKit. It
/// watches the model itself, so SwiftUI only hands it its frame, and what to do when a long
/// press asks for the note card (the note's rect, in this view's coordinates).
struct TimelineView: UIViewRepresentable {
    let model: MobileModel
    var onNoteCard: (CGRect) -> Void = { _ in }

    func makeUIView(context: Context) -> TimelineTouchView {
        let view = TimelineTouchView(model: model)
        view.onNoteCard = onNoteCard
        return view
    }

    func updateUIView(_ view: TimelineTouchView, context: Context) {
        view.onNoteCard = onNoteCard
    }
}
