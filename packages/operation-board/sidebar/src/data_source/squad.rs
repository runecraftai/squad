//! Squad state file data source for sidebar monitoring.
//!
//! Reads agent state from Squad's `state/` directory structure:
//! - `state/window-states` (TSV: window, id, label, state, detail)
//! - `state/<id>.meta` (JSON: model, effort, kind, mode)
//! - `state/<id>.busy-gen` (mtime for elapsed time)

use anyhow::{Context, Result};
use serde::Deserialize;
use std::fs;
use std::path::{Path, PathBuf};
use std::time::UNIX_EPOCH;

use crate::multiplexer::types::{AgentPane, AgentStatus};

use super::DataSource;

/// Squad task metadata from `state/<id>.meta` files.
#[derive(Debug, Deserialize, Default)]
struct SquadMeta {
    /// LLM model name (e.g., "claude-3-opus", "gpt-4")
    #[serde(default)]
    model: Option<String>,
    /// Effort level (e.g., "low", "medium", "high", "xhigh")
    #[serde(default)]
    effort: Option<String>,
    /// Task kind (e.g., "strike", "recon", "xo")
    #[serde(default)]
    kind: Option<String>,
    /// Task mode (e.g., "drill", "direct-pr", "local-only")
    #[serde(default)]
    mode: Option<String>,
    /// Project name or path
    #[serde(default)]
    project: Option<String>,
    /// Working directory / worktree path
    #[serde(default)]
    worktree: Option<String>,
}

/// A single row from Squad's `state/window-states` TSV file.
#[derive(Debug, Clone)]
struct WindowStateEntry {
    /// Window target (e.g., "squad:0" or just window name)
    window: String,
    /// Task ID
    id: String,
    /// State label (working, done, blocked, etc.)
    label: String,
    /// State verb (working, idle, etc.)
    state: String,
    /// Detail text
    detail: String,
}

/// Squad data source that reads from Squad's state directory.
pub struct SquadDataSource {
    /// Path to Squad's state directory (e.g., `/path/to/squad/state/`)
    state_dir: PathBuf,
}

impl SquadDataSource {
    /// Create a new SquadDataSource with the given state directory path.
    pub fn new(state_dir: PathBuf) -> Self {
        Self { state_dir }
    }

    /// Get the state directory path.
    pub fn state_dir(&self) -> &Path {
        &self.state_dir
    }

    /// Create a SquadDataSource using the SQUAD_BASE or SQUAD_HOME environment variable.
    ///
    /// Falls back to `~/.fob/squad/state/` if neither is set.
    pub fn from_env() -> Result<Self> {
        let base = if let Ok(base) = std::env::var("SQUAD_BASE") {
            PathBuf::from(base)
        } else if let Ok(home) = std::env::var("SQUAD_HOME") {
            PathBuf::from(home)
        } else {
            let home = home::home_dir()
                .ok_or_else(|| anyhow::anyhow!("Could not determine home directory"))?;
            home.join(".fob").join("squad")
        };

        let state_dir = base.join("state");
        Ok(Self { state_dir })
    }

    /// Parse the `state/window-states` TSV file.
    ///
    /// Format: window\tid\tlabel\tstate\tdetail
    fn read_window_states(&self) -> Result<Vec<WindowStateEntry>> {
        let path = self.state_dir.join("window-states");
        if !path.exists() {
            return Ok(Vec::new());
        }

        let content = fs::read_to_string(&path)
            .with_context(|| format!("Failed to read window-states: {}", path.display()))?;

        let mut entries = Vec::new();
        for line in content.lines() {
            let line = line.trim();
            if line.is_empty() {
                continue;
            }

            let parts: Vec<&str> = line.split('\t').collect();
            if parts.len() >= 5 {
                entries.push(WindowStateEntry {
                    window: parts[0].to_string(),
                    id: parts[1].to_string(),
                    label: parts[2].to_string(),
                    state: parts[3].to_string(),
                    detail: parts[4..].join("\t"), // Join remaining parts as detail
                });
            } else if parts.len() >= 4 {
                entries.push(WindowStateEntry {
                    window: parts[0].to_string(),
                    id: parts[1].to_string(),
                    label: parts[2].to_string(),
                    state: parts[3].to_string(),
                    detail: String::new(),
                });
            }
        }

        Ok(entries)
    }

    /// Read task metadata from `state/<id>.meta`.
    ///
    /// Squad writes meta files in shell key=value format (one per line),
    /// not JSON. Example:
    ///   window=Squad:sq-abc
    ///   model=claude-3-opus
    ///   effort=high
    ///   kind=strike
    fn read_meta(&self, task_id: &str) -> Result<SquadMeta> {
        let path = self.state_dir.join(format!("{}.meta", task_id));
        if !path.exists() {
            return Ok(SquadMeta::default());
        }

        let content = fs::read_to_string(&path)
            .with_context(|| format!("Failed to read meta: {}", path.display()))?;

        let mut meta = SquadMeta::default();
        for line in content.lines() {
            let line = line.trim();
            if line.is_empty() || line.starts_with('#') {
                continue;
            }
            if let Some((key, value)) = line.split_once('=') {
                let value = value.trim();
                if value.is_empty() || value == "-" {
                    continue;
                }
                match key.trim() {
                    "model" => meta.model = Some(value.to_string()),
                    "effort" => meta.effort = Some(value.to_string()),
                    "kind" => meta.kind = Some(value.to_string()),
                    "mode" => meta.mode = Some(value.to_string()),
                    "project" => meta.project = Some(value.to_string()),
                    "worktree" => meta.worktree = Some(value.to_string()),
                    _ => {} // Ignore unknown fields
                }
            }
        }
        Ok(meta)
    }

