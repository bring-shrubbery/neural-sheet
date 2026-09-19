import AppKit
import NeuralSheetCore
import SwiftUI

/// Turns the roll's mouse events into selection changes and `EditBatch`es (design §7). Installed
/// by the container in Edit mode; the roll forwards to it.
///
/// A drag never touches the document: the controller keeps a ``DragSession`` and pushes a
/// ``DragPreview`` to the roll, and the mouse-up commits one batch.
@MainActor final class RollEditController {
    unowned let model: AppModel
    unowned let roll: PianoRollView
    let geometry: TimelineGeometry
    weak var container: TimelineContainerView?

    /// Authored pixels.
    static let edgeWidth: CGFloat = 6
    static let minimumWidthForEdges: CGFloat = 14
    static let dragThreshold: CGFloat = 3
    static let autoScrollPixelsPerTick: CGFloat = 12
    static let autoScrollTicksPerKey = 4

    struct DragSession {
        enum Kind: Equatable {
            /// Mouse is down; the kind is decided once it has moved `dragThreshold`.
            case pending
            case move, duplicate
            case resize(NoteEdge)
            case marquee
            case draw
            case erase
        }

        var kind: Kind = .pending
        var anchorPoint: CGPoint
        var anchorPitch: Int
        var anchorHit: RollHit?
        var ids: Set<NoteID> = []
        var initialSelection: Set<NoteID> = []
        var additive = false
        /// The last resolved transform, committed on mouse-up.
        var resolvedSeconds = 0.0
        var resolvedSemitones = 0
        var drawn: NoteEvent?
        var erased: Set<NoteID> = []
    }

    var session: DragSession?
    /// The pointer's last position in window coordinates, for auto-scroll to re-feed.
    var lastWindowPoint: CGPoint = .zero
    var autoScrollTicks = 0

    init(model: AppModel, roll: PianoRollView, geometry: TimelineGeometry, container: TimelineContainerView) {
        self.model = model
        self.roll = roll
        self.geometry = geometry
        self.container = container
        roll.interaction = self
        roll.setSelection(model.editor.selection)
        model.dragCanceller = { [weak self] in self?.cancelDrag() ?? false }
    }

    /// Leaving Edit mode, or the window: the roll goes back to seeking on a click.
    func uninstall() {
        cancelDrag()
        roll.interaction = nil
        roll.setSelection([])
        model.dragCanceller = nil
    }

    // MARK: - Mouse

    func mouseDown(at point: CGPoint, event: NSEvent) {
        lastWindowPoint = event.locationInWindow
        let shift = event.modifierFlags.contains(.shift)
        let hit = roll.hit(at: point)
        var session = DragSession(anchorPoint: point, anchorPitch: geometry.pitch(forY: point.y) ?? hit?.note.pitch ?? 60)
        session.anchorHit = hit
        session.additive = shift
        session.initialSelection = model.editor.selection

        switch model.editor.tool {
        case .select, .draw:
            if let hit {
                if shift {
                    var selection = model.editor.selection
                    if selection.contains(hit.id) { selection.remove(hit.id) } else { selection.insert(hit.id) }
                    model.setSelection(selection)
                } else if !model.editor.selection.contains(hit.id) {
                    model.setSelection([hit.id])
                }

                session.ids = model.editor.selection
            } else if model.editor.tool == .select {
                if !shift { model.deselectAll() }
                if event.clickCount == 2 { insertNote(at: point); return }
            } else {
                // Draw on empty: the note starts now and follows the drag.
                let drawn = drawnNote(anchor: point, current: point)
                session.kind = .draw
                session.drawn = drawn
                roll.setPreview(DragPreview(kind: .draw(drawn), ids: []))
            }

        case .erase:
            if let hit {
                session.kind = .erase
                session.erased = [hit.id]
                roll.setPreview(DragPreview(kind: .erase, ids: session.erased))
            }
        }

        self.session = session
        container?.resumeDisplayLink()
    }

    func mouseDragged(at point: CGPoint, event: NSEvent) {
        lastWindowPoint = event.locationInWindow
        update(at: point, modifiers: event.modifierFlags)
        // Awake for auto-scroll should the pointer stop past an edge; it dozes again on its own.
        container?.resumeDisplayLink()
    }

