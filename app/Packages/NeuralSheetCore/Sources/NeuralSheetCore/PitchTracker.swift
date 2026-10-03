import Foundation

/// How far a note's sung or played pitch wanders from its nominal pitch, in cents every 10 ms
/// from its onset, measured from the take's own audio (pitch curves design §2). The model's
/// notes are steps; this is what puts the slide, the bend and the vibrato back.
///
/// The measurement is local to each note: the harmonics of that note's pitch, ±200 cents around
/// it, frame by frame. On a solo line or a vocal stem they stand out; in a dense mix they do
/// not, and the gate then gives no curve rather than a wrong one. Any thread; allocates freely.
public enum PitchTracker {
    /// The model's mono copy is what is measured.
    public static let sampleRate = 16_000.0
    /// One curve value per 10 ms from the onset.
    public static let frameSeconds = 0.010
    /// 160 samples: the hop between frames.
    static let hop = 160
    /// 40 ms Hann window, centred on each frame's time.
    static let window = 640
    /// The candidate deviations, in cents: −200, −190, …, +200.
    static let candidateStep = 10.0
    static let candidateCount = 41
    static let maximumCents = 200.0
    /// Harmonics summed per candidate, each weighted 1/h.
    static let harmonics = 5
    /// A frame whose measured harmonics hold less than this share of its windowed energy has no
    /// clear harmonic peak at the note's pitch and is unreliable (see `GoertzelBank`).
    static let minimumHarmonicity: Float = 0.5
    /// The share of a note's frames that must be reliable for it to keep a curve.
    static let reliableShare = 0.7
    /// Shorter notes get no curve: too few frames to tell a bend from noise.
    public static let minimumSeconds = 0.060
    /// Width of the median filter over the finished curve, in frames.
    static let medianSpan = 5
    /// Outside this range a note's harmonics leave the band or the window cannot resolve it.
    public static let pitchRange = 24...108

    /// Whether `note` is one the tracker measures at all: melodic and within ``pitchRange``.
    public static func measures(_ note: NoteEvent) -> Bool {
        !note.isDrum && pitchRange.contains(note.pitch)
    }

    /// The number of curve values for a note of this length: one per whole 10 ms.
    public static func frameCount(for note: NoteEvent) -> Int {
        max(0, Int(((note.endTime - note.startTime) / frameSeconds + 1e-9).rounded(.down)))
    }

    /// One note's curve, or nil: for a note the tracker does not measure, one under 60 ms, or one
    /// whose frames are too often without a clear harmonic peak.
    public static func track(note: NoteEvent, mono16k: [Float]) -> [Float]? {
        guard measures(note) else { return nil }

        var bank = GoertzelBank(pitch: note.pitch)

        return curve(for: note, mono16k: mono16k, bank: &bank)
    }

    /// Every measured note among `notes`, keyed by id: its curve, or nil for one the gate
    /// refused, so a re-track also clears a curve the audio no longer supports. Drums and notes
    /// outside ``pitchRange`` are left out. The Goertzel tables are built once per pitch and
    /// shared by every note at it (design §2, Cost). `isCancelled` is asked between notes; a
    /// cancelled run returns what it had, which the caller discards.
    public static func track(notes: [EditableNote], mono16k: [Float],
                             isCancelled: () -> Bool = { false }) -> [NoteID: [Float]?] {
        var banks: [Int: GoertzelBank] = [:]
        var result: [NoteID: [Float]?] = [:]

        for note in notes where measures(note.note) {
            if isCancelled() { break }

            var bank = banks[note.note.pitch] ?? GoertzelBank(pitch: note.note.pitch)
            result[note.id] = .some(curve(for: note.note, mono16k: mono16k, bank: &bank))
            banks[note.note.pitch] = bank
        }

        return result
    }

    // MARK: - The gate

    /// The frames measured, gated, gap-filled and median-filtered (design §2, Gate).
    static func curve(for note: NoteEvent, mono16k: [Float], bank: inout GoertzelBank) -> [Float]? {
        guard note.endTime - note.startTime >= minimumSeconds - 1e-9 else { return nil }

        let count = frameCount(for: note)

        guard count > 0 else { return nil }

        let frames = bank.measure(mono16k: mono16k, startSeconds: note.startTime, frameCount: count)
        let reliable = frames.filter(\.reliable).count

        guard Double(reliable) >= reliableShare * Double(count) else { return nil }

        return medianFiltered(filled(frames), span: medianSpan)
    }

    /// The unreliable frames replaced: inside the curve, by a straight line between the reliable
    /// neighbours; at either end, by the nearest reliable value (so frame 0 takes the curve's
    /// first value when it was unreliable).
    static func filled(_ frames: [GoertzelBank.Frame]) -> [Float] {
        var values = frames.map(\.cents)
        let reliable = frames.indices.filter { frames[$0].reliable }

        guard let first = reliable.first, let last = reliable.last else { return values }

        for index in 0..<first { values[index] = values[first] }
        for index in (last + 1)..<values.count { values[index] = values[last] }

        for (left, right) in zip(reliable, reliable.dropFirst()) where right - left > 1 {
            let from = values[left]
            let to = values[right]

            for index in (left + 1)..<right {
                let t = Float(index - left) / Float(right - left)
                values[index] = from + (to - from) * t
            }
        }

        return values
    }

    /// A centred running median over `span` values, the window shrinking at the ends.
    static func medianFiltered(_ values: [Float], span: Int) -> [Float] {
        guard values.count > 2, span > 1 else { return values }

        let half = span / 2
        var window: [Float] = []
        window.reserveCapacity(span)

        return values.indices.map { index in
            window.removeAll(keepingCapacity: true)
            window.append(contentsOf: values[max(0, index - half)...min(values.count - 1, index + half)])
            window.sort()

            return window.count % 2 == 1
                ? window[window.count / 2]
                : (window[window.count / 2 - 1] + window[window.count / 2]) / 2
        }
    }
}
