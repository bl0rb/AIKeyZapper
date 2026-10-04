import Foundation
import JavaScriptCore

public enum BindingHealth: Equatable, Sendable {
    case active
    case notApplied
    /// Settings keys whose current value differs from what the profile requires.
    case drifted([String])
    case folderMissing
}

public struct BindingStatus: Equatable, Sendable {
    public var health: BindingHealth
    public var conflicts: [SettingsConflict]
}

/// Writes a profile into `<root>/.claude/settings.local.json` (the highest-precedence non-managed layer)
/// and reverts exactly the values it wrote. Verified behaviour: see docs/feasibility.md.
public struct ClaudeSettingsBinder {
    public static let localSettingsPath = ".claude/settings.local.json"
    public static let gitExcludeLine = "/.claude/settings.local.json"
    static let gitExcludeComment = "# KeyZapper: projektlokale Claude-Code-Einstellungen"
    static let authEnvKeys = ["ANTHROPIC_BASE_URL", "ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN"]
    static let providerEnvKeys = ["CLAUDE_CODE_USE_BEDROCK", "CLAUDE_CODE_USE_VERTEX", "CLAUDE_CODE_USE_FOUNDRY"]

    public var helperPath: String
    public var managedSettingsPaths: [String]
    public var userSettingsPath: String

    public init(helperPath: String,
                managedSettingsPaths: [String] = ClaudeSettingsBinder.defaultManagedSettingsPaths(),
                userSettingsPath: String = canonicalPath("~/.claude/settings.json")) {
        self.helperPath = helperPath
        self.managedSettingsPaths = managedSettingsPaths
        self.userSettingsPath = userSettingsPath
    }

    public static func defaultManagedSettingsPaths() -> [String] {
        let base = "/Library/Application Support/ClaudeCode"
        let dropIns = ((try? FileManager.default.contentsOfDirectory(atPath: base + "/managed-settings.d")) ?? [])
            .filter { $0.hasSuffix(".json") }.sorted().map { base + "/managed-settings.d/" + $0 }
        return [base + "/managed-settings.json"] + dropIns
    }

    // MARK: Contract

    /// The values the app owns for a profile. `ANTHROPIC_API_KEY`/`ANTHROPIC_AUTH_TOKEN` are set to "" to
    /// neutralise values inherited from the IDE/shell environment (otherwise headers get mixed, spike T6/T7/T12).
    public func desiredValues(for profile: Profile) -> [String: String] {
        var endpoint = profile.endpoint.absoluteString
        while endpoint.hasSuffix("/") { endpoint.removeLast() }
        var values = [
            "apiKeyHelper": "\(Self.shellQuote(helperPath)) credential --profile \(profile.id.uuidString)",
            "env.ANTHROPIC_BASE_URL": endpoint,
            "env.ANTHROPIC_API_KEY": "",
            "env.ANTHROPIC_AUTH_TOKEN": "",
        ]
        for (name, value) in profile.modelEnvironment { values["env." + name] = value }
        for (name, value) in profile.environment ?? [:] where Profile.isAllowedEnvironmentName(name) {
            values["env." + name] = value
        }
        return values
    }

    /// Folder whose local settings Claude Code reads: the main worktree root inside git repositories
    /// (Claude Code ≥ 2.1.288, spike T4/T11/T15), otherwise the folder itself.
    public static func settingsRoot(for folder: String) -> String {
        let path = canonicalPath(folder)
        guard let common = Git.run(["rev-parse", "--path-format=absolute", "--git-common-dir"], in: path) else { return path }
        let commonURL = URL(fileURLWithPath: common)
        if commonURL.lastPathComponent == ".git" { return canonicalPath(commonURL.deletingLastPathComponent().path) }
        return Git.run(["rev-parse", "--show-toplevel"], in: path).map(canonicalPath) ?? path
    }

    // MARK: Apply / revert

    public struct ApplyResult {
        public var binding: WorkspaceBinding
        public var changed: Bool
        public var warnings: [SettingsConflict]
    }

