// What of a list a client does not hold as it is (`changed`: POST /changed/chats, /changed/sessions, /changed/threads)
// by the MoonBit reader (station/mb src/readops/changed.mbt; read/pool.ts MOVED) as the worker reads it, on the same
// database: each list as clients of every set of runtimes see it (sessions and chats' agents of a runtime one does not
// have left out), its rows held as they are, held as they were, held under another key's digest, held as no string,
// not held, and held by ids no list has; and the client shapes' runtime-bearing fields being the ones the program
// knows (`runtime_list`).
import assert from "node:assert/strict";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import { digest } from "../../client/core-ts/src/digest.ts";
import { SHAPES } from "../../client/core-ts/src/shapes/schema.ts";
import { mbReaderBinary } from "../src/read/mb-reader.ts";
import { Readers } from "../src/read/pool.ts";
import { Store, newMessage } from "../src/store/store.ts";
import { REFERENCE, readersOf } from "./reference.ts";

const binary = mbReaderBinary();

test("the client shapes name a runtime where the program looks for one", () => {
  // Every field of the three lists' shapes that holds a RuntimeKind, at any depth (runtime-view.ts walks the same).
  const found: string[] = [];
  const seen = new Set<string>();
  const holds = (ty: unknown, at: string): void => {
    if (ty === "RuntimeKind") return void found.push(at);
    if (typeof ty === "string") {
      if (seen.has(ty)) return;
      seen.add(ty);
      const shape = (SHAPES as Record<string, any>)[ty];
      if (shape?.kind === "struct") for (const f of shape.fields) holds(f.ty, `${ty}.${f.name}`);
      if (shape?.kind === "tagged") for (const [tag, v] of Object.entries(shape.variants)) holds(v, `${ty}<${tag}>`);
      return;
    }
    if (ty !== null && typeof ty === "object") for (const v of Object.values(ty)) (Array.isArray(v) ? v : [v]).forEach((x) => holds(x, at));
  };
  for (const ty of ["Session", "ChatItem", "ChatThread"]) holds(ty, ty);
  // (a chat's row holds its agents, `ChatItem.agents`, each a RowAgent)
  assert.deepEqual(found.sort(), ["RowAgent.runtime", "Session.runtime"]);
});

