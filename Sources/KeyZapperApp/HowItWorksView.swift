import SwiftUI

/// Explains the mechanism: one-time assignment, then Claude Code fetches the right key itself via the helper.
struct HowItWorksView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("So funktioniert KeyZapper").font(.title2).fontWeight(.semibold)
            Text("Einmal zuordnen – danach musst du nie wieder Keys wechseln.")
                .font(.headline).foregroundStyle(.green)

            flow

            VStack(alignment: .leading, spacing: 10) {
                step(1, "Einmal einrichten", "Profil mit Key anlegen und Projektordner zuordnen. Der Key liegt nur im macOS-Schlüsselbund.")
                step(2, "Verweis statt Key", "KeyZapper schreibt in den Projektordner .claude/settings.local.json – darin steht nur, welcher Helper und welches Profil gilt, nie der Key selbst.")
                step(3, "Claude holt den Key selbst", "Startet Claude Code in VS Code, IntelliJ oder im Terminal, ruft es den Helper auf. Der liefert genau den Key dieses Projekts – auch wenn KeyZapper geschlossen ist.")
                step(4, "Mehrere Projekte parallel", "Jedes Projekt nutzt seinen eigenen Key, gleichzeitig und unabhängig voneinander.")
            }

            GroupBox("Gut zu wissen") {
                VStack(alignment: .leading, spacing: 6) {
                    hint("arrow.clockwise", "Nach dem Zuordnen oder einem Profilwechsel die Claude-Sitzung im Projekt einmal neu starten.")
                    hint("key", "Neuer Key? Einmal „Ändern“ – alle zugeordneten Projekte nutzen ihn automatisch. Neue Sitzungen sofort, laufende nach spätestens 5 Minuten.")
                    hint("folder", "Die Zuordnung gilt für das ganze Repository samt Unterordnern und Worktrees. Außerhalb zugeordneter Ordner nutzt Claude die normale Anmeldung.")
                    hint("lock.shield", "Fehlt ein Key, schlagen Anfragen fehl. Es wird nie ein anderer Key verwendet.")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(4)
            }
        }
        .padding(24)
        .frame(width: 560)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) { Button("Verstanden") { dismiss() } }
        }
    }

    private var flow: some View {
        HStack(spacing: 8) {
            node("terminal", "Claude Code", "im Projekt")
            arrow
            node("bolt.horizontal.circle", "keyzapper-helper", "--profile")
            arrow
            node("key", "Schlüsselbund", "Projekt-Key")
            arrow
            node("server.rack", "LiteLLM", "→ Bedrock")
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 4)
    }

    private var arrow: some View {
        Image(systemName: "arrow.right").foregroundStyle(.secondary)
    }

    private func node(_ symbol: String, _ title: LocalizedStringKey, _ subtitle: LocalizedStringKey) -> some View {
        VStack(spacing: 3) {
            Image(systemName: symbol).font(.title3).foregroundStyle(Color.accentColor)
            Text(title).font(.caption).fontWeight(.semibold)
            Text(subtitle).font(.caption2.monospaced()).foregroundStyle(.secondary)
        }
        .frame(minWidth: 96)
        .padding(.vertical, 8)
        .padding(.horizontal, 6)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.2)))
    }

    private func step(_ number: Int, _ title: LocalizedStringKey, _ text: LocalizedStringKey) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(verbatim: "\(number)")
                .font(.caption).fontWeight(.bold).foregroundStyle(.white)
                .frame(width: 20, height: 20)
                .background(Circle().fill(Color.accentColor))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).fontWeight(.semibold)
                Text(text).foregroundStyle(.secondary)
            }
        }
    }

    private func hint(_ symbol: String, _ text: LocalizedStringKey) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: symbol).foregroundStyle(.secondary).frame(width: 18)
            Text(text)
        }
        .font(.callout)
    }
}
