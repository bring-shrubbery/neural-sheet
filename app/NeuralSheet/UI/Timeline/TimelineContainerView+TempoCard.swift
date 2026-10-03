import AppKit
import NeuralSheetCore
import SwiftUI

/// The ruler's tempo card (tempo map design §4), hanging from the pointer. One at a time; it
/// goes with the window, with the take, and with the next click elsewhere.
extension TimelineContainerView {
    func showTempoCard(at windowPoint: CGPoint, bar: Int) {
        guard let window, model.state.canPlay else { return }

        let model = model
        let card = tempoCard

        card.showPanel(at: window.convertPoint(toScreen: windowPoint), in: window, scale: geometry.scale) {
            RulerTempoCard(model: model, bar: bar, host: card)
        }
    }
}
