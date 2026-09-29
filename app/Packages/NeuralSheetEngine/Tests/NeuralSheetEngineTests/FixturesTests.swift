// The fixture readers are test support, but every later task's oracle goes through
// them, so the audio one is checked here rather than blamed later.

import Foundation
import Testing

@Test func theAudioFixtureIsFifteenSecondsOfSixteenKilohertzFloats() throws {
    let samples = try Fixtures.fixtureAudio()

    #expect(samples.count == 240_000, "15 s at 16 kHz")
    #expect(samples.allSatisfy { $0.isFinite && abs($0) <= 1.0 })
    #expect(samples.contains { $0 != 0 })
}
