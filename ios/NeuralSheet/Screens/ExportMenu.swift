import NeuralSheetCore
import SwiftUI
import UniformTypeIdentifiers

/// The Export menu (sub-issue I): the Mac's File → Export items for touch -- MIDI, MusicXML, PDF,
/// Audio… and Stems… -- on the Roll and Score screens' bars and the Transcribe screen's toolbar.
/// Each writes its files and opens the export sheet, which shares or saves them.
struct ExportMenu: View {
    let model: MobileModel

    var body: some View {
        Menu {
            Section {
                Button { model.export(.midi) } label: {
                    Label { Text("MIDI", comment: "Export menu: the .mid file") } icon: { Image(systemName: "pianokeys") }
                }
                .accessibilityIdentifier("export-midi")

                Button { model.export(.musicXML) } label: {
                    Label { Text("MusicXML", comment: "Export menu: the .musicxml score") } icon: { Image(systemName: "music.note.list") }
                }
                .accessibilityIdentifier("export-musicxml")

                Button { model.export(.pdf) } label: {
                    Label { Text("PDF", comment: "Export menu: the score's pages") } icon: { Image(systemName: "doc.richtext") }
                }
                .accessibilityIdentifier("export-pdf")
            }
            .disabled(!model.canExport)

            Section {
                Button { model.requestAudioExport() } label: {
                    Label { Text("Audio…", comment: "Export menu: render the take or the MIDI to an audio file") } icon: { Image(systemName: "waveform") }
                }
                .disabled(!model.canExportAudio)
                .accessibilityIdentifier("export-audio")

                Button { model.exportStems() } label: {
                    Label { Text("Stems…", comment: "Export menu: the take's drums, bass, vocals and the rest") } icon: { Image(systemName: "square.stack.3d.up") }
                }
                .disabled(!model.canExportStems)
                .accessibilityIdentifier("export-stems")
            }
        } label: {
            Label {
                Text("Export", comment: "The Export menu's button")
            } icon: {
                Image(systemName: "square.and.arrow.up")
            }
            .labelStyle(.iconOnly)
            .font(.title3)
            .frame(width: 44, height: 44)
        }
        .disabled(!model.canExportAudio && !model.canExport)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("export")
    }
}

/// The iPad's MIDI chip in the corner of the roll and the score: dragged into Files or a DAW as the `.mid` Export
/// MIDI writes, or -- chosen from its long-press menu, the Mac's ⌥ -- as the `.musicxml`.
struct ExportDragChip: View {
    let model: MobileModel

    @State private var dragsMusicXML = false

    var body: some View {
        let enabled = model.canExport

        HStack(spacing: 4) {
            Image(systemName: "doc")
            Text(verbatim: dragsMusicXML ? "MusicXML" : "MIDI")
                .font(.footnote.weight(.semibold))
        }
        .padding(.horizontal, 10)
        .frame(minHeight: 44)
        // Opaque under Reduce Transparency, as the Mac's floating cards are.
        .background(Capsule().fill(Accommodations.shared.reduceTransparency
            ? AnyShapeStyle(Color(.secondarySystemBackground)) : AnyShapeStyle(.regularMaterial)))
        .opacity(enabled ? 1 : 0.4)
        .onDrag {
            model.dragItemProvider(musicXML: dragsMusicXML) ?? NSItemProvider()
        }
        .contextMenu {
            Picker(selection: $dragsMusicXML) {
                Text("MIDI", comment: "Export menu: the .mid file").tag(false)
                Text("MusicXML", comment: "Export menu: the .musicxml score").tag(true)
            } label: {
                Text("Drag as", comment: "The MIDI chip's long-press menu: which file a drag carries")
            }
        }
        .allowsHitTesting(enabled)
        .accessibilityLabel(Text("Drag the MIDI into another app", comment: "The iPad's MIDI chip, to VoiceOver"))
        .accessibilityValue(Text(verbatim: dragsMusicXML ? "MusicXML" : "MIDI"))
        .accessibilityHint(Text("Touch and hold to drag it as MusicXML instead", comment: "VoiceOver hint (iPad): the MIDI chip's long-press menu chooses the file a drag carries"))
        .accessibilityIdentifier("drag-chip")
    }
}
