// One chat of a station that does not answer gone on with on another station from its copy (replica/handoff.ts,
// chat.ts, `replica.chat`), over a mesh of the test's (a station away fails what is asked of it) and on its clock: the
// chat's copy reaches the stations that keep it, its station goes away, and a member asks another station to go on with
// it. A new chat of that member's opens there, its first message a handoff prompt with the chat's messages and what is
// not there. Refused in words while the chat's station answers, where no station keeps a copy of it, where the copy
// does not hold the chat, and (to be asked again) where a keeper's reading fails. Read where the newest copy is.
import assert from "node:assert/strict";
import { mkdir, writeFile } from "node:fs/promises";
import { join } from "node:path";
import { DatabaseSync } from "node:sqlite";
import { afterEach, test } from "node:test";
import { Effect, Exit, Scope, type Clock } from "effect";
import { TestClock } from "effect/testing";
import { PeerBus, bytesOf, withBytes } from "../src/mesh/bus.ts";
import { Fibers } from "../src/ops/fibers.ts";
import { mbReaderBinary } from "../src/read/mb-reader.ts";
import { newestWhole } from "../src/replica/chat.ts";
import { Copies } from "../src/replica/copies.ts";
import { type HandedOff, type HandoffDeps, HandoffRefused, Handoffs, openHandoffChat } from "../src/replica/handoff.ts";
import { keepers, ranked } from "../src/replica/peers.ts";
import { Store } from "../src/store/store.ts";
import { Rig, settle } from "./hub-fakes.ts";
import { InlineRunner } from "./reference/replica-work.ts";
import { HOME, dataDir, station } from "./replica-fakes.ts";

type Json = any;
const binary = mbReaderBinary();
const skip = binary === null ? "the MoonBit program is not built here (station/mb/build.sh)" : false;

const scopes: Scope.Closeable[] = [];
const closing: (() => Promise<void>)[] = [];
afterEach(async () => {
  for (const c of closing.splice(0).reverse()) await c().catch(() => {});
  for (const s of scopes.splice(0)) await Effect.runPromise(Scope.close(s, Exit.void));
});

function testClock(): Clock.Clock {
  const scope = Effect.runSync(Scope.make());
  scopes.push(scope);
  return Effect.runSync(Scope.provide(TestClock.make(), scope));
}

/// What crosses the mesh: its JSON as a copy, the bytes after it as they are.
function across(v: Json): Json {
  const bytes = bytesOf(v);
  const copy = JSON.parse(JSON.stringify(v));
  return bytes === null ? copy : withBytes(copy, bytes);
}

type Node = { id: string; data: string; store: Store; copies: Copies; up: boolean; bus: PeerBus };

/// A workspace's stations on the test's mesh, all of HOME, its roster `roster`.
class Mesh {
  readonly nodes = new Map<string, Node>();
  roster: string[] = [];
  readonly clock = testClock();
  /// The requests each station was asked, by method.
  readonly asked = new Map<string, Map<string, number>>();

  add(id: string, made?: { data: string; store: Store; own?: boolean }): Node {
    const data = made?.data ?? dataDir(id.slice(0, 4));
    const store = made?.store ?? Store.open(join(data, "stillfail.db"), join(data, "archive"));
    const bus = new PeerBus({ sleep: async () => {} });
    const fibers = new Fibers("copies", this.clock);
    const node = { id, data, store, up: true, bus } as Node;
    bus.attach(async (to, ws, request) => {
      let m = this.asked.get(to);
      if (m === undefined) this.asked.set(to, (m = new Map()));
      m.set(String(request?.method), (m.get(String(request?.method)) ?? 0) + 1);
      const there = this.nodes.get(to);
      if (there === undefined || !there.up || !node.up) throw new Error("station unreachable");
      if (ws !== null && !this.roster.includes(id)) throw new Error("peer is not another station in this workspace");
      return across(await there.bus.handle(ws ?? "", id, across(request)));
    });
    const runner = new InlineRunner({ db: join(data, "stillfail.db"), replica: join(data, "replica"), dataDir: data, origin: id, now: () => this.clock.currentTimeMillisUnsafe() });
    node.copies = new Copies({
      data,
      here: () => id,
      places: () => ({ home: HOME, workspaces: [{ workspace: HOME, name: `${id.slice(0, 4)} in ${HOME}` }] }),
      roster: () => this.roster.map((s) => ({ id: s, name: s.slice(0, 4) })),
      ask: (s, r) => bus.ask(s, r),
      runner,
      fibers,
      changed: () => {},
      restart: async () => null,
      chatBinary: binary ?? undefined,
    });
    bus.on("replica.", node.copies.answers());
    store.subscribe((c) => node.copies.told(c));
    this.nodes.set(id, node);
    closing.push(async () => {
      await node.copies.close();
      await runner.close();
      await fibers.close();
      // (a rig's store is the rig's to close)
      if (made?.own !== false) {
        try { store.close(); } catch {}
      }
    });
    return node;
  }

