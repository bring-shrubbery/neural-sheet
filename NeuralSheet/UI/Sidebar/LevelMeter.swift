import NeuralSheetCore
import SwiftUI

/// A row of rounded segments lit from the left up to a level (`NnLevelMeter`): 16 of them under an
/// instrument strip's fader, 26 in the master panel.
///
/// The level arrives already smoothed -- `AppModel` runs the ballistics and the staleness rule for
/// every meter on one clock (§2.5) -- so this is only the mapping from a decibel value to segments,
/// through `MeterScale`. The segment colours come from the same scale, so the two sizes agree on
/// where green turns pale and where it turns hot even though no boundary falls on the same
/// decibel at both.
///
/// Only the lit count reaches the drawing: `db` changes on most frames, the count on few, and the
/// canvas is redrawn only when the count does.
struct LevelMeter: View {
    /// The level to show, after ballistics. Anything below the scale's floor reads as nothing lit.
    let db: Double
    let segments: Int
    /// Authored points between segments; multiplied by the UI scale here.
    let gap: CGFloat
    /// Authored height; multiplied by the UI scale here. The width is whatever the row gives.
    let height: CGFloat
    /// What an unlit segment is drawn in: the strip and the master differ (§1.4, §2.5).
    var unlit: Color = Theme.meterUnlitStrip

    @Environment(\.uiScale) private var k

    /// `nn::metrics::meterCorner`.
    static let corner: CGFloat = 1

    var body: some View {
        MeterSegments(lit: MeterScale.litSegments(db: db, count: segments),
                      count: segments,
                      gap: gap * k,
                      corner: LevelMeter.corner * k,
                      unlit: unlit)
            .equatable()
            .frame(height: height * k)
            .frame(maxWidth: .infinity)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

/// The drawing, keyed on the lit count rather than the level so SwiftUI can skip it when nothing
/// visible has changed.
private struct MeterSegments: View, Equatable {
    let lit: Int
    let count: Int
    let gap: CGFloat
    let corner: CGFloat
    let unlit: Color

    var body: some View {
        Canvas(opaque: false, rendersAsynchronously: false) { context, size in
            guard count > 0 else { return }

            // Float widths: the last segment's right edge then lands exactly on the width, where
            // rounding each one would accumulate into a ragged end. Neither meter divides into
            // whole pixels.
            let width = (size.width - CGFloat(count - 1) * gap) / CGFloat(count)

            guard width > 0 else { return }

            for segment in 0 ..< count {
                let rect = CGRect(x: CGFloat(segment) * (width + gap), y: 0, width: width, height: size.height)
                let colour = segment < lit ? MeterSegments.colour(for: segment, count: count) : unlit

                context.fill(Path(roundedRect: rect, cornerRadius: corner, style: .circular), with: .color(colour))
            }
        }
    }

    private static func colour(for segment: Int, count: Int) -> Color {
        switch MeterScale.band(segment: segment, count: count) {
        case .hot: Theme.meterHot
        case .mid: Theme.meterMid
        case .low: Theme.meterLow
        }
    }
}

#Preview("Level meters") {
    VStack(alignment: .leading, spacing: 12) {
        ForEach([-36.0, -24, -12, -6, -3, 0], id: \.self) { db in
            HStack(spacing: 12) {
                Text(TimeFormat.decibels(db))
                    .font(Fonts.meta(1))
                    .foregroundStyle(Theme.textDim)
                    .frame(width: 40, alignment: .trailing)
                LevelMeter(db: db, segments: 16, gap: 2, height: 3)
                    .frame(width: 163)
                LevelMeter(db: db, segments: 26, gap: 3, height: 5, unlit: Theme.meterUnlitMaster)
                    .frame(width: 233)
            }
        }
    }
    .padding(20)
    .background(Theme.bgSidebar)
}
