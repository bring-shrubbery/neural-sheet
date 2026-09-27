import Foundation

/// A pitch-preserving time stretch of the take, for playing it slower or faster than it was
/// recorded (speed design §3): WSOLA, waveform-similarity overlap-add. Each output window is a
/// stretch of the take placed where the speed says the next one belongs, adjusted within a small
/// seek span to the offset that best continues the window before it, and crossfaded into it.
///
/// Threading: ``render(left:right:frames:input:)`` and ``reset(at:input:)`` are the render
/// thread's and allocate nothing; every buffer is sized in ``init(sampleRate:maxBlockFrames:)``.
/// The object is owned by one thread and never shared, so nothing here is atomic.
public final class TimeStretcher {
    /// The take, as raw memory the render thread indexes. `right` is `left` for a mono take.
    public struct Input {
        public var left: UnsafePointer<Float>
        public var right: UnsafePointer<Float>
        public var frameCount: Int
        public var isStereo: Bool
        /// Indices at or past the loop's end fold back to its start, as the direct read's do.
        public var loop: LoopWindow?

        public init(left: UnsafePointer<Float>, right: UnsafePointer<Float>, frameCount: Int,
                    isStereo: Bool, loop: LoopWindow?) {
            self.left = left
            self.right = right
            self.frameCount = frameCount
            self.isStereo = isStereo
            self.loop = loop
        }

        /// The sample at `index` of channel 0 or 1: 0 before the take and past its end, wrapped
        /// into the loop when there is one.
        @inline(__always)
        public func sample(_ channel: Int, at index: Int) -> Float {
            let wrapped = loop?.wrapped(index) ?? index

            guard wrapped >= 0, wrapped < frameCount else { return 0 }

            return channel == 0 ? left[wrapped] : right[wrapped]
        }

        /// The mono of both channels at `index`, for the similarity search.
        @inline(__always)
        func mono(at index: Int) -> Float {
            isStereo ? (sample(0, at: index) + sample(1, at: index)) * 0.5 : sample(0, at: index)
        }
    }

    /// The window a new stretch of the take is taken in, the crossfade between consecutive
    /// windows, and how far either side of the nominal position the best continuation is looked
    /// for. Seconds; SoundTouch's shape, sized for music at half speed.
    public static let windowSeconds = 0.100
    public static let overlapSeconds = 0.012
    public static let seekSeconds = 0.025

    public static let minSpeed = 0.25
    public static let maxSpeed = 4.0

    /// The stretch: 0.5 plays at half speed. Clamped.
    public var speed: Double = 1 {
        didSet { speed = min(max(speed, TimeStretcher.minSpeed), TimeStretcher.maxSpeed) }
    }

    /// The take frame the next window's crossfade region nominally starts at. Fractional: the
    /// speed rarely divides a window into whole frames.
    public private(set) var position: Double = 0

    let windowLength: Int
    let overlapLength: Int
    let seekLength: Int

    /// Planar output not yet handed over, `capacity` frames per channel.
    private let ring: UnsafeMutableBufferPointer<Float>
    private let capacity: Int
    private var ringRead = 0
    private var ringCount = 0

    /// The last `overlapLength` frames of the current window, planar, not yet emitted: the next
    /// window is crossfaded from them.
    private let tail: UnsafeMutableBufferPointer<Float>

    /// Mono scratch for the search: the take over the seek span plus one overlap, and the tail.
    private let candidates: UnsafeMutableBufferPointer<Float>
    private let tailMono: UnsafeMutableBufferPointer<Float>

    public init(sampleRate: Double, maxBlockFrames: Int = 8192) {
        let rate = sampleRate.isFinite && sampleRate > 0 ? sampleRate : 48_000

        windowLength = max(64, Int((rate * TimeStretcher.windowSeconds).rounded()))
        overlapLength = max(8, min(Int((rate * TimeStretcher.overlapSeconds).rounded()), windowLength / 4))
        seekLength = max(2, Int((rate * TimeStretcher.seekSeconds).rounded()))

        capacity = max(1, maxBlockFrames) + windowLength

        ring = UnsafeMutableBufferPointer<Float>.allocate(capacity: 2 * capacity)
        ring.initialize(repeating: 0)
        tail = UnsafeMutableBufferPointer<Float>.allocate(capacity: 2 * overlapLength)
        tail.initialize(repeating: 0)
        candidates = UnsafeMutableBufferPointer<Float>.allocate(capacity: seekLength + overlapLength)
        candidates.initialize(repeating: 0)
        tailMono = UnsafeMutableBufferPointer<Float>.allocate(capacity: overlapLength)
        tailMono.initialize(repeating: 0)
    }

