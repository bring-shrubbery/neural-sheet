// Ported from muscriptor.cpp's cpp/src/vocabulary.hpp and cpp/src/vocabulary.cpp.

/// The event kinds the MT3 vocabulary encodes, in vocabulary order.
enum EventType: Int8 {
    case pad, eos, unk, shift, pitch, velocity, tie, program, drum
}

/// One decoded token: what it is, and the number it carries.
struct TokenEvent: Equatable {
    var type: EventType = .pad
    var value: Int32 = 0
}

/// A note's identity for as long as it is sounding.
struct NoteKey: Hashable, Comparable {
    var program: Int = 0
    var pitch: Int = 0

    /// The tie prologue is emitted in this order, and the reference's is `(program, pitch)`.
    static func < (lhs: NoteKey, rhs: NoteKey) -> Bool {
        (lhs.program, lhs.pitch) < (rhs.program, rhs.pitch)
    }
}

/// The MT3 token vocabulary: a fixed arithmetic index/event mapping.
///
/// Despite the name upstream gives it this is not a text tokenizer. There is no
/// BPE, no merges file and nothing to load: the vocabulary is contiguous ranges
/// concatenated in a fixed order, so a token id is a position in that
/// concatenation and a handful of comparisons reproduce it exactly.
enum Vocabulary {
    static let maxShiftSteps: Int32 = 1001

    // The ranges, laid out the way the reference's `build_event_vocab` concatenates
    // them. Written as running offsets rather than as literals so the structure stays
    // visible and a single wrong bound cannot hide.
    static let padID: Int32 = 0
    static let eosID: Int32 = 1
    static let unkID: Int32 = 2

    static let shiftFirst: Int32 = 3
    static let shiftCount = maxShiftSteps

    static let pitchFirst = shiftFirst + shiftCount
    static let pitchCount: Int32 = 128

    static let velocityFirst = pitchFirst + pitchCount
    static let velocityCount: Int32 = 2

    static let tieFirst = velocityFirst + velocityCount
    static let tieCount: Int32 = 1

    static let programFirst = tieFirst + tieCount
    static let programCount: Int32 = 130

    static let drumFirst = programFirst + programCount
    static let drumCount: Int32 = 128

    static let numTokens = drumFirst + drumCount

    /// The model's 10 ms grid, in frames per second.
    static let frameRate = 100

    /// Range descriptor, so `event(for:)` and `token(for:value:)` cannot disagree.
    private struct Range {
        var type: EventType
        var first: Int32
        var count: Int32
    }

    private static let ranges: [Range] = [
        Range(type: .pad, first: padID, count: 1),
        Range(type: .eos, first: eosID, count: 1),
        Range(type: .unk, first: unkID, count: 1),
        Range(type: .shift, first: shiftFirst, count: shiftCount),
        Range(type: .pitch, first: pitchFirst, count: pitchCount),
        Range(type: .velocity, first: velocityFirst, count: velocityCount),
        Range(type: .tie, first: tieFirst, count: tieCount),
        Range(type: .program, first: programFirst, count: programCount),
        Range(type: .drum, first: drumFirst, count: drumCount),
    ]

    /// What `tokenID` decodes to. An id outside the vocabulary answers `.unk`, which
    /// the decode state machine ignores: the same thing the reference does with a
    /// token it has no rule for.
    static func event(for tokenID: Int32) -> TokenEvent {
        for range in ranges where tokenID >= range.first && tokenID < range.first + range.count {
            return TokenEvent(type: range.type, value: tokenID - range.first)
        }

        return TokenEvent(type: .unk, value: 0)
    }

    /// The token id for an event, or -1 when `value` is outside that kind's range.
    static func token(for type: EventType, value: Int32) -> Int32 {
        for range in ranges where range.type == type {
            return value >= 0 && value < range.count ? range.first + value : -1
        }

        return -1
    }

    /// Encodes a tie prologue declaring `openKeys` as still sounding:
    /// `program p, pitch a, pitch b, program q, pitch c, …, tie`, over the keys sorted
    /// by `(program, pitch)`, with each program token emitted once for its run of
    /// pitches. An empty set still yields the bare `tie`.
    ///
    /// This is both what prelude forcing teacher-forces and what the training encoder
    /// produces, which is why the two agree.
    static func tieSectionTokenIDs(openKeys: [NoteKey]) -> [Int32] {
        var tokens: [Int32] = []
        tokens.reserveCapacity(openKeys.count * 2 + 1)

        // Tracks the sticky program register the decoder will be in, so a program token
        // is emitted once per run rather than once per pitch. Seeded with a value no
        // program can take, so the first key always emits one.
        var programState = -1

        for key in openKeys.sorted() {
            if key.program != programState {
                tokens.append(token(for: .program, value: Int32(key.program)))
                programState = key.program
            }

            tokens.append(token(for: .pitch, value: Int32(key.pitch)))
        }

        tokens.append(token(for: .tie, value: 0))
        return tokens
    }
}
