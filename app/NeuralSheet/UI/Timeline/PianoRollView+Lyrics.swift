import AppKit
import NeuralSheetCore

/// A note's syllable written inside it (markers and lyrics design §2; issue #18, requirement 12):
/// in the roll's small face, 3 px in from the onset, centred in the lane, in the ink the selection
/// outline uses, and only where the note is wide and tall enough to hold it whole; a note too
/// small shows nothing rather than a clipped fragment.
extension PianoRollView {
    static let lyricInset: CGFloat = 3
    static let lyricMinHeight: CGFloat = 9

    /// Called from `drawNote` on every repaint, so the width is measured once per text and scale
    /// and kept (``LyricWidths``); on the main thread, as the roll draws there.
    func drawLyric(_ lyric: Lyric, in rect: CGRect, ctx: CGContext) {
        let k = geometry.scale

        guard rect.height >= PianoRollView.lyricMinHeight * k, !lyric.text.isEmpty else { return }

        let font = TimelineFonts.scaleLabel(k)
        let inset = PianoRollView.lyricInset * k

        guard rect.width >= LyricWidths.width(of: lyric.text, font: font, scale: k) + 2 * inset else { return }

        TimelineText.draw(lyric.text, font: font, colour: TimelinePalette.textPrimary,
                          in: CGRect(x: rect.minX + inset, y: rect.minY, width: rect.width - inset, height: rect.height),
                          anchor: .centredLeft, context: ctx)
    }
}

/// The measured widths of the syllables the roll has drawn, keyed by scale and text: a repaint
/// draws every visible note, and a long sung line would otherwise lay out the same words again
/// on every frame of a scroll. An `NSCache`, so memory pressure can empty it.
@MainActor enum LyricWidths {
    private static let cache: NSCache<NSString, NSNumber> = {
        let cache = NSCache<NSString, NSNumber>()
        cache.countLimit = 4096
        return cache
    }()

    static func width(of text: String, font: CTFont, scale: CGFloat) -> CGFloat {
        let key = "\(scale)|\(text)" as NSString

        if let cached = cache.object(forKey: key) { return CGFloat(cached.doubleValue) }

        let width = TimelineText.width(text, font: font)
        cache.setObject(NSNumber(value: Double(width)), forKey: key)

        return width
    }
}
