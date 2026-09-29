# Swift Transcription Engine Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the C++ `muscriptor.cpp` engine and its C bridge with a pure-Swift package, `NeuralSheetEngine`, that reads the same GGUF checkpoints, runs on Accelerate or Metal, reproduces the C++ engine's token streams and notes on its fixture, and builds for macOS and iOS.

**Architecture:** A local Swift package beside `NeuralSheetCore`. The integer logic (vocabulary, decode state machine, note assembly, instrument tables) is a direct port. A Swift GGUF reader memory-maps the checkpoint. The conditioning front-end (STFT, mel, projection) runs on the CPU in F32 with Accelerate. A `Model` assembles the prefix and drives greedy decoding through a `TransformerBackend` protocol with two implementations, CPU (Accelerate plus a `Float16` SIMD GEMV) and Metal (kernels compiled from a Swift string). `Transcriber` does the chunking, prelude forcing and streaming. The C++ library, still present until the last task, is dumped once into oracle fixtures the Swift tests compare against.

**Tech Stack:** Swift 6.2 toolchain in Swift 5 language mode, Swift Testing, Foundation, Accelerate (vDSP, vForce, vImage, cblas), Metal. No third-party dependencies.

**Spec:** `docs/design/2026-09-29-swift-engine-design.md`. The behavioural reference is the C++ under `app/ThirdParty/muscriptor.cpp/` (read-only; it is a submodule): `cpp/src/*.cpp`, `cpp/include/muscriptor/*.hpp` and `docs/{API,MODEL,TOKENIZER,TESTING}.md`. Every Swift file's header comment names the C++ file it ports.

## Global Constraints

- The package is `app/Packages/NeuralSheetEngine`, `swift-tools-version: 6.2`, `platforms: [.macOS(.v26), .iOS(.v26)]`, targets in `.swiftLanguageMode(.v5)`, no package dependencies, `Foundation`, `Accelerate` and `Metal` only.
- `cd app/Packages/NeuralSheetEngine && swift test` must pass and `swift build` must be warning-free. Tests that need a checkpoint skip (do not fail) when none is installed; no test downloads anything.
- Checkpoints are looked for at `$NEURALSHEET_MODELS`, then `~/Library/NeuralSheet/models`, then `~/Library/NeuralNote/models`; file names `muscriptor-small-f16.gguf`, `muscriptor-medium-f16.gguf`, `muscriptor-large-f16.gguf`. On this machine `small` and `medium` are under `~/Library/NeuralSheet/models` and `large` under `~/Library/NeuralNote/models`.
- The package prints nothing. No `print` outside `engine-bench`.
- Keep files under roughly 400 lines; split with the `+Extension.swift` pattern.
- Tests use Swift Testing (`import Testing`, `@Test`, `#expect`, `#require`), as `NeuralSheetCore` does. Skips are `try #require(...)` on a checkpoint URL, or an early `return` after `Issue.record` is **not** acceptable: use `guard let url = Checkpoints.url(for: .small) else { return }` with a comment that the test skips without weights, and keep such tests in files named `*OracleTests.swift` or `*CheckpointTests.swift` so the skip set is visible.
- All public types are `Sendable` where they are values; `Transcriber`, `Model` and the backends are classes, not thread-safe, documented as one call at a time.
- Commit after every task with a lowercase `area: what` message (`engine:` for the package, `app:` for the app target, `chore:` for scripts and the project file, `docs:`), a body explaining why when it is not obvious, ending with `Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>`. Never push.
- Do not edit `project.pbxproj` except for build settings and the package reference. Do not edit anything under `app/ThirdParty/`.
- `arch(arm64)` only: `Float16` is used without guards; the app is arm64 only.
- Tolerances in tests are the ones written in this plan. Never widen one to make a test pass; find the bug.
- Numbers, names and orders below are copied from the C++ and are exact.

---

## File structure

```
app/Packages/NeuralSheetEngine/
  Package.swift
  NOTICE
  Sources/NeuralSheetEngine/
    Transcriber.swift                 load, backendName, transcribe (chunk loop, streaming)
    Transcriber+Configure.swift       options validation, instrument rows, forbidden ids, chunk filling
    TranscribeOptions.swift           TranscribeOptions, LoadOptions, TranscriptionUpdate, TranscriberError
    Note.swift                        Note, InstrumentGroup, the public lookups
    Tokens/Vocabulary.swift
    Tokens/OpenNoteTracker.swift
    Tokens/NoteAssembler.swift
    Tokens/InstrumentGroups.swift
    Tokens/InstrumentGroupTable.swift
    GGUF/GGUFFile.swift
    GGUF/GGUFReader.swift             the byte cursor and value parsing
    GGUF/GGUFValue.swift
    GGUF/TensorInfo.swift
    Model/Hparams.swift
    Model/ModelWeights.swift
    Model/PositionTable.swift
    Model/Model.swift                 state, reset, prefill, decode
    Model/Model+Generate.swift        generate, logit mask
    Model/Model+Embeddings.swift      token / class embedding rows in F32, prefix assembly
    DSP/STFT.swift
    DSP/ConditioningFrontEnd.swift
    Backends/TransformerBackend.swift
    Backends/CPU/CPUBackend.swift
    Backends/CPU/CPUKernels.swift
    Backends/CPU/CPUMatmul.swift
    Backends/CPU/CPUAttention.swift
    Backends/Metal/MetalBackend.swift
    Backends/Metal/MetalBackend+Forward.swift
    Backends/Metal/MetalKernels.swift
    Backends/Metal/MetalShaderSource.swift
  Sources/engine-bench/main.swift
  Tests/NeuralSheetEngineTests/
    Fixtures/audio/fixture_3chunks_16k.wav, Fixtures/audio/README.md
    Fixtures/vectors/tables.json, Fixtures/vectors/note_vectors.json
    Fixtures/oracle/small-cpu/…, small-metal/…, medium-cpu/…, medium-metal/…
    Support/Checkpoints.swift
    Support/Fixtures.swift            Bundle.module lookups, .f32 and JSON readers, WAV reader
    Support/Compare.swift             cosine, maxAbs, argmax, near-tie counting
    VocabularyTests.swift, InstrumentGroupsTests.swift
    OpenNoteTrackerTests.swift, NoteAssemblerTests.swift
    GGUFFileTests.swift, GGUFCheckpointTests.swift
    PositionTableTests.swift, STFTTests.swift, ConditioningOracleTests.swift
    CPUKernelsTests.swift, CPUMatmulTests.swift, CPUAttentionTests.swift
    ModelOracleTests.swift, GenerateOracleTests.swift, TranscriberTests.swift, TranscriberOracleTests.swift
    MetalOracleTests.swift, MediumOracleTests.swift
app/Scripts/oracle/oracle.cpp, oracle.sh, README.md
app/NeuralSheet/Engine/TranscriptionEngine.swift        (rewritten over the package)
```

The tasks are grouped into waves. Tasks inside a wave touch disjoint files and may run in parallel (in separate worktrees, rebased onto `main` in task order); a wave starts when the previous one has landed.

---

## Wave 1

### Task 1: Package skeleton, vocabulary and instrument tables

**Files:**
- Create: `app/Packages/NeuralSheetEngine/Package.swift`, `NOTICE`
- Create: `Sources/NeuralSheetEngine/Note.swift`, `TranscribeOptions.swift`
- Create: `Sources/NeuralSheetEngine/Tokens/Vocabulary.swift`, `Tokens/InstrumentGroups.swift`, `Tokens/InstrumentGroupTable.swift`
- Create: `Tests/NeuralSheetEngineTests/Fixtures/vectors/tables.json` (copy of `app/ThirdParty/muscriptor.cpp/testdata/vectors/tables.json`), `Fixtures/vectors/note_vectors.json`, `Fixtures/audio/fixture_3chunks_16k.wav`, `Fixtures/audio/README.md` (copies)
- Create: `Tests/NeuralSheetEngineTests/Support/Fixtures.swift`, `VocabularyTests.swift`, `InstrumentGroupsTests.swift`
- Reference: `cpp/src/vocabulary.{hpp,cpp}`, `cpp/src/instrument_groups.{hpp,cpp,inc}`, `cpp/include/muscriptor/note.hpp`, `cpp/include/muscriptor/error.hpp`, `cpp/src/error.cpp`, `docs/TOKENIZER.md` §1, §4, §5

**Interfaces:**
- Produces (public):

```swift
public struct Note: Equatable, Hashable, Sendable {
    public var onset: Double
    public var offset: Double
    public var pitch: Int
    public var program: Int
    public var isDrum: Bool
    public init(onset: Double, offset: Double, pitch: Int, program: Int, isDrum: Bool)
    /// The program the reference assigns to drum hits (`DRUM_PROGRAM`).
    public static let drumProgram = 128
    /// `MINIMUM_NOTE_DURATION_SECONDS`.
    public static let minimumDuration = 0.01
}

/// Raw values are the reference's group ids; declared in id order so `allCases` is enumerator order.
public enum InstrumentGroup: Int32, CaseIterable, Hashable, Sendable {
    case acousticPiano = 0, electricPiano = 1, chromaticPercussion = 2, organ = 3, acousticGuitar = 4,
         cleanElectricGuitar = 5, distortedElectricGuitar = 6, acousticBass = 7, electricBass = 8,
         violin = 9, viola = 10, cello = 11, contrabass = 12, orchestralHarp = 13, timpani = 14,
         stringEnsemble = 15, synthStrings = 16, voice = 17, orchestraHit = 18, trumpet = 19,
         trombone = 20, tuba = 21, frenchHorn = 22, brassSection = 23, sopranoAndAltoSax = 24,
         tenorSax = 25, baritoneSax = 26, oboe = 27, englishHorn = 28, bassoon = 29, clarinet = 30,
         flutes = 31, synthLead = 32, synthPad = 33, drums = 36
    /// `instrumentGroupFor(program)`: nil for an unnamed group; 96 and 128 answer `.drums`.
    public init?(program: Int)
    /// `instrumentName`: "electric_bass".
    public var name: String
    /// `programFor`: the representative program; 128 for drums.
    public var program: Int
    /// `instrumentLabel`: the name, or "program_<n>".
    public static func label(forProgram program: Int) -> String
}

public struct TranscribeOptions: Sendable { public var instruments: [InstrumentGroup]; public var preludeForcing: Bool; public init(instruments: [InstrumentGroup] = [], preludeForcing: Bool = true) }
public struct LoadOptions: Sendable { public var useGPU: Bool; public init(useGPU: Bool = true) }
public struct TranscriptionUpdate: Sendable { public var newNotes: [Note]; public var finalizedThrough: Double; public var progress: Float }
public enum TranscriberError: Error, Equatable, Sendable, CustomStringConvertible {
    case fileNotFound(String)                       // "checkpoint file not found"
    case invalidCheckpoint(String)                  // "not a valid muscriptor GGUF checkpoint"
    case unsupportedArchitecture(String)            // "checkpoint architecture is not supported"
    case unsupportedCheckpointVersion(found: Int)   // "checkpoint format version is not the one this build reads"
    case outOfMemory                                // "out of memory"
    case contextOverflow                            // "a chunk did not fit in the model context"
    case cancelled                                  // "cancelled by the caller"
    case invalidArgument(String)                    // "invalid transcribe options"
    case internalError(String)                      // "internal error"
    /// The C++ `describe` string in the comments above, without the payload.
    public var description: String
}
```

