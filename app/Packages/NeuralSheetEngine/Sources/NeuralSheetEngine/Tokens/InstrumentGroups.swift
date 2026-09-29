// Ported from muscriptor.cpp's cpp/src/instrument_groups.hpp and
// cpp/src/instrument_groups.cpp. The table itself is in InstrumentGroupTable.swift;
// everything here is arithmetic on top of it.

/// The MT3_FULL_PLUS instrument grouping, and the two ways a caller's instrument
/// selection reaches the model.
enum InstrumentGroups {
    /// Every group, named or not.
    static let numGroups = InstrumentGroupTable.representative.count

    /// Named groups, and so the most conditioning rows a selection can add. The KV
    /// context size depends on it, which is why it is spelled out and checked.
    static let maxSelectable = 35

    /// The row either class conditioner (dataset or instrument group) embeds when given
    /// no class: `tokenize` maps it to 0 and `forward` adds one.
    static let nullConditioningRow: Int32 = 1

    /// The only program the model emits for `groupID`, or -1 when there is no such group.
    static func representativeProgram(groupID: Int) -> Int {
        guard groupID >= 0, groupID < numGroups else { return -1 }
        return Int(InstrumentGroupTable.representative[groupID])
    }

    /// The group `program` represents, or nil if it represents none. Only a group's
    /// first program answers; the others belong to the group but are never emitted.
    static func groupID(forProgram program: Int) -> Int? {
        InstrumentGroupTable.representative.firstIndex { Int($0) == program }
    }

    /// The name for `groupID`, or nil if the group has none.
    static func name(forGroupID groupID: Int) -> String? {
        InstrumentGroupTable.named.first { Int($0.groupID) == groupID }?.name
    }

    /// The group with this exact name, or nil.
    static func group(forName name: String) -> InstrumentGroup? {
        InstrumentGroupTable.named.first { $0.name == name }.flatMap { InstrumentGroup(rawValue: $0.groupID) }
    }

    /// The `instrument_group` conditioner's embedding row for `group`.
    ///
    /// `ClassConditioner::tokenize` adds one and `forward` adds one again, so a group id
    /// lands on row `id + 2`. Spelled out because the double offset reads like an
    /// off-by-one at a glance.
    static func conditioningRow(_ group: InstrumentGroup) -> Int32 {
        group.rawValue + 2
    }

    /// One conditioning row per selected group, in the caller's order, or the single
    /// null row when nothing is selected.
    static func conditioningRows(_ groups: [InstrumentGroup]) -> [Int32] {
        groups.isEmpty ? [nullConditioningRow] : groups.map(conditioningRow)
    }

    /// Token ids to force to -inf so nothing outside `groups` can be decoded: every
    /// `program` token that is not an allowed group's representative, and every `drum`
    /// token unless `.drums` is selected. Timing, pitch, velocity, tie and the specials
    /// are never masked. The result is sorted and unique.
    ///
    /// - Precondition: `groups` is non-empty. The reference forbids every program and
    ///   every drum for an empty selection, so a caller meaning "no filter" has to skip
    ///   the mask entirely rather than pass nothing here; `Transcriber` does exactly that.
    static func forbiddenTokenIDs(_ groups: [InstrumentGroup]) -> [Int32] {
        precondition(!groups.isEmpty,
                     "forbiddenTokenIDs needs a non-empty selection: the reference forbids "
                         + "every program and every drum for an empty one")

        let allowDrums = groups.contains(.drums)

        // Drums contributes no allowed program: it is not a program group, and the
        // reference skips it here rather than allowing its representative (96).
        let allowedPrograms = groups.filter { $0 != .drums }
            .map { representativeProgram(groupID: Int($0.rawValue)) }
            .filter { $0 >= 0 }

        var forbidden: [Int32] = []
        forbidden.reserveCapacity(Int(Vocabulary.programCount + Vocabulary.drumCount))

        for value in 0 ..< Vocabulary.programCount where !allowedPrograms.contains(Int(value)) {
            forbidden.append(Vocabulary.token(for: .program, value: value))
        }

        if !allowDrums {
            for value in 0 ..< Vocabulary.drumCount {
                forbidden.append(Vocabulary.token(for: .drum, value: value))
            }
        }

        return forbidden
    }
}
