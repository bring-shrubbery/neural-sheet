import Testing

@testable import NeuralSheetCore

@Test func canPlayStates() {
    #expect(AppState.audioLoaded.canPlay)
    #expect(AppState.processing.canPlay)
    #expect(AppState.populated.canPlay)
    #expect(!AppState.empty.canPlay)
    #expect(!AppState.recording.canPlay)
}

@Test func hasTranscriptionStates() {
    #expect(AppState.processing.hasTranscription)
    #expect(AppState.populated.hasTranscription)
    #expect(!AppState.empty.hasTranscription)
    #expect(!AppState.recording.hasTranscription)
    #expect(!AppState.audioLoaded.hasTranscription)
}
