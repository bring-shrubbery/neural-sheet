import Foundation
import NeuralSheetCore

/// The names `NeuralSheetCore` gives in English -- instruments, clefs, tunings, modes, export
/// choices, the edits' undo titles -- in the user's language on screen (localization design §2).
///
/// Looked up at display time in the `Core` string table under the English name, rather than
/// localized inside the package: the same names go into the files the app writes (a MIDI
/// track's name, a MusicXML part's), which stay English whatever the language, and the package
/// and its tests stay locale-free. A name the table does not hold -- `program_57`, a version's
/// own name -- reads as it is.
nonisolated enum CoreNames {
    static let table = "Core"

    static func localized(_ english: String) -> String {
        Bundle.main.localizedString(forKey: english, value: english, table: table)
    }
}

extension InstrumentInfo {
    /// The instrument's name in the user's language.
    nonisolated var localizedName: String { CoreNames.localized(name) }
}

extension MusicalKey.Mode {
    /// "Major", "Dur", "Mayor": capitalised as a menu title.
    nonisolated var localizedTitle: String { CoreNames.localized(name.capitalized) }
}

extension PageSize {
    nonisolated var localizedName: String { CoreNames.localized(name) }
}

extension ClefChoice {
    nonisolated var localizedName: String { CoreNames.localized(name) }
}

extension PartDisplay.Mode {
    nonisolated var localizedName: String { CoreNames.localized(name) }
}

extension TabTemplate {
    nonisolated var localizedName: String { CoreNames.localized(name) }
}

extension TuningPreset {
    nonisolated var localizedName: String { CoreNames.localized(name) }
}

extension AudioExportWhat {
    nonisolated var localizedTitle: String { CoreNames.localized(title) }
}

extension AudioExportFormat {
    nonisolated var localizedTitle: String { CoreNames.localized(title) }
}

extension ModelSize {
    nonisolated var localizedName: String { CoreNames.localized(displayName) }
    nonisolated var localizedHint: String { CoreNames.localized(hint) }
}
