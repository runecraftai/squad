import assert from "node:assert/strict";
import test from "node:test";

import { createTelemetryClient, resolveTelemetryConfig } from "../src/telemetry.js";

function createFetchSpy(options = {}) {
  const requests = [];
  let release = () => {};
  const fetch = async (url, init = {}) => {
    if (options.throws) throw options.throws;
    const headers = {};
    for (const [key, value] of Object.entries(init.headers || {})) {
      headers[key] = value;
    }
    requests.push({
      url: String(url),
      method: init.method || "GET",
      headers,
      body: init.body ? JSON.parse(init.body) : undefined,
    });
    if (options.delayMs !== undefined) {
      await new Promise((resolve) => {
        const timer = setTimeout(resolve, options.delayMs);
        timer.unref?.();
        release = () => {
          clearTimeout(timer);
          resolve();
        };
      });
    }
    return new Response(null, { status: 200 });
  };
  return { fetch, requests, release };
}

test("telemetry can be disabled by environment", () => {
  const config = resolveTelemetryConfig({
    env: { SQ_REPORT_TELEMETRY: "0" },
    buildHost: "https://build.example",
    buildWebsiteID: "build-id",
  });

  assert.equal(config.enabled, false);
});

test("telemetry uses env values before build-time defaults", () => {
  const config = resolveTelemetryConfig({
    env: {
      SQ_REPORT_UMAMI_HOST: " https://env.example ",
      SQ_REPORT_UMAMI_WEBSITE_ID: " env-id ",
    },
    buildHost: "https://build.example",
    buildWebsiteID: "build-id",
  });

  assert.deepEqual(config, {
    enabled: true,
    host: "https://env.example",
    websiteID: "env-id",
  });
});

test("telemetry disables when no website id is configured", () => {
  const config = resolveTelemetryConfig({
    env: {},
    buildHost: "https://build.example",
    buildWebsiteID: "",
  });

  assert.equal(config.enabled, false);
});

test("telemetry sends anonymous Umami event payloads", async () => {
  const { fetch, requests } = createFetchSpy();
  const client = createTelemetryClient({
    enabled: true,
    host: "https://a.example.com/umami/",
    websiteID: "site-1",
    app: "sq-report",
    version: "1.2.3",
    platform: "darwin",
    arch: "arm64",
    fetch,
  });

  client.track("command", { command: "poll", status: "success" });
  await client.close(500);

  assert.equal(requests.length, 1);
  assert.equal(requests[0].url, "https://a.example.com/umami/api/send");
  assert.equal(requests[0].method, "POST");
  assert.equal(requests[0].headers["Content-Type"], "application/json");
  assert.match(requests[0].headers["User-Agent"], /^sq-report\/1.2.3 telemetry$/);
  assert.deepEqual(requests[0].body.payload.website, "site-1");
  assert.deepEqual(requests[0].body.payload.hostname, "cli");
  assert.deepEqual(requests[0].body.payload.title, "sq-report CLI");
  assert.deepEqual(requests[0].body.payload.url, "app://sq-report/command");
  assert.deepEqual(requests[0].body.payload.name, "command");
  assert.deepEqual(requests[0].body.payload.data.command, "poll");
  assert.deepEqual(requests[0].body.payload.data.status, "success");
  assert.deepEqual(requests[0].body.payload.data.platform, "darwin");
  assert.deepEqual(requests[0].body.payload.data.arch, "arm64");
  assert.deepEqual(requests[0].body.payload.data.version, "1.2.3");
  assert.equal(typeof requests[0].body.payload.timestamp, "number");
});

test("telemetry is best effort and never throws fetch failures", async () => {
  const client = createTelemetryClient({
    enabled: true,
    host: "https://a.example.com",
    websiteID: "site-1",
    app: "sq-report",
    version: "1.0.0",
    fetch: createFetchSpy({ throws: new Error("network down") }).fetch,
  });

  assert.doesNotThrow(() => client.track("command", {}));
  await assert.doesNotReject(() => client.close(500));
});

test("telemetry close waits only up to the requested timeout", async () => {
  const { fetch, requests, release } = createFetchSpy({ delayMs: 10_000 });
  const client = createTelemetryClient({
    enabled: true,
    host: "https://a.example.com",
    websiteID: "site-1",
    app: "sq-report",
    version: "1.0.0",
    fetch,
  });

  client.track("command", {});
  await client.close(20);
  assert.equal(requests.length, 1);
  release();
});
