import Foundation
import Security

public protocol CredentialStore {
    func read(_ ref: CredentialReference) throws -> String
    func write(_ secret: String, label: String, for ref: CredentialReference) throws
    func delete(_ ref: CredentialReference) throws
    /// Checks presence without reading the secret (no keychain ACL prompt).
    func exists(_ ref: CredentialReference) throws -> Bool
}

/// macOS login keychain, generic password items (service = `ref.service`, account = profile UUID).
/// At runtime only `keyzapper-helper` talks to the keychain, so the item ACL trusts exactly one binary.
public struct KeychainCredentialStore: CredentialStore {
    public init() {}

    private func baseQuery(_ ref: CredentialReference) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: ref.service,
         kSecAttrAccount as String: ref.account]
    }

    public func read(_ ref: CredentialReference) throws -> String {
        var query = baseQuery(ref)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else { throw Self.map(status, ref) }
        guard let data = result as? Data, let secret = String(data: data, encoding: .utf8), !secret.isEmpty else {
            throw KeyZapperError.emptyCredential
        }
        return secret
    }

    public func write(_ secret: String, label: String, for ref: CredentialReference) throws {
        guard !secret.isEmpty else { throw KeyZapperError.emptyCredential }
        let data = Data(secret.utf8)
        let update: [String: Any] = [kSecValueData as String: data, kSecAttrLabel as String: label]
        var status = SecItemUpdate(baseQuery(ref) as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var add = baseQuery(ref)
            add.merge(update) { $1 }
            status = SecItemAdd(add as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw Self.map(status, ref) }
    }

    public func delete(_ ref: CredentialReference) throws {
        let status = SecItemDelete(baseQuery(ref) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw Self.map(status, ref) }
    }

    public func exists(_ ref: CredentialReference) throws -> Bool {
        var query = baseQuery(ref)
        query[kSecReturnAttributes as String] = true
        let status = SecItemCopyMatching(query as CFDictionary, nil)
        if status == errSecItemNotFound { return false }
        guard status == errSecSuccess else { throw Self.map(status, ref) }
        return true
    }

    static func map(_ status: OSStatus, _ ref: CredentialReference) -> KeyZapperError {
        switch status {
        case errSecItemNotFound: .missingCredential(UUID(uuidString: ref.account) ?? UUID())
        case errSecInteractionNotAllowed, errSecNotAvailable: .keychainLocked
        case errSecAuthFailed, errSecUserCanceled, errSecNoAccessForItem: .keychainAccessDenied(status)
        default: .keychain(status)
        }
    }
}
