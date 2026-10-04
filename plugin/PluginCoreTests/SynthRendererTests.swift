import Foundation
import NeuralSheetCore
import Testing

/// The synth thread against a consumer that plays the render block's part: a note scheduled in the
/// bank lands in the ring at its own position on the timeline.

/// Reads the ring as a moving render block would, `block` frames at a time from `start`, until
/// `count` frames have been read; waits for the producer before each block so the test measures
/// placement, not the machine's speed. The left channel.
private func play(_ renderer: SynthRenderer, from start: Int, count: Int, block: Int = 512) -> [Float] {
    var output = [Float](repeating: 0, count: count)
    var left = [Float](repeating: 0, count: block)
    var right = [Float](repeating: 0, count: block)
    var position = start

    while position < start + count {
        let deadline = Date().addingTimeInterval(2)
        while renderer.renderedThrough < position + block, Date() < deadline {
            usleep(500)
        }

        _ = renderer.ring.consume(position: position, frames: block, left: &left, right: &right)

        let offset = position - start
        let n = min(block, count - offset)
        for i in 0..<n { output[offset + i] = left[i] }
        position += block
    }

    return output
}

private func firstSound(_ samples: [Float]) -> Int? {
    samples.firstIndex { abs($0) > 1e-5 }
}

@Test func aScheduledNoteIsInTheRingAtItsOwnPosition() throws {
    let renderer = try #require(SynthRenderer(sampleRate: 48000, maxHostFrames: 512))
    defer { renderer.stop() }

    renderer.setNotes([NoteEvent(startTime: 0.25, endTime: 0.75, pitch: 60, program: 0)])
    renderer.ring.stand(at: 0)
    renderer.start()

    let samples = play(renderer, from: 0, count: 24000)
    let onset = try #require(firstSound(samples))

    // 0.25 s at 48 kHz is frame 12 000; the DLS piano speaks within a few samples of it.
    #expect(onset >= 12000)
    #expect(onset < 12000 + 64)
    #expect(samples[0..<12000].allSatisfy { $0 == 0 })
}

@Test func afterAJumpTheNoteIsStillAtItsOwnPosition() throws {
    let renderer = try #require(SynthRenderer(sampleRate: 44100, maxHostFrames: 256))
    defer { renderer.stop() }

    renderer.setNotes([NoteEvent(startTime: 2.0, endTime: 2.5, pitch: 67, program: 0)])
    renderer.ring.stand(at: 0)
    renderer.start()

    _ = play(renderer, from: 0, count: 4096, block: 256)

    // Located to 1.9 s while playing: silent for the lead, then the synth from its anchor, with
    // the note at 2.0 s where it belongs.
    let jump = Int(1.9 * 44100)
    let samples = play(renderer, from: jump, count: 8820, block: 256)
    let onset = try #require(firstSound(samples))

    #expect(jump + onset >= 88200)
    #expect(jump + onset < 88200 + 64)
}

@Test func notesThatArriveLaterReplaceTheSilenceAlreadyAhead() throws {
    let renderer = try #require(SynthRenderer(sampleRate: 48000, maxHostFrames: 512))
    defer { renderer.stop() }

    renderer.ring.stand(at: 0)
    renderer.start()

    // The thread has rendered silence ahead of a standing transport; a transcription lands.
    let deadline = Date().addingTimeInterval(2)
    while renderer.renderedThrough < renderer.aheadFrames, Date() < deadline { usleep(500) }
    renderer.setNotes([NoteEvent(startTime: 0.05, endTime: 0.3, pitch: 72, program: 0)])
    usleep(50_000)

    let samples = play(renderer, from: 0, count: 9600)
    let onset = try #require(firstSound(samples))

    #expect(onset >= 2400)
    #expect(onset < 2400 + 64)
}
