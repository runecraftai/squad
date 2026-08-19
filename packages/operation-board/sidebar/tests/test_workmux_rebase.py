from pathlib import Path

from .conftest import (
    MuxEnvironment,
    assert_window_exists,
    create_commit,
    get_window_name,
    get_worktree_path,
    run_workmux_add,
    run_workmux_command,
    write_workmux_config,
)
from .support.remote_base import setup_worktree_with_remote_only_base


def run_workmux_rebase(
    env: MuxEnvironment,
    workmux_exe_path: Path,
    repo_path: Path,
    branch_name: str | None = None,
    *,
    expect_fail: bool = False,
    working_dir: Path | None = None,
):
    name_part = f" {branch_name}" if branch_name else ""
    return run_workmux_command(
        env,
        workmux_exe_path,
        repo_path,
        f"rebase{name_part}",
        expect_fail=expect_fail,
        working_dir=working_dir,
    )


def test_rebase_uses_saved_base_branch(
    mux_server: MuxEnvironment, workmux_exe_path: Path, repo_path: Path
):
    env = mux_server
    parent_branch = "feature/parent-rebase"
    child_branch = "feature/child-rebase"
    write_workmux_config(repo_path, env=env)

    run_workmux_add(env, workmux_exe_path, repo_path, parent_branch)
    parent_worktree_path = get_worktree_path(repo_path, parent_branch)
    parent_before = env.run_command(
        ["git", "rev-parse", parent_branch], cwd=repo_path
    ).stdout.strip()

    run_workmux_add(env, workmux_exe_path, repo_path, child_branch, base=parent_branch)
    child_worktree_path = get_worktree_path(repo_path, child_branch)
    create_commit(env, child_worktree_path, "feat: child before parent update")
    create_commit(env, parent_worktree_path, "feat: parent update")
    parent_after = env.run_command(
        ["git", "rev-parse", parent_branch], cwd=repo_path
    ).stdout.strip()

    assert parent_before != parent_after

    run_workmux_rebase(env, workmux_exe_path, repo_path, child_branch)

    merge_base = env.run_command(
        ["git", "merge-base", child_branch, parent_branch], cwd=repo_path
    ).stdout.strip()
    assert merge_base == parent_after
    assert child_worktree_path.exists()
    assert_window_exists(env, get_window_name(child_branch))
    env.run_command(
        ["git", "show-ref", "--verify", f"refs/heads/{child_branch}"], cwd=repo_path
    )


def test_rebase_from_within_worktree_succeeds(
    mux_server: MuxEnvironment, workmux_exe_path: Path, repo_path: Path
):
    env = mux_server
    branch_name = "feature/rebase-current"
    window_name = get_window_name(branch_name)
    write_workmux_config(repo_path, env=env)
    run_workmux_add(env, workmux_exe_path, repo_path, branch_name)

    main_file = repo_path / "main_update.txt"
    main_file.write_text("update on main")
    env.run_command(["git", "add", "main_update.txt"], cwd=repo_path)
    env.run_command(["git", "commit", "-m", "feat: main update"], cwd=repo_path)

    worktree_path = get_worktree_path(repo_path, branch_name)
    create_commit(env, worktree_path, "feat: branch work")

    env.run_command(
        ["git", "config", "--local", "--unset", f"branch.{branch_name}.workmux-base"],
        cwd=repo_path,
    )
    main_head = env.run_command(
        ["git", "rev-parse", "main"], cwd=repo_path
    ).stdout.strip()
    run_workmux_rebase(env, workmux_exe_path, repo_path, working_dir=worktree_path)

    merge_base = env.run_command(
        ["git", "merge-base", branch_name, "main"], cwd=repo_path
    ).stdout.strip()
    assert merge_base == main_head
    assert worktree_path.exists()
    assert_window_exists(env, window_name)
    env.run_command(
        ["git", "show-ref", "--verify", f"refs/heads/{branch_name}"], cwd=repo_path
    )


def test_rebase_falls_back_to_main_when_base_is_remote_only(
    mux_server: MuxEnvironment, workmux_exe_path: Path, repo_path: Path
):
    env = mux_server
    branch_name = "feature/rebase-remote-base"
    worktree = setup_worktree_with_remote_only_base(
        env, workmux_exe_path, repo_path, branch_name
    )
    worktree_path = worktree.path

    main_file = repo_path / "main_rebase_fallback.txt"
    main_file.write_text("main fallback")
    env.run_command(["git", "add", "main_rebase_fallback.txt"], cwd=repo_path)
    env.run_command(
        ["git", "commit", "-m", "feat: main fallback update"], cwd=repo_path
    )
    main_head = env.run_command(
        ["git", "rev-parse", "main"], cwd=repo_path
    ).stdout.strip()
    create_commit(env, worktree_path, "feat: remote base child work")

    run_workmux_rebase(env, workmux_exe_path, repo_path, branch_name)

    merge_base = env.run_command(
        ["git", "merge-base", branch_name, "main"], cwd=repo_path
    ).stdout.strip()
    assert merge_base == main_head
    assert worktree_path.exists()
    assert_window_exists(env, get_window_name(branch_name))
    env.run_command(
        ["git", "show-ref", "--verify", f"refs/heads/{branch_name}"], cwd=repo_path
    )


def test_rebase_fails_when_base_is_current_branch(
    mux_server: MuxEnvironment, workmux_exe_path: Path, repo_path: Path
):
    env = mux_server
    branch_name = "feature/rebase-self"
    write_workmux_config(repo_path, env=env)
    run_workmux_add(env, workmux_exe_path, repo_path, branch_name)
    env.run_command(
        ["git", "config", "--local", f"branch.{branch_name}.workmux-base", branch_name],
        cwd=repo_path,
    )

    worktree_path = get_worktree_path(repo_path, branch_name)
    head_before = env.run_command(
        ["git", "rev-parse", branch_name], cwd=repo_path
    ).stdout.strip()

    result = run_workmux_rebase(
        env, workmux_exe_path, repo_path, branch_name, expect_fail=True
    )

    head_after = env.run_command(
        ["git", "rev-parse", branch_name], cwd=repo_path
    ).stdout.strip()
    assert "Cannot rebase branch" in result.stderr
    assert head_after == head_before
    assert worktree_path.exists()
    assert_window_exists(env, get_window_name(branch_name))
