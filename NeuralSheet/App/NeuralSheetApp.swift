import SwiftUI

@main
struct NeuralSheetApp: App {
    init() {
        FontRegistry.registerBundledFonts()
    }

    var body: some Scene {
        Window("NeuralSheet", id: "main") {
            MainView()
        }
    }
}
