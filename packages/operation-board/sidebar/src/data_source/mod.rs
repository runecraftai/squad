//! Data source abstraction for sidebar agent monitoring.
//!
//! This module provides a trait-based abstraction for different data sources,
//! allowing the sidebar daemon to read agent state from either tmux (default)
//! or external systems like Squad.

pub mod squad;

use anyhow::Result;

use crate::multiplexer::types::AgentPane;

/// Trait for providing agent pane data to the sidebar daemon.
///
/// Implementations read agent state from different sources (tmux, Squad, etc.)
/// and return a list of `AgentPane` structs for display in the sidebar.
pub trait DataSource: Send + Sync {
    /// List all currently known agent panes.
    ///
    /// Returns a vector of `AgentPane` structs representing the current state
    /// of all agents tracked by this data source.
    fn list_agents(&self) -> Result<Vec<AgentPane>>;

    /// Get the name of this data source for logging/display.
    fn name(&self) -> &'static str;
}

/// Data source type for CLI selection.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum DataSourceType {
    /// tmux-based monitoring (default, original Workmux behavior)
    #[default]
    Tmux,
    /// Squad state file monitoring
    Squad,
}

impl std::fmt::Display for DataSourceType {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            DataSourceType::Tmux => write!(f, "tmux"),
            DataSourceType::Squad => write!(f, "squad"),
        }
    }
}

impl std::str::FromStr for DataSourceType {
    type Err = String;

    fn from_str(s: &str) -> Result<Self, Self::Err> {
        match s.to_lowercase().as_str() {
            "tmux" => Ok(DataSourceType::Tmux),
            "squad" => Ok(DataSourceType::Squad),
            other => Err(format!("unknown data source: {}", other)),
        }
    }
}
