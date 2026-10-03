import Foundation
import Testing

@testable import NeuralSheetCore

// Lyrics and markers in the core (markers and lyrics design §2, §3): the splitter, the typed
// form, the document commands and which commands keep a lyric, the marker list, the file.

private func sung(_ start: Double, _ end: Double, pitch: Int = 60, program: Int = 0, _ text: String? = nil) -> NoteEvent {
    NoteEvent(startTime: start, endTime: end, pitch: pitch, program: program, lyric: text.map { Lyric(text: $0) })
}

private func lyrics(_ batch: EditBatch) -> [Lyric?] {
    batch.changed.map(\.after.note.lyric) + batch.inserted.map(\.note.lyric)
}

// MARK: - Splitter

@Test func theSplitterCutsWordsAndSyllables() {
    let syllables = LyricSplitter.syllables(from: "Twin-kle twin-kle lit-tle star_")

    #expect(syllables.map(\.text) == ["Twin", "kle", "twin", "kle", "lit", "tle", "star"])
    #expect(syllables.map(\.syllabic) == [.begin, .end, .begin, .end, .begin, .end, .single])
    #expect(syllables.filter(\.extends).map(\.text) == ["star"])
}

@Test func theSplitterGivesMiddlesAndIgnoresStrayHyphensAndLines() {
    let syllables = LyricSplitter.syllables(from: "  won-der-ful\n-  - how_  ")

    #expect(syllables.map(\.text) == ["won", "der", "ful", "how"])
    #expect(syllables.map(\.syllabic) == [.begin, .middle, .end, .single])
    #expect(syllables.last?.extends == true)
}

// MARK: - Typed form

@Test func typedTextReadsItsTrailingMarks() {
    let twin = Lyric.typed("Twin-", after: nil)
    #expect(twin == Lyric(text: "Twin", syllabic: .begin))

    let kle = Lyric.typed("kle", after: twin)
    #expect(kle == Lyric(text: "kle", syllabic: .end))

    let der = Lyric.typed("der-", after: Lyric(text: "won", syllabic: .begin))
    #expect(der?.syllabic == .middle)

    let star = Lyric.typed(" star_ ", after: kle)
    #expect(star == Lyric(text: "star", syllabic: .single, extends: true))

    #expect(Lyric.typed(" -_ ", after: nil) == nil)
}

@Test func theTypedFormRoundTrips() {
    for lyric in [Lyric(text: "Twin", syllabic: .begin), Lyric(text: "kle", syllabic: .end, extends: true),
                  Lyric(text: "star", syllabic: .single, extends: true)] {
        let previous: Lyric? = lyric.syllabic == .end || lyric.syllabic == .middle ? Lyric(text: "x", syllabic: .begin) : nil
        #expect(Lyric.typed(lyric.typed, after: previous) == lyric)
    }

    #expect(Lyric(text: "won", syllabic: .begin).midiText == "won-")
    #expect(Lyric(text: "ful", syllabic: .end, extends: true).midiText == "ful")
}

// MARK: - File

@Test func aNoteWithoutALyricWritesNoKeyAndALyricRoundTrips() throws {
    let plain = NoteEvent(startTime: 0, endTime: 1, pitch: 60, program: 0)
    #expect(!String(decoding: try JSONEncoder().encode(plain), as: UTF8.self).contains("lyric"))

    let json = #"{"startTime":0,"endTime":1,"pitch":60,"amplitude":0.5,"program":0}"#
    #expect(try JSONDecoder().decode(NoteEvent.self, from: Data(json.utf8)).lyric == nil)

    var note = plain
    note.lyric = Lyric(text: "lit", syllabic: .begin, extends: true)
    #expect(try JSONDecoder().decode(NoteEvent.self, from: JSONEncoder().encode(note)) == note)
}

@Test func markersRoundTripThroughAFileAndAnOlderFileHasNone() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("markers-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: url) }

    var state = ProjectState()
    state.markers = [Marker(seconds: 0, name: "Intro"), Marker(seconds: 8.25, name: "Verse")]
    try state.save(to: url)
    #expect(try ProjectState.read(from: url) == state)

    try Data("{\"formatVersion\": 1}".utf8).write(to: url)
    #expect(try ProjectState.read(from: url).markers.isEmpty)
}

// MARK: - Markers

@Test func theMarkerListSortsAndFindsNeighbours() {
    let markers = [Marker(seconds: 8, name: "B"), Marker(seconds: -1, name: "A"), Marker(seconds: 16, name: "C")].sortedMarkers()

    #expect(markers.map(\.name) == ["A", "B", "C"])
    #expect(markers.first?.seconds == 0)
    #expect(markers.marker(before: 8)?.name == "A")
    #expect(markers.marker(after: 8)?.name == "C")
    #expect(markers.marker(after: 7.5)?.name == "B")
    #expect(markers.marker(before: 0) == nil)
    #expect(markers.marker(after: 16) == nil)
}

