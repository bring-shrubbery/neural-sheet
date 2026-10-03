import AppKit
import NeuralSheetCore
import SwiftUI

/// The lyric card's part in the container (markers and lyrics design §2): shown under the note
/// the model has it open on, moved along to the next note as syllables are entered, and closed
/// with the model's entry whichever side ends it.
extension TimelineContainerView {
    /// The sync's share: open, follow or close the card as the entry's note changes. Only in
    /// the Edit tab, where the roll edits.
    func syncLyricCard(_ new: Snapshot, old: Snapshot, first: Bool) {
        guard let id = new.lyricNote, mode == .edit else {
            lyricCard.dismiss()
            return
        }

        guard first || id != old.lyricNote || lyricCard.panel == nil else { return }

        guard let window, let note = model.document?.note(id)?.note else {
            model.closeLyricEntry()
            return
        }

        scrollToShow(note)

        // Under the note's onset, so the note and its neighbours stay in view above the card.
        let rect = roll.noteRect(note) ?? CGRect(x: geometry.x(forSeconds: note.startTime), y: roll.visibleRect.midY, width: 0, height: 0)
        let screenPoint = window.convertPoint(toScreen: roll.convert(CGPoint(x: rect.minX, y: rect.maxY + 2 * geometry.scale), to: nil))

        if lyricCard.panel != nil {
            lyricCard.movePanel(to: screenPoint)
            return
        }

        let model = model

        // Whichever way the card goes (Escape, a click elsewhere, the tab changing), the entry
        // goes with it; committing is only ever Return or Tab.
        lyricCard.onDismiss = { [weak model] in model?.closeLyricEntry() }
        lyricCard.showPanel(at: screenPoint, in: window, scale: geometry.scale) {
            LyricCard(model: model)
        }
    }

    /// The note brought into the viewport horizontally when the entry has stepped past its edge.
    private func scrollToShow(_ note: NoteEvent) {
        let visible = scrollView.contentView.bounds
        let x = geometry.x(forSeconds: note.startTime)

        guard x < visible.minX || x > visible.maxX - visible.width * 0.2 else { return }

        scroll(toX: max(0, x - visible.width * 0.3))
    }
}
