import Foundation
import NeuralSheetCore

/// The Edit menu's bulk commands (editor commands design §4): transpose, velocity, legato, join,
/// split and humanize, each on the selection or every note when nothing is selected, as Quantize
/// does, and each one batch.
nonisolated extension EditingCommands {
    // MARK: - Transpose

    /// Edit → Transpose: the melodic notes by `semitones`, the set kept together at the pitch
    /// edges as an arrow-key nudge is; drums never move (editor commands design §2).
    static func transpose(in document: NoteDocument, selection: Set<NoteID>, semitones: Int) -> EditBatch {
        let ids = selectionOrAll(selection, in: document).filter { id in document.note(id).map { !$0.note.isDrum } ?? false }
        var batch = document.move(ids, deltaSeconds: 0, deltaSemitones: semitones)
        batch.title = String(localized: "Transpose", comment: "Undo title: notes moved up or down")

        return batch
    }

    // MARK: - Velocity

    /// Each velocity times `percent` / 100, clamped to 1…127 by the document.
    static func scaleVelocity(in document: NoteDocument, selection: Set<NoteID>, percent: Int) -> EditBatch {
        let factor = Double(percent) / 100

        return document.setVelocities(selectionOrAll(selection, in: document),
                                      title: String(localized: "Scale Velocity", comment: "Undo title: velocities scaled")) {
            Int((Double($0) * factor).rounded())
        }
    }

    /// Velocity → From Audio: each note's velocity from the take's loudness at its onset, mapped
    /// over the affected notes' range (editor commands design §2). Quick enough for the main
    /// actor: it reads 800 samples a note.
    static func velocityFromAudio(in document: NoteDocument, selection: Set<NoteID>, mono16k: [Float]) -> EditBatch {
        let ids = selectionOrAll(selection, in: document)
        let targets = document.notes.filter { ids.contains($0.id) }
        let velocities = OnsetLoudness.velocities(forOnsets: targets.map(\.note.startTime), mono16k: mono16k)
        let byID = Dictionary(uniqueKeysWithValues: zip(targets.map(\.id), velocities))

        return document.setVelocities(byID, title: String(localized: "Velocity from Audio", comment: "Undo title: velocities set from the audio's loudness"))
    }

    // MARK: - Lengths

    /// Edit → Legato: each note to the next start of its instrument.
    static func legato(in document: NoteDocument, selection: Set<NoteID>) -> EditBatch {
        document.legato(selectionOrAll(selection, in: document))
    }

    /// Edit → Join Notes: same-pitch runs whose gaps are at most 50 ms, or a grid step at the
    /// first note's tempo when snap is on and that is longer (editor commands design §2).
    static func join(in document: NoteDocument, editor: EditorState, playheadSeconds: Double) -> EditBatch {
        let ids = selectionOrAll(editor.selection, in: document)
        let earliest = document.notes.first { ids.contains($0.id) }?.note.startTime ?? playheadSeconds
        let step = editor.snapEnabled ? editor.grid.step(atSeconds: earliest) : 0

        return document.join(ids, gap: max(0.05, step))
    }

    /// Edit → Split at Playhead: every affected note the playhead crosses, in two. Allocates
    /// ids, so it runs on the caller's copy of the document, which is the one to commit on;
    /// answers the halves for the selection.
    static func split(in document: inout NoteDocument, selection: Set<NoteID>,
                      at seconds: Double) -> (batch: EditBatch, halves: Set<NoteID>) {
        document.split(selectionOrAll(selection, in: document), at: seconds)
    }

    // MARK: - Humanize

    /// Edit → Humanize: starts within ±12 ms and velocities within ±8, fresh each time, so it can
    /// be applied again.
    static func humanize<G: RandomNumberGenerator>(in document: NoteDocument, selection: Set<NoteID>,
                                                   using generator: inout G) -> EditBatch {
        document.humanize(selectionOrAll(selection, in: document), timing: 0.012, velocity: 8, using: &generator)
    }
}
