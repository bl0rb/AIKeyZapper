import Foundation

/// Contract between Claude Code / the app and `keyzapper-helper`.
///
///     keyzapper-helper credential --profile <UUID>   # key on stdout (no newline), used as apiKeyHelper
///     keyzapper-helper pool       --profile <UUID>   # like credential; once its budget is used up, the key with
///                                                    # the most budget left on the same endpoint (hidden pool mode)
///     keyzapper-helper store      --profile <UUID>   # key on stdin (never as argument)
///     keyzapper-helper status     --profile <UUID>   # exit 0 if a key exists, 66 if not
///     keyzapper-helper delete     --profile <UUID>
///
/// Keys are only released for endpoints allowed by `ManagedConfig.allowedGatewayHosts` (exit 78 otherwise).
/// Messages go to stderr and never contain key material. A failure never falls back to another profile;
/// only `pool` switches to other profiles' keys, and only when the gateway reports the own budget as used up.
public enum HelperExitCode: Int32, Sendable {
    case ok = 0
    case usage = 64
    case unknownProfile = 65
    case missingCredential = 66
    case internalError = 70
    case keychainAccessDenied = 77
    case configError = 78
}

public struct KeyHelperCommand {
    public static let executableName = "keyzapper-helper"

    public struct Output: Equatable {
        public var exitCode: HelperExitCode
        public var stdout: String
        public var stderr: String
    }

    let metadata: MetadataStore
    let store: CredentialStore
    let config: ManagedConfig
    /// Remaining budget of a key at an endpoint (nil = unknown), used by `pool`.
    let remainingBudget: (URL, String) -> Double?

    public init(metadata: MetadataStore, store: CredentialStore, config: ManagedConfig = ManagedConfig(),
                remainingBudget: @escaping (URL, String) -> Double? = { GatewayCheck.remainingBudget(endpoint: $0, key: $1) }) {
        self.metadata = metadata
        self.store = store
        self.config = config
        self.remainingBudget = remainingBudget
    }

    public func run(_ args: [String], stdin: () -> String) -> Output {
        guard args.count == 3, args[1] == "--profile", ["credential", "pool", "store", "status", "delete"].contains(args[0]) else {
            return fail(.usage, L("Aufruf: \(Self.executableName) credential|pool|store|status|delete --profile <UUID>"))
        }
        guard let id = UUID(uuidString: args[2]) else { return fail(.unknownProfile, L("Ungültige Profil-ID: \(args[2])")) }
        let profile: Profile, state: AppState
        do {
            state = try metadata.load()
            guard let p = state.profile(id) else {
                if args[0] == "delete" { return deleteOrphan(id) }
                return fail(.unknownProfile, L("Unbekanntes Profil: \(id.uuidString)"))
            }
            profile = p
        } catch {
            return fail(.configError, error.localizedDescription)
        }
        if ["credential", "pool", "store"].contains(args[0]) && !config.isEndpointAllowed(profile.endpoint) {
            return fail(.configError, L("Endpunkt \(profile.endpoint.host() ?? "?") ist laut Firmenrichtlinie (AllowedGatewayHosts) nicht freigegeben."))
        }
        do {
            switch args[0] {
            case "credential":
                return Output(exitCode: .ok, stdout: try store.read(profile.keychainReference), stderr: "")
            case "pool":
                return Output(exitCode: .ok, stdout: try pooledKey(for: profile, in: state), stderr: "")
            case "store":
                let secret = stdin().trimmingCharacters(in: .whitespacesAndNewlines)
                try store.write(secret, label: "KeyZapper – \(profile.name)", for: profile.keychainReference)
                return Output(exitCode: .ok, stdout: "", stderr: "")
            case "status":
                return try store.exists(profile.keychainReference)
                    ? Output(exitCode: .ok, stdout: "", stderr: "")
                    : fail(.missingCredential, KeyZapperError.missingCredential(id).localizedDescription)
            default:
                try store.delete(profile.keychainReference)
                return Output(exitCode: .ok, stdout: "", stderr: "")
            }
        } catch let error as KeyZapperError {
            return fail(Self.exitCode(for: error), error.localizedDescription)
        } catch {
            return fail(.internalError, error.localizedDescription)
        }
    }

    /// The profile's own key while it has budget left or its budget is unknown, otherwise the key with the most
    /// budget left among the other profiles on the same endpoint (same models and allowlist).
    func pooledKey(for profile: Profile, in state: AppState) throws -> String {
        let own = try store.read(profile.keychainReference)
        guard let ownLeft = remainingBudget(profile.endpoint, own), ownLeft <= 0 else { return own }
        var best: (key: String, left: Double)?
        for other in state.profiles where other.id != profile.id && Self.sameEndpoint(other.endpoint, profile.endpoint) {
            guard let key = try? store.read(other.keychainReference), let left = remainingBudget(other.endpoint, key),
                  left > (best?.left ?? 0) else { continue }
            best = (key, left)
        }
        return best?.key ?? own
    }

    static func sameEndpoint(_ a: URL, _ b: URL) -> Bool {
        func trimmed(_ url: URL) -> Substring {
            let s = url.absoluteString
            return s[..<(s.lastIndex { $0 != "/" }.map(s.index(after:)) ?? s.startIndex)]
        }
        return trimmed(a) == trimmed(b)
    }

    /// Profile already removed from metadata: still allow cleaning up its keychain item.
    private func deleteOrphan(_ id: UUID) -> Output {
        do { try store.delete(CredentialReference(account: id.uuidString)) } catch {
            return fail(.internalError, error.localizedDescription)
        }
        return Output(exitCode: .ok, stdout: "", stderr: "")
    }

    private func fail(_ code: HelperExitCode, _ message: String) -> Output {
        Output(exitCode: code, stdout: "", stderr: "\(Self.executableName): \(message)\n")
    }

    static func exitCode(for error: KeyZapperError) -> HelperExitCode {
        switch error {
        case .unknownProfile: .unknownProfile
        case .missingCredential, .emptyCredential: .missingCredential
        case .keychainLocked, .keychainAccessDenied: .keychainAccessDenied
        case .unsupportedSchemaVersion, .corruptMetadata: .configError
        default: .internalError
        }
    }
}
