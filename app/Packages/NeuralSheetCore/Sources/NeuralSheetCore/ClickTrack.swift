import Foundation

/// The metronome as notes (click design §2): one short percussion hit on every beat of the tempo
/// map, the downbeat accented, for the playback engine's second scheduler to play through the
/// click's own synth. The beats are the grid's own (`TempoGrid.beatLines`), so the click and the
/// ruler cannot disagree about where a beat falls: three to a bar of 3/4, six to a bar of 6/8.
public enum ClickTrack {
    /// The click's instrument: outside 0…128 so it is never a mixer strip, never in the roll and
    /// never exported, but still an index into the playback engine's fixed table of synths.
    public static let program = NoteEvent.drumProgram + 1

    /// GM percussion keys: hi wood block for a beat, claves for a downbeat.
    public static let beatPitch = 76
    public static let downbeatPitch = 75

    public static let beatVelocity = 100
    public static let downbeatVelocity = 118

    /// Each hit's length; the synth plays a percussion hit out whatever its note-off, so this only
    /// has to be long enough to be a note.
    public static let hitSeconds = 0.06

    /// One hit per bar line and beat of `grid` in `0...duration`, in time order: a bar line is
    /// the accented downbeat. The grid's offset is honoured, and bar 0, −1… before it click too
    /// as far back as the take's start (issue #19 §6).
    public static func events(grid: TempoGrid, duration: Double) -> [NoteEvent] {
        guard duration.isFinite, duration > 0 else { return [] }

        // `beatLines` is inclusive at both ends; a beat exactly at the end would be heard after
        // the take has stopped.
        return grid.beatLines(from: 0, to: duration)
            .filter { $0.seconds < duration }
            .map { hit(at: $0.seconds, downbeat: $0.kind == .bar) }
    }

    /// The count-in before a take (click design §2): `bars` bars at the first segment's tempo and
    /// meter, from 0, and how long they last. The take starts at that length, on the next
    /// downbeat.
    public static func countIn(grid: TempoGrid, bars: Int) -> (events: [NoteEvent], seconds: Double) {
        guard bars > 0 else { return ([], 0) }

        let first = grid.segments[0]
        let countGrid = TempoGrid(segments: [GridSegment(startBar: 1, bpm: first.bpm, timeSignature: first.timeSignature)])
        let seconds = Double(bars) * first.barSeconds

        return (events(grid: countGrid, duration: seconds), seconds)
    }

    /// What the click plays from the moment Record is pressed: the count-in, then -- with
    /// Click while recording -- the project's grid with bar 1 on the take's first sample, for up
    /// to `horizon` seconds of take. Times are from the press; the take starts at `seconds`.
    public static func recording(grid: TempoGrid, countInBars: Int, clickDuringTake: Bool, horizon: Double)
        -> (events: [NoteEvent], seconds: Double)
    {
        let countIn = countIn(grid: grid, bars: countInBars)

        guard clickDuringTake else { return countIn }

        var takeGrid = grid
        // Bar 1 is the take's start (issue #19 §9), so the click during it is the grid at offset 0.
        takeGrid.offsetSeconds = 0

        let take = events(grid: takeGrid, duration: horizon).map { note in
            var shifted = note
            shifted.startTime += countIn.seconds
            shifted.endTime += countIn.seconds
            return shifted
        }

        return (countIn.events + take, countIn.seconds)
    }

    private static func hit(at seconds: Double, downbeat: Bool) -> NoteEvent {
        NoteEvent(startTime: seconds,
                  endTime: seconds + hitSeconds,
                  pitch: downbeat ? downbeatPitch : beatPitch,
                  amplitude: NoteEvent.amplitude(forVelocity: downbeat ? downbeatVelocity : beatVelocity),
                  program: program)
    }
}
