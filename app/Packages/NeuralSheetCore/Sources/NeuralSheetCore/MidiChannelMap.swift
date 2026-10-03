import Foundation

/// Which MIDI channel each instrument plays on, shared by the file writer and the live MIDI output
/// (MIDI out design §2), so a take played into a DAW lands on the channels the exported file would
/// have put it on.
public enum MidiChannelMap {
    /// General MIDI percussion. A melodic instrument here plays as drums whatever its program
    /// change says, so it is never handed out to one, even when the transcription has no drums.
    public static let drumChannel = 10

    /// The 15 channels left for melodic instruments, in the order they are handed out.
    static let melodicChannels = [1, 2, 3, 4, 5, 6, 7, 8, 9, 11, 12, 13, 14, 15, 16]

    /// Where `reuseChannels` starts handing channels out again: the block above the drums, so a
    /// reused channel is always one of the last few rather than colliding with the first
    /// instrument found.
    static let reuseFirstIndex = 9

    /// Channel 10 selects its kit from the note number, so the program there names the kit rather
    /// than the instrument. 0 is the standard kit.
    public static let drumKitProgram = 0

    /// The program change an instrument's channel carries: its own program, or the standard kit
    /// for the drums.
    public static func programChange(for program: Int) -> Int {
        program == NoteEvent.drumProgram ? drumKitProgram : min(max(program, 0), 127)
    }

    /// Assigns a MIDI channel to every instrument in the transcription.
    ///
    /// Melodic instruments take ``melodicChannels`` in ascending program order, which is the order
    /// the sidebar shows them in. Past the 15th, `mode` decides: `reuseChannels` cycles through the
    /// last six of the list, `dropExtraInstruments` keeps the 15 carrying the most notes (ties
    /// broken by the lower program) and leaves the rest out of the map entirely.
    ///
    /// - Parameters:
    ///   - programs: the programs present in the transcription; sorted and de-duplicated here, so
    ///     a caller cannot get a different map by passing them in some other order.
    ///   - noteCounts: how many notes each program carries, read only by `dropExtraInstruments`.
    /// - Returns: program → channel (1-16), without the programs that were dropped.
    public static func assign(programs: [Int], noteCounts: [Int: Int], mode: MidiOverflowMode) -> [Int: Int] {
        let programs = Set(programs).sorted()
        var melodic = programs.filter { $0 != NoteEvent.drumProgram }

        if mode == .dropExtraInstruments, melodic.count > melodicChannels.count {
            // Keep whatever carries the most notes: a lead is worth more than an incidental
            // instrument with three notes, whatever their program numbers say.
            let byNoteCount = melodic.sorted { lhs, rhs in
                let lhsCount = noteCounts[lhs] ?? 0
                let rhsCount = noteCounts[rhs] ?? 0

                return lhsCount != rhsCount ? lhsCount > rhsCount : lhs < rhs
            }
            melodic = byNoteCount.prefix(melodicChannels.count).sorted()
        }

        var map: [Int: Int] = [:]

        for (index, program) in melodic.enumerated() {
            if index < melodicChannels.count {
                map[program] = melodicChannels[index]
            } else {
                let reuseSpan = melodicChannels.count - reuseFirstIndex
                let overflowIndex = index - melodicChannels.count
                map[program] = melodicChannels[reuseFirstIndex + overflowIndex % reuseSpan]
            }
        }

        if programs.contains(NoteEvent.drumProgram) {
            map[NoteEvent.drumProgram] = drumChannel
        }

        return map
    }

    /// The map for a note list: its programs, counted, as the writer assigns them.
    public static func assign(notes: [NoteEvent], mode: MidiOverflowMode) -> [Int: Int] {
        var noteCounts: [Int: Int] = [:]

        for note in notes {
            noteCounts[note.program, default: 0] += 1
        }

        return assign(programs: Array(noteCounts.keys), noteCounts: noteCounts, mode: mode)
    }
}
