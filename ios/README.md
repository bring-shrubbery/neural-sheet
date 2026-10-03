NeuralSheet for iPhone and iPad, sharing the Mac app's packages and engine (design: `docs/design/2026-10-03-ios-app-design.md`).
`make project` regenerates `NeuralSheet-iOS.xcodeproj` from `project.yml` (`brew install xcodegen`); edit the spec, never the generated project.
Build with `xcodebuild -project NeuralSheet-iOS.xcodeproj -scheme NeuralSheet -destination 'generic/platform=iOS Simulator' build` (CMake on PATH, submodules checked out), or open the project in Xcode.
The temporary audio proof (sub-issue B) runs from the launch arguments: `SIMCTL_CHILD_NSUnbufferedIO=YES xcrun simctl launch --console-pty booted com.quassum.neuralsheet.ios -audioProof play,record`; `Scripts/make-test-take.py` regenerates its take.
