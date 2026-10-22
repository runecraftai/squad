import { defineConfig } from "vitest/config";

// Every suite spawns real service processes on disk stores, so suites run one
// file at a time to keep SIGKILL timing and socket startup deterministic.
export default defineConfig({
	test: {
		include: ["test/**/*.test.ts"],
		fileParallelism: false,
		testTimeout: 60_000,
		hookTimeout: 60_000,
	},
});