test("the MoonBit reader reads what of a list changed as the worker does", { skip: binary === null ? "the MoonBit program is not built here" : false }, async () => {
  const data = mkdtempSync(join(tmpdir(), "mb-reader-changed-"));
  const store = Store.open(join(data, "stillfail.db"), join(data, "archive"));
  const session = (key: string, runtime: string, at: number) =>
    store.insertSession({ key, connect: "ember", runtime, profile: "cc", workspace: "/w", token: key, createdAt: 1, lastActiveAt: at, ws: "w" } as Parameters<Store["insertSession"]>[0]);
  session("c1", "claude", 500);
  session("x1", "codex", 400);
  session("g1", "grok", 300);
  session("d1", "dsh", 200);
  let ts = 0;
  const say = (t: number, author: string, text: string, at: number) =>
    store.insertMessage({ ...newMessage(t, String(++ts), "person", author, text), at } as ReturnType<typeof newMessage>);
  const chat = (key: string, title: string, members: string[], at: number, agentLast?: string) => {
    const id = store.openThread("ember", "CHAT", key, title, null).id;
    for (const m of members) store.joinThread(id, m, "ember");
    say(id, "p@x", `hello ${key} "quoted"   é`, at);
    if (agentLast) {
      store.insertMessage({ ...newMessage(id, String(++ts), "agent", agentLast, `reply from ${agentLast}`), at: at + 1 } as ReturnType<typeof newMessage>);
    }
    return id;
  };
  chat("both", "Both", ["c1", "x1"], 100);
  chat("grok", "Grok's", ["g1"], 90, "g1");
  chat("all", "Everyone", ["d1", "c1", "x1", "g1"], 80, "g1");
  chat("none", "Nobody", [], 70);
  const viewer = { email: "p@x", workspace: "w", home: true };
  const worker = new Readers(data, 1, REFERENCE);
  const program = readersOf(data, binary);
  const read = (r: Readers, args: unknown, lang: "zh" | "en") => r.read("changed", args, lang).then((t) => JSON.parse(t), (e: Error & { status?: number }) => ({ error: e.message, status: e.status }));
  const lists: [string, Record<string, unknown>, string][] = [
    ["chats", { viewer, archived: false }, "id"],
    ["sharedChats", { viewer, sessions: null, threads: null }, "id"],
    ["sessions", { connect: null, archived: false, viewer, lang: "en" }, "key"],
    ["sessions", { connect: "ember", archived: true, viewer, lang: "zh" }, "key"],
    ["threads", { viewer, session: null, lang: "en" }, "id"],
    ["threads", { viewer, session: "c1", lang: "zh" }, "id"],
  ];
  const runtimes = [undefined, [], ["claude"], ["claude", "codex"], ["claude", "codex", "grok", "dsh"]];
  const all = async (r: Readers) => {
    const out: unknown[] = [];
    for (const lang of ["zh", "en"] as const) {
      for (const [op, args, id] of lists) {
        // what this list is, read whole by the worker, as a client holds it: some rows as they are, one as it was,
        // one under another's digest, one held as no string, and ids of none
        const whole = JSON.parse(await worker.read(op, args, lang)) as Record<string, unknown>[];
        const held: Record<string, unknown> = { gone: "abc", "": 1 };
        whole.forEach((row, i) => {
          const key = String(row[id]);
          if (i % 4 === 0) held[key] = digest(row);
          else if (i % 4 === 1) held[key] = digest({ ...row, changedHere: true });
          else if (i % 4 === 2) held[key] = digest(whole[0]);
          else held[key] = 7;
        });
        for (const rt of runtimes) out.push(await read(r, { op, args, id, held, runtimes: rt }, lang));
        out.push(await read(r, { op, args, id: "nope", held }, lang));
      }
    }
    return out;
  };
  try {
    const first = await all(program);
    assert.deepEqual(first, await all(worker));
    const said = JSON.stringify(first);
    for (const sign of ["\"order\":[", "\"rows\":[]", "Everyone", "\"runtime\":\"grok\""]) assert.ok(said.includes(sign), sign);
    // Consecutive POST /changed/shared with digests computed from actual production whole projection
    // (`station/src/read/runtime-view.ts`, which filters only `agents` and preserves `last.authorRuntime`)
    // must return 0 rows for both full and restricted runtime capability sets.
    const { runtimeView } = await import("../src/read/runtime-view.ts");
    const wholeRaw = JSON.parse(await program.read("sharedChats", { viewer, sessions: null, threads: null }, "en")) as Record<string, any>[];
    for (const rt of [["claude"], ["claude", "codex", "grok", "dsh"]]) {
      const projected = runtimeView({ vec: "ChatItem" }, wholeRaw, new Set(rt)) as Record<string, any>[];
      const grokRow = projected.find((row) => row.id === "g1");
      assert.equal(grokRow?.last?.authorRuntime, "grok", "production whole preserves last.authorRuntime");
      if (rt.includes("grok")) assert.equal(grokRow?.agents?.length, 1);
      else assert.equal(grokRow?.agents?.length, 0, "unsupported agent filtered out of agents");
      const held = Object.fromEntries(projected.map((row) => [String(row.id), digest(row)]));
      const delta = await read(program, { op: "sharedChats", args: { viewer, sessions: null, threads: null }, id: "id", held, runtimes: rt }, "en");
      assert.deepEqual(delta.rows, [], `consecutive changed/shared with production whole digests returns 0 rows for runtimes=${rt.join(",")}`);
      assert.equal(delta.order.length, projected.length);
    }
  } finally {
    worker.close(); program.close();
    store.close();
    rmSync(data, { recursive: true, force: true });
  }
});

