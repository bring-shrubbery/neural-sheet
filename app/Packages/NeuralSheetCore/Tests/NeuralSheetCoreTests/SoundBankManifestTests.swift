import CryptoKit
import Foundation
import Testing

@testable import NeuralSheetCore

/// The iOS app's General MIDI bank download (sub-issue H): the pinned source, the spec the
/// downloader is handed, and the folder it lands in.
@Suite(.serialized) struct SoundBankManifestTests {
    @Test func theSpecIsThePinnedFile() {
        let spec = SoundBankManifest.spec

        #expect(spec.fileName == "GeneralUser-GS.sf2")
        #expect(spec.byteSize == 32_319_396)
        #expect(spec.size == SoundBankManifest.downloaderKey)
        #expect(spec.sha256Hex.count == 64)
        #expect(spec.sha256Hex.allSatisfy { $0.isHexDigit && !$0.isUppercase })
        #expect(SoundBankManifest.revision.count == 40)
        #expect(spec.partFileName == "GeneralUser-GS.sf2.9575028c.part")
    }

    @Test func theURLsNameTheRevision() {
        let url = SoundBankManifest.url

        #expect(url.scheme == "https")
        #expect(url.host == "raw.githubusercontent.com")
        #expect(url.absoluteString
            == "https://raw.githubusercontent.com/mrbumpy409/GeneralUser-GS/97049183643d5fc5a9322a69c5b09efb667c6c3a/GeneralUser-GS.sf2")
        #expect(SoundBankManifest.spec.url == url)
        #expect(SoundBankManifest.licenceURL.absoluteString.contains(SoundBankManifest.revision))
        #expect(SoundBankManifest.licenceURL.lastPathComponent == "LICENSE.txt")
    }

    @Test func thePathsPutTheModelsFolderOnTheSoundBanks() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("neuralsheet-banks-\(UUID().uuidString)/soundbanks", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder.deletingLastPathComponent()) }

        let paths = SoundBankManifest.paths(soundBanks: folder)

        #expect(paths.models == folder)
        #expect(paths.secondaryModels == folder)

        let store = ModelStore(paths: paths, specs: [SoundBankManifest.spec])
        #expect(store.installedPath(for: SoundBankManifest.downloaderKey) == nil)

        // A sparse file of the manifest's size reads as installed, one of any other size does not.
        let file = folder.appendingPathComponent(SoundBankManifest.fileName)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: file.path, contents: nil)
        let handle = try FileHandle(forWritingTo: file)
        try handle.truncate(atOffset: UInt64(SoundBankManifest.byteSize - 1))
        #expect(store.installedPath(for: SoundBankManifest.downloaderKey) == nil)
        try handle.truncate(atOffset: UInt64(SoundBankManifest.byteSize))
        try handle.close()
        #expect(store.installedPath(for: SoundBankManifest.downloaderKey) == file)
    }

    /// The models' downloader over the bank's paths lands a verified file in the folder; a stand-in
    /// served by the stub takes the place of the real bank, as in the model download tests.
    @Test func theDownloaderLandsTheBankInItsFolder() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("neuralsheet-banks-\(UUID().uuidString)/soundbanks", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder.deletingLastPathComponent()) }

        let body = Data("RIFF\u{0}\u{0}\u{0}\u{0}sfbk".utf8) + Data(repeating: 7, count: 500)
        let digest = SHA256.hash(data: body).map { String(format: "%02x", $0) }.joined()
        let stubPath = "/bank-\(UUID().uuidString).sf2"
        defer { StubURLProtocol.unregister(path: stubPath) }
        StubURLProtocol.register(path: stubPath) { _ in StubResponse(statusCode: 200, chunks: [body]) }

        let spec = ModelSpec(size: SoundBankManifest.downloaderKey, fileName: SoundBankManifest.fileName,
                             byteSize: Int64(body.count), sha256Hex: digest,
                             url: URL(string: "https://stub.invalid\(stubPath)")!)
        let session = StubURLProtocol.makeSession()
        defer { session.invalidateAndCancel() }

        let downloader = ModelDownloader(specs: [spec], paths: SoundBankManifest.paths(soundBanks: folder),
                                         session: session, retryDelays: [])
        let finished = DispatchSemaphore(value: 0)

        downloader.onChange = { _, phase in
            if phase == .idle { finished.signal() }
        }
        downloader.start(SoundBankManifest.downloaderKey)

        #expect(finished.wait(timeout: .now() + 20) == .success)
        #expect(try Data(contentsOf: folder.appendingPathComponent(SoundBankManifest.fileName)) == body)
        #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent(spec.partFileName).path))
    }
}
