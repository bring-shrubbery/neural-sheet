import AVFoundation
import CoreAudio
import Foundation

/// Which hardware the one I/O unit is on: the chosen input and output -- a device, or System
/// Audio or an app through a process tap (system audio design §2) -- the private aggregate that
/// pairs them when they are not one device, the rollback when a device refuses, the teardown at
/// quit, and the input tap whose presence decides whether the input counts at all.
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

    /// What an aggregate's input side stands for: a hardware input, or the tap it was made
    /// around (system audio design §2). What decides whether the aggregate the unit is on can be
    /// reused for the pair now wanted.
    enum AggregateInput: Equatable {
        case device(AudioDeviceID)
        case tap(ProcessTap.Kind)
    }

    /// A private aggregate of ours, the pair it stands for, and the process tap that is its input
    /// when it has one -- owned together, because they are destroyed together and in this order.
    struct Aggregate {
        let device: AudioDeviceID
        let input: AggregateInput
        let output: AudioDeviceID
        let tap: ProcessTap?

        /// The aggregate, then its tap: a tap in a live aggregate is in use (system audio design
        /// §2). Never while the I/O unit is running on it.
        func destroy() {
            InputAggregate.destroy(device)
            tap?.destroy()
        }
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
    ///   System Audio and an app are always this shape: the aggregate is what carries the tap.
    ///
    /// The input only counts while something is pulling it: the node is only instantiated then, and
    /// instantiating it is what asks for microphone access. A tap is made, and the system's audio
    /// recording permission asked for, at the same moment.
    func applyDevices() {
        guard !isShutDown else { return }

        lastDeviceError = nil

        let wantedInput = inputTap != nil || inputTapInstalled ? recordingInput : nil

        guard outputDevice != nil || wantedInput != nil else {
            releaseAggregate()
            return
        }

        let input: AggregateInput? =
            if let kind = wantedInput?.tapKind {
                .tap(kind)
            } else {
                (wantedInput?.device ?? AudioDevices.defaultInput()).map { .device($0.id) }
            }

        let outputID = outputDevice?.id ?? AudioDevices.defaultOutput()?.id

        // The aggregate the unit is on already stands for this pair: a rebuild only needs the device
        // set on the unit again. A tap's aggregate keeps its tap.
        if let existing = aggregate, existing.input == input, existing.output == outputID,
            Self.setDevice(existing.device, on: engine.outputNode) == noErr
        {
            lastAppliedRecordingInput = wantedInput
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
                revert(\.outputDevice, on: engine.outputNode, fallback: lastAppliedOutputDevice) { $0 }
                return
            }
        }

        applyAggregate(input: input, output: outputID)
    }

    /// Puts the unit on the aggregate for `input` and `output` -- or on the device itself, when the
    /// two are one duplex device and there is nothing to aggregate -- replacing whatever aggregate
    /// it was on; on failure puts the unit back on the one that was working and both pickers back
    /// to what last took.
    ///
    /// Every path out destroys what it made and does not keep: a tap whose aggregate could not be
    /// made, an aggregate (and its tap) the unit refused, the previous aggregate (and its tap)
    /// once the unit is off it.
    private func applyAggregate(input: AggregateInput?, output: AudioDeviceID?) {
        let previous = aggregate
        aggregate = nil

        var created: Aggregate?
        var status = OSStatus(kAudioHardwareBadDeviceError)

        switch (input, output) {
        case (.device(let inputID)?, let output?):
            switch InputAggregate.create(input: inputID, output: output) {
            case .created(let device):
                created = Aggregate(device: device, input: .device(inputID), output: output, tap: nil)
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

        case (.tap(let kind)?, let output?):
            (created, status) = makeTapAggregate(kind: kind, output: output)

        default:
            break
        }

        guard status == noErr else {
            created?.destroy()
            lastDeviceError = status

            // Back onto the aggregate that was working, and it stays alive: a refused set can have
            // cleared the unit's device, and nothing later in the rebuild puts one back on a unit
            // that was cleared rather than orphaned. Not onto a tap nobody wants any more, though:
            // that would go on capturing the Mac's audio after the take. Destroyed instead, which
            // orphans the unit, and the rebuild's start puts an orphaned unit on the defaults.
            if let previous, previous.tap == nil || previous.input == input,
                Self.setDevice(previous.device, on: engine.outputNode) == noErr
            {
                aggregate = previous
            } else {
                previous?.destroy()
            }

            // Both, because neither choice is in effect. ``revert`` never names a private device.
            revert(\.recordingInput, on: engine.inputNode, fallback: lastAppliedRecordingInput) {
                .device($0)
            }
            revert(\.outputDevice, on: engine.outputNode, fallback: lastAppliedOutputDevice) { $0 }
            return
        }

        aggregate = created
        lastAppliedRecordingInput = inputTap != nil || inputTapInstalled ? recordingInput : nil
        lastAppliedOutputDevice = outputDevice

        // An app's take ends when the app quits (system audio design §2). The watch belongs to the
        // tap and goes with it. Hopped off the HAL's callback: ending the take destroys the tap,
        // which removes the listener, and that is not done from inside the listener itself.
        created?.tap?.watchProcessExit { [weak self] in
            DispatchQueue.main.async {
                self?.onTappedProcessExited?()
            }
        }

        // Only now that the unit is on the new one, and off this one.
        previous?.destroy()
    }

    /// A tap of `kind` and an aggregate around it with `output`, the unit pointed at it; or the
    /// status that stopped it, with whatever was made by then already destroyed except an
    /// aggregate the unit refused, which comes back for the caller to destroy with its tap. A
    /// tap that could not be made is also ``lastTapError``.
    private func makeTapAggregate(kind: ProcessTap.Kind, output: AudioDeviceID) -> (Aggregate?, OSStatus) {
        let tap: ProcessTap
        lastTapError = nil

        do {
            tap = try ProcessTap.create(kind: kind)
        } catch {
            let status = (error as? ProcessTap.Failure)?.status ?? OSStatus(kAudioHardwareUnspecifiedError)
            lastTapError = status
            return (nil, status)
        }

        switch InputAggregate.create(tap: tap, output: output) {
        case .created(let device):
            let created = Aggregate(device: device, input: .tap(kind), output: output, tap: tap)
            return (created, Self.setDevice(device, on: engine.outputNode))

        case .failed(let error):
            tap.destroy()
            return (nil, error)

        case .sameDevice:
            // Never for a tap; a refusal all the same.
            tap.destroy()
            return (nil, OSStatus(kAudioHardwareBadDeviceError))
        }
    }

    /// Gives the aggregate back once nothing is chosen any more, so a take from a chosen microphone
    /// does not leave the I/O unit -- and so playback -- on that microphone's aggregate for the
    /// rest of the session. A tap's aggregate goes with its tap.
    ///
    /// Destroying it is the whole of it, and it has to be done with the unit still on it: the
    /// `prepare()`/`start()` that ends the rebuild this is part of puts a unit whose device has gone
    /// away back on CoreAudio's default pair, but does nothing for one whose device was cleared by a
    /// refused set. Pointing it somewhere by hand first would be exactly such a set -- a unit whose
    /// input side has been enabled refuses a bare output-only device -- which is how a finished take
    /// once silenced playback. Only ever called with the engine stopped: from inside a rebuild, or
    /// by ``shutDown()``.
    private func releaseAggregate() {
        guard let existing = aggregate else { return }

        aggregate = nil
        existing.destroy()
    }

    /// The app is quitting (system audio design §2): the engine stops for good and the aggregate
    /// and its tap are destroyed now, rather than left for the process's exit to take down.
    /// Private aggregates and taps do not outlive the process, but nothing of ours is left to
    /// that. From `applicationWillTerminate`; nothing restarts the engine or makes a tap after.
    func shutDown() {
        guard !isShutDown else { return }
        isShutDown = true

        stopEngine()

        // Directly, not through ``inputTap``, whose `didSet` would rebuild the graph.
        if inputTapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            inputTapInstalled = false
        }

        releaseAggregate()
    }

    /// Puts the published choice back to the device the I/O unit is really on, so a rejected switch
    /// does not leave the picker naming something that is not playing. `wrap` makes the device a
    /// choice of the picker's kind.
    private func revert<Value>(
        _ key: ReferenceWritableKeyPath<PlaybackEngine, Value?>,
        on node: AVAudioIONode,
        fallback: Value?,
        wrap: (AudioDevice) -> Value
    ) {
        // By id, not by looking the id up in the pickers' lists: the unit can be on something the
        // lists leave out, and naming it is still better than publishing nil. A private device is
        // the exception -- our own aggregate, or the `CADefaultDeviceAggregate` CoreAudio keeps
        // behind the defaults -- since no picker should ever show one.
        let inUse = Self.currentDevice(of: node)
            .flatMap { AudioDevices.isPrivate(device: $0) ? nil : AudioDevices.device(withID: $0) }

        isRevertingDevice = true
        self[keyPath: key] = inUse.map(wrap) ?? fallback
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
    static func currentDevice(of node: AVAudioIONode) -> AudioDeviceID? {
        guard let unit = node.audioUnit else { return nil }

        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)

        let status = AudioUnitGetProperty(
            unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &deviceID,
            &size)

        return status == noErr && deviceID != kAudioObjectUnknown ? deviceID : nil
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
