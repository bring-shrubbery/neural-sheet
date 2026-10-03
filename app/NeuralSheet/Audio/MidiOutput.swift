import CoreMIDI
import Foundation
import NeuralSheetCore
import Synchronization

/// A CoreMIDI destination as the Audio menu lists it: remembered by its unique id, which survives
/// a relaunch and a replug, shown by its display name.
nonisolated struct MidiDestination: Identifiable, Hashable, Sendable {
    let uniqueID: Int32
    let name: String

    var id: Int32 { uniqueID }
}

/// The live MIDI output (MIDI out design §2): one CoreMIDI client and output port, the chosen
/// destination, and the sender thread that turns the render thread's notes into timestamped
/// packets.
///
/// Threading. The render thread's whole share is ``isSending`` (one atomic load), a push into
/// ``ring`` and ``signal()`` (`InstrumentSynthBank+MidiOut.swift`). Everything else is the main
/// thread's, and reaches the sender through its command queue, so a panic, a destination change
/// or a program change is ordered after every note already pushed.
nonisolated final class MidiOutput: @unchecked Sendable {
    let ring = MidiOutRing()

    /// Read once per render call: true while a destination is chosen.
    let sending = Atomic<Bool>(false)

    private let sender: MidiOutSender

    private var client: MIDIClientRef = 0
    private var port: MIDIPortRef = 0

    /// CoreMIDI said a device or a port came or went. Main queue.
    var onSetupChanged: (() -> Void)?

    /// The destination notes are sent to, or nil. Main thread.
    private(set) var destination: MidiDestination?

    /// The controllers per channel as of the last ``setRoutes(channels:mixer:)``, so a play start
    /// or a seek can send them all again and a mixer move only what changed. Main thread.
    private var controls: [MidiChannelControls] = []
    private var sentControls: [MidiChannelControls] = []

    init() {
        // The client comes before the sender, which is handed its port, so the notification block
        // cannot capture `self` yet; it reaches the handler through this relay instead.
        let relay = SetupRelay()
        var client: MIDIClientRef = 0
        var port: MIDIPortRef = 0

        let status = MIDIClientCreateWithBlock("NeuralSheet" as CFString, &client) { notification in
            guard notification.pointee.messageID == .msgSetupChanged else { return }

            DispatchQueue.main.async {
                relay.output?.onSetupChanged?()
            }
        }

        if status == noErr {
            MIDIOutputPortCreate(client, "NeuralSheet Out" as CFString, &port)
        }

        self.client = client
        self.port = port
        sender = MidiOutSender(port: port, ring: ring)
        relay.output = self
        sender.start()
    }

    deinit {
        shutDown()
    }

    // MARK: - Destinations

    /// Every destination CoreMIDI knows now, by display name: IAC buses, hardware ports, other
    /// apps' virtual inputs.
    static func destinations() -> [MidiDestination] {
        (0..<MIDIGetNumberOfDestinations()).compactMap { index in
            let endpoint = MIDIGetDestination(index)
            guard endpoint != 0 else { return nil }

            var uniqueID: Int32 = 0
            guard MIDIObjectGetIntegerProperty(endpoint, kMIDIPropertyUniqueID, &uniqueID) == noErr else { return nil }

            var name: Unmanaged<CFString>?
            let named = MIDIObjectGetStringProperty(endpoint, kMIDIPropertyDisplayName, &name) == noErr
            let title = named ? (name?.takeRetainedValue() as String?) : nil

            return MidiDestination(uniqueID: uniqueID, name: title ?? "MIDI \(uniqueID)")
        }
    }

    /// The destination with this unique id, if CoreMIDI has it now.
    static func destination(uniqueID: Int32) -> MidiDestination? {
        destinations().first { $0.uniqueID == uniqueID }
    }

    /// Sends to `destination` from now on, or to nothing: everything sounding on the old one is
    /// silenced first, and the new one is given the channels' programs and controllers. Main
    /// thread. False when the destination could not be found, which leaves the output off.
    @discardableResult
    func setDestination(_ destination: MidiDestination?) -> Bool {
        var endpoint: MIDIEndpointRef = 0

        if let destination {
            var object: MIDIObjectRef = 0
            var type = MIDIObjectType.other
            let found = MIDIObjectFindByUniqueID(destination.uniqueID, &object, &type) == noErr
            if found, type == .destination || type == .externalDestination { endpoint = object }
        }

        let resolved = endpoint == 0 ? nil : destination
        self.destination = resolved

        sender.enqueue(.setDestination(endpoint))
        sending.store(endpoint != 0, ordering: .relaxed)

        if endpoint != 0 { resendControls() }

        return resolved != nil || destination == nil
    }

    var isSending: Bool { sending.load(ordering: .relaxed) }

    // MARK: - What is sent

    /// Every channel's routing and controllers from the take's channel map and the mixer: the
    /// sender drops a muted program's notes, and a channel whose program, fader or pan moved gets
    /// its controllers again (MIDI out design §2). Main thread.
    ///
    /// Where the overflow mode puts several instruments on one channel, the lowest program names
    /// the channel's program and controllers, as the first track on it would in the file.
    func setRoutes(channels map: [Int: Int], mixer: InstrumentMixerState) {
        var routes = MidiOutRoutes()
        var byChannel: [Int: MidiChannelControls] = [:]

        for program in map.keys.sorted() where program >= 0 && program < MidiOutRoutes.programCount {
            guard let channel = map[program], (1...16).contains(channel) else { continue }

            routes.channels[program] = Int8(channel - 1)
            routes.audible[program] = mixer.isAudible(program: program)

            if byChannel[channel] == nil {
                byChannel[channel] = MidiChannelControls(
                    channel: channel,
                    program: MidiChannelMap.programChange(for: program),
                    volume: MidiChannelMap.volume(gainDb: mixer.gainDb(program: program)),
                    pan: MidiFileWriter.midiPan(mixer.pan(program: program)))
            }
        }

        sender.setRoutes(routes)
        controls = byChannel.keys.sorted().compactMap { byChannel[$0] }

        guard isSending else { return }

        let changed = controls.filter { !sentControls.contains($0) }
        sentControls = controls

        if !changed.isEmpty { sender.enqueue(.controls(changed)) }
    }

    /// Every channel's program change, CC 7 and CC 10 again: at play start, a seek and a new
    /// destination, so a DAW that missed them, or was reset, has them before the notes.
    func resendControls() {
        guard isSending else { return }

        sentControls = controls
        if !controls.isEmpty { sender.enqueue(.controls(controls)) }
    }

    /// All notes off (MIDI out design §2): CC 123 and CC 64 = 0 on every channel in use and a
    /// note-off for every note sent an on, sent after whatever the render thread has already
    /// pushed. Main thread, on stop, seek, end-of-take wrap, speed change, destination change and
    /// quit.
    func panic() {
        guard isSending else { return }

        sender.enqueue(.panic)
    }

    /// An audition note now, outside the transport: velocity 0 is its note-off. Main thread.
    func sendNote(program: Int, pitch: Int, velocity: Int) {
        guard isSending, (0...127).contains(pitch) else { return }

        sender.enqueue(.note(program: program, pitch: UInt8(pitch), velocity: UInt8(Swift.min(Swift.max(velocity, 0), 127))))
    }

    /// The render thread's wake-up for the sender, once per block that pushed anything.
    func signal() {
        sender.signal()
    }

    // MARK: - Lifecycle

    /// The quit: everything sounding is silenced and the sender given a moment to send it, then
    /// the port and the client go. Main thread; idempotent.
    func shutDown() {
        panic()
        sending.store(false, ordering: .relaxed)
        sender.stop(waitingUpTo: 0.5)

        if port != 0 {
            MIDIPortDispose(port)
            port = 0
        }

        if client != 0 {
            MIDIClientDispose(client)
            client = 0
        }
    }
}

/// Hands CoreMIDI's setup notifications to the output once it exists. Weak, so the client's block
/// does not keep the output alive; written once on the main thread before any notification can
/// matter, read on the main queue.
private nonisolated final class SetupRelay: @unchecked Sendable {
    weak var output: MidiOutput?
}