- Produces (internal):

```swift
enum EventType: Int8 { case pad, eos, unk, shift, pitch, velocity, tie, program, drum }
struct TokenEvent: Equatable { var type: EventType; var value: Int32 }
struct NoteKey: Hashable, Comparable { var program: Int; var pitch: Int }   // < by (program, pitch)
enum Vocabulary {
    static let maxShiftSteps: Int32 = 1001
    static let padID: Int32 = 0, eosID: Int32 = 1, unkID: Int32 = 2
    static let shiftFirst: Int32 = 3, shiftCount = maxShiftSteps
    static let pitchFirst = shiftFirst + shiftCount, pitchCount: Int32 = 128
    static let velocityFirst = pitchFirst + pitchCount, velocityCount: Int32 = 2
    static let tieFirst = velocityFirst + velocityCount, tieCount: Int32 = 1
    static let programFirst = tieFirst + tieCount, programCount: Int32 = 130
    static let drumFirst = programFirst + programCount, drumCount: Int32 = 128
    static let numTokens = drumFirst + drumCount            // 1393
    static let frameRate = 100
    static func event(for tokenID: Int32) -> TokenEvent    // out of range → (.unk, 0)
    static func token(for type: EventType, value: Int32) -> Int32   // -1 when out of range
    static func tieSectionTokenIDs(openKeys: [NoteKey]) -> [Int32]
}
enum InstrumentGroups {
    static let numGroups = 66
    static let maxSelectable = 35
    static let nullConditioningRow: Int32 = 1
    static func representativeProgram(groupID: Int) -> Int          // -1 when out of range
    static func groupID(forProgram program: Int) -> Int?
    static func name(forGroupID groupID: Int) -> String?
    static func group(forName name: String) -> InstrumentGroup?
    static func conditioningRow(_ group: InstrumentGroup) -> Int32   // rawValue + 2
    static func conditioningRows(_ groups: [InstrumentGroup]) -> [Int32]   // [1] when empty
    /// Precondition: `groups` is non-empty (the reference forbids everything for an empty one).
    static func forbiddenTokenIDs(_ groups: [InstrumentGroup]) -> [Int32]
}
// InstrumentGroupTable.swift, transcribed from instrument_groups.inc:
enum InstrumentGroupTable {
    static let representative: [Int16]                 // 66 entries, group id → first program
    static let named: [(name: String, groupID: Int32)] // 35 entries, in the .inc's order
}
```

- Test support (`Support/Fixtures.swift`):

```swift
enum Fixtures {
    static func url(_ relativePath: String) -> URL   // Bundle.module.resourceURL / "Fixtures" / relativePath
    static func json(_ relativePath: String) throws -> Any          // JSONSerialization
    static func floats(_ relativePath: String) throws -> [Float]    // raw little-endian .f32
    static func fixtureAudio() throws -> [Float]                    // the WAV's float32 samples (see below)
}
```

The WAV is 16 kHz mono IEEE float32 (`fmt` chunk format 3). Read it by walking RIFF chunks: after the 12-byte header, each chunk is a 4-byte id, a 4-byte little-endian size, the payload padded to even length; take the `data` chunk and reinterpret as `Float`. 240 000 samples.

- [ ] **Step 1: Create the package and the fixtures**

`Package.swift`:

```swift
// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "NeuralSheetEngine",
    platforms: [.macOS(.v26), .iOS(.v26)],
    products: [
        .library(name: "NeuralSheetEngine", targets: ["NeuralSheetEngine"]),
        .executable(name: "engine-bench", targets: ["engine-bench"]),
    ],
    targets: [
        .target(name: "NeuralSheetEngine", swiftSettings: [.swiftLanguageMode(.v5)]),
        .executableTarget(name: "engine-bench", dependencies: ["NeuralSheetEngine"], swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(
            name: "NeuralSheetEngineTests", dependencies: ["NeuralSheetEngine"],
            resources: [.copy("Fixtures")], swiftSettings: [.swiftLanguageMode(.v5)]),
    ])
```

`Sources/engine-bench/main.swift` is a placeholder for now: `import NeuralSheetEngine` and `print("engine-bench: not yet implemented")` (Task 8 replaces it).

Copy the four fixture files from `app/ThirdParty/muscriptor.cpp/testdata/` with `cp` (do not symlink). Write `NOTICE`:

```
NeuralSheetEngine is a Swift port of muscriptor.cpp (https://github.com/DamRsn/muscriptor.cpp),
Copyright (c) 2026 Damien Ronssin, MIT License, which itself carries MuScriptor's MIT notice
(Copyright (c) Kyutai and Mirelo). The full texts are in ../../../THIRD_PARTY_NOTICES.md.

Tests/NeuralSheetEngineTests/Fixtures/audio/fixture_3chunks_16k.wav is an excerpt of
"You Drive Me Insane" by Jon Worthy and the Bends, CC BY 4.0; see the README beside it.
```

- [ ] **Step 2: Write the failing tests**

`VocabularyTests.swift`, reading `tables.json` (`vocab.ranges`, `vocab.spot_check`, `vocab.num_tokens`, `vocab.eos_id`, `tie_section_token_ids`):

```swift
@Test func rangesMatchTheReferenceTable() throws {
    let tables = try #require(try Fixtures.json("vectors/tables.json") as? [String: Any])
    let vocab = try #require(tables["vocab"] as? [String: Any])
    let ranges = try #require(vocab["ranges"] as? [String: [Int]])
    #expect(ranges["shift"] == [Int(Vocabulary.shiftFirst), Int(Vocabulary.shiftFirst + Vocabulary.shiftCount - 1)])
    #expect(ranges["pitch"] == [Int(Vocabulary.pitchFirst), Int(Vocabulary.pitchFirst + Vocabulary.pitchCount - 1)])
    #expect(ranges["velocity"] == [1132, 1133]); #expect(ranges["tie"] == [1134, 1134])
    #expect(ranges["program"] == [1135, 1264]); #expect(ranges["drum"] == [1265, 1392])
    #expect(vocab["num_tokens"] as? Int == Int(Vocabulary.numTokens))
    #expect(vocab["eos_id"] as? Int == Int(Vocabulary.eosID))
}
@Test func spotChecksDecode() // every [id, type, value] triple: Vocabulary.event(for:) == TokenEvent(type, value), mapping "PAD","EOS","UNK","shift","pitch","velocity","tie","program","drum" to EventType, and Vocabulary.token(for: type, value:) == id
@Test func outOfRangeIdsAreUnknown()  // -1 and 1393 → .unk; token(for: .pitch, value: 128) == -1
@Test func tieSectionsMatchTheReference() // each case in tie_section_token_ids: open_keys [[program, pitch]] → token_ids, order of the input must not matter
```

`InstrumentGroupsTests.swift`, reading `tables.json` (`instrument_groups.drum_program`, `instrument_groups.group_program_map` {"gid": [programs]}, `instrument_groups.named_groups` or whichever key holds the id→name map — read the JSON once and use the key names it has; `forbidden_token_ids` [{instruments: [names], token_ids}]):

```swift
@Test func everyGroupsRepresentativeIsItsFirstProgram()   // for each gid in group_program_map: representativeProgram(groupID:) == programs[0]; numGroups == map.count == 66
@Test func namesMatchTheTable()                            // for each named group: name(forGroupID:) == name; group(forName:) == InstrumentGroup(rawValue:); unnamed ids (34, 35, 37...) → nil
@Test func drumProgramIsTheReferences()                    // Note.drumProgram == drum_program == 128; InstrumentGroup(program: 128) == .drums; InstrumentGroup(program: 96) == .drums; InstrumentGroup(program: 100) == nil; InstrumentGroup.drums.program == 128; InstrumentGroup.electricBass.program == 33
@Test func forbiddenIdsMatchTheReference()                 // every case with non-empty instruments: forbiddenTokenIDs(groups by name) == token_ids (as sets and as sorted arrays)
@Test func conditioningRows()                              // [] → [1]; [.electricBass, .drums] → [10, 38]
@Test func allCasesAreInIdOrderAndCount35()
@Test func labels()                                        // label(forProgram: 33) == "electric_bass"; label(forProgram: 100) == "program_100"; label(forProgram: 128) == "drums"
```

- [ ] **Step 3: Run the tests to see them fail** — `swift test` fails to compile (types missing).

- [ ] **Step 4: Implement** — transcribe `vocabulary.cpp` (the `RANGES` table as a static array of `(type, first, count)`), `instrument_groups.cpp` and the `.inc` table verbatim (66 numbers, 35 names), `error.cpp`'s strings into `TranscriberError.description`, `note.hpp` into `Note.swift`. `InstrumentGroup.init?(program:)`: 128 → `.drums`; otherwise `groupID(forProgram:)` then `name(forGroupID:)` non-nil → `InstrumentGroup(rawValue:)`.