    func mouseUp(at point: CGPoint, event: NSEvent) {
        guard self.session != nil else { return }

        // `update` may drop the session (a press that turned into nothing); read it after.
        update(at: point, modifiers: event.modifierFlags)

        guard let session = self.session else { return }

        self.session = nil
        roll.marquee.isHidden = true
        roll.setPreview(nil)

        guard let document = model.document else { return }

        switch session.kind {
        case .pending, .marquee:
            break

        case .move:
            guard session.resolvedSeconds != 0 || session.resolvedSemitones != 0 else { break }
            model.commit(document.move(session.ids, deltaSeconds: session.resolvedSeconds, deltaSemitones: session.resolvedSemitones))

        case .duplicate:
            // A copy on top of its original is no copy: the overlap rule would only eat one.
            guard session.resolvedSeconds != 0 || session.resolvedSemitones != 0 else { break }
            var copy = document
            let batch = copy.duplicate(session.ids, deltaSeconds: session.resolvedSeconds, deltaSemitones: session.resolvedSemitones)
            model.replaceDocumentAndCommit(copy, batch)
            model.setSelection(Set(batch.inserted.map(\.id)))

        case let .resize(edge):
            guard session.resolvedSeconds != 0 else { break }
            model.commit(document.resize(session.ids, edge: edge, deltaSeconds: session.resolvedSeconds))

        case .draw:
            if let drawn = session.drawn {
                var copy = document
                let batch = copy.insert(drawn)
                model.replaceDocumentAndCommit(copy, batch)
                model.setSelection(Set(batch.inserted.map(\.id)))
            }

        case .erase:
            model.commit(document.delete(session.erased))
        }
    }

    /// Escape, a tool change, an undo: the preview goes and nothing is committed. Answers whether
    /// there was a drag to cancel, which is what decides if Escape also clears the selection.
    @discardableResult
    func cancelDrag() -> Bool {
        guard session != nil else { return false }

        session = nil
        roll.marquee.isHidden = true
        roll.setPreview(nil)

        return true
    }

    // MARK: - Cursor

    func cursor(at point: CGPoint) -> NSCursor {
        switch model.editor.tool {
        case .draw:
            return .crosshair
        case .erase:
            return RollEditController.eraserCursor
        case .select:
            if let hit = roll.hit(at: point), hit.zone != .body {
                return .resizeLeftRight
            }

            return .arrow
        }
    }

    /// A 16 px eraser drawn from the toolbar's icon, hot spot at its tip.
    static let eraserCursor: NSCursor = {
        let size = NSSize(width: 16, height: 16)
        let image = NSImage(size: size, flipped: true) { rect in
            let path = Icons.EraserStroked().path(in: rect).cgPath
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            ctx.setStrokeColor(NSColor.white.cgColor)
            ctx.setLineWidth(Icons.strokeWidth)
            ctx.setLineCap(.round)
            ctx.setLineJoin(.round)
            ctx.addPath(path)
            ctx.strokePath()
            return true
        }

        return NSCursor(image: image, hotSpot: NSPoint(x: 3, y: 13))
    }()

    // MARK: - Helpers

    /// Double-click on empty in Select: one division at the target program.
    func insertNote(at point: CGPoint) {
        guard var document = model.document, let pitch = geometry.pitch(forY: point.y) else { return }

        let span = drawnNote(anchor: point, current: point)
        let batch = document.insert(NoteEvent(startTime: span.startTime, endTime: span.endTime, pitch: pitch, program: model.editor.targetProgram))
        model.replaceDocumentAndCommit(document, batch)
        model.setSelection(Set(batch.inserted.map(\.id)))
    }

    /// The Draw tool's note between the anchor and the pointer, at the anchor's pitch.
    func drawnNote(anchor: CGPoint, current: CGPoint) -> NoteEvent {
        let span = EditGestureMath.drawnNote(anchor: geometry.seconds(forX: anchor.x),
                                             current: geometry.seconds(forX: current.x),
                                             grid: model.editor.grid,
                                             snapEnabled: model.editor.snapEnabled)
        let pitch = geometry.pitch(forY: anchor.y) ?? 60

        return NoteEvent(startTime: span.start, endTime: span.end, pitch: pitch, program: model.editor.targetProgram)
    }
}
