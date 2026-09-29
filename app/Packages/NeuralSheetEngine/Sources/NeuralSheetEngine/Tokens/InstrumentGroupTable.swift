// Transcribed from muscriptor.cpp's cpp/src/instrument_groups.inc, which is itself
// generated (`uv run msl-tables --emit-cpp`) rather than written: upstream assigns
// the singleton groups (36 and up) by iterating a Python set, so their group id to
// program mapping is an artifact of CPython's set ordering and not of anything
// written down. InstrumentGroupsTests asserts this table against the same dump the
// C++ checks itself against, testdata/vectors/tables.json, which is what keeps the
// two from drifting.

/// The MT3_FULL_PLUS instrument grouping, verbatim.
enum InstrumentGroupTable {
    /// Group id to the group's first program, which is the only one the model ever
    /// emits for that group.
    static let representative: [Int16] = [
          0,   2,   8,  16,  24,  26,  29,  32,  33,  40,  41,  42,
         43,  46,  47,  48,  50,  52,  55,  56,  57,  58,  60,  61,
         64,  66,  67,  68,  69,  70,  71,  72,  80,  88, 100, 101,
         96,  97,  98,  99, 102, 103, 104, 105, 106, 107, 108, 109,
        110, 111, 112, 113, 114, 115, 116, 117, 118, 119, 120, 121,
        122, 123, 124, 125, 126, 127,
    ]

    /// The user-facing names, in the generated file's order. Group ids without one
    /// surface as their program number instead, matching the reference's `program_<n>`.
    static let named: [(name: String, groupID: Int32)] = [
        (name: "acoustic_piano", groupID: 0),
        (name: "electric_piano", groupID: 1),
        (name: "chromatic_percussion", groupID: 2),
        (name: "organ", groupID: 3),
        (name: "acoustic_guitar", groupID: 4),
        (name: "clean_electric_guitar", groupID: 5),
        (name: "distorted_electric_guitar", groupID: 6),
        (name: "acoustic_bass", groupID: 7),
        (name: "electric_bass", groupID: 8),
        (name: "violin", groupID: 9),
        (name: "viola", groupID: 10),
        (name: "cello", groupID: 11),
        (name: "contrabass", groupID: 12),
        (name: "orchestral_harp", groupID: 13),
        (name: "timpani", groupID: 14),
        (name: "string_ensemble", groupID: 15),
        (name: "synth_strings", groupID: 16),
        (name: "voice", groupID: 17),
        (name: "orchestra_hit", groupID: 18),
        (name: "trumpet", groupID: 19),
        (name: "trombone", groupID: 20),
        (name: "tuba", groupID: 21),
        (name: "french_horn", groupID: 22),
        (name: "brass_section", groupID: 23),
        (name: "soprano_and_alto_sax", groupID: 24),
        (name: "tenor_sax", groupID: 25),
        (name: "baritone_sax", groupID: 26),
        (name: "oboe", groupID: 27),
        (name: "english_horn", groupID: 28),
        (name: "bassoon", groupID: 29),
        (name: "clarinet", groupID: 30),
        (name: "flutes", groupID: 31),
        (name: "synth_lead", groupID: 32),
        (name: "synth_pad", groupID: 33),
        (name: "drums", groupID: 36),
    ]
}
