import CommonCrypto
import CryptoKit
import Foundation

/// Contents of a password-protected backup: metadata plus (optionally) the keys, by profile UUID.
public struct BackupPayload: Codable, Equatable, Sendable {
    public var createdAt: Date
    public var appVersion: String?
    public var state: AppState
    public var keys: [String: String]

    public init(createdAt: Date = Date(), appVersion: String?, state: AppState, keys: [String: String]) {
        self.createdAt = createdAt
        self.appVersion = appVersion
        self.state = state
        self.keys = keys
    }
}

/// `.kzbackup` file: AES-256-GCM, key derived with PBKDF2-HMAC-SHA256 from the password and a random salt.
/// The envelope parameters are authenticated as associated data, so tampering with them fails decryption.
public enum EncryptedBackup {
    public static let fileExtension = "kzbackup"
    public static let minimumPasswordLength = 12
    static let format = "keyzapper-backup"
    public static let defaultIterations = 600_000

    struct Envelope: Codable {
        var format: String
        var version: Int
        var kdf: String
        var iterations: Int
        var salt: Data
        var cipher: String
        var sealed: Data

        var associatedData: Data { Data("\(format)|\(version)|\(kdf)|\(iterations)|\(salt.base64EncodedString())|\(cipher)".utf8) }
    }

    public static func seal(_ payload: BackupPayload, password: String, iterations: Int = defaultIterations) throws -> Data {
        guard password.count >= minimumPasswordLength else { throw BackupError.passwordTooShort }
        var envelope = Envelope(format: format, version: 1, kdf: "pbkdf2-sha256", iterations: iterations,
                                salt: randomBytes(16), cipher: "aes-256-gcm", sealed: Data())
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let key = try deriveKey(password: password, salt: envelope.salt, iterations: iterations)
        let box = try AES.GCM.seal(try encoder.encode(payload), using: key, authenticating: envelope.associatedData)
        guard let combined = box.combined else { throw BackupError.corrupt }
        envelope.sealed = combined
        let output = JSONEncoder()
        output.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try output.encode(envelope)
    }

    public static func open(_ data: Data, password: String) throws -> BackupPayload {
        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: data), envelope.format == format else {
            throw BackupError.notABackup
        }
        guard envelope.version == 1, envelope.kdf == "pbkdf2-sha256", envelope.cipher == "aes-256-gcm" else {
            throw BackupError.unsupportedVersion
        }
        // Bounds guard against hostile files that would stall the KDF.
        guard (100_000...10_000_000).contains(envelope.iterations), envelope.salt.count >= 16 else { throw BackupError.corrupt }
        let key = try deriveKey(password: password, salt: envelope.salt, iterations: envelope.iterations)
        let plaintext: Data
        do {
            plaintext = try AES.GCM.open(try AES.GCM.SealedBox(combined: envelope.sealed), using: key,
                                         authenticating: envelope.associatedData)
        } catch {
            throw BackupError.wrongPasswordOrCorrupt
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let payload = try? decoder.decode(BackupPayload.self, from: plaintext) else { throw BackupError.corrupt }
        return payload
    }

    static func deriveKey(password: String, salt: Data, iterations: Int) throws -> SymmetricKey {
        let passwordBytes = Array(password.precomposedStringWithCanonicalMapping.utf8).map { CChar(bitPattern: $0) }
        var derived = [UInt8](repeating: 0, count: 32)
        let status = salt.withUnsafeBytes { saltBytes in
            CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), passwordBytes, passwordBytes.count,
                                 saltBytes.bindMemory(to: UInt8.self).baseAddress, salt.count,
                                 CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), UInt32(iterations), &derived, derived.count)
        }
        guard status == kCCSuccess else { throw BackupError.corrupt }
        return SymmetricKey(data: derived)
    }

    static func randomBytes(_ count: Int) -> Data {
        Data(SymmetricKey(size: SymmetricKeySize(bitCount: count * 8)).withUnsafeBytes { Array($0) })
    }
}

public enum BackupError: Error, Equatable, LocalizedError {
    case passwordTooShort
    case notABackup
    case unsupportedVersion
    case wrongPasswordOrCorrupt
    case corrupt

    public var errorDescription: String? {
        switch self {
        case .passwordTooShort: L("Das Passwort muss mindestens \(EncryptedBackup.minimumPasswordLength) Zeichen haben.")
        case .notABackup: L("Die Datei ist kein KeyZapper-Backup.")
        case .unsupportedVersion: L("Dieses Backup stammt von einer neueren KeyZapper-Version. Bitte App aktualisieren.")
        case .wrongPasswordOrCorrupt: L("Falsches Passwort oder beschädigte Backup-Datei.")
        case .corrupt: L("Die Backup-Datei ist beschädigt.")
        }
    }
}
