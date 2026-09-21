/// What to do when a transcription has more instruments than a MIDI file has melodic channels.
///
/// Raw values are stable: they are persisted in the settings and read by the MIDI writer.
public enum MidiOverflowMode: Int, Codable, Sendable {
    /// Wrap around and let two instruments share a channel.
    case reuseChannels = 0
    /// Write the first instruments only and leave the rest out.
    case dropExtraInstruments = 1
}

/// One row of the sidebar: an instrument the current transcription contains, or one the user has
/// picked for the next run and which has produced nothing yet.
public struct InstrumentEntry: Equatable, Sendable {
    public var program: Int
    public var info: InstrumentInfo
    public var noteCount: Int
    public var lowestPitch: Int
    public var highestPitch: Int

    /// Selected but not transcribed yet — the strip is there, with nothing in it.
    public var isPlaceholder: Bool { noteCount == 0 }

    public init(program: Int, info: InstrumentInfo, noteCount: Int, lowestPitch: Int, highestPitch: Int) {
        self.program = program
        self.info = info
        self.noteCount = noteCount
        self.lowestPitch = lowestPitch
        self.highestPitch = highestPitch
    }
}

/// One instrument's fader, mute and solo. The absent case is the neutral one, so only instruments
/// the user has actually touched take up room in the state.
public struct InstrumentChannelSettings: Equatable, Codable, Sendable {
    public var gainDb: Double = 0
    public var muted = false
    public var soloed = false

    public init(gainDb: Double = 0, muted: Bool = false, soloed: Bool = false) {
        self.gainDb = gainDb
        self.muted = muted
        self.soloed = soloed
    }
}

/// What instruments the transcription contains, and the fader, mute and solo for each.
///
/// The single place a program number becomes a colour: the sidebar chip, the fader fill and every
/// note in the piano roll read the same `entries`, so they cannot disagree.
///
/// `entries` is derived from the notes on every `update` and is deliberately not encoded — a project
/// rebuilds it from its own notes when it opens, while the mix (`settings`) is what has to survive.
/// That is also why `resetStoredSettings` clears only the mix: it is called when a transcription is
/// launched and nowhere else, so opening a project keeps what the user set.
public struct InstrumentMixerState: Equatable, Codable, Sendable {
    /// The fader range of the strip: −36 … +6 dB in 0.1 dB steps.
    public static let minGainDb = -36.0
    public static let maxGainDb = 6.0
    public static let gainStepDb = 0.1

    /// The lowest program a note can carry, and the highest (`NoteEvent.drumProgram`).
    static let programRange = 0...NoteEvent.drumProgram

    /// Keyed by program; an absent program means `InstrumentChannelSettings()`.
    public var settings: [Int: InstrumentChannelSettings] = [:]

    /// Ascending by program, so drums (128) are always last and the sidebar order is stable as
    /// chunks arrive. Ordering by first appearance would reshuffle it whenever a chunk introduced an
    /// instrument with a lower program.
    public private(set) var entries: [InstrumentEntry] = []

    public init() {}

    // MARK: - Entries

    /// Re-derives the instrument list from the current notes and the user's selection.
    ///
    /// Cheap enough to run per decoded chunk: one pass over a list the piano roll redraws in full
    /// anyway. Deriving the list from the notes rather than keeping a second record is what stops the
    /// two drifting apart. Selected programs with no notes become placeholders; notes with a program
    /// outside 0...128 are dropped rather than trusted.
    public mutating func update(notes: [NoteEvent], selectedPrograms: [Int]) {
        var counts = [Int](repeating: 0, count: InstrumentMixerState.programRange.count)
        var lowest = [Int](repeating: 127, count: InstrumentMixerState.programRange.count)
        var highest = [Int](repeating: 0, count: InstrumentMixerState.programRange.count)

        for note in notes where InstrumentMixerState.programRange.contains(note.program) {
            counts[note.program] += 1
            lowest[note.program] = min(lowest[note.program], note.pitch)
            highest[note.program] = max(highest[note.program], note.pitch)
        }

        let selected = Set(selectedPrograms.filter { InstrumentMixerState.programRange.contains($0) })

        entries = InstrumentMixerState.programRange.compactMap { program in
            let count = counts[program]

            guard count > 0 || selected.contains(program) else { return nil }

            return InstrumentEntry(
                program: program,
                info: Instruments.info(forProgram: program),
                noteCount: count,
                lowestPitch: count > 0 ? lowest[program] : 0,
                highestPitch: count > 0 ? highest[program] : 0)
        }
    }

    /// The entry for a program, or nil if the mix does not contain it.
    public func entry(forProgram program: Int) -> InstrumentEntry? {
        entries.first { $0.program == program }
    }

    // MARK: - Audibility

    /// Whether any instrument *currently on screen* is soloed.
    ///
    /// Solo is only meaningful against the current entries: one left soloed by a previous
    /// transcription would otherwise silence the whole of this one.
    public var anySoloed: Bool {
        entries.contains { isSoloed(program: $0.program) }
    }

    /// Whether the instrument is currently heard: not muted, and either soloed itself or with
    /// nothing else soloed. What the piano roll dims its notes by.
    public func isAudible(program: Int) -> Bool {
        guard !isMuted(program: program) else { return false }

        return !anySoloed || isSoloed(program: program)
    }

    // MARK: - Settings

    public func gainDb(program: Int) -> Double { settings[program]?.gainDb ?? 0 }

    public func isMuted(program: Int) -> Bool { settings[program]?.muted ?? false }

    public func isSoloed(program: Int) -> Bool { settings[program]?.soloed ?? false }

    /// Clamped to the fader's own range, so a value from an old project file or a typed-in number
    /// cannot put the mix outside what the strip can show.
    public mutating func setGain(program: Int, db: Double) {
        settings[program, default: InstrumentChannelSettings()].gainDb =
            min(max(db, InstrumentMixerState.minGainDb), InstrumentMixerState.maxGainDb)
    }

    public mutating func setMuted(program: Int, muted: Bool) {
        settings[program, default: InstrumentChannelSettings()].muted = muted
    }

    public mutating func setSoloed(program: Int, soloed: Bool) {
        settings[program, default: InstrumentChannelSettings()].soloed = soloed
    }

    /// Drops every stored fader, mute and solo so the next transcription's instruments start
    /// neutral. The entries are left alone: they are replaced by the next `update`.
    public mutating func resetStoredSettings() {
        settings.removeAll()
    }

    // MARK: - Codable

    /// Only the mix is persisted; `entries` is derived (see the type's note).
    private enum CodingKeys: String, CodingKey {
        case settings
    }
}
