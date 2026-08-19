"""
Tests for agent state management.

Verifies that:
1. workmux set-window-status creates agent state files
2. State files contain correct fields (pane_key, pane_pid, command, workdir, status)
3. State files contain pane identification info needed for reconciliation
4. Status updates overwrite existing state files (no duplicates)

Note: Reconciliation behavior (removing stale state files) is tested implicitly
through the dashboard TUI, which calls load_reconciled_agents(). These tests
verify the state files have the fields needed for reconciliation to work.
"""

import json
import os
import shlex
import shutil
from pathlib import Path

import pytest

from .conftest import (
    MuxEnvironment,
    TmuxEnvironment,
    get_window_name,
    get_worktree_path,
    make_env_script,
    poll_until,
    run_workmux_add,
    wait_for_window_ready,
    write_workmux_config,
)
from .support.agent_state import (
    build_status_cmd,
    build_status_cmd_with_marker,
    get_agents_dir,
    list_agent_state_files,
    read_agent_state,
)


# -----------------------------------------------------------------------------
# Tests
# -----------------------------------------------------------------------------


def test_set_window_status_creates_state_file(
    mux_server: MuxEnvironment, workmux_exe_path: Path, mux_repo_path: Path
):
    """Verifies that workmux set-window-status creates an agent state file."""
    env = mux_server
    branch_name = "feature-state-test"
    window_name = get_window_name(branch_name)

    # Configure with a pane that starts a shell (no blocking command)
    # so we can send keys to it
    write_workmux_config(
        mux_repo_path,
        panes=[
            {"focus": True},  # Just a shell, no command
        ],
    )

    run_workmux_add(env, workmux_exe_path, mux_repo_path, branch_name)

    # Wait for window/shell to be ready
    wait_for_window_ready(env, window_name)

    # Send set-window-status command to the pane using tab title
    # This simulates what Claude hooks do when agent starts working
    status_cmd = build_status_cmd(env, workmux_exe_path, "working")
    env.send_keys(window_name, status_cmd)

    # Wait for state file to be created
    def state_file_exists():
        files = list_agent_state_files(env)
        return len(files) > 0

    assert poll_until(state_file_exists, timeout=5.0), (
        f"No agent state file created after set-window-status. "
        f"State dir: {get_agents_dir(env)}"
    )


def test_set_window_status_disabled_by_env(
    mux_server: MuxEnvironment, workmux_exe_path: Path, mux_repo_path: Path
):
    env = mux_server
    branch_name = "feature-disabled-status-test"
    window_name = get_window_name(branch_name)

    write_workmux_config(
        mux_repo_path,
        panes=[
            {"focus": True},
        ],
    )

    run_workmux_add(env, workmux_exe_path, mux_repo_path, branch_name)
    wait_for_window_ready(env, window_name)

    marker_path = env.tmp_path / "disabled-status-finished"
    status_cmd = build_status_cmd_with_marker(
        env,
        workmux_exe_path,
        "working",
        marker_path,
        {"WORKMUX_DISABLE_SET_WINDOW_STATUS": "1"},
    )
    env.send_keys(window_name, status_cmd)

    assert poll_until(lambda: marker_path.exists(), timeout=5.0)
    assert list_agent_state_files(env) == []


@pytest.mark.tmux_only
def test_set_window_status_without_tmux_env_uses_cwd(
    mux_server: TmuxEnvironment, workmux_exe_path: Path, mux_repo_path: Path
):
    """Codex hooks strip TMUX/TMUX_PANE, so status must resolve the pane by cwd."""
    env = mux_server
    branch_name = "feature-status-no-tmux-env"
    window_name = get_window_name(branch_name)

    write_workmux_config(
        mux_repo_path,
        panes=[
            {"focus": True},
        ],
    )

    run_workmux_add(env, workmux_exe_path, mux_repo_path, branch_name)
    wait_for_window_ready(env, window_name)

    real_tmux = shutil.which("tmux", path=os.environ.get("PATH", ""))
    assert real_tmux is not None, "tmux binary not found"
    tmux_wrapper = env.fake_bin_dir / "tmux"
    tmux_wrapper.write_text(
        "#!/bin/sh\n"
        f'exec {shlex.quote(real_tmux)} -S {shlex.quote(str(env.socket_path))} "$@"\n'
    )
    tmux_wrapper.chmod(0o755)

    marker_path = env.tmp_path / "status-no-tmux-env-finished"
    worktree_path = get_worktree_path(mux_repo_path, branch_name)
    command = (
        "unset TMUX TMUX_PANE; "
        f"cd {shlex.quote(str(worktree_path))} && "
        f"{shlex.quote(str(workmux_exe_path))} set-window-status working; "
        f"touch {shlex.quote(str(marker_path))}"
    )
    status_cmd = make_env_script(
        env,
        command,
        {
            "HOME": str(env.home_path),
            "PATH": env.env["PATH"],
            "XDG_STATE_HOME": env.env["XDG_STATE_HOME"],
            "WORKMUX_BACKEND": "tmux",
        },
    )
    env.send_keys(window_name, status_cmd)

    assert poll_until(lambda: marker_path.exists(), timeout=5.0)
    assert poll_until(lambda: len(list_agent_state_files(env)) > 0, timeout=5.0), (
        "State file not created without TMUX/TMUX_PANE"
    )

    state = read_agent_state(list_agent_state_files(env)[0])
    assert state["pane_key"]["backend"] == "tmux"
    assert state["pane_key"]["instance"] == str(env.socket_path)
    assert state["workdir"] == str(worktree_path)
    assert state["status"] == "working"


