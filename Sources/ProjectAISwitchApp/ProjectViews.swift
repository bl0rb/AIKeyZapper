import AISwitchCore
import AppKit
import SwiftUI

struct AddProjectSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @ViewState private var folder: String?
    @ViewState private var profileID: UUID?
    @ViewState private var pickingFolder = false

    private var root: String? { folder.map(ClaudeSettingsBinder.settingsRoot(for:)) }
    private var existing: WorkspaceBinding? { root.flatMap { r in model.state.bindings.first { $0.path == r } } }

    var body: some View {
        Form {
            Section {
                LabeledContent("Projektordner") {
                    HStack {
                        Text(folder ?? "Kein Ordner gewählt").foregroundStyle(folder == nil ? .secondary : .primary).lineLimit(1).truncationMode(.middle)
                        Button("Auswählen …") { pickingFolder = true }
                    }
                }
                if let folder, let root, canonicalPath(folder) != root {
                    Label("Der Ordner gehört zum Git-Repository \(root). Claude Code liest Projekteinstellungen nur dort; die Zuordnung gilt für das ganze Repository inkl. Unterordnern und Worktrees.", systemImage: "info.circle")
                        .font(.caption)
                }
                Picker("Profil", selection: $profileID) {
                    Text("Bitte wählen").tag(UUID?.none)
                    ForEach(model.state.profiles) { Text($0.name).tag(UUID?.some($0.id)) }
                }
                if let existing {
                    Label("Bereits Profil „\(model.profileName(existing.profileID))“ zugeordnet – wird umgestellt.", systemImage: "arrow.triangle.swap")
                        .font(.caption)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .fileImporter(isPresented: $pickingFolder, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result { folder = url.path }
        }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Abbrechen") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Zuordnen") {
                    guard let folder, let profileID else { return }
                    model.bind(folder: folder, to: profileID)
                    dismiss()
                }
                .disabled(folder == nil || profileID == nil)
            }
        }
        .onAppear { if model.state.profiles.count == 1 { profileID = model.state.profiles.first?.id } }
    }
}

struct ProjectDetailView: View {
    @Environment(AppModel.self) private var model
    let binding: WorkspaceBinding
    @ViewState private var confirmUnbind = false

    var body: some View {
        let status = model.statuses[binding.id]
        let keyPresent = model.keyPresent[binding.profileID] == true
        Form {
            Section("Projekt") {
                LabeledContent("Ordner") {
                    HStack {
                        Text(binding.path).textSelection(.enabled).lineLimit(2).truncationMode(.middle)
                        Button("Im Finder zeigen", systemImage: "folder") {
                            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: binding.path)])
                        }
                        .labelStyle(.iconOnly).buttonStyle(.borderless)
                    }
                }
                Picker("Profil", selection: Binding(get: { binding.profileID }, set: { model.bind(folder: binding.path, to: $0) })) {
                    ForEach(model.state.profiles) { Text($0.name).tag($0.id) }
                }
            }
            Section("Integrationsstatus") {
                let (symbol, color) = StatusIcon.appearance(status, keyPresent: keyPresent)
                Label(Self.describe(status?.health), systemImage: symbol).foregroundStyle(color)
                if !keyPresent {
                    Label("Für das Profil ist kein Key hinterlegt. Claude-Anfragen schlagen fehl – es wird nicht auf andere Zugangsdaten ausgewichen.", systemImage: "key.slash")
                        .foregroundStyle(.red)
                }
                ForEach(status?.conflicts ?? [], id: \.self) { conflict in
                    Label(conflict.message, systemImage: conflict.severity == .blocking ? "xmark.octagon" : "exclamationmark.triangle")
                        .foregroundStyle(conflict.severity == .blocking ? .red : .orange)
                }
                Text("Änderungen gelten für neu gestartete Claude-Sitzungen (VS Code: neue Unterhaltung bzw. Fenster neu laden; IntelliJ: Claude im Terminal neu starten). Laufende Sitzungen übernehmen einen neuen Key nach Ablauf des Helper-Caches (Standard 5 min) oder nach einem 401.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle(AppModel.folderName(binding.path))
        .toolbar {
            ToolbarItemGroup {
                Button("Erneut anwenden") { model.reapply(binding) }.disabled(status?.health == .folderMissing)
                Button("Zuordnung entfernen", role: .destructive) { confirmUnbind = true }
            }
        }
        .confirmationDialog("Zuordnung für „\(AppModel.folderName(binding.path))“ entfernen?", isPresented: $confirmUnbind) {
            Button("Entfernen", role: .destructive) { model.unbind(binding) }
        } message: {
            Text("Nur die von der App gesetzten Einträge werden aus .claude/settings.local.json entfernt. Andere Einstellungen bleiben erhalten.")
        }
    }

    static func describe(_ health: BindingHealth?) -> String {
        switch health {
        case .active: "Aktiv – Claude Code verwendet in diesem Projekt das zugeordnete Profil."
        case .notApplied: "Nicht eingerichtet – Einstellungen fehlen. „Erneut anwenden“ wählen."
        case .drifted(let keys): "Abweichung in: \(keys.joined(separator: ", ")). „Erneut anwenden“ wählen."
        case .folderMissing: "Ordner nicht gefunden (verschoben oder gelöscht). Zuordnung entfernen und neuen Ort zuordnen."
        case nil: "Status unbekannt"
        }
    }
}
