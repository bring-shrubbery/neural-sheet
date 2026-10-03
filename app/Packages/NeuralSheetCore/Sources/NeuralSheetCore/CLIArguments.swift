import Foundation

/// What a headless run writes for each input (batch and CLI design §2): a MIDI file, a MusicXML
/// score, a `.neuralsheet` project. The batch window, the `neuralsheet` tool and the Shortcuts
/// action all name their outputs with this.
public enum TranscriptionOutput: String, CaseIterable, Codable, Sendable {
    case midi
    case musicXML
    case project

    public var fileExtension: String {
        switch self {
        case .midi: "mid"
        case .musicXML: "musicxml"
        case .project: ProjectPackage.pathExtension
        }
    }

    /// `<input name>.<extension>` (issue #24 §3), in `directory` or, without one, beside the input.
    public func url(for input: URL, in directory: URL?) -> URL {
        let name = input.deletingPathExtension().lastPathComponent
        let folder = directory ?? input.deletingLastPathComponent()

        return folder.appendingPathComponent(name).appendingPathExtension(fileExtension)
    }
}

/// `neuralsheet transcribe`'s options, as parsed. Paths are kept as typed; the caller resolves
/// them against its working directory.
public struct CLITranscribeOptions: Equatable, Sendable {
    public var inputs: [String] = []
    /// Nil uses the model chosen in Settings, or whichever is installed.
    public var model: ModelSize?
    /// Empty is Automatic, the model choosing.
    public var instruments: [InstrumentGroup] = []
    public var stems = false
    /// Never empty after parsing: MIDI when no output flag was given.
    public var outputs: Set<TranscriptionOutput> = []
    public var detect = false
    public var outDirectory: String?
    public var replace = false
    public var quiet = false

    public init() {}
}

/// One invocation of the tool.
public enum CLICommand: Equatable, Sendable {
    case transcribe(CLITranscribeOptions)
    case models
    case version
    case help
}

/// A usage error: the tool prints ``message`` and the usage, and exits 2.
public enum CLIError: Error, Equatable, Sendable {
    case noCommand
    case unknownCommand(String)
    case unknownOption(String)
    case missingValue(String)
    case unknownModel(String)
    case unknownInstrument(String)
    case noInputs
    case unexpectedArgument(String)

    public var message: String {
        switch self {
        case .noCommand:
            "No command given."
        case let .unknownCommand(command):
            "Unknown command \"\(command)\"."
        case let .unknownOption(option):
            "Unknown option \"\(option)\"."
        case let .missingValue(option):
            "\(option) needs a value."
        case let .unknownModel(name):
            "Unknown model \"\(name)\". Use small, medium or large."
        case let .unknownInstrument(name):
            "Unknown instrument \"\(name)\". Run neuralsheet --help for the names."
        case .noInputs:
            "No input files given."
        case let .unexpectedArgument(argument):
            "Unexpected argument \"\(argument)\"."
        }
    }
}

/// The `neuralsheet` tool's command line (issue #24 §4), parsed without touching the file system.
public enum CLIArguments {
    /// The words `--instruments` takes besides the group names: every named group.
    public static let allInstruments = "all"

    /// Parses the arguments after the program name (and after `--headless`).
    public static func parse(_ arguments: [String]) -> Result<CLICommand, CLIError> {
        guard let first = arguments.first else { return .failure(.noCommand) }

        switch first {
        case "--version", "-v", "version":
            return arguments.count == 1 ? .success(.version) : .failure(.unexpectedArgument(arguments[1]))
        case "--help", "-h", "help":
            return .success(.help)
        case "models":
            return arguments.count == 1 ? .success(.models) : .failure(.unexpectedArgument(arguments[1]))
        case "transcribe":
            return parseTranscribe(Array(arguments.dropFirst()))
        default:
            return .failure(first.hasPrefix("-") ? .unknownOption(first) : .unknownCommand(first))
        }
    }

