import { spawnSync } from "node:child_process";
import { existsSync, readFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { expect, test, type Page } from "@playwright/test";

/**
 * End-to-end pass over the real local surface: diff to line to comment to reload to change
 * request to stale. Everything runs offline against the private fixture server; any non-loopback
 * request fails the suite. The fixture capture is explicitly ineligible, so acceptance stays
 * disabled: this process never records a human acceptance.
 */

interface FixtureInfo { port: number; root: string; repo: string; dataDir: string; h1: string; h2: string; packetId: string; packetDigest: string; scopeDigest: string }

function fixtureInfo(): FixtureInfo {
	const port = Number(process.env.WARROOM_E2E_PORT ?? "4711");
	const path = process.env.WARROOM_E2E_INFO ?? join(tmpdir(), `warroom-e2e-${port}.json`);
	for (let attempt = 0; attempt < 100; attempt++) {
		if (existsSync(path)) {
			try { return JSON.parse(readFileSync(path, "utf8")) as FixtureInfo; } catch { /* still writing */ }
		}
		Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, 50);
	}
	throw new Error(`fixture info not found at ${path}`);
}

const externalRequests: string[] = [];

async function openReview(page: Page): Promise<void> {
	await page.goto("/");
	await expect(page.getByRole("heading", { name: "Runecraft Warroom" })).toBeVisible();
	await page.locator("#review-tab").click();
	await expect(page.locator("#review-root")).toBeVisible();
}

test("the local surface navigates diff, anchors a comment, survives reload, requests corrections and shows staleness offline", async ({ page }, testInfo) => {
	await page.route("**/*", async (route) => {
		const url = new URL(route.request().url());
		const loopback = url.hostname === "127.0.0.1" || url.hostname === "localhost" || url.hostname === "[::1]";
		if (!loopback) {
			externalRequests.push(url.toString());
			await route.abort();
			return;
		}
		await route.continue();
	});

	const info = fixtureInfo();
	await openReview(page);

	// Currentness, evidence coverage and the explicit ineligibility of synthetic evidence.
	await expect(page.locator("#review-status")).toContainText("Currentness: verified");
	await expect(page.locator("#review-status")).toContainText("Evidence: not eligible");
	await expect(page.locator("#review-evidence")).toContainText("run run-1");
	await expect(page.locator("#review-evidence")).toContainText("CI readiness recorded");
	await expect(page.locator("#review-evidence")).toContainText("steps skipped: none");
	await expect(page.locator("#review-accept")).toBeDisabled();
	await expect(page.locator("#review-decision-state")).toContainText("cannot be reviewed");

	// The complete file scope is listed, including documentation, tests, config and unreviewable objects.
	await expect(page.locator("#review-file-count")).toContainText("11 paths");
	await expect(page.locator('[data-review-file="docs/binary.bin"]')).toContainText("not reviewable: binary");
	await expect(page.locator('[data-review-file="docs/mixed.txt"]')).toBeVisible();
	await expect(page.locator('[data-review-file="tests/hello.test.ts"]')).toContainText("reviewable text");
	await expect(page.locator('[data-review-file="docs/path with spaces e acentuação.txt"]')).toHaveCount(1);

	// Diff of a path with spaces shows the exact added bytes.
	await page.locator('[data-review-file="docs/path with spaces e acentuação.txt"]').click();
	await expect(page.locator("#review-diff")).toContainText("line two");
	await page.locator('[data-review-mode="head"]').click();
	await expect(page.locator("#review-diff")).toContainText("line three");
	await page.locator('[data-review-mode="diff"]').click();
	await expect(page.locator("#review-diff")).toContainText("line two");

	// Keyboard navigation: focus a file button, select it with Enter, then anchor a head line.
	await page.locator('[data-review-file="src/hello.ts"]').focus();
	await page.keyboard.press("Enter");
	await expect(page.locator("#review-diff")).toContainText("hello, ${name}!");
	await page.locator('[data-review-anchor="head"][data-line="2"]').focus();
	await page.keyboard.press("Enter");
	await expect(page.locator("#review-comment-form")).toBeVisible();

	await page.locator("#review-comment-body").fill("The name check belongs here.");
	await page.locator("#review-comment-kind").selectOption("comment");
	await page.locator("#review-comment-save").click();
	await expect(page.locator("#review-comments")).toContainText("The name check belongs here.");
	await expect(page.locator("#review-message")).toContainText("Comment saved on this snapshot.");

	// Reload proves comments survive restart and stay anchored to the same snapshot.
	await openReview(page);
	await expect(page.locator("#review-comments")).toContainText("The name check belongs here.");
	await expect(page.locator("#review-comments")).toContainText("open");
	await page.locator('[data-resolve-comment]').first().click();
	await expect(page.locator("#review-comments")).toContainText("resolved");
	await expect(page.locator("#review-decision-state")).toContainText("No acceptance recorded");

	// A change request is recorded as its own decision, never as an acceptance.
	await page.locator("#review-declaration").fill("Fix the validation before merge.");
	await page.locator("#review-request-changes").click();
	await expect(page.locator("#review-message")).toContainText("Correction request recorded");
	await expect(page.locator("#review-decision-state")).toContainText("changes-requested");
	await expect(page.locator("#review-decision-state")).not.toContainText("code-review-acceptance: approved");

	// Advancing the recorded head ref makes the snapshot stale in the browser.
	const moved = spawnSync("git", ["-c", "user.name=F", "-c", "user.email=f@example.test", "-C", info.repo, "tag", "-f", "h1", info.h2], { encoding: "utf8" });
	expect(moved.status).toBe(0);
	await openReview(page);
	await expect(page.locator("#review-status")).toContainText("Snapshot status: stale");
	await expect(page.locator("#review-status")).toContainText("head-moved");
	await expect(page.locator("#review-accept")).toBeDisabled();
	await expect(page.locator("#review-decision-state")).toContainText("stale");

	// Text, not colour alone, carries every state; focus and labels exist for the decision controls.
	await expect(page.locator("#review-scope-confirm")).toHaveAttribute("type", "checkbox");
	await expect(page.getByLabel("Declaration")).toBeVisible();
	await expect(page.locator("#review-message")).toHaveAttribute("role", "status");
	await expect(page.locator("#review-message")).toHaveAttribute("aria-live", "polite");

	expect(externalRequests).toEqual([]);
	await page.screenshot({ path: testInfo.outputPath("review-flow.png"), fullPage: true });
});
