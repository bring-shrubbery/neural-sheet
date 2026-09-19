import Testing

@testable import NeuralSheetCore

// MARK: - The inventory table (docs/superpowers/specs/2026-09-17-neuralnote-feature-inventory.md §4.1)

/// One row of the inventory's 35-group table, in the table's own display order.
private struct InventoryRow {
    let group: InstrumentGroup
    let id: Int32
    let name: String
    let chip: String
    let hex: UInt32
}

private let inventoryRows: [InventoryRow] = [
    .init(group: .acousticPiano, id: 0, name: "Piano", chip: "PNO", hex: 0x3372FF),
    .init(group: .electricPiano, id: 1, name: "Electric Piano", chip: "EPN", hex: 0x85A0FF),
    .init(group: .organ, id: 3, name: "Organ", chip: "ORG", hex: 0x1F5FC1),
    .init(group: .acousticGuitar, id: 4, name: "Acoustic Guitar", chip: "AGT", hex: 0x45D1A8),
    .init(group: .cleanElectricGuitar, id: 5, name: "Electric Guitar", chip: "GTR", hex: 0x7AEED6),
    .init(group: .distortedElectricGuitar, id: 6, name: "Distorted Guitar", chip: "DGT", hex: 0x388D6D),
    .init(group: .electricBass, id: 8, name: "Bass", chip: "BAS", hex: 0x9033FF),
    .init(group: .acousticBass, id: 7, name: "Acoustic Bass", chip: "ABS", hex: 0xC685FF),
    .init(group: .contrabass, id: 12, name: "Contrabass", chip: "CBS", hex: 0x5B1FC1),
    .init(group: .violin, id: 9, name: "Violin", chip: "VLN", hex: 0xF9295D),
    .init(group: .viola, id: 10, name: "Viola", chip: "VLA", hex: 0xFF4363),
    .init(group: .cello, id: 11, name: "Cello", chip: "VLC", hex: 0xEA175E),
    .init(group: .stringEnsemble, id: 15, name: "Strings", chip: "STR", hex: 0xFF6471),
    .init(group: .synthStrings, id: 16, name: "Synth Strings", chip: "SST", hex: 0xC11F63),
    .init(group: .orchestralHarp, id: 13, name: "Harp", chip: "HRP", hex: 0xFF8585),
    .init(group: .trumpet, id: 19, name: "Trumpet", chip: "TPT", hex: 0xFFC458),
    .init(group: .trombone, id: 20, name: "Trombone", chip: "TBN", hex: 0xE07F25),
    .init(group: .frenchHorn, id: 22, name: "French Horn", chip: "HRN", hex: 0xF2A33C),
    .init(group: .brassSection, id: 23, name: "Brass", chip: "BRS", hex: 0xFFDD81),
    .init(group: .tuba, id: 21, name: "Tuba", chip: "TBA", hex: 0xB46029),
    .init(group: .sopranoAndAltoSax, id: 24, name: "Alto Sax", chip: "ASX", hex: 0xFEAC85),
    .init(group: .tenorSax, id: 25, name: "Tenor Sax", chip: "TSX", hex: 0xE8704A),
    .init(group: .baritoneSax, id: 26, name: "Baritone Sax", chip: "BSX", hex: 0xAE4532),
    .init(group: .flutes, id: 31, name: "Flute", chip: "FLT", hex: 0xC3D94E),
    .init(group: .oboe, id: 27, name: "Oboe", chip: "OBO", hex: 0xC9E868),
    .init(group: .englishHorn, id: 28, name: "English Horn", chip: "EHN", hex: 0xD0F385),
    .init(group: .clarinet, id: 30, name: "Clarinet", chip: "CLR", hex: 0xBBC638),
    .init(group: .bassoon, id: 29, name: "Bassoon", chip: "BSN", hex: 0x9C9C39),
    .init(group: .voice, id: 17, name: "Voice", chip: "VOX", hex: 0x4BC1E7),
    .init(group: .synthLead, id: 32, name: "Synth Lead", chip: "LED", hex: 0x86D7FE),
    .init(group: .synthPad, id: 33, name: "Synth Pad", chip: "PAD", hex: 0x329BAE),
    .init(group: .drums, id: 36, name: "Drums", chip: "DRM", hex: 0x77869F),
    .init(group: .timpani, id: 14, name: "Timpani", chip: "TMP", hex: 0x949FB9),
    .init(group: .chromaticPercussion, id: 2, name: "Chromatic Perc.", chip: "CPR", hex: 0xB3B9D1),
    .init(group: .orchestraHit, id: 18, name: "Orchestra Hit", chip: "OHT", hex: 0x616F80),
]

