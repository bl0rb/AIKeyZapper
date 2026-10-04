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
        case .unknownProfile(let id): L("Unbekanntes Profil: \(id)")
        case .missingCredential(let id): L("Für Profil \(id.uuidString) ist kein Key im Schlüsselbund hinterlegt.")
        case .keychainLocked: L("Der Schlüsselbund ist gesperrt.")
        case .keychainAccessDenied(let s): L("Zugriff auf den Schlüsselbund verweigert (OSStatus \(String(s))).")
        case .keychain(let s): L("Schlüsselbundfehler (OSStatus \(String(s))).")
        case .emptyCredential: L("Der Key ist leer.")
        case .unsupportedSchemaVersion(let v): L("Metadaten-Version \(String(v)) wird von dieser Version nicht unterstützt. Bitte App aktualisieren.")
        case .corruptMetadata(let m): L("Metadaten sind beschädigt: \(m)")
        case .folderNotFound(let p): L("Ordner nicht gefunden: \(p)")
        case .notSettingsRoot(let folder, let root): L("\(folder) liegt in einem Git-Repository. Claude Code liest Projekteinstellungen nur aus \(root).")
        case .settingsConflicts(let c): c.map(\.message).joined(separator: "\n")
        case .settingsUnreadable(let m): L("Claude-Einstellungen sind nicht lesbar: \(m)")
        case .concurrentModification(let p): L("\(p) wurde während der Änderung mehrfach von einem anderen Prozess geändert. Bitte erneut versuchen.")
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
