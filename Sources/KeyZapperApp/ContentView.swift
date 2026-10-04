import AppKit
import KeyZapperCore
import SwiftUI

/// Single overview: every profile with its key and all assigned projects, editable in place.
struct ContentView: View {
    @Environment(AppModel.self) private var model
    @ViewState private var showNewProfile = false
    @ViewState private var showAddProject = false
    @ViewState private var showHowItWorks = false

    var body: some View {
        VStack(spacing: 0) {
            banners
            if model.state.profiles.isEmpty {
                ContentUnavailableView {
                    Label("Noch keine Profile", systemImage: "key")
                } description: {
                    Text("Lege ein Profil mit LiteLLM-Endpunkt, Modellalias und deinem freigegebenen Key an.")
                } actions: {
                    Button("Profil anlegen") { showNewProfile = true }.buttonStyle(.borderedProminent)
                    Button("Backup importieren …") { model.backupSheet = .import }.buttonStyle(.link)
                    Button("So funktioniert’s") { showHowItWorks = true }.buttonStyle(.link)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        ForEach(model.state.profiles) { ProfileCard(profile: $0) }
                        HStack(spacing: 6) {
                            Image(systemName: "bolt.horizontal.circle").foregroundStyle(Color.accentColor)
                            Text("Claude Code holt in jedem zugeordneten Projekt den passenden Key automatisch über den Helper – kein manuelles Wechseln nötig. Nach neuen Zuordnungen die Claude-Sitzung einmal neu starten.")
                                .foregroundStyle(.secondary)
                        }
                        .font(.caption)
                        VersionFooter { showHowItWorks = true }
                    }
                    .padding(20)
                }
            }
        }
        .navigationTitle("KeyZapper")
        .toolbar {
            ToolbarItemGroup {
                Button { showNewProfile = true } label: { Label("Neues Profil", systemImage: "plus") }
                Button { showAddProject = true } label: { Label("Projekt zuordnen", systemImage: "folder.badge.plus") }
                    .disabled(model.state.profiles.isEmpty)
                Button { model.refresh() } label: { Label("Status aktualisieren", systemImage: "arrow.clockwise") }
                Menu {
                    Button("Backup exportieren …") { model.backupSheet = .export }.disabled(model.state.profiles.isEmpty)
                    Button("Backup importieren …") { model.backupSheet = .import }
                } label: {
                    Label("Backup", systemImage: "externaldrive.badge.timemachine")
                }
                Button { showHowItWorks = true } label: { Label("So funktioniert’s", systemImage: "info.circle") }
            }
        }
        .sheet(item: Binding(get: { model.backupSheet }, set: { model.backupSheet = $0 })) { sheet in
            switch sheet {
            case .export: ExportBackupSheet()
            case .import: ImportBackupSheet()
            }
        }
        .sheet(isPresented: $showHowItWorks) { HowItWorksView() }
        .sheet(isPresented: $showNewProfile) { ProfileEditor(existing: nil) }
        .sheet(isPresented: $showAddProject) { AddProjectSheet() }
        .alert("Fehler", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
    }

