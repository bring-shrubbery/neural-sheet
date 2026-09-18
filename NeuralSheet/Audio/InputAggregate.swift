import CoreAudio
import Foundation

/// A private aggregate device pairing an input with an output, for the one AUHAL AVAudioEngine has.
///
/// `AVAudioEngine`'s input and output nodes are two faces of one AUHAL -- `inputNode.audioUnit` and
/// `outputNode.audioUnit` are the same unit -- so `kAudioOutputUnitProperty_CurrentDevice` is a
/// single choice, not one per direction. Setting it to an input-only device is refused with
/// `kAudioUnitErr_InvalidPropertyValue` (-10851), and the refusal leaves the unit with *no* device at
/// all, which takes playback down with the recording. The same refusal meets an output-only device
/// once the unit has ever had its input side enabled -- from the first recording on, for the rest of
/// the process -- so from then on a chosen output needs an aggregate too.
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
    /// one of them has no UID, when they come to the same device (nothing to aggregate) or when
    /// CoreAudio refuses.
    ///
    /// Either may itself be an aggregate -- a Multi-Output Device is a common thing to choose as the
    /// output -- and CoreAudio will not nest one, so its members are used in its place.
    ///
    /// The caller owns the result and must ``destroy(_:)`` it once the unit is off it.
    static func create(input: AudioDeviceID, output: AudioDeviceID) -> AudioDeviceID? {
        let inputUIDs = memberUIDs(of: input)
        let outputUIDs = memberUIDs(of: output)

        guard let main = outputUIDs.first, !inputUIDs.isEmpty, inputUIDs != outputUIDs else {
            return nil
        }

        // The input is listed first, so its channels are the aggregate's first input channels and a
        // recording takes them rather than whatever inputs the output device happens to have.
        //
        // The output is the main sub-device: it owns the clock, and it is the side whose timing
        // cannot be nudged without the user hearing it. Everything else is drift-compensated.
        let members = inputUIDs + outputUIDs.filter { !inputUIDs.contains($0) }

        let description: [String: Any] = [
            Key.name: "NeuralSheet Input",
            Key.uid: "com.quassum.neuralsheet.aggregate.\(UUID().uuidString)",
            Key.isPrivate: 1,
            Key.isStacked: 0,
            Key.mainSubDevice: main,
            Key.subDeviceList: members.map { uid -> [String: Any] in
                uid == main ? [Key.uid: uid] : [Key.uid: uid, Key.driftCompensation: 1]
            },
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

    /// The UIDs a composition should name for `device`: its own, or, for an aggregate, its members'
    /// in their own order. Empty when it has no UID at all.
    private static func memberUIDs(of device: AudioDeviceID) -> [String] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioAggregateDevicePropertyFullSubDeviceList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var list: Unmanaged<CFArray>?
        var size = UInt32(MemoryLayout<Unmanaged<CFArray>?>.size)

        let status = withUnsafeMutablePointer(to: &list) { pointer -> OSStatus in
            AudioObjectGetPropertyData(device, &address, 0, nil, &size, pointer)
        }

        if status == noErr, let members = list?.takeRetainedValue() as? [String], !members.isEmpty {
            return members
        }

        return uid(of: device).map { [$0] } ?? []
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
