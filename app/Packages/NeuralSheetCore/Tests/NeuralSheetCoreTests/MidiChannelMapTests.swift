import Foundation
import Testing

@testable import NeuralSheetCore

// MARK: - The shared channel map (MIDI out design §4)

@Test func midiChannelMapIsWhatTheWriterAssigns() {
    let counts = Dictionary(uniqueKeysWithValues: (0..<20).map { ($0 * 5, 20 - $0) } + [(NoteEvent.drumProgram, 3)])

    for mode in [MidiOverflowMode.reuseChannels, .dropExtraInstruments] {
        #expect(
            MidiChannelMap.assign(programs: Array(counts.keys), noteCounts: counts, mode: mode)
                == MidiFileWriter.channelMap(programsAscending: Array(counts.keys), noteCounts: counts, mode: mode))
    }
}

@Test func midiChannelMapFromNotesCountsThemForTheDropMode() {
    // Sixteen melodic programs: the one with a single note is the one dropped.
    var notes: [NoteEvent] = []
    for program in 0..<16 {
        let count = program == 3 ? 1 : 2
        for index in 0..<count {
            notes.append(NoteEvent(startTime: Double(index), endTime: Double(index) + 0.5, pitch: 60, program: program))
        }
    }

    let map = MidiChannelMap.assign(notes: notes, mode: .dropExtraInstruments)

    #expect(map.count == 15)
    #expect(map[3] == nil)
    #expect(!map.values.contains(MidiChannelMap.drumChannel))
}

@Test func midiChannelMapPutsDrumsOnTenWithTheStandardKit() {
    let notes = [
        NoteEvent(startTime: 0, endTime: 1, pitch: 36, program: NoteEvent.drumProgram),
        NoteEvent(startTime: 0, endTime: 1, pitch: 60, program: 0),
    ]

    let map = MidiChannelMap.assign(notes: notes, mode: .reuseChannels)

    #expect(map[NoteEvent.drumProgram] == 10)
    #expect(map[0] == 1)
    #expect(MidiChannelMap.programChange(for: NoteEvent.drumProgram) == 0)
    #expect(MidiChannelMap.programChange(for: 33) == 33)
}

@Test func midiChannelMapVolumeIsTheFaderAsCC7() {
    #expect(MidiChannelMap.volume(gainDb: 0) == 100)
    #expect(MidiChannelMap.volume(gainDb: InstrumentMixerState.minGainDb) == 0)
    #expect(MidiChannelMap.volume(gainDb: -40) == 0)
    #expect(MidiChannelMap.volume(gainDb: 6) == 127)
    #expect(MidiChannelMap.volume(gainDb: -6) == 71)
    #expect(MidiChannelMap.volume(gainDb: .nan) == 0)
}
