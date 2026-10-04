import Foundation
import NeuralSheetCore

/// The meters' state between frames (§2.5), shared by the Mac's `AppModel` and the iPhone and
/// iPad's `MobileModel` (sub-issue H): the master's and every instrument's ballistics, and how
/// long the render thread has stood still. Each frame the model hands it the engine's raw levels
/// and gets the levels to show back; it publishes only the ones that moved.
nonisolated struct MeterLevels {
    /// What one frame shows: the master, and every instrument in the mix by program.
    struct Reading {
        var master: Double
        var instruments: [Int: Double]
    }

    private var master = MeterBallistics()
    private var instruments: [Int: MeterBallistics] = [:]

    /// The render counter as of the last frame, and how long it has stood still.
    private var lastRenderedFrames: UInt64
    private var staleSeconds = 0.0

    init(renderedFrames: UInt64 = 0) {
        lastRenderedFrames = renderedFrames
    }

    /// Instant attack, 24 dB/s release, every meter fed the floor once the render thread has
    /// stood still for `max(0.5 s, 2 × block)` so a stopped engine's meters fall rather than
    /// stick (§2.5). `level` is read only for a live engine, once per program in the mix; a
    /// program that left the mix is dropped.
    mutating func advance(dt: Double, renderedFrames: UInt64, blockSeconds: Double, masterInput: Double,
                          programs: [Int], level: (Int) -> Double) -> Reading {
        if renderedFrames != lastRenderedFrames {
            lastRenderedFrames = renderedFrames
            staleSeconds = 0
        } else {
            staleSeconds += max(0, dt)
        }

        let stale = staleSeconds >= max(0.5, 2 * blockSeconds)
        var reading = Reading(master: master.advance(input: stale ? MeterScale.minDb : masterInput, dt: dt),
                              instruments: [:])

        for program in programs {
            let input = stale ? MeterScale.minDb : level(program)

            reading.instruments[program] = instruments[program, default: MeterBallistics()].advance(input: input, dt: dt)
        }

        if instruments.count != programs.count {
            let present = Set(programs)

            for program in instruments.keys where !present.contains(program) {
                instruments[program] = nil
            }
        }

        return reading
    }

    /// A transcription thrown away: every instrument's meter starts again from the floor.
    mutating func resetInstruments() {
        instruments = [:]
    }
}
