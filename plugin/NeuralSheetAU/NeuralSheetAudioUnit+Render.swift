import AudioToolbox
import Foundation
import Synchronization

/// What the render block owns: the buffers it pulls the host's input into, the ring it captures
/// into, the synth's frames, the transport and the MIDI it reads, and its own memory of the last
/// cycle. A plain struct behind a pointer, so the block reads it with ordinary loads and nothing is
/// reference counted.
///
/// Written by ``NeuralSheetAudioUnit/allocateRenderResources()`` and
/// ``NeuralSheetAudioUnit/deallocateRenderResources()``, between which hosts render and outside
/// which they do not, so the block never sees the buffers or the references change underneath it;
/// the fields under "The render block's own" are written by the block alone.
nonisolated struct PassthroughScratch {
    /// One `AudioBuffer` per channel. Its `mData` pointers are reset to ``samples`` before every
    /// pull, because an upstream unit may answer a pull by pointing them at buffers of its own.
    var list: UnsafeMutablePointer<AudioBufferList>?

    /// `channels × maxFrames` floats, channel after channel.
    var samples: UnsafeMutablePointer<Float>?

    /// The synth's frames for the cycle, `maxFrames` each.
    var synthLeft: UnsafeMutablePointer<Float>?
    var synthRight: UnsafeMutablePointer<Float>?

    var channels = 0
    var maxFrames = 0
    var sampleRate: Double = 0

    /// The capture ring, unretained: the unit holds it strongly and replaces it only in
    /// `allocateRenderResources`, outside rendering, so the block borrows it without touching its
    /// reference count. The same holds for the synth's ring, the transport and the MIDI.
    var ring: Unmanaged<CaptureRing>?
    var synth: Unmanaged<SynthRing>?
    var transport: Unmanaged<PluginTransport>?

    // MARK: The render block's own

    /// Where the last cycle's gain ramps ended.
    var sourceGain: Float = 1
    var synthGain: Float = 0
    /// Whose transport the last cycle followed, and the host's position after it.
    var lastMode = PluginTransport.Mode.idle
    var lastHostEnd = 0

    mutating func allocate(channels: Int, maxFrames: Int) {
        let buffers = AudioBufferList.allocate(maximumBuffers: channels)
        let samples = UnsafeMutablePointer<Float>.allocate(capacity: channels * maxFrames)
        samples.initialize(repeating: 0, count: channels * maxFrames)

        for channel in 0..<channels {
            buffers[channel] = AudioBuffer(
                mNumberChannels: 1, mDataByteSize: UInt32(maxFrames * MemoryLayout<Float>.size),
                mData: UnsafeMutableRawPointer(samples + channel * maxFrames))
        }

        let synthLeft = UnsafeMutablePointer<Float>.allocate(capacity: maxFrames)
        let synthRight = UnsafeMutablePointer<Float>.allocate(capacity: maxFrames)
        synthLeft.initialize(repeating: 0, count: maxFrames)
        synthRight.initialize(repeating: 0, count: maxFrames)

        self.list = buffers.unsafeMutablePointer
        self.samples = samples
        self.synthLeft = synthLeft
        self.synthRight = synthRight
        self.channels = channels
        self.maxFrames = maxFrames
    }

    mutating func release() {
        if let list { free(list) }
        samples?.deallocate()
        synthLeft?.deallocate()
        synthRight?.deallocate()
        self = PassthroughScratch()
    }
}

/// The render block (Audio Unit design §2, "Audio path" and the mix): pulls the input, captures it
/// while a capture runs, and writes `source × a + synth × b` to the output, where the source is the
/// host's input -- or the take, while the plugin's own transport plays with the host stopped --
/// and the synth is what the synth thread rendered ahead for this stretch of the timeline. Render
/// thread.
///
/// It captures only `scratch`, a pointer (a trivial value: no retain, no release), and touches
/// nothing but the C structs it points at, the ones the host passes in, and the atomics and
/// preallocated storage of the objects it borrows. No allocation, no lock, no Objective-C, no call
/// to the host's transport block.
nonisolated func makePassthroughRenderBlock(
    _ scratch: UnsafeMutablePointer<PassthroughScratch>
) -> AUInternalRenderBlock {
    return { _, timestamp, frameCount, _, outputData, _, pullInputBlock in
        let resources = scratch.pointee
        guard let list = resources.list, let samples = resources.samples else {
            return kAudioUnitErr_Uninitialized
        }

        let frames = Int(frameCount)
        guard frames <= resources.maxFrames else { return kAudioUnitErr_TooManyFramesToProcess }

        let byteSize = UInt32(frames * MemoryLayout<Float>.size)
        let input = UnsafeMutableAudioBufferListPointer(list)
        for channel in 0..<resources.channels {
            input[channel].mData = UnsafeMutableRawPointer(samples + channel * resources.maxFrames)
            input[channel].mDataByteSize = byteSize
        }

        let output = UnsafeMutableAudioBufferListPointer(outputData)
        let shared = min(output.count, resources.channels)

        if let pullInputBlock {
            var pullFlags = AudioUnitRenderActionFlags()
            let status = pullInputBlock(&pullFlags, timestamp, frameCount, 0, list)
            guard status == noErr else { return status }
        } else {
            // No input connected: silence in, which the take or the synth may still play over.
            for channel in 0..<resources.channels {
                if let data = input[channel].mData { memset(data, 0, Int(byteSize)) }
            }
        }

        // In place when the host passed no buffers (hand it the input's) or the same ones,
        // otherwise a copy.
        for channel in 0..<shared {
            let source = input[channel].mData
            if output[channel].mData == nil {
                output[channel].mData = source
            } else if let destination = output[channel].mData, let source, destination != source {
                memcpy(destination, source, Int(byteSize))
            }
            output[channel].mDataByteSize = byteSize
        }

        // The capture: one acquiring load while idle. While capturing, the first cycle's host
        // sample time (a relaxed load and store) and the input copied into the ring (two atomic
        // loads, a memmove per channel, a releasing store). Before the mix, which may write over
        // the input in place. Borrowed, not retained: the unit keeps the ring alive while the
        // host renders.
        resources.ring?._withUnsafeGuaranteedRef { ring in
            if ring.capturing.load(ordering: .acquiring) {
                ring.noteStart(sampleTime: timestamp.pointee.mSampleTime)
                ring.push(frames: frames, from: input)
            }
        }

        resources.transport?._withUnsafeGuaranteedRef { transport in
            renderPlayback(scratch, transport: transport, timestamp: timestamp, frames: frames, output: output,
                           channels: shared)
        }

        return noErr
    }
}

