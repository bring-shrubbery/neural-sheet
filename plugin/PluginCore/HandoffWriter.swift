import AVFoundation
import Foundation
import NeuralSheetCore

/// *Open in NeuralSheet* (Audio Unit design §2): the take and its notes as a project package the
/// app opens, written into the App Group container's handoff folder,
/// `<handoff>/<uuid>/<name>.neuralsheet` (``AppPaths/handoff``), which is the one place both the
/// sandboxed extension and the app can reach. The app moves it into the Music folder and opens it.
///
/// The package is what the app's own Save writes (``ProjectPackage``): the take as
/// `audio/recording.wav` at the host's rate in 32-bit float, so the app decodes the very samples
/// the plugin transcribed and its 16 kHz copy has the length the notes were made against; the
/// notes as `transcription.json`; the instruments and the strips in `project.json`.
///
/// Free of AU types (design §3). Slow for a long take (a ten-minute stereo take is 230 MB of
/// WAV): off the main thread.
nonisolated enum HandoffWriter {
    /// The project's settings from the plugin's: the instruments and the strips; the rest at the
    /// app's defaults.
    static func projectState(selectedGroups: [Int32], mixer: [Int: InstrumentChannelSettings]) -> ProjectState {
        var state = ProjectState()
        state.audioFileName = ProjectPackage.recordingFileName
        state.selectedGroups = selectedGroups
        state.mixer = mixer
        return state
    }

    /// A file name from the host's track name, or "NeuralSheet Plugin": no path separators, no
    /// leading dot, at most 80 characters.
    static func packageName(trackName: String?) -> String {
        let cleaned = (trackName ?? "")
            .map { "/:\\".contains($0) || $0.isNewline ? "-" : $0 }
            .reduce(into: "") { $0.append($1) }
            .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))

        return cleaned.isEmpty ? "NeuralSheet Plugin" : String(cleaned.prefix(80))
    }

    /// Writes the package for `take` into a new `<uuid>` folder of `handoff` and returns its URL.
    /// The folder is removed again when the write fails.
    static func write(take: CapturedTake, transcription: ProjectTranscription?, state: ProjectState, name: String,
                      handoff: URL) throws -> URL {
        let manager = FileManager.default
        let folder = handoff.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let package = folder.appendingPathComponent(name).appendingPathExtension(ProjectPackage.pathExtension)
        let wav = folder.appendingPathComponent(".take.wav")

        do {
            try manager.createDirectory(at: folder, withIntermediateDirectories: true)
            defer { try? manager.removeItem(at: wav) }

            try writeWAV(take.source, to: wav)
            try ProjectPackage(state: state, transcription: transcription).write(to: package, audioSource: wav)
        } catch {
            try? manager.removeItem(at: folder)
            throw error
        }

        return package
    }

    /// `source`'s playback channels as a 32-bit float WAV at its rate.
    static func writeWAV(_ source: SourceAudio, to url: URL) throws {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: source.deviceRate,
            AVNumberOfChannelsKey: source.channelCount,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32,
                                   interleaved: false)
        let block = 65_536

        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(block)),
            let data = buffer.floatChannelData
        else { throw ProjectError.couldNotWrite("The take could not be written.") }

        var written = 0
        while written < source.frameCount {
            let count = min(block, source.frameCount - written)
            for channel in 0..<source.channelCount {
                data[channel].update(from: source.base(ofChannel: channel) + written, count: count)
            }
            buffer.frameLength = AVAudioFrameCount(count)
            try file.write(from: buffer)
            written += count
        }
    }
}
