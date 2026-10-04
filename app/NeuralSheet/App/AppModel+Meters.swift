import Foundation
import NeuralSheetCore

/// The meters: the master's and every instrument's level after ballistics, advanced once a frame
/// by the display-link tick (§2.5).
extension AppModel {
    /// One instrument's level after ballistics, or the floor for a program not in the mix.
    func instrumentLevelDb(program: Int) -> Double {
        instrumentLevels[program] ?? MeterScale.minDb
    }

    /// One frame of the meters (`MeterLevels`): the levels after ballistics and the staleness
    /// rule, published only where they moved; a program that left the mix is pruned (§2.5).
    // Internal: called from AppModel+Playback.swift's displayLinkTick.
    func advanceMeters(dt: Double) {
        let blockSeconds = engine.sampleRate > 0 ? Double(engine.ioBufferFrames) / engine.sampleRate : 0
        let bank = engine.synthBank
        let reading = meterLevels.advance(dt: dt, renderedFrames: bank.renderedFrames, blockSeconds: blockSeconds,
                                          masterInput: engine.masterLevelDb, programs: mixer.entries.map(\.program),
                                          level: { bank.levelDb(program: $0) })

        if reading.master != masterLevelDb {
            masterLevelDb = reading.master
        }

        for (program, level) in reading.instruments where instrumentLevels[program] != level {
            instrumentLevels[program] = level
        }

        if instrumentLevels.count != reading.instruments.count {
            for program in instrumentLevels.keys where reading.instruments[program] == nil {
                instrumentLevels[program] = nil
            }
        }
    }
}