- [ ] **Step 5: Run the tests to see them pass** — `swift test 2>&1 | tail -20`; also `swift build 2>&1 | grep -c warning` is 0.

- [ ] **Step 6: Commit** — `engine: package skeleton, vocabulary and instrument tables`

### Task 2: The decode state machine and note assembly

**Files:**
- Create: `Sources/NeuralSheetEngine/Tokens/OpenNoteTracker.swift`, `Tokens/NoteAssembler.swift`
- Create: `Tests/NeuralSheetEngineTests/OpenNoteTrackerTests.swift`, `NoteAssemblerTests.swift`
- Reference: `cpp/src/open_note_tracker.{hpp,cpp}`, `cpp/src/note_assembler.{hpp,cpp}`, `cpp/tests/test_tracker.cpp`, `cpp/tests/test_note_assembly.cpp`, `cpp/tests/vectors.cpp` (how `note_vectors.json` is read), `docs/TOKENIZER.md` §3, §6, §7

**Interfaces:**
- Consumes: `Vocabulary`, `NoteKey`, `EventType`, `Note`, `InstrumentGroup`, `TranscriberError` from Task 1.
- Produces:

```swift
struct ChunkBoundary: Equatable { var seekTime: Double; var nextSeekTime: Double? }
enum NoteActionKind: Equatable { case start, end, drumHit }
struct NoteAction: Equatable { var kind: NoteActionKind; var program: Int; var pitch: Int; var time: Double }
struct OpenNoteTracker {
    init()
    mutating func reset()
    mutating func feed(boundary: ChunkBoundary) -> [NoteAction]
    mutating func feed(token: Int32) -> [NoteAction]
    mutating func finish() -> [NoteAction]
    var openKeys: [NoteKey]     // sorted by (program, pitch)
}
struct TrackedNote: Equatable { var note: Note; var chunkIndex: Int; var key: NoteKey }
struct NoteAssembler {
    init()
    mutating func reset()
    /// Throws `.internalError` on an end with nothing open.
    mutating func apply(_ actions: [NoteAction], chunkIndex: Int) throws
    func closedIn(chunkIndex: Int) -> [Note]
    func finalize() -> [Note]
    static func validate(_ notes: inout [Note])
    static func trimOverlapping(_ notes: [Note]) -> [Note]
    static func sort(_ notes: inout [Note])
}
```

The open-note list is an array in insertion order (never a dictionary): `finish()` closes in insertion order and the assembler's close order feeds a stable sort. `startTick = Int((seekTime * 100).rounded())` (llround). Times are `Double(tick) / 100`.

- [ ] **Step 1: Write the failing tests**

`note_vectors.json` is `{"provenance": …, "vectors": [ {name, description, seek_times: [Double], chunk_tokens: [[Int]], open_keys_at_boundary: [[[program, pitch]]], actions: [{kind: "start"|"end"|"drum_hit", program, pitch, time}], notes: [{onset, offset, pitch, program, is_drum}] } ]}`. Read `cpp/tests/vectors.cpp` to confirm the key names and the `drum_hit` spelling before writing the decoder. Boundaries: `seek_times[i]` with `nextSeekTime = seek_times[i+1]` and nil on the last.

```swift
@Test func everyVectorProducesTheReferenceActionStream()  // replay boundaries + tokens + finish; same count; per action kind, pitch, time within 1e-12; program compared except for drum hits
@Test func everyVectorProducesTheReferenceNoteList()       // replay through the assembler; finalize(); same count; pitch, program, isDrum equal; onset, offset within 1e-12
@Test func openKeysAtEachBoundaryMatchTheReference()       // after feed(boundary:) for chunk i, openKeys == open_keys_at_boundary[i] (as [NoteKey], sorted)
@Test func closedInMatchesFinalizePerChunk()               // for every vector: concatenating closedIn(chunkIndex:) over all chunks (after finish applied to the last) is a permutation of finalize()
@Test func anEndWithNothingOpenThrows()                    // apply([.end program 0 pitch 60 at 1.0]) throws .internalError
@Test func aRetriggerWidensToTenMilliseconds()             // tokens: tie, shift 50, program 0, velocity 1, pitch 60, velocity 1, pitch 60, shift 100, velocity 0, pitch 60 → two notes on pitch 60: [0.50, 0.51] and [0.50, 1.00]? Compute by hand from the rules and assert the exact list; note that trimming cuts the first to the second's onset (0.50) and drops it, so the result is one note [0.50, 1.00]. Assert exactly that.
@Test func aShiftBeforeTieClosesEverythingAndSkipsTheChunk() // chunk 0 opens (0, 60) at 0.5; chunk 1 begins with shift 10 (no tie) → end at 5.0; a later tie and pitch in chunk 1 are ignored
```

- [ ] **Step 2: Run to see them fail.**

- [ ] **Step 3: Implement** — a straight transcription of `open_note_tracker.cpp` and `note_assembler.cpp`. In `trimOverlapping`, the two-level ordering matters: group by `(program, pitch, isDrum)` with a **stable** sort of indices by channel, then inside each group a **stable** sort by onset alone, cut each offset to the next onset, drop `onset >= offset`, then a final sort by `(onset, isDrum, program, pitch, offset)` with `false < true` for `isDrum`. Swift's `sort` is not guaranteed stable: use `sorted` on `enumerated()` with the index as the last key, or `stableSorted` helper. The C++ `closedIn` validates and trims chunks `k` and `k+1` together, then filters back to `k`.

- [ ] **Step 4: Run to see them pass.**

- [ ] **Step 5: Commit** — `engine: decode state machine and note assembly`

---

## Wave 2

### Task 3: The oracle

**Files:**
- Create: `app/Scripts/oracle/oracle.cpp`, `app/Scripts/oracle/oracle.sh`, `app/Scripts/oracle/README.md`
- Create: `app/Packages/NeuralSheetEngine/Tests/NeuralSheetEngineTests/Fixtures/oracle/{small-cpu,small-metal,medium-cpu,medium-metal}/…`
- Reference: `cpp/include/muscriptor/{model,transcriber,stft,note}.hpp`, `app/Scripts/engine-smoke.sh` (how to build against the archives), `docs/TESTING.md` (the variants)

**Interfaces:**
- Produces the files of design §6, per `<size>-<backend>` directory:

