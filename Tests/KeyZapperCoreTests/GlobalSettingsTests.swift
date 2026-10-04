@testable import KeyZapperCore
import Foundation
import Testing

struct GlobalSettingsTests {
    let dir = makeTempDir("claude")
    var userPath: String { dir + "/settings.json" }
    var binder: ClaudeSettingsBinder { ClaudeSettingsBinder(helperPath: "/h", managedSettingsPaths: [], userSettingsPath: userPath) }

    @Test func defaultProfileReplacesPlaintextKeyAndRevertsCleanly() throws {
        writeJSON(["env": ["ANTHROPIC_API_KEY": "sk-plain", "FOO": "bar"], "model": "opus"], to: userPath)
        let backup = try binder.backupUserSettings()
        let applied = try binder.applyGlobal(profile: sampleProfile, previous: nil)
        let json = try #require(readJSON(userPath))
        let env = try #require(json["env"] as? [String: String])
        #expect(env["ANTHROPIC_API_KEY"] == "")
        #expect(env["FOO"] == "bar")
        #expect(json["model"] as? String == "opus")
        #expect((json["apiKeyHelper"] as? String)?.contains(sampleProfile.id.uuidString) == true)
        #expect(binder.inspectGlobal(applied.binding, profile: sampleProfile) == .active)
        let backupText = try String(contentsOf: try #require(backup), encoding: .utf8)
        #expect(backupText.contains("sk-plain"))

        try binder.revertGlobal(applied.binding)
        let after = try #require(readJSON(userPath))
        #expect(after["apiKeyHelper"] == nil)
        #expect(after["env"] as? [String: String] == ["FOO": "bar"])
        #expect(after["$schema"] as? String == ClaudeSettingsBinder.schemaURL)
    }

    @Test func repairMakesFileStrictlyValidAndRemovesPlaintextKeys() throws {
        try #"{ "env": { "ANTHROPIC_API_KEY": "sk-plain", "CLAUDE_CODE_ENABLE_TELEMETRY": 0, }, "model": "opus", }"#
            .write(toFile: userPath, atomically: true, encoding: .utf8)
        #expect(ClaudeSettingsBinder.isUnparsableJSON(userPath))
        let backup = try binder.repairUserSettings()
        #expect(backup != nil)
        #expect(ClaudeSettingsBinder.isUnparsableJSON(userPath) == false)
        let json = try #require(readJSON(userPath))
        #expect(json["env"] as? [String: String] == ["CLAUDE_CODE_ENABLE_TELEMETRY": "0"])
        #expect(json["model"] as? String == "opus")

        try "{ totally broken".write(toFile: userPath, atomically: true, encoding: .utf8)
        try binder.repairUserSettings()
        #expect(readJSON(userPath)?["$schema"] as? String == ClaudeSettingsBinder.schemaURL)
    }

    @Test func auditFindsLogicalProblems() throws {
        writeJSON(["env": ["ANTHROPIC_API_KEY": "sk-plain", "ANTHROPIC_BASE_URL": "https://gw.test", "CLAUDE_CODE_ENABLE_TELEMETRY": 0,
                           "ANTHROPIC_DEFAULT_SONNET_MODEL": "eu.sonnet"],
                   "model": "claude-opus-5"], to: userPath)
        let ids = Set(GlobalSettingsAudit.check(path: userPath).map(\.id))
        #expect(ids.contains("plaintext-ANTHROPIC_API_KEY"))
        #expect(ids.contains("env-value-CLAUDE_CODE_ENABLE_TELEMETRY"))
        #expect(ids.contains("model-env-ANTHROPIC_DEFAULT_SONNET_MODEL"))
        #expect(ids.contains("fixed-model"))
        #expect(ids.contains("endpoint-without-key") == false)

        writeJSON(["env": ["ANTHROPIC_BASE_URL": "https://gw.test"]], to: userPath)
        let noKey = Set(GlobalSettingsAudit.check(path: userPath).map(\.id))
        #expect(noKey.contains("endpoint-without-key"))

        let applied = try binder.applyGlobal(profile: sampleProfile, previous: nil)
        let own = GlobalSettingsAudit.check(path: userPath, globalValues: applied.binding.managedValues)
        #expect(own.filter { $0.severity != .info }.isEmpty)

        try "{ \"a\": 1, }".write(toFile: userPath, atomically: true, encoding: .utf8)
        #expect(GlobalSettingsAudit.check(path: userPath).map(\.id) == ["invalid-json"])
        #expect(GlobalSettingsAudit.check(path: dir + "/none.json").map(\.id) == ["missing"])
    }

    @Test func managedModelVariablesAreReported() {
        let managed = makeTempDir("managed") + "/managed-settings.json"
        writeJSON(["env": ["ANTHROPIC_DEFAULT_SONNET_MODEL": "corp-sonnet"]], to: managed)
        let conflicts = ClaudeSettingsBinder(helperPath: "/h", managedSettingsPaths: [managed], userSettingsPath: userPath).managedConflicts()
        #expect(conflicts.count == 1)
        #expect(conflicts.first?.severity == .warning)
    }

    @Test func strictCheckCacheNoticesChanges() throws {
        try "{}".write(toFile: userPath, atomically: true, encoding: .utf8)
        #expect(ClaudeSettingsBinder.isUnparsableJSON(userPath) == false)
        try "{ \"a\": 1, }".write(toFile: userPath, atomically: true, encoding: .utf8)
        #expect(ClaudeSettingsBinder.isUnparsableJSON(userPath))
    }
}

struct DowngradeAndKeychainTests {
    @Test func mirrorRestoresFieldsAnOlderVersionDropped() throws {
        let store = MetadataStore(fileURL: URL(fileURLWithPath: makeTempDir()).appendingPathComponent("state.json"))
        var profile = sampleProfile
        profile.sonnetModel = "eu.sonnet"
        profile.environment = ["CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS": "1"]
        var state = AppState(profiles: [profile])
        state.disabled = true
        try store.save(state)
        // An older app rewrites state.json without the fields it does not know.
        let old = #"{"schemaVersion":1,"profiles":[{"id":"\#(profile.id.uuidString)","name":"Alpha","endpoint":"https://litellm.example.test/","modelAlias":"claude-alpha","credential":{"service":"KeyZapper.LiteLLM","account":"\#(profile.id.uuidString)"}}],"bindings":[]}"#
        try Data(old.utf8).write(to: store.fileURL)
        let loaded = try store.load()
        #expect(loaded.profiles.first?.sonnetModel == "eu.sonnet")
        #expect(loaded.profiles.first?.environment == ["CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS": "1"])
        #expect(loaded.disabled == true)
    }

    @Test func helperIgnoresCraftedCredentialReference() throws {
        let metadata = MetadataStore(fileURL: URL(fileURLWithPath: makeTempDir()).appendingPathComponent("state.json"))
        var crafted = sampleProfile
        crafted.credential = CredentialReference(service: "com.example.other-app", account: "victim")
        try metadata.save(AppState(profiles: [crafted]))
        let store = InMemoryCredentialStore()
        store.items = ["victim": "sk-foreign", sampleProfile.id.uuidString: "sk-own"]
        let out = KeyHelperCommand(metadata: metadata, store: store).run(["credential", "--profile", sampleProfile.id.uuidString]) { "" }
        #expect(out.stdout == "sk-own")
    }
}
