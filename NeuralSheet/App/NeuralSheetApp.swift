import SwiftUI

@main
struct NeuralSheetApp: App {
    /// Created once with the app: it owns the audio engine, and a second instance would open a
    /// second one.
    @State private var model = AppModel()

    init() {
        FontRegistry.registerBundledFonts()
    }

    var body: some Scene {
        Window("NeuralSheet", id: "main") {
            MainView(model: model)
        }
    }
}
