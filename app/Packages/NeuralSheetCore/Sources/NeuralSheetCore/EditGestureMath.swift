import CoreGraphics
import Foundation

/// Where on a note the pointer landed.
public enum NoteHitZone: Equatable, Sendable {
    case body, startEdge, endEdge
}

/// The axis a ⇧-drag keeps.
public enum AxisLock: Equatable, Sendable {
    case timeOnly, pitchOnly
}

/// The decisions the roll's edit controller makes, as pure functions of geometry and the grid, so
/// they can be tested without a view.
public enum EditGestureMath {
    /// The zone under `point`, or nil outside the rect. Edges exist only on notes at least
    /// `minimumWidthForEdges` wide, and each takes the outer `edgeWidth`.
    public static func hitZone(in rect: CGRect, at point: CGPoint, edgeWidth: CGFloat, minimumWidthForEdges: CGFloat) -> NoteHitZone? {
        guard rect.contains(point) else { return nil }
        guard rect.width >= minimumWidthForEdges else { return .body }

        if point.x < rect.minX + edgeWidth { return .startEdge }
        if point.x > rect.maxX - edgeWidth { return .endEdge }

        return .body
    }

    /// Under ⇧: the axis with the larger movement is the one that stays free.
    public static func axisLock(deltaX: Double, deltaY: Double) -> AxisLock {
        abs(deltaX) >= abs(deltaY) ? .timeOnly : .pitchOnly
    }

    /// The anchor note's start is snapped and the same delta applied to every note in the drag.
    public static func resolveMove(deltaSeconds: Double, deltaSemitones: Int, anchorStart: Double, grid: TempoGrid?, axisLock: AxisLock?) -> (seconds: Double, semitones: Int) {
        var seconds = deltaSeconds
        var semitones = deltaSemitones

        if let grid {
            seconds = grid.snap(anchorStart + deltaSeconds) - anchorStart
        }

        switch axisLock {
        case .timeOnly: semitones = 0
        case .pitchOnly: seconds = 0
        case nil: break
        }

        return (seconds, semitones)
    }

    /// The dragged edge of the anchor note is snapped; the same delta goes to every note.
    public static func resolveResize(deltaSeconds: Double, anchorEdgeTime: Double, grid: TempoGrid?) -> Double {
        guard let grid else { return deltaSeconds }

        return grid.snap(anchorEdgeTime + deltaSeconds) - anchorEdgeTime
    }

    /// The Draw tool's note: from the line at or before the click (or the click itself with snap
    /// off) to the pointer, never shorter than one division.
    public static func drawnNote(anchor: Double, current: Double, grid: TempoGrid, snapEnabled: Bool) -> (start: Double, end: Double) {
        let start = max(0, snapEnabled ? grid.snapDown(anchor) : anchor)
        let end = max(snapEnabled ? grid.snap(current) : current, start + grid.step)

        return (start, end)
    }

    /// Every note whose rect intersects the marquee (which may have negative extents).
    public static func marqueeSelection(_ rect: CGRect, notes: [(id: NoteID, rect: CGRect)]) -> Set<NoteID> {
        let marquee = rect.standardized

        return Set(notes.filter { $0.rect.intersects(marquee) }.map(\.id))
    }
}
