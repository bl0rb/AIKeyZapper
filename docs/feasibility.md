# Machbarkeit & Architekturentscheidung (Agent 1 / Orchestrator)

Stand: 2026-10-03. Prototyp: `spike/run_spike.sh [claude-binary]` (Mock-Gateway `spike/mock_gateway.py`,
nur `sk-test-*`-Keys, isoliertes `CLAUDE_CONFIG_DIR`; `REAL_CONFIG=1` prüft zusätzlich mit echtem Login,
`SLOW=1` den 401-Retry-Pfad). Automatisiert: `AISWITCH_E2E_CLAUDE=<claude> swift test`.

## Getestete Versionen

| Komponente | Version | Ergebnis |
|---|---|---|
| Claude Code (VS-Code-Erweiterung, gebündeltes Binary) | 2.1.288 | ✅ alle Kernfälle |
| Claude Code CLI (`~/.local/bin/claude`, von IntelliJ genutzt) | 2.1.206 | ⚠️ nur bei Start im Projektroot |
| VS Code | 1.138.0 | Binary geprüft; Klickpfad in der IDE manuell im Pilot prüfen |
| IntelliJ IDEA | – | nicht installiert → **offen** (nutzt die System-CLI) |
| macOS | 27.0, Swift 6.4 (Command Line Tools) | ✅ |

**Mindestversion:** Claude Code ≥ 2.1.288. Die App warnt bei älteren CLIs.

## Verhalten (Claude Code 2.1.288)

| # | Fall | Ergebnis |
|---|---|---|
| T1–T3 | Projekt A/B, Pfad mit Leerzeichen, gleichzeitig | jedes Projekt sendet seinen Key (`x-api-key` **und** `Authorization: Bearer`) |
| T4/T15 | Start in Unterordner eines Git-Repos | Einstellungen des Repo-Roots gelten; Unterordner-Bindung wird ignoriert |
| T5/T11 | Git-Worktree | Einstellungen des **Haupt-Checkouts** gelten; eigene Worktree-Bindung wird ignoriert |
| T16/T17 | Nicht-Git-Ordner | nur `<cwd>/.claude` zählt; ungebundener Unterordner → Standard-Auth |
| T6/T7 | `ANTHROPIC_API_KEY`/`_AUTH_TOKEN` in IDE-/Shell-Umgebung | **gemischte Header** (ein Header Env-Wert, einer Helper-Key) |
| T12 | dieselben Variablen, im Projekt-`env` auf `""` gesetzt | neutralisiert, nur Helper-Key |
| T8 | Keywechsel, neue Sitzung | neuer Key sofort |
| T14 | Keywechsel, laufende Sitzung | nach Ablauf von `CLAUDE_CODE_API_KEY_HELPER_TTL_MS` (Doku: Standard 5 min) wird der Cache-Wert noch einmal genutzt und im Hintergrund erneuert; der Folge-Request nutzt den neuen Key |
| T9 | serverseitig gesperrter Key (401) | Helper wird bei jedem Retry erneut aufgerufen, ~10 Retries über ~4 min, dann Abbruch „Failed to authenticate“ – kein Wechsel |
| T10/T13/T19 | Helper schlägt fehl (Key fehlt), auch mit echtem claude.ai-Login | Request mit **leerem** Credential an das Gateway – kein Rückfall auf OAuth/andere Keys |
| T18 | echter claude.ai-Login + Helper | Helper-Key hat Vorrang |

Abweichung 2.1.206: Einstellungen nur aus `<cwd>/.claude` (T4/T5/T17 → „Not logged in“, T11/T15 nutzen die Unterordner-Bindung).

## Entscheidung

* **Helper-Ansatz trägt**, kein Proxy und kein IDE-Plugin nötig.
* Die App schreibt in `<root>/.claude/settings.local.json` (höchste nicht verwaltete Ebene):
  `apiKeyHelper = '<App>/Contents/Helpers/aiswitch-key-helper' credential --profile <UUID>`,
  `env.ANTHROPIC_BASE_URL`, optional `env.ANTHROPIC_MODEL`, sowie `env.ANTHROPIC_API_KEY = ""` und
  `env.ANTHROPIC_AUTH_TOKEN = ""` (Neutralisierung, T12).
* `<root>` = Root des Haupt-Checkouts bei Git-Repos, sonst der gewählte Ordner. **Ein Profil pro Repository**
  (gilt für Unterordner und Worktrees); Bindungen an Unterordner/Worktrees werden abgelehnt.
* Nur der Helper greift auf den Schlüsselbund zu (App ruft `store`/`delete`/`status`/`credential` per stdin/stdout auf)
  → die Keychain-ACL vertraut genau einem Binary, keine Rückfragen bei Claude-Aufrufen.
* Kein eigener `CLAUDE_CODE_API_KEY_HELPER_TTL_MS`: neue Keys gelten sofort für neue Sitzungen; laufende nach TTL, 401 oder Neustart.
* **CC Switch:** schaltet die globale Claude-Konfiguration um (Tauri/Rust). Das widerspricht parallelen Projekten
  mit unterschiedlichen Keys, und der Stack passt nicht → kein Code übernommen, nur das Bedienkonzept (Profilliste, Zuordnung per Klick).

## Schnittstellen (verbindlich)

* Datenmodell: `Profile`, `WorkspaceBinding`, `CredentialReference`, `AppState.schemaVersion = 1`
  (`Sources/AISwitchCore/Models.swift`), gespeichert in `~/Library/Application Support/ProjectAISwitch/state.json` (0600, ohne Keys).
* Helper: `aiswitch-key-helper credential|store|status|delete --profile <UUID>`; Exit-Codes
  0 ok · 64 Aufruf · 65 unbekanntes Profil · 66 Key fehlt · 70 intern · 77 Schlüsselbund gesperrt/verweigert · 78 Metadaten.
* Konflikte (blockierend): verwaltete Einstellungen mit `apiKeyHelper`/`ANTHROPIC_BASE_URL`/`_API_KEY`/`_AUTH_TOKEN`;
  `CLAUDE_CODE_USE_BEDROCK|VERTEX|FOUNDRY` in einer Ebene; fremde Werte für App-Schlüssel in `settings.local.json`;
  eingecheckte `settings.local.json`; ungültiges JSON. Warnungen: dieselben Schlüssel in Benutzer-/Projekt-`settings.json`.
* Rücknahme entfernt nur Werte, die noch exakt dem App-Wert entsprechen, sowie die selbst angelegte Zeile in `<git-common-dir>/info/exclude`.

## Verbleibende Einschränkungen / offene Punkte

* IntelliJ-Integration ungetestet; die JetBrains-Integration nutzt die System-CLI → im Pilot mit CLI ≥ 2.1.288 prüfen.
* Start außerhalb des gebundenen Bereichs (Nicht-Git-Unterordner, fremder Ordner) nutzt die Standard-Auth des Entwicklers.
* Prozess-Umgebungsvariablen außer `ANTHROPIC_API_KEY`/`_AUTH_TOKEN` (z. B. `CLAUDE_CODE_USE_BEDROCK` aus der Shell) sieht die App nicht.
* Ad-hoc-signierte Builds: nach jedem Neubau fragt der Schlüsselbund ggf. erneut nach; mit Developer-ID-Signatur stabil (Agent 6).
* Streaming/Tool-Aufrufe über echtes LiteLLM → Bedrock, VPN-Ausfall, Rate-Limit/Budget gegen echtes Gateway: offen (Agent 5, benötigt Testkeys).
