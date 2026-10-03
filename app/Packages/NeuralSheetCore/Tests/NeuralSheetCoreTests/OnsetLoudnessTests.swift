import Foundation
import Testing

@testable import NeuralSheetCore

/// A second of silence with two 100 ms tones, at 0.2 s and 0.6 s, the second 20 dB louder.
private func twoOnsets() -> [Float] {
    var samples = [Float](repeating: 0, count: 16_000)

    for (start, amplitude) in [(0.2, Float(0.05)), (0.6, Float(0.5))] {
        let first = Int(start * 16_000)
        for index in first..<(first + 1_600) {
            samples[index] = amplitude * sin(2 * .pi * 440 * Float(index) / 16_000)
        }
    }

    return samples
}

@Test func onsetLoudnessMeasuresTheRmsInDecibels() {
    let samples = twoOnsets()
    let quiet = OnsetLoudness.measure(mono16k: samples, atSeconds: 0.2)
    let loud = OnsetLoudness.measure(mono16k: samples, atSeconds: 0.6)

    #expect(abs((loud - quiet) - 20) < 0.1)
    // A sine's RMS is its peak over √2.
    #expect(abs(loud - 20 * log10(0.5 / 2.0.squareRoot())) < 0.1)
    #expect(OnsetLoudness.measure(mono16k: samples, atSeconds: 0.9) == OnsetLoudness.floorDb)
    #expect(OnsetLoudness.measure(mono16k: samples, atSeconds: 5) == OnsetLoudness.floorDb)
}

@Test func onsetLoudnessMapsTheQuietestTo24AndTheLoudestTo127() {
    let samples = twoOnsets()

    #expect(OnsetLoudness.velocities(forOnsets: [0.2, 0.6], mono16k: samples) == [24, 127])
    #expect(OnsetLoudness.velocities(forOnsets: [0.6], mono16k: samples) == [100])
    #expect(OnsetLoudness.velocities(forOnsets: [], mono16k: samples) == [])
    #expect(OnsetLoudness.velocities(forLevels: [-40, -30, -20]) == [24, 76, 127])
}
