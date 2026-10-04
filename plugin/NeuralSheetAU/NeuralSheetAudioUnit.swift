import AVFoundation
import AudioToolbox
import Foundation

/// The NeuralSheet effect (Audio Unit design §2, "Audio path"): one stereo input, one stereo
/// output, any sample rate, no parameters yet.
///
/// In sub-issue A the audio passes through untouched. The render block is written against the
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
    }

    override func deallocateRenderResources() {
        scratch.pointee.release()
        super.deallocateRenderResources()
    }

    override var internalRenderBlock: AUInternalRenderBlock {
        makePassthroughRenderBlock(scratch)
    }
}
