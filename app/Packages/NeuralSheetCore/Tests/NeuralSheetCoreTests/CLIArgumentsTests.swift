import Foundation
import Testing

@testable import NeuralSheetCore

// MARK: - Helpers

private func transcribe(_ arguments: [String]) throws -> CLITranscribeOptions {
    guard case let .success(.transcribe(options)) = CLIArguments.parse(["transcribe"] + arguments) else {
        Issue.record("not a transcribe command: \(arguments)")
        throw CLIError.noCommand
    }

    return options
}

private func failure(_ arguments: [String]) -> CLIError? {
    if case let .failure(error) = CLIArguments.parse(arguments) { return error }

    return nil
}

// MARK: - Commands

@Test func cliTopLevelCommands() {
    #expect(CLIArguments.parse(["--version"]) == .success(.version))
    #expect(CLIArguments.parse(["-v"]) == .success(.version))
    #expect(CLIArguments.parse(["models"]) == .success(.models))
    #expect(CLIArguments.parse(["--help"]) == .success(.help))
    #expect(CLIArguments.parse(["-h"]) == .success(.help))
    #expect(CLIArguments.parse(["help"]) == .success(.help))
    #expect(CLIArguments.parse(["transcribe", "--help"]) == .success(.help))
}

@Test func cliTopLevelErrors() {
    #expect(failure([]) == .noCommand)
    #expect(failure(["export"]) == .unknownCommand("export"))
    #expect(failure(["--frobnicate"]) == .unknownOption("--frobnicate"))
    #expect(failure(["models", "extra"]) == .unexpectedArgument("extra"))
    #expect(failure(["--version", "extra"]) == .unexpectedArgument("extra"))
    #expect(failure(["transcribe"]) == .noInputs)
    #expect(failure(["transcribe", "--midi"]) == .noInputs)
}

// MARK: - Transcribe

@Test func cliTranscribeDefaults() throws {
    let options = try transcribe(["a.wav"])

    #expect(options.inputs == ["a.wav"])
    #expect(options.model == nil)
    #expect(options.instruments.isEmpty)
    #expect(!options.stems)
    #expect(options.outputs == [.midi])
    #expect(!options.detect)
    #expect(options.outDirectory == nil)
    #expect(!options.replace)
    #expect(!options.quiet)
}

@Test func cliTranscribeEveryFlag() throws {
    let options = try transcribe([
        "a.mp3", "--model", "medium", "--instruments", "piano,electric_bass", "--stems", "--midi",
        "--musicxml", "--project", "--detect", "--out", "~/Desktop/out", "--replace", "--quiet", "b.wav",
    ])

    #expect(options.inputs == ["a.mp3", "b.wav"])
    #expect(options.model == .medium)
    #expect(options.instruments == [.acousticPiano, .electricBass])
    #expect(options.stems)
    #expect(options.outputs == [.midi, .musicXML, .project])
    #expect(options.detect)
    #expect(options.outDirectory == "~/Desktop/out")
    #expect(options.replace)
    #expect(options.quiet)
}

@Test func cliTranscribeOutputsWithoutMidi() throws {
    #expect(try transcribe(["a.wav", "--musicxml"]).outputs == [.musicXML])
    #expect(try transcribe(["a.wav", "--project"]).outputs == [.project])
}

@Test func cliTranscribeInlineValuesAndShortQuiet() throws {
    let options = try transcribe(["--model=small", "--instruments=all", "--out=/tmp/x", "-q", "a.wav"])

    #expect(options.model == .small)
    #expect(options.instruments == InstrumentGroup.allCases)
    #expect(options.outDirectory == "/tmp/x")
    #expect(options.quiet)
}

@Test func cliTranscribeDoubleDashEndsOptions() throws {
    let options = try transcribe(["--", "--odd-name.wav", "a.wav"])

    #expect(options.inputs == ["--odd-name.wav", "a.wav"])
}

