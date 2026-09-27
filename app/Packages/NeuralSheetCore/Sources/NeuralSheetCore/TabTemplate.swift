import Foundation

/// One tuning of a template: the open pitches from the bottom tab line up.
public struct TuningPreset: Equatable, Sendable {
    public let name: String
    public let pitches: [Int]

    public init(_ name: String, _ pitches: [Int]) {
        self.name = name
        self.pitches = pitches
    }

    /// "E A D G B E".
    public var label: String { TuningPreset.label(for: pitches) }

    public static func label(for pitches: [Int]) -> String {
        pitches.map { MusicalKey.sharpNames[(($0 % 12) + 12) % 12] }.joined(separator: " ")
    }
}

/// A fretted instrument the tab can be written for (arrangement design §3.2): its strings, its
/// frets, its tunings, and the transposition its notation is customarily written at.
public struct TabTemplate: Equatable, Sendable, Identifiable {
    public let id: String
    public let name: String
    public let strings: Int
    public let frets: Int
    /// The first is the default.
    public let presets: [TuningPreset]
    /// What the notation staff is written at when this template is chosen for a part that has
    /// no transposition: guitar and bass music is written an octave above its sound.
    public let defaultTransposition: Int

    public func setup(preset: TuningPreset) -> TabSetup {
        TabSetup(template: id, tuning: preset.pitches, presetName: preset.name, frets: frets)
    }

    public static func template(id: String) -> TabTemplate? {
        all.first { $0.id == id }
    }

    /// The template a General MIDI program suggests: the guitars (24…31) and the basses
    /// (32…39); nothing for the rest.
    public static func template(forProgram program: Int) -> TabTemplate? {
        switch program {
        case 24...31: template(id: "guitar")
        case 32...39: template(id: "bass")
        default: nil
        }
    }

    // MIDI: C2 = 36, E2 = 40, A2 = 45, D3 = 50, G3 = 55, B3 = 59, E4 = 64.
    public static let all: [TabTemplate] = [
        TabTemplate(id: "guitar", name: "Guitar", strings: 6, frets: 24, presets: [
            TuningPreset("Standard (E A D G B E)", [40, 45, 50, 55, 59, 64]),
            TuningPreset("Drop D (D A D G B E)", [38, 45, 50, 55, 59, 64]),
            TuningPreset("Half-step down (E♭ A♭ D♭ G♭ B♭ E♭)", [39, 44, 49, 54, 58, 63]),
            TuningPreset("Whole-step down (D G C F A D)", [38, 43, 48, 53, 57, 62]),
            TuningPreset("DADGAD", [38, 45, 50, 55, 57, 62]),
            TuningPreset("Open G (D G D G B D)", [38, 43, 50, 55, 59, 62]),
            TuningPreset("Open D (D A D F♯ A D)", [38, 45, 50, 54, 57, 62]),
            TuningPreset("Open E (E B E G♯ B E)", [40, 47, 52, 56, 59, 64]),
        ], defaultTransposition: 12),
        TabTemplate(id: "guitar7", name: "Guitar (7-string)", strings: 7, frets: 24, presets: [
            TuningPreset("Standard (B E A D G B E)", [35, 40, 45, 50, 55, 59, 64]),
            TuningPreset("Drop A (A E A D G B E)", [33, 40, 45, 50, 55, 59, 64]),
        ], defaultTransposition: 12),
        TabTemplate(id: "bass", name: "Bass", strings: 4, frets: 24, presets: [
            TuningPreset("Standard (E A D G)", [28, 33, 38, 43]),
            TuningPreset("Drop D (D A D G)", [26, 33, 38, 43]),
            TuningPreset("Half-step down (E♭ A♭ D♭ G♭)", [27, 32, 37, 42]),
        ], defaultTransposition: 12),
        TabTemplate(id: "bass5", name: "Bass (5-string)", strings: 5, frets: 24, presets: [
            TuningPreset("Standard (B E A D G)", [23, 28, 33, 38, 43]),
            TuningPreset("Tenor (E A D G C)", [28, 33, 38, 43, 48]),
        ], defaultTransposition: 12),
        TabTemplate(id: "bass6", name: "Bass (6-string)", strings: 6, frets: 24, presets: [
            TuningPreset("Standard (B E A D G C)", [23, 28, 33, 38, 43, 48]),
        ], defaultTransposition: 12),
        // The fifth string is the bottom tab line, with its high pitch.
        TabTemplate(id: "banjo5", name: "Banjo (5-string)", strings: 5, frets: 22, presets: [
            TuningPreset("Open G (g D G B D)", [67, 50, 55, 59, 62]),
            TuningPreset("Double C (g C G C D)", [67, 48, 55, 60, 62]),
            TuningPreset("Sawmill (g D G C D)", [67, 50, 55, 60, 62]),
            TuningPreset("Open D (f♯ D F♯ A D)", [66, 50, 54, 57, 62]),
            TuningPreset("Drop C (g C G B D)", [67, 48, 55, 59, 62]),
        ], defaultTransposition: 0),
        TabTemplate(id: "banjoTenor", name: "Banjo (tenor)", strings: 4, frets: 19, presets: [
            TuningPreset("Standard (C G D A)", [48, 55, 62, 69]),
            TuningPreset("Irish (G D A E)", [43, 50, 57, 64]),
            TuningPreset("Chicago (D G B E)", [50, 55, 59, 64]),
        ], defaultTransposition: 0),
        TabTemplate(id: "banjoPlectrum", name: "Banjo (plectrum)", strings: 4, frets: 22, presets: [
            TuningPreset("Standard (C G B D)", [48, 55, 59, 62]),
        ], defaultTransposition: 0),
        TabTemplate(id: "mandolin", name: "Mandolin", strings: 4, frets: 20, presets: [
            TuningPreset("Standard (G D A E)", [55, 62, 69, 76]),
        ], defaultTransposition: 0),
        TabTemplate(id: "ukulele", name: "Ukulele", strings: 4, frets: 15, presets: [
            TuningPreset("Standard (g C E A, high G)", [67, 60, 64, 69]),
            TuningPreset("Low G (G C E A)", [55, 60, 64, 69]),
            TuningPreset("Baritone (D G B E)", [50, 55, 59, 64]),
        ], defaultTransposition: 0),
        TabTemplate(id: "lapSteel", name: "Lap steel", strings: 6, frets: 24, presets: [
            TuningPreset("C6 (C E G A C E)", [48, 52, 55, 57, 60, 64]),
            TuningPreset("Open E (E B E G♯ B E)", [40, 47, 52, 56, 59, 64]),
        ], defaultTransposition: 0),
    ]
}
