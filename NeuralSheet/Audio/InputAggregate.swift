import CoreAudio
import Foundation

/// A private aggregate device pairing a chosen input with the output that is playing.
///
/// `AVAudioEngine`'s input and output nodes are two faces of one AUHAL -- `inputNode.audioUnit` and
/// `outputNode.audioUnit` are the same unit -- so `kAudioOutputUnitProperty_CurrentDevice` is a
/// single choice, not one per direction. Setting it to an input-only device is refused with
/// `kAudioUnitErr_InvalidPropertyValue` (-10851), and the refusal leaves the unit with *no* device at
/// all, which takes playback down with the recording.
///
/// macOS has the same problem with its own defaults and answers it with an aggregate: the device an
/// untouched engine is on is a `CADefaultDeviceAggregate` CoreAudio built behind the two defaults.
/// This builds the same thing for a pair the user chose.
///
/// The aggregates here are private, so they live only inside this process, never appear in Sound
/// Settings, and are filtered out of ``AudioDevices/inputs()`` and ``AudioDevices/outputs()`` by the
/// `private` flag in their composition.
nonisolated enum InputAggregate {
    /// The composition keys, which CoreAudio only publishes as C string macros.
    private enum Key {
        static let name = "name"
        static let uid = "uid"
        static let isPrivate = "private"
        static let isStacked = "stacked"
        static let mainSubDevice = "master"
        static let subDeviceList = "subdevices"
        static let driftCompensation = "drift"
    }

    /// An aggregate presenting `input`'s input channels and `output`'s output channels, or nil when
    /// one of them has no UID, when they are the same device (nothing to aggregate) or when
    /// CoreAudio refuses.
    ///
    /// The caller owns the result and must ``destroy(_:)`` it once the unit is off it.
    static func create(input: AudioDeviceID, output: AudioDeviceID) -> AudioDeviceID? {
        guard input != output, let inputUID = uid(of: input), let outputUID = uid(of: output),
            inputUID != outputUID
        else { return nil }

        // The input is listed first, so its channels are the aggregate's first input channels and a
        // recording takes them rather than whatever inputs the output device happens to have.
        //
        // The output is the main sub-device: it owns the clock, and it is the side whose timing
        // cannot be nudged without the user hearing it. The input is drift-compensated instead.
        let description: [String: Any] = [
            Key.name: "NeuralSheet Input",
            Key.uid: "com.quassum.neuralsheet.aggregate.\(UUID().uuidString)",
            Key.isPrivate: 1,
            Key.isStacked: 0,
            Key.mainSubDevice: outputUID,
            Key.subDeviceList: [
                [Key.uid: inputUID, Key.driftCompensation: 1],
                [Key.uid: outputUID],
            ],
        ]

        var device = AudioDeviceID(0)
        let status = AudioHardwareCreateAggregateDevice(description as CFDictionary, &device)

        guard status == noErr, device != kAudioObjectUnknown else { return nil }

        return device
    }

    /// Tears one down. Harmless for `nil` and for a device that is already gone; never call it while
    /// an I/O unit is still pointed at it.
    static func destroy(_ device: AudioDeviceID?) {
        guard let device, device != kAudioObjectUnknown else { return }

        AudioHardwareDestroyAggregateDevice(device)
    }

    /// A device's persistent UID, which is how a composition names its sub-devices.
    static func uid(of device: AudioDeviceID) -> String? {
        guard device != kAudioObjectUnknown else { return nil }

        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var uid: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)

        let status = withUnsafeMutablePointer(to: &uid) { pointer -> OSStatus in
            AudioObjectGetPropertyData(device, &address, 0, nil, &size, pointer)
        }

        guard status == noErr else { return nil }

        return uid as String
    }
}