    @ViewBuilder private var banners: some View {
        VStack(spacing: 0) {
            if let backup = model.availableBackup {
                Banner(kind: .info,
                       title: L("OneDrive-Backup gefunden: \(backup.profiles.count) Profil(e), \(backup.bindings.count) Projekt(e)"),
                       detail: L("Profile und Zuordnungen wiederherstellen? Keys sind nicht im Backup und müssen neu eingetragen werden."),
                       actions: [BannerAction(title: L("Wiederherstellen"), action: model.restoreFromBackup),
                                 BannerAction(title: L("Verwerfen"), action: model.discardBackup)])
            }
            if let problem = model.backupProblem {
                Banner(kind: .warning, title: problem)
            }
            if let path = model.invalidUserSettingsPath {
                Banner(kind: .warning,
                       title: L("\((path as NSString).abbreviatingWithTildeInPath) ist kein gültiges JSON"),
                       detail: L("Claude Code ignoriert die Datei, und das Speichern der Modellauswahl schlägt fehl. Fehler finden mit „python3 -m json.tool ~/.claude/settings.json“ oder die Datei löschen."),
                       actions: [BannerAction(title: L("Im Finder zeigen")) {
                           NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                       }])
            }
            if !model.outdatedCLIs.isEmpty {
                Banner(kind: .warning,
                       title: L("Claude-Code-CLI veraltet: \(model.outdatedCLIs.joined(separator: ", "))"),
                       detail: L("IntelliJ nutzt diese CLI. Unter \(model.minimumCLIVersion) gilt die Projektzuordnung nur beim Start direkt im Projektordner. Aktualisieren mit „claude update“."))
            }
            if let update = model.availableUpdate {
                Banner(kind: .info,
                       title: L("KeyZapper \(update.version) ist verfügbar (installiert: \(model.appVersion ?? "?"))"),
                       detail: model.isInstallingUpdate ? L("Paket wird geladen und geprüft …") : L("Die Installation benötigt Administratorrechte."),
                       actions: [BannerAction(title: L("Installieren")) { Task { await model.installUpdate() } },
                                 BannerAction(title: L("Versionshinweise")) { NSWorkspace.shared.open(update.pageURL) }])
            }
            if let notice = model.notice {
                Banner(kind: .info, title: notice) { model.notice = nil }
            }
        }
    }
}

struct ProfileCard: View {
    @Environment(AppModel.self) private var model
    let profile: Profile
    @ViewState private var editing = false
    @ViewState private var replacingKey = false
    @ViewState private var addingProject = false
    @ViewState private var confirmDelete = false
    @ViewState private var checking = false
    @ViewState private var checkResult: GatewayCheckResult?

