# Opening AAC, CAF and video files — Design

Spec: [issue #11](https://github.com/bring-shrubbery/neural-sheet/issues/11).

A voice memo is an `.m4a`; a phone clip of a gig is a `.mov`. Both are refused today because the
accepted list is NeuralNote's JUCE list (`.mp3 .wav .bwf .aiff .aif .flac .ogg`). AVFoundation
decodes AAC and reads a video's audio track, so the change is mostly a longer list plus one new
path: a video's audio is pulled out into a file of its own first, and that file is the take.

Everything this document does not mention is unchanged.

## 1. Goals and non-goals

Goals

- `.m4a`, `.aac`, `.caf`, `.mp4`, `.m4v`, `.mov` open by drop and by File → Open…
- A video never enters a project package; the extracted audio does, losslessly where the codec
  allows.
- The extraction is off the main thread and cannot be raced by another load, record or run.

Non-goals

- Formats AVFoundation does not decode. Multiple audio tracks. Showing the video.

## 2. Decisions

| Question | Decision |
|---|---|
| Where the list lives | `AudioFileLoader.acceptedExtensions`, as today, extended. `AudioFileLoader.videoExtensions = ["mp4", "m4v", "mov"]` is the subset that takes the extraction path. |
| Audio-only containers | `AVAudioFile` as today. It reads `.m4a`, ADTS `.aac`, `.caf`, and an `.mp4` that holds only audio. |
| Video containers | Always the extraction path, even when the `.mp4` has no video track: cheaper to extract than to probe, and the result is the same file. |
| Extraction | `AVAssetExportSession` with `AVAssetExportPresetPassthrough` to `.m4a` when the first audio track's format is AAC or Apple Lossless; otherwise `AVAssetReader` on that track decoded to PCM float and written with `AVAudioFile` as `.caf` (so a `.mov` with LPCM stays bit-exact). No audio track → `LoadError.decodeFailed`. |
| Where the file goes | `AppPaths.recordings`, named `<video name>.m4a` or `.caf`. That folder already has the right lifecycle: a save copies the file into the package, close deletes it, a crash's leftover is swept at launch. |
| What the take remembers | `SourceAudio.sourcePath` is the extracted file (what Save copies); `droppedFileName` is the video's name (what the title, `audioDisplayName` and export names show). |
| Threading | `AppModel.loadAudio` clears, then starts a `Task.detached` that extracts and decodes; it lands on the main actor through `installSource`. While it runs, `importJob != nil` and `loadAudio`, `clear`, `startRecording`, `transcribe` and `openProject` refuse the same way they refuse while `regionJob != nil`. |
| Messages | The pre-check keeps "Could not load the file." with the list built from `acceptedExtensions`; every failure after the clear is "Could not load the audio file." with the same list, also built from it. |

## 3. Components

### `AudioFileLoader` (`Audio/AudioFileLoader.swift`)

- `acceptedExtensions` gains `"m4a", "aac", "caf", "mp4", "m4v", "mov"`, appended after the
  current list so the message keeps the inventory's order first.
- `static let videoExtensions: Set<String>`.
- `static func isVideo(_ url: URL) -> Bool`.
- `load(url:deviceRate:namedAfterFile:)` is unchanged for everything that is not a video.

### `VideoAudioExtractor` (new, `Audio/VideoAudioExtractor.swift`)

```swift
nonisolated enum VideoAudioExtractor {
    /// Writes the first audio track of `video` into `directory` and returns the new file.
    /// Passthrough `.m4a` for AAC / ALAC, decoded PCM `.caf` for anything else.
    static func extract(video: URL, into directory: URL) async throws -> URL
}
```

`async` because `AVAssetExportSession.export()` is. Loading `AVAsset` tracks goes through
`loadTracks(withMediaType: .audio)`; the codec check reads the first track's
`formatDescriptions` for `kAudioFormatMPEG4AAC*` and `kAudioFormatAppleLossless`. An existing
file at the destination is removed first (two drops of the same clip).

### `AppModel` (`App/AppModel.swift`)

- `loadAudio(url:)`: the guards gain `importJob == nil`; the pre-check is unchanged.
- `load(url:)` becomes: for a video, set `importJob`, `Task.detached` → `VideoAudioExtractor.extract`
  → `AudioFileLoader.load(url: extracted, deviceRate:)` → back on the main actor, clear
  `importJob`, `installSource` with `droppedFileName` overridden to the video's name, or
  `showError`. For anything else, the synchronous path as today.
- `importJob` is a small `Task<Void, Never>?`; `clearNow` cancels it, and a cancelled task
  installs nothing. It is also checked by the guards listed in §2.
- The "Accepted formats" string in `load` is built from the list.

### `SourceAudio`

`AudioFileLoader.load` gains a `displayName: String?` parameter (defaults to the file's own
stem) so the extracted file carries the video's name without a second initialiser.

## 4. Error handling

| Failure | Result |
|---|---|
| Unknown extension | "Could not load the file." before anything is cleared |
| Video without an audio track, unreadable asset, export failure | "Could not load the audio file.", the project left empty, the partial file removed |
| Project closed during extraction | task cancelled, nothing installed, the extracted file swept with the recordings |

## 5. Tests

`NeuralSheetCore` has no AVFoundation, so the extraction has no unit test; it is checked by
hand against an iPhone `.mov` (AAC), a `.mov` with LPCM audio from QuickTime, and a `.mp4`
without audio. The extension list order and the video subset are covered by a test on
`AudioFileLoader` if one exists for the list; otherwise none is added for a constant.

## 6. Changelog

"Open `.m4a`, `.aac`, `.caf` and the audio of `.mp4`, `.m4v` and `.mov` video files."
