import Foundation
import NeuralSheetCore

/// The meters: the master's and every instrument's level after ballistics, advanced once a frame
/// by the display-link tick (§2.5).
extension AppModel {
    /// One instrument's level after ballistics, or the floor for a program not in the mix.
    func instrumentLevelDb(program: Int) -> Double {
        instrumentLevels[program] ?? MeterScale.minDb
    }

    /// Instant attack, 24 dB/s release, every meter fed the floor once the render thread has
    /// stood still for `max(0.5 s, 2 × block)` so a stopped engine's meters fall rather than
    /// stick (§2.5).
    // Internal: called from AppModel+Playback.swift's displayLinkTick.
    func advanceMeters(dt: Double) {
        let frames = engine.synthBank.renderedFrames

        if frames != lastRenderedFrames {
            lastRenderedFrames = frames
            renderStaleSeconds = 0
        } else {
            renderStaleSeconds += max(0, dt)
        }

        let blockSeconds = engine.sampleRate > 0 ? Double(engine.ioBufferFrames) / engine.sampleRate : 0
        let stale = renderStaleSeconds >= max(0.5, 2 * blockSeconds)

        let master = masterBallistics.advance(input: stale ? MeterScale.minDb : engine.masterLevelDb, dt: dt)

        if master != masterLevelDb {
            masterLevelDb = master
        }

        // In place, keyed by what is in the mix now: a program that left the mix is pruned, and
        // the published dictionary is written only for a level that actually moved.
        for entry in mixer.entries {
            let program = entry.program
            let input = stale ? MeterScale.minDb : engine.synthBank.levelDb(program: program)
            let level = instrumentBallistics[program, default: MeterBallistics()].advance(input: input, dt: dt)

            if instrumentLevels[program] != level {
                instrumentLevels[program] = level
            }
        }

        if instrumentBallistics.count != mixer.entries.count {
            let present = Set(mixer.entries.map(\.program))

            for program in instrumentBallistics.keys where !present.contains(program) {
                instrumentBallistics[program] = nil
                instrumentLevels[program] = nil
            }
        }
    }
}
