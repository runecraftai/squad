"""
Tests for `workmux capture` command.

Tests error paths and happy-path capture from a live agent pane.
"""

from pathlib import Path

from .conftest import (
    MuxEnvironment,
    get_window_name,
    run_workmux_add,
    run_workmux_command,
    wait_for_pane_output,
    wait_for_window_ready,
    write_workmux_config,
)
from .support.agent_state import mark_agent_state, start_active_agent


def test_capture_error_worktree_not_found(
    mux_server: MuxEnvironment, workmux_exe_path: Path, mux_repo_path: Path
):
    """Capture fails when worktree doesn't exist."""
    result = run_workmux_command(
        mux_server,
        workmux_exe_path,
        mux_repo_path,
        "capture nonexistent",
        expect_fail=True,
    )
    assert result.exit_code != 0


def test_capture_error_no_agent_in_worktree(
    mux_server: MuxEnvironment, workmux_exe_path: Path, mux_repo_path: Path
):
    """Capture fails when worktree exists but no agent is running."""
    env = mux_server
    write_workmux_config(mux_repo_path)
    run_workmux_add(env, workmux_exe_path, mux_repo_path, "feature-no-agent")

    result = run_workmux_command(
        env,
        workmux_exe_path,
        mux_repo_path,
        "capture feature-no-agent",
        expect_fail=True,
    )
    assert "No agent running" in result.stderr


def test_capture_output_from_agent(
    mux_server: MuxEnvironment, workmux_exe_path: Path, mux_repo_path: Path
):
    """Capture returns pane content from a running agent."""
    env = mux_server
    branch_name = "feature-capture"
    window_name = get_window_name(branch_name)

    write_workmux_config(mux_repo_path, panes=[{"focus": True}])
    run_workmux_add(env, workmux_exe_path, mux_repo_path, branch_name)
    wait_for_window_ready(env, window_name)

    env.send_keys(window_name, "echo CAPTURE_MARKER_12345")
    wait_for_pane_output(env, window_name, "CAPTURE_MARKER_12345")

    mark_agent_state(env, workmux_exe_path, window_name, "working")

    result = run_workmux_command(
        env,
        workmux_exe_path,
        mux_repo_path,
        "capture feature-capture",
    )
    assert result.exit_code == 0
    assert "CAPTURE_MARKER_12345" in result.stdout


def test_capture_strips_ansi(
    mux_server: MuxEnvironment, workmux_exe_path: Path, mux_repo_path: Path
):
    """Capture output has ANSI escape codes stripped."""
    env = mux_server
    start_active_agent(
        env,
        workmux_exe_path,
        mux_repo_path,
        "feature-capture-ansi",
        status="working",
    )

    result = run_workmux_command(
        env,
        workmux_exe_path,
        mux_repo_path,
        "capture feature-capture-ansi",
    )
    assert result.exit_code == 0
    assert "\x1b[" not in result.stdout


def test_capture_custom_line_count(
    mux_server: MuxEnvironment, workmux_exe_path: Path, mux_repo_path: Path
):
    """Capture respects the --lines flag."""
    env = mux_server
    start_active_agent(
        env,
        workmux_exe_path,
        mux_repo_path,
        "feature-capture-lines",
        status="working",
    )

    result = run_workmux_command(
        env,
        workmux_exe_path,
        mux_repo_path,
        "capture feature-capture-lines -n 10",
    )
    assert result.exit_code == 0
