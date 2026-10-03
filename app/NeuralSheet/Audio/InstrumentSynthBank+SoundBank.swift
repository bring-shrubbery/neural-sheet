import AVFoundation
import AudioToolbox
import Foundation

/// The sound bank every synth plays through (click design §2): the system's General MIDI set, or
/// a SoundFont (`.sf2`) or DLS file the user chose. Main thread throughout.
///
/// The bank goes onto each DLS synth's audio unit through `kMusicDeviceProperty_SoundBankURL`,
/// before the program change, which then picks its preset from the new bank. The unit reloads in
/// place, so a change is no graph rebuild: the instruments, the audition (which plays through
/// them) and the click all change at once.
nonisolated extension InstrumentSynthBank {
    #if os(macOS)
    /// The DLS synth's own General MIDI bank, which "System" puts back: the property has no
    /// "default" value, so returning from a SoundFont means loading this file by name. iOS has no
    /// such file; its default bank is found at run time (`ios/NeuralSheet/Audio`).
    static let systemSoundBankURL = URL(
        fileURLWithPath: "/System/Library/Components/CoreAudio.component/Contents/Resources/gs_instruments.dls")
    #endif

    /// Why a bank was refused, for the dialog.
    enum SoundBankError: Error {
        /// Not a RIFF `sfbk` or `DLS ` file; the synth is never shown it (see ``isSoundBankFile(_:)``).
        case notASoundBank
        /// The synth refused it; the status is its own.
        case refused(OSStatus)
    }

    /// Puts `url` -- nil for the system's -- on every synth, the click's included. On a refusal
    /// every synth goes back to the system bank and the error says why (issue #19 §2); the caller
    /// reverts the setting and says so. Main thread.
    ///
    /// Each synth is silenced first and given its program again after, as `allNotesOff()` does: a
    /// note held across the swap would be left sounding a preset of the old bank.
    @discardableResult
    func setSoundBank(url: URL?) -> Result<Void, SoundBankError> {
        if let url, !Self.isSoundBankFile(url) {
            applySoundBank(nil)
            return .failure(.notASoundBank)
        }

        let status = applySoundBank(url)

        guard status == noErr else {
            applySoundBank(nil)
            return .failure(.refused(status))
        }

        return .success(())
    }

    /// Loads `url` into every synth and remembers it for the synths created later; the first
    /// refusal stops there and is returned.
    @discardableResult
    private func applySoundBank(_ url: URL?) -> OSStatus {
        soundBankURL = url

        lock.lock()
        let current = Array(instruments.values) + [clickInstrument].compactMap { $0 }
        lock.unlock()

        for instrument in current {
            sendAllNotesOff(to: instrument.node)

            let status = Self.load(url ?? Self.systemSoundBankURL, into: instrument.node)

            sendProgramChange(to: instrument.node, program: instrument.program)

            if status != noErr {
                soundBankURL = nil
                return status
            }
        }

        return noErr
    }

    /// For a synth just created: the bank in force, before its first program change. Nothing to
    /// do for the system's, which a new synth starts with.
    func loadCurrentSoundBank(into node: AVAudioUnitMIDIInstrument) {
        #if os(macOS)
        guard let soundBankURL else { return }

        Self.load(soundBankURL, into: node)
        #else
        // iOS's MIDI synth starts with no bank at all, so the default is loaded by hand.
        Self.load(soundBankURL ?? Self.systemSoundBankURL, into: node)
        #endif
    }

    /// `kMusicDeviceProperty_SoundBankURL` with a `CFURL`, as the property wants it. The URL is
    /// passed unretained and kept alive across the call.
    @discardableResult
    private static func load(_ url: URL, into node: AVAudioUnitMIDIInstrument) -> OSStatus {
        let bank = url as CFURL
        var reference = Unmanaged.passUnretained(bank)

        return withExtendedLifetime(bank) {
            AudioUnitSetProperty(
                node.audioUnit,
                kMusicDeviceProperty_SoundBankURL,
                kAudioUnitScope_Global,
                0,
                &reference,
                UInt32(MemoryLayout<Unmanaged<CFURL>>.size))
        }
    }

    #if !os(macOS)
    /// iOS: no default bank installed is silence, said once in the log, not a refusal -- there is
    /// nothing to fall back to (the bank download is the transport and settings sub-issue's).
    @discardableResult
    private static func load(_ url: URL?, into node: AVAudioUnitMIDIInstrument) -> OSStatus {
        guard let url else {
            reportMissingSoundBank()
            return noErr
        }

        return load(url, into: node)
    }
    #endif

    /// Whether `url` is a RIFF file of form `sfbk` (SoundFont 2) or `DLS `.
    ///
    /// Checked before the synth sees it, and not as a nicety: measured on macOS 26, handing the
    /// DLS synth a file that is not RIFF at all (a text file renamed `.sf2`) fails a CoreAudio
    /// assertion inside `AudioUnitSetProperty` and aborts the process. A RIFF file with the right
    /// form but a damaged body is refused with an error (-10871) and is left to the synth.
    static func isSoundBankFile(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }

        guard let header = try? handle.read(upToCount: 12), header.count == 12 else { return false }

        let bytes = [UInt8](header)
        let form = String(decoding: bytes[8..<12], as: UTF8.self)

        return String(decoding: bytes[0..<4], as: UTF8.self) == "RIFF" && (form == "sfbk" || form == "DLS ")
    }
}
