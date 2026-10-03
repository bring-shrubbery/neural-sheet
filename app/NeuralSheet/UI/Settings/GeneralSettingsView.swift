import AppKit
import NeuralSheetCore
import SwiftUI

/// Settings → General: the tooltips switch, Check for Updates, and the command-line tool (issue
/// #24 §5). The MIDI overflow rule (inventory §11.3) is an export setting, asked for in the export
/// dialog.
struct GeneralSettingsView: View {
    @Bindable var model: AppModel

    /// The symlink's state, read when the pane appears and after each Install or Remove.
    @State private var toolState: CommandLineTool.State = .notInstalled
    @State private var toolBusy = false
    @State private var toolError: String?

    var body: some View {
        Form {
            Section {
                Toggle("Show tooltips", isOn: $model.settings.tooltipsVisible)
            }

            Section {
                LabeledContent("Updates") {
                    Button("Check for Updates…") {
                        model.checkForUpdates()
                    }
                    .disabled(!model.updates.canCheckForUpdates)
                }
            }

            commandLineToolSection
        }
        .formStyle(.grouped)
        .onAppear { toolState = model.commandLineToolState }
    }

    // MARK: - Command-line tool

    private var commandLineToolSection: some View {
        Section {
            LabeledContent("Command-line tool") {
                HStack {
                    if toolState != .notInstalled {
                        Button("Remove") { change(install: false) }
                            .disabled(toolBusy)
                    }

                    Button(toolState == .installed ? "Reinstall…" : "Install…") { change(install: true) }
                        .disabled(toolBusy)
                }
            }

            LabeledContent("Path") {
                HStack {
                    Text(model.commandLineToolPath)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)

                    Button("Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(model.commandLineToolPath, forType: .string)
                    }
                }
            }
        } footer: {
            Text(toolFooter)
                .foregroundStyle(toolError == nil ? Color.secondary : Color.red)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var toolFooter: String {
        if let toolError { return toolError }

        switch toolState {
        case .notInstalled:
            return String(localized: "Install creates a link in /usr/local/bin so you can run neuralsheet in the Terminal. You will be asked for an administrator password.",
                          comment: "Settings → General: the command-line tool's footer before it is installed")
        case .installed:
            return String(localized: "Installed. Run neuralsheet --help in the Terminal to get started.",
                          comment: "Settings → General: the command-line tool's footer once installed")
        case let .other(path):
            return String(localized: "The link points at another copy of NeuralSheet (\(path)). Install points it at this one.",
                          comment: "Settings → General: the command-line tool's link points at another copy of the app")
        }
    }

    private func change(install: Bool) {
        toolBusy = true
        toolError = nil

        Task {
            let error = install ? await model.installCommandLineTool() : await model.removeCommandLineTool()

            toolError = error
            toolState = model.commandLineToolState
            toolBusy = false
        }
    }
}
