import AppKit
import KeyZapperCore
import Observation

/// Runs `keyzapper-helper`, the only process that touches the keychain. Keys go via stdin/stdout, never argv.
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
    /// Masked key per profile (`••••` + last 4 characters) so the assignment is visible; never the full key.
    private(set) var keyHints: [UUID: String] = [:]
    private(set) var availableUpdate: ReleaseInfo?
    private(set) var isInstallingUpdate = false
    /// Nil for development builds without an app bundle.
    let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    private(set) var statuses: [UUID: BindingStatus] = [:]
    private(set) var outdatedCLIs: [String] = []
    /// Unrestored OneDrive backup found on a fresh install; while set, the backup is not overwritten.
    private(set) var availableBackup: AppState?
    private(set) var backupProblem: String?
    var errorMessage: String?
    var notice: String?

    let config = ManagedConfig.load()
    private let backupDirectory: URL?
    var minimumCLIVersion: String { config.minimumClaudeCodeVersion ?? ClaudeCLI.minimumTestedVersion }

    private let metadata = MetadataStore()
    /// Set when metadata could not be read (e.g. newer schema); saving is blocked to avoid data loss.
    private var metadataUnreadable = false
    let helper = HelperClient.locate()
    private var binder: ClaudeSettingsBinder? { helper.map { ClaudeSettingsBinder(helperPath: $0.url.path) } }

    init() {
        backupDirectory = BackupStore.directory(for: config)
        do { state = try metadata.load() } catch {
            metadataUnreadable = true
            errorMessage = error.localizedDescription
        }
        if config.oneDriveBackup || config.backupDirectory != nil {
            if let backupDirectory {
                if state.profiles.isEmpty, let backup = try? BackupStore(directory: backupDirectory).read(), !backup.profiles.isEmpty {
                    availableBackup = backup
                }
            } else {
                backupProblem = "OneDrive-Backup ist aktiviert, aber es wurde kein OneDrive-Ordner gefunden. Bitte in OneDrive anmelden."
            }
        }
        syncManagedProfiles()
        refresh()
        let minimum = minimumCLIVersion
        Task { await checkForUpdates(userInitiated: false) }
        Task {
            let outdated = await Task.detached { ClaudeCLI.outdatedInstallations(minimum: minimum).map { "\(($0.path as NSString).abbreviatingWithTildeInPath) \($0.version)" } }.value
            outdatedCLIs = outdated
        }
    }

    func profileName(_ id: UUID) -> String { state.profile(id)?.name ?? "Unbekanntes Profil" }

    func isManaged(_ id: UUID) -> Bool { config.profiles.contains { $0.id == id } }

    /// Creates/updates the profiles IT defines via `ManagedProfiles`; developers only add their key.
    private func syncManagedProfiles() {
        for managed in config.profiles {
            var profile = state.profile(managed.id) ?? Profile(id: managed.id, name: managed.name, endpoint: managed.endpoint, modelAlias: managed.modelAlias)
            profile.name = managed.name
            profile.endpoint = managed.endpoint
            profile.modelAlias = managed.modelAlias
            if state.profile(managed.id) != profile { saveProfile(profile, newKey: nil) }
        }
    }

    func refresh() {
        guard let helper, let binder else {
            errorMessage = "Hilfsprogramm \(KeyHelperCommand.executableName) wurde nicht gefunden. Bitte App neu installieren."
            return
        }
        for profile in state.profiles {
            let result = helper.run("credential", profile.id)
            keyPresent[profile.id] = result.code != HelperExitCode.missingCredential.rawValue
            keyHints[profile.id] = result.code == HelperExitCode.ok.rawValue ? "••••" + String(result.stdout.suffix(4)) : nil
        }
        for binding in state.bindings {
            if let profile = state.profile(binding.profileID) { statuses[binding.id] = binder.inspect(binding, profile: profile) }
        }
    }

    // MARK: Profiles

    @discardableResult
    func saveProfile(_ profile: Profile, newKey: String?) -> Bool {
        guard config.isEndpointAllowed(profile.endpoint) else {
            errorMessage = "Der Endpunkt \(profile.endpoint.host() ?? "") ist laut Firmenrichtlinie nicht freigegeben. Erlaubt: \(config.allowedGatewayHosts.joined(separator: ", "))"
            return false
        }
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
        keyHints[profile.id] = nil
        persist()
    }

    /// Copies the key marked as concealed (ignored by clipboard managers) and clears it after 60 s if unchanged.
    func copyKey(_ profile: Profile) {
        guard let helper else { return }
        let result = helper.run("credential", profile.id)
        guard result.code == HelperExitCode.ok.rawValue else { errorMessage = result.message; return }
        let pasteboard = NSPasteboard.general
        let concealed = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
        pasteboard.declareTypes([.string, concealed], owner: nil)
        pasteboard.setString(result.stdout, forType: .string)
        pasteboard.setString("", forType: concealed)
        let changeCount = pasteboard.changeCount
        notice = "Key von „\(profile.name)“ kopiert. Er wird nach 60 Sekunden aus der Zwischenablage entfernt."
        Task {
            try? await Task.sleep(for: .seconds(60))
            if NSPasteboard.general.changeCount == changeCount { NSPasteboard.general.clearContents() }
        }
    }

    // MARK: Updates (GitHub releases)

    func checkForUpdates(userInitiated: Bool) async {
        guard config.updateCheckEnabled else {
            if userInitiated { notice = "Updates werden von der IT verteilt; die Update-Prüfung ist abgeschaltet." }
            return
        }
        guard let appVersion else {
            if userInitiated { notice = "Entwicklungsversion – keine Update-Prüfung." }
            return
        }
        do {
            let release = try await UpdateChecker.latestRelease()
            if UpdateChecker.isNewer(release.version, than: appVersion) {
                availableUpdate = release
            } else if userInitiated {
                notice = "KeyZapper \(appVersion) ist aktuell."
            }
        } catch {
            if userInitiated { errorMessage = "Update-Prüfung fehlgeschlagen: \(error.localizedDescription)" }
        }
    }

    /// Downloads and verifies the package, then hands it to the macOS installer (admin rights required).
    func installUpdate() async {
        guard let release = availableUpdate, !isInstallingUpdate else { return }
        isInstallingUpdate = true
        defer { isInstallingUpdate = false }
        do {
            let package = try await UpdateChecker.downloadPackage(release)
            NSWorkspace.shared.open(package)
            notice = "Installer für KeyZapper \(release.version) geöffnet. Nach der Installation KeyZapper neu starten."
            availableUpdate = nil
        } catch {
            errorMessage = "Update konnte nicht geladen werden: \(error.localizedDescription)"
        }
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
        do { try metadata.save(state) } catch {
            errorMessage = error.localizedDescription
            return false
        }
        writeBackup()
        return true
    }

    // MARK: OneDrive backup (profiles and bindings only, never keys)

    private func writeBackup() {
        guard let backupDirectory, availableBackup == nil else { return }
        do {
            try BackupStore(directory: backupDirectory).write(state)
            backupProblem = nil
        } catch {
            backupProblem = "OneDrive-Backup fehlgeschlagen: \(error.localizedDescription)"
        }
    }

    func restoreFromBackup() {
        guard let backup = availableBackup else { return }
        for profile in backup.profiles where state.profile(profile.id) == nil { state.profiles.append(profile) }
        availableBackup = nil
        guard persist() else { return }
        var restored = 0
        for binding in backup.bindings {
            guard let profile = state.profile(binding.profileID), FileManager.default.fileExists(atPath: binding.path),
                  apply(profile, folder: binding.path, previous: binding) else { continue }
            restored += 1
        }
        let skipped = backup.bindings.count - restored
        refresh()
        notice = "Backup wiederhergestellt: \(backup.profiles.count) Profil(e), \(restored) Projekt(e)"
            + (skipped > 0 ? ", \(skipped) übersprungen (Ordner fehlt oder Konflikt)" : "")
            + ". Keys werden nicht gesichert – bitte je Profil neu eintragen."
    }

    func discardBackup() {
        availableBackup = nil
        writeBackup()
    }

    static func folderName(_ path: String) -> String { URL(fileURLWithPath: path).lastPathComponent }
}
