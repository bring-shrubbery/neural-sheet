import Foundation

/// The bulk commands (editor commands design §3): velocity maps, legato, join, split and
/// humanize over a set of notes, each one ``EditBatch`` so it undoes in one step. Like the rest
/// of the commands they go through ``finished(_:)``, so a same-pitch overlap one of them would
/// make is resolved inside the same batch.
extension NoteDocument {
    /// Every note among `ids` gets `transform` of its velocity, clamped to 1…127. One map for
    /// Scale, From Audio and Humanize (editor commands design §2). A note whose velocity comes
    /// out the same keeps its amplitude exactly, so a no-op is no change.
    public func setVelocities(_ ids: Set<NoteID>, title: String = "Set Velocity",
                              transform: (Int) -> Int) -> EditBatch {
        changing(notes.filter { ids.contains($0.id) }, title: title) { note in
            let velocity = min(max(transform(note.velocity), 1), 127)

            guard velocity != note.velocity else { return note }

            var note = note
            note.amplitude = NoteEvent.amplitude(forVelocity: velocity)

            return note
        }
    }

    /// Each note named in `velocities` gets its own velocity, clamped to 1…127: Velocity → From
    /// Audio, where every note's comes from the take at its onset (editor commands design §2).
    /// Unchanged velocities keep their amplitude, as in the transform form.
    public func setVelocities(_ velocities: [NoteID: Int], title: String = "Set Velocity") -> EditBatch {
        var batch = EditBatch(title: title)

        for source in notes {
            guard let target = velocities[source.id] else { continue }

            let velocity = min(max(target, 1), 127)

            guard velocity != source.note.velocity else { continue }

            var after = source.note
            after.amplitude = NoteEvent.amplitude(forVelocity: velocity)
            batch.changed.append(NoteChange(before: source, after: EditableNote(id: source.id, note: after)))
        }

        return finished(batch)
    }

    /// Each note among `ids` ends where the next note of its instrument starts, whatever that
    /// note's pitch and whether or not it is among `ids` (editor commands design §2): the
    /// earliest start strictly after the note's own. A note with no successor keeps its length;
    /// none is left shorter than ``minimumLength``, so a successor a hair later cannot erase it.
    public func legato(_ ids: Set<NoteID>) -> EditBatch {
        var starts: [Int: [Double]] = [:]

        for note in notes {
            starts[note.note.program, default: []].append(note.note.startTime)
        }

        // `notes` is in start order, so each program's starts already are.
        return changing(notes.filter { ids.contains($0.id) }, title: "Legato") { note in
            guard let program = starts[note.program],
                  let successor = NoteDocument.firstStart(in: program, after: note.startTime)
            else { return note }

            var note = note
            note.endTime = max(successor, note.startTime + NoteDocument.minimumLength)

            return note
        }
    }

    /// Runs of the same instrument and pitch among `ids` merged into one note from the first
    /// start to the last end, while each starts no more than `gap` seconds after the one before
    /// ends (editor commands design §2). Only neighbours in the whole pitch lane are joined, so
    /// a note outside `ids` between two that are keeps them apart. The merged note keeps the
    /// first's id, velocity, confidence and lyric (markers and lyrics design §2), but not its
    /// pitch curve, which no longer spans it (pitch curves design §2); the rest are deleted with
    /// theirs.
    public func join(_ ids: Set<NoteID>, gap: Double) -> EditBatch {
        struct Lane: Hashable {
            var program: Int
            var pitch: Int
        }

        var lanes: [Lane: [EditableNote]] = [:]

        for note in notes {
            lanes[Lane(program: note.note.program, pitch: note.note.pitch), default: []].append(note)
        }

        var batch = EditBatch(title: "Join Notes")

        for lane in lanes.values {
            var run: EditableNote?
            var merged: EditableNote?

            for note in lane {
                if let current = merged, ids.contains(note.id), note.note.startTime - current.note.endTime <= gap + 1e-9 {
                    merged?.note.endTime = max(current.note.endTime, note.note.endTime)
                    batch.deleted.append(note)
                    continue
                }

                NoteDocument.flush(run, merged, into: &batch)
                run = ids.contains(note.id) ? note : nil
                merged = run
            }

            NoteDocument.flush(run, merged, into: &batch)
        }

        return finished(batch)
    }

