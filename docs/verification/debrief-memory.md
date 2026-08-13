# Startup-memory `/debrief` verification

Audience: maintainer verification.

This record supports the active bounded-memory and whole-file curation guarantees for Squad's internal `/debrief` skill.
[`docs/configuration.md`](../configuration.md) owns the current operator-facing setting and estimate.
The internal skill owns curation and completion-receipt behavior.
Task chronology, fixture paths, and delivery evidence remain outside this record.

## Synthetic real-agent pass

The development-only real-agent pass ran on 2026-07-30 with Pi 0.82.0 on `openai-codex/gpt-5.6-terra` at medium thinking.
It used disposable primary and XO-shaped `SQUAD_BASE` directories under the repository worktree only.
No live Squad memory, project data, credential content, or external system was placed in either fixture or prompt.
The following exact Bash shell body created the sanitized fixtures, invoked the model-qualified skill twice per base, and captured reports, hashes, and file modes:

```bash
set -eu
VERIFY_ROOT=$(mktemp -d "$PWD/.debrief-verification.XXXXXX")
RUNTIME_ROOT="$VERIFY_ROOT/runtime-root"
PRIMARY="$VERIFY_ROOT/primary"
XO="$VERIFY_ROOT/XO"
XO_ID=debrief-verification
mkdir -p "$RUNTIME_ROOT" "$PRIMARY/config" "$PRIMARY/data" \
  "$XO/bin" "$XO/config" "$XO/data"
printf '%s\n' 350 >"$PRIMARY/config/startup-memory-budget"
printf '%s\n' "$XO_ID" >"$XO/.sq-xo-home"
printf '%s\n' '# Synthetic Squad home' >"$XO/AGENTS.md"

file_mode() {
  if [ "$(uname)" = Darwin ]; then
    stat -f %Lp "$1"
  else
    stat -c %a "$1"
  fi
}

record_shared_state() {
  label=$1
  path=$2
  printf '%s sha256=%s mode=%s\n' "$label" \
    "$(shasum -a 256 "$path" | awk '{print $1}')" \
    "$(file_mode "$path")"
}

cat >"$PRIMARY/data/commander.md" <<'EOF'
# Commander

## Current preferences

- Prefer the simplest direct end-to-end operational path.
- Preserve unique current facts when compacting memory.
- Use plain dashes in prose.

## Duplicate and superseded material

- Prefer the simplest direct end-to-end operational path.
- Old policy: build a wrapper before every one-off operation.
- Old policy copy: always build a wrapper for one-off work.
- Stale tool path: `/opt/old-Squad/bin/fm`.
- Stale release version: 0.41.0.
- Completed task: migrated the demo fixture on Monday.
- Completed task detail: checked the demo fixture again on Tuesday.
- Metric from the completed task: 47 records moved.
EOF

cat >"$PRIMARY/data/commander-shared.md" <<'EOF'
# Shared commander preferences

This file is main-authoritative in the main Squad home.
In XO homes it is read-only in XO homes and must not be edited there.
Route new commander-preference discoveries to the main Squad through marked status or a document pointer.

- Never expose secrets or weaken an accepted safety boundary.
- Prefer the simplest direct end-to-end operational path.
- Superseded policy: XOs may rewrite shared memory when convenient.
- Duplicate safety note: do not expose secrets.
EOF

cat >"$PRIMARY/data/learnings.md" <<'EOF'
# Learnings

- Stable fact: startup-memory configuration is documented in `docs/configuration.md`.
- Authoritative pointer: incident detail belongs in `data/reports/synthetic-incident.md`.
- Stable fact copy: consult `docs/configuration.md` for startup-memory configuration.
- Completed chronology: first the synthetic incident was detected, then triaged, then assigned.
- Completed chronology continued: a patch was drafted, reviewed, merged, and announced.
- Old metric: the discarded prototype used 812 estimated tokens.
- Stale path: the discarded prototype lived at `/tmp/old-memory-prototype`.
- Superseded alternative: maintain both a JSON memory database and Markdown files.
- Report-sized procedure: create a staging directory, enumerate every file, copy each file, compare every line, write a status ledger, notify all operators, archive the ledger, and repeat the entire sequence after every prompt.
EOF

SQUAD_BASE="$PRIMARY" bin/sq-startup-memory-budget.sh report \
  >"$VERIFY_ROOT/primary.before.report"
for file in commander.md commander-shared.md learnings.md; do
  shasum -a 256 "$PRIMARY/data/$file"
done >"$VERIFY_ROOT/primary.before.sha256"

SQUAD_BASE="$PRIMARY" pi -p --no-session --no-extensions --no-context-files \
  --model openai-codex/gpt-5.6-terra --thinking medium \
  --skill .agents/skills/debrief/SKILL.md \
  'Invoke /debrief now against only the disposable synthetic Squad home in $SQUAD_BASE. There are no new session facts to file. Follow every requirement in the loaded debrief skill. Run the repository-owned bin/sq-startup-memory-budget.sh report command, with the existing SQUAD_BASE environment, before and after curation; that executable is the only permitted path outside $SQUAD_BASE. Retain the exact before total, preserve the complete main-authoritative routing header in data/commander-shared.md, and make the completion receipt state the effective budget, exact before and after totals, an action for each of the three files, every exception, and reset safety. Inspect all three startup-memory files completely, preserve every unique current preference, authority or safety boundary, stable fact, and authoritative pointer, and consolidate the supplied duplicate, superseded, stale, chronological, metric, and report-sized material. Do not access or modify any other home, credential, project data, or external system.' \
  >"$VERIFY_ROOT/primary.pass1.out"
SQUAD_BASE="$PRIMARY" bin/sq-startup-memory-budget.sh report \
  >"$VERIFY_ROOT/primary.after.report"
for file in commander.md commander-shared.md learnings.md; do
  shasum -a 256 "$PRIMARY/data/$file"
done >"$VERIFY_ROOT/primary.after.sha256"

SQUAD_BASE="$PRIMARY" pi -p --no-session --no-extensions --no-context-files \
  --model openai-codex/gpt-5.6-terra --thinking medium \
  --skill .agents/skills/debrief/SKILL.md \
  'Invoke /debrief now against only the disposable synthetic Squad home in $SQUAD_BASE. There are no new session facts to file. Follow every requirement in the loaded debrief skill. Run the repository-owned bin/sq-startup-memory-budget.sh report command, with the existing SQUAD_BASE environment, before and after curation; that executable is the only permitted path outside $SQUAD_BASE. Retain the exact before total, preserve the complete main-authoritative routing header in data/commander-shared.md, and make the completion receipt state the effective budget, exact before and after totals, an action for each of the three files, every exception, and reset safety. Inspect all three startup-memory files completely, preserve every unique current preference, authority or safety boundary, stable fact, and authoritative pointer, and consolidate the supplied duplicate, superseded, stale, chronological, metric, and report-sized material. Do not access or modify any other home, credential, project data, or external system.' \
  >"$VERIFY_ROOT/primary.pass2.out"
SQUAD_BASE="$PRIMARY" bin/sq-startup-memory-budget.sh report \
  >"$VERIFY_ROOT/primary.repeat.report"
for file in commander.md commander-shared.md learnings.md; do
  shasum -a 256 "$PRIMARY/data/$file"
done >"$VERIFY_ROOT/primary.repeat.sha256"

cat >"$XO/data/commander.md" <<'EOF'
# XO commander memory

- Current preference: report concrete blockers instead of guessing.
- Current preference copy: never guess when a concrete blocker can be reported.
- Shared overlap: never expose secrets.
- Superseded preference: silently infer missing configuration.
- Stale version: the unit uses 0.41.0.
- Completed task: inspected the synthetic queue yesterday.
- Completed task detail: closed the synthetic queue inspection after 19 checks.
EOF

cat >"$XO/data/learnings.md" <<'EOF'
# XO learnings

- Unique current learning: inherited shared memory counts against the local total.
- Authoritative pointer: startup-memory behavior is documented in `docs/configuration.md`.
- Duplicate learning: include inherited shared memory in the local total.
- Stale path: `/tmp/XO-memory-v1`.
- Superseded alternative: copy shared facts into every local file.
- Completed chronology: opened the sample, measured it, discussed it, revised it, remeasured it, and closed it.
- Old metric: the sample once measured 604 estimated tokens.
- Report-sized procedure: take a snapshot, copy it to a ledger, annotate every old measurement, preserve every discarded alternative, append a timestamp, and repeat after each completed task.
EOF

SQUAD_ROOT="$RUNTIME_ROOT"
SQUAD_BASE="$PRIMARY"
. bin/sq-ff-lib.sh
. bin/sq-config-inherit-lib.sh
validate_XO_home "$XO_ID" "$XO"
printf 'XO_validation=accepted id=%s home=%s\n' \
  "$XO_ID" "$VALIDATED_HOME" >"$VERIFY_ROOT/inheritance.out"
SQUAD_CONFIG_INHERIT_REPORT="$VERIFY_ROOT/inheritance.report" \
  propagate_XO_inheritance \
    "$PRIMARY" "$VALIDATED_HOME" "$PRIMARY/config" "$PRIMARY/data"
cat "$VERIFY_ROOT/inheritance.report" >>"$VERIFY_ROOT/inheritance.out"
cmp -s "$PRIMARY/data/commander-shared.md" \
  "$XO/data/commander-shared.md"
record_shared_state inherited "$XO/data/commander-shared.md" \
  >>"$VERIFY_ROOT/inheritance.out"

SQUAD_BASE="$XO" bin/sq-startup-memory-budget.sh report \
  >"$VERIFY_ROOT/XO.before.report"
for file in commander.md commander-shared.md learnings.md; do
  shasum -a 256 "$XO/data/$file"
done >"$VERIFY_ROOT/XO.before.sha256"
record_shared_state before "$XO/data/commander-shared.md" \
  >"$VERIFY_ROOT/XO.shared-state"

SQUAD_BASE="$XO" pi -p --no-session --no-extensions --no-context-files \
  --model openai-codex/gpt-5.6-terra --thinking medium \
  --skill .agents/skills/debrief/SKILL.md \
  'Invoke /debrief now against only the validated disposable synthetic XO home in $SQUAD_BASE. There are no new session facts to file. Follow every requirement in the loaded debrief skill. Run the repository-owned bin/sq-startup-memory-budget.sh report command, with the existing SQUAD_BASE environment, before and after curation; that executable is the only permitted path outside $SQUAD_BASE. Retain the exact before total, and make the completion receipt state the effective budget, exact before and after totals, an action for each of the three files, every exception, and reset safety. Inspect all three startup-memory files completely, keep data/commander-shared.md byte-identical and filesystem read-only because it was installed through primary-authoritative inheritance, preserve every unique current preference, stable learning, and authoritative pointer, and consolidate the supplied duplicate, superseded, stale, chronological, metric, overlap, and report-sized material in editable local memory. Do not access or modify any other home, credential, project data, or external system.' \
  >"$VERIFY_ROOT/XO.pass1.out"
SQUAD_BASE="$XO" bin/sq-startup-memory-budget.sh report \
  >"$VERIFY_ROOT/XO.after.report"
for file in commander.md commander-shared.md learnings.md; do
  shasum -a 256 "$XO/data/$file"
done >"$VERIFY_ROOT/XO.after.sha256"
record_shared_state after "$XO/data/commander-shared.md" \
  >>"$VERIFY_ROOT/XO.shared-state"

SQUAD_BASE="$XO" pi -p --no-session --no-extensions --no-context-files \
  --model openai-codex/gpt-5.6-terra --thinking medium \
  --skill .agents/skills/debrief/SKILL.md \
  'Invoke /debrief now against only the validated disposable synthetic XO home in $SQUAD_BASE. There are no new session facts to file. Follow every requirement in the loaded debrief skill. Run the repository-owned bin/sq-startup-memory-budget.sh report command, with the existing SQUAD_BASE environment, before and after curation; that executable is the only permitted path outside $SQUAD_BASE. Retain the exact before total, and make the completion receipt state the effective budget, exact before and after totals, an action for each of the three files, every exception, and reset safety. Inspect all three startup-memory files completely, keep data/commander-shared.md byte-identical and filesystem read-only because it was installed through primary-authoritative inheritance, preserve every unique current preference, stable learning, and authoritative pointer, and consolidate the supplied duplicate, superseded, stale, chronological, metric, overlap, and report-sized material in editable local memory. Do not access or modify any other home, credential, project data, or external system.' \
  >"$VERIFY_ROOT/XO.pass2.out"
SQUAD_BASE="$XO" bin/sq-startup-memory-budget.sh report \
  >"$VERIFY_ROOT/XO.repeat.report"
for file in commander.md commander-shared.md learnings.md; do
  shasum -a 256 "$XO/data/$file"
done >"$VERIFY_ROOT/XO.repeat.sha256"
record_shared_state repeat "$XO/data/commander-shared.md" \
  >>"$VERIFY_ROOT/XO.shared-state"
```