/// `GROUP_REPRESENTATIVE[groupId]`, copied from muscriptor's generated table
/// `ThirdParty/muscriptor.cpp/cpp/src/instrument_groups.inc:18-25`, restricted to the 35 named
/// groups of `NAMED_GROUPS` (same file, lines 29-65). `Drums` is the one exception: `programFor`
/// (`cpp/src/instrument_groups.cpp:187-194`) short-circuits it to `DRUM_PROGRAM` (128) rather than
/// returning its representative 96.
private let muscriptorPrograms: [InstrumentGroup: Int] = [
    .acousticPiano: 0, .electricPiano: 2, .chromaticPercussion: 8, .organ: 16,
    .acousticGuitar: 24, .cleanElectricGuitar: 26, .distortedElectricGuitar: 29,
    .acousticBass: 32, .electricBass: 33, .violin: 40, .viola: 41, .cello: 42,
    .contrabass: 43, .orchestralHarp: 46, .timpani: 47, .stringEnsemble: 48,
    .synthStrings: 50, .voice: 52, .orchestraHit: 55, .trumpet: 56, .trombone: 57,
    .tuba: 58, .frenchHorn: 60, .brassSection: 61, .sopranoAndAltoSax: 64,
    .tenorSax: 66, .baritoneSax: 67, .oboe: 68, .englishHorn: 69, .bassoon: 70,
    .clarinet: 71, .flutes: 72, .synthLead: 80, .synthPad: 88, .drums: 128,
]

// MARK: - RGBA

@Test func rgbaFromHexSplitsChannels() {
    let colour = RGBA(hex: 0x3372FF)

    #expect(colour.r == 0x33 / 255.0)
    #expect(colour.g == 0x72 / 255.0)
    #expect(colour.b == 0xFF / 255.0)
    #expect(colour.a == 1.0)
}

@Test func rgbaFromHexTakesAlpha() {
    #expect(RGBA(hex: 0x000000, alpha: 0.25).a == 0.25)
}

@Test func rgbaHslMatchesKnownConversions() {
    func near(_ lhs: RGBA, _ r: Double, _ g: Double, _ b: Double) -> Bool {
        abs(lhs.r - r) < 1e-9 && abs(lhs.g - g) < 1e-9 && abs(lhs.b - b) < 1e-9 && lhs.a == 1.0
    }

    #expect(near(RGBA.hsl(h: 0, s: 1, l: 0.5), 1, 0, 0))
    #expect(near(RGBA.hsl(h: 1.0 / 3.0, s: 1, l: 0.5), 0, 1, 0))
    #expect(near(RGBA.hsl(h: 2.0 / 3.0, s: 1, l: 0.5), 0, 0, 1))
    // Zero saturation is a grey at the lightness, whatever the hue.
    #expect(near(RGBA.hsl(h: 0.42, s: 0, l: 0.62), 0.62, 0.62, 0.62))
}

// MARK: - InstrumentGroup

@Test func instrumentGroupRawValuesMatchInventory() {
    for row in inventoryRows {
        #expect(row.group.rawValue == row.id, "\(row.name) should have group id \(row.id)")
    }

    #expect(Set(inventoryRows.map(\.id)).count == 35)
    #expect(Set(InstrumentGroup.allCases.map(\.rawValue)).count == 35)
}

@Test func allCasesAreEveryGroupInNumericOrder() {
    #expect(InstrumentGroup.allCases.count == 35)
    #expect(Set(InstrumentGroup.allCases) == Set(inventoryRows.map(\.group)))

    let raws = InstrumentGroup.allCases.map(\.rawValue)
    #expect(raws == raws.sorted(), "allCases must be in enumerator (numeric) order")
    #expect(raws.first == 0)
    #expect(raws.last == 36)
}

// MARK: - Instruments

@Test func allHasThirtyFiveInfosInEnumeratorOrder() {
    #expect(Instruments.all.count == 35)
    #expect(Instruments.all.map(\.group) == InstrumentGroup.allCases.map { Optional($0) })
}

@Test func displayTableMatchesInventoryVerbatim() {
    for row in inventoryRows {
        let info = Instruments.all.first { $0.group == row.group }

        #expect(info?.name == row.name)
        #expect(info?.abbreviation == row.chip)
        #expect(info?.colour == RGBA(hex: row.hex), "\(row.name) colour should be \(row.hex)")
    }
}

@Test func allColoursAreDistinct() {
    #expect(Set(Instruments.all.map(\.colour)).count == 35)
}

