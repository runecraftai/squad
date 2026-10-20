import { describe, expect, it } from "vitest";
import {
  descriptorText,
  httpStatus,
  listBase,
  probeRawUpgrade,
  removeBase,
  runClientProcess,
  startServiceProcess,
  temporaryBase,
  type ClientRun,
  type RunningServiceHandle,
} from "./fixtures";

const BASE_ID = (service: RunningServiceHandle): string => service.baseId;
const TOKEN = (service: RunningServiceHandle): string => service.token;

function record(
  run: ClientRun,
  kind: string,
): Record<string, unknown> | undefined {
  return run.records.find((entry) => entry.kind === kind);
}

async function withService(
  body: (service: RunningServiceHandle, base: string) => Promise<void>,
): Promise<void> {
  const base = await temporaryBase();
  const service = await startServiceProcess({ base });
  try {
    await body(service, base);
  } finally {
    await service.stop();
    await removeBase(base);
  }
}

describe("local service request surface", () => {
  it("serves only the upgrade route over plain HTTP", async () => {
    await withService(async (service) => {
      expect(await httpStatus(service.port, "/")).toBe(404);
      expect(await httpStatus(service.port, "/v1/link")).toBe(426);
      expect(await httpStatus(service.port, "/v1/link", "POST")).toBe(405);
      expect(await httpStatus(service.port, "/v1/nope")).toBe(404);
    });
  });

  it("refuses every unauthenticated or mismatched upgrade before any link", async () => {
    await withService(async (service) => {
      const good = [
        `Authorization: Bearer ${TOKEN(service)}`,
        `X-Squad-Base-Id: ${BASE_ID(service)}`,
      ];
      const open = await probeRawUpgrade(service.port, { headers: good });
      expect(open.status).toBe(101);

      const cases: Array<{
        headers: string[];
        status: number;
        path?: string;
        host?: string;
      }> = [
        { headers: [`X-Squad-Base-Id: ${BASE_ID(service)}`], status: 401 },
        {
          headers: [
            `Authorization: Bearer ${"0".repeat(64)}`,
            `X-Squad-Base-Id: ${BASE_ID(service)}`,
          ],
          status: 401,
        },
        {
          headers: [
            `Authorization: Bearer ${TOKEN(service)}`,
            `X-Squad-Base-Id: ${"a".repeat(64)}`,
          ],
          status: 401,
        },
        {
          headers: [...good, "Origin: http://browser.example"],
          status: 403,
        },
        { headers: good, status: 400, host: "rebinding.example" },
        { headers: good, status: 404, path: "/v1/link?token=leaked" },
        {
          headers: [...good, `X-Pad: ${"a".repeat(9000)}`],
          status: 431,
        },
      ];

      for (const entry of cases) {
        const probe = await probeRawUpgrade(service.port, {
          headers: entry.headers,
          path: entry.path,
          host: entry.host,
        });
        expect(probe.status).toBe(entry.status);
        expect(probe.text).not.toContain(service.baseId);
        expect(probe.text).not.toContain(service.serviceInstanceId);
        expect(probe.text).not.toContain(service.token);
      }
    });
  }, 60_000);

  it("refuses unspecified methods on the upgrade route", async () => {
    await withService(async (service) => {
      const probe = await probeRawUpgrade(service.port, {
        method: "POST",
        headers: [
          `Authorization: Bearer ${TOKEN(service)}`,
          `X-Squad-Base-Id: ${BASE_ID(service)}`,
        ],
      });
      expect(probe.status).toBe(405);
    });
  });

  it("refuses unsupported versions and wrong bases through the typed facet", async () => {
    await withService(async (service) => {
      const version = await runClientProcess(service.base, {
        mode: "call",
        capabilities: { schemaVersion: 2, baseId: service.baseId },
      });
      expect(version.code).toBe(0);
      expect(record(version, "capabilities")?.result).toEqual({
        ok: false,
        refusal: { code: "unsupported-version" },
      });

      const base = await runClientProcess(service.base, {
        mode: "call",
        capabilities: { schemaVersion: 1, baseId: "b".repeat(64) },
      });
      expect(record(base, "capabilities")?.result).toEqual({
        ok: false,
        refusal: { code: "base-mismatch" },
      });
    });
  }, 60_000);

  it("refuses every reserved operation with no accepted command", async () => {
    await withService(async (service) => {
      for (const operation of [
        "prompt",
        "steer",
        "cancel",
        "requestMission",
        "answerDecision",
      ]) {
        const run = await runClientProcess(service.base, {
          mode: "call",
          execute: {
            schemaVersion: 1,
            baseId: service.baseId,
            command: {
              schemaVersion: 1,
              requestId: `req-${operation}`,
              target: { kind: "task", id: "task-1" },
              payload: { operation },
            },
          },
        });
        expect(run.code).toBe(0);
        expect(record(run, "execute")?.result).toEqual({
          ok: true,
          acceptance: {
            requestId: `req-${operation}`,
            accepted: false,
            revision: null,
            error: "operation-unavailable",
          },
        });
      }
    });
  }, 90_000);

  it("refuses unknown operations and malformed payloads without side effects", async () => {
    await withService(async (service) => {
      const before = await listBase(service.base);
      const descriptor = await descriptorText(service.base);

      const unknown = await runClientProcess(service.base, {
        mode: "call",
        execute: {
          schemaVersion: 1,
          baseId: service.baseId,
          command: {
            schemaVersion: 1,
            requestId: "req-unknown",
            target: { kind: "task", id: "task-1" },
            payload: { operation: "shell" },
          },
        },
      });
      expect(record(unknown, "execute")?.result).toEqual({
        ok: false,
        refusal: { code: "invalid-request" },
      });

      const extra = await runClientProcess(service.base, {
        mode: "call",
        execute: {
          schemaVersion: 1,
          baseId: service.baseId,
          command: {
            schemaVersion: 1,
            requestId: "req-extra",
            target: { kind: "task", id: "task-1" },
            payload: { operation: "steer", text: "hello" },
          },
        },
      });
      // Chord's argument cleaning drops unknown payload fields before the
      // handler. The field cannot influence anything, and the command is still
      // refused; the strict Zod boundary refuses any declared-field divergence
      // that survives cleaning.
      const extraResult = record(extra, "execute")?.result as {
        ok: boolean;
        acceptance: { accepted: boolean };
      };
      expect(extraResult.ok).toBe(true);
      expect(extraResult.acceptance.accepted).toBe(false);
      expect(JSON.stringify(extraResult)).not.toContain("hello");

      const longId = await runClientProcess(service.base, {
        mode: "call",
        execute: {
          schemaVersion: 1,
          baseId: service.baseId,
          command: {
            schemaVersion: 1,
            requestId: "r".repeat(200),
            target: { kind: "task", id: "task-1" },
            payload: { operation: "steer" },
          },
        },
      });
      expect(record(longId, "execute-error")).toMatchObject({
        code: "invalid",
      });

      const badKind = await runClientProcess(service.base, {
        mode: "call",
        execute: {
          schemaVersion: 1,
          baseId: service.baseId,
          command: {
            schemaVersion: 1,
            requestId: "req-kind",
            target: { kind: "browser", id: "task-1" },
            payload: { operation: "steer" },
          },
        },
      });
      expect(record(badKind, "execute-error")).toMatchObject({
        code: "invalid",
      });

      expect(await listBase(service.base)).toEqual(before);
      expect(await descriptorText(service.base)).toBe(descriptor);
    });
  }, 120_000);
});
