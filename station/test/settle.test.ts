// What a hub test waits with (hub-fakes.ts `settle`): the loop's queued work and the disk's answers it waits on.
import assert from "node:assert/strict";
import { pbkdf2 } from "node:crypto";
import { mkdtempSync } from "node:fs";
import { open, stat } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import { settle } from "./hub-fakes.ts";

test("settle waits for the disk: file requests one after another, more of them than its turns, are all answered", async () => {
  // Each is asked as the one before is answered, a turn of the loop at least apart: 300 cannot be done in 100 turns.
  let answered = 0;
  const chain = (async () => {
    for (let i = 0; i < 300; i++) {
      await stat(import.meta.dirname);
      answered++;
    }
  })();
  await settle();
  assert.equal(answered, 300);
  await chain;
});

test("settle waits for a file handle's close (fs/promises writeFile's last step), however long libuv's threads take to come to it", async () => {
  const handle = await open(join(mkdtempSync(join(process.env.STILLFAIL_TEST_TMP ?? tmpdir(), "settle-")), "f"), "w");
  await handle.write("x");
  // libuv's threads busy with work that is no file request, as a loaded machine keeps them: the close waits behind it
  const threads = Number(process.env.UV_THREADPOOL_SIZE ?? 4);
  const busy = Array.from({ length: threads * 2 }, () => new Promise((r) => pbkdf2("x", "y", 200_000, 32, "sha256", r)));
  let closed = false;
  const closing = handle.close().then(() => void (closed = true));
  await settle();
  assert.ok(closed, "the close still out as settle came back");
  await closing;
  await Promise.all(busy);
});

test("settle with nothing out is its turns of the loop, no more", async () => {
  let turns = 0;
  let going = true;
  const count = () => {
    if (!going) return;
    turns++;
    setImmediate(count);
  };
  setImmediate(count);
  await settle(7);
  going = false;
  assert.equal(turns, 7);
});
