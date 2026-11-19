// What a station shares with the others in MoonBit (station/mb/src/share_sync, `stillfail-reader-harness --builder
// harness-share-sync`) held to the TypeScript it replaces (src/share/index.ts `Sharing`, src/share/memory.ts
// `MemorySync`, src/xshare/index.ts `ChatShares`): one world of stations built twice, the TypeScript's here and the
// program's in its harness, each with the same config.json, files, rosters and clock, its stations talking to each
// other over a transport that calls the other directly (a handler's failure the asker's refusal, as mesh/peer.ts
// gives it). Each step is taken in both, and both are held to the same answers (a failure by its kind and words), the
// same state.json and config.json, the same files in each station's data (the copies, links, logins written, the
// memory's records and blobs) and the same chat_shares rows. A share's id is random on each side: an id new in a step
// is named for the step on both (`sh#1`), and a case names it so.
import assert from "node:assert/strict";
import { type ChildProcessWithoutNullStreams, spawn } from "node:child_process";
import { createHash } from "node:crypto";
import { chmodSync, existsSync, lstatSync, mkdirSync, mkdtempSync, readdirSync, readFileSync, readlinkSync, renameSync, rmSync, utimesSync, writeFileSync } from "node:fs";
import { createServer, type Server } from "node:http";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { createInterface } from "node:readline";
import { DatabaseSync } from "node:sqlite";
import { after, test } from "node:test";
import { type Clock, Duration, Effect } from "effect";
import { agyLentFile, agyExpiryIn } from "../src/agents/agy.ts";
import { Cloud } from "../src/cloud/state.ts";
import { Refused } from "../src/mesh/bus.ts";
import { ConfigFile } from "../src/ops/config.ts";
import { Said } from "../src/ops/i18n.ts";
import { allowedIn } from "../src/sessions/config.ts";
import { writeBuiltinSkills } from "../src/sessions/agent-home.ts";
import { Sharing, portable, shareRefusal, signInFiles } from "../src/share/index.ts";
import { MemorySync, asideSkill, memoryFollowed, memoryPath, recOf } from "../src/share/memory.ts";
import { mbReaderBinary } from "../src/read/mb-reader.ts";
import { mbHarnessBinary } from "./mb-harness.ts";
import { toChatShare } from "../src/store/rows.ts";
import { Store } from "../src/store/store.ts";
import { chatShareIndexReady, hasChatShareIndex } from "../src/store/chat-share-index.ts";
import { ChatShares } from "../src/xshare/index.ts";
import { ChatShareIndexBuilder } from "../src/xshare/index-builder.ts";
import { settle } from "./hub-fakes.ts";

const binary = mbReaderBinary();
/// (the tests' program, its harness: the station's own commands are the reader's)
const harnessProgram = mbHarnessBinary();
const skip = binary === null ? "the MoonBit program (stillfail-reader) is not built here" : harnessProgram === null ? "the tests' MoonBit program (stillfail-reader-harness) is not built here" : false;

const A = "a".repeat(64);
const B = "b".repeat(64);
const C = "c".repeat(64);
const T0 = 1_800_000_000_000;
/// The station's own skills, where both sides write them from into a joined workspace's agent home.
const SKILLS = fileURLToPath(new URL("../src/skills/", import.meta.url)).replace(/\/$/, "");
const HOUR = 3600_000;

const dirs: string[] = [];
const fresh = (what: string) => {
  const dir = mkdtempSync(join(tmpdir(), `share-sync-${what}-`));
  dirs.push(dir);
  return dir;
};
const closers: (() => Promise<void>)[] = [];
after(async () => {
  for (const close of closers.splice(0)) await close().catch(() => {});
  for (const dir of dirs) rmSync(dir, { recursive: true, force: true });
});

type Json = any;
type Answer = { ok: Json } | { error: string; kind: string };
const plain = (v: unknown) => (v === undefined ? null : JSON.parse(JSON.stringify(v)));

// ── a clock both worlds' parts go by ──

/// A Clock moved on by the test alone: each wait a timer, fired in its time's order as `advance` passes it.
class ManualClock implements Clock.Clock {
  now = T0;
  #seq = 0;
  timers: { due: number; seq: number; fire: () => void; off: boolean }[] = [];
  currentTimeMillisUnsafe = () => this.now;
  currentTimeMillis = Effect.sync(() => this.now);
  currentTimeNanosUnsafe = () => BigInt(this.now) * 1_000_000n;
  currentTimeNanos = Effect.sync(() => BigInt(this.now) * 1_000_000n);
  monotonicTimeNanosUnsafe = () => BigInt(this.now) * 1_000_000n;
  monotonicTimeNanos = Effect.sync(() => BigInt(this.now) * 1_000_000n);
  sleep = (duration: Duration.Duration) =>
    Effect.callback<void>((resume) => {
      const t = { due: this.now + Math.max(0, Duration.toMillis(duration)), seq: ++this.#seq, fire: () => resume(Effect.void), off: false };
      this.timers.push(t);
      return Effect.sync(() => void (t.off = true));
    });
  next(until: number) {
    let best = -1;
    this.timers.forEach((t, i) => {
      if (t.off || t.due > until) return;
      if (best < 0 || t.due < this.timers[best]!.due || (t.due === this.timers[best]!.due && t.seq < this.timers[best]!.seq)) best = i;
    });
    return best < 0 ? null : this.timers.splice(best, 1)[0]!;
  }
}


// ── the TypeScript's world ──

type TsStation = { id: string; data: string; agentHome: string; config: ConfigFile; sharing: Sharing; memory: MemorySync; xshare: ChatShares | null; store: Store | null; inbox: Json[]; said: Record<string, Json[]> };

class TsWorld {
  clock = new ManualClock();
  stations = new Map<string, TsStation>();
  order: string[] = [];
  rosters: Record<string, { id: string; name: string }[]> = {};
  homes: Record<string, string> = {};
  wsNames: Record<string, string> = {};
  names: Record<string, string> = {};
  machineEmails: Record<string, string> = {};
  down = new Set<string>();
  listeners = new Set<() => void>();
  peersCurrent = true;
  renewRunning = false;
  tokenUrl: string | undefined = undefined;

  homeOf(id: string) {
    return this.homes[id] ?? "w";
  }
  inRoster(ws: string, id: string) {
    return (this.rosters[ws] ?? []).some((p) => p.id === id);
  }
  cloudFor(station: string): Cloud {
    const world = this;
    return Object.defineProperties(Object.create(Cloud.prototype), Object.getOwnPropertyDescriptors({
      get peersCurrent() {
        return world.peersCurrent;
      },
      lock: null,
      get state() {
        const home = world.homeOf(station);
        const joined = Object.entries(world.rosters)
          .filter(([ws, peers]) => ws !== home && peers.some((p) => p.id === station))
          .map(([ws, peers]) => ({ workspace: ws, workspace_name: world.wsNames[ws] ?? ws, name: "", peers, revocations: [] }));
        return { station, name: world.names[station], workspace: home, workspace_name: world.wsNames[home] ?? home, peers: world.rosters[home] ?? [], revocations: [], joined } as any;
      },
      listen(f: () => void) {
        world.listeners.add(f);
        return () => world.listeners.delete(f);
      },
    })) as Cloud;
  }

