import KeyZapperCore
import SwiftUI

struct AddProjectSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    var preselectedProfile: UUID?
    @ViewState private var folder: String?
    @ViewState private var profileID: UUID?
    @ViewState private var pickingFolder = false
    /// Resolved once per chosen folder (runs git), not on every render.
    @ViewState private var root: String?
    private var existing: WorkspaceBinding? { root.flatMap { r in model.state.bindings.first { $0.path == r } } }

    var body: some View {
        Form {
            Section {
                LabeledContent("Projektordner") {
                    HStack {
                        Group {
                            if let folder { Text(verbatim: folder) } else { Text("Kein Ordner gewählt").foregroundStyle(.secondary) }
                        }
                        .lineLimit(1).truncationMode(.middle)
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
            if case .success(let url) = result {
                folder = url.path
                root = ClaudeSettingsBinder.settingsRoot(for: url.path)
            }
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
        .onAppear { profileID = preselectedProfile ?? (model.state.profiles.count == 1 ? model.state.profiles.first?.id : nil) }
    }
}
