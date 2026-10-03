import Foundation

extension MidiFile {
    /// The file's tempo map and meters as grid segments, with tick 0 as bar 1 (MIDI import
    /// design §2): one segment per bar a tempo or meter event falls on, an event between bar
    /// lines rounded to the nearest. The notes themselves are timed exactly by the reader; only
    /// the grid's bars are this approximation, and a DAW's events sit on bar lines anyway.
    ///
    /// Nil for a SMPTE file (its ticks are not beats) and for one with neither a tempo nor a
    /// meter, which leaves the project's grid alone.
    public func gridSegments() -> [GridSegment]? {
        guard let ppq = ticksPerQuarter, !tempoMap.isEmpty || !timeSignatures.isEmpty else { return nil }

        // The bar each meter change starts, counted through the meters before it.
        var meterBars: [(tick: Int, bar: Int, meter: TimeSignature)] = [(0, 1, .common)]

        for event in timeSignatures {
            let bar = Self.bar(atTick: event.tick, meters: meterBars, ppq: ppq)

            if event.tick == 0 || bar == meterBars[meterBars.count - 1].bar {
                meterBars[meterBars.count - 1].meter = event.timeSignature
            } else {
                meterBars.append((event.tick, bar, event.timeSignature))
            }
        }

        var byBar: [Int: (bpm: Double?, meter: TimeSignature?)] = [:]

        for entry in meterBars { byBar[entry.bar, default: (nil, nil)].meter = entry.meter }

        for event in tempoMap {
            // Whole microseconds a quarter put 90 BPM at 89.99996; a thousandth of a BPM is far
            // finer than any tempo field and gives the round number back.
            let bpm = (event.bpm * 1000).rounded() / 1000
            byBar[Self.bar(atTick: event.tick, meters: meterBars, ppq: ppq), default: (nil, nil)].bpm = bpm
        }

        var segments: [GridSegment] = []
        var bpm = TempoGrid.defaultBpm
        var meter = TimeSignature.common

        for bar in byBar.keys.sorted() {
            guard let change = byBar[bar] else { continue }

            bpm = change.bpm ?? bpm
            meter = change.meter ?? meter

            if let last = segments.last, last.bpm == bpm, last.timeSignature == meter { continue }

            segments.append(GridSegment(startBar: bar, bpm: bpm, timeSignature: meter))
        }

        return segments
    }

    /// The nearest bar line (1-based) to `tick`, through the meter changes before it.
    private static func bar(atTick tick: Int, meters: [(tick: Int, bar: Int, meter: TimeSignature)], ppq: Int) -> Int {
        let base = meters.last { $0.tick <= tick } ?? meters[0]
        let ticksPerBar = base.meter.quarterBeatsPerBar * Double(ppq)

        return base.bar + Int((Double(tick - base.tick) / ticksPerBar).rounded())
    }
}
