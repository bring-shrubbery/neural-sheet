import NeuralSheetCore
import UIKit

/// Editing on touch (iOS app design §2, sub-issue F), the Mac's `RollEditController` for fingers:
///
/// - a drag that starts on a selected note moves the selection in time and pitch, snapped as the
///   Mac snaps (the pressed note's start to the grid while `snapEnabled`), each new lane heard;
/// - a drag that starts on a selected note's end handle resizes the selection from that end;
/// - with the Draw tool, a drag on empty lanes draws a note in the target instrument, and a tap
///   puts one division there;
/// - with the Select tool, a press held on empty lanes and then dragged marquee-selects;
/// - a press held on a note selects it and opens the note card;
/// - a two-finger tap undoes.
///
/// A drag on an unselected note, or on empty lanes with the Select tool, pans as before. Like the
/// Mac's, a drag never touches the document: the roll draws a ``DragPreview`` and the lift
/// commits one batch.
extension TimelineTouchView {
    struct EditDrag {
        enum Kind: Equatable {
            case move
            case resize(NoteEdge)
            case draw
            case marquee
        }

        var kind: Kind
        /// Roll coordinates.
        var anchorPoint: CGPoint
        var anchorPitch: Int
        var anchorNote: NoteEvent?
        var ids: Set<NoteID> = []
        var resolvedSeconds = 0.0
        var resolvedSemitones = 0
        var drawn: NoteEvent?
    }

    /// How long a press is held before it opens the card or starts a marquee.
    static let longPressSeconds = 0.4

    func installEditingGestures() {
        let editPan = UIPanGestureRecognizer(target: self, action: #selector(handleEditPan(_:)))
        editPan.maximumNumberOfTouches = 1
        editPan.delegate = self
        scrollView.addGestureRecognizer(editPan)
        scrollView.panGestureRecognizer.require(toFail: editPan)
        self.editPan = editPan

        let longPress = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPress(_:)))
        longPress.minimumPressDuration = TimelineTouchView.longPressSeconds
        longPress.delegate = self
        scrollView.addGestureRecognizer(longPress)
        self.longPress = longPress

        let undoTap = UITapGestureRecognizer(target: self, action: #selector(handleUndoTap(_:)))
        undoTap.numberOfTouchesRequired = 2
        addGestureRecognizer(undoTap)

        marquee.backgroundColor = UIColor(cgColor: TimelinePalette.accentWashRoll)
        marquee.layer.borderColor = TimelinePalette.textPrimary
        marquee.layer.borderWidth = 1
        marquee.isHidden = true
        marquee.isUserInteractionEnabled = false
        roll.addSubview(marquee)

        model.dragCanceller = { [weak self] in self?.cancelEditDrag() ?? false }
    }

    // MARK: - Hit testing

    /// The selected note a touch at `point` (roll coordinates) lands on, and where: its end
    /// handles first (``RollBandView/handleRects(for:)``), then its body grown to the minimum hit
    /// target. The nearest wins.
    func selectedNoteHit(at point: CGPoint) -> (id: NoteID, note: NoteEvent, zone: NoteHitZone)? {
        guard model.canEdit, !model.editor.selection.isEmpty else { return nil }

        let painter = roll.painter
        let reach = TimelineTouchView.minimumHitTarget / 2 + RollBandView.handleWidth
        let sliver = CGRect(x: point.x - reach, y: 0, width: 2 * reach, height: roll.bounds.height)
        let selection = model.editor.selection
        var best: (id: NoteID, note: NoteEvent, zone: NoteHitZone, distance: CGFloat)?

        for index in painter.indices(crossing: sliver, of: painter.notes, buckets: painter.buckets)
        where selection.contains(painter.ids[index]) {
            let note = painter.notes[index]

            guard let rect = painter.noteRect(note, height: roll.bounds.height) else { continue }

            let handles = RollBandView.handleRects(for: rect)
            let grown = rect.insetBy(dx: -max(0, (TimelineTouchView.minimumHitTarget - rect.width) / 2),
                                     dy: -max(0, (TimelineTouchView.minimumHitTarget - rect.height) / 2))
            let zone: NoteHitZone

            if handles.start.contains(point) {
                zone = .startEdge
            } else if handles.end.contains(point) {
                zone = .endEdge
            } else if grown.contains(point) {
                zone = .body
            } else {
                continue
            }

            let dx = max(rect.minX - point.x, 0, point.x - rect.maxX)
            let dy = max(rect.minY - point.y, 0, point.y - rect.maxY)
            let distance = (dx * dx + dy * dy).squareRoot()

            if best == nil || distance < best!.distance {
                best = (painter.ids[index], note, zone, distance)
            }
        }

        return best.map { ($0.id, $0.note, $0.zone) }
    }

