// Ported from muscriptor.cpp's cpp/src/note_assembler.hpp and
// cpp/src/note_assembler.cpp, which implement the reference's `validate_notes`,
// `trim_overlapping_notes` and `sort_notes` passes. Spec'd in that repo's
// docs/TOKENIZER.md sections 6 and 7.

/// A note plus the provenance the cleanup passes and the streaming slice need.
struct TrackedNote: Equatable {
    var note: Note

    /// Which chunk the note *closed* in, which is not necessarily where it began.
    var chunkIndex: Int = 0

    /// The decoded (program, pitch) the tracker opened it under, which is not
    /// `note.program` for a decoded program that is routed to drums.
    var key: NoteKey
}

/// Turns note actions into `Note`s, and runs the reference's cleanup passes.
///
/// Notes are completed and appended when they *close*, so the append order is close
/// order. That order is load-bearing: `trimOverlapping` sorts each channel by onset with
/// a stable sort, so ties inherit it.
struct NoteAssembler {
    // Append order is close order; see the type comment.
    private var closed: [TrackedNote] = []

    // Notes opened but not yet closed, in insertion order.
    private var opened: [TrackedNote] = []

    init() {}

    mutating func reset() {
        self = NoteAssembler()
    }

    /// - Parameters:
    ///   - actions: Actions from one chunk, in order.
    ///   - chunkIndex: Which chunk produced them. Recorded per note so the streaming
    ///     caller can ask for a single chunk's worth.
    /// - Throws: `TranscriberError.internalError` on an end with nothing open, which can
    ///   only be a bug in the tracker: the two agree on the open set by construction.
    mutating func apply(_ actions: [NoteAction], chunkIndex: Int) throws {
        for action in actions {
            switch action.kind {
            case .start:
                let isDrum = InstrumentGroup(program: action.program) == .drums

                // The note's program is resolved through the group, not copied from the
                // token: a decoded program 96 names itself "drums" upstream and is routed
                // as one, and this is where that has to happen -- it changes the trimming
                // channel, so doing it at label time instead would produce a different
                // note list.
                let note = Note(
                    onset: action.time,
                    offset: action.time,
                    pitch: action.pitch,
                    program: isDrum ? Note.drumProgram : action.program,
                    isDrum: isDrum,
                    confidence: action.confidence)

                opened.append(TrackedNote(
                    note: note, chunkIndex: chunkIndex,
                    key: NoteKey(program: action.program, pitch: action.pitch)))

            case .end:
                let key = NoteKey(program: action.program, pitch: action.pitch)

                guard let index = opened.firstIndex(where: { $0.key == key }) else {
                    throw TranscriberError.internalError(
                        "note end for (program \(action.program), pitch \(action.pitch)) with nothing open")
                }

                var note = opened.remove(at: index)
                note.note.offset = action.time
                note.chunkIndex = chunkIndex
                closed.append(note)

            case .drumHit:
                let note = Note(
                    onset: action.time,
                    offset: action.time + Note.minimumDuration,
                    pitch: action.pitch,
                    program: Note.drumProgram,
                    isDrum: true,
                    confidence: action.confidence)

                closed.append(TrackedNote(
                    note: note, chunkIndex: chunkIndex,
                    key: NoteKey(program: Note.drumProgram, pitch: action.pitch)))
            }
        }
    }

    /// Notes that closed during `chunkIndex`, cleaned.
    ///
    /// Cleaned over chunks `chunkIndex` and `chunkIndex + 1` together, then filtered
    /// back: a note's offset can only be truncated by a note starting strictly inside it,
    /// and on the model's 10 ms grid that neighbour is at most one chunk away. So this is
    /// what the final `finalize()` would produce for these notes, which is what makes the
    /// streaming callback append-only rather than provisional.
    ///
    /// (The exception is a chunk whose shifts run backwards -- nothing at inference
    /// forbids it, though the model does not do it -- where a much later note could in
    /// principle truncate an earlier one. `finalize()` is always authoritative.)
    func closedIn(chunkIndex: Int) -> [Note] {
        var window = closed.filter { $0.chunkIndex == chunkIndex || $0.chunkIndex == chunkIndex + 1 }
        Self.validate(&window)
        return Self.trim(window).filter { $0.chunkIndex == chunkIndex }.map(\.note)
    }

    /// Every note, cleaned over the whole list and globally sorted.
    func finalize() -> [Note] {
        var notes = closed
        Self.validate(&notes)
        return Self.trim(notes).map(\.note)
    }

