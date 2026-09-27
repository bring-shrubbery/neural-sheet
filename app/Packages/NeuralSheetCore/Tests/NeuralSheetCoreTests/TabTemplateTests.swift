import Foundation
import Testing

@testable import NeuralSheetCore

@Test func theLibraryCoversTheFrettedInstruments() {
    let ids = TabTemplate.all.map(\.id)
    #expect(ids == ["guitar", "guitar7", "bass", "bass5", "bass6", "banjo5", "banjoTenor", "banjoPlectrum", "mandolin", "ukulele", "lapSteel"])

    for template in TabTemplate.all {
        #expect(!template.presets.isEmpty, "\(template.id)")
        for preset in template.presets {
            #expect(preset.pitches.count == template.strings, "\(template.id) \(preset.name)")
        }
    }
}

@Test func standardTuningsAreRight() {
    let guitar = TabTemplate.template(id: "guitar")!
    #expect(guitar.presets[0].pitches == [40, 45, 50, 55, 59, 64], "E2 A2 D3 G3 B3 E4")
    #expect(guitar.presets[0].label == "E A D G B E")
    #expect(guitar.defaultTransposition == 12)
    #expect(guitar.frets == 24)

    let bass = TabTemplate.template(id: "bass")!
    #expect(bass.presets[0].pitches == [28, 33, 38, 43])
    #expect(bass.defaultTransposition == 12)

    let banjo = TabTemplate.template(id: "banjo5")!
    #expect(banjo.presets[0].name.hasPrefix("Open G"))
    // The fifth string first: g4, then D3 G3 B3 D4.
    #expect(banjo.presets[0].pitches == [67, 50, 55, 59, 62])
    #expect(banjo.presets.map(\.name).contains { $0.hasPrefix("Double C") })
    #expect(banjo.presets.map(\.name).contains { $0.hasPrefix("Sawmill") })
    #expect(banjo.defaultTransposition == 0)

    let ukulele = TabTemplate.template(id: "ukulele")!
    #expect(ukulele.presets[0].pitches == [67, 60, 64, 69], "high G first")
}

@Test func templatesFollowTheProgram() {
    #expect(TabTemplate.template(forProgram: 24)?.id == "guitar")
    #expect(TabTemplate.template(forProgram: 30)?.id == "guitar")
    #expect(TabTemplate.template(forProgram: 32)?.id == "bass")
    #expect(TabTemplate.template(forProgram: 33)?.id == "bass")
    #expect(TabTemplate.template(forProgram: 0) == nil)
    #expect(TabTemplate.template(forProgram: NoteEvent.drumProgram) == nil)
}

@Test func aSetupComesFromAPreset() {
    let guitar = TabTemplate.template(id: "guitar")!
    let dropD = guitar.presets.first { $0.name.hasPrefix("Drop D") }!
    let setup = guitar.setup(preset: dropD)
    #expect(setup.template == "guitar")
    #expect(setup.tuning == [38, 45, 50, 55, 59, 64])
    #expect(setup.presetName == dropD.name)
    #expect(setup.frets == 24)
    #expect(TuningPreset.label(for: [38, 45]) == "D A")
}
