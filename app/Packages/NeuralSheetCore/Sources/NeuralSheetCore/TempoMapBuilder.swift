import Foundation

/// 3/4 or 4/4 from the beats' accents (tempo map design §2): the envelope at each tracked beat,
/// folded at three and at four beats a bar. A meter's contrast is how far its strongest phase
/// stands above the rest, as a fraction of the rest; the better meter's must be a quarter more
/// than the other's and an accent at all, or nothing is said. (The envelope is log-compressed, so
/// a downbeat twice as loud stands only about a tenth above its neighbours: the contrast is the
/// excess, not the ratio.) 2/4
/// cannot be told from 4/4 this way and compound meters need another beat level, so those are
/// left to the user.
public enum MeterEstimator {
    public static let candidates = [TimeSignature(numerator: 3, denominator: 4), TimeSignature(numerator: 4, denominator: 4)]
    /// How much more the winner's contrast must be than the loser's.
    static let margin = 1.25
    /// The least contrast that is an accent at all: a downbeat 3 % above the other beats.
    static let minimumContrast = 0.03
    /// Bars of the longer meter needed before the accents mean anything.
    static let minimumBars = 3

    public static func estimate(envelope: [Float], beats: [Double]) -> TimeSignature? {
        let frames = beats.map(frame(forSeconds:))

        guard frames.count >= minimumBars * 4 else { return nil }

        let strengths = frames.map { Double(BeatTracker.strength(at: $0, in: envelope)) }
        let three = contrast(strengths, beatsPerBar: 3)
        let four = contrast(strengths, beatsPerBar: 4)
        let (winner, best, other) = three > four ? (candidates[0], three, four) : (candidates[1], four, three)

        guard best >= minimumContrast, best >= other * margin else { return nil }

        return winner
    }

    /// Which of the first `beatsPerBar` beats is a downbeat: the phase whose beats are loudest.
    public static func downbeatIndex(envelope: [Float], beats: [Double], beatsPerBar: Int) -> Int {
        let strengths = beats.map { Double(BeatTracker.strength(at: frame(forSeconds: $0), in: envelope)) }

        return phaseMeans(strengths, beatsPerBar: beatsPerBar).enumerated().max { $0.element < $1.element }?.offset ?? 0
    }

    /// How far the loudest phase's mean stands above the other phases' mean, as a fraction of
    /// it; 0 for no accent.
    static func contrast(_ strengths: [Double], beatsPerBar: Int) -> Double {
        let means = phaseMeans(strengths, beatsPerBar: beatsPerBar)

        guard let loudest = means.max(), means.count > 1 else { return 0 }

        let others = (means.reduce(0, +) - loudest) / Double(means.count - 1)

        return others > 0 ? loudest / others - 1 : (loudest > 0 ? .infinity : 0)
    }

    static func phaseMeans(_ strengths: [Double], beatsPerBar: Int) -> [Double] {
        guard beatsPerBar > 0 else { return [] }

        return (0..<beatsPerBar).map { phase in
            let picked = stride(from: phase, to: strengths.count, by: beatsPerBar).map { strengths[$0] }
            return picked.isEmpty ? 0 : picked.reduce(0, +) / Double(picked.count)
        }
    }

    static func frame(forSeconds seconds: Double) -> Int {
        Int(((seconds - TempoEstimator.frameCentreOffset) * TempoEstimator.envelopeRate).rounded())
    }
}

/// Beats folded into a tempo map (tempo map design §2): bars of the meter's beats from the first
/// downbeat, each bar's tempo from its length, and a run of bars a segment while each is within
/// 2 % of the run's first. A segment's tempo is the median of its bars to a tenth; the first
/// downbeat is the grid's new offset.
public enum TempoMapBuilder {
    /// How far a bar may stray from its segment's first bar and still belong to it.
    static let tolerance = 0.02

    /// The map, or nil with fewer than two whole bars to read it from.
    public static func build(beats: [Double], downbeatIndex: Int,
                             timeSignature: TimeSignature) -> (offset: Double, segments: [GridSegment])? {
        // A compound meter's tracked beat is its dotted beat, three of the written ones.
        let beatsPerBar = timeSignature.isCompound ? timeSignature.numerator / 3 : timeSignature.numerator
        let downbeats = Array(stride(from: max(0, downbeatIndex), to: beats.count, by: max(1, beatsPerBar)).map { beats[$0] })

        guard downbeats.count >= 3 else { return nil }

        let tempos = zip(downbeats.dropFirst(), downbeats).map { later, earlier in
            60 * timeSignature.quarterBeatsPerBar / (later - earlier)
        }

        var segments: [GridSegment] = []
        var run: [Double] = []

        func close(startingAt bar: Int) {
            guard !run.isEmpty else { return }

            let sorted = run.sorted()
            let median = sorted.count % 2 == 1
                ? sorted[sorted.count / 2]
                : (sorted[sorted.count / 2 - 1] + sorted[sorted.count / 2]) / 2

            segments.append(GridSegment(startBar: bar, bpm: (median * 10).rounded() / 10, timeSignature: timeSignature))
        }

        var runStart = 1

        for (index, tempo) in tempos.enumerated() {
            if let first = run.first, abs(tempo - first) > first * tolerance {
                close(startingAt: runStart)
                run = []
                runStart = index + 1
            }

            run.append(tempo)
        }

        close(startingAt: runStart)

        return (downbeats[0], segments)
    }
}
