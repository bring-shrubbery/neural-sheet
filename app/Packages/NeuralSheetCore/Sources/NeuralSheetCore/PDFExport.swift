import Foundation

/// What the PDF export decides in core (arrangement design §3.6): its file name, the MIDI and
/// MusicXML exports' rule with the PDF's extension. The pages themselves are drawn in the app.
public enum PDFExport {
    /// `"song_NNTranscription.pdf"`, or `"NNTranscription.pdf"` for a recorded take.
    public static func fileName(sourceFileNameWithoutExtension: String?) -> String {
        guard let name = sourceFileNameWithoutExtension, !name.isEmpty else {
            return "NNTranscription.pdf"
        }

        return "\(name)_NNTranscription.pdf"
    }
}