    public func apply(profile: Profile, folder: String, previous: WorkspaceBinding?) throws -> ApplyResult {
        let root = canonicalPath(folder)
        guard Self.isDirectory(root) else { throw KeyZapperError.folderNotFound(root) }
        let expected = Self.settingsRoot(for: root)
        guard expected == root else { throw KeyZapperError.notSettingsRoot(folder: root, root: expected) }

        let desired = desiredValues(for: profile)
        let previousValues = previous?.managedValues ?? [:]
        let outer = environmentConflicts(root: root)
        if outer.contains(where: { $0.severity == .blocking }) {
            throw KeyZapperError.settingsConflicts(outer.filter { $0.severity == .blocking })
        }
        let changed = try Self.withLock {
            try mutateLocalSettings(root: root) { settings in
                let local = Self.localConflicts(settings, desired: desired, previous: previousValues)
                guard local.isEmpty else { throw KeyZapperError.settingsConflicts(local) }
                for (key, value) in desired { settings.setValue(value, at: key) }
                for (key, value) in previousValues where desired[key] == nil && settings.stringValue(at: key) == value {
                    settings.removeValue(at: key)
                }
            }
        }
        let exclude = try ensureGitExcluded(root: root) ?? previous?.gitExcludeEntry
        let binding = WorkspaceBinding(id: previous?.id ?? UUID(), path: root, profileID: profile.id,
                                       managedValues: desired, gitExcludeEntry: exclude)
        return ApplyResult(binding: binding, changed: changed, warnings: outer)
    }

    /// Removes only values that still equal what the app wrote. Returns keys left in place because
    /// they were changed by someone else in the meantime.
    @discardableResult
    public func revert(_ binding: WorkspaceBinding) throws -> [String] {
        var kept: [String] = []
        if Self.isDirectory(binding.path) {
            _ = try Self.withLock {
                try mutateLocalSettings(root: binding.path) { settings in
                    kept = []
                    for (key, value) in binding.managedValues {
                        if settings.stringValue(at: key) == value { settings.removeValue(at: key) }
                        else if settings.hasValue(at: key) { kept.append(key) }
                    }
                }
            }
            if let line = binding.gitExcludeEntry { try removeGitExclude(root: binding.path, line: line) }
        }
        return kept.sorted()
    }

    // MARK: Global default profile (~/.claude/settings.json)

    /// Writes the profile into the user settings so folders without their own assignment use it too. Existing
    /// values for the same keys (e.g. a plaintext key) are replaced on purpose; `backupUserSettings()` keeps them.
    public func applyGlobal(profile: Profile, previous: WorkspaceBinding?) throws -> ApplyResult {
        let managed = managedConflicts()
        if managed.contains(where: { $0.severity == .blocking }) {
            throw KeyZapperError.settingsConflicts(managed.filter { $0.severity == .blocking })
        }
        let desired = desiredValues(for: profile)
        let previousValues = previous?.managedValues ?? [:]
        let url = URL(fileURLWithPath: userSettingsPath)
        let changed = try Self.withLock {
            try mutateSettings(at: url) { settings in
                if settings["$schema"] == nil { settings["$schema"] = Self.schemaURL }
                for (key, value) in desired { settings.setValue(value, at: key) }
                for (key, value) in previousValues where desired[key] == nil && settings.stringValue(at: key) == value {
                    settings.removeValue(at: key)
                }
            }
        }
        let binding = WorkspaceBinding(id: previous?.id ?? UUID(), path: userSettingsPath, profileID: profile.id, managedValues: desired)
        return ApplyResult(binding: binding, changed: changed, warnings: managed)
    }

    /// Removes the default profile's values from the user settings (only those still unchanged).
    @discardableResult
    public func revertGlobal(_ binding: WorkspaceBinding) throws -> [String] {
        var kept: [String] = []
        _ = try Self.withLock {
            try mutateSettings(at: URL(fileURLWithPath: userSettingsPath)) { settings in
                kept = []
                for (key, value) in binding.managedValues {
                    if settings.stringValue(at: key) == value { settings.removeValue(at: key) }
                    else if settings.hasValue(at: key) { kept.append(key) }
                }
            }
        }
        return kept.sorted()
    }

