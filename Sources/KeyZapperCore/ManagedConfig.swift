import CryptoKit
import Foundation

/// Settings IT can enforce with an Intune "Preference file" profile (preference domain = bundle ID).
/// Read through CFPreferences so app and helper both see `/Library/Managed Preferences`.
public struct ManagedConfig: Equatable, Sendable {
    public static let domain = "io.github.bl0rb.keyzapper"

    public struct ManagedProfile: Equatable, Sendable {
        public var id: UUID
        public var name: String
        public var endpoint: URL
        public var modelAlias: String
    }

    /// `ManagedProfiles`: array of dicts with `Name`, `Endpoint`, optional `ModelAlias`, optional `ID` (UUID).
    public var profiles: [ManagedProfile] = []
    /// `AllowedGatewayHosts`: exact hosts or `*.domain`; empty = no restriction.
    public var allowedGatewayHosts: [String] = []
    /// `DefaultEndpoint` / `DefaultModelAlias`: prefill for self-created profiles.
    public var defaultEndpoint: String?
    public var defaultModelAlias: String?
    /// `MinimumClaudeCodeVersion`: threshold for the outdated-CLI warning.
    public var minimumClaudeCodeVersion: String?
    /// `OneDriveBackup`: back up profiles and bindings (never keys) to the user's OneDrive.
    public var oneDriveBackup = false
    /// `BackupDirectory`: explicit backup folder (supports `~`); enables the backup on its own.
    public var backupDirectory: String?
    /// `UpdateCheckEnabled`: in-app update check against GitHub releases (default on). Turn off when Intune
    /// distributes a fixed version, otherwise Intune may reinstall it over a self-installed update.
    public var updateCheckEnabled = true
    /// `AllowKeyExport`: whether encrypted backups may contain keys (default on). Off: settings only.
    public var allowKeyExport = true

    static let keys = ["ManagedProfiles", "AllowedGatewayHosts", "DefaultEndpoint", "DefaultModelAlias",
                       "MinimumClaudeCodeVersion", "OneDriveBackup", "BackupDirectory", "UpdateCheckEnabled", "AllowKeyExport"]

    public init() {}

    public init(_ values: [String: Any]) {
        profiles = (values["ManagedProfiles"] as? [[String: Any]] ?? []).compactMap { dict in
            guard let name = (dict["Name"] as? String)?.trimmingCharacters(in: .whitespaces), !name.isEmpty,
                  let endpoint = (dict["Endpoint"] as? String).flatMap(URL.init(string:)), endpoint.host() != nil else { return nil }
            let id = (dict["ID"] as? String).flatMap(UUID.init(uuidString:)) ?? Self.derivedID(forName: name)
            return ManagedProfile(id: id, name: name, endpoint: endpoint, modelAlias: dict["ModelAlias"] as? String ?? "")
        }
        allowedGatewayHosts = (values["AllowedGatewayHosts"] as? [String] ?? []).map { $0.lowercased() }.filter { !$0.isEmpty }
        defaultEndpoint = values["DefaultEndpoint"] as? String
        defaultModelAlias = values["DefaultModelAlias"] as? String
        minimumClaudeCodeVersion = values["MinimumClaudeCodeVersion"] as? String
        oneDriveBackup = values["OneDriveBackup"] as? Bool ?? false
        backupDirectory = values["BackupDirectory"] as? String
        updateCheckEnabled = values["UpdateCheckEnabled"] as? Bool ?? true
        allowKeyExport = values["AllowKeyExport"] as? Bool ?? true
    }

    public static func load(domain: String = ManagedConfig.domain) -> ManagedConfig {
        var values: [String: Any] = [:]
        for key in keys {
            if let value = CFPreferencesCopyAppValue(key as CFString, domain as CFString) { values[key] = value }
        }
        return ManagedConfig(values)
    }

    public func isEndpointAllowed(_ url: URL) -> Bool {
        guard !allowedGatewayHosts.isEmpty else { return true }
        guard let host = url.host()?.lowercased() else { return false }
        return allowedGatewayHosts.contains { pattern in
            pattern.hasPrefix("*.") ? host.hasSuffix(String(pattern.dropFirst())) : host == pattern
        }
    }

    /// Stable profile ID for a managed profile without explicit `ID`, so bindings survive app restarts.
    static func derivedID(forName name: String) -> UUID {
        var bytes = Array(SHA256.hash(data: Data("keyzapper-managed-profile:\(name)".utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50 // version 5 style
        bytes[8] = (bytes[8] & 0x3F) | 0x80 // RFC 4122 variant
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }
}
