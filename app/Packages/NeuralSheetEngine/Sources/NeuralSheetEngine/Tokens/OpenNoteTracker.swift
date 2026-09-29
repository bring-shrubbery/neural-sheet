// Ported from muscriptor.cpp's cpp/src/open_note_tracker.hpp and
// cpp/src/open_note_tracker.cpp. The rules are spec'd in that repo's
// docs/TOKENIZER.md section 3.

/// Marks the start of a chunk in the token stream.
struct ChunkBoundary: Equatable {
    /// Where this chunk starts in the signal, in seconds.
    var seekTime: Double = 0

    /// Where the next one starts; nil on the last chunk, which is what turns the
    /// window-drop rule off there.
    var nextSeekTime: Double?
}

/// What the state machine decides a token means.
enum NoteActionKind: Equatable {
    case start, end, drumHit
}

/// One decision the state machine reached, with the instant it applies at.
struct NoteAction: Equatable {
    var kind: NoteActionKind = .start

    /// Meaningless for `.drumHit`, which reads no register: the reference's drum action
    /// carries only a pitch and a time.
    var program: Int = 0
    var pitch: Int = 0
    var time: Double = 0
}

/// The decode state machine for the model's token stream.
///
/// Consumes chunk boundaries and token ids in the order the model produces them and
/// answers with note actions. Every cross-chunk rule lives here: the tie prologue
/// (notes not re-declared close at the boundary), malformed chunks (a shift before the
/// `tie` token closes everything and drops the rest), the `nextSeekTime` window, and
/// retriggers.
///
/// Two callers share it, exactly as upstream: note assembly consumes the actions, and
/// prelude forcing reads `openKeys` at each boundary to build the next chunk's forced
/// prologue. One state machine serving both is what keeps decoding and forcing
/// consistent by construction.
struct OpenNoteTracker {
    /// An open note, and when it started.
    private struct OpenNote {
        var key: NoteKey
        var onset: Double = 0
    }

    /// Insertion-ordered on purpose, not a dictionary.
    ///
    /// `finish()` replays its closes in insertion order, and that order reaches the
    /// caller, where it decides which of two coincident notes overlap trimming
    /// truncates. A dictionary would quietly reorder them and nothing else in the
    /// pipeline would notice. There are a few dozen entries at most, so the linear
    /// lookup costs nothing.
    private var open: [OpenNote] = []

    // Per-chunk state. All of it resets at a boundary; `open` does not.
    private var seekTime: Double = 0
    private var nextSeekTime: Double?
    private var startTick = 0
    private var tickState = 0
    private var program: Int?
    private var velocity: Int32?
    private var inPrologue = true
    private var skipRest = false
    private var chunkStarted = false
    private var tieSet: [NoteKey] = []

    init() {}

    mutating func reset() {
        self = OpenNoteTracker()
    }

    /// Still-sounding notes, sorted by (program, pitch).
    var openKeys: [NoteKey] {
        open.map(\.key).sorted()
    }

    /// Start a new chunk.
    ///
    /// Must be called before reading `openKeys` for that boundary: a previous chunk that
    /// ended mid-prologue drops all its open notes here, and only afterwards is
    /// `openKeys` the decoder's own view.
    mutating func feed(boundary: ChunkBoundary) -> [NoteAction] {
        var actions: [NoteAction] = []

        // A previous chunk that never closed its tie prologue is malformed: it declared
        // nothing, so everything still sounding ends at *its* boundary, not at this one.
        if chunkStarted, inPrologue {
            actions = endAll(at: seekTime)
        }

        seekTime = boundary.seekTime
        nextSeekTime = boundary.nextSeekTime
        startTick = Int((boundary.seekTime * Double(Vocabulary.frameRate)).rounded())
        tickState = startTick
        program = nil
        velocity = nil
        inPrologue = true
        skipRest = false
        chunkStarted = true
        tieSet = []

        return actions
    }