    /// The reference's `validate_notes(fix=True)`.
    ///
    /// An if/else-if chain, not four independent rules -- that is how the reference
    /// writes it, and the branches are not commutative:
    ///
    ///     onset missing                            -> drop
    ///     else if offset missing                   -> onset + 10 ms
    ///     else if onset > offset                   -> max(offset, onset + 10 ms)
    ///     else if !isDrum and shorter than 10 ms   -> onset + 10 ms
    ///
    /// The first two cannot arise here (a `Note` always has both), so only the last two
    /// do any work.
    static func validate(_ notes: inout [Note]) {
        var tracked = notes.map { TrackedNote(note: $0, key: NoteKey(program: $0.program, pitch: $0.pitch)) }
        validate(&tracked)
        notes = tracked.map(\.note)
    }

    /// The reference's `trim_overlapping_notes(sort=True)`.
    ///
    /// Per (program, pitch, isDrum) channel, truncate each note's offset to the next
    /// onset in that channel, drop anything left empty, then sort the survivors by
    /// (onset, isDrum, program, pitch, offset).
    static func trimOverlapping(_ notes: [Note]) -> [Note] {
        trim(notes.map { TrackedNote(note: $0, key: NoteKey(program: $0.program, pitch: $0.pitch)) }).map(\.note)
    }

    /// The reference's `sort_notes`: (onset, isDrum, program, pitch, offset).
    static func sort(_ notes: inout [Note]) {
        notes = stableSorted(notes, by: isLess)
    }

    /// The reference's `sort_notes` key. `isDrum` sorts false before true, as the C++
    /// `std::tie` over a `bool` does.
    private static func isLess(_ left: Note, _ right: Note) -> Bool {
        (left.onset, left.isDrum ? 1 : 0, left.program, left.pitch, left.offset)
            < (right.onset, right.isDrum ? 1 : 0, right.program, right.pitch, right.offset)
    }

    private static func validate(_ notes: inout [TrackedNote]) {
        for index in notes.indices {
            let note = notes[index].note

            // The last two branches of the reference's chain.
            if note.onset > note.offset {
                notes[index].note.offset = max(note.offset, note.onset + Note.minimumDuration)
            } else if !note.isDrum, note.offset - note.onset < Note.minimumDuration {
                notes[index].note.offset = note.onset + Note.minimumDuration
            }
        }
    }

    /// Channel identity for trimming. Drums share the (program, pitch) space with melodic
    /// notes -- both can be program 128 -- so `isDrum` is part of the key rather than
    /// implied by it.
    private static func channel(_ tracked: TrackedNote) -> (Int, Int, Int) {
        (tracked.note.program, tracked.note.pitch, tracked.note.isDrum ? 1 : 0)
    }

    private static func trim(_ notes: [TrackedNote]) -> [TrackedNote] {
        guard notes.count > 1 else { return notes }

        // Group by channel while preserving the master (close) order inside each group:
        // the reference filters the master list per channel and then does a *stable* sort
        // on onset alone, so equal onsets keep close order. Sorting by the full five-key
        // comparator here instead would change which of two coincident notes gets
        // truncated.
        let order = stableSorted(Array(notes.indices)) { channel(notes[$0]) < channel(notes[$1]) }

        var trimmed: [TrackedNote] = []
        trimmed.reserveCapacity(notes.count)
        var start = 0

        while start < order.count {
            var end = start + 1

            while end < order.count, channel(notes[order[end]]) == channel(notes[order[start]]) {
                end += 1
            }

            var group = stableSorted(order[start ..< end].map { notes[$0] }) { $0.note.onset < $1.note.onset }

            for index in group.indices.dropFirst() where group[index - 1].note.offset > group[index].note.onset {
                group[index - 1].note.offset = group[index].note.onset
            }

            trimmed += group.filter { $0.note.onset < $0.note.offset }
            start = end
        }

        return stableSorted(trimmed) { isLess($0.note, $1.note) }
    }

    /// A stable sort, which `Array.sort` is not guaranteed to be. The original position
    /// is the last key, so equal elements keep the order they came in.
    private static func stableSorted<T>(_ elements: [T], by isLess: (T, T) -> Bool) -> [T] {
        elements.enumerated().sorted { left, right in
            if isLess(left.element, right.element) { return true }
            if isLess(right.element, left.element) { return false }
            return left.offset < right.offset
        }.map(\.element)
    }
}