    private static func parseTranscribe(_ arguments: [String]) -> Result<CLICommand, CLIError> {
        var options = CLITranscribeOptions()
        var index = 0
        var optionsEnded = false

        while index < arguments.count {
            let argument = arguments[index]
            index += 1

            guard !optionsEnded, argument.hasPrefix("-"), argument != "-" else {
                options.inputs.append(argument)
                continue
            }

            // `--name=value` as well as `--name value`.
            let parts = argument.split(separator: "=", maxSplits: 1).map(String.init)
            let name = parts[0]
            var inlineValue = parts.count > 1 ? parts[1] : nil

            func value() -> String? {
                if let inline = inlineValue {
                    inlineValue = nil
                    return inline
                }

                guard index < arguments.count, !arguments[index].hasPrefix("--") else { return nil }

                defer { index += 1 }
                return arguments[index]
            }

            switch name {
            case "--":
                optionsEnded = true
            case "--model":
                guard let raw = value() else { return .failure(.missingValue(name)) }
                guard let size = ModelSize(rawValue: raw.lowercased()), ModelSize.transcription.contains(size) else {
                    return .failure(.unknownModel(raw))
                }
                options.model = size
            case "--instruments":
                guard let raw = value() else { return .failure(.missingValue(name)) }
                switch instruments(raw) {
                case let .success(groups): options.instruments = groups
                case let .failure(error): return .failure(error)
                }
            case "--out":
                guard let raw = value(), !raw.isEmpty else { return .failure(.missingValue(name)) }
                options.outDirectory = raw
            case "--stems": options.stems = true
            case "--midi": options.outputs.insert(.midi)
            case "--musicxml": options.outputs.insert(.musicXML)
            case "--project": options.outputs.insert(.project)
            case "--detect": options.detect = true
            case "--replace": options.replace = true
            case "--quiet", "-q": options.quiet = true
            case "--help", "-h": return .success(.help)
            default:
                return .failure(.unknownOption(argument))
            }

            if inlineValue != nil {
                // A flag given `=value` it does not take.
                return .failure(.unexpectedArgument(argument))
            }
        }

        guard !options.inputs.isEmpty else { return .failure(.noInputs) }

        if options.outputs.isEmpty {
            options.outputs = [.midi]
        }

        return .success(.transcribe(options))
    }

    /// A comma-separated list of group names, or `all`; enumerator order, repeats dropped.
    public static func instruments(_ list: String) -> Result<[InstrumentGroup], CLIError> {
        var chosen = Set<InstrumentGroup>()

        for word in list.split(separator: ",").map({ $0.trimmingCharacters(in: .whitespaces).lowercased() })
        where !word.isEmpty {
            if word == allInstruments {
                chosen.formUnion(InstrumentGroup.allCases)
            } else if let group = InstrumentGroup(cliName: word) {
                chosen.insert(group)
            } else {
                return .failure(.unknownInstrument(word))
            }
        }

        guard !chosen.isEmpty else { return .failure(.missingValue("--instruments")) }

        return .success(InstrumentGroup.allCases.filter(chosen.contains))
    }

    // MARK: - Usage

    /// What `--help` prints, and what follows a usage error.
    public static var usage: String {
        let names = InstrumentGroup.allCases.map(\.cliName).joined(separator: ", ")

        return """
            Usage:
              neuralsheet transcribe <input>… [options]
              neuralsheet models
              neuralsheet --version

            Transcribe options:
              --model small|medium|large   The model (default: the one chosen in Settings)
              --instruments <list>         Comma-separated instrument names, or all (default: automatic)
              --stems                      Separate drums, bass, vocals and the rest first
              --midi                       Write <input name>.mid (the default output)
              --musicxml                   Write <input name>.musicxml
              --project                    Write <input name>.neuralsheet
              --detect                     Detect the tempo, the key and the chords
              --out <dir>                  Write into <dir> (default: next to each input)
              --replace                    Overwrite existing files (default: skip them)
              --quiet                      No progress on stderr

            Instruments: \(names)

            Exit status: 0 when every input succeeded, 1 when any failed, 2 for a usage or setup error.
            """
    }
}

extension InstrumentGroup {
    /// The name the app shows, as one lower-case word: "Electric Piano" is `electric_piano`.
    public var cliName: String {
        Self.snakeCased(Instruments.info(forProgram: Instruments.program(for: self)).name)
    }

    /// The group's own name, `acoustic_piano` or `electric_bass`: accepted too, so a name read in the
    /// code or the model's documentation works as well as the one on screen.
    public var cliAlias: String {
        let camel = String(describing: self)
        var result = ""

        for character in camel {
            if character.isUppercase {
                result += "_"
            }
            result += character.lowercased()
        }

        return result
    }

    /// The group a command-line name stands for, matched without regard to case.
    public init?(cliName: String) {
        let name = cliName.lowercased()

        guard let group = InstrumentGroup.allCases.first(where: { $0.cliName == name || $0.cliAlias == name })
        else { return nil }

        self = group
    }

    private static func snakeCased(_ text: String) -> String {
        let words = text.lowercased().split { !$0.isLetter && !$0.isNumber }

        return words.joined(separator: "_")
    }
}
