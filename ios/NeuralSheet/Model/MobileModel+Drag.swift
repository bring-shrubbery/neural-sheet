import Foundation
import NeuralSheetCore
import UniformTypeIdentifiers

/// The iPad's drag and drop (sub-issue I): the MIDI chip drags the `.mid` Export MIDI writes --
/// or the `.musicxml`, the Mac's ⌥ -- into Files or a DAW, as a file representation written only
/// when the receiver asks for it; and a `.mid` or a take dropped on the roll comes in through the
/// MIDI import or the audio import.
extension MobileModel {
    // MARK: - Out

    /// The chip's drag: the file under its export name, built and written when the drop asks,
    /// from the notes, grid, mix and arrangement as they are at the lift. Nil unless the
    /// transcription is finished.
    func dragItemProvider(musicXML: Bool) -> NSItemProvider? {
        guard canExport, let document else { return nil }

        let kind: FileExport = musicXML ? .musicXML : .midi
        let name = exportFileName(kind)
        let type = Self.contentType(kind)
        let build: @Sendable () -> Data

        if musicXML {
            let notes = document.events
            let ids = document.notes.map { Optional($0.id) }
            let editor = editor
            let arrangement = arrangement
            let takeName = droppedFileName
            build = { ExportCommands.musicXMLData(notes: notes, ids: ids, editor: editor, arrangement: arrangement, takeName: takeName) }
        } else {
            let notes = document.events
            let editor = editor
            let mixer = mixer
            let mode = settings.midiOverflowMode
            build = { ExportCommands.midiData(notes: notes, editor: editor, mixer: mixer, mode: mode) }
        }

        let provider = NSItemProvider()
        provider.suggestedName = name
        provider.registerFileRepresentation(for: type, visibility: .all) { completion in
            Self.writeDragFile(name: name, build: build, completion: completion)
        }

        return provider
    }

    /// The file representation's loader, on the provider's queue: the bytes into a folder of
    /// their own, handed over, then removed -- the receiver has its copy once `completion`
    /// returns.
    nonisolated private static func writeDragFile(name: String, build: @Sendable () -> Data,
                                                  completion: (URL?, Bool, (any Error)?) -> Void) -> Progress? {
        do {
            let folder = try newExportFolder()
            defer { removeExportFolder(folder) }

            let url = folder.appendingPathComponent(name)
            try build().write(to: url, options: .atomic)
            completion(url, false, nil)
        } catch {
            completion(nil, false, error)
        }

        return nil
    }

    // MARK: - In

    /// What the roll accepts: a MIDI file, or audio or video for a new take.
    static var droppableContentTypes: [UTType] { [.midi, .audio, .movie] }

    /// Whether a drop may land now: a MIDI file needs a take under it, a take needs no import
    /// or run in flight.
    var canAcceptDrop: Bool { canImport }

    /// The roll's drop: the first item, copied out of the provider's temporary file while it
    /// exists, then routed by its extension. False when there is nothing it can take.
    func acceptDrop(_ providers: [NSItemProvider]) -> Bool {
        guard canAcceptDrop,
              let provider = providers.first,
              let type = Self.droppableContentTypes.first(where: { provider.hasItemConformingToTypeIdentifier($0.identifier) })
        else { return false }

        _ = provider.loadFileRepresentation(for: type, openInPlace: false) { [weak self] url, _, error in
            guard let model = self, let url, error == nil, let folder = try? Self.newExportFolder() else { return }

            let copy = folder.appendingPathComponent(url.lastPathComponent)

            guard (try? FileManager.default.copyItem(at: url, to: copy)) != nil else {
                Self.removeExportFolder(folder)
                return
            }

            Task { @MainActor in
                model.importDropped(copy)
                Self.removeExportFolder(folder)
            }
        }

        return true
    }

    /// A dropped file, copied: a `.mid` through the MIDI import, anything else as a new take.
    /// Both read or copy the file before returning, so the caller may remove it.
    func importDropped(_ url: URL) {
        if MIDIImportCommands.isMIDI(url) {
            importMIDI(url: url)
        } else {
            importFile(at: url, securityScoped: false)
        }
    }
}
