@testable import KeyZapperCore
import Foundation
import Testing

struct ModelSettingsTests {
    @Test func tierModelsAndEnvironmentAreWrittenButReservedNamesAreNot() {
        let profile = Profile(name: "ITI-CS", endpoint: URL(string: "https://gateway.example.test")!, modelAlias: "",
                              opusModel: "eu.opus-iti", sonnetModel: " eu.sonnet-iti ", haikuModel: "",
                              environment: ["CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS": "1", "ANTHROPIC_API_KEY": "leak", "CLAUDE_CODE_USE_BEDROCK": "1"])
        let values = ClaudeSettingsBinder(helperPath: "/h", managedSettingsPaths: []).desiredValues(for: profile)
        #expect(values["env.ANTHROPIC_DEFAULT_OPUS_MODEL"] == "eu.opus-iti")
        #expect(values["env.ANTHROPIC_DEFAULT_SONNET_MODEL"] == "eu.sonnet-iti")
        #expect(values["env.ANTHROPIC_DEFAULT_HAIKU_MODEL"] == nil)
        #expect(values["env.ANTHROPIC_MODEL"] == nil)
        #expect(values["env.CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS"] == "1")
        #expect(values["env.ANTHROPIC_API_KEY"] == "")
        #expect(values["env.CLAUDE_CODE_USE_BEDROCK"] == nil)
        #expect(profile.configuredModels == ["eu.opus-iti", "eu.sonnet-iti"])
    }

    @Test func poolModeUsesPoolHelperWithShortCache() {
        let binder = ClaudeSettingsBinder(helperPath: "/h", managedSettingsPaths: [])
        let pooled = binder.desiredValues(for: sampleProfile, pooled: true)
        #expect(pooled["apiKeyHelper"] == "'/h' pool --profile \(sampleProfile.id.uuidString)")
        #expect(pooled["env.CLAUDE_CODE_API_KEY_HELPER_TTL_MS"] == "60000")
        #expect(binder.desiredValues(for: sampleProfile)["env.CLAUDE_CODE_API_KEY_HELPER_TTL_MS"] == nil)
    }

    @Test func parsesEnvironmentLines() {
        let parsed = Profile.parseEnvironment("CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS=1\n# comment\n\nFOO = a=b\nANTHROPIC_BASE_URL=x\nnot valid\n1BAD=2")
        #expect(parsed.values == ["CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS": "1", "FOO": "a=b"])
        #expect(parsed.invalidLines == ["ANTHROPIC_BASE_URL=x", "not valid", "1BAD=2"])
        let formatted = Profile.formatEnvironment(["B": "2", "A": "1"])
        #expect(formatted == "A=1\nB=2")
    }

    @Test func suggestsNewestModelPerTier() {
        let models = ["eu.anthropic.claude-haiku-4-5-20251001-v1:0", "eu.anthropic.claude-sonnet-4-5-iti-cs",
                      "eu.anthropic.claude-sonnet-5-iti-cs", "eu.anthropic.claude-opus-5-iti-cs", "text-embedding"]
        let suggestion = ModelSuggestion.suggest(from: models)
        #expect(suggestion.opus == "eu.anthropic.claude-opus-5-iti-cs")
        #expect(suggestion.sonnet == "eu.anthropic.claude-sonnet-5-iti-cs")
        #expect(suggestion.haiku == "eu.anthropic.claude-haiku-4-5-20251001-v1:0")
        let empty = ModelSuggestion.suggest(from: ["gpt-x"])
        #expect(empty.sonnet == nil)
    }

    @Test func profilesSavedBeforeModelTiersStillLoad() throws {
        let json = #"{"schemaVersion":1,"profiles":[{"id":"4F1C2A9E-7B3D-4E8A-9C1F-2D6B8E0A5C31","name":"Alt","endpoint":"https://x.test","modelAlias":"","credential":{"service":"KeyZapper.LiteLLM","account":"4F1C2A9E-7B3D-4E8A-9C1F-2D6B8E0A5C31"}}],"bindings":[]}"#
        let state = try MetadataStore.decode(Data(json.utf8))
        let profile = try #require(state.profiles.first)
        #expect(profile.sonnetModel == nil)
        #expect(profile.environment == nil)
    }

    @Test func managedProfilesCarryTierModelsAndEnvironment() {
        let config = ManagedConfig(["ManagedProfiles": [["Name": "ITI-CS", "Endpoint": "https://gw.test", "SonnetModel": "eu.sonnet",
                                                          "Environment": ["CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS": "1"]]]])
        let managed = config.profiles.first
        #expect(managed?.sonnetModel == "eu.sonnet")
        #expect(managed?.environment == ["CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS": "1"])
    }
}