@Test func programForMatchesMuscriptorTable() {
    for (group, program) in muscriptorPrograms {
        #expect(Instruments.program(for: group) == program)
    }

    // Spot checks against the generated table, cited by line:
    // instrument_groups.inc:19 — GROUP_REPRESENTATIVE[0] == 0 (acoustic_piano).
    #expect(Instruments.program(for: .acousticPiano) == 0)
    // instrument_groups.inc:19 — GROUP_REPRESENTATIVE[2] == 8 (chromatic_percussion, .inc:32).
    #expect(Instruments.program(for: .chromaticPercussion) == 8)
    // instrument_groups.inc:20 — GROUP_REPRESENTATIVE[16] == 50 (synth_strings, .inc:46).
    #expect(Instruments.program(for: .synthStrings) == 50)
    // instrument_groups.inc:21 — GROUP_REPRESENTATIVE[33] == 88 (synth_pad, .inc:63).
    #expect(Instruments.program(for: .synthPad) == 88)
    // instrument_groups.cpp:189-191 — programFor(Drums) returns DRUM_PROGRAM, not the group's own
    // representative 96 (GROUP_REPRESENTATIVE[36], .inc:22). The engine rewrites drum notes to 128,
    // so that is the program a NoteEvent carries (inventory §4).
    #expect(Instruments.program(for: .drums) == 128)
    #expect(Instruments.program(for: .drums) == NoteEvent.drumProgram)
}

@Test func groupForProgramInvertsProgramFor() {
    for group in InstrumentGroup.allCases {
        #expect(Instruments.group(forProgram: Instruments.program(for: group)) == group)
    }
}

@Test func groupForProgramIsNilOutsideNamedGroups() {
    // 1 and 3 represent no group at all; 97 and 100 represent unnamed singleton groups
    // (GROUP_REPRESENTATIVE[37] and [34]) which `instrumentGroupFor` rejects for having no name
    // (instrument_groups.cpp:167-180).
    #expect(Instruments.group(forProgram: 1) == nil)
    #expect(Instruments.group(forProgram: 3) == nil)
    #expect(Instruments.group(forProgram: 97) == nil)
    #expect(Instruments.group(forProgram: 100) == nil)
    #expect(Instruments.group(forProgram: -1) == nil)
    #expect(Instruments.group(forProgram: 129) == nil)
}

@Test func groupForProgramKeepsTheReferencesProgram96Quirk() {
    // instrument_groups.inc:22 puts 96 at index 36, which is Drums, so the reference maps program 96
    // back to Drums even though no note ever carries it (inventory §4).
    #expect(Instruments.group(forProgram: 96) == .drums)
}

@Test func infoForProgramNamesTheGroup() {
    let piano = Instruments.info(forProgram: 0)
    #expect(piano.group == .acousticPiano)
    #expect(piano.name == "Piano")
    #expect(piano.abbreviation == "PNO")
    #expect(piano.program == 0)

    let drums = Instruments.info(forProgram: NoteEvent.drumProgram)
    #expect(drums.group == .drums)
    #expect(drums.name == "Drums")
    #expect(drums.abbreviation == "DRM")
    #expect(drums.colour == RGBA(hex: 0x77869F))
}

@Test func infoForEveryNamedGroupProgramReturnsThatGroupsRow() {
    for row in inventoryRows {
        let info = Instruments.info(forProgram: Instruments.program(for: row.group))

        #expect(info.name == row.name)
        #expect(info.abbreviation == row.chip)
        #expect(info.group == row.group)
    }
}

@Test func infoForUnnamedProgramFallsBack() {
    let info = Instruments.info(forProgram: 100)

    #expect(info.group == nil)
    #expect(info.program == 100)
    #expect(info.name == "program_100")
    #expect(info.abbreviation == "100")
    #expect(info.colour == RGBA.hsl(h: 100.0 / 128.0, s: 0.22, l: 0.62))
}

@Test func fallbackHueSpinsFromProgramModulo128() {
    #expect(Instruments.info(forProgram: 1).colour == RGBA.hsl(h: 1.0 / 128.0, s: 0.22, l: 0.62))
    #expect(Instruments.info(forProgram: 127).colour == RGBA.hsl(h: 127.0 / 128.0, s: 0.22, l: 0.62))
    // Out of range, but the fallback still has to produce something stable rather than trap.
    #expect(Instruments.info(forProgram: 130).colour == RGBA.hsl(h: 2.0 / 128.0, s: 0.22, l: 0.62))
    #expect(Instruments.info(forProgram: 130).name == "program_130")
}
