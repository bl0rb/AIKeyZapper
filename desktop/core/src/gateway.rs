//! LiteLLM checks: `GET /v1/models` (models the key may use) and `GET /key/info` (budget of the calling key).
//! TLS uses the system trust store (native-tls), so company CAs installed by IT are trusted like in the browser.

use crate::l;
use serde::Serialize;
use std::time::Duration;

#[derive(Clone, Debug, PartialEq)]
pub enum CheckResult {
    /// `missing_models` is None when no model is configured, empty when all configured models are available.
    Ok { missing_models: Option<Vec<String>> },
    Unauthorized,
    RateLimited,
    BudgetExceeded,
    Unreachable(String),
    HttpError(u16),
}

impl CheckResult {
    pub fn message(&self) -> String {
        match self {
            CheckResult::Ok { missing_models: None } => l!("Verbindung erfolgreich."),
            CheckResult::Ok { missing_models: Some(m) } if m.is_empty() => l!("Verbindung erfolgreich, alle Modelle sind verfügbar."),
            CheckResult::Ok { missing_models: Some(m) } => {
                l!("Verbindung erfolgreich, aber diese Modelle sind für den Key nicht freigegeben: %@", m.join(", "))
            }
            CheckResult::Unauthorized => l!("Key wird vom Gateway abgelehnt (ungültig oder gesperrt)."),
            CheckResult::RateLimited => l!("Rate-Limit erreicht. Später erneut versuchen."),
            CheckResult::BudgetExceeded => l!("Budget dieses Keys ist ausgeschöpft."),
            CheckResult::Unreachable(reason) => l!("Gateway nicht erreichbar (VPN?): %@", reason),
            CheckResult::HttpError(code) => l!("Unerwartete Antwort vom Gateway (HTTP %@).", code),
        }
    }

    pub fn is_success(&self) -> bool {
        matches!(self, CheckResult::Ok { missing_models } if missing_models.as_ref().is_none_or(|m| m.is_empty()))
    }
}

/// Budget of a LiteLLM key in USD, as reported by `/key/info`.
#[derive(Clone, Debug, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct KeyBudget {
    pub spend: f64,
    /// None when the key has no budget limit.
    pub max_budget: Option<f64>,
    /// As LiteLLM reports it (Python ISO date).
    pub reset_at: Option<String>,
}

impl KeyBudget {
    /// Remaining budget; infinite without a limit.
    pub fn remaining(&self) -> f64 {
        self.max_budget.map(|max| (max - self.spend).max(0.0)).unwrap_or(f64::INFINITY)
    }
}

/// HTTP agent with the system trust store; non-2xx statuses are returned, not raised.
pub fn agent(timeout: Duration) -> ureq::Agent {
    ureq::Agent::config_builder()
        .timeout_global(Some(timeout))
        .http_status_as_error(false)
        .tls_config(ureq::tls::TlsConfig::builder().provider(ureq::tls::TlsProvider::NativeTls).build())
        .build()
        .into()
}

pub fn join_url(endpoint: &str, path: &str) -> String {
    format!("{}/{}", endpoint.trim_end_matches('/'), path)
}

fn get(path: &str, endpoint: &str, key: &str, timeout: Duration) -> Result<String, CheckResult> {
    let response = agent(timeout)
        .get(&join_url(endpoint, path))
        .header("Authorization", &format!("Bearer {key}"))
        .header("x-api-key", key)
        .call();
    let mut response = response.map_err(|e| CheckResult::Unreachable(e.to_string()))?;
    let status = response.status().as_u16();
    let body = response.body_mut().read_to_string().unwrap_or_default();
    let lower = body.to_lowercase();
    match status {
        200 => Ok(body),
        401 | 403 => Err(CheckResult::Unauthorized),
        429 if lower.contains("budget") => Err(CheckResult::BudgetExceeded),
        429 => Err(CheckResult::RateLimited),
        400 if lower.contains("budget") => Err(CheckResult::BudgetExceeded),
        other => Err(CheckResult::HttpError(other)),
    }
}

/// Model IDs available to the key, sorted.
pub fn models(endpoint: &str, key: &str) -> Result<Vec<String>, CheckResult> {
    let body = get("v1/models", endpoint, key, Duration::from_secs(10))?;
    let value: serde_json::Value = serde_json::from_str(&body).unwrap_or_default();
    let mut ids: Vec<String> = value["data"]
        .as_array()
        .map(|items| items.iter().filter_map(|m| m["id"].as_str().map(String::from)).collect())
        .unwrap_or_default();
    ids.sort();
    Ok(ids)
}

/// LiteLLM's `GET /key/info` without `key` parameter describes the calling key: spend, limit and next reset.
pub fn budget(endpoint: &str, key: &str, timeout: Duration) -> Result<KeyBudget, CheckResult> {
    let body = get("key/info", endpoint, key, timeout)?;
    let value: serde_json::Value = serde_json::from_str(&body).map_err(|_| CheckResult::HttpError(200))?;
    let info = value.get("info").filter(|i| i.is_object()).ok_or(CheckResult::HttpError(200))?;
    Ok(KeyBudget {
        spend: info["spend"].as_f64().unwrap_or(0.0),
        max_budget: info["max_budget"].as_f64(),
        reset_at: info["budget_reset_at"].as_str().map(String::from),
    })
}

/// Remaining budget for `keyzapper-helper pool`: None if unknown, 0 if exhausted, infinite without limit.
pub fn remaining_budget(endpoint: &str, key: &str) -> Option<f64> {
    match budget(endpoint, key, Duration::from_secs(5)) {
        Ok(b) => Some(b.remaining()),
        Err(CheckResult::BudgetExceeded) => Some(0.0),
        Err(_) => None,
    }
}

/// Connection test; also reports configured models the key may not use.
pub fn run(endpoint: &str, key: &str, wanted: &[String]) -> CheckResult {
    match models(endpoint, key) {
        Err(failure) => failure,
        Ok(_) if wanted.is_empty() => CheckResult::Ok { missing_models: None },
        Ok(available) => CheckResult::Ok { missing_models: Some(wanted.iter().filter(|w| !available.contains(w)).cloned().collect()) },
    }
}
