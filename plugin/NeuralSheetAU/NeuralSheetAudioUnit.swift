import AVFoundation
import AudioToolbox
import Foundation
import Synchronization

/// The NeuralSheet effect (Audio Unit design §2, "Audio path"): one stereo input, one stereo
/// output, any sample rate, no parameters yet.
///
/// The audio passes through untouched and, while a capture runs, is copied into a
/// ``CaptureRing`` (sub-issue B; `+Capture` is the main thread's side). The render block is written against the
/// render-thread rules (CLAUDE.md): it does not allocate, lock, call an Objective-C property or
/// grow an array. Everything it touches is reached through ``scratch``, a plain pointer captured
/// by value, so it never retains, releases or reaches through `self`.
///
/// `nonisolated` and `@unchecked Sendable`, as the app's audio types are: hosts create, configure
/// and render it from threads of their own. The only state shared with the render thread is
/// ``scratch``, which is written in `allocateRenderResources` and `deallocateRenderResources`,
/// and hosts never render outside that pair.
nonisolated final class NeuralSheetAudioUnit: AUAudioUnit, @unchecked Sendable {
    private let inputBus: AUAudioUnitBus
    private let outputBus: AUAudioUnitBus
    // Made once, right after super.init (they need the unit), and never replaced.
    private var inputBusArray: AUAudioUnitBusArray!
    private var outputBusArray: AUAudioUnitBusArray!
    private let emptyParameterTree = AUParameterTree.createTree(withChildren: [])

    /// The render block's whole world, allocated with the unit and freed in `deinit`.
    private let scratch = UnsafeMutablePointer<PassthroughScratch>.allocate(capacity: 1)

    /// The capture ring, made in `allocateRenderResources` for the host's format and kept across
    /// a deallocation, so a host that stops rendering for a moment does not lose a take. Locked
    /// because the host allocates on a thread of its own while the main thread drains; the
    /// render block never takes this lock, it borrows the ring through ``scratch``.
    private let ringLock = Mutex<CaptureRing?>(nil)

    /// The ring the main thread starts, drains and stops captures on; nil before the host has
    /// allocated render resources.
    var captureRing: CaptureRing? { ringLock.withLock { $0 } }

    override init(
        componentDescription: AudioComponentDescription, options: AudioComponentInstantiationOptions = []
    ) throws {
        guard let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2) else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(kAudioUnitErr_FormatNotSupported))
        }

        let inputBus = try AUAudioUnitBus(format: format)
        let outputBus = try AUAudioUnitBus(format: format)
        inputBus.name = "Input"
        outputBus.name = "Output"
        self.inputBus = inputBus
        self.outputBus = outputBus
        scratch.initialize(to: PassthroughScratch())

        try super.init(componentDescription: componentDescription, options: options)

        inputBusArray = AUAudioUnitBusArray(audioUnit: self, busType: .input, busses: [inputBus])
        outputBusArray = AUAudioUnitBusArray(audioUnit: self, busType: .output, busses: [outputBus])
        maximumFramesToRender = 4096
    }

    deinit {
        scratch.pointee.release()
        scratch.deinitialize(count: 1)
        scratch.deallocate()
    }

    override var inputBusses: AUAudioUnitBusArray { inputBusArray }

    override var outputBusses: AUAudioUnitBusArray { outputBusArray }

    override var parameterTree: AUParameterTree? {
        get { emptyParameterTree }
        set {}
    }

    /// Stereo in, stereo out.
    override var channelCapabilities: [NSNumber]? { [2, 2] }

    override var canProcessInPlace: Bool { true }

    override func shouldChange(to format: AVAudioFormat, for bus: AUAudioUnitBus) -> Bool {
        format.channelCount == 2 && super.shouldChange(to: format, for: bus)
    }

    /// Prepares the scratch the render block pulls the input into: one channel buffer per output
    /// channel, `maximumFramesToRender` long. Fails when the busses disagree, which a passthrough
    /// cannot bridge.
    override func allocateRenderResources() throws {
        let input = inputBus.format
        let output = outputBus.format

        guard input.channelCount == output.channelCount, input.sampleRate == output.sampleRate else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(kAudioUnitErr_FormatNotSupported))
        }

        try super.allocateRenderResources()

        scratch.pointee.release()
        scratch.pointee.allocate(channels: Int(output.channelCount), maxFrames: Int(maximumFramesToRender))
        scratch.pointee.ring = Unmanaged.passUnretained(ring(for: output))
    }

    /// The ring for `format`: the current one when the rate and channels are unchanged, otherwise
    /// a new one, which ends any capture running on the old (the main thread sees the swap and
    /// stops with what it drained).
    private func ring(for format: AVAudioFormat) -> CaptureRing {
        let rate = format.sampleRate
        let channels = Int(format.channelCount)

        return ringLock.withLock { current in
            if let current, current.sampleRate == rate, current.channels == channels { return current }

            current?.capturing.store(false, ordering: .releasing)
            let ring = CaptureRing(capacityFrames: CaptureRing.capacityFrames(for: rate), channels: channels,
                                   sampleRate: rate)
            current = ring
            return ring
        }
    }

    override func deallocateRenderResources() {
        scratch.pointee.release()
        super.deallocateRenderResources()
    }

    override var internalRenderBlock: AUInternalRenderBlock {
        makePassthroughRenderBlock(scratch)
    }
}
