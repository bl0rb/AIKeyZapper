import AppKit
import KeyZapperCore
import SwiftUI

/// Check of `~/.claude/settings.json` with repair/create and the default profile for unassigned folders.
struct ClaudeSettingsSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @ViewState private var selectedProfile: UUID?

    private var fileExists: Bool { FileManager.default.fileExists(atPath: model.userSettingsPath) }
    private var needsRepair: Bool { model.globalFindings.contains { $0.severity == .error || $0.id.hasPrefix("plaintext-") } }

    var body: some View {
        Form {
            Section {
                if model.globalFindings.allSatisfy({ $0.severity == .info }) {
                    Label("Keine Probleme gefunden.", systemImage: "checkmark.seal.fill").foregroundStyle(.green)
                }
                ForEach(model.globalFindings) { finding in
                    Label(finding.message, systemImage: Self.symbol(finding.severity))
                        .foregroundStyle(Self.color(finding.severity))
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack {
                    Button("Erneut prüfen") { model.refresh() }
                    Button(fileExists ? LocalizedStringKey("Reparieren") : LocalizedStringKey("Erzeugen")) { model.repairUserSettings() }
                        .disabled(fileExists && !needsRepair)
                    Spacer()
                    Button("Im Finder zeigen", systemImage: "folder") {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: model.userSettingsPath)])
                    }
                    .disabled(!fileExists)
                }
            } header: {
                Text(verbatim: (model.userSettingsPath as NSString).abbreviatingWithTildeInPath)
            } footer: {
                Text("„Reparieren“ macht die Datei gültig, entfernt Klartext-Keys und wandelt Werte in „env“ in Text um. Vorher legt KeyZapper eine Sicherung settings.json.keyzapper-<Zeit>.bak an.")
                    .font(.caption).foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading).frame(maxWidth: .infinity, alignment: .leading)
            }

            Section {
                Picker("Standardprofil", selection: $selectedProfile) {
                    Text("Keins").tag(UUID?.none)
                    ForEach(model.state.profiles) { Text($0.name).tag(UUID?.some($0.id)) }
                }
                if let health = model.globalHealth {
                    Label(Self.describe(health), systemImage: health == .active ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(health == .active ? .green : .orange)
                }
                HStack {
                    Spacer()
                    Button("Übernehmen") { model.setGlobalProfile(selectedProfile) }
                        .disabled(selectedProfile == model.state.globalBinding?.profileID && model.globalHealth == .active
                                  || (selectedProfile == nil && model.state.globalBinding == nil)
                                  || model.isDisabled)
                }
            } header: {
                Text("Standardprofil für alle übrigen Ordner")
            } footer: {
                Text("Trägt das Profil in ~/.claude/settings.json ein. Claude Code nutzt es in allen Ordnern ohne eigene Zuordnung, statt auf einen Klartext-Key oder die normale Anmeldung zurückzufallen. Zugeordnete Projekte behalten ihr eigenes Profil.")
                    .font(.caption).foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .formStyle(.grouped)
        .frame(width: 560)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) { Button("Fertig") { dismiss() } }
        }
        .onAppear { selectedProfile = model.state.globalBinding?.profileID }
    }

    static func symbol(_ severity: SettingsFinding.Severity) -> String {
        switch severity {
        case .error: "xmark.octagon.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .info: "info.circle"
        }
    }

    static func color(_ severity: SettingsFinding.Severity) -> Color {
        switch severity {
        case .error: .red
        case .warning: .orange
        case .info: .secondary
        }
    }

    static func describe(_ health: BindingHealth) -> String {
        switch health {
        case .active: L("Standardprofil ist aktiv.")
        case .notApplied: L("Standardprofil fehlt in der Datei – „Übernehmen“ wählen.")
        case .drifted(let keys): L("Abweichung in \(keys.joined(separator: ", ")) – „Übernehmen“ wählen.")
        case .folderMissing: L("Datei nicht gefunden.")
        }
    }
}
