// Ported from muscriptor.cpp's cpp/include/muscriptor/note.hpp, with the lookups
// that cpp/src/instrument_groups.cpp defines for it.

/// One transcribed note. The model predicts no velocity.
public struct Note: Equatable, Hashable, Sendable {
    /// Seconds, absolute in the input signal. Onsets land on the model's 10 ms grid.
    public var onset: Double

    /// Seconds, absolute in the input signal. Offsets may be off the grid, after
    /// overlap trimming.
    public var offset: Double

    /// MIDI note number, 0-127. For a drum hit this is the GM percussion note.
    public var pitch: Int

    /// The MIDI program the model decoded, or `drumProgram` for a drum hit.
    public var program: Int

    /// Drum-token hits last `minimumDuration`. A decoded program 96 is routed to drums
    /// and keeps its decoded offset.
    public var isDrum: Bool

    public init(onset: Double, offset: Double, pitch: Int, program: Int, isDrum: Bool) {
        self.onset = onset
        self.offset = offset
        self.pitch = pitch
        self.program = program
        self.isDrum = isDrum
    }

    /// The program the reference assigns to drum hits.
    public static let drumProgram = 128

    /// Shortest note the reference will emit, and its fallback duration.
    public static let minimumDuration = 0.01
}

/// The MT3_FULL_PLUS instrument groups that have a name: 34 groups plus drums.
///
/// Raw values are the reference's group ids, so they are not contiguous, and the cases
/// are declared in id order so `allCases` is that order too. The other 31 of the 66
/// groups are unnamed; `Note.program` identifies those.
public enum InstrumentGroup: Int32, CaseIterable, Hashable, Sendable {
    case acousticPiano = 0, electricPiano = 1, chromaticPercussion = 2, organ = 3, acousticGuitar = 4,
         cleanElectricGuitar = 5, distortedElectricGuitar = 6, acousticBass = 7, electricBass = 8,
         violin = 9, viola = 10, cello = 11, contrabass = 12, orchestralHarp = 13, timpani = 14,
         stringEnsemble = 15, synthStrings = 16, voice = 17, orchestraHit = 18, trumpet = 19,
         trombone = 20, tuba = 21, frenchHorn = 22, brassSection = 23, sopranoAndAltoSax = 24,
         tenorSax = 25, baritoneSax = 26, oboe = 27, englishHorn = 28, bassoon = 29, clarinet = 30,
         flutes = 31, synthLead = 32, synthPad = 33, drums = 36

    /// The named group a decoded program number belongs to, or nil for an unnamed group.
    ///
    /// Program 96 answers `.drums`: group 36 is both how drums are selected and the
    /// singleton group of GM program 96, and the reference labels a decoded 96 "drums"
    /// and writes it to MIDI channel 10.
    public init?(program: Int) {
        if program == Note.drumProgram {
            self = .drums
            return
        }

        guard let groupID = InstrumentGroups.groupID(forProgram: program),
              InstrumentGroups.name(forGroupID: groupID) != nil,
              let group = InstrumentGroup(rawValue: Int32(groupID))
        else {
            return nil
        }

        self = group
    }

    /// The group's name, e.g. "electric_bass".
    public var name: String {
        guard let name = InstrumentGroups.name(forGroupID: Int(rawValue)) else {
            // Every case of this enum is one of the table's named groups, so reaching here is
            // not a group without a name: it is the enum and the table having drifted apart,
            // and an empty string would travel into a project file and a MusicXML part.
            preconditionFailure("instrument group \(rawValue) has no name in the instrument table")
        }

        return name
    }

    /// The program the model emits for this group; `Note.drumProgram` for drums.
    public var program: Int {
        self == .drums ? Note.drumProgram : InstrumentGroups.representativeProgram(groupID: Int(rawValue))
    }

    /// The group name where there is one, otherwise "program_<n>".
    public static func label(forProgram program: Int) -> String {
        InstrumentGroup(program: program)?.name ?? "program_\(program)"
    }
}
