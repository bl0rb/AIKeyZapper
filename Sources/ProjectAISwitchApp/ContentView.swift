import AISwitchCore
import SwiftUI

enum SidebarItem: Hashable {
    case profile(UUID)
    case project(UUID)
}

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @ViewState private var selection: SidebarItem?
    @ViewState private var showNewProfile = false
    @ViewState private var showAddProject = false

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Section("Profile") {
                    ForEach(model.state.profiles) { profile in
                        Label {
                            VStack(alignment: .leading) {
                                Text(profile.name)
                                Text(profile.endpoint.host() ?? profile.endpoint.absoluteString).font(.caption).foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: model.keyPresent[profile.id] == true ? "key.fill" : "key.slash")
                                .foregroundStyle(model.keyPresent[profile.id] == true ? Color.accentColor : .red)
                        }
                        .tag(SidebarItem.profile(profile.id))
                    }
                }
                Section("Projekte") {
                    ForEach(model.state.bindings) { binding in
                        Label {
                            VStack(alignment: .leading) {
                                Text(AppModel.folderName(binding.path))
                                Text(model.profileName(binding.profileID)).font(.caption).foregroundStyle(.secondary)
                            }
                        } icon: {
                            StatusIcon(status: model.statuses[binding.id], keyPresent: model.keyPresent[binding.profileID] == true)
                        }
                        .tag(SidebarItem.project(binding.id))
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 230, ideal: 260)
            .toolbar {
                ToolbarItemGroup {
                    Button { showNewProfile = true } label: { Label("Neues Profil", systemImage: "plus") }
                    Button { showAddProject = true } label: { Label("Projekt zuordnen", systemImage: "folder.badge.plus") }
                        .disabled(model.state.profiles.isEmpty)
                    Button { model.refresh() } label: { Label("Status aktualisieren", systemImage: "arrow.clockwise") }
                }
            }
        } detail: {
            detail
        }
        .safeAreaInset(edge: .top, spacing: 0) { banners }
        .sheet(isPresented: $showNewProfile) { ProfileEditor(existing: nil) }
        .sheet(isPresented: $showAddProject) { AddProjectSheet() }
        .alert("Fehler", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
    }

    @ViewBuilder private var detail: some View {
        switch selection {
        case .profile(let id):
            if let profile = model.state.profile(id) { ProfileDetailView(profile: profile) } else { placeholder }
        case .project(let id):
            if let binding = model.state.bindings.first(where: { $0.id == id }) { ProjectDetailView(binding: binding) } else { placeholder }
        case nil:
            placeholder
        }
    }

    @ViewBuilder private var placeholder: some View {
        if model.state.profiles.isEmpty {
            ContentUnavailableView {
                Label("Noch keine Profile", systemImage: "key")
            } description: {
                Text("Lege ein Profil mit LiteLLM-Endpunkt, Modellalias und deinem freigegebenen Key an.")
            } actions: {
                Button("Profil anlegen") { showNewProfile = true }.buttonStyle(.borderedProminent)
            }
        } else if model.state.bindings.isEmpty {
            ContentUnavailableView {
                Label("Noch keine Projekte zugeordnet", systemImage: "folder")
            } description: {
                Text("Ordne einen Projektordner einem Profil zu. Claude Code verwendet dort dann automatisch den passenden Key.")
            } actions: {
                Button("Projekt zuordnen") { showAddProject = true }.buttonStyle(.borderedProminent)
            }
        } else {
            ContentUnavailableView("Profil oder Projekt auswählen", systemImage: "sidebar.left")
        }
    }

    @ViewBuilder private var banners: some View {
        VStack(spacing: 0) {
            if !model.outdatedCLIs.isEmpty {
                Banner(kind: .warning, text: "Veraltete Claude-Code-CLI gefunden: \(model.outdatedCLIs.joined(separator: ", ")). Ältere Versionen lesen Projekteinstellungen nur beim Start im Projektordner selbst (relevant für IntelliJ). Bitte auf ≥ \(ClaudeCLI.minimumTestedVersion) aktualisieren.")
            }
            if let notice = model.notice {
                Banner(kind: .info, text: notice) { model.notice = nil }
            }
        }
    }
}

struct Banner: View {
    enum Kind { case info, warning }
    var kind: Kind
    var text: String
    var dismiss: (() -> Void)?

    var body: some View {
        HStack(alignment: .top) {
            Image(systemName: kind == .info ? "info.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(kind == .info ? Color.accentColor : .orange)
            Text(text).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
            if let dismiss { Button("Schließen", systemImage: "xmark", action: dismiss).labelStyle(.iconOnly).buttonStyle(.borderless) }
        }
        .padding(10)
        .background(kind == .info ? Color.accentColor.opacity(0.12) : Color.orange.opacity(0.15))
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
