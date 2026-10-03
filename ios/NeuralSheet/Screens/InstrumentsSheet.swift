import NeuralSheetCore
import SwiftUI

/// The instruments the next run is held to (the Mac's sidebar picker, `InstrumentMenu`): every
/// group the model names, ticked where it is selected, with Automatic at the top for the default
/// of letting the model choose. A multi-select, so it stays open across taps.
struct InstrumentsSheet: View {
    let model: MobileModel

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    row(title: InstrumentsSheet.automaticTitle, chip: nil, ticked: model.selectedGroups.isEmpty) {
                        model.clearSelection()
                    }
                } footer: {
                    Text("Tick to include in transcription", comment: "The instruments sheet: what the ticks do")
                }

                Section {
                    ForEach(Instruments.all, id: \.program) { info in
                        if let group = info.group {
                            let ticked = model.selectedGroups.contains(group)

                            row(title: info.localizedName, chip: info.colour, ticked: ticked) {
                                model.setSelected(group, !ticked)
                            }
                        }
                    }
                }
            }
            .navigationTitle(Text("Instruments", comment: "The instruments sheet's title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button { dismiss() } label: { Text("Done", comment: "Closes a sheet") }
                }
            }
        }
    }

    private func row(title: String, chip: RGBA?, ticked: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Circle()
                    .fill(chip.map { Color(.sRGB, red: $0.r, green: $0.g, blue: $0.b, opacity: $0.a) } ?? .clear)
                    .overlay { if chip == nil { Image(systemName: "sparkles").font(.caption) } }
                    .frame(width: 14, height: 14)

                Text(title)
                    .foregroundStyle(.primary)

                Spacer()

                if ticked {
                    Image(systemName: "checkmark")
                        .foregroundStyle(.tint)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(ticked ? .isSelected : [])
    }

    /// The empty selection's row, as the Mac's picker names it.
    static var automaticTitle: String {
        String(localized: "Automatic (any instrument)", comment: "Instrument menu row: let the model choose the instruments")
    }

    /// What the Transcribe screen's row says the selection is: Automatic, one name, or a count.
    static func summary(_ groups: [InstrumentGroup]) -> String {
        switch groups.count {
        case 0:
            return String(localized: "Automatic", comment: "Transcribe screen: no instruments chosen, the model picks")
        case 1:
            return Instruments.info(forProgram: Instruments.program(for: groups[0])).localizedName
        default:
            return String(localized: "\(groups.count) instruments", comment: "Transcribe screen: how many instruments are chosen")
        }
    }
}
