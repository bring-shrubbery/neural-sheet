import AVFoundation
import CoreAudio
import Foundation
import NeuralSheetCore

/// Starting and stopping the AVAudioEngine, building its graph, and rebuilding it when the
/// hardware underneath changes. Main thread.
nonisolated extension PlaybackEngine {
    /// Starts the engine, or throws why it would not. Either way the engine now *should* be
    /// running: a refusal at launch -- the output device busy, or not there yet -- leaves the poll
    /// running and the health check retrying with its backoff, so the failure is a delay rather
    /// than a silent session. The error stays in ``lastStartError`` for the UI to show.
    func start() throws {
        guard !engine.isRunning, !isShutDown else { return }

        shouldRun = true
        resetHealBudget()

        applyDevices()

        // Before `prepare()`, not after `start()`: `prepare()` initialises the AUHAL, and an
        // initialised unit answers kAudioUnitErr_Initialized to a buffer-size request.
        let bufferStatus = requestIOBufferSize()
        lastIOBufferError = bufferStatus == noErr ? nil : bufferStatus

        engine.prepare()

        // The poll first, whatever `start()` says: it is what carries the retries.
        startWrapPoll()

        do {
            try engine.start()
            lastStartError = nil
        } catch {
            lastStartError = error
            throw error
        }

        readIOBufferSize()
    }

    /// A user gesture that wants the output -- Play, a device pick -- hands the health check a
    /// fresh budget, and when the engine is not running makes one attempt now rather than at the
    /// poll's next tick. Not from inside a rebuild, whose own attempt is under way.
    func retryStartIfNeeded() {
        guard !isRebuilding, !isShutDown else { return }

        resetHealBudget()

        guard !engine.isRunning else { return }

        try? start()
    }

    func resetHealBudget() {
        healAttempts = 0
        healDelay = Self.healBackoffSeconds
        healExhausted = false
    }

    func stopEngine() {
        shouldRun = false
        wrapPoll?.cancel()
        wrapPoll = nil
        engine.stop()
    }

    // MARK: - Graph

    // Internal: the init builds the first graph.
    func buildGraph() {
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)
        else { return }

        state.meter = RmsMeter(sampleRate: sampleRate)
        // Its windows are seconds, so a new rate means new buffers. The engine is stopped.
        state.stretcher = TimeStretcher(sampleRate: sampleRate, maxBlockFrames: RenderState.maxBlockFrames)
        state.stretching = false

        let node = AVAudioSourceNode(format: format, renderBlock: makeRenderBlock())
        sourceNode = node

        engine.attach(node)

        // Explicitly, and to the hardware's own format: a device change can hand the output node a
        // different channel count, and the implicit main-mixer connection keeps the one it was made
        // with, which leaves the engine refusing to start.
        engine.connect(engine.mainMixerNode, to: engine.outputNode, format: nil)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        engine.connect(masterMixer, to: engine.mainMixerNode, format: format)

        engine.mainMixerNode.installTap(onBus: 0, bufferSize: 1024, format: nil) {
            [state] buffer, _ in
            state.pushMeter(buffer)
        }
        meterTapInstalled = true
    }

    private func teardownGraph() {
        if meterTapInstalled {
            engine.mainMixerNode.removeTap(onBus: 0)
            meterTapInstalled = false
        }

        if let node = sourceNode {
            engine.disconnectNodeOutput(node)
            engine.detach(node)
            sourceNode = nil
        }

        engine.disconnectNodeOutput(masterMixer)
    }

    /// The common path for "the hardware underneath us changed": our own device switch, and the
    /// health check finding an engine that stopped on its own.
    func rebuildGraph(_ beforeRebuild: () -> Void) {
        guard !isRebuilding, !isShutDown else { return }
        isRebuilding = true
        defer { isRebuilding = false }

        let wasRunning = engine.isRunning
        let wasPlaying = isPlaying
        let position = playheadSeconds

        engine.stop()
        teardownGraph()

        beforeRebuild()

        let rate = engine.outputNode.outputFormat(forBus: 0).sampleRate
        if rate > 0 { sampleRate = rate }

        buildGraph()
        // The synths kept their nodes through the rebuild, but not necessarily the rate.
        synthBank.reconnectForCurrentRate()
        updateGains()

        // The take is stored at the device rate, so new hardware means converting it again.
        if let source = currentSource, source.deviceRate != sampleRate {
            setSource(source)
        }

        // The loop is frames at the device rate, so a new rate means converting it again.
        applyLoop()

        refreshInputTap()

        // `shouldRun` as well as `wasRunning`: the health check only calls this because the engine
        // has already stopped on its own, and that is exactly the case that has to come back up.
        if wasRunning || shouldRun {
            let bufferStatus = requestIOBufferSize()
            lastIOBufferError = bufferStatus == noErr ? nil : bufferStatus

            engine.prepare()

            do {
                try engine.start()
                lastStartError = nil
            } catch {
                lastStartError = error
            }

            readIOBufferSize()
        }

        // The transport survives a device change: the playhead is a position in the take, not in
        // the hardware.
        seek(seconds: position)
        if wasPlaying { play() }

        lastRebuild = Date()
    }
}
