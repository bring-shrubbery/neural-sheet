import Foundation
import NeuralSheetCore
import XCTest

@testable import NeuralSheet

/// The transport, the mix and the strips through the model's contract (sub-issue H): what the
/// bar and the strips set reaches the engine -- the speed clamped to its range, the loop window
/// from the range or the take, the crossfade with its holds and the split, the click, and the
/// faders, mutes, solos and pans as the synth bank's mixer -- and the mix's changes are undoable.
@MainActor
final class MobileModelTransportTests: XCTestCase {
    private let piano = NoteEvent(startTime: 0.5, endTime: 1.0, pitch: 60, program: 0)
    private let bass = NoteEvent(startTime: 1.0, endTime: 2.0, pitch: 40, program: 33)

    private var undoManager: UndoManager!

    /// Eight seconds of silence, a piano note and a bass note; with an undo manager that groups by
    /// hand (`step`) when the test is about undo.
    private func makeModel(undo: Bool = false) -> MobileModel {
        let take = SourceAudio(deviceRate: 48_000, channels: [[Float](repeating: 0, count: 8 * 48_000)],
                               mono16k: [Float](repeating: 0, count: 8 * 16_000),
                               peaks: WaveformPeaks(), droppedFileName: "take", sourcePath: nil)
        let model = MobileModel()
        model.installSource(take)
        model.installDocument(rawNotes: [piano, bass])

        if undo {
            undoManager = UndoManager()
            undoManager.groupsByEvent = false
            model.undoManager = undoManager
        }

        return model
    }

    private func step(_ action: () -> Void) {
        undoManager.beginUndoGrouping()
        action()
        undoManager.endUndoGrouping()
    }

    // MARK: - Speed

    func testTheSpeedIsClampedAndReachesTheEngine() {
        let model = makeModel()

        model.setPlaybackSpeed(0.733)
        XCTAssertEqual(model.playbackSpeed, 0.75, accuracy: 1e-9)
        XCTAssertEqual(model.engine.speed, 0.75, accuracy: 1e-9)

        model.setPlaybackSpeed(3)
        XCTAssertEqual(model.playbackSpeed, 1.5)
        XCTAssertEqual(model.engine.speed, 1.5)

        model.playbackSpeed = 0.1
        XCTAssertEqual(model.playbackSpeed, 0.5)
        XCTAssertEqual(model.engine.speed, 0.5)

        model.playbackSpeed = .nan
        XCTAssertEqual(model.playbackSpeed, 1)

        model.setPlaybackSpeed(1.2)
        model.resetSpeed()
        XCTAssertEqual(model.engine.speed, 1)
    }

    // MARK: - Loop

    func testTheLoopRepeatsTheRangeOrTheWholeTake() {
        let model = makeModel()

        XCTAssertNil(model.engine.loop)

        model.toggleLoop()
        XCTAssertTrue(model.loopEnabled)
        XCTAssertEqual(model.engine.loop, 0 ..< 8)

        model.setRange(2 ..< 4)
        XCTAssertEqual(model.engine.loop, 2 ..< 4)

        // A sliver is no range: the whole take again.
        model.setRange(3 ..< 3.01)
        XCTAssertEqual(model.engine.loop, 0 ..< 8)

        model.toggleLoop()
        XCTAssertNil(model.engine.loop)
    }

    func testTheLoopNeedsATake() {
        let model = MobileModel()

        model.toggleLoop()

        XCTAssertFalse(model.loopEnabled)
        XCTAssertNil(model.engine.loop)
    }

    // MARK: - Mix

    func testTheMixHoldsAndSplitReachTheEngine() {
        let model = makeModel()

        model.setMix(0.2)
        XCTAssertEqual(model.engine.mix, 0.2, accuracy: 1e-9)

        model.beginMixHold(.synth)
        XCTAssertEqual(model.effectiveMix, 1)
        XCTAssertEqual(model.engine.mix, 1)
        model.endMixHold()
        XCTAssertEqual(model.engine.mix, 0.2, accuracy: 1e-9)
        XCTAssertEqual(model.mix, 0.2, accuracy: 1e-9)

        // Under the split both sides play at full; the slider is inert, a hold silences an ear.
        model.setStereoSplit(true)
        XCTAssertTrue(model.engine.stereoSplit)
        XCTAssertEqual(model.engine.mix, 0.5)

        model.setMix(0.9)
        XCTAssertEqual(model.mix, 0.2, accuracy: 1e-9)

        model.beginMixHold(.source)
        XCTAssertEqual(model.engine.mix, 0)
        model.endMixHold()

        model.setStereoSplit(false)
        XCTAssertFalse(model.engine.stereoSplit)
        XCTAssertEqual(model.engine.mix, 0.2, accuracy: 1e-9)
    }

