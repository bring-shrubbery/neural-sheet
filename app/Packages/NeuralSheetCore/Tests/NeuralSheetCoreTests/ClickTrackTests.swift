import Foundation
import Testing

@testable import NeuralSheetCore

// MARK: - Helpers

private func times(_ events: [NoteEvent]) -> [Double] {
    events.map { ($0.startTime * 1e6).rounded() / 1e6 }
}

private func accents(_ events: [NoteEvent]) -> [Bool] {
    events.map { $0.pitch == ClickTrack.downbeatPitch }
}

// MARK: - Events from the map

@Test func clickFollowsA44MapThroughATempoChange() {
    // Bars 1–2 at 120 (a beat every 0.5 s), bar 3 on at 60 (a beat a second).
    let grid = TempoGrid(segments: [GridSegment(startBar: 1, bpm: 120), GridSegment(startBar: 3, bpm: 60)])
    let events = ClickTrack.events(grid: grid, duration: 8)

    #expect(times(events) == [0, 0.5, 1, 1.5, 2, 2.5, 3, 3.5, 4, 5, 6, 7])
    #expect(accents(events) == [true, false, false, false, true, false, false, false, true, false, false, false])
    #expect(events.allSatisfy { $0.program == ClickTrack.program })
    #expect(events.allSatisfy { abs($0.endTime - $0.startTime - ClickTrack.hitSeconds) < 1e-12 })
}

@Test func clickPlaysThreeBeatsToABarOf34ThroughATempoChange() {
    // Bar 1 at 120 (0.5 s a beat), bar 2 on at 90 (2/3 s a beat).
    let waltz = TimeSignature(numerator: 3, denominator: 4)
    let grid = TempoGrid(segments: [GridSegment(startBar: 1, bpm: 120, timeSignature: waltz),
                                    GridSegment(startBar: 2, bpm: 90, timeSignature: waltz)])
    let events = ClickTrack.events(grid: grid, duration: 5.5)

    #expect(times(events) == [0, 0.5, 1, 1.5, 2.166667, 2.833333, 3.5, 4.166667, 4.833333])
    #expect(accents(events) == [true, false, false, true, false, false, true, false, false])
}

@Test func clickAccentsAndVelocities() {
    let events = ClickTrack.events(grid: TempoGrid(bpm: 120), duration: 2)

    #expect(events.first?.velocity == ClickTrack.downbeatVelocity)
    #expect(events.first?.pitch == ClickTrack.downbeatPitch)
    #expect(events[1].velocity == ClickTrack.beatVelocity)
    #expect(events[1].pitch == ClickTrack.beatPitch)
}

@Test func clickBeforeTheOffsetClicksBarZeroWhereTheTakeHasIt() {
    // Bar 1 at 1 s: bar 0's last two beats fall at 0 and 0.5, unaccented.
    let grid = TempoGrid(bpm: 120, offsetSeconds: 1)
    let events = ClickTrack.events(grid: grid, duration: 2)

    #expect(times(events) == [0, 0.5, 1, 1.5])
    #expect(accents(events) == [false, false, true, false])
}

@Test func clickLeavesOutABeatAtTheVeryEndAndNothingForNoDuration() {
    #expect(times(ClickTrack.events(grid: TempoGrid(bpm: 120), duration: 1)) == [0, 0.5])
    #expect(ClickTrack.events(grid: TempoGrid(bpm: 120), duration: 0).isEmpty)
    #expect(ClickTrack.events(grid: TempoGrid(bpm: 120), duration: .nan).isEmpty)
}

// MARK: - Count-in

@Test func countInIsBarsAtTheFirstSegmentsTempoAndMeter() {
    let waltz = TimeSignature(numerator: 3, denominator: 4)
    // The second segment and the offset have nothing to say about the count-in.
    let grid = TempoGrid(segments: [GridSegment(startBar: 1, bpm: 90, timeSignature: waltz),
                                    GridSegment(startBar: 2, bpm: 200)], offsetSeconds: 3)
    let countIn = ClickTrack.countIn(grid: grid, bars: 2)

    #expect(abs(countIn.seconds - 4) < 1e-12)
    #expect(countIn.events.count == 6)
    #expect(accents(countIn.events) == [true, false, false, true, false, false])
    #expect(times(countIn.events) == [0, 0.666667, 1.333333, 2, 2.666667, 3.333333])
}

@Test func countInOffIsNothing() {
    let countIn = ClickTrack.countIn(grid: TempoGrid(bpm: 100), bars: 0)

    #expect(countIn.events.isEmpty)
    #expect(countIn.seconds == 0)
}

@Test func recordingClickIsTheCountInThenTheGridFromTheTakesStart() {
    // 1 bar of 4/4 at 100: four clicks over 2.4 s, then the take's bar 1 on the next downbeat
    // whatever the project's offset was.
    let grid = TempoGrid(bpm: 100, offsetSeconds: 0.7)
    let recording = ClickTrack.recording(grid: grid, countInBars: 1, clickDuringTake: true, horizon: 2.4)

    #expect(abs(recording.seconds - 2.4) < 1e-12)
    #expect(times(recording.events) == [0, 0.6, 1.2, 1.8, 2.4, 3, 3.6, 4.2])
    #expect(accents(recording.events) == [true, false, false, false, true, false, false, false])

    let silentTake = ClickTrack.recording(grid: grid, countInBars: 1, clickDuringTake: false, horizon: 60)
    #expect(silentTake.events.count == 4)

    let noCountIn = ClickTrack.recording(grid: grid, countInBars: 0, clickDuringTake: true, horizon: 1.2)
    #expect(noCountIn.seconds == 0)
    #expect(times(noCountIn.events) == [0, 0.6])
}

// MARK: - Settings

@Test func globalSettingsClickKeysRoundTripAndDefault() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("click-\(UUID().uuidString).settings")
    defer { try? FileManager.default.removeItem(at: url) }

    #expect(GlobalSettings().soundBankPath == nil)
    #expect(GlobalSettings().countInBars == 0)
    #expect(!GlobalSettings().clickWhileRecording)

    var settings = GlobalSettings()
    settings.soundBankPath = "/Users/someone/Banks/GeneralUser.sf2"
    settings.countInBars = 2
    settings.clickWhileRecording = true
    try settings.save(to: url)

    #expect(GlobalSettings.load(from: url) == settings)

    // A count-in the picker does not offer is off.
    let text = try String(contentsOf: url, encoding: .utf8)
        .replacingOccurrences(of: "<integer>2</integer>", with: "<integer>7</integer>")
    try text.write(to: url, atomically: true, encoding: .utf8)
    #expect(GlobalSettings.load(from: url).countInBars == 0)
}

@Test func projectStateClickRoundTripsAndDefaults() throws {
    #expect(!ProjectState().clickEnabled)
    #expect(ProjectState().clickGainDb == -6)

    var state = ProjectState()
    state.clickEnabled = true
    state.clickGainDb = -12
    state.mixer = [33: InstrumentChannelSettings(pan: -1)]

    let decoded = try JSONDecoder().decode(ProjectState.self, from: JSONEncoder().encode(state))
    #expect(decoded == state)

    let old = try JSONDecoder().decode(ProjectState.self, from: Data("{}".utf8))
    #expect(!old.clickEnabled)
    #expect(old.clickGainDb == -6)
}

@Test func countingInCannotPlayAndHasNoTranscription() {
    #expect(!AppState.countingIn.canPlay)
    #expect(!AppState.countingIn.hasTranscription)
}
