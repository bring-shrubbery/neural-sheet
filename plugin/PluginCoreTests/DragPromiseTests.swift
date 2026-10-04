import AppKit
import Foundation
import NeuralSheetCore
import Testing

@Test func theDraggedFileIsNamedAfterTheHostsTrack() {
    #expect(PluginDragNames.fileName(contextName: "Bass DI", musicXML: false) == "Bass DI.mid")
    #expect(PluginDragNames.fileName(contextName: "Bass DI", musicXML: true) == "Bass DI.musicxml")
    #expect(PluginDragNames.fileName(contextName: "Gtr 1/2: Verse", musicXML: false) == "Gtr 1-2- Verse.mid")
    #expect(PluginDragNames.fileName(contextName: nil, musicXML: false) == "NeuralSheet Transcription.mid")
    #expect(PluginDragNames.fileName(contextName: "  ", musicXML: true) == "NeuralSheet Transcription.musicxml")
    #expect(PluginDragNames.fileName(contextName: "..", musicXML: false) == "NeuralSheet Transcription.mid")
}

/// The chip's promise, written where a receiver would ask for it: the MIDI file the export
/// writes, under the promised name, and the drag's scratch folder gone afterwards.
@Test @MainActor func theFilePromiseWritesTheMidiFileWhereTheReceiverAsks() async throws {
    let notes = [
        NoteEvent(startTime: 0.5, endTime: 1.0, pitch: 60, program: 0),
        NoteEvent(startTime: 1.0, endTime: 1.5, pitch: 64, program: 33),
    ]
    var mixer = InstrumentMixerState()
    mixer.update(notes: notes, selectedPrograms: [])

    let name = PluginDragNames.fileName(contextName: "Keys", musicXML: false)
    let writer = MidiPromiseWriter(fileName: name, data: {
        ExportCommands.midiData(notes: notes, editor: EditorState(), mixer: mixer, mode: .reuseChannels)
    })
    let provider = NSFilePromiseProvider(fileType: "public.midi-audio", delegate: writer)

    #expect(writer.filePromiseProvider(provider, fileNameForType: "public.midi-audio") == "Keys.mid")

    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("plugin-drag-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let destination = folder.appendingPathComponent(name)

    let error: (any Error)? = await withCheckedContinuation { continuation in
        writer.filePromiseProvider(provider, writePromiseTo: destination) { error in
            continuation.resume(returning: error)
        }
    }

    #expect(error == nil)

    let bytes = try Data(contentsOf: destination)
    #expect(bytes.prefix(4) == Data("MThd".utf8))
    #expect(bytes == ExportCommands.midiData(notes: notes, editor: EditorState(), mixer: mixer, mode: .reuseChannels))
}

@Test @MainActor func aPromiseWithNothingToWriteFails() async {
    let writer = MidiPromiseWriter(fileName: "x.mid", data: { nil })
    let provider = NSFilePromiseProvider(fileType: "public.midi-audio", delegate: writer)
    let destination = FileManager.default.temporaryDirectory.appendingPathComponent("plugin-drag-\(UUID().uuidString).mid")

    let error: (any Error)? = await withCheckedContinuation { continuation in
        writer.filePromiseProvider(provider, writePromiseTo: destination) { error in
            continuation.resume(returning: error)
        }
    }

    #expect(error != nil)
    #expect(!FileManager.default.fileExists(atPath: destination.path))
}
