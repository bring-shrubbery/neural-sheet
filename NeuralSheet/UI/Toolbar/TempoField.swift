import AppKit
import SwiftUI

/// The toolbar's export-tempo editor (`NumericTextEditor<double>`): a 40 px field taking digits
/// and "." only, at most six characters, with the value vertically centred in the pill.
///
/// An `NSTextField` rather than a SwiftUI `TextField`: the original was a raw `juce::TextEditor`
/// that drew its own vertically-centred text, and SwiftUI's field keeps a minimum control height
/// that does not scale with the font, so its digits drop out of the pill at a reduced UI scale.
/// This gives the exact colours (`textFile` text, `accent` selection, a `textDim` placeholder),
/// the exact input restriction and the exact commit rule.
///
/// The value reaches `model.exportTempo` on every keystroke that leaves a valid tempo in the field
/// (20…999); leaving the field corrects whatever is left in it -- empty to 120, anything else
/// clamped into range -- and that correction is written too. A click anywhere outside the field
/// ends the edit, as the original's global mouse listener did.
struct TempoField: View {
    let model: AppModel
    /// Off, the field takes no click and shows its value dimmed. The pill already paints the
    /// disabled alpha, so nothing extra is drawn here.
    var isEnabled: Bool = true

    @Environment(\.uiScale) private var k
    @State private var editing = false

    /// `TEMPO_VALUE_WIDTH` and `nn::fonts::tempoValue`.
    static let width: CGFloat = 40
    /// `juce::TextEditor`'s default left indent: the text starts 4 px into the field.
    static let leftIndent: CGFloat = 4
    static let maxLength = 6
    static let minTempo = 20.0
    static let maxTempo = 999.0
    static let defaultTempo = 120.0

    var body: some View {
        let s = Scaled(k: k)

        // At rest the value is a SwiftUI `Text`, which shares the label's baseline centring at
        // every scale; the AppKit editor -- whose mono glyphs sit low in their line box -- only
        // takes over while the field is being edited. A click starts the edit.
        ZStack(alignment: .leading) {
            if !editing {
                Text(Self.format(model.exportTempo))
                    .font(Fonts.tempoValue(k))
                    .foregroundStyle(Theme.textFile)
                    .lineLimit(1)
                    .frame(width: s(Self.width - Self.leftIndent), alignment: .leading)
            }

            NumericField(value: Binding(get: { model.exportTempo }, set: { model.exportTempo = $0 }),
                         isEnabled: isEnabled,
                         editing: $editing,
                         scale: k)
                .frame(width: s(Self.width - Self.leftIndent))
                .frame(height: s(Toolbar.Metrics.buttonHeight), alignment: .center)
                .opacity(editing ? 1 : 0)
        }
        .padding(.leading, s(Self.leftIndent))
        .frame(width: s(Self.width), height: s(Toolbar.Metrics.buttonHeight), alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture {
            if isEnabled { editing = true }
        }
        .tooltip("Set export tempo for midi file")
        .accessibilityLabel("Export tempo")
    }

    // MARK: - Validation (shared with the AppKit field and the tests)

    /// `numberToStr`: whole tempos without a fraction, anything else to two places.
    static func format(_ tempo: Double) -> String {
        if tempo == tempo.rounded() {
            return String(format: "%.0f", tempo)
        }

        return String(format: "%.2f", tempo)
    }

    /// `setInputRestrictions(6, "0123456789.")`: the disallowed characters dropped, then the length.
    static func restricted(_ text: String) -> String {
        String(text.filter { "0123456789.".contains($0) }.prefix(maxLength))
    }

    /// `juce::String::getFloatValue`: the leading number, or 0 when there is none.
    static func parsed(_ text: String) -> Double {
        Scanner(string: text).scanDouble() ?? 0
    }

    /// `tempo_is_valid`: the tempo the text reads as, or nil when it is empty or out of range.
    static func validTempo(_ text: String) -> Double? {
        guard !text.isEmpty else { return nil }

        let tempo = parsed(text)

        return (minTempo ... maxTempo).contains(tempo) ? tempo : nil
    }

    /// `correct_tempo`: empty to the default, anything else clamped into range.
    static func corrected(_ text: String) -> String {
        guard !text.isEmpty else { return format(defaultTempo) }

        return format(min(maxTempo, max(minTempo, parsed(text))))
    }
}

// MARK: - AppKit field

private struct NumericField: NSViewRepresentable {
    @Binding var value: Double
    let isEnabled: Bool
    @Binding var editing: Bool
    let scale: CGFloat

