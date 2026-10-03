import AISwitchCore
import Foundation
import Observation

/// Runs `aiswitch-key-helper`, the only process that touches the keychain. Keys go via stdin/stdout, never argv.
struct HelperClient: Sendable {
    let url: URL

    static func locate() -> HelperClient? {
        let name = KeyHelperCommand.executableName
        var candidates = [Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/\(name)")]
        if let exe = Bundle.main.executableURL { candidates.append(exe.deletingLastPathComponent().appendingPathComponent(name)) }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }.map(HelperClient.init)
    }

    struct Result: Sendable {
        var code: Int32
        var stdout: String
        var stderr: String
        var message: String { stderr.replacingOccurrences(of: "\(KeyHelperCommand.executableName): ", with: "").trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    func run(_ command: String, _ profile: UUID, stdin: String? = nil) -> Result {
        let process = Process()
        process.executableURL = url
        process.arguments = [command, "--profile", profile.uuidString]
        let out = Pipe(), err = Pipe(), inp = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = inp
        do { try process.run() } catch {
            return Result(code: HelperExitCode.internalError.rawValue, stdout: "", stderr: error.localizedDescription)
        }
        if let stdin { inp.fileHandleForWriting.write(Data(stdin.utf8)) }
        try? inp.fileHandleForWriting.close()
        let o = out.fileHandleForReading.readDataToEndOfFile()
        let e = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return Result(code: process.terminationStatus, stdout: String(decoding: o, as: UTF8.self), stderr: String(decoding: e, as: UTF8.self))
    }
}

@MainActor @Observable
final class AppModel {
    private(set) var state = AppState()
    private(set) var keyPresent: [UUID: Bool] = [:]
    private(set) var statuses: [UUID: BindingStatus] = [:]
    private(set) var outdatedCLIs: [String] = []
    var errorMessage: String?
    var notice: String?

    private let metadata = MetadataStore()
    /// Set when metadata could not be read (e.g. newer schema); saving is blocked to avoid data loss.
    private var metadataUnreadable = false
    let helper = HelperClient.locate()
    private var binder: ClaudeSettingsBinder? { helper.map { ClaudeSettingsBinder(helperPath: $0.url.path) } }

    init() {
        do { state = try metadata.load() } catch {
            metadataUnreadable = true
            errorMessage = error.localizedDescription
        }
        refresh()
        Task {
            let outdated = await Task.detached { ClaudeCLI.outdatedInstallations().map { "\($0.path) (\($0.version))" } }.value
            outdatedCLIs = outdated
        }
    }

    func profileName(_ id: UUID) -> String { state.profile(id)?.name ?? "Unbekanntes Profil" }

    func refresh() {
        guard let helper, let binder else {
            errorMessage = "Hilfsprogramm \(KeyHelperCommand.executableName) wurde nicht gefunden. Bitte App neu installieren."
            return
        }
        for profile in state.profiles { keyPresent[profile.id] = helper.run("status", profile.id).code == HelperExitCode.ok.rawValue }
        for binding in state.bindings {
            if let profile = state.profile(binding.profileID) { statuses[binding.id] = binder.inspect(binding, profile: profile) }
        }
    }

    // MARK: Profiles

    @discardableResult
    func saveProfile(_ profile: Profile, newKey: String?) -> Bool {
        let old = state.profile(profile.id)
        if let i = state.profiles.firstIndex(where: { $0.id == profile.id }) { state.profiles[i] = profile } else { state.profiles.append(profile) }
        guard persist() else { return false }
        if let newKey, !newKey.isEmpty { storeKey(newKey, for: profile) }
        if let old, old.endpoint != profile.endpoint || old.modelAlias != profile.modelAlias {
            for binding in state.bindings where binding.profileID == profile.id { apply(profile, folder: binding.path, previous: binding) }
        }
        refresh()
        return true
    }

    func storeKey(_ key: String, for profile: Profile) {
        guard let helper else { return }
        let result = helper.run("store", profile.id, stdin: key)
        if result.code == HelperExitCode.ok.rawValue {
            notice = "Key für „\(profile.name)“ gespeichert. Neue Claude-Sitzungen verwenden ihn sofort, laufende nach Ablauf des Helper-Caches (Standard 5 min), nach einem 401 oder nach Neustart."
        } else {
            errorMessage = result.message
        }
        refresh()
    }

    func deleteProfile(_ profile: Profile) {
        for binding in state.bindings where binding.profileID == profile.id {
            guard unbind(binding) else { return }
        }
        guard let helper else { return }
        let result = helper.run("delete", profile.id)
        guard result.code == HelperExitCode.ok.rawValue else { errorMessage = result.message; return }
        state.profiles.removeAll { $0.id == profile.id }
        keyPresent[profile.id] = nil
        persist()
    }

    func testConnection(_ profile: Profile) async -> GatewayCheckResult? {
        guard let helper else { return nil }
        let result = await Task.detached { helper.run("credential", profile.id) }.value
        guard result.code == HelperExitCode.ok.rawValue else { errorMessage = result.message; return nil }
        return await GatewayCheck.run(endpoint: profile.endpoint, key: result.stdout, modelAlias: profile.modelAlias)
    }

    // MARK: Bindings

    func bind(folder: String, to profileID: UUID) {
        guard let profile = state.profile(profileID) else { return }
        let root = ClaudeSettingsBinder.settingsRoot(for: folder)
        apply(profile, folder: root, previous: state.bindings.first { $0.path == root })
        refresh()
    }

    func reapply(_ binding: WorkspaceBinding) {
        guard let profile = state.profile(binding.profileID) else { return }
        apply(profile, folder: binding.path, previous: binding)
        refresh()
    }

    @discardableResult
    func unbind(_ binding: WorkspaceBinding) -> Bool {
        guard let binder else { return false }
        do {
            let kept = try binder.revert(binding)
            state.bindings.removeAll { $0.id == binding.id }
            statuses[binding.id] = nil
            persist()
            notice = kept.isEmpty
                ? "Zuordnung für „\(Self.folderName(binding.path))“ entfernt. Laufende Claude-Sitzungen dort bitte neu starten."
                : "Zuordnung entfernt. Außerhalb der App geänderte Einträge wurden beibehalten: \(kept.joined(separator: ", "))"
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    @discardableResult
    private func apply(_ profile: Profile, folder: String, previous: WorkspaceBinding?) -> Bool {
        guard let binder else { return false }
        do {
            let result = try binder.apply(profile: profile, folder: folder, previous: previous)
            if let i = state.bindings.firstIndex(where: { $0.id == result.binding.id }) { state.bindings[i] = result.binding } else { state.bindings.append(result.binding) }
            persist()
            notice = result.changed
                ? "„\(Self.folderName(folder))“ verwendet jetzt Profil „\(profile.name)“. Laufende Claude-Sitzungen in diesem Projekt bitte neu starten."
                : "„\(Self.folderName(folder))“ ist bereits eingerichtet – keine Änderungen."
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    @discardableResult
    private func persist() -> Bool {
        guard !metadataUnreadable else {
            errorMessage = "Metadaten konnten nicht gelesen werden; Änderungen werden nicht gespeichert."
            return false
        }
        do { try metadata.save(state); return true } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    static func folderName(_ path: String) -> String { URL(fileURLWithPath: path).lastPathComponent }
}
