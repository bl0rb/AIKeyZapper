**English** · [Deutsch](feasibility.de.md)

# Feasibility & Architecture Decision (Agent 1 / Orchestrator)

As of: 2026-10-03. Prototype: `spike/run_spike.sh [claude-binary]` (mock gateway `spike/mock_gateway.py`,
only `sk-test-*` keys, isolated `CLAUDE_CONFIG_DIR`; `REAL_CONFIG=1` additionally checks with a real login,
`SLOW=1` the 401 retry path). Automated: `KEYZAPPER_E2E_CLAUDE=<claude> swift test`.

## Tested versions

| Component | Version | Result |
|---|---|---|
| Claude Code (VS Code extension, bundled binary) | 2.1.288 | ✅ all core cases |
| Claude Code CLI (`~/.local/bin/claude`, used by IntelliJ) | 2.1.206 | ⚠️ only when started in the project root |
| VS Code | 1.138.0 | Binary checked; click path in the IDE to be verified manually in the pilot |
| IntelliJ IDEA | – | not installed → **open** (uses the system CLI) |
| macOS | 27.0, Swift 6.4 (Command Line Tools) | ✅ |

**Minimum version:** Claude Code ≥ 2.1.288. The app warns about older CLIs.

## Behavior (Claude Code 2.1.288)

| # | Case | Result |
|---|---|---|
| T1–T3 | Project A/B, path with spaces, simultaneously | each project sends its own key (`x-api-key` **and** `Authorization: Bearer`) |
| T4/T15 | Start in a subfolder of a Git repo | Settings of the repo root apply; subfolder binding is ignored |
| T5/T11 | Git worktree | Settings of the **main checkout** apply; the worktree's own binding is ignored |
| T16/T17 | Non-Git folder | only `<cwd>/.claude` counts; unbound subfolder → default auth |
| T6/T7 | `ANTHROPIC_API_KEY`/`_AUTH_TOKEN` in IDE/shell environment | **mixed headers** (one header with the env value, one with the helper key) |
| T12 | same variables, set to `""` in the project `env` | neutralized, helper key only |
| T8 | Key change, new session | new key immediately |
| T14 | Key change, running session | after `CLAUDE_CODE_API_KEY_HELPER_TTL_MS` expires (docs: default 5 min) the cached value is used once more and refreshed in the background; the following request uses the new key |
| T9 | server-side blocked key (401) | helper is called again on every retry, ~10 retries over ~4 min, then abort “Failed to authenticate” – no fallback |
| T10/T13/T19 | Helper fails (key missing), also with a real claude.ai login | Request with an **empty** credential to the gateway – no fallback to OAuth/other keys |
| T18 | real claude.ai login + helper | Helper key takes precedence |

Deviation in 2.1.206: settings only from `<cwd>/.claude` (T4/T5/T17 → “Not logged in”, T11/T15 use the subfolder binding).

## Decision

* **The helper approach holds up**, no proxy and no IDE plugin needed.
* The app writes to `<root>/.claude/settings.local.json` (highest unmanaged level):
  `apiKeyHelper = '<App>/Contents/Helpers/keyzapper-helper' credential --profile <UUID>`,
  `env.ANTHROPIC_BASE_URL`, optionally `env.ANTHROPIC_MODEL`, as well as `env.ANTHROPIC_API_KEY = ""` and
  `env.ANTHROPIC_AUTH_TOKEN = ""` (neutralization, T12).
* `<root>` = root of the main checkout for Git repos, otherwise the chosen folder. **One profile per repository**
  (applies to subfolders and worktrees); bindings to subfolders/worktrees are rejected.
* Only the helper accesses the Keychain (the app calls `store`/`delete`/`status`/`credential` via stdin/stdout)
  → the Keychain ACL trusts exactly one binary, no prompts on Claude calls.
* No custom `CLAUDE_CODE_API_KEY_HELPER_TTL_MS`: new keys apply immediately to new sessions; running ones after TTL, 401 or restart.
* **CC Switch:** switches the global Claude configuration (Tauri/Rust). This conflicts with parallel projects
  using different keys, and the stack does not fit → no code adopted, only the interaction concept (profile list, assignment by click).

## Interfaces (binding)

* Data model: `Profile`, `WorkspaceBinding`, `CredentialReference`, `AppState.schemaVersion = 1`
  (`Sources/KeyZapperCore/Models.swift`), stored in `~/Library/Application Support/KeyZapper/state.json` (0600, without keys).
* Helper: `keyzapper-helper credential|store|status|delete --profile <UUID>`; exit codes
  0 ok · 64 usage · 65 unknown profile · 66 key missing · 70 internal · 77 Keychain locked/denied · 78 metadata or endpoint not in `AllowedGatewayHosts`.
* Conflicts (blocking): managed settings with `apiKeyHelper`/`ANTHROPIC_BASE_URL`/`_API_KEY`/`_AUTH_TOKEN`;
  `CLAUDE_CODE_USE_BEDROCK|VERTEX|FOUNDRY` in any level; foreign values for app keys in `settings.local.json`;
  checked-in `settings.local.json`; invalid JSON. Warnings: the same keys in user/project `settings.json`.
* Rollback only removes values that still exactly match the app value, as well as the self-created line in `<git-common-dir>/info/exclude`.

## Remaining limitations / open items

* IntelliJ integration untested; the JetBrains integration uses the system CLI → verify in the pilot with CLI ≥ 2.1.288.
* Starting outside the bound area (non-Git subfolder, foreign folder) uses the developer's default auth.
* Process environment variables other than `ANTHROPIC_API_KEY`/`_AUTH_TOKEN` (e.g. `CLAUDE_CODE_USE_BEDROCK` from the shell) are not visible to the app.
* Ad-hoc-signed builds: after every rebuild the Keychain may prompt again; stable with a Developer ID signature (Agent 6).
* Streaming/tool calls via real LiteLLM → Bedrock, VPN outage, rate limit/budget against a real gateway: open (Agent 5, needs test keys).
