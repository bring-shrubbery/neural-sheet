import AudioToolbox
import Foundation

/// What the render block owns: the buffers it pulls the host's input into. A plain struct behind
/// a pointer, so the block reads it with ordinary loads and nothing is reference counted.
///
/// Written only by ``NeuralSheetAudioUnit/allocateRenderResources()`` and
/// ``NeuralSheetAudioUnit/deallocateRenderResources()``, between which hosts render and outside
/// which they do not, so the block never sees it change underneath it.
nonisolated struct PassthroughScratch {
    /// One `AudioBuffer` per channel. Its `mData` pointers are reset to ``samples`` before every
    /// pull, because an upstream unit may answer a pull by pointing them at buffers of its own.
    var list: UnsafeMutablePointer<AudioBufferList>?

    /// `channels × maxFrames` floats, channel after channel.
    var samples: UnsafeMutablePointer<Float>?

    var channels = 0
    var maxFrames = 0

    mutating func allocate(channels: Int, maxFrames: Int) {
        let buffers = AudioBufferList.allocate(maximumBuffers: channels)
        let samples = UnsafeMutablePointer<Float>.allocate(capacity: channels * maxFrames)
        samples.initialize(repeating: 0, count: channels * maxFrames)

        for channel in 0..<channels {
            buffers[channel] = AudioBuffer(
                mNumberChannels: 1, mDataByteSize: UInt32(maxFrames * MemoryLayout<Float>.size),
                mData: UnsafeMutableRawPointer(samples + channel * maxFrames))
        }

        self.list = buffers.unsafeMutablePointer
        self.samples = samples
        self.channels = channels
        self.maxFrames = maxFrames
    }

    mutating func release() {
        if let list { free(list) }
        samples?.deallocate()
        self = PassthroughScratch()
    }
}

/// The render block: pulls the input and hands it to the output, nothing else. Render thread.
///
/// It captures only `scratch`, a pointer (a trivial value: no retain, no release), and touches
/// nothing but the C structs it points at and the ones the host passes in.
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

        // No input connected: silence, in the host's buffers or, when it passed none, in ours.
        guard let pullInputBlock else {
            for channel in 0..<shared {
                if output[channel].mData == nil { output[channel].mData = input[channel].mData }
                if let data = output[channel].mData { memset(data, 0, Int(byteSize)) }
                output[channel].mDataByteSize = byteSize
            }
            return noErr
        }

        var pullFlags = AudioUnitRenderActionFlags()
        let status = pullInputBlock(&pullFlags, timestamp, frameCount, 0, list)
        guard status == noErr else { return status }

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

        return noErr
    }
}
