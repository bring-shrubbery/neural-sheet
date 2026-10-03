import Foundation
import NeuralSheetCore

/// A finished headless run's notes as the app would land them, and the three files written from
/// them (batch and CLI design §2).
///
/// The landing is the app's: the After transcription settings filter the model's notes
/// (`NoteEvent.landing`), and the document is made from them merged, as `installDocument` makes
/// it. Detect is the Detect button's: the tempo map and the downbeat from the audio, then -- only
/// when a tempo was found, as there -- the key and the chords from the notes. Everything else is
/// a new project's default, so the files match an export from a project opened fresh.
nonisolated struct HeadlessResult {
    let rawNotes: [NoteEvent]
    let document: NoteDocument
    let grid: TempoGrid
    let key: MusicalKey?
    let chords: [ChordEvent]
    let source: SourceAudio
    let request: HeadlessTranscription.Request
    let settings: GlobalSettings

    init(engineNotes: [EngineNote], source: SourceAudio, request: HeadlessTranscription.Request,
         settings: GlobalSettings) {
        let raw = NoteEvent.landing(engineNotes.map(NoteEvent.init(engineNote:)), settings: settings)
        let document = NoteDocument(events: mergeOverlappingNotesWithSamePitch(raw))

        var grid = TempoGrid()
        var key: MusicalKey?
        var chords: [ChordEvent] = []

        if request.detect, let estimate = TempoEstimator.estimate(mono16k: source.mono16k, meter: grid.timeSignature) {
            grid.replaceMap(estimate.segments, offsetSeconds: estimate.downbeatSeconds)
            key = KeyEstimator.estimate(notes: document.events)

            if document.events.contains(where: { !$0.isDrum }) {
                let notesEnd = document.events.map(\.endTime).max() ?? 0
                chords = ChordDetector.detect(notes: document.events, grid: grid, key: key,
                                              duration: max(source.duration, notesEnd))
            }
        }

        self.rawNotes = raw
        self.document = document
        self.grid = grid
        self.key = key
        self.chords = chords
        self.source = source
        self.request = request
        self.settings = settings
    }

    /// The take's name: the input's, what the app's title and export names show.
    var takeName: String? { source.droppedFileName }

    // MARK: - Files

    func write(_ output: HeadlessTranscription.Output, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)

        switch output {
        case .midi:
            try midiData().write(to: url, options: .atomic)
        case .musicXML:
            try musicXMLData().write(to: url, options: .atomic)
        case .project:
            try writeProject(to: url)
        }
    }

    /// `AppModel.midiData()` for a fresh project: the grid's tempo map, no markers, every pan
    /// centred.
    func midiData() -> Data {
        MidiFileWriter.data(notes: document.events, grid: grid, mode: settings.midiOverflowMode)
    }

    /// `AppModel.musicXMLData()` for a fresh project: the default arrangement, titled after the take.
    func musicXMLData() -> Data {
        MusicXMLWriter.data(notes: document.events, ids: document.notes.map { Optional($0.id) }, grid: grid,
                            key: key, arrangement: ScoreArrangement(), takeName: takeName, chords: chords)
    }

    /// A project that opens in the app like a saved one: the audio copied in, the run's
    /// selection, the grid, the key and the chords, everything else at its default.
    func writeProject(to url: URL) throws {
        guard let audio = source.sourcePath else { throw ProjectError.couldNotWrite("The audio has no file to copy.") }

        var state = ProjectState()
        state.audioFileName = audio.lastPathComponent
        state.audioDisplayName = takeName
        state.selectedGroups = request.instruments.map(\.rawValue)
        state.exportTempo = grid.bpm
        state.gridOffsetSeconds = grid.offsetSeconds
        state.gridDivision = grid.division
        state.gridSegments = grid.segments
        state.gridSwing = grid.swing
        state.key = key
        state.chords = chords

        let transcription = ProjectTranscription(sourceSampleCount: source.mono16k.count, rawNotes: rawNotes,
                                                 document: document)

        try ProjectPackage(state: state, transcription: transcription).write(to: url, audioSource: audio)
    }
}
