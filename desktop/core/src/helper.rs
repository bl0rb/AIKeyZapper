//! Contract between Claude Code / the app and `keyzapper-helper`.
//!
//! ```text
//! keyzapper-helper credential --profile <UUID>   # key on stdout (no newline), used as apiKeyHelper
//! keyzapper-helper pool       --profile <UUID>   # like credential; once its budget is used up, the key with
//!                                                # the most budget left on the same endpoint (hidden pool mode)
//! keyzapper-helper store      --profile <UUID>   # key on stdin (never as argument)
//! keyzapper-helper status     --profile <UUID>   # exit 0 if a key exists, 66 if not
//! keyzapper-helper delete     --profile <UUID>
//! ```
//!
//! Keys are only released for endpoints allowed by `ManagedConfig::allowed_gateway_hosts` (exit 78 otherwise).
//! Messages go to stderr and never contain key material. A failure never falls back to another profile;
//! only `pool` switches to other profiles' keys, and only when the gateway reports the own budget as used up.

use crate::errors::Error;
use crate::keys::KeyStore;
use crate::managed::{host_of, ManagedConfig};
use crate::metadata::MetadataStore;
use crate::models::{parse_id, AppState, Profile};
use crate::{gateway, l};

pub const EXECUTABLE_NAME: &str = "keyzapper-helper";

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ExitCode {
    Ok = 0,
    Usage = 64,
    UnknownProfile = 65,
    MissingCredential = 66,
    InternalError = 70,
    KeyStoreError = 77,
    ConfigError = 78,
}

#[derive(Debug, PartialEq, Eq)]
pub struct Output {
    pub exit_code: ExitCode,
    pub stdout: String,
    pub stderr: String,
}

pub struct HelperCommand {
    pub metadata: MetadataStore,
    pub store: KeyStore,
    pub config: ManagedConfig,
    /// Remaining budget of a key at an endpoint (None = unknown), used by `pool`.
    pub remaining_budget: Box<dyn Fn(&str, &str) -> Option<f64>>,
}

impl HelperCommand {
    pub fn new(metadata: MetadataStore, store: KeyStore, config: ManagedConfig) -> Self {
        Self { metadata, store, config, remaining_budget: Box::new(gateway::remaining_budget) }
    }

    pub fn run(&self, args: &[String], stdin: impl FnOnce() -> String) -> Output {
        let commands = ["credential", "pool", "store", "status", "delete"];
        if args.len() != 3 || args[1] != "--profile" || !commands.contains(&args[0].as_str()) {
            return fail(ExitCode::Usage, l!("Aufruf: %@ credential|pool|store|status|delete --profile <UUID>", EXECUTABLE_NAME));
        }
        let Some(id) = parse_id(&args[2]) else { return fail(ExitCode::UnknownProfile, l!("Ungültige Profil-ID: %@", args[2])) };
        let state = match self.metadata.load() {
            Ok(state) => state,
            Err(e) => return fail(ExitCode::ConfigError, e.to_string()),
        };
        let Some(profile) = state.profile(&id) else {
            if args[0] == "delete" {
                return self.delete_orphan(&id);
            }
            return fail(ExitCode::UnknownProfile, l!("Unbekanntes Profil: %@", id));
        };
        if ["credential", "pool", "store"].contains(&args[0].as_str()) && !self.config.is_endpoint_allowed(&profile.endpoint) {
            let host = host_of(&profile.endpoint).unwrap_or_else(|| "?".into());
            return fail(ExitCode::ConfigError, l!("Endpunkt %@ ist laut Firmenrichtlinie (AllowedGatewayHosts) nicht freigegeben.", host));
        }
        let result = match args[0].as_str() {
            "credential" => self.store.read(&profile.id).map(ok),
            "pool" => self.pooled_key(profile, &state).map(ok),
            "store" => self.store.write(&profile.id, &stdin()).map(|_| ok(String::new())),
            "status" => match self.store.exists(&profile.id) {
                Ok(true) => Ok(ok(String::new())),
                Ok(false) => Err(Error::MissingCredential(profile.id.clone())),
                Err(e) => Err(e),
            },
            _ => self.store.delete(&profile.id).map(|_| ok(String::new())),
        };
        result.unwrap_or_else(|e| fail(exit_code(&e), e.to_string()))
    }

    /// The profile's own key while it has budget left or its budget is unknown, otherwise the key with the most
    /// budget left among the other profiles on the same endpoint (same models and allowlist).
    fn pooled_key(&self, profile: &Profile, state: &AppState) -> Result<String, Error> {
        let own = self.store.read(&profile.id)?;
        match (self.remaining_budget)(&profile.endpoint, &own) {
            Some(left) if left <= 0.0 => {}
            _ => return Ok(own),
        }
        let mut best: Option<(String, f64)> = None;
        for other in state.profiles.iter().filter(|o| o.id != profile.id && same_endpoint(&o.endpoint, &profile.endpoint)) {
            let Ok(key) = self.store.read(&other.id) else { continue };
            let Some(left) = (self.remaining_budget)(&other.endpoint, &key) else { continue };
            if left > best.as_ref().map_or(0.0, |b| b.1) {
                best = Some((key, left));
            }
        }
        Ok(best.map(|b| b.0).unwrap_or(own))
    }

    /// Profile already removed from metadata: still allow cleaning up its key.
    fn delete_orphan(&self, id: &str) -> Output {
        match self.store.delete(id) {
            Ok(()) => ok(String::new()),
            Err(e) => fail(ExitCode::InternalError, e.to_string()),
        }
    }
}

pub fn same_endpoint(a: &str, b: &str) -> bool {
    a.trim_end_matches('/') == b.trim_end_matches('/')
}

fn ok(stdout: String) -> Output {
    Output { exit_code: ExitCode::Ok, stdout, stderr: String::new() }
}

fn fail(code: ExitCode, message: String) -> Output {
    Output { exit_code: code, stdout: String::new(), stderr: format!("{EXECUTABLE_NAME}: {message}\n") }
}

fn exit_code(error: &Error) -> ExitCode {
    match error {
        Error::UnknownProfile(_) => ExitCode::UnknownProfile,
        Error::MissingCredential(_) | Error::EmptyCredential => ExitCode::MissingCredential,
        Error::KeyStore(_) => ExitCode::KeyStoreError,
        Error::UnsupportedSchemaVersion(_) | Error::CorruptMetadata(_) => ExitCode::ConfigError,
        _ => ExitCode::InternalError,
    }
}
