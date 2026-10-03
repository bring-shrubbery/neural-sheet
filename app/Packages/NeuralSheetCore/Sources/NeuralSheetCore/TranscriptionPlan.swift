import Foundation

/// One engine pass of a run: the take itself, or one of its separated stems, with the
/// instruments the decoder is held to and the share of the run's progress bar it fills.
public struct TranscriptionPass: Equatable, Sendable {
    /// The stem the pass decodes, in the separator's order (0 drums, 1 bass, 2 other, 3 vocals);
    /// nil for the take itself.
    public let stem: Int?
    /// The decoder's constraint; empty is Automatic.
    public let groups: [InstrumentGroup]

    public init(stem: Int?, groups: [InstrumentGroup]) {
        self.stem = stem
        self.groups = groups
    }

    /// The groups as the engine takes them: the library's own ids.
    public var engineGroups: [Int32] { groups.map(\.rawValue) }

    /// The pass's own 0…1 as the whole run's: all of it for a plain run; for a stems run the
    /// separation is the first half of the bar and each stem a quarter of the second.
    public func overallProgress(_ progress: Float) -> Float {
        guard let stem else { return progress }

        return 0.5 + (Float(stem) + progress) / Float(TranscriptionPlan.stemCount * 2)
    }
}

/// How a run is cut into engine passes (stem separation design §2, §5): what the app's run, the
/// iOS app's and the headless pipeline all decode with, so each transcribes a take alike.
public enum TranscriptionPlan {
    /// The stems the separator produces.
    public static let stemCount = 4

    /// The least audio a pass accepts, at the model's 16 kHz: one second. A shorter take is not
    /// run; a shorter stem contributes nothing rather than failing the run.
    public static let minimumSamples = 16_000

    /// The passes a run makes: one over the take with the selection, or one per stem with the
    /// instruments that stem can hold.
    public static func passes(selected: [InstrumentGroup], stems: Bool) -> [TranscriptionPass] {
        guard stems else { return [TranscriptionPass(stem: nil, groups: selected)] }

        return (0..<stemCount).map { TranscriptionPass(stem: $0, groups: stemGroups(stem: $0, selected: selected)) }
    }

    /// The groups each stem is decoded with (stem separation design §2): the drums as Drums, the
    /// bass as the two basses, the vocals as Voice, and the rest with the selection less those
    /// three, or every other named group when the selection is Automatic.
    public static func stemGroups(stem: Int, selected: [InstrumentGroup]) -> [InstrumentGroup] {
        let reserved: Set<InstrumentGroup> = [.drums, .acousticBass, .electricBass, .voice]

        switch stem {
        case 0: return [.drums]
        case 1: return [.acousticBass, .electricBass]
        case 3: return [.voice]
        default:
            let pool = selected.isEmpty ? InstrumentGroup.allCases : selected
            return pool.filter { !reserved.contains($0) }
        }
    }

    /// The separator's own 0…1 as the run's: the first half of the bar.
    public static func separationProgress(_ progress: Float) -> Float {
        progress * 0.5
    }
}

extension NoteEvent {
    /// The run's notes with the After transcription settings applied: what lands, at each of the
    /// three landings (a full run, a stems run, a region). Never notes already in the document.
    public static func landing(_ notes: [NoteEvent], settings: GlobalSettings) -> [NoteEvent] {
        NoteFilter.apply(
            notes, minimumLength: settings.minimumNoteLength, minimumConfidence: settings.minimumConfidence)
    }
}
