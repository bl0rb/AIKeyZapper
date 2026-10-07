use keyzapper_core::backup::{self, BackupError, BackupPayload};
use keyzapper_core::errors::Error;
use keyzapper_core::helper::{ExitCode, HelperCommand};
use keyzapper_core::keys::KeyStore;
use keyzapper_core::managed::ManagedConfig;
use keyzapper_core::metadata::MetadataStore;
use keyzapper_core::models::{AppState, Profile, WorkspaceBinding};
use keyzapper_core::paths::canonical_path;
use keyzapper_core::settings::{self, BindingHealth, SettingsBinder, GIT_EXCLUDE_LINE};
use serde_json::{json, Value};
use std::collections::BTreeMap;
use std::path::Path;
use std::process::Command;

const ALPHA: &str = "6F1E2D3C-4B5A-4978-8695-A4B3C2D1E0F9";
const BETA: &str = "0A1B2C3D-4E5F-4061-8273-94A5B6C7D8E9";

fn temp_dir(name: &str) -> String {
    let dir = std::env::temp_dir().join(format!("kz-{}", uuid::Uuid::new_v4())).join(name);
    std::fs::create_dir_all(&dir).unwrap();
    canonical_path(&dir.to_string_lossy())
}

fn sample() -> Profile {
    let mut p = Profile::new(ALPHA.into(), "Alpha".into(), "https://litellm.example.test/".into(), "claude-alpha".into());
    p.opus_model = Some("team-opus".into());
    p
}

fn other() -> Profile {
    Profile::new(BETA.into(), "Beta".into(), "https://litellm-b.example.test".into(), String::new())
}

fn binder() -> SettingsBinder {
    SettingsBinder {
        helper_path: "/Applications/Project AI'Switch.app/Contents/MacOS/keyzapper-helper".into(),
        managed_settings_paths: vec![],
        user_settings_path: "/nonexistent/settings.json".into(),
    }
}

fn read(path: &str) -> Value {
    serde_json::from_str(&std::fs::read_to_string(path).unwrap()).unwrap()
}

fn write(path: &str, value: Value) {
    std::fs::create_dir_all(Path::new(path).parent().unwrap()).unwrap();
    std::fs::write(path, value.to_string()).unwrap();
}

fn git(dir: &str, args: &[&str]) -> Option<String> {
    let out = Command::new("git").args(["-c", "user.email=t@t", "-c", "user.name=t"]).args(args).current_dir(dir).output().unwrap();
    out.status.success().then(|| String::from_utf8_lossy(&out.stdout).into_owned())
}

fn git_init(dir: &str) {
    assert!(git(dir, &["init", "-q"]).is_some() && git(dir, &["commit", "-q", "--allow-empty", "-m", "init"]).is_some());
}

fn local(root: &str) -> String {
    format!("{root}/.claude/settings.local.json")
}

#[test]
fn applies_idempotently_and_preserves_other_settings() {
    let root = temp_dir("proj with space");
    write(&local(&root), json!({"permissions": {"allow": ["Bash(ls)"]}, "env": {"FOO": "bar"}}));
    let first = binder().apply(&sample(), &root, None, false).unwrap();
    assert!(first.changed);
    let settings = read(&local(&root));
    assert_eq!(settings["permissions"]["allow"], json!(["Bash(ls)"]));
    assert_eq!(settings["env"]["FOO"], "bar");
    assert_eq!(settings["env"]["ANTHROPIC_BASE_URL"], "https://litellm.example.test");
    assert_eq!(settings["env"]["ANTHROPIC_MODEL"], "claude-alpha");
    assert_eq!(settings["env"]["ANTHROPIC_DEFAULT_OPUS_MODEL"], "team-opus");
    assert_eq!(settings["env"]["ANTHROPIC_API_KEY"], "");
    assert!(settings["apiKeyHelper"].as_str().unwrap().ends_with(&format!("credential --profile {ALPHA}")));

    let bytes = std::fs::read(local(&root)).unwrap();
    let second = binder().apply(&sample(), &root, Some(&first.binding), false).unwrap();
    assert!(!second.changed);
    assert_eq!(second.binding, first.binding);
    assert_eq!(std::fs::read(local(&root)).unwrap(), bytes);
    assert_eq!(binder().inspect(&first.binding, &sample(), &BTreeMap::new()).health, BindingHealth::Active);
}

