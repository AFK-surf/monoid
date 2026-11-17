// What a test file left running, found by its mark (setup-env.mjs): on Linux read from /proc, here a /proc of the
// test's own, so it is the same on every machine.
import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdirSync, mkdtempSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { leftRunning } from "./left-running.ts";

function proc(entries: Record<string, { environ?: string; cmdline?: string }>): string {
  const root = mkdtempSync(join(process.env.STILLFAIL_TEST_TMP ?? "/tmp", "proc-"));
  // (what /proc has besides the processes, passed over)
  mkdirSync(join(root, "self"));
  writeFileSync(join(root, "uptime"), "1.0 1.0\n");
  for (const [pid, e] of Object.entries(entries)) {
    mkdirSync(join(root, pid));
    if (e.environ !== undefined) writeFileSync(join(root, pid, "environ"), e.environ);
    if (e.cmdline !== undefined) writeFileSync(join(root, pid, "cmdline"), e.cmdline);
  }
  return root;
}

test("Linux: the processes carrying the file's mark, each with its command, from /proc", () => {
  const root = proc({
    // first in its environment
    "101": { environ: "STILLFAIL_TEST_FILE=7-1\0PATH=/bin\0", cmdline: "tail\0-f\0/tmp/x\0" },
    // among the rest
    "102": { environ: "HOME=/h\0STILLFAIL_TEST_FILE=7-1\0", cmdline: "node\0far.mjs\0" },
    // another file's mark, one that only begins with this one's, none at all
    "103": { environ: "STILLFAIL_TEST_FILE=8-1\0", cmdline: "node\0" },
    "104": { environ: "STILLFAIL_TEST_FILE=7-10\0", cmdline: "node\0" },
    "105": { environ: "PATH=/bin\0", cmdline: "sh\0" },
    // gone meanwhile (or another user's: unreadable)
    "106": {},
    // a kernel thread: no environment, no command
    "2": { environ: "", cmdline: "" },
    // this process itself
    "7": { environ: "STILLFAIL_TEST_FILE=7-1\0", cmdline: "node\0--test\0" },
  });
  assert.deepEqual(leftRunning("7-1", { platform: "linux", proc: root, self: 7 }).sort(), ["101 tail -f /tmp/x", "102 node far.mjs"]);
  assert.deepEqual(leftRunning("9-9", { platform: "linux", proc: root, self: 7 }), []);
});

test("Linux: no /proc to read is nothing found", () => {
  assert.deepEqual(leftRunning("7-1", { platform: "linux", proc: "/nonexistent/proc", self: 7 }), []);
});
