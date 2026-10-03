import Foundation
import NeuralSheetCore

/// What a take records from (system audio design §2): a hardware input, everything the Mac is
/// playing but NeuralSheet, or one app. Audio → Input's rows map onto it, and the engine wires
/// each into its private aggregate -- a device beside the output, or a process tap.
///
/// nil, wherever one is optional, is the system's default input.
nonisolated enum RecordingInput: Hashable, Sendable {
    case device(AudioDevice)
    case systemAudio
    /// One app, by the process it is now. The bundle id is what is remembered; the pid is what
    /// is tapped, and goes stale when the app quits.
    case app(bundleID: String, pid: pid_t, name: String)

    /// The hardware device, for a `.device`.
    var device: AudioDevice? {
        if case .device(let device) = self { device } else { nil }
    }

    /// The tap the engine makes for it, or nil for hardware.
    var tapKind: ProcessTap.Kind? {
        switch self {
        case .device: nil
        case .systemAudio: .allApps
        case .app(_, let pid, _): .app(pid)
        }
    }

    /// Whether a menu row for `other` is this choice: an app by its bundle id, whichever
    /// process it is now.
    func isSameChoice(as other: RecordingInput) -> Bool {
        switch (self, other) {
        case (.app(let mine, _, _), .app(let theirs, _, _)): mine == theirs
        default: self == other
        }
    }

    /// How it is remembered in the global settings. A device by its UID, which survives
    /// unplugging; nil when the device has none.
    var setting: RecordingInputSetting? {
        switch self {
        case .device(let device): InputAggregate.uid(of: device.id).map { .device(uid: $0) }
        case .systemAudio: .systemAudio
        case .app(let bundleID, _, _): .app(bundleID: bundleID)
        }
    }

    /// A remembered input, resolved against what is here now: the device by its UID among the
    /// inputs, the app by a running process with that bundle id. nil -- the system default, with
    /// no dialog -- when either is gone (issue #20 §6).
    init?(setting: RecordingInputSetting) {
        switch setting {
        case .device(let uid):
            guard let device = AudioDevices.inputs().first(where: { InputAggregate.uid(of: $0.id) == uid })
            else { return nil }

            self = .device(device)

        case .systemAudio:
            self = .systemAudio

        case .app(let bundleID):
            guard let app = ProcessTap.runningApp(bundleID: bundleID) else { return nil }

            self = .app(bundleID: app.bundleID, pid: app.pid, name: app.name)
        }
    }
}
