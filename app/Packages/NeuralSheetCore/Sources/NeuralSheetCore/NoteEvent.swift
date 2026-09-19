/// A single transcribed note: a pitch played by one instrument over a time span.
///
/// `program` identifies the instrument everywhere (synth voice, piano-roll colour, MIDI track):
/// 0-127 for a melodic note, ``drumProgram`` for a drum hit.
public struct NoteEvent: Equatable, Hashable, Codable, Sendable {
    /// Start of the note in seconds from the beginning of the audio.
    public var startTime: Double
    /// End of the note in seconds from the beginning of the audio.
    public var endTime: Double
    /// MIDI note number, 0-127.
    public var pitch: Int
    /// 0-1, a velocity-like value used for synth gain and MIDI velocity.
    public var amplitude: Double
    /// 0-127, or ``drumProgram``.
    public var program: Int

    /// The program reserved for drum hits; the model routes drums itself, so no melodic note
    /// carries it and no drum hit carries any other program.
    public static let drumProgram = 128

    /// Amplitude used for notes that carry no measured loudness, i.e. MIDI velocity 100.
    public static let defaultAmplitude = 100.0 / 127.0

    /// Whether this note is a drum hit. A complete test on its own, see ``drumProgram``.
    public var isDrum: Bool { program == NoteEvent.drumProgram }

    /// The MIDI velocity this note's amplitude stands for, 1…127. The model gives every note
    /// 100; the editor sets others.
    public var velocity: Int {
        min(max(Int((amplitude * 127).rounded()), 1), 127)
    }

    /// The amplitude that reads back as `velocity`, clamped to 1…127.
    public static func amplitude(forVelocity velocity: Int) -> Double {
        Double(min(max(velocity, 1), 127)) / 127.0
    }

    public init(
        startTime: Double,
        endTime: Double,
        pitch: Int,
        amplitude: Double = NoteEvent.defaultAmplitude,
        program: Int
    ) {
        self.startTime = startTime
        self.endTime = endTime
        self.pitch = pitch
        self.amplitude = amplitude
        self.program = program
    }
}

extension NoteEvent: Comparable {
    /// Ordered by start time, with ties broken on instrument, pitch and end time, so a chord shared
    /// by two instruments has one definite order rather than whatever the sort happened to produce.
    public static func < (lhs: NoteEvent, rhs: NoteEvent) -> Bool {
        (lhs.startTime, lhs.program, lhs.pitch, lhs.endTime)
            < (rhs.startTime, rhs.program, rhs.pitch, rhs.endTime)
    }
}

/// Merges notes of the same instrument *and* pitch whose intervals overlap into one, keeping the
/// later end, so one instrument never gets two overlapping note-on messages for the same pitch
/// (which can otherwise cut a still-sounding note short on the synth).
///
/// Keyed on the instrument as well as the pitch: two instruments playing the same note at the same
/// time is ordinary music, and merging those would delete one of them. Notes that merely touch
/// (`endTime == startTime`) do not overlap and stay separate. The merged note keeps the earlier
/// note's amplitude.
///
/// - Returns: the merged notes in sort order (see ``NoteEvent/<(_:_:)``).
public func mergeOverlappingNotesWithSamePitch(_ notes: [NoteEvent]) -> [NoteEvent] {
    // Sorting first means a note can only ever merge into one still-open note per instrument and
    // pitch, and it leaves the result sorted: merging only extends an end time, which is the last
    // tie-break and only compared between notes that share a start time, program and pitch — and
    // those have been merged into one by then.
    var merged: [NoteEvent] = []
    merged.reserveCapacity(notes.count)

    struct Key: Hashable {
        var program: Int
        var pitch: Int
    }
    // Index in `merged` of the note currently open for each instrument and pitch.
    var openIndices: [Key: Int] = [:]

    for note in notes.sorted() {
        let key = Key(program: note.program, pitch: note.pitch)
        if let index = openIndices[key], merged[index].endTime > note.startTime {
            merged[index].endTime = max(merged[index].endTime, note.endTime)
        } else {
            openIndices[key] = merged.count
            merged.append(note)
        }
    }

    return merged
}
