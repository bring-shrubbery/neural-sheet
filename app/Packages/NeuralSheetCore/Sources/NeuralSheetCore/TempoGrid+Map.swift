import Foundation

/// The tempo map's conversions and edits (tempo map design §2–§3). Seconds and quarter beats
/// meet only in ``quarterBeats(atSeconds:)`` and ``seconds(atQuarterBeats:)``, piecewise linear
/// over the segment boundaries; bars, beats, lines and snapping are all written over them. Quarter
/// beats count from bar 1's downbeat and are negative before it.
extension TempoGrid {
    /// Positions within this many quarter beats of a line count as on it, so a time computed
    /// from a line reads back as that line.
    static let tolerance = 1e-9

    // MARK: - Segments

    /// The segment covering `bar`; bars before 1 are the first segment's.
    public func segmentIndex(atBar bar: Int) -> Int {
        lastIndex { segments[$0].startBar <= bar }
    }

    public func segment(atBar bar: Int) -> GridSegment {
        segments[segmentIndex(atBar: bar)]
    }

    public func segment(atSeconds seconds: Double) -> GridSegment {
        segments[segmentIndex(atRelativeSeconds: seconds - offsetSeconds)]
    }

    /// Whether a segment after the first starts at `bar`: what a ruler marker stands for.
    public func isChange(atBar bar: Int) -> Bool {
        bar > 1 && segments[segmentIndex(atBar: bar)].startBar == bar
    }

    /// Seconds at which each segment after the first starts, with the segment.
    public var changes: [(seconds: Double, segment: GridSegment)] {
        zip(boundaries, segments).dropFirst().map { (offsetSeconds + $0.seconds, $1) }
    }

    /// The segments sounding anywhere in `from...to`: what a view asks before deciding how dense
    /// its lines may get.
    public func segments(from: Double, to: Double) -> ArraySlice<GridSegment> {
        let first = segmentIndex(atRelativeSeconds: from - offsetSeconds)
        let last = segmentIndex(atRelativeSeconds: max(from, to) - offsetSeconds)

        return segments[first...last]
    }

    private func segmentIndex(atRelativeSeconds seconds: Double) -> Int {
        lastIndex { boundaries[$0].seconds <= seconds }
    }

    private func segmentIndex(atQuarterBeats beats: Double) -> Int {
        lastIndex { boundaries[$0].beats <= beats }
    }

    /// The last segment index for which `isAtOrBefore` holds (it holds for a prefix), or 0.
    private func lastIndex(where isAtOrBefore: (Int) -> Bool) -> Int {
        var low = 0
        var high = segments.count - 1

        while low < high {
            let middle = (low + high + 1) / 2
            if isAtOrBefore(middle) { low = middle } else { high = middle - 1 }
        }

        return low
    }

    // MARK: - Conversions

    /// Quarter beats from bar 1's downbeat to `seconds`.
    public func quarterBeats(atSeconds seconds: Double) -> Double {
        let relative = seconds - offsetSeconds
        let index = segmentIndex(atRelativeSeconds: relative)

        return boundaries[index].beats + (relative - boundaries[index].seconds) * segments[index].bpm / 60
    }

    /// The inverse of ``quarterBeats(atSeconds:)``.
    public func seconds(atQuarterBeats beats: Double) -> Double {
        let index = segmentIndex(atQuarterBeats: beats)

        return offsetSeconds + boundaries[index].seconds + (beats - boundaries[index].beats) * 60 / segments[index].bpm
    }

    /// Quarter beats from bar 1's downbeat to the start of `bar` (1-based).
    public func quarterBeats(atBar bar: Int) -> Double {
        let index = segmentIndex(atBar: bar)
        let segment = segments[index]

        return boundaries[index].beats + Double(bar - segment.startBar) * segment.timeSignature.quarterBeatsPerBar
    }

    /// The start of `bar` in seconds.
    public func barStart(bar: Int) -> Double {
        seconds(atQuarterBeats: quarterBeats(atBar: bar))
    }

    /// The bar (1-based) holding the position `beats` quarter beats from bar 1.
    public func bar(atQuarterBeats beats: Double) -> Int {
        let index = segmentIndex(atQuarterBeats: beats + TempoGrid.tolerance)
        let segment = segments[index]
        let bars = (beats - boundaries[index].beats) / segment.timeSignature.quarterBeatsPerBar

        return segment.startBar + Int((bars + TempoGrid.tolerance).rounded(.down))
    }

    public func bar(atSeconds seconds: Double) -> Int {
        bar(atQuarterBeats: quarterBeats(atSeconds: seconds))
    }

    /// 1-based bar and beat at `seconds`, the beat counted in the meter's own unit (six to a
    /// bar of 6/8); bar 0 and below before the offset.
    public func barBeat(at seconds: Double) -> (bar: Int, beat: Int) {
        let beats = quarterBeats(atSeconds: seconds)
        let bar = self.bar(atQuarterBeats: beats)
        let meter = segment(atBar: bar).timeSignature
        let beat = Int(((beats - quarterBeats(atBar: bar)) / meter.beatLength + TempoGrid.tolerance).rounded(.down))

        return (bar, min(max(beat, 0), meter.numerator - 1) + 1)
    }

