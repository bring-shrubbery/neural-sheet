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

    /// What asking for an aggregate came to.
    enum Outcome {
        /// A new private aggregate the caller owns and must ``destroy(_:)`` once the unit is off it.
        case created(AudioDeviceID)
        /// `input` and `output` come to the same device, or the same set of devices: nothing to
        /// aggregate, and a duplex device takes a bare set on both sides.
        case sameDevice
        /// One of them has no UID, or CoreAudio refused.
        case failed(OSStatus)
    }

    /// An aggregate presenting `input`'s input channels and `output`'s output channels.
    ///
    /// Either may itself be an aggregate -- a Multi-Output Device is a common thing to choose as the
    /// output -- and CoreAudio will not nest one, so its members are used in its place, with its own
    /// clock device kept as the clock.
    static func create(input: AudioDeviceID, output: AudioDeviceID) -> Outcome {
        let inputMembers = members(of: input)
        let outputMembers = members(of: output)

        guard let main = outputMembers.main, !inputMembers.uids.isEmpty else {
            return .failed(OSStatus(kAudioHardwareBadDeviceError))
        }

        guard inputMembers.uids != outputMembers.uids else { return .sameDevice }

        // The input is listed first, so its channels are the aggregate's first input channels and a
        // recording takes them rather than whatever inputs the output device happens to have.
        //
        // The output side owns the clock: it is the side whose timing cannot be nudged without the
        // user hearing it. Everything else is drift-compensated.
        let uids = inputMembers.uids + outputMembers.uids.filter { !inputMembers.uids.contains($0) }

        let description: [String: Any] = [
            Key.name: "NeuralSheet Input",
            Key.uid: "com.quassum.neuralsheet.aggregate.\(UUID().uuidString)",
            Key.isPrivate: 1,
            Key.isStacked: 0,
            Key.mainSubDevice: main,
            Key.subDeviceList: uids.map { uid -> [String: Any] in
                uid == main ? [Key.uid: uid] : [Key.uid: uid, Key.driftCompensation: 1]
            },
        ]

        var device = AudioDeviceID(0)
        let status = AudioHardwareCreateAggregateDevice(description as CFDictionary, &device)

        guard status == noErr else { return .failed(status) }
        guard device != kAudioObjectUnknown else {
            return .failed(OSStatus(kAudioHardwareUnspecifiedError))
        }

        return .created(device)
    }

    /// Tears one down. Harmless for `nil` and for a device that is already gone; never call it while
    /// an I/O unit is still pointed at it.
    static func destroy(_ device: AudioDeviceID?) {
        guard let device, device != kAudioObjectUnknown else { return }

        AudioHardwareDestroyAggregateDevice(device)
    }

    /// The UIDs a composition should name for `device`, and which of them keeps the clock.
    ///
    /// A plain device is itself, both ways. An aggregate is its members in their own order -- all of
    /// them, so a member the user has switched off still comes along disabled rather than being
    /// silently lost -- and its clock is the main sub-device it was configured with, or failing
    /// that its first active member. `uids` is empty when the device has no UID at all.
    private static func members(of device: AudioDeviceID) -> (uids: [String], main: String?) {
        let all = stringList(of: device, selector: kAudioAggregateDevicePropertyFullSubDeviceList)

        guard !all.isEmpty else {
            let uid = uid(of: device)
            return (uid.map { [$0] } ?? [], uid)
        }

        let main =
            string(of: device, selector: kAudioAggregateDevicePropertyMainSubDevice)
            ?? stringList(of: device, selector: kAudioAggregateDevicePropertyActiveSubDeviceList)
                .first
            ?? all.first

        return (all, main)
    }

    private static func stringList(
        of device: AudioDeviceID, selector: AudioObjectPropertySelector
    ) -> [String] {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var list: Unmanaged<CFArray>?
        var size = UInt32(MemoryLayout<Unmanaged<CFArray>?>.size)

        let status = withUnsafeMutablePointer(to: &list) { pointer -> OSStatus in
            AudioObjectGetPropertyData(device, &address, 0, nil, &size, pointer)
        }

        guard status == noErr, let list else { return [] }

        return list.takeRetainedValue() as? [String] ?? []
    }

    private static func string(of device: AudioDeviceID, selector: AudioObjectPropertySelector)
        -> String?
    {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)

        let status = withUnsafeMutablePointer(to: &value) { pointer -> OSStatus in
            AudioObjectGetPropertyData(device, &address, 0, nil, &size, pointer)
        }

        guard status == noErr, let value else { return nil }

        let string = value.takeRetainedValue() as String
        return string.isEmpty ? nil : string
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
