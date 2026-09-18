import NeuralSheetCore
import SwiftUI

/// The panel pinned to the bottom of the sidebar (§1.4): a "MASTER" label over the 26-segment
/// master meter, under a `divSoft` top border. 63 authored points tall.
struct MasterPanel: View {
    /// The master level after ballistics and the staleness rule, in dB.
    let level: Double
    /// The panel's width in authored points: the sidebar's column, less its border.
    var width: CGFloat = SidebarMetrics.stripWidth

    @Environment(\.uiScale) private var k

    // MARK: - Authored extents (`Sidebar.cpp`, `nn::metrics`)

    static let height: CGFloat = 63
    private static let paddingSide: CGFloat = 14
    private static let paddingTop: CGFloat = 12
    private static let labelHeight: CGFloat = 12
    private static let meterTopGap: CGFloat = 10
    private static let meterHeight: CGFloat = 5
    private static let meterSegments = 26
    private static let meterGap: CGFloat = 3

    var body: some View {
        let s = Scaled(k: k)

        VStack(alignment: .leading, spacing: 0) {
            Text("MASTER")
                .font(Fonts.sectionHeader(k))
                .kerning(Fonts.tracking(Fonts.Tracking.sectionHeader,
                                        pointSize: Fonts.Size.sectionHeader,
                                        scale: k))
                .foregroundStyle(Theme.textLabel)
                .lineLimit(1)
                .frame(height: s(Self.labelHeight), alignment: .leading)

            LevelMeter(db: level,
                       segments: Self.meterSegments,
                       gap: Self.meterGap,
                       height: Self.meterHeight,
                       unlit: Theme.meterUnlitMaster)
                .padding(.top, s(Self.meterTopGap))

            Spacer(minLength: 0)
        }
        .padding(.horizontal, s(Self.paddingSide))
        .padding(.top, s(Self.paddingTop))
        .frame(width: s(width), height: s(Self.height), alignment: .topLeading)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Theme.divSoft)
                .frame(height: k)
        }
    }
}

#Preview("Master panel") {
    VStack(spacing: 0) {
        MasterPanel(level: -36)
        MasterPanel(level: -10)
        MasterPanel(level: -2)
    }
    .background(Theme.bgSidebar)
}
