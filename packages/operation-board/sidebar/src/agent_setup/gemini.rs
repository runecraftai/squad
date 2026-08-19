//! Gemini CLI status tracking setup.
//!
//! Detects Gemini CLI via the `~/.gemini/` directory.
//! Installs hooks by merging into `~/.gemini/settings.json`.

use anyhow::Result;
use serde_json::Value;
use std::path::PathBuf;

use super::StatusCheck;
use crate::agent_setup::json_config::{
    self, EmptyJsonRoot, JsonHookInstallSpec, JsonHookUninstallSpec,
};

/// Hooks configuration embedded at compile time.
const HOOKS_JSON: &str = include_str!("../../resources/gemini/settings.json");

fn gemini_dir() -> Option<PathBuf> {
    if let Ok(dir) = std::env::var("GEMINI_CONFIG_DIR") {
        return Some(PathBuf::from(dir));
    }
    home::home_dir().map(|h| h.join(".gemini"))
}

fn settings_path() -> Option<PathBuf> {
    gemini_dir().map(|d| d.join("settings.json"))
}

/// Detect if Gemini CLI is present via filesystem.
pub fn detect() -> Option<&'static str> {
    if gemini_dir().is_some_and(|d| d.is_dir()) {
        return Some("found ~/.gemini/");
    }
    None
}

/// Check if workmux hooks are installed in Gemini settings.json.
pub fn check() -> Result<StatusCheck> {
    let Some(path) = settings_path() else {
        return Ok(StatusCheck::NotInstalled);
    };

    json_config::check_hook_file(
        &path,
        "Failed to read ~/.gemini/settings.json",
        "~/.gemini/settings.json is not valid JSON",
    )
}

/// Remove workmux hooks from Gemini CLI settings.json.
///
/// Uses shared JSON helpers to surgically remove only workmux entries,
/// preserving any user-configured hooks. Returns a description of what
/// was done.
pub fn uninstall() -> Result<String> {
    let Some(path) = settings_path() else {
        return Ok("Gemini CLI config dir not found, nothing to uninstall".to_string());
    };
    uninstall_at(path)
}

fn uninstall_at(path: PathBuf) -> Result<String> {
    json_config::json_hook_uninstall(
        &path,
        &JsonHookUninstallSpec {
            messages: json_config::JsonHookUninstallMessages {
                file_missing: "No Gemini CLI settings.json found",
                not_found: "No workmux hooks found in Gemini CLI settings",
                soft_read_error: Some("Could not read Gemini CLI settings.json"),
                soft_parse_error: Some("Could not parse Gemini CLI settings.json"),
            },
            delete_if_no_hooks_remain: false,
            remove_plugins: false,
            soft_errors: true,
        },
    )
}

fn load_hooks() -> Result<Value> {
    json_config::hooks_from_embedded(HOOKS_JSON, "hooks config missing hooks key")
}

/// Install workmux hooks into `~/.gemini/settings.json`.
///
/// Merges hook groups into existing hooks without clobbering or creating
/// duplicates. Returns a description of what was done.
pub fn install() -> Result<String> {
    let path =
        settings_path().ok_or_else(|| anyhow::anyhow!("Could not determine home directory"))?;

    json_config::json_hook_install(
        &path,
        &load_hooks()?,
        &JsonHookInstallSpec {
            read_context: "Failed to read ~/.gemini/settings.json",
            parse_context: "~/.gemini/settings.json is not valid JSON",
            write_context: "Failed to write ~/.gemini/settings.json",
            mkdir_context: "Failed to create ~/.gemini/ directory",
            empty_root: EmptyJsonRoot::HooksObject,
        },
    )?;

    Ok("Installed hooks to ~/.gemini/settings.json".to_string())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_hooks_json_is_valid() {
        let parsed: serde_json::Value =
            serde_json::from_str(HOOKS_JSON).expect("embedded hooks config is valid JSON");
        let hooks = parsed.get("hooks").unwrap().as_object().unwrap();
        assert!(hooks.contains_key("BeforeAgent"));
        assert!(hooks.contains_key("Notification"));
        assert!(hooks.contains_key("AfterTool"));
        assert!(hooks.contains_key("AfterAgent"));
        assert!(hooks.contains_key("SessionEnd"));
    }

    #[test]
    fn test_hooks_json_contains_workmux_command() {
        assert!(HOOKS_JSON.contains("workmux set-window-status"));
    }

    #[test]
    fn test_load_hooks() {
        let hooks = load_hooks().unwrap();
        let obj = hooks.as_object().unwrap();
        assert!(obj.contains_key("BeforeAgent"));
        assert!(obj.contains_key("Notification"));
        assert!(obj.contains_key("AfterTool"));
        assert!(obj.contains_key("AfterAgent"));
        assert!(obj.contains_key("SessionEnd"));
    }

    #[test]
    fn test_uninstall_no_settings_file() {
        let tmp = tempfile::tempdir().unwrap();
        let settings_path = tmp.path().join("settings.json");
        let result = uninstall_at(settings_path).unwrap();
        assert!(result.contains("No Gemini CLI settings.json"));
    }

    #[test]
    fn test_uninstall_removes_hooks_only() {
        let tmp = tempfile::tempdir().unwrap();
        let settings_path = tmp.path().join("settings.json");
        std::fs::write(
            &settings_path,
            r#"{"hooks":{"AfterAgent":[{"hooks":[{"type":"command","command":"workmux set-window-status done"}]},{"hooks":[{"type":"command","command":"python3 my-hook.py"}]}]}}"#,
        )
        .unwrap();
        let result = uninstall_at(settings_path.clone()).unwrap();
        assert!(result.contains("Removed workmux hooks"));
        let content = std::fs::read_to_string(&settings_path).unwrap();
        let config: Value = serde_json::from_str(&content).unwrap();
        let after = config["hooks"]["AfterAgent"].as_array().unwrap();
        assert_eq!(after.len(), 1);
        assert!(
            after[0]["hooks"][0]["command"]
                .as_str()
                .unwrap()
                .contains("my-hook")
        );
    }

    #[test]
    fn test_uninstall_idempotent() {
        let tmp = tempfile::tempdir().unwrap();
        let settings_path = tmp.path().join("settings.json");
        std::fs::write(
            &settings_path,
            r#"{"hooks":{"AfterAgent":[{"hooks":[{"type":"command","command":"workmux set-window-status done"}]}]}}"#,
        )
        .unwrap();
        let result1 = uninstall_at(settings_path.clone()).unwrap();
        assert!(result1.contains("Removed workmux hooks"));
        let result2 = uninstall_at(settings_path).unwrap();
        assert!(result2.contains("No workmux hooks found"));
    }
}
