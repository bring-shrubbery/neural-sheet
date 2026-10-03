import Foundation

/// Swing (editor commands design §2): with a ratio above 0.5, the second of each pair of the
/// grid's divisions sits late, at `pairStart + swing × pairLength` rather than the midpoint. The
/// pairs count from each bar line, as the divisions do (tempo map design §2), so every bar
/// restarts the pattern. Only an eighth or a sixteenth grid swings; and a division that falls on
/// one of the meter's beats never moves (the eighths of 6/8 are its beats), nor does the odd one
/// out at the end of a bar whose pair the bar line cuts short.
extension TempoGrid {
    /// Straight: no swing.
    public static let straightSwing = 0.5
    /// The heaviest swing the field offers.
    public static let maxSwing = 0.75

    /// Into `straightSwing…maxSwing`; anything not finite is straight.
    public static func clampedSwing(_ swing: Double) -> Double {
        guard swing.isFinite else { return straightSwing }

        return min(max(swing, straightSwing), maxSwing)
    }

    /// Whether `division` is one swing applies to.
    public static func divisionSwings(_ division: GridDivision) -> Bool {
        division == .eighth || division == .sixteenth
    }

    /// Whether this grid's lines and snap are swung at all.
    public var swings: Bool {
        swing > TempoGrid.straightSwing && TempoGrid.divisionSwings(division)
    }

    /// This grid without swing: what the score and the MusicXML export quantize to, since swing
    /// is a feel, not notation (editor commands design §2).
    public var straight: TempoGrid {
        var grid = self
        grid.swing = TempoGrid.straightSwing
        return grid
    }

    /// Quarter beats from the bar line to division `index` of `division` in a bar of `meter`,
    /// swung when this grid swings that division.
    func divisionOffset(_ index: Int, division: GridDivision, in meter: TimeSignature) -> Double {
        let step = stepBeats(in: meter, division: division)
        let straight = Double(index) * step

        guard swing > TempoGrid.straightSwing, TempoGrid.divisionSwings(division), index % 2 == 1,
              Double(index + 1) * step <= meter.quarterBeatsPerBar + TempoGrid.tolerance
        else { return straight }

        let beats = straight / meter.beatLength

        guard abs(beats - beats.rounded()) >= TempoGrid.tolerance else { return straight }

        return (Double(index - 1) + 2 * swing) * step
    }

    /// The swung line nearest `into` quarter beats past a bar line (or the last at or before it,
    /// `down`), in quarter beats from the bar line; the bar line ahead counts.
    func swungSnap(into: Double, in meter: TimeSignature, down: Bool) -> Double {
        let step = stepBeats(in: meter, division: division)
        let length = meter.quarterBeatsPerBar
        let count = max(1, Int((length / step - TempoGrid.tolerance).rounded(.up)))
        let near = Int((into / step).rounded(.down))
        var candidates = [length]

        for index in max(0, near - 2)...max(0, near + 2) where index < count {
            candidates.append(divisionOffset(index, division: division, in: meter))
        }

        if down {
            return candidates.filter { $0 <= into + TempoGrid.tolerance }.max() ?? 0
        }

        return candidates.min { abs($0 - into) < abs($1 - into) } ?? 0
    }
}
