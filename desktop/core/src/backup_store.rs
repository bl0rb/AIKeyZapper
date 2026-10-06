use crate::errors::Result;
use crate::managed::ManagedConfig;
use crate::metadata::MetadataStore;
use crate::models::AppState;
use crate::paths;
use std::path::PathBuf;

/// Copy of the metadata (profiles and bindings, never keys) in the user's OneDrive, for moving to a new computer.
pub struct BackupStore {
    pub file: PathBuf,
}

pub const FILE_NAME: &str = "keyzapper-backup.json";

impl BackupStore {
    pub fn new(directory: PathBuf) -> Self {
        Self { file: directory.join(FILE_NAME) }
    }

    /// `BackupDirectory` if set; otherwise with `OneDriveBackup` the OneDrive folder plus `/KeyZapper`
    /// (macOS: `~/Library/CloudStorage/OneDrive*`, business account preferred; Windows: `%OneDriveCommercial%`/`%OneDrive%`).
    pub fn directory(config: &ManagedConfig) -> Option<PathBuf> {
        if let Some(explicit) = config.backup_directory.as_deref().filter(|d| !d.is_empty()) {
            return Some(paths::expand_tilde(explicit));
        }
        if !config.one_drive_backup {
            return None;
        }
        one_drive().map(|d| d.join("KeyZapper"))
    }

    pub fn write(&self, state: &AppState) -> Result<()> {
        MetadataStore::new(self.file.clone(), false).save(state)
    }

    pub fn read(&self) -> Result<Option<AppState>> {
        if !self.file.exists() {
            return Ok(None);
        }
        MetadataStore::new(self.file.clone(), false).load().map(Some)
    }
}

#[cfg(windows)]
fn one_drive() -> Option<PathBuf> {
    ["OneDriveCommercial", "OneDrive"].iter().find_map(|v| std::env::var_os(v).filter(|p| !p.is_empty())).map(PathBuf::from)
}

#[cfg(not(windows))]
fn one_drive() -> Option<PathBuf> {
    let cloud = paths::home_dir().join("Library/CloudStorage");
    let mut folders: Vec<String> = std::fs::read_dir(&cloud)
        .ok()?
        .filter_map(|e| e.ok()?.file_name().into_string().ok())
        .filter(|n| n.starts_with("OneDrive"))
        .collect();
    folders.sort();
    let folder = folders.iter().find(|f| !f.contains("Personal")).or(folders.first())?;
    Some(cloud.join(folder))
}
