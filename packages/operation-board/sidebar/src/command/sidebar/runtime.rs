//! TUI event loop for the sidebar client.

use anyhow::Result;
use crossterm::{
    event::{
        self, DisableMouseCapture, EnableMouseCapture, Event, KeyCode, KeyEventKind, MouseButton,
        MouseEventKind,
    },
    execute,
    terminal::{EnterAlternateScreen, LeaveAlternateScreen, disable_raw_mode, enable_raw_mode},
};
use ratatui::backend::CrosstermBackend;
use std::io;
use std::sync::mpsc;
use std::thread;
use std::time::Duration;

use crate::cmd::Cmd;
use crate::multiplexer::{create_backend, detect_backend};
use crate::shell::shell_quote;

use super::app::{HostIdentity, SidebarApp};
use super::client;
use super::daemon_ctrl::ensure_daemon_running;
use super::panes::shutdown_all_sidebars;
use super::ui::render_sidebar;

/// Drop guard that restores terminal state on panic or early return.
struct TerminalGuard;

impl Drop for TerminalGuard {
    fn drop(&mut self) {
        let _ = disable_raw_mode();
        let _ = execute!(io::stdout(), DisableMouseCapture, LeaveAlternateScreen);
    }
}

enum AppEvent {
    /// A new snapshot is available in the SnapshotHandle.
    SnapshotReady,
    /// A terminal input event (key press, resize, etc.).
    Input(Event),
}

/// Spawn a thread that reads terminal events and forwards them.
/// Must be called AFTER terminal raw mode is enabled.
fn spawn_input_thread(tx: mpsc::Sender<AppEvent>) {
    thread::spawn(move || {
        // event::read() blocks until input is available - zero CPU
        while let Ok(ev) = event::read() {
            if tx.send(AppEvent::Input(ev)).is_err() {
                break;
            }
        }
    });
}

