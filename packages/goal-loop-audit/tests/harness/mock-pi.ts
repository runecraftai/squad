// pi-goal-list-loop-audit — v0.28.7 (T7)
// tests/harness/mock-pi.ts
//
// The mock-ctx harness the audit called for (WRONG-OR-NOT-PREMIUM Stream 4,
// T7): a fake ExtensionAPI + stub ExtensionContext that let tests REGISTER
// goal.ts's tools/commands/event handlers and DRIVE them behaviorally —
// instead of regex-pinning source text.
//
// Design notes:
// - goal.ts is a singleton module with process-wide state (state.goal,
//   ownerSession, extensionApiStale, …). bun test SHARES module state across
//   files (verified empirically), so all goal.ts-driving behavioral tests
//   live in ONE file (tests/behavioral-orchestrator.test.ts), run in a
//   deliberate order, and share one sessionManager (the first session_start
//   claims it; anything else is "foreign").
// - sendMessageError / ui.*Impl are the fault-injection knobs (stale handle,
//   dialog throws, editor answers).
// - tick() lets the 0ms/50ms scheduled continuation timers fire.

import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";

/** pi's exact stale-handle signature (matched by isStaleApiError). */
export const STALE_ERROR_MESSAGE = "stale after session replacement or reload";

export function staleError(): Error {
  return new Error(`This extension's context is ${STALE_ERROR_MESSAGE}`);
}

export interface SentMessage {
  message: { customType?: string; content?: string; display?: boolean };
  options: unknown;
}

export class MockPi {
  tools = new Map<string, { name: string; execute: (...args: never[]) => Promise<unknown> }>();
  commands = new Map<string, (args: string, ctx: unknown) => Promise<void>>();
  handlers = new Map<string, (...args: never[]) => Promise<void>>();
  sent: SentMessage[] = [];
  userMessages: Array<{ message: string; options: unknown }> = [];
  /** When set, sendMessage throws it SYNCHRONOUSLY — matching pi's real
   * assertActive() semantics (stale = sync throw, not a rejected promise,
   * so goal.ts's try/catch send paths observe it exactly as in prod). */
  sendMessageError: Error | null = null;
  /** When set, getSessionName() throws it — trips the stale entry probe. */
  sessionNameError: Error | null = null;
  sessionName = "mock-session";
  private activeTools: string[] = [];
  readonly api: ExtensionAPI;

  constructor() {
    const self = this;
    this.api = {
      registerTool(def: { name: string; execute: (...args: never[]) => Promise<unknown> }): void {
        self.tools.set(def.name, { name: def.name, execute: def.execute });
      },
      registerCommand(name: string, spec: { handler: (args: string, ctx: unknown) => Promise<void> }): void {
        self.commands.set(name, spec.handler);
      },
      on(event: string, handler: (...args: never[]) => Promise<void>): void {
        self.handlers.set(event, handler);
      },
      sendMessage(message: SentMessage["message"], options: unknown): Promise<void> {
        if (self.sendMessageError) throw self.sendMessageError; // sync throw, like pi's assertActive()
        self.sent.push({ message, options });
        return Promise.resolve();
      },
      sendUserMessage(message: string, options: unknown): void {
        if (self.sendMessageError) throw self.sendMessageError;
        self.userMessages.push({ message, options });
      },
      getThinkingLevel(): string {
        return "high";
      },
      getSessionName(): string {
        if (self.sessionNameError) throw self.sessionNameError;
        return self.sessionName;
      },
      getActiveTools(): string[] {
        return [...self.activeTools];
      },
      setActiveTools(names: string[]): void {
        self.activeTools = [...names];
      },
      getCommands(): Array<{ name: string }> {
        return [...self.commands.keys()].map((name) => ({ name }));
      },
      async exec(): Promise<{ code: number; stdout: string; stderr: string }> {
        return { code: 0, stdout: "", stderr: "" };
      },
    } as unknown as ExtensionAPI;
  }

  async fire(event: string, ...args: unknown[]): Promise<void> {
    const h = this.handlers.get(event);
    if (!h) throw new Error(`no handler registered for event: ${event}`);
    await (h as (...a: unknown[]) => Promise<void>)(...args);
  }

  async runTool(name: string, params: unknown, ctx: unknown): Promise<{ content: Array<{ type: string; text: string }> }> {
    const t = this.tools.get(name);
    if (!t) throw new Error(`tool not registered: ${name}`);
    return (await (t.execute as (...a: unknown[]) => Promise<{ content: Array<{ type: string; text: string }> }>)(
      "call-1",
      params,
      new AbortController().signal,
      undefined,
      ctx,
    )) as { content: Array<{ type: string; text: string }> };
  }

