import AppKit
import NeuralSheetCore

/// The section markers' part in the container (markers and lyrics design §2): the ruler's flags
/// wired to the model, and the card a marker added from the menu opens on its flag so it can be
/// named at once.
extension TimelineContainerView {
    func installMarkers() {
        ruler.onMoveMarker = { [weak self] id, seconds in self?.model.moveMarker(id: id, to: seconds) }
        ruler.onMarkRange = { [weak self] id in self?.model.markRange(fromMarker: id) }
    }

    /// The sync's share: the list on the ruler, and the rename the menu asked for.
    func syncMarkers(_ new: Snapshot, old: Snapshot, first: Bool) {
        if first || new.markers != old.markers {
            ruler.markers = new.markers
        }

        if let id = new.markerToRename, first || id != old.markerToRename {
            showMarkerCard(id)
            model.markerRenameShown()
        }
    }

    /// The ruler's card on the marker's flag, its name field taking the keyboard. A flag scrolled
    /// out of view gets the card at the ruler's middle instead, so it never opens off screen.
    private func showMarkerCard(_ id: UUID) {
        guard let marker = model.markers.first(where: { $0.id == id }) else { return }

        let visible = ruler.visibleRect
        var point = CGPoint(x: geometry.x(forSeconds: marker.seconds), y: ruler.bounds.maxY)

        if !visible.contains(CGPoint(x: point.x, y: visible.midY)) {
            point.x = visible.midX
        }

        let target = RulerCardTarget(bar: model.editor.grid.bar(atSeconds: marker.seconds), seconds: marker.seconds, markerID: id)
        showTempoCard(at: ruler.convert(point, to: nil), target: target, focusesMarkerName: true)
    }
}