/// Run the sidebar TUI (called by the hidden `_sidebar-run` command).
pub fn run_sidebar() -> Result<()> {
    let mux = create_backend(detect_backend());

    if !mux.is_running().unwrap_or(false) {
        tracing::info!("sidebar-run exiting: mux not running");
        return Ok(());
    }

    // Create app BEFORE entering raw mode: terminal_light::luma() queries
    // the terminal via stdin, which would race with the input reader thread.
    let mut app = SidebarApp::new_client(mux)?;
    let Some(host_identity) = app.host_identity().cloned() else {
        tracing::error!("sidebar-run exiting: host pane identity unavailable");
        return Ok(());
    };

    // Ensure daemon is running (may have auto-exited or crashed)
    let sock_path = ensure_daemon_running()?;

    // Setup terminal (raw mode required before spawning input thread)
    enable_raw_mode()?;
    let mut stdout = io::stdout();
    execute!(stdout, EnterAlternateScreen, EnableMouseCapture)?;
    let _guard = TerminalGuard;
    let backend = CrosstermBackend::new(stdout);
    let mut terminal = ratatui::Terminal::new(backend)?;

    // Channel for all events
    let (tx, rx) = mpsc::channel();

    // Snapshot receiver: overwrites latest, sends SnapshotReady wake via
    // a thin forwarding thread that converts () -> AppEvent::SnapshotReady
    let snapshot_handle = {
        let (wake_tx, wake_rx) = mpsc::sync_channel::<()>(1);
        let event_tx = tx.clone();
        thread::spawn(move || {
            for () in wake_rx {
                if event_tx.send(AppEvent::SnapshotReady).is_err() {
                    break;
                }
            }
        });
        client::connect(&sock_path, wake_tx)
    };

    // Input reader thread (terminal is already in raw mode)
    spawn_input_thread(tx);

    let mut needs_render = true;
    let mut needs_clear = false;
    let startup = std::time::Instant::now();
    let startup_grace = Duration::from_secs(3);
    let tick_rate = Duration::from_millis(250);
    let mut last_spinner_tick = std::time::Instant::now();

    loop {
        // Render before blocking (redraws only when state changed)
        if needs_render {
            if needs_clear {
                terminal.clear()?;
                needs_clear = false;
            }
            terminal.draw(|f| render_sidebar(f, &mut app))?;
            needs_render = false;
        }

        // Adaptive timeout: 250ms when active, block when hidden.
        // If a resize debounce is pending, wake early to process it.
        let timeout = if let Some(deadline) = app.resize_deadline {
            let remaining = deadline.saturating_duration_since(std::time::Instant::now());
            remaining.min(tick_rate)
        } else if app.host_window_active() {
            tick_rate.saturating_sub(last_spinner_tick.elapsed())
        } else {
            // Block until a snapshot or input wakes us. Use a large timeout
            // since recv() without timeout would prevent clean shutdown if
            // all senders drop.
            Duration::from_secs(3600)
        };

        let first_event = match rx.recv_timeout(timeout) {
            Ok(ev) => Some(ev),
            Err(mpsc::RecvTimeoutError::Timeout) => {
                app.process_pending_resize(&startup, startup_grace);
                advance_spinner_if_due(
                    &mut app,
                    &mut last_spinner_tick,
                    tick_rate,
                    &mut needs_render,
                );
                continue;
            }
            Err(mpsc::RecvTimeoutError::Disconnected) => {
                tracing::info!("sidebar-run exiting: event channel disconnected");
                break;
            }
        };

        // Process first event
        if let Some(ev) = first_event {
            process_event(
                ev,
                &mut app,
                &snapshot_handle,
                &startup,
                startup_grace,
                &mut needs_render,
                &mut needs_clear,
            );
        }

        // Drain all pending events to coalesce (avoids multiple redraws)
        while let Ok(ev) = rx.try_recv() {
            process_event(
                ev,
                &mut app,
                &snapshot_handle,
                &startup,
                startup_grace,
                &mut needs_render,
                &mut needs_clear,
            );
        }

        // Process any pending resize whose debounce has elapsed
        app.process_pending_resize(&startup, startup_grace);
        advance_spinner_if_due(
            &mut app,
            &mut last_spinner_tick,
            tick_rate,
            &mut needs_render,
        );

        if app.should_quit {
            tracing::info!(
                host_window = ?app.host_window_id(),
                quit_reason = app.quit_reason.as_deref().unwrap_or("unknown"),
                "sidebar-run quitting"
            );
            if app.quit_silent {
                schedule_pane_kill(&host_identity.pane_id);
            } else {
                shutdown_all_sidebars(&host_identity);
            }
            break;
        }
    }

    // _guard handles cleanup on drop (including the normal exit path)
    Ok(())
}

fn advance_spinner_if_due(
    app: &mut SidebarApp,
    last_spinner_tick: &mut std::time::Instant,
    tick_rate: Duration,
    needs_render: &mut bool,
) {
    if !app.host_window_active() {
        *last_spinner_tick = std::time::Instant::now();
        return;
    }
    if last_spinner_tick.elapsed() >= tick_rate {
        *last_spinner_tick = std::time::Instant::now();
        app.tick();
        *needs_render = true;
    }
}

fn handle_resize_event(
    app: &mut SidebarApp,
    cols: u16,
    rows: u16,
    needs_render: &mut bool,
    needs_clear: &mut bool,
) {
    app.on_resize_event(cols, rows);
    *needs_render = true;
    *needs_clear = true;
}

fn pane_kill_command(pane_id: &str) -> String {
    format!(
        "sleep 0.05; tmux kill-pane -t {} 2>/dev/null || true",
        shell_quote(pane_id)
    )
}

fn schedule_pane_kill(pane_id: &str) {
    let cmd = pane_kill_command(pane_id);
    let _ = Cmd::new("tmux").args(&["run-shell", "-b", &cmd]).run();
}

