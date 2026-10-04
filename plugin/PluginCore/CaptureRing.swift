import CoreAudio
import Darwin
import Foundation
import Synchronization

/// The take being captured from the host (Audio Unit design §2, "Audio path"): a preallocated,
/// single-producer single-consumer ring of planar `Float` frames. The render block is the producer
/// and copies the input into it while ``capturing`` is set; the main thread is the consumer and
/// drains it, a few times a second while the capture runs and once more when it stops.
///
/// Planar rather than interleaved: the host hands the render block one buffer per channel, the
/// ring keeps one region per channel, so a push is one `memmove` per channel (two at the wrap) and
/// a drain hands back `[[Float]]` in the shape `SourceAudio` and the resampler take.
///
/// `head` and `tail` count frames forever (an `Int` does not wrap in the lifetime of a session)
/// and index the storage modulo ``capacityFrames``. The producer copies the frames in, then
/// publishes them with a releasing store of `head`; the consumer acquires `head`, copies out, and
/// releases `tail`, which is what lets the producer reuse those frames. A block that does not fit
/// is dropped whole and counted in ``overflowFrames``: losing a block is better than a render
/// thread waiting on the main thread, and dropping whole blocks keeps every channel the same
/// length.
///
/// Sized at `allocateRenderResources` for ten minutes at the host's rate (``capacityFrames(for:)``),
/// which at 48 kHz stereo is 230 MB. The storage is an anonymous mapping, so it costs nothing until
/// written. ``prepareForCapture()`` writes it all on the main thread before a capture starts, so
/// the render thread never takes a page fault on fresh memory, and ``releaseMemory()`` hands the
/// pages back after the capture is drained.
///
/// Free of AU types (design §3; `AudioBufferList` is Core Audio's), so a wrapper for another
/// plugin format can use it unchanged.
nonisolated final class CaptureRing: @unchecked Sendable {
    /// How long a take may be.
    static let maximumSeconds: Double = 600

    /// Frames per channel for ``maximumSeconds`` at `sampleRate`.
    static func capacityFrames(for sampleRate: Double) -> Int {
        max(Int((sampleRate * maximumSeconds).rounded(.up)), 1)
    }

    /// Frames per channel the ring holds.
    let capacityFrames: Int

    /// Channels, each `capacityFrames` long.
    let channels: Int

    /// The host rate the ring was sized for, kept so a reallocation at the same format can keep it.
    let sampleRate: Double

    /// Set by the main thread to start and stop a capture; read by the render block once a cycle.
    let capturing = Atomic<Bool>(false)

    /// Frames a full ring turned away since it was made. Written by the producer only.
    let overflowFrames = Atomic<Int>(0)

    /// The host's `mSampleTime` of the first frame of the current capture, as its bit pattern, or
    /// ``noSampleTime`` until the render block has stored it (``noteStart(sampleTime:)``).
    private let firstSampleTimeBits = Atomic<UInt64>(CaptureRing.noSampleTime)

    /// A NaN that no host sample time is.
    private static let noSampleTime = UInt64.max

    /// Written by the producer only.
    private let head = Atomic<Int>(0)

    /// Written by the consumer only.
    private let tail = Atomic<Int>(0)

    /// `channels × capacityFrames` floats, channel after channel; nil when the mapping failed,
    /// in which case every push is an overflow.
    private let storage: UnsafeMutablePointer<Float>?
    private let byteCount: Int

    init(capacityFrames: Int, channels: Int, sampleRate: Double = 0) {
        self.capacityFrames = max(capacityFrames, 1)
        self.channels = max(channels, 1)
        self.sampleRate = sampleRate

        let page = Int(getpagesize())
        let bytes = self.capacityFrames * self.channels * MemoryLayout<Float>.stride
        byteCount = (bytes + page - 1) / page * page

        let mapping = mmap(nil, byteCount, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0)
        storage = mapping == MAP_FAILED ? nil : mapping?.bindMemory(to: Float.self, capacity: bytes / MemoryLayout<Float>.stride)
    }

    deinit {
        if let storage { munmap(storage, byteCount) }
    }

    // MARK: - Producer (the render thread)

    /// Copies `frames` frames of `buffers` (one buffer per channel, as the host's non-interleaved
    /// format has them) into the ring and publishes them. A channel the host did not supply is
    /// stored as silence. False, and the frames counted in ``overflowFrames``, when they did not
    /// fit.
    ///
    /// Render thread: two atomic loads, a `memmove` per channel (two at the wrap), one releasing
    /// store. No allocation, no lock, no Objective-C.
    @discardableResult
    func push(frames: Int, from buffers: UnsafeMutableAudioBufferListPointer) -> Bool {
        guard frames > 0 else { return true }

        let position = head.load(ordering: .relaxed)
        let used = position - tail.load(ordering: .acquiring)

        guard let storage, frames <= capacityFrames - used else {
            overflowFrames.wrappingAdd(frames, ordering: .relaxed)
            return false
        }

        let start = position % capacityFrames
        let first = min(frames, capacityFrames - start)
        let rest = frames - first
        let supplied = buffers.count

        for channel in 0..<channels {
            let region = storage + channel * capacityFrames

            if channel < supplied, let data = buffers[channel].mData {
                let source = data.assumingMemoryBound(to: Float.self)
                (region + start).update(from: source, count: first)
                if rest > 0 { region.update(from: source + first, count: rest) }
            } else {
                (region + start).update(repeating: 0, count: first)
                if rest > 0 { region.update(repeating: 0, count: rest) }
            }
        }

        head.store(position &+ frames, ordering: .releasing)

        return true
    }

    /// Records the host's sample time of the capture's first frame: one relaxed load, and one
    /// relaxed store on the first cycle of a capture. Render thread, before the cycle's ``push``,
    /// whose releasing store publishes it with the frames.
    @inline(__always)
    func noteStart(sampleTime: Double) {
        if firstSampleTimeBits.load(ordering: .relaxed) == Self.noSampleTime {
            firstSampleTimeBits.store(sampleTime.bitPattern, ordering: .relaxed)
        }
    }

    // MARK: - Consumer (the main thread)

    /// The frames pushed since the last drain, one array per channel, or an empty array when
    /// nothing was pushed. Allocating; main thread.
    func drain() -> [[Float]] {
        let position = tail.load(ordering: .relaxed)
        let end = head.load(ordering: .acquiring)
        let count = end - position

        guard count > 0, let storage else { return [] }

        let start = position % capacityFrames
        let first = min(count, capacityFrames - start)

        let result = (0..<channels).map { channel -> [Float] in
            let region = storage + channel * capacityFrames
            var samples = [Float](UnsafeBufferPointer(start: region + start, count: first))
            if count > first {
                samples.append(contentsOf: UnsafeBufferPointer(start: region, count: count - first))
            }
            return samples
        }

        tail.store(end, ordering: .releasing)

        return result
    }

    /// Frames pushed and not yet drained.
    var pendingFrames: Int {
        head.load(ordering: .acquiring) - tail.load(ordering: .relaxed)
    }

    /// The first frame's host sample time for the current capture, nil until the render block has
    /// stored it.
    var firstSampleTime: Double? {
        let bits = firstSampleTimeBits.load(ordering: .acquiring)
        return bits == Self.noSampleTime ? nil : Double(bitPattern: bits)
    }

    /// Readies the ring for a capture while ``capturing`` is clear: drops anything left over,
    /// forgets the last capture's start time, and writes the whole mapping so the render thread
    /// never faults a fresh page in. Main thread; touches every page, tens of milliseconds for a
    /// stereo 48 kHz ring.
    func prepareForCapture() {
        tail.store(head.load(ordering: .acquiring), ordering: .releasing)
        firstSampleTimeBits.store(Self.noSampleTime, ordering: .relaxed)

        guard let storage else { return }

        madvise(storage, byteCount, MADV_FREE_REUSE)
        memset(storage, 0, byteCount)
    }

    /// Returns the pages to the system once a capture has stopped and been drained. They come
    /// back as zeros on the next ``prepareForCapture()``. Main thread.
    func releaseMemory() {
        guard let storage else { return }

        madvise(storage, byteCount, MADV_FREE_REUSABLE)
    }
}
