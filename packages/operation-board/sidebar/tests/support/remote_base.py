"""Helpers for worktrees whose stored base is a remote-only ref."""

from dataclasses import dataclass
from pathlib import Path

from ..conftest import (
    MuxEnvironment,
    get_worktree_path,
    run_workmux_add,
    write_workmux_config,
)


@dataclass(frozen=True)
class RemoteOnlyBaseWorktree:
    branch: str
    remote_base: str
    path: Path


def setup_worktree_with_remote_only_base(
    env: MuxEnvironment,
    workmux_exe_path: Path,
    repo_path: Path,
    branch_name: str,
    remote_base: str = "origin/remote-base",
) -> RemoteOnlyBaseWorktree:
    write_workmux_config(repo_path, env=env)
    env.run_command(
        ["git", "update-ref", f"refs/remotes/{remote_base}", "HEAD"],
        cwd=repo_path,
    )
    run_workmux_add(env, workmux_exe_path, repo_path, branch_name)
    worktree_path = get_worktree_path(repo_path, branch_name)
    env.run_command(
        ["git", "config", "--local", f"branch.{branch_name}.workmux-base", remote_base],
        cwd=repo_path,
    )
    return RemoteOnlyBaseWorktree(branch_name, remote_base, worktree_path)
