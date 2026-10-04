import Foundation

/// Versioned JSON metadata (profiles and bindings). Contains no secrets.
/// Written only by the app; the helper reads it to validate profile IDs.
public struct MetadataStore: Sendable {
    public let fileURL: URL

    public init(fileURL: URL = MetadataStore.defaultDirectory.appendingPathComponent("state.json")) {
        self.fileURL = fileURL
    }

    /// `~/Library/Application Support/KeyZapper`, overridable via `KEYZAPPER_HOME` (tests, spikes).
    public static var defaultDirectory: URL {
        if let override = ProcessInfo.processInfo.environment["KEYZAPPER_HOME"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/KeyZapper", isDirectory: true)
    }

    public func load() throws -> AppState {
        guard let data = try? Data(contentsOf: fileURL) else {
            if FileManager.default.fileExists(atPath: fileURL.path) {
                throw KeyZapperError.corruptMetadata(L("\(fileURL.path) ist nicht lesbar"))
            }
            return AppState()
        }
        return try Self.decode(data)
    }

    public func save(_ state: AppState) throws {
        let dir = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        var current = state
        current.schemaVersion = AppState.currentSchemaVersion
        try encoder.encode(current).write(to: fileURL, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }

    /// Decodes any known schema version and migrates it to the current one.
    static func decode(_ data: Data) throws -> AppState {
        struct Header: Decodable { var schemaVersion: Int }
        let version: Int
        do { version = try JSONDecoder().decode(Header.self, from: data).schemaVersion } catch {
            throw KeyZapperError.corruptMetadata(L("schemaVersion fehlt"))
        }
        guard version <= AppState.currentSchemaVersion else { throw KeyZapperError.unsupportedSchemaVersion(version) }
        switch version {
        case 1:
            do { return try JSONDecoder().decode(AppState.self, from: data) } catch {
                throw KeyZapperError.corruptMetadata(String(describing: error))
            }
        // Future: case 1 where current > 1 → decode V1 types, map to current, fall through.
        default:
            throw KeyZapperError.unsupportedSchemaVersion(version)
        }
    }
}