def test_state_file_has_correct_fields(
    mux_server: MuxEnvironment, workmux_exe_path: Path, mux_repo_path: Path
):
    """Verifies that agent state files contain the expected fields."""
    env = mux_server
    branch_name = "feature-fields-test"
    window_name = get_window_name(branch_name)

    write_workmux_config(
        mux_repo_path,
        panes=[
            {"focus": True},  # Just a shell
        ],
    )

    run_workmux_add(env, workmux_exe_path, mux_repo_path, branch_name)
    wait_for_window_ready(env, window_name)

    # Trigger state file creation using tab title
    status_cmd = build_status_cmd(env, workmux_exe_path, "working")
    env.send_keys(window_name, status_cmd)

    def state_file_exists():
        return len(list_agent_state_files(env)) > 0

    assert poll_until(state_file_exists, timeout=5.0), "State file not created"

    # Read and verify state file contents
    state_files = list_agent_state_files(env)
    state = read_agent_state(state_files[0])

    # Check required fields exist
    assert "pane_key" in state, "Missing pane_key field"
    assert "pane_pid" in state, "Missing pane_pid field"
    assert "command" in state, "Missing command field"
    assert "workdir" in state, "Missing workdir field"
    assert "status" in state, "Missing status field"

    # Check pane_key structure
    pane_key = state["pane_key"]
    assert "backend" in pane_key, "Missing backend in pane_key"
    assert "instance" in pane_key, "Missing instance in pane_key"
    assert "pane_id" in pane_key, "Missing pane_id in pane_key"

    # Verify values are sensible
    assert pane_key["backend"] == env.backend_name
    assert state["pane_pid"] > 0, "pane_pid should be positive"
    assert state["status"] == "working", (
        f"Expected status 'working', got '{state['status']}'"
    )
    # Command could be "workmux" (if captured during set-window-status) or the shell
    assert state["command"], "command should not be empty"


def test_state_file_contains_pane_info(
    mux_server: MuxEnvironment, workmux_exe_path: Path, mux_repo_path: Path
):
    """Verifies that state file contains valid pane identification info.

    This tests that the state file has the information needed for reconciliation
    to detect stale panes (pane_id, pane_pid, command).
    """
    env = mux_server
    branch_name = "feature-pane-info-test"
    window_name = get_window_name(branch_name)

    write_workmux_config(
        mux_repo_path,
        panes=[
            {"focus": True},  # Just a shell
        ],
    )

    run_workmux_add(env, workmux_exe_path, mux_repo_path, branch_name)
    wait_for_window_ready(env, window_name)

    # Create state file
    marker_path = env.tmp_path / "pane-info-status-finished"
    status_cmd = build_status_cmd_with_marker(
        env,
        workmux_exe_path,
        "working",
        marker_path,
    )
    env.send_keys(window_name, status_cmd)

    assert poll_until(lambda: marker_path.exists(), timeout=5.0)

    def state_file_exists():
        return len(list_agent_state_files(env)) > 0

    assert poll_until(state_file_exists, timeout=5.0), "State file not created"

    # Read state file and verify reconciliation-relevant fields
    state_files = list_agent_state_files(env)
    state = read_agent_state(state_files[0])

    # Verify pane_key has all required fields for pane identification
    pane_key = state["pane_key"]
    assert pane_key["pane_id"], "pane_id should be set"

    # Verify we have PID and command for stale detection
    assert state["pane_pid"] > 0, (
        "pane_pid should be positive (for PID-based stale detection)"
    )
    assert state["command"], "command should be set (for command-change detection)"

    # Verify workdir is set (useful for context)
    assert state["workdir"], "workdir should be set"


def test_status_update_overwrites_state(
    mux_server: MuxEnvironment, workmux_exe_path: Path, mux_repo_path: Path
):
    """Verifies that calling set-window-status again updates the existing state.

    This ensures the state file is updated (not duplicated) when status changes.
    """
    env = mux_server
    branch_name = "feature-status-update-test"
    window_name = get_window_name(branch_name)

    write_workmux_config(
        mux_repo_path,
        panes=[
            {"focus": True},  # Just a shell
        ],
    )

    run_workmux_add(env, workmux_exe_path, mux_repo_path, branch_name)
    wait_for_window_ready(env, window_name)

    # Create initial state with "working" status
    status_cmd = build_status_cmd(env, workmux_exe_path, "working")
    env.send_keys(window_name, status_cmd)

    def state_file_exists():
        return len(list_agent_state_files(env)) > 0

    assert poll_until(state_file_exists, timeout=5.0), "State file not created"

    # Verify initial status
    state_files = list_agent_state_files(env)
    assert len(state_files) == 1, f"Expected 1 state file, got {len(state_files)}"
    state = read_agent_state(state_files[0])
    assert state["status"] == "working", f"Expected 'working', got '{state['status']}'"

    # Update to "done" status
    status_cmd = build_status_cmd(env, workmux_exe_path, "done")
    env.send_keys(window_name, status_cmd)

    # Poll for status to be updated (more reliable than fixed sleep under load)
    def status_is_done():
        files = list_agent_state_files(env)
        if not files:
            return False
        try:
            state = read_agent_state(files[0])
            return state.get("status") == "done"
        except json.JSONDecodeError:
            # File might be partially written, keep polling
            return False

    assert poll_until(status_is_done, timeout=5.0), "Status was not updated to 'done'"

    # Should still be exactly 1 state file (updated, not duplicated)
    state_files = list_agent_state_files(env)
    assert len(state_files) == 1, (
        f"Expected 1 state file after update, got {len(state_files)}"
    )
