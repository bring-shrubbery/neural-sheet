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
