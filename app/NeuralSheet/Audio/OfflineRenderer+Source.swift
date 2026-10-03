import AVFoundation
import Foundation
import NeuralSheetCore

/// The offline graph's clock and the take's player (audio export design §2): what the source
/// node's render block reads and writes. The live engine's ``PlaybackEngine`` render block,
/// stripped of what an export never does -- seeks, loops, a speed, a transport someone else
/// starts and stops -- and keeping what makes the two sound the same: the take read one buffer
/// behind the transport, the MIDI scheduled one buffer ahead, through the same bank call.
///
/// Threading: `renderOffline` calls the source node's block synchronously on the renderer's own
/// thread, so plain fields are enough; nothing here is ever reached from the live render thread.
nonisolated final class OfflineSource: @unchecked Sendable {
    let take: SourceAudio?
    let bank: InstrumentSynthBank
    let rate: Double

    /// The take's frames the file covers: the range, at the render rate. Reads outside it are
    /// silence, so the original stops dead at the range's end as the spec has it.
    let rangeFrames: Range<Int>

    /// Where the transport stops, in frames: the range's end, or the last note-off for MIDI only.
    let transportEnd: Int

    /// The take's gain, the master folded in (``MixLaw/Gains/source``); 0 for MIDI only.
    let sourceGain: Float

    /// The transport, in take frames: where the next block starts.
    private(set) var playhead: Int

    /// True once the transport has reached ``transportEnd``; the scheduler has been asked for its
    /// note-offs, and every block from here on is the tail.
    private(set) var stopped = false

    init(take: SourceAudio?, bank: InstrumentSynthBank, rate: Double, rangeFrames: Range<Int>, transportEnd: Int,
         sourceGain: Float) {
        self.take = take
        self.bank = bank
        self.rate = rate
        self.rangeFrames = rangeFrames
        self.transportEnd = transportEnd
        self.sourceGain = sourceGain
        playhead = rangeFrames.lowerBound
    }

    /// The source node's render block.
    func makeRenderBlock() -> AVAudioSourceNodeRenderBlock {
        { [self] isSilence, timestamp, frameCount, audioBufferList in
            render(isSilence: isSilence, timestamp: timestamp.pointee, frames: Int(frameCount),
                   buffers: UnsafeMutableAudioBufferListPointer(audioBufferList))
            return noErr
        }
    }

    private func render(isSilence: UnsafeMutablePointer<ObjCBool>, timestamp: AudioTimeStamp, frames: Int,
                        buffers: UnsafeMutableAudioBufferListPointer) {
        for buffer in buffers {
            if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) }
        }

        let blockStart = playhead
        let blockEnd = stopped ? blockStart : min(blockStart + frames, transportEnd)

        // One buffer behind the transport, as the live engine reads it: the MIDI for this block
        // is scheduled a buffer ahead, so this is the take under the notes being heard now.
        var heard = false
        if let take, sourceGain != 0 {
            heard = readTake(take, from: blockStart - frames, frames: frames, into: buffers)
        }

        bank.schedule(from: Double(blockStart) / rate, to: Double(blockEnd) / rate, renderTime: timestamp,
                      frameCount: frames, sampleRate: rate, outputRate: rate)

        // The take carries on under the tail only as far as the range; the transport (and with it
        // the time the take is read at) keeps advancing so the one-buffer delay stays intact.
        playhead = blockStart + frames

        if !stopped, playhead >= transportEnd {
            stopped = true
            // The notes still held at the end get their note-offs in the next block, and their
            // release is the tail. Drums are one-shot and ring out on their own.
            bank.scheduler.requestAllNotesOff()
        }

        isSilence.pointee = ObjCBool(!heard)
    }

    /// The take's frames `[start, start + frames)` inside the range, at ``sourceGain``; a mono
    /// take feeds both outputs. True when any of it was inside the range.
    private func readTake(_ take: SourceAudio, from start: Int, frames: Int,
                          into buffers: UnsafeMutableAudioBufferListPointer) -> Bool {
        let lower = max(start, rangeFrames.lowerBound, 0)
        let upper = min(start + frames, rangeFrames.upperBound, take.frameCount)
        guard lower < upper else { return false }

        for channel in 0..<min(buffers.count, 2) {
            guard let output = buffers[channel].mData?.assumingMemoryBound(to: Float.self) else { continue }

            let base = take.base(ofChannel: min(channel, take.channelCount - 1))

            for index in lower..<upper {
                output[index - start] = base[index] * sourceGain
            }
        }

        return true
    }
}
