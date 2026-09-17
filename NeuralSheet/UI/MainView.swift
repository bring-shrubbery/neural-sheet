import NeuralSheetCore
import SwiftUI

struct MainView: View {
    private let canPlay = AppState.empty.canPlay

    var body: some View {
        Text("NeuralSheet")
            .padding()
    }
}

#Preview {
    MainView()
}
