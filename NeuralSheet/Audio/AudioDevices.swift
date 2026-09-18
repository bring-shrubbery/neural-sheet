import CoreAudio
import Foundation

/// One CoreAudio device, as the device pickers show it.
nonisolated struct AudioDevice: Identifiable, Equatable, Sendable {
    let id: AudioDeviceID
    let name: String
}

/// The hardware list, read straight from the CoreAudio HAL.
///
/// Every call re-reads the HAL rather than caching: devices come and go while the app is open, and a
/// list is only ever built to populate a menu that is about to be shown.
nonisolated enum AudioDevices {
    /// Every device with at least one input channel.
    static func inputs() -> [AudioDevice] {
        devices(scope: kAudioObjectPropertyScopeInput)
    }

    /// Every device with at least one output channel.
    static func outputs() -> [AudioDevice] {
        devices(scope: kAudioObjectPropertyScopeOutput)
    }

    /// The system's current default input, or nil when there is no input hardware at all.
    static func defaultInput() -> AudioDevice? {
        defaultDevice(selector: kAudioHardwarePropertyDefaultInputDevice)
    }

    /// The system's current default output, or nil when there is no output hardware at all.
    static func defaultOutput() -> AudioDevice? {
        defaultDevice(selector: kAudioHardwarePropertyDefaultOutputDevice)
    }

    /// One device by id, whether or not it would appear in ``inputs()`` or ``outputs()`` — for
    /// naming the device something is actually on, which is not always one the pickers offer.
    static func device(withID id: AudioDeviceID) -> AudioDevice? {
        guard id != kAudioObjectUnknown else { return nil }

        return name(of: id).map { AudioDevice(id: id, name: $0) }
    }

    // MARK: - HAL plumbing

    private static func devices(scope: AudioObjectPropertyScope) -> [AudioDevice] {
        allDeviceIDs()
            .filter { channelCount(device: $0, scope: scope) > 0 && !isPrivate(device: $0) }
            .compactMap { id in
                name(of: id).map { AudioDevice(id: id, name: $0) }
            }
    }

    private static func defaultDevice(selector: AudioObjectPropertySelector) -> AudioDevice? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)

        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID)

        guard status == noErr, deviceID != kAudioObjectUnknown else { return nil }

        return name(of: deviceID).map { AudioDevice(id: deviceID, name: $0) }
    }

    private static func allDeviceIDs() -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var size = UInt32(0)
        guard
            AudioObjectGetPropertyDataSize(
                AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr,
            size > 0
        else { return [] }

        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var ids = [AudioDeviceID](repeating: 0, count: count)

        let status = ids.withUnsafeMutableBufferPointer { buffer -> OSStatus in
            guard let base = buffer.baseAddress else { return OSStatus(-1) }
            return AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, base)
        }

        guard status == noErr else { return [] }

        // The HAL may report fewer than it sized for; trust the second size, not the first.
        return Array(ids.prefix(Int(size) / MemoryLayout<AudioDeviceID>.size))
    }

    /// How many channels the device carries in one direction. Zero means it is not a device of that
    /// kind — which is how an input-only or output-only box is told apart from a duplex one.
    private static func channelCount(device: AudioDeviceID, scope: AudioObjectPropertyScope) -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )

        var size = UInt32(0)
        guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr, size > 0
        else { return 0 }

        let storage = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { storage.deallocate() }

        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, storage) == noErr else {
            return 0
        }

        let list = UnsafeMutableAudioBufferListPointer(
            storage.assumingMemoryBound(to: AudioBufferList.self))

        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    /// CoreAudio keeps its own devices on the same list as the real ones: the `CADefaultDeviceAggregate`
    /// it builds behind whatever the default device is, for one, which appears as soon as an engine
    /// starts and vanishes when it stops. Nobody chose it, and an engine pointed at it will not run.
    ///
    /// Two flags catch them: the device's own hidden flag, and, for an aggregate, the `private` key
    /// in its composition.
    private static func isPrivate(device: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyIsHidden,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var hidden = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)

        if AudioObjectGetPropertyData(device, &address, 0, nil, &size, &hidden) == noErr, hidden != 0
        {
            return true
        }

        address.mSelector = kAudioAggregateDevicePropertyComposition

        var composition: Unmanaged<CFDictionary>?
        size = UInt32(MemoryLayout<Unmanaged<CFDictionary>?>.size)

        let status = withUnsafeMutablePointer(to: &composition) { pointer -> OSStatus in
            AudioObjectGetPropertyData(device, &address, 0, nil, &size, pointer)
        }

        guard status == noErr, let composition else { return false }

        let dictionary = composition.takeRetainedValue() as? [String: Any]

        // kAudioAggregateDeviceIsPrivateKey, which is not exported to Swift.
        guard let flag = dictionary?["private"] as? Int else { return false }

        return flag != 0
    }

    private static func name(of device: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var name: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)

        let status = withUnsafeMutablePointer(to: &name) { pointer -> OSStatus in
            AudioObjectGetPropertyData(device, &address, 0, nil, &size, pointer)
        }

        guard status == noErr else { return nil }

        return name as String
    }
}
