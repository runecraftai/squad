# Orca Linux Backend Validation + Mobile Companion Capability

Date: 2026-08-22 · Machine: Omarchy (Arch) x86_64, kernel 7.1.8-arch1-3 · Orca version validated: **1.4.188**

---

## Goal A — Orca as a Squad runtime backend on Linux

### Verdict

**YES with one required adapter change at the time of this validation.** Squad's Orca backend worked end to end on this machine
for spawn → peek → send. The single blocking defect observed then was at teardown: Orca on Linux returns
**composite worktree ids** (`repoId::path`) that `bin/sq-backend.sh`'s endpoint atom validation
rejects, so `bin/sq-teardown.sh` refuses cleanup ("Orca endpoint metadata ... malformed or
inconsistent"). Spawn, runtime checks, terminal read, send, and worktree removal via raw CLI all
work unmodified.

### Install record

- Downloaded `orca-linux.AppImage` (205,918,977 bytes, x86_64) from release `v1.4.188`
  (`https://github.com/stablyai/orca/releases/download/v1.4.188/orca-linux.AppImage`).
- Installed at `~/.local/bin/orca-linux.AppImage`, mode 755, symlinked as `~/.local/bin/orca`.
  `/opt` was unavailable (no sudo password); `~/.local/bin` was the authorized fallback.
- FUSE available on this machine (`/dev/fuse`, fusermount3), so the AppImage runs directly — no
  `--appimage-extract` needed.
- Desktop session present (`DISPLAY=:0`), so no Xvfb was needed (the headless guide's Xvfb path
  only applies when no DISPLAY exists).
- Runtime started with: `orca serve --port 6768 --pairing-address <LAN-IP> --mobile-pairing --json`
  → ready JSON block with `schemaVersion: 1`. `orca status --json` reports `reachable=true`,
  `state=ready`, `appVersion=1.4.188`.

### Adapter smoke evidence (all through Squad helpers, zero code changes)

Scratch recon task `orca-smoke` against throwaway repo `/tmp/orca-smoke-repo`
(git init + one commit), spawned with:
`bin/sq-spawn.sh orca-smoke /tmp/orca-smoke-repo --recon --harness pi --backend orca`

| Step | Result |
|---|---|
| Readiness gate (`fm_backend_orca_runtime_check`) | ✅ passed (`reachable=true state=ready`) |
| `orca repo add/show` | ✅ worked |
| `orca worktree create` (Orca-managed isolation) | ✅ worktree at `/home/rehem/orca/workspaces/orca-smoke-repo/sq-orca-smoke` |
| `orca terminal create` + harness launch | ✅ pi launched in Orca terminal; meta recorded `backend=orca`, `terminal=term_…`, `orca_worktree_id=…` |
| `sq-peek` (`orca terminal read`) | ✅ read agent output incl. completion transcript |
| `sq-send` steer delivery (pre-native Pi delivery) | ⚠️ text delivered and executed by the worker, but returned `verdict=unknown` ("delivery unconfirmed") because the post-send composer-clearance classifier found no bordered composer row to verify against (pi's prompt shape here doesn't match the classifier's expectations - same conservative `unknown` behavior documented for bare shell rows; delivery itself succeeded) |
| Teardown | ❌ REFUSED: composite worktree id fails `fm_backend_endpoint_atom_valid` (see below) |

Cleanup completed manually via raw CLI (equivalent to what teardown would do): terminal closed,
`orca worktree rm --worktree id:<composite-id> --force` returned `removed:true`, scratch state
files removed, `/tmp/orca-smoke-repo` deleted.

### macOS-assumption inventory (`bin/backends/orca.sh` + adjacent paths)

The adapter script itself contains **no macOS-specific paths, brew references, or platform
checks** — it is pure `orca` CLI orchestration. The assumptions live in docs and response-shape
handling:

1. **Worktree id shape (the one real break)** — adapter stores whatever `result.worktrees[].id`
   returns. On macOS builds this is a bare UUID; on Linux v1.4.188 it is a composite
   `<repoUUID>::<absolutePath>` (confirmed via `orca worktree list --json`). The id passes through
   spawn fine, but `fm_backend_endpoint_atom_valid()` in `bin/sq-backend.sh` only accepts
   `[A-Za-z0-9._@%+-]`, rejecting `:` and `/`, so teardown validation refuses.
   *Minimal fix:* widen the atom pattern for orca worktree ids (allow `:` and `/`), or split the
   recorded value into repo-id + path fields. The raw CLI already accepts the composite id in
   `--worktree id:<value>` selectors (verified: `removed:true`).
2. **Install source assumption (docs, not code)** — `docs/orca-backend.md` says `/Applications/Orca.app`
   + `brew install orca`. On Linux the AppImage *is* the CLI (`~/.local/bin/orca → AppImage`), and
   `serve` also self-installs a native desktop CLI at `~/.local/bin/orca-ide`. Note: serve logs
   `[serve] bare orca dispatcher skipped-foreign` for the AppImage symlink, i.e. Orca prefers its
   own `orca-ide`; either binary answers all commands the adapter uses.
3. **App-running requirement (docs, not code)** — docs require the desktop app running; on Linux
   `orca serve` is the supported headless form (repo guide `docs/reference/headless-linux-server.md`)
   and satisfies the same readiness contract.
4. **Composer idle regex** `^Type a message\.\.\.$` — harness-dependent, not OS-dependent; no
   change observed needed beyond the pre-existing conservative `unknown` verdict noted above.
5. Everything else (status JSON contract `result.runtime.reachable/state`, terminal handle shape
   `term_<uuid>`, `terminal read/send/close` flags, cursor pagination fields) matched the verified
   shapes exactly — no changes needed.

### Required-change list for full Linux support

- [ ] R1 (blocking): accept composite Orca worktree ids in endpoint metadata validation
      (`bin/sq-backend.sh` atom check; possibly also `bin/sq-teardown.sh`'s identity-match logic,
      which compares the id-derived path).
- [ ] R2 (docs): update `docs/orca-backend.md`: Linux install = AppImage/deb (`gh release` asset
      `orca-linux.AppImage` or `orca-ide_<ver>_amd64.deb`), runtime = `orca serve`, CLI =
      AppImage or self-installed `orca-ide`; keep macOS/brew as the macOS path.
- [ ] R3 (optional): investigate sq-send's `verdict=unknown` under the pi harness on Linux —
      delivery works; only the confirmation classifier stays unknown.

Regression entry points for the follow-up strike: `tests/sq-backend-orca.test.sh`,
`tests/sq-backend.test.sh`.

### Goal A evidence summary

At the time of this validation, `config/backend=orca` worked on this machine: spawns landed in real isolated Orca-managed
worktrees with working terminals, peek/send operated them, and readiness gating passed. Teardown
was blocked pending R1; see [`docs/orca-backend.md`](docs/orca-backend.md) and [`docs/verification/runtime-backends.md`](docs/verification/runtime-backends.md#orca) for the current contract and evidence.

---

## Goal B — Orca Android mobile companion capability

### Answer: INTERACTIVE, not status-only

Someone on the phone **can type into an agent terminal and effectively run shell commands
remotely.** The official docs describe it as "read-mostly," but that undersells the input surface;
the actual capability list (onorca.dev/docs/mobile) includes:

- Raw terminal view with **Live input mode**: a capture field forwards keyboard bytes directly to
  the PTY (per-terminal toggle; **direct input is now the default for first-seen terminals** per
  `mobile/mobile-terminal-direct-input-default.md` in the repo). Buffered command-input mode (text
  field + Enter) remains available. This is genuine interactive shell control — TUIs, REPLs, SSH.
- Replying to agent prompts (`continue`, `yes`, free text), image/file attachments, dictation.
- Quick Commands: saved terminal commands / agent prompts runnable from the session tab strip.
- Source control: review diffs, stage/unstage, **commit from the phone**; create workspaces
  remotely; bulk tab close; browser sessions in Web/Mobile view; push notifications on completion.
- Status/usage watching: every worktree + agent status across hosts, scrollback hydration,
  Chat UI transcripts, account/rate-limit usage screens.

Limits: it's explicitly "not a full editor — a remote control"; pairing is one-time; direct/LAN
sessions drop when the desktop server closes; Relay-backed pairing needs sign-in.

Sources: https://www.onorca.dev/docs/mobile · https://www.onorca.dev/docs/android-apk ·
github.com/stablyai/orca `mobile/README.md` ("Monitor worktrees, view terminal output, **and send
commands** from your phone"), `mobile/mobile-terminal-direct-input-default.md`, README.md Mobile
Companion section ("Monitor and steer your agents from your phone").

### Phone-side test prepared (commander performs)

Server is RUNNING and healthy with a fresh **mobile-scoped** pairing offer:

- Pairing URL (paste into the app's Pair screen):
  see `~/.local/state/orca/pairing-url.txt` (line 1) — an `orca://pair?code=…` link advertising
  `ws://192.168.1.11:6768` (LAN).
- QR code image: `~/.local/state/orca/pairing-qr.png` (encodes the same URL; scan with the phone
  camera or the app).
- If the phone has Tailscale, restart advertise with the Tailscale IP instead for off-LAN use
  (current machine address: 100.116.51.14).

Steps:

1. Install the APK: download `app-release.apk` (v0.0.44,
   https://github.com/stablyai/orca/releases/download/mobile-android-v0.0.44/app-release.apk)
   in Chrome (not inside Discord/GitHub apps), open Downloads, tap the APK, allow
   "install unknown apps" for the browser when prompted. Samsung: may need to toggle Auto Blocker
   off temporarily (Settings → Security and privacy → Auto Blocker).
2. Ensure the phone is on the same LAN as this machine (192.168.1.x).
3. Open Orca mobile → choose **Pair** → scan `pairing-qr.png` or paste the `orca://pair?code=…`
   URL from `~/.local/state/orca/pairing-url.txt`.
4. Verify: worktrees list appears; open any terminal, switch to **Live** input if not default,
    type `echo hello-from-phone` and confirm output appears — proving interactive shell control.
5. Never pair a device yourself — done by commander only (per task constraint).

---

## Final state checklist

- [x] Report written (this file).
- [x] `orca status --json` → reachable=true, state=ready, app running, v1.4.188; fresh
      mobile-scoped pairing offer + QR ready at `~/.local/state/orca/pairing-{url.txt,qr.png}`.
- [x] Scratch artifacts cleaned: `orca-smoke` task endpoint removed (terminal closed, Orca
      worktree removed), Squad scratch state files removed, `/tmp/orca-smoke-repo` deleted.
      No tracked Squad file modified anywhere.
- [x] Orca serve left RUNNING with pairing ready (final state).
