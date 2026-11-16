// The live view's reader of its own (live.ts `OwnReader`, where no readers are given: a test's) ends itself as its last
// answer comes, and a close in the same moment waits for that end before it takes its directory away: once `close`
// resolved no program of it runs and nothing of it is left on the disk. Before, the close found no reader (the answer
// had let it go) and removed the directory while the program still had its database open in it: `ENOTEMPTY` (rmdir) as
// it wrote its `-wal` there, hub-routes.test.ts failing on main (2026-11-16).
import assert from "node:assert/strict";
import { mkdtempSync, readdirSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import { MbProcess, mbReaderBinary } from "../src/read/mb-reader.ts";
import { LiveHub } from "../src/sessions/live.ts";

const skip = mbReaderBinary() === null ? "the MoonBit program is not built here" : false;
const said = (text: string, id: string) =>
  `${JSON.stringify({ type: "assistant", timestamp: "2026-11-16T00:00:00Z", message: { id, content: [{ type: "text", text }] } })}\n`;

test("a live view closed as its reader's last answer comes leaves no program and nothing on the disk", { skip }, async (t) => {
  const base = mkdtempSync(join(process.env.STILLFAIL_TEST_TMP ?? tmpdir(), "live-close-"));
  const before = process.env.STILLFAIL_TEST_TMP;
  // (the reader's directory made under this test's own, so what is left of it is seen)
  process.env.STILLFAIL_TEST_TMP = base;
  t.after(() => {
    if (before === undefined) delete process.env.STILLFAIL_TEST_TMP;
    else process.env.STILLFAIL_TEST_TMP = before;
    rmSync(base, { recursive: true, force: true });
  });
  const transcript = join(base, "x.jsonl");
  writeFileSync(transcript, said("one", "m1") + said("two", "m2") + said("three", "m3"));
  const ours = () => MbProcess.live().filter((p) => p.args.some((a) => a.startsWith(base)));
  const left = () => readdirSync(base).filter((name) => name.startsWith("live-reader-"));
  for (let round = 0; round < 8; round++) {
    const hub = new LiveHub(() => null);
    // Answered, the reader let go in the same moment: closed before anything else runs.
    assert.equal(await hub.counted("claude", transcript), 3);
    await hub.close();
    assert.deepEqual(ours(), [], `round ${round}: its program ended before the close resolved`);
    assert.deepEqual(left(), [], `round ${round}: its directory removed`);
  }
});

test("a live view closed while its reader's directory is being made starts no reader after", { skip }, async (t) => {
  const base = mkdtempSync(join(process.env.STILLFAIL_TEST_TMP ?? tmpdir(), "live-close-"));
  const before = process.env.STILLFAIL_TEST_TMP;
  process.env.STILLFAIL_TEST_TMP = base;
  t.after(() => {
    if (before === undefined) delete process.env.STILLFAIL_TEST_TMP;
    else process.env.STILLFAIL_TEST_TMP = before;
    rmSync(base, { recursive: true, force: true });
  });
  const transcript = join(base, "x.jsonl");
  writeFileSync(transcript, said("one", "m1"));
  const hub = new LiveHub(() => null);
  const refused = assert.rejects(hub.counted("claude", transcript), /the live view is closed/);
  await hub.close();
  await refused;
  assert.deepEqual(MbProcess.live().filter((p) => p.args.some((a) => a.startsWith(base))), []);
  assert.deepEqual(readdirSync(base).filter((name) => name.startsWith("live-reader-")), []);
});