    /// Get the mtime of `state/<id>.busy-gen` as a Unix timestamp.
    ///
    /// Returns None if the file doesn't exist.
    fn read_busy_gen_mtime(&self, task_id: &str) -> Option<u64> {
        let path = self.state_dir.join(format!("{}.busy-gen", task_id));
        fs::metadata(&path)
            .ok()
            .and_then(|m| m.modified().ok())
            .and_then(|t| t.duration_since(UNIX_EPOCH).ok())
            .map(|d| d.as_secs())
    }

    /// Map a Squad state label to a Workmux AgentStatus.
    fn map_status(label: &str) -> Option<AgentStatus> {
        match label.to_lowercase().as_str() {
            "working" => Some(AgentStatus::Working),
            "done" => Some(AgentStatus::Done),
            "blocked" | "awaiting-decision" => Some(AgentStatus::Waiting),
            "failed" => Some(AgentStatus::Done), // Show as done with error styling
            "idle" | _ => None,
        }
    }

    /// Parse the window target into session and window name.
    ///
    /// Input format: "session:window" or just "window"
    /// Returns: (session, window_name)
    fn parse_window_target(window: &str) -> (String, String) {
        if let Some((session, name)) = window.split_once(':') {
            (session.to_string(), name.to_string())
        } else {
            ("squad".to_string(), window.to_string())
        }
    }
}

impl DataSource for SquadDataSource {
    fn list_agents(&self) -> Result<Vec<AgentPane>> {
        let entries = self.read_window_states()?;
        let mut agents = Vec::new();

        for entry in entries {
            let meta = self.read_meta(&entry.id).unwrap_or_default();
            let busy_gen_mtime = self.read_busy_gen_mtime(&entry.id);
            let (session, window_name) = Self::parse_window_target(&entry.window);

            // Build the pane title from state and detail
            let pane_title = if entry.detail.is_empty() {
                Some(entry.state.clone())
            } else {
                Some(format!("{}: {}", entry.state, entry.detail))
            };

            // Build agent command from model and effort
            let agent_command = match (&meta.model, &meta.effort) {
                (Some(model), Some(effort)) => Some(format!("{} ({})", model, effort)),
                (Some(model), None) => Some(model.clone()),
                (None, Some(effort)) => Some(format!("({})", effort)),
                (None, None) => None,
            };

            let agent = AgentPane {
                session: session.clone(),
                window_name,
                // Use the real session:window target (e.g. "squad:my-task") as
                // pane_id.  This is a valid tmux target for switch-client -t,
                // unlike the synthetic %task-id which only looks like a tmux
                // pane-id but isn't one.
                pane_id: entry.window.clone(),
                window_id: String::new(),
                window_index: None,
                path: meta
                    .worktree
                    .map(PathBuf::from)
                    .or_else(|| meta.project.map(PathBuf::from))
                    .unwrap_or_else(|| PathBuf::from("/")),
                pane_title,
                status: Self::map_status(&entry.label),
                status_ts: busy_gen_mtime,
                updated_ts: busy_gen_mtime,
                // Use empty string instead of None: Squad's window names are real
                // task IDs (always meaningful), not auto-tracked shell names.
                // A real tmux backend provides pane_current_command; we have no live
                // pane, so we supply a sentinel that lets the window name pass
                // `is_window_meaningful` (it differs from any real task ID and is
                // not a generic shell name).
                window_cmd: Some("".to_string()),
                agent_command,
                agent_kind: meta.kind,
            };

            agents.push(agent);
        }

        Ok(agents)
    }

    fn name(&self) -> &'static str {
        "squad"
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;
    use tempfile::TempDir;

    fn create_test_state_dir() -> TempDir {
        let dir = TempDir::new().unwrap();
        let state_dir = dir.path().join("state");
        fs::create_dir_all(&state_dir).unwrap();
        dir
    }

    #[test]
    fn test_parse_window_target() {
        let (session, window) = SquadDataSource::parse_window_target("squad:my-window");
        assert_eq!(session, "squad");
        assert_eq!(window, "my-window");

        let (session, window) = SquadDataSource::parse_window_target("just-window");
        assert_eq!(session, "squad");
        assert_eq!(window, "just-window");
    }

