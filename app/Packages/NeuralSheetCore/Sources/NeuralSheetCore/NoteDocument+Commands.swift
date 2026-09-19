import Foundation

/// Which end of a note a resize takes hold of.
public enum NoteEdge: Equatable, Sendable {
    case start, end
}

/// The editor's commands. Each builds the ``EditBatch`` that ``NoteDocument/commit(_:)`` applies,
/// already run through the invariants (§4.4 of the design): every note in it is clamped, and any
/// same-instrument same-pitch overlap the edit would create is resolved inside the same batch, so
/// it undoes with it.
extension NoteDocument {
    // MARK: - Builders

    public mutating func insert(_ note: NoteEvent) -> EditBatch {
        let inserted = EditableNote(id: allocateID(), note: note)

        return finished(EditBatch(title: "Add Note", inserted: [inserted]))
    }

    public mutating func duplicate(_ ids: Set<NoteID>, deltaSeconds: Double, deltaSemitones: Int) -> EditBatch {
        let sources = selected(ids)
        var copies: [EditableNote] = []

        for source in sources {
            copies.append(EditableNote(id: allocateID(), note: NoteDocument.shifted(source.note, by: deltaSeconds, semitones: deltaSemitones)))
        }

        return finished(EditBatch(title: NoteDocument.title("Duplicate", count: copies.count), inserted: copies))
    }

    public func delete(_ ids: Set<NoteID>) -> EditBatch {
        let doomed = selected(ids)

        return EditBatch(title: NoteDocument.title("Delete", count: doomed.count), deleted: doomed)
    }

    /// The whole selection moves by one delta, reduced so the earliest note stops at 0 and no
    /// pitch leaves 0…127 — relative spacing is kept rather than notes piling up at the edge.
    public func move(_ ids: Set<NoteID>, deltaSeconds: Double, deltaSemitones: Int) -> EditBatch {
        let sources = selected(ids)

        guard !sources.isEmpty else { return EditBatch(title: "Move Note") }

        let earliest = sources.map(\.note.startTime).min() ?? 0
        let lowest = sources.map(\.note.pitch).min() ?? 0
        let highest = sources.map(\.note.pitch).max() ?? 127
        let seconds = max(deltaSeconds, -earliest)
        let semitones = min(max(deltaSemitones, -lowest), 127 - highest)

        return changing(sources, title: NoteDocument.title("Move", count: sources.count)) {
            NoteDocument.shifted($0, by: seconds, semitones: semitones)
        }
    }

    public func resize(_ ids: Set<NoteID>, edge: NoteEdge, deltaSeconds: Double) -> EditBatch {
        let sources = selected(ids)

        return changing(sources, title: NoteDocument.title("Resize", count: sources.count)) { note in
            var note = note

            switch edge {
            case .start:
                note.startTime = min(max(note.startTime + deltaSeconds, 0), note.endTime - NoteDocument.minimumLength)
            case .end:
                note.endTime = max(note.endTime + deltaSeconds, note.startTime + NoteDocument.minimumLength)
            }

            return note
        }
    }

    public func setStart(_ ids: Set<NoteID>, seconds: Double) -> EditBatch {
        changing(selected(ids), title: "Set Start") { note in
            NoteDocument.shifted(note, by: max(0, seconds) - note.startTime, semitones: 0)
        }
    }

    public func setLength(_ ids: Set<NoteID>, seconds: Double) -> EditBatch {
        changing(selected(ids), title: "Set Length") { note in
            var note = note
            note.endTime = note.startTime + max(seconds, NoteDocument.minimumLength)

            return note
        }
    }

    public func setPitch(_ ids: Set<NoteID>, pitch: Int) -> EditBatch {
        changing(selected(ids), title: "Set Pitch") { note in
            var note = note
            note.pitch = pitch

            return note
        }
    }

    public func setProgram(_ ids: Set<NoteID>, program: Int) -> EditBatch {
        changing(selected(ids), title: "Change Instrument") { note in
            var note = note
            note.program = program

            return note
        }
    }

    public func setVelocity(_ ids: Set<NoteID>, velocity: Int) -> EditBatch {
        changing(selected(ids), title: "Set Velocity") { note in
            var note = note
            note.amplitude = NoteEvent.amplitude(forVelocity: velocity)

            return note
        }
    }

    /// Starts to the nearest line; with `lengths`, lengths to the nearest whole number of
    /// divisions, never under one.
    public func quantize(_ ids: Set<NoteID>, grid: TempoGrid, lengths: Bool) -> EditBatch {
        changing(selected(ids), title: "Quantize") { note in
            var note = NoteDocument.shifted(note, by: grid.snap(note.startTime) - note.startTime, semitones: 0)

            if lengths {
                let divisions = max(1, ((note.endTime - note.startTime) / grid.step).rounded())
                note.endTime = note.startTime + divisions * grid.step
            }

            return note
        }
    }

    // MARK: - Helpers

    private func selected(_ ids: Set<NoteID>) -> [EditableNote] {
        notes.filter { ids.contains($0.id) }
    }

