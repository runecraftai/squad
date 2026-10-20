import { describe, expect, it } from "vitest";
import {
  paddedReason,
  readDescriptor,
  removeBase,
  runClientProcess,
  startServiceProcess,
  temporaryBase,
  type ClientRecord,
} from "./fixtures";

function kinds(records: readonly ClientRecord[]): string[] {
  return records.map((entry) => String(entry.kind));
}

function reasons(records: readonly ClientRecord[]): string[] {
  return records
    .map((entry) => entry.reason)
    .filter((reason): reason is string => typeof reason === "string");
}

describe("local service replication", () => {
  it("delivers one atomic snapshot and then only the changes", async () => {
    const base = await temporaryBase();
    const revisions = 10;
    const service = await startServiceProcess({
      base,
      source: "scripted",
      revisions,
      intervalMs: 80,
      startDelayMs: 300,
    });
    try {
      const client = await runClientProcess(base, {
        mode: "attach",
        durationMs: 2_000,
      });
      expect(client.code).toBe(0);
      const seen = kinds(client.records);
      expect(seen[0]).toBe("attached");
      const events = seen.filter((kind) => kind.startsWith("event-"));
      expect(events[0]).toBe("event-snap");
      expect(events).toContain("event-ops");
      const finalReason = paddedReason(revisions, 40);
      expect(reasons(client.records).at(-1)).toBe(finalReason);
      expect(client.stderr).toBe("");
    } finally {
      await service.stop();
      await removeBase(base);
    }
  }, 90_000);

  it("converges for clients that attach during concurrent mutation", async () => {
    const base = await temporaryBase();
    const revisions = 24;
    const service = await startServiceProcess({
      base,
      source: "scripted",
      revisions,
      intervalMs: 60,
      startDelayMs: 250,
    });
    try {
      const [early, late] = await Promise.all([
        runClientProcess(base, { mode: "attach", durationMs: 2_600 }),
        runClientProcess(base, { mode: "attach", durationMs: 2_000 }),
      ]);
      expect(early.code).toBe(0);
      expect(late.code).toBe(0);
      const finalReason = paddedReason(revisions, 40);
      expect(reasons(early.records).at(-1)).toBe(finalReason);
      expect(reasons(late.records).at(-1)).toBe(finalReason);
      for (const run of [early, late]) {
        const events = kinds(run.records).filter((kind) =>
          kind.startsWith("event-"),
        );
        expect(events[0]).toBe("event-snap");
      }
    } finally {
      await service.stop();
      await removeBase(base);
    }
  }, 90_000);

  it("gives a reattaching client a fresh snapshot instead of retained replay", async () => {
    const base = await temporaryBase();
    const revisions = 6;
    const service = await startServiceProcess({
      base,
      source: "scripted",
      revisions,
      intervalMs: 50,
      startDelayMs: 200,
    });
    try {
      const first = await runClientProcess(base, {
        mode: "attach",
        durationMs: 1_200,
      });
      expect(first.code).toBe(0);
      const second = await runClientProcess(base, {
        mode: "attach",
        durationMs: 600,
      });
      expect(second.code).toBe(0);
      const snapshot = second.records.find(
        (entry) => entry.kind === "event-snap",
      );
      expect(snapshot?.reason).toBe(paddedReason(revisions, 40));
      // A fresh attach is one snapshot of current state, not a replay log.
      expect(
        kinds(second.records).filter((kind) => kind === "event-snap"),
      ).toHaveLength(1);
      expect(kinds(second.records)).not.toContain("event-ops");
    } finally {
      await service.stop();
      await removeBase(base);
    }
  }, 90_000);

  it("keeps a slow subscriber bounded without stopping the service or other clients", async () => {
    const base = await temporaryBase();
    const revisions = 6_000;
    const reasonBytes = 200;
    const service = await startServiceProcess({
      base,
      source: "burst",
      revisions,
      reasonBytes,
      startDelayMs: 700,
    });
    try {
      const descriptorBefore = await readDescriptor(base);
      const [slow, fast] = await Promise.all([
        runClientProcess(base, {
          mode: "slow",
          blockMs: 1_800,
          durationMs: 4_500,
        }),
        runClientProcess(base, { mode: "attach", durationMs: 3_500 }),
      ]);
      const finalReason = paddedReason(revisions, reasonBytes);
      expect(fast.code).toBe(0);
      expect(reasons(fast.records).at(-1)).toBe(finalReason);

      expect(slow.code).toBe(0);
      expect(kinds(slow.records)).toContain("unblocked");
      expect(reasons(slow.records).at(-1)).toBe(finalReason);

      // The slow client was reset or caught up by a later snapshot; either way
      // it never received a partial value claiming to be complete.
      const slowEvents = kinds(slow.records).filter((kind) =>
        kind.startsWith("event-"),
      );
      expect(slowEvents[0]).toBe("event-snap");
      expect(slowEvents.length).toBeGreaterThan(1);
      // The stalled consumer is replaced by a current-value reset, never an
      // unbounded queue of missed deltas.
      expect(slowEvents).toContain("event-reset");

      // The service is still ready and unchanged.
      expect(await readDescriptor(base)).toEqual(descriptorBefore);
      const after = await runClientProcess(base, {
        mode: "attach",
        durationMs: 500,
      });
      expect(after.code).toBe(0);
      expect(slow.stderr).toBe("");
      expect(fast.stderr).toBe("");
    } finally {
      await service.stop();
      await removeBase(base);
    }
  }, 150_000);
});
