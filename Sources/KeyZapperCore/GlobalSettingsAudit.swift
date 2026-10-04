import Foundation

public struct SettingsFinding: Identifiable, Equatable, Sendable {
    public enum Severity: Sendable { case error, warning, info }
    public var id: String
    public var severity: Severity
    public var message: String
}

/// Logical checks of `~/.claude/settings.json` for use with an LLM gateway: things Claude Code accepts silently
/// but that break or weaken the setup (plaintext keys, endpoint without key, non-text env values, …).
public enum GlobalSettingsAudit {
    static let modelAliases: Set<String> = ["default", "opus", "sonnet", "haiku", "opusplan", "best"]

    /// - Parameter globalValues: values KeyZapper's default profile wrote; they are expected, not findings.
    public static func check(path: String, globalValues: [String: String] = [:]) -> [SettingsFinding] {
        guard FileManager.default.fileExists(atPath: path) else {
            return [SettingsFinding(id: "missing", severity: .info,
                                    message: L("Keine globale settings.json vorhanden. Claude Code nutzt Standardwerte."))]
        }
        if ClaudeSettingsBinder.isUnparsableJSON(path) {
            return [SettingsFinding(id: "invalid-json", severity: .error,
                                    message: L("Kein gültiges JSON: Claude Code ignoriert die Datei, und das Speichern der Modellauswahl schlägt fehl."))]
        }
        guard let settings = (try? ClaudeSettingsBinder.readJSON(path)) ?? nil else { return [] }
        var findings: [SettingsFinding] = []
        func add(_ id: String, _ severity: SettingsFinding.Severity, _ message: String) {
            findings.append(SettingsFinding(id: id, severity: severity, message: message))
        }
        func isOwn(_ key: String) -> Bool { globalValues[key] != nil && settings.stringValue(at: key) == globalValues[key] }

        let env = settings["env"] as? [String: Any] ?? [:]
        if settings["env"] != nil && settings["env"] as? [String: Any] == nil {
            add("env-type", .error, L("„env“ ist kein Objekt; Claude Code erwartet Name-Wert-Paare."))
        }
        for (name, value) in env.sorted(by: { $0.key < $1.key }) where !(value is String) {
            add("env-value-\(name)", .error, L("„env.\(name)“ ist kein Text. Claude Code erwartet Zeichenketten, z. B. „1“ statt 1."))
        }
        for name in ["ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN"] where (env[name] as? String)?.isEmpty == false {
            add("plaintext-\(name)", .warning, L("Klartext-Key in „env.\(name)“. Außerhalb zugeordneter Projekte nutzt Claude diesen Key. Besser entfernen und ein Standardprofil setzen."))
        }
        let hasHelper = settings["apiKeyHelper"] != nil
        if hasHelper && !isOwn("apiKeyHelper") {
            add("own-helper", .info, L("Eigener „apiKeyHelper“ gesetzt. In zugeordneten Projekten hat KeyZapper Vorrang."))
        }
        let hasKey = ["ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN"].contains { (env[$0] as? String)?.isEmpty == false }
        if (env["ANTHROPIC_BASE_URL"] as? String)?.isEmpty == false && !hasKey && !hasHelper {
            add("endpoint-without-key", .warning, L("„env.ANTHROPIC_BASE_URL“ ist gesetzt, aber kein Key. Außerhalb zugeordneter Projekte schlagen Anfragen fehl; ein Standardprofil behebt das."))
        }
        for name in ClaudeSettingsBinder.providerEnvKeys where ClaudeSettingsBinder.isTruthy(env[name] as? String) {
            add("provider-\(name)", .warning, L("„env.\(name)“ leitet Claude Code an LiteLLM vorbei."))
        }
        for name in ClaudeSettingsBinder.modelEnvKeys where env[name] != nil && !isOwn("env." + name) {
            add("model-env-\(name)", .info, L("„env.\(name)“ gilt nur außerhalb zugeordneter Projekte; dort gelten die Modelle des Profils."))
        }
        if let model = settings["model"] as? String, model.hasPrefix("claude-"),
           !modelAliases.contains(model.replacingOccurrences(of: "[1m]", with: "")) {
            add("fixed-model", .warning, L("„model“ ist die feste Modell-ID „\(model)“. Über ein Gateway mit eigenen Namen besser einen Alias wählen (opus, sonnet, haiku), damit die Profilmodelle greifen."))
        }
        return findings
    }
}