  async command(name: string, args: string, ctx: unknown): Promise<void> {
    const h = this.commands.get(name);
    if (!h) throw new Error(`command not registered: ${name}`);
    await h(args, ctx);
  }
}

export interface MockNotify {
  message: string;
  type?: string;
}

export class MockUi {
  notifies: MockNotify[] = [];
  statuses: Record<string, string | undefined> = {};
  widgets: Record<string, unknown> = {};
  confirmImpl: ((title: string, message: string) => Promise<boolean>) | undefined = async () => true;
  selectImpl: ((title: string, options: string[]) => Promise<string | undefined>) | undefined = async () => undefined;
  inputImpl: ((title: string, placeholder?: string) => Promise<string | undefined>) | undefined = async () => undefined;
  customImpl: ((...args: unknown[]) => Promise<unknown>) | undefined = async () => undefined;

  notify(message: string, type?: string): void {
    this.notifies.push({ message, type });
  }
  setStatus(key: string, text: string | undefined): void {
    this.statuses[key] = text;
  }
  setWidget(key: string, lines: unknown): void {
    this.widgets[key] = lines;
  }
  confirm(title: string, message: string): Promise<boolean> {
    return this.confirmImpl ? this.confirmImpl(title, message) : Promise.resolve(true);
  }
  select(title: string, options: string[]): Promise<string | undefined> {
    return this.selectImpl ? this.selectImpl(title, options) : Promise.resolve(undefined);
  }
  input(title: string, placeholder?: string): Promise<string | undefined> {
    return this.inputImpl ? this.inputImpl(title, placeholder) : Promise.resolve(undefined);
  }
  custom(...args: unknown[]): Promise<unknown> {
    return this.customImpl ? this.customImpl(...args) : Promise.resolve(undefined);
  }
  get theme(): undefined {
    return undefined;
  }

  /** All notify messages containing `substr` (case-insensitive). */
  matching(substr: string): MockNotify[] {
    const needle = substr.toLowerCase();
    return this.notifies.filter((n) => n.message.toLowerCase().includes(needle));
  }
}

export type MockCtx = Omit<ExtensionContext, "ui"> & { ui: MockUi };

export function makeMockCtx(cwd: string, opts: { sessionManager?: unknown; idle?: boolean; pending?: boolean } = {}): MockCtx {
  const ui = new MockUi();
  return {
    cwd,
    hasUI: true,
    sessionManager: opts.sessionManager ?? { mock: "session-manager" },
    model: { provider: "anthropic", id: "mock-model" },
    isIdle: () => opts.idle ?? true,
    hasPendingMessages: () => opts.pending ?? false,
    abort: () => {},
    ui,
  } as unknown as MockCtx;
}

export function tmpCwd(): string {
  return fs.mkdtempSync(path.join(os.tmpdir(), "glla-behavioral-"));
}

/** Seed a .pi-glla/active.jsonl with ONE state line (the restore-gate input). */
export function seedState(cwd: string, value: { goal?: unknown; list?: unknown[]; loop?: unknown }): void {
  fs.mkdirSync(path.join(cwd, ".pi-glla"), { recursive: true });
  const line = JSON.stringify({ type: "state", value: { goal: null, list: [], loop: null, ...value }, at: new Date().toISOString() });
  fs.writeFileSync(path.join(cwd, ".pi-glla", "active.jsonl"), line + "\n");
}

/** A minimal valid active-goal object for seedState. */
export function seedGoal(overrides: Record<string, unknown> = {}): Record<string, unknown> {
  const now = new Date().toISOString();
  return {
    id: `test-${Date.now()}-${Math.random().toString(36).slice(2, 8)}`,
    objective: "seeded test objective — done when pinned",
    status: "active",
    policy: "goal",
    autoContinue: true,
    usage: { inputTokens: 0, outputTokens: 0, cacheReadTokens: 0, cacheWriteTokens: 0, cost: 0, turns: 0 },
    createdAt: now,
    updatedAt: now,
    ...overrides,
  };
}

/** A minimal valid active-loop object for seedState. */
export function seedLoop(overrides: Record<string, unknown> = {}): Record<string, unknown> {
  return {
    target: "seeded loop target",
    measureCmd: "echo 1",
    direction: "min",
    iteration: 1,
    maxIterations: 50,
    plateauWindow: 5,
    stallCount: 0,
    bestValue: null,
    lastValue: null,
    active: true,
    history: [],
    startedAt: new Date().toISOString(),
    ...overrides,
  };
}

/** Let scheduled 0ms/50ms continuation timers fire. */
export function tick(ms = 150): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}
