//! Sidebar pane creation, destruction, and lifecycle management.

use anyhow::{Result, anyhow};
use tracing::debug;

use crate::cmd::Cmd;
use crate::config::SidebarPosition;

use super::SIDEBAR_ROLE_VALUE;
use super::app::HostIdentity;
use super::daemon_ctrl::kill_daemon;
use super::hooks::remove_hooks;
use super::layout_tree::{layout_after_sidebar_remove, reflow_after_sidebar_add};

/// Check if a window already has a sidebar pane.
pub(super) fn find_sidebar_in_window(window_id: &str) -> Result<bool> {
    let output = Cmd::new("tmux")
        .args(&["list-panes", "-t", window_id, "-F", "#{@workmux_role}"])
        .run_and_capture_stdout()?;

    Ok(output.lines().any(|l| l.trim() == SIDEBAR_ROLE_VALUE))
}

/// Create a sidebar pane in a specific window (idempotent).
pub(super) fn create_sidebar_in_window(
    window_id: &str,
    position: SidebarPosition,
    size: u16,
) -> Result<()> {
    if find_sidebar_in_window(window_id).unwrap_or(false) {
        debug!(
            window_id,
            "create_sidebar_in_window: already exists, skipping"
        );
        return Ok(());
    }

    let exe = std::env::current_exe()?;
    let exe_str = exe.to_str().ok_or_else(|| anyhow!("exe path not UTF-8"))?;
    let size_str = size.to_string();

    debug!(window_id, position = ?position, size, "create_sidebar_in_window: creating");

    // Get the first pane in the window as split target
    let target_pane = Cmd::new("tmux")
        .args(&["list-panes", "-t", window_id, "-F", "#{pane_id}"])
        .run_and_capture_stdout()?;
    let target_pane = target_pane.lines().next().map(|l| l.trim()).unwrap_or("");
    if target_pane.is_empty() {
        return Ok(());
    }

    let split_flag = match position {
        SidebarPosition::Left => "-hbf",
        SidebarPosition::Top => "-vbf",
    };

    let new_pane_id = Cmd::new("tmux")
        .args(&[
            "split-window",
            split_flag,
            "-l",
            &size_str,
            "-t",
            target_pane,
            "-d",
            "-P",
            "-F",
            "#{pane_id}",
            exe_str,
            "_sidebar-run",
        ])
        .run_and_capture_stdout()?
        .trim()
        .to_string();

    Cmd::new("tmux")
        .args(&[
            "set-option",
            "-p",
            "-t",
            &new_pane_id,
            "@workmux_role",
            SIDEBAR_ROLE_VALUE,
        ])
        .run()?;

    reflow_after_sidebar_add(window_id, &new_pane_id, position, size);

    debug!(
        window_id,
        pane_id = new_pane_id.as_str(),
        requested_size = size,
        "create_sidebar_in_window: done"
    );

    Ok(())
}

enum SidebarWindowScope<'a> {
    All,
    Session(&'a str),
}

fn sidebar_window_extent_format(position: SidebarPosition) -> &'static str {
    match position {
        SidebarPosition::Left => "#{window_id} #{window_width}",
        SidebarPosition::Top => "#{window_id} #{window_height}",
    }
}

fn list_windows_for_sidebars(
    scope: SidebarWindowScope<'_>,
    position: SidebarPosition,
) -> Result<String> {
    let format = sidebar_window_extent_format(position);
    match scope {
        SidebarWindowScope::All => Cmd::new("tmux")
            .args(&["list-windows", "-a", "-F", format])
            .run_and_capture_stdout(),
        SidebarWindowScope::Session(session_id) => Cmd::new("tmux")
            .args(&["list-windows", "-t", session_id, "-F", format])
            .run_and_capture_stdout(),
    }
}

/// Create sidebars in all existing tmux windows.
///
/// Computes width per-window from `#{window_width}` so each window gets a
/// sidebar proportional to its own dimensions. Unattached sessions may have
/// stale geometry, but `reflow()` corrects them on reattach.
pub(super) fn create_sidebars_in_all_windows(config: &crate::config::Config) -> Result<()> {
    let position = super::read_sidebar_position(config);
    let output = list_windows_for_sidebars(SidebarWindowScope::All, position)?;

    debug!(position = ?position, "create_sidebars_in_all_windows: creating sidebars");
    create_sidebars_from_window_output(&output, config, position)
}

