import AppKit
import NeuralSheetCore
import SwiftUI

/// The ruler card's marker section (markers and lyrics design §2; issue #18, requirement 2): the
/// marker under the pointer with its name field and Delete, or Add Marker Here, which turns the
/// section into the new marker's at once. The name is written as it is typed, like the card's
/// tempo, so the flag, the score and the exports follow the field; Return closes the card.
struct RulerMarkerSection: View {
    let model: AppModel
    /// Where Add Marker Here puts the marker.
    let seconds: Double
    let host: PopupMenuPresenter
    let focusesName: Bool

    @Environment(\.uiScale) private var k
    @State private var markerID: UUID?
    @FocusState private var nameFocused: Bool

    private static let labelHeight: CGFloat = 12

    init(model: AppModel, seconds: Double, markerID: UUID?, host: PopupMenuPresenter, focusesName: Bool) {
        self.model = model
        self.seconds = seconds
        self.host = host
        self.focusesName = focusesName
        _markerID = State(initialValue: markerID)
    }

    var body: some View {
        let s = Scaled(k: k)
        let marker = markerID.flatMap { id in model.markers.first { $0.id == id } }

        VStack(alignment: .leading, spacing: 0) {
            Rectangle()
                .fill(Theme.divSoft)
                .frame(height: k)
                .padding(.bottom, s(10))

            // One layout in both states, so the panel, sized once when it opens, fits either:
            // Add Marker Here turns into Delete in place and the name field comes alive.
            Text((marker.map { "Marker at \(model.editor.grid.barBeatLabel(at: $0.seconds + 1e-6))" } ?? "Marker").uppercased())
                .font(Fonts.sectionHeader(k))
                .kerning(Fonts.tracking(Fonts.Tracking.sectionHeader, pointSize: Fonts.Size.sectionHeader, scale: k))
                .foregroundStyle(Theme.popupTitle)
                .lineLimit(1)
                .frame(height: s(Self.labelHeight), alignment: .leading)
                .accessibilityAddTraits(.isHeader)

            HStack(spacing: 0) {
                Text("Name")
                    .font(Fonts.meta(k))
                    .foregroundStyle(Theme.textMuted)
                    .accessibilityHidden(true)

                Spacer(minLength: s(8))

                nameField(marker)
            }
            .frame(height: s(SelectionFields.rowHeight))
            .padding(.top, s(8))
            .disabled(marker == nil)
            .opacity(marker == nil ? Theme.disabledAlpha : 1)

            Group {
                if let marker {
                    button("Delete Marker", foreground: Theme.warn) {
                        host.dismiss()
                        model.removeMarker(id: marker.id)
                    }
                } else {
                    button("Add Marker Here", foreground: Theme.textButton) {
                        markerID = model.addMarker(at: seconds)
                        nameFocused = true
                    }
                }
            }
            .padding(.top, s(10))
        }
        .onAppear {
            if focusesName { nameFocused = true }
        }
    }

    private func nameField(_ marker: Marker?) -> some View {
        let s = Scaled(k: k)

        return TextField("", text: Binding(get: { marker?.name ?? "" },
                                           set: { name in marker.map { model.renameMarker(id: $0.id, to: name) } }))
            .textFieldStyle(.plain)
            .font(Fonts.meta(k))
            .foregroundStyle(Theme.textStrong)
            .focused($nameFocused)
            .padding(.horizontal, s(6))
            .frame(width: s(140), height: s(NumberField.height))
            .background(RoundedRectangle(cornerRadius: s(NumberField.corner), style: .circular).fill(Theme.bgControlAlt))
            .overlay(RoundedRectangle(cornerRadius: s(NumberField.corner), style: .circular)
                .strokeBorder(nameFocused ? Theme.accent : Theme.divStrong, lineWidth: k))
            .onSubmit { host.dismiss() }
            .accessibilityLabel(Text(AccessibilityText.markerName))
    }

    private func button(_ title: String, foreground: Color, action: @escaping () -> Void) -> some View {
        let s = Scaled(k: k)

        return FlatButton(idle: Theme.bgControlAlt, on: Theme.bgControlActive,
                          foregroundIdle: foreground, foregroundOn: Theme.textBright,
                          corner: s(NumberField.corner), action: action) { _ in
            Text(title)
                .font(Fonts.buttonLabel(k))
                .fixedSize()
                .padding(.horizontal, s(10))
                .frame(height: s(NumberField.height))
        }
    }
}
