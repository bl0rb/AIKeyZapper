import Foundation

/// Contract between Claude Code / the app and `keyzapper-helper`.
///
///     keyzapper-helper credential --profile <UUID>   # key on stdout (no newline), used as apiKeyHelper
///     keyzapper-helper store      --profile <UUID>   # key on stdin (never as argument)
///     keyzapper-helper status     --profile <UUID>   # exit 0 if a key exists, 66 if not
///     keyzapper-helper delete     --profile <UUID>
///
/// Keys are only released for endpoints allowed by `ManagedConfig.allowedGatewayHosts` (exit 78 otherwise).
/// Messages go to stderr and never contain key material. A failure never falls back to another profile.
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

    public init(metadata: MetadataStore, store: CredentialStore, config: ManagedConfig = ManagedConfig()) {
        self.metadata = metadata
        self.store = store
        self.config = config
    }

    public func run(_ args: [String], stdin: () -> String) -> Output {
        guard args.count == 3, args[1] == "--profile", ["credential", "store", "status", "delete"].contains(args[0]) else {
            return fail(.usage, L("Aufruf: \(Self.executableName) credential|store|status|delete --profile <UUID>"))
        }
        guard let id = UUID(uuidString: args[2]) else { return fail(.unknownProfile, L("Ungültige Profil-ID: \(args[2])")) }
        let profile: Profile
        do {
            guard let p = try metadata.load().profile(id) else {
                if args[0] == "delete" { return deleteOrphan(id) }
                return fail(.unknownProfile, L("Unbekanntes Profil: \(id.uuidString)"))
            }
            profile = p
        } catch {
            return fail(.configError, error.localizedDescription)
        }
        if ["credential", "store"].contains(args[0]) && !config.isEndpointAllowed(profile.endpoint) {
            return fail(.configError, L("Endpunkt \(profile.endpoint.host() ?? "?") ist laut Firmenrichtlinie (AllowedGatewayHosts) nicht freigegeben."))
        }
        do {
            switch args[0] {
            case "credential":
                return Output(exitCode: .ok, stdout: try store.read(profile.keychainReference), stderr: "")
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