    private var bindings: [WorkspaceBinding] { model.state.bindings.filter { $0.profileID == profile.id } }
    private var hasKey: Bool { model.keyPresent[profile.id] == true }
    private var isManaged: Bool { model.isManaged(profile.id) }

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 8) {
                            Text(profile.name).font(.title3).fontWeight(.semibold)
                            if isManaged {
                                Text("Von der IT vorgegeben").font(.caption).foregroundStyle(.secondary)
                                    .padding(.horizontal, 6).padding(.vertical, 1)
                                    .background(Capsule().stroke(.secondary.opacity(0.4)))
                            }
                        }
                        Text(profile.endpoint.absoluteString + (profile.modelAlias.isEmpty ? "" : L(" · Modell \(profile.modelAlias)")))
                            .font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                        if !tierModels.isEmpty {
                            Text(verbatim: tierModels).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                    }
                    Spacer()
                    Button("Bearbeiten") { editing = true }.disabled(isManaged)
                    Button("Löschen", role: .destructive) { confirmDelete = true }.disabled(isManaged)
                }

                HStack {
                    keyChip
                    Spacer()
                    Button("Kopieren", systemImage: "doc.on.doc") { model.copyKey(profile) }.disabled(!hasKey)
                    Button(hasKey ? LocalizedStringKey("Ändern") : LocalizedStringKey("Key hinterlegen"), systemImage: "pencil") { replacingKey = true }
                    Button("Verbindung prüfen") {
                        checking = true
                        checkResult = nil
                        Task {
                            checkResult = await model.testConnection(profile)
                            checking = false
                        }
                    }
                    .disabled(checking || !hasKey)
                }
                if checking { ProgressView().controlSize(.small) }
                if let checkResult {
                    Label(checkResult.message, systemImage: checkResult.isSuccess ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(checkResult.isSuccess ? .green : .orange)
                }

                assignedProjects
            }
            .padding(8)
        }
        .sheet(isPresented: $editing) { ProfileEditor(existing: profile) }
        .sheet(isPresented: $replacingKey) { ReplaceKeySheet(profile: profile) }
        .sheet(isPresented: $addingProject) { AddProjectSheet(preselectedProfile: profile.id) }
        .confirmationDialog("Profil „\(profile.name)“ löschen?", isPresented: $confirmDelete) {
            Button("Löschen", role: .destructive) { model.deleteProfile(profile) }
        } message: {
            if bindings.isEmpty {
                Text("Der Key wird aus dem Schlüsselbund entfernt.")
            } else {
                Text("Der Key wird aus dem Schlüsselbund entfernt und \(bindings.count) Projektzuordnung(en) werden zurückgenommen.")
            }
        }
        .onChange(of: profile) { checkResult = nil }
    }

    private var keyColor: Color { hasKey ? .green : .red }

    /// "Opus … · Sonnet … · Haiku …" for the tiers mapped to gateway model names.
    private var tierModels: String {
        [("Opus", profile.opusModel), ("Sonnet", profile.sonnetModel), ("Haiku", profile.haikuModel)]
            .compactMap { tier, model in model.map { "\(tier) \($0)" } }
            .joined(separator: " · ")
    }

    /// The key as a framed chip, so it reads as the thing the projects below are assigned to.
    private var keyChip: some View {
        HStack(spacing: 6) {
            Image(systemName: hasKey ? "key.fill" : "key.slash").foregroundStyle(keyColor)
            if hasKey {
                Text(verbatim: "Key \(model.keyHints[profile.id] ?? "••••")").monospaced()
            } else {
                Text("Kein Key hinterlegt – Anfragen schlagen fehl")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 6).fill(keyColor.opacity(0.10)))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(keyColor.opacity(0.45)))
    }

    /// Projects hang off the key: indented, joined by a connector line in the key's color, in their own panel.
    private var assignedProjects: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label {
                    if bindings.isEmpty {
                        Text("Noch keinem Projekt zugeordnet")
                    } else if bindings.count == 1 {
                        Text("Nutzen diesen Key · 1 Projekt")
                    } else {
                        Text("Nutzen diesen Key · \(bindings.count) Projekte")
                    }
                } icon: {
                    Image(systemName: "arrow.turn.down.right")
                }
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Projekt zuordnen …", systemImage: "folder.badge.plus") { addingProject = true }
            }
            if !bindings.isEmpty {
                VStack(spacing: 0) {
                    ForEach(Array(bindings.enumerated()), id: \.element.id) { index, binding in
                        if index > 0 { Divider() }
                        ProjectRow(binding: binding).padding(.horizontal, 12)
                    }
                }
                .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.2)))
            }
        }
        .padding(.leading, 28)
        .overlay(alignment: .leading) {
            // Starts right under the key icon of the chip above.
            Rectangle().fill(keyColor.opacity(0.45)).frame(width: 2).padding(.leading, 16).padding(.top, -12).padding(.bottom, 2)
        }
    }
}

struct ProjectRow: View {
    @Environment(AppModel.self) private var model
    let binding: WorkspaceBinding
    @ViewState private var confirmUnbind = false

