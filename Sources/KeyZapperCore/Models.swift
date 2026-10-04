import Foundation

/// Points to the keychain item holding a profile's LiteLLM key. The key itself never leaves the keychain
/// except through `keyzapper-helper credential`.
public struct CredentialReference: Codable, Hashable, Sendable {
    public static let defaultService = "KeyZapper.LiteLLM"
    public var service: String
    public var account: String

    public init(service: String = CredentialReference.defaultService, account: String) {
        self.service = service
        self.account = account
    }
}

public struct Profile: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    /// LiteLLM base URL, written to `env.ANTHROPIC_BASE_URL`.
    public var endpoint: URL
    /// Optional model alias, written to `env.ANTHROPIC_MODEL` when non-empty.
    public var modelAlias: String
    /// Gateway model names for Claude Code's model tiers (`env.ANTHROPIC_DEFAULT_{OPUS,SONNET,HAIKU}_MODEL`).
    public var opusModel: String?
    public var sonnetModel: String?
    public var haikuModel: String?
    /// Further environment variables for Claude Code, e.g. `CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS=1`.
    public var environment: [String: String]?
    public var credential: CredentialReference

    public init(id: UUID = UUID(), name: String, endpoint: URL, modelAlias: String,
                opusModel: String? = nil, sonnetModel: String? = nil, haikuModel: String? = nil,
                environment: [String: String]? = nil) {
        self.id = id
        self.name = name
        self.endpoint = endpoint
        self.modelAlias = modelAlias
        self.opusModel = opusModel
        self.sonnetModel = sonnetModel
        self.haikuModel = haikuModel
        self.environment = environment
        self.credential = CredentialReference(account: id.uuidString)
    }

    /// Environment entries KeyZapper writes for the model settings (only non-empty values).
    public var modelEnvironment: [String: String] {
        var values: [String: String] = [:]
        for (name, value) in [("ANTHROPIC_MODEL", modelAlias), ("ANTHROPIC_DEFAULT_OPUS_MODEL", opusModel ?? ""),
                              ("ANTHROPIC_DEFAULT_SONNET_MODEL", sonnetModel ?? ""), ("ANTHROPIC_DEFAULT_HAIKU_MODEL", haikuModel ?? "")] {
            let trimmed = value.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty { values[name] = trimmed }
        }
        return values
    }

    /// All configured model names, used to verify them against the gateway.
    public var configuredModels: [String] { Array(Set(modelEnvironment.values)).sorted() }

    /// Names that the extra environment must not set: credentials, endpoint, model fields and provider switches.
    public static let reservedEnvironmentNames: Set<String> = [
        "ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_BASE_URL", "ANTHROPIC_MODEL",
        "ANTHROPIC_DEFAULT_OPUS_MODEL", "ANTHROPIC_DEFAULT_SONNET_MODEL", "ANTHROPIC_DEFAULT_HAIKU_MODEL",
        "CLAUDE_CODE_USE_BEDROCK", "CLAUDE_CODE_USE_VERTEX", "CLAUDE_CODE_USE_FOUNDRY",
    ]

    public static func isAllowedEnvironmentName(_ name: String) -> Bool {
        name.range(of: "^[A-Za-z_][A-Za-z0-9_]*$", options: .regularExpression) != nil && !reservedEnvironmentNames.contains(name)
    }

    /// Parses `NAME=value` lines; returns the valid entries and the lines that were rejected.
    public static func parseEnvironment(_ text: String) -> (values: [String: String], invalidLines: [String]) {
        var values: [String: String] = [:], invalid: [String] = []
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            let parts = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2, isAllowedEnvironmentName(parts[0]) else { invalid.append(line); continue }
            values[parts[0]] = parts[1]
        }
        return (values, invalid)
    }

    public static func formatEnvironment(_ values: [String: String]?) -> String {
        (values ?? [:]).sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "\n")
    }
}

/// Picks the newest-looking model name per tier from a gateway model list (by name, e.g. "sonnet-5" over "sonnet-4-5").
public enum ModelSuggestion {
    public static func suggest(from models: [String]) -> (opus: String?, sonnet: String?, haiku: String?) {
        func best(_ tier: String) -> String? {
            models.filter { $0.lowercased().contains(tier) }.sorted { $0.localizedStandardCompare($1) == .orderedDescending }.first
        }
        return (best("opus"), best("sonnet"), best("haiku"))
    }
}

public struct WorkspaceBinding: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    /// Canonical path of the folder whose `.claude/settings.local.json` Claude Code reads
    /// (the main worktree root for git repositories).
    public var path: String
    public var profileID: UUID
    /// Exactly what the app wrote, keyed by settings key path (e.g. `env.ANTHROPIC_BASE_URL`).
    /// Used for idempotent re-apply and for reverting only app-made changes.
    public var managedValues: [String: String]
    /// Line the app appended to `<git-common-dir>/info/exclude`, if any.
    public var gitExcludeEntry: String?

    public init(id: UUID = UUID(), path: String, profileID: UUID, managedValues: [String: String] = [:], gitExcludeEntry: String? = nil) {
        self.id = id
        self.path = path
        self.profileID = profileID
        self.managedValues = managedValues
        self.gitExcludeEntry = gitExcludeEntry
    }
}

public struct AppState: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1
    public var schemaVersion: Int
    public var profiles: [Profile]
    public var bindings: [WorkspaceBinding]

    public init(profiles: [Profile] = [], bindings: [WorkspaceBinding] = []) {
        self.schemaVersion = AppState.currentSchemaVersion
        self.profiles = profiles
        self.bindings = bindings
    }

    public func profile(_ id: UUID) -> Profile? { profiles.first { $0.id == id } }
}
