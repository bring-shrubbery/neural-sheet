import Foundation
import Testing

@testable import NeuralSheetCore

@Test func anArrangementDefaultsEveryPartToNotation() {
    let arrangement = ScoreArrangement()
    #expect(arrangement.display(for: 40) == PartDisplay())
    #expect(arrangement.layout == .continuous)
    #expect(arrangement.pageSize == .a4)
    #expect(PartDisplay().mode == .notation)
    #expect(PartDisplay().clef == .automatic)
    #expect(PartDisplay().transposition == 0)
    #expect(PartDisplay().tab == nil)
    #expect(!PartDisplay().isHidden)
    #expect(SheetMetadata().showsMeasureNumbers && SheetMetadata().showsPartNames && SheetMetadata().showsTempo
        && SheetMetadata().showsChords)
}

@Test func anArrangementRoundTripsThroughJSON() throws {
    var arrangement = ScoreArrangement()
    var guitar = PartDisplay()
    guitar.mode = .both
    guitar.clef = .treble8vb
    guitar.transposition = 12
    guitar.tab = TabSetup(template: "guitar", tuning: [40, 45, 50, 55, 59, 64], presetName: "Standard", frets: 24)
    guitar.strings = [NoteID(3): 2]
    arrangement.parts[24] = guitar
    arrangement.sheet.title = "Take"
    arrangement.sheet.composer = "Trad."
    arrangement.sheet.showsChords = false
    arrangement.layout = .pages
    arrangement.pageSize = .letter

    let data = try JSONEncoder().encode(arrangement)
    let decoded = try JSONDecoder().decode(ScoreArrangement.self, from: data)
    #expect(decoded == arrangement)
    #expect(decoded.display(for: 24).strings[NoteID(3)] == 2)
}

@Test func anArrangementFromAnOlderFileFillsItsDefaults() throws {
    let json = #"{"parts":{"0":{"mode":"tab"}},"sheet":{"title":"Old"}}"#
    let decoded = try JSONDecoder().decode(ScoreArrangement.self, from: Data(json.utf8))
    #expect(decoded.display(for: 0).mode == .tab)
    #expect(decoded.display(for: 0).clef == .automatic)
    #expect(decoded.sheet.title == "Old")
    #expect(decoded.sheet.showsTempo)
    #expect(decoded.sheet.showsChords)
    #expect(decoded.layout == .continuous)
}

@Test func pageSizesInPoints() {
    #expect(abs(PageSize.a4.points.width - 595.28) < 0.01)
    #expect(abs(PageSize.a4.points.height - 841.89) < 0.01)
    #expect(PageSize.letter.points == CGSize(width: 612, height: 792))
    #expect(abs(PageSize.margin - 42.52) < 0.01)
    #expect(abs(PageSize.headerHeight - 51.02) < 0.01)
}

@Test func sheetTitlesFallBackToTheTake() {
    #expect(SheetMetadata().resolvedTitle(takeName: "song") == "song")
    #expect(SheetMetadata().resolvedTitle(takeName: nil) == "Untitled")
    var sheet = SheetMetadata()
    sheet.title = "My Tune"
    #expect(sheet.resolvedTitle(takeName: "song") == "My Tune")
    sheet.title = "   "
    #expect(sheet.resolvedTitle(takeName: "song") == "song", "blank is no title")
}

@Test func clefChoicesHaveNames() {
    #expect(ClefChoice.allCases.first == .automatic)
    #expect(ClefChoice.treble8vb.name == "Treble 8vb")
    #expect(ClefChoice.grand.name == "Grand staff")
}
