# ProjectAISwitch

macOS-App, die freigegebene LiteLLM-Keys im Schlüsselbund verwaltet und Projektordnern zuordnet, sodass Claude Code
(VS Code, IntelliJ, CLI) pro Projekt automatisch den richtigen Key verwendet. Architektur und Testergebnisse: [docs/feasibility.md](docs/feasibility.md).

## Aufbau

* `Sources/AISwitchCore` – Datenmodell, Metadaten, Schlüsselbund, Helper-Logik, Claude-Einstellungen (`ClaudeSettingsBinder`)
* `Sources/KeyHelper` – `aiswitch-key-helper`, von Claude Code als `apiKeyHelper` aufgerufen
* `Sources/ProjectAISwitchApp` – SwiftUI-Oberfläche
* `spike/` – Integrationsprototyp mit Mock-Gateway

## Bauen & testen

```bash
swift test
```

```bash
AISWITCH_E2E_CLAUDE="$(which claude)" swift test
```

```bash
scripts/build-app.sh
```

Das App-Bundle landet in `dist/ProjectAISwitch.app`. Für Releases `SIGN_IDENTITY="Developer ID Application: …"` setzen.

## Nutzung

1. Profil anlegen: Name, LiteLLM-Endpunkt, optional Modellalias, Key.
2. „Projekt zuordnen“: Ordner wählen (bei Git-Repos wird der Repository-Root verwendet), Profil wählen.
3. Claude-Sitzung im Projekt neu starten. Rücknahme über „Zuordnung entfernen“ entfernt nur die App-Einträge.
