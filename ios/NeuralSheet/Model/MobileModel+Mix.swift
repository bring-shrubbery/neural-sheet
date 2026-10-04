import Foundation
import NeuralSheetCore

/// The strips' side of the model (sub-issue H): the instruments the notes and the selection
/// stand for, each one's fader, mute, solo and pan, the meters, the highlight on a tap, and the
/// strip menu's whole-instrument commands -- the Mac's `AppModel+Mix`, `+Meters` and
/// `+Instruments` without the window.
///
/// The mix is project state, not a note edit, and on the Mac it is not undoable; here a change
/// must reach the undo manager for the document to save it (as the arrangement's does), so each
/// toggle, and each fader or pan drag as a whole, is one "Mix" entry that Undo puts back.
extension MobileModel {
    // MARK: - Instrument selection

    /// Adds or removes one group, as the Mac's `setSelected`. Not while a run is in flight: the
    /// run has its own copy, and a change would only mislead.
    func setSelected(_ group: InstrumentGroup, _ on: Bool) {
        guard run == nil else { return }

        var groups = selectedGroups

        if on {
            groups.append(group)
        } else {
            groups.removeAll { $0 == group }
        }

        let normalised = MobileModel.normalised(groups)

        if normalised != selectedGroups {
            selectedGroups = normalised
        }
    }

    /// Back to Automatic.
    func clearSelection() {
        guard run == nil, !selectedGroups.isEmpty else { return }

        selectedGroups = []
    }

    /// Enumerator order, duplicates dropped, as the Mac keeps ``selectedGroups``.
    static func normalised(_ groups: [InstrumentGroup]) -> [InstrumentGroup] {
        let chosen = Set(groups)

        return InstrumentGroup.allCases.filter(chosen.contains)
    }

    /// The programs the selection stands for, which the strips show as placeholders.
    var selectedPrograms: [Int] { selectedGroups.map(Instruments.program(for:)) }

    // MARK: - Strips

    /// Re-derives the strips from the notes and the selection, and pushes the faders.
    func refreshMixerEntries() {
        var updated = mixer
        updated.update(notes: document?.events ?? streamedNotes, selectedPrograms: selectedPrograms)

        if updated != mixer {
            mixer = updated
        }

        engine.synthBank.apply(mixer: mixer)

        if let highlightedProgram, !mixer.entries.contains(where: { $0.program == highlightedProgram }) {
            self.highlightedProgram = nil
        }
    }

    /// A fader moving. `dragging` while the finger is down: the drag is one undo entry, registered
    /// by ``endMixDrag()``.
    func setGain(program: Int, db: Double, dragging: Bool = false) {
        changeMix(dragging: dragging) { $0.setGain(program: program, db: db) }
    }

    /// The strip's pan, −1…1.
    func setPan(program: Int, _ pan: Double, dragging: Bool = false) {
        changeMix(dragging: dragging) { $0.setPan(program: program, pan: pan) }
    }

    func setMuted(program: Int, _ muted: Bool) {
        changeMix(dragging: false) { $0.setMuted(program: program, muted: muted) }
    }

    func setSoloed(program: Int, _ soloed: Bool) {
        changeMix(dragging: false) { $0.setSoloed(program: program, soloed: soloed) }
    }

    /// The click's fader in the output popover, −36 (silence) … +6 dB.
    func setClickGain(db: Double, dragging: Bool = false) {
        let before = mixSnapshot()

        clickGainDb = min(max(db, InstrumentMixerState.minGainDb), InstrumentMixerState.maxGainDb)
        noteMixChange(before: before, dragging: dragging)
    }

    /// The finger lifted off a fader or a pan: the drag's one undo entry.
    func endMixDrag() {
        guard let before = mixBeforeDrag else { return }

        mixBeforeDrag = nil
        registerMixUndo(before: before)
    }

    /// A tap on a strip's name: singles the instrument out on the roll, or lets it go when it is
    /// the one already singled out. Over notes that can be edited the tap also makes it the
    /// target, as a strip click in the Mac's Edit tab does.
    func toggleHighlight(program: Int) {
        guard mixer.entries.contains(where: { $0.program == program }) else { return }

        highlightedProgram = highlightedProgram == program ? nil : program

        if canEdit {
            setTargetProgram(program)
        }
    }

    // MARK: - Meters

