import { appendFileSync } from "node:fs";

const traceFile = process.env.SQ_QUOTA_MODULE_TRACE_FILE;

export async function load(url, context, nextLoad) {
  if (traceFile && !url.startsWith("node:"))
    appendFileSync(traceFile, `${url}\n`);
  return nextLoad(url, context);
}
