import Foundation

/// The key of a transcription from its notes (key design §2): the pitch-class histogram of the
/// melodic notes, weighted by duration, correlated with the Krumhansl–Kessler profiles of the
/// twelve major and twelve minor keys.
public enum KeyEstimator {
    /// Krumhansl & Kessler (1982): how well each scale degree fits a major and a minor key.
    static let majorProfile: [Double] = [6.35, 2.23, 3.48, 2.33, 4.38, 4.09, 2.52, 5.19, 2.39, 3.66, 2.29, 2.88]
    static let minorProfile: [Double] = [6.33, 2.68, 3.52, 5.38, 2.60, 3.53, 2.54, 4.75, 3.98, 2.69, 3.34, 3.17]

    /// The best-fitting key, or nil without a melodic note.
    public static func estimate(notes: [NoteEvent]) -> MusicalKey? {
        var histogram = [Double](repeating: 0, count: 12)

        for note in notes where !note.isDrum {
            let weight = max(note.endTime - note.startTime, 0)
            guard weight.isFinite, weight > 0 else { continue }
            histogram[((note.pitch % 12) + 12) % 12] += weight
        }

        guard histogram.contains(where: { $0 > 0 }) else { return nil }

        var best: MusicalKey?
        var bestScore = -Double.infinity

        for tonic in 0..<12 {
            for mode in MusicalKey.Mode.allCases {
                let profile = mode == .major ? majorProfile : minorProfile
                // The profile rotated so its first entry sits on the tonic.
                let rotated = (0..<12).map { profile[(($0 - tonic) % 12 + 12) % 12] }
                let score = correlation(histogram, rotated)

                if score > bestScore {
                    bestScore = score
                    best = MusicalKey(tonic: tonic, mode: mode)
                }
            }
        }

        return best
    }

    /// Pearson's r.
    static func correlation(_ x: [Double], _ y: [Double]) -> Double {
        let n = Double(x.count)
        let meanX = x.reduce(0, +) / n
        let meanY = y.reduce(0, +) / n
        var covariance = 0.0
        var varianceX = 0.0
        var varianceY = 0.0

        for (a, b) in zip(x, y) {
            covariance += (a - meanX) * (b - meanY)
            varianceX += (a - meanX) * (a - meanX)
            varianceY += (b - meanY) * (b - meanY)
        }

        let denominator = (varianceX * varianceY).squareRoot()

        return denominator > 0 ? covariance / denominator : 0
    }
}
