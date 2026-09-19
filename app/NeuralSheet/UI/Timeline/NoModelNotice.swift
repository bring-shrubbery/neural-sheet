import SwiftUI

/// What the piano roll says while no transcription model is installed (§3.2, in place of the
/// panel NeuralNote forced open there): one line, and the button that opens Settings → Model.
/// Shown by the root view over the roll's part of the timeline while the roll is otherwise idle.
struct NoModelNotice: View {
    let model: AppModel

    @Environment(\.openSettings) private var openSettings
    @Environment(\.uiScale) private var k

    var body: some View {
        let s = Scaled(k: k)

        VStack(spacing: s(12)) {
            Text("No transcription model installed")
                .font(Fonts.filename(k))
                .foregroundStyle(Theme.textPrimary)

            FlatButton(idle: Theme.ctaFill,
                       on: Theme.ctaFill,
                       foregroundIdle: Theme.ctaText,
                       foregroundOn: Theme.ctaText,
                       corner: s(6),
                       action: open) { _ in
                HStack(spacing: s(9)) {
                    Icons.DownloadStroked()
                        .stroke(style: Icons.strokeStyle(scale: k))
                        .frame(width: s(15), height: s(15))
                    Text("Download a model…")
                        .font(Fonts.buttonLabel(k))
                }
                .padding(.horizontal, s(17))
                .frame(height: s(34))
                .overlay(
                    RoundedRectangle(cornerRadius: s(6), style: .circular)
                        .strokeBorder(Theme.ctaBorder, lineWidth: k))
            }
            .tooltip("Open Settings → Model")
        }
        .padding(s(20))
        .popupSurface(corner: s(8), shadow: false)
        .accessibilityElement(children: .contain)
    }

    private func open() {
        model.settingsTab = .model
        openSettings()
    }
}
