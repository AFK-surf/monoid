// A queued card outcome's pages read by the MoonBit reader (station/mb src/readops/cardpages.mbt; read/pool.ts MOVED)
// as the reader thread read them (store/card-outbox.ts `cardEditPage`, `cardMessagePage`): byte for byte, page after
// page, on a chat with none, one with a card edited among many entries (pages of 64 and 512), one whose target is
// never edited (paged to its end), with `entries_cards` and without it.
import assert from "node:assert/strict";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import { mbReaderBinary } from "../src/read/mb-reader.ts";
import { Readers } from "../src/read/pool.ts";
import { Store } from "../src/store/store.ts";
import { REFERENCE_WORKER, readersOf } from "./reference.ts";

const binary = mbReaderBinary();

test("the MoonBit reader pages a queued card's edits and messages as the reader thread does", { skip: binary === null ? "the MoonBit program is not built here" : false }, async () => {
  const data = mkdtempSync(join(tmpdir(), "mb-reader-card-pages-"));
  const store = Store.open(join(data, "stillfail.db"), join(data, "archive"));
  const db = store.db;
  const chat = (name: string) => store.openThread("ember", "CHAT", name, name, null).id;
  const empty = chat("empty"), long = chat("long"), plain = chat("plain");
  // `long`: its card at 1, an edit with a card at 2, 80 edits of its text, 80 cards of other messages, then 1,100
  // messages: a message page of 512 three times over, an edit page of 64 more than once.
  db.prepare(`INSERT INTO entries(thread,n,kind,ts,author_kind,author,text,at,card) VALUES(?,1,'message','card','agent','a','question',1,?)`)
    .run(long, JSON.stringify({ type: "text", adb: { reason: "original" } }));
  const edit = db.prepare("INSERT INTO entries(thread,n,kind,target,author_kind,author,text,at,card) VALUES(?,?,'edit',?,'agent','a',?,?,?)");
  edit.run(long, 2, 1, "old card", 2, JSON.stringify({ type: "text", adb: { reason: "old card" } }));
  for (let n = 3; n <= 82; n++) edit.run(long, n, 1, `text ${n}`, n, null);
  for (let n = 83; n <= 162; n++) edit.run(long, n, n + 1000, "other", n, JSON.stringify({ type: "text" }));
  const message = db.prepare("INSERT INTO entries(thread,n,kind,ts,author_kind,author,text,at) VALUES(?,?,'message',?,'person','p','hi',?)");
  for (let n = 163; n <= 1262; n++) message.run(long, n, `m${n}`, n);
  for (let n = 1; n <= 700; n++) message.run(plain, n, `p${n}`, n);
  const worker = new Readers(data, 1, REFERENCE_WORKER);
  const program = readersOf(data, binary);
  const raw = (readers: Readers, op: string, args: unknown) => readers.read(op, args, "en").catch((e: Error & { status?: number }) => `error ${e.status} ${e.message}`);
  /// Every page of one search, newest first, as each reader said it.
  const paged = async (readers: Readers, op: string, thread: number, target: string) => {
    const pages: string[] = [];
    let before: string | null = null;
    for (;;) {
      const text = await raw(readers, op, { thread, target, before });
      pages.push(text);
      const page = JSON.parse(text) as { kind: string; before?: string };
      if (page.kind !== "next") return pages;
      before = page.before!;
    }
  };
  const searches: [string, number, string][] = [
    ["internalCardEditPage", empty, "1"], ["internalCardMessagePage", empty, "1"],
    ["internalCardEditPage", long, "1"], ["internalCardEditPage", long, "999"], ["internalCardEditPage", long, "1083"],
    ["internalCardMessagePage", long, "1"], ["internalCardMessagePage", long, "999"], ["internalCardMessagePage", long, "5"],
    ["internalCardEditPage", plain, "1"], ["internalCardMessagePage", plain, "1"], ["internalCardMessagePage", plain, "700000"],
    ["internalCardEditPage", 424242, "1"], ["internalCardMessagePage", 424242, "1"],
  ];
  const all = async (readers: Readers) => {
    const out: string[][] = [];
    for (const [op, thread, target] of searches) out.push(await paged(readers, op, thread, target));
    // a cursor given (one of the middle of the chat)
    out.push([await raw(readers, "internalCardEditPage", { thread: long, target: "1", before: "100" })]);
    out.push([await raw(readers, "internalCardMessagePage", { thread: long, target: "1", before: "1" })]);
    return out;
  };
  try {
    const indexed = await all(program);
    assert.deepEqual(indexed, await all(worker));
    const kinds = indexed.flat().map((t) => JSON.parse(t).kind);
    for (const kind of ["found", "next", "end"]) assert.ok(kinds.includes(kind), kind);
    assert.ok(indexed.some((pages) => pages.length >= 3), "a search of three pages or more");
    assert.ok(indexed.flat().includes(JSON.stringify({ kind: "found", card: JSON.stringify({ type: "text", adb: { reason: "old card" } }) })));
    // Without the index of cards: every entry is a candidate.
    db.exec("DROP INDEX entries_cards");
    const unindexed = await all(program);
    assert.deepEqual(unindexed, await all(worker));
    assert.notDeepEqual(unindexed, indexed);
  } finally {
    worker.close(); program.close();
    store.close();
    rmSync(data, { recursive: true, force: true });
  }
});
