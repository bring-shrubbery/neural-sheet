import AppKit
import SwiftUI

/// A small numeric field in the timeline's mono face: commits on Return or focus loss, steps by
/// `step` on ↑/↓ (×10 with ⇧), and clamps into `range`. Shared by the Edit toolbar and the
/// selection inspector.
///
/// A nil `value` -- a selection whose notes disagree -- shows "—" and still takes a number; any
/// number then commits, since there is no single value it could equal.
struct NumberField: View {
    let value: Double?
    let range: ClosedRange<Double>
    let decimals: Int
    let step: Double
    /// Authored width.
    let width: CGFloat
    let onCommit: (Double) -> Void

    @Environment(\.uiScale) private var k
    @State private var text = ""
    @FocusState private var isFocused: Bool

    static let height: CGFloat = 22
    static let corner: CGFloat = 4

    init(value: Double?, range: ClosedRange<Double>, decimals: Int, step: Double = 1, width: CGFloat = 52,
         onCommit: @escaping (Double) -> Void) {
        self.value = value
        self.range = range
        self.decimals = decimals
        self.step = step
        self.width = width
        self.onCommit = onCommit
    }

    /// The single-value form the toolbar uses.
    init(value: Double, range: ClosedRange<Double>, decimals: Int, step: Double = 1, width: CGFloat = 52,
         onCommit: @escaping (Double) -> Void) {
        self.init(value: Optional(value), range: range, decimals: decimals, step: step, width: width, onCommit: onCommit)
    }

    var body: some View {
        let s = Scaled(k: k)

        TextField("", text: $text)
            .textFieldStyle(.plain)
            .font(Fonts.mono(10, weight: 500, scale: k))
            .foregroundStyle(Theme.textStrong)
            .multilineTextAlignment(.trailing)
            .focused($isFocused)
            .padding(.horizontal, s(6))
            .frame(width: s(width), height: s(Self.height))
            .background(RoundedRectangle(cornerRadius: s(Self.corner), style: .circular).fill(Theme.bgControlAlt))
            .overlay(RoundedRectangle(cornerRadius: s(Self.corner), style: .circular)
                .strokeBorder(isFocused ? Theme.accent : Theme.divStrong, lineWidth: k))
            .onAppear { text = Self.format(value, decimals: decimals) }
            // An outside change wins over whatever is half-typed: ⌖ while this field has focus
            // must show the playhead, not the old number.
            .onChange(of: value) { _, new in text = Self.format(new, decimals: decimals) }
            .onChange(of: isFocused) { _, focused in
                if !focused { commit() }
            }
            .onSubmit(commit)
            // One handler per arrow, reading the modifier itself: a second `onKeyPress` on the
            // same key would take the press first and the shifted variant would never be seen.
            .onKeyPress(.upArrow, phases: .down) { press in
                if press.modifiers.contains(.shift) {
                    nudge(by: step * 10)
                } else {
                    nudge(by: step)
                }

                return .handled
            }
            .onKeyPress(.downArrow, phases: .down) { press in
                if press.modifiers.contains(.shift) {
                    nudge(by: -step * 10)
                } else {
                    nudge(by: -step)
                }

                return .handled
            }
    }

    /// Return or focus loss: an unparseable entry is thrown away and the last value shown again.
    private func commit() {
        guard let parsed = Double(text.trimmingCharacters(in: .whitespaces)), parsed.isFinite else {
            text = Self.format(value, decimals: decimals)
            return
        }

        let clamped = min(max(parsed, range.lowerBound), range.upperBound)
        text = Self.format(clamped, decimals: decimals)

        if clamped != value {
            onCommit(clamped)
        }
    }

    /// Steps from what is typed, not from `value`, so an edit in progress is stepped rather than
    /// replaced. Nothing to step from -- "—" and no entry -- steps nothing.
    private func nudge(by delta: Double) {
        guard let current = Double(text.trimmingCharacters(in: .whitespaces)) ?? value else { return }

        let next = min(max(current + delta, range.lowerBound), range.upperBound)
        text = Self.format(next, decimals: decimals)
        onCommit(next)
    }

    static func format(_ value: Double?, decimals: Int) -> String {
        guard let value else { return "—" }

        return String(format: "%.\(decimals)f", value)
    }
}

/// Hands the caller the AppKit view under a SwiftUI control, to anchor a popup to it. Shared by
/// the Edit toolbar's division menu and the selection inspector's instrument menu.
struct AnchorCatcher: NSViewRepresentable {
    let found: (NSView) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { found(view) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}
