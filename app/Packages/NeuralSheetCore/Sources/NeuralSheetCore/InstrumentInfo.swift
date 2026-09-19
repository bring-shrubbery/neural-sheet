/// A colour with straight (non-premultiplied) components in 0...1.
///
/// The instrument palette is a model-level fact — the sidebar chip, the fader fill and every note in
/// the piano roll read the same assignment — so it lives here rather than in a view layer, free of
/// any AppKit/SwiftUI type.
public struct RGBA: Equatable, Hashable, Codable, Sendable {
    public var r: Double
    public var g: Double
    public var b: Double
    public var a: Double

    public init(r: Double, g: Double, b: Double, a: Double = 1) {
        self.r = r
        self.g = g
        self.b = b
        self.a = a
    }

    /// From a `0xRRGGBB` literal, which is how the palette is written down.
    public init(hex: UInt32, alpha: Double = 1) {
        self.init(
            r: Double((hex >> 16) & 0xFF) / 255.0,
            g: Double((hex >> 8) & 0xFF) / 255.0,
            b: Double(hex & 0xFF) / 255.0,
            a: alpha)
    }

    /// HSL to RGB, matching `juce::Colour::fromHSL` so the fallback hues stay identical to v2's.
    ///
    /// - Parameters:
    ///   - h: Hue as a fraction of the circle; wraps rather than clamping.
    ///   - s: Saturation 0...1.
    ///   - l: Lightness 0...1.
    public static func hsl(h: Double, s: Double, l: Double) -> RGBA {
        let lightness = min(max(l, 0), 1)
        let saturation = min(max(s, 0), 1)

        guard saturation > 0 else {
            return RGBA(r: lightness, g: lightness, b: lightness)
        }

        let upper =
            lightness < 0.5
            ? lightness * (1 + saturation)
            : lightness + saturation - (lightness * saturation)
        let lower = 2 * lightness - upper

        func component(_ hue: Double) -> Double {
            let wrapped = hue - hue.rounded(.down)

            if wrapped < 1.0 / 6.0 { return lower + (upper - lower) * wrapped * 6 }
            if wrapped < 0.5 { return upper }
            if wrapped < 2.0 / 3.0 { return lower + (upper - lower) * (2.0 / 3.0 - wrapped) * 6 }

            return lower
        }

        return RGBA(r: component(h + 1.0 / 3.0), g: component(h), b: component(h - 1.0 / 3.0))
    }
}

/// The 35 named instrument groups of the model's MT3_FULL_PLUS grouping — what the user picks and
/// what a transcribed program maps back to.
///
/// Raw values are the library's own group ids (`NAMED_GROUPS` in
/// `ThirdParty/muscriptor.cpp/cpp/src/instrument_groups.inc`), not indices: the ids are not
/// contiguous (there is no 34 or 35 here, and Drums is 36), and they are what the conditioning rows
/// and the token mask are computed from, so they have to be carried verbatim. Declared in numeric
/// order, which is the order `allCases` and `Instruments.all` come out in.
public enum InstrumentGroup: Int32, CaseIterable, Codable, Sendable {
    case acousticPiano = 0
    case electricPiano = 1
    case chromaticPercussion = 2
    case organ = 3
    case acousticGuitar = 4
    case cleanElectricGuitar = 5
    case distortedElectricGuitar = 6
    case acousticBass = 7
    case electricBass = 8
    case violin = 9
    case viola = 10
    case cello = 11
    case contrabass = 12
    case orchestralHarp = 13
    case timpani = 14
    case stringEnsemble = 15
    case synthStrings = 16
    case voice = 17
    case orchestraHit = 18
    case trumpet = 19
    case trombone = 20
    case tuba = 21
    case frenchHorn = 22
    case brassSection = 23
    case sopranoAndAltoSax = 24
    case tenorSax = 25
    case baritoneSax = 26
    case oboe = 27
    case englishHorn = 28
    case bassoon = 29
    case clarinet = 30
    case flutes = 31
    case synthLead = 32
    case synthPad = 33
    case drums = 36
}

/// How one instrument is named, chipped and coloured in the UI.
///
/// `group` is nil for a program outside the named groups — the model can decode one but never picks
/// it — in which case the library's own `program_<n>` label stands in.
public struct InstrumentInfo: Equatable, Hashable, Sendable {
    public let group: InstrumentGroup?
    public let program: Int
    public let name: String
    public let abbreviation: String
    public let colour: RGBA

