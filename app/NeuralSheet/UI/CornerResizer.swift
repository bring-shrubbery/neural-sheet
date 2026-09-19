import AppKit
import SwiftUI

/// The resize grip in the window's bottom-right corner (`ResizableCornerComponent` with
/// `NeuralNoteLookAndFeel::drawCornerResizer`, inventory §1.1): three diagonal lines at 30 / 55 /
/// 80 % of an 18 px square, `textScale` at rest and `textDim` while the pointer is on it or
/// dragging it. Window pixels, not authored ones: the original was a child of the editor, outside
/// the scaled main view.
///
/// Dragging it resizes the window the way the corner did -- the size follows the pointer, the
/// controller's clamp keeps it inside 0.5× … the display's maximum, and the window keeps its
/// top-left where it was. The scale is written back when the drag ends (`resizeEnd`).
struct CornerResizer: NSViewRepresentable {
    let controller: MainWindowController

    /// `AudioProcessorEditor::resized`'s `resizerSize`.
    static let size: CGFloat = 18

    func makeNSView(context: Context) -> ResizerView {
        ResizerView(controller: controller)
    }

    func updateNSView(_ nsView: ResizerView, context: Context) {}

    final class ResizerView: NSView {
        private let controller: MainWindowController
        private var isHovered = false
        private var isDragging = false
        private var dragOrigin = NSPoint.zero
        private var startSize = NSSize.zero
        private var tracking: NSTrackingArea?

        init(controller: MainWindowController) {
            self.controller = controller
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) is not supported")
        }

        override var isFlipped: Bool { true }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()

            if let tracking {
                removeTrackingArea(tracking)
            }

            let area = NSTrackingArea(rect: .zero,
                                      options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                      owner: self,
                                      userInfo: nil)
            addTrackingArea(area)
            tracking = area
        }

        override func mouseEntered(with event: NSEvent) {
            isHovered = true
            needsDisplay = true
        }

        override func mouseExited(with event: NSEvent) {
            isHovered = false
            needsDisplay = true
        }

        // MARK: - Drag

        override func mouseDown(with event: NSEvent) {
            guard let window else { return }

            dragOrigin = NSEvent.mouseLocation
            startSize = window.contentView?.frame.size ?? window.frame.size
            isDragging = true
            needsDisplay = true
        }

        /// `ResizableCornerComponent::mouseDrag`: the new size is the start size plus the pointer's
        /// travel, handed to the constrainer -- here the controller's clamp, which keeps the
        /// aspect and the scale limits.
        override func mouseDragged(with event: NSEvent) {
            guard isDragging else { return }

            let now = NSEvent.mouseLocation
            let width = startSize.width + (now.x - dragOrigin.x)
            let height = startSize.height - (now.y - dragOrigin.y)

            controller.resize(toContentSize: NSSize(width: width, height: height))
        }

        override func mouseUp(with event: NSEvent) {
            guard isDragging else { return }

            isDragging = false
            needsDisplay = true
            controller.persistScale()
        }

        // MARK: - Drawing

        override func draw(_ dirtyRect: NSRect) {
            guard let ctx = NSGraphicsContext.current?.cgContext else { return }

            let colour = isHovered || isDragging ? Theme.textDim : Theme.textScale
            let size = min(bounds.width, bounds.height)

            ctx.setStrokeColor(TimelinePalette.cg(colour))
            ctx.setLineWidth(1)

            for offset in [0.30, 0.55, 0.80] {
                let from = size * CGFloat(offset)

                ctx.move(to: CGPoint(x: size, y: from))
                ctx.addLine(to: CGPoint(x: from, y: size))
            }

            ctx.strokePath()
        }
    }
}