    deinit {
        ring.deallocate()
        tail.deallocate()
        candidates.deallocate()
        tailMono.deallocate()
    }

    /// How many frames one iteration adds to the ring.
    var framesPerIteration: Int { windowLength - overlapLength }

    /// Starts over at `position`: the ring is emptied and the tail seeded from the take there, so
    /// the first window continues the take exactly rather than fading in from silence.
    public func reset(at position: Double, input: Input) {
        self.position = position.isFinite ? position : 0
        ringRead = 0
        ringCount = 0

        let base = Int(self.position.rounded())

        for i in 0..<overlapLength {
            tail[i] = input.sample(0, at: base + i)
            tail[overlapLength + i] = input.sample(1, at: base + i)
        }
    }

    /// Fills `frames` frames of both outputs with the take stretched by ``speed`` from
    /// ``position`` on. A block the ring cannot serve -- larger than it was sized for -- is
    /// silence.
    public func render(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>,
                       frames: Int, input: Input) {
        guard frames > 0 else { return }

        guard frames <= capacity - framesPerIteration else {
            for i in 0..<frames {
                left[i] = 0
                right[i] = 0
            }
            return
        }

        while ringCount < frames {
            iterate(input)
        }

        let ringLeft = ring.baseAddress.unsafelyUnwrapped
        let ringRight = ringLeft + capacity
        var read = ringRead

        for i in 0..<frames {
            left[i] = ringLeft[read]
            right[i] = ringRight[read]
            read += 1
            if read == capacity { read = 0 }
        }

        ringRead = read
        ringCount -= frames
    }

    /// One window into the ring, placed by the search and crossfaded from the tail.
    private func iterate(_ input: Input) {
        let nominal = Int(position.rounded())
        let searchStart = nominal - seekLength / 2

        // The take over the seek span plus the overlap, and the tail, both mono.
        for i in 0..<(seekLength + overlapLength) {
            candidates[i] = input.mono(at: searchStart + i)
        }

        for i in 0..<overlapLength {
            tailMono[i] = input.isStereo ? (tail[i] + tail[overlapLength + i]) * 0.5 : tail[i]
        }

        // The offset whose overlap best continues the tail: the dot product over the root of
        // the candidate's energy, the energy kept as a sliding sum so the search is linear in
        // the span plus the products.
        var energy: Float = 0
        for i in 0..<overlapLength {
            energy += candidates[i] * candidates[i]
        }

        var bestOffset = 0
        var bestScore = -Float.greatestFiniteMagnitude

        for k in 0..<seekLength {
            var dot: Float = 0
            let segment = candidates.baseAddress.unsafelyUnwrapped + k
            let reference = tailMono.baseAddress.unsafelyUnwrapped

            for i in 0..<overlapLength {
                dot += reference[i] * segment[i]
            }

            let score = dot / (energy.squareRoot() + 1e-9)

            if score > bestScore {
                bestScore = score
                bestOffset = k
            }

            let leaving = candidates[k]
            let entering = candidates[k + overlapLength]
            energy = max(0, energy - leaving * leaving + entering * entering)
        }

        let pos = searchStart + bestOffset
        let ringLeft = ring.baseAddress.unsafelyUnwrapped
        let ringRight = ringLeft + capacity
        var write = ringRead + ringCount
        if write >= capacity { write -= capacity }

        @inline(__always) func push(_ l: Float, _ r: Float) {
            ringLeft[write] = l
            ringRight[write] = r
            write += 1
            if write == capacity { write = 0 }
        }

        // The crossfade from the tail into the take at `pos`.
        let fadeStep = 1 / Float(overlapLength)
        var fade: Float = 0

        for i in 0..<overlapLength {
            let l = tail[i] * (1 - fade) + input.sample(0, at: pos + i) * fade
            let r = tail[overlapLength + i] * (1 - fade) + input.sample(1, at: pos + i) * fade
            push(l, r)
            fade += fadeStep
        }

        // The middle of the window, as it is.
        for i in overlapLength..<(windowLength - overlapLength) {
            push(input.sample(0, at: pos + i), input.sample(1, at: pos + i))
        }

        // The window's own tail, kept for the next crossfade.
        for i in 0..<overlapLength {
            tail[i] = input.sample(0, at: pos + windowLength - overlapLength + i)
            tail[overlapLength + i] = input.sample(1, at: pos + windowLength - overlapLength + i)
        }

        ringCount += framesPerIteration

        position += Double(framesPerIteration) * speed
        if let loop = input.loop {
            position = loop.wrapped(position)
        }
    }
}
