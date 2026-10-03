@testable import KeyZapperCore
import Foundation
import Testing

struct ManagedConfigTests {
    @Test func parsesIntuneValuesAndDerivesStableProfileIDs() {
        let explicit = UUID()
        let config = ManagedConfig([
            "ManagedProfiles": [
                ["Name": "Alpha", "Endpoint": "https://litellm.firma.de", "ModelAlias": "sonnet"],
                ["Name": "Beta", "Endpoint": "https://litellm.firma.de", "ID": explicit.uuidString],
                ["Name": "", "Endpoint": "https://x.de"],
                ["Name": "Kaputt", "Endpoint": "kein url"],
            ],
            "AllowedGatewayHosts": ["LiteLLM.firma.de", "*.gw.firma.de"],
            "DefaultEndpoint": "https://litellm.firma.de",
            "MinimumClaudeCodeVersion": "2.2.0",
            "OneDriveBackup": true,
        ])
        let names = config.profiles.map { $0.name }
        #expect(names == ["Alpha", "Beta"])
        let alphaID = ManagedConfig.derivedID(forName: "Alpha")
        let renamedEndpoint: [String: Any] = ["ManagedProfiles": [["Name": "Alpha", "Endpoint": "https://other.de"]]]
        let sameNameID = ManagedConfig(renamedEndpoint).profiles.first?.id
        #expect(config.profiles[0].id == alphaID)
        #expect(sameNameID == alphaID)
        #expect(config.profiles[1].id == explicit)
        #expect(config.profiles[0].modelAlias == "sonnet")
        #expect(config.profiles[1].modelAlias == "")
        #expect(config.minimumClaudeCodeVersion == "2.2.0")
        #expect(config.oneDriveBackup)
        let empty = ManagedConfig()
        #expect(empty.profiles.isEmpty)
        #expect(empty.oneDriveBackup == false)
    }

    @Test func gatewayAllowlist() {
        let config = ManagedConfig(["AllowedGatewayHosts": ["litellm.firma.de", "*.gw.firma.de"]])
        #expect(config.isEndpointAllowed(URL(string: "https://LITELLM.firma.de/v1")!))
        #expect(config.isEndpointAllowed(URL(string: "https://eu.gw.firma.de")!))
        #expect(!config.isEndpointAllowed(URL(string: "https://evilgw.firma.de")!))
        #expect(!config.isEndpointAllowed(URL(string: "https://litellm.firma.de.evil.com")!))
        #expect(ManagedConfig().isEndpointAllowed(URL(string: "https://anything.example")!))
    }

    @Test func helperRefusesKeyForDisallowedEndpoint() throws {
        let metadata = MetadataStore(fileURL: URL(fileURLWithPath: makeTempDir()).appendingPathComponent("state.json"))
        try metadata.save(AppState(profiles: [sampleProfile]))
        let store = InMemoryCredentialStore()
        store.items[sampleProfile.id.uuidString] = "sk-alpha"
        let args = ["credential", "--profile", sampleProfile.id.uuidString]
        let blocked = KeyHelperCommand(metadata: metadata, store: store, config: ManagedConfig(["AllowedGatewayHosts": ["litellm.firma.de"]])).run(args) { "" }
        #expect(blocked.exitCode == .configError && blocked.stdout.isEmpty)
        let allowed = KeyHelperCommand(metadata: metadata, store: store, config: ManagedConfig(["AllowedGatewayHosts": ["*.example.test"]])).run(args) { "" }
        #expect(allowed.stdout == "sk-alpha")
    }
}

struct BackupStoreTests {
    @Test func resolvesOneDriveFolderPreferringBusinessAccount() throws {
        let home = URL(fileURLWithPath: makeTempDir("home"))
        let cloud = home.appendingPathComponent("Library/CloudStorage")
        #expect(BackupStore.directory(for: ManagedConfig(["OneDriveBackup": true]), home: home) == nil)
        for folder in ["OneDrive-Personal", "OneDrive-Firma GmbH", "iCloud Drive"] {
            try FileManager.default.createDirectory(at: cloud.appendingPathComponent(folder), withIntermediateDirectories: true)
        }
        let resolved = BackupStore.directory(for: ManagedConfig(["OneDriveBackup": true]), home: home)?.path
        #expect(resolved == cloud.appendingPathComponent("OneDrive-Firma GmbH/KeyZapper").path)
        #expect(BackupStore.directory(for: ManagedConfig(), home: home) == nil)
        let explicitDir = BackupStore.directory(for: ManagedConfig(["BackupDirectory": "~/Backups/KZ"]), home: home)?.path
        #expect(explicitDir == NSHomeDirectory() + "/Backups/KZ")
    }

    @Test func roundTripContainsNoKeys() throws {
        let store = BackupStore(directory: URL(fileURLWithPath: makeTempDir("OneDrive-Firma")).appendingPathComponent("KeyZapper"))
        #expect(try store.read() == nil)
        let state = AppState(profiles: [sampleProfile], bindings: [WorkspaceBinding(path: "/p", profileID: sampleProfile.id)])
        try store.write(state)
        #expect(try store.read() == state)
        let text = try String(contentsOf: store.fileURL, encoding: .utf8)
        #expect(!text.contains("sk-"))
    }
}