  async settle(): Promise<void> {
    for (let i = 0; i < 3; i++) for (const n of this.nodes.values()) if (n.up) await n.copies.settle();
  }
}

const id = (c: string) => c.repeat(64);

/// Station A with its chats, B a station with a hub (where the chat goes on), and two more; B one of those that keep
/// A's copy, or not (`bKeeps`). Every station started and A's copy at its keepers.
async function workspace(bKeeps: boolean) {
  const mesh = new Mesh();
  const A = id("a");
  // (B, C and D in the order they keep A's copies: B first where it keeps one, last where it does not)
  const order = ranked(HOME, A, [id("b"), id("c"), id("d")]);
  const B = bKeeps ? order[0]! : order[2]!;
  const others = order.filter((s) => s !== B);
  // (E is a station never seen: none keeps a copy of its)
  const E = id("e");
  mesh.roster = [A, B, ...others];
  const made = station();
  const a = mesh.add(A, made);
  const rig = new Rig({ workspaces: [HOME] });
  closing.push(() => rig.close());
  const b = mesh.add(B, { data: rig.dir, store: rig.store, own: false });
  for (const s of others) mesh.add(s);
  for (const n of mesh.nodes.values()) await n.copies.start();
  await mesh.settle();
  const keptBy = keepers(HOME, A, mesh.roster);
  assert.equal(keptBy.includes(B), bKeeps);
  const thread = made.store.sessionThreads("chat:a")[0]!.thread.id;
  const deps: HandoffDeps = { here: () => B, attached: () => true, roster: () => mesh.roster.map((s) => ({ id: s, name: s.slice(0, 4) })), ask: (s, r) => b.bus.ask(s, r), copies: b.copies, open: (o) => openHandoffChat(rig.hub, o) };
  const handoffs = new Handoffs(deps);
  const ask = (origin: string, t: number, key: string | null = null, by = handoffs) => by.ask({ ws: HOME, origin, thread: t, by: "q@x", lang: "en", runtime: null, model: null, key });
  return { mesh, A, B, E, a, b, rig, made, thread, keptBy, ask, deps, before: opened(rig, 0).threads };
}

/// What a refusal said, and its status.
async function refused(p: Promise<HandedOff>): Promise<{ status: number; message: string }> {
  try {
    await p;
  } catch (e) {
    assert.ok(e instanceof HandoffRefused, `a refusal, not ${(e as Error).message}`);
    return { status: e.status, message: e.message };
  }
  assert.fail("it was not refused");
}

/// The rows of the chat B opened: its thread and its entries, as B's database holds them.
function opened(rig: Rig, thread: number) {
  const db = new DatabaseSync(join(rig.dir, "stillfail.db"), { readOnly: true });
  try {
    const t = db.prepare("SELECT title, surface FROM threads WHERE id = ?").get(thread) as Json;
    const entries = db.prepare("SELECT author_kind, author, text FROM entries WHERE thread = ? ORDER BY n").all(thread) as Json[];
    const threads = (db.prepare("SELECT COUNT(*) AS n FROM threads").get() as Json).n as number;
    return { t, entries, threads };
  } finally {
    db.close();
  }
}