    public init(group: InstrumentGroup?, program: Int, name: String, abbreviation: String, colour: RGBA) {
        self.group = group
        self.program = program
        self.name = name
        self.abbreviation = abbreviation
        self.colour = colour
    }
}

/// The instrument table: group ids to programs (the library's), and programs to how they are shown.
public enum Instruments {
    /// Every named group's display row, in `InstrumentGroup` enumerator order.
    public static let all: [InstrumentInfo] = displays.map {
        InstrumentInfo(
            group: $0.group,
            program: program(for: $0.group),
            name: $0.name,
            abbreviation: $0.abbreviation,
            colour: RGBA(hex: $0.hex))
    }

    /// The only program the model emits for `group`.
    ///
    /// Copied from muscriptor's generated `GROUP_REPRESENTATIVE`
    /// (`ThirdParty/muscriptor.cpp/cpp/src/instrument_groups.inc`), with the same Drums
    /// short-circuit `msl::programFor` applies (`cpp/src/instrument_groups.cpp`): drums answer 128
    /// rather than their table entry 96, because the engine rewrites every drum note's program to
    /// 128.
    public static func program(for group: InstrumentGroup) -> Int {
        guard group != .drums else { return NoteEvent.drumProgram }

        return groupRepresentative[Int(group.rawValue)]
    }

    /// The group a program stands for, or nil if it stands for none the user can pick.
    ///
    /// Mirrors `msl::instrumentGroupFor`: the drum program answers Drums, any other program is
    /// looked up in the representative table, and a hit on a group with no name (the singleton
    /// groups 34, 35 and 37 upwards) answers nil.
    public static func group(forProgram p: Int) -> InstrumentGroup? {
        guard p != NoteEvent.drumProgram else { return .drums }
        guard let index = groupRepresentative.firstIndex(of: p) else { return nil }

        // Also nil for a representative of an unnamed group: InstrumentGroup enumerates exactly the
        // 35 named ids. Note 96 lands on Drums, which is the reference's own quirk — no note carries
        // program 96, since drums are rewritten to 128.
        return InstrumentGroup(rawValue: Int32(index))
    }

    /// How to show a program, named group or not.
    ///
    /// A program outside the named groups falls back to the library's `program_<n>` label, the
    /// program number as its chip, and a hue spun from `program % 128` — stable across runs and
    /// visibly not one of the palette's families.
    public static func info(forProgram p: Int) -> InstrumentInfo {
        if let group = group(forProgram: p), let display = displaysByGroup[group] {
            return InstrumentInfo(
                group: group,
                program: p,
                name: display.name,
                abbreviation: display.abbreviation,
                colour: RGBA(hex: display.hex))
        }

        return InstrumentInfo(
            group: nil,
            program: p,
            name: "program_\(p)",
            abbreviation: "\(p)",
            colour: RGBA.hsl(h: Double(((p % 128) + 128) % 128) / 128.0, s: 0.22, l: 0.62))
    }

    // MARK: - The tables

    private struct Display: Sendable {
        let group: InstrumentGroup
        let name: String
        let abbreviation: String
        let hex: UInt32
    }

