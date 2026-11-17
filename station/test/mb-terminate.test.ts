import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { mkdtempSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";

test("terminating an unreferenced reader waits for its close in an after hook", () => {
  const dir = mkdtempSync(join(tmpdir(), "mb-terminate-"));
  try {
    const marker = join(dir, "done");
    const env: NodeJS.ProcessEnv = { ...process.env, TERMINATE_MARKER: marker };
    delete env.NODE_TEST_CONTEXT;
    const result = spawnSync(process.execPath, ["--import", "./test/setup-env.mjs", "--test", "./test/mb-terminate-fixture.mjs"], {
      env, encoding: "utf8",
    });
    assert.equal(result.status, 0, result.stderr + result.stdout);
    assert.equal(readFileSync(marker, "utf8"), "closed");
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});
