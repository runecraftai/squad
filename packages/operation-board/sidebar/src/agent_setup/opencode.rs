//! OpenCode status tracking setup.
//!
//! Detects OpenCode via its config directory. Resolution order:
//! 1. `OPENCODE_CONFIG` env var (explicit override)
//! 2. `XDG_CONFIG_HOME/opencode`
//! 3. `~/.config/opencode`
//!
//! Installs plugin by writing `package.json` and `workmux-status.ts` to the
//! OpenCode config directory.

use anyhow::{Context, Result};
use serde_json::Value;
use std::fs;
use std::path::PathBuf;

use super::StatusCheck;

/// OpenCode distribution files, embedded at compile time.
const PLUGIN_SOURCE: &str = include_str!("../../resources/opencode/plugins/workmux-status.ts");
const PACKAGE_JSON: &str = include_str!("../../resources/opencode/package.json");

pub fn opencode_config_dir() -> Option<PathBuf> {
    if let Ok(dir) = std::env::var("OPENCODE_CONFIG") {
        return Some(PathBuf::from(dir));
    }
    if let Ok(xdg) = std::env::var("XDG_CONFIG_HOME") {
        return Some(PathBuf::from(xdg).join("opencode"));
    }
    home::home_dir().map(|h| h.join(".config/opencode"))
}

fn plugin_path() -> Option<PathBuf> {
    opencode_config_dir().map(|d| d.join("plugins/workmux-status.ts"))
}

fn legacy_plugin_path() -> Option<PathBuf> {
    opencode_config_dir().map(|d| d.join("plugin/workmux-status.ts"))
}

fn package_json_path() -> Option<PathBuf> {
    opencode_config_dir().map(|d| d.join("package.json"))
}

/// Detect if OpenCode is present via filesystem.
/// Returns the reason string if detected, None otherwise.
pub fn detect() -> Option<&'static str> {
    if std::env::var("OPENCODE_CONFIG").is_ok_and(|d| PathBuf::from(d).is_dir()) {
        return Some("found $OPENCODE_CONFIG");
    }
    if opencode_config_dir().is_some_and(|d| d.is_dir()) {
        return Some("found ~/.config/opencode/");
    }

    None
}

/// Check if workmux plugin is installed for OpenCode.
pub fn check() -> Result<StatusCheck> {
    let Some(path) = plugin_path() else {
        return Ok(StatusCheck::NotInstalled);
    };

    if path.exists() || legacy_plugin_path().is_some_and(|legacy| legacy.exists()) {
        Ok(StatusCheck::Installed)
    } else {
        Ok(StatusCheck::NotInstalled)
    }
}

/// Install workmux plugin for OpenCode.
/// Returns a description of what was done.
pub fn install() -> Result<String> {
    let path =
        plugin_path().ok_or_else(|| anyhow::anyhow!("Could not determine home directory"))?;
    let package_json =
        package_json_path().ok_or_else(|| anyhow::anyhow!("Could not determine home directory"))?;

    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent).context("Failed to create OpenCode plugin directory")?;
    }

    if let Some(parent) = package_json.parent() {
        fs::create_dir_all(parent).context("Failed to create OpenCode config directory")?;
    }

    fs::write(&package_json, PACKAGE_JSON).context("Failed to write OpenCode package.json")?;
    fs::write(&path, PLUGIN_SOURCE).context("Failed to write OpenCode plugin")?;

    Ok(format!(
        "Installed OpenCode plugin files to {} and {}. Restart OpenCode for it to take effect.",
        package_json.display(),
        path.display()
    ))
}

/// Remove workmux plugin files from OpenCode config directory.
///
/// Removes plugin files from both new and legacy locations. For
/// package.json, only removes it if it matches the bundled content
/// exactly (preserving user-modified package.json).
pub fn uninstall() -> Result<String> {
    let Some(config_dir) = opencode_config_dir() else {
        return Ok("No OpenCode config directory found".to_string());
    };
    uninstall_at(config_dir)
}