    #[test]
    fn test_map_status() {
        assert_eq!(
            SquadDataSource::map_status("working"),
            Some(AgentStatus::Working)
        );
        assert_eq!(
            SquadDataSource::map_status("done"),
            Some(AgentStatus::Done)
        );
        assert_eq!(
            SquadDataSource::map_status("blocked"),
            Some(AgentStatus::Waiting)
        );
        assert_eq!(
            SquadDataSource::map_status("awaiting-decision"),
            Some(AgentStatus::Waiting)
        );
        assert_eq!(
            SquadDataSource::map_status("failed"),
            Some(AgentStatus::Done)
        );
        assert_eq!(SquadDataSource::map_status("idle"), None);
        assert_eq!(SquadDataSource::map_status("unknown"), None);
    }

    #[test]
    fn test_read_window_states_empty() {
        let dir = create_test_state_dir();
        let state_dir = dir.path().join("state");
        let ds = SquadDataSource::new(state_dir);

        let entries = ds.read_window_states().unwrap();
        assert!(entries.is_empty());
    }

    #[test]
    fn test_read_window_states() {
        let dir = create_test_state_dir();
        let state_dir = dir.path().join("state");

        let content = "squad:main\ttask-1\tworking\tworking\tImplementing feature\n\
                        squad:main\ttask-2\tdone\tdone\tFeature complete\n";
        fs::write(state_dir.join("window-states"), content).unwrap();

        let ds = SquadDataSource::new(state_dir);
        let entries = ds.read_window_states().unwrap();

        assert_eq!(entries.len(), 2);
        assert_eq!(entries[0].id, "task-1");
        assert_eq!(entries[0].label, "working");
        assert_eq!(entries[0].detail, "Implementing feature");
        assert_eq!(entries[1].id, "task-2");
        assert_eq!(entries[1].label, "done");
    }

    #[test]
    fn test_read_meta() {
        let dir = create_test_state_dir();
        let state_dir = dir.path().join("state");

        // Squad writes meta in shell key=value format, not JSON
        let meta_content = "window=Squad:sq-abc\nmodel=claude-3-opus\neffort=high\nkind=strike\nmode=drill\nproject=my-project\nworktree=/tmp/worktree-123\n";
        fs::write(state_dir.join("task-1.meta"), meta_content).unwrap();

        let ds = SquadDataSource::new(state_dir);
        let meta = ds.read_meta("task-1").unwrap();

        assert_eq!(meta.model.unwrap(), "claude-3-opus");
        assert_eq!(meta.effort.unwrap(), "high");
        assert_eq!(meta.kind.unwrap(), "strike");
        assert_eq!(meta.worktree.unwrap(), "/tmp/worktree-123");
    }

    #[test]
    fn test_read_meta_empty_values() {
        let dir = create_test_state_dir();
        let state_dir = dir.path().join("state");

        // Squad uses '-' for unset values
        let meta_content = "model=-\neffort=-\nkind=strike\n";
        fs::write(state_dir.join("task-1.meta"), meta_content).unwrap();

        let ds = SquadDataSource::new(state_dir);
        let meta = ds.read_meta("task-1").unwrap();

        assert!(meta.model.is_none());
        assert!(meta.effort.is_none());
        assert_eq!(meta.kind.unwrap(), "strike");
    }

    #[test]
    fn test_pane_id_is_valid_tmux_window_target() {
        // Squad agents must produce pane_ids that resolve to real tmux
        // session:window targets, not synthetic %task-id strings.
        let dir = create_test_state_dir();
        let state_dir = dir.path().join("state");

        let content =
            "squad:my-task\tsq-my-task\tworking\tworking\tRecon\n";
        fs::write(state_dir.join("window-states"), content).unwrap();

        let ds = SquadDataSource::new(state_dir);
        let agents = ds.list_agents().unwrap();
        let agent = &agents[0];

        // pane_id must be a valid tmux session:window target
        assert_eq!(agent.pane_id, "squad:my-task");
        // ...not a synthetic %-prefixed fake pane-id
        assert!(!agent.pane_id.starts_with('%'),
            "pane_id must not be a synthetic %%-prefixed id: {}", agent.pane_id);
    }

    #[test]
    fn test_list_agents_full() {
        let dir = create_test_state_dir();
        let state_dir = dir.path().join("state");

        // Write window-states
        let content = "squad:main\ttask-1\tworking\tworking\tImplementing feature\n";
        fs::write(state_dir.join("window-states"), content).unwrap();

        // Write meta in shell key=value format
        let meta_content = "model=claude-3-opus\neffort=high\nkind=strike\nworktree=/tmp/worktree-123\n";
        fs::write(state_dir.join("task-1.meta"), meta_content).unwrap();

        let ds = SquadDataSource::new(state_dir);
        let agents = ds.list_agents().unwrap();

        assert_eq!(agents.len(), 1);
        let agent = &agents[0];
        assert_eq!(agent.session, "squad");
        assert_eq!(agent.window_name, "main");
        // pane_id is the real session:window target, not a synthetic %task-id
        assert_eq!(agent.pane_id, "squad:main");
        assert_eq!(agent.status, Some(AgentStatus::Working));
        assert_eq!(agent.path, PathBuf::from("/tmp/worktree-123"));
        assert_eq!(agent.agent_kind.as_ref().unwrap(), "strike");
        assert!(agent.agent_command.as_ref().unwrap().contains("claude-3-opus"));
    }
}
