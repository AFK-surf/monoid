// What the station's main thread waits on as its services keep what they were told: a chat platform's names
// (src/connects/names.ts), Feishu's conversations (src/feishu/threads.ts), Comma's Tasks and the parts of a file a
// Router reads (src/comma/tasks.ts, src/comma/surface.ts) and its indexes' directories (src/comma/stats.ts), a person's
// own lock as a device or a station brings it (src/mesh/person-chains.ts), the log's end a bug report takes
// (src/feedback/notice.ts), what a rig was told to run (src/rig/log.ts) and a heap snapshot asked for (src/ops/heap.ts):
// none of node:fs's synchronous calls (station/AGENTS.md, the main thread waits on nothing). Each ran as a name was
// learned, a Feishu or Comma message came, a lock was brought, a report was sent or a rig was asked to run something.
import assert from "node:assert/strict";
import { generateKeyPairSync, sign as nodeSign } from "node:crypto";
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { readFile, readdir, stat } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { after, test } from "node:test";
import { type Entry, entryHash, signedBytes } from "../../shared/lock.ts";
import { CommaStats } from "../src/comma/stats.ts";
import { CommaSurface } from "../src/comma/surface.ts";
import { CommaTasks } from "../src/comma/tasks.ts";
import { NameBook } from "../src/connects/names.ts";
import { readTail } from "../src/feedback/notice.ts";
import { FeishuThreads } from "../src/feishu/threads.ts";
import { PersonChains } from "../src/mesh/person-chains.ts";
import { answerHeapRequests, heapCommand } from "../src/ops/heap.ts";
import { CommandLog } from "../src/rig/log.ts";
import { settle } from "./hub-fakes.ts";
import { syncCalls } from "./main-thread-sync.ts";

const dir = mkdtempSync(join(tmpdir(), "services-io-"));
after(() => rmSync(dir, { recursive: true, force: true }));
const json = async (path: string) => JSON.parse(await readFile(path, "utf8"));

test("a name learned is kept off the main thread, and written by the time the book is closed", async () => {
  const path = join(dir, "slack-names.json");
  const book = new NameBook(path, { saveAfterMs: 0, learnAfterMs: 0 });
  assert.deepEqual(await syncCalls(async () => {
    assert.equal(book.person("u:T:U1", async () => ({ name: "Ann", email: "ann@x" })), null);
    assert.equal(book.channel("c:T:C1", async () => "general"), null);
    await settle();
    await book.close();
  }), []);
  const kept = await json(path);
  assert.equal(kept["u:T:U1"].person.name, "Ann");
  assert.equal(kept["c:T:C1"].channel, "general");
});

test("Feishu's conversations and Comma's Tasks are kept off the main thread, the latest written", async () => {
  const threadsPath = join(dir, "feishu-threads.json"), tasksPath = join(dir, "comma-tasks.json");
  const threads = new FeishuThreads(threadsPath);
  const tasks = new CommaTasks(tasksPath);
  assert.deepEqual(await syncCalls(async () => {
    threads.begin("f", "oc_1", "om_1");
    threads.heard("f", "oc_1", 5);
    threads.heardTopic("f", "omt_1", "om_2");
    await threads.written();
    tasks.invited("cm", "task-1", { requester: "u1", title: "t", runtime: null, model: null }, 0);
    tasks.given("cm", "task-1", 3, 2);
    tasks.invited("cm", "task-2", { requester: "u1", title: null, runtime: null, model: null }, 0);
    tasks.left("cm", "task-2");
    await tasks.written();
  }), []);
  assert.deepEqual(await json(threadsPath), { f: { chats: { oc_1: "om_1" }, topics: { omt_1: "om_2" }, seen: { oc_1: 5 } } });
  const kept = await json(tasksPath);
  assert.equal(kept.cm["task-1"].fetched, 3);
  assert.equal(kept.cm["task-2"].left, true);
  // Read back as the next station reads them.
  assert.equal(new FeishuThreads(threadsPath).current("f", "oc_1"), "om_1");
  assert.equal(new CommaTasks(tasksPath).get("cm", "task-1")?.answered, 2);
});

test("a Router reads a posted file a part at a time off the main thread, and Comma's index directories are made so", async () => {
  const file = join(dir, "posted.bin");
  writeFileSync(file, Buffer.alloc(1000, 7));
  const surface = new CommaSurface({ connect: "cm", server: "http://127.0.0.1", token: "test", name: "one", tasks: {} as never, store: {} as never, models: () => [] });
  (surface as any).posting.set("k", { task: "t", files: [{ name: "posted.bin", path: file, size: 1000 }, { name: "gone", path: join(dir, "gone"), size: 1 }] });
  const data = join(dir, "comma-data");
  let part: any, gone: any;
  assert.deepEqual(await syncCalls(async () => {
    part = await (surface as any).handle("task.posted_file", { key: "k", task: "t", index: 0, offset: 400 });
    gone = await (surface as any).handle("task.posted_file", { key: "k", task: "t", index: 1, offset: 0 });
    await CommaStats.makeDirs(data);
  }), []);
  assert.equal(part.size, 1000);
  assert.equal(part.offset, 400);
  assert.equal(Buffer.from(part.data, "base64").length, 600);
  assert.deepEqual(gone, { missing: "no longer on its station" });
  assert.ok((await stat(join(data, "comma-indexes"))).isDirectory());
});