@Test func theDefaultMarkerNameCountsPastTheHighest() {
    #expect([Marker]().nextDefaultName() == "Marker 1")
    #expect([Marker(seconds: 0, name: "Intro")].nextDefaultName() == "Marker 2")
    #expect([Marker(seconds: 0, name: "Marker 5")].nextDefaultName() == "Marker 6")
}

// MARK: - Commands

@Test func setLyricChangesOnlyTheLyricAndClears() {
    var document = NoteDocument(events: [sung(0, 1)])
    let id = document.notes[0].id

    let batch = document.setLyric(id: id, Lyric(text: "Twin", syllabic: .begin))
    #expect(batch.title == "Lyric")
    #expect(batch.changed.count == 1)
    document.commit(batch)
    #expect(document.notes[0].note.lyric?.text == "Twin")

    #expect(document.setLyric(id: id, Lyric(text: "Twin", syllabic: .begin)).isEmpty)
    document.commit(document.setLyric(id: id, nil))
    #expect(document.notes[0].note.lyric == nil)
    document.undo()
    #expect(document.notes[0].note.lyric?.text == "Twin")
}

@Test func setLyricsHandsOutInOrderAndCountsWhatIsLeft() {
    let document = NoteDocument(events: [sung(0, 1), sung(1, 2), sung(2, 3)])
    let ids = document.notes.map(\.id)
    let syllables = LyricSplitter.syllables(from: "a b c d e")

    let (batch, leftOver) = document.setLyrics([ids[2], ids[0]], lyrics: syllables)
    #expect(batch.title == "Paste Lyrics")
    #expect(leftOver == 3)
    #expect(batch.changed.first { $0.after.id == ids[2] }?.after.note.lyric?.text == "a")
    #expect(batch.changed.first { $0.after.id == ids[0] }?.after.note.lyric?.text == "b")

    let (short, none) = document.setLyrics(ids, lyrics: [Lyric(text: "x")])
    #expect(none == 0)
    #expect(short.changed.count == 1)
}

@Test func theNextAndPreviousNoteStayOnTheInstrument() {
    let document = NoteDocument(events: [sung(0, 1), sung(0.5, 1, program: 40), sung(2, 3)])
    let piano = document.notes.filter { $0.note.program == 0 }

    #expect(document.nextNote(sameProgramAs: piano[0].id)?.id == piano[1].id)
    #expect(document.nextNote(sameProgramAs: piano[1].id) == nil)
    #expect(document.previousNote(sameProgramAs: piano[1].id)?.id == piano[0].id)
}

@Test func editsKeepTheLyric() {
    let document = NoteDocument(events: [sung(0.1, 1, "la"), sung(2.1, 3, pitch: 62, "lo")])
    let ids = Set(document.notes.map(\.id))
    let grid = TempoGrid(bpm: 120, offsetSeconds: 0, division: .quarter)

    for batch in [document.move(ids, deltaSeconds: 0.3, deltaSemitones: 2),
                  document.setPitch(ids, pitch: 70),
                  document.resize(ids, edge: .end, deltaSeconds: 0.4),
                  document.setLength(ids, seconds: 0.2),
                  document.setVelocity(ids, velocity: 30),
                  document.setProgram(ids, program: 5),
                  document.quantize(ids, grid: grid, lengths: true)] {
        #expect(!batch.changed.isEmpty)
        #expect(batch.changed.allSatisfy { $0.after.note.lyric != nil })
    }
}

@Test func splitKeepsTheLyricOnTheFirstHalfAndJoinOnTheFirstNote() {
    var document = NoteDocument(events: [sung(0, 1, "la"), sung(1, 2, "lo")])
    let first = document.notes[0].id

    let (split, _) = document.split([first], at: 0.5)
    #expect(split.changed.first?.after.note.lyric?.text == "la")
    #expect(split.inserted.first?.note.lyric == nil)

    let join = document.join(Set(document.notes.map(\.id)), gap: 0.01)
    #expect(join.changed.first?.after.note.lyric?.text == "la")
    #expect(join.deleted.first?.note.lyric?.text == "lo")
}

@Test func pastedAndDuplicatedNotesCarryTheirLyricButDrawnOnesDoNot() {
    var document = NoteDocument(events: [sung(0, 1, "la")])
    let id = document.notes[0].id

    #expect(lyrics(document.paste([sung(0, 1, "lo")], at: 4)) == [Lyric(text: "lo")])
    #expect(lyrics(document.duplicate([id], deltaSeconds: 2, deltaSemitones: 0)) == [Lyric(text: "la")])
    #expect(lyrics(document.insert(sung(5, 6, "no"))) == [nil])
}
