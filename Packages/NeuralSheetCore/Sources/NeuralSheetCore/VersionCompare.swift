import Foundation

/// Comparing two release tags, the way the update check does it.
///
/// The GitHub tag is `v2.1` while the bundle's version is `2.0.9`, so the leading "v" is dropped and
/// the rest read as dotted numbers: a missing component counts as 0, which is what makes `2.0` and
/// `2.0.0` the same version rather than two. Anything that is not a number reads as 0 too, so a
/// malformed tag can never be mistaken for an update.
public enum VersionCompare {
    /// Whether `remote` names a strictly newer version than `local`.
    public static func isNewer(_ remote: String, than local: String) -> Bool {
        let remoteParts = components(of: remote)
        let localParts = components(of: local)

        for index in 0..<max(remoteParts.count, localParts.count) {
            let remoteValue = index < remoteParts.count ? remoteParts[index] : 0
            let localValue = index < localParts.count ? localParts[index] : 0

            if remoteValue != localValue { return remoteValue > localValue }
        }

        return false
    }

    /// The dotted numbers of a version string, with the leading "v"/"V" dropped.
    private static func components(of version: String) -> [Int] {
        var text = Substring(version)

        if let first = text.first, first == "v" || first == "V" { text = text.dropFirst() }

        guard !text.isEmpty else { return [] }

        return text.split(separator: ".", omittingEmptySubsequences: false).map {
            Int($0.trimmingCharacters(in: .whitespaces)) ?? 0
        }
    }
}
