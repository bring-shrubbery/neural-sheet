import Foundation
import NeuralSheetCore
import UniformTypeIdentifiers

/// The transcription's exits (iOS app design §2, Exports; sub-issue I): MIDI, MusicXML and PDF
/// built by the Mac's `ExportCommands` under the Mac's names, written into a temporary folder of
/// their own and handed to the export sheet, which shares them or saves them to Files and removes
/// the folder when it closes. The audio render and the stems are `+AudioExport` and
/// `+StemsExport`; the iPad's drag of the MIDI is ``dragItemProvider(musicXML:)``.
extension MobileModel {
    /// What the exports have under way and ready, as one observed value.
    struct ExportState {
        /// Export Audio…'s render, or nil.
        var audioRender: AudioRenderJob?
        /// Export Stems…'s separation or writing, or nil.
        var stemsExport: StemsExportJob?
        /// The files an export wrote, waiting to be shared or saved; nil once the sheet closes.
        var ready: ExportedFiles?
        /// Why the last export failed, for the sheet to say.
        var failure: MobileAlert?
        /// The audio choices are being asked.
        var isAskingAudio = false
        /// A MIDI file dropped over notes, waiting on Replace or Add.
        var pendingMIDI: PendingMIDIImport?
        /// The project's file name, for a recorded take's audio and stem files.
        var projectName: String?
        /// The take's kept separation (`+StemsExport`), or nil.
        var keptStems: URL?

        /// Whether the export sheet is up: asking, working, failed or ready.
        var isSheetShown: Bool {
            isAskingAudio || audioRender != nil || stemsExport != nil || ready != nil || failure != nil
        }
    }

    /// Files written for one export, in a folder of their own.
    struct ExportedFiles: Identifiable, Equatable {
        let id = UUID()
        let folder: URL
        let files: [URL]
    }

    /// The three files built from the notes alone.
    enum FileExport: CaseIterable {
        case midi, musicXML, pdf
    }

    /// A finished transcription and no run replacing it: what every export of the notes needs,
    /// as the Mac's `canExport` (`state == .populated`).
    var canExport: Bool { document != nil && run == nil }

    /// The take's name in the audio and stem files, as the Mac names them.
    var exportTakeName: String {
        ExportCommands.takeName(droppedFileName: droppedFileName, projectName: exports.projectName)
    }

    // MARK: - Names and bytes

    func exportFileName(_ kind: FileExport) -> String {
        switch kind {
        case .midi: ExportCommands.midiFileName(takeName: droppedFileName)
        case .musicXML: ExportCommands.musicXMLFileName(takeName: droppedFileName)
        case .pdf: ExportCommands.pdfFileName(takeName: droppedFileName)
        }
    }

    /// The file's bytes, or nil unless the transcription is finished (or, for the PDF, when a
    /// PDF context cannot be made).
    func exportData(_ kind: FileExport) -> Data? {
        guard canExport, let document else { return nil }

        switch kind {
        case .midi:
            return ExportCommands.midiData(notes: document.events, editor: editor, mixer: mixer,
                                           mode: settings.midiOverflowMode)
        case .musicXML:
            return ExportCommands.musicXMLData(notes: document.events, ids: document.notes.map { Optional($0.id) },
                                               editor: editor, arrangement: arrangement, takeName: droppedFileName)
        case .pdf:
            return ExportCommands.pdfData(document: scoreDocument(), arrangement: arrangement, takeName: droppedFileName)
        }
    }

    static func contentType(_ kind: FileExport) -> UTType {
        switch kind {
        case .midi: .midi
        case .musicXML: UTType(filenameExtension: "musicxml", conformingTo: .xml) ?? .xml
        case .pdf: .pdf
        }
    }

    // MARK: - Commands

    /// The Export menu's MIDI, MusicXML and PDF: the file into its folder, then the sheet.
    func export(_ kind: FileExport) {
        guard canExport, !exports.isSheetShown else { return }

        do {
            let url = try writeExport(kind)
            exports.ready = ExportedFiles(folder: url.deletingLastPathComponent(), files: [url])
        } catch {
            exports.failure = MobileAlert(title: Self.errorTitle, message: Self.writeFailure(kind))
        }
    }

    /// Writes one export into a new folder of its own and returns the file.
    func writeExport(_ kind: FileExport) throws -> URL {
        guard let data = exportData(kind) else { throw CocoaError(.fileWriteUnknown) }

        let url = try Self.newExportFolder().appendingPathComponent(exportFileName(kind))
        try data.write(to: url, options: .atomic)
        return url
    }

    /// The sheet closed: whatever it was showing is over. A render or a separation still running
    /// is cancelled, and the written files go.
    func dismissExport() {
        cancelAudioExport()
        cancelStemsExport()

        if let ready = exports.ready {
            Self.removeExportFolder(ready.folder)
        }

        exports.ready = nil
        exports.failure = nil
        exports.isAskingAudio = false
    }

    /// The document is closing: no export outlives it, and the kept stems go.
    func closeExports() {
        dismissExport()
        exports.pendingMIDI = nil
        dropKeptStems()
    }

    // MARK: - Folders

    /// `temporaryDirectory/NeuralSheet-Exports`: one folder per export, removed when its sheet
    /// closes; anything left over is swept at launch.
    nonisolated static var exportsScratchFolder: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("NeuralSheet-Exports", isDirectory: true)
    }

    nonisolated static func newExportFolder() throws -> URL {
        let folder = exportsScratchFolder.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    /// Removes one export's folder, and only a folder directly inside the scratch folder.
    nonisolated static func removeExportFolder(_ folder: URL) {
        let parent = folder.deletingLastPathComponent().standardizedFileURL.path

        guard parent == exportsScratchFolder.standardizedFileURL.path else { return }

        try? FileManager.default.removeItem(at: folder)
    }

    /// At launch: whatever an export or a drag left behind.
    nonisolated static func sweepExportScratch() {
        try? FileManager.default.removeItem(at: exportsScratchFolder)
    }

    // MARK: - Messages

    static func writeFailure(_ kind: FileExport) -> String {
        switch kind {
        case .midi: String(localized: "Could not write the MIDI file.", comment: "Alert body: File → Export MIDI… failed")
        case .musicXML: String(localized: "Could not write the MusicXML file.", comment: "Alert body: File → Export MusicXML… failed")
        case .pdf: String(localized: "Could not write the PDF file.", comment: "Alert body: File → Export PDF… failed")
        }
    }
}