    // MARK: - Begin

    /// The edit drag begins on a selected note, or with the Draw tool on an empty lane; anywhere
    /// else it fails and the scroll view pans.
    func editPanShouldBegin(_ recognizer: UIPanGestureRecognizer) -> Bool {
        editDrag = nil

        guard model.canEdit, recognizer.numberOfTouches == 1 else { return false }

        let travel = recognizer.translation(in: roll)
        let now = recognizer.location(in: roll)
        let start = CGPoint(x: now.x - travel.x, y: now.y - travel.y)

        guard roll.bounds.contains(start) else { return false }

        let anchorPitch = geometry.pitch(forY: start.y)

        if let hit = selectedNoteHit(at: start) {
            let kind: EditDrag.Kind = switch hit.zone {
            case .body: .move
            case .startEdge: .resize(.start)
            case .endEdge: .resize(.end)
            }

            editDrag = EditDrag(kind: kind, anchorPoint: start, anchorPitch: anchorPitch ?? hit.note.pitch,
                                anchorNote: hit.note, ids: model.editor.selection)
            return true
        }

        guard model.editor.tool == .draw, noteHit(at: start) == nil, let anchorPitch else { return false }

        editDrag = EditDrag(kind: .draw, anchorPoint: start, anchorPitch: anchorPitch)
        return true
    }

    /// The long press: on a note to open its card, or with the Select tool on empty lanes to
    /// start a marquee.
    func longPressShouldBegin(_ recognizer: UILongPressGestureRecognizer) -> Bool {
        let point = recognizer.location(in: roll)

        guard model.canEdit, roll.bounds.contains(point) else { return false }

        return noteHit(at: point) != nil || model.editor.tool == .select
    }

    // MARK: - Gestures

    @objc private func handleEditPan(_ recognizer: UIPanGestureRecognizer) {
        let point = recognizer.location(in: roll)

        switch recognizer.state {
        case .began, .changed:
            updateEditDrag(at: point)
        case .ended:
            updateEditDrag(at: point)
            finishEditDrag()
        default:
            cancelEditDrag()
        }
    }

    @objc private func handleLongPress(_ recognizer: UILongPressGestureRecognizer) {
        let point = recognizer.location(in: roll)

        switch recognizer.state {
        case .began:
            // Whatever the scroll view had started is not a pan any more.
            scrollView.panGestureRecognizer.isEnabled = false
            scrollView.panGestureRecognizer.isEnabled = true
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()

            if let hit = noteHit(at: point) {
                if !model.editor.selection.contains(hit.id) {
                    model.setSelection([hit.id])
                }

                model.audition(hit.note)
                openNoteCard(for: hit.note)
                return
            }

            editDrag = EditDrag(kind: .marquee, anchorPoint: point, anchorPitch: 0)
            model.deselectAll()
            updateEditDrag(at: point)

        case .changed:
            guard editDrag?.kind == .marquee else { return }

            updateEditDrag(at: point)

        case .ended:
            guard editDrag?.kind == .marquee else { return }

            updateEditDrag(at: point)
            finishEditDrag()

        default:
            if editDrag?.kind == .marquee {
                cancelEditDrag()
            }
        }
    }

    @objc private func handleUndoTap(_ recognizer: UITapGestureRecognizer) {
        model.undo()
    }

    /// The card for the selection, anchored on `note` where it is drawn now.
    func openNoteCard(for note: NoteEvent) {
        guard let rect = roll.painter.noteRect(note, height: roll.bounds.height) else { return }

        onNoteCard?(roll.convert(rect, to: self))
    }

    /// The Draw tool's tap on an empty lane: one division in the target instrument, as the Mac's
    /// Draw click puts down. False off the lanes, where the tap seeks instead.
    func insertNote(at point: CGPoint) -> Bool {
        guard model.canEdit, model.editor.tool == .draw, let note = drawnNote(anchor: point, current: point) else { return false }

        model.insertNote(note)
        sync()
        return true
    }

    // MARK: - The drag

