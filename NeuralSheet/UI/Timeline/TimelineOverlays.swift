import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The centred Transcribe call-to-action (`VisualizationPanel::mTranscribeButton`, §3.4): height 34,
/// padding 17, icon gap 9, corner 6, `ctaFill` over an accent outline, `ctaText` icon and label.
/// Visible while the roll is idle and a model is installed; enabled only with audio loaded.
struct TranscribeCTA: View {
    let label: String
    let isEnabled: Bool
    let scale: CGFloat
    let action: () -> Void

    var body: some View {
        FlatButton(isEnabled: isEnabled,
                   idle: Theme.ctaFill,
                   on: Theme.ctaFill,
                   foregroundIdle: Theme.ctaText,
                   foregroundOn: Theme.ctaText,
                   corner: 6 * scale,
                   action: action) { _ in
            HStack(spacing: 9 * scale) {
                Icons.TranscribeStroked()
                    .stroke(style: Icons.strokeStyle(scale: scale))
                    .frame(width: 15 * scale, height: 15 * scale)
                Text(label)
                    .font(Fonts.buttonLabel(scale))
            }
            .padding(.horizontal, 17 * scale)
            .frame(height: 34 * scale)
            .overlay(
                RoundedRectangle(cornerRadius: 6 * scale, style: .circular)
                    .strokeBorder(Theme.ctaBorder, lineWidth: 1 * scale))
        }
        .tooltip("Transcribe the loaded audio")
        .environment(\.uiScale, scale)
    }
}

/// The "Load audio file" button on the empty waveform (`AudioRegion::mLoadButton`, §7.3): folder
/// icon 14 px, height 32, padding 15, gap 8, accent outline over `accentFillButton`. Opens the
/// "Select Audio File" chooser filtered to the accepted extensions.
struct LoadAudioButton: View {
    let scale: CGFloat
    let action: () -> Void

    var body: some View {
        FlatButton(idle: Theme.accentFillButton,
                   on: Theme.accentFillButton,
                   foregroundIdle: Theme.ctaText,
                   foregroundOn: Theme.ctaText,
                   corner: 6 * scale,
                   action: action) { _ in
            HStack(spacing: 8 * scale) {
                Icons.FolderStroked()
                    .stroke(style: Icons.strokeStyle(scale: scale))
                    .frame(width: 14 * scale, height: 14 * scale)
                Text("Load audio file")
                    .font(Fonts.buttonLabel(scale))
            }
            .padding(.horizontal, 15 * scale)
            .frame(height: 32 * scale)
            .overlay(
                RoundedRectangle(cornerRadius: 6 * scale, style: .circular)
                    .strokeBorder(Theme.ctaBorder, lineWidth: 1 * scale))
        }
        .tooltip("Load an audio file")
        .environment(\.uiScale, scale)
    }

    /// The chooser the button opens: "Select Audio File", one file, the loader's own extensions.
    static func chooseFile() -> URL? {
        let panel = NSOpenPanel()
        panel.title = "Select Audio File"
        panel.message = "Select Audio File"
        panel.allowedContentTypes = AudioFileLoader.acceptedExtensions.compactMap { UTType(filenameExtension: $0) }
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false

        guard panel.runModal() == .OK else { return nil }

        return panel.url
    }
}

/// An `NSHostingView` that sizes itself to its content and stays out of the way of the timeline
/// underneath: a click beside the button is a click on the roll.
final class OverlayHost<Content: View>: NSHostingView<Content> {
    required init(rootView: Content) {
        super.init(rootView: rootView)
        sizingOptions = [.intrinsicContentSize]
        translatesAutoresizingMaskIntoConstraints = true
    }

    @MainActor @preconcurrency required init?(coder: NSCoder) {
        nil
    }

    /// Re-measures the content and places it centred in `region` — or, with `top`, centred
    /// horizontally with its top edge there.
    func place(centredIn region: CGRect, top: CGFloat? = nil) {
        let size = intrinsicContentSize
        let x = region.minX + ((region.width - size.width) / 2).rounded(.down)
        let y = top ?? region.minY + ((region.height - size.height) / 2).rounded(.down)

        frame = CGRect(x: x, y: y, width: size.width, height: size.height)
    }
}