fn uninstall_at(config_dir: PathBuf) -> Result<String> {
    let mut removed = Vec::new();

    // Remove plugin file (new location: plugins/workmux-status.ts)
    let plugin_path = config_dir.join("plugins/workmux-status.ts");
    if plugin_path.exists() {
        fs::remove_file(&plugin_path)?;
        removed.push(plugin_path.display().to_string());
        // Clean up empty plugins directory
        if let Some(parent) = plugin_path.parent()
            && parent.read_dir().is_ok_and(|mut it| it.next().is_none())
        {
            let _ = fs::remove_dir(parent);
        }
    }

    // Remove legacy plugin file (plugin/workmux-status.ts)
    let legacy_path = config_dir.join("plugin/workmux-status.ts");
    if legacy_path.exists() {
        fs::remove_file(&legacy_path)?;
        removed.push(legacy_path.display().to_string());
    }

    // Handle package.json: only remove if it matches what we installed exactly
    let pkg_path = config_dir.join("package.json");
    if pkg_path.exists() {
        let content = fs::read_to_string(&pkg_path)?;
        // Parse both as JSON for semantic comparison (ignores formatting)
        if let (Ok(installed), Ok(existing)) = (
            serde_json::from_str::<Value>(PACKAGE_JSON),
            serde_json::from_str::<Value>(&content),
        ) && installed == existing
        {
            fs::remove_file(&pkg_path)?;
            removed.push(pkg_path.display().to_string());
        }
    }

    if removed.is_empty() {
        Ok("No OpenCode plugin files found".to_string())
    } else {
        Ok(format!(
            "Removed OpenCode plugin files: {}",
            removed.join(", ")
        ))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_uninstall_no_files() {
        let tmp = tempfile::tempdir().unwrap();
        let result = uninstall_at(tmp.path().to_path_buf()).unwrap();
        assert!(result.contains("No OpenCode plugin files found"));
    }

    #[test]
    fn test_uninstall_removes_plugin_file() {
        let tmp = tempfile::tempdir().unwrap();
        let plugin_dir = tmp.path().join("plugins");
        std::fs::create_dir_all(&plugin_dir).unwrap();
        std::fs::write(plugin_dir.join("workmux-status.ts"), "// plugin code").unwrap();

        let result = uninstall_at(tmp.path().to_path_buf()).unwrap();
        assert!(result.contains("Removed OpenCode plugin files"));
        assert!(!plugin_dir.join("workmux-status.ts").exists());
    }

    #[test]
    fn test_uninstall_removes_package_json_if_matches_bundled() {
        let tmp = tempfile::tempdir().unwrap();
        let plugin_dir = tmp.path().join("plugins");
        std::fs::create_dir_all(&plugin_dir).unwrap();
        std::fs::write(plugin_dir.join("workmux-status.ts"), "// plugin code").unwrap();
        std::fs::write(tmp.path().join("package.json"), PACKAGE_JSON).unwrap();

        let result = uninstall_at(tmp.path().to_path_buf()).unwrap();
        assert!(result.contains("Removed OpenCode plugin files"));
        assert!(!tmp.path().join("package.json").exists());
    }

    #[test]
    fn test_uninstall_keeps_modified_package_json() {
        let tmp = tempfile::tempdir().unwrap();
        let plugin_dir = tmp.path().join("plugins");
        std::fs::create_dir_all(&plugin_dir).unwrap();
        std::fs::write(plugin_dir.join("workmux-status.ts"), "// plugin code").unwrap();
        std::fs::write(tmp.path().join("package.json"), r#"{"name": "custom"}"#).unwrap();

        let result = uninstall_at(tmp.path().to_path_buf()).unwrap();
        assert!(result.contains("Removed OpenCode plugin files"));
        assert!(tmp.path().join("package.json").exists());
    }

    #[test]
    fn test_uninstall_idempotent() {
        let tmp = tempfile::tempdir().unwrap();
        let result1 = uninstall_at(tmp.path().to_path_buf()).unwrap();
        assert!(result1.contains("No OpenCode plugin files found"));
        let result2 = uninstall_at(tmp.path().to_path_buf()).unwrap();
        assert!(result2.contains("No OpenCode plugin files found"));
    }
}