    func makeCoordinator() -> Coordinator {
        Coordinator(value: $value, editing: $editing)
    }

    func makeNSView(context: Context) -> CenteredTextField {
        let field = CenteredTextField()
        // Explicit, because a modern NSTextField ignores `cellClass` and keeps the plain cell it
        // was built with, so the vertical centring would never run.
        let cell = CenteredCell(textCell: "")
        cell.isEditable = true
        cell.isSelectable = true
        cell.wraps = false
        cell.isScrollable = true
        field.cell = cell
        field.delegate = context.coordinator
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.usesSingleLineMode = true
        field.lineBreakMode = .byClipping
        field.cell?.isScrollable = true
        field.alignment = .left
        field.placeholderString = TempoField.format(TempoField.defaultTempo)
        context.coordinator.field = field

        return field
    }

    func updateNSView(_ field: CenteredTextField, context: Context) {
        context.coordinator.value = $value
        field.font = NSFont(name: Fonts.Name.monoRegular, size: Fonts.Size.tempoValue * scale)
            ?? NSFont.monospacedSystemFont(ofSize: Fonts.Size.tempoValue * scale, weight: .regular)
        field.textColor = NSColor(Theme.textFile)
        field.placeholderColor = NSColor(Theme.textDim)
        field.isEnabled = isEnabled
        field.isEditable = isEnabled
        field.isSelectable = isEnabled

        // Not while editing: the field must not reformat what is being typed. Otherwise a restored
        // session or a click-away correction shows straight away.
        if field.currentEditor() == nil {
            let shown = TempoField.format(value)

            if field.stringValue != shown {
                field.stringValue = shown
            }

            context.coordinator.lastAccepted = shown
        }

        // The click flipped `editing`; take focus on the next runloop turn, once the field is
        // visible and part of a window.
        if editing, field.window?.firstResponder !== field.currentEditor(), isEnabled {
            DispatchQueue.main.async {
                field.window?.makeFirstResponder(field)
            }
        }
    }

    // MARK: - Coordinator

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var value: Binding<Double>
        var editing: Binding<Bool>
        weak var field: CenteredTextField?

        /// The text as it last stood after restriction, for a rejected character to fall back to.
        /// Seeded with the displayed value whenever the field is not being edited.
        var lastAccepted = ""

        init(value: Binding<Double>, editing: Binding<Bool>) {
            self.value = value
            self.editing = editing
        }

        func controlTextDidBeginEditing(_ obj: Notification) {
            // Focus by any route -- a click, Tab, a programmatic focus -- shows the live editor in
            // place of the display `Text`.
            if !editing.wrappedValue {
                editing.wrappedValue = true
            }
        }

        func controlTextDidChange(_ obj: Notification) {
            guard let field else { return }

            let restricted = TempoField.restricted(field.stringValue)

            if restricted != field.stringValue {
                // A disallowed character typed over a selection -- Space, with the value selected
                // on focus -- would otherwise wipe the value and leave an empty field: the original
                // refused the character and left the text alone, so the previous text comes back.
                let editor = field.currentEditor()
                let restored = restricted.isEmpty ? lastAccepted : restricted
                field.stringValue = restored
                editor?.selectedRange = NSRange(location: restored.count, length: 0)
            }

            lastAccepted = field.stringValue

            if let tempo = TempoField.validTempo(field.stringValue), tempo != value.wrappedValue {
                value.wrappedValue = tempo
            }
        }

