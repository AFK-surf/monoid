// The migrations in MoonBit (station/mb src/move_coord: reader `--builder harness-move-coord`) held to the TypeScript
// they are a port of (src/move/): the same world given to both, each part of the one and of the other driven the same
// way, and what each did compared: what it answered, what it asked of its world and of the other station in what order,
// and every file it keeps (stopped.log, last.json, turn.json, jobs.log, sizes.log, accounts-lent.log, accounts-shared.json,
// accounts-known.json, repos.json, settings.json, vaults.json, the kept sets), byte for byte.
// The world is the test's: a module's, a store's, a hub's, a hand-over's, the other station's answers, the clock. The
// TypeScript is given it directly; the program asks it of the test over its harness (a line a message), the same
// objects made again for it. Time is the test's clock for both: the program's timers are armed on it here.
// Where the TypeScript's station (move/station.ts) makes its hand-over itself (replica/handover.ts, the station's, not
// these parts'), it is given the test's hand-over after it is made, and what that one tells the station's moves
// (handed away, back stopped, shown here) is told to the same parts the station's own hand-over would tell.
import assert from "node:assert/strict";
import { execFileSync, spawn, type ChildProcessWithoutNullStreams } from "node:child_process";
import { existsSync, mkdirSync, mkdtempSync, readdirSync, readFileSync, rmSync, statSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { createInterface } from "node:readline";
import { after, test } from "node:test";
import { fileURLToPath } from "node:url";
import { bytesOf, Refused } from "../src/mesh/bus.ts";
import { PeerGone, PeerStopped } from "../src/mesh/peer.ts";
import { Fibers } from "../src/ops/fibers.ts";
import { Said, setStationLang } from "../src/ops/i18n.ts";
import { mbReaderBinary } from "../src/read/mb-reader.ts";
import { accountItemId, accountsModule } from "../src/move/accounts.ts";
import { chatsModule, shortKey, stampOf } from "../src/move/chats.ts";
import { connectItemId, connectsModule } from "../src/move/connects.ts";
import { JobsModule, jobItemId } from "../src/move/jobs.ts";
import { KeptLog, KeptMap, KeptSet, LentLog } from "../src/move/kept.ts";
import { AskAgain, Gone, type Item, type ItemState, type Module, type Need, UNANSWERED } from "../src/move/module.ts";
import { ReposModule, repoItemId } from "../src/move/repos.ts";
import { moveView } from "../src/move/routes.ts";
import { type Selection, Scheduler } from "../src/move/scheduler.ts";
import { SettingsModule } from "../src/move/settings.ts";
import { Sizes } from "../src/move/sizes.ts";
import { Moves, accountOf } from "../src/move/station.ts";
import { Told, isUnder } from "../src/move/told.ts";
import { VaultModule, vaultItemId } from "../src/move/vault.ts";
import { shareRefusal } from "../src/share/index.ts";
import { testClock } from "./hub-fakes.ts";

type Json = any;

// (what both say in English here)
setStationLang("en");

const binary = mbReaderBinary();
const skip = binary === null ? "the MoonBit program (stillfail-reader) is not built here" : false;
const CATALOG = fileURLToPath(new URL("../../client/i18n/catalog/", import.meta.url));

const dirs: string[] = [];
const fresh = (what: string) => {
  const dir = mkdtempSync(join(process.env.STILLFAIL_TEST_TMP ?? tmpdir(), `mbmove-${what}-`));
  dirs.push(dir);
  return dir;
};
after(() => {
  for (const dir of dirs) rmSync(dir, { recursive: true, force: true });
});

/// A JSON round trip: what both sides are compared as.
const plain = (v: unknown) => (v === undefined ? null : JSON.parse(JSON.stringify(v)));

/// What a failure is across the harness: its class, by name.
function kindOf(e: unknown): string {
  if (e instanceof AskAgain) return "AskAgain";
  if (e instanceof Gone) return "Gone";
  if (e instanceof Said) return "Said";
  if (e instanceof Refused) return "Refused";
  if (e instanceof PeerStopped) return "PeerStopped";
  if (e instanceof PeerGone) return "PeerGone";
  return "Error";
}
function errorOf(kind: string, message: string): Error {
  switch (kind) {
    case "AskAgain": return new AskAgain(message);
    case "Gone": return new Gone(message);
    case "Said": return new Said(message);
    case "Refused": return new Refused(message);
    case "PeerStopped": return Object.assign(new PeerStopped(), { message });
    case "PeerGone": return new PeerGone(message);
    default: return new Error(message);
  }
}

/// The test's clock, shared by both sides: the TypeScript's parts' Fibers and the program's timers.
const t = testClock();
const clockFibers = new Fibers("mb-move-coord", t.clock);
after(() => clockFibers.close());

/// Turns of the loop until what was set going here is done (the TypeScript's side of `quiet`).
async function turns(n = 30) {
  for (let i = 0; i < n; i++) await new Promise((r) => setImmediate(r));
}

type World = Record<string, (...args: Json[]) => unknown>;

/// The program, started once: commands asked of it, its asks of the test's worlds answered.
class Program {
  readonly child: ChildProcessWithoutNullStreams;
  #next = 0;
  readonly #done = new Map<number, { resolve: (v: Json) => void; reject: (e: Error) => void }>();
  /// Each instance's world, by its name: what the program asks of it.
  readonly worlds = new Map<string, World>();
  readonly #timers = new Map<number, () => void>();
  /// What the program asked and is not answered yet.
  readonly #inflight = new Set<Promise<unknown>>();
  /// How many asks the program made so far.
  #asked = 0;
  /// What it told (`tell`), in order.
  readonly told: Json[] = [];
  #stderr = "";

  constructor() {
    const shell = fresh("shell");
    this.child = spawn(binary!, ["--builder", "harness-move-coord", "--shell-dir", shell], { stdio: ["pipe", "pipe", "pipe"] });
    createInterface({ input: this.child.stdout }).on("line", (line) => this.#line(line));
    this.child.stderr.on("data", (d) => (this.#stderr += d));
    this.child.on("exit", (code) => {
      for (const w of this.#done.values()) w.reject(new Error(`the program ended (${code}): ${this.#stderr}`));
    });
  }

  #send(j: Json) {
    this.child.stdin.write(`${JSON.stringify({ ...j, now: clockFibers.now() })}\n`);
  }

  cmd(cmd: string, j: Json = {}): Promise<Json> {
    const id = ++this.#next;
    return new Promise((resolve, reject) => {
      this.#done.set(id, { resolve, reject });
      this.#send({ cmd, id, ...j });
    });
  }

  #line(line: string) {
    const m = JSON.parse(line);
    if (typeof m.done === "number") {
      const w = this.#done.get(m.done);
      this.#done.delete(m.done);
      if (m.err !== undefined) w?.reject(errorOf(m.err.kind, m.err.message));
      else w?.resolve(m.ok);
      return;
    }
    if (typeof m.tell === "string") {
      this.told.push(m);
      if (m.tell === "after") this.#timers.set(m.timer, clockFibers.after(m.ms, () => void this.cmd("fire", { timer: m.timer, once: true }))); // timer: the program's own, armed on the test's clock
      else if (m.tell === "every") this.#timers.set(m.timer, clockFibers.every(m.ms, () => this.cmd("fire", { timer: m.timer }))); // timer: the program's own, on the test's clock
      else if (m.tell === "cancel") (this.#timers.get(m.timer)?.(), this.#timers.delete(m.timer));
      return;
    }
    if (typeof m.call === "string") {
      this.#asked++;
      const world = this.worlds.get(m.inst);
      const f = world?.[m.call];
      const run = (async () => {
        try {
          if (f === undefined) throw new Error(`no ${m.call} in the world of ${m.inst}`);
          const ok = await f(...(m.args as Json[]));
          this.#send({ re: m.id, ok: ok === undefined ? null : ok });
        } catch (e) {
          this.#send({ re: m.id, err: { kind: kindOf(e), message: (e as Error)?.message ?? String(e) } });
        }
      })();
      // (one the test holds on purpose, a gate it opens later, is not waited for by `quiet`)
      if (this.parked?.(m.call, m.args as Json[]) === true) return;
      this.#inflight.add(run);
      void run.finally(() => this.#inflight.delete(run));
    }
  }

  /// The asks a test holds on purpose (`quiet` does not wait for them).
  parked: ((call: string, args: Json[]) => boolean) | null = null;

  /// A callback the program gave, called.
  cb(handle: Json, ...args: Json[]): Promise<Json> {
    return this.cmd("cb", { cb: handle.cb, args });
  }

  /// Once nothing here or there goes on before something else is asked.
  /// (a sync asked after every answer sent and answered with none asked since: what the program was given it has taken)
  async quiet() {
    for (let i = 0; i < 1000; i++) {
      await Promise.all([...this.#inflight]);
      await turns(3);
      const asked = this.#asked;
      await this.cmd("sync");
      await turns(3);
      if (this.#inflight.size === 0 && this.#asked === asked) return;
    }
    throw new Error("the program never came to rest");
  }

  /// The holds of updates the program holds now, by instance.
  holds(inst: string): number {
    let n = 0;
    for (const m of this.told) if (m.inst === inst && m.tell === "hold") n++;
    for (const m of this.told) if (m.inst === inst && m.tell === "letGo") n--;
    return n;
  }
}

let program: Program | null = null;
async function mb(): Promise<Program> {
  if (program !== null) return program;
  program = new Program();
  await program.cmd("words", { zh: join(CATALOG, "zh", "station.json"), en: join(CATALOG, "en", "station.json"), lang: "en" });
  return program;
}
after(() => program?.child.stdin.end());

/// Every file under `dir`, by its path in it, with its text (the program's and the TypeScript's kept the same).
function filesOf(dir: string): Record<string, string> {
  const out: Record<string, string> = {};
  const walk = (at: string) => {
    if (!existsSync(at)) return;
    for (const name of readdirSync(at).sort()) {
      const path = join(at, name);
      if (statSync(path).isDirectory()) walk(path);
      else if (!name.endsWith(".tmp")) out[path.slice(dir.length + 1)] = readFileSync(path, "utf8");
    }
  };
  walk(dir);
  return out;
}

/// The two sides' files compared: the same names, the same bytes.
function sameFiles(ts: string, mbDir: string, what: string) {
  assert.deepEqual(filesOf(mbDir), filesOf(ts), `${what}: the files kept`);
}

/// An outcome as either side gives it: its value, or its failure's class and words.
async function outcome(f: () => Promise<unknown>): Promise<Json> {
  try {
    return { ok: JSON.stringify(plain(await f())) };
  } catch (e) {
    return { failed: kindOf(e), error: (e as Error).message };
  }
}

// ── kept.ts ──

test("kept: a set, a map, a log (its lines, a line cut short, one grown past twice what it says, the file of before taken in) and the logins lent, the same files and reads", { skip }, async () => {
  const p = await mb();
  const ts = fresh("kept-ts");
  const ms = fresh("kept-mb");
  // (the files of before, and a log cut short, on both sides)
  for (const dir of [ts, ms]) {
    mkdirSync(join(dir, "move"), { recursive: true });
    writeFileSync(join(dir, "move", "before.json"), JSON.stringify({ x: { a: 1 }, "2": "two", y: null }));
    writeFileSync(join(dir, "move", "cut.log"), `${JSON.stringify({ k: "a", v: 1 })}\n${JSON.stringify({ k: "b", v: 2 })}\n{"k":"c","v`);
    let grown = "";
    for (let i = 0; i < 70; i++) grown += `${JSON.stringify({ k: `k${i % 3}`, v: i })}\n`;
    writeFileSync(join(dir, "move", "grown.log"), grown);
    writeFileSync(join(dir, "move", "lent.json"), JSON.stringify({ "sh-1": { to: "B", item: "share:sh-1", pid: "cc", made: true, widened: false, for: ["chats k1", "chats k2"] } }));
  }
  const kinds = [
    { name: "set", kind: "set", path: "move/set.json" },
    { name: "map", kind: "map", path: "move/map.json" },
    { name: "log", kind: "log", path: "move/log.log", from: "move/before.json" },
    { name: "cut", kind: "log", path: "move/cut.log" },
    { name: "grown", kind: "log", path: "move/grown.log" },
    { name: "lent", kind: "lent", path: "move/lent.log", from: "move/lent.json" },
  ];
  const tsOf = new Map<string, Json>();
  for (const k of kinds) {
    const path = join(ts, k.path);
    tsOf.set(k.name, k.kind === "set" ? new KeptSet(path) : k.kind === "map" ? new KeptMap(path) : k.kind === "log" ? new KeptLog(path, k.from === undefined ? undefined : { path: join(ts, k.from), records: (raw) => Object.entries(raw as Record<string, Json>) }) : new LentLog(path, join(ts, k.from!)));
    await p.cmd("kept.new", { inst: `kept-${k.name}`, kind: k.kind, path: join(ms, k.path), ...(k.from !== undefined ? { from: join(ms, k.from) } : {}) });
  }
  const ops: [string, string, Json[]][] = [
    ["set", "add", ["a"]], ["set", "add", ["b"]], ["set", "add", ["a"]], ["set", "delete", ["a"]], ["set", "add", ["c"]], ["set", "delete", ["zz"]],
    ["map", "set", ["a", { x: 1 }]], ["map", "set", ["10", 2]], ["map", "set", ["a", { x: 3 }]], ["map", "delete", ["b"]], ["map", "set", ["b", [1, "two", null]]], ["map", "delete", ["a"]],
    ["log", "set", ["x", { a: 2 }]], ["log", "delete", ["y"]], ["log", "set", ["z", "zed"]], ["log", "delete", ["nope"]], ["log", "many", [[["m1", 1], ["x", null], ["m2", { deep: [1, 2] }], ["absent", null]]]], ["log", "set", ["x", "again"]],
    ["cut", "set", ["d", 4]], ["cut", "delete", ["a"]],
    ["grown", "set", ["k9", 9]],
    ["lent", "setBase", ["sh-2", { to: "C", item: "key:k", pid: "cx", made: false, widened: true }]], ["lent", "lentFor", ["sh-2", "chats k3"]], ["lent", "lentFor", ["sh-1", "chats k3"]], ["lent", "unlent", ["sh-1", "chats k1"]],
    ["lent", "set", ["sh-1", { to: "B", item: "share:sh-1", pid: "cc", made: true, widened: false, hostMoved: true, for: ["chats k9"] }]], ["lent", "delete", ["sh-2"]],
  ];
  const reads: [string, string, Json[]][] = [
    ["set", "values", []], ["set", "has", ["b"]], ["set", "size", []],
    ["map", "entries", []], ["map", "get", ["b"]],
    ["log", "values", []], ["log", "keys", []], ["log", "get", ["m2"]], ["log", "size", []],
    ["cut", "keys", []], ["cut", "values", []], ["grown", "keys", []], ["grown", "values", []],
    ["lent", "entries", []], ["lent", "sharesFor", ["chats k3"]], ["lent", "forCount", ["sh-1"]], ["lent", "base", ["sh-1"]], ["lent", "get", ["sh-1"]],
  ];
  const readBoth = async (when: string) => {
    for (const [inst, method, args] of reads) {
      const o = tsOf.get(inst)!;
      const mine = method === "size" ? o.size : method === "keys" || method === "values" || method === "entries" ? o[method]() : o[method](...args);
      const theirs = await p.cmd("kept", { inst: `kept-${inst}`, method, args });
      assert.deepEqual(theirs, plain(mine), `${when}: ${inst}.${method}(${JSON.stringify(args)})`);
    }
  };
  await readBoth("as read");
  for (const [inst, method, args] of ops) {
    await tsOf.get(inst)![method](...args);
    await p.cmd("kept", { inst: `kept-${inst}`, method, args });
  }
  await readBoth("after the changes");
  await turns();
  await p.quiet();
  sameFiles(ts, ms, "kept");
  // (each read again from what was written: the same as kept)
  for (const k of kinds) await p.cmd("kept.new", { inst: `kept-${k.name}`, kind: k.kind, path: join(ms, k.path), ...(k.from !== undefined ? { from: join(ms, k.from) } : {}) });
  for (const k of kinds) {
    const path = join(ts, k.path);
    tsOf.set(k.name, k.kind === "set" ? new KeptSet(path) : k.kind === "map" ? new KeptMap(path) : k.kind === "log" ? new KeptLog(path) : new LentLog(path, join(ts, k.from!)));
  }
  await readBoth("read again");
});

// ── scheduler.ts over modules of the test's ──

type FakeOpts = {
  usable?: (id: string) => boolean; usableThere?: (id: string) => boolean; fails?: Set<string>; backFails?: Set<string>;
  lend?: boolean; isHere?: (id: string) => boolean; ready?: (id: string) => string | null; noStop?: boolean;
  gate?: Map<string, Promise<void>>; abandon?: boolean; lentTo?: Map<string, string>;
};
type Fake = Module & { where: Map<string, string>; stopped: Map<string, Need>; items: Omit<Item, "module">[] };

/// A module of the test's: its items, where each is, what it did in order (`log`, shared by a world's modules).
function fake(id: string, needs: string[], items: Omit<Item, "module">[], log: string[], o: FakeOpts = {}): Fake {
  const where = new Map<string, string>(items.map((x) => [x.id, "here"]));
  const stopped = new Map<string, Need>();
  const m: Fake = {
    id, needs, where, stopped, items,
    async plan(ws, to) {
      log.push(`plan ${id} ${ws}→${to}`);
      return items.map((x) => ({ module: id, ...x }));
    },
    async move(item, to, progress, opts) {
      log.push(`move ${id}/${item.id}${opts?.stoppedFor ? ` stoppedFor ${JSON.stringify(opts.stoppedFor)}` : ""}`);
      progress({ done: 1, total: 2, unit: "bytes" });
      await o.gate?.get(item.id);
      if (o.fails?.has(item.id)) throw new Error(`${item.id} would not go`);
      where.set(item.id, to);
    },
    async back(item, from, opts) {
      log.push(`back ${id}/${item.id} from ${from}${opts?.stoppedFor ? ` stoppedFor ${JSON.stringify(opts.stoppedFor)}` : ""}`);
      if (o.backFails?.has(item.id)) throw new Said(`${item.id} would not come back`);
      where.set(item.id, "here");
    },
    state(item): ItemState {
      const w = where.get(item.id);
      const lent = o.lentTo?.get(item.id);
      if (lent !== undefined && w === "here") return { state: "here", lentTo: lent };
      return { state: w === undefined || w === "here" ? "here" : "there", ...(w !== undefined && w !== "here" && w !== "B" ? { at: w } : {}) };
    },
    ...(o.usable !== undefined ? { usableHere: (item: Item) => o.usable!(item.id) } : {}),
    ...(o.usableThere !== undefined ? { usableThere: (item: Item) => where.get(item.id) === "here" && o.usableThere!(item.id) } : {}),
    ...(o.lend === true ? {
      canLend: (item: Item) => !o.lentTo!.has(item.id) && where.get(item.id) === "here",
      async lend(item: Item, to: string, forWhom: Need[]) {
        log.push(`lend ${id}/${item.id} to ${to} for ${forWhom.map((n) => n.id).join(",")}`);
        if (o.fails?.has(`lend:${item.id}`)) throw new Refused(`${item.id} cannot be lent`);
        o.lentTo!.set(item.id, to);
      },
      async lentFor(item: Item, to: string, forWhom: Need[]) {
        log.push(`lentFor ${id}/${item.id} to ${to} for ${forWhom.map((n) => n.id).join(",")}`);
      },
      async left(gone: Need[]) {
        log.push(`left ${id} ${gone.map((n) => `${n.module}/${n.id}`).join(",")}`);
        if (gone.length === 0) return;
        for (const k of [...o.lentTo!.keys()]) o.lentTo!.delete(k);
      },
    } : {}),
    ...(o.isHere !== undefined ? { isHere: (item: Item) => o.isHere!(item.id) } : {}),
    ...(o.ready !== undefined ? { ready: async (item: Item) => o.ready!(item.id) } : {}),
    ...(o.abandon === true ? { abandon: () => void log.push(`abandon ${id}`) } : {}),
    ...(o.noStop === true ? {} : {
      async stop(item: Item, waitsFor: Need) {
        log.push(`stop ${id}/${item.id} for ${JSON.stringify(waitsFor)}`);
        stopped.set(item.id, waitsFor);
      },
      async resume(item: Item) {
        log.push(`resume ${id}/${item.id}`);
        stopped.delete(item.id);
      },
    }),
  };
  return m;
}

/// A world of modules, made twice (one for each side): accounts, chats needing them, jobs needing chats, connects.
function modulesWorld(o: { fails?: Set<string>; backFails?: Set<string>; lend?: boolean; gate?: Map<string, Promise<void>>; cycle?: boolean; ready?: (id: string) => string | null } = {}) {
  const log: string[] = [];
  const lentTo = new Map<string, string>();
  const accounts = fake("accounts", [], [
    { id: "sub", label: "a subscription", needs: [] },
    { id: "grok", label: "a Grok sign-in", needs: [] },
    { id: "mine", label: "the machine's", needs: [], cannot: "this machine's own login cannot go" },
    { id: "asked", label: "a login", needs: [], cannot: "not answered: ask again", again: true },
    { id: "shared", label: "a shared login", needs: [] },
  ], log, { usable: (x) => x === "sub", usableThere: (x) => x === "shared" && false, lend: o.lend, lentTo, fails: o.fails, isHere: (x) => x === "sub", noStop: true });
  const chats = fake("chats", ["accounts", "connects"], [
    { id: "chat:c1", label: "chat:chat one", needs: [{ module: "accounts", id: "sub" }] },
    { id: "c2", label: "chat two", needs: [{ module: "accounts", id: "grok" }] },
    { id: "c3", label: "chat three", needs: [{ module: "accounts", id: "mine" }] },
    { id: "c4", label: "chat four", needs: [{ module: "accounts", id: "asked" }] },
    { id: "c5", label: "chat five", needs: [{ module: "accounts", id: "shared" }, { module: "accounts", id: "grok" }] },
    ...(o.cycle === true ? [{ id: "x1", label: "x one", needs: [{ module: "connects", id: "k1" }] }] : []),
  ], log, { fails: o.fails, backFails: o.backFails, gate: o.gate, abandon: true, ready: o.ready });
  const jobs = fake("jobs", ["chats"], [{ id: "j1", label: "dev server", needs: [{ module: "chats", id: "chat:c1" }] }, { id: "j2", label: "watcher", needs: [{ module: "chats", id: "c2" }] }], log);
  const connects = fake("connects", ["chats"], [
    { id: "k1", label: "slack", needs: o.cycle === true ? [{ module: "chats", id: "x1" }] : [] },
  ], log, { noStop: true });
  return { log, modules: [accounts, chats, jobs, connects] as Fake[], lentTo };
}

const MODULE_FNS = ["plan", "move", "back", "state", "usableHere", "usableThere", "canLend", "lend", "lentFor", "left", "isHere", "abandon", "ready", "stop", "resume"];

/// A scheduler of each side over its own world, the same deps: what each told and did.
async function schedulers(w: () => ReturnType<typeof modulesWorld>, o: { refusal?: (ws: string, s: string) => string | null; roomForAll?: (plan: Json) => string | null; data?: (dir: string) => void } = {}) {
  const p = await mb();
  const inst = `sched-${Math.random().toString(36).slice(2)}`;
  const tw = w();
  const mw = w();
  const tsData = fresh("sched-ts");
  const mbData = fresh("sched-mb");
  o.data?.(tsData);
  o.data?.(mbData);
  const told = { ts: [] as string[], mb: [] as string[] };
  const deps = (side: "ts" | "mb") => ({
    changed: () => void told[side].push("changed"),
    tellArrived: async (to: string, item: Need) => void told[side].push(`arrived ${item.module}/${item.id} at ${to}`),
    now: () => clockFibers.now(),
    refusal: async (ws: string, s: string) => o.refusal?.(ws, s) ?? null,
    roomForAll: async (_ws: string, _s: string, plan: Json) => o.roomForAll?.(plan) ?? null,
    restarted: () => "cut by a restart",
    turn: (on: boolean, s: string) => void told[side].push(`turn ${on} ${s}`),
  });
  let holdsTs = 0;
  const tsS = new Scheduler({ data: tsData, modules: tw.modules, ...deps("ts"), hold: () => (holdsTs++, () => void holdsTs--) });
  const world: World = {
    changed: () => void told.mb.push("changed"),
    tellArrived: (to: string, item: Need) => deps("mb").tellArrived(to, item),
    refusal: (ws: string, s: string) => deps("mb").refusal(ws, s),
    roomForAll: (ws: string, s: string, plan: Json) => deps("mb").roomForAll(ws, s, plan),
    progress: () => null,
  };
  for (const m of mw.modules) {
    for (const f of MODULE_FNS) {
      const fn = (m as Json)[f];
      if (typeof fn !== "function") continue;
      world[`mod.${m.id}.${f}`] = async (...args: Json[]) => {
        if (f === "move") return fn.call(m, args[0], args[1], (pr: Json) => void p.cb(args[2], pr), args[3] ?? undefined);
        if (f === "back") return fn.call(m, args[0], args[1], args[2] ?? undefined);
        if (f === "plan") return fn.call(m, args[0], args[1]);
        return fn.apply(m, args);
      };
    }
  }
  p.worlds.set(inst, world);
  await p.cmd("sched.new", {
    inst, data: mbData,
    modules: mw.modules.map((m) => ({ id: m.id, needs: m.needs, has: MODULE_FNS.filter((f) => typeof (m as Json)[f] === "function") })),
    deps: { has: ["changed", "tellArrived", "now", "refusal", "roomForAll", "hold", "restarted", "turn"], restarted: "cut by a restart" },
  });
  // (`turn` told by the program as a line of its own)
  const mbTurns = () => p.told.filter((m) => m.inst === inst && m.tell === "turn").map((m) => `turn ${m.on} ${m.station}`);
  const sched = (method: string, ...args: Json[]) => p.cmd("sched", { inst, method, args });
  const both = async (what: string, ts: () => Promise<unknown>, method: string, ...args: Json[]) => {
    const a = await outcome(ts);
    const b = await outcome(() => sched(method, ...args));
    await tsS.settle();
    await turns();
    await p.quiet();
    assert.deepEqual(b, a, `${what}: what each answered`);
    assert.deepEqual(mw.log, tw.log, `${what}: what each did of its modules, in order`);
    assert.deepEqual(told.mb.filter((x) => !x.startsWith("turn") && x !== "changed"), told.ts.filter((x) => !x.startsWith("turn") && x !== "changed"), `${what}: what each told`);
    assert.deepEqual(mbTurns(), told.ts.filter((x) => x.startsWith("turn")), `${what}: its turns`);
    assert.equal(p.holds(inst), holdsTs, `${what}: the updates held`);
    sameFiles(tsData, mbData, what);
    // (where each stands, as the plan shows it, and what is stopped)
    const [pt, pm] = [plain(await tsS.plan("ws", "B")), await sched("plan", "ws", "B")];
    assert.equal(JSON.stringify(pm), JSON.stringify(pt), `${what}: the plan after`);
    assert.deepEqual(await sched("stopped"), plain(tsS.stopped()), `${what}: what is stopped`);
    assert.deepEqual(await sched("last", "ws"), plain(tsS.last("ws")), `${what}: the last turn`);
    tw.log.length = 0;
    mw.log.length = 0;
  };
  const move = (what: string, sel: Selection, by: string | null = "p@x", to = "B") => both(what, () => tsS.move("ws", to, sel, by), "move", "ws", to, sel, by);
  const back = (what: string, sel: Selection, by: string | null = "p@x", from = "B") => both(what, () => tsS.back("ws", from, sel, by), "back", "ws", from, sel, by);
  return { p, inst, tsS, sched, both, move, back, tw, mw, tsData, mbData };
}

test("scheduler: one item refused for its need, its need moved, then it with its job following; withNeeds; arriveStopped; a need that cannot go, said in its own words", { skip }, async () => {
  const s = await schedulers(() => modulesWorld());
  await s.both("the plan", () => s.tsS.plan("ws", "B"), "plan", "ws", "B");
  await s.move("refused for its need", { module: "chats", item: "chat:c1" });
  await s.move("its need", { module: "accounts", item: "sub" });
  await s.move("then it, its job following", { module: "chats", item: "chat:c1", follow: ["jobs"] });
  await s.move("an item that is not", { module: "chats", item: "nope" });
  await s.move("a need of the machine's", { module: "chats", item: "c3", withNeeds: true });
  await s.move("a need not answered, arriveStopped", { module: "chats", item: "c4", arriveStopped: true });
  await s.move("arriveStopped where its need stays", { module: "chats", item: "c2", arriveStopped: true });
  await s.move("withNeeds: its job's needs first", { module: "jobs", item: "j2", withNeeds: true });
  await s.back("back refused: what needs it is there", { module: "accounts", item: "grok" });
  await s.back("back with what needs it", { module: "accounts", item: "grok", withNeeds: true, follow: ["jobs"] });
  await s.back("back of what is not there", { module: "accounts", item: "mine" });
  await s.back("back all", { all: true });
});

test("scheduler: a whole move in its late order (what stops others last, what it stops right after), a failure stopping only what needs it, what moved for an item that did not go brought back", { skip }, async () => {
  const s = await schedulers(() => modulesWorld({ fails: new Set(["c2"]) }));
  await s.move("withNeeds, the item failing", { module: "chats", item: "c2", withNeeds: true });
  await s.move("all", { all: true, follow: ["jobs"] });
  await s.back("all back", { all: true });
});

test("scheduler: a need lent, not moved (its host here), kept lent for what a later turn takes there, taken back as the last is here; a lend refused", { skip }, async () => {
  const s = await schedulers(() => modulesWorld({ lend: true }));
  await s.move("lent for the chat", { module: "chats", item: "c2", withNeeds: true });
  await s.move("the job after, its need lent there", { module: "jobs", item: "j2", withNeeds: true });
  await s.back("back: the job, then the chat", { module: "chats", item: "c2", withNeeds: true, follow: ["jobs"] });
  await s.move("the host asked for itself too", { all: true });
  const r = await schedulers(() => modulesWorld({ lend: true, fails: new Set(["lend:grok"]) }));
  await r.move("its lend refused", { module: "chats", item: "c2", withNeeds: true });
});

test("scheduler: a chain of items needing each other round, a would-stop refusal, an item not ready, a back failing", { skip }, async () => {
  const s = await schedulers(() => modulesWorld({ cycle: true, backFails: new Set(["c2"]), ready: (id) => (id === "c5" ? "it is in a turn" : null) }));
  await s.both("the plan names the round", () => s.tsS.plan("ws", "B"), "plan", "ws", "B");
  await s.move("an item on the round", { module: "chats", item: "x1", withNeeds: true });
  await s.move("not ready", { module: "chats", item: "c5", withNeeds: true });
  await s.move("a need whose leaving would stop others", { module: "jobs", item: "j1", withNeeds: true });
  await s.move("its need moved first by name", { module: "accounts", item: "grok" });
  await s.move("the chat", { module: "chats", item: "c2" });
  await s.back("its move back failing", { module: "chats", item: "c2" });
  await s.back("its need's move back refused, what needs it failed there", { module: "accounts", item: "grok" });
});

test("scheduler: a turn refused before anything is held, a whole move that does not fit, the station started again (a turn cut, the file of before taken in, what waits held again and let go)", { skip }, async () => {
  let refuse: string | null = "moving is off there";
  const s = await schedulers(() => modulesWorld(), { refusal: () => refuse, roomForAll: (plan) => (plan.items.length > 3 ? "it does not fit there" : null) });
  await s.move("refused", { module: "accounts", item: "sub" });
  refuse = null;
  await s.move("does not fit", { all: true });
  await s.move("an account away, what needs it stopped", { module: "accounts", item: "grok" });
  // (started again: on each side a scheduler made anew over the same files, a turn cut there and a file of before)
  const cut = JSON.stringify({ ws: "ws", how: "move", station: "B", by: "q@x" });
  const before = JSON.stringify([{ item: { module: "jobs", id: "j1" }, waitsFor: { module: "chats", id: "chat:c1", label: "chat one", at: "B" }, ws: "ws" }]);
  const t2 = await schedulers(() => modulesWorld(), {
    data: (dir) => {
      mkdirSync(join(dir, "move"), { recursive: true });
      writeFileSync(join(dir, "move", "turn.json"), cut);
      writeFileSync(join(dir, "move", "stopped.json"), before);
    },
  });
  await t2.both("started", () => t2.tsS.start(), "start");
  await t2.both("what waits for what is here settled", () => t2.tsS.settleStopped(), "settleStopped");
  await t2.both("an item stopped as it arrived", () => t2.tsS.noteStopped({ module: "chats", id: "c2" }, { module: "accounts", id: "grok", label: "a Grok sign-in", at: "B" }, "ws"), "noteStopped", { module: "chats", id: "c2" }, { module: "accounts", id: "grok", label: "a Grok sign-in", at: "B" }, "ws");
  await t2.both("what it waits for arrived", () => t2.tsS.arrived({ module: "accounts", id: "grok" }), "arrived", { module: "accounts", id: "grok" });
  await t2.both("stopped again", () => t2.tsS.noteStopped({ module: "chats", id: "c2" }, { module: "accounts", id: "grok" }, "ws", false), "noteStopped", { module: "chats", id: "c2" }, { module: "accounts", id: "grok" }, "ws", false);
  await t2.both("then gone from here", () => t2.tsS.forget([{ module: "chats", id: "c2" }]), "forget", [{ module: "chats", id: "c2" }]);
  assert.deepEqual([await t2.sched("hasStopped"), await t2.sched("hasStopped", "B"), await t2.sched("waitsOn", "accounts")], [t2.tsS.hasStopped(), t2.tsS.hasStopped("B"), t2.tsS.waitsOn("accounts")], "what is stopped looked at");
});

test("scheduler: a turn under way, read as it goes (held, its plan shown, GET /move's page), stopped by a person: nothing further, the item under way gives up", { skip }, async () => {
  let open: () => void = () => {};
  // (each side's turn come to its gate, told as it asks for it)
  const reached: Promise<void>[] = [];
  const gate = () => {
    const g = new Map<string, Promise<void>>();
    const held = new Promise<void>((r) => (open = r));
    let hit = () => {};
    reached.push(new Promise<void>((r) => (hit = r)));
    g.get = (id: string) => (id === "c2" ? (hit(), held) : undefined);
    return g;
  };
  const opens: (() => void)[] = [];
  const s = await schedulers(() => {
    const w = modulesWorld({ gate: gate() });
    opens.push(open);
    return w;
  });
  // (the TypeScript's turn begun, then the program's: each held at the chat's move)
  s.p.parked = (call, args) => call === "mod.chats.move" && (args[0] as Json)?.id === "c2";
  const tsRun = s.tsS.move("ws", "B", { module: "chats", item: "c2", arriveStopped: true, follow: ["jobs"] }, "p@x");
  const mbTurn = await s.sched("moveSoon", "ws", "B", { module: "chats", item: "c2", arriveStopped: true, follow: ["jobs"] }, "p@x");
  // (both turns at their gates: told as each comes to it, not a count of turns, which its plan's reads and its turn's
  // file outrun on a loaded machine)
  await Promise.all(reached);
  await s.p.quiet();
  assert.equal(await s.sched("busy"), s.tsS.busy(), "busy");
  assert.deepEqual(await s.sched("current"), plain(s.tsS.current()), "what it is at");
  const held = s.tsS.held("ws", "B")!;
  const mbHeld = await s.sched("held", "ws", "B");
  assert.equal(JSON.stringify(mbHeld.plan), JSON.stringify(held.plan), "the turn's own plan");
  assert.deepEqual(mbHeld.at, Object.fromEntries(held.view.at), "each item's place");
  assert.deepEqual(mbHeld.counts, Object.fromEntries(held.view.counts), "the counts kept");
  assert.equal(JSON.stringify(await s.sched("planShown", "ws", "B")), JSON.stringify(plain(await s.tsS.planShown("ws", "B"))), "the plan shown while it runs");
  const view = (o: Json) => moveView(held.plan, ["accounts", "chats", "jobs", "connects"], s.tsS.stopped(), o, s.tsS.last("ws"), s.tsS.stopping(), (id) => id.slice(0, 12), s.tsS.current(), held.view);
  for (const o of [{}, { module: "chats", after: "c2", limit: 2 }, { module: "accounts", limit: 1 }]) {
    assert.equal(JSON.stringify(await s.sched("view", { ws: "ws", to: "B", ...o })), JSON.stringify(view(o)), `GET /move's page while it runs ${JSON.stringify(o)}`);
  }
  assert.equal(await s.sched("stopTurn", "o@x"), s.tsS.stopTurn("o@x"), "stopped");
  assert.equal(await s.sched("stopping"), s.tsS.stopping());
  for (const o of opens) o();
  const a = await outcome(() => tsRun);
  const b = await outcome(() => s.p.cmd("turn.wait", { turn: mbTurn }));
  await s.tsS.settle();
  await turns();
  await s.p.quiet();
  assert.deepEqual(b, a, "what the turn came to");
  assert.deepEqual(s.mw.log, s.tw.log, "what each did of its modules, in order");
  sameFiles(s.tsData, s.mbData, "the turn stopped");
  assert.deepEqual(await s.sched("last", "ws"), plain(s.tsS.last("ws")), "its last turn, who stopped it");
  s.p.parked = null;
});

// ── told.ts ──

/// A told pair: this station's Told of each side, the same other station answering both.
async function toldPair(answer: (request: Json, n: number) => Json | Error) {
  const p = await mb();
  const inst = `told-${Math.random().toString(36).slice(2)}`;
  const asks = { ts: [] as string[], mb: [] as string[] };
  const ask = (side: "ts" | "mb") => {
    let n = 0;
    return async (station: string, request: Json) => {
      asks[side].push(`${clockFibers.now()} ${station} ${JSON.stringify(request)}`);
      const a = answer(request, n++);
      if (a instanceof Error) throw a;
      return a;
    };
  };
  let holdsTs = 0;
  const tsT = new Told({ fibers: clockFibers, ask: ask("ts"), hold: () => (holdsTs++, () => void holdsTs--) });
  const mbAsk = ask("mb");
  const progress = { ts: [] as Json[], mb: [] as Json[] };
  const work = { ts: new Map<string, () => Promise<Json>>(), mb: new Map<string, () => Promise<Json>>() };
  p.worlds.set(inst, {
    ask: (station: string, request: Json) => mbAsk(station, request),
    progress: (pr: Json) => void progress.mb.push(pr),
    work: async (name: string, cb: Json) => {
      void p.cb(cb, { at: name });
      return await work.mb.get(name)!();
    },
    measure: async (name: string) => ({ measured: name }),
  });
  await p.cmd("told.new", { inst, hold: true });
  const told = (method: string, ...args: Json[]) => p.cmd("told", { inst, method, args });
  const settle = async () => {
    await tsT.settle();
    await told("settle");
    await turns();
    await p.quiet();
  };
  return { p, inst, tsT, told, asks, progress, work, settle, holds: () => [holdsTs, p.holds(inst)] };
}

test("told: a step asked of another station, under way, told how it goes and its end; asked again after a silence and as the other is heard from; let go; a station from before answering at once", { skip }, async () => {
  const ended = { result: { ok: "placed" } };
  const s = await toldPair((r, n) => (r.method === "x.step" && n === 0 ? { under: true, told: r.told } : r.method === "x.old" ? { ok: "at once" } : n === 1 ? { under: true, told: r.told } : ended.result));
  const a = s.tsT.asked("B", "k1", () => ({ method: "x.step", told: "k1" }), (pr) => void s.progress.ts.push(pr));
  const b = s.told("asked", "B", "k1", { method: "x.step", told: "k1" });
  await s.settle();
  assert.deepEqual(s.asks.mb, s.asks.ts, "asked once");
  // (told how it goes, then nothing for a silence: asked again; then its end told)
  assert.deepEqual(await s.told("heard", "B", { told: "k1", progress: { done: 1 } }), s.tsT.heard("B", { told: "k1", progress: { done: 1 } }));
  await s.settle();
  // (to the silence's end, then on: the program's ask is written down as it reaches the test, so the clock waits there
  // for it; past it in one step, it came at 16 s on a slow machine)
  await t.adjust(15_000);
  await s.settle();
  await t.adjust(1_000);
  await s.settle();
  assert.deepEqual(s.asks.mb, s.asks.ts, "asked again after the silence");
  await t.adjust(11_000);
  s.tsT.reached("B");
  await s.told("reached", "B");
  await s.settle();
  assert.deepEqual(s.asks.mb, s.asks.ts, "asked again as the other is heard from");
  assert.deepEqual(await s.told("heard", "B", { told: "k1", ended: true, result: { ok: 1 } }), s.tsT.heard("B", { told: "k1", ended: true, result: { ok: 1 } }));
  assert.deepEqual(await outcome(() => b), await outcome(() => a), "its end");
  assert.deepEqual(s.progress.mb, s.progress.ts, "how it went");
  // (an end told as a failure, a step let go, a station from before)
  const c = s.tsT.asked("B", "k2", () => ({ method: "x.step", told: "k2" }));
  const d = s.told("asked", "B", "k2", { method: "x.step", told: "k2" });
  await s.settle();
  s.tsT.heard("B", { told: "k2", ended: true, error: "its disk is full" });
  await s.told("heard", "B", { told: "k2", ended: true, error: "its disk is full" });
  assert.deepEqual(await outcome(() => d), await outcome(() => c), "failed there");
  const e = s.tsT.asked("B", "k3", () => ({ method: "x.step", told: "k3" }));
  const f = s.told("asked", "B", "k3", { method: "x.step", told: "k3" });
  await s.settle();
  s.tsT.letGo("B", "k3", new Error("its hand-over given up"));
  await s.told("letGo", "B", "k3", "its hand-over given up");
  assert.deepEqual(await outcome(() => f), await outcome(() => e), "let go");
  const g = s.tsT.asked("B", "k4", () => ({ method: "x.old" }));
  const h = s.told("asked", "B", "k4", { method: "x.old" });
  assert.deepEqual(await outcome(() => h), await outcome(() => g), "a station from before");
  await s.settle();
  assert.deepEqual(s.asks.mb, s.asks.ts, "every ask, in order, at its time");
  assert.deepEqual(await s.told("heard", "C", { told: "nothing" }), s.tsT.heard("C", { told: "nothing" }), "a step not waited on");
});

test("told: a step run for another station: under way at once, the same asked again under way, a beat told as it works, its end told until answered (a failure of the telling retried with its backoff), then given again; a failing one refused again; closed", { skip }, async () => {
  let failTells = 2;
  const s = await toldPair((r) => {
    if (r.ended === true && failTells > 0) {
      failTells--;
      return new Error("station unreachable");
    }
    return { ok: true };
  });
  let release = { ts: () => {}, mb: () => {} };
  s.work.ts.set("place", () => new Promise((r) => (release.ts = () => r({ placed: 3 }))));
  s.work.mb.set("place", () => new Promise((r) => (release.mb = () => r({ placed: 3 }))));
  // (the work held till the test lets it go: not waited for as the program comes to rest)
  s.p.parked = (call, args) => call === "work" && args[0] === "place";
  const tsWork = (name: string) => (progress: (p: Json) => void) => (progress({ at: name }), s.work.ts.get(name)!());
  const run = (method: string, key: string, name: string) => outcome(async () => s.tsT.run("A", key, tsWork(name), method === "measured" ? { measure: async () => ({ measured: name }) } : {}));
  const runMb = (method: string, key: string, name: string) => outcome(() => s.told("run", "A", key, name, method === "measured"));
  // (while the work is held, what was set going comes to rest; the steps under way are not waited for)
  const rest = async () => {
    await turns();
    await s.p.quiet();
  };
  assert.deepEqual(await runMb("measured", "s1", "place"), await run("measured", "s1", "place"), "under way at once");
  await rest();
  assert.deepEqual(await runMb("measured", "s1", "place"), await run("measured", "s1", "place"), "under way, asked again");
  assert.deepEqual(s.holds()[1], s.holds()[0], "the update held while it runs");
  await t.adjust(5_000);
  await rest();
  assert.deepEqual(s.asks.mb, s.asks.ts, "a beat");
  release.ts();
  release.mb();
  await s.settle();
  for (const step of [10_000, 20_000]) {
    await t.adjust(step);
    await s.settle();
  }
  assert.deepEqual(s.asks.mb, s.asks.ts, "its end told until answered, with the backoff");
  assert.deepEqual(s.holds()[1], s.holds()[0], "let go as it ended");
  assert.deepEqual(await runMb("measured", "s1", "place"), await run("measured", "s1", "place"), "ended: its result again");
  s.work.ts.set("fail", async () => { throw new Error("no room"); });
  s.work.mb.set("fail", async () => { throw new Error("no room"); });
  assert.deepEqual(await runMb("plain", "s2", "fail"), await run("plain", "s2", "fail"));
  await s.settle();
  assert.deepEqual(await runMb("plain", "s2", "fail"), await run("plain", "s2", "fail"), "its failure refused again");
  s.tsT.close();
  await s.told("close");
  assert.deepEqual(await runMb("plain", "s3", "fail"), await run("plain", "s3", "fail"), "closed: refused");
  assert.deepEqual(await outcome(() => s.told("asked", "B", "k9", { method: "x" })), await outcome(() => s.tsT.asked("B", "k9", () => ({ method: "x" }))), "closed: nothing asked");
  assert.deepEqual(s.asks.mb, s.asks.ts, "every ask, in order, at its time");
  s.p.parked = null;
});

// ── the pure parts ──

test("the pure parts: what an account, a connect, a repository, a vault's and a job's item are; a profile's account and share; a session's stamp; the words a transport says it went unanswered by; a remote's url; a size", { skip }, async () => {
  const p = await mb();
  const pure = (fn: string, ...args: Json[]) => p.cmd("pure", { args: [{ fn, args }] });
  const profiles: Json[] = [
    { id: "cc", runtime: "claude", share: { id: "sh-cc" } }, { id: "cx", runtime: "codex", env: { OPENAI_API_KEY: "k", A_B: "1", AB: "2", a: "3", "2": "x" } },
    { id: "own", runtime: "claude", name: "mine" }, { id: "m", machine: true }, { id: "sub", access: { kind: "subscription" }, env: { X: "1" }, runtime: "grok" },
    { id: "cur", access: { kind: "subscription" }, runtime: "cursor" }, { id: "kimi", access: { provider: "kimi-code", login: true } }, { id: "b", share: { id: "s", borrowed: true } }, { id: 7, name: "" },
  ];
  for (const pr of profiles) {
    assert.deepEqual(await pure("accountOf", pr, "stA"), plain(accountOf(pr, "stA")), `accountOf ${JSON.stringify(pr)}`);
    assert.deepEqual(await pure("shareRefusal", pr), shareRefusal(pr), `shareRefusal ${JSON.stringify(pr)}`);
    const a = accountOf(pr, "stA");
    assert.equal(await pure("accountItemId", String(pr.id), a), accountItemId(String(pr.id), a));
  }
  for (const [id, here] of [["cl", "A"], ["x@B", "A"]]) assert.equal(await pure("connectItemId", id, here), connectItemId(id!, here!));
  assert.equal(await pure("repoItemId", "git@x:y.git"), repoItemId("git@x:y.git"));
  assert.equal(await pure("vaultItemId", "p@x"), vaultItemId("p@x"));
  assert.equal(await pure("jobItemId", { session: "s1", name: "dev" }), jobItemId({ session: "s1", name: "dev" }));
  for (const [row, job] of [[null, undefined], [{ lastActiveAt: 17, archivedAt: null }, "3/0"], [{ lastActiveAt: 1.5, archivedAt: 9 }, undefined]] as const) assert.equal(await pure("stampOf", row, job ?? null), stampOf(row as Json, job));
  for (const k of ["chat:abc", "slack:C1:1.2"]) assert.equal(await pure("shortKey", k), shortKey(k));
  for (const m of ["the other station answered nothing", "peer request timed out", "Connection was RESET by peer", "stream stopped", "disk full", "station unreachable"]) assert.equal(await pure("unanswered", m), UNANSWERED.test(m), m);
  for (const [a, k] of [[{ under: true, told: "k" }, "k"], [{ under: true, told: "j" }, "k"], [null, "k"]] as const) assert.equal(await pure("isUnder", a, k), isUnder(a, k));
  const sizes = [0, 1, 1024 ** 3, 1.25 * 1024 ** 3, 21474836480, 0.04 * 1024 ** 3, 999.96 * 1024 ** 3];
  const gb = (n: number) => `${(n / 1024 ** 3).toFixed(1)} GB`;
  for (const n of sizes) assert.equal(await pure("gb", n), gb(n), `gb ${n}`);
  const keys = ["OPENAI_API_KEY", "A_B", "AB", "a", "B", "Z9", "Z_", "z1", "_x", "-y"];
  for (const x of keys) for (const y of keys) assert.equal(Math.sign(await pure("localeCompare", x, y)), Math.sign(x.localeCompare(y)), `${x} ⋚ ${y}`);
});

// ── the modules ──

/// A station-sized world of the test's, made once for each side: its profiles, sessions and their pages, a hand-over,
/// a hub, jobs, connects, vaults and settings, and the other station's answers; what each part asked of it, in order.
function stationWorld(o: { here?: string; there?: Record<string, (r: Json) => Json | Error> } = {}) {
  const here = o.here ?? "A";
  const calls: string[] = [];
  const note = (s: string) => void calls.push(s);
  const profiles: Json[] = [
    { id: "cc", runtime: "claude", name: "Claude", share: { id: "sh-cc" } },
    { id: "cx", runtime: "codex", env: { OPENAI_API_KEY: "k" } },
    { id: "own", runtime: "claude", name: "own login" },
    { id: "grok", runtime: "grok", access: { kind: "subscription" } },
    { id: "bor", runtime: "claude", share: { id: "sh-bor", borrowed: true, host: "C" } },
    { id: "mine", runtime: "claude", machine: true },
  ];
  const sessions: Json[] = [
    { key: "chat:a1", ws: null, title: "first", workspace: "/w/a1", connect: "chat", lastActiveAt: 5, archivedAt: null, profile: "cc" },
    { key: "chat:a2", ws: "ws", title: null, workspace: "/w/a2", connect: "cm", lastActiveAt: 6, archivedAt: 9, profile: "own" },
    { key: "sl:C1:1", ws: "ws", title: "a thread", workspace: "/w/s1", connect: "sl", lastActiveAt: 7, archivedAt: null, profile: "grok" },
    { key: "chat:a4", ws: "handed:ws", title: "gone", workspace: "/w/a4", connect: "chat", lastActiveAt: 8, archivedAt: null, profile: "cc" },
    { key: "chat:a5", ws: "coming:ws", title: "coming", workspace: "/w/a5", connect: "chat", lastActiveAt: 1, archivedAt: null, profile: "cc" },
    { key: "chat:a6", ws: "ws", title: "six", workspace: "/w/a6", connect: "chat", lastActiveAt: 2, archivedAt: null, profile: "bor" },
    { key: "chat:a7", ws: "ws", title: "seven", workspace: "/w/a7", connect: "chat", lastActiveAt: 3, archivedAt: null, profile: "mine" },
  ];
  const handed = new Map<string, Json>([["chat:a4", { session: "chat:a4", station: "B", ws: "ws", thread: 1, there: 2, at: 3 }]]);
  const outs = new Map<string, Json>([["sl:C1:1", { step: "files", done: 10, total: 100, to: "B" }], ["chat:a6", { step: "failed", error: "it failed there", done: 0, total: 0 }]]);
  const page = (keys: string[], n: number) => ({ keys, rows: sessions.filter((r) => keys.includes(r.key)), handle: { page: n } });
  const pages = [page(["chat:a1", "chat:a2", "sl:C1:1"], 0), page(["chat:a4", "chat:a5", "chat:a6", "chat:a7"], 1)];
  const accountsOfKey = (k: string): [string, Json][] => {
    const s = sessions.find((x) => x.key === k);
    if (s === undefined) return [];
    const pr = profiles.find((x) => x.id === s.profile);
    return [[s.profile, pr === undefined ? null : accountOf(pr, here)]];
  };
  const jobs: Json[] = [{ id: "j-1", session: "chat:a1", name: "dev", command: "npm run dev", cwd: "/w/a1" }, { id: "j-2", session: "sl:C1:1", name: "watch", command: "tsc -w" }];
  const there = o.there ?? {};
  const ask = async (station: string, request: Json) => {
    note(`ask ${station} ${JSON.stringify(request)}`);
    const f = there[String(request?.method ?? "")];
    if (f === undefined) throw new Refused(`no ${String(request?.method)} there`);
    const a = f(request);
    if (a instanceof Error) throw a;
    return a;
  };
  const config: Json = { askToName: true, sandboxes: { a: 1 }, agentEnv: { X: "1" }, maxNudges: 3 };
  const plain_: Json[] = [{ ws: "ws", owner: "p@x", id: "i1", version: 2 }];
  const vaults: Json[] = [{ ws: "ws", owner: "p@x", id: "v1", seq: 1 }];
  const vaultItems: Json[] = [{ ws: "ws", vault: "v1", id: "vi1", version: 1 }];
  return {
    here, calls, note, profiles, sessions, handed, outs, pages, jobs, ask, config, plain_, vaults, vaultItems,
    handover: {
      together: (k: string) => (k === "chat:a1" ? ["chat:a1", "chat:a2"] : [k]),
      chatOf: (k: string) => (k === "chat:a2" ? "chat:a1" : k),
      accountsOf: (keys: string[]) => new Map(keys.flatMap(accountsOfKey)),
      pastLeft: (accounts: Map<string, Json>) => [...accounts.keys()].filter((k) => k === "mine"),
      check: (k: string, to: string) => (k === "chat:a6" ? `chat ${k} cannot go to ${to}: it is busy` : null),
      comingIn: () => [["chat:a5"], ["chat:a8"]],
      outOf: (k: string) => outs.get(k) ?? null,
      comingFrom: (k: string) => (k === "chat:a5" ? "C" : null),
      waitsForTurn: (o_: Json) => o_.step === "files",
      arrived: async (k: string) => (note(`arrived? ${k}`), k !== "chat:never"),
      handOver: async (k: string, to: string, opts: Json) => (note(`handOver ${k} to ${to} ${JSON.stringify(opts?.stoppedFor ?? null)} wait ${opts?.wait}`), opts?.progress?.({ done: 5, total: 10, unit: "bytes" }), { step: "gone" }),
      abandon: () => note("abandon"),
    },
  };
}

test("modules: settings and vault, each moved and moved back, and what another station asks of them; the files each keeps", { skip }, async () => {
  const p = await mb();
  for (const kind of ["settings", "vault"] as const) {
    const inst = `mod-${kind}-${Math.random().toString(36).slice(2)}`;
    const tsW = stationWorld({ there: { "move.setting.values": () => ({ values: { askToName: false, sandboxes: { b: 2 }, maxNudges: 3 } }), "move.setting.put": () => ({ ok: true }), "move.setting.back": () => ({ ok: true }), "move.vault.put": () => ({ ok: true }), "move.vault.back": () => ({ ok: true }) } });
    const mbW = stationWorld({ there: { "move.setting.values": () => ({ values: { askToName: false, sandboxes: { b: 2 }, maxNudges: 3 } }), "move.setting.put": () => ({ ok: true }), "move.setting.back": () => ({ ok: true }), "move.vault.put": () => ({ ok: true }), "move.vault.back": () => ({ ok: true }) } });
    const tsData = fresh(`${kind}-ts`);
    const mbData = fresh(`${kind}-mb`);
    const vaultDeps = (w: ReturnType<typeof stationWorld>) => ({
      owners: () => ["p@x"],
      plain: { items: () => w.plain_, item: (_ws: string, id: string) => w.plain_.find((x) => x.id === id) ?? null, put: (i: Json) => void w.note(`plain.put ${JSON.stringify(i)}`), forget: (ws: string, id: string) => void w.note(`plain.forget ${ws} ${id}`) },
      vaults: { vaults: () => w.vaults, vault: (_ws: string, id: string) => w.vaults.find((x) => x.id === id) ?? null, items: () => w.vaultItems, item: (_ws: string, v: string, id: string) => w.vaultItems.find((x) => x.vault === v && x.id === id) ?? null, putVault: (v: Json) => void w.note(`putVault ${JSON.stringify(v)}`), putItem: (i: Json) => void w.note(`putItem ${JSON.stringify(i)}`), forgetItem: (ws: string, v: string, id: string) => void w.note(`forgetItem ${ws} ${v} ${id}`), forgetVault: (ws: string, id: string) => void w.note(`forgetVault ${ws} ${id}`) },
    });
    const applyOp = (raw: Json, op: Json) => {
      if (op.op === "set") raw[op.key] = structuredClone(op.value);
      else if (op.op === "delete") delete raw[op.key];
      else if (op.op === "merge") {
        raw[op.key] = { ...(raw[op.key] !== null && typeof raw[op.key] === "object" && !Array.isArray(raw[op.key]) ? raw[op.key] : {}) };
        for (const [k, v] of Object.entries(op.entries)) raw[op.key][k] = structuredClone(v);
      } else if (op.op === "unmerge" && raw[op.key] !== null && typeof raw[op.key] === "object" && !Array.isArray(raw[op.key])) {
        raw[op.key] = { ...raw[op.key] };
        for (const k of op.keys) delete raw[op.key][k];
      }
    };
    const tsM: Json = kind === "settings"
      ? new SettingsModule({ data: tsData, ask: tsW.ask, config: { raw: () => tsW.config, updateSoon: async (f) => void f(tsW.config) } })
      : new VaultModule({ data: tsData, ask: tsW.ask, ...vaultDeps(tsW) });
    const v = vaultDeps(mbW);
    p.worlds.set(inst, {
      ask: (s: string, r: Json) => mbW.ask(s, r),
      "config.raw": () => mbW.config,
      "config.update": (op: Json) => void applyOp(mbW.config, op),
      owners: () => v.owners(),
      "plain.items": () => v.plain.items(), "plain.item": (ws: string, id: string) => v.plain.item(ws, id), "plain.put": (i: Json) => v.plain.put(i), "plain.forget": (ws: string, id: string) => v.plain.forget(ws, id),
      "vaults.vaults": () => v.vaults.vaults(), "vaults.vault": (ws: string, id: string) => v.vaults.vault(ws, id), "vaults.items": () => v.vaults.items(), "vaults.item": (ws: string, vv: string, id: string) => v.vaults.item(ws, vv, id),
      "vaults.putVault": (x: Json) => v.vaults.putVault(x), "vaults.putItem": (x: Json) => v.vaults.putItem(x), "vaults.forgetItem": (ws: string, vv: string, id: string) => v.vaults.forgetItem(ws, vv, id), "vaults.forgetVault": (ws: string, id: string) => v.vaults.forgetVault(ws, id),
    });
    await p.cmd("mod.new", { inst, kind, data: mbData, here: "A" });
    const call = (method: string, ...args: Json[]) => p.cmd("mod", { inst, method, args });
    const step = async (what: string, ts: () => Promise<unknown>, method: string, ...args: Json[]) => {
      const a = await outcome(ts);
      const b = await outcome(() => call(method, ...args));
      await turns();
      await p.quiet();
      assert.deepEqual(b, a, `${kind} ${what}`);
      assert.deepEqual(mbW.calls, tsW.calls, `${kind} ${what}: what it asked`);
      sameFiles(tsData, mbData, `${kind} ${what}`);
      if (kind === "settings") assert.deepEqual(mbW.config, tsW.config, `${kind} ${what}: config.json`);
    };
    const items: Json[] = plain(await tsM.plan("ws", "B"));
    tsW.calls.length = 0; // (the items read for the steps below: no step of the module's)
    await step("plan", () => tsM.plan("ws", "B"), "plan", "ws", "B");
    await step("plan of none", () => tsM.plan("ws", ""), "plan", "ws", "");
    for (const x of items) {
      await step(`move ${x.id}`, () => tsM.move(x, "B", () => {}), "move", x, "B");
      await step(`state ${x.id}`, async () => tsM.state(x), "state", x);
    }
    for (const x of items) await step(`back ${x.id}`, () => tsM.back(x, "B"), "back", x, "B");
    // (what another station asks of it)
    const asks: Json[] = kind === "settings"
      ? [{ method: "move.setting.values", key: "agentEnv", keys: ["askToName", "nope", "agentEnv"] }, { method: "move.setting.put", key: "warmMinutes", value: 9 }, { method: "move.setting.put", key: "warmMinutes", value: 10 }, { method: "move.setting.put", key: "agentEnv", value: { X: "2", Y: "3" } }, { method: "move.setting.put", key: "maxNudges", value: 3 }, { method: "move.setting.put", key: "askToName", value: false }, { method: "move.setting.back", key: "agentEnv" }, { method: "move.setting.back", key: "warmMinutes" }, { method: "move.setting.back", key: "nope" }, { method: "move.setting.what", key: "maxNudges" }]
      : [{ method: "move.vault.put", ws: "ws", owner: "q@x", plain: [{ ws: "ws", owner: "q@x", id: "i9", version: 1 }, { ws: "ws", owner: "q@x", id: "i1", version: 1 }, { ws: "ws", owner: "q@x", id: "i1", version: 5 }, { ws: "zz", owner: "q@x", id: "i2" }] }, { method: "move.vault.put", ws: "ws", owner: "q@x", vault: { ws: "ws", owner: "q@x", id: "v9", seq: 1 }, items: [{ ws: "ws", vault: "v9", id: "x1", version: 1 }, { ws: "ws", vault: "v9", id: "x1", version: 1 }] }, { method: "move.vault.put", ws: "ws", owner: "q@x", vault: { ws: "ws", owner: "q@x", id: "v1", seq: 5 }, items: [{ ws: "ws", vault: "v1", id: "vi1", version: 0 }] }, { method: "move.vault.back", ws: "ws", owner: "q@x" }, { method: "move.vault.back", ws: "ws", owner: "nobody" }, { method: "move.vault.put", ws: "", owner: "q@x" }, { method: "move.vault.what", ws: "ws", owner: "q@x" }];
    for (const r of asks) await step(`asked ${JSON.stringify(r)}`, () => (kind === "settings" ? tsM.answer("C", r) : tsM.answer(r)), "answer", ...(kind === "settings" ? ["C", r] : [r]));
  }
});

test("modules: the jobs, kept as their chat is held, moved and moved back, started again; the file of before taken in", { skip }, async () => {
  const p = await mb();
  const inst = `mod-jobs-${Math.random().toString(36).slice(2)}`;
  const tsW = stationWorld({ there: { "move.job.start": () => ({ ok: true }), "move.job.stop": () => ({ ok: true }) } });
  const mbW = stationWorld({ there: { "move.job.start": () => ({ ok: true }), "move.job.stop": () => ({ ok: true }) } });
  const tsData = fresh("jobs-ts");
  const mbData = fresh("jobs-mb");
  for (const d of [tsData, mbData]) {
    mkdirSync(join(d, "move"), { recursive: true });
    writeFileSync(join(d, "move", "jobs.json"), JSON.stringify({ kept: [{ session: "chat:old", name: "srv", command: "x" }], moved: [{ job: { session: "chat:gone", name: "w", command: "y" }, to: "C" }] }));
  }
  const deps = (w: ReturnType<typeof stationWorld>) => ({
    up: (keys: string[] | null, ws?: string) => (w.note(`up ${JSON.stringify(keys)} ${ws ?? ""}`), w.jobs.filter((j) => keys === null || keys.includes(j.session))),
    stop: async (id: string, why: string) => void (w.note(`stop ${id} ${why}`), (w.jobs = w.jobs.filter((j) => j.id !== id))),
    start: (j: Json) => void w.note(`start ${JSON.stringify(j)}`),
    chatOf: (s: string) => w.handover.chatOf(s),
  });
  const tsM = new JobsModule({ data: tsData, ask: tsW.ask, here: () => "A", ...deps(tsW) });
  const d = deps(mbW);
  p.worlds.set(inst, { ask: (s: string, r: Json) => mbW.ask(s, r), up: (k: Json, ws: Json) => d.up(k, ws ?? undefined), stop: (id: string, why: string) => d.stop(id, why), start: (j: Json) => d.start(j), chatOf: (s: string) => d.chatOf(s) });
  await p.cmd("mod.new", { inst, kind: "jobs", data: mbData, here: "A" });
  const call = (method: string, ...args: Json[]) => p.cmd("mod", { inst, method, args });
  const step = async (what: string, ts: () => Promise<unknown>, method: string, ...args: Json[]) => {
    const a = await outcome(ts);
    const b = await outcome(() => call(method, ...args));
    await turns();
    await p.quiet();
    // (the TypeScript's writes end with its promises, not in a count of turns: its file of before is let go once its
    // lines are written, after a plan that writes nothing)
    await tsM.settled();
    assert.deepEqual(b, a, what);
    assert.deepEqual(mbW.calls, tsW.calls, `${what}: what it asked`);
    sameFiles(tsData, mbData, what);
  };
  await step("plan", () => tsM.plan("ws"), "plan", "ws", "B");
  await step("kept as its chat is held", () => tsM.keep(["chat:a1", "chat:a2"], "held"), "keep", ["chat:a1", "chat:a2"], "held");
  const item = { module: "jobs", id: "chat:a1#dev", label: "dev (npm run dev)", needs: [{ module: "chats", id: "chat:a1" }] };
  const up = { module: "jobs", id: "sl:C1:1#watch", label: "watch (tsc -w)", needs: [{ module: "chats", id: "sl:C1:1" }] };
  for (const x of [item, up]) await step(`state ${x.id}`, async () => tsM.state(x), "state", x);
  await step("moved", () => tsM.move(item, "B"), "move", item, "B");
  await step("one still up moved", () => tsM.move(up, "B"), "move", up, "B");
  await step("one not kept", () => tsM.move({ ...item, id: "chat:zz#no", label: "no" }, "B"), "move", { ...item, id: "chat:zz#no", label: "no" }, "B");
  await step("back stopped (its chat still there)", () => tsM.back(item, "B", { stoppedFor: { module: "chats", id: "chat:a1" } }), "back", item, "B", { stoppedFor: { module: "chats", id: "chat:a1" } });
  await step("resumed", () => tsM.resume(item), "resume", item);
  await step("back", () => tsM.back(up, "B"), "back", up, "B");
  await step("back of one not moved", () => tsM.back(item, "B"), "back", item, "B");
  await step("kept again", () => tsM.keep(["chat:old"], "x"), "keep", ["chat:old"], "x");
  await step("and started", async () => tsM.startKept(["chat:old", "chat:a1"]), "startKept", ["chat:old", "chat:a1"]);
  await step("plan after", () => tsM.plan("ws"), "plan", "ws", "B");
});

test("modules: the connects, routed and not, moved and back, where each runs", { skip }, async () => {
  const p = await mb();
  const inst = `mod-connects-${Math.random().toString(36).slice(2)}`;
  const tsW = stationWorld({ there: { "move.back": () => ({ ok: true }) } });
  const mbW = stationWorld({ there: { "move.back": () => ({ ok: true }) } });
  const deps = (w: ReturnType<typeof stationWorld>) => {
    const runs = new Map<string, string>([["fs", "C"]]);
    return {
      own: () => [{ id: "sl", name: "Slack", kind: "slack", mode: "workspace" }, { id: "cm", name: "Comma", kind: "comma", mode: "workspace" }, { id: "ss", name: "one", kind: "slack", mode: "single-session" }, { id: "fs", name: "Feishu", kind: "feishu", mode: "workspace" }],
      chatsOf: async (id: string) => (w.note(`chatsOf ${id}`), id === "sl" ? ["sl:C1:1"] : []),
      kindOf: (id: string) => (id === "cm" ? { kind: "comma", mode: "workspace" } : id === "sl" ? { kind: "slack", mode: "workspace" } : null),
      keysOf: async (id: string) => (w.note(`keysOf ${id}`), ["chat:a2"]),
      runsOn: (id: string) => runs.get(id) ?? null,
      move: async (id: string, to: string, awaiting: string[]) => void (w.note(`move ${id} ${to} ${JSON.stringify(awaiting)}`), runs.set(id, to)),
      here: () => "A",
    };
  };
  const tsM = connectsModule({ ask: tsW.ask, ...deps(tsW) });
  const d = deps(mbW);
  p.worlds.set(inst, { ask: (s: string, r: Json) => mbW.ask(s, r), own: () => d.own(), chatsOf: (id: string) => d.chatsOf(id), kindOf: (id: string) => d.kindOf(id), keysOf: (id: string) => d.keysOf(id), runsOn: (id: string) => d.runsOn(id), move: (id: string, to: string, a: string[]) => d.move(id, to, a) });
  await p.cmd("mod.new", { inst, kind: "connects", here: "A", has: ["kindOf", "keysOf"] });
  const call = (method: string, ...args: Json[]) => p.cmd("mod", { inst, method, args });
  const items: Json[] = plain(await tsM.plan("ws", "B"));
  const mbItems = await call("plan", "ws", "B");
  assert.deepEqual(mbItems, items, "the plan");
  assert.deepEqual(mbW.calls, tsW.calls);
  for (const x of items) {
    assert.deepEqual(await call("state", x), plain(tsM.state(x)), `state ${x.id}`);
    assert.deepEqual(await outcome(() => call("move", x, "B")), await outcome(() => tsM.move(x, "B", () => {})), `move ${x.id}`);
    assert.deepEqual(await call("state", x), plain(tsM.state(x)), `state ${x.id} after`);
    assert.deepEqual(await outcome(() => call("back", x, "B")), await outcome(() => tsM.back(x, "B")), `back ${x.id}`);
    assert.deepEqual(await call("state", x), plain(tsM.state(x)), `state ${x.id} back`);
  }
  assert.deepEqual(mbW.calls, tsW.calls, "what each asked");
});

test("modules: the chats, planned a page at a time (their needs, why one cannot go, what it leaves, its size's stamp), where each stands, moved, moved back as a told step, stopped and let go", { skip }, async () => {
  const p = await mb();
  const inst = `mod-chats-${Math.random().toString(36).slice(2)}`;
  const live = (r: Json) => ({ live: r.keys.filter((k: string) => k === "chat:a2"), name: "Bee" });
  const tsW = stationWorld({ there: { "move.chats.live": live, "move.back": (r) => ({ under: true, told: r.told }) } });
  const mbW = stationWorld({ there: { "move.chats.live": live, "move.back": (r) => ({ under: true, told: r.told }) } });
  const tsData = fresh("chats-ts");
  const mbData = fresh("chats-mb");
  const deps = (w: ReturnType<typeof stationWorld>) => ({
    store: {
      handedTo: (k: string) => w.handed.get(k) ?? null,
      jobsMarkOf: (keys: string[]) => (w.note(`jobsMarkOf ${JSON.stringify(keys)}`), new Map(keys.filter((k) => k === "chat:a1").map((k) => [k, "1/running"]))),
      getSession: (k: string) => w.sessions.find((s) => s.key === k) ?? null,
    } as Json,
    hub: {
      holdChat: async (k: string, why: string, notice?: () => string) => void w.note(`hold ${k} ${why} | ${notice?.()}`),
      releaseChat: (k: string) => (w.note(`release ${k}`), true),
      busy: (k: string) => k === "chat:a2",
    },
    jobs: { keep: async (keys: string[], why: string) => void w.note(`keep ${JSON.stringify(keys)} ${why}`), startKept: (keys: string[]) => void w.note(`startKept ${JSON.stringify(keys)}`) },
    kindOf: (id: string) => (id === "cm" ? { kind: "comma", mode: "workspace" } : id === "sl" ? { kind: "slack", mode: "workspace" } : null),
    vaultsOf: (keys: string[], ws: string) => new Map(keys.filter((k) => k === "chat:a1").map((k) => [k, [`vault:p@x@${ws}`]])),
    name: (id: string) => (id === "B" ? "Bee" : id.slice(0, 12)),
  });
  const reads = (w: ReturnType<typeof stationWorld>) => ({
    pages: async function* () {
      for (const pg of w.pages) yield { keys: pg.keys, rows: () => pg.rows, session: (k: string) => w.sessions.find((s) => s.key === k) ?? null } as Json;
    },
    load: async () => {},
    loaded: () => [],
    worktrees: async (dir: string) => (dir === "/w/a1" ? [{ repo: "/r/one", url: "git@h:one.git" }] : []),
  });
  const handoverOf = (w: ReturnType<typeof stationWorld>) => ({ ...w.handover, together: (k: string) => w.handover.together(k), accountsOf: (keys: string[]) => w.handover.accountsOf(keys), pastLeft: (a: Map<string, Json>) => w.handover.pastLeft(a), check: (k: string, to: string) => w.handover.check(k, to), arrived: (k: string) => w.handover.arrived(k) }) as Json;
  // (a told step back, told ended by the other at once)
  const tsTold = new Told({ fibers: clockFibers, ask: tsW.ask });
  const tsSizes = new Sizes({ data: tsData, measure: async () => [] });
  const tsM = chatsModule({ ...deps(tsW), handover: handoverOf(tsW), ask: tsW.ask, told: tsTold, here: () => "A", reads: () => reads(tsW) as Json, sizes: tsSizes, wait: () => false });
  const d = deps(mbW);
  const mbReads = reads(mbW);
  const pageList = mbW.pages;
  p.worlds.set(inst, {
    ask: (s: string, r: Json) => mbW.ask(s, r),
    "store.handedTo": (k: string) => d.store.handedTo(k), "store.jobsMarkOf": (keys: string[]) => [...d.store.jobsMarkOf(keys)], "store.getSession": (k: string) => d.store.getSession(k),
    "hub.holdChat": (k: string, why: string, notice: string) => d.hub.holdChat(k, why, () => notice), "hub.releaseChat": (k: string) => d.hub.releaseChat(k), "hub.busy": (k: string) => d.hub.busy(k),
    "jobs.keep": (keys: string[], why: string) => d.jobs.keep(keys, why), "jobs.startKept": (keys: string[]) => d.jobs.startKept(keys),
    kindOf: (id: string) => d.kindOf(id), vaultsOf: (keys: string[], ws: string) => Object.fromEntries(d.vaultsOf(keys, ws)),
    "reads.page": (_ws: string, n: number) => pageList[n] ?? null,
    "reads.worktrees": (dir: string) => mbReads.worktrees(dir),
    "page.session": (_h: Json, k: string) => mbW.sessions.find((s) => s.key === k) ?? null,
    "handover.together": (k: string) => mbW.handover.together(k), "handover.accountsOf": (keys: string[]) => [...mbW.handover.accountsOf(keys)],
    "handover.pastLeft": (a: Json[]) => mbW.handover.pastLeft(new Map(a)), "handover.check": (k: string, to: string) => mbW.handover.check(k, to),
    "handover.comingIn": () => mbW.handover.comingIn(), "handover.outOf": (k: string) => mbW.handover.outOf(k), "handover.comingFrom": (k: string) => mbW.handover.comingFrom(k),
    "handover.waitsForTurn": (o_: Json) => mbW.handover.waitsForTurn(o_), "handover.arrived": (k: string) => mbW.handover.arrived(k),
    "handover.handOver": (k: string, to: string, wait: boolean, cb: Json, stoppedFor: Json) => mbW.handover.handOver(k, to, { wait, stoppedFor: stoppedFor ?? undefined, progress: (pr: Json) => void p.cb(cb, pr) }),
    "handover.abandon": () => mbW.handover.abandon(),
    measure: () => [],
  });
  await p.cmd("told.new", { inst: `${inst}-told` });
  p.worlds.set(`${inst}-told`, { ask: (s: string, r: Json) => mbW.ask(s, r) });
  await p.cmd("mod.new", { inst: `${inst}-sizes`, kind: "sizes", data: mbData });
  p.worlds.set(`${inst}-sizes`, { measure: () => [] });
  await p.cmd("mod.new", { inst, kind: "chats", here: "A", told: `${inst}-told`, sizes: `${inst}-sizes`, names: { B: "Bee" }, has: ["busy", "wait"], waitValue: false });
  const call = (method: string, ...args: Json[]) => p.cmd("mod", { inst, method, args });
  const step = async (what: string, ts: () => Promise<unknown>, method: string, ...args: Json[]) => {
    const a = await outcome(ts);
    const b = await outcome(() => call(method, ...args));
    await turns();
    await p.quiet();
    assert.deepEqual(b, a, what);
    assert.deepEqual(mbW.calls, tsW.calls, `${what}: what it asked`);
  };
  await step("planned", () => tsM.plan("ws", "B"), "plan", "ws", "B", false);
  await step("planned for no station", () => tsM.plan("ws", ""), "plan", "ws", "", false);
  const items: Json[] = plain(await tsM.plan("ws", "B"));
  tsW.calls.length = 0;
  await call("plan", "ws", "B", false);
  mbW.calls.length = 0;
  for (const x of items) {
    await step(`state ${x.id}`, async () => tsM.state(x), "state", x);
    await step(`ready ${x.id}`, () => tsM.ready!(x, "B"), "ready", x, "B");
  }
  await step("moved", () => tsM.move(items[0], "B", () => {}, { stoppedFor: { module: "accounts", id: "share:sh-cc", label: "Claude" } }), "move", items[0], "B", { stoppedFor: { module: "accounts", id: "share:sh-cc", label: "Claude" } });
  await step("stopped", () => tsM.stop!(items[0], { module: "accounts", id: "share:sh-cc", label: "Claude", at: "B" }), "stop", items[0], { module: "accounts", id: "share:sh-cc", label: "Claude", at: "B" });
  await step("stopped for one here", () => tsM.stop!(items[1], { module: "accounts", id: "grok" }), "stop", items[1], { module: "accounts", id: "grok" });
  await step("let go", () => tsM.resume!(items[0]), "resume", items[0]);
  await step("abandoned", async () => tsM.abandon!(), "abandon");
  // (back, a told step: the other tells its end as it is asked)
  const backBoth = async (x: Json, stoppedFor?: Json) => {
    // (each taken as it ends: one refused before the test looks is not a failure of the run)
    const a = outcome(() => tsM.back(x, "B", stoppedFor === undefined ? undefined : { stoppedFor }));
    const b = outcome(() => call("back", x, "B", stoppedFor === undefined ? null : { stoppedFor }));
    await turns();
    await p.quiet();
    const keyOf = (calls: string[]) => JSON.parse(calls.findLast((c) => c.startsWith("ask B "))!.slice(6)).told;
    tsTold.heard("B", { told: keyOf(tsW.calls), ended: true, result: { ok: true } });
    await p.cmd("told", { inst: `${inst}-told`, method: "heard", args: ["B", { told: keyOf(mbW.calls), ended: true, result: { ok: true } }] });
    const [ra, rb] = [await a, await b];
    await turns();
    await p.quiet();
    assert.deepEqual(rb, ra, `back ${x.id}`);
    // (the told key is each ask's own: its random part aside)
    const norm = (calls: string[]) => calls.map((c) => c.replace(/back:([^:"]+(?::[^:"]+)*?):[0-9a-f]{12}/g, "back:$1:…"));
    assert.deepEqual(norm(mbW.calls), norm(tsW.calls), `back ${x.id}: what it asked`);
  };
  await backBoth(items[0], { module: "accounts", id: "grok", label: "Grok" });
  mbW.handover.arrived = async (k: string) => (mbW.note(`arrived? ${k}`), false);
  tsW.handover.arrived = async (k: string) => (tsW.note(`arrived? ${k}`), false);
  await backBoth(items[1]);
  sameFiles(tsData, mbData, "the chats' sizes");
});

test("modules: the accounts, planned as the other answers (hosted, borrowed, a third station's, not answered), moved (shared as they move), lent and taken back, come home; their files", { skip }, async () => {
  const p = await mb();
  const inst = `mod-accounts-${Math.random().toString(36).slice(2)}`;
  const answers = [
    (r: Json) => ({ here: Object.fromEntries(Object.keys(r.accounts).map((id) => [id, id.startsWith("share:sh-bor") ? "bor" : null])), hosts: { "share:sh-bor": false } }),
    () => new Error("the other station answered nothing"),
    (r: Json) => ({ here: Object.fromEntries(Object.keys(r.accounts).map((id) => [id, "x"])) }),
  ];
  let which = 0;
  const there = { "move.accounts": (r: Json) => answers[which]!(r), "move.back": () => ({ ok: true }) };
  const tsW = stationWorld({ there });
  const mbW = stationWorld({ there });
  const tsData = fresh("accounts-ts");
  const mbData = fresh("accounts-mb");
  for (const d of [tsData, mbData]) {
    mkdirSync(join(d, "move"), { recursive: true });
    writeFileSync(join(d, "move", "accounts-lent.json"), JSON.stringify({ "sh-old": { to: "B", item: "share:sh-old", pid: "old", made: false, widened: true, for: [] } }));
  }
  const deps = (w: ReturnType<typeof stationWorld>) => {
    let uses = 0;
    return {
      used: () => new Map<string, Json>(w.sessions.map((s) => [s.profile, (() => { const pr = w.profiles.find((x) => x.id === s.profile); return pr === undefined ? null : accountOf(pr, "A"); })()])),
      shared: (id: string) => { const pr = w.profiles.find((x) => x.id === id); return pr?.share !== null && typeof pr?.share === "object"; },
      moveProfile: async (id: string, to: string) => (w.note(`moveProfile ${id} ${to}`), { id }),
      present: (id: string) => (id.startsWith("share:sh-cc") ? "cc" : undefined),
      profile: (id: string) => w.profiles.find((x) => x.id === id),
      shareMoves: {
        move: async (id: string, to: string, made: (s: string) => Promise<void>) => (w.note(`share.move ${id} ${to}`), await made(`sh-${id}`), { id, share: `sh-${id}` }),
        unshare: async (share: string, stations: string[]) => (w.note(`unshare ${share} ${JSON.stringify(stations)}`), true),
        lend: async (id: string, to: string) => (w.note(`lend ${id} ${to}`), { share: `sh-${id}`, made: id !== "cc", widened: id === "cc" }),
        unlend: async (share: string, to: string, made: boolean, widened: boolean) => void w.note(`unlend ${share} ${to} ${made} ${widened}`),
        usesThere: async (to: string, share: string) => (w.note(`usesThere ${to} ${share}`), uses++ % 2),
        handedOn: (to: string, pid: string) => (w.note(`handedOn ${to} ${pid}`), pid === "old" ? ["chat:h1"] : []),
      },
    };
  };
  const tsM = accountsModule({ ...deps(tsW), ask: tsW.ask, here: () => "A", data: tsData });
  const d = deps(mbW);
  p.worlds.set(inst, {
    ask: (s: string, r: Json) => mbW.ask(s, r),
    used: () => [...d.used()], shared: (id: string) => d.shared(id), moveProfile: (id: string, to: string) => d.moveProfile(id, to), present: (id: string) => d.present(id) ?? null, profile: (id: string) => d.profile(id) ?? null,
    "share.move": (id: string, to: string, cb: Json) => d.shareMoves.move(id, to, async (s) => void (await p.cb(cb, s))),
    "share.unshare": (s: string, st: string[]) => d.shareMoves.unshare(s, st), "share.lend": (id: string, to: string) => d.shareMoves.lend(id, to),
    "share.unlend": (s: string, to: string, m: boolean, w: boolean) => d.shareMoves.unlend(s, to, m, w), "share.usesThere": (to: string, s: string) => d.shareMoves.usesThere(to, s), "share.handedOn": (to: string, pid: string) => d.shareMoves.handedOn(to, pid),
  });
  await p.cmd("mod.new", { inst, kind: "accounts", data: mbData, here: "A", has: ["present", "profile", "shareMoves", "lend", "usesThere", "handedOn"] });
  const call = (method: string, ...args: Json[]) => p.cmd("mod", { inst, method, args });
  const step = async (what: string, ts: () => Promise<unknown>, method: string, ...args: Json[]) => {
    const a = await outcome(ts);
    const b = await outcome(() => call(method, ...args));
    await turns();
    await p.quiet();
    // (the TypeScript's writes end with its promises, not in a count of turns: its file of before is let go once its
    // lines are written, after a plan that writes nothing)
    await tsM.settled();
    assert.deepEqual(b, a, what);
    assert.deepEqual(mbW.calls, tsW.calls, `${what}: what it asked`);
    sameFiles(tsData, mbData, what);
  };
  for (const w of [0, 1, 2, 0]) {
    which = w;
    await step(`planned as the other answers (${w})`, () => tsM.plan("ws", "B"), "plan", "ws", "B");
  }
  await step("planned for no station", () => tsM.plan("ws", ""), "plan", "ws", "");
  const items: Json[] = plain(await tsM.plan("ws", "B"));
  tsW.calls.length = 0;
  await call("plan", "ws", "B");
  mbW.calls.length = 0;
  const look = async (what: string) => {
    for (const x of items) {
      for (const f of ["state", "usableHere", "usableThere", "canLend", "isHere"] as const) {
        const mine = (tsM as Json)[f]?.(x) ?? false;
        assert.deepEqual(await call(f, x), plain(mine), `${what}: ${f} ${x.id}`);
      }
    }
  };
  await look("planned");
  const byId = (id: string) => items.find((x) => x.id === id)!;
  await step("lent for a chat", () => tsM.lend!(byId("share:sh-cc"), "B", [{ module: "chats", id: "chat:a1" }, { module: "chats", id: "chat:a1" }]), "lend", byId("share:sh-cc"), "B", [{ module: "chats", id: "chat:a1" }, { module: "chats", id: "chat:a1" }]);
  await look("lent");
  await step("kept lent for another", () => tsM.lentFor!(byId("share:sh-cc"), "B", [{ module: "chats", id: "chat:a6" }]), "lentFor", byId("share:sh-cc"), "B", [{ module: "chats", id: "chat:a6" }]);
  await step("one here again", () => tsM.left!([{ module: "chats", id: "chat:a1" }]), "left", [{ module: "chats", id: "chat:a1" }]);
  await step("the last here again", () => tsM.left!([{ module: "chats", id: "chat:a6" }]), "left", [{ module: "chats", id: "chat:a6" }]);
  await step("looked at again at a turn's end", () => tsM.left!([]), "left", []);
  await step("looked at as the other said", () => (tsM as Json).lookAt("B", { share: "sh-old", uses: 0 }), "lookAt", "B", { share: "sh-old", uses: 0 });
  // (a login no chat here runs on, so no item of the plan: as station_move names it)
  const cx = { module: "accounts", id: accountItemId("cx", accountOf(tsW.profiles[1], "A")), label: "cx", needs: [] };
  await step("lent again", () => tsM.lend!(cx, "B", [{ module: "chats", id: "x" }]), "lend", cx, "B", [{ module: "chats", id: "x" }]);
  await step("then its host moved by name", () => tsM.move(cx, "B", () => {}), "move", cx, "B");
  sameFiles(tsData, mbData, "its host moved");
  await look("moved");
  await step("one shared as it moves", () => tsM.move(byId("own:own@A"), "B", () => {}), "move", byId("own:own@A"), "B");
  await step("one not here", () => tsM.move({ ...byId("own:own@A"), id: "own:none@A" }, "B", () => {}), "move", { ...byId("own:own@A"), id: "own:none@A" }, "B");
  await look("shared as it moved");
  await step("back", () => tsM.back(byId("share:sh-cc"), "B"), "back", byId("share:sh-cc"), "B");
  await step("home", () => (tsM as Json).cameHome("sh-own", "B"), "cameHome", "sh-own", "B");
  await step("home, lent by widening", () => (tsM as Json).cameHome("sh-cx", "B"), "cameHome", "sh-cx", "B");
  await look("home");
});

test("modules: the repositories, planned from their worktrees, cloned there and their bundle fetched, removed only where a move made them; the clones' file", { skip }, async () => {
  const p = await mb();
  const inst = `mod-repos-${Math.random().toString(36).slice(2)}`;
  const git = (dir: string, args: string[]) => execFileSync("git", ["-C", dir, ...args], { encoding: "utf8", env: { ...process.env, GIT_AUTHOR_NAME: "t", GIT_AUTHOR_EMAIL: "t@x", GIT_COMMITTER_NAME: "t", GIT_COMMITTER_EMAIL: "t@x", GIT_CONFIG_NOSYSTEM: "1" }, stdio: ["ignore", "pipe", "pipe"] }).trim();
  // (a remote, a clone of it in the cache with a commit no remote has, and a chat's worktree of it)
  const make = (side: string) => {
    const root = fresh(`repos-${side}`);
    const remote = join(root, "remote.git");
    mkdirSync(remote, { recursive: true });
    git(remote, ["init", "-q", "--bare", "-b", "main"]);
    const repos = join(root, "repos");
    mkdirSync(repos, { recursive: true });
    execFileSync("git", ["clone", "-q", remote, join(repos, "one")], { stdio: "ignore" });
    const one = join(repos, "one");
    writeFileSync(join(one, "README"), "one\n");
    git(one, ["add", "-A"]);
    git(one, ["commit", "-q", "-m", "first"]);
    git(one, ["push", "-q", "origin", "HEAD:main"]);
    writeFileSync(join(one, "NEW"), "not pushed\n");
    git(one, ["add", "-A"]);
    git(one, ["commit", "-q", "-m", "local"]);
    const work = join(root, "sessions", "s1", "workspace");
    mkdirSync(dirname(work), { recursive: true });
    git(one, ["worktree", "add", "-q", "-b", "s1", join(work, "one")]);
    const thereRepos = join(root, "there");
    return { root, remote, repos, work, data: join(root, "data"), thereRepos };
  };
  const a = make("ts");
  const b = make("mb");
  const calls = { ts: [] as string[], mb: [] as string[] };
  // (the other station: a ReposModule of the TypeScript's for each side, its clones in their own directory)
  const thereOf = (w: typeof a, side: "ts" | "mb") => {
    // (what it tells back, told to this side's own module: the TypeScript's, or the program's)
    let told: ((r: Json) => Promise<Json>) | null = null;
    const there = new ReposModule({ data: join(w.root, "theredata"), reposDir: w.thereRepos, workspaces: async () => [], git: async (dir, args) => git(dir, args), ask: async (_s, r) => told!(r), here: () => "B" });
    return { there, set: (m: (r: Json) => Promise<Json>) => void (told = m), side };
  };
  const tsThere = thereOf(a, "ts");
  const mbThere = thereOf(b, "mb");
  const norm = (s: string, w: typeof a) => s.split(w.root).join("<root>");
  const ask = (w: typeof a, there: typeof tsThere, side: "ts" | "mb") => async (station: string, request: Json, bytes?: Json) => {
    calls[side].push(norm(`ask ${station} ${JSON.stringify({ ...request, ...(typeof request.told === "string" ? { told: request.told.replace(/:[0-9a-f]{12}$/, ":…") } : {}) })}`, w));
    if (request.method === "move.repo.bundle") {
      // (the TypeScript's bytes as it sends them; the program's as its world is given them)
      const theirs = bytes !== undefined && bytes !== null && typeof bytes[Symbol.asyncIterator] === "function" ? bytes : null;
      if (theirs !== null) {
        const { told: _t, ...r0 } = request;
        return await there.there.answer("A", r0, theirs);
      }
      const text = bytes?.text ?? (bytes?.file !== undefined ? readFileSync(bytes.file).subarray(bytes.offset, bytes.offset + bytes.size) : null);
      async function* pieces() { if (text !== null) yield Buffer.from(text); }
      const { told: _, ...r } = request;
      return await there.there.answer("A", r, pieces() as Json);
    }
    return await there.there.answer("A", request, null);
  };
  const tsAsk = ask(a, tsThere, "ts");
  const tsM = new ReposModule({ data: a.data, reposDir: a.repos, workspaces: async () => [a.work], git: async (dir, args) => git(dir, args), ask: (s, r) => tsAsk(s, r, bytesOf(r) ?? undefined), here: () => "A", name: (s) => (s === "B" ? "Bee" : s) });
  tsThere.set((r) => tsM.answer("A", r, null));
  mbThere.set((r) => p.cmd("mod", { inst, method: "answer", args: ["A", r] }));
  p.worlds.set(inst, {
    ask: (s: string, r: Json, bytesJ: Json) => ask(b, mbThere, "mb")(s, r, bytesJ ?? undefined),
    workspaces: () => [b.work],
    git: (dir: string, args: string[]) => git(dir, args),
    "fs.writeFrom": (path: string, text: string) => void writeFileSync(path, text),
  });
  await p.cmd("mod.new", { inst, kind: "repos", data: b.data, reposDir: b.repos, here: "A", names: { B: "Bee" } });
  const call = (method: string, ...args: Json[]) => p.cmd("mod", { inst, method, args });
  const pa = plain(await tsM.plan("ws", "B")).map((x: Json) => norm(JSON.stringify(x), a));
  const pb = (await call("plan", "ws", "B")).map((x: Json) => norm(JSON.stringify(x), b));
  assert.deepEqual(pb, pa, "planned from the worktrees");
  const item = plain(await tsM.plan("ws", "B"))[0];
  const itemB = (await call("plan", "ws", "B"))[0];
  // (moved: cloned there by the other station's own module (told back as it ends), its bundle fetched there)
  const [ra, rb] = [await outcome(() => tsM.move(item, "B", () => {})), await outcome(() => call("move", itemB, "B"))];
  assert.deepEqual(rb, ra, "moved");
  await turns();
  await p.quiet();
  assert.deepEqual(await call("state", itemB), plain(tsM.state(item)), "there");
  assert.equal(git(join(b.thereRepos, "one"), ["log", "--format=%s", "s1"]), git(join(a.thereRepos, "one"), ["log", "--format=%s", "s1"]), "its commits there");
  assert.deepEqual(calls.mb, calls.ts, "what each asked");
  // (what another station asks of the clones here: the program's module answering)
  const have = { method: "move.repo.have", urls: [a.remote, "nowhere"] };
  assert.deepEqual(await call("answer", "B", { ...have, urls: [b.remote, "nowhere"] }), plain(await tsM.answer("B", have, null)) && { have: { [b.remote]: true, nowhere: false } }, "which it has");
  assert.deepEqual(await outcome(() => call("answer", "B", { method: "move.repo.make", url: "" })), await outcome(() => tsM.answer("B", { method: "move.repo.make", url: "" }, null)), "no remote");
  assert.deepEqual(await outcome(() => call("answer", "B", { method: "move.repo.what" })), await outcome(() => tsM.answer("B", { method: "move.repo.what" }, null)), "no such request");
  assert.deepEqual(await outcome(() => call("answer", "B", { method: "move.repo.bundle", url: "nowhere" }, "x")), await outcome(() => tsM.answer("B", { method: "move.repo.bundle", url: "nowhere" }, null)), "a bundle with no clone");
  // (back: removed there where this move made it)
  calls.ts.length = 0;
  calls.mb.length = 0;
  assert.deepEqual(await outcome(() => call("back", itemB, "B")), await outcome(() => tsM.back(item, "B")), "moved back");
  assert.deepEqual(calls.mb, calls.ts, "what each asked of its move back");
  assert.equal(existsSync(join(b.thereRepos, "one")), existsSync(join(a.thereRepos, "one")), "the clone there removed as made");
  const files = (dir: string, w: typeof a) => Object.fromEntries(Object.entries(filesOf(dir)).map(([k, v]) => [k, norm(v, w)]));
  assert.deepEqual(files(b.data, b), files(a.data, a), "the files kept");
});

// ── station.ts: two stations, each the TypeScript's or each the program's ──

/// A whole station's moves over the test's world: its store and hub, its hand-over (the test's, over what it holds),
/// its connects, jobs, profiles, vault and config; the other station reached through the test's bus.
function stationOf(id: "A" | "B", side: "ts" | "mb", net: Net) {
  const w = stationWorld({ here: id });
  const data = fresh(`station-${side}-${id}`);
  const shown = new Set<string>();
  const handOver = async (k: string, to: string, opts: Json) => {
    w.note(`handOver ${k} to ${to} ${JSON.stringify(opts?.stoppedFor ?? null)} wait ${opts?.wait ?? true}`);
    opts?.progress?.({ done: 5, total: 10, unit: "bytes" });
    const answer = await net.ask(id, to, { method: "handover.take", key: k, ...(opts?.stoppedFor !== undefined ? { stoppedFor: opts.stoppedFor } : {}) });
    w.handed.set(k, { session: k, station: to });
    const out = { step: "gone", to, shown: true };
    w.outs.set(k, out);
    await hooks?.went([k]);
    return { ...out, answer };
  };
  let hooks: { went: (keys: string[]) => Promise<void>; shown: (keys: string[], from?: string) => Promise<void>; arrivedStopped: (keys: string[], need: Json, ws: string) => Promise<void> } | null = null;
  /// What another station hands here (`handover.take`): shown here, stopped where what it waits for is not.
  const take = async (peer: string, r: Json) => {
    w.handed.delete(r.key);
    w.outs.delete(r.key);
    if (!w.sessions.some((s) => s.key === r.key)) w.sessions.push({ key: r.key, ws: "ws", title: r.key, workspace: `/w/${r.key}`, connect: "chat", lastActiveAt: 1, archivedAt: null, profile: "cc" });
    shown.add(r.key);
    if (r.stoppedFor !== undefined) await hooks?.arrivedStopped([r.key], r.stoppedFor, "ws");
    await hooks?.shown([r.key], peer);
    return { took: r.key };
  };
  const handover = {
    ...w.handover,
    together: (k: string) => w.handover.together(k),
    handOver,
    start: async () => void w.note("handover.start"),
    close: async () => {},
    settle: async () => {},
    loadedWithin: async () => {},
    reached: (peer: string) => void w.note(`handover.reached ${peer}`),
    answer: async (peer: string, r: Json) => (r.method === "handover.take" ? take(peer, r) : { handed: r.method }),
    // (what the station answers of `handover.*` (station.ts `answers`): the test's, as the program's world gives it)
    answers: () => async (peer: string, r: Json): Promise<Json> => (r.method === "handover.take" ? take(peer, r) : { handed: r.method }),
  };
  const jobs = {
    up: (keys: string[] | null) => w.jobs.filter((j) => keys === null || keys.includes(j.session)),
    stop: async (jid: string) => void (w.note(`jobs.stop ${jid}`), (w.jobs = w.jobs.filter((j) => j.id !== jid))),
    start: async (j: Json) => void w.note(`jobs.start ${JSON.stringify(j)}`),
    stopNamed: async (s: string, n: string) => void w.note(`jobs.stopNamed ${s} ${n}`),
  };
  const store = {
    handedTo: (k: string) => w.handed.get(k) ?? null,
    getSession: (k: string) => w.sessions.find((s) => s.key === k) ?? null,
    jobsMarkOf: (keys: string[]) => new Map(keys.map((k) => [k, "0/none"])),
    liveSessionsOn: (pid: string, most: number) => w.sessions.filter((s) => s.profile === pid && !w.handed.has(s.key)).slice(0, most).map((s) => s.key),
    liveOf: (keys: string[]) => keys.filter((k) => w.sessions.some((s) => s.key === k && !w.handed.has(k)) && k === "chat:a7"),
    jobsUpOf: (keys: string[]) => w.jobs.filter((j) => keys.includes(j.session)).map((j) => ({ ...j, sessionKey: j.session })),
    sessionsOfConnect: (c: string) => w.sessions.filter((s) => s.connect === c).map((s) => s.key),
    handedChats: (after: string) => [...w.handed.values()].filter((h) => h.session > after).sort((x, y) => (x.session < y.session ? -1 : 1)),
    listBindings: () => new Map([["chat:a2", ["cm"]]]),
  };
  const page = (keys: string[], n: number) => ({ keys, rows: () => w.sessions.filter((r) => keys.includes(r.key)), session: (k: string) => w.sessions.find((s) => s.key === k) ?? null, handle: { page: n, keys } });
  const sessionsIn = (_ws: string, after: string, limit: number) => {
    const keys = w.sessions.map((s) => s.key).filter((k) => k > after).sort().slice(0, limit);
    return page(keys, after.length);
  };
  const connects = {
    kindOf: (c: string) => (c === "cm" ? { kind: "comma", mode: "workspace" } : null),
    ownIn: () => (id === "A" ? [{ id: "cm", name: "Comma", kind: "comma", mode: "workspace" }] : []),
    runsOn: () => null,
    move: async (c: string, to: string, awaiting?: string[]) => void w.note(`connects.move ${c} ${to} ${JSON.stringify(awaiting ?? [])}`),
    arrived: async (keys: string[]) => void w.note(`connects.arrived ${JSON.stringify(keys)}`),
  };
  const shareMoves = {
    move: async (pid: string, to: string, made: (s: string) => Promise<void>) => (w.note(`share.move ${pid} ${to}`), await made(`sh-${pid}`), { id: pid, share: `sh-${pid}` }),
    unshare: async (s: string, st: string[]) => (w.note(`unshare ${s} ${JSON.stringify(st)}`), true),
    lend: async (pid: string, to: string) => (w.note(`lend ${pid} ${to}`), { share: `sh-${pid === "cc" ? "cc" : pid}`, made: pid !== "cc", widened: pid === "cc" }),
    unlend: async (s: string, to: string, m: boolean, wd: boolean) => void w.note(`unlend ${s} ${to} ${m} ${wd}`),
  };
  const roster = [{ id: "A", name: "Ay", tasks: false }, { id: "B", name: "Bee", tasks: false }];
  const config = w.config;
  const room = { free: id === "B" ? 30 * 1024 ** 3 : 1e15, total: 100 * 1024 ** 3 };
  const sizes = async (keys: string[], sizing: Json) => [...keys, ...(sizing.places ?? []).map((pl: Json) => pl.key)].map((k) => ({ key: k, bytes: k.length * 1024 ** 3, complete: k !== "chat:a2", room: `${data}/sessions/${k}`, transcripts: [`${data}/transcripts/claude/x/${k}.jsonl`] }));
  return { id, w, data, handover, jobs, store, page, sessionsIn, connects, shareMoves, roster, config, room, sizes, shown, setHooks: (h: typeof hooks) => void (hooks = h), side };
}

/// The bus between two stations of a side: what each asked of the other, in order, and how a request may fail
/// (`fail`: the transport's own failure for it, once).
class Net {
  readonly heard: string[] = [];
  readonly answer = new Map<string, (peer: string, request: Json, ws?: string) => Promise<Json>>();
  fail: ((from: string, to: string, request: Json) => Error | null) | null = null;
  down = new Set<string>();
  async ask(from: string, to: string, request: Json): Promise<Json> {
    const norm = JSON.stringify(request, (k, v) => (k === "told" && typeof v === "string" ? v.replace(/:[0-9a-f]{12}$/, ":…") : k === "fromData" ? "<data>" : v));
    // (each side's data directories its own: named alike)
    this.heard.push(`${from}→${to} ${norm.replace(/mbmove-station-(?:ts|mb)-([AB])-[A-Za-z0-9]+/g, "station-$1")}`);
    if (this.down.has(to)) throw new Error("station unreachable");
    const f = this.fail?.(from, to, request) ?? null;
    if (f !== null) {
      this.heard.push(`  failed: ${f.constructor.name}`);
      throw f;
    }
    const answer = this.answer.get(to);
    if (answer === undefined) throw new Error("station unreachable");
    return JSON.parse(JSON.stringify(await answer(from, JSON.parse(JSON.stringify(request)), "ws")));
  }
}

/// The two stations of a side: each its moves over its own world, the bus between them.
async function stations(side: "ts" | "mb", o: { on?: boolean } = {}) {
  const net = new Net();
  const st = { A: stationOf("A", side, net), B: stationOf("B", side, net) };
  const p = side === "mb" ? await mb() : null;
  const made: Record<string, { cmd: (method: string, ...args: Json[]) => Promise<Json>; ts?: Moves; inst?: string }> = {};
  for (const s of [st.A, st.B]) {
    if (side === "ts") {
      const moves = new Moves({
        data: s.data, here: () => s.id, home: () => "ws", roster: () => s.roster, ask: (to, r) => net.ask(s.id, to, r), fibers: clockFibers, store: s.store as Json,
        hub: { holdChat: async (k: string, why: string, notice?: () => string) => void s.w.note(`hub.hold ${k} ${why} | ${notice?.()}`), releaseChat: (k: string) => (s.w.note(`hub.release ${k}`), true), busy: () => false } as Json,
        connects: s.connects as Json, jobs: s.jobs as Json, profiles: () => s.w.profiles, moveProfile: async (pid, to) => (s.w.note(`moveProfile ${pid} ${to}`), { id: pid }), shareMoves: s.shareMoves,
        sessionsIn: (ws, after, limit) => s.sessionsIn(ws, after, limit) as Json, reposDir: join(s.data, "repos"), room: async () => s.room as Json, sizes: s.sizes as Json, config: { raw: () => s.config, updateSoon: async (f) => void f(s.config) },
        moveOn: () => o.on ?? true, hold: () => () => {}, clonesElsewhere: async () => [], git: async () => "",
        vault: { owners: () => [], grantOwners: () => new Map(), plain: { items: () => [], item: () => null, put: () => {}, forget: () => {} }, vaults: { vaults: () => [], vault: () => null, items: () => [], item: () => null, putVault: () => {}, putItem: () => {}, forgetItem: () => {}, forgetVault: () => {} } },
      });
      // (the test's hand-over in place of the station's own; what it tells the moves, told to the same parts)
      Object.assign(moves.handover, s.handover);
      s.setHooks({
        went: (keys) => moves.scheduler.forget(keys.map((id) => ({ module: "chats", id }))),
        arrivedStopped: (keys, need, ws) => moves.scheduler.noteStopped({ module: "chats", id: keys[0]! }, need, ws),
        shown: async (keys, from) => {
          await s.connects.arrived(keys);
          await (moves.modules[0] as Json).left(keys.map((k) => ({ module: "chats", id: k }))).catch(() => {});
          if (from !== undefined) await (moves.modules[0] as Json).lookAt(from).catch(() => {});
        },
      });
      const answers = moves.answers(() => true);
      net.answer.set(s.id, (peer, r, ws) => answers(peer, r, ws));
      made[s.id] = {
        ts: moves,
        cmd: async (method, ...args) => {
          switch (method) {
            case "scheduler": {
              const [c] = args;
              return (moves.scheduler as Json)[c.method](...c.args);
            }
            case "refusal": return moves.refusal(args[0], args[1], args[2] ?? "en");
            case "settle": await moves.scheduler.settle(); await moves.told.settle(); await turns(); return null;
            case "heard": return moves.heard(args[0]);
            case "loginsChanged": return moves.loginsChanged();
            case "room": return moves.room(args[0], args[1], args[2]);
            case "roomForAll": return moves.roomForAll(args[0], args[1], args[2]);
            case "accountHere": return moves.accountHere(args[0]);
            case "answer": return answers(args[0], args[1], args[2]);
            case "start": return moves.start();
            default: throw new Error(`no ${method}`);
          }
        },
      };
    } else {
      const inst = `moves-${s.id}-${Math.random().toString(36).slice(2)}`;
      const world: World = {
        ask: (to: string, r: Json) => net.ask(s.id, to, r),
        "store.subscribe": () => null, "store.handedTo": (k: string) => s.store.handedTo(k), "store.getSession": (k: string) => s.store.getSession(k), "store.jobsMarkOf": (keys: string[]) => [...s.store.jobsMarkOf(keys)],
        "store.liveSessionsOn": (pid: string, n: number) => s.store.liveSessionsOn(pid, n), "store.liveOf": (keys: string[]) => s.store.liveOf(keys), "store.jobsUpOf": (keys: string[]) => s.store.jobsUpOf(keys),
        "store.sessionsOfConnect": (c: string) => s.store.sessionsOfConnect(c), "store.sessionPage": (keys: string[]) => ({ keys, rows: s.w.sessions.filter((r) => keys.includes(r.key)), handle: { keys } }), "store.handedChats": (after: string) => s.store.handedChats(after), "store.listBindings": () => [...s.store.listBindings()],
        "hub.holdChat": (k: string, why: string, notice: string) => void s.w.note(`hub.hold ${k} ${why} | ${notice}`), "hub.releaseChat": (k: string) => (s.w.note(`hub.release ${k}`), true), "hub.busy": () => false,
        "handover.make": (hooks: Json) => void s.setHooks({
          went: async (keys) => void (await p!.cb(hooks.went, keys)),
          arrivedStopped: async (keys, need, ws) => void (await p!.cb(hooks.arrivedStopped, keys, need, ws)),
          shown: async (keys, from) => {
            await s.connects.arrived(keys);
            await p!.cb(hooks.shown, keys, from ?? null).catch(() => {});
          },
        }),
        "handover.together": (k: string) => s.handover.together(k), "handover.chatOf": (k: string) => s.handover.chatOf(k), "handover.accountsOf": (keys: string[]) => [...s.handover.accountsOf(keys)],
        "handover.pastLeft": (a: Json[]) => s.handover.pastLeft(new Map(a)), "handover.check": (k: string, to: string) => s.handover.check(k, to), "handover.comingIn": () => s.handover.comingIn(),
        "handover.outOf": (k: string) => s.handover.outOf(k), "handover.comingFrom": (k: string) => s.handover.comingFrom(k), "handover.waitsForTurn": (o_: Json) => s.handover.waitsForTurn(o_),
        "handover.arrived": (k: string) => s.handover.arrived(k), "handover.abandon": () => s.handover.abandon(),
        "handover.handOver": (k: string, to: string, wait: boolean, cb: Json, stoppedFor: Json) => s.handover.handOver(k, to, { wait, stoppedFor: stoppedFor ?? undefined, progress: cb === null ? undefined : (pr: Json) => void p!.cb(cb, pr) }),
        "handover.start": () => s.handover.start(), "handover.close": () => s.handover.close(), "handover.settle": () => null, "handover.loadedWithin": () => null,
        "handover.answer": (peer: string, r: Json) => s.handover.answer(peer, r), "handover.reached": (peer: string) => s.handover.reached(peer),
        "page.session": (h: Json, k: string) => s.w.sessions.find((x) => x.key === k) ?? null,
        "connects.kindOf": (c: string) => s.connects.kindOf(c), "connects.ownIn": () => s.connects.ownIn(), "connects.runsOn": () => null, "connects.move": (c: string, to: string, a: string[]) => s.connects.move(c, to, a), "connects.arrived": () => null,
        "jobs.up": (keys: string[] | null) => s.jobs.up(keys), "jobs.stop": (jid: string) => s.jobs.stop(jid), "jobs.start": (j: Json) => s.jobs.start(j), "jobs.stopNamed": (x: string, n: string) => s.jobs.stopNamed(x, n),
        profiles: () => s.w.profiles, moveProfile: async (pid: string, to: string) => (s.w.note(`moveProfile ${pid} ${to}`), { id: pid }),
        "share.move": (pid: string, to: string, cb: Json) => s.shareMoves.move(pid, to, async (x) => void (await p!.cb(cb, x))), "share.unshare": (x: string, st_: string[]) => s.shareMoves.unshare(x, st_),
        "share.lend": (pid: string, to: string) => s.shareMoves.lend(pid, to), "share.unlend": (x: string, to: string, m: boolean, wd: boolean) => s.shareMoves.unlend(x, to, m, wd),
        sessionsIn: (ws: string, after: string, limit: number) => { const pg = s.sessionsIn(ws, after, limit); return { keys: pg.keys, rows: pg.rows(), handle: pg.handle }; },
        room: () => s.room, sizes: (keys: string[], sizing: Json) => s.sizes(keys, sizing), "config.raw": () => s.config, "config.update": () => null,
        "vault.owners": () => [], "vault.grantOwners": () => ({}), clonesElsewhere: () => [], git: () => "",
      };
      p!.worlds.set(inst, world);
      await p!.cmd("moves.new", { inst, data: s.data, here: s.id, home: "ws", rosters: { ws: s.roster }, reposDir: join(s.data, "repos"), on: o.on ?? true, has: ["connects", "shareMoves"] });
      net.answer.set(s.id, (peer, r, ws) => p!.cmd("moves", { inst, method: "answer", args: [peer, r, ws ?? null] }));
      made[s.id] = { inst, cmd: (method, ...args) => p!.cmd("moves", { inst, method, args }) };
    }
  }
  const quiet = async () => {
    await made.A!.cmd("settle");
    await made.B!.cmd("settle");
    await turns();
    if (p !== null) await p.quiet();
  };
  return { net, st, made, quiet };
}

test("stations: a chat moved with its login lent, its job following, then moved back; what each asked of the other, what each did, and every file kept, the same", { skip }, async () => {
  const ts = await stations("ts");
  const mbs = await stations("mb");
  const both = async (what: string, f: (s: Awaited<ReturnType<typeof stations>>) => Promise<unknown>) => {
    const a = await outcome(() => f(ts));
    const b = await outcome(() => f(mbs));
    await ts.quiet();
    await mbs.quiet();
    assert.deepEqual(b, a, `${what}: what it answered`);
    assert.deepEqual(mbs.net.heard, ts.net.heard, `${what}: what each station asked of the other, in order`);
    for (const id of ["A", "B"] as const) {
      const named = (calls: string[]) => calls.map((c) => c.replace(/mbmove-station-(?:ts|mb)-([AB])-[A-Za-z0-9]+/g, "station-$1"));
      assert.deepEqual(named(mbs.st[id].w.calls), named(ts.st[id].w.calls), `${what}: what ${id} did of its world`);
      const files = (dir: string) => Object.fromEntries(Object.entries(filesOf(dir)).map(([k, v]) => [k, v.split(dir).join("<data>")]));
      assert.deepEqual(files(mbs.st[id].data), files(ts.st[id].data), `${what}: the files ${id} keeps`);
    }
  };
  const sched = (id: "A" | "B", method: string, ...args: Json[]) => (s: Awaited<ReturnType<typeof stations>>) => s.made[id]!.cmd("scheduler", { method, args });
  await both("started", async (s) => (await s.made.A!.cmd("start"), await s.made.B!.cmd("start")));
  await both("refusal", (s) => s.made.A!.cmd("refusal", "ws", "B", "en"));
  await both("the plan toward B", sched("A", "plan", "ws", "B"));
  await both("a chat moved with what it needs, its job following", sched("A", "move", "ws", "B", { module: "chats", item: "chat:a1", withNeeds: true, follow: ["jobs"] }, "p@x"));
  await both("the plan after", sched("A", "plan", "ws", "B"));
  await both("B's plan back toward A", sched("B", "plan", "ws", "A"));
  await both("the room", (s) => s.made.A!.cmd("room", "ws", "B", ["chat:a1", "sl:C1:1"]));
  await both("a whole move that does not fit there", sched("A", "move", "ws", "B", { all: true, follow: ["jobs"] }, "p@x"));
  await both("moved back with what needs it", sched("A", "back", "ws", "B", { module: "chats", item: "chat:a1", withNeeds: true, follow: ["jobs"] }, "p@x"));
  await both("a login that cannot be had here moved away: what needs it stopped", sched("A", "move", "ws", "B", { module: "accounts", item: "own:own@A" }, "p@x"));
  await both("stopped as B is heard from", async (s) => (await s.made.A!.cmd("heard", "B"), await s.made.A!.cmd("loginsChanged")));
  await both("what B asks of A", async (s) => {
    const out: Json[] = [];
    for (const r of [
      { method: "move.open", workspace: "ws" }, { method: "move.uses", share: "sh-cc" }, { method: "move.accounts", accounts: { "share:sh-cc": { share: "sh-cc", name: "c" }, "own:own@A": { own: "own@A", name: "o" }, "key:x": { key: "x", name: "k" } } },
      { method: "move.chats.live", keys: ["chat:a7", "chat:zz", 3] }, { method: "move.job.start", job: { session: "chat:a7", name: "dev", command: "x", cwd: "/elsewhere/x" }, fromData: "/elsewhere" }, { method: "move.job.start", job: { session: "nope", name: "d", command: "x" } }, { method: "move.job.start", job: { name: 3 } },
      { method: "move.job.stop", session: "chat:a7", name: "dev" }, { method: "move.arrived", item: { module: "accounts", id: "own:own@A" } }, { method: "move.arrived" }, { method: "move.unused", share: "sh-cc" }, { method: "move.unused" },
      { method: "move.sizes", places: [{ key: "k1", room: "/elsewhere/sessions/k1", transcripts: ["/elsewhere/t/1", 4] }], fromData: "/elsewhere" }, { method: "move.sizes", places: [] },
      { method: "move.back", module: "accounts", id: "own:own@A", to: "B" }, { method: "move.back", module: "accounts", id: "share:sh-bor", to: "B" }, { method: "move.back", module: "accounts", id: "nope", to: "B" }, { method: "move.back", module: "connects", id: "cm@A", to: "B" },
      { method: "move.back", module: "chats", id: "chat:a6", to: "B", told: "back:chat:a6:x" }, { method: "move.back", module: "what", id: "x", to: "B" }, { method: "move.back", module: "chats", id: "x", to: "C" },
      { method: "move.told", told: "k" }, { method: "move.nothing" }, { method: "handover.begin", key: "x" },
      { method: "move.setting.values", key: "agentEnv", keys: ["askToName"] }, { method: "move.vault.back", ws: "ws", owner: "p@x" }, { method: "move.repo.have", urls: [] },
    ]) out.push(await outcome(() => s.made.A!.cmd("answer", "B", r, "ws")));
    return out;
  });
});

test("stations: a request meeting the other's process stopping asked again once, dialed anew; its connection gone sent again once, then the station said gone for the rest of the turn (a drop asked all the same, once); one switched off, one out of reach, one whose disk would be too full", { skip }, async () => {
  for (const scenario of ["stopped", "gone", "off", "unreachable"] as const) {
    const ts = await stations("ts", { on: scenario !== "off" });
    const mbs = await stations("mb", { on: scenario !== "off" });
    const failing = (net: Net) => {
      let n = 0;
      net.fail = (_from, _to, r) => {
        if (scenario === "stopped" && r.method === "move.chats.live" && n++ === 0) return new PeerStopped();
        if (scenario === "gone" && (r.method === "handover.take" || r.method === "handover.drop" || r.method === "move.arrived")) return new PeerGone();
        if (scenario === "unreachable" && r.method === "move.open") return new PeerGone();
        return null;
      };
    };
    failing(ts.net);
    failing(mbs.net);
    const both = async (what: string, f: (s: Awaited<ReturnType<typeof stations>>) => Promise<unknown>) => {
      const a = await outcome(() => f(ts));
      const b = await outcome(() => f(mbs));
      await ts.quiet();
      await mbs.quiet();
      assert.deepEqual(b, a, `${scenario} ${what}: what it answered`);
      assert.deepEqual(mbs.net.heard, ts.net.heard, `${scenario} ${what}: what each station asked of the other, in order`);
      for (const id of ["A", "B"] as const) {
        const named = (calls: string[]) => calls.map((c) => c.replace(/mbmove-station-(?:ts|mb)-([AB])-[A-Za-z0-9]+/g, "station-$1"));
        assert.deepEqual(named(mbs.st[id].w.calls), named(ts.st[id].w.calls), `${scenario} ${what}: what ${id} did`);
        const files = (dir: string) => Object.fromEntries(Object.entries(filesOf(dir)).map(([k, v]) => [k, v.split(dir).join("<data>")]));
        assert.deepEqual(files(mbs.st[id].data), files(ts.st[id].data), `${scenario} ${what}: the files ${id} keeps`);
      }
    };
    await both("refusal", (s) => s.made.A!.cmd("refusal", "ws", "B", "en"));
    await both("a move", (s) => s.made.A!.cmd("scheduler", { method: "move", args: ["ws", "B", { module: "chats", item: "chat:a1", withNeeds: true, follow: ["jobs"] }, "p@x"] }));
    await both("asked of the other in no turn", (s) => s.made.A!.cmd("roomForAll", "ws", "B", { items: [{ module: "chats", id: "chat:a1", state: "here" }, { module: "chats", id: "sl:C1:1", state: "here" }] }));
  }
});

// ── routes.ts ──

test("routes: GET /move's page of a plan at rest (each module's page, its done and cannot, a row's every field), POST /move, /move/back and /move/stop refused and begun as the TypeScript's", { skip }, async () => {
  const p = await mb();
  const plan = {
    ws: "ws", to: "B", modules: [{ id: "accounts", needs: [] }, { id: "chats", needs: ["accounts"] }, { id: "jobs", needs: ["chats"] }],
    items: [
      { module: "accounts", id: "a1", label: "A one", needs: [], state: "there", wouldStop: [] },
      { module: "accounts", id: "a2", label: "A two", needs: [], state: "here", cannot: "no", lentTo: "C", wouldStop: [{ module: "chats", id: "c1" }] },
      { module: "chats", id: "c1", label: "chat one", needs: [{ module: "accounts", id: "a2" }], state: "stopped", waitsFor: { module: "accounts", id: "a2", at: "C" }, at: "D", leaves: "x", wouldStop: [] },
      { module: "chats", id: "c2", label: "chat two", needs: [], state: "moving", progress: { done: 1, total: 2, unit: "bytes" }, waits: "turn", wouldStop: [] },
      { module: "chats", id: "c3", label: "chat three", needs: [], state: "moving", waits: "station", from: "C", error: "", wouldStop: [] },
      { module: "chats", id: "c4", label: "chat four", needs: [], state: "failed", error: "it failed", wouldStop: [] },
      { module: "jobs", id: "j1", label: "job", needs: [{ module: "chats", id: "c1" }], state: "here", wouldStop: [] },
    ],
  };
  const last = { at: 5, by: "p@x", how: "move", station: "B", stoppedBy: null, done: [{ module: "chats", id: "c1" }], refused: [{ item: { module: "chats", id: "c2", label: "x" }, why: "no" }], stopped: [{ item: { module: "jobs", id: "j1" }, waitsFor: { module: "chats", id: "c1" } }], resumed: [], failed: { item: null, error: "cut" }, failures: [{ item: { module: "chats", id: "c4" }, error: "e" }], returned: [{ module: "accounts", id: "a1" }], lent: [] };
  const names: Record<string, string> = { C: "Cee" };
  const name = (id: string) => names[id] ?? id.slice(0, 12);
  for (const o of [{}, { module: "chats", after: "c1", limit: 2 }, { module: "chats", after: "zz", limit: 0 }, { module: "accounts", limit: 500 }, { module: "jobs", after: "j1" }]) {
    for (const [l, current, stopping] of [[null, null, false], [last, { module: "chats", id: "c4" }, true]] as const) {
      const theirs = await p.cmd("view", { args: [{ plan, order: ["accounts", "chats", "jobs"], stopped: [{ item: { module: "jobs", id: "j1" }, waitsFor: { module: "chats", id: "c1" } }], ...o, last: l, stopping, current, names }] });
      const mine = moveView(plan as Json, ["accounts", "chats", "jobs"], [{ item: { module: "jobs", id: "j1" }, waitsFor: { module: "chats", id: "c1" } }], o, l as Json, stopping, name, current);
      assert.equal(JSON.stringify(theirs), JSON.stringify(mine), `the page ${JSON.stringify(o)} ${l === null ? "at rest" : "after a turn"}`);
    }
  }
  // (the routes over a station's moves: each side's, the same requests)
  const ts = await stations("ts");
  const mbs = await stations("mb");
  const { moveRoutes } = await import("../src/move/routes.ts");
  const routesTs = moveRoutes({
    scheduler: ts.made.A!.ts!.scheduler, order: () => ts.made.A!.ts!.modules.map((m) => m.id), home: () => "ws", here: () => "A", rig: () => false,
    station: (_ws, v) => { const r = ts.st.A.roster.find((x) => x.id === v || x.name === v); return r === undefined ? null : { id: r.id, tasks: false }; },
    name: (_ws, id) => ts.st.A.roster.find((x) => x.id === id)?.name || null,
    refusal: (ws, s, lang) => ts.made.A!.ts!.refusal(ws, s, lang),
  });
  const ask = async (s: "ts" | "mb", r: Json) => {
    if (s === "mb") return await mbs.made.A!.cmd("route", r);
    const route = routesTs.find((x) => x.method === r.method && x.pattern.test(r.path))!;
    const a = await route.handle({ method: r.method, path: r.path, query: r.query ?? [], headers: {}, body: Buffer.from(r.body === undefined || r.body === null ? "" : JSON.stringify(r.body)), viewer: { sub: "o", email: r.email ?? "o@x", name: "o", role: r.role ?? "owner", workspace: "ws", device: "d" } as Json, lang: r.lang ?? "en" } as Json, []);
    return { status: a.status, body: JSON.parse(String(a.body)) };
  };
  for (const r of [
    { method: "GET", path: "/move", query: [["to", "B"]] }, { method: "GET", path: "/move/", query: [["to", "Bee"], ["module", "chats"], ["limit", "1"]] }, { method: "GET", path: "/move", query: [["to", "nobody"]] }, { method: "GET", path: "/move", query: [["to", "B"], ["limit", "abc"]] },
    { method: "POST", path: "/move", body: { to: "B" }, role: "member" }, { method: "POST", path: "/move", body: { to: "nobody", module: "chats", item: "x" } }, { method: "POST", path: "/move", body: { to: "A", module: "chats", item: "x" } },
    { method: "POST", path: "/move", body: { to: "B" } }, { method: "POST", path: "/move/back", body: { from: "B", module: "chats" } }, { method: "POST", path: "/move/stop", body: {} },
    { method: "POST", path: "/move", body: { to: " B ", module: "accounts", item: "own:own@A" }, email: "p@x" },
  ]) {
    const [a, b] = [await ask("ts", r), await ask("mb", r)];
    await ts.quiet();
    await mbs.quiet();
    assert.deepEqual(b, a, `${r.method} ${r.path} ${JSON.stringify(r.body ?? r.query)}`);
  }
  assert.deepEqual(mbs.net.heard, ts.net.heard, "what each asked of the other");
  const viewAfter = { method: "GET", path: "/move", query: [["to", "B"]] };
  assert.deepEqual(await ask("mb", viewAfter), await ask("ts", viewAfter), "the page after the turn");
});
