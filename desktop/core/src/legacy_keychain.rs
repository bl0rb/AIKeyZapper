//! One-time move of keys from the macOS keychain (KeyZapper ≤ 1.x) into the key file.
//! Only `has_key` runs on its own and never prompts; `take_key` runs when the user asks for the move and may
//! show one keychain prompt per key, unless the old helper (which the items trust) is still installed.

#[cfg(target_os = "macos")]
const SERVICE: &str = "KeyZapper.LiteLLM";
#[cfg(target_os = "macos")]
const OLD_HELPER: &str = "/Applications/KeyZapper.app/Contents/Helpers/keyzapper-helper";

/// Whether the keychain holds a key for the profile (attributes only, no prompt).
#[cfg(target_os = "macos")]
pub fn has_key(id: &str) -> bool {
    std::process::Command::new("/usr/bin/security")
        .args(["find-generic-password", "-s", SERVICE, "-a", id])
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .status()
        .is_ok_and(|s| s.success())
}

/// Reads the key: through the old helper if it is still installed, otherwise with `security` (prompts).
#[cfg(target_os = "macos")]
pub fn take_key(id: &str) -> Option<String> {
    let via_helper = std::path::Path::new(OLD_HELPER)
        .is_file()
        .then(|| std::process::Command::new(OLD_HELPER).args(["credential", "--profile", id]).output().ok())
        .flatten()
        .filter(|o| o.status.success());
    let output = match via_helper {
        Some(output) => output,
        None => std::process::Command::new("/usr/bin/security").args(["find-generic-password", "-s", SERVICE, "-a", id, "-w"]).output().ok()?,
    };
    let key = String::from_utf8_lossy(&output.stdout).trim().to_string();
    (output.status.success() && !key.is_empty()).then_some(key)
}

#[cfg(not(target_os = "macos"))]
pub fn has_key(_id: &str) -> bool {
    false
}

#[cfg(not(target_os = "macos"))]
pub fn take_key(_id: &str) -> Option<String> {
    None
}
