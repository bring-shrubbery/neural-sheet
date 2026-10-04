import Foundation

/// The dragged file's name (Audio Unit design §2, "UI": *Drag MIDI out*): after the host's track
/// when the host names it (`AUAudioUnit.contextName`), else "NeuralSheet Transcription", with what
/// a file name cannot hold replaced. Free of AU types (design §3).
nonisolated enum PluginDragNames {
    static let fallback = "NeuralSheet Transcription"

    /// The name without its extension.
    static func baseName(contextName: String?) -> String {
        let cleaned = (contextName ?? "")
            .map { $0 == "/" || $0 == ":" || $0.isNewline ? "-" : $0 }
            .reduce(into: "") { $0.append($1) }
            .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))

        return cleaned.isEmpty ? fallback : cleaned
    }

    /// `<track>.mid`, or `.musicxml` with ⌥ held.
    static func fileName(contextName: String?, musicXML: Bool) -> String {
        baseName(contextName: contextName) + (musicXML ? ".musicxml" : ".mid")
    }
}
