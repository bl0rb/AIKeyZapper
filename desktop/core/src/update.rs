//! Checks the public GitHub releases of KeyZapper and downloads the installer of a newer release
//! (`.pkg` on macOS, `.msi` on Windows), verified against the SHA-256 digest GitHub publishes.

use crate::{gateway, l};
use sha2::{Digest, Sha256};
use std::cmp::Ordering;
use std::io::Read;
use std::path::PathBuf;
use std::time::Duration;

pub const REPOSITORY: &str = "bl0rb/ClaudeKeyZapper";
pub const INSTALLER_EXTENSION: &str = if cfg!(windows) { ".msi" } else { ".pkg" };

#[derive(Clone, Debug, PartialEq)]
pub struct ReleaseInfo {
    pub version: String,
    /// GitHub pre-release (beta tags like `1.2.0-beta.1`).
    pub prerelease: bool,
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

/// The newest release; with `include_prereleases` also beta releases (whichever version is highest).
pub fn latest_release(include_prereleases: bool) -> Result<ReleaseInfo, UpdateError> {
    if !include_prereleases {
        let body = get_json(&format!("https://api.github.com/repos/{REPOSITORY}/releases/latest"))?;
        return parse(&body).ok_or(UpdateError::Unavailable(200));
    }
    let body = get_json(&format!("https://api.github.com/repos/{REPOSITORY}/releases?per_page=30"))?;
    newest(&body).ok_or(UpdateError::Unavailable(200))
}

fn get_json(url: &str) -> Result<String, UpdateError> {
    let mut response = gateway::agent(Duration::from_secs(15))
        .get(url)
        .header("Accept", "application/vnd.github+json")
        .header("User-Agent", "KeyZapper")
        .call()
        .map_err(|e| UpdateError::Network(e.to_string()))?;
    if response.status().as_u16() != 200 {
        return Err(UpdateError::Unavailable(response.status().as_u16()));
    }
    response.body_mut().read_to_string().map_err(|e| UpdateError::Network(e.to_string()))
}

pub fn parse(body: &str) -> Option<ReleaseInfo> {
    release_info(&serde_json::from_str(body).ok()?)
}

/// The highest-versioned published release in a `GET /releases` list.
pub fn newest(body: &str) -> Option<ReleaseInfo> {
    let releases: Vec<serde_json::Value> = serde_json::from_str(body).ok()?;
    releases
        .iter()
        .filter(|r| r["draft"].as_bool() != Some(true))
        .filter_map(release_info)
        .max_by(|a, b| compare_versions(&a.version, &b.version))
}

fn release_info(release: &serde_json::Value) -> Option<ReleaseInfo> {
    // Only accept packages served by GitHub itself.
    let asset = release["assets"].as_array()?.iter().find(|a| {
        a["name"].as_str().is_some_and(|n| n.ends_with(INSTALLER_EXTENSION))
            && a["browser_download_url"].as_str().and_then(|u| url::Url::parse(u).ok()).is_some_and(|u| u.host_str() == Some("github.com"))
    });
    Some(ReleaseInfo {
        version: normalized(release["tag_name"].as_str()?),
        prerelease: release["prerelease"].as_bool().unwrap_or(false),
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

/// Semantic version order: numeric fields, then a pre-release (`1.2.0-beta.2`) before its release (`1.2.0`),
/// pre-release fields compared numerically where both are numbers.
pub fn compare_versions(a: &str, b: &str) -> Ordering {
    let split = |v: &str| {
        let v = normalized(v);
        let (core, pre) = v.split_once('-').map(|(c, p)| (c.to_string(), Some(p.to_string()))).unwrap_or((v.clone(), None));
        (core.split('.').map(|p| p.parse::<u64>().unwrap_or(0)).collect::<Vec<_>>(), pre)
    };
    let ((ca, pa), (cb, pb)) = (split(a), split(b));
    for i in 0..ca.len().max(cb.len()) {
        let order = ca.get(i).unwrap_or(&0).cmp(cb.get(i).unwrap_or(&0));
        if order.is_ne() {
            return order;
        }
    }
    match (pa, pb) {
        (None, None) => Ordering::Equal,
        (None, Some(_)) => Ordering::Greater,
        (Some(_), None) => Ordering::Less,
        (Some(pa), Some(pb)) => {
            let (fa, fb): (Vec<&str>, Vec<&str>) = (pa.split('.').collect(), pb.split('.').collect());
            for i in 0..fa.len().max(fb.len()) {
                let order = match (fa.get(i), fb.get(i)) {
                    (None, _) => Ordering::Less,
                    (_, None) => Ordering::Greater,
                    (Some(x), Some(y)) => match (x.parse::<u64>(), y.parse::<u64>()) {
                        (Ok(x), Ok(y)) => x.cmp(&y),
                        _ => x.cmp(y),
                    },
                };
                if order.is_ne() {
                    return order;
                }
            }
            Ordering::Equal
        }
    }
}

pub fn is_older(a: &str, b: &str) -> bool {
    compare_versions(a, b) == Ordering::Less
}

/// Beta and other pre-release versions (`1.2.0-beta.1`).
pub fn is_prerelease(version: &str) -> bool {
    version.contains('-')
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
        assert!(is_newer("1.1.0-beta.2", "1.1.0-beta.1"));
        assert!(is_newer("1.1.0-beta.10", "1.1.0-beta.9"));
        assert!(is_newer("1.1.0", "1.1.0-beta.2"));
        assert!(is_newer("1.1.0-beta.1", "1.0.7"));
        assert!(!is_newer("1.1.0-beta.1", "1.1.0"));
        assert!(is_older("2.1.206", "2.1.288"));
        let body = format!(
            r#"{{"tag_name":"1.2.0","html_url":"https://github.com/x/y/releases/1.2.0","assets":[
              {{"name":"KeyZapper-1.2.0{ext}","browser_download_url":"https://github.com/x/y/KeyZapper-1.2.0{ext}","digest":"sha256:ABC"}},
              {{"name":"Evil{ext}","browser_download_url":"https://evil.example/Evil{ext}"}}]}}"#,
            ext = INSTALLER_EXTENSION
        );
        let release = parse(&body).unwrap();
        assert_eq!(release.version, "1.2.0");
        assert!(!release.prerelease);
        assert_eq!(release.package_sha256.as_deref(), Some("abc"));
        assert!(release.package_url.unwrap().starts_with("https://github.com/"));
    }

    #[test]
    fn newest_includes_betas_but_skips_drafts() {
        let body = r#"[
          {"tag_name":"1.0.7","prerelease":false,"html_url":"https://github.com/x/y/releases/1.0.7","assets":[]},
          {"tag_name":"1.1.0-beta.2","prerelease":true,"html_url":"https://github.com/x/y/releases/b2","assets":[]},
          {"tag_name":"1.1.0-beta.10","prerelease":true,"html_url":"https://github.com/x/y/releases/b10","assets":[]},
          {"tag_name":"1.2.0","draft":true,"html_url":"https://github.com/x/y/releases/d","assets":[]}]"#;
        let release = newest(body).unwrap();
        assert_eq!(release.version, "1.1.0-beta.10");
        assert!(release.prerelease);
    }
}
