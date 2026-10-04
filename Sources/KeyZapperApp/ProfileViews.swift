import KeyZapperCore
import SwiftUI

struct ProfileEditor: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let existing: Profile?
    @ViewState private var name = ""
    @ViewState private var endpoint = ""
    @ViewState private var modelAlias = ""
    @ViewState private var opusModel = ""
    @ViewState private var sonnetModel = ""
    @ViewState private var haikuModel = ""
    @ViewState private var environmentText = ""
    @ViewState private var key = ""
    @ViewState private var gatewayModels: [String] = []
    @ViewState private var loadingModels = false

    private var endpointURL: URL? {
        guard let url = URL(string: endpoint.trimmingCharacters(in: .whitespaces)),
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host() != nil else { return nil }
        return url
    }

    private var isManaged: Bool { existing.map { model.isManaged($0.id) } ?? false }

    private var endpointAllowed: Bool { endpointURL.map(model.config.isEndpointAllowed) ?? true }

    private var parsedEnvironment: (values: [String: String], invalidLines: [String]) { Profile.parseEnvironment(environmentText) }

    private var isValid: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty && endpointURL != nil && endpointAllowed
            && (existing != nil || !key.isEmpty) && parsedEnvironment.invalidLines.isEmpty
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
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Section {
                modelField("Opus", text: $opusModel)
                modelField("Sonnet", text: $sonnetModel)
                modelField("Haiku", text: $haikuModel)
                modelField("Standardmodell", text: $modelAlias)
                HStack {
                    Button("Modelle vom Gateway laden") { loadModels() }
                        .disabled(endpointURL == nil || !endpointAllowed || loadingModels || (existing == nil && key.isEmpty))
                    if loadingModels { ProgressView().controlSize(.small) }
                    if !gatewayModels.isEmpty {
                        Text("\(String(gatewayModels.count)) Modelle verfügbar").font(.caption).foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Modelle")
            } footer: {
                Text("Eigene Modellnamen des Gateways für die Modellstufen von Claude Code. Leer lassen, um den Claude-Standard zu verwenden.")
                    .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.leading).frame(maxWidth: .infinity, alignment: .leading)
            }
            .disabled(isManaged)
            Section {
                TextEditor(text: $environmentText)
                    .font(.body.monospaced())
                    .frame(minHeight: 56)
                ForEach(parsedEnvironment.invalidLines, id: \.self) { line in
                    Text("Ungültig oder nicht erlaubt: \(line)").font(.caption).foregroundStyle(.red)
                }
            } header: {
                Text("Weitere Umgebungsvariablen")
            } footer: {
                Text("Eine pro Zeile im Format NAME=Wert, z. B. CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS=1 für Bedrock über LiteLLM. Key, Endpunkt und Modelle werden oben gesetzt.")
                    .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.leading).frame(maxWidth: .infinity, alignment: .leading)
            }
            .disabled(isManaged)
        }
        .formStyle(.grouped)
        .frame(width: 540)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Abbrechen") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button(existing == nil ? LocalizedStringKey("Anlegen") : LocalizedStringKey("Sichern")) {
                    guard let url = endpointURL else { return }
                    var profile = existing ?? Profile(name: name, endpoint: url, modelAlias: modelAlias)
                    profile.name = name.trimmingCharacters(in: .whitespaces)
                    profile.endpoint = url
                    profile.modelAlias = modelAlias.trimmingCharacters(in: .whitespaces)
                    profile.opusModel = Self.nonEmpty(opusModel)
                    profile.sonnetModel = Self.nonEmpty(sonnetModel)
                    profile.haikuModel = Self.nonEmpty(haikuModel)
                    let environment = parsedEnvironment.values
                    profile.environment = environment.isEmpty ? nil : environment
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
            opusModel = existing.opusModel ?? ""
            sonnetModel = existing.sonnetModel ?? ""
            haikuModel = existing.haikuModel ?? ""
            environmentText = Profile.formatEnvironment(existing.environment)
        }
    }

    /// Text field with a menu of the models the gateway reported for this key.
    private func modelField(_ title: LocalizedStringKey, text: Binding<String>) -> some View {
        HStack {
            TextField(title, text: text, prompt: Text("Claude-Standard"))
            Menu {
                ForEach(gatewayModels, id: \.self) { name in Button(name) { text.wrappedValue = name } }
                if !text.wrappedValue.isEmpty {
                    Divider()
                    Button("Claude-Standard verwenden") { text.wrappedValue = "" }
                }
            } label: {
                Image(systemName: "chevron.up.chevron.down")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .disabled(gatewayModels.isEmpty)
        }
    }

    private func loadModels() {
        guard let url = endpointURL else { return }
        loadingModels = true
        Task {
            let models = await model.availableModels(endpoint: url, typedKey: key, profileID: existing?.id)
            loadingModels = false
            guard let models, !models.isEmpty else { return }
            gatewayModels = models
            // Fill empty tiers with the best match, keep what the user already chose.
            let suggestion = ModelSuggestion.suggest(from: models)
            if opusModel.isEmpty { opusModel = suggestion.opus ?? "" }
            if sonnetModel.isEmpty { sonnetModel = suggestion.sonnet ?? "" }
            if haikuModel.isEmpty { haikuModel = suggestion.haiku ?? "" }
        }
    }

    private static func nonEmpty(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : trimmed
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
