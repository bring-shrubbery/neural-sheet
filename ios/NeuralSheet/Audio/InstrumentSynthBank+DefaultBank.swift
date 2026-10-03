import Foundation
import NeuralSheetCore
import os
import Synchronization

/// iOS has no system General MIDI bank: the Mac's DLS synth plays `gs_instruments.dls`, which
/// is not on iOS and may not be shipped, and the MIDI synth starts with no bank at all. The
/// default bank is whichever `.sf2` or `.dls` is here, looked for in order:
///
/// 1. `DefaultSoundBank.sf2` (or `.dls`) in the app bundle, if a build ships one;
/// 2. the first `.sf2` or `.dls` in `Library/NeuralSheet/soundbanks/`, where the bank download of
///    the transport and settings sub-issue (H) will put it.
///
/// None is silence on the synths, said once in the log (`+SoundBank.swift`).
nonisolated extension InstrumentSynthBank {
    /// The folder a downloaded or imported bank lives in.
    static var soundBanksDirectory: URL {
        AppPaths.standard.root.appendingPathComponent("soundbanks", isDirectory: true)
    }

    /// The default bank, or nil when there is none. Looked up afresh each time, so a bank that
    /// arrives mid-session is picked up by the next synth.
    static var systemSoundBankURL: URL? {
        for ext in ["sf2", "dls"] {
            if let bundled = Bundle.main.url(forResource: "DefaultSoundBank", withExtension: ext) {
                return bundled
            }
        }

        let entries =
            (try? FileManager.default.contentsOfDirectory(
                at: soundBanksDirectory, includingPropertiesForKeys: nil)) ?? []

        return entries
            .filter { ["sf2", "dls"].contains($0.pathExtension.lowercased()) && isSoundBankFile($0) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .first
    }

    private static let missingBankReported = Atomic<Bool>(false)

    private static let log = Logger(subsystem: "com.quassum.neuralsheet.ios", category: "audio")

    /// Once per session: the synths are silent because there is no bank to load.
    static func reportMissingSoundBank() {
        guard !missingBankReported.exchange(true, ordering: .relaxed) else { return }

        log.error(
            "No sound bank: the synth is silent until a .sf2 is in the bundle or \(soundBanksDirectory.path, privacy: .public)"
        )
    }
}
