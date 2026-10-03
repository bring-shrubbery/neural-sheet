import Foundation

/// The chords of a transcription from its notes (chord symbols design §2): a template match over
/// each bar of the tempo map and its two halves, key-aware, with a slash bass. Pure and
/// deterministic: the same notes, grid and key always give the same list.
public enum ChordDetector {
    /// What an out-of-template pitch class costs against an in-template one.
    static let outOfTemplatePenalty = 0.6
    /// What a chord tone that barely sounds costs, so a passing note does not turn every triad
    /// into a seventh: a superset template would otherwise match as well as its triad.
    static let missingTonePenalty = 0.1
    /// Below this share of the window's heaviest pitch class, a chord tone counts as missing.
    static let missingToneShare = 0.1
    static let inKeyBonus = 0.05
    static let bassIsRootBonus = 0.1
    /// How much better the two halves must score, on average, for a bar to split.
    static let splitMargin = 0.08
    /// The lowest note counts as the bass only at this share of the window's heaviest note.
    static let bassShare = 0.2
    /// A window lighter than this share of the median bar (scaled by its length) is N.C.
    static let silenceShare = 0.05
    /// Scores closer than this are a tie.
    static let epsilon = 1e-9

    /// The chord list for `notes` (drums skipped) over the bars of `grid` from 0 to `duration`
    /// seconds (the notes' end when `duration` is not positive), in time order, consecutive equal
    /// chords merged; empty without a melodic note.
    public static func detect(notes: [NoteEvent], grid: TempoGrid, key: MusicalKey?, duration: Double) -> [ChordEvent] {
        let melodic = notes.filter { !$0.isDrum && $0.endTime > $0.startTime && $0.startTime.isFinite && $0.endTime.isFinite }
        guard !melodic.isEmpty else { return [] }

        let end = duration > 0 && duration.isFinite ? duration : melodic.map(\.endTime).max() ?? 0
        guard end > 0 else { return [] }

        let bars = windows(grid: grid, end: end)
        let barProfiles = bars.map { Profile(notes: melodic, from: $0.start, to: $0.end) }
        let silence = silenceShare * median(barProfiles.map(\.total).filter { $0 > 0 })

        var events: [ChordEvent] = []

        func append(_ seconds: Double, _ chord: ChordSymbol?) {
            if let last = events.last, last.chord == chord { return }
            events.append(ChordEvent(seconds: seconds, chord: chord))
        }

        for (index, bar) in bars.enumerated() {
            let barLength = bar.end - bar.start
            let threshold = { (length: Double) in barLength > 0 ? silence * length / barLength : silence }
            let whole = best(barProfiles[index], key: key, threshold: threshold(barLength))

            if let middle = bar.middle {
                let first = best(Profile(notes: melodic, from: bar.start, to: middle), key: key, threshold: threshold(middle - bar.start))
                let second = best(Profile(notes: melodic, from: middle, to: bar.end), key: key, threshold: threshold(bar.end - middle))

                if first.chord != second.chord, (first.score + second.score) / 2 > whole.score + splitMargin {
                    append(bar.start, first.chord)
                    append(middle, second.chord)
                    continue
                }
            }

            append(bar.start, whole.chord)
        }

        return events
    }

    // MARK: - Windows

    struct Window {
        var start: Double
        var end: Double
        /// Where the bar may split; nil when a half would be shorter than one beat.
        var middle: Double?
    }

    /// Every bar of the map that overlaps `0..<end`, clipped to it. The split point is the beat
    /// nearest the bar's middle, half the beats rounded down (2 + 2 in 4/4, 3 + 3 in 6/8, 1 + 2
    /// in 3/4), so neither half is shorter than one beat (chord symbols design §2).
    static func windows(grid: TempoGrid, end: Double) -> [Window] {
        var result: [Window] = []
        var bar = grid.bar(atSeconds: 0)

        while true {
            let start = grid.barStart(bar: bar)
            guard start < end else { break }

            let next = grid.barStart(bar: bar + 1)
            let meter = grid.segment(atBar: bar).timeSignature
            let half = meter.numerator / 2
            var middle: Double?

            if half >= 1 {
                let seconds = grid.seconds(atQuarterBeats: grid.quarterBeats(atBar: bar) + Double(half) * meter.beatLength)
                if seconds > max(start, 0), seconds < min(next, end) { middle = seconds }
            }

            if next > 0 { result.append(Window(start: max(start, 0), end: min(next, end), middle: middle)) }
            bar += 1
        }

        return result
    }