/// Create sidebars in all windows of a specific session (by session_id).
pub(super) fn create_sidebars_in_session(
    session_id: &str,
    config: &crate::config::Config,
) -> Result<()> {
    let position = super::read_sidebar_position(config);
    let output = list_windows_for_sidebars(SidebarWindowScope::Session(session_id), position)?;

    debug!(session_id, position = ?position, "create_sidebars_in_session: creating sidebars");
    create_sidebars_from_window_output(&output, config, position)
}

fn create_sidebars_from_window_output(
    output: &str,
    config: &crate::config::Config,
    position: SidebarPosition,
) -> Result<()> {
    for line in output.lines() {
        let line = line.trim();
        if line.is_empty() {
            continue;
        }
        let (window_id, extent_str) = line.split_once(' ').unwrap_or((line, "0"));
        let window_extent: u16 = extent_str.parse().unwrap_or(0);
        let size = super::effective_size_for(config, position, window_extent);
        let _ = create_sidebar_in_window(window_id, position, size);
    }
    Ok(())
}

fn compute_sidebar_layouts(
    sidebars: &[(String, String)],
    position: SidebarPosition,
) -> Vec<Option<String>> {
    sidebars
        .iter()
        .map(|(window_id, pane_id)| layout_after_sidebar_remove(window_id, pane_id, position))
        .collect()
}

fn kill_panes_and_apply_layouts(sidebars: &[(String, String)], layouts: &[Option<String>]) {
    for (_, pane_id) in sidebars {
        let _ = Cmd::new("tmux").args(&["kill-pane", "-t", pane_id]).run();
    }
    for (i, (window_id, _)) in sidebars.iter().enumerate() {
        if let Some(layout) = &layouts[i] {
            let _ = Cmd::new("tmux")
                .args(&["select-layout", "-t", window_id, layout])
                .run();
        }
    }
}

/// Kill sidebar panes only in a specific session (by session_id).
/// Handles layout restoration for killed panes.
pub(super) fn kill_sidebars_in_session(session_id: &str) {
    let config = crate::config::Config::load(None).unwrap_or_default();
    let position = super::read_sidebar_position(&config);
    let output = Cmd::new("tmux")
        .args(&[
            "list-panes",
            "-a",
            "-F",
            "#{session_id} #{window_id} #{pane_id} #{@workmux_role}",
        ])
        .run_and_capture_stdout()
        .unwrap_or_default();

    let session_sidebars: Vec<(String, String)> = output
        .lines()
        .filter_map(|line| {
            let mut parts = line.splitn(4, ' ');
            let sid = parts.next()?;
            let window_id = parts.next()?;
            let pane_id = parts.next()?;
            let role = parts.next()?.trim();
            (role == SIDEBAR_ROLE_VALUE && sid == session_id)
                .then(|| (window_id.to_string(), pane_id.to_string()))
        })
        .collect();

    let layouts = compute_sidebar_layouts(&session_sidebars, position);
    kill_panes_and_apply_layouts(&session_sidebars, &layouts);
}

/// Find all sidebar panes across all windows. Returns (window_id, pane_id) pairs.
pub(super) fn list_sidebar_panes() -> Vec<(String, String)> {
    let output = Cmd::new("tmux")
        .args(&[
            "list-panes",
            "-a",
            "-F",
            "#{window_id} #{pane_id} #{@workmux_role}",
        ])
        .run_and_capture_stdout()
        .unwrap_or_default();

    output
        .lines()
        .filter_map(|line| {
            let (window_id, rest) = line.split_once(' ')?;
            let (pane_id, role) = rest.split_once(' ')?;
            (role.trim() == SIDEBAR_ROLE_VALUE)
                .then(|| (window_id.to_string(), pane_id.to_string()))
        })
        .collect()
}

