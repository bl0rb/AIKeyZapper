@testable import KeyZapperCore
import Foundation
import Testing

struct EncryptedBackupTests {
    let payload = BackupPayload(createdAt: Date(timeIntervalSince1970: 1_790_000_000), appVersion: "1.0.3",
                                state: AppState(profiles: [sampleProfile], bindings: [WorkspaceBinding(path: "/p", profileID: sampleProfile.id)]),
                                keys: [sampleProfile.id.uuidString: "sk-secret-alpha"])
    let password = "correct horse battery"

    @Test func roundTripKeepsKeysAndSettings() throws {
        let data = try EncryptedBackup.seal(payload, password: password, iterations: 100_000)
        let opened = try EncryptedBackup.open(data, password: password)
        #expect(opened == payload)
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains("sk-secret") == false)
        #expect(text.contains(sampleProfile.name) == false)
    }

    @Test func wrongPasswordIsRejected() throws {
        let data = try EncryptedBackup.seal(payload, password: password, iterations: 100_000)
        #expect(throws: BackupError.wrongPasswordOrCorrupt) { try EncryptedBackup.open(data, password: "wrong password!!") }
    }

    @Test func tamperedEnvelopeIsRejected() throws {
        let data = try EncryptedBackup.seal(payload, password: password, iterations: 100_000)
        let tampered = Data(String(decoding: data, as: UTF8.self).replacingOccurrences(of: "100000", with: "100001").utf8)
        #expect(throws: BackupError.wrongPasswordOrCorrupt) { try EncryptedBackup.open(tampered, password: password) }
    }

    @Test func rejectsShortPasswordsForeignFilesAndHostileParameters() throws {
        #expect(throws: BackupError.passwordTooShort) { try EncryptedBackup.seal(payload, password: "short", iterations: 100_000) }
        #expect(throws: BackupError.notABackup) { try EncryptedBackup.open(Data("{}".utf8), password: password) }
        let data = try EncryptedBackup.seal(payload, password: password, iterations: 100_000)
        let hostile = Data(String(decoding: data, as: UTF8.self).replacingOccurrences(of: "100000", with: "999999999").utf8)
        #expect(throws: BackupError.corrupt) { try EncryptedBackup.open(hostile, password: password) }
    }

    @Test func keyExportCanBeDisabledByIT() {
        #expect(ManagedConfig().allowKeyExport)
        #expect(ManagedConfig(["AllowKeyExport": false]).allowKeyExport == false)
    }
}
