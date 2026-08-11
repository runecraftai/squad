import { appendFileSync } from "node:fs";
const started = process.cpuUsage();

process.on("beforeExit", () => {
  const out = process.env.SQ_BROWSER_PROCESS_TIMING;
  if (out) {
    const elapsed = process.cpuUsage(started);
    appendFileSync(out, `${(elapsed.user + elapsed.system) / 1_000}\n`);
  }
});