    /// Every note among `ids` that the playhead crosses, cut in two at `seconds`, both halves at
    /// least ``minimumLength`` (editor commands design §2). The first half keeps the id; the
    /// second is a new note with the same instrument, pitch, velocity and confidence; neither
    /// keeps a pitch curve (pitch curves design §2), and only the first keeps the lyric (markers
    /// and lyrics design §2), since the syllable was sung from the onset. Mutating
    /// because it allocates ids, as ``paste(_:at:)`` does. Returns the ids of every half, for
    /// the selection.
    public mutating func split(_ ids: Set<NoteID>, at seconds: Double) -> (batch: EditBatch, halves: Set<NoteID>) {
        var batch = EditBatch(title: "Split Notes")

        for source in notes where ids.contains(source.id) && NoteDocument.spans(source.note, seconds) {
            var first = source.note
            first.endTime = seconds
            var second = source.note
            second.startTime = seconds
            // The curve ran from the first half's onset; the first half loses it to the length
            // rule in `finished`, the second never had one of its own (pitch curves design §2).
            second.pitchCurve = nil
            second.lyric = nil

            batch.changed.append(NoteChange(before: source, after: EditableNote(id: source.id, note: first)))
            batch.inserted.append(EditableNote(id: allocateID(), note: second))
        }

        if batch.changed.count == 1 {
            batch.title = "Split Note"
        }

        let finished = finished(batch)
        let halves = Set(finished.changed.map(\.after.id) + finished.inserted.map(\.id))

        return (finished, halves)
    }

    /// Whether `seconds` cuts `note` into two halves each at least ``minimumLength`` long: what
    /// Split acts on, and what the menu asks before enabling it.
    public static func spans(_ note: NoteEvent, _ seconds: Double) -> Bool {
        seconds - note.startTime >= minimumLength && note.endTime - seconds >= minimumLength
    }

    /// Each note among `ids` moved by a uniform random amount within ±`timing` seconds (never
    /// before 0; its end moves with it) and its velocity by a uniform random whole number within
    /// ±`velocity`, clamped to 1…127 (editor commands design §2). The draws are taken in document
    /// order, so a seeded generator gives the same batch every time.
    public func humanize(_ ids: Set<NoteID>, timing: Double, velocity: Int,
                         using generator: inout some RandomNumberGenerator) -> EditBatch {
        let sources = notes.filter { ids.contains($0.id) }
        var shifts: [NoteID: (seconds: Double, velocity: Int)] = [:]

        for source in sources {
            let seconds = timing > 0 ? Double.random(in: -timing...timing, using: &generator) : 0
            let delta = velocity > 0 ? Int.random(in: -velocity...velocity, using: &generator) : 0
            shifts[source.id] = (max(seconds, -source.note.startTime), delta)
        }

        var batch = EditBatch(title: "Humanize")

        for source in sources {
            guard let shift = shifts[source.id] else { continue }

            var after = NoteDocument.shifted(source.note, by: shift.seconds, semitones: 0)
            let target = min(max(source.note.velocity + shift.velocity, 1), 127)

            if target != source.note.velocity {
                after.amplitude = NoteEvent.amplitude(forVelocity: target)
            }

            if after != source.note {
                batch.changed.append(NoteChange(before: source, after: EditableNote(id: source.id, note: after)))
            }
        }

        return finished(batch)
    }

    // MARK: - Helpers

    /// The first of the sorted `starts` strictly after `seconds`, by binary search.
    private static func firstStart(in starts: [Double], after seconds: Double) -> Double? {
        var low = 0
        var high = starts.count

        while low < high {
            let middle = (low + high) / 2
            if starts[middle] <= seconds { low = middle + 1 } else { high = middle }
        }

        return low < starts.count ? starts[low] : nil
    }

    /// A finished run: a change when it grew past its first note.
    private static func flush(_ run: EditableNote?, _ merged: EditableNote?, into batch: inout EditBatch) {
        guard let run, let merged, merged != run else { return }

        batch.changed.append(NoteChange(before: run, after: merged))
    }
}
