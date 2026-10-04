import AppKit
import SwiftUI

/// The container (Audio Unit design §2, "Project"): it exists to carry the extension, which the
/// system registers the first time this app is launched, and shows one window. Nothing at launch
/// beyond that window.
@main
struct NeuralSheetPluginApp: App {
    @NSApplicationDelegateAdaptor private var delegate: ContainerAppDelegate

    var body: some Scene {
        Window("NeuralSheet Plugin", id: "main") {
            ContainerView()
        }
        .windowResizability(.contentSize)
    }
}

final class ContainerAppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
