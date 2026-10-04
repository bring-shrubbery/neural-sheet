import CoreAudio
import Foundation

/// Planar buffers the tests push from, freed with the list.
nonisolated final class Buffers {
    let list: UnsafeMutableAudioBufferListPointer
    private let samples: [UnsafeMutablePointer<Float>]

    /// `channels` buffers of `frames` floats, channel `c` frame `f` holding `value(c, f)`.
    init(channels: Int, frames: Int, value: (Int, Int) -> Float) {
        list = AudioBufferList.allocate(maximumBuffers: channels)
        samples = (0..<channels).map { channel in
            let pointer = UnsafeMutablePointer<Float>.allocate(capacity: max(frames, 1))
            for frame in 0..<frames { pointer[frame] = value(channel, frame) }
            return pointer
        }
        for channel in 0..<channels {
            list[channel] = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(frames * 4),
                                        mData: UnsafeMutableRawPointer(samples[channel]))
        }
    }

    deinit {
        samples.forEach { $0.deallocate() }
        free(list.unsafeMutablePointer)
    }
}

/// A block of `frames` frames numbered from `first`; channel 1 is the negative of channel 0.
nonisolated func block(from first: Int, frames: Int, channels: Int = 2) -> Buffers {
    Buffers(channels: channels, frames: frames) { channel, frame in
        Float(first + frame) * (channel == 0 ? 1 : -1)
    }
}

/// Pushes a ``block(from:frames:channels:)``, kept alive until the ring has copied it.
@discardableResult
nonisolated func push(_ ring: CaptureRing, from first: Int, frames: Int, channels: Int = 2) -> Bool {
    let buffers = block(from: first, frames: frames, channels: channels)
    return withExtendedLifetime(buffers) { ring.push(frames: frames, from: buffers.list) }
}

nonisolated func numbered(_ range: Range<Int>, sign: Float = 1) -> [Float] {
    range.map { Float($0) * sign }
}