    public func inspectGlobal(_ binding: WorkspaceBinding, profile: Profile) -> BindingHealth {
        guard !Self.isUnparsableJSON(userSettingsPath), let settings = (try? Self.readJSON(userSettingsPath)) ?? nil else {
            return .notApplied
        }
        let desired = desiredValues(for: profile)
        let differing = desired.filter { settings.stringValue(at: $0.key) != $0.value }.keys.sorted()
        if differing.isEmpty { return .active }
        return desired.keys.allSatisfy({ !settings.hasValue(at: $0) }) ? .notApplied : .drifted(differing)
    }

    /// Copies the user settings to `settings.json.keyzapper-<timestamp>.bak` before KeyZapper changes them.
    @discardableResult
    public func backupUserSettings() throws -> URL? {
        guard FileManager.default.fileExists(atPath: userSettingsPath) else { return nil }
        let stamp = ISO8601DateFormatter.string(from: Date(), timeZone: .current, formatOptions: [.withFullDate, .withTime])
        let target = URL(fileURLWithPath: userSettingsPath + ".keyzapper-\(stamp).bak")
        try? FileManager.default.removeItem(at: target)
        try FileManager.default.copyItem(at: URL(fileURLWithPath: userSettingsPath), to: target)
        return target
    }

    /// Makes `~/.claude/settings.json` valid for Claude Code: keeps everything readable, removes plaintext keys,
    /// turns non-text `env` values into text and adds `$schema`. An unreadable file is replaced by a fresh one.
    /// The original is backed up first; returns the backup.
    @discardableResult
    public func repairUserSettings() throws -> URL? {
        let backup = try backupUserSettings()
        let url = URL(fileURLWithPath: userSettingsPath)
        var settings = ((try? Self.readJSON(userSettingsPath)) ?? nil) ?? [:]
        if settings["$schema"] == nil { settings["$schema"] = Self.schemaURL }
        if var env = settings["env"] as? [String: Any] {
            for key in ["ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN"] where (env[key] as? String)?.isEmpty == false { env[key] = nil }
            for (key, value) in env where !(value is String) { env[key] = "\(value)" }
            settings["env"] = env.isEmpty ? nil : env
        } else if settings["env"] != nil {
            settings["env"] = nil
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var data = try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        data.append(0x0A)
        try data.write(to: url, options: .atomic)
        return backup
    }

    static let schemaURL = "https://json.schemastore.org/claude-code-settings.json"

    // MARK: Status

    public func inspect(_ binding: WorkspaceBinding, profile: Profile, globalValues: [String: String] = [:]) -> BindingStatus {
        guard Self.isDirectory(binding.path) else { return BindingStatus(health: .folderMissing, conflicts: []) }
        var conflicts = environmentConflicts(root: binding.path, globalValues: globalValues)
        let localPath = Self.localSettingsURL(binding.path).path
        let settings: [String: Any]
        do {
            // Strict check first: Claude Code ignores a file Foundation would still accept (e.g. trailing commas).
            guard !Self.isUnparsableJSON(localPath) else { throw KeyZapperError.settingsUnreadable(localPath) }
            settings = try Self.readJSON(localPath) ?? [:]
        } catch {
            conflicts.append(SettingsConflict(.blocking, L("\(Self.localSettingsPath) ist kein gültiges JSON.")))
            return BindingStatus(health: .drifted([]), conflicts: conflicts)
        }
        let desired = desiredValues(for: profile)
        let differing = desired.filter { settings.stringValue(at: $0.key) != $0.value }.keys.sorted()
        let health: BindingHealth
        if differing.isEmpty { health = .active }
        else if desired.keys.allSatisfy({ !settings.hasValue(at: $0) }) { health = .notApplied }
        else { health = .drifted(differing) }
        return BindingStatus(health: health, conflicts: conflicts)
    }

    // MARK: Conflicts

    /// Conflicts in the local file itself. Values are never included in messages (they may be secrets).
    static func localConflicts(_ settings: [String: Any], desired: [String: String], previous: [String: String]) -> [SettingsConflict] {
        desired.keys.sorted().compactMap { key in
            guard settings.hasValue(at: key) else { return nil }
            let current = settings.stringValue(at: key)
            if current == desired[key] || (current != nil && current == previous[key]) { return nil }
            return SettingsConflict(.blocking, L("\(localSettingsPath): „\(key)“ ist bereits mit einem anderen Wert gesetzt. Bitte manuell entfernen."))
        }
    }

    /// Managed settings, git tracking, provider switches (blocking) and lower-precedence layers (warnings).
    public func environmentConflicts(root: String, globalValues: [String: String] = [:]) -> [SettingsConflict] {
        var result = managedConflicts()
        if Git.status(["ls-files", "--error-unmatch", Self.localSettingsPath], in: root) == 0 {
            result.append(SettingsConflict(.blocking, L("\(Self.localSettingsPath) ist im Git-Repository eingecheckt und würde geteilt.")))
        }
        let projectSettingsPath = URL(fileURLWithPath: root).appendingPathComponent(".claude/settings.json").path
        let layers = [(L("Benutzereinstellungen"), userSettingsPath),
                      (L("Projekteinstellungen"), projectSettingsPath),
                      (L("Lokale Projekteinstellungen"), Self.localSettingsURL(root).path)] +
                     managedSettingsPaths.map { (L("Verwaltete Firmeneinstellung"), $0) }
        for (name, path) in layers {
            // User settings get one app-wide banner; invalid local settings are reported by inspect().
            if path != userSettingsPath && path != Self.localSettingsURL(root).path && Self.isUnparsableJSON(path) {
                result.append(SettingsConflict(.warning, L("\(name) (\(path)) sind kein gültiges JSON; Claude Code ignoriert die Datei.")))
                continue
            }
            guard let settings = try? Self.readJSON(path) else { continue }
            for key in Self.providerEnvKeys where Self.isTruthy(settings.stringValue(at: "env." + key)) {
                result.append(SettingsConflict(.blocking, L("\(name) (\(path)): „\(key)“ leitet Claude Code an LiteLLM vorbei.")))
            }
            if path == userSettingsPath || path == projectSettingsPath {
                // Values of KeyZapper's own default profile in the user settings are expected, not a conflict.
                for key in ["apiKeyHelper"] + Self.authEnvKeys.map({ "env." + $0 }) where settings.hasValue(at: key)
                    && !(path == userSettingsPath && globalValues[key] != nil && settings.stringValue(at: key) == globalValues[key]) {
                    result.append(SettingsConflict(.warning, L("\(name) (\(path)) setzen „\(key)“; die Projektzuordnung hat Vorrang.")))
                }
            }
        }
        return result
    }

    /// Managed (company) settings: auth keys are blocking, model variables override the profile's models.
    public func managedConflicts() -> [SettingsConflict] {
        var result: [SettingsConflict] = []
        for path in managedSettingsPaths {
            guard let managed = try? Self.readJSON(path) else { continue }
            for key in ["apiKeyHelper"] + Self.authEnvKeys.map({ "env." + $0 }) where managed.hasValue(at: key) {
                result.append(SettingsConflict(.blocking, L("Verwaltete Firmeneinstellung \(path) setzt „\(key)“ und hat Vorrang vor der Projektzuordnung.")))
            }
            for key in Self.modelEnvKeys.map({ "env." + $0 }) where managed.hasValue(at: key) {
                result.append(SettingsConflict(.warning, L("Verwaltete Firmeneinstellung \(path) setzt „\(key)“ und überstimmt die Modelle des Profils.")))
            }
        }
        return result
    }

    static let modelEnvKeys = ["ANTHROPIC_MODEL", "ANTHROPIC_DEFAULT_OPUS_MODEL", "ANTHROPIC_DEFAULT_SONNET_MODEL", "ANTHROPIC_DEFAULT_HAIKU_MODEL"]

    // MARK: Local settings I/O

    static func localSettingsURL(_ root: String) -> URL {
        URL(fileURLWithPath: root).appendingPathComponent(localSettingsPath)
    }

    /// Read-modify-write with optimistic concurrency: the file is replaced atomically (rename) only if it
    /// is still byte-identical to what was read. Returns false when nothing had to change (idempotent).
    func mutateLocalSettings(root: String, _ transform: (inout [String: Any]) throws -> Void) throws -> Bool {
        try mutateSettings(at: Self.localSettingsURL(root), transform)
    }

    func mutateSettings(at url: URL, _ transform: (inout [String: Any]) throws -> Void) throws -> Bool {
        let fm = FileManager.default
        for _ in 0..<3 {
            let original = fm.fileExists(atPath: url.path) ? try Self.readData(url) : nil
            var settings = try original.map(Self.parse) ?? [:]
            let before = try Self.canonicalJSON(settings)
            try transform(&settings)
            if let env = settings["env"] as? [String: Any], env.isEmpty { settings["env"] = nil }
            // Rewrite even without changes if Claude Code cannot parse the file as it is (e.g. trailing commas).
            if try Self.canonicalJSON(settings) == before, original == nil || !Self.isUnparsableJSON(url.path) { return false }

            if settings.isEmpty {
                guard (try? Self.readData(url)) == original else { continue }
                try? fm.removeItem(at: url)
                let dir = url.deletingLastPathComponent()
                if (try? fm.contentsOfDirectory(atPath: dir.path))?.isEmpty == true { try? fm.removeItem(at: dir) }
                return true
            }
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            var data = try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            data.append(0x0A)
            let tmp = url.deletingLastPathComponent().appendingPathComponent(".settings.local.json.keyzapper-\(UUID().uuidString)")
            try data.write(to: tmp)
            let permissions = (try? fm.attributesOfItem(atPath: url.path)[.posixPermissions]) ?? 0o644
            try fm.setAttributes([.posixPermissions: permissions], ofItemAtPath: tmp.path)
            guard (fm.fileExists(atPath: url.path) ? try? Self.readData(url) : nil) == original else {
                try? fm.removeItem(at: tmp)
                continue
            }
            guard rename(tmp.path, url.path) == 0 else {
                try? fm.removeItem(at: tmp)
                throw KeyZapperError.settingsUnreadable("\(url.path): \(String(cString: strerror(errno)))")
            }
            return true
        }
        throw KeyZapperError.concurrentModification(url.path)
    }

    static func readData(_ url: URL) throws -> Data {
        do { return try Data(contentsOf: url) } catch { throw KeyZapperError.settingsUnreadable(url.path) }
    }

    static func parse(_ data: Data) throws -> [String: Any] {
        if data.allSatisfy({ [0x20, 0x0A, 0x0D, 0x09].contains($0) }) { return [:] }
        guard let object = try? JSONSerialization.jsonObject(with: data), let dict = object as? [String: Any] else {
            throw KeyZapperError.settingsUnreadable(L("kein gültiges JSON-Objekt"))
        }
        return dict
    }

    /// True if the file exists but is not a JSON object for Claude Code. Checked with JavaScript's strict
    /// `JSON.parse` like Claude Code itself: Foundation's parser accepts e.g. trailing commas that Claude rejects.
    /// Results are cached per path, modification date and size; one shared JSContext does the parsing.
    public static func isUnparsableJSON(_ path: String) -> Bool {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path) else { return false }
        let stamp = JSONCheckStamp(modified: attributes[.modificationDate] as? Date, size: (attributes[.size] as? NSNumber)?.intValue ?? -1)
        jsonCheckLock.lock()
        defer { jsonCheckLock.unlock() }
        if let cached = jsonCheckCache[path], cached.stamp == stamp { return cached.unparsable }
        let unparsable = strictlyUnparsable(path)
        jsonCheckCache[path] = (stamp, unparsable)
        return unparsable
    }

