import CryptoKit
import Foundation

public struct ReleaseInfo: Equatable, Sendable {
    public var version: String
    public var pageURL: URL
    public var packageURL: URL?
    /// Hex SHA-256 of the package as published by GitHub (`digest` of the release asset), if available.
    public var packageSHA256: String?
}

/// Checks the public GitHub releases of KeyZapper and downloads the `.pkg` of a newer release.
public enum UpdateChecker {
    public static let repository = "bl0rb/AIKeyZapper"
    public static var latestReleaseURL: URL { URL(string: "https://api.github.com/repos/\(repository)/releases/latest")! }

    public static func latestRelease(session: URLSession = .shared) async throws -> ReleaseInfo {
        var request = URLRequest(url: latestReleaseURL, timeoutInterval: 15)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw UpdateError.unavailable((response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        return try parse(data)
    }

    static func parse(_ data: Data) throws -> ReleaseInfo {
        struct Release: Decodable {
            struct Asset: Decodable { var name: String; var browser_download_url: URL; var digest: String? }
            var tag_name: String
            var html_url: URL
            var assets: [Asset]
        }
        let release = try JSONDecoder().decode(Release.self, from: data)
        // Only accept packages served by GitHub itself.
        let asset = release.assets.first { $0.name.hasSuffix(".pkg") && $0.browser_download_url.host() == "github.com" }
        let sha = asset?.digest.flatMap { $0.hasPrefix("sha256:") ? String($0.dropFirst(7)).lowercased() : nil }
        return ReleaseInfo(version: normalized(release.tag_name), pageURL: release.html_url,
                           packageURL: asset?.browser_download_url, packageSHA256: sha)
    }

    public static func isNewer(_ candidate: String, than installed: String) -> Bool {
        ClaudeCLI.isOlder(normalized(installed), than: normalized(candidate))
    }

    /// Downloads the package into a temporary folder and verifies its SHA-256 when GitHub published one.
    public static func downloadPackage(_ release: ReleaseInfo, session: URLSession = .shared) async throws -> URL {
        guard let packageURL = release.packageURL else { throw UpdateError.noPackage }
        let (tempFile, response) = try await session.download(from: packageURL)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw UpdateError.unavailable((response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        let target = FileManager.default.temporaryDirectory
            .appendingPathComponent("KeyZapper-Update-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent(packageURL.lastPathComponent)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: tempFile, to: target)
        if let expected = release.packageSHA256 { try verify(target, sha256: expected) }
        return target
    }

    static func verify(_ file: URL, sha256 expected: String) throws {
        let actual = SHA256.hash(data: try Data(contentsOf: file)).map { String(format: "%02x", $0) }.joined()
        guard actual == expected.lowercased() else {
            try? FileManager.default.removeItem(at: file)
            throw UpdateError.checksumMismatch
        }
    }

    static func normalized(_ version: String) -> String {
        version.hasPrefix("v") ? String(version.dropFirst()) : version
    }
}

public enum UpdateError: Error, Equatable, LocalizedError {
    case unavailable(Int)
    case noPackage
    case checksumMismatch

    public var errorDescription: String? {
        switch self {
        case .unavailable(let status): L("Update-Server nicht erreichbar (HTTP \(String(status))).")
        case .noPackage: L("Das Release enthält kein Installationspaket.")
        case .checksumMismatch: L("Prüfsumme des heruntergeladenen Pakets stimmt nicht. Installation abgebrochen.")
        }
    }
}
