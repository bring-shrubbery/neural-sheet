import SwiftUI

/// The MIDI chip at the trailing end of the Edit and Score toolbars (MIDI out design §2): a
/// document glyph and "MIDI", dragged onto the Finder or a DAW's track as the `.mid` File →
/// Export MIDI… would write, or with ⌥ held at the mouse-down as the `.musicxml`. A click without
/// a drag runs Export MIDI…. Dimmed and inert until there is a finished transcription.
///
/// NeuralNote's drag-out, reduced to a chip with a file promise: the file is written when the
/// receiver asks for it, so the drop carries the tempo and the mix as they are then.
struct MidiDragChip: View {
    let model: AppModel

    @Environment(\.uiScale) private var k

    private typealias Metrics = Toolbar.Metrics

    var body: some View {
        let s = Scaled(k: k)
        let enabled = model.canExport
        let model = model

        HStack(spacing: s(6)) {
            DocumentGlyph()
                .stroke(style: Icons.strokeStyle(scale: k))
                .frame(width: s(Metrics.iconSize), height: s(Metrics.iconSize))

            Text("MIDI")
                .font(Fonts.buttonLabel(k))
                .fixedSize()
        }
        .foregroundStyle(Theme.textButton)
        .padding(.horizontal, s(Metrics.buttonPadX - 2))
        .frame(height: s(Metrics.buttonHeight))
        .background(RoundedRectangle(cornerRadius: s(Metrics.corner), style: .circular).fill(Theme.bgControlAlt))
        .opacity(enabled ? 1 : Theme.disabledAlpha)
        .overlay(
            MidiDragSource(isEnabled: enabled,
                           export: { musicXML in model.dragExport(musicXML: musicXML) },
                           click: { model.requestExport() })
        )
        .tooltip("Drag the MIDI into a DAW or the Finder | ⌥ for MusicXML · click to export")
        // A file promise needs a mouse; to VoiceOver and the keyboard the chip is the click,
        // Export MIDI…, which writes the same file (a11y design §2).
        .accessibleButton(Text(AccessibilityText.exportMIDI), isEnabled: enabled) { model.requestExport() }
    }
}

/// A page with its corner folded: the chip's glyph, in the icons' 16-point design square.
private nonisolated struct DocumentGlyph: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()

        p.move(to: CGPoint(x: 3.5, y: 1.5))
        p.addLine(to: CGPoint(x: 9.5, y: 1.5))
        p.addLine(to: CGPoint(x: 12.5, y: 4.5))
        p.addLine(to: CGPoint(x: 12.5, y: 14.5))
        p.addLine(to: CGPoint(x: 3.5, y: 14.5))
        p.closeSubpath()
        p.move(to: CGPoint(x: 9.5, y: 1.5))
        p.addLine(to: CGPoint(x: 9.5, y: 4.5))
        p.addLine(to: CGPoint(x: 12.5, y: 4.5))

        return IconGeometry.fitted(p, in: rect)
    }
}
