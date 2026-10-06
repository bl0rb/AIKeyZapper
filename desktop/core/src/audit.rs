//! Logical checks of `~/.claude/settings.json` for use with an LLM gateway: things Claude Code accepts silently
//! but that break or weaken the setup (plaintext keys, endpoint without key, non-text env values, …).

use crate::settings::{is_truthy, is_unparsable_json, read_json, MODEL_ENV_KEYS, PROVIDER_ENV_KEYS};
use crate::{json, l};
use serde::Serialize;
use std::collections::BTreeMap;

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum Severity {
    Error,
    Warning,
    Info,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
pub struct Finding {
    pub id: String,
    pub severity: Severity,
    pub message: String,
}

const MODEL_ALIASES: [&str; 6] = ["default", "opus", "sonnet", "haiku", "opusplan", "best"];

/// `global_values`: values KeyZapper's default profile wrote; they are expected, not findings.
pub fn check(path: &str, global_values: &BTreeMap<String, String>) -> Vec<Finding> {
    if !std::path::Path::new(path).exists() {
        return vec![Finding {
            id: "missing".into(),
            severity: Severity::Info,
            message: l!("Keine globale settings.json vorhanden. Claude Code nutzt Standardwerte."),
        }];
    }
    if is_unparsable_json(path) {
        return vec![Finding {
            id: "invalid-json".into(),
            severity: Severity::Error,
            message: l!("Kein gültiges JSON: Claude Code ignoriert die Datei, und das Speichern der Modellauswahl schlägt fehl."),
        }];
    }
    let Ok(Some(settings)) = read_json(path) else { return vec![] };
    let mut findings = Vec::new();
    let mut add = |id: String, severity: Severity, message: String| findings.push(Finding { id, severity, message });
    let is_own = |key: &str| global_values.get(key).is_some_and(|v| json::get_str(&settings, key) == Some(v.as_str()));

    let empty = serde_json::Map::new();
    let env = settings.get("env").and_then(|e| e.as_object()).unwrap_or(&empty);
    if settings.get("env").is_some_and(|e| !e.is_object()) {
        add("env-type".into(), Severity::Error, l!("„env“ ist kein Objekt; Claude Code erwartet Name-Wert-Paare."));
    }
    for (name, value) in env {
        if !value.is_string() {
            add(format!("env-value-{name}"), Severity::Error, l!("„env.%@“ ist kein Text. Claude Code erwartet Zeichenketten, z. B. „1“ statt 1.", name));
        }
    }
    let non_empty = |name: &str| env.get(name).and_then(|v| v.as_str()).is_some_and(|v| !v.is_empty());
    for name in ["ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN"] {
        if non_empty(name) {
            add(
                format!("plaintext-{name}"),
                Severity::Warning,
                l!("Klartext-Key in „env.%@“. Außerhalb zugeordneter Projekte nutzt Claude diesen Key. Besser entfernen und ein Standardprofil setzen.", name),
            );
        }
    }
    let has_helper = settings.contains_key("apiKeyHelper");
    if has_helper && !is_own("apiKeyHelper") {
        add("own-helper".into(), Severity::Info, l!("Eigener „apiKeyHelper“ gesetzt. In zugeordneten Projekten hat KeyZapper Vorrang."));
    }
    let has_key = non_empty("ANTHROPIC_API_KEY") || non_empty("ANTHROPIC_AUTH_TOKEN");
    if non_empty("ANTHROPIC_BASE_URL") && !has_key && !has_helper {
        add(
            "endpoint-without-key".into(),
            Severity::Warning,
            l!("„env.ANTHROPIC_BASE_URL“ ist gesetzt, aber kein Key. Außerhalb zugeordneter Projekte schlagen Anfragen fehl; ein Standardprofil behebt das."),
        );
    }
    for name in PROVIDER_ENV_KEYS {
        if is_truthy(env.get(name).and_then(|v| v.as_str())) {
            add(format!("provider-{name}"), Severity::Warning, l!("„env.%@“ leitet Claude Code an LiteLLM vorbei.", name));
        }
    }
    for name in MODEL_ENV_KEYS {
        if env.contains_key(name) && !is_own(&format!("env.{name}")) {
            add(
                format!("model-env-{name}"),
                Severity::Info,
                l!("„env.%@“ gilt nur außerhalb zugeordneter Projekte; dort gelten die Modelle des Profils.", name),
            );
        }
    }
    if let Some(model) = settings.get("model").and_then(|m| m.as_str()) {
        if model.starts_with("claude-") && !MODEL_ALIASES.contains(&model.replace("[1m]", "").as_str()) {
            add(
                "fixed-model".into(),
                Severity::Warning,
                l!("„model“ ist die feste Modell-ID „%@“. Über ein Gateway mit eigenen Namen besser einen Alias wählen (opus, sonnet, haiku), damit die Profilmodelle greifen.", model),
            );
        }
    }
    findings
}
