//! Checks the public GitHub releases of KeyZapper and downloads the installer of a newer release
//! (`.pkg` on macOS, `.msi` on Windows), verified against the SHA-256 digest GitHub publishes.

use crate::{gateway, l};
use sha2::{Digest, Sha256};
use std::io::Read;
use std::path::PathBuf;
use std::time::Duration;

pub const REPOSITORY: &str = "bl0rb/ClaudeKeyZapper";
pub const INSTALLER_EXTENSION: &str = if cfg!(windows) { ".msi" } else { ".pkg" };

#[derive(Clone, Debug, PartialEq)]
pub struct ReleaseInfo {
    pub version: String,
    pub page_url: String,
    pub package_url: Option<String>,
    /// Hex SHA-256 of the package as published by GitHub (`digest` of the release asset), if available.
    pub package_sha256: Option<String>,
}

#[derive(Debug, PartialEq)]
pub enum UpdateError {
    Unavailable(u16),
    Network(String),
    NoPackage,
    ChecksumMismatch,
    MissingChecksum,
}

impl std::fmt::Display for UpdateError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(&match self {
            UpdateError::Unavailable(status) => l!("Update-Server nicht erreichbar (HTTP %@).", status),
            UpdateError::Network(reason) => reason.clone(),
            UpdateError::NoPackage => l!("Das Release enthält kein Installationspaket."),
            UpdateError::ChecksumMismatch => l!("Prüfsumme des heruntergeladenen Pakets stimmt nicht. Installation abgebrochen."),
            UpdateError::MissingChecksum => {
                l!("Für das Paket ist keine Prüfsumme veröffentlicht. Bitte manuell von der Release-Seite installieren.")
            }
        })
    }
}

pub fn latest_release() -> Result<ReleaseInfo, UpdateError> {
    let url = format!("https://api.github.com/repos/{REPOSITORY}/releases/latest");
    let mut response = gateway::agent(Duration::from_secs(15))
        .get(&url)
        .header("Accept", "application/vnd.github+json")
        .header("User-Agent", "KeyZapper")
        .call()
        .map_err(|e| UpdateError::Network(e.to_string()))?;
    if response.status().as_u16() != 200 {
        return Err(UpdateError::Unavailable(response.status().as_u16()));
    }
    let body = response.body_mut().read_to_string().map_err(|e| UpdateError::Network(e.to_string()))?;
    parse(&body).ok_or(UpdateError::Unavailable(200))
}

pub fn parse(body: &str) -> Option<ReleaseInfo> {
    let release: serde_json::Value = serde_json::from_str(body).ok()?;
    // Only accept packages served by GitHub itself.
    let asset = release["assets"].as_array()?.iter().find(|a| {
        a["name"].as_str().is_some_and(|n| n.ends_with(INSTALLER_EXTENSION))
            && a["browser_download_url"].as_str().and_then(|u| url::Url::parse(u).ok()).is_some_and(|u| u.host_str() == Some("github.com"))
    });
    Some(ReleaseInfo {
        version: normalized(release["tag_name"].as_str()?),
        page_url: release["html_url"].as_str()?.to_string(),
        package_url: asset.and_then(|a| a["browser_download_url"].as_str()).map(String::from),
        package_sha256: asset
            .and_then(|a| a["digest"].as_str())
            .and_then(|d| d.strip_prefix("sha256:"))
            .map(str::to_lowercase),
    })
}

fn normalized(version: &str) -> String {
    version.strip_prefix('v').unwrap_or(version).to_string()
}

/// Compares dotted versions numerically.
pub fn is_older(a: &str, b: &str) -> bool {
    let parse = |s: &str| s.split('.').map(|p| p.parse::<u64>().unwrap_or(0)).collect::<Vec<_>>();
    let (pa, pb) = (parse(a), parse(b));
    for i in 0..pa.len().max(pb.len()) {
        let (x, y) = (pa.get(i).copied().unwrap_or(0), pb.get(i).copied().unwrap_or(0));
        if x != y {
            return x < y;
        }
    }
    false
}

pub fn is_newer(candidate: &str, installed: &str) -> bool {
    is_older(&normalized(installed), &normalized(candidate))
}

/// Downloads the package into a temporary folder and verifies its SHA-256 (refuses without a published checksum).
pub fn download_package(release: &ReleaseInfo) -> Result<PathBuf, UpdateError> {
    let package_url = release.package_url.as_ref().ok_or(UpdateError::NoPackage)?;
    let expected = release.package_sha256.as_ref().ok_or(UpdateError::MissingChecksum)?;
    let mut response = gateway::agent(Duration::from_secs(300))
        .get(package_url)
        .header("User-Agent", "KeyZapper")
        .call()
        .map_err(|e| UpdateError::Network(e.to_string()))?;
    if response.status().as_u16() != 200 {
        return Err(UpdateError::Unavailable(response.status().as_u16()));
    }
    let mut data = Vec::new();
    response
        .body_mut()
        .with_config()
        .limit(512 * 1024 * 1024)
        .reader()
        .read_to_end(&mut data)
        .map_err(|e| UpdateError::Network(e.to_string()))?;
    if hex_sha256(&data) != *expected {
        return Err(UpdateError::ChecksumMismatch);
    }
    let name = package_url.rsplit('/').next().filter(|n| !n.is_empty()).unwrap_or("KeyZapper-Update");
    let dir = std::env::temp_dir().join(format!("KeyZapper-Update-{}", uuid::Uuid::new_v4()));
    std::fs::create_dir_all(&dir).map_err(|e| UpdateError::Network(e.to_string()))?;
    let target = dir.join(name);
    std::fs::write(&target, &data).map_err(|e| UpdateError::Network(e.to_string()))?;
    Ok(target)
}

pub fn hex_sha256(data: &[u8]) -> String {
    Sha256::digest(data).iter().map(|b| format!("{b:02x}")).collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn compares_versions_and_picks_platform_package() {
        assert!(is_newer("v1.0.10", "1.0.9"));
        assert!(!is_newer("1.0.7", "1.0.7"));
        let body = format!(
            r#"{{"tag_name":"1.2.0","html_url":"https://github.com/x/y/releases/1.2.0","assets":[
              {{"name":"KeyZapper-1.2.0{ext}","browser_download_url":"https://github.com/x/y/KeyZapper-1.2.0{ext}","digest":"sha256:ABC"}},
              {{"name":"Evil{ext}","browser_download_url":"https://evil.example/Evil{ext}"}}]}}"#,
            ext = INSTALLER_EXTENSION
        );
        let release = parse(&body).unwrap();
        assert_eq!(release.version, "1.2.0");
        assert_eq!(release.package_sha256.as_deref(), Some("abc"));
        assert!(release.package_url.unwrap().starts_with("https://github.com/"));
    }
}
