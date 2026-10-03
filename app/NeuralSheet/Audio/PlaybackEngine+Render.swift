import AVFoundation
import Foundation
import NeuralSheetCore
import Synchronization

/// Everything the render thread touches, in one object both ``PlaybackEngine`` and its render block
/// hold. The block captures this rather than the engine, so nothing it does can retain, release or
/// reach through `self` while the audio device is waiting.
///
/// `@unchecked Sendable`: every cross-thread field is an atomic, and the two plain `var`s are each
/// touched by exactly one thread (``previousSourceGain`` by the render block, ``meter`` by the tap).
// Internal rather than private: PlaybackEngine.swift holds it and the extensions reach it.
nonisolated final class RenderState: @unchecked Sendable {
    /// The take the render block reads, as a single machine word written only from the main thread.
    ///
    /// Unmanaged rather than a strong reference because a strong one in a class would be read
    /// through a lock-free-but-not-atomic sequence of loads; one pointer-sized slot is written and
    /// read atomically by the hardware. ``PlaybackEngine`` keeps the object itself alive, and keeps
    /// the one it replaced alive for a grace period, so the block can never see freed memory.
    let source = UnsafeMutablePointer<Unmanaged<SourceAudio>?>.allocate(capacity: 1)

    let playing = Atomic<Bool>(false)

    /// The playhead in frames at the device rate. The render block owns it; the main thread reads it
    /// and asks for changes through ``pendingSeek``.
    let playheadFrames = Atomic<Int>(0)

    /// A seek the render block has not applied yet, or -1 for none.
    let pendingSeek = Atomic<Int>(-1)

    /// `cos(mix · π/2) × masterGain`, muted folded in, as a `Float` bit pattern.
    let sourceGainBits = Atomic<UInt32>(0)

    /// Bumped every time the playhead runs off the end. The main thread polls it.
    let wrapGeneration = Atomic<Int>(0)

    /// The master meter's level, as a `Double` bit pattern.
    let masterLevelBits = Atomic<UInt64>(RmsMeter.floorDb.bitPattern)

    /// The loop as ``LoopWindow/packed``, 0 for none (loop design §4). One word, so the block
    /// never reads one end from a newer loop than the other.
    let loopBits = Atomic<UInt64>(0)

    /// The playback speed as a `Float` bit pattern, 1 for the take's own (speed design §4).
    let speedBits = Atomic<UInt32>(Float(1).bitPattern)

    /// Render thread only: the playhead to the fraction of a frame. ``playheadFrames`` is its
    /// rounding, published for the main thread; at any speed but 1 a block covers a fractional
    /// number of take frames and the fraction has to be kept somewhere.
    var playheadExact = 0.0

    /// Render thread only: where the last block's gain ramp ended.
    var previousSourceGain: Float = 0

    /// Render thread only: the stretch at any speed but 1, and whether the previous block used
    /// it (so it carries on rather than being reset). Replaced with the engine stopped when the
    /// rate changes. The scratch takes the stretcher's second channel when the output has one.
    var stretcher = TimeStretcher(sampleRate: 48000, maxBlockFrames: RenderState.maxBlockFrames)
    var stretching = false
    let stretchScratch = UnsafeMutableBufferPointer<Float>.allocate(capacity: RenderState.maxBlockFrames)

    /// The largest block the stretch path serves; a bigger one is silence rather than an overrun.
    static let maxBlockFrames = 8192

    /// Render thread only: the playhead the last rendered block started at, and whether that
    /// block was the one just before this. The take is read one buffer behind the playhead, and
    /// through a loop jump "one buffer behind" is the previous block's start, not `playhead -
    /// frames`.
    var lastBlockStart = 0
    var continuous = false

    /// Tap thread only. Replaced (with the engine stopped) when the device rate changes.
    var meter = RmsMeter(sampleRate: 48000)

    /// Tap thread only: room to fold a stereo tap buffer to mono without allocating.
    let meterScratch = UnsafeMutableBufferPointer<Float>.allocate(capacity: 16384)

    init() {
        source.initialize(to: nil)
        meterScratch.initialize(repeating: 0)
        stretchScratch.initialize(repeating: 0)
    }

    deinit {
        source.deinitialize(count: 1)
        source.deallocate()
        meterScratch.deallocate()
        stretchScratch.deallocate()
    }

    /// Tap thread. Folds the master mixer's output to mono and pushes it into the meter.
    func pushMeter(_ buffer: AVAudioPCMBuffer) {
        guard let data = buffer.floatChannelData, let scratch = meterScratch.baseAddress else {
            return
        }

        let frames = Swift.min(Int(buffer.frameLength), meterScratch.count)
        guard frames > 0 else { return }

        let channels = Int(buffer.format.channelCount)

        if channels >= 2 {
            let left = data[0]
            let right = data[1]
            for i in 0..<frames {
                scratch[i] = (left[i] + right[i]) * 0.5
            }
        } else {
            scratch.update(from: data[0], count: frames)
        }

        meter.push(UnsafeBufferPointer(start: scratch, count: frames))
        masterLevelBits.store(meter.decibels.bitPattern, ordering: .relaxed)
    }
}

