import Foundation
import NeuralSheetCore

/// File → Export PDF…'s bytes, apart from ``ExportCommands`` because they need the score's
/// renderer, which the Audio Unit (it compiles `ExportCommands.swift` by path) does not carry.
extension ExportCommands {
    /// The score's pages, whatever the Score tab shows, laid out as the Mac prints them; nil when
    /// a PDF context cannot be made.
    @MainActor
    static func pdfData(document: ScoreDocument, arrangement: ScoreArrangement, takeName droppedFileName: String?) -> Data? {
        ScorePDF.data(document: document, arrangement: arrangement, takeName: droppedFileName)
    }
}
