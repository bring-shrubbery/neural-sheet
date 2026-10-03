import Foundation

/// A named section of the take (markers and lyrics design §2): "Intro", "Verse", "Chorus". Kept
/// in seconds, like the chord symbols, so it stays put when the grid changes; the score and the
/// exports find its bar through the grid. The id lets the ruler and the card name one marker
/// while the list is re-sorted under it.
public struct Marker: Equatable, Hashable, Codable, Sendable, Identifiable {
    public var id: UUID
    public var seconds: Double
    public var name: String

    public init(id: UUID = UUID(), seconds: Double, name: String) {
        self.id = id
        self.seconds = seconds
        self.name = name
    }
}

extension [Marker] {
    /// The list as the project keeps it: in time order (a stable sort, so equal times keep their
    /// order), never before 0.
    public func sortedMarkers() -> [Marker] {
        map { Marker(id: $0.id, seconds: Swift.max(0, $0.seconds.isFinite ? $0.seconds : 0), name: $0.name) }
            .enumerated()
            .sorted { $0.element.seconds != $1.element.seconds ? $0.element.seconds < $1.element.seconds : $0.offset < $1.offset }
            .map(\.element)
    }

    /// The last marker strictly before `seconds`, with a small tolerance so a playhead sitting on
    /// a marker jumps past it to the one before rather than to itself.
    public func marker(before seconds: Double, tolerance: Double = 0.01) -> Marker? {
        last { $0.seconds < seconds - tolerance }
    }

    /// The first marker strictly after `seconds`, with the same tolerance.
    public func marker(after seconds: Double, tolerance: Double = 0.01) -> Marker? {
        first { $0.seconds > seconds + tolerance }
    }

    /// "Marker N" for the next one added: one past the highest N any marker is already called,
    /// so a deleted marker's name is not handed out again beside a later one.
    public func nextDefaultName() -> String {
        let taken = compactMap { marker -> Int? in
            guard marker.name.hasPrefix("Marker ") else { return nil }
            return Int(marker.name.dropFirst("Marker ".count))
        }

        return "Marker \(Swift.max(count, taken.max() ?? 0) + 1)"
    }
}
