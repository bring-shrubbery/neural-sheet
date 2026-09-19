import Foundation

/// A note's identity inside one ``NoteDocument``: what a selection and an undo batch refer to,
/// which an array index cannot be, since the notes are re-sorted after every edit.
public struct NoteID: Hashable, Comparable, Codable, Sendable {
    public let raw: Int

    public init(_ raw: Int) {
        self.raw = raw
    }

    public static func < (lhs: NoteID, rhs: NoteID) -> Bool {
        lhs.raw < rhs.raw
    }

    // A bare integer in the file, not `{"raw": n}`: thousands of notes are written per save. The
    // keyed form is still read, since a session this branch wrote earlier embeds ids that way.

    private enum CodingKeys: String, CodingKey {
        case raw
    }

    public init(from decoder: Decoder) throws {
        if let bare = try? decoder.singleValueContainer().decode(Int.self) {
            raw = bare
        } else {
            raw = try decoder.container(keyedBy: CodingKeys.self).decode(Int.self, forKey: .raw)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(raw)
    }
}

/// A note with its identity.
public struct EditableNote: Equatable, Hashable, Codable, Sendable {
    public var id: NoteID
    public var note: NoteEvent

    public init(id: NoteID, note: NoteEvent) {
        self.id = id
        self.note = note
    }
}

/// One note before and after an edit. A struct rather than a tuple so the batch is `Codable`.
public struct NoteChange: Equatable, Codable, Sendable {
    public var before: EditableNote
    public var after: EditableNote

    public init(before: EditableNote, after: EditableNote) {
        self.before = before
        self.after = after
    }
}

/// One undoable edit: the notes it adds, the notes it removes and the notes it changes. Every
/// command in the editor is expressed as one of these; its inverse is the same struct with the
/// roles swapped, which is the whole undo model.
public struct EditBatch: Equatable, Codable, Sendable {
    /// "Move Notes", "Delete Note"…: what the Undo menu item says.
    public var title: String
    public var inserted: [EditableNote]
    public var deleted: [EditableNote]
    public var changed: [NoteChange]

    public init(title: String, inserted: [EditableNote] = [], deleted: [EditableNote] = [], changed: [NoteChange] = []) {
        self.title = title
        self.inserted = inserted
        self.deleted = deleted
        self.changed = changed
    }

    public var isEmpty: Bool { inserted.isEmpty && deleted.isEmpty && changed.isEmpty }

    public var inverse: EditBatch {
        EditBatch(title: title,
                  inserted: deleted,
                  deleted: inserted,
                  changed: changed.map { NoteChange(before: $0.after, after: $0.before) })
    }
}

/// The editable transcription: identified notes kept in `NoteEvent` order, and the undo and redo
/// stacks of batches that got them there.
///
/// `events` is what the piano roll draws, the scheduler plays and the export writes; nothing
/// downstream of the document knows about ids or history. The history is not encoded: a restored
/// session starts with no undo, but keeps `isEdited` so the app still knows the notes are not the
/// model's own.
public struct NoteDocument: Equatable, Codable, Sendable {
    /// The shortest note an edit can leave behind, in seconds.
    public static let minimumLength = 0.010
    /// Batches kept for undo.
    public static let undoLimit = 100

    /// Sorted by `NoteEvent.<`, ties broken by id.
    public private(set) var notes: [EditableNote]
    public private(set) var undoStack: [EditBatch] = []
    public private(set) var redoStack: [EditBatch] = []
    /// True once any batch has been committed. Survives undo-to-empty; cleared only by making a
    /// new document.
    public private(set) var isEdited = false
    private var nextID: Int

    public init(events: [NoteEvent]) {
        let sorted = events.sorted()
        notes = sorted.enumerated().map { EditableNote(id: NoteID($0.offset), note: $0.element) }
        nextID = sorted.count
    }

    // MARK: - Reading

    public var events: [NoteEvent] { notes.map(\.note) }

    public func note(_ id: NoteID) -> EditableNote? {
        notes.first { $0.id == id }
    }

    public func contains(_ id: NoteID) -> Bool {
        notes.contains { $0.id == id }
    }

    /// A fresh id for a note about to be inserted. Taking one without committing is harmless.
    public mutating func allocateID() -> NoteID {
        defer { nextID += 1 }

        return NoteID(nextID)
    }

    // MARK: - History

    public var canUndo: Bool { !undoStack.isEmpty }
    public var canRedo: Bool { !redoStack.isEmpty }
    public var undoTitle: String? { undoStack.last?.title }
    public var redoTitle: String? { redoStack.last?.title }

    /// Applies the batch, records it, and drops whatever could have been redone.
    public mutating func commit(_ batch: EditBatch) {
        guard !batch.isEmpty else { return }

        apply(batch)
        undoStack.append(batch)

        if undoStack.count > NoteDocument.undoLimit {
            undoStack.removeFirst(undoStack.count - NoteDocument.undoLimit)
        }

        redoStack.removeAll()
        isEdited = true
    }

    /// The batch undone, for the menu title; nil with nothing to undo.
    @discardableResult
    public mutating func undo() -> EditBatch? {
        guard let batch = undoStack.popLast() else { return nil }

        apply(batch.inverse)
        redoStack.append(batch)

        return batch
    }

    @discardableResult
    public mutating func redo() -> EditBatch? {
        guard let batch = redoStack.popLast() else { return nil }

        apply(batch)
        undoStack.append(batch)

        return batch
    }

    /// Deletions and changes by id, then the insertions, then one sort.
    private mutating func apply(_ batch: EditBatch) {
        let deleted = Set(batch.deleted.map(\.id))
        var changes: [NoteID: EditableNote] = [:]

        for change in batch.changed {
            changes[change.after.id] = change.after
        }

        var result: [EditableNote] = []
        result.reserveCapacity(notes.count + batch.inserted.count)

        for note in notes where !deleted.contains(note.id) {
            result.append(changes[note.id] ?? note)
        }

        result.append(contentsOf: batch.inserted)
        result.sort(by: NoteDocument.ordered)
        notes = result
    }

    /// `NoteEvent.<` — which ignores amplitude — with the id as the final tie-break, so the order
    /// is total and two saves of one document give one file.
    static func ordered(_ lhs: EditableNote, _ rhs: EditableNote) -> Bool {
        if lhs.note < rhs.note { return true }
        if rhs.note < lhs.note { return false }

        return lhs.id < rhs.id
    }

    // MARK: - Codable

    private enum CodingKeys: String, CodingKey {
        case notes, isEdited, nextID
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decoded = try container.decode([EditableNote].self, forKey: .notes)
        notes = decoded.sorted(by: NoteDocument.ordered)
        isEdited = try container.decodeIfPresent(Bool.self, forKey: .isEdited) ?? false
        // Past every stored id whatever the file's counter says, so a hand-edited file cannot
        // make `allocateID` hand out an id a note already has.
        let pastStoredIDs = (decoded.map(\.id.raw).max() ?? -1) + 1
        nextID = max(try container.decodeIfPresent(Int.self, forKey: .nextID) ?? 0, pastStoredIDs)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(notes, forKey: .notes)
        try container.encode(isEdited, forKey: .isEdited)
        try container.encode(nextID, forKey: .nextID)
    }
}
