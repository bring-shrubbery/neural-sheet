import AppKit
import NeuralSheetCore
import SwiftUI

/// The chord lane's part in the container (chord symbols design §2): its wiring to the model,
/// its height in the stack, and its card, hanging from the pointer as the tempo card does.
extension TimelineContainerView {
    func installChordLane() {
        chordLane.onSeek = { [weak self] seconds in self?.seek(toSeconds: seconds) }
        chordLane.onAdd = { [weak self] seconds in self?.model.addChord(at: seconds) }
        chordLane.onMove = { [weak self] index, seconds in self?.model.moveChord(from: index, to: seconds) }
        chordLane.onCard = { [weak self] point, index in self?.showChordCard(at: point, index: index) }
    }

    /// The lane shows in the Edit tab while there are chords; anywhere else, or with none, it is
    /// zero high and the roll starts under the ruler as it always did. A change relays the stack,
    /// and the column beside it, so the keyboard and the roll stay level.
    func updateChordLaneHeight() {
        let height = mode == .edit && !model.editor.chords.isEmpty ? ChordLaneView.height : 0

        if mode != .edit || model.editor.chords.isEmpty {
            chordCard.dismiss()
        }

        guard geometry.chordLaneHeight != height else { return }

        geometry.chordLaneHeight = height
        needsLayout = true
        layoutDocument()
        placeOverlays()
    }

    /// The sync's share: the list, its spelling and the grid it snaps to.
    func syncChordLane(_ new: Snapshot, old: Snapshot, first: Bool) {
        if first || new.chords != old.chords {
            // A card opened by index is for a list that has since gained or lost a chord.
            if new.chords.count != old.chords.count { chordCard.dismiss() }

            chordLane.chords = new.chords
            updateChordLaneHeight()
        }

        if first || new.key != old.key {
            chordLane.key = new.key
        }

        if first || new.grid != old.grid {
            chordLane.grid = new.grid
        }

        if first || new.snapEnabled != old.snapEnabled {
            chordLane.snapEnabled = new.snapEnabled
        }
    }

    func showChordCard(at windowPoint: CGPoint, index: Int) {
        guard let window, model.chords.indices.contains(index) else { return }

        let model = model
        let card = chordCard

        card.showPanel(at: window.convertPoint(toScreen: windowPoint), in: window, scale: geometry.scale) {
            ChordCard(model: model, index: index, host: card)
        }
    }
}
