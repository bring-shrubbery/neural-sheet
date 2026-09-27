import Foundation
import Testing

@testable import NeuralSheetCore

@Test func pdfFileNamesFollowTheMidiRule() {
    #expect(PDFExport.fileName(sourceFileNameWithoutExtension: "song") == "song_NNTranscription.pdf")
}

@Test func pdfFileNameFallsBackWhenThereIsNoSource() {
    #expect(PDFExport.fileName(sourceFileNameWithoutExtension: nil) == "NNTranscription.pdf")
    #expect(PDFExport.fileName(sourceFileNameWithoutExtension: "") == "NNTranscription.pdf")
}