fn sole_pane_is_sidebar(output: &str, pane_id: &str) -> bool {
    let mut panes = output
        .lines()
        .map(str::trim)
        .filter(|line| !line.is_empty());
    panes.next() == Some(pane_id) && panes.next().is_none()
}

fn sidebar_is_only_pane(window_id: &str, pane_id: &str) -> bool {
    Cmd::new("tmux")
        .args(&["list-panes", "-t", window_id, "-F", "#{pane_id}"])
        .run_and_capture_stdout()
        .is_ok_and(|output| sole_pane_is_sidebar(&output, pane_id))
}

fn should_exit_for_last_pane(
    startup_grace_elapsed: bool,
    identity: Option<&HostIdentity>,
    pane_counts: &std::collections::HashMap<String, usize>,
    verify_live_panes: impl FnOnce(&str, &str) -> bool,
) -> bool {
    if !startup_grace_elapsed {
        return false;
    }
    let Some(identity) = identity else {
        return false;
    };

    pane_counts.get(&identity.window_id).copied().unwrap_or(2) <= 1
        && verify_live_panes(&identity.window_id, &identity.pane_id)
}

fn process_event(
    event: AppEvent,
    app: &mut SidebarApp,
    snapshot_handle: &client::SnapshotHandle,
    startup: &std::time::Instant,
    startup_grace: Duration,
    needs_render: &mut bool,
    needs_clear: &mut bool,
) {
    match event {
        AppEvent::SnapshotReady => {
            if let Some(snapshot) = snapshot_handle.take() {
                let last_pane = should_exit_for_last_pane(
                    startup.elapsed() > startup_grace,
                    app.host_identity(),
                    &snapshot.window_pane_counts,
                    sidebar_is_only_pane,
                );
                if last_pane {
                    let window_id = app.host_window_id().unwrap_or("unknown");
                    app.quit_reason = Some(format!(
                        "last-pane: sidebar is sole pane in window {}",
                        window_id
                    ));
                    app.quit_silent = true;
                    app.should_quit = true;
                }
                app.apply_snapshot(snapshot);
                *needs_render = true;
            }
        }
        AppEvent::Input(Event::Key(key)) if key.kind == KeyEventKind::Press => {
            handle_key_press(app, key.code, key.modifiers);
            *needs_render = true;
        }
        AppEvent::Input(Event::Mouse(_)) if app.pending_exit => {}
        AppEvent::Input(Event::Mouse(mouse)) => {
            match mouse.kind {
                MouseEventKind::Down(MouseButton::Left) => {
                    if let Some(idx) = app.hit_test(mouse.column, mouse.row) {
                        app.select_index(idx);
                        app.jump_to_selected();
                    }
                }
                MouseEventKind::ScrollUp => {
                    app.scroll_up();
                }
                MouseEventKind::ScrollDown => {
                    app.scroll_down();
                }
                _ => {}
            }
            *needs_render = true;
        }
        AppEvent::Input(Event::Resize(cols, rows)) => {
            handle_resize_event(app, cols, rows, needs_render, needs_clear);
        }
        AppEvent::Input(_) => {}
    }
}