Bounded observed output:

```text
XO_validation=accepted id=debrief-verification
startup-memory-budget pushed
data/commander-shared.md pushed
inherited sha256=d08ce8e35b17c8342773d551b5c1551a5a6ded5f45ab0f7ed5b6ef91ea1d408c mode=444
primary: 699 -> 219 estimated tokens against a 350-token budget
primary repeat: 219 -> 219; all three files byte-identical
XO: 518 -> 192 estimated tokens against a 350-token budget
XO repeat: 192 -> 192; all three files byte-identical
before sha256=d08ce8e35b17c8342773d551b5c1551a5a6ded5f45ab0f7ed5b6ef91ea1d408c mode=444
after sha256=d08ce8e35b17c8342773d551b5c1551a5a6ded5f45ab0f7ed5b6ef91ea1d408c mode=444
repeat sha256=d08ce8e35b17c8342773d551b5c1551a5a6ded5f45ab0f7ed5b6ef91ea1d408c mode=444
```

The first pass preserved current preferences, shared-memory and safety authority, a stable operating fact, and authoritative configuration and incident-report pointers while removing duplicate, superseded, stale, and chronological material.
The XO fixture passed the production base validator before the existing inheritance owner installed the main-authoritative file read-only.
Both XO passes preserved its unique local preference and learning while leaving those inherited bytes and mode untouched.
This verifies the real instruction path consolidates to budget, reports truthful deltas, preserves the primary-owned shared boundary, and does not grow on an identical second pass.
