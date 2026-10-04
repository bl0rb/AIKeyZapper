import Foundation

/// Copy of the metadata (profiles and bindings, never keys) in the user's OneDrive, for moving to a new Mac.
public struct BackupStore: Sendable {
    public static let fileName = "keyzapper-backup.json"
    public let fileURL: URL

    public init(directory: URL) {
        fileURL = directory.appendingPathComponent(Self.fileName)
    }

    /// `BackupDirectory` if set; otherwise with `OneDriveBackup` the OneDrive folder under
    /// `~/Library/CloudStorage` (business account preferred over "OneDrive-Personal") plus `/KeyZapper`.
    public static func directory(for config: ManagedConfig, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL? {
        if let explicit = config.backupDirectory, !explicit.isEmpty {
            return URL(fileURLWithPath: (explicit as NSString).expandingTildeInPath, isDirectory: true)
        }
        guard config.oneDriveBackup else { return nil }
        let cloud = home.appendingPathComponent("Library/CloudStorage", isDirectory: true)
        let folders = ((try? FileManager.default.contentsOfDirectory(atPath: cloud.path)) ?? [])
            .filter { $0.hasPrefix("OneDrive") }.sorted()
        guard let folder = folders.first(where: { !$0.contains("Personal") }) ?? folders.first else { return nil }
        return cloud.appendingPathComponent(folder).appendingPathComponent("KeyZapper", isDirectory: true)
    }

    public func write(_ state: AppState) throws {
        try MetadataStore(fileURL: fileURL, mirror: false).save(state)
    }

    public func read() throws -> AppState? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        return try MetadataStore(fileURL: fileURL, mirror: false).load()
    }
}
