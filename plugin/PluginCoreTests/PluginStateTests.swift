import Foundation
import NeuralSheetCore
import Testing

// The plugin's saved state (Audio Unit design §2, "State"): the take as ALAC and the settings
// around it, coded and decoded, and the merge into the host's fullState dictionary.

/// Planar noise on the 24-bit grid inside full scale, what ALAC at 24 bits keeps bit for bit.
private func gridNoise(frames: Int, channels: Int) -> [[Float]] {
    var generator = SystemRandomNumberGenerator()
    return (0..<channels).map { _ in
        (0..<frames).map { _ in Float(Int.random(in: -(1 << 23)..<(1 << 23), using: &generator)) / Float(1 << 23) }
    }
}

private func take(_ channels: [[Float]], rate: Double = 48_000, start: Double? = 1024) throws -> CapturedTake {
    try #require(CapturedTake.make(channels: channels, sampleRate: rate, startSampleTime: start))
}

private func channels(of take: CapturedTake) -> [[Float]] {
    (0..<take.source.channelCount).map { channel in
        Array(UnsafeBufferPointer(start: take.source.base(ofChannel: channel), count: take.frameCount))
    }
}

private func sampleState(take: PluginState.Take?) -> PluginState {
    let notes = [
        NoteEvent(startTime: 0.5, endTime: 1.0, pitch: 60, amplitude: 0.8, program: 0),
        NoteEvent(startTime: 1.2, endTime: 2.0, pitch: 43, amplitude: 0.6, program: 33),
    ]
    var state = PluginState()
    state.take = take
    state.transcription = ProjectTranscription(sourceSampleCount: 32_000, rawNotes: notes,
                                               document: NoteDocument(events: notes))
    state.modelSize = .medium
    state.selectedGroups = [InstrumentGroup.allCases[0].rawValue]
    state.separateStems = true
    state.mix = 0.8
    state.masterGainDb = -3
    state.mixer = [0: InstrumentChannelSettings(gainDb: -6, muted: true), 33: InstrumentChannelSettings(soloed: true)]
    state.sendsMIDI = true
    return state
}

@Test func theTakeSurvivesALACBitForBit() throws {
    let source = gridNoise(frames: 100_000, channels: 2)
    let captured = try take(source)

    let stored = try #require(PluginState.Take.make(from: captured))
    #expect(stored.frameCount == 100_000)
    #expect(stored.channelCount == 2)
    #expect(stored.sampleRate == 48_000)
    #expect(stored.startSampleTime == 1024)
    #expect(!stored.truncated)
    #expect(stored.alac.count < 100_000 * 2 * 4)

    let restored = try #require(stored.restore())
    #expect(channels(of: restored) == source)
    #expect(restored.startSampleTime == 1024)
    #expect(restored.source.mono16k == captured.source.mono16k)
}

@Test func aSecondRoundTripIsBitExactForAnyFloats() throws {
    // Off the grid and past full scale: rounded and clipped once, then kept.
    let source = (0..<2).map { _ in (0..<20_000).map { _ in Float.random(in: -1.5..<1.5) * 0.37 } }
    let once = try #require(PluginState.Take.make(from: try take(source))?.restore())
    let twice = try #require(PluginState.Take.make(from: once)?.restore())

    #expect(channels(of: twice) == channels(of: once))
    #expect(zip(channels(of: once)[0], source[0]).allSatisfy { abs($0 - max(-1, min(1, $1))) <= 1.0 / Float(1 << 23) })
}

@Test func theStateRoundTrips() throws {
    let stored = try #require(PluginState.Take.make(from: try take(gridNoise(frames: 48_000, channels: 2))))
    let state = sampleState(take: stored)

    let data = try #require(state.encode())
    let decoded = try #require(PluginState.decode(data))

    #expect(decoded == state)
    #expect(decoded.transcription?.document.events == state.transcription?.document.events)
    #expect(decoded.take?.alac == stored.alac)
}

@Test func aStateWithoutATakeRoundTrips() throws {
    let state = PluginState()
    #expect(PluginState.decode(try #require(state.encode())) == state)
}

@Test func anotherVersionIsNotRestored() throws {
    var state = sampleState(take: nil)
    state.version = PluginState.currentVersion + 1
    #expect(PluginState.decode(try #require(state.encode())) == nil)

    state.version = 0
    #expect(PluginState.decode(try #require(state.encode())) == nil)
}

@Test func aTruncatedOrForeignBlobIsNotRestored() throws {
    let stored = try #require(PluginState.Take.make(from: try take(gridNoise(frames: 48_000, channels: 2))))
    let data = try #require(sampleState(take: stored).encode())

    #expect(PluginState.decode(data.prefix(data.count / 2)) == nil)
    #expect(PluginState.decode(data.prefix(16)) == nil)
    #expect(PluginState.decode(Data()) == nil)
    #expect(PluginState.decode(Data("not a state".utf8)) == nil)
}

@Test func damagedAudioDecodesToNoTake() throws {
    var stored = try #require(PluginState.Take.make(from: try take(gridNoise(frames: 48_000, channels: 2))))
    let good = stored

    stored.alac = stored.alac.prefix(stored.alac.count / 2)
    #expect(stored.restore() == nil)

    stored = good
    stored.frameCount += 1
    #expect(stored.restore() == nil)

    stored = good
    stored.sampleRate = 44_100
    #expect(stored.restore() == nil)
}

@Test func aTakeLongerThanTheCapIsStoredCut() throws {
    // The cap at one second rather than ten minutes, to keep minutes of audio out of a test.
    let source = gridNoise(frames: 48_100, channels: 1)
    let stored = try #require(PluginState.Take.make(from: try take(source), maximumSeconds: 1))

    #expect(stored.truncated)
    #expect(stored.frameCount == 48_000)
    #expect(channels(of: try #require(stored.restore()))[0] == Array(source[0].prefix(48_000)))
    #expect(PluginState.maximumTakeSeconds == 600)
}

// MARK: - fullState

@Test func theStateIsMergedIntoTheHostsDictionary() throws {
    let base: [String: Any] = ["type": 1_635_083_896, "subtype": 1_314_087_028, "name": "Untitled", "data": Data([1, 2])]
    let blob = Data([9, 8, 7])

    let merged = PluginFullState.merging(blob, into: base)

    #expect(merged.count == base.count + 1)
    #expect(merged["type"] as? Int == 1_635_083_896)
    #expect(merged["name"] as? String == "Untitled")
    #expect(merged["data"] as? Data == Data([1, 2]))
    #expect(PluginFullState.blob(in: merged) == blob)
}

@Test func noStateLeavesTheHostsDictionaryAlone() {
    let base: [String: Any] = ["name": "Untitled", PluginFullState.key: Data([1])]

    #expect(PluginFullState.merging(nil, into: base).keys.sorted() == ["name"])
    #expect(PluginFullState.merging(Data([2]), into: nil).count == 1)
    #expect(PluginFullState.blob(in: ["name": "Untitled"]) == nil)
    #expect(PluginFullState.blob(in: [PluginFullState.key: "not data"]) == nil)
    #expect(PluginFullState.blob(in: nil) == nil)
}