function ed() {
  const { privateKey, publicKey } = generateKeyPairSync("ed25519");
  const hex = (publicKey.export({ format: "der", type: "spki" }) as Buffer).subarray(-32).toString("hex");
  return { hex, id: `ed25519:${hex}`, sign: (bytes: Buffer) => nodeSign(null, bytes, privateKey).toString("hex") };
}

test("a person's lock brought is kept in memory at once and written off the main thread before it is said kept", async () => {
  const path = join(dir, "mesh", "person-chains.json");
  const chains = new PersonChains(path);
  const key = ed(), base = ed();
  const chain: Entry[] = [];
  const add = (kind: string, body: unknown) => {
    const last = chain.at(-1);
    const e = { v: 1, ws: "person:carol", seq: chain.length, prev: last ? entryHash(last) : null, at: 1000, kind, body } as Omit<Entry, "sig">;
    chain.push({ ...e, sig: { key: key.id, alg: "Ed25519", sig: key.sign(signedBytes(entryHash(e as Entry))) } } as Entry);
  };
  add("genesis", { sub: "carol", device: { key: key.id, id: base.hex, label: "first" } });
  const genesis = entryHash(chain[0]!);
  add("device", { key: ed().id, id: ed().hex, label: "d1" });
  assert.deepEqual(await syncCalls(async () => {
    chains.keep(genesis, chain.slice(0, 1), "w1");
    // What is taken next is judged by what was kept, before it is written.
    assert.equal(chains.kept(genesis)?.length, 1);
    chains.keep(genesis, chain, "w1");
    await chains.written();
  }), []);
  assert.equal((await json(path)).chains[genesis].length, 2);
  assert.equal((await stat(path)).mode & 0o777, 0o600);
  assert.deepEqual(new PersonChains(path).heardIn("w1").map(([g, c]) => [g, c.length]), [[genesis, 2]]);
});

test("a person's lock that could not be written is not said kept", async () => {
  const path = join(dir, "unwritable", "person-chains.json");
  // (a directory where the file would go: the rename onto it fails)
  mkdirSync(path, { recursive: true });
  const chains = new PersonChains(path);
  const key = ed(), base = ed();
  const e = { v: 1, ws: "person:dan", seq: 0, prev: null, at: 1000, kind: "genesis", body: { sub: "dan", device: { key: key.id, id: base.hex, label: "first" } } } as Omit<Entry, "sig">;
  const genesis = { ...e, sig: { key: key.id, alg: "Ed25519", sig: key.sign(signedBytes(entryHash(e as Entry))) } } as Entry;
  chains.keep(entryHash(genesis), [genesis], "w1");
  await assert.rejects(chains.written());
  // Kept in memory all the same, and nothing waits on a write that is over.
  assert.equal(chains.kept(entryHash(genesis))?.length, 1);
  await chains.written();
});

test("a bug report reads the log's end off the main thread", async () => {
  const path = join(dir, "stillfail.log");
  writeFileSync(path, "first line\nsecond line\nthird line\n");
  let tail: string | null = null, none: string | null = "";
  assert.deepEqual(await syncCalls(async () => {
    tail = await readTail(path, 20);
    none = await readTail(join(dir, "no.log"), 20);
  }), []);
  assert.equal(tail, "third line\n");
  assert.equal(none, null);
});

test("what a rig was told to run is appended, moved aside past its most and read back off the main thread", async () => {
  const path = join(dir, "rig", "commands.log");
  const line = (key: string) => ({ at: 1, station: "s", session: "c", key, name: "n", command: "make", kind: "task" as const });
  let log: CommandLog | null = null;
  let last: unknown[] = [];
  assert.deepEqual(await syncCalls(async () => {
    log = new CommandLog(path);
    log.add(line("a"));
    await log.written();
  }), []);
  // Past its most (4 MB): the next line goes to a file of its own, the one before moved aside.
  writeFileSync(path, "x".repeat(4 * 1024 * 1024 + 1) + "\n");
  assert.deepEqual(await syncCalls(async () => {
    log!.add(line("b"));
    log!.add(line("c"));
    last = await log!.last(5);
  }), []);
  assert.deepEqual(last.map((c: any) => c.key), ["c", "b"]);
  assert.deepEqual((await readdir(join(dir, "rig"))).sort(), ["commands.log", "commands.log.1"]);
});

test("a heap snapshot is asked for, taken and answered off the main thread", async () => {
  const data = join(dir, "heap");
  let code = -1;
  assert.deepEqual(await syncCalls(async () => {
    const stop = answerHeapRequests(data);
    try {
      code = await heapCommand(data);
    } finally {
      stop();
    }
  }), []);
  assert.equal(code, 0);
  assert.equal((await readdir(join(data, "run"))).filter((n) => n.endsWith(".heapsnapshot")).length, 1);
});
