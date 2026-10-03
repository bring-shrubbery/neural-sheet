import SwiftUI

/// The sheet over the window while Export Audio… renders (audio export design §2): what is being
/// written, a bar by frames and Cancel, which removes the partial file. On system controls, as
/// the export dialog is. The window behind keeps playing.
struct RenderProgressSheet: View {
    let model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Exporting Audio")
                .font(.headline)

            Text(model.audioRender?.fileName ?? "")
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)

            ProgressView(value: min(max(model.audioRender?.progress ?? 0, 0), 1))
                .progressViewStyle(.linear)

            HStack {
                Spacer()

                Button("Cancel", role: .cancel) {
                    model.cancelAudioExport()
                }
                .keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 360)
        .interactiveDismissDisabled()
    }
}
