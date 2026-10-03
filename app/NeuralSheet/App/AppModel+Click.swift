import Darwin
import Foundation
import NeuralSheetCore

/// The click and the count-in (click design §2): the metronome on the grid's beats during
/// playback, and the state machine that counts a take in and starts it on the downbeat.
///
/// How the count-in starts the take on the downbeat, to the sample: Record arms the recorder at
/// once (the input tap's graph rebuild is over before the first click) and starts the click on
/// its own clock in the synth bank, which advances by each render block's frames. When that clock
/// reaches the end of the count-in bars, the render thread publishes the host time at which the
/// downbeat will be heard (`DownbeatMark`); the recorder's tap drops everything captured before
/// that host time and cuts the block holding it there. So the take's first sample is fixed by
/// the engine's clock, not by when the main thread notices. The engine's 30 Hz poll then moves
/// the state from `.countingIn` to `.recording` once the downbeat has passed -- up to a poll late,
/// which only the UI sees.
extension AppModel {
    /// How much take the recording's click list covers: an hour of beats, a few thousand notes,
    /// built once at Record. A longer take carries on silently.
    static let recordingClickHorizon = 3600.0

    // MARK: - Playback click

    /// `k` and the CLICK button.
    func toggleClick() {
        clickEnabled.toggle()
    }

    /// What the engine's switch is: the project's CLICK, except while a take is counted in or
    /// recorded, when the recording's own list decides what is heard -- the count-in, then the
    /// take's beats only with Click while recording -- and CLICK is left for playback after it.
    func applyClickEnabled() {
        switch state {
        case .countingIn, .recording:
            engine.synthBank.clickEnabled = true
        case .empty, .audioLoaded, .processing, .populated:
            engine.synthBank.clickEnabled = clickEnabled
        }
    }

    /// The beats of the grid over the take, handed to the click's scheduler whenever the grid or
    /// the take's length changes. Not during a count-in or a recording, whose list is the
    /// recording's own.
    func refreshClickTrack() {
        guard state != .countingIn, state != .recording else { return }

        engine.synthBank.setClickEvents(ClickTrack.events(grid: editor.grid, duration: duration))
    }

    // MARK: - Count-in

    /// Record from empty, with the microphone granted: a count-in or a click during the take
    /// arms the recorder against the click's downbeat; without either the take starts now, as it
    /// always did.
    func beginRecording() {
        let aligned = settings.countInBars > 0 || settings.clickWhileRecording

        startRecording(atDownbeat: aligned)
    }

    /// The recorder is armed: the click's list becomes the count-in (and the take's beats with
    /// Click while recording), its clock starts, and the state is `.countingIn` -- or straight
    /// `.recording` with no count-in bars, the take starting on the clock's first block.
    func startCountIn() {
        let plan = ClickTrack.recording(grid: editor.grid, countInBars: settings.countInBars,
                                        clickDuringTake: settings.clickWhileRecording,
                                        horizon: AppModel.recordingClickHorizon)
        let bank = engine.synthBank

        countInBeats = plan.events.filter { $0.startTime < plan.seconds }.map(\.startTime)

        bank.setClickEvents(plan.events)
        bank.clickEnabled = true
        bank.startClickClock(downbeatSeconds: plan.seconds)

        if plan.seconds > 0 {
            countInRemaining = countInBeats.count
            transition(to: .countingIn)
        } else {
            beginTake()
        }
    }

    /// The engine's poll, 30 Hz on the main queue: the count shown, and the take begun once the
    /// downbeat's host time has passed. The recorder has already started itself at that host
    /// time; this is the UI catching up.
    func pollCountIn() {
        guard state == .countingIn else { return }

        let bank = engine.synthBank

        if let downbeat = bank.downbeat.hostTime, mach_absolute_time() >= downbeat {
            beginTake()
            return
        }

        // "4", "3", "2", "1" as each beat sounds; the first number shows from the press.
        let clock = bank.clickClockSeconds
        let started = countInBeats.count(where: { $0 <= clock })
        let remaining = max(1, countInBeats.count - max(started, 1) + 1)

        if countInRemaining != remaining {
            countInRemaining = remaining
        }
    }

    /// The downbeat: the take is under way, and the grid's bar 1 is its first sample
    /// (issue #19 §9). The click carries on only with Click while recording, as its list says.
    private func beginTake() {
        countInRemaining = nil
        countInBeats = []
        editor.grid.offsetSeconds = 0
        transition(to: .recording)
    }

    /// Esc or Record during the count-in: nothing is kept, back to empty.
    func cancelCountIn() {
        guard state == .countingIn else { return }

        clearNow()
    }

    /// After a take or a cancelled count-in: the click back on the transport, the project's
    /// switch and the project's beats.
    func endRecordingClick() {
        engine.synthBank.stopClickClock()
        countInRemaining = nil
        countInBeats = []
        applyClickEnabled()
        refreshClickTrack()
    }
}