test("chatMarks own=1 returns only the 7 viewer fields and both own/legacy filter scoped threads and whole pins by viewer workspace", { skip: binary === null ? "the MoonBit program is not built here" : false }, async () => {
  const data = mkdtempSync(join(tmpdir(), "mb-reader-marks-perm-"));
  const store = Store.open(join(data, "stillfail.db"), join(data, "archive"));
  const session = (key: string, ws: string | null, at: number) =>
    store.insertSession({ key, connect: "ember", runtime: "claude", profile: "cc", workspace: "/w", token: key, createdAt: 1, lastActiveAt: at, ws } as Parameters<Store["insertSession"]>[0]);
  session("sa", "ws-a", 500);
  session("sb", "ws-b", 400);
  let ts = 0;
  const say = (t: number, author: string, text: string, at: number) =>
    store.insertMessage({ ...newMessage(t, String(++ts), "person", author, text), at } as ReturnType<typeof newMessage>);
  const chat = (key: string, title: string, member: string, at: number) => {
    const id = store.openThread("ember", "CHAT", key, title, null).id;
    store.joinThread(id, member, "ember");
    say(id, "p@x", `hello ${key}`, at);
    return id;
  };
  const ta = chat("a", "A", "sa", 100);
  const tb = chat("b", "B", "sb", 90);
  // Seed marks for viewer p@x in both ws-a and ws-b (synthetic permission fixture).
  store.db.prepare("INSERT OR REPLACE INTO reads (viewer, thread, n, at) VALUES (?, ?, ?, ?)").run("p@x", ta, 1, 10);
  store.db.prepare("INSERT OR REPLACE INTO reads (viewer, thread, n, at) VALUES (?, ?, ?, ?)").run("p@x", tb, 1, 20);
  store.db.prepare("INSERT OR REPLACE INTO pins (viewer, session, at) VALUES (?, ?, ?)").run("p@x", "sa", 10);
  store.db.prepare("INSERT OR REPLACE INTO pins (viewer, session, at) VALUES (?, ?, ?)").run("p@x", "sb", 20);
  store.db.prepare("INSERT OR REPLACE INTO kept_chats (viewer, thread) VALUES (?, ?)").run("p@x", ta);
  store.db.prepare("INSERT OR REPLACE INTO kept_chats (viewer, thread) VALUES (?, ?)").run("p@x", tb);
  store.db.prepare("INSERT OR REPLACE INTO hidden_chats (viewer, thread) VALUES (?, ?)").run("p@x", ta);
  store.db.prepare("INSERT OR REPLACE INTO hidden_chats (viewer, thread) VALUES (?, ?)").run("p@x", tb);
  store.db.prepare("INSERT OR REPLACE INTO muted_chats (viewer, thread) VALUES (?, ?)").run("p@x", ta);
  store.db.prepare("INSERT OR REPLACE INTO muted_chats (viewer, thread) VALUES (?, ?)").run("p@x", tb);
  store.db.prepare("INSERT OR REPLACE INTO dismissed (viewer, thread, n, at) VALUES (?, ?, ?, ?)").run("p@x", ta, 1, 10);
  store.db.prepare("INSERT OR REPLACE INTO dismissed (viewer, thread, n, at) VALUES (?, ?, ?, ?)").run("p@x", tb, 1, 20);

  const viewerA = { email: "p@x", workspace: "ws-a", home: false };
  const worker = new Readers(data, 1, REFERENCE);
  const program = readersOf(data, binary);
  try {
    for (const own of [true, false]) {
      // Whole marks: ws-b pin & thread marks must not leak to ws-a viewer.
      const wWhole = JSON.parse(await worker.read("chatMarks", { viewer: viewerA, scope: null, own }, "en")) as Record<string, any>;
      const pWhole = JSON.parse(await program.read("chatMarks", { viewer: viewerA, scope: null, own }, "en")) as Record<string, any>;
      assert.deepEqual(pWhole, wWhole, `whole chatMarks parity (own=${own})`);
      assert.deepEqual(Object.keys(pWhole.pins), ["sa"], `whole pins filtered by viewer ws (own=${own})`);
      assert.deepEqual(Object.keys(pWhole.reads), [String(ta)], `whole reads filtered by viewer ws (own=${own})`);
      assert.deepEqual(pWhole.kept, [ta]);
      assert.deepEqual(pWhole.hidden, [ta]);
      assert.deepEqual(pWhole.muted, [ta]);
      assert.deepEqual(pWhole.dismissed, [`${ta}:1`]);
      if (own) {
        assert.deepEqual(Object.keys(pWhole).sort(), ["dismissed", "hidden", "kept", "muted", "pins", "reads", "selves"]);
      } else {
        assert.ok("card" in pWhole && "need" in pWhole && "openers" in pWhole);
      }

      // Scoped marks requesting forbidden ws-b thread & session directly: must be filtered out.
      const scope = { sessions: ["sb"], threads: [tb] };
      const wScoped = JSON.parse(await worker.read("chatMarks", { viewer: viewerA, scope, own }, "en")) as Record<string, any>;
      const pScoped = JSON.parse(await program.read("chatMarks", { viewer: viewerA, scope, own }, "en")) as Record<string, any>;
      assert.deepEqual(pScoped, wScoped, `scoped chatMarks parity (own=${own})`);
      assert.deepEqual(pScoped.pins, {});
      assert.deepEqual(pScoped.reads, {});
      assert.deepEqual(pScoped.kept, []);
      assert.deepEqual(pScoped.hidden, []);
      assert.deepEqual(pScoped.muted, []);
      assert.deepEqual(pScoped.dismissed, []);
      if (own) {
        assert.deepEqual(Object.keys(pScoped).sort(), ["dismissed", "hidden", "kept", "muted", "pins", "reads", "selves"]);
      }
    }
  } finally {
    worker.close(); program.close();
    store.close();
    rmSync(data, { recursive: true, force: true });
  }
});
