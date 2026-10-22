#!/usr/bin/env bash
# lab-proof.sh - executable Q4 proof of slice A1 (plan section 14, "Prova obrigatória Q4").
#
# A human approval survives a hard kill of the laboratory service:
#   1 admit a mission with a fixed key; record mission, approval and gate IDs and the commit sequence
#   2 the pending approval is visible from the terminal with the same revision
#   3 SIGKILL only the lab service process; confirm death by signal and no graceful shutdown
#   4 restart on the same store; the readiness probe reaches "ready", not merely a new PID
#   5 the same single approval is pending: same ID, action, revision and content
#   6 answer from the terminal; the persisted receipt is read back by another process
#   7 the mission continues: one continuation receipt, one applied effect, one effect receipt
#   8 SIGKILL and restart again, resend the answer: same receipt, no new effect, no second
#     question, counters stable over three poll intervals
#
# Usage: bash packages/sq-durable/scripts/lab-proof.sh
# Env:   SQ_DURABLE_EVIDENCE_DIR  directory for the persisted evidence (default: a new mktemp dir)
#        SQ_DURABLE_POLL_MS       gate poll interval in ms (default 300)
# Exit:  0 proof passed; 1 proof failed (evidence.json says which step and why).
# Uses only the laboratory store it creates; never touches Squad state, projects or the network.
set -euo pipefail

PKG_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
CLI_JS="$PKG_DIR/dist/cli.js"
POLL_MS=${SQ_DURABLE_POLL_MS:-300}
MISSION=dm1-q4-proof
ACTION=lab-deploy
REVISION=r1-q4proof
ACTION_ARGS='{"target":"lab-ledger","note":"controlled effect, no network"}'

if [ ! -f "$CLI_JS" ]; then
	[ -d "$PKG_DIR/node_modules" ] || { echo "lab-proof: run 'npm ci' in $PKG_DIR first" >&2; exit 1; }
	(cd "$PKG_DIR" && npm run build >/dev/null)
fi

EVIDENCE=${SQ_DURABLE_EVIDENCE_DIR:-$(mktemp -d "${TMPDIR:-/tmp}/sq-durable-proof.XXXXXX")}
mkdir -p "$EVIDENCE"
EVIDENCE=$(cd "$EVIDENCE" && pwd)
STORE="$EVIDENCE/store"
STEPS="$EVIDENCE/steps.log"
FACTS="$EVIDENCE/facts.jsonl"
: >"$STEPS"
: >"$FACTS"

NODE=(node --disable-warning=ExperimentalWarning)
SERVICE_PID=""
SERVICE_RUN=0
CURRENT_STEP=0

cli() { "${NODE[@]}" "$CLI_JS" "$@"; }

# get FILE PATH - print one value of a JSON file; PATH is dot-separated (array indexes are numbers).
get() {
	"${NODE[@]}" -e '
const value = process.argv[2].split(".").filter(Boolean).reduce((v, k) => (v == null ? undefined : v[k]), JSON.parse(require("fs").readFileSync(process.argv[1], "utf8")));
process.stdout.write(value === undefined ? "undefined" : typeof value === "string" ? value : JSON.stringify(value));
' "$1" "$2"
}

# fact KEY JSON - append one fact to the evidence.
fact() {
	# shellcheck disable=SC2016 # JavaScript template literal, not shell expansion.
	"${NODE[@]}" -e 'const [step, key, value] = process.argv.slice(1); process.stdout.write(`${JSON.stringify({ step: Number(step), key, value: JSON.parse(value) })}\n`);' \
		"$CURRENT_STEP" "$1" "$2" >>"$FACTS"
}