    private func updateEditDrag(at point: CGPoint) {
        guard var drag = editDrag else { return }

        let dx = point.x - drag.anchorPoint.x
        let dy = point.y - drag.anchorPoint.y
        let snap = model.editor.snapEnabled ? model.editor.grid : nil
        let deltaSeconds = geometry.seconds(forX: dx)

        switch drag.kind {
        case .move:
            let pitch = geometry.pitch(forY: point.y) ?? drag.anchorPitch
            let resolved = EditGestureMath.resolveMove(deltaSeconds: deltaSeconds,
                                                       deltaSemitones: pitch - drag.anchorPitch,
                                                       anchorStart: drag.anchorNote?.startTime ?? 0,
                                                       grid: snap, axisLock: nil)

            // Every lane the pressed note crosses is heard, so a drag can be steered by ear.
            if resolved.semitones != drag.resolvedSemitones, let note = drag.anchorNote {
                var carried = note
                carried.pitch = min(max(note.pitch + resolved.semitones, 0), 127)
                model.audition(carried)
                UISelectionFeedbackGenerator().selectionChanged()
            }

            drag.resolvedSeconds = resolved.seconds
            drag.resolvedSemitones = resolved.semitones
            setPreview(DragPreview(kind: .transform(deltaSeconds: resolved.seconds, deltaSemitones: resolved.semitones,
                                                    duplicating: false),
                                   ids: drag.ids))

        case let .resize(edge):
            let anchorEdge = edge == .start ? drag.anchorNote?.startTime : drag.anchorNote?.endTime
            drag.resolvedSeconds = EditGestureMath.resolveResize(deltaSeconds: deltaSeconds, anchorEdgeTime: anchorEdge ?? 0, grid: snap)
            setPreview(DragPreview(kind: .resize(edge: edge, deltaSeconds: drag.resolvedSeconds), ids: drag.ids))

        case .draw:
            guard let drawn = drawnNote(anchor: drag.anchorPoint, current: point) else { break }

            drag.drawn = drawn
            setPreview(DragPreview(kind: .draw(drawn), ids: []))

        case .marquee:
            let rect = CGRect(x: drag.anchorPoint.x, y: drag.anchorPoint.y, width: dx, height: dy).standardized
            marquee.frame = rect
            marquee.isHidden = false
            model.setSelection(EditGestureMath.marqueeSelection(rect, notes: noteRects(intersecting: rect)))
        }

        editDrag = drag
    }

    private func finishEditDrag() {
        guard let drag = editDrag else { return }

        editDrag = nil
        marquee.isHidden = true
        setPreview(nil)

        switch drag.kind {
        case .move:
            model.moveNotes(drag.ids, deltaSeconds: drag.resolvedSeconds, deltaSemitones: drag.resolvedSemitones)

            // A move that changed the pitch was heard on the way; one in time alone as it lands.
            if drag.resolvedSemitones == 0, drag.resolvedSeconds != 0, var landed = drag.anchorNote {
                landed.startTime += drag.resolvedSeconds
                landed.endTime += drag.resolvedSeconds
                model.audition(landed)
            }

        case let .resize(edge):
            model.resizeNotes(drag.ids, edge: edge, deltaSeconds: drag.resolvedSeconds)

        case .draw:
            if let drawn = drag.drawn {
                model.insertNote(drawn)
            }

        case .marquee:
            break
        }

        // The landed notes now, rather than one frame of the old ones when the preview goes.
        sync()
    }

    /// Undo, a tool change, a command: the preview goes and nothing is committed. Answers whether
    /// there was a drag to cancel.
    @discardableResult
    func cancelEditDrag() -> Bool {
        guard editDrag != nil else { return false }

        editDrag = nil
        marquee.isHidden = true
        setPreview(nil)

        return true
    }

    private func setPreview(_ preview: DragPreview?) {
        guard roll.painter.preview != preview else { return }

        roll.painter.preview = preview
        roll.painter.refreshPreviewIndices()
        roll.setNeedsDisplay()
    }

    /// The Draw tool's note between the anchor and the finger, at the anchor's lane, in the
    /// target instrument; nil off the lanes.
    private func drawnNote(anchor: CGPoint, current: CGPoint) -> NoteEvent? {
        guard let pitch = geometry.pitch(forY: anchor.y) else { return nil }

        let span = EditGestureMath.drawnNote(anchor: geometry.seconds(forX: anchor.x),
                                             current: geometry.seconds(forX: current.x),
                                             grid: model.editor.grid,
                                             snapEnabled: model.editor.snapEnabled)

        return NoteEvent(startTime: span.start, endTime: span.end, pitch: pitch, program: model.editor.targetProgram)
    }

    /// Every drawn note's rect that meets `rect`, for the marquee.
    private func noteRects(intersecting rect: CGRect) -> [(id: NoteID, rect: CGRect)] {
        let painter = roll.painter

        return painter.indices(crossing: rect, of: painter.notes, buckets: painter.buckets).compactMap { index in
            painter.noteRect(painter.notes[index], height: roll.bounds.height).map { (painter.ids[index], $0) }
        }
    }
}
