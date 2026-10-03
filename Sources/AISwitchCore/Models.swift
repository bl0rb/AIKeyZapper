import Foundation

/// Points to the keychain item holding a profile's LiteLLM key. The key itself never leaves the keychain
/// except through `aiswitch-key-helper credential`.
public struct CredentialReference: Codable, Hashable, Sendable {
    public static let defaultService = "ProjectAISwitch.LiteLLM"
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
    public var credential: CredentialReference

    public init(id: UUID = UUID(), name: String, endpoint: URL, modelAlias: String) {
        self.id = id
        self.name = name
        self.endpoint = endpoint
        self.modelAlias = modelAlias
        self.credential = CredentialReference(account: id.uuidString)
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