    struct JSONCheckStamp: Equatable { var modified: Date?; var size: Int }
    private static let jsonCheckLock = NSLock()
    private static var jsonCheckCache: [String: (stamp: JSONCheckStamp, unparsable: Bool)] = [:]
    private static let jsonContext = JSContext()

    private static func strictlyUnparsable(_ path: String) -> Bool {
        guard let data = FileManager.default.contents(atPath: path) else { return false }
        let text = String(decoding: data, as: UTF8.self)
        guard !text.allSatisfy(\.isWhitespace), let context = jsonContext else { return false }
        context.setObject(text, forKeyedSubscript: "input" as NSString)
        let verdict = context.evaluateScript("""
            (function () {
              try { var v = JSON.parse(input); return v !== null && typeof v === 'object' && !Array.isArray(v); }
              catch (e) { return false; }
            })()
            """)
        return verdict?.toBool() != true
    }

    static func readJSON(_ path: String) throws -> [String: Any]? {
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        return try parse(readData(URL(fileURLWithPath: path)))
    }

    static func canonicalJSON(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    // MARK: Git exclude

    /// Ensures the local settings file is git-ignored via `<git-common-dir>/info/exclude` (shared by all
    /// worktrees). Returns the line added, or nil if nothing was added.
    func ensureGitExcluded(root: String) throws -> String? {
        guard let common = Git.run(["rev-parse", "--path-format=absolute", "--git-common-dir"], in: root) else { return nil }
        if Git.status(["check-ignore", "-q", Self.localSettingsPath], in: root) == 0 { return nil }
        let exclude = URL(fileURLWithPath: common).appendingPathComponent("info/exclude")
        try FileManager.default.createDirectory(at: exclude.deletingLastPathComponent(), withIntermediateDirectories: true)
        var text = (try? String(contentsOf: exclude, encoding: .utf8)) ?? ""
        if !text.isEmpty && !text.hasSuffix("\n") { text += "\n" }
        text += Self.gitExcludeComment + "\n" + Self.gitExcludeLine + "\n"
        try text.write(to: exclude, atomically: true, encoding: .utf8)
        return Self.gitExcludeLine
    }

    func removeGitExclude(root: String, line: String) throws {
        guard let common = Git.run(["rev-parse", "--path-format=absolute", "--git-common-dir"], in: root) else { return }
        let exclude = URL(fileURLWithPath: common).appendingPathComponent("info/exclude")
        guard let text = try? String(contentsOf: exclude, encoding: .utf8) else { return }
        var lines = text.components(separatedBy: "\n")
        guard let index = lines.lastIndex(of: line) else { return }
        lines.remove(at: index)
        if index > 0 && lines[index - 1] == Self.gitExcludeComment { lines.remove(at: index - 1) }
        try lines.joined(separator: "\n").write(to: exclude, atomically: true, encoding: .utf8)
    }

    // MARK: Helpers

    static func withLock<T>(_ body: () throws -> T) throws -> T {
        let lockPath = FileManager.default.temporaryDirectory.appendingPathComponent("KeyZapper-settings.lock").path
        let fd = open(lockPath, O_CREAT | O_RDWR, 0o600)
        guard fd >= 0 else { return try body() }
        defer { flock(fd, LOCK_UN); close(fd) }
        flock(fd, LOCK_EX)
        return try body()
    }

    static func shellQuote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    static func isDirectory(_ path: String) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
    }

