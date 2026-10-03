import Foundation
import NeuralSheetCore

/// The mix: the ORIG / MIDI crossfade with its keys and holds, the instrument selection the next
/// run is restricted to, and the strips' faders, mutes, solos and pans.
extension AppModel {
    /// §3.4 step 6, and nowhere else: the next run's instruments start neutral. Opening a project
    /// keeps its mix (§4.2).
    func resetMixerSettingsForLaunch() {
        mixer.resetStoredSettings()
        refreshMixerEntries()
    }

    /// The programs the selection stands for, which the sidebar shows as placeholders (§3.3).
    var selectedPrograms: [Int] { selectedGroups.map(Instruments.program(for:)) }

    /// What one press of `[` or `]` moves the crossfade by.
    static let mixStep = 0.1

    /// The keys: a tenth toward the source (`steps < 0`) or the synth, landing on tenths so a
    /// few presses from wherever the slider was left reach either end exactly. Nothing to move
    /// while the split is on.
    func nudgeMix(steps: Int) {
        guard !stereoSplit else { return }

        let tenths = ((mix + Double(steps) * AppModel.mixStep) / AppModel.mixStep).rounded()

        mix = min(max(tenths * AppModel.mixStep, 0), 1)
    }

    /// What the slider shows: the hold while there is one, the set mix otherwise.
    var effectiveMix: Double { mixHold ?? mix }

    /// What the engine is told. Under the split the set mix means nothing -- both sides play at
    /// full -- so it gets the middle, or a hold's end to silence the other ear.
    // Internal: the mix's didSets in AppModel.swift read it.
    var engineMix: Double { stereoSplit ? (mixHold ?? 0.5) : effectiveMix }

    enum MixSide {
        case source
        case synth
    }

    /// Mouse-down on ORIG or MIDI: that side alone until ``endMixHold()``.
    func beginMixHold(_ side: MixSide) {
        mixHold = side == .source ? 0 : 1
        engine.mix = engineMix
    }

    func endMixHold() {
        guard mixHold != nil else { return }

        mixHold = nil
        engine.mix = engineMix
    }

    // MARK: - Instrument selection

    /// Adds or removes one group. Only before a run: the selection is a decoder constraint, not
    /// a filter, so it cannot change once a transcription exists (§3.3).
    func setSelected(_ group: InstrumentGroup, _ on: Bool) {
        guard !state.hasTranscription else { return }

        var groups = selectedGroups

        if on {
            groups.append(group)
        } else {
            groups.removeAll { $0 == group }
        }

        let normalised = AppModel.normalised(groups)

        if normalised != selectedGroups {
            selectedGroups = normalised
        }
    }

    /// Back to Automatic.
    func clearSelection() {
        guard !state.hasTranscription, !selectedGroups.isEmpty else { return }

        selectedGroups = []
    }

    /// Enumerator order, duplicates dropped: the only shape ``selectedGroups`` is set to.
    static func normalised(_ groups: [InstrumentGroup]) -> [InstrumentGroup] {
        let chosen = Set(groups)

        return InstrumentGroup.allCases.filter(chosen.contains)
    }

    /// Re-derives the sidebar's rows from the notes and the selection, and pushes the faders.
    func refreshMixerEntries() {
        mixer.update(notes: notes, selectedPrograms: selectedPrograms)
        applyMixer()
    }

    // MARK: - Mixer

    func setGain(program: Int, db: Double) {
        mixer.setGain(program: program, db: db)
        applyMixer()
    }

    func setMuted(program: Int, _ muted: Bool) {
        mixer.setMuted(program: program, muted: muted)
        applyMixer()
    }

    func setSoloed(program: Int, _ soloed: Bool) {
        mixer.setSoloed(program: program, soloed: soloed)
        applyMixer()
    }

    /// The strip's pan, −1…1 (click design §2): a mixing setting like the fader, so not on the
    /// undo stack, but in the project, so it marks it edited.
    func setPan(program: Int, _ pan: Double) {
        mixer.setPan(program: program, pan: pan)
        applyMixer()
    }
}