  add(c: Json) {
    const { id, data, agentHome } = c;
    const config = new ConfigFile(data);
    const said: Record<string, Json[]> = {};
    const note = (what: string, v: Json) => (said[what] ??= []).push(v);
    const world = this;
    const sharing = new Sharing({
      data, config, cloud: this.cloudFor(id),
      ask: async (to, workspace, request) => {
        const other = this.stations.get(to);
        if (!other || this.down.has(to)) throw new Error("peer unavailable");
        const both = (ws: string) => this.inRoster(ws, id) && this.inRoster(ws, to);
        const ws = workspace ?? this.cloudFor(id).memberships().find((m) => both(m.workspace))?.workspace;
        if (ws === undefined || !both(ws)) throw new Error("peer is not another station in this workspace");
        try {
          return plain(await other.sharing.handle(id, plain(request), ws));
        } catch (e) {
          throw new Refused((e as Error).message);
        }
      },
      agentHome: () => agentHome,
      env: { CODEX_HOME: join(data, "machine", "codex") },
      machineEmail: (runtime) => this.machineEmails[`${id}/${runtime}`] ?? null,
      claudeToken: async (p) => (note("lent", p.id), { token: `token-of-${p.id}`, expiresAt: world.clock.now + 2 * HOUR }),
      codexRenewRunning: async () => world.renewRunning,
      status: async (pid) => ({ check: { state: "ok", detail: `checked ${pid}`, models: null, checkedAt: 1 }, quota: null }),
      changed: () => {},
      profileChanged: async (pid, reset) => void note("changed", [pid, reset]),
      quotaReset: async (pid) => void note("resets", pid),
      profileGone: async (pid) => void note("gone", pid),
      clock: this.clock,
      ...(this.tokenUrl === undefined ? {} : { codexTokenUrl: this.tokenUrl }),
      binary: binary!,
    });
    sharing.onHosted = (share, peer) => note("hosted", [share, peer]);
    const memory = new MemorySync({
      data, cloud: this.cloudFor(id), agentHome: () => agentHome, still: true, clock: this.clock, binary: binary!,
      ask: async (to, ws, request) => {
        const other = this.stations.get(to);
        if (!other || this.down.has(to)) throw new Error("peer unavailable");
        try {
          return plain(await other.memory.handle(id, plain(request), ws));
        } catch (e) {
          throw new Refused((e as Error).message);
        }
      },
    });
    let xshare: ChatShares | null = null;
    let store: Store | null = null;
    const inbox: Json[] = [];
    if (typeof c.db === "string") {
      store = Store.open(c.db, null, this.clock);
      const me = id;
      xshare = new ChatShares({
        data, store, cloud: this.cloudFor(id), clock: this.clock,
        ask: async (to, request) => {
          const other = this.stations.get(to);
          if (!other || this.down.has(to) || other.xshare === null) throw new Error("peer unavailable");
          const own = this.homeOf(me);
          const workspace = typeof request?.workspace === "string" ? request.workspace : own;
          if (workspace === own) {
            if (!this.inRoster(own, to) || this.homeOf(to) !== own) throw new Error("peer is not another station in this workspace");
            return plain(await other.xshare.inside(me, plain(request)));
          }
          if (!this.stations.get(me)!.xshare!.reaches(to, workspace)) throw new Error("that station is of another workspace that shares no chat with this one");
          if (this.homeOf(to) !== workspace) throw new Error("station is outside this workspace");
          try {
            return plain(await other.xshare.outside(me, plain(request)));
          } catch (e) {
            throw new Refused((e as Error).message);
          }
        },
        link: (chat) => `https://app.still.fail/o/${this.homeOf(me)}/${me}/${chat}`,
        title: (chat) => `title of ${chat}`,
        touches: (request) => [request?.args?.chat ?? request?.chat ?? request?.to].filter((x) => typeof x === "string"),
        inbox: async (peer, request) => (inbox.push({ peer, request: plain(request) }), { ok: true }),
      });
    }
    this.stations.set(id, { id, data, agentHome, config, sharing, memory, xshare, store, inbox, said });
    this.order.push(id);
  }

  async settle(only: string[]) {
    const which = only.length > 0 ? only : this.order;
    for (let i = 0; i < 4; i++) {
      await new Promise((r) => setImmediate(r));
      await Promise.all(which.flatMap((id) => {
        const s = this.stations.get(id)!;
        return [s.sharing.reconcile(), ...(s.xshare ? [s.xshare.reconcile()] : [])];
      }));
    }
    await settle();
    for (const id of which) {
      const s = this.stations.get(id)!;
      await s.sharing.stateWritten();
      await s.memory.written();
      await s.config.written();
    }
    await settle();
  }

  /// Until what a timer or a call set going (a pass bringing things in line) is over, nothing new begun for it.
  async idle() {
    for (let i = 0; i < 3; i++) {
      await settle();
      for (const id of this.order) {
        const s = this.stations.get(id)!;
        await (s.sharing as any).reconciling;
        await (s.xshare as any)?.reconciling;
      }
    }
  }

  async advance(ms: number) {
    const until = this.clock.now + ms;
    for (let t = this.clock.next(until); t !== null; t = this.clock.next(until)) {
      if (t.due > this.clock.now) this.clock.now = t.due;
      t.fire();
      await this.idle();
    }
    this.clock.now = until;
  }

  profile(s: TsStation, id: string) {
    const p = (s.config.raw().profiles ?? []).find((x: Json) => x.id === id);
    if (!p) throw new Error(`no profile ${id}`);
    return p;
  }

  async call(s: TsStation, part: string, method: string, args: Json[]): Promise<Json> {
    const a = (i: number) => (args[i] === null ? undefined : args[i]);
    if (part === "share") {
      const sh = s.sharing;
      switch (method) {
        case "shareProfile": return sh.shareProfile(a(0), a(1) === true, args[2] ?? null, args[3] ?? null, args[4] ?? null);
        case "shareSkill": return sh.shareSkill(a(0), a(1) === true, args[2] ?? null);
        case "moveProfile": return sh.moveProfile(a(0), a(1), a(2), a(3) === true ? async (share) => void (s.said.shareFirst ??= []).push(share) : undefined);
        case "lendTo": return sh.lendTo(a(0), a(1));
        case "unlend": return sh.unlend(a(0), a(1), a(2) === true, a(3) === true);
        case "unshareMoved": return sh.unshareMoved(a(0), a(1));
        case "lendClaude": return sh.lendClaude(this.profile(s, a(0)), a(1));
        case "lendCodex": return sh.lendCodex(this.profile(s, a(0)), a(1) === true);
        case "lendAgy": return sh.lendAgy(this.profile(s, a(0)), a(1) === true);
        case "status": return sh.status(this.profile(s, a(0)));
        case "loginUpdated": return sh.loginUpdated(a(0));
        case "quotaReset": return sh.quotaReset(a(0), a(1));
        case "profileView": return sh.profileView(this.profile(s, a(0)), a(1) ?? null);
        case "skillView": return sh.skillView(a(0));
        case "borrowedSubscription": return sh.borrowedSubscription(this.profile(s, a(0)));
        case "handle": return sh.handle(a(0), args[1], a(2));
        case "reconcile": return sh.reconcile();
        case "renewedBehind": return sh.renewedBehind(a(0));
      }
    }
    if (part === "memory") {
      switch (method) {
        case "levelNow": return s.memory.levelNow();
        case "handle": return s.memory.handle(a(0), args[1], a(2));
      }
    }
    if (part === "xshare" && s.xshare !== null) {
      const x = s.xshare;
      switch (method) {
        case "share": return x.share(a(0), args[1] ?? [], a(2) === true, a(3));
        case "trust": return x.trust(a(0), a(1), a(2), a(3), a(4));
        case "borrowed": return x.borrowed(a(0));
        case "inside": return x.inside(a(0), args[1], a(2));
        case "outside": return x.outside(a(0), args[1], a(2));
        case "address": return x.address(a(0), args[1]);
        case "reaches": return x.reaches(a(0), a(1));
        case "workspaceOf": return args.length > 1 ? x.workspaceOf(a(0), args[1]) : x.workspaceOf(a(0));
        case "send": return x.send(a(0), args[1], async (addressed) => {
          (s.said.sent ??= []).push(plain(addressed));
          if (args[2] === true) throw new Error("not taken");
          return { sent: addressed };
        });
        case "start": return x.start();
        case "indexBuild": {
          const builder = new ChatShareIndexBuilder(s.store!, Promise.resolve(), binary!);
          builder.request();
          await builder.settled();
          const answer = [hasChatShareIndex(s.store!.db), chatShareIndexReady(s.store!.db)];
          await builder.close();
          return answer;
        }
        case "reconcile": return x.reconcile();
        case "chatShares": return [...s.store!.chatShares()];
      }
    }
    throw new Error(`no ${part} method ${method}`);
  }

  snapshot(id: string) {
    const s = this.stations.get(id)!;
    const memory: Record<string, Json> = {};
    for (const m of this.cloudFor(id).memberships()) {
      const file = join(s.data, "share", "memory", `${m.workspace}.json`);
      if (existsSync(file)) memory[m.workspace] = JSON.parse(readFileSync(file, "utf8"));
    }
    return plain({
      config: s.config.raw(),
      share: (s.sharing as any).state ?? (s.sharing as any).readState(),
      xshare: s.xshare === null ? null : (s.xshare as any).readState(),
      memory,
      inbox: s.inbox,
      said: s.said,
    });
  }

  async run(c: Json): Promise<Answer> {
    try {
      return { ok: plain(await this.case(c)) };
    } catch (e) {
      return { error: (e as Error).message, kind: e instanceof Refused ? "refused" : e instanceof Said ? "said" : "error" };
    }
  }

