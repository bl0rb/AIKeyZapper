import AISwitchCore
import SwiftUI

struct ProfileEditor: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let existing: Profile?
    @ViewState private var name = ""
    @ViewState private var endpoint = ""
    @ViewState private var modelAlias = ""
    @ViewState private var key = ""

    private var endpointURL: URL? {
        guard let url = URL(string: endpoint.trimmingCharacters(in: .whitespaces)),
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host() != nil else { return nil }
        return url
    }

    private var isValid: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty && endpointURL != nil && (existing != nil || !key.isEmpty)
    }

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $name, prompt: Text("z. B. Projekt Alpha"))
                TextField("LiteLLM-Endpunkt", text: $endpoint, prompt: Text("https://litellm.firma.intern"))
                if !endpoint.isEmpty && endpointURL == nil {
                    Text("Bitte eine vollständige http(s)-URL angeben.").font(.caption).foregroundStyle(.red)
                }
                TextField("Modellalias", text: $modelAlias, prompt: Text("optional, z. B. claude-sonnet"))
            }
            Section {
                SecureField(existing == nil ? "Key" : "Neuer Key", text: $key, prompt: Text(existing == nil ? "sk-…" : "leer lassen, um den Key zu behalten"))
            } footer: {
                Text("Der Key wird ausschließlich im macOS-Schlüsselbund gespeichert.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Abbrechen") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button(existing == nil ? "Anlegen" : "Sichern") {
                    guard let url = endpointURL else { return }
                    var profile = existing ?? Profile(name: name, endpoint: url, modelAlias: modelAlias)
                    profile.name = name.trimmingCharacters(in: .whitespaces)
                    profile.endpoint = url
                    profile.modelAlias = modelAlias.trimmingCharacters(in: .whitespaces)
                    if model.saveProfile(profile, newKey: key) { dismiss() }
                }
                .disabled(!isValid)
            }
        }
        .onAppear {
            guard let existing else { return }
            name = existing.name
            endpoint = existing.endpoint.absoluteString
            modelAlias = existing.modelAlias
        }
    }
}

struct ReplaceKeySheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let profile: Profile
    @ViewState private var key = ""

    var body: some View {
        Form {
            SecureField("Neuer Key", text: $key)
            Text("Der bisherige Key für „\(profile.name)“ wird im Schlüsselbund ersetzt. Andere Profile bleiben unverändert.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        .frame(width: 420)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Abbrechen") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Ersetzen") { model.storeKey(key, for: profile); dismiss() }.disabled(key.isEmpty)
            }
        }
    }
}

struct ProfileDetailView: View {
    @Environment(AppModel.self) private var model
    let profile: Profile
    @ViewState private var editing = false
    @ViewState private var replacingKey = false
    @ViewState private var confirmDelete = false
    @ViewState private var checking = false
    @ViewState private var checkResult: GatewayCheckResult?

    private var bindings: [WorkspaceBinding] { model.state.bindings.filter { $0.profileID == profile.id } }

    var body: some View {
        Form {
            Section("Profil") {
                LabeledContent("Name", value: profile.name)
                LabeledContent("Endpunkt", value: profile.endpoint.absoluteString)
                LabeledContent("Modellalias", value: profile.modelAlias.isEmpty ? "– (Claude-Standard)" : profile.modelAlias)
                LabeledContent("Key") {
                    if model.keyPresent[profile.id] == true {
                        Label("im Schlüsselbund hinterlegt", systemImage: "checkmark.seal.fill").foregroundStyle(.green)
                    } else {
                        Label("fehlt – Anfragen schlagen fehl", systemImage: "xmark.octagon.fill").foregroundStyle(.red)
                    }
                }
            }
            Section("Verbindung") {
                HStack {
                    Button("Verbindung mit LiteLLM prüfen") {
                        checking = true
                        checkResult = nil
                        Task {
                            checkResult = await model.testConnection(profile)
                            checking = false
                        }
                    }
                    .disabled(checking || model.keyPresent[profile.id] != true)
                    if checking { ProgressView().controlSize(.small) }
                }
                if let checkResult {
                    let ok: Bool = { if case .ok(let available) = checkResult { return available != false } else { return false } }()
                    Label(checkResult.message, systemImage: ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(ok ? .green : .orange)
                }
            }
            Section("Zugeordnete Projekte") {
                if bindings.isEmpty {
                    Text("Keine").foregroundStyle(.secondary)
                } else {
                    ForEach(bindings) { binding in
                        Text(binding.path).textSelection(.enabled)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(profile.name)
        .toolbar {
            ToolbarItemGroup {
                Button("Bearbeiten") { editing = true }
                Button("Key ersetzen") { replacingKey = true }
                Button("Profil löschen", role: .destructive) { confirmDelete = true }
            }
        }
        .sheet(isPresented: $editing) { ProfileEditor(existing: profile) }
        .sheet(isPresented: $replacingKey) { ReplaceKeySheet(profile: profile) }
        .confirmationDialog("Profil „\(profile.name)“ löschen?", isPresented: $confirmDelete) {
            Button("Löschen", role: .destructive) { model.deleteProfile(profile) }
        } message: {
            Text(bindings.isEmpty
                 ? "Der Key wird aus dem Schlüsselbund entfernt."
                 : "Der Key wird aus dem Schlüsselbund entfernt und \(bindings.count) Projektzuordnung(en) werden zurückgenommen.")
        }
        .onChange(of: profile) { checkResult = nil }
    }
}
