import Foundation

/// The General MIDI SoundFont the iPhone and iPad app offers to download (iOS app design §2,
/// sub-issue H). iOS has no system GM bank, and the app does not ship one: Settings → Audio
/// downloads this at the user's request, through the models' downloader -- resumed from the part
/// file, checked against the digest compiled in here -- into the app's `soundbanks/` folder.
///
/// GeneralUser GS by S. Christian Collins, v2.0.3, pinned to one commit of its official GitHub
/// repository (which its author keeps "for automated packaging"). Its licence (GeneralUser GS
/// License v2.0) lets it be used without restriction and redistributed, which the Settings row
/// says with a link to the licence text at the same commit.
public enum SoundBankManifest {
    public static let name = "GeneralUser GS"
    public static let version = "2.0.3"
    public static let author = "S. Christian Collins"

    public static let repo = "mrbumpy409/GeneralUser-GS"
    public static let revision = "97049183643d5fc5a9322a69c5b09efb667c6c3a"

    public static let fileName = "GeneralUser-GS.sf2"
    public static let byteSize: Int64 = 32_319_396
    public static let sha256Hex = "9575028c7a1f589f5770fccc8cff2734566af40cd26ed836944e9a5152688cfe"

    public static var url: URL {
        // Constant components, so this cannot fail.
        URL(string: "https://raw.githubusercontent.com/\(repo)/\(revision)/\(fileName)")!
    }

    /// The licence text at the pinned commit, which the Settings row links to.
    public static var licenceURL: URL {
        URL(string: "https://github.com/\(repo)/blob/\(revision)/documentation/LICENSE.txt")!
    }

    /// The author's page, the place the licence asks people to be sent to.
    public static let homepageURL = URL(string: "https://www.schristiancollins.com/generaluser")!

    /// The downloader and the store key their jobs by ``ModelSize``. The bank goes through a
    /// downloader of its own, over a folder of its own (``paths(soundBanks:)``), so it borrows one
    /// size as that downloader's only key; no model is ever looked for in that folder.
    public static let downloaderKey: ModelSize = .stems

    /// The bank as the downloader sees it.
    public static var spec: ModelSpec {
        ModelSpec(size: downloaderKey, fileName: fileName, byteSize: byteSize, sha256Hex: sha256Hex, url: url)
    }

    /// Paths whose models folder is `soundBanks`, with nothing secondary to look in: what the
    /// bank's downloader and store are given, so the download lands, and is looked for, there.
    public static func paths(soundBanks: URL) -> AppPaths {
        var paths = AppPaths(root: soundBanks.deletingLastPathComponent(), secondaryModels: soundBanks, music: soundBanks)
        paths.models = soundBanks
        return paths
    }
}
