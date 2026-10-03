import AppIntents
import NeuralSheetCore

/// The Shortcuts actions' choices (batch and CLI design §2). App Intents reads these at build time,
/// so the names are literals: the same the app shows.

/// Small, Medium or Large; the action's default (none chosen) is the model chosen in Settings.
nonisolated enum IntentModel: String, AppEnum {
    case small, medium, large

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Model"
    static let caseDisplayRepresentations: [IntentModel: DisplayRepresentation] = [
        .small: "Small",
        .medium: "Medium",
        .large: "Large",
    ]

    var size: ModelSize {
        switch self {
        case .small: .small
        case .medium: .medium
        case .large: .large
        }
    }
}

/// MIDI, MusicXML, a NeuralSheet project.
nonisolated enum IntentOutput: String, AppEnum {
    case midi, musicXML, project

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Output"
    static let caseDisplayRepresentations: [IntentOutput: DisplayRepresentation] = [
        .midi: "MIDI",
        .musicXML: "MusicXML",
        .project: "NeuralSheet Project",
    ]

    var output: TranscriptionOutput {
        switch self {
        case .midi: .midi
        case .musicXML: .musicXML
        case .project: .project
        }
    }
}

/// Every instrument group the model names, and All. None chosen is Automatic.
nonisolated enum IntentInstrument: String, AppEnum {
    case all
    case acousticPiano
    case electricPiano
    case chromaticPercussion
    case organ
    case acousticGuitar
    case cleanElectricGuitar
    case distortedElectricGuitar
    case acousticBass
    case electricBass
    case violin
    case viola
    case cello
    case contrabass
    case orchestralHarp
    case timpani
    case stringEnsemble
    case synthStrings
    case voice
    case orchestraHit
    case trumpet
    case trombone
    case tuba
    case frenchHorn
    case brassSection
    case sopranoAndAltoSax
    case tenorSax
    case baritoneSax
    case oboe
    case englishHorn
    case bassoon
    case clarinet
    case flutes
    case synthLead
    case synthPad
    case drums

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Instrument"
    static let caseDisplayRepresentations: [IntentInstrument: DisplayRepresentation] = [
        .all: "All Instruments",
        .acousticPiano: "Piano",
        .electricPiano: "Electric Piano",
        .chromaticPercussion: "Chromatic Perc.",
        .organ: "Organ",
        .acousticGuitar: "Acoustic Guitar",
        .cleanElectricGuitar: "Electric Guitar",
        .distortedElectricGuitar: "Distorted Guitar",
        .acousticBass: "Acoustic Bass",
        .electricBass: "Bass",
        .violin: "Violin",
        .viola: "Viola",
        .cello: "Cello",
        .contrabass: "Contrabass",
        .orchestralHarp: "Harp",
        .timpani: "Timpani",
        .stringEnsemble: "Strings",
        .synthStrings: "Synth Strings",
        .voice: "Voice",
        .orchestraHit: "Orchestra Hit",
        .trumpet: "Trumpet",
        .trombone: "Trombone",
        .tuba: "Tuba",
        .frenchHorn: "French Horn",
        .brassSection: "Brass",
        .sopranoAndAltoSax: "Alto Sax",
        .tenorSax: "Tenor Sax",
        .baritoneSax: "Baritone Sax",
        .oboe: "Oboe",
        .englishHorn: "English Horn",
        .bassoon: "Bassoon",
        .clarinet: "Clarinet",
        .flutes: "Flute",
        .synthLead: "Synth Lead",
        .synthPad: "Synth Pad",
        .drums: "Drums",
    ]

    /// The groups this choice stands for: every one for All.
    var groups: [InstrumentGroup] {
        guard self != .all else { return InstrumentGroup.allCases }

        return InstrumentGroup.allCases.filter { String(describing: $0) == rawValue }
    }

    /// A list of choices as the run's selection: enumerator order, repeats dropped.
    static func groups(_ choices: [IntentInstrument]) -> [InstrumentGroup] {
        let chosen = Set(choices.flatMap(\.groups))

        return InstrumentGroup.allCases.filter(chosen.contains)
    }
}
