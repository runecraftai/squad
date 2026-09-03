# Verification: the Claude account axis

Audience: maintainer verification.

This record supports `bin/sq-claude-account.sh`, `bin/sq-spawn.sh --account`, and the schema in [`docs/configuration.md`](../configuration.md#claude-account-selection-configclaude-accounts).
It records only facts that must be re-established when the `claude` CLI or `sq-quota` version changes.
Task chronology and incident transcripts stay in the private task report and PR evidence.

## Subject

| Field | Value |
|---|---|
| `claude` version | `2.1.259 (Claude Code)` |
| `sq-quota` version | `0.1.2` |
| Platform | macOS arm64 (Darwin 25.6.0) |
| Verified | 2026-09-03 |

This sandbox has exactly one commander-registered Claude account (`gestaoponttual@gmail.com`, config dir `/Users/oserafim/.claude-ponttual`), so the isolation evidence below uses a second, freshly created, never-authenticated `CLAUDE_CONFIG_DIR` rather than a second paid subscription.
The mechanism the whole account axis rests on - two different `CLAUDE_CONFIG_DIR` values producing two independently distinguishable identities from the one real CLI - is exactly what this proves; a genuine second account exercises the identical code path and should be re-run through this same procedure to extend the evidence once registered.

## `CLAUDE_CONFIG_DIR` isolates authentication per directory

```
$ echo "CLAUDE_CONFIG_DIR=${CLAUDE_CONFIG_DIR:-<unset>}"
CLAUDE_CONFIG_DIR=/Users/oserafim/.claude-ponttual

$ claude auth status --json
{
  "loggedIn": true,
  "authMethod": "claude.ai",
  "apiProvider": "firstParty",
  "analyticsDisabled": false,
  "projectsDirectory": "/Users/oserafim/.claude-ponttual/projects",
  "email": "gestaoponttual@gmail.com",
  "orgId": "27f10a83-a026-49be-8d29-055d8df643af",
  "orgName": "gestaoponttual@gmail.com's Organization",
  "subscriptionType": "pro"
}
$ echo "exit=$?"
exit=0

$ mkdir -p /tmp/empty-claude-config
$ CLAUDE_CONFIG_DIR=/tmp/empty-claude-config claude auth status --json
{
  "loggedIn": false,
  "authMethod": "none",
  "apiProvider": "firstParty",
  "analyticsDisabled": false,
  "projectsDirectory": "/tmp/empty-claude-config/projects"
}
$ echo "exit=$?"
exit=1

$ CLAUDE_CONFIG_DIR=/tmp/does-not-exist-xyz claude auth status --json
{
  "loggedIn": false,
  "authMethod": "none",
  "apiProvider": "firstParty",
  "analyticsDisabled": false,
  "projectsDirectory": "/tmp/does-not-exist-xyz/projects"
}
$ echo "exit=$?"
exit=1
```

Three properties follow and are load-bearing for the account axis:

- `claude auth status --json` scopes entirely to `CLAUDE_CONFIG_DIR`: the same command against the real account's dir and an empty dir reports opposite `loggedIn` values.
- Exit status agrees with the parsed field in both directions observed (`0` + `loggedIn: true`, `1` + `loggedIn: false`); `bin/sq-claude-account.sh verify` requires both, never either alone (`squad-coding-guidelines` "Harness-dependent checks").
- A config dir that does not exist on disk yet behaves exactly like an empty one - `loggedIn: false`, exit `1` - rather than erroring, so `sq-spawn.sh --account` fails closed the same way for a registered label whose directory has never been created as for one that was created but never logged in.

## `bin/sq-claude-account.sh verify` against the real CLI

```
$ printf 'real /Users/oserafim/.claude-ponttual\ncold /tmp/empty-claude-config\n' > /tmp/claude-accounts-config/claude-accounts
$ SQUAD_CONFIG_OVERRIDE=/tmp/claude-accounts-config bin/sq-claude-account.sh verify real
/Users/oserafim/.claude-ponttual
$ echo "exit=$?"
exit=0

$ SQUAD_CONFIG_OVERRIDE=/tmp/claude-accounts-config bin/sq-claude-account.sh verify cold
error: Claude account 'cold' at /tmp/empty-claude-config is not logged in (claude auth status exit=1). Registering an account is the commander's own action: log in with CLAUDE_CONFIG_DIR=/tmp/empty-claude-config claude auth login, then retry.
$ echo "exit=$?"
exit=1
```

Reproduced exactly by `tests/sq-claude-account-live-e2e.test.sh` (`SQUAD_CLAUDE_ACCOUNT_LIVE_E2E=1`), which also drives the full `bin/sq-spawn.sh --account` path against the real CLI: a `--account real` spawn succeeds, records `account=real` in `state/<id>.meta`, and forwards `CLAUDE_CONFIG_DIR='/Users/oserafim/.claude-ponttual'` onto the faked launch pane; a `--account cold` spawn refuses with the same "is not logged in" message before any endpoint is created.
Run that guard after any `claude` CLI upgrade and before trusting refreshed account-axis evidence; `tests/sq-claude-account.test.sh` pins the same contract against a fake `claude` binary for ordinary CI runs.

## `sq-quota` scopes claude quota reads to `CLAUDE_CONFIG_DIR`, but cannot read this base's numbers

```
$ sq-quota --provider claude --json
{
  "generatedAt": "2026-09-03T14:04:46.462Z",
  "schemaVersion": 3,
  "providers": [
    {
      "provider": "claude",
      "label": "Claude",
      "source": "unavailable",
      "windows": [],
      "state": {
        "status": "auth_required",
        "stale": false,
        "error": "keychain_prompt_required",
        "sourcesTried": ["oauth-file", "keychain"],
        "reason": "keychain_access_required",
        "remedyCommand": "sq-quota --allow-keychain-prompt"
      },
      "quotaSemantics": { "status": "unknown", "description": "No quota windows are available, so no effective remaining percentage can be computed.", "effectiveAvailability": [] }
    }
  ],
  "help": ["Tell your user: run `sq-quota --allow-keychain-prompt` once and approve Keychain access (\"Always Allow\") so sq-quota can read claude's live quota."]
}
$ echo "exit=$?"
exit=1

$ CLAUDE_CONFIG_DIR=/tmp/empty-claude-config sq-quota --provider claude --json
{
  "generatedAt": "2026-09-03T14:04:58.040Z",
  "schemaVersion": 3,
  "providers": [
    {
      "provider": "claude",
      "label": "Claude",
      "source": "unavailable",
      "windows": [],
      "state": { "status": "auth_required", "stale": false, "error": "credentials_missing", "sourcesTried": ["oauth-file", "keychain"] },
      "quotaSemantics": { "status": "unknown", "description": "No quota windows are available, so no effective remaining percentage can be computed.", "effectiveAvailability": [] }
    }
  ]
}
$ echo "exit=$?"
exit=1
```

`state.error` differs between the two runs (`keychain_prompt_required` for the real, oauth-file-backed account versus `credentials_missing` for an empty dir with no oauth file at all), which proves `sq-quota --provider claude` does scope its inspection to `CLAUDE_CONFIG_DIR` and is not reading one fixed ambient location.
This base's real account still cannot return quota **numbers** - `windows: []`, `status: auth_required` - because reading them needs interactive macOS Keychain approval (`sq-quota --allow-keychain-prompt`), a gap that predates and is unrelated to the account axis.
This is a known, documented gap, not something this change works around: Squad's operating rules forbid touching the macOS keychain, so `--allow-keychain-prompt` is never run on the commander's behalf, and per-account quota headroom stays unavailable in this base for every registered account equally until the commander approves that prompt once.
Reading a specific registered account's quota once that gap clears is `CLAUDE_CONFIG_DIR=<the account's registered dir> sq-quota --provider claude --json`, exactly as shown above.
