import Foundation
import NeuralSheetCore
import os

/// The transport bar's side of the model (sub-issue H): play and pause, go to start, seek, the
/// ORIG / MIDI mix with its holds and the stereo split, SPEED, Loop, CLICK, the output level and
/// MUTE -- the Mac's `AppModel+Playback`, `+Mix`, `+Practice` and `+Click` over the same engine,
/// with the arithmetic in the shared `TransportCommands`.
extension MobileModel {
    // MARK: - Transport

    /// Play or pause, starting the engine first if it is not running.
    func togglePlay() {
        guard canPlay else { return }

        if engine.isPlaying {
            engine.pause()
        } else {
            guard startEngineIfNeeded() else { return }

            engine.play()
        }

        syncTransport()
    }

    /// Stop and rewind; the timeline follows ``goToStartGeneration`` back to its left edge.
    func goToStart() {
        guard canPlay else { return }

        engine.stop()
        syncTransport()
        goToStartGeneration &+= 1
    }

    /// A tap on the roll's empty lanes, the ruler, the waveform or the score: the playhead there.
    /// Ignored past the end of the take, as the engine ignores it.
    func seek(toSeconds seconds: Double) {
        guard canPlay else { return }

        engine.seek(seconds: seconds)
        syncTransport()
    }

    /// The mirrors brought up to the engine: running or not, and where the playhead is. The saved
    /// ``playheadSeconds`` moves only when the transport is still, so what observes it (the
    /// score's cursor) is not woken thirty times a second.
    func syncTransport() {
        let running = engine.isPlaying
        let position = engine.playheadSeconds

        if running != isTransportRunning {
            isTransportRunning = running
        }

        if !running, playheadSeconds != position {
            playheadSeconds = position
        }

        if positionSeconds != position {
            positionSeconds = position
        }
    }

    /// The engine's 30 Hz poll: the transport's mirrors -- the take running out included -- the
    /// meters, and a sound bank changed in Settings.
    func transportTick() {
        syncTransport()
        advanceMeters(dt: 1.0 / 30)
        reloadSoundBankIfChanged()
        logMetersIfAsked()
    }

    /// For the simulator and the UI tests: `-logMeters` prints the meters and the transport's
    /// state once a second while the take plays, as `NeuralSheet meters:` lines in the unified log
    /// (subsystem `com.quassum.neuralsheet.ios`, category `meters`).
    private static let logsMeters = ProcessInfo.processInfo.arguments.contains("-logMeters")
    private static let meterLog = Logger(subsystem: "com.quassum.neuralsheet.ios", category: "meters")
    private static var meterLogTicks = 0

    private func logMetersIfAsked() {
        guard Self.logsMeters, isTransportRunning else { return }

        Self.meterLogTicks += 1

        guard Self.meterLogTicks % 30 == 0 else { return }

        let strips = mixer.entries.map { String(format: "%d %.1f", $0.program, instrumentLevelDb(program: $0.program)) }
        let loop = engine.loop.map { String(format: "%.2f-%.2f", $0.lowerBound, $0.upperBound) } ?? "off"

        let line = String(format: "NeuralSheet meters: t %.2f master %.1f dB · mix %.2f split %@ speed %.2f loop %@ click %@ muted %@ · ",
                     positionSeconds, masterLevelDb, effectiveMix, stereoSplit ? "on" : "off", playbackSpeed, loop,
                     clickEnabled ? "on" : "off", outputMuted ? "on" : "off") + strips.joined(separator: " · ")

        Self.meterLog.notice("\(line, privacy: .public)")
    }

    // MARK: - Mix

    /// What the slider shows: the hold while there is one, the set mix otherwise.
    var effectiveMix: Double { mixHold ?? mix }

    enum MixSide {
        case source
        case synth
    }

    /// A finger down on ORIG or MIDI: that side alone until ``endMixHold()``.
    func beginMixHold(_ side: MixSide) {
        mixHold = side == .source ? 0 : 1
    }

    func endMixHold() {
        guard mixHold != nil else { return }

        mixHold = nil
    }

    /// The slider; inert under the split, as on the Mac.
    func setMix(_ value: Double) {
        guard !stereoSplit else { return }

        mix = min(max(value, 0), 1)
    }

    /// The split toggle beside the slider.
    func setStereoSplit(_ on: Bool) {
        stereoSplit = on
    }

    /// The mix, the hold and the split to the engine.
    func applyMix() {
        engine.stereoSplit = stereoSplit
        engine.mix = TransportCommands.engineMix(mix: mix, hold: mixHold, stereoSplit: stereoSplit)
    }

    // MARK: - Speed

    /// The speed popover's slider, landing on its notches.
    func setPlaybackSpeed(_ speed: Double) {
        playbackSpeed = TransportCommands.nudgedSpeed(speed, steps: 0)
    }

    /// The popover's Reset: the take's own speed.
    func resetSpeed() {
        playbackSpeed = 1
    }

    // MARK: - Loop

    /// The Loop button: only over a take that can play.
    func toggleLoop() {
        guard canPlay else { return }

        loopEnabled.toggle()
    }

    /// The stretch the engine repeats, written only when it differs: the toggle, the range and the
    /// take's length all call it.
    func applyLoop() {
        let loop = TransportCommands.loopWindow(enabled: loopEnabled, duration: duration, range: editor.range)

        if engine.loop != loop {
            engine.loop = loop
        }
    }

    // MARK: - Click

    /// CLICK: per project, so an undoable change like the strips'.
    func toggleClick() {
        let before = mixSnapshot()

        clickEnabled.toggle()
        registerMixUndo(before: before)
    }

    /// The engine's switch: CLICK, except while a take is counted in or recorded, when the
    /// recording's own list decides what is heard (`+Recording`).
    func applyClickEnabled() {
        let bank = engine.synthBank
        let enabled = recording != nil || clickEnabled

        bank.clickEnabled = enabled

        // Switched off between a click's note-on and its note-off, the note-off is never sent:
        // harmless for a bank's woodblock, which dies away, but the MIDI synth's fallback tone
        // (no bank on iOS) sustains until told to stop.
        if !enabled, let click = bank.clickInstrument {
            bank.sendAllNotesOff(to: click.node)
        }
    }

    /// The grid's beats over the take, for the click's scheduler; not while a take is counted in
    /// or recorded, whose list is the recording's own.
    func refreshClickTrack() {
        guard recording == nil else { return }

        engine.synthBank.setClickEvents(ClickTrack.events(grid: editor.grid, duration: duration))
    }

    // MARK: - Output

    func setMasterGain(db: Double) {
        masterGainDb = min(max(db, InstrumentMixerState.minGainDb), InstrumentMixerState.maxGainDb)
    }

    func toggleOutputMuted() {
        outputMuted.toggle()
    }
}
