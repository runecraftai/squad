//! Codex status tracking setup.
//!
//! Detects Codex via the `~/.codex/` directory.
//! Installs hooks by merging into `~/.codex/hooks.json`.
//!
//! Codex hooks require enabling the feature flag in `~/.codex/config.toml`:
//! ```toml
//! [features]
//! hooks = true
//! ```

use anyhow::{Context, Result};
use serde_json::Value;
use std::fs;
use std::path::{Path, PathBuf};

use super::StatusCheck;
use crate::agent_setup::json_config::{
    self, EmptyJsonRoot, JsonHookInstallSpec, JsonHookUninstallSpec,
};

/// Hooks configuration embedded at compile time.
const HOOKS_JSON: &str = include_str!("../../.codex/hooks/workmux-status.json");

fn codex_dir() -> Option<PathBuf> {
    if let Ok(dir) = std::env::var("CODEX_CONFIG_DIR") {
        return Some(PathBuf::from(dir));
    }
    home::home_dir().map(|h| h.join(".codex"))
}

fn hooks_path() -> Option<PathBuf> {
    codex_dir().map(|d| d.join("hooks.json"))
}

/// Detect if Codex is present via filesystem.
pub fn detect() -> Option<&'static str> {
    if codex_dir().is_some_and(|d| d.is_dir()) {
        return Some("found ~/.codex/");
    }
    None
}

/// Check if all workmux hooks are installed in Codex hooks.json.
pub fn check() -> Result<StatusCheck> {
    let Some(path) = hooks_path() else {
        return Ok(StatusCheck::NotInstalled);
    };

    check_at(&path)
}

fn check_at(path: &Path) -> Result<StatusCheck> {
    if !path.exists() {
        return Ok(StatusCheck::NotInstalled);
    }

    let content = fs::read_to_string(path).context("Failed to read ~/.codex/hooks.json")?;
    let config: Value =
        serde_json::from_str(&content).context("~/.codex/hooks.json is not valid JSON")?;

    let required = [
        ("UserPromptSubmit", "working"),
        ("PermissionRequest", "waiting"),
        ("PostToolUse", "working"),
        ("SubagentStart", "working"),
        ("SubagentStop", "working"),
        ("Stop", "done"),
    ];

    if required
        .iter()
        .all(|(event, status)| has_status_hook(&config, event, status))
    {
        Ok(StatusCheck::Installed)
    } else {
        Ok(StatusCheck::NotInstalled)
    }
}

fn has_status_hook(config: &Value, event: &str, status: &str) -> bool {
    let expected = format!("workmux set-window-status {status}");
    config["hooks"][event]
        .as_array()
        .into_iter()
        .flatten()
        .filter_map(|group| group.get("hooks").and_then(Value::as_array))
        .flatten()
        .filter_map(|hook| hook.get("command").and_then(Value::as_str))
        .any(|command| command.contains(&expected))
}

/// Remove workmux hooks from Codex hooks.json.
///
/// Removes only workmux hook entries from hooks.json. If the file
/// becomes empty of all hooks, deletes it entirely. Preserves any
/// user-configured hooks from other tools.
pub fn uninstall() -> Result<String> {
    let Some(path) = hooks_path() else {
        return Ok("Codex dir not found, nothing to uninstall".to_string());
    };
    uninstall_at(path)
}

fn uninstall_at(path: PathBuf) -> Result<String> {
    json_config::json_hook_uninstall(
        &path,
        &JsonHookUninstallSpec {
            messages: json_config::JsonHookUninstallMessages {
                file_missing: "No Codex hooks.json found",
                not_found: "No workmux hooks found in Codex hooks.json",
                soft_read_error: None,
                soft_parse_error: None,
            },
            delete_if_no_hooks_remain: true,
            remove_plugins: false,
            soft_errors: false,
        },
    )
}

fn load_hooks() -> Result<Value> {
    json_config::hooks_from_embedded(HOOKS_JSON, "hooks config missing hooks key")
}

fn config_toml_path() -> Option<PathBuf> {
    codex_dir().map(|d| d.join("config.toml"))
}

