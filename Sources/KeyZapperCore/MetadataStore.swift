import Foundation

/// Versioned JSON metadata (profiles and bindings). Contains no secrets.
/// Written only by the app; the helper reads it to validate profile IDs.
public struct MetadataStore: Sendable {
    public let fileURL: URL
    /// Full copy next to the state file. Older app versions rewrite `state.json` without fields they do not know;
    /// on load those fields are restored from this mirror, so a downgrade does not lose them.
    let mirrorURL: URL?

    public init(fileURL: URL = MetadataStore.defaultDirectory.appendingPathComponent("state.json"), mirror: Bool = true) {
        self.fileURL = fileURL
        self.mirrorURL = mirror ? fileURL.deletingPathExtension().appendingPathExtension("full.json") : nil
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
        let state = try Self.decode(data)
        guard let mirrorURL, let mirrorData = try? Data(contentsOf: mirrorURL), let mirror = try? Self.decode(mirrorData) else {
            return state
        }
        return Self.restoringDroppedFields(state, from: mirror)
    }

    /// Copies fields an older app version dropped (model tiers, environment, global profile, deactivation).
    static func restoringDroppedFields(_ state: AppState, from mirror: AppState) -> AppState {
        var result = state
        for index in result.profiles.indices {
            let profile = result.profiles[index]
            guard profile.opusModel == nil, profile.sonnetModel == nil, profile.haikuModel == nil, profile.environment == nil,
                  let saved = mirror.profile(profile.id), saved.endpoint == profile.endpoint else { continue }
            result.profiles[index].opusModel = saved.opusModel
            result.profiles[index].sonnetModel = saved.sonnetModel
            result.profiles[index].haikuModel = saved.haikuModel
            result.profiles[index].environment = saved.environment
        }
        if result.globalBinding == nil, let global = mirror.globalBinding, result.profile(global.profileID) != nil {
            result.globalBinding = global
        }
        if result.disabled == nil { result.disabled = mirror.disabled }
        return result
    }

    public func save(_ state: AppState) throws {
        let dir = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        var current = state
        current.schemaVersion = AppState.currentSchemaVersion
        let data = try encoder.encode(current)
        for url in [fileURL, mirrorURL].compactMap({ $0 }) {
            try data.write(to: url, options: [.atomic])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
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