    static func isTruthy(_ value: String?) -> Bool {
        guard let v = value?.lowercased(), !v.isEmpty else { return false }
        return !["0", "false", "no", "off"].contains(v)
    }
}

// MARK: Dotted key paths ("apiKeyHelper", "env.ANTHROPIC_BASE_URL")

extension Dictionary where Key == String, Value == Any {
    func value(at keyPath: String) -> Any? {
        let parts = keyPath.split(separator: ".", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return self[keyPath] }
        return (self[parts[0]] as? [String: Any])?[parts[1]]
    }

    func hasValue(at keyPath: String) -> Bool { value(at: keyPath) != nil }

    func stringValue(at keyPath: String) -> String? { value(at: keyPath) as? String }

    mutating func setValue(_ value: String, at keyPath: String) {
        let parts = keyPath.split(separator: ".", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { self[keyPath] = value; return }
        var inner = self[parts[0]] as? [String: Any] ?? [:]
        inner[parts[1]] = value
        self[parts[0]] = inner
    }

    mutating func removeValue(at keyPath: String) {
        let parts = keyPath.split(separator: ".", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { self[keyPath] = nil; return }
        guard var inner = self[parts[0]] as? [String: Any] else { return }
        inner[parts[1]] = nil
        self[parts[0]] = inner
    }
}
