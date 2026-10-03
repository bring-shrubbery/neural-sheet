import Foundation
import SwiftUI

// The process's entry point (batch and CLI design §2). `neuralsheet`, the launcher script in the
// bundle's Resources, runs this binary with `--headless` first: the command line is then served
// without AppKit ever starting -- no NSApplication, no windows, no Dock icon -- and the process
// exits with the tool's status. Anything else is the app.
if CommandLine.arguments.dropFirst().first == HeadlessMain.flag {
    HeadlessMain.start(arguments: Array(CommandLine.arguments.dropFirst(2)))
} else {
    NeuralSheetApp.main()
}
