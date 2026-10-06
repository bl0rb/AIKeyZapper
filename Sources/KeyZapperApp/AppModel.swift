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
    /// Budget per profile as reported by the gateway; missing while unknown (no key, gateway unreachable).
    private(set) var budgets: [UUID: KeyBudget] = [:]
    private(set) var availableUpdate: ReleaseInfo?
    /// Findings of the logical check of `~/.claude/settings.json`.
    private(set) var globalFindings: [SettingsFinding] = []
    /// State of the default profile in `~/.claude/settings.json`, nil if none is set.
    private(set) var globalHealth: BindingHealth?
    var isDisabled: Bool { state.disabled == true }
    var userSettingsPath: String { binder?.userSettingsPath ?? canonicalPath("~/.claude/settings.json") }
    private var refreshGeneration = 0
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
                backupProblem = L("OneDrive-Backup ist aktiviert, aber es wurde kein OneDrive-Ordner gefunden. Bitte in OneDrive anmelden.")
            }
        }
        syncManagedProfiles()
        refresh()
        refreshBudgets()
        let minimum = minimumCLIVersion
        Task { await checkForUpdates(userInitiated: false) }
        Task {
            let outdated = await Task.detached { ClaudeCLI.outdatedInstallations(minimum: minimum).map { "\(($0.path as NSString).abbreviatingWithTildeInPath) \($0.version)" } }.value
            outdatedCLIs = outdated
        }
    }

    func profileName(_ id: UUID) -> String { state.profile(id)?.name ?? L("Unbekanntes Profil") }

    func isManaged(_ id: UUID) -> Bool { config.profiles.contains { $0.id == id } }

    /// Creates/updates the profiles IT defines via `ManagedProfiles`; developers only add their key.
    private func syncManagedProfiles() {
        for managed in config.profiles {
            var profile = state.profile(managed.id) ?? Profile(id: managed.id, name: managed.name, endpoint: managed.endpoint, modelAlias: managed.modelAlias)
            profile.name = managed.name
            profile.endpoint = managed.endpoint
            profile.modelAlias = managed.modelAlias
            profile.opusModel = managed.opusModel
            profile.sonnetModel = managed.sonnetModel
            profile.haikuModel = managed.haikuModel
            profile.environment = managed.environment
            if state.profile(managed.id) != profile { saveProfile(profile, newKey: nil) }
        }
    }

    /// Recomputes key presence, project status and the settings check off the main thread; the newest run wins.
    func refresh() {
        guard let helper, let binder else {
            errorMessage = L("Hilfsprogramm \(KeyHelperCommand.executableName) wurde nicht gefunden. Bitte App neu installieren.")
            return
        }
        refreshGeneration += 1
        let generation = refreshGeneration, state = self.state, knownHints = keyHints
        Task {
            let snapshot = await Task.detached { Self.status(of: state, helper: helper, binder: binder, knownHints: knownHints) }.value
            guard generation == refreshGeneration else { return }
            keyPresent = snapshot.keyPresent
            keyHints = snapshot.keyHints
            statuses = snapshot.statuses
            globalHealth = snapshot.globalHealth
            globalFindings = snapshot.globalFindings
        }
    }

    struct StatusSnapshot: Sendable {
        var keyPresent: [UUID: Bool] = [:]
        var keyHints: [UUID: String] = [:]
        var statuses: [UUID: BindingStatus] = [:]
        var globalHealth: BindingHealth?
        var globalFindings: [SettingsFinding] = []
    }

    /// Key presence via `status` (no secret read); the masked hint is read once per profile and then cached.
    nonisolated static func status(of state: AppState, helper: HelperClient, binder: ClaudeSettingsBinder,
                                   knownHints: [UUID: String]) -> StatusSnapshot {
        var snapshot = StatusSnapshot()
        for profile in state.profiles {
            let present = helper.run("status", profile.id).code != HelperExitCode.missingCredential.rawValue
            snapshot.keyPresent[profile.id] = present
            guard present else { continue }
            if let hint = knownHints[profile.id] {
                snapshot.keyHints[profile.id] = hint
            } else {
                let result = helper.run("credential", profile.id)
                if result.code == HelperExitCode.ok.rawValue { snapshot.keyHints[profile.id] = maskedHint(result.stdout) }
            }
        }
        let globalValues = state.globalBinding?.managedValues ?? [:]
        if state.disabled != true {
            for binding in state.bindings {
                if let profile = state.profile(binding.profileID) {
                    snapshot.statuses[binding.id] = binder.inspect(binding, profile: profile, globalValues: globalValues)
                }
            }
            if let global = state.globalBinding, let profile = state.profile(global.profileID) {
                snapshot.globalHealth = binder.inspectGlobal(global, profile: profile)
            }
        }
        snapshot.globalFindings = GlobalSettingsAudit.check(path: binder.userSettingsPath, globalValues: globalValues)
        return snapshot
    }

    nonisolated static func maskedHint(_ key: String) -> String { "••••" + String(key.suffix(4)) }

    /// Loads the budget of every stored key from the gateway (LiteLLM `/key/info`).
    func refreshBudgets() {
        for profile in state.profiles { refreshBudget(profile) }
    }

    func refreshBudget(_ profile: Profile) {
        guard let helper else { return }
        Task {
            let result = await Task.detached { helper.run("credential", profile.id) }.value
            guard result.code == HelperExitCode.ok.rawValue else { budgets[profile.id] = nil; return }
            budgets[profile.id] = try? await GatewayCheck.budget(endpoint: profile.endpoint, key: result.stdout).get()
        }
    }

    // MARK: Profiles

    @discardableResult
    func saveProfile(_ profile: Profile, newKey: String?) -> Bool {
        guard config.isEndpointAllowed(profile.endpoint) else {
            errorMessage = L("Der Endpunkt \(profile.endpoint.host() ?? "") ist laut Firmenrichtlinie nicht freigegeben. Erlaubt: \(config.allowedGatewayHosts.joined(separator: ", "))")
            return false
        }
        let old = state.profile(profile.id)
        if let i = state.profiles.firstIndex(where: { $0.id == profile.id }) { state.profiles[i] = profile } else { state.profiles.append(profile) }
        guard persist() else { return false }
        if let newKey, !newKey.isEmpty { storeKey(newKey, for: profile) }
        if let old, old != profile, !isDisabled {
            for binding in state.bindings where binding.profileID == profile.id { apply(profile, folder: binding.path, previous: binding) }
            if let global = state.globalBinding, global.profileID == profile.id { applyGlobal(profile, previous: global) }
        }
        refresh()
        return true
    }

    func storeKey(_ key: String, for profile: Profile) {
        guard let helper else { return }
        let result = helper.run("store", profile.id, stdin: key)
        if result.code == HelperExitCode.ok.rawValue {
            keyHints[profile.id] = Self.maskedHint(key.trimmingCharacters(in: .whitespacesAndNewlines))
            refreshBudget(profile)
            notice = L("Key für „\(profile.name)“ gespeichert. Neue Claude-Sitzungen verwenden ihn sofort, laufende nach Ablauf des Helper-Caches (Standard 5 min), nach einem 401 oder nach Neustart.")
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
        if let global = state.globalBinding, global.profileID == profile.id {
            _ = try? binder?.revertGlobal(global)
            state.globalBinding = nil
        }
        state.profiles.removeAll { $0.id == profile.id }
        keyPresent[profile.id] = nil
        keyHints[profile.id] = nil
        persist()
    }

    /// Copies the key marked as concealed (ignored by clipboard managers) and clears it after 60 s if unchanged.
    func copyKey(_ profile: Profile) {
        guard config.allowKeyExport else {
            errorMessage = L("Das Kopieren von Keys ist laut Firmenrichtlinie (AllowKeyExport) deaktiviert.")
            return
        }
        guard let helper else { return }
        let result = helper.run("credential", profile.id)
        guard result.code == HelperExitCode.ok.rawValue else { errorMessage = result.message; return }
        let pasteboard = NSPasteboard.general
        let concealed = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
        pasteboard.declareTypes([.string, concealed], owner: nil)
        pasteboard.setString(result.stdout, forType: .string)
        pasteboard.setString("", forType: concealed)
        let changeCount = pasteboard.changeCount
        notice = L("Key von „\(profile.name)“ kopiert. Er wird nach 60 Sekunden aus der Zwischenablage entfernt.")
        Task {
            try? await Task.sleep(for: .seconds(60))
            if NSPasteboard.general.changeCount == changeCount { NSPasteboard.general.clearContents() }
        }
    }

    // MARK: Updates (GitHub releases)

    func checkForUpdates(userInitiated: Bool) async {
        guard config.updateCheckEnabled else {
            if userInitiated { notice = L("Updates werden von der IT verteilt; die Update-Prüfung ist abgeschaltet.") }
            return
        }
        guard let appVersion else {
            if userInitiated { notice = L("Entwicklungsversion – keine Update-Prüfung.") }
            return
        }
        do {
            let release = try await UpdateChecker.latestRelease()
            if UpdateChecker.isNewer(release.version, than: appVersion) {
                availableUpdate = release
            } else if userInitiated {
                notice = L("KeyZapper \(appVersion) ist aktuell.")
            }
        } catch {
            if userInitiated { errorMessage = L("Update-Prüfung fehlgeschlagen: \(error.localizedDescription)") }
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
            notice = L("Installer für KeyZapper \(release.version) geöffnet. Nach der Installation KeyZapper neu starten.")
            availableUpdate = nil
        } catch {
            errorMessage = L("Update konnte nicht geladen werden: \(error.localizedDescription)")
        }
    }

    func testConnection(_ profile: Profile) async -> GatewayCheckResult? {
        guard let helper else { return nil }
        let result = await Task.detached { helper.run("credential", profile.id) }.value
        guard result.code == HelperExitCode.ok.rawValue else { errorMessage = result.message; return nil }
        refreshBudget(profile)
        return await GatewayCheck.run(endpoint: profile.endpoint, key: result.stdout, models: profile.configuredModels)
    }

    /// Lists the gateway's model names for a key: the one typed in the editor, else the stored key of the profile.
    func availableModels(endpoint: URL, typedKey: String, profileID: UUID?) async -> [String]? {
        guard config.isEndpointAllowed(endpoint) else {
            errorMessage = L("Der Endpunkt \(endpoint.host() ?? "") ist laut Firmenrichtlinie nicht freigegeben. Erlaubt: \(config.allowedGatewayHosts.joined(separator: ", "))")
            return nil
        }
        var key = typedKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if key.isEmpty, let profileID, let helper {
            let result = await Task.detached { helper.run("credential", profileID) }.value
            guard result.code == HelperExitCode.ok.rawValue else { errorMessage = result.message; return nil }
            key = result.stdout
        }
        guard !key.isEmpty else { errorMessage = L("Für den Modellabruf wird ein Key benötigt."); return nil }
        switch await GatewayCheck.models(endpoint: endpoint, key: key) {
        case .success(let models):
            if models.isEmpty { errorMessage = L("Das Gateway hat keine Modelle für diesen Key gemeldet.") }
            return models
        case .failure(let failure):
            errorMessage = failure.result.message
            return nil
        }
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

    /// Projects whose Budget-Killer may burn this profile's key: pooled bindings of other profiles on the same endpoint.
    func budgetKillers(burning profile: Profile) -> [WorkspaceBinding] {
        guard !isDisabled else { return [] }
        return state.bindings.filter { binding in
            binding.pooled == true && binding.profileID != profile.id
                && state.profile(binding.profileID).map { KeyHelperCommand.sameEndpoint($0.endpoint, profile.endpoint) } == true
        }
    }

    /// Hidden Budget-Killer: switches a project between its own key and the pool of all keys on the same endpoint.
    func togglePool(_ binding: WorkspaceBinding) {
        guard let profile = state.profile(binding.profileID) else { return }
        let pooled = binding.pooled != true
        guard apply(profile, folder: binding.path, previous: binding, pooled: pooled) else { return }
        notice = pooled
            ? L("Budget-Killer für „\(Self.folderName(binding.path))“ aktiv: Ist das Budget von „\(profile.name)“ verbraucht, verbrennt Claude die Keys der anderen Profile am selben Gateway. Laufende Claude-Sitzungen bitte neu starten.")
            : L("Budget-Killer für „\(Self.folderName(binding.path))“ aus: Claude nutzt nur noch den Key von „\(profile.name)“. Laufende Claude-Sitzungen bitte neu starten.")
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
                ? L("Zuordnung für „\(Self.folderName(binding.path))“ entfernt. Laufende Claude-Sitzungen dort bitte neu starten.")
                : L("Zuordnung entfernt. Außerhalb der App geänderte Einträge wurden beibehalten: \(kept.joined(separator: ", "))")
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    @discardableResult
    private func apply(_ profile: Profile, folder: String, previous: WorkspaceBinding?, pooled: Bool? = nil) -> Bool {
        guard let binder else { return false }
        guard !isDisabled else {
            errorMessage = L("KeyZapper ist deaktiviert. Bitte zuerst wieder aktivieren.")
            return false
        }
        do {
            let result = try binder.apply(profile: profile, folder: folder, previous: previous, pooled: pooled ?? (previous?.pooled == true))
            if let i = state.bindings.firstIndex(where: { $0.id == result.binding.id }) { state.bindings[i] = result.binding } else { state.bindings.append(result.binding) }
            persist()
            notice = result.changed
                ? L("„\(Self.folderName(folder))“ verwendet jetzt Profil „\(profile.name)“. Laufende Claude-Sitzungen in diesem Projekt bitte neu starten.")
                : L("„\(Self.folderName(folder))“ ist bereits eingerichtet – keine Änderungen.")
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    @discardableResult
    private func persist() -> Bool {
        guard !metadataUnreadable else {
            errorMessage = L("Metadaten konnten nicht gelesen werden; Änderungen werden nicht gespeichert.")
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
            backupProblem = L("OneDrive-Backup fehlgeschlagen: \(error.localizedDescription)")
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
        notice = L("Backup wiederhergestellt: \(String(backup.profiles.count)) Profil(e), \(String(restored)) Projekt(e)")
            + (skipped > 0 ? L(", \(String(skipped)) übersprungen (Ordner fehlt oder Konflikt)") : "")
            + L(". Keys werden nicht gesichert – bitte je Profil neu eintragen.")
    }

    // MARK: Encrypted backup file (keys and settings)

    enum BackupSheet: String, Identifiable {
        case export, `import`
        var id: String { rawValue }
    }

    var backupSheet: BackupSheet?

    /// Writes profiles, assignments and (unless IT forbids it) the keys into a password-encrypted `.kzbackup` file.
    func exportBackup(password: String, to url: URL) async -> Bool {
        guard let helper else { return false }
        var keys: [String: String] = [:]
        if config.allowKeyExport {
            for profile in state.profiles {
                let result = helper.run("credential", profile.id)
                if result.code == HelperExitCode.ok.rawValue { keys[profile.id.uuidString] = result.stdout }
            }
        }
        let payload = BackupPayload(appVersion: appVersion, state: state, keys: keys)
        do {
            let data = try await Task.detached { try EncryptedBackup.seal(payload, password: password) }.value
            try data.write(to: url, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            let profileCount = state.profiles.count, keyCount = keys.count, projectCount = state.bindings.count
            notice = L("Verschlüsseltes Backup gespeichert: \(String(profileCount)) Profil(e), \(String(keyCount)) Key(s), \(String(projectCount)) Projekt(e).")
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    /// Restores profiles and keys from an encrypted backup and re-assigns projects whose folders exist on this Mac.
    func importBackup(from url: URL, password: String) async -> Bool {
        guard let helper else { return false }
        guard !isDisabled else {
            errorMessage = L("KeyZapper ist deaktiviert. Bitte zuerst wieder aktivieren.")
            return false
        }
        let payload: BackupPayload
        do {
            let data = try Data(contentsOf: url)
            payload = try await Task.detached { try EncryptedBackup.open(data, password: password) }.value
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
        var skippedCount = 0
        var changedProfiles: Set<UUID> = []
        for var profile in payload.state.profiles {
            guard config.isEndpointAllowed(profile.endpoint) else { skippedCount += 1; continue }
            profile.credential = profile.keychainReference
            if let i = state.profiles.firstIndex(where: { $0.id == profile.id }) {
                if !isManaged(profile.id) && state.profiles[i] != profile {
                    state.profiles[i] = profile
                    changedProfiles.insert(profile.id)
                }
            } else {
                state.profiles.append(profile)
            }
        }
        guard persist() else { return false }
        var keyCount = 0
        for (id, key) in payload.keys {
            guard let uuid = UUID(uuidString: id), state.profile(uuid) != nil else { continue }
            if helper.run("store", uuid, stdin: key).code == HelperExitCode.ok.rawValue {
                keyCount += 1
                keyHints[uuid] = Self.maskedHint(key)
            }
        }
        var projectCount = 0
        for binding in payload.state.bindings {
            guard let profile = state.profile(binding.profileID), FileManager.default.fileExists(atPath: binding.path) else {
                skippedCount += 1
                continue
            }
            let previous = state.bindings.first { $0.path == binding.path } ?? binding
            if apply(profile, folder: binding.path, previous: previous) { projectCount += 1 } else { skippedCount += 1 }
        }
        // Existing assignments of profiles the backup changed must pick up the new endpoint and models too.
        let importedPaths = Set(payload.state.bindings.map(\.path))
        for binding in state.bindings where changedProfiles.contains(binding.profileID) && !importedPaths.contains(binding.path) {
            if let profile = state.profile(binding.profileID) { apply(profile, folder: binding.path, previous: binding) }
        }
        if let global = state.globalBinding, changedProfiles.contains(global.profileID), let profile = state.profile(global.profileID) {
            applyGlobal(profile, previous: global)
        }
        refresh()
        let profileCount = payload.state.profiles.count
        notice = L("Backup importiert: \(String(profileCount)) Profil(e), \(String(keyCount)) Key(s), \(String(projectCount)) Projekt(e).")
            + (skippedCount > 0 ? L(" \(String(skippedCount)) Eintrag/Einträge übersprungen (Ordner fehlt, Konflikt oder nicht freigegebener Endpunkt).") : "")
        return true
    }

    // MARK: ~/.claude/settings.json (default profile, repair) and deactivation

    /// Sets (or with nil removes) the default profile in `~/.claude/settings.json` for folders without assignment.
    func setGlobalProfile(_ profileID: UUID?) {
        guard let binder else { return }
        guard !isDisabled else { errorMessage = L("KeyZapper ist deaktiviert. Bitte zuerst wieder aktivieren."); return }
        if let profileID, let profile = state.profile(profileID) {
            let backup = state.globalBinding == nil ? try? binder.backupUserSettings() : nil
            if applyGlobal(profile, previous: state.globalBinding) {
                notice = L("Standardprofil „\(profile.name)“ in ~/.claude/settings.json eingetragen. Es gilt für alle Ordner ohne eigene Zuordnung.")
                    + (backup.map { L(" Sicherung: \($0.lastPathComponent)") } ?? "")
            }
        } else if let global = state.globalBinding {
            do {
                try binder.revertGlobal(global)
                state.globalBinding = nil
                persist()
                notice = L("Standardprofil aus ~/.claude/settings.json entfernt.")
            } catch { errorMessage = error.localizedDescription }
        }
        refresh()
    }

    @discardableResult
    private func applyGlobal(_ profile: Profile, previous: WorkspaceBinding?) -> Bool {
        guard let binder else { return false }
        do {
            state.globalBinding = try binder.applyGlobal(profile: profile, previous: previous).binding
            persist()
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    /// Backs up and cleans `~/.claude/settings.json` (valid JSON, no plaintext keys) or creates it.
    func repairUserSettings() {
        guard let binder else { return }
        do {
            let backup = try binder.repairUserSettings()
            if !isDisabled, let global = state.globalBinding, let profile = state.profile(global.profileID) {
                applyGlobal(profile, previous: global)
            }
            notice = L("~/.claude/settings.json ist jetzt gültig und frei von Klartext-Keys.")
                + (backup.map { L(" Sicherung: \($0.lastPathComponent)") } ?? "")
        } catch {
            errorMessage = error.localizedDescription
        }
        refresh()
    }

    /// Deactivation removes KeyZapper's values from all projects and the user settings but keeps the assignments,
    /// so activating writes them again. Claude Code meanwhile uses its normal login everywhere.
    func setDisabled(_ disable: Bool) {
        guard let binder, disable != isDisabled else { return }
        if disable {
            var failed: [String] = []
            for binding in state.bindings {
                do { try binder.revert(binding) } catch { failed.append(Self.folderName(binding.path)) }
            }
            if let global = state.globalBinding { _ = try? binder.revertGlobal(global) }
            state.disabled = true
            persist()
            notice = L("KeyZapper ist deaktiviert. Claude Code nutzt jetzt überall die normale Anmeldung; laufende Sitzungen bitte neu starten.")
            if !failed.isEmpty { errorMessage = L("Diese Projekte konnten nicht zurückgesetzt werden: \(failed.joined(separator: ", "))") }
        } else {
            state.disabled = nil
            persist()
            for binding in state.bindings {
                if let profile = state.profile(binding.profileID) { apply(profile, folder: binding.path, previous: binding) }
            }
            if let global = state.globalBinding, let profile = state.profile(global.profileID) { applyGlobal(profile, previous: global) }
            notice = L("KeyZapper ist wieder aktiv. Laufende Claude-Sitzungen bitte neu starten.")
        }
        refresh()
    }

    func discardBackup() {
        availableBackup = nil
        writeBackup()
    }

    static func folderName(_ path: String) -> String { URL(fileURLWithPath: path).lastPathComponent }
}
