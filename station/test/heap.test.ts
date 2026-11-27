// `stillfail heap` (src/ops/heap.ts): the command asks, the station writes its heap snapshot (the owner's alone, the
// latest only) and says where; a request the station's watcher did not see is taken all the same.
import assert from "node:assert/strict";
import { EventEmitter } from "node:events";
import { type FSWatcher, closeSync, existsSync, mkdirSync, mkdtempSync, openSync, readFileSync, readSync, readdirSync, rmSync, statSync, watch, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import { answerHeapRequests, heapCommand } from "../src/ops/heap.ts";

const snapshots = (dir: string) => readdirSync(dir).filter((n) => n.endsWith(".heapsnapshot"));

/// The station's answer in `run`, once it is there (written whole, by a rename).
const answered = (run: string) =>
  new Promise<{ path?: string; error?: string }>((resolve) => {
    const path = join(run, "heap.answer");
    const check = () => {
      if (!existsSync(path)) return;
      w.close();
      resolve(JSON.parse(readFileSync(path, "utf8")));
    };
    const w = watch(run, check);
    check();
  });

test("asked from the command line, the station writes its heap snapshot, only the latest kept, the owner's alone", async () => {
  const data = mkdtempSync(join(tmpdir(), "heap-"));
  const stop = answerHeapRequests(data);
  try {
    const run = join(data, "run");
    assert.equal(await heapCommand(data), 0);
    const [first] = snapshots(run);
    assert.ok(first, "a snapshot is there");
    const path = join(run, first!);
    assert.equal(statSync(path).mode & 0o777, 0o600);
    // A heap snapshot: JSON that starts with its meta.
    const head = Buffer.alloc(32);
    const fd = openSync(path, "r");
    readSync(fd, head, 0, 32, 0);
    closeSync(fd);
    assert.match(head.toString(), /^\{"snapshot":\{"meta"/);
    assert.equal(await heapCommand(data), 0);
    assert.equal(snapshots(run).length, 1, "the one before is gone");
    assert.ok(!existsSync(join(run, "heap.request")) && !existsSync(join(run, "heap.answer")), "nothing left of the asking");
  } finally {
    stop();
    rmSync(data, { recursive: true, force: true });
  }
});

test("asked before the station watched, the request is taken all the same", async () => {
  const data = mkdtempSync(join(tmpdir(), "heap-"));
  const asked = heapCommand(data);
  const stop = answerHeapRequests(data);
  try {
    assert.equal(await asked, 0);
    assert.equal(snapshots(join(data, "run")).length, 1);
  } finally {
    stop();
    rmSync(data, { recursive: true, force: true });
  }
});

test("a watcher that cannot be opened (EMFILE) is told, never an unhandled rejection, and a waiting request is taken", async () => {
  const data = mkdtempSync(join(tmpdir(), "heap-"));
  const rejections: unknown[] = [];
  const onRejection = (reason: unknown) => rejections.push(reason);
  process.on("unhandledRejection", onRejection);
  let opened = 0;
  const emfile = () => {
    opened++;
    throw Object.assign(new Error("EMFILE: too many open files, watch"), { code: "EMFILE" });
  };
  // Asked while no station ran: no watcher will tell of it.
  const run = join(data, "run");
  mkdirSync(run, { recursive: true });
  writeFileSync(join(run, "heap.request"), String(process.pid));
  const answer = answered(run);
  const stop = answerHeapRequests(data, emfile);
  try {
    const { path, error } = await answer;
    assert.equal(error, undefined);
    assert.equal(opened, 1);
    assert.deepEqual(snapshots(run), [path!.slice(run.length + 1)]);
    assert.ok(!existsSync(join(run, "heap.request")), "the request is taken");
    await new Promise((resolve) => setImmediate(resolve));
    assert.deepEqual(rejections, []);
  } finally {
    stop();
    process.off("unhandledRejection", onRejection);
    rmSync(data, { recursive: true, force: true });
  }
});

test("a watcher that fails is told and closed, and not closed again on stop", async () => {
  const data = mkdtempSync(join(tmpdir(), "heap-"));
  class FailingWatcher extends EventEmitter {
    closed = 0;
    close() {
      this.closed++;
    }
  }
  const failing = new FailingWatcher();
  let opened!: () => void;
  const open = new Promise<void>((resolve) => (opened = resolve));
  const stop = answerHeapRequests(data, () => {
    opened();
    return failing as unknown as FSWatcher;
  });
  try {
    await open;
    failing.emit("error", Object.assign(new Error("EMFILE: too many open files"), { code: "EMFILE" }));
    assert.equal(failing.closed, 1);
  } finally {
    stop();
    rmSync(data, { recursive: true, force: true });
  }
  assert.equal(failing.closed, 1, "stop closes no watcher already closed");
});
