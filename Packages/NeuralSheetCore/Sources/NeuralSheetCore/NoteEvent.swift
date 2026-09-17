/// One transcribed note: a pitch held over a time span by one instrument.
public struct NoteEvent: Equatable, Hashable, Codable, Sendable {
    public var startTime: Double
    public var endTime: Double
    public var pitch: Int
    public var amplitude: Double
    public var program: Int

    /// The program the engine rewrites every drum note to, whatever group it came from.
    public static let drumProgram = 128

    /// Velocity 100 of 127, the reference's fixed amplitude.
    public static let defaultAmplitude = 100.0 / 127.0

    public var isDrum: Bool { program == NoteEvent.drumProgram }

    public init(
        startTime: Double,
        endTime: Double,
        pitch: Int,
        amplitude: Double = NoteEvent.defaultAmplitude,
        program: Int
    ) {
        self.startTime = startTime
        self.endTime = endTime
        self.pitch = pitch
        self.amplitude = amplitude
        self.program = program
    }
}
