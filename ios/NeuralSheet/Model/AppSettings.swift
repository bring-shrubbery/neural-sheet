import Foundation
import NeuralSheetCore
import Observation

/// The global settings, one set for the whole app as on the Mac (`GlobalSettings` in
/// `global.settings` beside the models), saved on every change. Every open document reads the
/// model size, the Stems switch, the After transcription filters and the count-in from here.
@Observable
final class AppSettings {
    static let shared = AppSettings()

    var settings: GlobalSettings {
        didSet {
            guard settings != oldValue else { return }

            save()
        }
    }

    @ObservationIgnored private let paths: AppPaths

    init(paths: AppPaths = .standard) {
        self.paths = paths
        settings = GlobalSettings.load(from: paths.globalSettings)
    }

    private func save() {
        do {
            try paths.ensureDirectories()
            try settings.save(to: paths.globalSettings)
        } catch {
            print("NeuralSheet: could not save the settings: \(error.localizedDescription)")
        }
    }
}

/// A message box: a title and a body, as the Mac's `showError` puts them.
struct MobileAlert: Identifiable, Equatable {
    let id = UUID()
    var title: String
    var message: String
}