        func controlTextDidEndEditing(_ obj: Notification) {
            guard let field else { return }

            if TempoField.validTempo(field.stringValue) == nil {
                field.stringValue = TempoField.corrected(field.stringValue)
            }

            if let tempo = TempoField.validTempo(field.stringValue) {
                value.wrappedValue = tempo
            }

            // Back to the SwiftUI `Text` for display.
            if editing.wrappedValue {
                editing.wrappedValue = false
            }
        }

        /// Return and Escape both end the edit; the field's own value is committed either way.
        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            if selector == #selector(NSResponder.insertNewline(_:)) || selector == #selector(NSResponder.cancelOperation(_:)) {
                control.window?.makeFirstResponder(nil)
                return true
            }

            return false
        }
    }
}

/// A single-line field whose text and caret sit on the vertical centre line, whatever the font
/// against the frame, so it reads centred in the toolbar pill at every UI scale. The whole edit is
/// given up on a mouse-down anywhere outside the field, as the original's global listener did.
private final class CenteredTextField: NSTextField {
    private var clickMonitor: Any?

    var placeholderColor: NSColor = .secondaryLabelColor {
        didSet { refreshPlaceholder() }
    }

    override var placeholderString: String? {
        didSet { refreshPlaceholder() }
    }

    private func refreshPlaceholder() {
        guard let placeholderString else { return }

        placeholderAttributedString = NSAttributedString(
            string: placeholderString,
            attributes: [.foregroundColor: placeholderColor, .font: font ?? NSFont.systemFont(ofSize: 11)])
    }

    override func becomeFirstResponder() -> Bool {
        let began = super.becomeFirstResponder()

        if began {
            currentEditor()?.selectedRange = NSRange(location: 0, length: stringValue.count)
            startClickMonitor()
        }

        return began
    }

    override func textDidEndEditing(_ notification: Notification) {
        super.textDidEndEditing(notification)
        stopClickMonitor()
    }

    private func startClickMonitor() {
        stopClickMonitor()

        clickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
            guard let self else { return event }

            if event.window === self.window {
                let point = self.convert(event.locationInWindow, from: nil)

                if self.bounds.contains(point) {
                    return event
                }
            }

            self.window?.makeFirstResponder(nil)

            return event
        }
    }

    private func stopClickMonitor() {
        if let clickMonitor {
            NSEvent.removeMonitor(clickMonitor)
            self.clickMonitor = nil
        }
    }

    deinit {
        if let clickMonitor {
            NSEvent.removeMonitor(clickMonitor)
        }
    }
}

/// Vertically centres the drawing rect and the field editor's rect (`juce`'s editor drew its text
/// centred; `NSTextFieldCell` top-aligns by default).
private final class CenteredCell: NSTextFieldCell {
    private func centred(_ rect: NSRect) -> NSRect {
        let height = ceil(font?.boundingRectForFont.height ?? rect.height)
        guard height < rect.height else { return rect }

        var centred = rect
        centred.origin.y = rect.origin.y + (rect.height - height) / 2
        centred.size.height = height

        return centred
    }

    override func titleRect(forBounds rect: NSRect) -> NSRect {
        super.titleRect(forBounds: centred(rect))
    }

    override func drawInterior(withFrame cellFrame: NSRect, in controlView: NSView) {
        super.drawInterior(withFrame: centred(cellFrame), in: controlView)
    }

    override func edit(withFrame rect: NSRect, in controlView: NSView, editor: NSText, delegate: Any?, event: NSEvent?) {
        super.edit(withFrame: centred(rect), in: controlView, editor: editor, delegate: delegate, event: event)
    }

    override func select(withFrame rect: NSRect, in controlView: NSView, editor: NSText, delegate: Any?, start: Int, length: Int) {
        super.select(withFrame: centred(rect), in: controlView, editor: editor, delegate: delegate, start: start, length: length)
    }
}