/// The source node's render block: it owns the playhead, reads the take a buffer behind it (through
/// the stretch at any speed but 1), ramps the source gain and schedules the synths. Render thread;
/// it reaches the engine only through ``RenderState``, never through `self`.
nonisolated extension PlaybackEngine {
    // Internal: buildGraph makes the source node with it.
    func makeRenderBlock() -> AVAudioSourceNodeRenderBlock {
        let state = self.state
        let bank = self.synthBank
        let rate = sampleRate

        return { isSilence, timestamp, frameCount, audioBufferList in
            let frames = Int(frameCount)
            let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)

            for buffer in buffers {
                if let data = buffer.mData {
                    memset(data, 0, Int(buffer.mDataByteSize))
                }
            }

            // Gains are ramped from where the last block ended, so a fader move does not step.
            let targetGain = Float(bitPattern: state.sourceGainBits.load(ordering: .relaxed))
            let startGain = state.previousSourceGain
            state.previousSourceGain = targetGain

            let seek = state.pendingSeek.exchange(-1, ordering: .relaxed)
            var playhead = state.playheadExact
            if seek >= 0 { playhead = Double(seek) }

            let playing = state.playing.load(ordering: .relaxed)
            let source = state.source.pointee?.takeUnretainedValue()
            let loop = LoopWindow(packed: state.loopBits.load(ordering: .relaxed))
            let speed = Double(Float(bitPattern: state.speedBits.load(ordering: .relaxed)))
            // The take frames this block covers: `frames` at the take's own speed.
            let span = Double(frames) * speed

            let startSeconds = playhead / rate
            var endSeconds = startSeconds
            var rendered = false
            var wrapped = false

            if playing, let source, source.frameCount > 0, frames > 0 {
                let total = source.frameCount
                let step = (targetGain - startGain) / Float(frames)
                let outputs = min(buffers.count, 2)

                if speed != 1 {
                    // The stretch (speed design §4). It reads the take itself, through the same
                    // wrapped index as the direct read, and keeps its own place in it from one
                    // block to the next; a seek, a block that did not render or a return from
                    // speed 1 starts it again one block behind the playhead, where the direct
                    // read would be.
                    let input = TimeStretcher.Input(
                        left: source.base(ofChannel: 0),
                        right: source.base(ofChannel: min(1, source.channelCount - 1)),
                        frameCount: total, isStereo: source.channelCount > 1, loop: loop)

                    if !state.stretching || seek >= 0 {
                        state.stretcher.reset(at: playhead - span, input: input)
                    }

                    state.stretcher.speed = speed

                    if let left = buffers[0].mData?.assumingMemoryBound(to: Float.self),
                        let scratch = state.stretchScratch.baseAddress, frames <= RenderState.maxBlockFrames
                    {
                        let rightOutput = outputs > 1 ? buffers[1].mData?.assumingMemoryBound(to: Float.self) : nil
                        let right = rightOutput ?? scratch

                        state.stretcher.render(left: left, right: right, frames: frames, input: input)

                        var gain = startGain
                        for i in 0..<frames {
                            left[i] *= gain
                            if rightOutput != nil { right[i] *= gain }
                            gain += step
                        }
                    }

                    state.stretching = true
                    // The direct read's continuity is broken: it comes back a block behind.
                    state.continuous = false
                } else {
                    let blockStart = Int(playhead.rounded())
                    // One buffer behind the playhead: the MIDI for [playhead, playhead + buffer)
                    // is being scheduled a cycle ahead, and this delay is what keeps the two
                    // aligned. Through a loop jump the buffer behind is the previous block's
                    // start, which is the same thing until the jump and the right thing after it
                    // (loop design §4).
                    let readStart = seek < 0 && state.continuous ? state.lastBlockStart : blockStart - frames

                    for channel in 0..<outputs {
                        guard let output = buffers[channel].mData?.assumingMemoryBound(to: Float.self)
                        else { continue }

                        // A mono take feeds both outputs.
                        let base = source.base(
                            ofChannel: min(channel, source.channelCount - 1))
                        var gain = startGain

                        for i in 0..<frames {
                            // A read window that crosses the loop's end takes the rest from its
                            // start.
                            let index = loop?.wrapped(readStart + i) ?? (readStart + i)
                            let sample = index >= 0 && index < total ? base[index] : 0
                            output[i] = sample * gain
                            gain += step
                        }
                    }

                    state.lastBlockStart = blockStart
                    state.continuous = true
                    state.stretching = false
                }

                rendered = true

                if let loop {
                    // The synth stops at the loop's end; the playhead carries the overshoot past
                    // its start. The end of the take is never reached: the jump comes first.
                    let advanced = loop.advance(from: playhead, span: span)
                    endSeconds = advanced.renderEnd / rate
                    playhead = advanced.next
                } else {
                    playhead += span
                    endSeconds = playhead / rate

                    // `playhead - span` is where this block started: once that is at or past
                    // the end, every sample has been handed over and the take is done.
                    if playhead - span >= Double(total) {
                        playhead = 0
                        state.playing.store(false, ordering: .relaxed)
                        wrapped = true
                    }
                }
            } else {
                // A block that did not render breaks both runs: the next one reads a buffer
                // behind wherever the playhead is by then.
                state.continuous = false
                state.stretching = false
            }

            state.playheadExact = playhead
            state.playheadFrames.store(Int(playhead.rounded()), ordering: .relaxed)

            // After the playhead store, not before: the poll re-anchors the scheduler to
            // ``playheadSeconds``, and bumping the generation first would let it read the position
            // the block is about to replace.
            if wrapped {
                state.wrapGeneration.wrappingAdd(1, ordering: .relaxed)
            }

            // Every block, playing or not: a stop, a seek or a swapped note list all leave
            // note-offs to deliver and this is what delivers them.
            // At `rate / speed`: a note Δ seconds into the block lands Δ × rate / speed output
            // frames in, and its length stretches with the audio (speed design §2).
            bank.schedule(
                from: startSeconds,
                to: endSeconds,
                renderTime: timestamp.pointee,
                frameCount: frames,
                sampleRate: rate / speed,
                outputRate: rate
            )

            isSilence.pointee = ObjCBool(!rendered)

            return noErr
        }
    }
}