    func testTheOutputLevelAndMuteReachTheEngine() {
        let model = makeModel()

        model.setMasterGain(db: 12)
        XCTAssertEqual(model.engine.masterGainDb, InstrumentMixerState.maxGainDb)

        model.toggleOutputMuted()
        XCTAssertTrue(model.engine.muted)
    }

    // MARK: - Click

    func testClickReachesTheEngineAndUndoes() {
        let model = makeModel(undo: true)

        step { model.toggleClick() }
        XCTAssertTrue(model.clickEnabled)
        XCTAssertTrue(model.engine.synthBank.clickEnabled)

        undoManager.undo()
        XCTAssertFalse(model.clickEnabled)
        XCTAssertFalse(model.engine.synthBank.clickEnabled)
    }

    // MARK: - Strips

    func testTheStripsAreTheNotesInstruments() {
        let model = makeModel()

        XCTAssertEqual(model.mixer.entries.map(\.program), [0, 33])
        XCTAssertEqual(model.mixer.entries.map(\.noteCount), [1, 1])
    }

    func testMuteSoloAndGainReachTheSynthBanksMixer() {
        let model = makeModel()
        let applied = { model.engine.synthBank.appliedMixer }

        model.setMuted(program: 0, true)
        XCTAssertFalse(applied().isAudible(program: 0))
        XCTAssertTrue(applied().isAudible(program: 33))

        model.setMuted(program: 0, false)
        model.setSoloed(program: 33, true)
        XCTAssertFalse(applied().isAudible(program: 0))
        XCTAssertTrue(applied().isAudible(program: 33))

        model.setGain(program: 33, db: -6)
        XCTAssertEqual(applied().gainDb(program: 33), -6, accuracy: 1e-9)

        model.setPan(program: 33, -0.5)
        XCTAssertEqual(applied().pan(program: 33), -0.5, accuracy: 1e-9)
        XCTAssertEqual(model.mixer, applied())
    }

    /// A fader drag is one undo entry, however many values it went through.
    func testAFaderDragIsOneUndo() {
        let model = makeModel(undo: true)

        step {
            for db in stride(from: -1.0, through: -9.0, by: -1) {
                model.setGain(program: 0, db: db, dragging: true)
            }
            model.endMixDrag()
        }
        XCTAssertEqual(model.mixer.gainDb(program: 0), -9, accuracy: 1e-9)

        undoManager.undo()
        XCTAssertEqual(model.mixer.gainDb(program: 0), 0)
        XCTAssertEqual(model.engine.synthBank.appliedMixer.gainDb(program: 0), 0)
        XCTAssertFalse(undoManager.canUndo)
    }

    func testATapSinglesTheInstrumentOutAndMakesItTheTarget() {
        let model = makeModel()

        model.toggleHighlight(program: 33)
        XCTAssertEqual(model.highlightedProgram, 33)
        XCTAssertEqual(model.editor.targetProgram, 33)

        model.toggleHighlight(program: 33)
        XCTAssertNil(model.highlightedProgram)
    }

    func testTheStripMenusCommandsCommitBatches() {
        let model = makeModel()

        model.reassignInstrument(33, to: 32)
        XCTAssertEqual(Set(model.document?.events.map(\.program) ?? []), [0, 32])
        XCTAssertEqual(model.mixer.entries.map(\.program), [0, 32])

        model.deleteInstrument(32)
        XCTAssertEqual(model.document?.events.map(\.program), [0])

        model.undo()
        XCTAssertEqual(Set(model.document?.events.map(\.program) ?? []), [0, 32])
    }

    // MARK: - Meters

    /// With the engine still, every meter is fed the floor: one per strip, none for a program
    /// that left the mix.
    func testTheMetersFollowTheStrips() {
        let model = makeModel()

        model.advanceMeters(dt: 1)
        XCTAssertEqual(Set(model.instrumentLevels.keys), [0, 33])
        XCTAssertEqual(model.masterLevelDb, MeterScale.minDb)

        model.deleteInstrument(33)
        model.advanceMeters(dt: 1)
        XCTAssertEqual(Set(model.instrumentLevels.keys), [0])
    }
}
