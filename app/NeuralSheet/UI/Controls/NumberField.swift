import SwiftUI

/// A small numeric field in the timeline's mono face: commits on Return or focus loss, steps by
/// `step` on ↑/↓ (×10 with ⇧), and clamps into `range`. Shared by the Edit toolbar and the
/// selection inspector.
struct NumberField: View {
    let value: Double
    let range: ClosedRange<Double>
    let decimals: Int
    var step: Double = 1
    /// Authored width.
    var width: CGFloat = 52
    let onCommit: (Double) -> Void

    @Environment(\.uiScale) private var k
    @State private var text = ""
    @FocusState private var isFocused: Bool

    static let height: CGFloat = 22
    static let corner: CGFloat = 4

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
            .onChange(of: value) { _, new in
                if !isFocused { text = Self.format(new, decimals: decimals) }
            }
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
    /// replaced.
    private func nudge(by delta: Double) {
        let current = Double(text.trimmingCharacters(in: .whitespaces)) ?? value
        let next = min(max(current + delta, range.lowerBound), range.upperBound)
        text = Self.format(next, decimals: decimals)
        onCommit(next)
    }

    static func format(_ value: Double, decimals: Int) -> String {
        String(format: "%.\(decimals)f", value)
    }
}
