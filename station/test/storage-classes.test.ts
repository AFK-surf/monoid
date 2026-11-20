// What the station keeps in <data> (src/ops/storage.ts): every name its code joins onto the data directory is in
// STORAGE_MANIFEST with its class, so a new one says what bounds it or CI fails here; and the upkeep holds what is
// bounded to its bound while it never touches what is authoritative.
import assert from "node:assert/strict";
import { mkdirSync, readdirSync, readFileSync, statSync, utimesSync, writeFileSync, existsSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, relative } from "node:path";
import { describe, test } from "node:test";
import { fileURLToPath } from "node:url";
import {
  CONFIG_BACKUPS_KEPT, STATION_LOG_CAP, STORAGE_MANIFEST, THUMBS_CAP, UPKEEP_FIRST_MS, Upkeep, WAL_CAP, capByAge, keepNewest, orphanMarks, removeStale,
  storageEntry, treeBytes, walCheckpoint,
} from "../src/ops/storage.ts";
import { testClock } from "./hub-fakes.ts";
import { readersOf } from "./reference.ts";
import { mbReaderBinary } from "../src/read/mb-reader.ts";
import { Store } from "../src/store/store.ts";
import { tempDir } from "./temp-dir.ts";

const src = join(dirname(fileURLToPath(import.meta.url)), "..", "src");

/// Every `.ts` file under `dir`.
function sources(dir: string): string[] {
  return readdirSync(dir, { withFileTypes: true }).flatMap((d) => (d.isDirectory() ? sources(join(dir, d.name)) : d.name.endsWith(".ts") ? [join(dir, d.name)] : []));
}

