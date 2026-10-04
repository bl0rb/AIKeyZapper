@testable import KeyZapperCore
import CryptoKit
import Foundation
import Testing

struct UpdateCheckerTests {
    static let releaseJSON = """
    {"tag_name": "1.2.0", "html_url": "https://github.com/bl0rb/AIKeyZapper/releases/tag/1.2.0",
     "assets": [
       {"name": "notes.txt", "browser_download_url": "https://github.com/bl0rb/AIKeyZapper/releases/download/1.2.0/notes.txt"},
       {"name": "KeyZapper-1.2.0.pkg", "browser_download_url": "https://github.com/bl0rb/AIKeyZapper/releases/download/1.2.0/KeyZapper-1.2.0.pkg",
        "digest": "sha256:ABCDEF"}]}
    """

    @Test func parsesLatestReleaseWithPackageAndDigest() throws {
        let release = try UpdateChecker.parse(Data(Self.releaseJSON.utf8))
        #expect(release.version == "1.2.0")
        #expect(release.packageURL?.lastPathComponent == "KeyZapper-1.2.0.pkg")
        #expect(release.packageSHA256 == "abcdef")
    }

    @Test func ignoresPackagesNotServedByGitHub() throws {
        let json = Self.releaseJSON.replacingOccurrences(of: "https://github.com/bl0rb/AIKeyZapper/releases/download/1.2.0/KeyZapper", with: "https://evil.example/KeyZapper")
        let release = try UpdateChecker.parse(Data(json.utf8))
        #expect(release.packageURL == nil)
    }

    @Test func comparesVersions() {
        #expect(UpdateChecker.isNewer("1.0.1", than: "1.0.0"))
        #expect(UpdateChecker.isNewer("v1.1.0", than: "1.0.9"))
        #expect(UpdateChecker.isNewer("1.0.0", than: "1.0.0") == false)
        #expect(UpdateChecker.isNewer("0.9.0", than: "1.0.0") == false)
    }

    @Test func verifiesChecksum() throws {
        let file = URL(fileURLWithPath: makeTempDir()).appendingPathComponent("pkg")
        try Data("payload".utf8).write(to: file)
        let good = SHA256.hash(data: Data("payload".utf8)).map { String(format: "%02x", $0) }.joined()
        try UpdateChecker.verify(file, sha256: good.uppercased())
        #expect(throws: UpdateError.checksumMismatch) { try UpdateChecker.verify(file, sha256: String(repeating: "0", count: 64)) }
        #expect(FileManager.default.fileExists(atPath: file.path) == false)
    }

    @Test func updateCheckDefaultsOnAndCanBeDisabledByIT() {
        #expect(ManagedConfig().updateCheckEnabled)
        #expect(ManagedConfig(["UpdateCheckEnabled": false]).updateCheckEnabled == false)
    }
}
