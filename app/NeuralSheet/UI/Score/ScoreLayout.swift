import AppKit
import NeuralSheetCore

/// The Score tab's geometry: the core's system layout at the view's staff space. Pages come in
/// the next task.
struct ScoreLayout {
    let systems: ScoreSystemLayout

    var sp: CGFloat { systems.sp }
    var totalHeight: CGFloat { systems.totalHeight }

    init(document: ScoreDocument, arrangement: ScoreArrangement, width: CGFloat, sp: CGFloat) {
        systems = ScoreSystemLayout(document: document, arrangement: arrangement, width: width, sp: sp)
    }

    func box(forMeasure index: Int) -> (system: ScoreSystemLayout.System, box: ScoreSystemLayout.MeasureBox)? {
        systems.box(forMeasure: index)
    }

    func hitTest(_ point: CGPoint) -> (measure: Int, units: Double)? {
        systems.hitTest(point)
    }
}
