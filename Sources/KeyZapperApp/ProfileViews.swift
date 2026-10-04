import KeyZapperCore
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

    private var isManaged: Bool { existing.map { model.isManaged($0.id) } ?? false }

    private var endpointAllowed: Bool { endpointURL.map(model.config.isEndpointAllowed) ?? true }

    private var isValid: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty && endpointURL != nil && endpointAllowed && (existing != nil || !key.isEmpty)
    }

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $name, prompt: Text("z. B. Projekt Alpha"))
                TextField("LiteLLM-Endpunkt", text: $endpoint, prompt: Text("https://litellm.firma.intern"))
                if !endpoint.isEmpty && endpointURL == nil {
                    Text("Bitte eine vollständige http(s)-URL angeben.").font(.caption).foregroundStyle(.red)
                } else if !endpointAllowed {
                    Text("Host nicht freigegeben. Erlaubt: \(model.config.allowedGatewayHosts.joined(separator: ", "))").font(.caption).foregroundStyle(.red)
                }
                TextField("Modellalias", text: $modelAlias, prompt: Text("optional, z. B. claude-sonnet"))
            } footer: {
                if isManaged { Text("Von der IT vorgegeben – nur der Key kann geändert werden.").font(.caption).foregroundStyle(.secondary) }
            }
            .disabled(isManaged)
            Section {
                if existing == nil {
                    SecureField("Key", text: $key, prompt: Text(verbatim: "sk-…"))
                } else {
                    SecureField("Neuer Key", text: $key, prompt: Text("leer lassen, um den Key zu behalten"))
                }
            } footer: {
                Text("Der Key wird ausschließlich im macOS-Schlüsselbund gespeichert.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Abbrechen") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button(existing == nil ? LocalizedStringKey("Anlegen") : LocalizedStringKey("Sichern")) {
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
            guard let existing else {
                endpoint = model.config.defaultEndpoint ?? ""
                modelAlias = model.config.defaultModelAlias ?? ""
                return
            }
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
