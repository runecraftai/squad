//! Daemon lifecycle management: spawn, kill, signal, health checks.

use anyhow::{Result, anyhow};
use std::path::PathBuf;
use std::time::Duration;

use crate::cmd::Cmd;
use crate::multiplexer::{create_backend, detect_backend};

use super::daemon;

/// Ensure the daemon is running, spawning it if needed. Returns the socket path.
pub(super) fn ensure_daemon_running() -> Result<PathBuf> {
    let mux = create_backend(detect_backend());
    let instance_id = mux.instance_id();
    let sock_path = daemon::socket_path(&instance_id);

    if std::os::unix::net::UnixStream::connect(&sock_path).is_ok() {
        return Ok(sock_path);
    }

    // Stale socket from a crashed daemon
    let _ = std::fs::remove_file(&sock_path);
    spawn_daemon()?;
    if !wait_for_socket(&instance_id, Duration::from_secs(2)) {
        return Err(anyhow!("Sidebar daemon failed to start"));
    }
    Ok(sock_path)
}

/// Spawn the sidebar daemon as a detached background process.
///
/// When `SQUAD_BASE` or `SQUAD_HOME` is set, automatically uses the
/// Squad data source instead of the default tmux data source.
fn spawn_daemon() -> Result<()> {
    let exe = std::env::current_exe()?;
    let mux = create_backend(detect_backend());
    let instance_id = mux.instance_id();
    let mut cmd = std::process::Command::new(exe);
    cmd.arg("_sidebar-daemon");

    // Auto-detect Squad environment and use Squad data source
    if std::env::var("SQUAD_BASE").is_ok() || std::env::var("SQUAD_HOME").is_ok() {
        cmd.arg("--data-source").arg("squad");
    }

    // Pass instance ID so daemon uses the same socket path as the client
    cmd.arg("--instance-id").arg(&instance_id);

    cmd.stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .spawn()?;
    Ok(())
}

/// Wait for the daemon's Unix socket to appear.
fn wait_for_socket(instance_id: &str, timeout: Duration) -> bool {
    let path = daemon::socket_path(instance_id);
    let start = std::time::Instant::now();
    while start.elapsed() < timeout {
        if path.exists() {
            return true;
        }
        std::thread::sleep(Duration::from_millis(50));
    }
    false
}

/// Read the daemon PID from the tmux global option.
fn daemon_pid() -> Option<String> {
    Cmd::new("tmux")
        .args(&["show-option", "-gqv", "@workmux_sidebar_daemon_pid"])
        .run_and_capture_stdout()
        .ok()
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty())
}

/// Kill the sidebar daemon (sends SIGTERM, cleans up tmux option).
pub(super) fn kill_daemon() {
    if let Some(pid) = daemon_pid() {
        let _ = std::process::Command::new("kill")
            .args(["-TERM", &pid])
            .stderr(std::process::Stdio::null())
            .status();
    }
    let _ = Cmd::new("tmux")
        .args(&["set-option", "-gu", "@workmux_sidebar_daemon_pid"])
        .run();
}

/// Signal the daemon to do an immediate refresh, bypassing tmux hook latency.
pub(super) fn signal_daemon() {
    if let Some(pid) = daemon_pid() {
        let _ = std::process::Command::new("kill")
            .args(["-USR1", &pid])
            .stderr(std::process::Stdio::null())
            .status();
    }
}
