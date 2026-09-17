import Foundation
import Testing

@testable import NeuralSheetCore

private func note(_ pitch: Int, _ program: Int, at start: Double = 0) -> NoteEvent {
    NoteEvent(startTime: start, endTime: start + 0.5, pitch: pitch, program: program)
}

// MARK: - Entries

@Test func entriesAreAscendingByProgramWithDrumsLast() {
    var state = InstrumentMixerState()
    state.update(
        notes: [
            note(60, NoteEvent.drumProgram),
            note(40, 33),
            note(72, 0),
            note(64, 56),
        ],
        selectedPrograms: [])

    #expect(state.entries.map(\.program) == [0, 33, 56, NoteEvent.drumProgram])
    #expect(state.entries.last?.info.name == "Drums")
}

@Test func entriesTallyCountsAndPitchRange() {
    var state = InstrumentMixerState()
    state.update(
        notes: [note(60, 0), note(48, 0), note(72, 0), note(55, 33)],
        selectedPrograms: [])

    let piano = state.entry(forProgram: 0)
    #expect(piano?.noteCount == 3)
    #expect(piano?.lowestPitch == 48)
    #expect(piano?.highestPitch == 72)
    #expect(piano?.isPlaceholder == false)

    let bass = state.entry(forProgram: 33)
    #expect(bass?.noteCount == 1)
    #expect(bass?.lowestPitch == 55)
    #expect(bass?.highestPitch == 55)
}

@Test func selectedProgramsWithoutNotesBecomePlaceholders() {
    var state = InstrumentMixerState()
    state.update(notes: [note(60, 56)], selectedPrograms: [0, 56])

    #expect(state.entries.map(\.program) == [0, 56])

    let placeholder = state.entry(forProgram: 0)
    #expect(placeholder?.noteCount == 0)
    #expect(placeholder?.isPlaceholder == true)
    #expect(placeholder?.lowestPitch == 0)
    #expect(placeholder?.highestPitch == 0)
    #expect(placeholder?.info.name == "Piano")

    #expect(state.entry(forProgram: 56)?.isPlaceholder == false)
}

@Test func entriesCarryTheInstrumentInfoIncludingFallbacks() {
    var state = InstrumentMixerState()
    state.update(notes: [note(60, 100)], selectedPrograms: [])

    #expect(state.entry(forProgram: 100)?.info.name == "program_100")
    #expect(state.entry(forProgram: 100)?.info.abbreviation == "100")
}

@Test func updateReplacesThePreviousEntries() {
    var state = InstrumentMixerState()
    state.update(notes: [note(60, 0)], selectedPrograms: [])
    state.update(notes: [note(60, 33)], selectedPrograms: [])

    #expect(state.entries.map(\.program) == [33])
}

@Test func updateIgnoresProgramsOutsideTheValidRange() {
    var state = InstrumentMixerState()
    state.update(notes: [note(60, -1), note(60, 129), note(60, 0)], selectedPrograms: [-5, 200])

    #expect(state.entries.map(\.program) == [0])
}

// MARK: - Audibility

@Test func everythingIsAudibleByDefault() {
    var state = InstrumentMixerState()
    state.update(notes: [note(60, 0), note(60, 33)], selectedPrograms: [])

    #expect(state.isAudible(program: 0))
    #expect(state.isAudible(program: 33))
    #expect(!state.anySoloed)
}

@Test func mutingSilencesOnlyThatProgram() {
    var state = InstrumentMixerState()
    state.update(notes: [note(60, 0), note(60, 33)], selectedPrograms: [])
    state.setMuted(program: 0, muted: true)

    #expect(!state.isAudible(program: 0))
    #expect(state.isAudible(program: 33))
}

@Test func soloingSilencesEveryOtherProgram() {
    var state = InstrumentMixerState()
    state.update(notes: [note(60, 0), note(60, 33)], selectedPrograms: [])
    state.setSoloed(program: 33, soloed: true)

    #expect(state.anySoloed)
    #expect(state.isAudible(program: 33))
    #expect(!state.isAudible(program: 0))
}

@Test func muteBeatsSolo() {
    var state = InstrumentMixerState()
    state.update(notes: [note(60, 0)], selectedPrograms: [])
    state.setSoloed(program: 0, soloed: true)
    state.setMuted(program: 0, muted: true)

    #expect(!state.isAudible(program: 0))
}

@Test func soloOnAProgramOutsideTheEntriesDoesNotSilenceTheMix() {
    var state = InstrumentMixerState()
    state.update(notes: [note(60, 0)], selectedPrograms: [])
    state.setSoloed(program: 33, soloed: true)
    // 33 is not in the current transcription, so its stale solo must not mute what is.
    state.update(notes: [note(60, 0)], selectedPrograms: [])

    #expect(!state.anySoloed)
    #expect(state.isAudible(program: 0))
}

// MARK: - Settings

@Test func gainClampsToTheFaderRange() {
    var state = InstrumentMixerState()

    state.setGain(program: 0, db: -100)
    #expect(state.gainDb(program: 0) == InstrumentMixerState.minGainDb)

    state.setGain(program: 0, db: 100)
    #expect(state.gainDb(program: 0) == InstrumentMixerState.maxGainDb)

    state.setGain(program: 0, db: -12.5)
    #expect(state.gainDb(program: 0) == -12.5)
}

@Test func faderRangeMatchesTheStrip() {
    #expect(InstrumentMixerState.minGainDb == -36.0)
    #expect(InstrumentMixerState.maxGainDb == 6.0)
    #expect(InstrumentMixerState.gainStepDb == 0.1)
}

@Test func absentSettingsReadAsDefaults() {
    let state = InstrumentMixerState()

    #expect(state.settings.isEmpty)
    #expect(state.gainDb(program: 42) == 0)
    #expect(!state.isMuted(program: 42))
    #expect(!state.isSoloed(program: 42))
    #expect(InstrumentChannelSettings() == InstrumentChannelSettings(gainDb: 0, muted: false, soloed: false))
}

@Test func resetStoredSettingsEmptiesSettingsButKeepsEntries() {
    var state = InstrumentMixerState()
    state.update(notes: [note(60, 0)], selectedPrograms: [])
    state.setGain(program: 0, db: -6)
    state.setMuted(program: 0, muted: true)
    state.setSoloed(program: 0, soloed: true)

    #expect(state.settings.count == 1)

    state.resetStoredSettings()

    #expect(state.settings.isEmpty)
    #expect(state.entries.map(\.program) == [0])
    #expect(state.gainDb(program: 0) == 0)
    #expect(state.isAudible(program: 0))
}

@Test func settingsSurviveACodableRoundTrip() throws {
    var state = InstrumentMixerState()
    state.update(notes: [note(60, 0)], selectedPrograms: [])
    state.setGain(program: 0, db: -6)
    state.setSoloed(program: 33, soloed: true)

    let data = try JSONEncoder().encode(state)
    let decoded = try JSONDecoder().decode(InstrumentMixerState.self, from: data)

    #expect(decoded.settings == state.settings)
    // Entries are derived from the notes, so they are rebuilt rather than persisted.
    #expect(decoded.entries.isEmpty)
}

// MARK: - MIDI overflow mode

@Test func midiOverflowModeRawValues() {
    #expect(MidiOverflowMode.reuseChannels.rawValue == 0)
    #expect(MidiOverflowMode.dropExtraInstruments.rawValue == 1)
    #expect(MidiOverflowMode(rawValue: 1) == .dropExtraInstruments)
}
