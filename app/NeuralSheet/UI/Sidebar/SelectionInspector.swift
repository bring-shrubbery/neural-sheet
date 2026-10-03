import AppKit
import NeuralSheetCore
import SwiftUI

/// The sidebar's SELECTION panel in the Edit tab (design §6.3): what is selected, and the fields
/// that set it (``SelectionFields``), which the roll's note card shares.
struct SelectionInspector: View {
    let model: AppModel

    @Environment(\.uiScale) private var k

    /// The header and eight rows: 150 for the design's five, then a row and its gap more for the
    /// lyric (markers and lyrics design §2) and for each read-only one, confidence (confidence
    /// design §2) and the pitch curve (pitch curves design §2).
    static let height: CGFloat = 222
    private static let paddingSide: CGFloat = 14
    private static let paddingTop: CGFloat = 12
    private static let labelHeight: CGFloat = 12

    var body: some View {
        let s = Scaled(k: k)
        let count = model.editor.selection.count

        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("SELECTION")
                    .font(Fonts.sectionHeader(k))
                    .kerning(Fonts.tracking(Fonts.Tracking.sectionHeader, pointSize: Fonts.Size.sectionHeader, scale: k))
                    .foregroundStyle(Theme.textLabel)
                    .accessibilityAddTraits(.isHeader)

                Spacer(minLength: 0)

                Text(SelectionText.count(count))
                    .font(Fonts.mono(10, weight: 400, scale: k))
                    .foregroundStyle(Theme.textFaintest)
            }
            .frame(height: s(Self.labelHeight))

            SelectionFields(model: model)
                .padding(.top, s(8))

            Spacer(minLength: 0)
        }
        .padding(.horizontal, s(Self.paddingSide))
        .padding(.top, s(Self.paddingTop))
        .frame(width: s(SidebarMetrics.stripWidth), height: s(Self.height), alignment: .topLeading)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Theme.divSoft)
                .frame(height: k)
        }
    }
}