/// The names the station's code joins onto its data directory: `join(<…data…>, "name…")` and `resolve(…)` as written,
/// `<…data…>` an expression ending in `data` or `dataDir` (`data`, `this.data`, `this.#data`, `options.data`,
/// `this.config().dataDir`, …); the first part of a literal path.
function joinedOntoData(): { name: string; at: string }[] {
  const found: { name: string; at: string }[] = [];
  const re = /\b(?:join|resolve)\(\s*([\w.#$()]*?(?:\b|#|\.)(?:data|dataDir))\s*,\s*(["'`])([^"'`$]+)\2/g;
  for (const file of sources(src)) {
    const text = readFileSync(file, "utf8");
    for (const m of text.matchAll(re)) {
      const name = m[3]!.split(/[\\/]/)[0]!;
      if (name === "" || name === "." || name === "..") continue;
      const line = text.slice(0, m.index).split("\n").length;
      found.push({ name, at: `${relative(src, file)}:${line}` });
    }
  }
  return found;
}

describe("<data>'s manifest", () => {
  test("every name the station joins onto its data directory is listed, with its class", () => {
    const found = joinedOntoData();
    assert.ok(found.length > 40, `the scan finds the station's names (${found.length})`);
    const missing = found.filter((f) => storageEntry(f.name) === undefined);
    assert.deepEqual(missing, [], "each name joined onto <data> is in src/ops/storage.ts STORAGE_MANIFEST, with what bounds it");
  });

  test("each entry says its class, and a bounded one what holds it", () => {
    const names = new Set<string>();
    for (const e of STORAGE_MANIFEST) {
      assert.ok(!names.has(e.name), `${e.name} once`);
      names.add(e.name);
      assert.ok(["authoritative", "session-bound", "bounded-ephemeral"].includes(e.class), e.name);
      if (e.class !== "authoritative") assert.ok(e.maxBytes !== undefined || e.maxAgeMs !== undefined || e.reclaim !== undefined, `${e.name}: its bound or what holds it`);
    }
    for (const lasting of ["stillfail.db", "config.json", "transcripts", "uploads", "homes"]) assert.equal(storageEntry(lasting)?.class, "authoritative", lasting);
    assert.equal(storageEntry("repos")?.class, "session-bound");
    assert.equal(storageEntry("config.json.bak-1794678500")?.class, "bounded-ephemeral");
  });
});

describe("the upkeep", () => {
  const MiB = 1024 ** 2;

  test("thumbnails are held to their bound, the longest unchanged first", async () => {
    const dir = join(tempDir(join(tmpdir(), "up-")), "thumbs");
    mkdirSync(dir);
    for (let i = 0; i < 5; i++) {
      writeFileSync(join(dir, `t${i}.jpg`), Buffer.alloc(MiB, 1));
      utimesSync(join(dir, `t${i}.jpg`), 1000 + i, 1000 + i);
    }
    const freed = await capByAge(dir, 3 * MiB);
    assert.ok(freed >= 2 * MiB);
    assert.deepEqual(readdirSync(dir).sort(), ["t2.jpg", "t3.jpg", "t4.jpg"], "the two oldest went");
    assert.equal(await capByAge(dir, 3 * MiB), 0, "within its bound: nothing");
  });

  test("of config.json's copies of before, the newest are kept; config.json itself never", async () => {
    const data = tempDir(join(tmpdir(), "up-"));
    writeFileSync(join(data, "config.json"), "{}");
    for (let i = 0; i < 6; i++) {
      writeFileSync(join(data, `config.json.bak-${i}`), "{}");
      utimesSync(join(data, `config.json.bak-${i}`), 1000 + i, 1000 + i);
    }
    const gone = await keepNewest(data, "config.json.bak-", CONFIG_BACKUPS_KEPT);
    assert.deepEqual(gone.sort(), ["config.json.bak-0", "config.json.bak-1", "config.json.bak-2"]);
    assert.ok(existsSync(join(data, "config.json")));
  });

  test("half-done downloads of Node go once old; a fresh one and Node itself stay", async () => {
    const node = join(tempDir(join(tmpdir(), "up-")), "node");
    mkdirSync(join(node, "v24.22.1"), { recursive: true });
    mkdirSync(join(node, ".part-v24.23.0.123"));
    mkdirSync(join(node, ".part-v24.23.0.456"));
    utimesSync(join(node, ".part-v24.23.0.123"), 1, 1);
    utimesSync(join(node, "v24.22.1"), 1, 1);
    const gone = await removeStale(node, ".part-", 3600_000, statSync(join(node, ".part-v24.23.0.456")).mtimeMs + 1000);
    assert.deepEqual(gone, [".part-v24.23.0.123"]);
    assert.deepEqual(readdirSync(node).sort(), [".part-v24.23.0.456", "v24.22.1"]);
  });

  test("readings of transcripts gone go; those of transcripts there stay", async () => {
    const data = tempDir(join(tmpdir(), "up-"));
    const marks = join(data, "transcript-marks");
    mkdirSync(marks);
    writeFileSync(join(data, "t.jsonl"), "{}\n");
    writeFileSync(join(marks, "a.json"), JSON.stringify({ reading: 1, state: { path: join(data, "t.jsonl") }, marks: [] }));
    writeFileSync(join(marks, "b.json"), JSON.stringify({ reading: 1, state: { path: join(data, "gone.jsonl") }, marks: [] }));
    writeFileSync(join(marks, "c.json"), "not json");
    assert.deepEqual((await orphanMarks(marks)).sort(), ["b.json", "c.json"]);
    assert.deepEqual(readdirSync(marks), ["a.json"]);
  });

  test("the database's log past its bound is written into the database once, and only then", async () => {
    const data = tempDir(join(tmpdir(), "up-"));
    const wal = join(data, "stillfail.db-wal");
    let asked = 0;
    writeFileSync(wal, Buffer.alloc(1024));
    assert.equal(await walCheckpoint(wal, async () => void asked++), false);
    writeFileSync(wal, Buffer.alloc(WAL_CAP + 1));
    assert.equal(await walCheckpoint(wal, async () => (asked++, writeFileSync(wal, ""), [0, 0, 0])), true);
    assert.equal(asked, 1);
  });

  for (const mb of [true, false]) test(`the database's log past its bound is cut to nothing by the readers' checkpoint (${mb ? "the MoonBit program's" : "the reader thread's"})`, { skip: mb && mbReaderBinary() === null && "the MoonBit reader is not built here" }, async () => {
    const data = tempDir(join(tmpdir(), "wal-"));
    const store = Store.open(join(data, "stillfail.db"), join(data, "archive"));
    const readers = readersOf(data, mb ? mbReaderBinary() : null);
    try {
      for (let i = 0; i < 200; i++) store.recordProcess(100_000 + i, i, "job", `job: ${"x".repeat(200)}`);
      const wal = join(data, "stillfail.db-wal");
      assert.ok(statSync(wal).size > 0, "the log has what was written");
      assert.equal(await walCheckpoint(wal, () => readers.checkpointHard()), false, "within its bound: not asked");
      await readers.checkpointHard();
      assert.equal(statSync(wal).size, 0, "all of it written in, its file cut");
      assert.equal(store.listProcesses().length, 200, "nothing lost");
    } finally {
      readers.close();
      store.close();
    }
  });

  test("a round on its clock: logs cut where they are, caches held, what is authoritative untouched", async () => {
    const data = tempDir(join(tmpdir(), "up-"));
    for (const d of ["thumbs", "transcript-marks", "transcripts", "uploads", "homes", "repos", "run", "node"]) mkdirSync(join(data, d));
    const lasting = { "stillfail.db": "db", "config.json": "{}", "transcripts/a.jsonl": "{}\n", "uploads/a.png": "png", "homes/x": "x", "repos/r": "r" };
    for (const [p, text] of Object.entries(lasting)) writeFileSync(join(data, p), text);
    for (const p of ["transcripts/a.jsonl", "uploads/a.png", "homes/x", "repos/r", "stillfail.db"]) utimesSync(join(data, p), 1, 1);
    writeFileSync(join(data, "stillfail.log"), Buffer.alloc(STATION_LOG_CAP + 10, 0x61));
    writeFileSync(join(data, "thumbs", "old.jpg"), Buffer.alloc(THUMBS_CAP + 1));
    const time = testClock();
    const said: string[] = [];
    const upkeep = new Upkeep({ data, clock: time.clock, runners: async () => void said.push("runners"), jobs: async () => void said.push("jobs"), remote: async () => void said.push("remote") });
    upkeep.start();
    await time.begun(1);
    assert.deepEqual(said, [], "nothing before its first round is due");
    await time.adjust(UPKEEP_FIRST_MS);
    // Its round done, the next is waited for.
    await time.begun(2);
    assert.equal(statSync(join(data, "stillfail.log")).size, 0, "the station's log cut");
    assert.equal(statSync(join(data, "stillfail.log.1")).size, STATION_LOG_CAP, "its last cap kept");
    assert.deepEqual(readdirSync(join(data, "thumbs")), [], "thumbnails over their bound gone");
    assert.deepEqual(said, ["runners", "jobs", "remote"]);
    for (const [p, text] of Object.entries(lasting)) assert.equal(readFileSync(join(data, p), "utf8"), text, `${p} untouched`);
    await upkeep.close();
  });

  test("a tree's bytes, links not followed", async () => {
    const dir = tempDir(join(tmpdir(), "up-"));
    mkdirSync(join(dir, "a", "b"), { recursive: true });
    writeFileSync(join(dir, "a", "b", "f"), Buffer.alloc(64 * 1024, 1));
    const t = await treeBytes(dir);
    assert.ok(t.bytes >= 64 * 1024 && !t.partial);
    assert.equal((await treeBytes(dir, 2)).partial, true);
  });
});
