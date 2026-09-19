import Foundation
import NeuralSheetCore

/// The release check (`UpdateCheck.cpp`, inventory §9): one GET of the latest release, its
/// `tag_name` against the bundle's version, and a notice on the model when there is something to
/// say.
///
/// Once per window open with `explicit: false`, where only a newer release is worth a notice, and
/// from Settings → Check for updates with `explicit: true`, where "You are on the latest version"
/// is too -- and so is "Could not check for updates": a click that produced nothing would read
/// as a click that did nothing. On the launch path an empty or unreadable response stays a silent
/// no-op, as it was: the check is a courtesy, not a feature the app waits on.
enum UpdateCheck {
    /// Spec §7 deviation 4: the NeuralSheet repository, until a release exists there.
    nonisolated static let latestReleaseAPI = URL(string: "https://api.github.com/repos/antoni/neural-sheet/releases/latest")!
    nonisolated static let latestReleasePage = URL(string: "https://github.com/antoni/neural-sheet/releases/latest")!

    /// How long a notice stands on its own.
    static let noticeDuration: TimeInterval = 10

    /// How far past now the expiry is pushed on every tick the pointer rests on the notice.
    static let hoverExtension: TimeInterval = 3

    /// The hover tick's rate (§11.5).
    static let hoverTickHz = 5.0

    static let newVersionText = "A new version of NeuralSheet is available"
    static let latestVersionText = "You are on the latest version of NeuralSheet"
    static let checkFailedText = "Could not check for updates"

    /// `CFBundleShortVersionString`, which is what `JucePlugin_VersionString` was.
    nonisolated static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    /// Starts the check and, when it lands, sets `model.updateNotice`. The request runs on
    /// `URLSession`'s own threads; the answer is applied on the main actor.
    static func run(for model: AppModel, explicit: Bool) {
        Task { @MainActor [weak model] in
            let tag = await latestTag()

            model?.applyUpdateCheck(latestTag: tag, explicit: explicit)
        }
    }

    /// The latest release's `tag_name`, or nil when there is no answer worth acting on.
    nonisolated static func latestTag() async -> String? {
        var request = URLRequest(url: latestReleaseAPI)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 15

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse).map({ (200 ..< 300).contains($0.statusCode) }) ?? true,
              !data.isEmpty
        else { return nil }

        return tagName(in: data)
    }

    /// `tag_name` from the release JSON, or nil when the body is not the object expected.
    nonisolated static func tagName(in data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = json["tag_name"] as? String,
              !tag.isEmpty
        else { return nil }

        return tag
    }
}

extension AppModel {
    /// The main-actor half of the check: a notice when the tag is newer, or -- only when asked
    /// for -- when it is not, or when there was no answer (`latestTag` nil: the request failed,
    /// or the response carried no tag).
    func applyUpdateCheck(latestTag: String?, explicit: Bool) {
        let expiresAt = Date().addingTimeInterval(UpdateCheck.noticeDuration)

        guard let latestTag else {
            if explicit {
                updateNotice = UpdateNotice(text: UpdateCheck.checkFailedText, showsSeeUpdate: false, expiresAt: expiresAt)
            }

            return
        }

        if VersionCompare.isNewer(latestTag, than: UpdateCheck.currentVersion) {
            updateNotice = UpdateNotice(text: UpdateCheck.newVersionText, showsSeeUpdate: true, expiresAt: expiresAt)
        } else if explicit {
            updateNotice = UpdateNotice(text: UpdateCheck.latestVersionText, showsSeeUpdate: false, expiresAt: expiresAt)
        }
    }

    /// One 5 Hz tick with the pointer over the notice: the expiry is pushed out to at least
    /// `now + 3 s`, never pulled in.
    func extendUpdateNoticeForHover() {
        guard var notice = updateNotice else { return }

        let extended = Date().addingTimeInterval(UpdateCheck.hoverExtension)

        if extended > notice.expiresAt {
            notice.expiresAt = extended
            updateNotice = notice
        }
    }
}