    /// One instrument's level after ballistics, or the floor for a program not in the mix.
    func instrumentLevelDb(program: Int) -> Double {
        instrumentLevels[program] ?? MeterScale.minDb
    }

    /// One frame of the meters (`MeterLevels`), published only where they moved; a program that
    /// left the mix is pruned, as on the Mac.
    func advanceMeters(dt: Double) {
        let bank = engine.synthBank
        let reading = meterLevels.advance(dt: dt, renderedFrames: bank.renderedFrames, blockSeconds: 0,
                                          masterInput: engine.masterLevelDb, programs: mixer.entries.map(\.program),
                                          level: { bank.levelDb(program: $0) })

        if reading.master != masterLevelDb {
            masterLevelDb = reading.master
        }

        for (program, level) in reading.instruments where instrumentLevels[program] != level {
            instrumentLevels[program] = level
        }

        if instrumentLevels.count != reading.instruments.count {
            for program in instrumentLevels.keys where reading.instruments[program] == nil {
                instrumentLevels[program] = nil
            }
        }
    }

    // MARK: - Whole-instrument commands (region design §4.1)

    /// Every note of `program` to `destination`; a merge when `destination` is already in the
    /// mix. The target follows, as on the Mac.
    func reassignInstrument(_ program: Int, to destination: Int) {
        guard let document = editableDocument(for: program) else { return }

        let followsTarget = editor.targetProgram == program

        commit(document.reassign(program: program, to: destination))

        if followsTarget {
            setTargetProgram(destination)
        }
    }

    /// The notes of `program` at or above `pitch` (or below it) to `destination`.
    func splitInstrument(_ program: Int, atPitch pitch: Int, sendingAbove: Bool, to destination: Int) {
        guard let document = editableDocument(for: program) else { return }

        commit(document.split(program: program, atPitch: pitch, sendingAbove: sendingAbove, to: destination))
    }

    /// Every note of `program` gone; its fader, mute and solo stay, so an undo brings the strip
    /// back as it was.
    func deleteInstrument(_ program: Int) {
        guard let document = editableDocument(for: program) else { return }

        commit(document.deleteInstrument(program: program))
    }

    /// The document, when it may change and `program` is a strip; any drag is cancelled first.
    private func editableDocument(for program: Int) -> NoteDocument? {
        guard canEdit, let document, mixer.entries.contains(where: { $0.program == program }) else { return nil }

        _ = dragCanceller?()

        return document
    }

    // MARK: - Undo

    /// What a "Mix" entry puts back: the strips' settings and the click's.
    struct MixSnapshot: Equatable {
        var channels: [Int: InstrumentChannelSettings]
        var clickEnabled: Bool
        var clickGainDb: Double
    }

    func mixSnapshot() -> MixSnapshot {
        MixSnapshot(channels: mixer.settings, clickEnabled: clickEnabled, clickGainDb: clickGainDb)
    }

    private func changeMix(dragging: Bool, _ change: (inout InstrumentMixerState) -> Void) {
        let before = mixSnapshot()
        var updated = mixer
        change(&updated)

        guard updated != mixer else { return }

        mixer = updated
        engine.synthBank.apply(mixer: mixer)
        noteMixChange(before: before, dragging: dragging)
    }

    /// A drag keeps where it started for ``endMixDrag()``; anything else is its own entry now.
    private func noteMixChange(before: MixSnapshot, dragging: Bool) {
        if dragging {
            if mixBeforeDrag == nil { mixBeforeDrag = before }
        } else if let started = mixBeforeDrag {
            mixBeforeDrag = nil
            registerMixUndo(before: started)
        } else {
            registerMixUndo(before: before)
        }
    }

    func registerMixUndo(before: MixSnapshot) {
        guard let undoManager, before != mixSnapshot() else { return }

        undoManager.registerUndo(withTarget: self) { model in
            let after = model.mixSnapshot()
            model.restoreMix(before)
            model.registerMixUndo(before: after)
        }
        undoManager.setActionName(String(localized: "Mix", comment: "Undo title: a change to the strips' faders, mutes, solos or pans, or to the click"))
    }

    private func restoreMix(_ snapshot: MixSnapshot) {
        var updated = mixer
        updated.settings = snapshot.channels
        mixer = updated
        engine.synthBank.apply(mixer: mixer)
        clickEnabled = snapshot.clickEnabled
        clickGainDb = snapshot.clickGainDb
    }
}
