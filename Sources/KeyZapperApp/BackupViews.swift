import AppKit
import KeyZapperCore
import SwiftUI
import UniformTypeIdentifiers

private let backupType = UTType(filenameExtension: EncryptedBackup.fileExtension) ?? .data

struct ExportBackupSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @ViewState private var password = ""
    @ViewState private var confirmation = ""
    @ViewState private var working = false

    private var isValid: Bool { password.count >= EncryptedBackup.minimumPasswordLength && password == confirmation }

    var body: some View {
        Form {
            Section {
                SecureField("Passwort", text: $password)
                SecureField("Passwort wiederholen", text: $confirmation)
                if !confirmation.isEmpty && password != confirmation {
                    Text("Die Passwörter stimmen nicht überein.").font(.caption).foregroundStyle(.red)
                }
            } header: {
                Text("Backup exportieren")
            } footer: {
                Text("Mindestens \(String(EncryptedBackup.minimumPasswordLength)) Zeichen. Ohne dieses Passwort lässt sich das Backup nicht wiederherstellen – es wird nirgends gespeichert.")
                    .font(.caption).foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading).frame(maxWidth: .infinity, alignment: .leading)
            }
            Section {
                if model.config.allowKeyExport {
                    Label("Enthält Profile, Projektzuordnungen und Keys – verschlüsselt mit AES-256-GCM.", systemImage: "lock.doc")
                } else {
                    Label("Enthält Profile und Projektzuordnungen. Keys sind laut Firmenrichtlinie vom Export ausgenommen.", systemImage: "lock.doc")
                }
            }
            .font(.callout)
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Abbrechen") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Exportieren …") {
                    let panel = NSSavePanel()
                    panel.allowedContentTypes = [backupType]
                    panel.nameFieldStringValue = "KeyZapper-Backup-\(Date().formatted(.iso8601.year().month().day())).\(EncryptedBackup.fileExtension)"
                    guard panel.runModal() == .OK, let url = panel.url else { return }
                    working = true
                    Task {
                        let ok = await model.exportBackup(password: password, to: url)
                        working = false
                        if ok { dismiss() }
                    }
                }
                .disabled(!isValid || working)
            }
        }
        .overlay { if working { ProgressView() } }
    }
}

struct ImportBackupSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @ViewState private var file: URL?
    @ViewState private var password = ""
    @ViewState private var working = false

    var body: some View {
        Form {
            Section {
                LabeledContent("Backup-Datei") {
                    HStack {
                        Group {
                            if let file { Text(verbatim: file.lastPathComponent) } else { Text("Keine Datei gewählt").foregroundStyle(.secondary) }
                        }
                        .lineLimit(1).truncationMode(.middle)
                        Button("Auswählen …") {
                            let panel = NSOpenPanel()
                            panel.allowedContentTypes = [backupType]
                            panel.allowsMultipleSelection = false
                            if panel.runModal() == .OK { file = panel.url }
                        }
                    }
                }
                SecureField("Passwort", text: $password)
            } header: {
                Text("Backup importieren")
            } footer: {
                Text("Profile und Keys aus dem Backup überschreiben vorhandene mit gleicher ID. Projekte werden zugeordnet, sofern ihr Ordner auf diesem Mac existiert.")
                    .font(.caption).foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Abbrechen") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Importieren") {
                    guard let file else { return }
                    working = true
                    Task {
                        let ok = await model.importBackup(from: file, password: password)
                        working = false
                        if ok { dismiss() }
                    }
                }
                .disabled(file == nil || password.isEmpty || working)
            }
        }
        .overlay { if working { ProgressView() } }
    }
}
