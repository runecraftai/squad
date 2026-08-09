import type { ChangedFileLike } from "../lib/pr-review-publish.ts";

const changedFile: ChangedFileLike = {};
changedFile.filename = "src/parser.ts";
changedFile.patch = "@@ -1 +1 @@";
