import AVFoundation
import Foundation
import NeuralSheetCore
import Synchronization

/// The render thread's whole share of the bank: one call per render block, made from
/// ``PlaybackEngine``'s source node. Nothing here allocates, locks, looks anything up in a
/// dictionary or calls an Objective-C property -- see the type's note on threading.
nonisolated extension InstrumentSynthBank {
    /// Schedules everything in `[t0, t1)` one buffer ahead of `renderTime`, then the click's
    /// events for the same block (click design §3).
    ///
    /// One buffer ahead because the synths render in the same cycle as the source node and their
    /// order within it is not defined; ``PlaybackEngine`` delays its own source read by the same
    /// buffer, which is what keeps the two sample-aligned. `sampleRate` is the transport's (the
    /// device rate over the playback speed); `outputRate` is the device's own, which the click's
    /// free-running clock counts in while a take is being counted in or recorded.
    func schedule(
        from t0: Double, to t1: Double, renderTime: AudioTimeStamp, frameCount: Int,
        sampleRate: Double, outputRate: Double
    ) {
        frameCounter.wrappingAdd(UInt64(Swift.max(frameCount, 0)), ordering: .relaxed)

        scheduler.collect(from: t0, to: t1, sampleRate: sampleRate, into: &events)

        // `AUEventSampleTimeImmediate` takes a buffer offset too, so a timestamp without a usable
        // sample time still places the events inside the block rather than losing their order.
        let sampleTime = renderTime.mSampleTime
        let hasSampleTime =
            renderTime.mFlags.contains(.sampleTimeValid) && sampleTime.isFinite
            && abs(sampleTime) < 4e15
        let base =
            hasSampleTime
            ? AUEventSampleTime(sampleTime) + AUEventSampleTime(frameCount)
            : AUEventSampleTime(AUEventSampleTimeImmediate)

        send(events, base: base)

        scheduleClick(
            from: t0, to: t1, renderTime: renderTime, frameCount: frameCount, sampleRate: sampleRate,
            outputRate: outputRate, base: base)
    }

    /// Render thread. Hands each event to its synth's scheduling block: an indexed load, three
    /// bytes written into ``midiBytes`` and the block call, nothing else.
    func send(_ collected: [SynthEvent], base: AUEventSampleTime) {
        guard !collected.isEmpty, let bytes = midiBytes.baseAddress else { return }

        collected.withUnsafeBufferPointer { collected in
            for event in collected {
                // The drums and the click are percussion on channel 10.
                let isDrum = event.program >= NoteEvent.drumProgram

                // Drum note-offs are never sent: a GM kit is one-shot, and a note-off 10 ms into a
                // hit would choke every cymbal. A seek or a stop silences them with CC 123 instead.
                if isDrum, !event.isOn { continue }

                guard event.program >= 0, event.program < InstrumentSynthBank.programCount,
                    let block = blocks[event.program]
                else { continue }

                let channel =
                    isDrum ? InstrumentSynthBank.drumChannel : InstrumentSynthBank.melodicChannel

                bytes[0] =
                    (event.isOn
                        ? InstrumentSynthBank.noteOnStatus : InstrumentSynthBank.noteOffStatus)
                    | channel
                bytes[1] = UInt8(Swift.min(Swift.max(event.pitch, 0), 127))
                bytes[2] = event.isOn ? event.velocity : 0

                block(base + AUEventSampleTime(event.sampleOffset), 0, 3, UnsafePointer(bytes))
            }
        }
    }
}
