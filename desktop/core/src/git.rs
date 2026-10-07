use std::process::{Command, Stdio};

/// `/usr/bin/git` on macOS (apps do not get the shell PATH), `git` from PATH elsewhere.
fn git_executable() -> &'static str {
    if cfg!(target_os = "macos") { "/usr/bin/git" } else { "git" }
}

/// Runs a command without flashing a console window on Windows.
pub fn command(program: &str) -> Command {
    #[allow(unused_mut)]
    let mut cmd = Command::new(program);
    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt;
        const CREATE_NO_WINDOW: u32 = 0x0800_0000;
        cmd.creation_flags(CREATE_NO_WINDOW);
    }
    cmd
}

fn exec(args: &[&str], dir: &str) -> Option<(i32, String)> {
    let mut cmd = command(git_executable());
    cmd.arg("-C").arg(dir).args(args).stdin(Stdio::null()).stderr(Stdio::null());
    for key in ["GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE", "GIT_COMMON_DIR"] {
        cmd.env_remove(key);
    }
    let output = cmd.output().ok()?;
    Some((output.status.code().unwrap_or(-1), String::from_utf8_lossy(&output.stdout).into_owned()))
}

/// Trimmed stdout on exit 0, None otherwise (also when git is unavailable).
pub fn run(args: &[&str], dir: &str) -> Option<String> {
    match exec(args, dir)? {
        (0, out) => Some(out.trim().to_string()),
        _ => None,
    }
}

pub fn status(args: &[&str], dir: &str) -> i32 {
    exec(args, dir).map(|(code, _)| code).unwrap_or(-1)
}
