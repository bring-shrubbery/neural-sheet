import Foundation
import Testing

@testable import NeuralSheetCore

private let grid = TempoGrid(bpm: 120, offsetSeconds: 0, division: .sixteenth)

private func quarters(_ count: Int) -> [NoteEvent] {
    (0..<count).map { NoteEvent(startTime: Double($0) * 0.5, endTime: Double($0) * 0.5 + 0.5, pitch: 67, program: 0) }
}

@Test func aShortScoreIsOnePageWithAHeader() {
    let score = ScoreDocument.build(notes: quarters(8), grid: grid, key: nil)
    let layout = ScorePageLayout(document: score, arrangement: ScoreArrangement(), pageSize: .a4, sp: 7)

    #expect(layout.pages.count == 1)
    let page = layout.pages[0]
    #expect(page.frame.size == PageSize.a4.points)
    #expect(page.headerHeight == PageSize.headerHeight)
    #expect(page.systems.count == 1)
    #expect(page.systems[0].frame.minY >= PageSize.margin + PageSize.headerHeight, "the first system sits under the header")
    #expect(page.systems[0].frame.minX >= PageSize.margin)
    #expect(page.systems[0].frame.maxX <= PageSize.a4.points.width - PageSize.margin + 0.5)
}

@Test func systemsPaginateWithoutSplitting() {
    // Many parts make a tall system; many bars make many systems.
    var notes: [NoteEvent] = []
    for program in [0, 24, 33, 40, 56, 65] {
        notes += (0..<64).map { NoteEvent(startTime: Double($0) * 0.5, endTime: Double($0) * 0.5 + 0.5, pitch: 60, program: program) }
    }
    let score = ScoreDocument.build(notes: notes, grid: grid, key: nil)
    let layout = ScorePageLayout(document: score, arrangement: ScoreArrangement(), pageSize: .letter, sp: 7)

    #expect(layout.pages.count > 1)
    #expect(layout.pages.map(\.index) == Array(0..<layout.pages.count))
    #expect(layout.pages.dropFirst().allSatisfy { $0.headerHeight == 0 })

    for page in layout.pages {
        for system in page.systems {
            #expect(system.frame.minY >= PageSize.margin + page.headerHeight - 0.5)
            #expect(system.frame.maxY <= page.frame.height - PageSize.margin - ScorePageLayout.footerHeight + 0.5, "no system runs into the footer")
        }
    }

    let measures = layout.pages.flatMap(\.systems).flatMap(\.measures).map(\.index)
    #expect(measures == Array(0..<score.measureCount), "every measure once, in order")
}

@Test func aScaledPageScalesItsFrameAndMargins() {
    let score = ScoreDocument.build(notes: quarters(8), grid: grid, key: nil)
    let layout = ScorePageLayout(document: score, arrangement: ScoreArrangement(), pageSize: .a4, sp: 14, scale: 2)

    #expect(layout.pages.count == 1)
    let page = layout.pages[0]
    #expect(page.frame.size == CGSize(width: PageSize.a4.points.width * 2, height: PageSize.a4.points.height * 2))
    #expect(page.headerHeight == PageSize.headerHeight * 2)
    #expect(page.systems[0].frame.minY >= 2 * (PageSize.margin + PageSize.headerHeight))
    #expect(page.systems[0].frame.minX >= 2 * PageSize.margin)
    #expect(page.systems[0].frame.maxX <= 2 * (PageSize.a4.points.width - PageSize.margin) + 0.5)
}

@Test func inkStaysOffTheHeaderAndTheFooter() {
    var notes: [NoteEvent] = []
    for program in [0, 24, 33, 40, 56, 65] {
        notes += (0..<64).map { NoteEvent(startTime: Double($0) * 0.5, endTime: Double($0) * 0.5 + 0.5, pitch: 60, program: program) }
    }
    let score = ScoreDocument.build(notes: notes, grid: grid, key: nil)
    let layout = ScorePageLayout(document: score, arrangement: ScoreArrangement(), pageSize: .letter, sp: 7)

    #expect(layout.pages.count > 1)

    for page in layout.pages {
        // A clef, a ledger line or a stem reaches about two spaces past the rows.
        #expect(page.systems.first!.frame.minY >= PageSize.margin + page.headerHeight + 2 * 7 - 0.5)
        #expect(page.systems.last!.frame.maxY + 2 * 7 <= page.frame.height - PageSize.margin - ScorePageLayout.footerHeight + 0.5)
    }
}

@Test func anEmptyScoreIsOneEmptyPage() {
    let layout = ScorePageLayout(document: .empty, arrangement: ScoreArrangement(), pageSize: .a4, sp: 7)
    #expect(layout.pages.count == 1)
    #expect(layout.pages[0].systems.isEmpty)
}