    /// Consume one model token.
    mutating func feed(token tokenID: Int32) -> [NoteAction] {
        guard !skipRest else { return [] }

        let event = Vocabulary.event(for: tokenID)
        return inPrologue ? feedPrologue(event) : feedBody(event)
    }

    /// End of stream: close whatever is still sounding.
    mutating func finish() -> [NoteAction] {
        // A stream that ran out mid-prologue never declared anything, so its open notes
        // end at the boundary rather than getting the minimum duration.
        if chunkStarted, inPrologue {
            return endAll(at: seekTime)
        }

        let actions = open.map { note in
            NoteAction(
                kind: .end, program: note.key.program, pitch: note.key.pitch,
                time: note.onset + Note.minimumDuration)
        }

        open.removeAll()
        return actions
    }

    private mutating func endAll(at time: Double) -> [NoteAction] {
        let actions = open.map { note in
            NoteAction(kind: .end, program: note.key.program, pitch: note.key.pitch, time: time)
        }

        open.removeAll()
        return actions
    }

    private mutating func feedPrologue(_ event: TokenEvent) -> [NoteAction] {
        switch event.type {
        case .tie:
            // End of the tie section. Everything not re-declared stops sounding here --
            // this is the whole cross-chunk mechanism.
            inPrologue = false
            velocity = nil

            var actions: [NoteAction] = []
            var kept: [OpenNote] = []
            kept.reserveCapacity(open.count)

            for note in open {
                if tieSet.contains(note.key) {
                    kept.append(note)
                } else {
                    actions.append(NoteAction(
                        kind: .end, program: note.key.program, pitch: note.key.pitch, time: seekTime))
                }
            }

            open = kept
            return actions

        case .shift:
            // No tie token: the chunk is malformed. Close everything and throw away the
            // rest of it, including a tie that turns up later.
            inPrologue = false
            skipRest = true
            return endAll(at: seekTime)

        case .program:
            program = Int(event.value)
            return []

        case .pitch:
            if let program {
                tieSet.append(NoteKey(program: program, pitch: Int(event.value)))
            }

            return []

        default:
            return []
        }
    }

    private mutating func feedBody(_ event: TokenEvent) -> [NoteAction] {
        switch event.type {
        case .shift:
            // Absolute within the chunk, and 0 is a no-op rather than a rewind. Reading
            // it as a delta produces plausible, progressively-wrong timing that nothing
            // else catches.
            if event.value > 0 {
                tickState = startTick + Int(event.value)
            }

            return []

        case .program:
            program = Int(event.value)
            return []

        case .velocity:
            velocity = event.value
            return []

        case .drum:
            let time = Double(tickState) / Double(Vocabulary.frameRate)

            if let nextSeekTime, time >= nextSeekTime {
                return []
            }

            // Instantaneous, never enters the open set, and reads neither register.
            return [NoteAction(kind: .drumHit, program: 0, pitch: Int(event.value), time: time)]

        case .pitch:
            guard let program, let velocity else { return [] }

            let time = Double(tickState) / Double(Vocabulary.frameRate)

            // The model routinely emits events past the end of its own window; they
            // belong to the next chunk, which will decide for itself.
            if let nextSeekTime, time >= nextSeekTime {
                return []
            }

            let key = NoteKey(program: program, pitch: Int(event.value))
            var actions: [NoteAction] = []

            if let index = open.firstIndex(where: { $0.key == key }) {
                open.remove(at: index)
                actions.append(NoteAction(kind: .end, program: key.program, pitch: key.pitch, time: time))
            }

            // Velocity is an on/off flag, not dynamics. A pitch that is already open and
            // gets velocity 1 therefore retriggers: closed just above, reopened here, at
            // the same instant.
            if velocity > 0 {
                open.append(OpenNote(key: key, onset: time))
                actions.append(NoteAction(kind: .start, program: key.program, pitch: key.pitch, time: time))
            }

            return actions

        default:
            return []
        }
    }
}
