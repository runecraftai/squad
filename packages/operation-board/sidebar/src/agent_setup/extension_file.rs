//! Shared extension file lifecycle helpers for agent setup.

use anyhow::{Context, Result};
use std::fs;
use std::path::Path;

use super::StatusCheck;

/// Map an optional extension path to an install status check.
pub fn check_installed(path: Option<&Path>) -> Result<StatusCheck> {
    let Some(path) = path else {
        return Ok(StatusCheck::NotInstalled);
    };

    if path.exists() {
        Ok(StatusCheck::Installed)
    } else {
        Ok(StatusCheck::NotInstalled)
    }
}

/// Create parent directories and write an extension source file.
pub fn install_extension_file(
    path: &Path,
    source: &str,
    mkdir_context: &str,
    write_context: &str,
) -> Result<()> {
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent).context(mkdir_context.to_string())?;
    }

    fs::write(path, source).context(write_context.to_string())?;
    Ok(())
}

/// Remove an extension file and clean up an empty parent directory.
pub fn remove_extension_file(path: &Path) -> Result<bool> {
    if !path.exists() {
        return Ok(false);
    }

    fs::remove_file(path)?;
    if let Some(parent) = path.parent()
        && parent.read_dir().is_ok_and(|mut it| it.next().is_none())
    {
        let _ = fs::remove_dir(parent);
    }

    Ok(true)
}