    static func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }

        let sorted = values.sorted()
        let middle = sorted.count / 2

        return sorted.count % 2 == 1 ? sorted[middle] : (sorted[middle - 1] + sorted[middle]) / 2
    }

    // MARK: - Profiles

    /// A window's weighted pitch classes and its bass.
    struct Profile {
        var weights = [Double](repeating: 0, count: 12)
        var total = 0.0
        var bass: Int?

        /// Each note clipped to `from..<to`, weighed by its clipped length times its velocity; the
        /// bass is the lowest note weighing at least ``bassShare`` of the heaviest.
        init(notes: [NoteEvent], from: Double, to: Double) {
            var heaviest = 0.0
            var clipped: [(pitch: Int, weight: Double)] = []

            for note in notes {
                let length = min(note.endTime, to) - max(note.startTime, from)
                guard length > 0 else { continue }

                let weight = length * min(max(note.amplitude, 0), 1)
                guard weight > 0 else { continue }

                clipped.append((note.pitch, weight))
                weights[ChordSymbol.pitchClass(note.pitch)] += weight
                total += weight
                heaviest = max(heaviest, weight)
            }

            bass = clipped.filter { $0.weight >= ChordDetector.bassShare * heaviest }.min { $0.pitch < $1.pitch }
                .map { ChordSymbol.pitchClass($0.pitch) }
        }
    }

    // MARK: - Scoring

    /// The best chord for a profile and its score; N.C. (scoring 0) when the window weighs less
    /// than `threshold` or nothing at all.
    static func best(_ profile: Profile, key: MusicalKey?, threshold: Double) -> (chord: ChordSymbol?, score: Double) {
        guard profile.total > 0, profile.total >= threshold else { return (nil, 0) }

        var best: ChordSymbol?
        var bestScore = -Double.infinity

        // Qualities outside, so a tie keeps the simpler one (chord symbols design §2).
        for quality in ChordQuality.allCases {
            for root in 0..<12 {
                let candidate = ChordSymbol(root: root, quality: quality)
                let value = score(candidate, profile: profile, key: key)

                if value > bestScore + epsilon {
                    bestScore = value
                    best = candidate
                }
            }
        }

        guard var chord = best else { return (nil, 0) }

        // A slash only when the bass is one of the chord's other tones (issue #16, requirement 1).
        if let bass = profile.bass, bass != chord.root, chord.pitchClasses.contains(bass) {
            chord.bass = bass
        }

        return (chord, bestScore)
    }

    /// In-template weight less ``outOfTemplatePenalty`` times the rest, over the total; less
    /// ``missingTonePenalty`` per chord tone that barely sounds; plus the key and bass bonuses.
    static func score(_ chord: ChordSymbol, profile: Profile, key: MusicalKey?) -> Double {
        let tones = chord.pitchClasses
        let heaviest = profile.weights.max() ?? 0
        var inside = 0.0

        for pitchClass in tones { inside += profile.weights[pitchClass] }

        let outside = profile.total - inside
        var value = (inside - outOfTemplatePenalty * max(outside, 0)) / profile.total

        for pitchClass in tones where profile.weights[pitchClass] < missingToneShare * heaviest {
            value -= missingTonePenalty
        }

        if let key, tones.allSatisfy({ key.scalePitchClasses.contains($0) }) { value += inKeyBonus }
        if profile.bass == chord.root { value += bassIsRootBonus }

        return value
    }
}
