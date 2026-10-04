import Foundation
import NeuralSheetCore
import Synchronization
import Testing

private extension PluginTransport {
    var ownPlayingNow: Bool { ownPlaying.load(ordering: .relaxed) }
    var hostPlayingNow: Bool { hostPlaying.load(ordering: .relaxed) }
    var pendingSeekNow: Int { pendingSeek.load(ordering: .relaxed) }
}

private func cycle(hostPlaying: Bool = false, hostStart: Double? = 1000, sampleTime: Double? = 5000,
                   ownPlaying: Bool = false, own: Int = 0, takeFrames: Int = 48000, frames: Int = 512,
                   lastMode: PluginTransport.Mode = .idle, lastHostEnd: Int = 0) -> PluginTransport.Cycle {
    PluginTransport.cycle(hostPlaying: hostPlaying, hostStart: hostStart, sampleTime: sampleTime,
                          ownPlaying: ownPlaying, ownPosition: own, takeFrames: takeFrames, frames: frames,
                          lastMode: lastMode, lastHostEnd: lastHostEnd)
}

@Test func theHostPlayingPutsTheTimelineAtItsSampleTimeLessTheTakesStart() {
    let playing = cycle(hostPlaying: true, sampleTime: 5000, ownPlaying: true, own: 300)
    #expect(playing == PluginTransport.Cycle(mode: .host, position: 4000, ownPosition: 300, ownFinished: false))

    // Before the take started on the host's clock: a negative position, which plays no notes.
    #expect(cycle(hostPlaying: true, sampleTime: 200).position == -800)
}

@Test func theHostPlayingWithoutAClockLeavesEverythingStanding() {
    // No start for the take, or no valid sample time: nothing moves, and the plugin's own
    // transport does not play over the host.
    #expect(cycle(hostPlaying: true, hostStart: nil, ownPlaying: true, own: 64).mode == .idle)
    #expect(cycle(hostPlaying: true, sampleTime: nil, ownPlaying: true, own: 64)
        == PluginTransport.Cycle(mode: .idle, position: 64, ownPosition: 64, ownFinished: false))
}

@Test func thePluginsTransportAdvancesThroughTheTakeAndStopsAtItsEnd() {
    #expect(cycle(ownPlaying: true, own: 1000)
        == PluginTransport.Cycle(mode: .own, position: 1000, ownPosition: 1512, ownFinished: false))

    // The last block runs off the end: it plays, and the transport goes back to the start, stopped.
    #expect(cycle(ownPlaying: true, own: 47800)
        == PluginTransport.Cycle(mode: .own, position: 47800, ownPosition: 0, ownFinished: true))

    // No take: nothing to play.
    #expect(cycle(ownPlaying: true, own: 0, takeFrames: 0).mode == .idle)
    // Paused: standing where it is.
    #expect(cycle(own: 700) == PluginTransport.Cycle(mode: .idle, position: 700, ownPosition: 700, ownFinished: false))
}

@Test func whenTheHostStopsThePluginsTransportStandsWhereTheHostWas() {
    #expect(cycle(own: 5, lastMode: .host, lastHostEnd: 20000)
        == PluginTransport.Cycle(mode: .idle, position: 20000, ownPosition: 20000, ownFinished: false))

    // Outside the take: at its start.
    #expect(cycle(own: 5, lastMode: .host, lastHostEnd: 90000).position == 0)
    #expect(cycle(own: 5, lastMode: .host, lastHostEnd: -10).position == 0)
}

@Test func theTakeAndTheSeekAreTheMainThreadsAndThePlayheadFollowsWhoeverMoves() {
    let transport = PluginTransport()
    let take = SourceAudio(deviceRate: 48000, channels: [[Float](repeating: 0, count: 4800)], mono16k: [],
                           peaks: WaveformPeaks(), droppedFileName: nil, sourcePath: nil)

    transport.play()
    #expect(!transport.ownPlayingNow)  // nothing to play yet

    transport.setTake(take, startSampleTime: 96000)
    #expect(transport.hostStart == 96000)
    var borrowed: SourceAudio?
    transport.withTake { borrowed = $0 }
    #expect(borrowed === take)

    transport.play()
    #expect(transport.ownPlayingNow)

    transport.seek(toFrame: 99999)
    #expect(transport.playheadFrame == 4799)
    #expect(transport.pendingSeekNow == 4799)

    // The host's position wins while it plays.
    transport.position.store(1234, ordering: .relaxed)
    transport.modeWord.store(PluginTransport.Mode.host.rawValue, ordering: .relaxed)
    #expect(transport.playheadFrame == 1234)

    transport.setTake(nil, startSampleTime: nil)
    #expect(transport.hostStart == nil)
    transport.withTake { borrowed = $0 }
    #expect(borrowed == nil)
    #expect(!transport.ownPlayingNow)
}

@Test @MainActor func thePollFollowsTheHostAndPausesThePluginsTransportWhenItStarts() {
    let transport = PluginTransport()
    let take = SourceAudio(deviceRate: 48000, channels: [[Float](repeating: 0, count: 4800)], mono16k: [],
                           peaks: WaveformPeaks(), droppedFileName: nil, sourcePath: nil)
    transport.setTake(take, startSampleTime: 0)

    var host = PluginTransportPoll.HostState(playing: false, tempo: 92)
    let poll = PluginTransportPoll(transport: transport) { host }
    var events: [String] = []
    poll.onHostStart = { events.append("start") }
    poll.onHostStop = { events.append("stop") }
    poll.onOwnStop = { events.append("own stop") }

    poll.tick()
    #expect(poll.hostTempo == 92)
    #expect(!poll.hostPlaying)

    transport.play()
    poll.refreshOwn()
    #expect(poll.ownPlaying)

    host.playing = true
    poll.tick()
    #expect(poll.hostPlaying)
    #expect(transport.hostPlayingNow)
    #expect(!transport.ownPlayingNow)
    #expect(events == ["start", "own stop"])

    host.playing = nil  // a host that stops answering is stopped
    poll.tick()
    #expect(!transport.hostPlayingNow)
    #expect(events == ["start", "own stop", "stop"])
}
