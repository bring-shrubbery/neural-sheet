import NeuralSheetCore
import SwiftUI

/// The workspace tabs under the top bar (design §3.1): TRANSCRIBE, and EDIT once there is a
/// finished transcription. Room to the right for more.
struct TabStrip: View {
    let model: AppModel

    @Environment(\.uiScale) private var k

    static let height: CGFloat = 32
    private static let paddingLeft: CGFloat = 18
    private static let tabGap: CGFloat = 16
    private static let underlineHeight: CGFloat = 2

    var body: some View {
        let s = Scaled(k: k)

        HStack(spacing: s(Self.tabGap)) {
            TabButton(title: "TRANSCRIBE",
                      isActive: model.workspace == .transcribe,
                      isEnabled: true,
                      tooltip: nil) { model.setWorkspace(.transcribe) }

            TabButton(title: "EDIT",
                      isActive: model.workspace == .edit,
                      isEnabled: model.canEdit,
                      tooltip: model.canEdit ? nil : "Transcribe the audio first") { model.setWorkspace(.edit) }

            Spacer(minLength: 0)
        }
        .padding(.leading, s(Self.paddingLeft))
        .frame(height: s(Self.height))
        .frame(maxWidth: .infinity)
        .background(Theme.bgTopBar)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Theme.divStrong)
                .frame(height: k)
        }
    }

    /// One tab: the label, and the accent underline flush with the strip's border when active.
    private struct TabButton: View {
        let title: String
        let isActive: Bool
        let isEnabled: Bool
        let tooltip: String?
        let action: () -> Void

        @Environment(\.uiScale) private var k
        @State private var isHovered = false

        var body: some View {
            let s = Scaled(k: k)
            let colour = isActive || (isHovered && isEnabled) ? Theme.textPrimary : Theme.textMuted

            VStack(spacing: 0) {
                Spacer(minLength: 0)

                Text(title)
                    .font(Fonts.sectionHeader(k))
                    .kerning(Fonts.tracking(Fonts.Tracking.sectionHeader,
                                            pointSize: Fonts.Size.sectionHeader,
                                            scale: k))
                    .foregroundStyle(colour)
                    .lineLimit(1)

                Spacer(minLength: 0)

                Rectangle()
                    .fill(isActive ? Theme.accent : Color.clear)
                    .frame(height: s(TabStrip.underlineHeight))
            }
            .frame(height: s(TabStrip.height - 1))
            .fixedSize(horizontal: true, vertical: false)
            .contentShape(Rectangle())
            .opacity(isEnabled ? 1 : Theme.disabledAlpha)
            .onHover { isHovered = $0 }
            .onTapGesture { if isEnabled { action() } }
            .pointerStyle(isEnabled ? .link : nil)
            .tooltip(tooltip ?? "")
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel(title)
        }
    }
}
