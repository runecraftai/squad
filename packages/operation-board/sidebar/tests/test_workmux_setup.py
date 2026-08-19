"""Tests for `workmux setup` command."""

import json
from pathlib import Path

from .conftest import (
    MuxEnvironment,
    run_workmux_command,
)
from .support.setup import run_setup_with_answers, write_claude_manual_status_hook


# ---------------------------------------------------------------------------
# Non-interactive tests (no prompt expected)
# ---------------------------------------------------------------------------


class TestSetupNoPrompt:
    """Tests where setup exits without prompting for input."""

    def test_no_agents_detected(
        self,
        mux_server: MuxEnvironment,
        workmux_exe_path: Path,
        repo_path: Path,
    ):
        """Prints message when no agent directories exist."""
        result = run_workmux_command(mux_server, workmux_exe_path, repo_path, "setup")
        assert "No agents detected" in result.stdout

    def test_claude_hooks_already_configured(
        self,
        mux_server: MuxEnvironment,
        workmux_exe_path: Path,
        repo_path: Path,
    ):
        """Claude with manual hooks shows all-configured message."""
        write_claude_manual_status_hook(mux_server.home_path / ".claude")

        result = run_workmux_command(
            mux_server, workmux_exe_path, repo_path, "setup --hooks"
        )
        assert "All agents have status tracking configured" in result.stdout

    def test_claude_plugin_enabled(
        self,
        mux_server: MuxEnvironment,
        workmux_exe_path: Path,
        repo_path: Path,
    ):
        """Claude with enabled plugin shows all-configured message."""
        claude_dir = mux_server.home_path / ".claude"
        claude_dir.mkdir()
        settings = {"enabledPlugins": {"workmux-status@workmux": True}}
        (claude_dir / "settings.json").write_text(json.dumps(settings))

        result = run_workmux_command(
            mux_server, workmux_exe_path, repo_path, "setup --hooks"
        )
        assert "All agents have status tracking configured" in result.stdout

    def test_claude_plugin_disabled_counts_as_configured(
        self,
        mux_server: MuxEnvironment,
        workmux_exe_path: Path,
        repo_path: Path,
    ):
        """Disabled plugin still counts as configured (user knows about it)."""
        claude_dir = mux_server.home_path / ".claude"
        claude_dir.mkdir()
        settings = {"enabledPlugins": {"workmux-status@workmux": False}}
        (claude_dir / "settings.json").write_text(json.dumps(settings))

        result = run_workmux_command(
            mux_server, workmux_exe_path, repo_path, "setup --hooks"
        )
        assert "All agents have status tracking configured" in result.stdout

    def test_opencode_plugin_configured(
        self,
        mux_server: MuxEnvironment,
        workmux_exe_path: Path,
        repo_path: Path,
    ):
        """OpenCode with plugin file shows all-configured message."""
        plugin_dir = mux_server.home_path / ".config" / "opencode" / "plugin"
        plugin_dir.mkdir(parents=True)
        (plugin_dir / "workmux-status.ts").write_text("// plugin")

        result = run_workmux_command(
            mux_server, workmux_exe_path, repo_path, "setup --hooks"
        )
        assert "All agents have status tracking configured" in result.stdout

    def test_omp_extension_configured(
        self,
        mux_server: MuxEnvironment,
        workmux_exe_path: Path,
        repo_path: Path,
    ):
        """OMP with extension file shows all-configured message."""
        extension_dir = mux_server.home_path / ".omp" / "agent" / "extensions"
        extension_dir.mkdir(parents=True)
        (extension_dir / "workmux-status.ts").write_text("// extension")

        result = run_workmux_command(
            mux_server, workmux_exe_path, repo_path, "setup --hooks"
        )
        assert "All agents have status tracking configured" in result.stdout

    def test_both_agents_configured(
        self,
        mux_server: MuxEnvironment,
        workmux_exe_path: Path,
        repo_path: Path,
    ):
        """Both agents configured shows all-configured message."""
        write_claude_manual_status_hook(mux_server.home_path / ".claude")
        plugin_dir = mux_server.home_path / ".config" / "opencode" / "plugin"
        plugin_dir.mkdir(parents=True)
        (plugin_dir / "workmux-status.ts").write_text("// plugin")

        result = run_workmux_command(
            mux_server, workmux_exe_path, repo_path, "setup --hooks"
        )
        assert "All agents have status tracking configured" in result.stdout

    def test_requires_interactive_terminal(
        self,
        mux_server: MuxEnvironment,
        workmux_exe_path: Path,
        repo_path: Path,
    ):
        """Fails when stdin is piped (not a terminal)."""
        result = run_workmux_command(
            mux_server,
            workmux_exe_path,
            repo_path,
            "setup",
            stdin_input="y\n",
            expect_fail=True,
        )
        assert "interactive terminal" in result.stderr


# ---------------------------------------------------------------------------
# Interactive tests (prompt for Y/n)
# ---------------------------------------------------------------------------