#[cfg(unix)]
#[test]
fn helper_command_survives_spaces_and_quotes_in_path() {
    use std::os::unix::fs::PermissionsExt;
    let dir = temp_dir("helper dir's");
    let helper = format!("{dir}/keyzapper-helper");
    std::fs::write(&helper, "#!/bin/sh\nprintf 'ok:%s' \"$3\"\n").unwrap();
    std::fs::set_permissions(&helper, std::fs::Permissions::from_mode(0o755)).unwrap();
    let b = SettingsBinder { helper_path: helper, ..binder() };
    let command = b.desired_values(&sample(), false)["apiKeyHelper"].clone();
    let out = Command::new("/bin/sh").arg("-c").arg(&command).output().unwrap();
    assert_eq!(String::from_utf8_lossy(&out.stdout), format!("ok:{ALPHA}"));
}

/// Claude Code runs `apiKeyHelper` through `cmd /d /s /c` on Windows.
#[cfg(windows)]
#[test]
fn helper_command_survives_spaces_in_path_under_cmd() {
    use std::os::windows::process::CommandExt;
    let dir = temp_dir("helper dir");
    let helper = format!("{dir}\\keyzapper-helper.cmd");
    std::fs::write(&helper, "@echo ok:%3\r\n").unwrap();
    let b = SettingsBinder { helper_path: helper, ..binder() };
    let command = b.desired_values(&sample(), false)["apiKeyHelper"].clone();
    let out = Command::new("cmd.exe").raw_arg(format!("/d /s /c \"{command}\"")).output().unwrap();
    assert_eq!(String::from_utf8_lossy(&out.stdout).trim(), format!("ok:{ALPHA}"));
}

#[test]
fn toggles_pool_mode_and_removes_its_cache_setting_again() {
    let root = temp_dir("proj");
    let pooled = binder().apply(&sample(), &root, None, true).unwrap();
    assert!(pooled.binding.is_pooled());
    assert!(read(&local(&root))["apiKeyHelper"].as_str().unwrap().ends_with(&format!("pool --profile {ALPHA}")));
    let plain = binder().apply(&sample(), &root, Some(&pooled.binding), false).unwrap();
    assert_eq!(plain.binding.pooled, None);
    assert!(read(&local(&root))["env"].get("CLAUDE_CODE_API_KEY_HELPER_TTL_MS").is_none());
    assert_eq!(binder().inspect(&plain.binding, &sample(), &BTreeMap::new()).health, BindingHealth::Active);
}

#[test]
fn foreign_values_are_conflicts_and_left_untouched() {
    let root = temp_dir("proj");
    write(&local(&root), json!({"apiKeyHelper": "/usr/local/bin/other", "env": {"ANTHROPIC_API_KEY": "sk-user"}}));
    let before = std::fs::read(local(&root)).unwrap();
    match binder().apply(&sample(), &root, None, false) {
        Err(Error::SettingsConflicts(conflicts)) => {
            assert_eq!(conflicts.len(), 2);
            assert!(!conflicts.iter().any(|c| c.message.contains("sk-user")));
        }
        other => panic!("expected conflicts, got {:?}", other.err()),
    }
    assert_eq!(std::fs::read(local(&root)).unwrap(), before);
}

#[test]
fn switching_profile_replaces_only_own_values() {
    let root = temp_dir("proj");
    let a = binder().apply(&sample(), &root, None, false).unwrap();
    let b = binder().apply(&other(), &root, Some(&a.binding), false).unwrap();
    let env = &read(&local(&root))["env"];
    assert_eq!(env["ANTHROPIC_BASE_URL"], "https://litellm-b.example.test");
    assert!(env.get("ANTHROPIC_MODEL").is_none());
    assert_eq!(b.binding.id, a.binding.id);
    assert_eq!(b.binding.profile_id, BETA);
}

