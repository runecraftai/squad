# Release operations

This runbook covers activation, normal operation, recovery, and emergency shutdown for the `pi-pr-review` npm release pipeline. GitHub tags, GitHub releases, workflow artifacts, and npm versions are immutable release records; never move, reuse, or replace them.

## Security boundaries

`.github/workflows/release-please.yml` denies permissions by default and uses four jobs:

| Job | Environment | Permissions | Purpose |
| --- | --- | --- | --- |
| `release` | `release-automation` | `contents: read` for `github.token` | Reads the environment-scoped App key, creates a short-lived repository installation token, and runs Release Please. |
| `validate` | none | `contents: read` | Checks the exact tag and `main` ancestry before running source, sets up pinned Node and Bun releases without installing project dependencies, then runs all tests and package/workflow policy checks. |
| `package` | none | `contents: read` | Uses a fresh runner and exact tag checkout. It installs nothing and runs no repository script; it creates one `npm pack --ignore-scripts` tarball and uploads it by unique artifact ID. |
| `publish` | `npm-publish` | `actions: read`, `id-token: write` | Checks out no source, runs no repository code, verifies the exact current-run tarball, rechecks npm state, and publishes through OIDC. |

The App private key and npm OIDC permission never coexist with project execution. The publish job accepts only the artifact ID and digests emitted by the fresh package job, and it independently checks the archive paths, package metadata, Pi entry points, lifecycle-script policy, package version, and SHA-256.

All jobs require these repository variables to equal the exact lowercase value `true`:

- `NPM_TRUSTED_PUBLISHING_READY`
- `RELEASE_AUTOMATION_ENABLED`

An absent or different value closes the gate. Keep both variables absent throughout rollout.

## One-time activation

### 1. Protect GitHub environments

Create both environments with selected deployment branches restricted to branch `main` only. Tags and unrestricted deployment policies are not allowed.

For `release-automation`:

- Store `NERV_OPS_PRIVATE_KEY` only as an environment secret.
- Store the App Client ID as the repository variable `NERV_OPS_CLIENT_ID`. The Client ID is an identifier, not a secret.
- Do not configure an approval gate that could block routine Release Please operation.

For `npm-publish`:

- Store no secrets.
- Use the environment name as part of the npm trusted-publisher identity.
- With the current single-operator model, do not enable prevent-self-review or required reviewers. Add an independent reviewer and backup only when those people actually exist.

### 2. Scope the GitHub App

The private `nerv-ops` App should be installed only on intended repositories and have only:

- Contents: read and write
- Pull requests: read and write
- Metadata: read-only, required by GitHub

Do not grant Actions, Administration, Environments, Secrets, or Workflows permissions. Do not allow the App to bypass `main` protection. The workflow omits `owner` and `repositories` when creating the token, so the resulting installation token is scoped to the current repository.

Upload the existing active App private key without putting it in a shell argument or repository file:

```bash
gh secret set NERV_OPS_PRIVATE_KEY \
  --repo 10ego/pi-pr-review \
  --env release-automation \
  < /secure/path/to/nerv-ops-private-key.pem
```

After the environment secret is confirmed and release authentication is validated, delete the repository-level secret with the same name. Do not rotate or revoke the still-active key solely for this migration.

### 3. Bind npm trusted publishing

In the npm settings for `pi-pr-review`, configure the GitHub Actions trusted publisher with exactly:

```text
Owner:       10ego
Repository:  pi-pr-review
Workflow:    release-please.yml
Environment: npm-publish
```

Do not configure `NPM_TOKEN` or another token fallback. Keep npm account 2FA enabled and remove unused automation tokens.

### 4. Protect release tags

Protect tags matching `v*` against updates and deletion, and enable immutable GitHub releases when available. Release Please must be able to create a new tag, but neither operators nor the App should be able to move an existing release tag.

### 5. Verify configuration before opening gates

Use name-only checks; never print the private key:

```bash
gh secret list --repo 10ego/pi-pr-review
gh secret list --repo 10ego/pi-pr-review --env release-automation
gh secret list --repo 10ego/pi-pr-review --env npm-publish
gh api repos/10ego/pi-pr-review/environments/release-automation
gh api repos/10ego/pi-pr-review/environments/npm-publish
npm view pi-pr-review version dist-tags --json
```

Confirm:

- `main` still requires `Validate PR title` and `Test`, including for administrators.
- Both environments admit only `main`.
- The App key appears only in `release-automation`.
- `npm-publish` contains no secrets.
- npm names the exact workflow and `npm-publish` environment.
- Every workflow action is pinned to an approved full commit SHA.
- `bun test`, `npm run test:tooling`, `npm run verify:release-version`, `npm run verify:package`, `npm run verify:workflows`, and Actionlint pass on `main`.

### 6. Open gates in order

Set npm readiness first:

```bash
gh variable set NPM_TRUSTED_PUBLISHING_READY \
  --repo 10ego/pi-pr-review \
  --body true
```

After one final configuration review, enable automation:

```bash
gh variable set RELEASE_AUTOMATION_ENABLED \
  --repo 10ego/pi-pr-review \
  --body true
```

A variable change does not cancel a workflow already running. Cancel unsafe or stale runs separately.

## Normal releases

1. A conventional squash commit lands on `main`.
2. `release` enters `release-automation`, creates a one-hour repository-scoped App token, and creates or updates the Release Please PR.
3. Required checks hold the release PR until it is safe to auto-merge with squash.
4. The release PR merge synchronizes the root package version, changelog, and release manifest.
5. A subsequent Release Please run creates the exact `v<version>` tag and non-draft GitHub release.
6. `validate` verifies the tag before running code, tests the release, and checks npm availability.
7. `package` creates and uploads one fresh lifecycle-script-disabled tarball.
8. `publish` verifies the current-run artifact, rechecks that the exact version is absent and the selected dist-tag advances, then publishes with npm provenance.

Stable versions explicitly update `latest`; prereleases explicitly update `next`. A normal run fails if the exact npm version already exists.

## Recovery publication

Recovery is only for an existing non-draft GitHub release whose npm publication did not complete. Inspect the release and dispatch from `main`:

```bash
gh release view v1.8.0 \
  --repo 10ego/pi-pr-review \
  --json tagName,isDraft,targetCommitish

gh workflow run .github/workflows/release-please.yml \
  --repo 10ego/pi-pr-review \
  --ref main \
  -f tag=v1.8.0
```

Recovery skips the App-key environment, verifies the release with read-only `github.token`, and performs all normal validation, packaging, and publication checks. If npm already contains the exact version, recovery succeeds as a no-op.

Never recover by moving a tag, drafting a replacement release, rebuilding an existing npm version, or uploading a manually repacked artifact.

## Emergency shutdown

Close automation immediately by deleting or changing `RELEASE_AUTOMATION_ENABLED`:

```bash
gh variable delete RELEASE_AUTOMATION_ENABLED --repo 10ego/pi-pr-review
```

Close `NPM_TRUSTED_PUBLISHING_READY` as well if npm OIDC or the trusted-publisher identity is suspect. Cancel active workflow runs and revoke the App key if GitHub credentials may be exposed. Restore npm readiness first and release automation last only after all prerequisites are revalidated.

## Maintenance

- Update pinned Actions through reviewed pull requests and update the workflow policy allowlist in the same change.
- Run package inspection only with `--ignore-scripts`.
- Add no package install, pack, prepare, or publish lifecycle scripts without a new security review.
- Update the package file policy when adding a new published component path.
- Treat a changed artifact digest, moved tag, npm integrity mismatch, or unexpected dist-tag as a security incident rather than a reason to bypass a check.
