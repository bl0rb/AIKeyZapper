use crate::errors::{Error, Result};
use crate::paths;
use std::collections::BTreeMap;
use std::path::PathBuf;

/// The LiteLLM keys by profile ID in `keys.json` next to the metadata. No keychain or credential manager,
/// so neither the app nor Claude Code ever triggers an access prompt. Protection is the file system:
/// owner-only permissions on macOS, the user-only profile folder (`%LOCALAPPDATA%`) on Windows.
#[derive(Clone, Debug)]
pub struct KeyStore {
    pub file: PathBuf,
}

impl Default for KeyStore {
    fn default() -> Self {
        Self { file: paths::data_dir().join("keys.json") }
    }
}

impl KeyStore {
    pub fn all(&self) -> Result<BTreeMap<String, String>> {
        match std::fs::read(&self.file) {
            Ok(data) => serde_json::from_slice(&data).map_err(|e| Error::KeyStore(e.to_string())),
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(BTreeMap::new()),
            Err(e) => Err(Error::KeyStore(e.to_string())),
        }
    }

    pub fn read(&self, id: &str) -> Result<String> {
        match self.all()?.remove(id) {
            Some(key) if !key.is_empty() => Ok(key),
            Some(_) => Err(Error::EmptyCredential),
            None => Err(Error::MissingCredential(id.to_string())),
        }
    }

    pub fn exists(&self, id: &str) -> Result<bool> {
        Ok(self.all()?.get(id).is_some_and(|k| !k.is_empty()))
    }

    pub fn write(&self, id: &str, secret: &str) -> Result<()> {
        let secret = secret.trim();
        if secret.is_empty() {
            return Err(Error::EmptyCredential);
        }
        let mut keys = self.all()?;
        keys.insert(id.to_string(), secret.to_string());
        self.save(&keys)
    }

    pub fn delete(&self, id: &str) -> Result<()> {
        let mut keys = self.all()?;
        if keys.remove(id).is_some() {
            self.save(&keys)?;
        }
        Ok(())
    }

    fn save(&self, keys: &BTreeMap<String, String>) -> Result<()> {
        if let Some(dir) = self.file.parent() {
            paths::create_private_dir(dir).map_err(|e| Error::KeyStore(e.to_string()))?;
        }
        let text = serde_json::to_string_pretty(keys).map_err(|e| Error::KeyStore(e.to_string()))?;
        paths::write_atomic(&self.file, text.as_bytes(), true).map_err(|e| Error::KeyStore(e.to_string()))
    }
}

/// `••••` + last 4 characters, so the assignment is visible without showing the key.
pub fn masked_hint(key: &str) -> String {
    let chars: Vec<char> = key.trim().chars().collect();
    let tail: String = chars[chars.len().saturating_sub(4)..].iter().collect();
    format!("••••{tail}")
}