    /// Names, chips and colours from the inventory's §4.1 table (itself v2's `InstrumentInfo.cpp`),
    /// re-sorted into enumerator order. Names are shortened where the group's own is longer than the
    /// strip can show: "Bass" is the electric one, the acoustic keeps its qualifier.
    ///
    /// Colours are per instrument rather than per sidebar position, so an instrument keeps its hue
    /// as a transcription streams in. They form families — keys blue, guitars green, bass purple,
    /// strings pink, brass orange, saxes red-orange, winds chartreuse, voice/synth cyan, percussion
    /// slate — and no two of the 35 are equal, which `allColoursAreDistinct` is what enforces now
    /// that there is no `static_assert`.
    private static let displays: [Display] = [
        Display(group: .acousticPiano, name: "Piano", abbreviation: "PNO", hex: 0x3372FF),
        Display(group: .electricPiano, name: "Electric Piano", abbreviation: "EPN", hex: 0x85A0FF),
        Display(group: .chromaticPercussion, name: "Chromatic Perc.", abbreviation: "CPR", hex: 0xB3B9D1),
        Display(group: .organ, name: "Organ", abbreviation: "ORG", hex: 0x1F5FC1),
        Display(group: .acousticGuitar, name: "Acoustic Guitar", abbreviation: "AGT", hex: 0x45D1A8),
        Display(group: .cleanElectricGuitar, name: "Electric Guitar", abbreviation: "GTR", hex: 0x7AEED6),
        Display(group: .distortedElectricGuitar, name: "Distorted Guitar", abbreviation: "DGT", hex: 0x388D6D),
        Display(group: .acousticBass, name: "Acoustic Bass", abbreviation: "ABS", hex: 0xC685FF),
        Display(group: .electricBass, name: "Bass", abbreviation: "BAS", hex: 0x9033FF),
        Display(group: .violin, name: "Violin", abbreviation: "VLN", hex: 0xF9295D),
        Display(group: .viola, name: "Viola", abbreviation: "VLA", hex: 0xFF4363),
        Display(group: .cello, name: "Cello", abbreviation: "VLC", hex: 0xEA175E),
        Display(group: .contrabass, name: "Contrabass", abbreviation: "CBS", hex: 0x5B1FC1),
        Display(group: .orchestralHarp, name: "Harp", abbreviation: "HRP", hex: 0xFF8585),
        Display(group: .timpani, name: "Timpani", abbreviation: "TMP", hex: 0x949FB9),
        Display(group: .stringEnsemble, name: "Strings", abbreviation: "STR", hex: 0xFF6471),
        Display(group: .synthStrings, name: "Synth Strings", abbreviation: "SST", hex: 0xC11F63),
        Display(group: .voice, name: "Voice", abbreviation: "VOX", hex: 0x4BC1E7),
        Display(group: .orchestraHit, name: "Orchestra Hit", abbreviation: "OHT", hex: 0x616F80),
        Display(group: .trumpet, name: "Trumpet", abbreviation: "TPT", hex: 0xFFC458),
        Display(group: .trombone, name: "Trombone", abbreviation: "TBN", hex: 0xE07F25),
        Display(group: .tuba, name: "Tuba", abbreviation: "TBA", hex: 0xB46029),
        Display(group: .frenchHorn, name: "French Horn", abbreviation: "HRN", hex: 0xF2A33C),
        Display(group: .brassSection, name: "Brass", abbreviation: "BRS", hex: 0xFFDD81),
        Display(group: .sopranoAndAltoSax, name: "Alto Sax", abbreviation: "ASX", hex: 0xFEAC85),
        Display(group: .tenorSax, name: "Tenor Sax", abbreviation: "TSX", hex: 0xE8704A),
        Display(group: .baritoneSax, name: "Baritone Sax", abbreviation: "BSX", hex: 0xAE4532),
        Display(group: .oboe, name: "Oboe", abbreviation: "OBO", hex: 0xC9E868),
        Display(group: .englishHorn, name: "English Horn", abbreviation: "EHN", hex: 0xD0F385),
        Display(group: .bassoon, name: "Bassoon", abbreviation: "BSN", hex: 0x9C9C39),
        Display(group: .clarinet, name: "Clarinet", abbreviation: "CLR", hex: 0xBBC638),
        Display(group: .flutes, name: "Flute", abbreviation: "FLT", hex: 0xC3D94E),
        Display(group: .synthLead, name: "Synth Lead", abbreviation: "LED", hex: 0x86D7FE),
        Display(group: .synthPad, name: "Synth Pad", abbreviation: "PAD", hex: 0x329BAE),
        Display(group: .drums, name: "Drums", abbreviation: "DRM", hex: 0x77869F),
    ]

    private static let displaysByGroup: [InstrumentGroup: Display] =
        Dictionary(uniqueKeysWithValues: displays.map { ($0.group, $0) })

    /// `GROUP_REPRESENTATIVE`, copied verbatim from muscriptor's generated
    /// `ThirdParty/muscriptor.cpp/cpp/src/instrument_groups.inc`: group id -> the group's first
    /// program, which is the only one the model ever emits for it. Indices 34, 35 and 37 upwards are
    /// the unnamed singleton groups, kept so the program -> group lookup rejects their programs the
    /// same way the reference does.
    private static let groupRepresentative: [Int] = [
        0, 2, 8, 16, 24, 26, 29, 32, 33, 40, 41, 42,
        43, 46, 47, 48, 50, 52, 55, 56, 57, 58, 60, 61,
        64, 66, 67, 68, 69, 70, 71, 72, 80, 88, 100, 101,
        96, 97, 98, 99, 102, 103, 104, 105, 106, 107, 108, 109,
        110, 111, 112, 113, 114, 115, 116, 117, 118, 119, 120, 121,
        122, 123, 124, 125, 126, 127,
    ]
}