log() { printf '%s step %s: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%S.%3NZ)" "$CURRENT_STEP" "$*" | tee -a "$STEPS" >&2; }

finish() {
	local result=$1 reason=$2
	"${NODE[@]}" - "$EVIDENCE" "$result" "$reason" "$CURRENT_STEP" "$PKG_DIR" "$POLL_MS" "$MISSION" "$ACTION" "$REVISION" <<'EOF'
const fs = require("fs");
const path = require("path");
const crypto = require("crypto");
const { execFileSync } = require("child_process");
const [evidence, result, reason, step, pkg, pollMs, mission, action, revision] = process.argv.slice(2);
const hash = crypto.createHash("sha256");
const files = [];
const walk = (dir) => {
	for (const name of fs.readdirSync(dir).sort()) {
		const full = path.join(dir, name);
		if (fs.statSync(full).isDirectory()) walk(full);
		else files.push(full);
	}
};
walk(path.join(pkg, "src"));
files.push(path.join(pkg, "package-lock.json"), path.join(pkg, "scripts", "lab-proof.sh"));
for (const file of files) hash.update(path.relative(pkg, file)).update("\0").update(fs.readFileSync(file));
let revisionOfCode = "unknown";
try { revisionOfCode = execFileSync("git", ["-C", pkg, "rev-parse", "HEAD"], { encoding: "utf8" }).trim(); } catch {}
let dirty = null;
try { dirty = execFileSync("git", ["-C", pkg, "status", "--porcelain", "--", "."], { encoding: "utf8" }).trim() !== ""; } catch {}
const facts = fs.readFileSync(path.join(evidence, "facts.jsonl"), "utf8").split("\n").filter(Boolean).map((line) => JSON.parse(line));
const out = {
	proof: "sq-durable A1 Q4: approval survives a hard kill",
	result,
	reason: reason || null,
	failedStep: result === "pass" ? null : Number(step),
	finishedAt: new Date().toISOString(),
	code: { gitRevision: revisionOfCode, packageDirty: dirty, sourceSha256: hash.digest("hex"), files: files.length },
	config: { pollMs: Number(pollMs), mission, action, revision, node: process.version, faultInjection: "external SIGKILL (kill -KILL <pid>)" },
	pi: JSON.parse(fs.readFileSync(path.join(pkg, "node_modules", "@earendil-works", "pi-durable", "package.json"), "utf8")).version,
	facts,
};
fs.writeFileSync(path.join(evidence, "evidence.json"), `${JSON.stringify(out, null, 2)}\n`);
EOF
	echo "lab-proof: $result${reason:+ ($reason)}; evidence in $EVIDENCE/evidence.json" >&2
}

fail() {
	log "FAIL: $*"
	finish fail "$*"
	stop_service_hard
	exit 1
}

stop_service_hard() {
	if [ -n "$SERVICE_PID" ] && kill -0 "$SERVICE_PID" 2>/dev/null; then
		kill -KILL "$SERVICE_PID" 2>/dev/null || true
		wait "$SERVICE_PID" 2>/dev/null || true
	fi
	SERVICE_PID=""
}

on_exit() {
	local rc=$?
	if [ "$rc" -ne 0 ] && [ ! -f "$EVIDENCE/evidence.json" ]; then finish fail "unexpected exit $rc at step $CURRENT_STEP"; fi
	stop_service_hard
}
trap on_exit EXIT

start_service() {
	SERVICE_RUN=$((SERVICE_RUN + 1))
	# The node process itself is the background job, so $! is the lab service PID and nothing else.
	"${NODE[@]}" "$CLI_JS" serve --store "$STORE" --poll-ms "$POLL_MS" 2>>"$EVIDENCE/service-$SERVICE_RUN.log" &
	SERVICE_PID=$!
	log "service run $SERVICE_RUN started as pid $SERVICE_PID"
}

await_ready() {
	local out="$EVIDENCE/ready-$SERVICE_RUN.json"
	# Deadline: readiness plus two poll intervals plus 5 s, never an endless wait.
	local wait_s=$(( (2 * POLL_MS) / 1000 + 10 ))
	if ! cli ready --store "$STORE" --wait "$wait_s" --json >"$out"; then
		fail "readiness probe did not reach ready for run $SERVICE_RUN: $(get "$out" state) $(get "$out" reasons)"
	fi
	[ "$(get "$out" pid)" = "$SERVICE_PID" ] || fail "ready answered from pid $(get "$out" pid), expected $SERVICE_PID"
	[ "$(get "$out" resumedAt)" != "null" ] || fail "ready without resume()"
	log "ready: pid $SERVICE_PID incarnation $(get "$out" incarnation) lastSeq $(get "$out" lastSeq)"
	fact "ready_run_$SERVICE_RUN" "$(cat "$out")"
}

# Kill only the lab service with SIGKILL and prove the death was by signal, without graceful shutdown.
hard_kill() {
	local pid=$SERVICE_PID status=0
	kill -KILL "$pid"
	wait "$pid" || status=$?
	[ "$status" -eq 137 ] || fail "service pid $pid exit status $status, expected 137 (killed by SIGKILL)"
	if kill -0 "$pid" 2>/dev/null; then fail "service pid $pid still alive after SIGKILL"; fi
	if grep -q '"event":"shutdown"' "$EVIDENCE/service-$SERVICE_RUN.log"; then
		fail "service run $SERVICE_RUN logged a graceful shutdown; the kill was not hard"
	fi
	fact "kill_run_$SERVICE_RUN" "{\"pid\":$pid,\"signal\":\"SIGKILL\",\"waitStatus\":$status,\"gracefulShutdownLogged\":false}"
	log "pid $pid killed by SIGKILL (wait status $status), no graceful shutdown logged"
	SERVICE_PID=""
}

stats_snapshot() {
	cli stats --store "$STORE" --json >"$1" || fail "stats query failed"
	"${NODE[@]}" -e '
const s = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
process.stdout.write(JSON.stringify({ seq: s.seq, missions: s.missions, pending: s.pending, decisions: s.decisions, rejectedAttempts: s.rejectedAttempts, continuations: s.continuations, effectAttempts: s.effectAttempts, effectReceipts: s.effectReceipts, liveGates: s.liveGates, executor: s.executor }));
' "$1"
}

log "evidence directory $EVIDENCE"
cli init --store "$STORE" --lab --json >"$EVIDENCE/init.json"
fact init "$(cat "$EVIDENCE/init.json")"
start_service
await_ready

# 1. Admission with a fixed key.
CURRENT_STEP=1
cli admit --store "$STORE" --mission "$MISSION" --action "$ACTION" --revision "$REVISION" --args "$ACTION_ARGS" --json >"$EVIDENCE/admit.json" ||
	fail "admission failed: $(cat "$EVIDENCE/admit.json")"
[ "$(get "$EVIDENCE/admit.json" outcome)" = created ] || fail "first admission was not created"
APPROVAL_ID=$(get "$EVIDENCE/admit.json" approvalId)
GATE_ID=$(get "$EVIDENCE/admit.json" gateTaskId)
ADMITTED_SEQ=$(get "$EVIDENCE/admit.json" admittedSeq)
fact admission "$(cat "$EVIDENCE/admit.json")"
log "admitted $MISSION: approval $APPROVAL_ID gate $GATE_ID seq $ADMITTED_SEQ"

# 2. The pending approval is visible with the same revision.
CURRENT_STEP=2
cli approvals pending --store "$STORE" --json >"$EVIDENCE/pending-before-kill.json"
[ "$(get "$EVIDENCE/pending-before-kill.json" pending.length)" = 1 ] || fail "expected exactly one pending approval before the kill"
[ "$(get "$EVIDENCE/pending-before-kill.json" pending.0.approvalId)" = "$APPROVAL_ID" ] || fail "pending approval ID differs from admission"
[ "$(get "$EVIDENCE/pending-before-kill.json" pending.0.revision)" = "$REVISION" ] || fail "pending approval revision differs from admission"
PENDING_BEFORE=$(get "$EVIDENCE/pending-before-kill.json" pending.0)
fact pending_before_kill "$PENDING_BEFORE"
log "one pending approval visible with revision $REVISION"

# 3. Hard kill of the lab process only.
CURRENT_STEP=3
FIRST_PID=$SERVICE_PID
hard_kill

# 4. Restart on the same store; the probe must reach ready.
CURRENT_STEP=4
start_service
[ "$SERVICE_PID" != "$FIRST_PID" ] || fail "restart reused pid $FIRST_PID"
await_ready
[ "$(get "$EVIDENCE/ready-2.json" storeId)" = "$(get "$EVIDENCE/init.json" storeId)" ] || fail "restart opened a different store"

# 5. The same single approval is still pending.
CURRENT_STEP=5
cli approvals pending --store "$STORE" --json >"$EVIDENCE/pending-after-restart.json"
[ "$(get "$EVIDENCE/pending-after-restart.json" pending.length)" = 1 ] || fail "expected exactly one pending approval after restart"
PENDING_AFTER=$(get "$EVIDENCE/pending-after-restart.json" pending.0)
[ "$PENDING_AFTER" = "$PENDING_BEFORE" ] || fail "pending approval changed across the kill: before $PENDING_BEFORE after $PENDING_AFTER"
fact pending_after_restart "$PENDING_AFTER"
log "same approval pending after restart: id, action, revision and content identical"

# 6. Answer from the terminal; read the persisted receipt back from another process.
CURRENT_STEP=6
cli answer --store "$STORE" --approval "$APPROVAL_ID" --revision "$REVISION" --decision approve --response-id resp-q4-1 --json >"$EVIDENCE/answer.json" ||
	fail "answer failed: $(cat "$EVIDENCE/answer.json")"
[ "$(get "$EVIDENCE/answer.json" outcome)" = recorded ] || fail "answer was not recorded"
DECISION_RECEIPT=$(get "$EVIDENCE/answer.json" receipt.receiptId)
cli receipt --store "$STORE" --approval "$APPROVAL_ID" --json >"$EVIDENCE/receipt-after-answer.json"
[ "$(get "$EVIDENCE/receipt-after-answer.json" decision.receiptId)" = "$DECISION_RECEIPT" ] || fail "another process read a different decision receipt"
fact decision_receipt "$(get "$EVIDENCE/answer.json" receipt)"
log "decision recorded: receipt $DECISION_RECEIPT (read back by a separate process)"

# 7. The mission continues: one continuation receipt, one applied effect, one effect receipt.
CURRENT_STEP=7
deadline=$(( $(date +%s) + (2 * POLL_MS) / 1000 + 5 ))
while :; do
	cli receipt --store "$STORE" --approval "$APPROVAL_ID" --json >"$EVIDENCE/receipt-after-effect.json"
	[ "$(get "$EVIDENCE/receipt-after-effect.json" effect.state)" = applied ] && break
	[ "$(date +%s)" -lt "$deadline" ] || fail "mission did not continue within the deadline: $(get "$EVIDENCE/receipt-after-effect.json" missionStatus)"
	sleep 0.1
done
R="$EVIDENCE/receipt-after-effect.json"
CONTINUATION=$(get "$R" continuation.receiptId)
EFFECT_KEY=$(get "$R" continuation.effectKey)
EFFECT_RECEIPT=$(get "$R" effect.receipt.receiptId)
[ "$CONTINUATION" != "undefined" ] && [ "$CONTINUATION" != "null" ] || fail "no continuation receipt"
[ "$(get "$R" continuation.decisionReceiptId)" = "$DECISION_RECEIPT" ] || fail "continuation does not reference the decision receipt"
[ "$(get "$R" effect.effectKey)" = "$EFFECT_KEY" ] || fail "effect key differs from the continuation receipt"
[ "$(get "$R" effect.receipt.effectKey)" = "$EFFECT_KEY" ] || fail "effect receipt names another key"
[ "$(get "$R" effect.receipt.continuationReceiptId)" = "$CONTINUATION" ] || fail "effect receipt does not reference the continuation"
[ "$(get "$R" effect.receipt.decisionReceiptId)" = "$DECISION_RECEIPT" ] || fail "effect receipt does not reference the decision"
[ "$(get "$R" missionStatus)" = completed ] || fail "mission is $(get "$R" missionStatus), expected completed"
cli ledger --store "$STORE" --json >"$EVIDENCE/ledger-after-effect.json"
L="$EVIDENCE/ledger-after-effect.json"
for counter in appliedEffects distinctKeys receipts applyCalls invocations; do
	[ "$(get "$L" "counters.$counter")" = 1 ] || fail "executor counter $counter is $(get "$L" "counters.$counter"), expected 1"
done
[ "$(get "$L" "effects.$EFFECT_KEY.receipt.receiptId")" = "$EFFECT_RECEIPT" ] || fail "executor ledger does not hold the recorded effect receipt"
STATS_AFTER_EFFECT=$(stats_snapshot "$EVIDENCE/stats-after-effect.json")
[ "$(get "$EVIDENCE/stats-after-effect.json" continuations)" = 1 ] || fail "expected one continuation receipt"
[ "$(get "$EVIDENCE/stats-after-effect.json" effectReceipts)" = 1 ] || fail "expected one effect receipt"
[ "$(get "$EVIDENCE/stats-after-effect.json" pending)" = 0 ] || fail "a question is still pending after the decision"
fact continuation "$(get "$R" continuation)"
fact effect "$(get "$R" effect)"
fact ledger_after_effect "$(get "$L" counters)"
fact stats_after_effect "$STATS_AFTER_EFFECT"
log "continued: continuation $CONTINUATION, effect key $EFFECT_KEY applied once, effect receipt $EFFECT_RECEIPT"

# 8. Restart again and resend the answer: same receipt, no new effect, no second question, stable counters.
CURRENT_STEP=8
hard_kill
start_service
await_ready
cli answer --store "$STORE" --approval "$APPROVAL_ID" --revision "$REVISION" --decision approve --response-id resp-q4-1 --json >"$EVIDENCE/resend-same-response.json" ||
	fail "resend with the same responseId failed"
cli answer --store "$STORE" --approval "$APPROVAL_ID" --revision "$REVISION" --decision approve --response-id resp-q4-2 --json >"$EVIDENCE/resend-new-response.json" ||
	fail "resend with a new responseId failed"
for resend in resend-same-response resend-new-response; do
	[ "$(get "$EVIDENCE/$resend.json" outcome)" = duplicate ] || fail "$resend was not recognized as a duplicate"
	[ "$(get "$EVIDENCE/$resend.json" receipt.receiptId)" = "$DECISION_RECEIPT" ] || fail "$resend returned another receipt"
done
cli approvals pending --store "$STORE" --json >"$EVIDENCE/pending-after-resend.json"
[ "$(get "$EVIDENCE/pending-after-resend.json" pending.length)" = 0 ] || fail "a second question appeared after the resend"
SAMPLES=()
for i in 1 2 3; do
	sleep "$(awk "BEGIN { print $POLL_MS / 1000 }")"
	SAMPLES+=("$(stats_snapshot "$EVIDENCE/stats-interval-$i.json")")
done
for i in 0 1 2; do
	[ "${SAMPLES[$i]}" = "$STATS_AFTER_EFFECT" ] || fail "counters moved in interval $((i + 1)): ${SAMPLES[$i]} vs $STATS_AFTER_EFFECT"
done
cli receipt --store "$STORE" --approval "$APPROVAL_ID" --json >"$EVIDENCE/receipt-final.json"
[ "$(get "$EVIDENCE/receipt-final.json" effect.receipt.receiptId)" = "$EFFECT_RECEIPT" ] || fail "effect receipt changed after restart"
[ "$(get "$EVIDENCE/receipt-final.json" continuation.receiptId)" = "$CONTINUATION" ] || fail "continuation receipt changed after restart"
cli ledger --store "$STORE" --json >"$EVIDENCE/ledger-final.json"
[ "$(get "$EVIDENCE/ledger-final.json" counters)" = "$(get "$L" counters)" ] || fail "executor ledger moved after the resend"
fact resend "{\"sameResponse\":$(get "$EVIDENCE/resend-same-response.json" receipt),\"newResponse\":$(get "$EVIDENCE/resend-new-response.json" receipt)}"
fact counters_three_intervals "[${SAMPLES[0]},${SAMPLES[1]},${SAMPLES[2]}]"
log "resend after restart returned receipt $DECISION_RECEIPT; no new effect, no second question; counters stable for 3 intervals"

kill -TERM "$SERVICE_PID"
wait "$SERVICE_PID" || true
SERVICE_PID=""
CURRENT_STEP=9
finish pass ""