@Test func cliTranscribeModels() throws {
    #expect(try transcribe(["a.wav", "--model", "small"]).model == .small)
    #expect(try transcribe(["a.wav", "--model", "LARGE"]).model == .large)
    #expect(failure(["transcribe", "a.wav", "--model", "huge"]) == .unknownModel("huge"))
    // The separation weights are a model, but not one to transcribe with.
    #expect(failure(["transcribe", "a.wav", "--model", "stems"]) == .unknownModel("stems"))
    #expect(failure(["transcribe", "a.wav", "--model"]) == .missingValue("--model"))
    #expect(failure(["transcribe", "a.wav", "--model", "--midi"]) == .missingValue("--model"))
}

@Test func cliTranscribeErrors() {
    #expect(failure(["transcribe", "a.wav", "--wat"]) == .unknownOption("--wat"))
    #expect(failure(["transcribe", "a.wav", "--out"]) == .missingValue("--out"))
    #expect(failure(["transcribe", "a.wav", "--instruments"]) == .missingValue("--instruments"))
    #expect(failure(["transcribe", "a.wav", "--instruments", ","]) == .missingValue("--instruments"))
    #expect(failure(["transcribe", "a.wav", "--instruments", "piano,kazoo"]) == .unknownInstrument("kazoo"))
    #expect(failure(["transcribe", "a.wav", "--stems=yes"]) == .unexpectedArgument("--stems=yes"))
}

// MARK: - Instruments

@Test func cliInstrumentNames() {
    #expect(InstrumentGroup.acousticPiano.cliName == "piano")
    #expect(InstrumentGroup.electricBass.cliName == "bass")
    #expect(InstrumentGroup.electricBass.cliAlias == "electric_bass")
    #expect(InstrumentGroup.chromaticPercussion.cliName == "chromatic_perc")
    #expect(InstrumentGroup.sopranoAndAltoSax.cliName == "alto_sax")
    #expect(InstrumentGroup.drums.cliName == "drums")

    #expect(InstrumentGroup(cliName: "Piano") == .acousticPiano)
    #expect(InstrumentGroup(cliName: "acoustic_piano") == .acousticPiano)
    #expect(InstrumentGroup(cliName: "electric_bass") == .electricBass)
    #expect(InstrumentGroup(cliName: "kazoo") == nil)
}

@Test func cliInstrumentNamesAreUnambiguous() {
    let names = InstrumentGroup.allCases.map(\.cliName)
    let aliases = InstrumentGroup.allCases.map(\.cliAlias)

    #expect(Set(names).count == names.count)
    #expect(Set(aliases).count == aliases.count)

    // Every name, display or alias, comes back to its own group.
    for group in InstrumentGroup.allCases {
        #expect(InstrumentGroup(cliName: group.cliName) == group)
        #expect(InstrumentGroup(cliName: group.cliAlias) == group)
    }
}

@Test func cliInstrumentListOrderAndAll() {
    #expect(CLIArguments.instruments("drums, piano,piano") == .success([.acousticPiano, .drums]))
    #expect(CLIArguments.instruments("all") == .success(InstrumentGroup.allCases))
    #expect(CLIArguments.instruments("ALL,piano") == .success(InstrumentGroup.allCases))
}

// MARK: - Usage and outputs

@Test func cliUsageNamesEveryFlagAndInstrument() {
    let usage = CLIArguments.usage

    for flag in ["--model", "--instruments", "--stems", "--midi", "--musicxml", "--project", "--detect",
                 "--out", "--replace", "--quiet", "models", "--version"] {
        #expect(usage.contains(flag))
    }

    for group in InstrumentGroup.allCases {
        #expect(usage.contains(group.cliName))
    }
}

@Test func transcriptionOutputNames() {
    let input = URL(fileURLWithPath: "/music/lessons/week 1.mp3")

    #expect(TranscriptionOutput.midi.url(for: input, in: nil).path == "/music/lessons/week 1.mid")
    #expect(TranscriptionOutput.musicXML.url(for: input, in: nil).path == "/music/lessons/week 1.musicxml")
    #expect(TranscriptionOutput.project.url(for: input, in: URL(fileURLWithPath: "/out")).path
                == "/out/week 1.neuralsheet")
}
