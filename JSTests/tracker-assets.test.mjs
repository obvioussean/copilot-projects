import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import test from "node:test";
import { trackerResourceDir } from "./support/tracker.mjs";

test("the tracker extension is a valid ES module", () => {
  const extension = join(trackerResourceDir, "extension.mjs");
  assert.doesNotThrow(() => execFileSync(process.execPath, ["--check", extension]));
  assert.ok(
    readFileSync(extension, "utf8").includes('from "@github/copilot-sdk/extension"'),
    "the extension must still join the Copilot CLI session"
  );
});
