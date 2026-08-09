// pi-goal-list-loop-audit — v0.25.0
// tests/quota-retry.test.ts
//
// Eager-continuation contract item 12 (Section C): quota-aware retry.
// Tests 1-2 cover parseQuotaError exactly as the contract specifies.
// Tests 3-4 as drafted asserted orchestrator branch behavior (goal status
// after a 429 audit) which lives inline in complete_goal — not reachable
// without a pi harness. The deterministic core is tested instead: the
// schedule/fire/cancel mechanics and the error-pattern recognition the
// branch keys on. The branch itself is pinned by source-text assertions
// in tests/eager-continuation-core.test.ts.

import { test } from "node:test";
import * as assert from "node:assert/strict";

import {
  isQuotaError,
  parseQuotaError,
  scheduleQuotaRetry,
  cancelQuotaRetry,
  isQuotaRetryPending,
} from "../extensions/quota-retry.ts";

const fakeCtx = { ui: { notify: () => {} } } as any;

test("parseQuotaError: 429 with Retry-After: 5 → retryAfterSec 5 (item 12 test 1)", () => {
  const q = parseQuotaError("Error: 429 Too Many Requests\nRetry-After: 5");
  assert.equal(q.retryAfterSec, 5);
  assert.equal(q.fromUpstream, true);
});

test("parseQuotaError: 429 without hint → default 3600 (item 12 test 2)", () => {
  const q = parseQuotaError("Error: 429 quota exceeded");
  assert.equal(q.retryAfterSec, 3600);
  assert.equal(q.fromUpstream, false);
});

test("parseQuotaError: prose hints (retry in 2m / retry after 30 seconds)", () => {
  assert.equal(parseQuotaError("temporarily rate-limited upstream, retry in 2m").retryAfterSec, 120);
  assert.equal(parseQuotaError("retry after 30 seconds").retryAfterSec, 30);
  assert.equal(parseQuotaError("Retry in 1h please").retryAfterSec, 3600);
});

test("isQuotaError: wild-caught shapes", () => {
  assert.equal(isQuotaError('403: {"message":"Key limit exceeded (total limit)"}'), true);
  assert.equal(isQuotaError("429 Too Many Requests"), true);
  assert.equal(isQuotaError("temporarily rate-limited upstream"), true);
  assert.equal(isQuotaError("insufficient credits"), true);
  assert.equal(isQuotaError("model not found"), false);
  assert.equal(isQuotaError(undefined), false);
});

test("scheduleQuotaRetry: fires the callback after the window (item 12 test 3 core)", async () => {
  let fired = 0;
  scheduleQuotaRetry(fakeCtx, 1, "429 test", () => { fired++; });
  assert.equal(isQuotaRetryPending(), true);
  await new Promise((r) => setTimeout(r, 1300));
  assert.equal(fired, 1);
  assert.equal(isQuotaRetryPending(), false);
});

test("cancelQuotaRetry: a pending retry does not fire (item 12 test 4 core)", async () => {
  let fired = 0;
  scheduleQuotaRetry(fakeCtx, 1, "429 test", () => { fired++; });
  cancelQuotaRetry();
  assert.equal(isQuotaRetryPending(), false);
  await new Promise((r) => setTimeout(r, 1300));
  assert.equal(fired, 0);
});