    private static func title(_ verb: String, count: Int) -> String {
        count == 1 ? "\(verb) Note" : "\(verb) Notes"
    }

    static func shifted(_ note: NoteEvent, by seconds: Double, semitones: Int) -> NoteEvent {
        var note = note
        note.startTime += seconds
        note.endTime += seconds
        note.pitch += semitones

        return note
    }

    /// A change per note the transform actually changes.
    private func changing(_ sources: [EditableNote], title: String, _ transform: (NoteEvent) -> NoteEvent) -> EditBatch {
        var batch = EditBatch(title: title)

        for source in sources {
            let after = transform(source.note)

            if after != source.note {
                batch.changed.append(NoteChange(before: source, after: EditableNote(id: source.id, note: after)))
            }
        }

        return finished(batch)
    }

    // MARK: - Invariants

    /// Clamps every note the batch introduces, then resolves the overlaps it creates.
    private func finished(_ batch: EditBatch) -> EditBatch {
        var batch = batch
        batch.inserted = batch.inserted.map { EditableNote(id: $0.id, note: NoteDocument.clamped($0.note)) }
        batch.changed = batch.changed.map { NoteChange(before: $0.before, after: EditableNote(id: $0.after.id, note: NoteDocument.clamped($0.after.note))) }

        return resolvingOverlaps(batch)
    }

    static func clamped(_ note: NoteEvent) -> NoteEvent {
        var note = note
        note.pitch = min(max(note.pitch, 0), 127)
        note.program = note.program == NoteEvent.drumProgram ? note.program : min(max(note.program, 0), 127)
        note.amplitude = note.amplitude.isFinite ? min(max(note.amplitude, 1.0 / 127.0), 1) : NoteEvent.defaultAmplitude
        note.startTime = note.startTime.isFinite ? max(note.startTime, 0) : 0
        note.endTime = note.endTime.isFinite ? max(note.endTime, note.startTime + minimumLength) : note.startTime + minimumLength

        return note
    }

    /// Projects the batch onto the notes, then walks every instrument-and-pitch group the batch
    /// touched: an earlier note overlapping a later one is trimmed to end where the later starts,
    /// or deleted when the trim would leave less than ``minimumLength``. The document never holds
    /// an overlap between commits, so only groups the batch touches can have one.
    private func resolvingOverlaps(_ batch: EditBatch) -> EditBatch {
        struct Key: Hashable {
            var program: Int
            var pitch: Int
        }

        var batch = batch
        let deleted = Set(batch.deleted.map(\.id))
        var projected: [NoteID: EditableNote] = [:]

        for note in notes where !deleted.contains(note.id) {
            projected[note.id] = note
        }

        for change in batch.changed {
            projected[change.after.id] = change.after
        }

        for note in batch.inserted {
            projected[note.id] = note
        }

        let touched = Set(batch.changed.map { Key(program: $0.after.note.program, pitch: $0.after.note.pitch) }
            + batch.inserted.map { Key(program: $0.note.program, pitch: $0.note.pitch) })

        guard !touched.isEmpty else { return batch }

        var groups: [Key: [EditableNote]] = [:]

        for note in projected.values {
            let key = Key(program: note.note.program, pitch: note.note.pitch)

            if touched.contains(key) {
                groups[key, default: []].append(note)
            }
        }

        // Per group, in start order: each note may only be cut by the one after it.
        for (_, group) in groups {
            let ordered = group.sorted(by: NoteDocument.ordered)

            for index in ordered.indices.dropLast() {
                let earlier = ordered[index]
                let later = ordered[index + 1]

                guard earlier.note.endTime > later.note.startTime else { continue }

                if later.note.startTime - earlier.note.startTime >= NoteDocument.minimumLength {
                    var trimmed = earlier.note
                    trimmed.endTime = later.note.startTime
                    record(EditableNote(id: earlier.id, note: trimmed), in: &batch)
                } else {
                    remove(earlier, from: &batch)
                }
            }
        }

        return batch
    }

    /// A trimmed note replaces its own entry in the batch, or becomes a new change.
    private func record(_ trimmed: EditableNote, in batch: inout EditBatch) {
        if let index = batch.inserted.firstIndex(where: { $0.id == trimmed.id }) {
            batch.inserted[index] = trimmed
        } else if let index = batch.changed.firstIndex(where: { $0.after.id == trimmed.id }) {
            batch.changed[index].after = trimmed
        } else if let original = note(trimmed.id) {
            batch.changed.append(NoteChange(before: original, after: trimmed))
        }
    }

    /// A note the trim would erase: an inserted one is simply not inserted, a changed one is
    /// deleted from its original, an untouched one is deleted as it is.
    private func remove(_ doomed: EditableNote, from batch: inout EditBatch) {
        if let index = batch.inserted.firstIndex(where: { $0.id == doomed.id }) {
            batch.inserted.remove(at: index)
        } else if let index = batch.changed.firstIndex(where: { $0.after.id == doomed.id }) {
            let original = batch.changed[index].before
            batch.changed.remove(at: index)
            batch.deleted.append(original)
        } else if let original = note(doomed.id) {
            batch.deleted.append(original)
        }
    }
}
