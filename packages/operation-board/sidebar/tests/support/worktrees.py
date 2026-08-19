"""Helpers for multi-worktree test setup and assertions."""

from collections.abc import Iterable, Sequence
from dataclasses import dataclass
from pathlib import Path

from ..conftest import (
    MuxEnvironment,
    get_window_name,
    get_worktree_path,
    run_workmux_add,
)


@dataclass(frozen=True)
class AddedWorktree:
    branch: str
    window: str
    path: Path


def add_worktrees(
    env: MuxEnvironment,
    workmux_exe_path: Path,
    repo_path: Path,
    branches: Sequence[str],
) -> list[AddedWorktree]:
    worktrees: list[AddedWorktree] = []
    for branch in branches:
        run_workmux_add(env, workmux_exe_path, repo_path, branch)
        worktrees.append(
            AddedWorktree(
                branch=branch,
                window=get_window_name(branch),
                path=get_worktree_path(repo_path, branch),
            )
        )
    return worktrees


def assert_worktrees_exist(worktrees: Sequence[AddedWorktree]) -> None:
    for wt in worktrees:
        assert wt.path.exists(), f"Worktree {wt.branch} should exist"


def assert_worktrees_removed(worktrees: Sequence[AddedWorktree]) -> None:
    for wt in worktrees:
        assert not wt.path.exists(), f"Worktree {wt.branch} should be removed"


def assert_windows_closed(
    env: MuxEnvironment, worktrees: Sequence[AddedWorktree]
) -> None:
    windows = env.list_windows()
    for wt in worktrees:
        assert wt.window not in windows, f"Window for {wt.branch} should be closed"


def assert_branches_present(
    env: MuxEnvironment, repo_path: Path, branches: Iterable[str]
) -> None:
    for branch in branches:
        result = env.run_command(["git", "branch", "--list", branch], cwd=repo_path)
        assert branch in result.stdout, f"Branch {branch} should still exist"


def assert_branches_deleted(
    env: MuxEnvironment, repo_path: Path, branches: Iterable[str]
) -> None:
    for branch in branches:
        result = env.run_command(["git", "branch", "--list", branch], cwd=repo_path)
        assert branch not in result.stdout, f"Branch {branch} should be deleted"