/// Ensure `hooks = true` is set under `[features]` in config.toml.
/// Returns true if the file was modified.
fn ensure_hooks_feature_flag() -> Result<bool> {
    let path =
        config_toml_path().ok_or_else(|| anyhow::anyhow!("Could not determine home directory"))?;

    let content = if path.exists() {
        fs::read_to_string(&path).context("Failed to read ~/.codex/config.toml")?
    } else {
        String::new()
    };

    // Check if already enabled
    if is_hooks_feature_enabled(&content) {
        return Ok(false);
    }

    let updated = if has_hooks_feature_key(&content) {
        // Replace existing hooks value
        content
            .lines()
            .map(|line| {
                if line
                    .trim()
                    .split_once('=')
                    .is_some_and(|(key, _)| key.trim() == "hooks")
                {
                    "hooks = true"
                } else {
                    line
                }
            })
            .collect::<Vec<_>>()
            .join("\n")
            + if content.ends_with('\n') { "\n" } else { "" }
    } else if content.contains("[features]") {
        // Insert after the [features] line
        content.replacen("[features]", "[features]\nhooks = true", 1)
    } else {
        // Append a new [features] section
        let sep = if content.is_empty() || content.ends_with('\n') {
            ""
        } else {
            "\n"
        };
        format!("{content}{sep}\n[features]\nhooks = true\n")
    };

    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent).context("Failed to create ~/.codex/ directory")?;
    }
    fs::write(&path, &updated).context("Failed to write ~/.codex/config.toml")?;

    Ok(true)
}

/// Check if `hooks = true` is set in the config content.
fn is_hooks_feature_enabled(content: &str) -> bool {
    content.lines().any(|line| {
        let trimmed = line.trim();
        trimmed == "hooks = true" || trimmed == "hooks=true"
    })
}

/// Check if `hooks` key exists at all (regardless of value).
fn has_hooks_feature_key(content: &str) -> bool {
    content.lines().any(|line| {
        line.trim()
            .split_once('=')
            .is_some_and(|(key, _)| key.trim() == "hooks")
    })
}

fn normalize_subagent_stop_status(config: &mut Value) -> bool {
    let Some(groups) = config["hooks"]["SubagentStop"].as_array_mut() else {
        return false;
    };

    let mut modified = false;
    for hook in groups
        .iter_mut()
        .filter_map(|group| group.get_mut("hooks").and_then(Value::as_array_mut))
        .flatten()
    {
        let Some(command) = hook.get_mut("command") else {
            continue;
        };
        if command.as_str() == Some("workmux set-window-status done") {
            *command = Value::String("workmux set-window-status working".to_string());
            modified = true;
        }
    }
    modified
}

fn normalize_installed_hooks(path: &Path) -> Result<()> {
    if !path.exists() {
        return Ok(());
    }

    let content = fs::read_to_string(path).context("Failed to read ~/.codex/hooks.json")?;
    let mut config: Value =
        serde_json::from_str(&content).context("~/.codex/hooks.json is not valid JSON")?;
    if normalize_subagent_stop_status(&mut config) {
        let output = serde_json::to_string_pretty(&config)?;
        fs::write(path, output + "\n").context("Failed to write ~/.codex/hooks.json")?;
    }
    Ok(())
}

fn install_hooks_at(path: &Path) -> Result<()> {
    normalize_installed_hooks(path)?;
    json_config::json_hook_install(
        path,
        &load_hooks()?,
        &JsonHookInstallSpec {
            read_context: "Failed to read ~/.codex/hooks.json",
            parse_context: "~/.codex/hooks.json is not valid JSON",
            write_context: "Failed to write ~/.codex/hooks.json",
            mkdir_context: "Failed to create ~/.codex/ directory",
            empty_root: EmptyJsonRoot::HooksObject,
        },
    )
}