  async case(c: Json): Promise<Json> {
    switch (c.op) {
      case "station": return this.add(c);
      case "cloud":
        if (c.rosters) this.rosters = structuredClone(c.rosters);
        Object.assign(this.homes, c.homes ?? {});
        Object.assign(this.wsNames, c.wsNames ?? {});
        Object.assign(this.names, c.names ?? {});
        if (typeof c.peersCurrent === "boolean") this.peersCurrent = c.peersCurrent;
        if (c.tell === true) {
          for (const f of [...this.listeners]) f();
          // The next snapshot includes the writes these roster listeners start.
          await this.idle();
        }
        return null;
      case "set":
        if (typeof c.renewRunning === "boolean") this.renewRunning = c.renewRunning;
        if (typeof c.tokenUrl === "string") this.tokenUrl = c.tokenUrl;
        for (const [k, v] of Object.entries(c.machineEmail ?? {})) {
          if (typeof v === "string") this.machineEmails[k] = v;
          else delete this.machineEmails[k];
        }
        return null;
      case "now": this.clock.now = c.at; return null;
      case "down": this.down.add(c.station); return null;
      case "up": this.down.delete(c.station); return null;
      case "call": {
        const s = this.stations.get(c.station);
        if (!s) throw new Error(`no station ${c.station}`);
        const answer = await this.call(s, c.part, c.method, c.args ?? []);
        await this.idle();
        return answer;
      }
      case "settle": return this.settle(c.stations ?? []);
      case "advance": return this.advance(c.ms);
      case "snapshot": return this.snapshot(c.station);
      case "close":
        for (const id of this.order) {
          const s = this.stations.get(id)!;
          await s.sharing.close();
          await s.memory.stop();
          await s.xshare?.close();
          s.store?.close();
        }
        return null;
    }
    throw new Error(`no op ${c.op}`);
  }
}

// ── the program's world ──

class MbWorld {
  child: ChildProcessWithoutNullStreams;
  waiting: ((line: string) => void)[] = [];
  stderr = "";
  constructor() {
    this.child = spawn(harnessProgram!, ["--builder", "harness-share-sync", "--shell-dir", fresh("shell")], { stdio: ["pipe", "pipe", "pipe"] });
    this.child.stderr.on("data", (d) => (this.stderr += d));
    // (a line that is no answer is the program saying it failed: the answer it stands for)
    createInterface({ input: this.child.stdout }).on("line", (line) => this.waiting.shift()?.(line.startsWith("{") ? line : JSON.stringify({ error: `the program said: ${line}`, kind: "ended" })));
    this.child.on("exit", (code) => {
      for (const w of this.waiting.splice(0)) w(JSON.stringify({ error: `the program ended (${code}): ${this.stderr}`, kind: "ended" }));
    });
    closers.push(async () => {
      this.child.stdin.end();
    });
  }
  run(c: Json): Promise<Answer> {
    return new Promise((resolve) => {
      this.waiting.push((line) => resolve(JSON.parse(line)));
      this.child.stdin.write(`${JSON.stringify(c)}\n`);
    });
  }
}

// ── one world, twice ──

const SHARE_ID = /sh-[0-9a-f]{20}/g;
const MOVED_ID = /moved-[0-9a-f]{8}/g;

/// What differs between the two worlds by nature taken out: where each is, and each random id named for the step it
/// first came in.
class Names {
  ids = new Map<string, string>();
  back = new Map<string, string>();
  /// Each directory's device and inode as a skill shared keeps it (`dir`), by where it is: the same on both sides.
  dirs = new Map<string, string>();
  readonly root: string;
  constructor(root: string) {
    this.root = root;
  }
  learn(texts: string[], step: number): string[] {
    const fresh: string[] = [];
    for (const text of texts) {
      for (const m of [...text.matchAll(SHARE_ID), ...text.matchAll(MOVED_ID)]) {
        if (!this.ids.has(m[0]) && !fresh.includes(m[0])) fresh.push(m[0]);
      }
    }
    fresh.forEach((id, i) => {
      const name = `<${id.startsWith("sh-") ? "sh" : "moved"} ${step}${fresh.length > 1 ? `.${i}` : ""}>`;
      this.ids.set(id, name);
      this.back.set(name, id);
    });
    return fresh;
  }
  text(s: string): string {
    return s.split(this.root).join("<root>").replace(SHARE_ID, (id) => this.ids.get(id) ?? id).replace(MOVED_ID, (id) => this.ids.get(id) ?? id);
  }
  value(v: Json): Json {
    if (typeof v === "string") return this.dirs.get(v) ?? this.text(v);
    if (Array.isArray(v)) return v.map((x) => this.value(x));
    if (v !== null && typeof v === "object") return Object.fromEntries(Object.entries(v).map(([k, x]) => [this.text(k), this.value(x)]));
    return v;
  }
  /// A case as this world takes it: the names of its ids and `<root>` given back.
  unname(v: Json): Json {
    if (typeof v === "string") {
      let s = v.split("<root>").join(this.root);
      for (const [name, id] of this.back) s = s.split(name).join(id);
      return s;
    }
    if (Array.isArray(v)) return v.map((x) => this.unname(x));
    if (v !== null && typeof v === "object") return Object.fromEntries(Object.entries(v).map(([k, x]) => [this.unname(k), this.unname(x)]));
    return v;
  }
}

/// A station's files as they are: each path under its data with what it is (a file's text and mode, a link's target,
/// a directory), JSON read as values; what a write leaves for a moment left out.
function filesOf(root: string, dirs?: Map<string, string>): Record<string, Json> {
  const out: Record<string, Json> = {};
  const walk = (rel: string) => {
    const at = rel === "" ? root : join(root, rel);
    for (const name of readdirSync(at).sort()) {
      const sub = rel === "" ? name : `${rel}/${name}`;
      if (name.endsWith(".tmp") || name.endsWith(".memory-tmp") || name.startsWith("stillfail.db") || name === "config.json" || /\.json\.tmp-/.test(name)) continue;
      if (/^shell$/.test(sub)) continue;
      const st = lstatSync(join(root, sub));
      if (st.isSymbolicLink()) out[sub] = { link: readlinkSync(join(root, sub)) };
      else if (st.isDirectory()) {
        out[sub] = "dir";
        const big = lstatSync(join(root, sub), { bigint: true });
        dirs?.set(`${big.dev}:${big.ino}`, `<dir ${sub}>`);
        walk(sub);
      } else {
        const text = readFileSync(join(root, sub), "utf8");
        let value: Json = text;
        if (name.endsWith(".json")) try { value = JSON.parse(text); } catch {}
        out[sub] = { mode: (st.mode & 0o777).toString(8), value };
      }
    }
  };
  walk("");
  return out;
}

/// The chat_shares rows of a station's database, and the deadlines' lookup made of them where it is.
function sharesOf(db: string): Json[] {
  if (!existsSync(db)) return [];
  const d = new DatabaseSync(db, { readOnly: true });
  try {
    const rows: Json[] = d.prepare("SELECT session, shared, write, by, at FROM chat_shares ORDER BY session").all().map((r) => ({ ...r }));
    if (d.prepare("SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'chat_share_index_meta'").get() !== undefined) {
      rows.push({
        meta: d.prepare("SELECT version, phase, cursor, end_session FROM chat_share_index_meta").all().map((r) => ({ ...r })),
        targets: d.prepare("SELECT session, ordinal, workspace, used FROM chat_share_targets ORDER BY session, ordinal").all().map((r) => ({ ...r })),
        uncertain: d.prepare("SELECT session FROM chat_share_uncertain ORDER BY session").all().map((r) => ({ ...r })),
        dirty: d.prepare("SELECT session FROM chat_share_dirty ORDER BY session").all().map((r) => ({ ...r })),
      });
    }
    return rows;
  } finally {
    d.close();
  }
}

type Spec = { id: string; name?: string; config?: Json; db?: boolean };

class Twin {
  ts = new TsWorld();
  mb = new MbWorld();
  roots = { ts: fresh("ts"), mb: fresh("mb") };
  names = { ts: new Names(""), mb: new Names("") };
  step = 0;
  specs: Spec[] = [];
  constructor() {
    this.names.ts = new Names(this.roots.ts);
    this.names.mb = new Names(this.roots.mb);
    closers.push(async () => {
      await this.ts.run({ op: "close" });
    });
  }
  data(world: "ts" | "mb", id: string) {
    return join(this.roots[world], id.slice(0, 1), "data");
  }
  /// A file written in a station's data on both sides, at the same time.
  write(id: string, rel: string, text: string | Buffer, mode?: number) {
    for (const world of ["ts", "mb"] as const) {
      const path = join(this.data(world, id), this.names[world].unname(rel));
      mkdirSync(join(path, ".."), { recursive: true });
      writeFileSync(path, text);
      if (mode !== undefined) chmodSync(path, mode);
      utimesSync(path, new Date(T0 - HOUR), new Date(T0 - HOUR));
    }
  }
  /// A file or directory moved or taken away on both sides.
  rename(id: string, from: string, to: string) {
    for (const world of ["ts", "mb"] as const) renameSync(join(this.data(world, id), from), join(this.data(world, id), to));
  }
  remove(id: string, rel: string) {
    for (const world of ["ts", "mb"] as const) rmSync(join(this.data(world, id), this.names[world].unname(rel)), { recursive: true, force: true });
  }
  async stations(specs: Spec[], cloud: Json) {
    await this.both({ op: "cloud", ...cloud });
    await this.both({ op: "now", at: T0 });
    for (const s of specs) {
      for (const world of ["ts", "mb"] as const) {
        const data = this.data(world, s.id);
        mkdirSync(join(data, "agent", "skills"), { recursive: true });
        writeFileSync(join(data, "config.json"), JSON.stringify(s.config ?? { profiles: [] }));
        if (s.db) {
          // (the station's database as the store makes it, for each side's chat_shares)
          if (world === "mb") Store.open(join(data, "stillfail.db"), null, this.ts.clock).close();
        }
      }
    }
    for (const s of specs) {
      const make = (world: "ts" | "mb") => ({ op: "station", id: s.id, data: this.data(world, s.id), agentHome: join(this.data(world, s.id), "agent"), skillsSource: SKILLS, ...(s.db ? { db: join(this.data(world, s.id), "stillfail.db") } : {}) });
      const [t, m] = [await this.ts.run(make("ts")), await this.mb.run(make("mb"))];
      assert.deepEqual(m, t, `station ${s.id.slice(0, 1)}`);
    }
    this.specs.push(...specs);
    if (specs.some((s) => s.name)) await this.both({ op: "cloud", names: Object.fromEntries(specs.filter((s) => s.name).map((s) => [s.id, s.name])) });
  }
  /// One step in both worlds: the same answer (a failure by its kind and words), then the same stations.
  async both(c: Json, what = JSON.stringify(c).slice(0, 160)): Promise<Json> {
    this.step++;
    const t = await this.ts.run(this.names.ts.unname(c));
    const m = await this.mb.run(this.names.mb.unname(c));
    await this.same(what, t, m);
    if (process.env.SHARE_SYNC_TRACE) process.stderr.write(`${this.step} ${what.slice(0, 110)}\n    => ${JSON.stringify(this.names.ts.value(t)).slice(0, 300)}\n`);
    return this.names.ts.value("ok" in t ? t.ok : t);
  }
  /// The two worlds compared now, after `t` and `m` (what each answered last).
  async same(what: string, t: Answer, m: Answer) {
    const texts = { ts: [JSON.stringify(t)], mb: [JSON.stringify(m)] };
    const states: Record<"ts" | "mb", Json[]> = { ts: [], mb: [] };
    for (const s of this.specs) {
      const station = this.ts.stations.get(s.id)!;
      await station.sharing.stateWritten();
      await station.memory.written();
      await station.config.written();
      await (station.xshare as any)?.file?.written();
      const ts = this.ts.snapshot(s.id);
      const mb = await this.mb.run({ op: "snapshot", station: s.id });
      if (!("ok" in mb)) assert.fail(`${what}: the program's snapshot failed: ${JSON.stringify(mb)}`);
      const tf = filesOf(this.data("ts", s.id), this.names.ts.dirs);
      const mf = filesOf(this.data("mb", s.id), this.names.mb.dirs);
      const ts_ = this.ts.stations.get(s.id)!;
      const tr = ts_.store === null ? [] : sharesOf(join(this.data("ts", s.id), "stillfail.db"));
      const mr = s.db ? sharesOf(join(this.data("mb", s.id), "stillfail.db")) : [];
      states.ts.push({ state: ts, files: tf, rows: tr });
      states.mb.push({ state: mb.ok, files: mf, rows: mr });
      texts.ts.push(JSON.stringify(ts), JSON.stringify(tf), JSON.stringify(tr));
      texts.mb.push(JSON.stringify(mb.ok), JSON.stringify(mf), JSON.stringify(mr));
    }
    const nt = this.names.ts.learn(texts.ts, this.step);
    const nm = this.names.mb.learn(texts.mb, this.step);
    assert.equal(nm.length, nt.length, `${what}: as many new ids`);
    assert.deepEqual(this.names.mb.value(m), this.names.ts.value(t), `${what}: the answer`);
    this.specs.forEach((s, i) => {
      const tsv = this.names.ts.value(states.ts[i]);
      const mbv = this.names.mb.value(states.mb[i]);
      for (const k of ["state", "files", "rows"]) assert.deepEqual(mbv[k], tsv[k], `${what}: station ${s.id.slice(0, 1)}'s ${k}`);
    });
  }
}

const jwt = (claims: object) => ["{}", JSON.stringify(claims), "s"].map((p) => Buffer.from(p).toString("base64url")).join(".");

// ── the pure functions ──

test("what a profile is lent, refused and served by, a memory's paths and records, a kept-apart skill: as the TypeScript says", { skip }, async () => {
  const mb = new MbWorld();
  const pure = async (fn: string, value: Json, more: Json = {}) => {
    const a = await mb.run({ op: "pure", fn, value, ...more });
    if (!("ok" in a)) assert.fail(`${fn}: ${a.error}`);
    return a.ok;
  };
  const profiles: Json[] = [
    { runtime: "claude", access: { kind: "subscription" } }, { access: { kind: "subscription" } }, { runtime: "codex", access: { kind: "subscription" } },
    { runtime: "grok", access: { kind: "subscription" } }, { runtime: "cursor", access: { kind: "subscription" } }, { runtime: "devin", access: { kind: "subscription" } },
    { runtime: "agy", access: { kind: "subscription" } }, { access: { kind: "opencode-go", login: true } }, { access: { kind: "api-provider", provider: "kimi-code", login: true } },
    { access: { kind: "api-provider", provider: "deepseek", key: "k" }, name: "n", env: { A: "1" }, home: "h", models: ["x"], enabled: false, fast: true },
    { access: { kind: "subscription", key: "secret" }, runtime: "claude", model: null }, { share: { borrowed: true } }, {},
    { runtime: "codex", access: { kind: "subscription" }, env: { HTTP_PROXY: "http://127.0.0.1:7890", https_proxy: "http://127.0.0.1:7890", All_Proxy: "socks5://127.0.0.1:7891", NO_PROXY: "corp.example", no_proxy: "x", KEEP: "1", MY_HTTP_PROXY: "y", HTTP_PROXY_2: "z" } },
  ];
  for (const p of profiles) {
    assert.deepEqual(await pure("signInFiles", p), signInFiles(p), JSON.stringify(p));
    assert.deepEqual(await pure("shareRefusal", p), shareRefusal(p), JSON.stringify(p));
    assert.deepEqual(await pure("portable", p), portable(p), JSON.stringify(p));
  }
  // A machine's proxy stays on its machine: another station has its own way out, or none.
  assert.deepEqual(portable(profiles.at(-1)!).env, { KEEP: "1", MY_HTTP_PROXY: "y", HTTP_PROXY_2: "z" });
  assert.equal("env" in portable({ runtime: "claude" }), false);
  for (const [p, ws, home] of [[{ share: { borrowed: true, workspaces: ["a"] } }, "b", "a"], [{ share: { borrowed: true, workspaces: ["a"] } }, null, "a"], [{ withheld: ["j"] }, "j", "h"], [{ withheld: ["j"] }, "h", "h"], [{}, "x", null], [{ share: { borrowed: true, workspaces: ["b"] } }, null, "a"]] as const) {
    assert.equal(await pure("allowedIn", p, { ws, home }), allowedIn(p as Json, ws, home), JSON.stringify([p, ws, home]));
  }
  for (const path of ["MEMORY.md", "skills/a/SKILL.md", "skills/stillfail-jobs/SKILL.md", "skills/a/.x", "skills/a/node_modules/x", "skills/a", "other/x/y", "skills/con/x", "skills/a/b c/d", 5, "x".repeat(600)]) {
    assert.equal(await pure("memoryPath", path), memoryPath(path), String(path));
  }
  const h = "a".repeat(64);
  for (const r of [{ hash: h, at: 1, by: h, prev: [], size: 1, mode: 0o644 }, { hash: "", at: 0, by: h, prev: [h], size: 0, mode: 0o755, origin: true }, { hash: h, at: 1.5, by: h, prev: [], size: 1, mode: 0o644 }, { hash: h, at: 1, by: "x", prev: [], size: 1, mode: 0o644 }, { hash: h, at: 1, by: h, prev: [], size: 1, mode: 0o600 }, { hash: h, at: 1, by: h, prev: [], size: 600_000, mode: 0o644 }, null, "x"]) {
    assert.deepEqual(await pure("recOf", r), plain(recOf(r)), JSON.stringify(r));
  }
  for (const rel of ["skills", "skills/a", "skills/a/b", "skills/stillfail-jobs", "workspaces", "workspaces/W1", "workspaces/W1/skills/a", "workspaces/a b", "repo", "skills/.git", "workspaces/W1/repo"]) {
    assert.equal(await pure("memoryFollowed", rel), memoryFollowed(rel), rel);
  }
  for (const text of ["---\nname: deploy\ndescription: Deploys\n---\nbody\n", "no front matter\n", "---\ndescription:   x\n---\n", "---\nname: a\n---", "---\n\n---\nrest", "---\r\nname: a\r\n---\n"]) {
    assert.equal(await pure("asideSkill", text, { name: "deploy-mini", station: "mini" }), asideSkill(Buffer.from(text), "deploy-mini", "mini").toString("utf8"), text);
  }
  for (const text of [JSON.stringify({ token: { expiry: "2026-11-17T05:00:00.123456Z" } }), JSON.stringify({ token: { expiry: "2026-11-17T13:00:00+08:00" } }), JSON.stringify({ token: {} }), "not json", JSON.stringify({ token: { expiry: "2026-11-17" } })]) {
    assert.equal(await pure("agyExpiryIn", text), agyExpiryIn(text), text);
  }
  for (const lent of [{ token: { access_token: "a", refresh_token: "r" }, email: "e@x", auth_method: null, stored: { project_id: "p", auth_method: "gcp", token: "old" } }, { token: { access_token: "a" } }, { token: null, email: "" }]) {
    assert.equal(await pure("agyLentFile", lent), agyLentFile(lent as Json), JSON.stringify(lent));
  }
  for (const ms of [0, T0, 1795400000123, -1, 253402300800000]) assert.equal(await pure("isoString", ms), new Date(ms).toISOString(), String(ms));
  for (const v of [{ b: 1, "2": [1, 2], a: {}, "10": null, "01": "x" }, [1.5, -0, 1e21, 1e-7, " \u0000\"", { x: [] }], "é", 12345678901234567890]) {
    assert.equal(await pure("stringify", v), JSON.stringify(v), JSON.stringify(v));
    assert.equal(await pure("stringify2", v), JSON.stringify(v, null, 2), JSON.stringify(v));
  }
  for (const row of [{ session: "s", shared: JSON.stringify([{ workspace: "w", name: "n", used: 5 }, { workspace: "v" }, { name: "x" }]), write: 1, by: "p", at: 3 }, { session: "s", shared: "not json", write: 0, by: "p", at: 3 }, { session: "s", shared: JSON.stringify({}), write: 0, by: null, at: 1 }]) {
    assert.deepEqual(await pure("toChatShare", row), plain(toChatShare(row)), JSON.stringify(row));
  }
  mb.child.stdin.end();
});

// ── profiles ──

const KEY = { id: "deepseek", name: "DeepSeek", access: { kind: "api-provider", provider: "deepseek", key: "sk-secret" }, home: "homes/deepseek", env: {} };
const SUB = { id: "max", name: "Claude Max", runtime: "claude", access: { kind: "subscription" }, home: "homes/max", env: {} };
const CODEX = { id: "plus", name: "ChatGPT Plus", runtime: "codex", access: { kind: "subscription" }, home: "homes/plus", env: {} };
const AGY = { id: "gem", name: "Google", runtime: "agy", access: { kind: "subscription" }, home: "homes/gem", env: {} };
const OWN = { id: "pro", name: "Claude Pro", runtime: "claude", access: { kind: "subscription" }, home: "homes/pro", env: {} };
const OWN2 = { id: "pro2", name: "Claude Pro 2", runtime: "claude", access: { kind: "subscription" }, home: "homes/pro2", env: {} };
const GROK = { id: "grok", name: "SuperGrok", runtime: "grok", access: { kind: "subscription" }, home: "homes/grok", env: {} };
const MACHINE = { id: "machine-claude", name: "This machine", runtime: "claude", access: { kind: "subscription" }, machine: true, env: {} };
const roster = (...ids: string[]) => ids.map((id) => ({ id, name: { [A]: "studio", [B]: "mini", [C]: "laptop" }[id]! }));

test("profiles shared, narrowed, lent, reset, moved and handed over: the program does as the TypeScript did", { skip }, async () => {
  const w = new Twin();
  const server: Server = createServer((req, res) => {
    let body = "";
    req.on("data", (d) => (body += d));
    req.on("end", () => {
      const asked = JSON.parse(body);
      res.writeHead(asked.refresh_token === "r" ? 200 : 400, { "content-type": "application/json" });
      res.end(JSON.stringify({ access_token: jwt({ exp: Math.floor((T0 + 3 * 86400_000) / 1000) }), id_token: jwt({ email: "renewed@x.test" }), refresh_token: "r2" }));
    });
  });
  await new Promise<void>((r) => server.listen(0, "127.0.0.1", r));
  closers.push(() => new Promise((r) => server.close(() => r())));
  const url = `http://127.0.0.1:${(server.address() as Json).port}/oauth/token`;
  await w.both({ op: "set", tokenUrl: url });
  w.ts.tokenUrl = url;
  await w.stations(
    [{ id: A, config: { profiles: [KEY, SUB, CODEX, AGY, OWN, OWN2, GROK, MACHINE] } }, { id: B }, { id: C, config: { profiles: [{ ...OWN, id: "mine", home: "homes/mine" }] } }],
    { rosters: { w: roster(A, B, C), j: roster(A, B) }, homes: {}, wsNames: { w: "Team", j: "Joined" } },
  );
  // Logins in their homes: Claude's account, Codex's (two days), the Antigravity CLI's (an hour).
  w.write(A, "homes/max/.claude.json", JSON.stringify({ oauthAccount: { emailAddress: "max@x.test" } }));
  w.write(A, "homes/max/.credentials.json", JSON.stringify({ claudeAiOauth: { accessToken: "a" } }), 0o600);
  w.write(A, "homes/pro/.claude.json", JSON.stringify({ oauthAccount: { emailAddress: "pro@x.test" } }));
  w.write(A, "homes/pro/.credentials.json", JSON.stringify({ claudeAiOauth: { accessToken: "p" } }), 0o600);
  w.write(A, "homes/pro2/.claude.json", JSON.stringify({ oauthAccount: { emailAddress: "pro2@x.test" } }));
  w.write(A, "homes/pro2/.credentials.json", JSON.stringify({ claudeAiOauth: { accessToken: "p2" } }), 0o600);
  w.write(C, "homes/mine/.claude.json", JSON.stringify({ oauthAccount: { emailAddress: "pro@x.test" } }));
  w.write(A, "homes/plus/auth.json", JSON.stringify({ tokens: { id_token: jwt({ email: "plus@x.test" }), access_token: jwt({ exp: Math.floor((T0 + 2 * 86400_000) / 1000) }), account_id: "acct", refresh_token: "r" } }));
  const signIn = (access: string, minutes: number) => JSON.stringify({ token: { access_token: access, token_type: "Bearer", refresh_token: "refresh-here", expiry: new Date(T0 + minutes * 60_000).toISOString(), expires_in: 3599 }, auth_method: "consumer", id_token_email: "someone@gmail.test" });
  w.write(A, "homes/gem/agy/.gemini/antigravity-cli/antigravity-oauth-token", signIn("first", 60));

  // A key profile shared with every station, then narrowed to one, then a person's choice among some of them.
  await w.both({ op: "call", station: A, part: "share", method: "shareProfile", args: ["deepseek", true, null] });
  await w.both({ op: "settle" });
  await w.both({ op: "call", station: A, part: "share", method: "shareProfile", args: ["deepseek", true, [A, B]] });
  await w.both({ op: "settle" });
  await w.both({ op: "call", station: A, part: "share", method: "shareProfile", args: ["deepseek", true, null, [B, C], "someone"] });
  await w.both({ op: "settle" });
  await w.both({ op: "call", station: A, part: "share", method: "shareProfile", args: ["deepseek", true, [B], [B, C], "someone"] });
  await w.both({ op: "settle" });
  await w.both({ op: "call", station: A, part: "share", method: "profileView", args: ["deepseek"] });
  // Seen from a workspace's member: only this station and that workspace's (C is not in j).
  await w.both({ op: "call", station: A, part: "share", method: "profileView", args: ["deepseek", "j"] });
  await w.both({ op: "call", station: A, part: "share", method: "profileView", args: ["deepseek", "w"] });
  // What cannot be shared, said so.
  await w.both({ op: "call", station: A, part: "share", method: "shareProfile", args: ["grok", true, null] });
  await w.both({ op: "call", station: A, part: "share", method: "shareProfile", args: ["nobody", true, null] });

  // A Claude subscription lent; its host away, the token lent before used while it lasts.
  await w.both({ op: "call", station: A, part: "share", method: "shareProfile", args: ["max", true, null] });
  await w.both({ op: "settle" });
  const max = (await w.both({ op: "snapshot", station: B })).config.profiles.find((p: Json) => p.name === "Claude Max").id;
  await w.both({ op: "call", station: B, part: "share", method: "lendClaude", args: [max] });
  await w.both({ op: "call", station: B, part: "share", method: "status", args: [max] });
  await w.both({ op: "call", station: B, part: "share", method: "profileView", args: [max] });
  await w.both({ op: "call", station: B, part: "share", method: "profileView", args: [max, "j"] });
  await w.both({ op: "call", station: B, part: "share", method: "borrowedSubscription", args: [max] });
  await w.both({ op: "down", station: A });
  await w.both({ op: "call", station: B, part: "share", method: "lendClaude", args: [max] });
  await w.both({ op: "call", station: B, part: "share", method: "lendClaude", args: [max, `token-of-max`] });
  await w.both({ op: "advance", ms: 1.5 * HOUR });
  await w.both({ op: "call", station: B, part: "share", method: "lendClaude", args: [max] });
  await w.both({ op: "call", station: B, part: "share", method: "status", args: [max] });
  await w.both({ op: "settle" });
  await w.both({ op: "up", station: A });
  await w.both({ op: "advance", ms: 2 * 60_000 });
  await w.both({ op: "settle" });

  // A machine's own login carries its account to its copies.
  await w.both({ op: "set", machineEmail: { [`${A}/claude`]: "machine@x.test" } });
  await w.both({ op: "call", station: A, part: "share", method: "shareProfile", args: ["machine-claude", true, null] });
  await w.both({ op: "settle" });

  // A Codex subscription lent, renewed on its host first once it runs out within a day; a reset sent to its host.
  await w.both({ op: "call", station: A, part: "share", method: "shareProfile", args: ["plus", true, null] });
  await w.both({ op: "settle" });
  const plus = (await w.both({ op: "snapshot", station: B })).config.profiles.find((p: Json) => p.name === "ChatGPT Plus").id;
  await w.both({ op: "call", station: B, part: "share", method: "lendCodex", args: [plus] });
  await w.both({ op: "advance", ms: 30 * HOUR });
  await w.both({ op: "call", station: B, part: "share", method: "lendCodex", args: [plus] });
  await w.both({ op: "call", station: A, part: "share", method: "renewedBehind", args: ["plus"] });
  await w.both({ op: "settle" });
  await w.both({ op: "call", station: B, part: "share", method: "quotaReset", args: [plus, "k1"] });
  await w.both({ op: "settle" });
  await w.both({ op: "call", station: B, part: "share", method: "quotaReset", args: [plus, "k1"] });
  await w.both({ op: "settle" });

  // An Antigravity CLI sign-in lent without its refresh token; one about to run out, with nothing here to renew it, not.
  await w.both({ op: "call", station: A, part: "share", method: "shareProfile", args: ["gem", true, null] });
  await w.both({ op: "settle" });
  const gem = (await w.both({ op: "snapshot", station: B })).config.profiles.find((p: Json) => p.name === "Google").id;
  w.write(A, "homes/gem/agy/.gemini/antigravity-cli/antigravity-oauth-token", signIn("second", 32 * 60 + 60));
  await w.both({ op: "call", station: B, part: "share", method: "lendAgy", args: [gem] });
  w.write(A, "homes/gem/agy/.gemini/antigravity-cli/antigravity-oauth-token", signIn("third", 32 * 60 + 20));
  await w.both({ op: "call", station: B, part: "share", method: "lendAgy", args: [gem] });
  await w.both({ op: "call", station: A, part: "share", method: "loginUpdated", args: ["max"] });
  await w.both({ op: "settle" });

  // Moved: a shared key profile to B (A keeps a copy of it, borrowed from B now); its own to C (C has one of the same
  // account already); a subscription shared first as it moves, and that share undone once it is home.
  await w.both({ op: "call", station: A, part: "share", method: "moveProfile", args: ["max", A] });
  await w.both({ op: "call", station: A, part: "share", method: "moveProfile", args: ["machine-claude", B] });
  await w.both({ op: "call", station: A, part: "share", method: "moveProfile", args: ["nobody", B, "en"] });
  await w.both({ op: "call", station: A, part: "share", method: "moveProfile", args: ["max", B] });
  await w.both({ op: "settle" });
  await w.both({ op: "call", station: A, part: "share", method: "moveProfile", args: ["pro", C] });
  await w.both({ op: "settle" });
  const back = (await w.both({ op: "snapshot", station: B })).config.profiles.find((p: Json) => p.name === "Claude Max").id;
  await w.both({ op: "call", station: B, part: "share", method: "moveProfile", args: [back, A] });
  await w.both({ op: "settle" });
  await w.both({ op: "call", station: A, part: "share", method: "moveProfile", args: ["deepseek", C] });
  await w.both({ op: "settle" });

  // Lent to a station for a move's sake, and that undone.
  const lent = await w.both({ op: "call", station: A, part: "share", method: "lendTo", args: ["gem", C] });
  await w.both({ op: "settle" });
  await w.both({ op: "call", station: A, part: "share", method: "unlend", args: [lent.share, C, lent.made, lent.widened] });
  await w.both({ op: "settle" });
  await w.both({ op: "call", station: A, part: "share", method: "shareProfile", args: ["gem", false, null] });
  await w.both({ op: "settle" });
  const lent2 = await w.both({ op: "call", station: A, part: "share", method: "lendTo", args: ["gem", B] });
  await w.both({ op: "settle" });
  await w.both({ op: "call", station: A, part: "share", method: "unshareMoved", args: [lent2.share, [A, B]] });
  await w.both({ op: "settle" });

  // One not shared, moved with its share made first (a migration's): A borrows it from B, and once it is back home the
  // share is undone; one shared with A alone lent to C widens it, and that undone.
  await w.both({ op: "call", station: A, part: "share", method: "moveProfile", args: ["pro2", B, "zh", true] });
  await w.both({ op: "settle" });
  const pro2 = (await w.both({ op: "snapshot", station: B })).config.profiles.find((p: Json) => p.name === "Claude Pro 2");
  assert.equal(pro2.share.allow.length, 2, "shared with the two stations of the move alone");
  await w.both({ op: "call", station: B, part: "share", method: "moveProfile", args: [pro2.id, A] });
  await w.both({ op: "settle" });
  await w.both({ op: "call", station: A, part: "share", method: "unshareMoved", args: [pro2.share.id, [A, B]] });
  await w.both({ op: "settle" });
  await w.both({ op: "call", station: A, part: "share", method: "shareProfile", args: ["gem", true, [A]] });
  await w.both({ op: "settle" });
  const widened = await w.both({ op: "call", station: A, part: "share", method: "lendTo", args: ["gem", C] });
  assert.deepEqual([widened.made, widened.widened], [false, true]);
  await w.both({ op: "settle" });
  await w.both({ op: "call", station: A, part: "share", method: "unlend", args: [widened.share, C, false, true] });
  await w.both({ op: "settle" });

  // A station leaves the workspace: what it had of another's is taken away, what was shared with it forgotten.
  await w.both({ op: "cloud", rosters: { w: roster(A, B), j: roster(A, B) }, tell: true });
  await w.both({ op: "settle" });
  await w.both({ op: "call", station: A, part: "share", method: "handle", args: [B, { method: "share.version", id: "sh-00000000000000000000" }] });
  await w.both({ op: "call", station: A, part: "share", method: "handle", args: [B, { method: "share.changed", id: "bad" }] });
  await w.both({ op: "close" });
});

// ── skills ──

const SKILL = "---\nname: deploy\ndescription: Deploys the thing\n---\n\nRun ./go.sh.\n";

test("skills shared, linked where they are copied, edited from a copy (on an older one, kept beside it), renamed and taken away: as the TypeScript does", { skip }, async () => {
  const w = new Twin();
  await w.stations([{ id: A }, { id: B }, { id: C }], { rosters: { w: roster(A, B, C), j: roster(A, B) }, homes: { [C]: "w" }, wsNames: { w: "Team" } });
  w.write(A, "agent/skills/deploy/SKILL.md", SKILL);
  w.write(A, "agent/skills/deploy/go.sh", "#!/bin/sh\necho go\n", 0o755);
  w.write(A, "agent/skills/con/SKILL.md", "---\nname: con\n---\n");
  w.write(A, "agent/skills/big/SKILL.md", "x".repeat(600 * 1024));
  w.write(C, "agent/skills/deploy/SKILL.md", "---\nname: deploy\ndescription: C's own\n---\n");
  await w.both({ op: "call", station: A, part: "share", method: "shareSkill", args: ["deploy", true, null] });
  await w.both({ op: "call", station: A, part: "share", method: "shareSkill", args: ["nothing", true, null] });
  await w.both({ op: "call", station: A, part: "share", method: "shareSkill", args: ["con", true, null] });
  await w.both({ op: "call", station: A, part: "share", method: "shareSkill", args: ["big", true, null] });
  await w.both({ op: "settle" });
  await w.both({ op: "settle" });
  await w.both({ op: "call", station: A, part: "share", method: "skillView", args: ["deploy"] });
  await w.both({ op: "call", station: B, part: "share", method: "skillView", args: ["deploy"] });
  await w.both({ op: "call", station: C, part: "share", method: "skillView", args: ["deploy"] });
  const id = (await w.both({ op: "snapshot", station: A })).config.sharedSkills.deploy.id;
  // An edit from B on the version it has: taken; one on an older version: kept beside it.
  const files = { "SKILL.md": Buffer.from(SKILL.replace("Run", "Run it with")).toString("base64"), "go.sh": Buffer.from("#!/bin/sh\necho went\n").toString("base64") };
  const version = (await w.both({ op: "snapshot", station: A })).share.hosted[id].version;
  await w.both({ op: "call", station: A, part: "share", method: "handle", args: [B, { method: "share.put", id, base: version, files }] });
  await w.both({ op: "settle" });
  await w.both({ op: "call", station: A, part: "share", method: "handle", args: [B, { method: "share.put", id, base: version, files: { "SKILL.md": Buffer.from("older\n").toString("base64") } }] });
  await w.both({ op: "settle" });
  await w.both({ op: "call", station: A, part: "share", method: "handle", args: [B, { method: "share.put", id, base: 0, files: { "../x": Buffer.from("out").toString("base64") } }] });
  const conflict = readdirSync(join(w.data("ts", A), "agent", "skills", "deploy")).filter((n) => n.startsWith("SKILL.conflict-"));
  assert.equal(conflict.length, 1, "the edit on an older copy kept beside the skill");
  assert.ok(lstatSync(join(w.data("ts", B), "agent", "skills", "deploy")).isSymbolicLink(), "linked where it is copied");
  // Renamed on its host: shared under its new name, linked so where it is copied.
  w.rename(A, "agent/skills/deploy", "agent/skills/ship");
  await w.both({ op: "settle" });
  assert.ok(lstatSync(join(w.data("ts", B), "agent", "skills", "ship")).isSymbolicLink(), "linked under its new name");
  // Stopped: its copies taken away.
  await w.both({ op: "call", station: A, part: "share", method: "shareSkill", args: ["ship", false, null] });
  await w.both({ op: "settle" });
  await w.both({ op: "close" });
});

// ── the memory ──

test("the memory brought level between stations: merged, deleted, a station's skill of one name kept apart: as the TypeScript does", { skip }, async () => {
  const w = new Twin();
  await w.stations([{ id: A, name: "ccvm" }, { id: B, name: "Studio" }, { id: C, name: "Mini1" }], { rosters: { w: roster(A, B, C) }, homes: {} });
  w.write(A, "agent/MEMORY.md", "# 全局记忆\n\n- /tmp 各会话共用。\n- ccvm 盘小，不编译。\n");
  w.write(B, "agent/MEMORY.md", "# 全局记忆\n\n- /tmp 各会话共用。\n- UI 改动先出图。\n");
  w.write(A, "agent/skills/stillfail/SKILL.md", "---\nname: stillfail\ndescription: the project\n---\n\nmerge rules\n");
  w.write(B, "agent/skills/stillfail/SKILL.md", "---\nname: stillfail\ndescription: this machine\n---\n\nhosts and keys\nmore of it\n");
  w.write(B, "agent/skills/stillfail/key", "secret\n", 0o600);
  w.write(C, "agent/skills/notes/SKILL.md", "---\nname: notes\n---\n\nnote one\n");
  await w.both({ op: "call", station: A, part: "memory", method: "levelNow" });
  await w.both({ op: "call", station: B, part: "memory", method: "levelNow" });
  await w.both({ op: "call", station: C, part: "memory", method: "levelNow" });
  await w.both({ op: "call", station: A, part: "memory", method: "levelNow" });
  assert.ok(readdirSync(join(w.data("ts", A), "agent", "skills")).some((n) => n.startsWith("stillfail-")), "a skill of one name and nothing alike kept apart");
  assert.match(readFileSync(join(w.data("ts", B), "agent", "MEMORY.md"), "utf8"), /\[studio\] ccvm 盘小/);
  // Both edit one file apart from the version they share: merged alike.
  w.write(A, "agent/skills/notes/SKILL.md", "---\nname: notes\n---\n\nnote one\nnote from A\n");
  w.write(C, "agent/skills/notes/SKILL.md", "---\nname: notes\n---\n\nnote zero\nnote one\n");
  await w.both({ op: "advance", ms: 60_000 });
  await w.both({ op: "call", station: A, part: "memory", method: "levelNow" });
  await w.both({ op: "call", station: C, part: "memory", method: "levelNow" });
  await w.both({ op: "call", station: B, part: "memory", method: "levelNow" });
  const notes = readFileSync(join(w.data("ts", B), "agent", "skills", "notes", "SKILL.md"), "utf8");
  assert.ok(notes.includes("note zero") && notes.includes("note from A"), "both edits merged");
  // Deleted on one: deleted on each; a station away is passed over and brought level once back.
  w.remove(B, "agent/skills/notes");
  await w.both({ op: "down", station: C });
  await w.both({ op: "call", station: B, part: "memory", method: "levelNow" });
  await w.both({ op: "up", station: C });
  await w.both({ op: "call", station: C, part: "memory", method: "levelNow" });
  await w.both({ op: "call", station: A, part: "memory", method: "levelNow" });
  // What a peer may ask: only this workspace's, and well-formed.
  await w.both({ op: "call", station: A, part: "memory", method: "handle", args: [B, { method: "memory.put", files: { "../x": { hash: "" } } }, "w"] });
  await w.both({ op: "call", station: A, part: "memory", method: "handle", args: [B, { method: "memory.get" }, "nowhere"] });
  await w.both({ op: "call", station: A, part: "memory", method: "handle", args: [B, { method: "memory.blobs", hashes: [createHash("sha256").update("nothing").digest("hex"), 5] }, "w"] });
  await w.both({ op: "call", station: A, part: "memory", method: "handle", args: [B, { method: "memory.what" }, "w"] });
  await w.both({ op: "close" });
});

// ── chats shared with other workspaces ──

const X = "x".repeat(64);
const X2 = "2".repeat(64);
const P = "p".repeat(64);
const Q = "q".repeat(64);

test("chats shared with another workspace, taken once a member said to, read, written, answered and lapsed: as the TypeScript does", { skip }, async () => {
  const w = new Twin();
  const W1 = "01W1";
  const W2 = "01W2";
  const r1 = [{ id: X, name: "studio" }, { id: X2, name: "mini" }];
  const r2 = [{ id: P, name: "laptop" }, { id: Q, name: "desk" }];
  await w.stations([{ id: X, db: true }, { id: X2, db: true }, { id: P, db: true }, { id: Q, db: true }], {
    rosters: { [W1]: r1, [W2]: r2 }, homes: { [X]: W1, [X2]: W1, [P]: W2, [Q]: W2 }, wsNames: { [W1]: "Team", [W2]: "Home" },
  });
  for (const s of [X, X2, P, Q]) await w.both({ op: "call", station: s, part: "xshare", method: "start" });
  await w.both({ op: "call", station: X, part: "xshare", method: "share", args: ["c1", [{ workspace: W2, name: "Home", stations: r2 }], false, "a@x"] });
  await w.both({ op: "settle" });
  await w.both({ op: "call", station: P, part: "xshare", method: "borrowed", args: [] });
  await w.both({ op: "call", station: P, part: "xshare", method: "trust", args: [W1, "Team", X, "studio"] });
  await w.both({ op: "settle" });
  await w.both({ op: "call", station: P, part: "xshare", method: "borrowed", args: [] });
  await w.both({ op: "call", station: Q, part: "xshare", method: "borrowed", args: [] });
  // Reading the shared chat let through; another chat, writing, a task: not.
  await w.both({ op: "call", station: X, part: "xshare", method: "outside", args: [P, { method: "session.read", tool: "chat_read", args: { chat: "c1" } }] });
  await w.both({ op: "call", station: X, part: "xshare", method: "outside", args: [P, { method: "session.read", tool: "chat_read", args: { chat: "c2" } }] });
  await w.both({ op: "call", station: X, part: "xshare", method: "outside", args: [P, { method: "session.message", to: "c1", text: "hi" }] });
  await w.both({ op: "call", station: X, part: "xshare", method: "outside", args: [P, { method: "task.prepare" }] });
  await w.both({ op: "call", station: X, part: "xshare", method: "outside", args: [P, { method: "describe" }] });
  await w.both({ op: "call", station: P, part: "xshare", method: "outside", args: ["s".repeat(64), { method: "xshare.changed", chat: "evil", from: "01W3", link: "https://app.still.fail/o/01W3/s/evil", version: 1 }] });
  await w.both({ op: "call", station: X, part: "xshare", method: "inside", args: [X2, { method: "xshare.trusts", station: P }] });
  await w.both({ op: "call", station: P, part: "xshare", method: "inside", args: [Q, { method: "xshare.trusts", station: X }] });
  // Written to once allowed; the roster of W2 changed, its stations told.
  await w.both({ op: "call", station: X, part: "xshare", method: "share", args: ["c1", [{ workspace: W2, name: "Home", stations: r2 }], true, "a@x"] });
  await w.both({ op: "settle" });
  await w.both({ op: "call", station: X, part: "xshare", method: "outside", args: [P, { method: "session.message", to: "c1", text: "hi" }] });
  await w.both({ op: "cloud", rosters: { [W1]: r1, [W2]: [...r2, { id: C, name: "new" }] }, tell: true });
  await w.both({ op: "settle" });
  // A session of P writes to X's chat (addressed for W2's sake), and X may answer it for 6 hours of quiet.
  await w.both({ op: "call", station: P, part: "xshare", method: "address", args: [X, { method: "session.message", session: "ps", to: "c1" }] });
  await w.both({ op: "call", station: P, part: "xshare", method: "send", args: [X, { method: "session.message", session: "ps", to: "c1" }] });
  await w.both({ op: "call", station: P, part: "xshare", method: "send", args: [X, { method: "session.message", session: "ps2", to: "c1" }, true] });
  await w.both({ op: "call", station: P, part: "xshare", method: "outside", args: [X, { method: "session.message", to: "ps", text: "answer" }] });
  await w.both({ op: "call", station: P, part: "xshare", method: "workspaceOf", args: [X] });
  await w.both({ op: "call", station: P, part: "xshare", method: "reaches", args: [X, W1] });
  await w.both({ op: "advance", ms: 2 * HOUR });
  await w.both({ op: "call", station: X, part: "xshare", method: "outside", args: [P, { method: "session.read", args: { chat: "c1" } }] });
  // Unused for six hours: the share lapses, its stations told; a read then answered why.
  await w.both({ op: "advance", ms: 6 * HOUR + 60_000 });
  await w.both({ op: "settle" });
  await w.both({ op: "call", station: X, part: "xshare", method: "outside", args: [P, { method: "session.read", args: { chat: "c1" } }] });
  await w.both({ op: "call", station: P, part: "xshare", method: "outside", args: [X, { method: "session.message", to: "ps", text: "late" }] });
  await w.both({ op: "call", station: P, part: "xshare", method: "borrowed", args: [] });
  // Shared again, then no longer.
  await w.both({ op: "call", station: X, part: "xshare", method: "share", args: ["c1", [{ workspace: W2, name: "Home", stations: r2 }], false, "a@x"] });
  await w.both({ op: "settle" });
  await w.both({ op: "call", station: X, part: "xshare", method: "share", args: ["c1", [], false, "a@x"] });
  await w.both({ op: "settle" });
  await w.both({ op: "call", station: X, part: "xshare", method: "share", args: ["c1", [{ workspace: W1, name: "self", stations: r1 }], false, "a@x"] });
  await w.both({ op: "close" });
});

test("past a few shares, the deadlines' lookup prepared in batches, and the shares then read by it: as the TypeScript does", { skip }, async () => {
  const w = new Twin();
  const W1 = "01W1";
  const W2 = "01W2";
  const r1 = [{ id: X, name: "studio" }];
  const r2 = [{ id: P, name: "laptop" }];
  await w.stations([{ id: X, db: true }, { id: P, db: true }], { rosters: { [W1]: r1, [W2]: r2 }, homes: { [X]: W1, [P]: W2 }, wsNames: { [W1]: "Team", [W2]: "Home" } });
  for (let i = 0; i < 3; i++) await w.both({ op: "call", station: X, part: "xshare", method: "share", args: [`c${i}`, [{ workspace: W2, name: "Home", stations: r2 }], i % 2 === 0, "a@x"] });
  // A few: nothing made.
  assert.deepEqual(await w.both({ op: "call", station: X, part: "xshare", method: "indexBuild" }), [false, false]);
  for (let i = 3; i < 40; i++) {
    await w.both({ op: "advance", ms: 10 * 60_000 });
    await w.both({ op: "call", station: X, part: "xshare", method: "share", args: [`c${i}`, [{ workspace: W2, name: "Home", stations: r2 }], false, "a@x"] });
  }
  assert.deepEqual(await w.both({ op: "call", station: X, part: "xshare", method: "indexBuild" }), [true, true]);
  await w.both({ op: "call", station: X, part: "xshare", method: "chatShares" });
  // Some lapse; one shared again after: read by the lookup, its deadlines and what was written since alike.
  await w.both({ op: "advance", ms: 2 * HOUR });
  await w.both({ op: "call", station: X, part: "xshare", method: "share", args: ["c1", [{ workspace: W2, name: "Home", stations: r2 }], true, "a@x"] });
  await w.both({ op: "call", station: X, part: "xshare", method: "chatShares" });
  await w.both({ op: "call", station: X, part: "xshare", method: "outside", args: [P, { method: "session.read", args: { chat: "c0" } }] });
  await w.both({ op: "close" });
});

test("a joined workspace's agent home made as the memory first looks at it: the station's own skills in it as its home has them, stillfail-move only on a station of the test channel", { skip }, async () => {
  const w = new Twin();
  await w.stations([{ id: A, name: "stable" }, { id: B, name: "test" }], { rosters: { w: roster(A, B), j: roster(A, B) }, homes: {} });
  // The agents' home as AgentHomeLive keeps it: stillfail-move where moving is on (features.ts `stationMove`, the
  // station's channel), none on a stable station.
  for (const world of ["ts", "mb"] as const) {
    await writeBuiltinSkills(join(w.data(world, A), "agent"), false, null, false);
    await writeBuiltinSkills(join(w.data(world, B), "agent"), false, null, true);
  }
  w.write(A, "agent/skills/notes/SKILL.md", "---\nname: notes\n---\n\nfrom the stable one\n");
  await w.both({ op: "call", station: A, part: "memory", method: "levelNow" });
  await w.both({ op: "call", station: B, part: "memory", method: "levelNow" });
  assert.ok(!existsSync(join(w.data("ts", A), "agent", "workspaces", "j", "skills", "stillfail-move")), "no stillfail-move on a stable station");
  assert.ok(existsSync(join(w.data("ts", B), "agent", "workspaces", "j", "skills", "stillfail-move", "SKILL.md")), "stillfail-move on a station of the test channel");
  assert.ok(existsSync(join(w.data("ts", A), "agent", "workspaces", "j", "MEMORY.md")));
  await w.both({ op: "close" });
});
