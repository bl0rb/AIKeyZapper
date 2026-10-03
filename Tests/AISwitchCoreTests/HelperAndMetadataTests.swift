@testable import AISwitchCore
import Foundation
import Testing

struct MetadataStoreTests {
    @Test func roundTripAndMissingFile() throws {
        let store = MetadataStore(fileURL: URL(fileURLWithPath: makeTempDir()).appendingPathComponent("sub/state.json"))
        #expect(try store.load() == AppState())
        let state = AppState(profiles: [sampleProfile], bindings: [WorkspaceBinding(path: "/x", profileID: sampleProfile.id)])
        try store.save(state)
        #expect(try store.load() == state)
        let perms = try FileManager.default.attributesOfItem(atPath: store.fileURL.path)[.posixPermissions] as? Int
        #expect(perms == 0o600)
    }

    @Test func rejectsNewerSchemaAndCorruptData() throws {
        #expect(throws: AISwitchError.unsupportedSchemaVersion(99)) {
            try MetadataStore.decode(Data(#"{"schemaVersion":99,"profiles":[],"bindings":[]}"#.utf8))
        }
        #expect(throws: AISwitchError.self) { try MetadataStore.decode(Data("nope".utf8)) }
    }
}

struct KeyHelperCommandTests {
    let store = InMemoryCredentialStore()
    let metadata: MetadataStore

    init() throws {
        metadata = MetadataStore(fileURL: URL(fileURLWithPath: makeTempDir()).appendingPathComponent("state.json"))
        try metadata.save(AppState(profiles: [sampleProfile, otherProfile]))
        store.items = [sampleProfile.id.uuidString: "sk-alpha", otherProfile.id.uuidString: "sk-beta"]
    }

    func run(_ args: [String], stdin: String = "") -> KeyHelperCommand.Output {
        KeyHelperCommand(metadata: metadata, store: store).run(args) { stdin }
    }

    @Test func returnsOnlyRequestedProfileKeyWithoutNewline() {
        #expect(run(["credential", "--profile", sampleProfile.id.uuidString]) == .init(exitCode: .ok, stdout: "sk-alpha", stderr: ""))
        #expect(run(["credential", "--profile", otherProfile.id.uuidString]).stdout == "sk-beta")
    }

    @Test func missingCredentialFailsWithoutFallback() {
        store.items[sampleProfile.id.uuidString] = nil
        let out = run(["credential", "--profile", sampleProfile.id.uuidString])
        #expect(out.exitCode == .missingCredential)
        #expect(out.stdout.isEmpty)
        #expect(!out.stderr.contains("sk-"))
    }

    @Test func unknownOrInvalidProfileAndUsage() {
        #expect(run(["credential", "--profile", UUID().uuidString]).exitCode == .unknownProfile)
        #expect(run(["credential", "--profile", "not-a-uuid"]).exitCode == .unknownProfile)
        #expect(run(["credential"]).exitCode == .usage)
        #expect(run(["export", "--profile", sampleProfile.id.uuidString]).exitCode == .usage)
    }

    @Test func keychainLockedOrDenied() {
        store.failure = .keychainLocked
        #expect(run(["credential", "--profile", sampleProfile.id.uuidString]).exitCode == .keychainAccessDenied)
        store.failure = .keychainAccessDenied(-128)
        #expect(run(["credential", "--profile", sampleProfile.id.uuidString]).exitCode == .keychainAccessDenied)
    }

    @Test func storeReadsStdinStatusAndDelete() {
        #expect(run(["store", "--profile", sampleProfile.id.uuidString], stdin: "sk-new\n").exitCode == .ok)
        #expect(store.items[sampleProfile.id.uuidString] == "sk-new")
        #expect(store.items[otherProfile.id.uuidString] == "sk-beta")
        #expect(run(["store", "--profile", sampleProfile.id.uuidString], stdin: " \n").exitCode == .missingCredential)
        #expect(run(["status", "--profile", sampleProfile.id.uuidString]).exitCode == .ok)
        #expect(run(["delete", "--profile", sampleProfile.id.uuidString]).exitCode == .ok)
        #expect(run(["status", "--profile", sampleProfile.id.uuidString]).exitCode == .missingCredential)
    }

    @Test func unreadableMetadataIsConfigError() throws {
        try Data(#"{"schemaVersion":42}"#.utf8).write(to: metadata.fileURL)
        #expect(run(["credential", "--profile", sampleProfile.id.uuidString]).exitCode == .configError)
    }
}

@Test func cliVersionComparison() {
    #expect(ClaudeCLI.isOlder("2.1.206", than: "2.1.288"))
    #expect(!ClaudeCLI.isOlder("2.1.288", than: "2.1.288"))
    #expect(!ClaudeCLI.isOlder("2.2.0", than: "2.1.288"))
}