    var body: some View {
        let status = model.statuses[binding.id]
        let keyPresent = model.keyPresent[binding.profileID] == true
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                StatusIcon(status: status, keyPresent: keyPresent)
                VStack(alignment: .leading, spacing: 1) {
                    Text(AppModel.folderName(binding.path)).fontWeight(.medium)
                    Text((binding.path as NSString).abbreviatingWithTildeInPath)
                        .font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                }
                Spacer()
                Picker("Profil", selection: Binding(get: { binding.profileID }, set: { model.bind(folder: binding.path, to: $0) })) {
                    ForEach(model.state.profiles) { Text($0.name).tag($0.id) }
                }
                .labelsHidden()
                .fixedSize()
                .help("Profil für dieses Projekt wechseln")
                Button("Im Finder zeigen", systemImage: "folder") {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: binding.path)])
                }
                .labelStyle(.iconOnly)
                Button("Erneut anwenden", systemImage: "arrow.triangle.2.circlepath") { model.reapply(binding) }
                    .labelStyle(.iconOnly)
                    .disabled(status?.health == .folderMissing)
                    .help("Einstellungen erneut schreiben")
                Button("Entfernen", systemImage: "trash", role: .destructive) { confirmUnbind = true }
                    .labelStyle(.iconOnly)
                    .help("Zuordnung entfernen")
            }
            if status?.health != .active || !keyPresent {
                Text(Self.describe(status?.health, keyPresent: keyPresent))
                    .font(.caption).foregroundStyle(StatusIcon.appearance(status, keyPresent: keyPresent).1)
            }
            ForEach(status?.conflicts ?? [], id: \.self) { conflict in
                Label(conflict.message, systemImage: conflict.severity == .blocking ? "xmark.octagon" : "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(conflict.severity == .blocking ? .red : .orange)
            }
        }
        .padding(.vertical, 4)
        .confirmationDialog("Zuordnung für „\(AppModel.folderName(binding.path))“ entfernen?", isPresented: $confirmUnbind) {
            Button("Entfernen", role: .destructive) { model.unbind(binding) }
        } message: {
            Text("Nur die von der App gesetzten Einträge werden aus .claude/settings.local.json entfernt. Andere Einstellungen bleiben erhalten.")
        }
    }

    static func describe(_ health: BindingHealth?, keyPresent: Bool) -> String {
        if !keyPresent && health == .active { return L("Für das Profil ist kein Key hinterlegt – Claude-Anfragen schlagen fehl.") }
        switch health {
        case .active: return L("Aktiv")
        case .notApplied: return L("Nicht eingerichtet – „Erneut anwenden“ wählen.")
        case .drifted(let keys): return L("Abweichung in \(keys.joined(separator: ", ")) – „Erneut anwenden“ wählen.")
        case .folderMissing: return L("Ordner nicht gefunden (verschoben oder gelöscht). Zuordnung entfernen und neu zuordnen.")
        case nil: return L("Status unbekannt")
        }
    }
}

struct VersionFooter: View {
    @Environment(AppModel.self) private var model
    var showHowItWorks: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            if let version = model.appVersion {
                Text(verbatim: "KeyZapper \(version)").foregroundStyle(.secondary)
            } else {
                Text("KeyZapper Entwicklungsversion").foregroundStyle(.secondary)
            }
            if model.config.updateCheckEnabled {
                Button("Nach Updates suchen") { Task { await model.checkForUpdates(userInitiated: true) } }
                    .buttonStyle(.link)
            } else {
                Text("Updates über die IT").foregroundStyle(.secondary)
            }
            Button("So funktioniert’s", action: showHowItWorks).buttonStyle(.link)
            Link("Projektseite", destination: URL(string: "https://github.com/\(UpdateChecker.repository)")!)
        }
        .font(.caption)
    }
}

struct BannerAction {
    var title: String
    var action: () -> Void
}

struct Banner: View {
    enum Kind { case info, warning }
    var kind: Kind
    var title: String
    var detail: String?
    var actions: [BannerAction] = []
    var dismiss: (() -> Void)?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: kind == .info ? "info.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(kind == .info ? Color.accentColor : .orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).fontWeight(kind == .warning ? .semibold : .regular)
                if let detail { Text(detail).font(.callout).foregroundStyle(.secondary) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
            ForEach(actions.indices, id: \.self) { i in Button(actions[i].title, action: actions[i].action) }
            if let dismiss { Button("Schließen", systemImage: "xmark", action: dismiss).labelStyle(.iconOnly).buttonStyle(.borderless) }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(kind == .info ? Color.accentColor.opacity(0.12) : Color.orange.opacity(0.15))
        .overlay(alignment: .bottom) { Divider() }
    }
}

struct StatusIcon: View {
    var status: BindingStatus?
    var keyPresent: Bool

    var body: some View {
        let (symbol, color) = Self.appearance(status, keyPresent: keyPresent)
        Image(systemName: symbol).foregroundStyle(color)
    }

    static func appearance(_ status: BindingStatus?, keyPresent: Bool) -> (String, Color) {
        guard let status else { return ("questionmark.circle", .secondary) }
        if status.health == .folderMissing || !keyPresent || status.conflicts.contains(where: { $0.severity == .blocking }) {
            return ("xmark.octagon.fill", .red)
        }
        if status.health != .active { return ("exclamationmark.triangle.fill", .orange) }
        return ("checkmark.circle.fill", .green)
    }
}
