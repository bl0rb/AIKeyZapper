use crate::l;

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Severity {
    Blocking,
    Warning,
}

#[derive(Clone, Debug, PartialEq, Eq, Hash)]
pub struct SettingsConflict {
    pub blocking: bool,
    pub message: String,
}

impl SettingsConflict {
    pub fn blocking(message: String) -> Self {
        Self { blocking: true, message }
    }
    pub fn warning(message: String) -> Self {
        Self { blocking: false, message }
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Error {
    UnknownProfile(String),
    MissingCredential(String),
    EmptyCredential,
    KeyStore(String),
    UnsupportedSchemaVersion(u32),
    CorruptMetadata(String),
    FolderNotFound(String),
    NotSettingsRoot { folder: String, root: String },
    SettingsConflicts(Vec<SettingsConflict>),
    SettingsUnreadable(String),
    ConcurrentModification(String),
    Io(String),
}

impl std::fmt::Display for Error {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        let text = match self {
            Error::UnknownProfile(id) => l!("Unbekanntes Profil: %@", id),
            Error::MissingCredential(id) => l!("Für Profil %@ ist kein Key hinterlegt.", id),
            Error::EmptyCredential => l!("Der Key ist leer."),
            Error::KeyStore(m) => l!("Key-Datei ist nicht lesbar oder nicht schreibbar: %@", m),
            Error::UnsupportedSchemaVersion(v) => {
                l!("Metadaten-Version %@ wird von dieser Version nicht unterstützt. Bitte App aktualisieren.", v)
            }
            Error::CorruptMetadata(m) => l!("Metadaten sind beschädigt: %@", m),
            Error::FolderNotFound(p) => l!("Ordner nicht gefunden: %@", p),
            Error::NotSettingsRoot { folder, root } => {
                l!("%@ liegt in einem Git-Repository. Claude Code liest Projekteinstellungen nur aus %@.", folder, root)
            }
            Error::SettingsConflicts(c) => c.iter().map(|c| c.message.as_str()).collect::<Vec<_>>().join("\n"),
            Error::SettingsUnreadable(m) => l!("Claude-Einstellungen sind nicht lesbar: %@", m),
            Error::ConcurrentModification(p) => {
                l!("%@ wurde während der Änderung mehrfach von einem anderen Prozess geändert. Bitte erneut versuchen.", p)
            }
            Error::Io(m) => m.clone(),
        };
        f.write_str(&text)
    }
}

impl std::error::Error for Error {}

impl From<std::io::Error> for Error {
    fn from(e: std::io::Error) -> Self {
        Error::Io(e.to_string())
    }
}

pub type Result<T> = std::result::Result<T, Error>;