fn handle_key_press(
    app: &mut SidebarApp,
    code: KeyCode,
    modifiers: crossterm::event::KeyModifiers,
) {
    if app.pending_exit {
        if code == KeyCode::Char('y') {
            app.quit_reason = Some("confirmed user exit".to_string());
            app.should_quit = true;
        } else {
            app.pending_exit = false;
        }
        return;
    }

    match (code, modifiers) {
        (KeyCode::Char('q'), _)
        | (KeyCode::Esc, _)
        | (KeyCode::Char('c'), crossterm::event::KeyModifiers::CONTROL) => {
            app.pending_exit = true;
        }
        (KeyCode::Char('j'), _) | (KeyCode::Down, _) => app.next(),
        (KeyCode::Char('k'), _) | (KeyCode::Up, _) => app.previous(),
        (KeyCode::Enter, _) => app.jump_to_selected(),
        (KeyCode::Char('G'), _) => app.select_last(),
        (KeyCode::Char('g'), _) => app.select_first(),
        (KeyCode::Char('v'), _) => app.toggle_layout_mode(),
        (KeyCode::Char('z'), _) => app.toggle_sleeping(),
        (KeyCode::Char('f'), _) => app.toggle_filter_mode(),
        _ => {}
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::command::sidebar::app::TemplateError;
    use crossterm::event::KeyModifiers;

    fn test_app() -> SidebarApp {
        SidebarApp::test_with_template_error(TemplateError {
            location: String::new(),
            message: String::new(),
        })
    }

    fn test_identity() -> HostIdentity {
        HostIdentity {
            session_name: "main".to_string(),
            session_id: "$1".to_string(),
            window_id: "@42".to_string(),
            pane_id: "%12".to_string(),
        }
    }

    #[test]
    fn last_pane_exit_requires_snapshot_and_live_confirmation() {
        let identity = test_identity();
        let one_pane = std::collections::HashMap::from([("@42".to_string(), 1)]);
        let two_panes = std::collections::HashMap::from([("@42".to_string(), 2)]);

        assert!(!should_exit_for_last_pane(
            false,
            Some(&identity),
            &one_pane,
            |_, _| panic!("startup grace must skip live verification")
        ));
        assert!(!should_exit_for_last_pane(
            true,
            None,
            &one_pane,
            |_, _| panic!("missing identity must skip live verification")
        ));
        assert!(!should_exit_for_last_pane(
            true,
            Some(&identity),
            &std::collections::HashMap::new(),
            |_, _| panic!("missing count must skip live verification")
        ));
        assert!(!should_exit_for_last_pane(
            true,
            Some(&identity),
            &two_panes,
            |_, _| panic!("multiple panes must skip live verification")
        ));
        assert!(!should_exit_for_last_pane(
            true,
            Some(&identity),
            &one_pane,
            |window_id, pane_id| window_id == "@42" && pane_id != "%12"
        ));
        assert!(should_exit_for_last_pane(
            true,
            Some(&identity),
            &one_pane,
            |window_id, pane_id| window_id == "@42" && pane_id == "%12"
        ));
    }

    #[test]
    fn pane_kill_command_targets_captured_sidebar_pane() {
        assert_eq!(
            pane_kill_command("%12"),
            "sleep 0.05; tmux kill-pane -t '%12' 2>/dev/null || true"
        );
    }

    #[test]
    fn sole_pane_confirmation_requires_sidebar_identity() {
        assert!(sole_pane_is_sidebar("%12\n", "%12"));
        assert!(!sole_pane_is_sidebar("%12\n%13\n", "%12"));
        assert!(!sole_pane_is_sidebar("%13\n", "%12"));
        assert!(!sole_pane_is_sidebar("", "%12"));
    }

    #[test]
    fn resize_requests_full_redraw() {
        let mut app = test_app();
        let mut needs_render = false;
        let mut needs_clear = false;

        handle_resize_event(&mut app, 120, 3, &mut needs_render, &mut needs_clear);

        assert!(needs_render);
        assert!(needs_clear);
    }

    #[test]
    fn q_q_does_not_quit_sidebar() {
        let mut app = test_app();

        handle_key_press(&mut app, KeyCode::Char('q'), KeyModifiers::NONE);
        assert!(app.pending_exit);
        assert!(!app.should_quit);

        handle_key_press(&mut app, KeyCode::Char('q'), KeyModifiers::NONE);
        assert!(!app.pending_exit);
        assert!(!app.should_quit);
    }

    #[test]
    fn y_confirms_pending_exit() {
        let mut app = test_app();

        handle_key_press(&mut app, KeyCode::Char('q'), KeyModifiers::NONE);
        handle_key_press(&mut app, KeyCode::Char('y'), KeyModifiers::NONE);

        assert!(app.should_quit);
        assert_eq!(app.quit_reason.as_deref(), Some("confirmed user exit"));
    }
}