#[test]
fn user_edited_value_blocks_reapply_and_survives_revert() {
    let root = temp_dir("proj");
    let a = binder().apply(&sample(), &root, None, false).unwrap();
    let mut settings = read(&local(&root));
    settings["env"]["ANTHROPIC_MODEL"] = json!("user-choice");
    settings["model"] = json!("opus");
    write(&local(&root), settings);
    assert_eq!(
        binder().inspect(&a.binding, &sample(), &BTreeMap::new()).health,
        BindingHealth::Drifted(vec!["env.ANTHROPIC_MODEL".into()])
    );
    assert!(binder().apply(&sample(), &root, None, false).is_err());
    assert_eq!(binder().revert(&a.binding).unwrap(), vec!["env.ANTHROPIC_MODEL".to_string()]);
    let after = read(&local(&root));
    assert!(after.get("apiKeyHelper").is_none());
    assert_eq!(after["model"], "opus");
    assert_eq!(after["env"], json!({"ANTHROPIC_MODEL": "user-choice"}));
}

#[test]
fn revert_deletes_file_created_only_for_the_binding() {
    let root = temp_dir("proj");
    let a = binder().apply(&sample(), &root, None, false).unwrap();
    assert!(binder().revert(&a.binding).unwrap().is_empty());
    assert!(!Path::new(&local(&root)).exists());
    assert!(!Path::new(&format!("{root}/.claude")).exists());
    assert_eq!(binder().inspect(&a.binding, &sample(), &BTreeMap::new()).health, BindingHealth::NotApplied);
}

#[test]
fn invalid_json_is_not_overwritten_and_missing_folder_is_reported() {
    let root = temp_dir("proj");
    std::fs::create_dir_all(format!("{root}/.claude")).unwrap();
    std::fs::write(local(&root), "{ broken").unwrap();
    assert!(binder().apply(&sample(), &root, None, false).is_err());
    assert_eq!(std::fs::read_to_string(local(&root)).unwrap(), "{ broken");

    let gone = format!("{root}/gone");
    let binding = WorkspaceBinding::new(gone.clone(), ALPHA.into());
    assert_eq!(binder().inspect(&binding, &sample(), &BTreeMap::new()).health, BindingHealth::FolderMissing);
    assert_eq!(binder().apply(&sample(), &gone, None, false).err(), Some(Error::FolderNotFound(canonical_path(&gone))));
}

#[test]
fn trailing_comma_is_reported_and_repaired_by_reapply() {
    let root = temp_dir("proj");
    let applied = binder().apply(&sample(), &root, None, false).unwrap();
    let text = std::fs::read_to_string(local(&root)).unwrap();
    std::fs::write(local(&root), text.replacen("\"apiKeyHelper\"", "\"model\": \"opus\",\n  \"apiKeyHelper\"", 1).replace("\n}", ",\n}")).unwrap();
    assert!(settings::is_unparsable_json(&local(&root)));
    let status = binder().inspect(&applied.binding, &sample(), &BTreeMap::new());
    assert!(status.conflicts.iter().any(|c| c.blocking));
    let again = binder().apply(&sample(), &root, Some(&applied.binding), false).unwrap();
    assert!(again.changed);
    assert!(!settings::is_unparsable_json(&local(&root)));
    assert_eq!(read(&local(&root))["model"], "opus");
}

#[test]
fn managed_settings_and_provider_switches_block() {
    let root = temp_dir("proj");
    let managed = format!("{}/managed-settings.json", temp_dir("managed"));
    write(&managed, json!({"apiKeyHelper": "/opt/corp/helper"}));
    let user = format!("{}/settings.json", temp_dir("user"));
    write(&user, json!({"env": {"CLAUDE_CODE_USE_BEDROCK": "1", "ANTHROPIC_API_KEY": "x"}}));
    let strict = SettingsBinder { helper_path: "/h".into(), managed_settings_paths: vec![managed], user_settings_path: user };
    let conflicts = strict.environment_conflicts(&root, &BTreeMap::new());
    assert_eq!(conflicts.iter().filter(|c| c.blocking).count(), 2);
    assert_eq!(conflicts.iter().filter(|c| !c.blocking).count(), 1);
    assert!(strict.apply(&sample(), &root, None, false).is_err());
    assert!(!Path::new(&local(&root)).exists());
}