/// Kill all sidebar panes and reflow content to fill the window.
///
/// Computes the target layout from the live tree BEFORE killing panes,
/// then applies it after. This preserves pane arrangements the user
/// created while the sidebar was open.
pub(super) fn kill_all_sidebars_and_restore_layouts() {
    let config = crate::config::Config::load(None).unwrap_or_default();
    let position = super::read_sidebar_position(&config);
    let sidebars = list_sidebar_panes();

    let layouts = compute_sidebar_layouts(&sidebars, position);
    kill_panes_and_apply_layouts(&sidebars, &layouts);
}

fn is_own_sidebar(pane_id: &str, own_pane_id: &str) -> bool {
    pane_id == own_pane_id
}

/// Shut down sidebars (called when any sidebar quits).
/// Kills other sidebar panes immediately, then defers our own window's
/// layout reflow so it fires after our process exits and the pane closes.
///
/// In session-scoped mode, only kills sidebars in our session and removes
/// our session from the scope set. Full cleanup (daemon, hooks) only happens
/// when no scoped sessions remain.
pub(super) fn shutdown_all_sidebars(identity: &HostIdentity) {
    let config = crate::config::Config::load(None).unwrap_or_default();
    let position = super::read_sidebar_position(&config);
    let our_pane = identity.pane_id.as_str();
    let our_window = identity.window_id.as_str();
    let our_session_id = identity.session_id.as_str();

    let scope = super::current_scope();

    let sidebars = match &scope {
        super::SidebarScope::Sessions(ids) => {
            let our_sid = our_session_id;
            let output = Cmd::new("tmux")
                .args(&[
                    "list-panes",
                    "-a",
                    "-F",
                    "#{session_id} #{window_id} #{pane_id} #{@workmux_role}",
                ])
                .run_and_capture_stdout()
                .unwrap_or_default();
            let sidebars: Vec<_> = output
                .lines()
                .filter_map(|line| {
                    let mut parts = line.splitn(4, ' ');
                    let sid = parts.next()?;
                    let wid = parts.next()?;
                    let pid = parts.next()?;
                    let role = parts.next()?.trim();
                    (role == SIDEBAR_ROLE_VALUE && sid == our_sid)
                        .then(|| (wid.to_string(), pid.to_string()))
                })
                .collect();

            // Update scope: remove our session from the set
            let mut remaining = ids.clone();
            remaining.remove(our_sid);
            if remaining.is_empty() {
                super::set_scope(&super::SidebarScope::Off);
            } else {
                super::set_scope(&super::SidebarScope::Sessions(remaining));
            }

            sidebars
        }
        _ => list_sidebar_panes(),
    };

    let layouts = compute_sidebar_layouts(&sidebars, position);

    let other_sidebars: Vec<(String, String)> = sidebars
        .iter()
        .filter(|(_, pane_id)| !is_own_sidebar(pane_id, our_pane))
        .cloned()
        .collect();
    let other_layouts: Vec<Option<String>> = sidebars
        .iter()
        .enumerate()
        .filter(|(_, (_, pane_id))| !is_own_sidebar(pane_id, our_pane))
        .map(|(i, _)| layouts[i].clone())
        .collect();
    let our_layout = sidebars
        .iter()
        .enumerate()
        .find(|(_, (_, pane_id))| is_own_sidebar(pane_id, our_pane))
        .and_then(|(i, _)| layouts[i].clone());

    kill_panes_and_apply_layouts(&other_sidebars, &other_layouts);

    // Full cleanup only if no scoped sessions remain (or global mode)
    let remaining_scope = super::current_scope();
    let full_cleanup = !matches!(remaining_scope, super::SidebarScope::Sessions(_));

    if full_cleanup {
        kill_daemon();
        remove_hooks();
        super::clear_sidebar_globals();
    }

    // Defer our own window's layout reflow until after our pane closes
    if let Some(layout) = our_layout {
        let cmd = format!("sleep 0.1; tmux select-layout -t {our_window} '{layout}' 2>/dev/null");
        let _ = Cmd::new("tmux").args(&["run-shell", "-b", &cmd]).run();
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn own_sidebar_matches_captured_pane_id() {
        assert!(is_own_sidebar("%12", "%12"));
        assert!(!is_own_sidebar("%13", "%12"));
    }
}
