import SwiftUI

/// The MIDI chip (Audio Unit design §2, "UI": *Drag MIDI out*): a document glyph and "MIDI",
/// dragged onto a track or the Finder as the `.mid`, or with ⌥ held at the mouse-down as the
/// `.musicxml`, through the app's file promise (`MidiDragSource`). Dimmed and inert until there is
/// a finished transcription. A click does nothing: the plugin has no export dialog.
struct PluginDragChip: View {
    let model: PluginViewModel

    var body: some View {
        let enabled = model.canDrag
        let model = model

        Label("MIDI", systemImage: "doc")
            .font(.callout.weight(.medium))
            .padding(.horizontal, 8)
            .frame(height: 22)
            .background(.quaternary, in: .rect(cornerRadius: 5))
            .opacity(enabled ? 1 : 0.4)
            .overlay(
                MidiDragSource(isEnabled: enabled,
                               export: { musicXML in model.dragExport(musicXML: musicXML) },
                               click: {})
            )
            .help("Drag the MIDI onto a track or the Finder · ⌥ for MusicXML")
            .accessibilityLabel("Drag the MIDI")
    }
}
