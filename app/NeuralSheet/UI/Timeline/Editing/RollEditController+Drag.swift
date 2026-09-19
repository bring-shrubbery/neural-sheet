import AppKit
import NeuralSheetCore

/// The drag itself: deciding what a pending press became, resolving each move, and auto-scroll.
extension RollEditController {
    /// Every mouse move (and every auto-scroll tick) comes through here.
    func update(at point: CGPoint, modifiers: NSEvent.ModifierFlags) {
        guard var session else { return }

        let k = geometry.scale
        let dx = point.x - session.anchorPoint.x
        let dy = point.y - session.anchorPoint.y

        if session.kind == .pending {
            guard hypot(dx, dy) >= RollEditController.dragThreshold * k else { return }

            switch (model.editor.tool, session.anchorHit?.zone) {
            case (_, .body?):
                session.kind = modifiers.contains(.option) ? .duplicate : .move
            case (_, .startEdge?):
                session.kind = .resize(.start)
            case (_, .endEdge?):
                session.kind = .resize(.end)
            case (.select, nil):
                session.kind = .marquee
            case (.erase, nil):
                // From empty: whatever the pointer passes over goes.
                session.kind = .erase
            default:
                self.session = nil
                return
            }
        }

        // ⌘ inverts the snap setting for the gesture.
        let snap = model.editor.snapEnabled != modifiers.contains(.command) ? model.editor.grid : nil
        let deltaSeconds = geometry.seconds(forX: dx)

        switch session.kind {
        case .move, .duplicate:
            let pitch = geometry.pitch(forY: point.y) ?? session.anchorPitch
            let lock: AxisLock? = modifiers.contains(.shift) ? EditGestureMath.axisLock(deltaX: Double(dx), deltaY: Double(dy)) : nil
            let resolved = EditGestureMath.resolveMove(deltaSeconds: deltaSeconds,
                                                       deltaSemitones: pitch - session.anchorPitch,
                                                       anchorStart: session.anchorHit?.note.startTime ?? 0,
                                                       grid: snap, axisLock: lock)
            session.resolvedSeconds = resolved.seconds
            session.resolvedSemitones = resolved.semitones
            roll.setPreview(DragPreview(kind: .transform(deltaSeconds: resolved.seconds, deltaSemitones: resolved.semitones,
                                                         duplicating: session.kind == .duplicate),
                                        ids: session.ids))

        case let .resize(edge):
            let anchorEdge = edge == .start ? session.anchorHit?.note.startTime : session.anchorHit?.note.endTime
            session.resolvedSeconds = EditGestureMath.resolveResize(deltaSeconds: deltaSeconds, anchorEdgeTime: anchorEdge ?? 0, grid: snap)
            roll.setPreview(DragPreview(kind: .resize(edge: edge, deltaSeconds: session.resolvedSeconds), ids: session.ids))

        case .marquee:
            let rect = CGRect(x: session.anchorPoint.x, y: session.anchorPoint.y, width: dx, height: dy).standardized
            roll.marquee.frame = rect
            roll.marquee.isHidden = false
            let inside = EditGestureMath.marqueeSelection(rect, notes: roll.noteRects(intersecting: rect))
            model.setSelection(session.additive ? session.initialSelection.union(inside) : inside)

        case .draw:
            // The anchor had a lane when the session began, so this cannot come back nil. `snap`
            // already carries ⌘'s inversion for the gesture.
            guard let drawn = drawnNote(anchor: session.anchorPoint, current: point, snapEnabled: snap != nil) else { break }
            session.drawn = drawn
            roll.setPreview(DragPreview(kind: .draw(drawn), ids: []))

        case .erase:
            if let hit = roll.hit(at: point) {
                session.erased.insert(hit.id)
            }
            roll.setPreview(DragPreview(kind: .erase, ids: session.erased))

        case .pending:
            break
        }

        self.session = session
    }

    /// One display-link tick during a drag: scrolls when the pointer is past the viewport and
    /// re-feeds the drag at the same window point. True when something scrolled, which keeps the
    /// link awake for the next tick; at the end of the content nothing does, and it dozes.
    func autoScrollTick() -> Bool {
        guard let session, session.kind != .pending, let container else { return false }

        let k = geometry.scale
        let clip = container.scrollView.contentView
        let visible = roll.visibleRect
        let point = roll.convert(lastWindowPoint, from: nil)
        var scrolled = false

        if point.x < visible.minX || point.x > visible.maxX {
            let before = clip.bounds.minX
            let step = RollEditController.autoScrollPixelsPerTick * k

            container.scroll(toX: point.x < visible.minX ? before - step : before + step)
            scrolled = clip.bounds.minX != before
        }

        if point.y < visible.minY || point.y > visible.maxY {
            autoScrollTicks += 1

            if autoScrollTicks % RollEditController.autoScrollTicksPerKey == 0,
               container.scrollPitch(bySemitones: point.y < visible.minY ? 1 : -1)
            {
                scrolled = true
            }
        } else {
            autoScrollTicks = 0
        }

        if scrolled {
            // Every kind re-feeds, the marquee included: the pointer is still, the content moved.
            update(at: roll.convert(lastWindowPoint, from: nil), modifiers: NSEvent.modifierFlags)
        }

        return scrolled
    }
}
