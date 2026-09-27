import Foundation

/// Which string each note of a chord is played on (arrangement design §3.3).
public enum TabFingering {
    public struct Placement: Equatable, Sendable {
        /// 0 is the bottom tab line.
        public var string: Int
        /// `pitch − open pitch`; negative or past the last fret is unplayable.
        public var fret: Int
        public var isPlayable: Bool

        public init(string: Int, fret: Int, isPlayable: Bool) {
            self.string = string
            self.fret = fret
            self.isPlayable = isPlayable
        }
    }

    /// One placement per pitch, in the pitches' order. Manual choices take their strings
    /// first; the rest, lowest pitch first, take the free string with the lowest fret at or
    /// above 0; a note no free string can hold takes the free string whose fret is nearest the
    /// playable range, unplayable; with no string free at all, the top string, unplayable.
    public static func place(pitches: [Int], tuning: [Int], frets: Int, manual: [Int?]) -> [Placement] {
        guard !tuning.isEmpty else {
            return pitches.map { _ in Placement(string: 0, fret: 0, isPlayable: false) }
        }

        var placements = [Placement?](repeating: nil, count: pitches.count)
        var taken = Set<Int>()

        // Manual first.
        for (index, pitch) in pitches.enumerated() {
            guard index < manual.count, let wanted = manual[index] else { continue }

            let string = min(max(wanted, 0), tuning.count - 1)
            let fret = pitch - tuning[string]
            placements[index] = Placement(string: string, fret: fret, isPlayable: fret >= 0 && fret <= frets && !taken.contains(string))
            taken.insert(string)
        }

        // Then the automatic ones, lowest pitch first.
        let automatic = pitches.indices.filter { placements[$0] == nil }.sorted { pitches[$0] < pitches[$1] }

        for index in automatic {
            let pitch = pitches[index]
            let free = tuning.indices.filter { !taken.contains($0) }

            guard !free.isEmpty else {
                let string = tuning.count - 1
                placements[index] = Placement(string: string, fret: pitch - tuning[string], isPlayable: false)
                continue
            }

            let playable = free.filter { pitch - tuning[$0] >= 0 && pitch - tuning[$0] <= frets }

            if let best = playable.min(by: { pitch - tuning[$0] < pitch - tuning[$1] }) {
                placements[index] = Placement(string: best, fret: pitch - tuning[best], isPlayable: true)
                taken.insert(best)
                continue
            }

            // Nearest to the range: the distance below 0 or above the last fret.
            let nearest = free.min { a, b in
                distance(pitch - tuning[a], frets: frets) < distance(pitch - tuning[b], frets: frets)
            }!
            placements[index] = Placement(string: nearest, fret: pitch - tuning[nearest], isPlayable: false)
            taken.insert(nearest)
        }

        return placements.map { $0 ?? Placement(string: 0, fret: 0, isPlayable: false) }
    }

    private static func distance(_ fret: Int, frets: Int) -> Int {
        fret < 0 ? -fret : max(0, fret - frets)
    }
}
