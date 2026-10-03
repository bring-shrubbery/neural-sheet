import NeuralSheetCore
import SwiftUI

// TODO(E): replace with a thin UIView over the shared CoreGraphics waveform drawing once the
// drawing split (iOS app design §3.2, sub-issue E) has landed.

/// The take's waveform, the whole take across the width: one min/max bar per point column, read
/// from the peaks pyramid in a single locked pass (`WaveformPeaks.withReader`). While a take is
/// recording it draws the live peaks, the take so far filling the width.
struct WaveformStrip: View {
    let peaks: WaveformPeaks?
    /// Redraws every frame, for the live peaks of a take in progress.
    var live = false

    var body: some View {
        if live {
            TimelineView(.animation(minimumInterval: 1.0 / 30)) { _ in
                canvas
            }
        } else {
            canvas
        }
    }

    private var canvas: some View {
        Canvas { context, size in
            guard let peaks else { return }

            let columns = max(Int(size.width), 1)
            let mid = size.height / 2
            var path = Path()

            peaks.withReader { reader in
                let count = reader.sampleCount

                guard count > 0 else { return }

                for column in 0..<columns {
                    let start = column * count / columns
                    let end = max((column + 1) * count / columns, start + 1)
                    let pair = reader.peaks(from: start, to: end)

                    guard !pair.isEmpty else { continue }

                    let top = mid - CGFloat(min(pair.max, 1)) * mid
                    let bottom = mid - CGFloat(max(pair.min, -1)) * mid
                    path.addRect(CGRect(x: CGFloat(column), y: top, width: 1, height: max(bottom - top, 1)))
                }
            }

            context.fill(path, with: .color(.accentColor))
        }
        .accessibilityHidden(true)
    }
}