    /// Seconds per division where `seconds` falls; a bar division is that bar.
    public func step(atSeconds seconds: Double) -> Double {
        let segment = self.segment(atSeconds: seconds)

        return stepBeats(in: segment.timeSignature, division: division) * 60 / segment.bpm
    }

    /// A division's length in quarter beats inside a bar of `meter`: its own, except that the
    /// whole-bar division is the bar.
    func stepBeats(in meter: TimeSignature, division: GridDivision) -> Double {
        division == .bar ? meter.quarterBeatsPerBar : division.beats
    }

    // MARK: - Snapping

    /// The nearest grid line, never before 0. The division counts from each bar line, so a bar
    /// it does not divide evenly ends in a shorter step (tempo map design §2).
    public func snap(_ seconds: Double) -> Double {
        snapped(seconds, down: false)
    }

    /// The grid line at or before `seconds`, never before 0.
    public func snapDown(_ seconds: Double) -> Double {
        snapped(seconds, down: true)
    }

    private func snapped(_ seconds: Double, down: Bool) -> Double {
        guard seconds.isFinite else { return 0 }

        let beats = quarterBeats(atSeconds: seconds)
        let bar = self.bar(atQuarterBeats: beats)
        let start = quarterBeats(atBar: bar)
        let length = segment(atBar: bar).timeSignature.quarterBeatsPerBar
        let step = stepBeats(in: segment(atBar: bar).timeSignature, division: division)
        let into = beats - start
        var position: Double

        if down {
            position = (into / step + TempoGrid.tolerance).rounded(.down) * step
        } else {
            position = min((into / step).rounded() * step, length)
            // The bar line ahead can be nearer than the last whole step before it.
            if length - into < abs(into - position) { position = length }
        }

        return max(0, self.seconds(atQuarterBeats: start + position))
    }

    // MARK: - Lines

    /// Every line of `division` (this grid's by default) in `from...to`, at or after 0, in order:
    /// `.bar` at bar lines, `.beat` on the meter's beats, `.division` between.
    public func lines(from: Double, to: Double, division: GridDivision? = nil) -> [GridLine] {
        let division = division ?? self.division

        return lines(from: from, to: to) { stepBeats(in: $0, division: division) }
    }

    /// The bar lines and the meter's beats in `from...to`: six to a bar of 6/8, three of 3/4.
    public func beatLines(from: Double, to: Double) -> [GridLine] {
        lines(from: from, to: to) { $0.beatLength }
    }

    private func lines(from: Double, to: Double, step: (TimeSignature) -> Double) -> [GridLine] {
        guard from.isFinite, to.isFinite, to >= max(from, 0) else { return [] }

        let slack = 1e-9
        var bar = self.bar(atSeconds: max(from, 0))
        let lastBar = self.bar(atSeconds: to)
        var lines: [GridLine] = []

        while bar <= lastBar {
            let meter = segment(atBar: bar).timeSignature
            let start = quarterBeats(atBar: bar)
            let stepBeats = step(meter)
            let count = max(1, Int((meter.quarterBeatsPerBar / stepBeats - TempoGrid.tolerance).rounded(.up)))

            for index in 0..<count {
                let offset = Double(index) * stepBeats
                let seconds = self.seconds(atQuarterBeats: start + offset)

                guard seconds >= from - slack, seconds <= to + slack, seconds >= -slack else { continue }

                let beats = offset / meter.beatLength
                let kind: GridLine.Kind = index == 0 ? .bar
                    : abs(beats - beats.rounded()) < TempoGrid.tolerance ? .beat : .division

                lines.append(GridLine(seconds: max(0, seconds), kind: kind))
            }

            bar += 1
        }

        return lines
    }

    // MARK: - Editing the map

    /// The tempo of the segment covering `bar`.
    public mutating func setTempo(_ bpm: Double, atBar bar: Int) {
        segments[segmentIndex(atBar: bar)].bpm = TempoGrid.clampedBpm(bpm)
    }

    /// The meter of the segment covering `bar`. Later segments keep their bar numbers, so they
    /// move in time with it.
    public mutating func setTimeSignature(_ meter: TimeSignature, atBar bar: Int) {
        segments[segmentIndex(atBar: bar)].timeSignature = meter
    }

    /// A new segment at `bar`, a copy of the one covering it; false when `bar` is bar 1 or before,
    /// or already starts a segment.
    @discardableResult
    public mutating func addChange(atBar bar: Int) -> Bool {
        let index = segmentIndex(atBar: bar)

        guard bar > 1, segments[index].startBar != bar else { return false }

        var copy = segments[index]
        copy.startBar = bar
        segments.insert(copy, at: index + 1)

        return true
    }

    /// Removes the segment starting at `bar`, which then belongs to the one before; false for
    /// bar 1 or a bar no segment starts at.
    @discardableResult
    public mutating func removeChange(atBar bar: Int) -> Bool {
        guard bar > 1, let index = segments.firstIndex(where: { $0.startBar == bar }) else { return false }

        segments.remove(at: index)

        return true
    }

    /// The whole map at once, as Detect lands it (tempo map design §2).
    public mutating func replaceMap(_ segments: [GridSegment], offsetSeconds: Double) {
        self.segments = TempoGrid.sanitised(segments)
        self.offsetSeconds = max(0, offsetSeconds.isFinite ? offsetSeconds : 0)
    }
}