class TestSetupInstall:
    """Tests that exercise the interactive install prompt."""

    def test_claude_install_accept(
        self,
        mux_server: MuxEnvironment,
        workmux_exe_path: Path,
        repo_path: Path,
    ):
        """Answering 'y' installs hooks into settings.json."""
        claude_dir = mux_server.home_path / ".claude"
        claude_dir.mkdir()

        run_setup_with_answers(mux_server, workmux_exe_path, hooks_answer="y")

        settings_path = claude_dir / "settings.json"
        assert settings_path.exists()
        settings = json.loads(settings_path.read_text())
        assert "hooks" in settings
        assert "UserPromptSubmit" in settings["hooks"]
        assert "Notification" in settings["hooks"]
        assert "PostToolUse" in settings["hooks"]
        assert "Stop" in settings["hooks"]

    def test_claude_install_default_enter(
        self,
        mux_server: MuxEnvironment,
        workmux_exe_path: Path,
        repo_path: Path,
    ):
        """Pressing Enter accepts installation (default is Y)."""
        claude_dir = mux_server.home_path / ".claude"
        claude_dir.mkdir()

        run_setup_with_answers(mux_server, workmux_exe_path, hooks_answer="")

        settings_path = claude_dir / "settings.json"
        assert settings_path.exists()
        settings = json.loads(settings_path.read_text())
        assert "hooks" in settings

    def test_claude_install_decline(
        self,
        mux_server: MuxEnvironment,
        workmux_exe_path: Path,
        repo_path: Path,
    ):
        """Answering 'n' skips installation."""
        claude_dir = mux_server.home_path / ".claude"
        claude_dir.mkdir()

        run_setup_with_answers(mux_server, workmux_exe_path, hooks_answer="n")

        settings_path = claude_dir / "settings.json"
        assert not settings_path.exists()

    def test_opencode_install_accept(
        self,
        mux_server: MuxEnvironment,
        workmux_exe_path: Path,
        repo_path: Path,
    ):
        """Accepting installs OpenCode package and plugin files."""
        opencode_dir = mux_server.home_path / ".config" / "opencode"
        opencode_dir.mkdir(parents=True)

        run_setup_with_answers(mux_server, workmux_exe_path, hooks_answer="y")

        package_json_path = opencode_dir / "package.json"
        plugin_path = opencode_dir / "plugins" / "workmux-status.ts"
        assert package_json_path.exists()
        assert len(package_json_path.read_text()) > 0
        assert plugin_path.exists()
        assert len(plugin_path.read_text()) > 0

    def test_omp_install_accept(
        self,
        mux_server: MuxEnvironment,
        workmux_exe_path: Path,
        repo_path: Path,
    ):
        """Accepting installs OMP extension file."""
        omp_dir = mux_server.home_path / ".omp" / "agent"
        omp_dir.mkdir(parents=True)

        run_setup_with_answers(mux_server, workmux_exe_path, hooks_answer="y")

        extension_path = omp_dir / "extensions" / "workmux-status.ts"
        assert extension_path.exists()
        extension_text = extension_path.read_text()
        assert "@oh-my-pi/pi-coding-agent" in extension_text
        assert 'workmux", ["set-window-status' in extension_text
        assert 'pi.on("message_end"' in extension_text
        assert '"role" in event.message' in extension_text
        assert 'event.message.role === "assistant"' in extension_text
        assert 'event.toolName === "ask"' in extension_text
        assert 'setStatus("waiting")' in extension_text

    def test_both_agents_install_accept(
        self,
        mux_server: MuxEnvironment,
        workmux_exe_path: Path,
        repo_path: Path,
    ):
        """Accepting installs both agents' hooks."""
        claude_dir = mux_server.home_path / ".claude"
        claude_dir.mkdir()
        opencode_dir = mux_server.home_path / ".config" / "opencode"
        opencode_dir.mkdir(parents=True)

        run_setup_with_answers(mux_server, workmux_exe_path, hooks_answer="y")

        settings_path = claude_dir / "settings.json"
        assert settings_path.exists()
        settings = json.loads(settings_path.read_text())
        assert "hooks" in settings
        assert "Stop" in settings["hooks"]

        package_json_path = opencode_dir / "package.json"
        plugin_path = opencode_dir / "plugins" / "workmux-status.ts"
        assert package_json_path.exists()
        assert plugin_path.exists()

    def test_claude_preserves_existing_settings(
        self,
        mux_server: MuxEnvironment,
        workmux_exe_path: Path,
        repo_path: Path,
    ):
        """Installing hooks preserves existing settings.json content."""
        claude_dir = mux_server.home_path / ".claude"
        claude_dir.mkdir()
        existing = {
            "permissions": {"allow": ["Bash"]},
            "hooks": {
                "Stop": [
                    {
                        "hooks": [
                            {
                                "type": "command",
                                "command": "afplay /System/Library/Sounds/Glass.aiff",
                            }
                        ]
                    }
                ]
            },
        }
        (claude_dir / "settings.json").write_text(json.dumps(existing, indent=2))

        run_setup_with_answers(mux_server, workmux_exe_path, hooks_answer="y")

        settings = json.loads((claude_dir / "settings.json").read_text())
        assert "permissions" in settings
        assert settings["permissions"]["allow"] == ["Bash"]
        stop_commands = [
            hook.get("command", "")
            for group in settings["hooks"]["Stop"]
            for hook in group.get("hooks", [])
        ]
        assert "afplay /System/Library/Sounds/Glass.aiff" in stop_commands
        assert "workmux set-window-status done" in stop_commands
        assert "UserPromptSubmit" in settings["hooks"]
        assert "Notification" in settings["hooks"]
        assert "PostToolUse" in settings["hooks"]
