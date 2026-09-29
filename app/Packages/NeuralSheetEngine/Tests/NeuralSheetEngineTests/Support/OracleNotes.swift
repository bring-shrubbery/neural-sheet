// The `notes_<variant>.json` dumps: the four variants of muscriptor.cpp's docs/TESTING.md,
// what they were run with, and how a run of the Swift engine is compared against one.
//
// Three suites make exactly this comparison -- the CPU transcriber, the Metal one and the
// medium checkpoint on both -- so the arguments, the parsing and the field-by-field
// expectations live here rather than three times over. The arguments are stated in Swift
// and checked against the dump's own `instruments` and `prelude_forcing`, so a fixture
// regenerated with a different selection fails instead of quietly moving the goalposts.

import Foundation
import Testing

@testable import NeuralSheetEngine

/// One of muscriptor.cpp's four test variants. The raw value is the dump's file-name stem.
enum OracleVariant: String, CaseIterable {
    case plain, prelude, bass, band

    /// The selection the oracle transcribed with, in the order it passed it: the engine
    /// sorts the conditioning rows downstream, but the dump's array is in this order and
    /// the prefix's length depends on the count, so both are part of what is compared.
    var instruments: [InstrumentGroup] {
        switch self {
        case .plain, .prelude: return []
        case .bass: return [.electricBass]
        case .band: return [.distortedElectricGuitar, .synthLead, .electricBass, .drums, .voice]
        }
    }

    /// `plain` is the only variant that decodes without the tie prologue forced; `prelude`
    /// is the default, i.e. what the app runs.
    var preludeForcing: Bool { self != .plain }
}

struct OracleNotes {
    /// One streamed update as the dump records it: the callback's contract, not its notes.
    struct Update {
        var finalizedThrough: Double
        var progress: Float
        var newNotes: Int
    }

    var instruments: [InstrumentGroup]
    var preludeForcing: Bool
    var notes: [Note]
    var updates: [Update]

    /// Reads a variant's dump from one oracle directory (`small-cpu`, `medium-metal`, …),
    /// or nil when the fixtures are not in the bundle, which is the same skip a missing
    /// checkpoint takes.
    static func load(_ variant: OracleVariant, from directory: String) -> OracleNotes? {
        guard let root = try? Fixtures.json("oracle/\(directory)/notes_\(variant.rawValue).json") as? [String: Any],
            let names = root["instruments"] as? [String],
            let preludeForcing = root["prelude_forcing"] as? Bool,
            let notes = root["notes"] as? [[String: Any]],
            let updates = root["updates"] as? [[String: Any]]
        else {
            return nil
        }

        let groups = names.compactMap { InstrumentGroups.group(forName: $0) }

        guard groups.count == names.count else { return nil }

        return OracleNotes(
            instruments: groups,
            preludeForcing: preludeForcing,
            notes: notes.map { note in
                Note(
                    onset: (note["onset"] as? NSNumber)?.doubleValue ?? .nan,
                    offset: (note["offset"] as? NSNumber)?.doubleValue ?? .nan,
                    pitch: (note["pitch"] as? NSNumber)?.intValue ?? -1,
                    program: (note["program"] as? NSNumber)?.intValue ?? -1,
                    isDrum: (note["is_drum"] as? NSNumber)?.boolValue ?? false)
            },
            // `progress` was printed from a C++ `float`, so it is read back as one:
            // widening the decimal to `Double` first and comparing there would fail on the
            // ninth digit for a reason that has nothing to do with the engine.
            updates: updates.map { update in
                Update(
                    finalizedThrough: (update["finalized_through"] as? NSNumber)?.doubleValue ?? .nan,
                    progress: (update["progress"] as? NSNumber)?.floatValue ?? .nan,
                    newNotes: (update["new_notes"] as? NSNumber)?.intValue ?? -1)
            })
    }

    /// Runs one variant through a transcriber the caller has loaded and compares both
    /// halves of what it produced, the notes and the shape of the updates. Returns the
    /// notes, or nil when the dump is not there and the test skips.
    @discardableResult
    static func expectVariant(
        _ variant: OracleVariant, through transcriber: Transcriber, samples: [Float],
        from directory: String
    ) throws -> [Note]? {
        guard let oracle = load(variant, from: directory) else { return nil }

        let label = "\(directory) \(variant.rawValue)"
        #expect(oracle.instruments == variant.instruments, "\(label): the dump's selection")
        #expect(oracle.preludeForcing == variant.preludeForcing, "\(label): the dump's prelude forcing")

        var updates: [TranscriptionUpdate] = []

        let notes = try transcriber.transcribe(
            samples: samples,
            options: TranscribeOptions(
                instruments: variant.instruments, preludeForcing: variant.preludeForcing)
        ) { update in
            updates.append(update)
            return true
        }

        oracle.expect(notes, label)
        oracle.expect(updates, label)
        return notes
    }

    /// Notes compare field by field rather than by `==`: the times are sums of a `double`
    /// tick count and a chunk offset, so they can land a rounding step from the dump's
    /// nine printed digits, while pitch, program and the drum flag are integers and must be
    /// identical.
    func expect(_ notes: [Note], _ label: String) {
        #expect(notes.count == self.notes.count, "\(label): note count")

        for (index, pair) in zip(notes, self.notes).enumerated() {
            let (got, want) = pair
            #expect(got.pitch == want.pitch, "\(label) note \(index): pitch")
            #expect(got.program == want.program, "\(label) note \(index): program")
            #expect(got.isDrum == want.isDrum, "\(label) note \(index): is_drum")
            #expect(
                abs(got.onset - want.onset) <= 1e-9,
                "\(label) note \(index): onset \(got.onset) / \(want.onset)")
            #expect(
                abs(got.offset - want.offset) <= 1e-9,
                "\(label) note \(index): offset \(got.offset) / \(want.offset)")
        }
    }

    /// The streaming contract the app draws the piano roll from: how far each call
    /// finalized, the progress it reported and how many notes it handed over. The notes
    /// themselves are compared by the result above; the dump only counts them.
    func expect(_ updates: [TranscriptionUpdate], _ label: String) {
        #expect(updates.count == self.updates.count, "\(label): update count")

        for (index, pair) in zip(updates, self.updates).enumerated() {
            let (got, want) = pair
            #expect(
                got.finalizedThrough == want.finalizedThrough,
                "\(label) update \(index): finalized_through")
            #expect(abs(got.progress - want.progress) <= 1e-6, "\(label) update \(index): progress")
            #expect(got.newNotes.count == want.newNotes, "\(label) update \(index): new_notes")
        }
    }
}
