import Foundation
import NeuralSheetCore

/// The engine-facing half of a transcription run, shared by the Mac's `AppModel` and the iOS
/// app's `MobileModel` (iOS app design §2): the hand-off from the engine thread, the streamed
/// notes, the landing and the failure's words. What the run is cut into is the core package's
/// `TranscriptionPlan`; who owns the run, and what the screen shows of it, is each app's.
nonisolated enum TranscriptionRun {
    /// `_updatePostProcessing` while a run streams: the raw notes become what is drawn and
    /// played. There is no document yet; the merge is the whole post-processing.
    static func streamedNotes(_ rawNotes: [NoteEvent]) -> [NoteEvent] {
        mergeOverlappingNotesWithSamePitch(rawNotes)
    }

    /// A finished run's notes as they land: the run's own result, authoritative over the stream
    /// (which is missing any note the model never closed), with the After transcription settings
    /// applied. Once over a stems run's four results is what once per stem would give: the
    /// filter is per note.
    static func landing(_ final: [EngineNote], settings: GlobalSettings) -> [NoteEvent] {
        NoteEvent.landing(final.map(NoteEvent.init(engineNote:)), settings: settings)
    }

    // MARK: - Failure

    static var failedTitle: String {
        String(localized: "Transcription failed.", comment: "Alert title: a run failed")
    }

    /// The model's failure, with its reason when there is one.
    static func failedBody(_ reason: String) -> String {
        reason.isEmpty
            ? String(localized: "The transcription model could not be loaded or run.", comment: "Alert body: a run failed without a reason")
            : String(localized: "The transcription model could not be loaded or run: \(reason).",
                     comment: "Alert body: a run failed; the reason is the engine's, or a sentence from this catalog")
    }

    /// The `<reason>` of the failure dialog: the library's own description, except for a checkpoint
    /// from another release, which is the first place such a file shows up and says what to do.
    /// Shared with the region run's failure dialog and the headless pipeline.
    static func failureReason(_ error: EngineError, modelPath: URL?) -> String {
        if error.isUnsupportedVersion, let modelPath {
            let file = modelPath.lastPathComponent

            return String(localized: "\(file) is for another version of NeuralSheet. Delete it from the models folder, then download it again",
                          comment: "The reason in a failed transcription's alert: the model file is from another release")
        }

        // `EngineError.message` rather than the library's `description` directly: only
        // `TranscriptionEngine` imports `NeuralSheetEngine`, so the app sees the wording
        // through its own type.
        return error.message
    }
}

/// Where the engine thread leaves each chunk for the main actor's 30 Hz drain (§3.4, §11.5).
///
/// The engine reports once per 5 s of audio, on its own thread; the drain runs at the timer's
/// pace and finds something only at the model's. Keeping the hand-off in a buffer rather than
/// hopping every update onto the main actor keeps the C++ shape: nothing the engine does can touch
/// the notes the piano roll is drawing, and a cancelled or failed run leaves nothing half-applied.
///
/// `@unchecked Sendable`: every field is guarded by `lock`.
nonisolated final class TranscriptionStaging: @unchecked Sendable {
    /// What one drain found.
    struct Drained {
        var notes: [EngineNote]
        var finalizedThrough: Double
        var progress: Float

        /// Whether the drain moves the stream on: new notes, or a frontier past the one the
        /// stream has. Gates the post-processing, so it runs at the model's pace -- once per
        /// 5 s of audio -- rather than at the timer's.
        func advances(past finalizedThrough: Double) -> Bool {
            !notes.isEmpty || self.finalizedThrough > finalizedThrough
        }

        /// The drained notes as the app's, to append to the run's raw notes.
        var rawNotes: [NoteEvent] { notes.map(NoteEvent.init(engineNote:)) }
    }

    private let lock = NSLock()
    private var notes: [EngineNote] = []
    private var finalizedThrough = 0.0
    private var progress: Float = 0

    /// The engine thread: adds one chunk's notes and moves the frontier and the progress.
    func stage(_ update: EngineUpdate) {
        lock.lock()
        notes.append(contentsOf: update.newNotes)
        finalizedThrough = max(finalizedThrough, update.finalizedThrough)
        progress = max(progress, update.progress)
        lock.unlock()
    }

    /// The main actor: takes everything staged since the last drain. The frontier and the progress
    /// are left as they are, so a drain that finds no notes still reads the latest of each.
    func drain() -> Drained {
        lock.lock()
        defer { lock.unlock() }

        let drained = notes
        notes = []

        return Drained(notes: drained, finalizedThrough: finalizedThrough, progress: progress)
    }

    /// Before a run, and after one ends: nothing from the last run may leak into the next.
    func reset() {
        lock.lock()
        notes = []
        finalizedThrough = 0
        progress = 0
        lock.unlock()
    }
}

extension NoteEvent {
    /// The engine's note as the app's: the same span, pitch, program and confidence, with the fixed
    /// amplitude of 100/127 the model gives every note (it predicts no velocity).
    nonisolated init(engineNote note: EngineNote) {
        self.init(
            startTime: note.onset, endTime: note.offset, pitch: note.pitch, program: note.program,
            confidence: note.confidence)
    }
}
