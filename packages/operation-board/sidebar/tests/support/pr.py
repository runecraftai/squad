"""Helpers for PR checkout tests."""

from pathlib import Path
from typing import Any

from ..conftest import MuxEnvironment, install_fake_gh_cli


def setup_pr_remote(
    env: MuxEnvironment,
    repo_path: Path,
    remote_repo_path: Path,
) -> None:
    github_url = "https://github.com/testowner/testrepo.git"

    env.run_command(
        ["git", "remote", "add", "origin", github_url],
        cwd=repo_path,
    )
    env.run_command(
        ["git", "remote", "set-url", "--push", "origin", str(remote_repo_path)],
        cwd=repo_path,
    )
    env.run_command(
        ["git", "config", f"url.{remote_repo_path}.insteadOf", github_url],
        cwd=repo_path,
    )
    env.run_command(["git", "push", "-u", "origin", "main"], cwd=repo_path)


def setup_pr_remote_and_branch(
    env: MuxEnvironment,
    repo_path: Path,
    remote_repo_path: Path,
    branch_name: str,
) -> None:
    setup_pr_remote(env, repo_path, remote_repo_path)

    env.run_command(["git", "checkout", "-b", branch_name], cwd=repo_path)
    env.run_command(
        ["git", "commit", "--allow-empty", "-m", "PR changes"],
        cwd=repo_path,
    )
    env.run_command(["git", "push", "-u", "origin", branch_name], cwd=repo_path)
    env.run_command(["git", "checkout", "main"], cwd=repo_path)
    env.run_command(["git", "branch", "-D", branch_name], cwd=repo_path)


def pr_view_json(
    *,
    branch: str = "feature-branch",
    owner: str = "testowner",
    state: str = "OPEN",
    draft: bool = False,
    title: str = "Add new feature",
    author: str = "contributor",
) -> dict[str, Any]:
    return {
        "headRefName": branch,
        "headRepositoryOwner": {"login": owner},
        "state": state,
        "isDraft": draft,
        "title": title,
        "author": {"login": author},
    }


def install_fake_pr_view(
    env: MuxEnvironment,
    *,
    number: int = 123,
    branch: str = "feature-branch",
    owner: str = "testowner",
    state: str = "OPEN",
    draft: bool = False,
    title: str = "Add new feature",
    author: str = "contributor",
) -> dict[str, Any]:
    pr_data = pr_view_json(
        branch=branch,
        owner=owner,
        state=state,
        draft=draft,
        title=title,
        author=author,
    )
    install_fake_gh_cli(env, pr_number=number, json_response=pr_data)
    return pr_data
