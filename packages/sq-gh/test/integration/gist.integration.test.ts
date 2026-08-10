/**
 * Integration tests for gist edit operations.
 *
 * These tests drive the real `gistCommand` router against a real GitHub gist,
 * so they require:
 *   - `gh` installed and authenticated with the `gist` scope
 *   - Network access
 *
 * Gate: run only when GIST_INTEGRATION=1 is set in the environment.
 * Run locally: GIST_INTEGRATION=1 pnpm test test/integration/gist.integration.test.ts
 *
 * Critically, these go THROUGH `gistCommand` (not hand-built ghExec argv) so
 * they exercise gh-axi's own flag routing end-to-end against real gh. The
 * earlier version called ghExec directly and therefore validated gh's argv
 * contract but none of gh-axi's routing — which is exactly how the TTY-inference
 * bug (--remove rejected, --add <path> misrouted to stdin) slipped through.
 *
 * Only the stdin *source* is mocked (`readStdin`/`isStdinTTY`): the content a
 * user would pipe is supplied via the mock, while the routing and the real gh
 * invocation stay live.
 */
import {
  describe,
  it,
  expect,
  beforeAll,
  afterAll,
  beforeEach,
  vi,
} from "vitest";
import { writeFile, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { ghExec, ghJson } from "../../src/gh.js";
import { gistCommand } from "../../src/commands/gist.js";
import { isStdinTTY, readStdin } from "../../src/stdin.js";

// Mock only the stdin source. gh itself stays real.
vi.mock("../../src/stdin.js", () => ({
  isStdinTTY: vi.fn(() => false),
  readStdin: vi.fn(async () => ""),
}));

const mockedReadStdin = vi.mocked(readStdin);
const mockedIsStdinTTY = vi.mocked(isStdinTTY);

const RUN = process.env["GIST_INTEGRATION"] === "1";

// ── helpers ────────────────────────────────────────────────────────────────

interface GistFile {
  filename: string;
  content: string;
}

interface GistResponse {
  id: string;
  description: string;
  files: Record<string, GistFile>;
}

async function createGist(
  description: string,
  files: Record<string, string>,
): Promise<string> {
  // Build the argv using repeated -f flags for gh api
  const argv: string[] = [
    "api",
    "-X",
    "POST",
    "/gists",
    "-f",
    `description=${description}`,
  ];
  for (const [name, content] of Object.entries(files)) {
    argv.push("-f", `files[${name}][content]=${content}`);
  }
  const result = await ghJson<GistResponse>(argv);
  return result.id;
}

async function fetchGist(id: string): Promise<GistResponse> {
  return ghJson<GistResponse>(["api", `/gists/${id}`]);
}

async function deleteGist(id: string): Promise<void> {
  await ghExec(["api", "-X", "DELETE", `/gists/${id}`]);
}

// ── test suite ─────────────────────────────────────────────────────────────

describe.skipIf(!RUN)(
  "gist edit — integration (real gh, real gist, GIST_INTEGRATION=1)",
  () => {
    let gistId: string;

    beforeEach(() => {
      // Reset call history so per-test call assertions are isolated, then set
      // the default: non-TTY stdin (the agent context) and no piped content.
      mockedIsStdinTTY.mockClear();
      mockedReadStdin.mockClear();
      mockedIsStdinTTY.mockReturnValue(false);
      mockedReadStdin.mockResolvedValue("");
    });

    beforeAll(async () => {
      // Create a secret scratch gist with two files so we can test multi-file
      // operations (e.g., the desc-only blocker only reproduces on multi-file gists).
      gistId = await createGist("gh-axi integration test scratch", {
        "notes.txt": "original content",
        "second.txt": "second file original",
      });
      console.log(`Created scratch gist: ${gistId}`);
    });

    afterAll(async () => {
      if (gistId) {
        await deleteGist(gistId);
        console.log(`Deleted scratch gist: ${gistId}`);
      }
    });

    it("replace file content from stdin via gistCommand (blocker 1 regression)", async () => {
      const before = await fetchGist(gistId);
      expect(before.files["notes.txt"]?.content).toBe("original content");

      mockedReadStdin.mockResolvedValue("replaced by integration test");
      await gistCommand(["edit", gistId, "--filename", "notes.txt"]);

      const after = await fetchGist(gistId);
      console.log(
        `  notes.txt before: ${before.files["notes.txt"]?.content ?? "n/a"}`,
      );
      console.log(
        `  notes.txt after:  ${after.files["notes.txt"]?.content ?? "n/a"}`,
      );
      expect(after.files["notes.txt"]?.content).toBe(
        "replaced by integration test",
      );
    });

    it("update description only via gistCommand (blocker 2 regression)", async () => {
      // desc-only on a 2-file gist must not prompt; gistCommand routes it
      // through the REST API PATCH.
      const before = await fetchGist(gistId);
      const descBefore = before.description;

      await gistCommand([
        "edit",
        gistId,
        "--desc",
        "updated by integration test",
      ]);

      const after = await fetchGist(gistId);
      console.log(`  description before: ${descBefore}`);
      console.log(`  description after:  ${after.description}`);
      expect(after.description).toBe("updated by integration test");
    });

    it("add a new file from piped stdin via gistCommand (blocker 3 regression)", async () => {
      // --add <name> - reads from stdin and creates a new file. The explicit
      // `-` sentinel is what selects the stdin path.
      const before = await fetchGist(gistId);
      expect(before.files["brand-new.txt"]).toBeUndefined();

      mockedReadStdin.mockResolvedValue("added from stdin by integration test");
      await gistCommand(["edit", gistId, "--add", "brand-new.txt", "-"]);

      const after = await fetchGist(gistId);
      console.log(`  brand-new.txt before: (not present)`);
      console.log(
        `  brand-new.txt after:  ${after.files["brand-new.txt"]?.content ?? "n/a"}`,
      );
      expect(after.files["brand-new.txt"]?.content).toBe(
        "added from stdin by integration test",
      );
    });

    it("add a file from disk via gistCommand in non-TTY context (bug #1b regression)", async () => {
      // Without an explicit `-`, --add must read from disk even though the
      // agent stdin is non-TTY. The old code misrouted this to the stdin branch
      // and never read the file.
      const diskName = `gh-axi-gist-disk-${gistId}.txt`;
      const before = await fetchGist(gistId);
      expect(before.files[diskName]).toBeUndefined();

      const diskPath = join(tmpdir(), diskName);
      await writeFile(diskPath, "added from disk by integration test", "utf8");
      try {
        await gistCommand(["edit", gistId, "--add", diskPath]);
      } finally {
        await rm(diskPath, { force: true });
      }

      const after = await fetchGist(gistId);
      const added = Object.values(after.files).find(
        (f) => f.content === "added from disk by integration test",
      );
      console.log(`  from-disk file present after: ${added ? "yes" : "no"}`);
      expect(added).toBeDefined();
      expect(mockedReadStdin).not.toHaveBeenCalled();
    });

    it("remove a file via gistCommand in non-TTY context (bug #1a regression)", async () => {
      // The old TTY-inference rejected --remove in non-TTY (agent) contexts.
      // Through gistCommand it must simply remove the file.
      const before = await fetchGist(gistId);
      expect(before.files["brand-new.txt"]).toBeDefined();

      await gistCommand(["edit", gistId, "--remove", "brand-new.txt"]);

      const after = await fetchGist(gistId);
      console.log(`  brand-new.txt before: (present)`);
      console.log(
        `  brand-new.txt after:  ${after.files["brand-new.txt"] === undefined ? "(removed)" : "still present"}`,
      );
      expect(after.files["brand-new.txt"]).toBeUndefined();
    });
  },
);
