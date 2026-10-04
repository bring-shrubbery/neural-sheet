import Foundation
import NeuralSheetCore
import SwiftUI

// Before anything reads a model or the settings, the app and the command line alike: the one-time
// move of `~/Library/NeuralSheet/models` and `global.settings` into the App Group container the
// Audio Unit shares (Audio Unit design §2, "Models and settings"). Quiet once done.
AppPaths.standard.migrateToGroupContainer()

// The process's entry point (batch and CLI design §2). `neuralsheet`, the launcher script in the
// bundle's Resources, runs this binary with `--headless` first: the command line is then served
// without AppKit ever starting -- no NSApplication, no windows, no Dock icon -- and the process
// exits with the tool's status. Anything else is the app.
if CommandLine.arguments.dropFirst().first == HeadlessMain.flag {
    HeadlessMain.start(arguments: Array(CommandLine.arguments.dropFirst(2)))
} else {
    NeuralSheetApp.main()
}
