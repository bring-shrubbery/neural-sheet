import AppKit
import NeuralSheetCore

/// What the roll's notes do when VoiceOver acts on them, answered by the container, which owns
/// the model (a11y design §2). Every action goes through the same `AppModel` commands a click or
/// a key does.
@MainActor protocol RollAccessibilityHandler: AnyObject {
    /// The grid the notes are placed on, in both tabs.
    var rollAccessibilityGrid: TempoGrid { get }
    /// The Edit tab: notes can be selected, deleted, moved and opened in the card.
    var rollAccessibilityEditing: Bool { get }

    func rollAccessibilitySeek(_ seconds: Double)
    func rollAccessibilitySelect(_ id: NoteID)
    func rollAccessibilityDelete(_ id: NoteID)
    func rollAccessibilityMove(_ id: NoteID, steps: Int, semitones: Int)
    func rollAccessibilityOpenCard(_ id: NoteID, at windowPoint: CGPoint)
}

/// The roll as an accessibility container (a11y design §2): its children are the notes in the
/// band on show, in time order and top to bottom, each read as "C4, Piano, bar 3 beat 2, half a
/// beat" and selected as the outline shows. In the Edit tab a press selects a note as a click
/// does, and the actions menu holds Select, Delete, Open Note Card and the four moves the arrow
/// keys make; in the Transcribe tab a press seeks to the note.
///
/// The elements are made when VoiceOver first asks and kept until the notes or the band change
/// (`setNotes`, a band slide) -- never per draw. Their frames are asked of the roll live, so a
/// zoom or a pitch scroll needs no rebuild.
extension PianoRollView: KeyboardFocusableView {
    override func isAccessibilityElement() -> Bool { true }

    override func accessibilityRole() -> NSAccessibility.Role? { .group }

    override func accessibilityLabel() -> String? {
        String(localized: "Piano roll", comment: "VoiceOver: the piano roll, which holds the notes")
    }

    override func accessibilityChildren() -> [Any]? {
        accessibilityNoteElements()
    }

    override func accessibilitySelectedChildren() -> [Any]? {
        accessibilityNoteElements().filter { $0.isAccessibilitySelected() }
    }

    /// The selection's first note, so VoiceOver lands where the outline is.
    override var accessibilityFocusedUIElement: Any? {
        accessibilitySelectedChildren()?.first ?? self
    }

    /// A band slide brings other notes into the band: the next ask makes them.
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        invalidateAccessibilityNotes()
    }

    override func setBoundsOrigin(_ newOrigin: NSPoint) {
        super.setBoundsOrigin(newOrigin)
        invalidateAccessibilityNotes()
    }

    func invalidateAccessibilityNotes() {
        guard accessibilityNotes != nil else { return }

        accessibilityNotes = nil
        NSAccessibility.post(element: self, notification: .layoutChanged)
    }

    /// The outline moved: VoiceOver hears it, and its cursor follows the first selected note.
    func accessibilitySelectionDidChange() {
        guard let notes = accessibilityNotes else { return }

        NSAccessibility.post(element: self, notification: .selectedChildrenChanged)

        if let first = notes.first(where: { $0.isAccessibilitySelected() }) {
            NSAccessibility.post(element: first, notification: .focusedUIElementChanged)
        }
    }

    // MARK: - Elements

    private func accessibilityNoteElements() -> [DrawnElement] {
        if let accessibilityNotes { return accessibilityNotes }

        let elements = bandIndices().map(noteElement)
        accessibilityNotes = elements

        return elements
    }

    /// Every note whose seconds cross the band, once each, left to right and high to low.
    private func bandIndices() -> [Int] {
        guard !buckets.isEmpty, canPlay else { return [] }

        let first = max(0, Int(geometry.seconds(forX: bounds.minX)))
        let last = min(buckets.count - 1, Int(geometry.seconds(forX: bounds.maxX)))

        guard first <= last else { return [] }

        var seen = Set<Int>()
        var indices: [Int] = []

        for bucket in first...last {
            for index in buckets[bucket] where seen.insert(index).inserted {
                indices.append(index)
            }
        }

        return indices.sorted { a, b in
            notes[a].startTime != notes[b].startTime ? notes[a].startTime < notes[b].startTime : notes[a].pitch > notes[b].pitch
        }
    }

    private func noteElement(_ index: Int) -> DrawnElement {
        let id = ids[index]
        let element = DrawnElement(
            in: self, role: .button,
            roleDescription: String(localized: "note", comment: "VoiceOver: what a note on the piano roll is, said after its name"),
            rect: { [weak self] in self?.accessibilityNote(index, id: id).flatMap { self?.noteRect($0) } },
            label: { [weak self] in
                guard let self, let note = accessibilityNote(index, id: id) else { return "" }

                return NoteSpeech.description(of: note, grid: accessibilityHandler?.rollAccessibilityGrid ?? TempoGrid())
            })

        element.isSelected = { [weak self] in self?.selection.contains(id) ?? false }

        element.press = { [weak self] in
            guard let self, let handler = accessibilityHandler, let note = accessibilityNote(index, id: id) else { return false }

            if handler.rollAccessibilityEditing {
                handler.rollAccessibilitySelect(id)
            } else {
                handler.rollAccessibilitySeek(note.startTime)
            }

            return true
        }

        element.actions = { [weak self, weak element] in
            guard let self, let handler = accessibilityHandler, handler.rollAccessibilityEditing else { return [] }

            return noteActions(id: id, handler: handler, element: element)
        }

        return element
    }

    /// The note at `index` while it is still the note the element was made for.
    private func accessibilityNote(_ index: Int, id: NoteID) -> NoteEvent? {
        guard index < notes.count, ids[index] == id else { return nil }

        return notes[index]
    }

    private func noteActions(id: NoteID, handler: RollAccessibilityHandler, element: DrawnElement?) -> [NSAccessibilityCustomAction] {
        func action(_ name: String, _ perform: @escaping () -> Void) -> NSAccessibilityCustomAction {
            NSAccessibilityCustomAction(name: name) {
                perform()
                return true
            }
        }

        return [
            action(String(localized: "Select", comment: "VoiceOver action on a note: select it")) {
                handler.rollAccessibilitySelect(id)
            },
            action(String(localized: "Delete", comment: "VoiceOver action on a note: delete it")) {
                handler.rollAccessibilityDelete(id)
            },
            action(String(localized: "Open Note Card", comment: "VoiceOver action on a note: open the card with its fields")) { [weak element] in
                guard let point = element?.windowCentre else { return }

                handler.rollAccessibilityOpenCard(id, at: point)
            },
            action(String(localized: "Move Left", comment: "VoiceOver action on a note: a grid step earlier")) {
                handler.rollAccessibilityMove(id, steps: -1, semitones: 0)
            },
            action(String(localized: "Move Right", comment: "VoiceOver action on a note: a grid step later")) {
                handler.rollAccessibilityMove(id, steps: 1, semitones: 0)
            },
            action(String(localized: "Move Up", comment: "VoiceOver action on a note: a semitone higher")) {
                handler.rollAccessibilityMove(id, steps: 0, semitones: 1)
            },
            action(String(localized: "Move Down", comment: "VoiceOver action on a note: a semitone lower")) {
                handler.rollAccessibilityMove(id, steps: 0, semitones: -1)
            },
        ]
    }

    // MARK: - Keyboard focus

    override var acceptsFirstResponder: Bool { acceptsKeyboardFocus }

    override func drawFocusRingMask() {
        NSBezierPath(rect: focusRingRect).fill()
    }

    override var focusRingMaskBounds: NSRect { focusRingRect }
}
