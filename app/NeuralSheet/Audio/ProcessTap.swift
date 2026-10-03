import AppKit
import CoreAudio
import Foundation

/// A Core Audio process tap: what the Mac is playing, as an input stream a private aggregate can
/// carry beside the chosen output (system audio design §2). Every app but NeuralSheet itself, or
/// one app.
///
/// The tap is a HAL object that outlives nothing on its own: it is ours from
/// ``create(kind:)`` until ``destroy()``, and an aggregate that lists it has to be destroyed
/// first, since a tap in a live aggregate is in use. ``PlaybackEngine`` keeps that order; the
/// `deinit` here is only a backstop for a path that forgot.
///
/// Private (`isPrivate`), so it lives only inside this process and dies with it, and unmuted, so
/// the user keeps hearing what is being recorded. NeuralSheet's own process is excluded from the
/// all-apps tap, so the click, the MIDI and the take's playback never land in a take.
///
/// Main thread only, like the engine that owns it; `@unchecked Sendable` because the exit
/// listener's block is delivered on the main queue.
nonisolated final class ProcessTap: @unchecked Sendable {
    /// What a tap captures.
    enum Kind: Equatable, Sendable {
        /// Every process's output but NeuralSheet's own.
        case allApps
        /// One process's output, by pid.
        case app(pid_t)
    }

    /// Why a tap could not be made: CoreAudio's status. `kAudioHardwareIllegalOperationError` is
    /// how a refused permission comes back (system audio design §2).
    struct Failure: Error {
        let status: OSStatus
    }

    /// One app producing audio right now, as Audio → Input lists it.
    struct RunningApp: Identifiable, Equatable, Sendable {
        let pid: pid_t
        let bundleID: String
        let name: String

        var id: pid_t { pid }
    }

    /// The tap's HAL object.
    let id: AudioObjectID

    /// What an aggregate's composition names it by.
    let uid: String

    let kind: Kind

    /// The tapped process's HAL object, for ``Kind/app(_:)``: what the exit watch looks for.
    private let processObject: AudioObjectID?

    /// The exit watch's block as registered, which is what removing it needs.
    private var exitListener: AudioObjectPropertyListenerBlock?
    private var exitReported = false
    private var destroyed = false

    private init(id: AudioObjectID, uid: String, kind: Kind, processObject: AudioObjectID?) {
        self.id = id
        self.uid = uid
        self.kind = kind
        self.processObject = processObject
    }

    deinit {
        destroy()
    }

    // MARK: - Lifecycle

    /// Makes a tap, or throws CoreAudio's refusal. The first one a user ever makes is what puts
    /// up the system's "System Audio Recording Only" prompt (`NSAudioCaptureUsageDescription`).
    static func create(kind: Kind) throws -> ProcessTap {
        let description: CATapDescription
        var tapped: AudioObjectID?

        switch kind {
        case .allApps:
            // Not excluding nothing when our own object cannot be found: the take would then
            // carry the click and the playback, which is the one thing the input promises not to.
            guard let own = ownProcessObject() else {
                throw Failure(status: OSStatus(kAudioHardwareBadObjectError))
            }

            description = CATapDescription(stereoGlobalTapButExcludeProcesses: [own])

        case .app(let pid):
            guard let object = processObject(pid: pid) else {
                throw Failure(status: OSStatus(kAudioHardwareBadObjectError))
            }

            tapped = object
            description = CATapDescription(stereoMixdownOfProcesses: [object])
        }

        description.name = "NeuralSheet System Audio"
        description.isPrivate = true
        description.muteBehavior = .unmuted

        var tapID = AudioObjectID(kAudioObjectUnknown)
        let status = AudioHardwareCreateProcessTap(description, &tapID)

        guard status == noErr, tapID != kAudioObjectUnknown else {
            throw Failure(status: status == noErr ? OSStatus(kAudioHardwareUnspecifiedError) : status)
        }

        guard let uid = string(of: tapID, selector: kAudioTapPropertyUID) else {
            AudioHardwareDestroyProcessTap(tapID)
            throw Failure(status: OSStatus(kAudioHardwareUnspecifiedError))
        }

        return ProcessTap(id: tapID, uid: uid, kind: kind, processObject: tapped)
    }

    /// Stops watching for the process to exit and destroys the tap. Idempotent. Never while an
    /// aggregate that lists the tap still exists: destroy that first.
    func destroy() {
        guard !destroyed else { return }
        destroyed = true

        if let exitListener {
            var address = Self.processListAddress
            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject), &address, .main, exitListener)
            self.exitListener = nil
        }

        AudioHardwareDestroyProcessTap(id)
    }

    /// Calls `handler` on the main queue, once, when the tapped process has exited -- its HAL
    /// object leaves the process list. Nothing for an all-apps tap, which no exit ends.
    ///
    /// The list rather than `kAudioProcessPropertyIsRunning`, which the design named: that one
    /// says whether the process is doing I/O, so it turns false when the user pauses the app,
    /// and on exit the object is gone before it says anything (measured). The listener stays
    /// registered until ``destroy()`` removes it -- never from inside its own block -- and
    /// ``exitReported`` keeps it to one call meanwhile.
    func watchProcessExit(_ handler: @escaping @Sendable () -> Void) {
        guard let processObject, exitListener == nil, !destroyed else { return }

        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self, !self.destroyed, !self.exitReported,
                !Self.processObjects().contains(processObject)
            else { return }

            self.exitReported = true
            handler()
        }

        var address = Self.processListAddress
        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address, .main, block)

        if status == noErr {
            exitListener = block
        }
    }

    // MARK: - Processes

    /// NeuralSheet's own HAL process object, which the all-apps tap leaves out.
    static func ownProcessObject() -> AudioObjectID? {
        processObject(pid: getpid())
    }

    /// The HAL object for a process, or nil when it has never used audio or is gone.
    static func processObject(pid: pid_t) -> AudioObjectID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var pid = pid
        var object = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)

        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address,
            UInt32(MemoryLayout<pid_t>.size), &pid, &size, &object)

        return status == noErr && object != kAudioObjectUnknown ? object : nil
    }

    /// Every app producing audio right now but NeuralSheet, by name, one row per bundle id: what
    /// Audio → Input offers under System Audio. Re-read from the HAL every time, as the device
    /// lists are.
    ///
    /// A browser's audio comes from its helper process, so that is the row that appears, under
    /// the helper's own name.
    static func runningApps() -> [RunningApp] {
        apps(producingOutputOnly: true)
    }

    /// A process with this bundle id, playing or not: how a remembered app is found again at
    /// launch (system audio design §2).
    static func runningApp(bundleID: String) -> RunningApp? {
        apps(producingOutputOnly: false).first { $0.bundleID == bundleID }
    }

    private static func apps(producingOutputOnly: Bool) -> [RunningApp] {
        let own = getpid()
        var seen = Set<String>()

        let apps = processObjects().compactMap { object -> RunningApp? in
            guard let pid = uint32(of: object, selector: kAudioProcessPropertyPID).map({ pid_t(bitPattern: $0) }),
                pid != own,
                let bundleID = string(of: object, selector: kAudioProcessPropertyBundleID),
                !producingOutputOnly || uint32(of: object, selector: kAudioProcessPropertyIsRunningOutput) == 1,
                seen.insert(bundleID).inserted
            else { return nil }

            let name = NSRunningApplication(processIdentifier: pid)?.localizedName ?? bundleID
            return RunningApp(pid: pid, bundleID: bundleID, name: name)
        }

        return apps.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    // MARK: - HAL plumbing

    private static var processListAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    private static func processObjects() -> [AudioObjectID] {
        var address = processListAddress
        let system = AudioObjectID(kAudioObjectSystemObject)

        var size = UInt32(0)
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0
        else { return [] }

        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)

        let status = ids.withUnsafeMutableBufferPointer { buffer -> OSStatus in
            guard let base = buffer.baseAddress else { return OSStatus(-1) }
            return AudioObjectGetPropertyData(system, &address, 0, nil, &size, base)
        }

        guard status == noErr else { return [] }

        // The list can shrink between the two calls; trust the second size.
        return Array(ids.prefix(Int(size) / MemoryLayout<AudioObjectID>.size))
    }

    private static func uint32(of object: AudioObjectID, selector: AudioObjectPropertySelector) -> UInt32? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var value = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)

        return AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr ? value : nil
    }

    private static func string(of object: AudioObjectID, selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)

        let status = withUnsafeMutablePointer(to: &value) { pointer -> OSStatus in
            AudioObjectGetPropertyData(object, &address, 0, nil, &size, pointer)
        }

        guard status == noErr, let value else { return nil }

        let string = value.takeRetainedValue() as String
        return string.isEmpty ? nil : string
    }
}