#[test]
fn global_profile_is_written_reverted_and_repair_removes_plaintext_keys() {
    let user = format!("{}/settings.json", temp_dir("home"));
    std::fs::write(&user, r#"{"model": "opus", "env": {"ANTHROPIC_API_KEY": "sk-plain", "DEBUG": 1, }, }"#).unwrap();
    let b = SettingsBinder { user_settings_path: user.clone(), ..binder() };
    let backup = b.repair_user_settings().unwrap().unwrap();
    assert!(backup.exists());
    let repaired = read(&user);
    assert!(repaired["env"].get("ANTHROPIC_API_KEY").is_none());
    assert_eq!(repaired["env"]["DEBUG"], "1");
    assert!(repaired["$schema"].is_string());

    let global = b.apply_global(&sample(), None).unwrap();
    assert_eq!(b.inspect_global(&global.binding, &sample()), BindingHealth::Active);
    assert!(b.revert_global(&global.binding).unwrap().is_empty());
    let after = read(&user);
    assert!(after.get("apiKeyHelper").is_none());
    assert_eq!(after["model"], "opus");
}

#[test]
fn subfolders_and_worktrees_resolve_to_main_root_and_git_exclude_is_managed() {
    let repo = temp_dir("repo");
    git_init(&repo);
    std::fs::create_dir_all(format!("{repo}/sub/deep")).unwrap();
    let worktree = canonical_path(&format!("{}/repo wt", Path::new(&repo).parent().unwrap().display()));
    assert!(git(&repo, &["worktree", "add", "-q", "--detach", &worktree]).is_some());
    assert_eq!(settings::settings_root(&format!("{repo}/sub/deep")), repo);
    assert_eq!(settings::settings_root(&worktree), repo);
    assert!(matches!(binder().apply(&sample(), &format!("{repo}/sub"), None, false), Err(Error::NotSettingsRoot { .. })));

    let first = binder().apply(&sample(), &repo, None, false).unwrap();
    assert_eq!(first.binding.git_exclude_entry.as_deref(), Some(GIT_EXCLUDE_LINE));
    assert!(git(&repo, &["check-ignore", "-q", ".claude/settings.local.json"]).is_some());
    assert_eq!(git(&repo, &["status", "--porcelain"]).as_deref(), Some(""));
    let second = binder().apply(&sample(), &repo, Some(&first.binding), false).unwrap();
    let exclude = std::fs::read_to_string(format!("{repo}/.git/info/exclude")).unwrap();
    assert_eq!(exclude.matches(GIT_EXCLUDE_LINE).count(), 1);
    binder().revert(&second.binding).unwrap();
    assert!(!std::fs::read_to_string(format!("{repo}/.git/info/exclude")).unwrap().contains(GIT_EXCLUDE_LINE));
}

#[test]
fn tracked_local_settings_block() {
    let repo = temp_dir("repo");
    git_init(&repo);
    write(&local(&repo), json!({"model": "opus"}));
    assert!(git(&repo, &["add", "-f", ".claude/settings.local.json"]).is_some() && git(&repo, &["commit", "-qm", "add"]).is_some());
    assert!(binder().apply(&sample(), &repo, None, false).is_err());
}

#[test]
fn metadata_round_trip_rejects_newer_schema_and_reads_macos_files() {
    let dir = temp_dir("meta");
    let store = MetadataStore::new(Path::new(&dir).join("sub/state.json"), true);
    assert_eq!(store.load().unwrap(), AppState::default());
    let state = AppState { profiles: vec![sample()], bindings: vec![WorkspaceBinding::new("/x".into(), ALPHA.into())], ..AppState::default() };
    store.save(&state).unwrap();
    assert_eq!(store.load().unwrap(), state);
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        assert_eq!(std::fs::metadata(store.path()).unwrap().permissions().mode() & 0o777, 0o600);
    }
    assert_eq!(MetadataStore::decode(br#"{"schemaVersion":99,"profiles":[],"bindings":[]}"#), Err(Error::UnsupportedSchemaVersion(99)));
    assert!(MetadataStore::decode(b"nope").is_err());

    // Written by the macOS app (lowercase ID accepted, normalised).
    let swift = br#"{"bindings":[{"id":"11111111-2222-4333-8444-555555555555","managedValues":{},"path":"\/p","profileID":"6f1e2d3c-4b5a-4978-8695-a4b3c2d1e0f9"}],
        "profiles":[{"credential":{"account":"6F1E2D3C-4B5A-4978-8695-A4B3C2D1E0F9","service":"KeyZapper.LiteLLM"},"endpoint":"https:\/\/litellm.example.test","id":"6F1E2D3C-4B5A-4978-8695-A4B3C2D1E0F9","modelAlias":"","name":"Alpha"}],
        "schemaVersion":1}"#;
    let decoded = MetadataStore::decode(swift).unwrap();
    assert_eq!(decoded.bindings[0].profile_id, ALPHA);
    assert_eq!(decoded.bindings[0].path, "/p");
}

fn helper(dir: &str, budgets: BTreeMap<String, f64>) -> HelperCommand {
    HelperCommand {
        metadata: MetadataStore::new(Path::new(dir).join("state.json"), true),
        store: KeyStore { file: Path::new(dir).join("keys.json") },
        config: ManagedConfig::default(),
        remaining_budget: Box::new(move |_, key| budgets.get(key).copied()),
    }
}

fn args(command: &str, id: &str) -> Vec<String> {
    vec![command.into(), "--profile".into(), id.into()]
}

#[test]
fn helper_returns_only_requested_key_and_never_falls_back() {
    let dir = temp_dir("helper");
    let h = helper(&dir, BTreeMap::new());
    h.metadata.save(&AppState { profiles: vec![sample(), other()], ..AppState::default() }).unwrap();
    assert_eq!(h.run(&args("store", ALPHA), || "sk-alpha\n".into()).exit_code, ExitCode::Ok);
    assert_eq!(h.run(&args("store", BETA), || "sk-beta".into()).exit_code, ExitCode::Ok);
    let out = h.run(&args("credential", &ALPHA.to_lowercase()), String::new);
    assert_eq!((out.exit_code, out.stdout.as_str()), (ExitCode::Ok, "sk-alpha"));
    assert_eq!(h.run(&args("credential", BETA), String::new).stdout, "sk-beta");
    assert_eq!(h.run(&args("store", ALPHA), || " \n".into()).exit_code, ExitCode::MissingCredential);
    assert_eq!(h.run(&args("status", ALPHA), String::new).exit_code, ExitCode::Ok);
    assert_eq!(h.run(&args("delete", ALPHA), String::new).exit_code, ExitCode::Ok);
    let missing = h.run(&args("credential", ALPHA), String::new);
    assert_eq!(missing.exit_code, ExitCode::MissingCredential);
    assert!(missing.stdout.is_empty() && !missing.stderr.contains("sk-"));
    assert_eq!(h.run(&args("credential", "6F1E2D3C-0000-4978-8695-A4B3C2D1E0F9"), String::new).exit_code, ExitCode::UnknownProfile);
    assert_eq!(h.run(&args("credential", "not-a-uuid"), String::new).exit_code, ExitCode::UnknownProfile);
    assert_eq!(h.run(&["credential".into()], String::new).exit_code, ExitCode::Usage);
    assert_eq!(h.run(&args("export", BETA), String::new).exit_code, ExitCode::Usage);
}

#[test]
fn helper_respects_gateway_allowlist() {
    let dir = temp_dir("helper");
    let mut h = helper(&dir, BTreeMap::new());
    h.metadata.save(&AppState { profiles: vec![sample()], ..AppState::default() }).unwrap();
    h.store.write(ALPHA, "sk-alpha").unwrap();
    h.config.allowed_gateway_hosts = vec!["litellm.firma.example".into()];
    assert_eq!(h.run(&args("credential", ALPHA), String::new).exit_code, ExitCode::ConfigError);
}

#[test]
fn pool_falls_back_to_key_with_most_budget_on_same_endpoint() {
    let dir = temp_dir("pool");
    let gamma = Profile::new("1A1B2C3D-4E5F-4061-8273-94A5B6C7D8E9".into(), "Gamma".into(), "https://litellm.example.test".into(), String::new());
    let delta = Profile::new("2A1B2C3D-4E5F-4061-8273-94A5B6C7D8E9".into(), "Delta".into(), "https://litellm.example.test/".into(), String::new());
    let left = |alpha: f64| BTreeMap::from([("sk-alpha".into(), alpha), ("sk-beta".into(), 100.0), ("sk-gamma".into(), 5.0), ("sk-delta".into(), 8.0)]);
    let setup = |h: &HelperCommand| {
        h.metadata.save(&AppState { profiles: vec![sample(), other(), gamma.clone(), delta.clone()], ..AppState::default() }).unwrap();
        for (id, key) in [(ALPHA, "sk-alpha"), (BETA, "sk-beta"), (gamma.id.as_str(), "sk-gamma"), (delta.id.as_str(), "sk-delta")] {
            h.store.write(id, key).unwrap();
        }
    };
    let h = helper(&dir, left(1.0));
    setup(&h);
    assert_eq!(h.run(&args("pool", ALPHA), String::new).stdout, "sk-alpha");
    let h = helper(&dir, left(0.0));
    assert_eq!(h.run(&args("pool", ALPHA), String::new).stdout, "sk-delta");
}

fn payload() -> BackupPayload {
    BackupPayload {
        created_at: "2026-09-21T14:13:20Z".into(),
        app_version: Some("1.0.3".into()),
        state: AppState { profiles: vec![sample()], bindings: vec![WorkspaceBinding::new("/p".into(), ALPHA.into())], ..AppState::default() },
        keys: BTreeMap::from([(ALPHA.into(), "sk-secret-alpha".into())]),
    }
}

#[test]
fn backup_round_trip_and_rejections() {
    let password = "correct horse battery";
    let payload = payload();
    let data = backup::seal(&payload, password, 100_000).unwrap();
    assert_eq!(backup::open(&data, password).unwrap(), payload);
    let text = String::from_utf8_lossy(&data);
    assert!(!text.contains("sk-secret") && !text.contains("Alpha"));
    assert_eq!(backup::open(&data, "wrong password!!"), Err(BackupError::WrongPasswordOrCorrupt));
    let tampered = text.replace("100000", "100001");
    assert_eq!(backup::open(tampered.as_bytes(), password), Err(BackupError::WrongPasswordOrCorrupt));
    let hostile = text.replace("100000", "999999999");
    assert_eq!(backup::open(hostile.as_bytes(), password), Err(BackupError::Corrupt));
    assert_eq!(backup::seal(&payload, "short", 100_000), Err(BackupError::PasswordTooShort));
    assert_eq!(backup::open(b"{}", password), Err(BackupError::NotABackup));
}

/// `tests/fixtures/swift-backup.kzbackup` was written by the macOS app (KeyZapper 1.0.7) with the password
/// "correct horse battery" and the payload above.
#[test]
fn opens_backups_made_by_the_macos_app() {
    let data = std::fs::read(concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fixtures/swift-backup.kzbackup")).unwrap();
    let opened = backup::open(&data, "correct horse battery").unwrap();
    assert_eq!(opened.keys, payload().keys);
    assert_eq!(opened.state.profiles[0].id, ALPHA);
    assert_eq!(opened.created_at, "2026-09-21T14:13:20Z");
}
