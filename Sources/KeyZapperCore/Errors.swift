import Foundation

public enum KeyZapperError: Error, Equatable, LocalizedError {
    case unknownProfile(String)
    case missingCredential(UUID)
    case keychainLocked
    case keychainAccessDenied(Int32)
    case keychain(Int32)
    case emptyCredential
    case unsupportedSchemaVersion(Int)
    case corruptMetadata(String)
    case folderNotFound(String)
    case notSettingsRoot(folder: String, root: String)
    case settingsConflicts([SettingsConflict])
    case settingsUnreadable(String)
    case concurrentModification(String)

    public var errorDescription: String? {
        switch self {
        case .unknownProfile(let id): "Unbekanntes Profil: \(id)"
        case .missingCredential(let id): "Für Profil \(id.uuidString) ist kein Key im Schlüsselbund hinterlegt."
        case .keychainLocked: "Der Schlüsselbund ist gesperrt."
        case .keychainAccessDenied(let s): "Zugriff auf den Schlüsselbund verweigert (OSStatus \(s))."
        case .keychain(let s): "Schlüsselbundfehler (OSStatus \(s))."
        case .emptyCredential: "Der Key ist leer."
        case .unsupportedSchemaVersion(let v): "Metadaten-Version \(v) wird von dieser Version nicht unterstützt. Bitte App aktualisieren."
        case .corruptMetadata(let m): "Metadaten sind beschädigt: \(m)"
        case .folderNotFound(let p): "Ordner nicht gefunden: \(p)"
        case .notSettingsRoot(let folder, let root): "\(folder) liegt in einem Git-Repository. Claude Code liest Projekteinstellungen nur aus \(root)."
        case .settingsConflicts(let c): c.map(\.message).joined(separator: "\n")
        case .settingsUnreadable(let m): "Claude-Einstellungen sind nicht lesbar: \(m)"
        case .concurrentModification(let p): "\(p) wurde während der Änderung mehrfach von einem anderen Prozess geändert. Bitte erneut versuchen."
        }
    }
}

public struct SettingsConflict: Equatable, Hashable, Sendable {
    public enum Severity: Sendable { case blocking, warning }
    public var severity: Severity
    public var message: String

    public init(_ severity: Severity, _ message: String) {
        self.severity = severity
        self.message = message
    }
}
