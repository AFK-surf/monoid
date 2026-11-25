import assert from "node:assert/strict";
import { chmodSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import { MbProcess } from "../src/read/mb-reader.ts";
import { RequestedBuilder } from "../src/read/requested-builder.ts";

const quoted = (s: string) => `'${s.replaceAll("'", "'\\''")}'`;

function script(path: string, body: string): string {
  writeFileSync(path, `#!/bin/sh\n${body}\n`);
  chmodSync(path, 0o755);
  return path;
}

/// Until the process of `binary` is no longer among those running: its end seen by everything listening for it.
async function ended(binary: string): Promise<void> {
  while (MbProcess.live().some((p) => p.binary === binary)) await new Promise((r) => setImmediate(r));
}

// A builder let go idle ends some time after it is let go; the next one, started meanwhile for a new request, takes the
// permit for its batch at once. The first one's end once took the permit as the second one's no longer held, so its
// answer never gave it back: every builder sharing the permit then waited for good, each read on them timed out
// (two stations, 2026-11-25).
test("a builder let go idle ending after the next one took the permit leaves it to be given back", async () => {
  const dir = mkdtempSync(join(tmpdir(), "requested-builder-permit-"));
  const answer = "printf '%s\\n' '{\"done\":true}'";
  const first = script(join(dir, "first"), `while read -r line; do ${answer}; done`);
  const go = join(dir, "go");
  // (the second answers its first batch only once the test has seen the first one's end)
  const second = script(join(dir, "second"),
    `read -r line\nwhile [ ! -e ${quoted(go)} ]; do sleep 0.01; done\n${answer}\nwhile read -r line; do ${answer}; done`);
  const priority = new SharedArrayBuffer(8), permit = new Int32Array(priority);
  let starts = 0;
  const builder = new RequestedBuilder<string>({ priority },
    { binary: () => starts++ === 0 ? first : second, args: [] }, "session", "permit test");
  try {
    await builder.ready(["a"]);
    assert.equal(Atomics.load(permit, 1), 0);
    assert.equal(builder.trimIdle(), true);
    const next = builder.ready(["b"]);
    assert.notEqual(Atomics.load(permit, 1), 0, "the second builder holds the permit for its batch");
    await ended(first);
    writeFileSync(go, "");
    await next;
    assert.equal(Atomics.load(permit, 1), 0, "the permit given back with the second builder's answer");
    await builder.ready(["c"]);
  } finally { writeFileSync(go, ""); await builder.close(); rmSync(dir, { recursive: true, force: true }); }
});
