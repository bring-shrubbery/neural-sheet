import Foundation

/// Which notes two sets of notes do not share (versions design §2, Differences): what Show
/// Differences selects and what the status bar counts while a version is compared.
///
/// Two notes are counterparts when they are on the same instrument and pitch, start within
/// `startTolerance` of each other and end within `endTolerance` — the model's onsets wander by a
/// frame or two between runs, and its offsets by more, so an exact match would call every note
/// different. Matching is one to one and greedy by how close the starts are (ties on how close
/// the ends are), per instrument and pitch: a note can stand for one counterpart only, so two
/// quick repeats against one long note leave one of them unmatched.
public enum NoteMatcher {
    public static let defaultStartTolerance = 0.03
    public static let defaultEndTolerance = 0.06

    /// The current notes with no counterpart in `against` (`added`, by id) and the notes of
    /// `against` with none among the current ones (`missing`, in note order).
    public static func unmatched(current: [EditableNote], against: [NoteEvent],
                                 startTolerance: Double = defaultStartTolerance,
                                 endTolerance: Double = defaultEndTolerance) -> (added: Set<NoteID>, missing: [NoteEvent]) {
        struct Key: Hashable {
            var program: Int
            var pitch: Int
        }

        var currentByKey: [Key: [Int]] = [:]
        var otherByKey: [Key: [Int]] = [:]

        for (index, note) in current.enumerated() {
            currentByKey[Key(program: note.note.program, pitch: note.note.pitch), default: []].append(index)
        }

        for (index, note) in against.enumerated() {
            otherByKey[Key(program: note.program, pitch: note.pitch), default: []].append(index)
        }

        var matchedCurrent = [Bool](repeating: false, count: current.count)
        var matchedOther = [Bool](repeating: false, count: against.count)

        for (key, currentIndices) in currentByKey {
            guard let otherIndices = otherByKey[key] else { continue }

            let others = otherIndices.sorted { against[$0].startTime < against[$1].startTime }
            let otherStarts = others.map { against[$0].startTime }
            var pairs: [(current: Int, other: Int, start: Double, end: Double)] = []

            // Every pair within tolerance, found by a binary search into the other notes' starts.
            for c in currentIndices {
                let note = current[c].note
                var position = lowerBound(otherStarts, note.startTime - startTolerance)

                while position < others.count, otherStarts[position] <= note.startTime + startTolerance {
                    let o = others[position]
                    let startDistance = abs(against[o].startTime - note.startTime)
                    let endDistance = abs(against[o].endTime - note.endTime)

                    if startDistance <= startTolerance, endDistance <= endTolerance {
                        pairs.append((c, o, startDistance, endDistance))
                    }

                    position += 1
                }
            }

            pairs.sort { ($0.start, $0.end, $0.current, $0.other) < ($1.start, $1.end, $1.current, $1.other) }

            for pair in pairs where !matchedCurrent[pair.current] && !matchedOther[pair.other] {
                matchedCurrent[pair.current] = true
                matchedOther[pair.other] = true
            }
        }

        let added = Set(current.indices.filter { !matchedCurrent[$0] }.map { current[$0].id })
        let missing = against.indices.filter { !matchedOther[$0] }.map { against[$0] }.sorted()

        return (added, missing)
    }

    /// The first index whose value is not below `value`.
    private static func lowerBound(_ sorted: [Double], _ value: Double) -> Int {
        var low = 0
        var high = sorted.count

        while low < high {
            let middle = (low + high) / 2

            if sorted[middle] < value {
                low = middle + 1
            } else {
                high = middle
            }
        }

        return low
    }
}
