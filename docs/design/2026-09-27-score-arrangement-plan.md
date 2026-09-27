# Score Arrangement Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give the Score tab a per-part arrangement (display mode, clef, transposition, tablature with tunings, hidden parts, manual string choices), sheet metadata, a page layout and a PDF export, with the MusicXML export following the same settings.

**Architecture:** A `ScoreArrangement` value in the project drives a richer `ScoreDocument` (written pitches, tab staves with string placements). The system packing moves into the core package so a `ScorePageLayout` can paginate it under test. The drawing moves out of `ScoreView` into a `ScoreRenderer` that both the view and the PDF export call. Floating cards edit the arrangement through `AppModel` commands.

**Tech Stack:** Swift 6.2 (Swift 5 language mode in the core package), Swift Testing, AppKit, CoreGraphics (PDF context), SwiftUI for the cards and toolbar.

**Spec:** `docs/design/2026-09-27-score-arrangement-design.md`

## Global Constraints

- Build must be warning-free in our own sources: `cd app && xcodebuild -project NeuralSheet.xcodeproj -scheme NeuralSheet -configuration Debug -destination 'platform=macOS,arch=arm64' build 2>&1 | grep -E "warning:|error:|BUILD"` shows only `BUILD SUCCEEDED` (the `appintentsmetadataprocessor` line is the tool's, not ours).
- Core tests must pass: `cd app/Packages/NeuralSheetCore && swift test`.
- Views use the `AppModel` public contract only: no view touches `transcription`, `engine`, `document` writes, or calls `transition(to:)`. Add a method on `AppModel` instead.
- Edits to notes go through `NoteDocument` and `AppModel.commit`. The arrangement is not an edit: it is display state, never in the undo stack.
- Keep files under roughly 400 lines; split with the `+Extension.swift` pattern.
- Commit after every task with a lowercase `area: what` message (`core:`, `app:`, `ui:`, `docs:`), ending with `Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>`.
- Do not edit `project.pbxproj` except for build settings; source files are picked up automatically.
- A project saved by this build must open in the previous one: `arrangement` is one optional key; the saved workspace for the Score tab stays `edit`.
- User-facing strings say "NeuralSheet".
- The changelog entry is one sentence: what the user can do and where.
- After each task, touch the changed `.swift` files before grepping the build log for warnings (an incremental build hides them).

---

## File structure

Core (`app/Packages/NeuralSheetCore/Sources/NeuralSheetCore/`):
- `ScoreArrangement.swift` — `ScoreArrangement`, `PartDisplay`, `TabSetup`, `SheetMetadata`, `ScoreLayoutMode`, `PageSize`, `ClefChoice`.
- `TabTemplate.swift` — `TabTemplate`, `TuningPreset`, the template table.
- `TabFingering.swift` — `TabFingering.Placement`, `TabFingering.place`.
- `ScoreModel+Pitch.swift` (modify) — the four new clefs, `ClefChoice.resolve`, `MusicalKey.transposed(by:)`.
- `ScoreModel.swift` (modify) — the arrangement-aware build, `ScoreTabStaff`, ids and written pitches on notes.
- `ScoreSystemLayout.swift` — the system packing and row geometry, moved from the UI.
- `ScorePageLayout.swift` — pages.
- `MusicXMLWriter.swift`, `MusicXMLWriter+Tab.swift` (new) — the arrangement in the export.
- `ProjectState.swift`, `ProjectContent.swift` (modify) — `arrangement`.

App (`app/NeuralSheet/App/`):
- `AppModel.swift` (modify) — `arrangement`, `selectedTabNote`.
- `AppModel+Arrangement.swift` — the commands, the pruning, the PDF export.
- `AppModel+Project.swift`, `AppModel+ProjectOpen.swift`, `AppModel+Editing.swift` (modify).
- `KeyboardShortcuts.swift` (modify) — ↑/↓ in the Score tab.
- `NeuralSheetApp.swift` (modify) — Export PDF….

UI (`app/NeuralSheet/UI/Score/` unless said):
- `ScoreRenderer.swift`, `ScoreRenderer+Chords.swift`, `ScoreRenderer+Tab.swift`, `ScoreRenderer+Page.swift` — drawing.
- `ScoreView.swift` (rewrite) — cursor, selection, hit-testing, clicks.
- `ScoreLayout.swift` (rewrite) — the continuous or paged geometry from the core layouts.
- `ScoreContainerView.swift` (modify) — pages mode, the cards.
- `ScorePDF.swift` — the PDF data.
- `PartDisplayCard.swift`, `StringCard.swift`, `SheetCard.swift` — the floating cards.
- `UI/Toolbar/ScoreToolbar.swift`, `UI/Toolbar/GridControls.swift` (extracted from `EditToolbar.swift`).
- `UI/MainView.swift` (modify) — the toolbar per tab.

---

### Task 1: The arrangement value

**Files:**
- Create: `app/Packages/NeuralSheetCore/Sources/NeuralSheetCore/ScoreArrangement.swift`
- Test: `app/Packages/NeuralSheetCore/Tests/NeuralSheetCoreTests/ScoreArrangementTests.swift`

**Interfaces:**
- Produces: `ScoreArrangement`, `PartDisplay`, `PartDisplay.Mode`, `TabSetup`, `SheetMetadata`, `ScoreLayoutMode`, `PageSize`, `ClefChoice` exactly as in the code below; every later task uses these names.

- [ ] **Step 1: Write the failing tests**

```swift
import Foundation
import Testing

@testable import NeuralSheetCore

@Test func anArrangementDefaultsEveryPartToNotation() {
    let arrangement = ScoreArrangement()
    #expect(arrangement.display(for: 40) == PartDisplay())
    #expect(arrangement.layout == .continuous)
    #expect(arrangement.pageSize == .a4)
    #expect(PartDisplay().mode == .notation)
    #expect(PartDisplay().clef == .automatic)
    #expect(PartDisplay().transposition == 0)
    #expect(PartDisplay().tab == nil)
    #expect(!PartDisplay().isHidden)
    #expect(SheetMetadata().showsMeasureNumbers && SheetMetadata().showsPartNames && SheetMetadata().showsTempo)
}

@Test func anArrangementRoundTripsThroughJSON() throws {
    var arrangement = ScoreArrangement()
    var guitar = PartDisplay()
    guitar.mode = .both
    guitar.clef = .treble8vb
    guitar.transposition = 12
    guitar.tab = TabSetup(template: "guitar", tuning: [40, 45, 50, 55, 59, 64], presetName: "Standard", frets: 24)
    guitar.strings = [NoteID(3): 2]
    arrangement.parts[24] = guitar
    arrangement.sheet.title = "Take"
    arrangement.sheet.composer = "Trad."
    arrangement.layout = .pages
    arrangement.pageSize = .letter

    let data = try JSONEncoder().encode(arrangement)
    let decoded = try JSONDecoder().decode(ScoreArrangement.self, from: data)
    #expect(decoded == arrangement)
    #expect(decoded.display(for: 24).strings[NoteID(3)] == 2)
}

@Test func anArrangementFromAnOlderFileFillsItsDefaults() throws {
    let json = #"{"parts":{"0":{"mode":"tab"}},"sheet":{"title":"Old"}}"#
    let decoded = try JSONDecoder().decode(ScoreArrangement.self, from: Data(json.utf8))
    #expect(decoded.display(for: 0).mode == .tab)
    #expect(decoded.display(for: 0).clef == .automatic)
    #expect(decoded.sheet.title == "Old")
    #expect(decoded.sheet.showsTempo)
    #expect(decoded.layout == .continuous)
}

@Test func pageSizesInPoints() {
    #expect(abs(PageSize.a4.points.width - 595.28) < 0.01)
    #expect(abs(PageSize.a4.points.height - 841.89) < 0.01)
    #expect(PageSize.letter.points == CGSize(width: 612, height: 792))
    #expect(abs(PageSize.margin - 42.52) < 0.01)
    #expect(abs(PageSize.headerHeight - 51.02) < 0.01)
}

@Test func sheetTitlesFallBackToTheTake() {
    #expect(SheetMetadata().resolvedTitle(takeName: "song") == "song")
    #expect(SheetMetadata().resolvedTitle(takeName: nil) == "Untitled")
    var sheet = SheetMetadata()
    sheet.title = "My Tune"
    #expect(sheet.resolvedTitle(takeName: "song") == "My Tune")
    sheet.title = "   "
    #expect(sheet.resolvedTitle(takeName: "song") == "song", "blank is no title")
}

@Test func clefChoicesHaveNames() {
    #expect(ClefChoice.allCases.first == .automatic)
    #expect(ClefChoice.treble8vb.name == "Treble 8vb")
    #expect(ClefChoice.grand.name == "Grand staff")
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd app/Packages/NeuralSheetCore && swift test --filter ScoreArrangement`
Expected: compile errors, `ScoreArrangement` not found.

- [ ] **Step 3: Write the value**

```swift
import Foundation

/// How the Score tab shows the transcription (arrangement design §3.1): per-part display,
/// the sheet's metadata, the layout and the page size. Display state, saved with the project,
/// never in the undo stack.
public struct ScoreArrangement: Equatable, Codable, Sendable {
    /// By program; a part without an entry shows as `PartDisplay()`.
    public var parts: [Int: PartDisplay] = [:]
    public var sheet = SheetMetadata()
    public var layout: ScoreLayoutMode = .continuous
    public var pageSize: PageSize = .a4

    public init() {}

    public func display(for program: Int) -> PartDisplay {
        parts[program] ?? PartDisplay()
    }

    private enum CodingKeys: String, CodingKey { case parts, sheet, layout, pageSize }

    /// Every key falls back to its default, so a file from a version that lacks one loads.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        parts = try container.decodeIfPresent([Int: PartDisplay].self, forKey: .parts) ?? [:]
        sheet = try container.decodeIfPresent(SheetMetadata.self, forKey: .sheet) ?? SheetMetadata()
        layout = try container.decodeIfPresent(ScoreLayoutMode.self, forKey: .layout) ?? .continuous
        pageSize = try container.decodeIfPresent(PageSize.self, forKey: .pageSize) ?? .a4
    }
}

public enum ScoreLayoutMode: String, Codable, Sendable, CaseIterable {
    case continuous, pages
}

/// Portrait pages, in PostScript points (72 to the inch).
public enum PageSize: String, Codable, Sendable, CaseIterable {
    case a4, letter

    public var points: CGSize {
        switch self {
        case .a4: CGSize(width: 210 / 25.4 * 72, height: 297 / 25.4 * 72)
        case .letter: CGSize(width: 612, height: 792)
        }
    }

    public var name: String {
        switch self {
        case .a4: "A4"
        case .letter: "Letter"
        }
    }

    /// 15 mm on every side.
    public static let margin: CGFloat = 15 / 25.4 * 72
    /// 18 mm more at the top of page 1 for the header block.
    public static let headerHeight: CGFloat = 18 / 25.4 * 72
}

/// The clef a part is shown in; `automatic` is the range rule the Score tab had from the start.
public enum ClefChoice: String, Codable, Sendable, CaseIterable {
    case automatic, treble, bass, grand, alto, tenor, treble8vb, bass8vb, percussion

    public var name: String {
        switch self {
        case .automatic: "Automatic"
        case .treble: "Treble"
        case .bass: "Bass"
        case .grand: "Grand staff"
        case .alto: "Alto"
        case .tenor: "Tenor"
        case .treble8vb: "Treble 8vb"
        case .bass8vb: "Bass 8vb"
        case .percussion: "Percussion"
        }
    }
}

/// One part's display (arrangement design §3.1).
public struct PartDisplay: Equatable, Codable, Sendable {
    public enum Mode: String, Codable, Sendable, CaseIterable {
        case notation, tab, both

        public var name: String {
            switch self {
            case .notation: "Notation"
            case .tab: "Tab"
            case .both: "Both"
            }
        }
    }

    public var mode: Mode = .notation
    public var clef: ClefChoice = .automatic
    /// Written = sounding + transposition, in semitones.
    public var transposition = 0
    /// Nil until a template is chosen.
    public var tab: TabSetup? = nil
    public var isHidden = false
    /// Manual string choices by note id, 0 being the bottom tab line.
    public var strings: [NoteID: Int] = [:]

    public init() {}

    private enum CodingKeys: String, CodingKey { case mode, clef, transposition, tab, isHidden, strings }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        mode = try container.decodeIfPresent(Mode.self, forKey: .mode) ?? .notation
        clef = try container.decodeIfPresent(ClefChoice.self, forKey: .clef) ?? .automatic
        transposition = try container.decodeIfPresent(Int.self, forKey: .transposition) ?? 0
        tab = try container.decodeIfPresent(TabSetup.self, forKey: .tab)
        isHidden = try container.decodeIfPresent(Bool.self, forKey: .isHidden) ?? false
        strings = try container.decodeIfPresent([NoteID: Int].self, forKey: .strings) ?? [:]
    }

    /// Whether a tab staff is shown.
    public var showsTab: Bool { tab != nil && mode != .notation }
    /// Whether a notation staff is shown.
    public var showsNotation: Bool { tab == nil || mode != .tab }
}

/// A part's tablature: which template, the open pitches from the bottom tab line up, where
/// they came from, and how many frets.
public struct TabSetup: Equatable, Codable, Sendable {
    public var template: String
    public var tuning: [Int]
    public var presetName: String?
    public var frets: Int

    public init(template: String, tuning: [Int], presetName: String?, frets: Int) {
        self.template = template
        self.tuning = tuning
        self.presetName = presetName
        self.frets = frets
    }
}

/// What the sheet says about itself (arrangement design §3.1).
public struct SheetMetadata: Equatable, Codable, Sendable {
    /// Nil or blank: the take's name.
    public var title: String? = nil
    public var subtitle = ""
    public var composer = ""
    public var arranger = ""
    /// The footer.
    public var copyright = ""
    public var showsMeasureNumbers = true
    public var showsPartNames = true
    public var showsTempo = true

    public init() {}

    public func resolvedTitle(takeName: String?) -> String {
        if let title, !title.trimmingCharacters(in: .whitespaces).isEmpty {
            return title
        }

        if let takeName, !takeName.isEmpty {
            return takeName
        }

        return "Untitled"
    }

    private enum CodingKeys: String, CodingKey {
        case title, subtitle, composer, arranger, copyright, showsMeasureNumbers, showsPartNames, showsTempo
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        title = try container.decodeIfPresent(String.self, forKey: .title)
        subtitle = try container.decodeIfPresent(String.self, forKey: .subtitle) ?? ""
        composer = try container.decodeIfPresent(String.self, forKey: .composer) ?? ""
        arranger = try container.decodeIfPresent(String.self, forKey: .arranger) ?? ""
        copyright = try container.decodeIfPresent(String.self, forKey: .copyright) ?? ""
        showsMeasureNumbers = try container.decodeIfPresent(Bool.self, forKey: .showsMeasureNumbers) ?? true
        showsPartNames = try container.decodeIfPresent(Bool.self, forKey: .showsPartNames) ?? true
        showsTempo = try container.decodeIfPresent(Bool.self, forKey: .showsTempo) ?? true
    }
}
```

`NoteID` must be `Codable` and `Hashable` for the `[NoteID: Int]` dictionary; it already is (the document stores it). If `[NoteID: Int]` does not encode as a JSON object (Swift encodes non-string-keyed dictionaries as arrays), that is acceptable: the round-trip test is what matters, and the array form decodes back.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd app/Packages/NeuralSheetCore && swift test --filter ScoreArrangement`
Expected: 6 tests pass.

- [ ] **Step 5: Commit**

```bash
git add app/Packages/NeuralSheetCore/Sources/NeuralSheetCore/ScoreArrangement.swift app/Packages/NeuralSheetCore/Tests/NeuralSheetCoreTests/ScoreArrangementTests.swift
git commit -m "core: the score arrangement value

Per-part display, sheet metadata, layout mode and page size, every
field defaulting when a file lacks it (arrangement design §3.1).

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 2: The tablature library

**Files:**
- Create: `app/Packages/NeuralSheetCore/Sources/NeuralSheetCore/TabTemplate.swift`
- Test: `app/Packages/NeuralSheetCore/Tests/NeuralSheetCoreTests/TabTemplateTests.swift`

**Interfaces:**
- Consumes: `TabSetup` (Task 1).
- Produces: `TabTemplate` (`id`, `name`, `strings`, `frets`, `presets`, `defaultTransposition`, `static all`, `static template(id:)`, `static template(forProgram:)`, `func setup(preset:) -> TabSetup`), `TuningPreset` (`name`, `pitches`, `label`).

- [ ] **Step 1: Write the failing tests**

```swift
import Foundation
import Testing

@testable import NeuralSheetCore

@Test func theLibraryCoversTheFrettedInstruments() {
    let ids = TabTemplate.all.map(\.id)
    #expect(ids == ["guitar", "guitar7", "bass", "bass5", "bass6", "banjo5", "banjoTenor", "banjoPlectrum", "mandolin", "ukulele", "lapSteel"])

    for template in TabTemplate.all {
        #expect(!template.presets.isEmpty, template.id)
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
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd app/Packages/NeuralSheetCore && swift test --filter TabTemplate`
Expected: compile errors.

- [ ] **Step 3: Write the library**

```swift
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
```

`MusicalKey.sharpNames` is `static let` and internal in `MusicalKey.swift`; it is in the same module, so this compiles.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd app/Packages/NeuralSheetCore && swift test --filter TabTemplate`
Expected: 4 tests pass.

- [ ] **Step 5: Commit**

```bash
git add app/Packages/NeuralSheetCore/Sources/NeuralSheetCore/TabTemplate.swift app/Packages/NeuralSheetCore/Tests/NeuralSheetCoreTests/TabTemplateTests.swift
git commit -m "core: the tablature library

Eleven fretted templates with their tunings, the banjo's fifth string
first (arrangement design §3.2).

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 3: String assignment

**Files:**
- Create: `app/Packages/NeuralSheetCore/Sources/NeuralSheetCore/TabFingering.swift`
- Test: `app/Packages/NeuralSheetCore/Tests/NeuralSheetCoreTests/TabFingeringTests.swift`

**Interfaces:**
- Produces: `TabFingering.Placement { string: Int, fret: Int, isPlayable: Bool }`, `TabFingering.place(pitches: [Int], tuning: [Int], frets: Int, manual: [Int?]) -> [Placement]` (one placement per pitch, in the pitches' order).

- [ ] **Step 1: Write the failing tests**

```swift
import Foundation
import Testing

@testable import NeuralSheetCore

private let guitar = [40, 45, 50, 55, 59, 64]
private let openG = [67, 50, 55, 59, 62]

@Test func aNoteTakesTheLowestFretThatFits() {
    let placements = TabFingering.place(pitches: [64], tuning: guitar, frets: 24, manual: [nil])
    #expect(placements == [.init(string: 5, fret: 0, isPlayable: true)], "open high E, not the 5th fret of B")

    let g3 = TabFingering.place(pitches: [55], tuning: guitar, frets: 24, manual: [nil])
    #expect(g3 == [.init(string: 3, fret: 0, isPlayable: true)])
}

@Test func anOpenGBanjoChordLandsOnOpenStrings() {
    let placements = TabFingering.place(pitches: [50, 55, 59, 62, 67], tuning: openG, frets: 22, manual: [nil, nil, nil, nil, nil])
    #expect(placements.map(\.string) == [1, 2, 3, 4, 0])
    #expect(placements.allSatisfy { $0.fret == 0 && $0.isPlayable })
}

@Test func aChordFillsDistinctStrings() {
    // E major barre shapes share pitches with open strings; the strings must not double up.
    let placements = TabFingering.place(pitches: [40, 47, 52, 56, 59, 64], tuning: guitar, frets: 24, manual: Array(repeating: nil, count: 6))
    #expect(Set(placements.map(\.string)).count == 6)
    #expect(placements.allSatisfy(\.isPlayable))
}

@Test func impossibleNotesArePlacedAndMarked() {
    let low = TabFingering.place(pitches: [38], tuning: guitar, frets: 24, manual: [nil])
    #expect(low == [.init(string: 0, fret: -2, isPlayable: false)], "below the lowest open string: the lowest string, a negative fret")

    let high = TabFingering.place(pitches: [100], tuning: guitar, frets: 24, manual: [nil])
    #expect(high == [.init(string: 5, fret: 36, isPlayable: false)])

    // Seven notes on six strings: the surplus goes to the last string, unplayable.
    let seven = TabFingering.place(pitches: [40, 45, 50, 55, 59, 64, 65], tuning: guitar, frets: 24, manual: Array(repeating: nil, count: 7))
    #expect(seven.filter { !$0.isPlayable }.count == 1)
    #expect(seven.last?.string == 5)
}

@Test func aManualChoiceWinsAndMayBeImpossible() {
    let onA = TabFingering.place(pitches: [64], tuning: guitar, frets: 24, manual: [1])
    #expect(onA == [.init(string: 1, fret: 19, isPlayable: true)])

    let onLowE = TabFingering.place(pitches: [38], tuning: guitar, frets: 24, manual: [2])
    #expect(onLowE == [.init(string: 2, fret: -12, isPlayable: false)])

    // A manual choice takes its string before the automatic notes pick theirs.
    let chord = TabFingering.place(pitches: [55, 59], tuning: guitar, frets: 24, manual: [nil, 3])
    #expect(chord[1] == .init(string: 3, fret: 4, isPlayable: true))
    #expect(chord[0].string == 2, "G3 moves to the D string, fret 5, since the G string is taken")
    #expect(chord[0].fret == 5)

    let outOfRange = TabFingering.place(pitches: [55], tuning: guitar, frets: 24, manual: [9])
    #expect(outOfRange[0].string == 5, "a string the template does not have is clamped to the top one")
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd app/Packages/NeuralSheetCore && swift test --filter TabFingering`
Expected: compile errors.

- [ ] **Step 3: Write the assignment**

```swift
import Foundation

/// Which string each note of a chord is played on (arrangement design §3.3).
public enum TabFingering {
    public struct Placement: Equatable, Sendable {
        /// 0 is the bottom tab line.
        public var string: Int
        /// `pitch − open pitch`; negative or past the last fret is unplayable.
        public var fret: Int
        public var isPlayable: Bool

        public init(string: Int, fret: Int, isPlayable: Bool) {
            self.string = string
            self.fret = fret
            self.isPlayable = isPlayable
        }
    }

    /// One placement per pitch, in the pitches' order. Manual choices take their strings
    /// first; the rest, lowest pitch first, take the free string with the lowest fret at or
    /// above 0; a note no free string can hold takes the free string whose fret is nearest the
    /// playable range, unplayable; with no string free at all, the top string, unplayable.
    public static func place(pitches: [Int], tuning: [Int], frets: Int, manual: [Int?]) -> [Placement] {
        guard !tuning.isEmpty else {
            return pitches.map { _ in Placement(string: 0, fret: 0, isPlayable: false) }
        }

        var placements = [Placement?](repeating: nil, count: pitches.count)
        var taken = Set<Int>()

        // Manual first.
        for (index, pitch) in pitches.enumerated() {
            guard index < manual.count, let wanted = manual[index] else { continue }

            let string = min(max(wanted, 0), tuning.count - 1)
            let fret = pitch - tuning[string]
            placements[index] = Placement(string: string, fret: fret, isPlayable: fret >= 0 && fret <= frets && !taken.contains(string))
            taken.insert(string)
        }

        // Then the automatic ones, lowest pitch first.
        let automatic = pitches.indices.filter { placements[$0] == nil }.sorted { pitches[$0] < pitches[$1] }

        for index in automatic {
            let pitch = pitches[index]
            let free = tuning.indices.filter { !taken.contains($0) }

            guard !free.isEmpty else {
                let string = tuning.count - 1
                placements[index] = Placement(string: string, fret: pitch - tuning[string], isPlayable: false)
                continue
            }

            let playable = free.filter { pitch - tuning[$0] >= 0 && pitch - tuning[$0] <= frets }

            if let best = playable.min(by: { pitch - tuning[$0] < pitch - tuning[$1] }) {
                placements[index] = Placement(string: best, fret: pitch - tuning[best], isPlayable: true)
                taken.insert(best)
                continue
            }

            // Nearest to the range: the distance below 0 or above the last fret.
            let nearest = free.min { a, b in
                distance(pitch - tuning[a], frets: frets) < distance(pitch - tuning[b], frets: frets)
            }!
            placements[index] = Placement(string: nearest, fret: pitch - tuning[nearest], isPlayable: false)
            taken.insert(nearest)
        }

        return placements.map { $0 ?? Placement(string: 0, fret: 0, isPlayable: false) }
    }

    private static func distance(_ fret: Int, frets: Int) -> Int {
        fret < 0 ? -fret : max(0, fret - frets)
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd app/Packages/NeuralSheetCore && swift test --filter TabFingering`
Expected: 5 tests pass. If `impossibleNotesArePlacedAndMarked`'s seven-note case reports the unplayable note on a string other than 5, check that the six lower pitches took strings 0…5 in pitch order and the seventh had no free string.

- [ ] **Step 5: Commit**

```bash
git add app/Packages/NeuralSheetCore/Sources/NeuralSheetCore/TabFingering.swift app/Packages/NeuralSheetCore/Tests/NeuralSheetCoreTests/TabFingeringTests.swift
git commit -m "core: string assignment for tab

Manual choices first, then the lowest fret that fits, impossible notes
placed and marked (arrangement design §3.3).

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 4: Clefs, transposition and the tab staff in the score model

**Files:**
- Modify: `app/Packages/NeuralSheetCore/Sources/NeuralSheetCore/ScoreModel+Pitch.swift`
- Modify: `app/Packages/NeuralSheetCore/Sources/NeuralSheetCore/ScoreModel.swift`
- Modify: `app/Packages/NeuralSheetCore/Sources/NeuralSheetCore/MusicXMLWriter+Rhythm.swift` (the `UnitNote.id` field and the `unitNotes(_:ids:grid:quantum:)` overload)
- Modify: `app/Packages/NeuralSheetCore/Sources/NeuralSheetCore/MusicalKey.swift` (`transposed(by:)`)
- Test: `app/Packages/NeuralSheetCore/Tests/NeuralSheetCoreTests/ScoreModelTests.swift` (append)

**Interfaces:**
- Consumes: `ScoreArrangement`, `PartDisplay`, `ClefChoice` (Task 1); `TabFingering` (Task 3).
- Produces:
  - `Clef` cases `treble, bass, alto, tenor, treble8vb, bass8vb, percussion`; `Clef.step(forStep:octave:)`, `Clef.signaturePositions(fifths:)` for all; `Clef.isOctaveDown: Bool`.
  - `ClefChoice.resolve(for pitches: [Int]) -> [Clef]` (one clef, or `[.treble, .bass]` for grand).
  - `MusicalKey.transposed(by semitones: Int) -> MusicalKey`.
  - `ScoreDocument.build(notes: [NoteEvent], ids: [NoteID?]? = nil, grid: TempoGrid, key: MusicalKey?, arrangement: ScoreArrangement = ScoreArrangement()) -> ScoreDocument`.
  - `ScorePart.display: PartDisplay`, `ScorePart.tab: ScoreTabStaff?`, `ScorePart.writtenFifths: Int`.
  - `ScoreTabStaff { tuning: [Int], frets: Int, measures: [ScoreMeasure] }`.
  - `ScoreNote.id: NoteID?`, `ScoreNote.writtenPitch: Int`, `ScoreNote.placement: TabFingering.Placement?`.
  - `MusicXMLWriter.UnitNote.id: NoteID?`.

- [ ] **Step 1: Write the failing tests** (append to `ScoreModelTests.swift`)

```swift
@Test func newClefsHaveTheirBaselines() {
    #expect(Clef.alto.step(forStep: "F", octave: 3) == 0)
    #expect(Clef.alto.step(forStep: "C", octave: 4) == 4, "middle C on the alto's middle line")
    #expect(Clef.tenor.step(forStep: "D", octave: 3) == 0)
    #expect(Clef.tenor.step(forStep: "C", octave: 4) == 6, "middle C on the tenor's fourth line")
    #expect(Clef.treble8vb.step(forStep: "E", octave: 4) == 0, "the octave is in the transposition, not the clef")
    #expect(Clef.bass8vb.step(forStep: "G", octave: 2) == 0)
    #expect(Clef.treble8vb.isOctaveDown && Clef.bass8vb.isOctaveDown && !Clef.treble.isOctaveDown)
    // Alto and tenor signatures sit inside the staff, one position per letter.
    #expect(Clef.alto.signaturePositions(fifths: 1) == [7], "F♯ in the alto's top space")
    #expect(Clef.tenor.signaturePositions(fifths: -1) == [5], "B♭ in the tenor's third space")
    #expect(Clef.alto.signaturePositions(fifths: 3).count == 3)
}

@Test func clefChoicesResolve() {
    #expect(ClefChoice.automatic.resolve(for: [72, 74]) == [.treble])
    #expect(ClefChoice.automatic.resolve(for: [40, 43]) == [.bass])
    #expect(ClefChoice.grand.resolve(for: [60]) == [.treble, .bass])
    #expect(ClefChoice.alto.resolve(for: [60]) == [.alto])
    #expect(ClefChoice.treble8vb.resolve(for: [40]) == [.treble8vb])
    #expect(ClefChoice.percussion.resolve(for: []) == [.percussion])
}

@Test func keysTranspose() {
    #expect(MusicalKey(tonic: 0, mode: .major).transposed(by: 2) == MusicalKey(tonic: 2, mode: .major))
    #expect(MusicalKey(tonic: 0, mode: .minor).transposed(by: 9) == MusicalKey(tonic: 9, mode: .minor))
    #expect(MusicalKey(tonic: 5, mode: .major).transposed(by: -12) == MusicalKey(tonic: 5, mode: .major))
}

@Test func aTrumpetPartIsWrittenAToneUp() {
    var arrangement = ScoreArrangement()
    var trumpet = PartDisplay()
    trumpet.transposition = 2
    arrangement.parts[56] = trumpet

    let notes = [note(60, at: 0, program: 56), note(65, at: 0.5, program: 56)]
    let score = ScoreDocument.build(notes: notes, grid: grid, key: MusicalKey(tonic: 0, mode: .major), arrangement: arrangement)
    let part = score.parts[0]

    #expect(part.writtenFifths == 2, "C major sounds; D major is written")
    #expect(part.display.transposition == 2)
    let first = part.staves[0].measures[0].pieces[0].notes[0]
    #expect(first.pitch == 60 && first.writtenPitch == 62)
    #expect(first.step == -1, "D4 hangs just under the treble staff")
    #expect(first.accidental == nil)
    let second = part.staves[0].measures[0].pieces[1].notes[0]
    #expect(second.writtenPitch == 67 && second.accidental == nil, "G in D major")
}

@Test func aGuitarPartGetsATabStaffAndKeepsItsIds() {
    var arrangement = ScoreArrangement()
    var guitar = PartDisplay()
    guitar.mode = .both
    guitar.transposition = 12
    guitar.clef = .treble8vb
    guitar.tab = TabTemplate.template(id: "guitar")!.setup(preset: TabTemplate.template(id: "guitar")!.presets[0])
    guitar.strings = [NoteID(7): 1]
    arrangement.parts[24] = guitar

    let notes = [note(64, at: 0, program: 24), note(55, at: 0, program: 24), note(38, at: 0.5, program: 24)]
    let ids: [NoteID?] = [NoteID(7), NoteID(8), NoteID(9)]
    let score = ScoreDocument.build(notes: notes, ids: ids, grid: grid, key: nil, arrangement: arrangement)
    let part = score.parts[0]

    #expect(part.staves.map(\.clef) == [.treble8vb])
    #expect(part.tab?.tuning == [40, 45, 50, 55, 59, 64])

    let chord = part.tab!.measures[0].pieces[0]
    #expect(chord.notes.map(\.id) == [NoteID(8), NoteID(7)], "ascending pitch, ids carried")
    #expect(chord.notes[1].placement == .init(string: 1, fret: 19, isPlayable: true), "the manual choice")
    #expect(chord.notes[0].placement == .init(string: 3, fret: 0, isPlayable: true))

    let low = part.tab!.measures[0].pieces[1]
    #expect(low.notes[0].placement?.isPlayable == false, "D2 is below the guitar")

    // The notation staff shows the written octave: E4 sounding is written E5.
    #expect(part.staves[0].measures[0].pieces[0].notes.map(\.writtenPitch) == [67, 76])
}

@Test func tabOnlyAndHiddenParts() {
    var arrangement = ScoreArrangement()
    var bass = PartDisplay()
    bass.mode = .tab
    bass.tab = TabTemplate.template(id: "bass")!.setup(preset: TabTemplate.template(id: "bass")!.presets[0])
    arrangement.parts[33] = bass
    var hidden = PartDisplay()
    hidden.isHidden = true
    arrangement.parts[0] = hidden

    let score = ScoreDocument.build(notes: [note(43, at: 0, program: 33), note(60, at: 0)], grid: grid, key: nil, arrangement: arrangement)
    #expect(score.parts.map(\.program) == [33], "the piano is hidden")
    #expect(score.parts[0].staves.isEmpty)
    #expect(score.parts[0].tab != nil)
    #expect(score.measureCount == 1)
}

@Test func theOldBuildStillWorks() {
    let score = ScoreDocument.build(notes: [note(60, at: 0)], grid: grid, key: nil)
    #expect(score.parts[0].display == PartDisplay())
    #expect(score.parts[0].tab == nil)
    #expect(score.parts[0].staves[0].measures[0].pieces[0].notes[0].id == nil)
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd app/Packages/NeuralSheetCore && swift test --filter "newClefs|clefChoices|keysTranspose|aTrumpetPart|aGuitarPart|tabOnlyAnd|theOldBuild"`
Expected: compile errors.

- [ ] **Step 3: The clefs and the key**

In `ScoreModel+Pitch.swift`, replace the `Clef` enum's declaration and `baseline` with:

```swift
public enum Clef: Equatable, Sendable {
    case treble, bass, alto, tenor, treble8vb, bass8vb, percussion

    /// The diatonic number of the bottom line: E4 for the treble staff, G2 for the bass, F3 for
    /// the alto, D3 for the tenor; the octave clefs the same as their parents (the octave is in
    /// the part's transposition); the percussion staff places its display positions as the
    /// treble does.
    var baseline: Int {
        switch self {
        case .treble, .treble8vb, .percussion: ScorePitch.diatonic(step: "E", octave: 4)
        case .bass, .bass8vb: ScorePitch.diatonic(step: "G", octave: 2)
        case .alto: ScorePitch.diatonic(step: "F", octave: 3)
        case .tenor: ScorePitch.diatonic(step: "D", octave: 3)
        }
    }

    public var isOctaveDown: Bool { self == .treble8vb || self == .bass8vb }
```

and replace `signaturePositions(fifths:)` with:

```swift
    /// The staff steps the key signature's accidentals sit on, in signature order: the treble
    /// and bass staves' conventional places, the C clefs' letters each at its one step inside
    /// the staff.
    public func signaturePositions(fifths: Int) -> [Int] {
        guard fifths != 0 else { return [] }

        let count = min(abs(fifths), 7)
        let letters = (fifths > 0 ? ScorePitch.sharpOrder : ScorePitch.flatOrder).prefix(count)

        switch self {
        case .treble, .treble8vb, .percussion:
            return Array((fifths > 0 ? ScorePitch.trebleSharps : ScorePitch.trebleFlats).prefix(count))
        case .bass, .bass8vb:
            return (fifths > 0 ? ScorePitch.trebleSharps : ScorePitch.trebleFlats).prefix(count).map { $0 - 2 }
        case .alto, .tenor:
            // Each letter's step in the window 2…8, which every letter enters exactly once.
            return letters.map { letter in
                let index = ScorePitch.letters.firstIndex(of: letter) ?? 0
                let raw = (index - baseline % 7 + 7) % 7   // the letter's step in 0…6
                return raw < 2 ? raw + 7 : raw
            }
        }
    }
}

extension ClefChoice {
    /// The staves a choice stands for: the range rule for `automatic`, two for the grand staff.
    public func resolve(for pitches: [Int]) -> [Clef] {
        switch self {
        case .automatic:
            switch MusicXMLWriter.staffLayout(for: pitches) {
            case .treble: return [.treble]
            case .bass: return [.bass]
            case .grand: return [.treble, .bass]
            case .percussion: return [.percussion]
            }
        case .treble: return [.treble]
        case .bass: return [.bass]
        case .grand: return [.treble, .bass]
        case .alto: return [.alto]
        case .tenor: return [.tenor]
        case .treble8vb: return [.treble8vb]
        case .bass8vb: return [.bass8vb]
        case .percussion: return [.percussion]
        }
    }
}
```

In `MusicalKey.swift` add inside the struct:

```swift
    /// The same mode from the tonic `semitones` away: the written key of a transposing part.
    public func transposed(by semitones: Int) -> MusicalKey {
        MusicalKey(tonic: tonic + semitones, mode: mode)
    }
```

- [ ] **Step 4: Ids through the rhythm helpers**

In `MusicXMLWriter+Rhythm.swift`, change `UnitNote` to

```swift
    struct UnitNote: Equatable {
        var start: Int
        var end: Int
        var pitch: Int
        var id: NoteID? = nil
    }
```

and add beside `unitNotes(_:grid:quantum:)`:

```swift
    /// ``unitNotes(_:grid:quantum:)`` with the document's ids alongside, where there are any.
    static func unitNotes(_ notes: [NoteEvent], ids: [NoteID?]?, grid: TempoGrid, quantum: Int) -> [UnitNote] {
        let unitsPerSecond = Double(divisions) / grid.secondsPerBeat
        let step = max(1, quantum)

        func units(_ seconds: Double) -> Int {
            let raw = (seconds - grid.offsetSeconds) * unitsPerSecond
            guard raw.isFinite else { return 0 }
            return Int((raw / Double(step)).rounded()) * step
        }

        return notes.enumerated().map { index, note in
            let start = units(note.startTime)
            let end = max(units(note.endTime), start + step)
            let id = ids.flatMap { index < $0.count ? $0[index] : nil }

            return UnitNote(start: start, end: end, pitch: note.pitch, id: id)
        }
        .sorted { ($0.start, $0.pitch, $0.end) < ($1.start, $1.pitch, $1.end) }
    }
```

and make the old `unitNotes(_:grid:quantum:)` call it with `ids: nil`.

- [ ] **Step 5: The score model**

In `ScoreModel.swift`:

Add to `ScoreNote`: `public var id: NoteID? = nil`, `public var writtenPitch: Int = 0` (set by the builder; keep the memberwise order `pitch, step, accidental, tiedFrom, tiedTo, head, id, writtenPitch, placement`), `public var placement: TabFingering.Placement? = nil`.

Add:

```swift
/// A part's tablature: the same pieces as its staves, each note placed on a string.
public struct ScoreTabStaff: Equatable, Sendable {
    public var tuning: [Int]
    public var frets: Int
    public var measures: [ScoreMeasure]
}
```

Add to `ScorePart`: `public var display: PartDisplay = PartDisplay()`, `public var tab: ScoreTabStaff? = nil`, `public var writtenFifths: Int = 0`.

Replace `build` with:

```swift
    /// The score for `notes` on `grid` in `key`, shown as `arrangement` says: hidden parts left
    /// out, each part at its written transposition, in its clefs, with a tab staff when it has
    /// a template. `ids` runs alongside `notes` (the document's) or is nil while a run streams.
    public static func build(notes: [NoteEvent], ids: [NoteID?]? = nil, grid: TempoGrid, key: MusicalKey?,
                             arrangement: ScoreArrangement = ScoreArrangement()) -> ScoreDocument {
        var notesByProgram: [Int: [(NoteEvent, NoteID?)]] = [:]

        for (index, note) in notes.enumerated() {
            let id = ids.flatMap { index < $0.count ? $0[index] : nil }
            notesByProgram[note.program, default: []].append((note, id))
        }

        let quantum = MusicXMLWriter.quantum(for: grid.division)
        let programs = notesByProgram.keys.sorted().filter { !arrangement.display(for: $0).isHidden }

        let writerParts = programs.map { program -> MusicXMLWriter.Part in
            let pairs = notesByProgram[program] ?? []
            return MusicXMLWriter.Part(program: program,
                                       name: Instruments.info(forProgram: program).name,
                                       channel: 1,
                                       notes: MusicXMLWriter.unitNotes(pairs.map(\.0), ids: pairs.map(\.1), grid: grid, quantum: quantum))
        }

        let span = MusicXMLWriter.measureSpan(writerParts)

        let parts = writerParts.map { part -> ScorePart in
            let info = Instruments.info(forProgram: part.program)
            let display = arrangement.display(for: part.program)
            let isDrums = part.program == NoteEvent.drumProgram
            let transposition = isDrums ? 0 : display.transposition
            let writtenKey = key?.transposed(by: transposition)
            let fifths = writtenKey?.fifths ?? 0
            let written = part.notes.map { note in
                var shifted = note
                shifted.pitch = min(max(note.pitch + transposition, 0), 127)
                return shifted
            }

            var staves: [ScoreStaff] = []

            if display.showsNotation {
                let clefs: [Clef] = isDrums ? [.percussion] : display.clef.resolve(for: written.map(\.pitch))
                let staffNotes: [(Clef, [MusicXMLWriter.UnitNote])] = clefs.count == 2
                    ? [(clefs[0], written.filter { $0.pitch >= MusicXMLWriter.middleC }),
                       (clefs[1], written.filter { $0.pitch < MusicXMLWriter.middleC })]
                    : [(clefs[0], written)]

                staves = staffNotes.map { clef, unitNotes in
                    ScoreStaff(clef: clef, measures: span.map { bar in
                        measure(bar: bar, notes: unitNotes, sounding: part.notes, clef: clef, isDrums: isDrums, fifths: fifths)
                    })
                }
            }

            var tab: ScoreTabStaff?

            if let setup = display.tab, display.showsTab, !isDrums {
                tab = ScoreTabStaff(tuning: setup.tuning, frets: setup.frets, measures: span.map { bar in
                    tabMeasure(bar: bar, notes: part.notes, setup: setup, manual: display.strings)
                })
            }

            var scorePart = ScorePart(program: part.program, name: info.name, abbreviation: info.abbreviation, staves: staves)
            scorePart.display = display
            scorePart.tab = tab
            scorePart.writtenFifths = fifths

            return scorePart
        }

        return ScoreDocument(parts: parts, measureCount: span.count, firstBar: span.lowerBound, fifths: key?.fifths ?? 0, bpm: grid.bpm)
    }
```

Change `measure(bar:notes:clef:isDrums:fifths:)` to take the written notes as `notes` and the sounding ones as `sounding` (both arrays share order after sorting by the same keys, so match by id or by index): simplest, give `UnitNote` the sounding pitch too. Replace the `written` construction above so each written `UnitNote` keeps its id, and in `measure` set `ScoreNote.pitch` from `sounding` by looking the id up when ids exist, else by the transposition passed in. To keep this simple and testable, change the `measure` signature to

```swift
    static func measure(bar: Int, notes: [MusicXMLWriter.UnitNote], transposition: Int, clef: Clef, isDrums: Bool, fifths: Int) -> ScoreMeasure
```

where `notes` are the *written* unit notes and the sounding pitch is `note.pitch - transposition`; in `build` pass `transposition` instead of `sounding`. Inside `measure`, construct each `ScoreNote` with `pitch: note.pitch - transposition`, `writtenPitch: note.pitch`, `id: note.id`, and everything else as today (spelling from `note.pitch`, the written one).

Add:

```swift
    /// One bar of a tab staff: the same segments and values as the notation, each chord's
    /// notes placed on strings.
    static func tabMeasure(bar: Int, notes: [MusicXMLWriter.UnitNote], setup: TabSetup, manual: [NoteID: Int]) -> ScoreMeasure {
        let from = bar * MusicXMLWriter.barUnits
        let to = from + MusicXMLWriter.barUnits
        var pieces: [ScorePiece] = []

        for segment in MusicXMLWriter.segments(notes, from: from, to: to) {
            if segment.isRest, segment.start == from, segment.end == to {
                pieces.append(ScorePiece(startUnits: 0, units: MusicXMLWriter.barUnits, type: "whole", dots: 0, notes: [], isWholeMeasureRest: true))
                continue
            }

            let placements = TabFingering.place(pitches: segment.notes.map(\.pitch), tuning: setup.tuning, frets: setup.frets,
                                                manual: segment.notes.map { $0.id.flatMap { manual[$0] } })
            var pieceStart = segment.start

            for value in MusicXMLWriter.printableDurations(segment.end - segment.start) {
                let pieceEnd = pieceStart + value.units
                let scoreNotes = segment.notes.enumerated().map { index, note in
                    ScoreNote(pitch: note.pitch, step: placements[index].string, accidental: nil,
                              tiedFrom: note.start < pieceStart, tiedTo: note.end > pieceEnd, head: .normal,
                              id: note.id, writtenPitch: note.pitch, placement: placements[index])
                }

                pieces.append(ScorePiece(startUnits: pieceStart - from, units: value.units, type: value.type, dots: value.dots,
                                         notes: scoreNotes, isWholeMeasureRest: false))
                pieceStart = pieceEnd
            }
        }

        return ScoreMeasure(pieces: pieces)
    }
```

In a tab piece, `ScoreNote.step` is the string index (the renderer draws the fret on that line).

- [ ] **Step 6: Run the whole suite**

Run: `cd app/Packages/NeuralSheetCore && swift test`
Expected: every test passes, including the earlier `ScoreModelTests`. If `aScaleIsEightQuartersOverTwoMeasures` fails on `writtenPitch`, the old build path must set `writtenPitch = pitch` (transposition 0).

- [ ] **Step 7: Build the app** (the container view calls the old `build` signature, which still exists)

Run the build from Global Constraints. Expected: `BUILD SUCCEEDED`, no warnings.

- [ ] **Step 8: Commit**

```bash
git add app/Packages/NeuralSheetCore
git commit -m "core: clefs, transposition and a tab staff in the score model

Alto, tenor and octave clefs; a part written at its transposition in
its transposed key; a tab staff with each chord placed on strings; the
document's ids carried on every note (arrangement design §3.4).

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 5: The arrangement on the model and in the project

**Files:**
- Modify: `app/Packages/NeuralSheetCore/Sources/NeuralSheetCore/ProjectState.swift`
- Modify: `app/Packages/NeuralSheetCore/Sources/NeuralSheetCore/ProjectContent.swift`
- Modify: `app/Packages/NeuralSheetCore/Tests/NeuralSheetCoreTests/ProjectStateTests.swift`
- Modify: `app/NeuralSheet/App/AppModel.swift`
- Create: `app/NeuralSheet/App/AppModel+Arrangement.swift`
- Modify: `app/NeuralSheet/App/AppModel+Project.swift`, `app/NeuralSheet/App/AppModel+ProjectOpen.swift`, `app/NeuralSheet/App/AppModel+Editing.swift`

**Interfaces:**
- Produces on `AppModel`: `var arrangement: ScoreArrangement`; `var selectedTabNote: (program: Int, id: NoteID)?`; `func setPartMode(_:program:)`, `setPartClef(_:program:)`, `setPartTransposition(_:program:)`, `setPartTab(template:preset:program:)`, `clearPartTab(program:)`, `setPartTuning(string:pitch:program:)`, `setPartFrets(_:program:)`, `setPartHidden(_:program:)`, `setString(_ string: Int?, program:id:)`, `moveSelectedTabString(by:)`, `selectTabNote(program:id:)`, `setSheet(_:)`, `setScoreLayout(_:)`, `setPageSize(_:)`, `pruneStringChoices()`.
- `ProjectState.arrangement: ScoreArrangement`, `ProjectContent.arrangement: ScoreArrangement`.

- [ ] **Step 1: The project state and content**

In `ProjectState.swift` add `public var arrangement = ScoreArrangement()` after `key`, the `arrangement` coding key, and `arrangement = try container.decodeIfPresent(ScoreArrangement.self, forKey: .arrangement) ?? defaults.arrangement`. In `ProjectContent.swift` add `public var arrangement: ScoreArrangement` with an `arrangement: ScoreArrangement = ScoreArrangement()` init parameter after `key`.

Append to `ProjectStateTests.swift`'s round-trip test, after `state.key = …`: `state.arrangement.layout = .pages; state.arrangement.parts[24] = { var d = PartDisplay(); d.mode = .tab; return d }()`. The existing `#expect(try ProjectState.read(from: url) == state)` covers it. Add:

```swift
@Test func aProjectWithoutAnArrangementOpensWithTheDefaults() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("noarr-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: url) }
    try Data("{\"formatVersion\": 1}".utf8).write(to: url)
    #expect(try ProjectState.read(from: url).arrangement == ScoreArrangement())
}
```

Run `swift test`; expected green.

- [ ] **Step 2: The model's property and commands**

In `AppModel.swift`, after `var editor = EditorState() { … }`:

```swift
    /// How the Score tab shows the transcription (arrangement design §3.1). Saved with the
    /// project; `AppModel+Arrangement.swift` is its only writer.
    var arrangement = ScoreArrangement()

    /// The tab note the Score tab has selected, whose string ↑/↓ move. Transient.
    var selectedTabNote: (program: Int, id: NoteID)?
```

Create `AppModel+Arrangement.swift`:

```swift
import Foundation
import NeuralSheetCore

/// The Score tab's arrangement commands (arrangement design §5): every write to
/// `arrangement` goes through here, so the pruning and the defaults live in one place.
extension AppModel {
    private func updatePart(_ program: Int, _ change: (inout PartDisplay) -> Void) {
        var display = arrangement.display(for: program)
        change(&display)

        if arrangement.parts[program] != display {
            arrangement.parts[program] = display
        }
    }

    func setPartMode(_ mode: PartDisplay.Mode, program: Int) {
        updatePart(program) { $0.mode = mode }
    }

    func setPartClef(_ clef: ClefChoice, program: Int) {
        updatePart(program) { $0.clef = clef }
    }

    /// Semitones, −36…36.
    func setPartTransposition(_ semitones: Int, program: Int) {
        updatePart(program) { $0.transposition = min(max(semitones, -36), 36) }
    }

    /// A template and one of its presets. A part still in notation goes to notation and tab,
    /// and one with no transposition takes the template's customary one.
    func setPartTab(template: TabTemplate, preset: TuningPreset, program: Int) {
        updatePart(program) { display in
            let hadTab = display.tab != nil
            display.tab = template.setup(preset: preset)
            if display.mode == .notation { display.mode = .both }
            if !hadTab, display.transposition == 0 { display.transposition = template.defaultTransposition }
            display.strings = [:]
        }
    }

    func clearPartTab(program: Int) {
        updatePart(program) { display in
            display.tab = nil
            display.strings = [:]
            if display.mode != .notation { display.mode = .notation }
        }
    }

    /// One string's open pitch, which makes the tuning custom.
    func setPartTuning(string: Int, pitch: Int, program: Int) {
        updatePart(program) { display in
            guard var tab = display.tab, string >= 0, string < tab.tuning.count else { return }
            tab.tuning[string] = min(max(pitch, 0), 127)
            tab.presetName = nil
            display.tab = tab
        }
    }

    func setPartFrets(_ frets: Int, program: Int) {
        updatePart(program) { display in
            guard var tab = display.tab else { return }
            tab.frets = min(max(frets, 1), 36)
            display.tab = tab
        }
    }

    func setPartHidden(_ hidden: Bool, program: Int) {
        updatePart(program) { $0.isHidden = hidden }
    }

    /// A manual string for one note, or nil for the automatic choice.
    func setString(_ string: Int?, program: Int, id: NoteID) {
        updatePart(program) { display in
            if let string {
                display.strings[id] = string
            } else {
                display.strings[id] = nil
            }
        }
    }

    func selectTabNote(program: Int, id: NoteID) {
        selectedTabNote = (program, id)
    }

    func deselectTabNote() {
        selectedTabNote = nil
    }

    /// ↑ / ↓ in the Score tab: the selected note a string up or down, clamped to the template.
    func moveSelectedTabString(by delta: Int) {
        guard let selected = selectedTabNote, let tab = arrangement.display(for: selected.program).tab,
              let current = currentString(program: selected.program, id: selected.id) else { return }

        setString(min(max(current + delta, 0), tab.tuning.count - 1), program: selected.program, id: selected.id)
    }

    /// The string a note is on now: the manual choice, else where the automatic placement put
    /// it, read off a fresh score.
    func currentString(program: Int, id: NoteID) -> Int? {
        if let manual = arrangement.display(for: program).strings[id] { return manual }

        let score = scoreDocument()
        guard let part = score.parts.first(where: { $0.program == program }), let tab = part.tab else { return nil }

        for measure in tab.measures {
            for piece in measure.pieces {
                if let note = piece.notes.first(where: { $0.id == id }) { return note.placement?.string }
            }
        }

        return nil
    }

    /// The score as the Score tab and the exports see it.
    func scoreDocument() -> ScoreDocument {
        let ids = document?.notes.map { Optional($0.id) }
        return ScoreDocument.build(notes: notes, ids: ids, grid: editor.grid, key: editor.key, arrangement: arrangement)
    }

    /// Drops manual string choices for notes the document no longer has. After every commit.
    func pruneStringChoices() {
        guard let document else { return }

        for (program, display) in arrangement.parts where !display.strings.isEmpty {
            let kept = display.strings.filter { document.contains($0.key) }
            if kept.count != display.strings.count {
                arrangement.parts[program]?.strings = kept
            }
        }

        if let selected = selectedTabNote, !document.contains(selected.id) {
            selectedTabNote = nil
        }
    }

    func setSheet(_ sheet: SheetMetadata) {
        if arrangement.sheet != sheet { arrangement.sheet = sheet }
    }

    func setScoreLayout(_ layout: ScoreLayoutMode) {
        if arrangement.layout != layout { arrangement.layout = layout }
    }

    func setPageSize(_ size: PageSize) {
        if arrangement.pageSize != size { arrangement.pageSize = size }
    }
}
```

In `AppModel+Editing.swift`'s `applyDocument()` add `pruneStringChoices()` after `validateTargetProgram()`. In `installDocument`, nothing more: `applyDocument` runs.

- [ ] **Step 3: Save, restore, dirty**

`AppModel+Project.swift`: `projectContent()` passes `arrangement: arrangement`; `projectState(audioFileName:)` sets `state.arrangement = arrangement`; the new-project reset (the line `editor = EditorState()`) also sets `arrangement = ScoreArrangement()` and `selectedTabNote = nil`. `AppModel+ProjectOpen.swift`: after `editor.key = saved.key` add `arrangement = saved.arrangement`.

- [ ] **Step 4: Build and test**

Run the build and `swift test`. Expected: green, no warnings.

- [ ] **Step 5: Commit**

```bash
git add app/Packages/NeuralSheetCore app/NeuralSheet/App
git commit -m "app: the arrangement on the model and in the project

Every write goes through one extension; string choices are pruned as
notes go; the project saves and restores it, and a change marks the
project edited (arrangement design §5).

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 6: The system layout moves into the core

**Files:**
- Create: `app/Packages/NeuralSheetCore/Sources/NeuralSheetCore/ScoreSystemLayout.swift`
- Test: `app/Packages/NeuralSheetCore/Tests/NeuralSheetCoreTests/ScoreSystemLayoutTests.swift`
- Modify: `app/NeuralSheet/UI/Score/ScoreLayout.swift` (becomes a wrapper), `app/NeuralSheet/UI/Score/ScoreView.swift`, `app/NeuralSheet/UI/Score/ScoreContainerView.swift` (type names)

**Interfaces:**
- Produces: `ScoreSystemLayout` with `init(document:arrangement:width:sp:)`, `systems: [ScoreSystemLayout.System]`, `totalHeight: CGFloat`, `sp: CGFloat`, `func box(forMeasure:) -> (system: System, box: MeasureBox)?`, `func hitTest(_:) -> (measure: Int, units: Double)?`; `System { frame, rows: [StaffRow], measures: [MeasureBox], showsTimeSignature, staffTop, staffBottom, func offset(by dy: CGFloat) -> System }`; `StaffRow { partIndex, kind: Kind (.staff(index: Int, clef: Clef) | .tab), bottomLineY, height }`; `MeasureBox` as the UI has it (`index, x, width, contentX, onsets, endX, x(forUnits:), units(forX:)`).
- The UI's `ScoreLayout` keeps its name and API but wraps a `ScoreSystemLayout` (continuous) or a `ScorePageLayout` (Task 7).

- [ ] **Step 1: Write the failing tests**

```swift
import Foundation
import Testing

@testable import NeuralSheetCore

private let grid = TempoGrid(bpm: 120, offsetSeconds: 0, division: .sixteenth)

private func quarters(_ count: Int, program: Int = 0, pitch: Int = 67) -> [NoteEvent] {
    (0..<count).map { NoteEvent(startTime: Double($0) * 0.5, endTime: Double($0) * 0.5 + 0.5, pitch: pitch, program: program) }
}

@Test func systemsWrapToTheWidthAndFillIt() {
    let score = ScoreDocument.build(notes: quarters(32), grid: grid, key: nil)
    let layout = ScoreSystemLayout(document: score, arrangement: ScoreArrangement(), width: 600, sp: 8)

    #expect(layout.systems.count > 1)
    #expect(layout.systems.flatMap(\.measures).map(\.index) == Array(0..<8))
    for system in layout.systems.dropLast() {
        #expect(abs(system.frame.maxX - (600 - ScoreSystemLayout.rightMargin * 8)) < 0.5, "every system but the last fills the width")
    }
    #expect(layout.totalHeight > layout.systems.last!.frame.maxY)
}

@Test func rowsStackStavesAndTabs() {
    var arrangement = ScoreArrangement()
    var guitar = PartDisplay()
    guitar.mode = .both
    guitar.tab = TabTemplate.template(id: "guitar")!.setup(preset: TabTemplate.template(id: "guitar")!.presets[0])
    arrangement.parts[24] = guitar

    let score = ScoreDocument.build(notes: quarters(4, program: 24, pitch: 64) + quarters(4, program: 0, pitch: 72), grid: grid, key: nil, arrangement: arrangement)
    let layout = ScoreSystemLayout(document: score, arrangement: arrangement, width: 900, sp: 8)
    let rows = layout.systems[0].rows

    #expect(rows.count == 3, "the piano's staff, the guitar's staff, the guitar's tab")
    #expect(rows[0].partIndex == 0)
    #expect(rows[1].partIndex == 1 && rows[1].kind == .staff(index: 0, clef: .treble))
    #expect(rows[2].partIndex == 1 && rows[2].kind == .tab)
    #expect(abs(rows[2].height - 5 * 1.5 * 8) < 0.01, "six lines, 1.5 spaces apart")
    #expect(rows[2].bottomLineY > rows[1].bottomLineY)
    #expect(layout.systems[0].staffBottom == rows[2].bottomLineY)
}

@Test func aSystemOffsetsAsAWhole() {
    let score = ScoreDocument.build(notes: quarters(4), grid: grid, key: nil)
    let layout = ScoreSystemLayout(document: score, arrangement: ScoreArrangement(), width: 600, sp: 8)
    let system = layout.systems[0]
    let moved = system.offset(by: 100)

    #expect(moved.frame.minY == system.frame.minY + 100)
    #expect(moved.rows[0].bottomLineY == system.rows[0].bottomLineY + 100)
    #expect(moved.measures[0].x == system.measures[0].x, "x is untouched")
}

@Test func measurePositionsInvert() {
    let score = ScoreDocument.build(notes: quarters(8), grid: grid, key: nil)
    let layout = ScoreSystemLayout(document: score, arrangement: ScoreArrangement(), width: 900, sp: 8)
    let (_, box) = layout.box(forMeasure: 1)!
    let x = box.x(forUnits: 36)
    #expect(abs(box.units(forX: x) - 36) < 0.01)
    #expect(layout.hitTest(CGPoint(x: x, y: layout.systems[0].frame.midY))?.measure == 1)
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd app/Packages/NeuralSheetCore && swift test --filter ScoreSystemLayout`
Expected: compile errors.

- [ ] **Step 3: Move the layout**

Create `ScoreSystemLayout.swift` from the current `UI/Score/ScoreLayout.swift` with these changes:

- `import Foundation` only; the type is `public struct ScoreSystemLayout`, every nested type and the metrics `public`.
- `init(document: ScoreDocument, arrangement: ScoreArrangement, width: CGFloat, sp: CGFloat)`.
- `StaffRow` becomes:

```swift
    public struct StaffRow: Equatable, Sendable {
        public enum Kind: Equatable, Sendable {
            case staff(index: Int, clef: Clef)
            case tab
        }

        public var partIndex: Int
        public var kind: Kind
        /// The bottom line's y.
        public var bottomLineY: CGFloat
        /// The lines' extent above the bottom line: 4 spaces for a staff, (strings − 1) × 1.5 for a tab.
        public var height: CGFloat

        public var topLineY: CGFloat { bottomLineY - height }
    }
```

- The row loop becomes:

```swift
            for (partIndex, part) in document.parts.enumerated() {
                var rowsOfPart = 0

                for (staffIndex, staff) in part.staves.enumerated() {
                    if rowsOfPart > 0 { rowY += ScoreSystemLayout.staffGap * sp }
                    rowY += 4 * sp
                    rows.append(StaffRow(partIndex: partIndex, kind: .staff(index: staffIndex, clef: staff.clef), bottomLineY: rowY, height: 4 * sp))
                    rowsOfPart += 1
                }

                if let tab = part.tab {
                    if rowsOfPart > 0 { rowY += ScoreSystemLayout.tabGap * sp }
                    let height = CGFloat(max(1, tab.tuning.count - 1)) * ScoreSystemLayout.tabLineGap * sp
                    rowY += height
                    rows.append(StaffRow(partIndex: partIndex, kind: .tab, bottomLineY: rowY, height: height))
                    rowsOfPart += 1
                }

                rowY += ScoreSystemLayout.partGap * sp
            }
```

with `public static let tabGap: CGFloat = 5`, `public static let tabLineGap: CGFloat = 1.5`, and `systemHeight(for:arrangement:sp:)` computed the same way (sum the rows, less the trailing part gap). `System.staffTop` becomes `rows.first.map { $0.topLineY } ?? frame.minY`; drop `spaceHint`.

- Add to `System`:

```swift
        public func offset(by dy: CGFloat) -> System {
            var moved = self
            moved.frame.origin.y += dy
            moved.rows = rows.map { row in
                var row = row
                row.bottomLineY += dy
                return row
            }
            return moved
        }
```

- The onset table also visits `part.tab?.measures` so the tab's accidental columns (none) do not matter, but the tab's pieces share the staves' onsets anyway; no change needed beyond reading `part.tab` when a part has no staves (tab-only): in `onsetTable`, iterate `part.staves.map(\.measures) + (part.tab.map { [$0.measures] } ?? [])`.
- `hitTest` unchanged. `leftMargin`, `rightMargin` etc. become `public static`.

Rewrite `UI/Score/ScoreLayout.swift` as a thin wrapper for now:

```swift
import AppKit
import NeuralSheetCore

/// The Score tab's geometry: the core's system layout at the view's staff space. Pages come in
/// the next task.
struct ScoreLayout {
    let systems: ScoreSystemLayout

    var sp: CGFloat { systems.sp }
    var totalHeight: CGFloat { systems.totalHeight }

    init(document: ScoreDocument, arrangement: ScoreArrangement, width: CGFloat, sp: CGFloat) {
        systems = ScoreSystemLayout(document: document, arrangement: arrangement, width: width, sp: sp)
    }

    func box(forMeasure index: Int) -> (system: ScoreSystemLayout.System, box: ScoreSystemLayout.MeasureBox)? {
        systems.box(forMeasure: index)
    }

    func hitTest(_ point: CGPoint) -> (measure: Int, units: Double)? {
        systems.hitTest(point)
    }
}
```

Update `ScoreView.swift` and `ScoreContainerView.swift`: `ScoreLayout.System` → `ScoreSystemLayout.System`, `layout.systems` → `layout.systems.systems`, the `ScoreLayout(document:width:sp:)` call gains `arrangement: model.arrangement`, `row.staffIndex`/`row.clef` reads become `if case .staff(let staffIndex, let clef) = row.kind` (skip `.tab` rows in the drawing for now; Task 8 draws them), `system.staffTop` as before, `ScoreLayout.staffGap` → `ScoreSystemLayout.staffGap`, `ScoreLayout.clefWidth` → `ScoreSystemLayout.clefWidth`, and so on. `ScoreContainerView.sync` builds with `model.scoreDocument()` and also observes `model.arrangement` (add `_ = model.arrangement` to `observeModel` and compare `lastArrangement`).

- [ ] **Step 4: Test and build**

Run `swift test` and the app build. Expected: green, no warnings.

- [ ] **Step 5: Commit**

```bash
git add app/Packages/NeuralSheetCore app/NeuralSheet/UI/Score
git commit -m "core: the score's system layout, with tab rows

Moved from the view so pages can be laid out under test; a part's tab
is a row of its own under its staves (arrangement design §3.5).

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 7: Pages

**Files:**
- Create: `app/Packages/NeuralSheetCore/Sources/NeuralSheetCore/ScorePageLayout.swift`
- Test: `app/Packages/NeuralSheetCore/Tests/NeuralSheetCoreTests/ScorePageLayoutTests.swift`

**Interfaces:**
- Produces: `ScorePageLayout` with `init(document:arrangement:pageSize:sp:)`, `pages: [Page]`, `pageSize: PageSize`, `sp`; `Page { index: Int, frame: CGRect (origin zero, the page's points), headerHeight: CGFloat, systems: [ScoreSystemLayout.System] (in page coordinates) }`; `static let pageStaffSpace: CGFloat = 7`, `static let footerHeight: CGFloat = 24`.

- [ ] **Step 1: Write the failing tests**

```swift
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

@Test func anEmptyScoreIsOneEmptyPage() {
    let layout = ScorePageLayout(document: .empty, arrangement: ScoreArrangement(), pageSize: .a4, sp: 7)
    #expect(layout.pages.count == 1)
    #expect(layout.pages[0].systems.isEmpty)
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd app/Packages/NeuralSheetCore && swift test --filter ScorePageLayout`
Expected: compile errors.

- [ ] **Step 3: Write the pagination**

```swift
import Foundation

/// The score on pages (arrangement design §3.5): the system layout at the page's content width,
/// the systems dealt onto pages by height, never split; page 1 keeps room for the header, every
/// page for the footer.
public struct ScorePageLayout: Sendable {
    public struct Page: Sendable {
        public var index: Int
        /// Origin zero, the page's size in points.
        public var frame: CGRect
        /// `PageSize.headerHeight` on the first page, 0 after.
        public var headerHeight: CGFloat
        /// In page coordinates.
        public var systems: [ScoreSystemLayout.System]
    }

    /// A staff space on a page: printed music is set smaller than the screen's 8.
    public static let pageStaffSpace: CGFloat = 7
    /// Room under the last system for the copyright line and the page number.
    public static let footerHeight: CGFloat = 24

    public let pageSize: PageSize
    public let sp: CGFloat
    public let systems: ScoreSystemLayout
    public var pages: [Page] = []

    public init(document: ScoreDocument, arrangement: ScoreArrangement, pageSize: PageSize, sp: CGFloat = ScorePageLayout.pageStaffSpace) {
        self.pageSize = pageSize
        self.sp = sp

        let size = pageSize.points
        let contentWidth = size.width - 2 * PageSize.margin
        // The system layout lays out from its own left margin; shift so its left edge lands on
        // the page margin.
        systems = ScoreSystemLayout(document: document, arrangement: arrangement, width: contentWidth + (ScoreSystemLayout.leftMargin + ScoreSystemLayout.rightMargin) * sp, sp: sp)

        let dx = PageSize.margin - ScoreSystemLayout.leftMargin * sp
        var current = Page(index: 0, frame: CGRect(origin: .zero, size: size), headerHeight: PageSize.headerHeight, systems: [])
        var y = PageSize.margin + PageSize.headerHeight
        let bottom = size.height - PageSize.margin - ScorePageLayout.footerHeight

        for system in systems.systems {
            let height = system.frame.height + ScoreSystemLayout.systemGap * sp

            if !current.systems.isEmpty, y + system.frame.height > bottom {
                pages.append(current)
                current = Page(index: pages.count, frame: CGRect(origin: .zero, size: size), headerHeight: 0, systems: [])
                y = PageSize.margin
            }

            var placed = system.offset(by: y - system.frame.minY)
            placed.frame.origin.x += dx
            placed.measures = placed.measures.map { box in
                var box = box
                box.x += dx
                box.contentX += dx
                box.onsets = box.onsets.map { (units: $0.units, x: $0.x + dx) }
                return box
            }
            current.systems.append(placed)
            y += height
        }

        pages.append(current)
    }

    /// The page and system holding measure `index`.
    public func box(forMeasure index: Int) -> (page: Page, system: ScoreSystemLayout.System, box: ScoreSystemLayout.MeasureBox)? {
        for page in pages {
            for system in page.systems {
                if let box = system.measures.first(where: { $0.index == index }) {
                    return (page, system, box)
                }
            }
        }

        return nil
    }
}
```

`MeasureBox.x`, `contentX` and `onsets` must be `public var` for the shift above; make them so in Task 6's file if they are not.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd app/Packages/NeuralSheetCore && swift test`
Expected: green.

- [ ] **Step 5: Commit**

```bash
git add app/Packages/NeuralSheetCore
git commit -m "core: the score on pages

Systems dealt onto A4 or Letter pages by height, never split, the first
page keeping room for the header (arrangement design §3.5).

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 8: The renderer, with tab staves

**Files:**
- Create: `app/NeuralSheet/UI/Score/ScoreRenderer.swift`, `app/NeuralSheet/UI/Score/ScoreRenderer+Chords.swift`, `app/NeuralSheet/UI/Score/ScoreRenderer+Tab.swift`
- Modify: `app/NeuralSheet/UI/Score/ScoreView.swift` (drawing removed; keeps the cursor, selection, hit list, clicks)
- Modify: `app/NeuralSheet/UI/Score/ScoreGlyphs.swift` (a `drawTabClef`)

**Interfaces:**
- Produces: `struct ScoreRenderer { let document: ScoreDocument; let arrangement: ScoreArrangement; let sp: CGFloat; init(document:arrangement:sp:) }` with `func drawSystem(_ system: ScoreSystemLayout.System, in ctx: CGContext, hits: inout [TabHit])`, `struct TabHit { program: Int; id: NoteID; frame: CGRect; string: Int }`, `static func stemUp(_:) -> Bool`.
- `ScoreView` gains `var hits: [TabHit]`, `var selectedTabNote: (program: Int, id: NoteID)?`, `var onSelectTabNote: ((TabHit?) -> Void)?`, `var onRightClickTabNote: ((TabHit, NSPoint) -> Void)?`.

- [ ] **Step 1: Move the drawing**

Create `ScoreRenderer.swift`:

```swift
import AppKit
import CoreText
import NeuralSheetCore

/// A tab note as drawn, for selection and the string card.
struct TabHit: Equatable {
    var program: Int
    var id: NoteID
    var frame: CGRect
    var string: Int
}

/// Draws a laid-out score into any `CGContext` (arrangement design §4): the view and the PDF
/// export share it. Staves, bar lines, clefs, signatures, part names, measure numbers and the
/// tempo here; chords in `+Chords`, tab staves in `+Tab`, the page's header and footer in `+Page`.
struct ScoreRenderer {
    let document: ScoreDocument
    let arrangement: ScoreArrangement
    let sp: CGFloat

    var pixel: CGFloat { max(1, (sp / 8).rounded()) }

    func drawSystem(_ system: ScoreSystemLayout.System, in ctx: CGContext, hits: inout [TabHit]) {
        drawStaffLines(system, in: ctx)
        drawBarLines(system, in: ctx)
        drawPrefixes(system, in: ctx)
        drawNumbersAndTempo(system, in: ctx)

        for row in system.rows {
            let part = document.parts[row.partIndex]

            switch row.kind {
            case let .staff(index, _):
                drawStaffMusic(part.staves[index], row: row, system: system, in: ctx)
            case .tab:
                if let tab = part.tab {
                    drawTabMusic(tab, part: part, row: row, system: system, in: ctx, hits: &hits)
                }
            }
        }
    }
```

then move `drawSystem`'s existing bodies from `ScoreView` into private methods here, split as named above:

- `drawStaffLines`: the five lines for a `.staff` row; for a `.tab` row, `tuning.count` lines `ScoreSystemLayout.tabLineGap * sp` apart from `row.bottomLineY` up; then the left edge from `system.staffTop` to `system.staffBottom`.
- `drawBarLines`: per row over `row.topLineY … row.bottomLineY` (the tab included), the final double bar as today.
- `drawPrefixes`: per row: the part name when `row` is the part's first row and `arrangement.sheet.showsPartNames`, centred over the part's rows (from the first row's `topLineY` to the last row's `bottomLineY`); the clef (`.staff`) or the "TAB" mark (`.tab`, `ScoreGlyphs.drawTabClef`); the signature for `.staff` rows with `part.writtenFifths` (not `document.fifths`) and `staff.clef.signaturePositions(fifths:)`; the time signature on the first system for `.staff` rows.
- `drawNumbersAndTempo`: the measure number when `arrangement.sheet.showsMeasureNumbers`, the tempo on the first system when `arrangement.sheet.showsTempo`.
- `drawStaffMusic`: the pieces of the staff's measures as today (`drawChord` and the rests, the ties), with `writtenPitch` used for nothing but the ties' pitch match (`note.pitch` still identifies a note across pieces).

Move `drawChord`, `drawTimeSignature`, `drawTempo` and `stemUp` into `ScoreRenderer+Chords.swift` as methods of `ScoreRenderer` (the same bodies; `row.bottomLineY` and `sp` as before). Keep `ScorePalette` in `ScoreRenderer.swift` and add `static let unplayable = TimelinePalette.cg(Theme.warn)` and `static let selection = TimelinePalette.cg(Theme.accent, alpha: 0.35)`.

- [ ] **Step 2: The tab staff**

`ScoreRenderer+Tab.swift`:

```swift
import AppKit
import CoreText
import NeuralSheetCore

extension ScoreRenderer {
    /// Fret numbers on the strings' lines, stems and flags below, ties as arcs under the numbers
    /// (arrangement design §4). Every number is recorded in `hits` for the selection.
    func drawTabMusic(_ tab: ScoreTabStaff, part: ScorePart, row: ScoreSystemLayout.StaffRow,
                      system: ScoreSystemLayout.System, in ctx: CGContext, hits: inout [TabHit]) {
        let lineGap = ScoreSystemLayout.tabLineGap * sp
        let font = CTFontCreateWithName(Fonts.monoName(500) as CFString, 1.35 * sp, nil)

        for (boxIndex, box) in system.measures.enumerated() where box.index < tab.measures.count {
            let measure = tab.measures[box.index]

            for (pieceIndex, piece) in measure.pieces.enumerated() {
                let x = piece.isWholeMeasureRest ? (box.contentX + box.endX) / 2 : box.x(forUnits: Double(piece.startUnits))

                if piece.isRest {
                    // A tab rest: the notation's rest glyph, small, centred on the tab.
                    ScoreGlyphs.drawRest(type: piece.type, dots: piece.dots, x: x, bottomLineY: row.bottomLineY - row.height / 2 + 2 * sp * 0.7,
                                         sp: sp * 0.7, colour: ScorePalette.line, context: ctx)
                    continue
                }

                for note in piece.notes {
                    guard let placement = note.placement else { continue }

                    let y = row.bottomLineY - CGFloat(placement.string) * lineGap
                    let text = "\(placement.fret)"
                    let width = TimelineText.width(text, font: font) + 0.4 * sp
                    let frame = CGRect(x: x - width / 2, y: y - 0.75 * sp, width: width, height: 1.5 * sp)

                    // A box in the paper colour so the number covers the line.
                    ctx.setFillColor(ScorePalette.paper)
                    ctx.fill(frame.insetBy(dx: 0, dy: 0.15 * sp))

                    let colour = placement.isPlayable ? ScorePalette.ink : ScorePalette.unplayable
                    TimelineText.draw(text, font: font, colour: colour, in: frame, anchor: .centred, context: ctx)

                    if let id = note.id {
                        hits.append(TabHit(program: part.program, id: id, frame: frame, string: placement.string))
                    }

                    if note.tiedTo {
                        let nextInMeasure = pieceIndex + 1 < measure.pieces.count ? measure.pieces[pieceIndex + 1] : nil
                        let nextBox = boxIndex + 1 < system.measures.count ? system.measures[boxIndex + 1] : nil
                        let nextPiece = nextInMeasure ?? nextBox.flatMap { $0.index < tab.measures.count ? tab.measures[$0.index].pieces.first : nil }
                        let nextX: CGFloat? = nextInMeasure.map { box.x(forUnits: Double($0.startUnits)) }
                            ?? nextBox.flatMap { next in nextPiece.map { next.x(forUnits: Double($0.startUnits)) } }
                        let continues = nextPiece?.notes.contains { $0.pitch == note.pitch } == true
                        let toX = (continues ? nextX : nil) ?? (box.endX - 0.3 * sp)

                        ScoreGlyphs.drawTie(from: CGPoint(x: x + width / 2, y: y + 0.6 * sp), to: CGPoint(x: toX - width / 2, y: y + 0.6 * sp),
                                            below: true, sp: sp, colour: colour, context: ctx)
                    }
                }

                // Rhythm under the tab: a stem from just below the bottom line, flags off it.
                guard piece.hasStem else { continue }

                let stemWidth = max(pixel, 0.13 * sp)
                let top = row.bottomLineY + 0.6 * sp
                let bottom = top + 2.6 * sp
                ctx.setFillColor(ScorePalette.ink)
                ctx.fill(CGRect(x: x - stemWidth / 2, y: top, width: stemWidth, height: bottom - top))
                ScoreGlyphs.drawFlags(count: piece.flags, stemEnd: CGPoint(x: x + stemWidth / 2, y: bottom), stemUp: false, sp: sp,
                                      colour: ScorePalette.ink, context: ctx)

                for dot in 0..<piece.dots {
                    ctx.fillEllipse(in: CGRect(x: x + (0.6 + CGFloat(dot) * 0.5) * sp, y: bottom - 0.4 * sp, width: 0.35 * sp, height: 0.35 * sp))
                }
            }
        }
    }
}
```

`TimelineText.width(_:font:tracking:)` exists in `TimelineDrawing.swift`. Add to `ScoreGlyphs`:

```swift
    /// "TAB" stacked down the staff's height, in place of a clef.
    static func drawTabClef(x: CGFloat, topLineY: CGFloat, bottomLineY: CGFloat, sp: CGFloat, colour: CGColor, context ctx: CGContext) {
        let font = CTFontCreateWithName(Fonts.sansName(600) as CFString, 1.6 * sp, nil)
        let height = bottomLineY - topLineY
        for (index, letter) in ["T", "A", "B"].enumerated() {
            let y = topLineY + height * (CGFloat(index) + 0.5) / 3
            TimelineText.draw(letter, font: font, colour: colour, in: CGRect(x: x, y: y - sp, width: 2.4 * sp, height: 2 * sp), anchor: .centred, context: ctx)
        }
    }
```

- [ ] **Step 3: The view keeps the interaction**

Rewrite `ScoreView.swift` so `draw(_:)` is:

```swift
    override func draw(_ rect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        ctx.fill(rect.intersection(bounds), ScorePalette.paper)

        guard let layout else { return }

        let renderer = ScoreRenderer(document: document, arrangement: arrangement, sp: layout.sp)
        var collected: [TabHit] = []

        for system in layout.systems.systems where system.frame.insetBy(dx: 0, dy: -8 * layout.sp).intersects(rect) {
            renderer.drawSystem(system, in: ctx, hits: &collected)
        }

        hits = collected

        if let selected = selectedTabNote, let hit = hits.first(where: { $0.program == selected.program && $0.id == selected.id }) {
            ctx.setStrokeColor(ScorePalette.selectionEdge)
            ctx.setLineWidth(max(1, layout.sp / 8))
            ctx.stroke(hit.frame.insetBy(dx: -layout.sp * 0.15, dy: -layout.sp * 0.15))
        }
    }
```

with `var arrangement = ScoreArrangement()`, `var hits: [TabHit] = []`, `var selectedTabNote: (program: Int, id: NoteID)?`, `ScorePalette.selectionEdge = TimelinePalette.cg(Theme.accent)`. `mouseDown` first looks for a hit under the point (`hits.first { $0.frame.insetBy(dx: -2, dy: -2).contains(point) }`): with one, `onSelectTabNote?(hit)` and no seek; without, `onSelectTabNote?(nil)` and the seek as today. Add `override func rightMouseDown(with:)`: a hit under the point calls `onRightClickTabNote?(hit, event.locationInWindow)`. Drawing only the visible systems means `hits` holds the visible notes, which is all selection needs.

The container sets `score.arrangement = model.arrangement` and `score.selectedTabNote = model.selectedTabNote` in `sync` (observe `model.selectedTabNote`; a change repaints), wires `onSelectTabNote` to `model.selectTabNote` / `model.deselectTabNote`, and leaves `onRightClickTabNote` for Task 9.

- [ ] **Step 4: Render harness and build**

Build the app (warning-free). Then render offscreen (see the `offscreen-render-harness` memory): a guitar part with `mode = .both`, standard tuning, one impossible low note, in the harness's `main.swift`; view the PNG and check the tab lines, the fret numbers, the red number, the stems below.

- [ ] **Step 5: Commit**

```bash
git add app/NeuralSheet/UI/Score
git commit -m "ui: the score renderer, with tablature

The drawing leaves the view for a renderer the PDF export can share;
a part's tab draws fret numbers on its strings, red where a note cannot
be played, with the rhythm below; tab notes select on click.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 9: The part card and the string card

**Files:**
- Create: `app/NeuralSheet/UI/Score/PartDisplayCard.swift`, `app/NeuralSheet/UI/Score/StringCard.swift`
- Modify: `app/NeuralSheet/UI/Score/ScoreContainerView.swift`, `app/NeuralSheet/UI/Score/ScoreView.swift` (part-name hit frames), `app/NeuralSheet/App/KeyboardShortcuts.swift`

**Interfaces:**
- Consumes: the `AppModel` commands of Task 5; `PopupMenuPresenter.showPanel(at:in:scale:content:)`; `MenuRow`, `NumberField`, `PitchField` (`UI/Sidebar/SelectionFields.swift`, internal), `FlatButton`.
- Produces: `ScoreView.nameHits: [(partIndex: Int, program: Int, frame: CGRect)]` filled by the renderer (`ScoreRenderer.drawPrefixes` records each part name's frame into a `names: inout [NameHit]` parameter; add `struct NameHit { program: Int; frame: CGRect }` beside `TabHit` and thread it through `drawSystem(_:in:hits:names:)`).

- [ ] **Step 1: The part card**

```swift
import AppKit
import NeuralSheetCore
import SwiftUI

/// A part's display (arrangement design §6): opened by a click on its name in the score. Rows
/// for the display mode, the clef, the transposition, the tab template and tuning, the frets
/// and a hide switch; every change goes straight to the model.
struct PartDisplayCard: View {
    let model: AppModel
    let program: Int
    let host: PopupMenuPresenter

    @Environment(\.uiScale) private var k
    @State private var clefMenu = PopupMenuPresenter()
    @State private var clefAnchor: NSView?
    @State private var transpositionMenu = PopupMenuPresenter()
    @State private var transpositionAnchor: NSView?
    @State private var templateMenu = PopupMenuPresenter()
    @State private var templateAnchor: NSView?
    @State private var tuningMenu = PopupMenuPresenter()
    @State private var tuningAnchor: NSView?

    static let width: CGFloat = 260
    private static let padding: CGFloat = 12
    private static let rowGap: CGFloat = 8

    /// Written = sounding + semitones.
    static let transpositionPresets: [(String, Int)] = [
        ("None", 0), ("B♭ (+2)", 2), ("B♭ tenor (+14)", 14), ("E♭ alto (+9)", 9), ("E♭ baritone (+21)", 21),
        ("F (+7)", 7), ("A (+3)", 3), ("Octave up (+12)", 12), ("Octave down (−12)", -12),
    ]

    var body: some View {
        let s = Scaled(k: k)
        let display = model.arrangement.display(for: program)
        let info = Instruments.info(forProgram: program)

        VStack(alignment: .leading, spacing: s(Self.rowGap)) {
            Text(info.name.uppercased())
                .font(Fonts.sectionHeader(k))
                .kerning(Fonts.tracking(Fonts.Tracking.sectionHeader, pointSize: Fonts.Size.sectionHeader, scale: k))
                .foregroundStyle(Theme.popupTitle)

            row("Display") {
                HStack(spacing: s(2)) {
                    ForEach(PartDisplay.Mode.allCases, id: \.self) { mode in
                        segment(mode.name, isOn: display.mode == mode, isEnabled: mode == .notation || display.tab != nil) {
                            model.setPartMode(mode, program: program)
                        }
                    }
                }
            }

            row("Clef") {
                menuButton(display.clef.name) { showClefMenu() }
                    .background(AnchorCatcher { clefAnchor = $0 })
            }

            row("Transposition") {
                HStack(spacing: s(6)) {
                    menuButton(Self.transpositionPresets.first { $0.1 == display.transposition }?.0 ?? "Custom") { showTranspositionMenu() }
                        .background(AnchorCatcher { transpositionAnchor = $0 })
                    NumberField(value: Double(display.transposition), range: -36 ... 36, decimals: 0, width: 40) {
                        model.setPartTransposition(Int($0), program: program)
                    }
                }
            }

            row("Tab") {
                menuButton(display.tab.flatMap { TabTemplate.template(id: $0.template)?.name } ?? "None") { showTemplateMenu() }
                    .background(AnchorCatcher { templateAnchor = $0 })
            }

            if let tab = display.tab {
                row("Tuning") {
                    menuButton(tab.presetName ?? "Custom") { showTuningMenu(tab) }
                        .background(AnchorCatcher { tuningAnchor = $0 })
                }

                // One pitch field per string, bottom tab line first.
                HStack(spacing: s(4)) {
                    ForEach(Array(tab.tuning.enumerated()), id: \.offset) { string, pitch in
                        PitchField(pitch: pitch, width: 34) { model.setPartTuning(string: string, pitch: $0, program: program) }
                    }
                }

                row("Frets") {
                    NumberField(value: Double(tab.frets), range: 1 ... 36, decimals: 0, width: 40) {
                        model.setPartFrets(Int($0), program: program)
                    }
                }
            }

            row("Hidden") {
                segment(display.isHidden ? "Hidden" : "Shown", isOn: display.isHidden, isEnabled: true) {
                    model.setPartHidden(!display.isHidden, program: program)
                }
            }
        }
        .padding(s(Self.padding))
        .frame(width: s(Self.width), alignment: .leading)
    }

    private func row<Control: View>(_ label: String, @ViewBuilder control: () -> Control) -> some View {
        HStack(spacing: Scaled(k: k)(8)) {
            TrackedLabel(string: label.uppercased(), em: Fonts.Tracking.pillLabel, pointSize: Fonts.Size.pillLabel, font: Fonts.pillLabel(k), scale: k)
                .foregroundStyle(Theme.textLabel)
                .frame(width: Scaled(k: k)(84), alignment: .leading)
            control()
            Spacer(minLength: 0)
        }
    }

    private func segment(_ title: String, isOn: Bool, isEnabled: Bool, action: @escaping () -> Void) -> some View {
        let s = Scaled(k: k)
        return FlatButton(isOn: isOn, isEnabled: isEnabled, idle: Theme.bgControlAlt, on: Theme.accentFillActive,
                          foregroundIdle: Theme.textButton, foregroundOn: Theme.accentText, corner: s(4), action: action) { _ in
            Text(title).font(Fonts.buttonLabel(k)).fixedSize().padding(.horizontal, s(8)).frame(height: s(22))
        }
    }

    private func menuButton(_ title: String, action: @escaping () -> Void) -> some View {
        segment(title, isOn: false, isEnabled: true, action: action)
    }

    private func showClefMenu() {
        guard let anchor = clefAnchor else { return }
        let menu = clefMenu
        let model = model
        let program = program
        host.child = menu
        menu.show(from: anchor, width: PopupMenuPresenter.width(forTitles: ClefChoice.allCases.map(\.name), scale: k), scale: k) {
            ForEach(ClefChoice.allCases, id: \.self) { clef in
                MenuRow(title: clef.name, isTicked: model.arrangement.display(for: program).clef == clef) {
                    menu.dismiss()
                    model.setPartClef(clef, program: program)
                }
            }
        }
    }

    private func showTranspositionMenu() {
        guard let anchor = transpositionAnchor else { return }
        let menu = transpositionMenu
        let model = model
        let program = program
        host.child = menu
        menu.show(from: anchor, width: PopupMenuPresenter.width(forTitles: Self.transpositionPresets.map(\.0), scale: k), scale: k) {
            ForEach(Self.transpositionPresets, id: \.1) { preset in
                MenuRow(title: preset.0, isTicked: model.arrangement.display(for: program).transposition == preset.1) {
                    menu.dismiss()
                    model.setPartTransposition(preset.1, program: program)
                }
            }
        }
    }

    private func showTemplateMenu() {
        guard let anchor = templateAnchor else { return }
        let menu = templateMenu
        let model = model
        let program = program
        host.child = menu
        menu.show(from: anchor, width: PopupMenuPresenter.width(forTitles: ["None"] + TabTemplate.all.map(\.name), scale: k), scale: k) {
            MenuRow(title: "None", isTicked: model.arrangement.display(for: program).tab == nil) {
                menu.dismiss()
                model.clearPartTab(program: program)
            }
            MenuSeparator()
            ForEach(TabTemplate.all) { template in
                MenuRow(title: template.name, isTicked: model.arrangement.display(for: program).tab?.template == template.id) {
                    menu.dismiss()
                    model.setPartTab(template: template, preset: template.presets[0], program: program)
                }
            }
        }
    }

    private func showTuningMenu(_ tab: TabSetup) {
        guard let anchor = tuningAnchor, let template = TabTemplate.template(id: tab.template) else { return }
        let menu = tuningMenu
        let model = model
        let program = program
        host.child = menu
        menu.show(from: anchor, width: PopupMenuPresenter.width(forTitles: template.presets.map(\.name), scale: k), scale: k) {
            ForEach(template.presets, id: \.name) { preset in
                MenuRow(title: preset.name, isTicked: tab.presetName == preset.name) {
                    menu.dismiss()
                    model.setPartTab(template: template, preset: preset, program: program)
                }
            }
        }
    }
}
```

`PitchField` in `SelectionFields.swift` is declared `struct PitchField: View` with an init; if its init differs from `PitchField(pitch:width:onCommit:)`, adapt the call to its actual signature (read the file). `host.child` is how the instrument card parents its menus; if `PopupMenuPresenter.child` is not settable from here, follow whatever `InstrumentCard.showChangeMenu` does.

- [ ] **Step 2: The string card**

```swift
import AppKit
import NeuralSheetCore
import SwiftUI

/// A tab note's strings (arrangement design §4): every string with the fret the note would
/// take there, impossible ones in the warning colour, the current one ticked, and Automatic.
struct StringCard: View {
    let model: AppModel
    let hit: TabHit
    let pitch: Int
    let host: PopupMenuPresenter

    @Environment(\.uiScale) private var k

    var body: some View {
        let display = model.arrangement.display(for: hit.program)
        let tab = display.tab
        let manual = display.strings[hit.id]

        VStack(alignment: .leading, spacing: 0) {
            MenuRow(title: "Automatic", isTicked: manual == nil) {
                host.dismiss()
                model.setString(nil, program: hit.program, id: hit.id)
            }
            MenuSeparator()
            if let tab {
                ForEach(Array(tab.tuning.enumerated().reversed()), id: \.offset) { string, open in
                    let fret = pitch - open
                    let playable = fret >= 0 && fret <= tab.frets
                    MenuRow(title: "String \(tab.tuning.count - string) (\(TuningPreset.label(for: [open]))): fret \(fret)",
                            isTicked: manual == string,
                            chip: playable ? nil : Theme.warn) {
                        host.dismiss()
                        model.setString(string, program: hit.program, id: hit.id)
                    }
                }
            }
        }
    }
}
```

`MenuRow` has a `chip: Color?` parameter (`MenuPanel.swift` line 111); the warning colour as the chip marks the impossible strings.

- [ ] **Step 3: Presenting the cards and the keys**

In `ScoreContainerView`: a `card = PopupMenuPresenter()`; `score.onRightClickTabNote = { [weak self] hit, windowPoint in … }` finds the note's sounding pitch from `self.score.document` (search the part's tab measures for `id`) and shows `StringCard(model:hit:pitch:host: card)` with `card.showPanel(at: window.convertPoint(toScreen: windowPoint), in: window, scale: scale)`; `score.onClickPartName = { program, windowPoint in … }` shows `PartDisplayCard(model:program:host: card)` the same way. `ScoreView.mouseDown` checks `nameHits` before `hits`.

In `KeyboardShortcuts.handle`, before the repeat guard, after the editor keys:

```swift
        // The Score tab's keys: a selected tab note a string up or down.
        if model.workspace == .score, !shift, event.keyCode == KeyCode.up || event.keyCode == KeyCode.down {
            model.moveSelectedTabString(by: event.keyCode == KeyCode.up ? 1 : -1)
            return true
        }
```

and a row in the doc comment's table: `| ↑ / ↓ (Score tab) | the selected tab note a string up / down |`. ↑ moves toward the higher-numbered tab line (the top); with the banjo's fifth string at the bottom that is still "up the page", which is what the eye expects.

- [ ] **Step 4: Build, render, commit**

Build warning-free; render the harness once more if the renderer changed. Commit:

```bash
git add app/NeuralSheet/UI/Score app/NeuralSheet/App/KeyboardShortcuts.swift
git commit -m "ui: the part card and the string card

A click on a part's name opens its display, clef, transposition, tab
template, tuning, frets and hide switch; a right-click on a fret number
lists the strings, impossible ones marked; ↑/↓ move the selection a
string.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 10: Pages in the view, the header and the footer

**Files:**
- Create: `app/NeuralSheet/UI/Score/ScoreRenderer+Page.swift`
- Modify: `app/NeuralSheet/UI/Score/ScoreLayout.swift`, `app/NeuralSheet/UI/Score/ScoreView.swift`, `app/NeuralSheet/UI/Score/ScoreContainerView.swift`

**Interfaces:**
- `ScoreLayout` becomes an enum-backed wrapper: `init(document:arrangement:width:sp:takeName:)`; `var mode: ScoreLayoutMode`; `var pageFrames: [CGRect]` (in view coordinates, stacked with `pageGap = 24`); `var systems: [ScoreSystemLayout.System]` (view coordinates, both modes); `totalHeight`; `sp`; `box(forMeasure:)`; `hitTest(_:)`; `var pages: ScorePageLayout?`.
- `ScoreRenderer.drawPage(_ page: ScorePageLayout.Page, at origin: CGPoint, takeName: String?, in ctx: CGContext, hits: inout [TabHit], names: inout [NameHit])` draws the sheet background, the header on page 1, the systems, the footer.

- [ ] **Step 1: The wrapper**

```swift
import AppKit
import NeuralSheetCore

/// The Score tab's geometry in view coordinates: the continuous system layout at the screen's
/// staff space, or the pages stacked down the view with a gap between (arrangement design §6).
struct ScoreLayout {
    static let pageGap: CGFloat = 24

    let mode: ScoreLayoutMode
    let sp: CGFloat
    let continuous: ScoreSystemLayout?
    let pages: ScorePageLayout?
    /// Each page's frame in view coordinates (pages mode).
    let pageFrames: [CGRect]
    /// Every system in view coordinates, whichever mode.
    let systems: [ScoreSystemLayout.System]
    let totalHeight: CGFloat

    init(document: ScoreDocument, arrangement: ScoreArrangement, width: CGFloat, scale: CGFloat) {
        mode = arrangement.layout

        switch arrangement.layout {
        case .continuous:
            let layout = ScoreSystemLayout(document: document, arrangement: arrangement, width: width, sp: ScoreContainerView.staffSpace * scale)
            sp = layout.sp
            continuous = layout
            pages = nil
            pageFrames = []
            systems = layout.systems
            totalHeight = layout.totalHeight

        case .pages:
            let layout = ScorePageLayout(document: document, arrangement: arrangement, pageSize: arrangement.pageSize,
                                         sp: ScorePageLayout.pageStaffSpace * scale)
            sp = layout.sp
            continuous = nil
            pages = layout

            let pageSize = CGSize(width: arrangement.pageSize.points.width * scale, height: arrangement.pageSize.points.height * scale)
            let x = max(0, (width - pageSize.width) / 2)
            var frames: [CGRect] = []
            var placed: [ScoreSystemLayout.System] = []
            var y = ScoreLayout.pageGap

            for page in layout.pages {
                let frame = CGRect(origin: CGPoint(x: x, y: y), size: pageSize)
                frames.append(frame)
                // Page coordinates are unscaled points; the view's are scaled.
                placed += page.systems.map { $0.scaled(by: scale).offset(by: frame.minY).offsetX(by: frame.minX) }
                y = frame.maxY + ScoreLayout.pageGap
            }

            pageFrames = frames
            systems = placed
            totalHeight = y
        }
    }

    func box(forMeasure index: Int) -> (system: ScoreSystemLayout.System, box: ScoreSystemLayout.MeasureBox)? {
        for system in systems {
            if let box = system.measures.first(where: { $0.index == index }) { return (system, box) }
        }
        return nil
    }

    func hitTest(_ point: CGPoint) -> (measure: Int, units: Double)? {
        for system in systems where point.y >= system.frame.minY - sp * 4 && point.y <= system.frame.maxY + sp * 4 {
            for box in system.measures where point.x >= box.x && point.x < box.endX {
                return (box.index, box.units(forX: point.x))
            }
            if let first = system.measures.first, point.x < first.x { return (first.index, 0) }
            if let last = system.measures.last, point.x >= last.endX { return (last.index, Double(MusicXMLWriter.barUnits)) }
        }
        return nil
    }
}
```

`ScorePageLayout.init` takes `sp` scaled, so the page layout's points are already scaled; then `scaled(by:)` is not needed — remove it and pass `sp: ScorePageLayout.pageStaffSpace * scale` with the page frame `pageSize.points * scale`. But `PageSize.margin` and `headerHeight` are in unscaled points inside `ScorePageLayout`: give `ScorePageLayout.init` a `scale: CGFloat = 1` parameter that multiplies the page size, the margins, the header and the footer, and use it here with `scale`. Add `offsetX(by:)` to `System` in the core (shifting `frame.origin.x`, every box's `x`, `contentX` and onsets) beside `offset(by:)`, with a test in `ScoreSystemLayoutTests` (`moved.measures[0].x == system.measures[0].x + 50`). The PDF (Task 11) uses `scale: 1`.

- [ ] **Step 2: The page renderer**

```swift
import AppKit
import CoreText
import NeuralSheetCore

extension ScoreRenderer {
    /// A page (arrangement design §4): the sheet, the header on page 1, its systems, the footer.
    /// `frame` is the page in the context's coordinates, its systems already there.
    func drawPage(_ page: ScorePageLayout.Page, frame: CGRect, systems: [ScoreSystemLayout.System], takeName: String?,
                  scale: CGFloat, in ctx: CGContext, hits: inout [TabHit], names: inout [NameHit]) {
        ctx.setFillColor(ScorePalette.paper)
        ctx.fill(frame)

        if page.index == 0 {
            drawHeader(in: CGRect(x: frame.minX + PageSize.margin * scale, y: frame.minY + PageSize.margin * scale,
                                  width: frame.width - 2 * PageSize.margin * scale, height: PageSize.headerHeight * scale),
                       takeName: takeName, in: ctx)
        }

        for system in systems {
            drawSystem(system, in: ctx, hits: &hits, names: &names)
        }

        drawFooter(pageIndex: page.index, in: CGRect(x: frame.minX + PageSize.margin * scale,
                                                     y: frame.maxY - (PageSize.margin + ScorePageLayout.footerHeight) * scale,
                                                     width: frame.width - 2 * PageSize.margin * scale,
                                                     height: ScorePageLayout.footerHeight * scale), in: ctx)
    }

    private func drawHeader(in rect: CGRect, takeName: String?, in ctx: CGContext) {
        let sheet = arrangement.sheet
        let title = CTFontCreateWithName(Fonts.sansName(600) as CFString, 3 * sp, nil)
        let subtitle = CTFontCreateWithName(Fonts.sansName(500) as CFString, 1.8 * sp, nil)
        let small = CTFontCreateWithName(Fonts.sansName(500) as CFString, 1.6 * sp, nil)

        TimelineText.draw(sheet.resolvedTitle(takeName: takeName), font: title, colour: ScorePalette.ink,
                          in: CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: 3.6 * sp), anchor: .centred, context: ctx)

        if !sheet.subtitle.isEmpty {
            TimelineText.draw(sheet.subtitle, font: subtitle, colour: ScorePalette.ink,
                              in: CGRect(x: rect.minX, y: rect.minY + 3.6 * sp, width: rect.width, height: 2.2 * sp), anchor: .centred, context: ctx)
        }

        if !sheet.composer.isEmpty {
            TimelineText.draw(sheet.composer, font: small, colour: ScorePalette.ink,
                              in: CGRect(x: rect.minX, y: rect.maxY - 4 * sp, width: rect.width, height: 2 * sp), anchor: .centredRight, context: ctx)
        }

        if !sheet.arranger.isEmpty {
            TimelineText.draw("arr. " + sheet.arranger, font: small, colour: ScorePalette.ink,
                              in: CGRect(x: rect.minX, y: rect.maxY - 2 * sp, width: rect.width, height: 2 * sp), anchor: .centredRight, context: ctx)
        }
    }

    private func drawFooter(pageIndex: Int, in rect: CGRect, in ctx: CGContext) {
        let font = CTFontCreateWithName(Fonts.sansName(400) as CFString, 1.2 * sp, nil)

        if !arrangement.sheet.copyright.isEmpty {
            TimelineText.draw(arrangement.sheet.copyright, font: font, colour: ScorePalette.faint, in: rect, anchor: .centred, context: ctx)
        }

        // The page number at the outer edge: right on odd pages, left on even.
        TimelineText.draw("\(pageIndex + 1)", font: font, colour: ScorePalette.faint, in: rect,
                          anchor: pageIndex % 2 == 0 ? .centredRight : .centredLeft, context: ctx)
    }
}
```

`Fonts.sansName(400)` must exist; if `sansName` only knows 500 and 600, use 500.

- [ ] **Step 3: The view in pages mode**

`ScoreView.draw`: in pages mode, fill the whole rect with `TimelinePalette.cg(Theme.bgPanel)` (the surround), then for each page whose frame intersects `rect`, call `renderer.drawPage(page, frame: pageFrame, systems: systemsOfThatPage, takeName:, scale:, …)`. Keep a `pagesSystems: [[ScoreSystemLayout.System]]` on `ScoreLayout` (per page, view coordinates) so the view can hand each page its systems. In continuous mode draw as before. `ScoreView` gains `var takeName: String?` set by the container from `model.droppedFileName`.

`ScoreContainerView.relayout` builds `ScoreLayout(document:arrangement:width:scale:)`; the scroll view's background colour follows the mode (`bgPanel` for pages, `paper` for continuous). The cursor and following work off `layout.systems` unchanged.

- [ ] **Step 4: Build, render a page, commit**

Build warning-free. In the harness, build an arrangement with `layout = .pages` and a title, render the first page frame, view it. Commit:

```bash
git add app/Packages/NeuralSheetCore app/NeuralSheet/UI/Score
git commit -m "ui: pages in the Score tab, with the header and the footer

A4 or Letter sheets on a grey surround, the title block on the first,
the copyright and page number on every one (arrangement design §6).

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 11: The PDF export

**Files:**
- Create: `app/NeuralSheet/UI/Score/ScorePDF.swift`
- Modify: `app/NeuralSheet/App/AppModel+Arrangement.swift` (`exportPDF()`, `pdfExportFileName()`), `app/NeuralSheet/App/NeuralSheetApp.swift` (menu item)

**Interfaces:**
- Produces: `enum ScorePDF { static func data(document: ScoreDocument, arrangement: ScoreArrangement, takeName: String?) -> Data? }`, `AppModel.exportPDF()`, `AppModel.pdfExportFileName() -> String` (`"<name>_NNTranscription.pdf"` or `"NNTranscription.pdf"`).

- [ ] **Step 1: The PDF**

```swift
import AppKit
import NeuralSheetCore

/// The score's pages as a PDF (arrangement design §5): one PDF page per laid-out page, the
/// renderer drawing into a flipped PDF context exactly as it draws into the view.
enum ScorePDF {
    static func data(document: ScoreDocument, arrangement: ScoreArrangement, takeName: String?) -> Data? {
        var paged = arrangement
        paged.layout = .pages

        let layout = ScorePageLayout(document: document, arrangement: paged, pageSize: paged.pageSize, sp: ScorePageLayout.pageStaffSpace)
        let renderer = ScoreRenderer(document: document, arrangement: paged, sp: layout.sp)
        let data = NSMutableData()

        guard let consumer = CGDataConsumer(data: data as CFMutableData) else { return nil }

        var mediaBox = CGRect(origin: .zero, size: paged.pageSize.points)

        guard let ctx = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else { return nil }

        for page in layout.pages {
            ctx.beginPDFPage(nil)
            // The renderer draws y-down; PDF is y-up.
            ctx.translateBy(x: 0, y: mediaBox.height)
            ctx.scaleBy(x: 1, y: -1)

            var hits: [TabHit] = []
            var names: [NameHit] = []
            renderer.drawPage(page, frame: page.frame, systems: page.systems, takeName: takeName, scale: 1, in: ctx, hits: &hits, names: &names)

            ctx.endPDFPage()
        }

        ctx.closePDF()

        return data as Data
    }
}
```

The renderer's text goes through `TimelineText.draw`, which sets a flipped text matrix for a flipped context; with the context flipped here the same code produces upright text. The glyphs through `ScoreGlyphs.drawGlyph` set the text matrix to identity and use the CTM, which is the flipped one, so they land as in the view.

- [ ] **Step 2: The command and the menu**

In `AppModel+Arrangement.swift`:

```swift
    /// `<source>_NNTranscription.pdf`, or `NNTranscription.pdf` for a recorded take.
    func pdfExportFileName() -> String {
        guard let name = droppedFileName, !name.isEmpty else { return "NNTranscription.pdf" }
        return "\(name)_NNTranscription.pdf"
    }

    /// File → Export PDF…: the pages, whatever the tab shows, through a save panel titled
    /// "Export PDF" in the Music folder.
    func exportPDF() {
        guard canExport, let data = ScorePDF.data(document: scoreDocument(), arrangement: arrangement, takeName: droppedFileName) else { return }

        let panel = NSSavePanel()
        panel.title = "Export PDF"
        panel.message = "Export PDF"
        panel.directoryURL = paths.musicFolder
        panel.nameFieldStringValue = pdfExportFileName()
        panel.allowedContentTypes = [.pdf]
        panel.canCreateDirectories = true

        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            try data.write(to: url, options: .atomic)
        } catch {
            showError("Error", "Could not write the PDF file.")
        }
    }
```

(`import AppKit` and `import UniformTypeIdentifiers` at the top of the file.) In `NeuralSheetApp.swift` after `Export MusicXML…`:

```swift
            Button("Export PDF…") { model.exportPDF() }
                .keyboardShortcut("p", modifiers: [.command, .shift, .option])
                .disabled(!model.canExport)
```

- [ ] **Step 3: Verify the bytes**

Build. In the harness (it links the UI files), call `ScorePDF.data(...)` for the sample score, write `score.pdf`, and open it with `Read` (PDF pages render). Check the header, the systems and the page number.

- [ ] **Step 4: Commit**

```bash
git add app/NeuralSheet/UI/Score/ScorePDF.swift app/NeuralSheet/App/AppModel+Arrangement.swift app/NeuralSheet/App/NeuralSheetApp.swift
git commit -m "app: File → Export PDF…

The score's pages through the same renderer the Score tab draws with.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 12: The Score toolbar and the sheet card

**Files:**
- Create: `app/NeuralSheet/UI/Toolbar/GridControls.swift` (extracted), `app/NeuralSheet/UI/Toolbar/ScoreToolbar.swift`, `app/NeuralSheet/UI/Score/SheetCard.swift`
- Modify: `app/NeuralSheet/UI/Toolbar/EditToolbar.swift` (uses `GridControls`), `app/NeuralSheet/UI/MainView.swift`

**Interfaces:**
- `GridControls(model:)`: the TEMPO, BEAT 1 AT, ⌖, Tap, Detect group and the KEY group as they are in `EditToolbar` today, plus `EditToolbarStyle` helpers (`iconButton`, `labelButton`, `pillLabel`) moved into a shared file-private-free `ToolbarPieces` enum so both toolbars use them. Simplest: move `iconButton`, `labelButton`, `pillLabel` and the two menus into `GridControls.swift` as members of `GridControls`, and have `EditToolbar` call `GridControls(model: model)` in place of the two `HStack`s.
- `ScoreToolbar(model:)`: Continuous / Pages, A4 / Letter (enabled in Pages), `GridControls`, spacer, `Sheet…`, `Export PDF`.
- `SheetCard(model:host:)`: six `TextField`s in the note card's field style and three `MenuCheckbox` rows (`MenuPanel.swift` has `MenuCheckbox`), each writing through `model.setSheet(_:)`.

- [ ] **Step 1: Extract, then build the toolbar**

`ScoreToolbar.body` follows `EditToolbar`'s frame (`Toolbar.Metrics`), with:

```swift
                HStack(spacing: s(2)) {
                    segment("Continuous", isOn: arrangement.layout == .continuous) { model.setScoreLayout(.continuous) }
                    segment("Pages", isOn: arrangement.layout == .pages) { model.setScoreLayout(.pages) }
                }
                .padding(s(2))
                .background(RoundedRectangle(cornerRadius: s(Metrics.corner), style: .circular).fill(Theme.bgControlAlt))

                HStack(spacing: s(2)) {
                    ForEach(PageSize.allCases, id: \.self) { size in
                        segment(size.name, isOn: arrangement.pageSize == size, isEnabled: arrangement.layout == .pages) { model.setPageSize(size) }
                    }
                }
                .padding(s(2))
                .background(RoundedRectangle(cornerRadius: s(Metrics.corner), style: .circular).fill(Theme.bgControlAlt))

                GridControls(model: model)

                Spacer(minLength: 0)

                labelButton("Sheet…", tooltip: "Title, subtitle, composer, arranger, copyright") { showSheetCard() }
                    .background(AnchorCatcher { sheetAnchor = $0 })

                labelButton("Export PDF", tooltip: "Write the pages as a PDF (⌥⇧⌘P)", isEnabled: model.canExport, action: model.exportPDF)
```

`showSheetCard` uses a `PopupMenuPresenter` with `show(from: anchor, width: SheetCard.width, scale: k) { SheetCard(model: model, host: card) }`. `MainView` switches: `.transcribe → Toolbar`, `.edit → EditToolbar`, `.score → ScoreToolbar`.

- [ ] **Step 2: Build and commit**

```bash
git add app/NeuralSheet/UI
git commit -m "ui: a Score toolbar and the sheet card

Continuous or pages, A4 or Letter, the grid and key controls shared
with the Edit toolbar, the sheet's title block, and Export PDF.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 13: The MusicXML export follows the arrangement

**Files:**
- Modify: `app/Packages/NeuralSheetCore/Sources/NeuralSheetCore/MusicXMLWriter.swift`
- Create: `app/Packages/NeuralSheetCore/Sources/NeuralSheetCore/MusicXMLWriter+Tab.swift`
- Test: `app/Packages/NeuralSheetCore/Tests/NeuralSheetCoreTests/MusicXMLWriterTests.swift` (append)
- Modify: `app/NeuralSheet/App/AppModel.swift` (`musicXMLData` passes ids, arrangement and the take name)

**Interfaces:**
- `MusicXMLWriter.data(notes: [NoteEvent], ids: [NoteID?]? = nil, grid: TempoGrid, fifths: Int = 0, title: String? = nil, arrangement: ScoreArrangement = ScoreArrangement(), takeName: String? = nil) -> Data`: the existing four-argument calls keep working.

- [ ] **Step 1: Write the failing tests**

```swift
@Test func theExportFollowsTheArrangement() throws {
    var arrangement = ScoreArrangement()
    var trumpet = PartDisplay()
    trumpet.transposition = 2
    trumpet.clef = .treble
    arrangement.parts[56] = trumpet
    var guitar = PartDisplay()
    guitar.mode = .both
    guitar.transposition = 12
    guitar.clef = .treble8vb
    guitar.tab = TabTemplate.template(id: "guitar")!.setup(preset: TabTemplate.template(id: "guitar")!.presets[0])
    arrangement.parts[24] = guitar
    var hidden = PartDisplay()
    hidden.isHidden = true
    arrangement.parts[0] = hidden
    arrangement.sheet.title = "Reel"
    arrangement.sheet.subtitle = "Set 2"
    arrangement.sheet.composer = "Trad."
    arrangement.sheet.arranger = "A."
    arrangement.sheet.copyright = "© 2026"

    let notes = [
        NoteEvent(startTime: 0, endTime: 0.5, pitch: 60, program: 56),
        NoteEvent(startTime: 0, endTime: 0.5, pitch: 64, program: 24),
        NoteEvent(startTime: 0, endTime: 0.5, pitch: 60, program: 0),
    ]
    let data = MusicXMLWriter.data(notes: notes, ids: nil, grid: TempoGrid(bpm: 120, offsetSeconds: 0, division: .sixteenth),
                                   fifths: 0, title: nil, arrangement: arrangement, takeName: "take")
    let score = try XMLDocument(data: data, options: [])

    #expect(try score.nodes(forXPath: "//part-list/score-part/part-name").map(\.stringValue) == ["Guitar", "Guitar (TAB)", "Trumpet"], "the piano is hidden; the tab is a part of its own")
    #expect(try score.nodes(forXPath: "//work-title").first?.stringValue == "Reel")
    #expect(try score.nodes(forXPath: "//identification/creator[@type='composer']").first?.stringValue == "Trad.")
    #expect(try score.nodes(forXPath: "//identification/creator[@type='arranger']").first?.stringValue == "A.")
    #expect(try score.nodes(forXPath: "//identification/rights").first?.stringValue == "© 2026")
    #expect(try score.nodes(forXPath: "//credit/credit-words").first?.stringValue == "Set 2")

    // The trumpet: written a tone up, D major, with the transpose element MusicXML expects (sounding = written + chromatic).
    #expect(try score.nodes(forXPath: "//part[3]/measure[1]/attributes/key/fifths").first?.stringValue == "2")
    #expect(try score.nodes(forXPath: "//part[3]/measure[1]/attributes/transpose/chromatic").first?.stringValue == "-2")
    #expect(try score.nodes(forXPath: "//part[3]//note/pitch/step").first?.stringValue == "D")

    // The guitar's notation: treble 8vb, written an octave up; its tab: six lines, the tuning, string and fret.
    #expect(try score.nodes(forXPath: "//part[1]/measure[1]/attributes/clef/clef-octave-change").first?.stringValue == "-1")
    #expect(try score.nodes(forXPath: "//part[1]//note/pitch/octave").first?.stringValue == "5")
    #expect(try score.nodes(forXPath: "//part[2]/measure[1]/attributes/clef/sign").first?.stringValue == "TAB")
    #expect(try score.nodes(forXPath: "//part[2]/measure[1]/attributes/staff-details/staff-lines").first?.stringValue == "6")
    #expect(try score.nodes(forXPath: "//part[2]/measure[1]/attributes/staff-details/staff-tuning").count == 6)
    #expect(try score.nodes(forXPath: "//part[2]//note/notations/technical/string").first?.stringValue == "1", "the high E is string 1 in MusicXML's numbering")
    #expect(try score.nodes(forXPath: "//part[2]//note/notations/technical/fret").first?.stringValue == "0")
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd app/Packages/NeuralSheetCore && swift test --filter theExportFollows`
Expected: compile error (no such `data` overload).

- [ ] **Step 3: Write the export**

In `MusicXMLWriter.swift`, replace `data(notes:grid:fifths:title:)` with the new signature (the old one as a forwarding overload). Build the document from `ScoreDocument.build(notes:ids:grid:key:arrangement:)` where `key` is `fifths == 0 ? nil : MusicalKey(tonic: …)`: simpler, pass a `key: MusicalKey?` parameter through from the model (`musicXMLData` has `editor.key`) and keep `fifths` only for the old overload, deriving the key from it as `nil` when 0 and the major key of that signature otherwise (`MusicalKey.major(fifths:)`, a small helper: the tonic is `(fifths * 7) mod 12`). Then:

- `<identification>`: `<creator type="composer">`, `<creator type="arranger">` when non-empty, `<rights>` when non-empty, then the `<encoding>`; `<work-title>` from `sheet.resolvedTitle(takeName:)`; a `<credit page="1"><credit-type>subtitle</credit-type><credit-words>…</credit-words></credit>` when the subtitle is non-empty.
- Parts: for each `ScorePart` of the document, one `<score-part>` for its notation when `part.display.showsNotation` (`P<n>`) and one for its tab when `part.tab != nil` (`P<n>T`, name `"\(part.name) (TAB)"`).
- The notation part's attributes: `<key><fifths>part.writtenFifths</fifths></key>`; the clef from `staff.clef`: treble G2, bass F4, alto C3, tenor C4, the 8vb variants with `<clef-octave-change>-1</clef-octave-change>`, percussion as today; `<transpose><chromatic>-transposition</chromatic></transpose>` when the transposition is not 0 (`<octave-change>` for whole octaves: chromatic `−transposition mod 12` with sign, octave-change `−transposition / 12`; for ±12 write `<chromatic>0</chromatic><octave-change>∓1</octave-change>`). The notes are the `ScoreMeasure` pieces already built (written pitches spelled): rewrite `partXML` to consume `ScoreStaff.measures` instead of re-segmenting, so the writer and the score agree by construction. Rests, ties, chords, dots and staves as today.
- The tab part (`MusicXMLWriter+Tab.swift`): `<clef><sign>TAB</sign><line>5</line></clef>`, `<staff-details><staff-lines>n</staff-lines>` and one `<staff-tuning line="i">` per string from the bottom line (`line="1"`) up with `<tuning-step>`, `<tuning-alter>` when needed and `<tuning-octave>`; each note `<pitch>` (the sounding pitch), `<duration>`, `<voice>1</voice>`, `<type>`, dots, ties, and `<notations><technical><string>n − placement.string</string><fret>placement.fret</fret></technical></notations>`; rests as usual.

- [ ] **Step 4: Run every test, build, wire the model**

`AppModel.musicXMLData()` becomes `MusicXMLWriter.data(notes: notes, ids: document?.notes.map { Optional($0.id) }, grid: editor.grid, key: editor.key, arrangement: arrangement, takeName: droppedFileName)`. `swift test` green; the build warning-free.

- [ ] **Step 5: Commit**

```bash
git add app/Packages/NeuralSheetCore app/NeuralSheet/App/AppModel.swift
git commit -m "core: the MusicXML export follows the arrangement

Clefs and transpositions per part, tab parts with their tuning and
string and fret per note, hidden parts left out, and the sheet's
credits (arrangement design §5).

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 14: Docs

**Files:**
- Modify: `AGENTS.md` (the departures list), `CHANGELOG.md`, `docs/design/2026-09-27-score-view-design.md` (a note at §1 pointing at the arrangement design)

- [ ] **Step 1: Write the three changes**

AGENTS.md, appended to the departures sentence after the Score tab clause: `; the Score tab has an arrangement saved in the project: per-part notation or tab in any tuning with the string per note, clef and transposition, hidden parts, a page layout with the sheet's title block, and File → Export PDF… (design: \`docs/design/2026-09-27-score-arrangement-design.md\`)`.

CHANGELOG.md, one line after the Score tab's: `- Arrange the score: click a part's name in the Score tab for its clef, transposition or tab in any tuning, switch to pages with a title, and File → Export PDF… prints it.`

Score design §1, after the non-goals: `*Since the arrangement design (\`2026-09-27-score-arrangement-design.md\`): per-part display, tablature, pages and a PDF export.*`

- [ ] **Step 2: Commit**

```bash
git add AGENTS.md CHANGELOG.md docs/design/2026-09-27-score-view-design.md
git commit -m "docs: the score arrangement in the departures list, the changelog and the score design

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

## Self-review notes

- Spec coverage: §3.1 → Task 1; §3.2 → Task 2; §3.3 → Task 3; §3.4 → Task 4; §3.5 → Tasks 6–7; §3.6 → Tasks 1 and 11; §4 → Tasks 8–10; §5 → Tasks 5, 11, 13; §6 → Tasks 9, 10, 12; §7 → Task 14.
- The spec's `ScoreArrangement.display(for:)`, `PartDisplay`, `TabSetup`, `SheetMetadata`, `TabTemplate`, `TuningPreset`, `TabFingering.Placement`, `ScoreTabStaff`, `ScoreSystemLayout`, `ScorePageLayout`, `ScoreRenderer`, `TabHit` are used with the same names throughout.
- `ScoreLayout` (UI) changes shape twice (Task 6 wrapper, Task 10 modes); each task's `ScoreView`/`ScoreContainerView` edits are stated where they happen.
