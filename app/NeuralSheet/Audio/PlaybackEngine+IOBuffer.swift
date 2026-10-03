import AVFoundation
import CoreAudio
import Foundation

/// The I/O unit's buffer size: asked for small before the engine is prepared, and read back for
/// what the HAL actually settled on. Main thread.
nonisolated extension PlaybackEngine {
    /// Asks for the small I/O buffer, before the engine is prepared.
    ///
    /// Two routes, because neither works on its own: the AUHAL takes the property only while it is
    /// uninitialised, and it stays initialised across a stop, so a restart has to go to the device
    /// instead. The request is advisory either way — the HAL clamps it to what the device supports
    /// and to what other clients have asked for — which is why ``readIOBufferSize()`` reports what
    /// actually happened rather than what was asked.
    func requestIOBufferSize() -> OSStatus {
        var frames = Self.requestedIOBufferFrames
        let size = UInt32(MemoryLayout<UInt32>.size)

        var status = OSStatus(kAudioUnitErr_Uninitialized)

        if let unit = engine.outputNode.audioUnit {
            status = AudioUnitSetProperty(
                unit, kAudioDevicePropertyBufferFrameSize, kAudioUnitScope_Global, 0, &frames, size)
        }

        if status != noErr, let device = Self.currentDevice(of: engine.outputNode) {
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyBufferFrameSize,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )

            status = AudioObjectSetPropertyData(device, &address, 0, nil, size, &frames)
        }

        return status
    }

    /// Reads back the frame count the device settled on into ``ioBufferFrames``.
    @discardableResult
    func readIOBufferSize() -> Int {
        var frames = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        var status = OSStatus(kAudioUnitErr_Uninitialized)

        if let unit = engine.outputNode.audioUnit {
            status = AudioUnitGetProperty(
                unit, kAudioDevicePropertyBufferFrameSize, kAudioUnitScope_Global, 0, &frames, &size)
        }

        if status != noErr, let device = Self.currentDevice(of: engine.outputNode) {
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyBufferFrameSize,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )

            status = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &frames)
        }

        ioBufferFrames = status == noErr ? Int(frames) : 0

        return ioBufferFrames
    }
}