/// The transport's cycle and the mix, over the output that already holds the input. Render
/// thread; see ``makePassthroughRenderBlock(_:)``.
@inline(__always)
nonisolated private func renderPlayback(_ scratch: UnsafeMutablePointer<PassthroughScratch>,
                                        transport: PluginTransport, timestamp: UnsafePointer<AudioTimeStamp>,
                                        frames: Int, output: UnsafeMutableAudioBufferListPointer, channels: Int) {
    let resources = scratch.pointee
    guard frames > 0, let synthLeft = resources.synthLeft, let synthRight = resources.synthRight else { return }

    // Whose transport, and where: a handful of relaxed loads and an exchange; the decision is
    // arithmetic (`PluginTransport.cycle`).
    let seek = transport.pendingSeek.exchange(-1, ordering: .relaxed)
    let own = seek >= 0 ? seek : transport.ownPosition.load(ordering: .relaxed)
    let stamp = timestamp.pointee
    let sampleTime = stamp.mFlags.contains(.sampleTimeValid) ? stamp.mSampleTime : nil

    transport.withTake { take in
        let takeFrames = take?.frameCount ?? 0
        let cycle = PluginTransport.cycle(
            hostPlaying: transport.hostPlaying.load(ordering: .relaxed), hostStart: transport.hostStart,
            sampleTime: sampleTime, ownPlaying: transport.ownPlaying.load(ordering: .relaxed), ownPosition: own,
            takeFrames: takeFrames, frames: frames, lastMode: resources.lastMode, lastHostEnd: resources.lastHostEnd)

        transport.ownPosition.store(cycle.ownPosition, ordering: .relaxed)
        if cycle.ownFinished { transport.ownPlaying.store(false, ordering: .relaxed) }
        transport.position.store(cycle.position, ordering: .relaxed)
        transport.modeWord.store(cycle.mode.rawValue, ordering: .relaxed)

        let moving = cycle.mode != .idle
        let wasMoving = resources.lastMode != .idle
        scratch.pointee.lastMode = cycle.mode
        if cycle.mode == .host { scratch.pointee.lastHostEnd = cycle.position + frames }

        // The synth's frames for this stretch of the timeline, or, on the cycle the transport
        // stops, the stretch it would have played next, faded out. Atomics and copies into the
        // preallocated buffers (`SynthRing`).
        var synthFrames = 0
        var fadeOut = false
        resources.synth?._withUnsafeGuaranteedRef { ring in
            if moving {
                synthFrames = ring.consume(position: cycle.position, frames: frames, left: synthLeft, right: synthRight)
            } else {
                if wasMoving {
                    synthFrames = ring.peek(position: ring.consumerTail, frames: frames, left: synthLeft,
                                            right: synthRight)
                    fadeOut = true
                }
                ring.stand(at: cycle.position)
            }
        }

        // The gains, ramped from where the last cycle's ended so a slider move does not step.
        let sourceTarget = Float(bitPattern: transport.sourceGainBits.load(ordering: .relaxed))
        let synthTarget = fadeOut ? 0 : Float(bitPattern: transport.synthGainBits.load(ordering: .relaxed))
            * Float(bitPattern: transport.masterGainBits.load(ordering: .relaxed))
        let sourceStart = resources.sourceGain
        let synthStart = resources.synthGain
        scratch.pointee.sourceGain = sourceTarget
        scratch.pointee.synthGain = synthFrames > 0 ? synthTarget : 0

        let playsTake = cycle.mode == .own && take != nil
        let addsSynth = synthFrames > 0 && (synthStart != 0 || synthTarget != 0)

        // The host's input at unity with no synth: already in the output.
        guard playsTake || addsSynth || sourceStart != 1 || sourceTarget != 1 else { return }

        let sourceStep = (sourceTarget - sourceStart) / Float(frames)
        let synthStep = (synthTarget - synthStart) / Float(frames)

        for channel in 0..<channels {
            guard let destination = output[channel].mData?.assumingMemoryBound(to: Float.self) else { continue }

            let synth: UnsafeMutablePointer<Float>? = !addsSynth ? nil : channel == 0 ? synthLeft
                : channel == 1 ? synthRight : nil
            var sourceGain = sourceStart
            var synthGain = synthStart

            if playsTake, let take {
                // The take in place of the host's input; a mono take feeds both outputs.
                let base = take.base(ofChannel: min(channel, take.channelCount - 1))

                for i in 0..<frames {
                    let index = cycle.position + i
                    let sample = index >= 0 && index < takeFrames ? base[index] : 0
                    destination[i] = sample * sourceGain + (synth?[i] ?? 0) * synthGain
                    sourceGain += sourceStep
                    synthGain += synthStep
                }
            } else {
                for i in 0..<frames {
                    destination[i] = destination[i] * sourceGain + (synth?[i] ?? 0) * synthGain
                    sourceGain += sourceStep
                    synthGain += synthStep
                }
            }
        }
    }
}