| File | Format |
|---|---|
| `hparams.json` | `{"dim","n_head","head_dim","n_layer","ffn_dim","vocab_size","initial_token_id","logit_mask_start","layer_norm_eps","max_period","sample_rate","n_fft","hop_length","frame_rate","n_mels","log_eps","n_ctx","backend","checkpoint","muscriptor_cpp_commit"}` |
| `positions.f32` | rows 0…7 of `Model::positionEmbeddings()`, `[8][dim]` little-endian float32 |
| `stft.f32` | frames 0…7 of `model.stft().magnitudes(chunk0)`, `[8][1025]` |
| `cond.f32` | `model.encodeAudio(chunk0)`, `[501][dim]` |
| `prefill_logits.f32` | `model.reset(); model.prefill(cond, 501, {initial_token_id})`, `[vocab_size]` |
| `decode_steps.json` | `{"fed": [16 ints], "argmax": [16 ints]}`: step s feeds `fed[s]` (the argmax of the previous logits, starting from the prefill's) and records the argmax of the logits it returns |
| `decode_logits.f32` | the 16 steps' masked logits, `[16][vocab_size]` |
| `tokens.json` | `{"chunks": [[…], […], […]]}`: for each of the 3 chunks, `model.reset()`, `encodeAudio`, `model.generate(cond, 501, 2000, 1)` with default instrument rows and no forbidden ids, EOS included |
| `tokens_band.json` | `{"instruments": ["distorted_electric_guitar","synth_lead","electric_bass","drums","voice"], "chunk0": […]}`: `setInstrumentRows(conditioningRows)`, `setForbiddenTokens(forbiddenTokenIds)` (both from `instrument_groups.hpp`, internal header — add `cpp/src` to the include path), then `generate` on chunk 0 |
| `notes_plain.json`, `notes_prelude.json`, `notes_bass.json`, `notes_band.json` | `{"variant","instruments":[names],"prelude_forcing":bool,"notes":[{"onset","offset","pitch","program","is_drum"}],"updates":[{"finalized_through","progress","new_notes"}]}` from `Transcriber::transcribe` on the whole fixture: plain = no forcing, no selection; prelude = forcing; bass = forcing + `electric_bass`; band = forcing + the five above |

The `chunk0` above is the fixture's first 80 000 samples. Doubles are written with `%.17g`; floats in `.f32` are raw bytes. The `backend` names are `CPU` and `Metal`.

- [ ] **Step 1: Write `oracle.cpp`**

A single `main(argc, argv)`: `oracle <gguf> <cpu|gpu> <fixture.wav> <out-dir>`. Read the WAV as Task 1 describes (format 3, mono, 16 kHz; assert). Load `msl::Model::load(path, {.n_ctx = 2538, .use_gpu = gpu})` for the tensor dumps and `msl::Transcriber::load(path, {.use_gpu = gpu})` for the note variants. Use `nlohmann`-free hand-written JSON output (`std::ofstream` with `%.17g` for doubles). The CPU tensors (`positions`, `stft`, `cond`, `prefill_logits`, `decode_*`) are written for both backends (they are cheap); note in the README that the tests read tensors from the `-cpu` directories and tokens and notes from both.

- [ ] **Step 2: Write `oracle.sh`**

Mirrors `engine-smoke.sh`: runs `build-engine.sh`, compiles `oracle.cpp` with `clang++ -std=c++23 -O2 -I ThirdParty/muscriptor.cpp/cpp/include -I ThirdParty/muscriptor.cpp/cpp/src -L build/engine/lib -lmuscriptor_ggml -lggml -lggml-base -lggml-cpu -lggml-metal -lpffft -framework Metal -framework MetalKit -framework Accelerate -framework Foundation`, then runs it for `small` and `medium` on `cpu` and `gpu` into the four fixture directories, resolving checkpoints as the Global Constraints say. It records `git -C ThirdParty/muscriptor.cpp rev-parse HEAD` into `hparams.json` via an argument.

- [ ] **Step 3: Run it** — `app/Scripts/oracle/oracle.sh`. Expect four directories, `cond.f32` of 501×dim×4 bytes (1 539 072 for small, 2 052 096 for medium), three chunks of tokens each ending in 1, `notes_prelude.json` with a few hundred notes. Sanity-check: `tokens.json`'s chunk streams differ between `small` and `medium`; `notes_plain` and `notes_prelude` differ; every `bass` note has program 33; `band` notes only carry programs {29, 80, 33, 128, 52}. Check the CPU and Metal `tokens.json` are identical for both sizes; if they are not, record which chunks differ in the README (the Swift tests then compare against the backend they run on).

- [ ] **Step 4: Write the README** — what the files are, the command that made them, the muscriptor.cpp commit, and that regenerating needs a checkout of muscriptor.cpp at that commit under `app/ThirdParty/` plus `build/engine/lib` from `build-engine.sh`.

- [ ] **Step 5: Commit** — `chore: oracle dumps of the C++ engine for the Swift port's tests` (the `.f32` files are binary; commit them as they are).

### Task 4: The GGUF reader, hyperparameters and weights

**Files:**
- Create: `Sources/NeuralSheetEngine/GGUF/GGUFValue.swift`, `GGUF/GGUFReader.swift`, `GGUF/GGUFFile.swift`, `GGUF/TensorInfo.swift`
- Create: `Sources/NeuralSheetEngine/Model/Hparams.swift`, `Model/ModelWeights.swift`, `Model/PositionTable.swift`
- Create: `Tests/NeuralSheetEngineTests/Support/Checkpoints.swift`, `GGUFFileTests.swift`, `GGUFCheckpointTests.swift`, `PositionTableTests.swift`
- Reference: `cpp/src/gguf_file.{hpp,cpp}`, `cpp/src/model.cpp` (`Model::load`: the keys, the checks, `buildPositionTable`), the GGUF spec (https://github.com/ggml-org/ggml/blob/master/docs/gguf.md): magic `GGUF`, version 3, `uint64 n_tensors`, `uint64 n_kv`, KV pairs (string key, `uint32 type`, value), tensor infos (string name, `uint32 n_dims`, `uint64 ne[n_dims]`, `uint32 type`, `uint64 offset`), then the data section aligned to `general.alignment` (default 32) from the end of the tensor infos; tensor offsets are relative to the data section start. Value types: 0 uint8, 1 int8, 2 uint16, 3 int16, 4 uint32, 5 int32, 6 float32, 7 bool, 8 string (`uint64 len` + bytes), 9 array (`uint32 type`, `uint64 count`, values), 10 uint64, 11 int64, 12 float64. Tensor types: 0 F32, 1 F16.

**Interfaces:**
- Produces:

```swift
enum GGUFValue: Equatable { case uint8(UInt8), int8(Int8), uint16(UInt16), int16(Int16), uint32(UInt32), int32(Int32), float32(Float), bool(Bool), string(String), array([GGUFValue]), uint64(UInt64), int64(Int64), float64(Double) }
enum TensorDataType: UInt32 { case f32 = 0, f16 = 1; var byteSize: Int }
struct TensorInfo: Equatable {
    var name: String
    var shape: [Int]          // ggml `ne`: innermost first; a torch (out, in) matrix is [in, out]
    var dataType: TensorDataType
    var offset: Int           // from the data section start
    var elementCount: Int
    var byteCount: Int
}
final class GGUFFile {
    /// `.fileNotFound` when there is no regular file; `.invalidCheckpoint` when it is not a GGUF v2/v3 or is truncated.
    init(url: URL) throws
    let url: URL
    let metadata: [String: GGUFValue]
    let tensors: [String: TensorInfo]
    let tensorInfos: [TensorInfo]            // file order
    let alignment: Int
    let dataOffset: Int                      // absolute
    func has(_ key: String) -> Bool
    func int32(_ key: String) throws -> Int32    // .invalidCheckpoint when absent or another type
    func float32(_ key: String) throws -> Float
    func tensor(named name: String) throws -> TensorInfo   // .invalidCheckpoint naming the tensor
    /// Bytes of the tensor inside the mapping; valid while the file lives.
    func bytes(of tensor: TensorInfo) -> UnsafeRawBufferPointer
    /// The whole data section.
    var dataSection: UnsafeRawBufferPointer { get }
    /// F32 values of an F32 or F16 tensor (`tensorToFloat`).
    func floats(of tensor: TensorInfo) throws -> [Float]
}
struct Hparams: Equatable {
    var dim, nHead, headDim, nLayer, ffnDim, vocabSize, initialTokenID, logitMaskStart: Int
    var layerNormEps, maxPeriod: Float
    var sampleRate, nFFT, hopLength, frameRate, nMels: Int
    var logEps: Float
    var nFreq: Int { nFFT / 2 + 1 }
    static let formatVersion = 1
    /// Reads `muscriptor.format_version` first (absent counts as 0) → `.unsupportedCheckpointVersion(found:)`;
    /// then every key; `headDim * nHead != dim` → `.unsupportedArchitecture`.
    init(file: GGUFFile) throws
}
struct LayerWeights { var attnNormW, attnNormB, attnQKV, attnOut, ffnNormW, ffnNormB, ffnUp, ffnDown: TensorInfo }
struct ModelWeights {
    var tokenEmbd, output, outputNormW, outputNormB, melFB, stftWindow, projW, projB, instrumentGroup, datasetName: TensorInfo
    var layers: [LayerWeights]
    init(file: GGUFFile, hparams: Hparams) throws     // the names of MODEL.md's tensor map, `blk.<i>.<part>`
}
struct PositionTable {
    let count: Int, dim: Int
    let values: [Float]                                // [count][dim]
    /// `.unsupportedArchitecture` when dim is odd. cos half first, exponent i / (half - 1), phase = pos / maxPeriod^exponent, all in Float.
    init(count: Int, dim: Int, maxPeriod: Float) throws
    func rows(from start: Int, count n: Int) -> ArraySlice<Float>
}
```

Mapping: open with `open(2)`, `fstat`, `mmap(nil, size, PROT_READ, MAP_PRIVATE, fd, 0)`, close the descriptor, `munmap` in `deinit`. All parsing bounds-checked: a read past the end is `.invalidCheckpoint("truncated")`. Keys and strings are UTF-8.

- Test support (`Support/Checkpoints.swift`):

```swift
enum CheckpointSize: String { case small, medium, large; var fileName: String { "muscriptor-\(rawValue)-f16.gguf" } }
enum Checkpoints {
    /// `$NEURALSHEET_MODELS`, `~/Library/NeuralSheet/models`, `~/Library/NeuralNote/models`; nil when absent.
    static func url(for size: CheckpointSize) -> URL?
}
```

- [ ] **Step 1: Write the failing tests**

`GGUFFileTests.swift` writes a GGUF into a temporary file with a small helper (`GGUFWriter` in the test target: magic, version 3, counts, KV pairs of every type including a string array, two tensors, F32 `[4, 3]` and F16 `[8]`, alignment 32, data padded) and checks: every metadata value reads back equal; `tensorInfos` order and shapes; `bytes(of:)` of each tensor equals what was written; `floats(of:)` of the F16 tensor equals the source floats (use exactly representable values: 0.5, -1.25, 1024, …); `int32("missing")` throws `.invalidCheckpoint`; `int32` on a float key throws `.invalidCheckpoint`; a file that is not a GGUF (`"hello"`) throws `.invalidCheckpoint`; a path that does not exist throws `.fileNotFound`; a truncated file (cut in the tensor infos) throws `.invalidCheckpoint`. Also: a GGUF whose `muscriptor.format_version` is 2 makes `Hparams(file:)` throw `.unsupportedCheckpointVersion(found: 2)`, and one without the key `found: 0`; a GGUF with `head_count 12, head_dim 60, embedding_length 768` throws `.unsupportedArchitecture`.

`GGUFCheckpointTests.swift` (skips without `small`): the file has 122 tensors; `Hparams` equals `Hparams(dim: 768, nHead: 12, headDim: 64, nLayer: 14, ffnDim: 3072, vocabSize: 1393, initialTokenID: 1393, logitMaskStart: 1393, layerNormEps: 1e-5 (within 1e-9), maxPeriod: 10000, sampleRate: 16000, nFFT: 2048, hopLength: 160, frameRate: 100, nMels: 512, logEps: 1e-6 (within 1e-12))`; `ModelWeights` loads; `tokenEmbd.shape == [768, 1394]`, `.dataType == .f16`; `melFB.shape == [1025, 512]`, `.f32`; `stftWindow.shape == [2048]`; `floats(of: stftWindow)` has 2048 values in `0...1`, `[0] == 0`, and `[1024]` within 1e-3 of 1; `layers.count == 14`, `layers[3].attnQKV.shape == [768, 2304]`. And with `hparams.json` from `Fixtures/oracle/small-cpu` (Task 3; if the directory is absent the test still checks the literal values above): every field equal.

`PositionTableTests.swift`: `PositionTable(count: 8, dim: 768, maxPeriod: 10000)` against a `Double` evaluation, max-abs 1e-5; `dim: 7` throws; `positions.f32` from `small-cpu` (skip if the fixture dir is absent, but it will be present after Task 3 lands) equals the table's first 8 rows within 1e-6 absolute (both are Float evaluations of the same formula, so expect exact or near-exact).

- [ ] **Step 2: Run to see them fail.**
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run to see them pass**; `swift build` warning-free.
- [ ] **Step 5: Commit** — `engine: GGUF reader, hyperparameters, weights and the position table`

### Task 5: The STFT and the conditioning front-end

**Files:**
- Create: `Sources/NeuralSheetEngine/DSP/STFT.swift`, `DSP/ConditioningFrontEnd.swift`
- Create: `Tests/NeuralSheetEngineTests/STFTTests.swift`, `ConditioningOracleTests.swift`, `Support/Compare.swift`
- Reference: `cpp/src/stft.cpp`, `cpp/include/muscriptor/stft.hpp`, `cpp/src/model.cpp` (`encodeConditioning`), `docs/MODEL.md` ("Architecture details": reflect padding, last frame masked, magnitudes not powers)

**Interfaces:**
- Consumes: `GGUFFile`, `ModelWeights`, `Hparams` (Task 4) — for `ConditioningFrontEnd.init`. To build and test the STFT alone, nothing from Task 4 is needed; write the STFT first. If Task 4 has not landed in your worktree, write `ConditioningFrontEnd` against the interfaces in Task 4 above and note it in the report; the controller rebases.
- Produces:

```swift
struct STFT {
    let nFFT: Int, hopLength: Int
    let window: [Float]
    var nFreq: Int { nFFT / 2 + 1 }
    /// `.internalError` when nFFT is not a power of two ≥ 32, hop ≤ 0, or window.count != nFFT.
    init(nFFT: Int, hopLength: Int, window: [Float]) throws
    func frameCount(sampleCount: Int) -> Int                 // 1 + sampleCount / hopLength; 0 for negative
    /// Magnitudes [frameCount][nFreq] row-major. `.internalError` when sampleCount < nFFT/2 + 1.
    func magnitudes(_ samples: [Float]) throws -> [Float]
}
struct ConditioningFrontEnd {
    let hparams: Hparams
    let stft: STFT
    /// Loads `cond.stft_window` into the STFT, `cond.mel_fb.weight` as [nMels][nFreq], `cond.proj.weight` as [dim][nMels], `cond.proj.bias` as [dim], all F32.
    init(file: GGUFFile, weights: ModelWeights, hparams: Hparams) throws
    /// mel = fb · mag; logmel = log(mel + logEps); proj = W · logmel + b; rows i >= sampleCount / hopLength zeroed. [frameCount][dim].
    func encode(spectrum: [Float], frameCount: Int, sampleCount: Int) throws -> [Float]
    func encodeAudio(_ samples: [Float]) throws -> [Float]
}
```

STFT algorithm (port of `Stft::magnitudes`): pad `nFFT/2` each side by reflection excluding the edge sample (`padded[i] = x[pad - i]` for `i < pad`; `padded[pad + n + i] = x[n - 2 - i]`); for each frame multiply by the window and take a real FFT; `row[0] = |Re F(0)|`, `row[nFFT/2] = |Re F(N/2)|`, `row[k] = sqrt(re² + im²)`. Use `vDSP.FFT(log2n:radix:ofType:)` with `DSPSplitComplex`, `vDSP.ctoz` packing of the even/odd samples, `forward` transform; vDSP's real FFT returns DC in `real[0]`, Nyquist in `imag[0]`, and every value **scaled by 2** relative to the DFT — divide by 2. Reuse the setup and the scratch buffers across frames. Pin every one of these conventions with the tests below rather than by recollection.

Conditioning: `cblas_sgemm` twice in F32 (`mag [frames][1025] × fbᵀ` → `[frames][512]`; `logmel [frames][512] × Wᵀ` → `[frames][768]`), `vForce` `vvlogf` for the log, bias add, then zero rows `>= sampleCount / hopLength`.

- Test support (`Support/Compare.swift`):

```swift
enum Compare {
    static func maxAbsDifference(_ a: [Float], _ b: [Float]) -> Float
    static func cosine(_ a: [Float], _ b: [Float]) -> Double          // dot / (|a||b|) in Double
    static func scale(_ a: [Float]) -> Float                           // max |a|
    static func argmax(_ a: [Float]) -> Int
    /// The gap between the largest and second-largest value.
    static func topTwoMargin(_ a: [Float]) -> Float
}
```

- [ ] **Step 1: Write the failing tests**

`STFTTests.swift`:
- `frameCount`: 80 000 samples → 501; 0 → 1; -5 → 0.
- A naive DFT reference in the test (`Double` loops, `O(N²)`, on `nFFT = 64`, hop 16, a Hann window computed as `0.5 - 0.5 cos(2πi/N)`, a 300-sample random signal seeded with `SystemRandomNumberGenerator` replaced by a fixed LCG so the test is deterministic): the same reflect padding, magnitudes; compare all frames, max-abs within 1e-4 × scale.
- Reflect padding: a signal that is a ramp `x[i] = Float(i)` of 100 samples, `nFFT = 8`, hop 4, rectangular window: the first frame's DC equals `|Σ padded[0..<8]|` computed by hand from `x[4], x[3], x[2], x[1], x[0], x[1], x[2], x[3]` = 16.
- DC and Nyquist: a constant signal of 1.0 with a rectangular window: bin 0 = N, others 0 (within 1e-4); the alternating signal `(-1)^i`: bin N/2 = N, others 0.
- Too short throws `.internalError`; a bad window length throws.
- Against the oracle (skip if `Fixtures/oracle/small-cpu/stft.f32` is absent): load `small` (skip if absent) to get the window from `cond.stft_window` through `GGUFFile.floats(of:)`; STFT of the fixture's first 80 000 samples; the first 8 frames against `stft.f32`, max-abs within 1e-4 × `Compare.scale(oracle)`.

`ConditioningOracleTests.swift` (skips without `small` or the oracle): `encodeAudio(chunk0)` against `cond.f32`: max-abs within 1e-3 × scale, cosine above 0.99999; row 500 is all zeros; rows 0…499 are not.

- [ ] **Step 2: Run to see them fail.** — [ ] **Step 3: Implement.** — [ ] **Step 4: Run to see them pass.**
- [ ] **Step 5: Commit** — `engine: STFT and the conditioning front-end on Accelerate`

### Task 6: CPU kernels

**Files:**
- Create: `Sources/NeuralSheetEngine/Backends/CPU/CPUKernels.swift`, `CPU/CPUMatmul.swift`, `CPU/CPUAttention.swift`
- Create: `Tests/NeuralSheetEngineTests/CPUKernelsTests.swift`, `CPUMatmulTests.swift`, `CPUAttentionTests.swift`
- Reference: `cpp/src/model.cpp` (`buildEvalGraph`: the exact op order and shapes), ggml's `ggml_norm` (mean/variance over the row, `1/sqrt(var + eps)`, population variance), `ggml_gelu_erf` (`0.5 x (1 + erf(x/√2))`), `ggml_soft_max_ext` (scale then add mask then softmax over the row)

**Interfaces:**
- Consumes nothing from other tasks (kernels take raw pointers). Uses `Accelerate`.
- Produces (all `static`, all `nonisolated`, no allocation inside the hot loops beyond what is documented):

```swift
enum CPUKernels {
    /// out[r] = (x[r] - mean) / sqrt(var + eps) * weight + bias, per row of `dim`.
    static func layerNorm(_ x: UnsafePointer<Float>, rows: Int, dim: Int, weight: UnsafePointer<Float>, bias: UnsafePointer<Float>, eps: Float, out: UnsafeMutablePointer<Float>)
    /// x = 0.5 x (1 + erf(x / sqrt 2)), in place, using vForce `vverff`.
    static func geluErf(_ x: UnsafeMutablePointer<Float>, count: Int)
    /// y += x
    static func add(_ y: UnsafeMutablePointer<Float>, _ x: UnsafePointer<Float>, count: Int)
    /// Softmax over each row of `columns`, in place, after scaling by `scale` and adding `mask` (row-major [rows][columns], 0 or -inf). Rows of all -inf are not possible here (the diagonal is always allowed).
    static func softmaxRows(_ s: UnsafeMutablePointer<Float>, rows: Int, columns: Int, scale: Float, mask: UnsafePointer<Float>?)
    /// The performance-core count (`hw.perflevel0.logicalcpu`), else `ProcessInfo.activeProcessorCount`.
    static let threadCount: Int
}
enum CPUMatmul {
    /// out[r][o] = Σ_i W[o][i] · x[r][i], W row-major [outFeatures][inFeatures] F16 (a GGUF tensor with ne = [inFeatures, outFeatures]), x [rows][inFeatures] F32, out [rows][outFeatures] F32.
    /// rows == 1: `Float16` SIMD GEMV, F32 accumulation, output rows split across `concurrentPerform`.
    /// rows > 1: `vImageConvert_Planar16FtoPlanarF` of W into `scratch` (caller-provided, ≥ outFeatures·inFeatures floats), then `cblas_sgemm`.
    static func matmulF16(weights: UnsafePointer<Float16>, outFeatures: Int, inFeatures: Int, input: UnsafePointer<Float>, rows: Int, output: UnsafeMutablePointer<Float>, scratch: UnsafeMutablePointer<Float>)
    /// The F32 form, for tests and the conditioning path.
    static func matmulF32(weights: UnsafePointer<Float>, outFeatures: Int, inFeatures: Int, input: UnsafePointer<Float>, rows: Int, output: UnsafeMutablePointer<Float>)
}
enum CPUAttention {
    /// q: [nNew][dim] (head h at columns h·headDim ..< (h+1)·headDim); kCache, vCache: [nCtx][dim] with rows 0 ..< nPast + nNew filled;
    /// out: [nNew][dim]. Per head: scores [nNew][nKV] = q_h · K_hᵀ · scale, mask j > nPast + i to -inf, softmax, out_h = P · V_h.
    /// `scores` is caller scratch of nNew · nKV floats. Heads split across `concurrentPerform`.
    static func attend(q: UnsafePointer<Float>, kCache: UnsafePointer<Float>, vCache: UnsafePointer<Float>, nNew: Int, nPast: Int, nHead: Int, headDim: Int, scale: Float, scores: UnsafeMutablePointer<Float>, out: UnsafeMutablePointer<Float>)
}
```

GEMV detail: for each output row `o`, accumulate over `inFeatures` in blocks of 8: `SIMD8<Float>(SIMD8<Float16>(loaded)) * SIMD8<Float>(x)` into four independent `SIMD8<Float>` accumulators, then reduce. Load `SIMD8<Float16>` with `UnsafeRawPointer.loadUnaligned(fromByteOffset:as:)`. `inFeatures` is always a multiple of 32 here (768, 1024, 1536, 3072, 4096, 6144) but handle a scalar tail anyway. Chunk output rows in blocks of 16 per `concurrentPerform` iteration.

- [ ] **Step 1: Write the failing tests** — every kernel against a `Double` scalar reference on seeded pseudo-random data (a small LCG in the test file, `UInt64` state, `x = (x &* 6364136223846793005 &+ 1442695040888963407)`, values in -1…1):
  - `layerNorm`: rows 3, dim 64, random weight and bias, eps 1e-5, max-abs 1e-5.
  - `geluErf`: 1000 values in -6…6, max-abs 1e-6 against `0.5 x (1 + erf(x/√2))` with `Foundation.erf`; `gelu(0) == 0`; `gelu(3) ≈ 2.99595`; and it is **not** the tanh approximation: `gelu(-2.5)` vs the tanh form differs by more than 1e-4.
  - `softmaxRows`: rows 2, columns 7, scale 0.125, mask with -inf in the last three columns of row 0; each row sums to 1 within 1e-6, masked entries are exactly 0, values against the reference within 1e-6.
  - `matmulF16`: `outFeatures 48, inFeatures 96`, rows 1 and rows 5, F16 weights (random floats rounded through `Float16`), compare to `Double` accumulation of the F16-rounded weights, max-abs 1e-4 × scale; `inFeatures 100` (tail path) rows 1.
  - `matmulF32`: rows 3, 40×24.
  - `attend`: nHead 2, headDim 4, nPast 3, nNew 2 (nCtx ≥ 5), random q/K/V, scale 0.5, against a loop in `Double`; and with `nNew 1, nPast 0` (a single row attends only to itself: out == v row 0).
- [ ] **Step 2: Run to see them fail.** — [ ] **Step 3: Implement.** — [ ] **Step 4: Run to see them pass**, warning-free.
- [ ] **Step 5: Commit** — `engine: CPU kernels on Accelerate and Float16 SIMD`

---

## Wave 3

### Task 7: The backend protocol, the CPU backend and the model

**Files:**
- Create: `Sources/NeuralSheetEngine/Backends/TransformerBackend.swift`, `Backends/CPU/CPUBackend.swift`
- Create: `Sources/NeuralSheetEngine/Model/Model.swift`, `Model/Model+Embeddings.swift`, `Model/Model+Generate.swift`
- Create: `Tests/NeuralSheetEngineTests/ModelOracleTests.swift`, `GenerateOracleTests.swift`
- Reference: `cpp/src/model.cpp` (`Impl`, `buildEvalGraph`, `prefill`, `decode`, `generate`, `applyLogitMask`, `buildMask`, `fillPositions`, `reset`), `docs/MODEL.md`

**Interfaces:**
- Consumes: Tasks 4, 5, 6 as declared above; `InstrumentGroups.nullConditioningRow`.
- Produces:

```swift
protocol TransformerBackend: AnyObject {
    var name: String { get }                 // "CPU" or "Metal"
    var contextSize: Int { get }
    /// Zero the KV cache.
    func reset()
    /// input: the layer-0 activations [nNew][dim] (embeddings + positions). Appends this step's K and V at rows nPast ..< nPast + nNew,
    /// runs every layer, the output norm and the LM head on the last row. Returns raw logits [vocabSize].
    /// `.contextOverflow` when nPast + nNew > contextSize.
    func forward(input: [Float], nNew: Int, nPast: Int) throws -> [Float]
}
final class CPUBackend: TransformerBackend {
    /// Keeps `file` alive; weight pointers are into its mapping. Allocates K and V per layer ([nCtx][dim] F32 each) and the scratch buffers once.
    init(file: GGUFFile, hparams: Hparams, weights: ModelWeights, contextSize: Int) throws
}
final class Model {
    let hparams: Hparams
    let positions: PositionTable            // count = contextSize
    let backend: TransformerBackend
    var backendName: String { backend.name }
    var contextSize: Int { backend.contextSize }
    private(set) var nPast: Int
    private(set) var instrumentRows: [Int32]   // [1] by default
    var hasForbiddenTokens: Bool
    init(file: GGUFFile, hparams: Hparams, weights: ModelWeights, backend: TransformerBackend) throws
    /// Opens the file, reads hparams and weights, picks Metal (if useGPU and a device exists and `MetalBackend` is available) else CPU, contextSize = nCtx.
    static func load(url: URL, useGPU: Bool, contextSize: Int) throws -> Model
    func reset()                                          // nPast = 0, backend.reset()
    func setInstrumentRows(_ rows: [Int32])               // [] → [1]
    func setForbiddenTokens(_ ids: [Int32])               // [] clears; ids out of 0..<vocabSize ignored
    /// [cond, dataset row 1, instrument rows, tokens] + positions[nPast...]; returns masked logits. `.internalError` on a bad count or empty tokens.
    func prefill(conditioning: [Float], frameCount: Int, tokens: [Int32]) throws -> [Float]
    func decode(token: Int32) throws -> [Float]
    /// reset(); prefill([initialTokenID] + prompt); then argmax/decode until eosID or maxTokens tokens counting the prompt; returns prompt + generated (EOS included).
    func generate(conditioning: [Float], frameCount: Int, maxTokens: Int, eosID: Int32, prompt: [Int32] = []) throws -> [Int32]
}
```

`Model+Embeddings`: at init, convert `token_embd` (`[vocab+1][dim]`), `cond.dataset_name` (`[5][dim]`) and `cond.instrument_group` (`[1001][dim]`) to F32 arrays once (`GGUFFile.floats(of:)`); `embed(tokens:)` gathers rows. `Model.load` keeps `MetalBackend` behind a `static func makeMetalBackend(...) -> TransformerBackend?` hook in `Model` that Task 9 fills in; in this task it returns nil so `load` always answers CPU. `Model.load`'s `contextSize` default is the C++ `Transcriber`'s 2538 = 501 + 1 + 35 + 1 + 2000; `Transcriber` (Task 8) passes it explicitly.

`CPUBackend.forward`, per layer, with `x` as `[nNew][dim]`: `layerNorm → h`; `matmulF16(attnQKV, out 3·dim) → qkv [nNew][3·dim]`; copy `k = qkv[:, dim..<2dim]` and `v = qkv[:, 2dim..<3dim]` into the caches at rows `nPast...`; `attend(q: qkv[:, 0..<dim], …)` → `ctx [nNew][dim]`; `matmulF16(attnOut) → a`; `x += a`; `layerNorm → h2`; `matmulF16(ffnUp) → f [nNew][ffnDim]`; `geluErf(f)`; `matmulF16(ffnDown) → d`; `x += d`. Then `layerNorm(outputNorm)` on the last row only, `matmulF16(output, rows 1) → logits [vocabSize]`. The `q` slice is strided (row stride `3·dim`): either copy it out or give `attend` a `qStride` parameter — pick one and keep `CPUAttention`'s tests passing (extend them if you add the stride). `scale = 1 / sqrt(headDim)`. The scratch for `matmulF16`'s F32 conversion needs `max(3·dim·dim, ffnDim·dim, vocabSize·dim)` floats; allocate once at init.

- [ ] **Step 1: Write the failing tests** (both files skip without `small` and `Fixtures/oracle/small-cpu`):

`ModelOracleTests.swift`:
```swift
@Test func prefillLogitsMatchTheOracle()  // model = Model.load(small, useGPU: false, contextSize: 2538); cond = ConditioningFrontEnd.encodeAudio(chunk0); logits = model.prefill(cond, 501, [Int32(hparams.initialTokenID)]); oracle prefill_logits.f32: same argmax; Compare.cosine over indices < logitMaskStart > 0.999; logits[1393...] all -inf; model.nPast == 503
@Test func decodeStepsMatchTheOracle()    // after the prefill above, for s in 0..<16: logits = model.decode(token: fed[s]); argmax == oracle argmax[s] unless Compare.topTwoMargin(oracle row s) < 0.05 (count those, allow them, record the count with Issue.record? no — print nothing; just don't fail); cosine > 0.999 per step; nPast == 503 + s + 1
@Test func contextOverflowIsReported()    // Model.load(small, contextSize: 600); prefill of 503 rows OK; then 98 decodes; the 98th throws .contextOverflow (503 + 97 = 600 fits; 601 does not)
@Test func forbiddenTokensMaskTheLogits() // setForbiddenTokens([1135, 1136]); prefill; logits[1135] == -inf and logits[1136] == -inf; setForbiddenTokens([]) → finite again after reset+prefill
@Test func instrumentRowsChangeThePrefixLength()  // setInstrumentRows([10, 38]); prefill → nPast == 504
```

`GenerateOracleTests.swift`:
```swift
@Test func everyChunkGeneratesTheOracleTokens()  // for chunk in 0..<3: cond = encodeAudio(fixture chunk, zero-padded to 80000); tokens = model.generate(cond, 501, 2000, 1); compare to tokens.json chunks[chunk]: identical. (A mismatch is a bug unless the oracle's own decode_logits show a near-tie at that step, which only covers chunk 0's first 16 steps; treat any mismatch as a failure and investigate.)
@Test func bandSelectionGeneratesTheOracleTokens() // setInstrumentRows(conditioningRows(band)); setForbiddenTokens(forbiddenTokenIDs(band)); generate chunk 0 == tokens_band.json chunk0
@Test func aPromptIsReturnedFirst()               // generate(prompt: [1135, 1064, 1134]) on chunk 0: result starts with the prompt; result.count <= 2000
```

- [ ] **Step 2: Run to see them fail.** — [ ] **Step 3: Implement.** — [ ] **Step 4: Run to see them pass.** Expect `everyChunkGeneratesTheOracleTokens` to be the test that finds bugs; when it fails, compare `prefillLogitsMatchTheOracle` first, then the first decode step, and bisect inside `forward` by checking layer-0 outputs against a scalar re-implementation in a scratch test before touching tolerances.
- [ ] **Step 5: Commit** — `engine: the model over a CPU backend, matching the C++ engine's tokens`

---

## Wave 4

### Task 8: The transcriber and the benchmark

**Files:**
- Create: `Sources/NeuralSheetEngine/Transcriber.swift`, `Transcriber+Configure.swift`
- Replace: `Sources/engine-bench/main.swift`
- Create: `Tests/NeuralSheetEngineTests/TranscriberTests.swift`, `TranscriberOracleTests.swift`
- Reference: `cpp/src/transcriber.cpp`, `cpp/include/muscriptor/transcriber.hpp`, `docs/API.md`, `cpp/bench/bench.cpp`

**Interfaces:**
- Consumes: `Model`, `ConditioningFrontEnd`, `OpenNoteTracker`, `NoteAssembler`, `Vocabulary`, `InstrumentGroups`, the public value types.
- Produces (public):

```swift
public final class Transcriber {
    public static let sampleRate = 16_000
    public static let segmentSamples = 80_000
    public static let segmentDuration = 5.0
    public static let maxTokensPerChunk = 2000
    public static let checkpointFormatVersion = 1
    /// Blocking, seconds for a large model. Maps every failure to a `TranscriberError`.
    /// `.unsupportedArchitecture` unless sampleRate == 16000, frameRate == 100, hopLength == 160.
    public init(url: URL, options: LoadOptions = LoadOptions()) throws
    public var backendName: String { get }
    /// Blocking. One call at a time. `onUpdate` runs synchronously on the calling thread once per chunk and once at the end; return false to cancel (`.cancelled`).
    public func transcribe(samples: [Float], options: TranscribeOptions = TranscribeOptions(), onUpdate: ((TranscriptionUpdate) -> Bool)? = nil) throws -> [Note]
    public static func chunkCount(sampleCount: Int) -> Int
}
```

Port `Transcriber::Impl::transcribe` step for step: reset tracker and assembler first; configure (unique instruments keeping order; any group with no name → `.invalidArgument`; rows; forbidden ids only for a non-empty selection); per chunk fill 80 000 zero-padded; `encodeAudio`; boundary; `assembler.apply(tracker.feed(boundary:))`; prompt from `Vocabulary.tieSectionTokenIDs(openKeys)` when `chunk > 0 && preludeForcing`; `prefix = 501 + 1 + instrumentRows.count`, `budget = contextSize - prefix - 1`, `budget <= prompt.count → .contextOverflow`, `maxTokens = min(2000, budget)`; `generate`; feed tokens until EOS; the update with `closedIn(chunk - 1)` (empty on chunk 0), `finalizedThrough = chunk * 5`, `progress = (chunk+1)/n`; after the loop `apply(tracker.finish(), n-1)` and the final update with `closedIn(n-1)`, `finalizedThrough = n * 5`, `progress = 1`; `finalize()`. The `contextSize` passed to `Model.load` is `501 + 1 + 35 + 1 + 2000 = 2538`.

`engine-bench`: `engine-bench <gguf> [cpu|gpu] [wav]` (the wav defaults to the fixture path relative to the package: `Tests/NeuralSheetEngineTests/Fixtures/audio/fixture_3chunks_16k.wav` resolved from `#filePath`). Prints `backend`, `audio seconds`, `wall seconds`, `real-time factor`, `notes`, and per phase for chunk 0 through `Model` directly: `prefill ms`, `decode ms mean / p50 over 200 steps`, `conditioning ms`. Uses `ContinuousClock`.

- [ ] **Step 1: Write the failing tests**

`TranscriberTests.swift` (no weights): `chunkCount(sampleCount:)` 0 → 0, 1 → 1, 80 000 → 1, 80 001 → 2, 240 000 → 3; `TranscriberError.description` strings equal the C++ ones for all nine cases; `Transcriber(url: "/nonexistent")` throws `.fileNotFound`; `Transcriber(url: <the tables.json fixture>)` throws `.invalidCheckpoint`; a GGUF written in the test (reuse `GGUFWriter` from Task 4) with `format_version 2` throws `.unsupportedCheckpointVersion(found: 2)`.

`TranscriberOracleTests.swift` (skip without `small` + oracle; backend CPU via `LoadOptions(useGPU: false)`):
```swift
@Test func plainVariantMatches()   // preludeForcing false, no instruments → notes == notes_plain (count equal; per note pitch, program, isDrum equal, onset/offset within 1e-9); updates' finalized_through and progress sequences equal, and the new_notes counts equal
@Test func preludeVariantMatches() // default options → notes_prelude
@Test func bassVariantMatches()    // [.electricBass] → notes_bass; every note program 33
@Test func bandVariantMatches()    // the five → notes_band
@Test func streamedNotesConcatenateToTheResult() // prelude variant: the union of every update's newNotes, sorted with NoteAssembler.sort, == the returned notes
@Test func anEmptySignalGivesNoNotesAndNoCalls()
@Test func cancellationStopsAfterOneChunk()      // onUpdate returns false on its first call → throws .cancelled and the callback was called exactly once
@Test func anUnnamedGroupIsRejected()            // InstrumentGroup(rawValue: 36) is drums; there is no unnamed case in the enum, so instead cover: duplicates are collapsed ([.electricBass, .electricBass] behaves as [.electricBass] — same notes as bassVariantMatches)
@Test func backendNameIsCPU()
```

- [ ] **Step 2: Run to see them fail.** — [ ] **Step 3: Implement.** — [ ] **Step 4: Run to see them pass.** Then `swift run -c release engine-bench ~/Library/NeuralSheet/models/muscriptor-small-f16.gguf cpu` and record the numbers in the report.
- [ ] **Step 5: Commit** — `engine: the transcriber and a benchmark`

### Task 9: The Metal backend

**Files:**
- Create: `Sources/NeuralSheetEngine/Backends/Metal/MetalShaderSource.swift`, `Metal/MetalKernels.swift`, `Metal/MetalBackend.swift`, `Metal/MetalBackend+Forward.swift`
- Modify: `Sources/NeuralSheetEngine/Model/Model.swift` (`makeMetalBackend` returns a `MetalBackend` when `MTLCreateSystemDefaultDevice()` is non-nil)
- Create: `Tests/NeuralSheetEngineTests/MetalOracleTests.swift`
- Reference: Task 7's `CPUBackend.forward` (the op order is identical), `cpp/src/model.cpp`

**Interfaces:**
- Consumes: `TransformerBackend`, `GGUFFile`, `Hparams`, `ModelWeights`, `Model.load`'s hook.
- Produces:

```swift
final class MetalBackend: TransformerBackend {
    /// Compiles the shader library from `MetalShaderSource.source` (cached per process in a static), copies the GGUF data section into one shared MTLBuffer,
    /// allocates K/V caches ([nCtx][dim] F32 per layer), activation buffers sized for nNew up to contextSize, and the pipeline states.
    init(device: MTLDevice, file: GGUFFile, hparams: Hparams, weights: ModelWeights, contextSize: Int) throws
    var name: String { "Metal" }
}
enum MetalShaderSource { static let source: String }
```

Kernels (MSL, all F32 activations, F16 weights read with `half` and accumulated in `float`):

| Kernel | Grid | Does |
|---|---|---|
| `layer_norm` | one threadgroup per row, 256 threads | two-pass mean/variance in threadgroup memory, then `(x - mean) * rsqrt(var + eps) * w + b` |
| `matvec_f16` | one threadgroup of 32 threads (one simdgroup) per output row, rows == 1 | each lane sums a strided slice of `W[o][i] * x[i]`, `simd_sum` |
| `matmul_f16` | 2D grid over (outFeatures, rows), rows > 1 | one thread per output element, plain loop over `inFeatures` (prefill is ~500 rows; keep it simple, optimise later if the bench says so) |
| `copy_kv` | grid (dim, nNew) | copies k and v slices of qkv into the caches at row nPast + r |
| `attn_scores` | grid (nKV, nNew, nHead) | `s[h][i][j] = j <= nPast + i ? dot(q_h[i], K_h[j]) * scale : -inf` |
| `softmax_rows` | one threadgroup per (h, i) row over nKV | max, exp-sum, normalise in threadgroup memory |
| `attn_values` | grid (headDim, nNew, nHead) | `o[i][h·headDim + d] = Σ_j p[h][i][j] · V[j][h·headDim + d]` |
| `gelu_erf` | 1D | `0.5 x (1 + erf(x / sqrt(2)))` (MSL `erf`) |
| `add_inplace` | 1D | `y += x` |

`forward`: one `MTLCommandBuffer` per call, one compute encoder, every dispatch encoded in order, `commit`, `waitUntilCompleted`, then read the logits buffer (`storageModeShared`). Upload `input` with `memcpy` into the shared activation buffer. Check `commandBuffer.error` → `.internalError`. Buffers larger than the device's `maxBufferLength` → `.outOfMemory`.

- [ ] **Step 1: Write the failing tests** — `MetalOracleTests.swift` (skip when `MTLCreateSystemDefaultDevice()` is nil, without `small`, or without the oracle): the same five `ModelOracleTests` and three `GenerateOracleTests` cases with `Model.load(small, useGPU: true, contextSize: 2538)` asserting `model.backendName == "Metal"`, reading `Fixtures/oracle/small-metal/` for tokens and `small-cpu` for tensors; plus `cpuAndMetalLogitsAgree`: the prefill logits from both backends, cosine > 0.9999, same argmax; and the four `TranscriberOracleTests` variants with `LoadOptions(useGPU: true)` against `small-metal` notes. Also a pure test: `MetalShaderSource.source` compiles (`device.makeLibrary(source:options:)` throws nothing) and has every function name in the table above.
- [ ] **Step 2: Run to see them fail.** — [ ] **Step 3: Implement.** Debug by comparing against `CPUBackend` on the same input: both implement the same protocol, so a scratch test can run one layer's worth of each and diff. — [ ] **Step 4: Run to see them pass.** Then `swift run -c release engine-bench <small> gpu` and `<medium> gpu`; record the numbers.
- [ ] **Step 5: Commit** — `engine: Metal backend`

---

## Wave 5

### Task 10: The medium checkpoint tests and the numbers

**Files:**
- Create: `Tests/NeuralSheetEngineTests/MediumOracleTests.swift`
- Modify: `app/Scripts/oracle/README.md` (append the benchmark table)

**Interfaces:** consumes everything public and `Model`.

- [ ] **Step 1: Write the tests** (skip without `medium` or its oracle dirs): `tokens.json` per chunk on CPU against `medium-cpu`; on Metal against `medium-metal` (skip without a device); `notes_prelude.json` on both. Tag them `.tags(.slow)` with a `Tag` extension in `Support/`.
- [ ] **Step 2: Run** `swift test --filter MediumOracleTests` (minutes). They must pass; a mismatch is a bug in a kernel's numerics at the larger dim — investigate as Task 7 says.
- [ ] **Step 3: Bench** `swift run -c release engine-bench` for small and medium on cpu and gpu; append a table (backend, size, RTF, prefill ms, decode ms mean/p50) to `app/Scripts/oracle/README.md` with the machine name.
- [ ] **Step 4: Commit** — `engine: medium checkpoint tests and benchmark numbers`

### Task 11: The app over the Swift engine; the C++ engine goes

**Files:**
- Modify: `app/NeuralSheet.xcodeproj/project.pbxproj` — add `XCLocalSwiftPackageReference "Packages/NeuralSheetEngine"` and an `XCSwiftPackageProductDependency` for `NeuralSheetEngine` wired like `NeuralSheetCore`'s (three places: `PBXBuildFile`, `PBXFrameworksBuildPhase.files`, `PBXNativeTarget.packageProductDependencies`, plus `PBXProject.packageReferences`); remove `-lmuscriptor_ggml -lggml -lggml-base -lggml-cpu -lggml-metal -lpffft` and `-framework MetalKit` from both `OTHER_LDFLAGS`; remove `$(SRCROOT)/ThirdParty/muscriptor.cpp/cpp/include` from both `HEADER_SEARCH_PATHS`. Keep `-ldemucs`, Metal, Accelerate, Foundation and the demucs include paths.
- Rewrite: `app/NeuralSheet/Engine/TranscriptionEngine.swift`
- Modify: `app/NeuralSheet/NeuralSheet-Bridging-Header.h` (drop `Engine/nsheet_engine.h`), `app/NeuralSheet/App/AppModel+Transcription.swift` (`failureReason`)
- Delete: `app/NeuralSheet/Engine/nsheet_engine.h`, `nsheet_engine.cpp`, `app/Scripts/engine-smoke.sh`, `app/Scripts/engine_smoke.cpp`
- Modify: `app/Scripts/build-engine.sh` — only demucs: drop the muscriptor CMake configure/build, the archive copy loop and the muscriptor stamp half; the stamp is the demucs commit alone; the missing-submodule check names demucs only.
- Modify: `.gitmodules` (remove the muscriptor entry), `git rm app/ThirdParty/muscriptor.cpp` (and `rm -rf .git/modules/ThirdParty/muscriptor.cpp` after), `.github/workflows/ci.yml` (nothing to change: the cache key hashes `.gitmodules` and the script; confirm)
- Grep: `grep -rn "nsheet_engine\|muscriptor" app/NeuralSheet app/Scripts .github README.md CLAUDE.md docs/release.md` and fix every hit except `app/Scripts/oracle/*` and `ModelManifest.swift` (the download repository is still `DamRsn/muscriptor-gguf`).

**Interfaces:**
- Consumes: `Transcriber`, `TranscribeOptions`, `LoadOptions`, `TranscriptionUpdate`, `Note`, `InstrumentGroup`, `TranscriberError`.
- Produces (app):

```swift
nonisolated struct EngineNote: Equatable, Sendable { var onset: Double; var offset: Double; var pitch: Int; var program: Int; var isDrum: Bool }   // unchanged
nonisolated struct EngineUpdate: Sendable { var newNotes: [EngineNote]; var finalizedThrough: Double; var progress: Float }                        // unchanged
nonisolated enum EngineError: Error {
    case load(TranscriberError)
    case transcribe(TranscriberError)
    case cancelled
    var isUnsupportedVersion: Bool   // true for .load(.unsupportedCheckpointVersion) or .transcribe(...)
    var message: String              // the TranscriberError's description; "" for cancelled
}
nonisolated final class TranscriptionEngine: @unchecked Sendable {
    var isRunning: Bool
    func run(modelPath: URL, groups: [Int32], samples16k: [Float], onUpdate: @escaping @Sendable (EngineUpdate) -> Bool, completion: @escaping @Sendable (Result<[EngineNote], EngineError>) -> Void)   // same thread model as today
    func cancel()
    static func allGroups() -> [Int32]              // InstrumentGroup.allCases.map(\.rawValue)
    static func program(for group: Int32) -> Int32  // InstrumentGroup(rawValue:)?.program ?? -1
}
```

`run` on its thread: `Transcriber(url: modelPath, options: LoadOptions(useGPU: true))` (a throw → `.load(error)`), `groups.compactMap(InstrumentGroup.init(rawValue:))` (an unknown raw value → `.transcribe(.invalidArgument("…"))` before loading), `transcribe(samples:options:onUpdate:)` where `onUpdate` converts the update and returns `handler(update) && !isCancelled`; `.cancelled` → `.cancelled`; another throw → `.transcribe(error)`. `failureReason` in `AppModel+Transcription.swift` switches on `.load(let e), .transcribe(let e)` → `e.description`. The `run`-while-running assertion path reports `.transcribe(.invalidArgument("a run is already in flight"))`.

- [ ] **Step 1: Make the changes above.**
- [ ] **Step 2: Build** — `cd app && touch NeuralSheet/Engine/*.swift NeuralSheet/App/AppModel+Transcription.swift && xcodebuild -project NeuralSheet.xcodeproj -scheme NeuralSheet -configuration Debug -destination 'platform=macOS,arch=arm64' build 2>&1 | grep -E "warning:|error:|BUILD"` → only `BUILD SUCCEEDED` (the `appintentsmetadataprocessor` line is not ours). `cd app/Packages/NeuralSheetCore && swift test` still passes. `rm -rf app/build/engine && app/Scripts/build-engine.sh` builds demucs alone.
- [ ] **Step 3: Run the app once** with `open app/build/.../NeuralSheet.app` is not possible from the shell without permissions (memory: no screenshots); instead prove the path with a tiny Swift script or the bench: `swift run -c release engine-bench <small> gpu` already covers load + transcribe; for the app wiring, add a unit-free check: `grep -n "Transcriber(" app/NeuralSheet/Engine/TranscriptionEngine.swift`. The maintainer runs the app.
- [ ] **Step 4: Commit in pieces** — `app: transcription through the Swift engine` (TranscriptionEngine, AppModel, bridging header, pbxproj package reference and link flags), then `chore: remove the C++ transcription engine` (nsheet_engine files, smoke script, build-engine.sh, .gitmodules, submodule).

### Task 12: iOS proof, docs and changelog

**Files:**
- Modify: `CLAUDE.md` (the intro sentence, the `Where things are` tree: `Engine/` is now the `TranscriptionEngine` wrapper; add `Packages/NeuralSheetEngine`; drop the muscriptor submodule line; `Scripts/build-engine.sh` builds demucs; requirements: CMake still needed for demucs; the actor-isolation bullet still true), `README.md` (the "unchanged and linked as a static library" sentence → the Swift port; build requirements; layout; credits keep muscriptor.cpp as the origin; the licence paragraph's list), `CHANGELOG.md` (one sentence under Unreleased › Changed: "The transcription engine is now written in Swift, so it runs on the Mac's GPU without any C++ and can be built for iOS."), `docs/release.md` if it mentions the engine build time.
- Create: `docs/design/2026-09-29-swift-engine-design.md` § "Deliberate departures" line in `CLAUDE.md`'s inventory bullet: append "; the transcription engine is a Swift port of muscriptor.cpp, `Packages/NeuralSheetEngine`, on Accelerate or Metal (design: `docs/design/2026-09-29-swift-engine-design.md`)".

- [ ] **Step 1: iOS** — `cd app/Packages/NeuralSheetEngine && xcodebuild -scheme NeuralSheetEngine -destination 'generic/platform=iOS' -derivedDataPath /tmp/nse-ios build 2>&1 | grep -E "error:|BUILD"` and the same for `'generic/platform=iOS Simulator'` → `BUILD SUCCEEDED` twice. Fix anything platform-specific (e.g. `sysctlbyname` is fine on iOS; `Bundle.module` is test-only).
- [ ] **Step 2: Docs** as above. Keep the changelog to one sentence.
- [ ] **Step 3: Commit** — `docs: the Swift engine in the guidance, the readme and the changelog`.

---

## Self-review notes

- Spec coverage: §2's decisions map to Tasks 1–2 (surface, tables), 3 (oracle), 4 (weights in memory, GGUF), 5 (front-end), 6–7 (CPU, protocol, precision, KV, threads), 8 (transcriber, bench, errors), 9 (Metal, backend choice), 10 (medium, numbers), 11 (the app, what goes), 12 (iOS, notices via the package `NOTICE` from Task 1, docs). §6's ladder is one test file per row.
- Type consistency: `Model.load(url:useGPU:contextSize:)` is used by Tasks 7, 8, 9, 10 with the same signature; `TransformerBackend.forward(input:nNew:nPast:)` by 7 and 9; `Checkpoints.url(for:)` by 4–10; `Compare` by 5, 7, 9; `Fixtures` by 1–10; `GGUFWriter` (test-only, Task 4) by 8.
- Open questions resolved in the plan: the strided `q` in `attend` (Task 7 decides and keeps tests green); the near-tie margin is 0.05 on the oracle's logits, a value to revisit only if the oracle's `decode_logits` show genuine ties; the oracle's tensors come from the CPU directories.
