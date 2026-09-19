import AppKit
import NeuralSheetCore

/// The container's part in editing: the controller's life, and the scrolling a drag asks for.
extension TimelineContainerView {
    /// The controller exists exactly while the timeline is in Edit mode and in a window; the
    /// mode's `didSet` and `viewDidMoveToWindow` both settle it here.
    func syncEditController() {
        let wanted = mode == .edit && window != nil

        if wanted, editController == nil {
            editController = RollEditController(model: model, roll: roll, geometry: geometry, container: self)
        } else if !wanted, let editController {
            editController.uninstall()
            self.editController = nil
        }
    }

    /// Auto-scroll during a drag: one key up or down (`firstKey` counts keys). Answers whether
    /// the column moved, which it does not once the range's end is on screen.
    @discardableResult
    func scrollPitch(bySemitones semitones: Int) -> Bool {
        let before = Int(geometry.firstKey)
        geometry.firstKey += Double(semitones)
        geometry.settleFirstKey()

        guard Int(geometry.firstKey) != before else { return false }

        keyboard.needsDisplay = true
        roll.needsDisplay = true

        return true
    }
}
