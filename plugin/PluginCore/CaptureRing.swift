import Foundation

/// The take being captured from the host (Audio Unit design §2, "Audio path"): a preallocated,
/// single-producer single-consumer ring of non-interleaved `Float` frames. The render block is the
/// producer and copies the input into it while a capture runs; the main thread is the consumer and
/// drains it into a `SourceAudio` when the capture stops.
///
/// Sized for ten minutes at the host's rate and allocated once, in `allocateRenderResources`, so
/// the render thread never allocates. Free of AU types (design §3), so a wrapper for another
/// plugin format can use it unchanged.
///
/// A stub in sub-issue A, which only puts the module layout in place: the write and drain paths
/// and their atomics land in sub-issue B.
nonisolated final class CaptureRing: @unchecked Sendable {
    /// Frames per channel the ring holds.
    let capacityFrames: Int

    /// Channels, each `capacityFrames` long.
    let channels: Int

    /// One contiguous block, channel after channel.
    private let storage: UnsafeMutableBufferPointer<Float>

    init(capacityFrames: Int, channels: Int) {
        self.capacityFrames = max(capacityFrames, 0)
        self.channels = max(channels, 0)
        storage = .allocate(capacity: self.capacityFrames * self.channels)
        storage.initialize(repeating: 0)
    }

    deinit {
        storage.deallocate()
    }
}