test("an away station's chat goes on on another station from the copy a keeper holds, in a new chat with a handoff prompt", { skip }, async () => {
  const w = await workspace(false);
  // (A answers: the chat goes on there, nothing read of its copy)
  const up = await refused(w.ask(w.A, w.thread));
  assert.equal(up.status, 409);
  assert.match(up.message, /aaaa answers, so the chat goes on there: open it on aaaa, or move it to this station/);
  assert.equal(opened(w.rig, 0).threads, w.before, "no chat opened while A answers");
  assert.equal([...w.mesh.asked.values()].some((m) => m.has("replica.chat")), false);

  // A station whose copy no station keeps (every station that could keep one answers that it keeps none)
  const none = await refused(w.ask(w.E, 1));
  assert.equal(none.status, 404);
  assert.match(none.message, /No station keeps a backup of eeeeeeee's chats, so this chat cannot go on from one: open it on eeeeeeee once it is back/);

  // A goes away; B keeps no copy of it, and asks the station that keeps it first
  w.a.up = false;
  w.mesh.asked.clear();
  const done = await w.ask(w.A, w.thread);
  await settle();
  assert.equal(done.keptBy, w.keptBy.find((s) => s !== w.B), "read where the copy is kept, in the order of its keepers");
  assert.equal(w.mesh.asked.get(done.keptBy)?.get("replica.chat"), 1);
  assert.equal(done.title, "Chat chat:a");
  const { t, entries, threads } = opened(w.rig, done.thread);
  assert.equal(threads, w.before + 1, "one chat more on B: the new one, none of A's rows");
  assert.equal(t.title, "Chat chat:a");
  assert.equal(t.surface, "chat");
  assert.equal(entries.length, 1, "its first message, the prompt");
  const [first] = entries;
  assert.equal(first.author_kind, "person");
  assert.equal(first.author, "q@x", "said as the member who asked");
  const text = first.text as string;
  for (const said of [
    `This chat continues the chat "Chat chat:a" of station aaaa (chat ${w.thread} there). Station aaaa does not answer now`,
    "from the backup of it that station",
    "Station aaaa may still be running. This chat and that one go on apart from here",
    "The working directory stayed on station aaaa: its files, its branches and the commits it did not push are not on this station.",
    "The chat's agents on station aaaa:",
    "- claude, working in ",
    "chat:a says 1",
    "chat:a says 29",
    // (the first message as it was edited)
    " (edited):\nedited words",
    "(files attached there, not on this station: pic.png)",
  ]) assert.ok(text.includes(said), `the prompt says ${JSON.stringify(said)}:\n${text}`);
  assert.ok(text.indexOf("chat:a says 1") < text.indexOf("chat:a says 29"), "oldest first");
  // (another workspace's chat, the deleted one and the archived one are not in it)
  for (const not of ["chat:o says", "chat:gone says", "chat:b says"]) assert.equal(text.includes(not), false, not);

  // A chat A's copy does not hold
  const noChat = await refused(w.ask(w.A, 987_654));
  assert.equal(noChat.status, 404);
  assert.match(noChat.message, /aaaa's backup does not hold this chat .*open it on aaaa once it is back/);

  // This station's own chat
  const here = await refused(w.ask(w.B, 1));
  assert.equal(here.status, 400);
  assert.match(here.message, /This chat is on this station/);
});

test("a station that keeps the away station's copy reads the chat from its own disk, asking no other", { skip }, async () => {
  const w = await workspace(true);
  w.a.up = false;
  const done = await w.ask(w.A, w.thread);
  await settle();
  assert.equal(done.keptBy, w.B);
  assert.equal([...w.mesh.asked.values()].some((m) => m.has("replica.chat")), false, "no other station asked for the chat");
  const { entries } = opened(w.rig, done.thread);
  assert.ok((entries[0]!.text as string).includes("chat:a says 29"));
  assert.ok((entries[0]!.text as string).includes(`from the backup of it that station ${w.B.slice(0, 4)} keeps`));
});

test("a handoff asked again with the same key gives the chat it opened, not a second one", { skip }, async () => {
  const w = await workspace(true);
  w.a.up = false;
  // (asked twice at once, as a second press would)
  const [one, two] = await Promise.all([w.ask(w.A, w.thread, "key-1"), w.ask(w.A, w.thread, "key-1")]);
  await settle();
  assert.equal(two.session, one.session);
  assert.equal(two.thread, one.thread);
  // (asked again once it is done, as a retry after a lost answer)
  const again = await w.ask(w.A, w.thread, "key-1");
  assert.equal(again.session, one.session);
  // (asked of the station started again, its memory of the key gone: the chat's own key finds it, said into once)
  const later = await w.ask(w.A, w.thread, "key-1", new Handoffs(w.deps));
  await settle();
  assert.equal(later.session, one.session);
  assert.equal(later.thread, one.thread);
  assert.equal(opened(w.rig, one.thread).entries.length, 1, "the prompt said once");
  assert.equal(opened(w.rig, 0).threads, w.before + 1, "one chat opened for the key");
  // (another key: another chat)
  const other = await w.ask(w.A, w.thread, "key-2");
  await settle();
  assert.notEqual(other.session, one.session);
  assert.equal(opened(w.rig, 0).threads, w.before + 2);
});

test("a keeper whose reading fails is one not reached: the asker is told to try again, not that no station keeps the chat", { skip }, async () => {
  const w = await workspace(false);
  w.a.up = false;
  // (every keeper's copy of A broken on its disk: its batches no longer batches)
  for (const s of w.keptBy) {
    const n = w.mesh.nodes.get(s)!;
    const g = newestWhole(await n.copies.held(HOME, w.A), HOME, w.A);
    assert.ok(g !== undefined, "the keeper holds A's copy");
    for (const b of g.batches) await writeFile(join(n.copies.kept.dir(HOME, w.A), g.gen, "log", b), "not a batch");
  }
  const r = await refused(w.ask(w.A, w.thread));
  assert.equal(r.status, 503);
  assert.match(r.message, /The stations that keep aaaa's backup do not answer now, or are not updated yet: try again in a few minutes/);
  assert.equal(opened(w.rig, 0).threads, w.before, "no chat opened");
});

test("where the keepers' newest copy is of a newer format, the asker is told to update this station", { skip }, async () => {
  const w = await workspace(false);
  w.a.up = false;
  // (a generation after the one each keeper holds, its head of a format after this station's)
  for (const s of w.keptBy) {
    const n = w.mesh.nodes.get(s)!;
    const g = newestWhole(await n.copies.held(HOME, w.A), HOME, w.A)!;
    const gen = `zz-${g.gen.split("-")[1]}`;
    const dir = join(n.copies.kept.dir(HOME, w.A), gen);
    await mkdir(join(dir, "log"), { recursive: true });
    await writeFile(join(dir, "head.json"), JSON.stringify({ ...g.head, v: 99, gen }));
  }
  const r = await refused(w.ask(w.A, w.thread));
  assert.equal(r.status, 409);
  assert.match(r.message, /The backup of aaaa's chats on .{4} is from a newer version of still.fail: update this station, then try again/);
  assert.equal(opened(w.rig, 0).threads, w.before, "no chat opened");
});

test("the chat is read where the newest copy is, though another keeper comes first in their order", { skip }, async () => {
  const w = await workspace(false);
  const [first, second] = w.keptBy.filter((s) => s !== w.B);
  assert.ok(first !== undefined && second !== undefined);
  // (the first keeper away while A says more: only the others get the copy that holds it)
  w.mesh.nodes.get(first)!.up = false;
  w.made.store.insertMessage({ thread: w.thread, ts: "chat:a.later", authorKind: "person", author: "p@x", text: "said while the first keeper was away" });
  await w.mesh.settle();
  w.mesh.nodes.get(first)!.up = true;
  w.a.up = false;
  const heads = await Promise.all([first, second].map(async (s) => newestWhole(await w.mesh.nodes.get(s)!.copies.held(HOME, w.A), HOME, w.A)?.head));
  // (one generation, made at the same time on the test's clock: the second's goes further)
  assert.equal(heads[1]!.gen, heads[0]!.gen);
  assert.ok(heads[1]!.to > heads[0]!.to, "the second keeper's copy is the newer");
  w.mesh.asked.clear();
  const done = await w.ask(w.A, w.thread);
  await settle();
  assert.notEqual(done.keptBy, first);
  assert.equal(w.mesh.asked.get(first)?.get("replica.chat"), undefined, "the older copy not read");
  const { entries } = opened(w.rig, done.thread);
  assert.ok((entries[0]!.text as string).includes("said while the first keeper was away"));
});

test("a runtime this station does not know, or a model without its runtime, is refused as POST /sessions refuses it", { skip }, async () => {
  const w = await workspace(false);
  w.a.up = false;
  const h = new Handoffs(w.deps);
  const ask = (runtime: string | null, model: string | null) => h.ask({ ws: HOME, origin: w.A, thread: w.thread, by: "q@x", lang: "en", runtime, model, key: null });
  const bad = await refused(ask("nope", null));
  assert.equal(bad.status, 400);
  assert.match(bad.message, /runtime must be/);
  const alone = await refused(ask(null, "some-model"));
  assert.equal(alone.status, 400);
  assert.match(alone.message, /A model is named without its runtime/);
  // (off the mesh: no station can be asked, nor A told from one not reached)
  const off = await refused(new Handoffs({ ...w.deps, attached: () => false }).ask({ ws: HOME, origin: w.A, thread: w.thread, by: "q@x", lang: "en", runtime: null, model: null, key: null }));
  assert.equal(off.status, 503);
  assert.match(off.message, /not connected to the other stations/);
  assert.equal(opened(w.rig, 0).threads, w.before);
});