/// Install workmux hooks into `~/.codex/hooks.json`.
///
/// Merges hook groups into existing hooks without clobbering or creating
/// duplicates. Returns a description of what was done.
pub fn install() -> Result<String> {
    let path = hooks_path().ok_or_else(|| anyhow::anyhow!("Could not determine home directory"))?;

    install_hooks_at(&path)?;

    // Ensure hooks feature flag is enabled in config.toml
    let feature_msg = match ensure_hooks_feature_flag() {
        Ok(true) => ", enabled hooks in ~/.codex/config.toml",
        _ => "",
    };

    Ok(format!(
        "Installed hooks to ~/.codex/hooks.json{feature_msg}"
    ))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_hooks_json_is_valid() {
        let parsed: serde_json::Value =
            serde_json::from_str(HOOKS_JSON).expect("embedded hooks config is valid JSON");
        let hooks = parsed.get("hooks").unwrap().as_object().unwrap();
        assert!(hooks.contains_key("UserPromptSubmit"));
        assert!(hooks.contains_key("PermissionRequest"));
        assert!(hooks.contains_key("PostToolUse"));
        assert!(hooks.contains_key("SubagentStart"));
        assert!(hooks.contains_key("SubagentStop"));
        assert!(hooks.contains_key("Stop"));
    }

    #[test]
    fn test_hooks_json_contains_workmux_commands() {
        assert!(HOOKS_JSON.contains("workmux set-window-status working"));
        assert!(HOOKS_JSON.contains("workmux set-window-status waiting"));
        assert!(HOOKS_JSON.contains("workmux set-window-status done"));
    }

    #[test]
    fn test_load_hooks() {
        let hooks = load_hooks().unwrap();
        let obj = hooks.as_object().unwrap();
        assert!(obj.contains_key("UserPromptSubmit"));
        assert!(obj.contains_key("PermissionRequest"));
        assert!(obj.contains_key("PostToolUse"));
        assert!(obj.contains_key("SubagentStart"));
        assert!(obj.contains_key("SubagentStop"));
        assert!(obj.contains_key("Stop"));
    }

    #[test]
    fn test_install_normalizes_subagent_stop_status() {
        let tmp = tempfile::tempdir().unwrap();
        let path = tmp.path().join("hooks.json");
        let mut config: Value = serde_json::from_str(HOOKS_JSON).unwrap();
        config["hooks"]["SubagentStop"][0]["hooks"][0]["command"] =
            Value::String("workmux set-window-status done".to_string());
        config["hooks"]["SubagentStop"]
            .as_array_mut()
            .unwrap()
            .push(serde_json::json!({
                "hooks": [{
                    "type": "command",
                    "command": "python3 my-hook.py"
                }]
            }));
        fs::write(&path, serde_json::to_string_pretty(&config).unwrap()).unwrap();

        install_hooks_at(&path).unwrap();
        install_hooks_at(&path).unwrap();

        let installed: Value = serde_json::from_str(&fs::read_to_string(&path).unwrap()).unwrap();
        assert!(has_status_hook(&installed, "SubagentStop", "working"));
        assert!(!has_status_hook(&installed, "SubagentStop", "done"));
        assert!(
            installed["hooks"]["SubagentStop"]
                .as_array()
                .unwrap()
                .iter()
                .flat_map(|group| group["hooks"].as_array().unwrap())
                .any(|hook| hook["command"] == "python3 my-hook.py")
        );
    }

    #[test]
    fn test_check_requires_complete_hooks() {
        let tmp = tempfile::tempdir().unwrap();
        let path = tmp.path().join("hooks.json");
        let mut config: Value = serde_json::from_str(HOOKS_JSON).unwrap();
        config["hooks"]
            .as_object_mut()
            .unwrap()
            .remove("PermissionRequest");
        fs::write(&path, serde_json::to_string_pretty(&config).unwrap()).unwrap();

        assert!(matches!(
            check_at(&path).unwrap(),
            StatusCheck::NotInstalled
        ));

        install_hooks_at(&path).unwrap();

        assert!(matches!(check_at(&path).unwrap(), StatusCheck::Installed));
    }

    #[test]
    fn test_install_upgrades_legacy_hooks_idempotently() {
        let tmp = tempfile::tempdir().unwrap();
        let path = tmp.path().join("hooks.json");
        let mut config: Value = serde_json::from_str(HOOKS_JSON).unwrap();
        config["hooks"]
            .as_object_mut()
            .unwrap()
            .remove("PermissionRequest");
        config["hooks"]["Stop"]
            .as_array_mut()
            .unwrap()
            .push(serde_json::json!({
                "hooks": [{
                    "type": "command",
                    "command": "python3 my-hook.py"
                }]
            }));
        fs::write(&path, serde_json::to_string_pretty(&config).unwrap()).unwrap();

        install_hooks_at(&path).unwrap();
        install_hooks_at(&path).unwrap();

        let installed: Value = serde_json::from_str(&fs::read_to_string(&path).unwrap()).unwrap();
        assert!(has_status_hook(&installed, "PermissionRequest", "waiting"));
        let permission_groups = installed["hooks"]["PermissionRequest"].as_array().unwrap();
        assert_eq!(permission_groups.len(), 1);
        assert!(
            installed["hooks"]["Stop"]
                .as_array()
                .unwrap()
                .iter()
                .flat_map(|group| group["hooks"].as_array().unwrap())
                .any(|hook| hook["command"] == "python3 my-hook.py")
        );
    }

    #[test]
    fn test_is_hooks_feature_enabled_true() {
        assert!(is_hooks_feature_enabled("[features]\nhooks = true\n"));
    }

    #[test]
    fn test_is_hooks_feature_enabled_no_spaces() {
        assert!(is_hooks_feature_enabled("[features]\nhooks=true\n"));
    }

    #[test]
    fn test_is_hooks_feature_enabled_with_other_settings() {
        let content = "[model]\ndefault = \"gpt-4\"\n\n[features]\nhooks = true\n";
        assert!(is_hooks_feature_enabled(content));
    }

    #[test]
    fn test_is_hooks_feature_enabled_false() {
        assert!(!is_hooks_feature_enabled("[features]\nhooks = false\n"));
    }

    #[test]
    fn test_has_hooks_feature_key_true() {
        assert!(has_hooks_feature_key("[features]\nhooks = true\n"));
    }

    #[test]
    fn test_has_hooks_feature_key_false() {
        assert!(has_hooks_feature_key("[features]\nhooks = false\n"));
    }

    #[test]
    fn test_has_hooks_feature_key_missing() {
        assert!(!has_hooks_feature_key("[features]\n"));
    }

    #[test]
    fn test_is_hooks_feature_enabled_empty() {
        assert!(!is_hooks_feature_enabled(""));
    }

    #[test]
    fn test_is_hooks_feature_enabled_no_features_section() {
        assert!(!is_hooks_feature_enabled("[model]\ndefault = \"gpt-4\"\n"));
    }

    #[test]
    fn test_uninstall_no_hooks_file() {
        let tmp = tempfile::tempdir().unwrap();
        let hooks_path = tmp.path().join("hooks.json");
        let result = uninstall_at(hooks_path).unwrap();
        assert!(result.contains("No Codex hooks.json found"));
    }

    #[test]
    fn test_uninstall_removes_hooks_keeps_others() {
        let tmp = tempfile::tempdir().unwrap();
        let hooks_path = tmp.path().join("hooks.json");
        std::fs::write(
            &hooks_path,
            r#"{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"workmux set-window-status done"}]},{"hooks":[{"type":"command","command":"python3 my-hook.py"}]}]}}"#,
        )
        .unwrap();
        let result = uninstall_at(hooks_path.clone()).unwrap();
        assert!(result.contains("Removed workmux hooks"));
        assert!(hooks_path.exists());
        let content = std::fs::read_to_string(&hooks_path).unwrap();
        let config: Value = serde_json::from_str(&content).unwrap();
        let stop = config["hooks"]["Stop"].as_array().unwrap();
        assert_eq!(stop.len(), 1);
        assert!(
            stop[0]["hooks"][0]["command"]
                .as_str()
                .unwrap()
                .contains("my-hook")
        );
    }

    #[test]
    fn test_uninstall_deletes_file_when_empty() {
        let tmp = tempfile::tempdir().unwrap();
        let hooks_path = tmp.path().join("hooks.json");
        std::fs::write(
            &hooks_path,
            r#"{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"workmux set-window-status done"}]}]}}"#,
        )
        .unwrap();
        let result = uninstall_at(hooks_path.clone()).unwrap();
        assert!(result.contains("no hooks remain"));
        assert!(!hooks_path.exists());
    }

    #[test]
    fn test_uninstall_idempotent() {
        let tmp = tempfile::tempdir().unwrap();
        let hooks_path = tmp.path().join("hooks.json");
        std::fs::write(
            &hooks_path,
            r#"{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"workmux set-window-status done"}]}]}}"#,
        )
        .unwrap();
        let result1 = uninstall_at(hooks_path.clone()).unwrap();
        assert!(result1.contains("no hooks remain"));
        assert!(!hooks_path.exists());
        let result2 = uninstall_at(hooks_path).unwrap();
        assert!(result2.contains("No Codex"), "result2: {result2}");
    }
}
