# Recording system audio — Design

Spec: [issue #20](https://github.com/bring-shrubbery/neural-sheet/issues/20).

The recorder reads `AVAudioEngine`'s input node, which sits on a private aggregate device
NeuralSheet builds for the chosen input and output pair (`InputAggregate`). Core Audio's process
taps (macOS 14.2) are designed to be sub-devices of exactly such an aggregate: a tap on "every
process" or on one process becomes the aggregate's input, and the engine records it as it
records a microphone. So "System Audio" is a new kind of input that the aggregate knows how to
wire, and everything downstream stays as it is.

It builds on the recording path in `2026-09-17-neuralsheet-design.md` §3 and `InputAggregate`.
Everything this document does not mention is unchanged. **Lifecycle is reviewed harder than
anything else here: a tap and an aggregate must be destroyed on every path.**

## 1. Goals and non-goals

Goals

- System Audio (all apps) or one app as the recording input, through a tap in the existing
  aggregate; NeuralSheet's own output excluded; permission handled; remembered.

Non-goals

- Tap plus microphone together; per-tab capture; virtual drivers.

## 2. Decisions

| Question | Decision |
|---|---|
| Input model | `RecordingInput` enum in the app: `.device(AudioDevice)`, `.systemAudio`, `.app(bundleID: String, pid: pid_t, name: String)`. `PlaybackEngine.inputDevice: AudioDevice?` becomes `PlaybackEngine.recordingInput: RecordingInput?`; the Audio menu's rows map onto it. |
| Tap | `CATapDescription(stereoGlobalTapButExcludeProcesses: [ownProcessObject])` for All Apps; `CATapDescription(stereoMixdownOfProcesses: [processObject])` for one app. `isPrivate = true`, `muteBehavior = .unmuted` (the user keeps hearing it). `AudioHardwareCreateProcessTap` → tap `AudioObjectID`; `AudioHardwareDestroyProcessTap` on every teardown. |
| The process object | `kAudioHardwarePropertyTranslatePIDToProcessObject` for a pid; the app's own from `getpid()`. The running-apps list: `kAudioHardwarePropertyProcessObjectList`, each with `kAudioProcessPropertyBundleID` and `kAudioProcessPropertyIsRunningOutput`; names from `NSRunningApplication(processIdentifier:)`. |
| The aggregate | `InputAggregate.create(input:output:)` gains a `tap: AudioObjectID?` form: the composition has the output as the only sub-device and the tap in `kAudioAggregateDeviceTapListKey` (`[[kAudioSubTapUIDKey: tapUID]]`), `kAudioAggregateDeviceTapAutoStartKey = true`. The tap's UID comes from `kAudioTapPropertyUID`. The engine's `rebuildGraph` treats a tap input like a device input: a new aggregate, the unit moved, the old destroyed, and now the old tap destroyed after its aggregate. |
| Order of teardown | Aggregate first, then tap (a tap in a live aggregate is in use). Both in `PlaybackEngine.deinit`, in `rebuildGraph` when the pair changes, and in `applicationWillTerminate`. |
| Permission | The first `AudioHardwareCreateProcessTap` triggers the system prompt (TCC "System Audio Recording Only"; the Info.plist needs `NSAudioCaptureUsageDescription`). A failure with `kAudioHardwareIllegalOperationError` or a tap that creates but delivers silence after 1 s with the status `kAudioHardwareNotRunningError` is treated as denied: the dialog "NeuralSheet needs permission to record system audio." / "Allow it in System Settings › Privacy & Security › Screen & System Audio Recording, then choose the input again.", and the input returns to the previous `.device`. |
| Meter and mute | Unchanged: the input node's tap feeds the meter, `inputMuted` applies as today. |
| Mid-take loss | The aggregate keeps running with silence when the tapped process exits (Core Audio keeps the tap object); the take continues as silence. The issue asked for a clean end: the recorder watches `kAudioProcessPropertyIsRunning` on the tapped process (a property listener on the main queue) and calls `toggleRecord()` when it turns false, which stops the take with what was captured. All Apps never ends this way. |
| Persistence | `GlobalSettings.recordingInput: String` encodes `device:<uid>`, `system`, or `app:<bundleID>`. At launch, `app:` resolves to a running process with that bundle id or falls back to default with no dialog. |
| Menu | Audio → Input: the hardware devices as today, a divider, "System Audio" (All Apps) and then one row per running output-producing app (excluding NeuralSheet), rebuilt in `onAppear` of the menu as the device rows are. Checkmark on the chosen one. |

## 3. Components

- `Audio/ProcessTap.swift` (new, `nonisolated`): `ProcessTap.create(kind:) throws -> ProcessTap`
  (`id`, `uid`, `destroy()`), `ProcessTap.runningApps() -> [(pid, bundleID, name)]`,
  `ProcessTap.ownProcessObject()`.
- `Audio/InputAggregate.swift`: the tap form of `create`.
- `Audio/PlaybackEngine+Devices.swift` (extract the device code from `PlaybackEngine.swift`, which
  is at 1 193 lines and must shrink anyway): `recordingInput`, the rebuild with taps, the teardown
  order, the process-exit listener.
- `App/AppModel.swift` (`setRecordingInput`), `App/NeuralSheetApp.swift` audio menu rows,
  `Core/GlobalSettings.swift`, `Info.plist` usage string, the sandbox entitlement check (audio
  input is already granted for the microphone; taps need no extra entitlement).

## 4. Checks

- Build warning-free; `swift test` unchanged (no Core logic beyond the settings string, which
  gets a round-trip test).
- Manual: the four acceptance scenarios in the issue, plus `system_profiler SPAudioDataType`
  after quit shows no NeuralSheet aggregate, and Activity Monitor shows no leaked tap (the
  `coreaudiod` tap count is visible through `kAudioHardwarePropertyTapList`; a tiny debug
  command `NeuralSheet --list-taps` is acceptable during development but must not ship).

## 5. Changelog

"Record what your Mac is playing: Audio → Input → System Audio, or one app, needs no loopback
driver."
