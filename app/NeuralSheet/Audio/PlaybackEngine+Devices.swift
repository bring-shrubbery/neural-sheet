import AVFoundation
import CoreAudio
import Foundation

/// Which hardware the one I/O unit is on: the chosen input and output, the private aggregate
/// that pairs them when they are not one device, the rollback when a device refuses, the I/O
/// buffer size, and the input tap whose presence decides whether the input counts at all.
///
/// Main thread, as everything on ``PlaybackEngine`` is unless it says otherwise; nothing here is
/// reachable from the render block.
nonisolated extension PlaybackEngine {
    // MARK: - Choosing devices

    /// Stops the engine, points the I/O unit at the chosen devices, builds the graph again against
    /// whatever the new hardware's format turns out to be, and starts it back up.
    ///
    /// The whole graph, not just the parts that look stale: new hardware can change the sample rate
    /// and the channel count, and a connection made against the old one is what makes `start()`
    /// return quietly without running.
    func reconfigureDevices() {
        // A device the user just chose gets a fresh budget: whatever made the last one unstartable
        // has nothing to say about this one.
        resetHealBudget()

        rebuildGraph { self.applyDevices() }
    }

    /// Points the I/O unit at the chosen devices.
    ///
    /// One unit serves both directions, so "the chosen input and the chosen output" is one device
    /// to set, not two. Three shapes of it:
    ///
    /// - Nothing chosen: the unit is left on CoreAudio's own default pair, and any aggregate of ours
    ///   is given back.
    /// - An output alone, on a unit that has never had an input side: the bare device, as before.
    /// - Everything else -- a chosen input, or a chosen output on a unit that has had its input side
    ///   enabled: a private aggregate of the pair. See ``InputAggregate`` for why a bare device
    ///   cannot do it, and ``applyAggregate(input:output:)`` for what happens when it cannot either.
    ///
    /// The input only counts while something is pulling it: the node is only instantiated then, and
    /// instantiating it is what asks for microphone access.
    func applyDevices() {
        lastDeviceError = nil

        let wantedInput = inputTap != nil || inputTapInstalled ? inputDevice : nil

        guard outputDevice != nil || wantedInput != nil else {
            releaseAggregate()
            return
        }

        let inputID = wantedInput?.id ?? AudioDevices.defaultInput()?.id
        let outputID = outputDevice?.id ?? AudioDevices.defaultOutput()?.id

        // The aggregate the unit is on already stands for this pair: a rebuild only needs the device
        // set on the unit again.
        if let existing = aggregate, existing.input == inputID, existing.output == outputID,
            Self.setDevice(existing.device, on: engine.outputNode) == noErr
        {
            lastAppliedInputDevice = wantedInput
            lastAppliedOutputDevice = outputDevice
            return
        }

        // A bare output device. Right for a unit that has never had an input side, and refused --
        // with kAudioUnitErr_InvalidPropertyValue, clearing whatever device it had -- by one that
        // has: measured, and the refusal outlives the tap, the take and the restart. Once the unit
        // is on an aggregate of ours it has had one, so the attempt is not made again.
        if let outputDevice, wantedInput == nil, aggregate == nil {
            let status = Self.setDevice(outputDevice.id, on: engine.outputNode)

            if status == noErr {
                lastAppliedOutputDevice = outputDevice
                return
            }

            if status != OSStatus(kAudioUnitErr_InvalidPropertyValue) {
                lastDeviceError = status
                revert(\.outputDevice, on: engine.outputNode, fallback: lastAppliedOutputDevice)
                return
            }
        }

        applyAggregate(input: inputID, output: outputID)
    }

    /// Puts the unit on the aggregate for `input` and `output` -- or on the device itself, when the
    /// two are one duplex device and there is nothing to aggregate -- replacing whatever aggregate
    /// it was on; on failure puts the unit back on the one that was working and both pickers back
    /// to what last took.
    private func applyAggregate(input: AudioDeviceID?, output: AudioDeviceID?) {
        let previous = aggregate
        aggregate = nil

        var created: Aggregate?
        var status = OSStatus(kAudioHardwareBadDeviceError)

        if let input, let output {
            switch InputAggregate.create(input: input, output: output) {
            case .created(let device):
                created = (device: device, input: input, output: output)
                status = Self.setDevice(device, on: engine.outputNode)

            case .sameDevice:
                // A duplex device -- a USB interface, a loopback driver, an aggregate the user made
                // with both directions -- chosen for both sides takes a bare set: it has the input
                // streams the unit's input side wants. `aggregate` stays nil, so the bare path is
                // tried first next time too.
                status = Self.setDevice(output, on: engine.outputNode)

            case .failed(let error):
                status = error
            }
        }

        guard status == noErr else {
            InputAggregate.destroy(created?.device)
            lastDeviceError = status

            // Back onto the aggregate that was working, and it stays alive: a refused set can have
            // cleared the unit's device, and nothing later in the rebuild puts one back on a unit
            // that was cleared rather than orphaned.
            if let previous, Self.setDevice(previous.device, on: engine.outputNode) == noErr {
                aggregate = previous
            } else {
                InputAggregate.destroy(previous?.device)
            }

            // Both, because neither choice is in effect. ``revert`` never names a private device.
            revert(\.inputDevice, on: engine.inputNode, fallback: lastAppliedInputDevice)
            revert(\.outputDevice, on: engine.outputNode, fallback: lastAppliedOutputDevice)
            return
        }

        aggregate = created
        lastAppliedInputDevice = inputTap != nil || inputTapInstalled ? inputDevice : nil
        lastAppliedOutputDevice = outputDevice

        // Only now that the unit is on the new one, and off this one.
        InputAggregate.destroy(previous?.device)
    }

    /// Gives the aggregate back once nothing is chosen any more, so a take from a chosen microphone
    /// does not leave the I/O unit -- and so playback -- on that microphone's aggregate for the
    /// rest of the session.
    ///
    /// Destroying it is the whole of it, and it has to be done with the unit still on it: the
    /// `prepare()`/`start()` that ends the rebuild this is part of puts a unit whose device has gone
    /// away back on CoreAudio's default pair, but does nothing for one whose device was cleared by a
    /// refused set. Pointing it somewhere by hand first would be exactly such a set -- a unit whose
    /// input side has been enabled refuses a bare output-only device -- which is how a finished take
    /// once silenced playback. Only ever called from inside a rebuild, with the engine stopped.
    private func releaseAggregate() {
        guard let existing = aggregate else { return }

        InputAggregate.destroy(existing.device)
        aggregate = nil
    }

    /// Puts the published choice back to the device the I/O unit is really on, so a rejected switch
    /// does not leave the picker naming something that is not playing.
    private func revert(
        _ key: ReferenceWritableKeyPath<PlaybackEngine, AudioDevice?>,
        on node: AVAudioIONode,
        fallback: AudioDevice?
    ) {
        // By id, not by looking the id up in the pickers' lists: the unit can be on something the
        // lists leave out, and naming it is still better than publishing nil. A private device is
        // the exception -- our own aggregate, or the `CADefaultDeviceAggregate` CoreAudio keeps
        // behind the defaults -- since no picker should ever show one.
        let inUse = Self.currentDevice(of: node)
            .flatMap { AudioDevices.isPrivate(device: $0) ? nil : AudioDevices.device(withID: $0) }

        isRevertingDevice = true
        self[keyPath: key] = inUse ?? fallback
        isRevertingDevice = false
    }

    @discardableResult
    private static func setDevice(_ id: AudioDeviceID, on node: AVAudioIONode) -> OSStatus {
        guard let unit = node.audioUnit else { return OSStatus(kAudioUnitErr_Uninitialized) }

        var deviceID = id

        return AudioUnitSetProperty(
            unit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &deviceID,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
    }

    /// Which device the node's I/O unit is on right now, whatever was asked for.
    private static func currentDevice(of node: AVAudioIONode) -> AudioDeviceID? {
        guard let unit = node.audioUnit else { return nil }

        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)

        let status = AudioUnitGetProperty(
            unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &deviceID,
            &size)

        return status == noErr && deviceID != kAudioObjectUnknown ? deviceID : nil
    }

    // MARK: - I/O buffer

    /// Asks for the small I/O buffer, before the engine is prepared.
    ///
    /// Two routes, because neither works on its own: the AUHAL takes the property only while it is
    /// uninitialised, and it stays initialised across a stop, so a restart has to go to the device
    /// instead. The request is advisory either way — the HAL clamps it to what the device supports
    /// and to what other clients have asked for — which is why ``readIOBufferSize()`` reports what
    /// actually happened rather than what was asked.
    func requestIOBufferSize() -> OSStatus {
        var frames = Self.requestedIOBufferFrames
        let size = UInt32(MemoryLayout<UInt32>.size)

        var status = OSStatus(kAudioUnitErr_Uninitialized)

        if let unit = engine.outputNode.audioUnit {
            status = AudioUnitSetProperty(
                unit, kAudioDevicePropertyBufferFrameSize, kAudioUnitScope_Global, 0, &frames, size)
        }

        if status != noErr, let device = Self.currentDevice(of: engine.outputNode) {
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyBufferFrameSize,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )

            status = AudioObjectSetPropertyData(device, &address, 0, nil, size, &frames)
        }

        return status
    }

    /// Reads back the frame count the device settled on into ``ioBufferFrames``.
    @discardableResult
    func readIOBufferSize() -> Int {
        var frames = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        var status = OSStatus(kAudioUnitErr_Uninitialized)

        if let unit = engine.outputNode.audioUnit {
            status = AudioUnitGetProperty(
                unit, kAudioDevicePropertyBufferFrameSize, kAudioUnitScope_Global, 0, &frames, &size)
        }

        if status != noErr, let device = Self.currentDevice(of: engine.outputNode) {
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyBufferFrameSize,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )

            status = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &frames)
        }

        ioBufferFrames = status == noErr ? Int(frames) : 0

        return ioBufferFrames
    }

    // MARK: - Input tap

    /// Puts the tap on or takes it off, and restarts the engine when that changed whether the input
    /// node is in use at all.
    ///
    /// The restart is not optional: the I/O unit enables its input side when the engine starts, from
    /// whether anything is pulling the input node, so a tap installed on an engine that started
    /// without one is never called. Coming back through ``rebuildGraph(_:)`` is what re-enables it.
    func refreshInputTap() {
        let wasInstalled = inputTapInstalled

        if inputTapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            inputTapInstalled = false
        }

        defer {
            if inputTapInstalled != wasInstalled {
                // A no-op while a rebuild is already in flight, which is where this call came
                // from. Through `applyDevices` rather than empty-handed: a tap that has just come
                // off is when the aggregate behind it is given back, and the devices have to be
                // applied again over the top of that.
                rebuildGraph { self.applyDevices() }
            }
        }

        guard let inputTap else { return }

        // Before the format is read, not after: the node reports the format of the device its unit
        // is on, and a tap installed with the last device's rate captures at the wrong one.
        applyDevices()

        let format = engine.inputNode.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { return }

        // nil, not the format just read: a device switch settles a moment after it is asked for, and
        // an explicit format that no longer matches the node's live one is an uncatchable ObjC
        // exception out of `installTap`. The tap's own buffers carry the format either way.
        engine.inputNode.installTap(onBus: 0, bufferSize: 1024, format: nil) { buffer, time in
            inputTap(buffer, time)
        }
        inputTapInstalled = true
    }
}
