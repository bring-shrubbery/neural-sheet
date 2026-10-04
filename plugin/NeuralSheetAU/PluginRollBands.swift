import AppKit
import NeuralSheetCore

/// One band of the plugin's roll: an `NSView` whose `draw(_:)` is the Mac timeline's shared
/// painter over the roll's ``TimelineGeometry`` (Audio Unit design §2, "UI"). Like the Mac's and
/// the iOS app's bands it is a window a few viewports wide that slides with the scroll, its bounds
/// origin at the document x it sits at, so it draws in document coordinates.
class PluginBandView: NSView {
    let geometry: TimelineGeometry

    init(geometry: TimelineGeometry) {
        self.geometry = geometry
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) {
        nil
    }

    override var isFlipped: Bool { true }

    override var isOpaque: Bool { true }

    /// Read-only: a click goes to nothing in the band (the plugin does not edit or seek yet).
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// The current context and the exposed part of the band.
    func context(for dirtyRect: NSRect) -> (CGContext, CGRect)? {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return nil }

        return (ctx, dirtyRect.intersection(bounds))
    }
}

/// The piano roll: ``RollPainter``, with nothing selected and no drag.
final class PluginRollBand: PluginBandView {
    var painter: RollPainter

    override init(geometry: TimelineGeometry) {
        painter = RollPainter(geometry: geometry)
        super.init(geometry: geometry)
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let (ctx, dirty) = context(for: dirtyRect) else { return }

        painter.draw(ctx, in: dirty, bounds: bounds)
    }
}

/// The time ruler: ``RulerPainter`` in seconds (the plugin has no tempo grid).
final class PluginRulerBand: PluginBandView {
    var painter: RulerPainter

    override init(geometry: TimelineGeometry) {
        painter = RulerPainter(geometry: geometry)
        super.init(geometry: geometry)
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let (ctx, dirty) = context(for: dirtyRect) else { return }

        painter.draw(ctx, in: dirty, bounds: bounds)
    }
}

/// The take's waveform, the Edit tab's 40 px strip: ``WaveformPainter``.
final class PluginWaveformBand: PluginBandView {
    var peaks: WaveformPeaks?

    override func draw(_ dirtyRect: NSRect) {
        guard let (ctx, dirty) = context(for: dirtyRect) else { return }

        WaveformPainter.draw(ctx, in: dirty, bounds: bounds, geometry: geometry, peaks: peaks, isCompact: true,
                             isFileOver: false)
    }
}

/// The key column left of the roll, fixed while the roll scrolls in time: ``KeyboardPainter``.
final class PluginKeyboardBand: PluginBandView {
    var isDimmed = true

    override func draw(_ dirtyRect: NSRect) {
        guard let (ctx, dirty) = context(for: dirtyRect) else { return }

        KeyboardPainter.draw(ctx, in: dirty, bounds: bounds, geometry: geometry, isDimmed: isDimmed, key: nil)
    }
}

/// The corner beside the waveform and the ruler: ``GutterPainter``, compact as in the Edit tab.
final class PluginGutterBand: PluginBandView {
    override func draw(_ dirtyRect: NSRect) {
        guard let (ctx, _) = context(for: dirtyRect) else { return }

        GutterPainter.draw(ctx, in: dirtyRect, bounds: bounds, scale: geometry.scale,
                           waveformHeight: geometry.waveformHeight, isCompact: true)
    }
}

/// The scroll view's clip, which says when it scrolled (the scroller's drag included), so the
/// bands slide and the overlays follow without a notification observer to release.
final class PluginClipView: NSClipView {
    var onScroll: (() -> Void)?

    override func setBoundsOrigin(_ newOrigin: NSPoint) {
        super.setBoundsOrigin(newOrigin)
        onScroll?()
    }
}

/// The scroll view, whose wheel and pinch are the roll's: a wheel pans pitch and time as the Mac
/// timeline's does, ⌘-wheel and a pinch zoom time, ⌥ zooms pitch (`WheelGesture`).
final class PluginScrollView: NSScrollView {
    var onWheel: ((NSEvent) -> Void)?
    var onMagnify: ((NSEvent) -> Void)?

    override func scrollWheel(with event: NSEvent) {
        if let onWheel { onWheel(event) } else { super.scrollWheel(with: event) }
    }

    override func magnify(with event: NSEvent) {
        if let onMagnify { onMagnify(event) } else { super.magnify(with: event) }
    }
}

/// The scrolled content: as wide as the timeline, holding the time bands.
final class PluginDocumentView: NSView {
    override var isFlipped: Bool { true }
}

/// Where the playhead and the decode frontier sit over the scroll view, clipped to it and never
/// hit-tested.
final class PluginOverlayView: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        clipsToBounds = true
    }

    required init?(coder: NSCoder) {
        nil
    }

    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// The display link's target: weak on the roll, so the link's own retain never keeps it alive.
final class PluginDisplayLinkProxy: NSObject {
    weak var target: PluginRollView?

    @objc func fire(_ link: CADisplayLink) {
        target?.tick()
    }
}
