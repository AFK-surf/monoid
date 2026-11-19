// A session's storage in MoonBit (station/mb/src/session_storage, `stillfail-reader-harness --builder harness-session-storage`)
// held to the TypeScript it is written from (src/sessions/archive.ts, cold.ts, archive-policy.ts, chat-archive.ts,
// clones.ts, agent-home.ts, others.ts, peer-files.ts, relay.ts): each scenario is played on two worlds made alike, one
// given the TypeScript and one the program, in real temporary directories, and what each answered, what it wrote on
// the disk (every path, its kind, mode, bytes and link), what it told its station (the store's writes, the notices,
// the log, the requests it sent other stations) must be the same, the worlds' own paths written `<root>`.
//
// The station is a fake of the test's (`World`): its store and hub as the modules ask them, another station of the
// workspace as a function answering its requests (`peer`), its chats' surfaces. The program reaches it through its
// harness's calls on stdout (`store.getSession`, `peers.call`, `chat.places`...); the TypeScript through the same
// objects, and through module mocks for what is another subsystem's (a thread's history, an archive's lifecycle, the
// words, the log), which the program asks as `fn.*`. Module mocks need `--experimental-test-module-mocks`: run without
// it (as `pnpm test` runs a file), this file runs itself again with it, and fails as that run fails.
import assert from "node:assert/strict";
import { type ChildProcess, spawn, spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import {
  chmodSync, existsSync, lstatSync, mkdirSync, mkdtempSync, readFileSync, readdirSync, readlinkSync, realpathSync, rmSync, statSync, symlinkSync,
  utimesSync, writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { zstdDecompressSync } from "node:zlib";
import { dirname, join } from "node:path";
import { createInterface } from "node:readline";
import { fileURLToPath } from "node:url";
import { after, mock, test } from "node:test";

const self = fileURLToPath(import.meta.url);
const stationDir = fileURLToPath(new URL("..", import.meta.url));
const src = (p: string) => new URL(`../src/${p}`, import.meta.url).href;

type Json = any;
const NOW = 1_800_000_000_000;

// ---------------------------------------------------------------------------------------------------------------
// The world

/// What a world was told: each write of its store, each notice, each line of its log, each request to the other station.
type Told = [string, ...Json[]];

class Thrown extends Error {
  readonly kind: string;
  constructor(kind: string, message: string) {
    super(message);
    this.kind = kind;
  }
}

type Session = Record<string, Json>;
type Thread = Record<string, Json>;

/// A station as the modules ask it, over the files under `root`.
class World {
  readonly told: Told[] = [];
  readonly root: string;
  readonly data: string;
  sessions = new Map<string, Session>();
  threads: Thread[] = [];
  /// thread id → its members (session, connect).
  members = new Map<number, { session: string; connect: string }[]>();
  shares = new Map<string, { to: { workspace: string }[]; write: boolean }>();
  lapsedShares = new Set<string>();
  inUse: string[] = [];
  jobs: Json[] = [];
  running = new Set<string>();
  sources = new Map<string, Json[]>();
  inUseTranscripts = new Set<string>();
  located = new Map<string, Json>();
  workspaces: string[] = ["W1"];
  wsOfKey = new Map<string, string>();
  links = new Map<string, string>();
  outside: Json[] = [];
  pages = new Map<string, Json>();
  policies = new Map<string, Json>();
  decisions: Json[] = [];
  connects: Json[] = [];
  surfaces = new Map<string, Json>();
  relayed = new Map<string, [string, number][]>();
  peer: ((station: string, request: Json) => Promise<Json>) | null = null;
  threadListMode = false;
  clonesIndex: Json[] = [];
  cloning = new Map<string, (r: { ok: boolean; stderr: string }) => void>();
  nextThread = 100;

  constructor(prefix: string) {
    this.root = realpathSync(mkdtempSync(join(tmpdir(), prefix)));
    dirs.push(this.root);
    this.data = join(this.root, "data");
    mkdirSync(this.data, { recursive: true });
  }

  tell(...what: Told) {
    this.told.push(what);
  }

  thread(id: number) {
    return this.threads.find((t) => t.id === id) ?? null;
  }

  sessionThreads(key: string) {
    return this.threads.filter((t) => (this.members.get(t.id as number) ?? []).some((m) => m.session === key)).map((t) => ({ thread: t, connect: this.members.get(t.id as number)!.find((m) => m.session === key)!.connect }));
  }

  readonly store = {
    getSession: (key: string) => this.sessions.get(key) ?? null,
    threadSessions: (id: number) => (this.members.get(id) ?? []).map((m) => ({ ...m, thread: id })),
    sessionThreads: (key: string) => this.sessionThreads(key),
    chatShare: (c: string) => this.shares.get(c) ?? null,
    usedChatShare: (c: string, ws: string[]) => this.tell("store.usedChatShare", c, ws),
    chatShareLapsed: (c: string, _ws: string[]) => this.lapsedShares.has(c),
    threadsAt: (channel: string, ts: string) => this.threads.filter((t) => t.channel === channel && t.threadTs === ts),
    threadAt: (surface: string, channel: string, ts: string) => this.threads.find((t) => t.surface === surface && t.channel === channel && t.threadTs === ts) ?? null,
    sessionHomeThread: (key: string) => {
      const t = this.threads.find((t) => t.home === key);
      return t ? { thread: t, connect: this.members.get(t.id as number)?.[0]?.connect ?? "ember" } : null;
    },
    latestThread: (key: string) => this.sessionThreads(key).at(-1) ?? null,
    recentSessionThreads: (key: string) => ({ threads: this.sessionThreads(key), more: false }),
    listSessions: () => [...this.sessions.values()],
    listThreads: () => this.threadRows(),
    recentChatList: (ws: string | null, _home: string | null, limit: number) => {
      const threads = this.threadRows().filter((t) => ws === null || (t.thread.home ?? t.sessions[0]?.session ?? "") === "" || this.inWs(t.thread.home ?? t.sessions[0]!.session, ws));
      return { threads: threads.slice(0, limit), sessions: [...this.sessions.values()], total: threads.length };
    },
    searchChatList: (ws: string | null, home: string | null, limit: number, query: string) => {
      const all = this.store.recentChatList(ws, home, 1000).threads.filter((t: Json) => JSON.stringify(t).toLowerCase().includes(query));
      return { threads: all.slice(0, limit), sessions: [...this.sessions.values()], total: all.length };
    },
    sessionsInUse: () => this.inUse.map((k) => this.sessions.get(k)!).filter(Boolean),
    jobsUp: () => this.jobs,
    runtimeSessionSources: (key: string) => this.sources.get(key) ?? [],
    transcriptInUse: (_runtime: string, id: string, _key: string) => this.inUseTranscripts.has(id),
    archiveDir: () => join(this.data, "archive"),
    lastArchivedSession: () => [...this.sessions.values()].filter((s) => s.archivedAt !== null).at(-1) ?? null,
    archivedSessions: (after: Session | null, through: Session) => {
      const all = [...this.sessions.values()].filter((s) => s.archivedAt !== null);
      const from = after === null ? 0 : all.findIndex((s) => s.key === after.key) + 1;
      const to = all.findIndex((s) => s.key === through.key) + 1;
      return all.slice(from, to).slice(0, 2);
    },
    archivePolicy: (ws: string | null = null) => this.policies.get(ws ?? "") ?? null,
    setArchivePolicy: (policy: Json, by: Json, summary: string, ws: string | null = null) => {
      this.tell("store.setArchivePolicy", policy, by, summary, ws ?? null);
      this.policies.set(ws ?? "", { policy, change: { at: NOW, summary, by } });
    },
    latestDecisionsSince: (since: number, _viewer: Json) => this.decisions.filter((d) => d.at >= since),
    now: () => NOW,
    relayedTo: (connect: string) => new Map(this.relayed.get(connect) ?? []),
    openThread: (surface: string, channel: string, ts: string, home: string | null, by: string) => {
      const t = { id: this.nextThread++, surface, channel, threadTs: ts, home, title: null, autoTitle: null, hiddenAt: null, hiddenBy: null, createdAt: NOW };
      this.threads.push(t);
      this.tell("store.openThread", surface, channel, ts, home, by);
      return t;
    },
    noteRelayed: (connect: string, channel: string) => this.tell("store.noteRelayed", connect, channel),
    joinThread: (thread: number, session: string, connect: string) => this.tell("store.joinThread", thread, session, connect),
    insertMessage: (m: Json) => this.tell("store.insertMessage", m),
  };

  inWs(key: string, ws: string) {
    return (this.wsOfKey.get(key) ?? "W1") === ws;
  }

  threadRows() {
    return this.threads.map((t) => ({
      thread: t,
      sessions: (this.members.get(t.id as number) ?? []).map((m) => ({ session: m.session })),
      firstText: t.firstText ?? null,
      lastMessage: t.last ?? null,
    }));
  }

  readonly hub: Json = (() => {
    const w = this;
    const hub: Json = {
      store: this.store,
      now: () => NOW,
      config: () => ({ dataDir: w.data, connects: w.connects, profiles: [] }),
      inWorkspace: (key: string, ws: string) => w.inWs(key, ws),
      wsOf: (key: string | null) => (key === null ? "W1" : (w.wsOfKey.get(key) ?? "W1")),
      workspaces: () => w.workspaces,
      peers: () => (w.peer === null ? null : (station: string, request: Json) => {
        w.tell("peer", station, shownRequest(request));
        return w.peer!(station, request);
      }),
      link: (key: string) => w.links.get(key),
      outsideChats: (_ws: string | null) => w.outside,
      processState: (key: string) => (w.running.has(key) ? "running" : "idle"),
      live: {
        page: async (session: string, before: number, limit: number) => w.pages.get(session)?.(before, limit) ?? null,
        locateAsync: async (key: string) => w.located.get(key) ?? null,
      },
      chatOf: (id: string) => w.surfaces.get(id),
      surface: (id: string) => `surface-${id}`,
      chat: (connect: string) => ({ post: async (ref: Json, text: string, files: Json[]) => { w.tell("chat.post", connect, ref, text, files); return "9.1"; } }),
      openings: { set: (id: number, v: Json) => w.tell("hub.openings", id, v) },
      notify: (session: string, text: string) => w.tell("hub.notify", session, text),
    };
    return hub;
  })();

  /// What the modules ask of another subsystem (mocked for the TypeScript, `fn.*` for the program).
  readonly fns: Record<string, (...a: any[]) => any> = {
    threadHistory: (key: string, thread: Thread, connect: string, address: string, args: Json, wantSeen: boolean) => {
      const seen = wantSeen ? [{ path: join(this.data, "sessions", "c", "s1", "workspace", "uploads", "a.txt"), name: "a.txt", size: 3, kind: "file" }] : [];
      return { text: `history of ${address} via ${connect} for ${key} (${JSON.stringify(args.limit ?? null)}) #${thread.id}`, seen };
    },
    threadsToldOf: (key: string, recent: Json) => recent.threads.map((t: Json) => `${t.thread.channel}/${t.thread.threadTs}`).concat(key === "none" ? [] : []),
    archiveChat: (id: number, archived: boolean) => this.tell("fn.archiveChat", id, archived),
    shownFacts: (path: string) => (path.endsWith(".png") ? { width: 4, height: 2 } : null),
    realOutside: async (path: string) => {
      try {
        return realpathSync(path);
      } catch {
        return null;
      }
    },
    tr: (lang: string, key: string, vars: Json) => `[${lang}] ${key} ${JSON.stringify(vars)}`,
    stationLang: () => "zh",
    titleOf: (thread: Thread) => thread.title ?? `untitled ${thread.id}`,
    startEnv: () => ({ PATH: "/usr/bin" }),
  };

  policyMine = (s: string) => !s.startsWith("other");
  policyTitle = (s: string) => `title of ${s}`;
}

/// A request as the other station is told it: its bytes read whole.
function shownRequest(request: Json): Json {
  if (request === null || typeof request !== "object") return request;
  const out = { ...request };
  if (out.$file !== undefined) {
    const f = out.$file;
    delete out.$file;
    out.bytes = readFileSync(f.path).subarray(f.offset, f.end).toString("base64");
  }
  return out;
}

// ---------------------------------------------------------------------------------------------------------------
// The TypeScript's side: the mocks

let tsWorld: World | null = null;
const ts = () => tsWorld!;

let mods: Json = null;

async function installMocks() {
  const mocked = async (path: string, over: (real: Json) => Record<string, unknown>) => {
    const real = { ...(await import(src(path))) };
    mock.module(src(path), { exports: { ...real, ...over(real) } } as never);
  };
  await mocked("ops/log.ts", (real) => ({
    log: {
      ...real.log,
      info: (part: string, message: string, fields?: Json) => tsWorld?.tell("log.info", part, message, fields ?? null),
      warn: (part: string, message: string, fields?: Json) => tsWorld?.tell("log.warn", part, message, fields ?? null),
    },
  }));
  await mocked("ops/i18n.ts", (real) => ({ tr: (lang: string, key: string, vars: Json) => ts().fns.tr(lang, key, vars ?? {}), stationLang: () => ts().fns.stationLang(), _real: real.tr }));
  await mocked("ops/agent-env.ts", () => ({ startEnv: () => ts().fns.startEnv() }));
  await mocked("ops/places.ts", () => ({ realOutside: (path: string) => ts().fns.realOutside(path) }));
  await mocked("sessions/image-size.ts", () => ({ shownFactsSoon: async (path: string) => ts().fns.shownFacts(path) }));
  await mocked("read/views.ts", () => ({ titleOf: (thread: Thread) => ts().fns.titleOf(thread) }));
  await mocked("sessions/afresh.ts", () => ({ threadsToldOf: (_hub: Json, key: string, recent: Json) => ts().fns.threadsToldOf(key, recent) }));
  await mocked("sessions/lifecycle.ts", () => ({ archiveChat: (_hub: Json, id: number, archived: boolean) => ts().fns.archiveChat(id, archived) }));
  await mocked("sessions/conversations.ts", () => ({
    threadHistory: async (_hub: Json, key: string, thread: Thread, connect: string, address: string, args: Json, seen?: Json[]) => {
      const r = ts().fns.threadHistory(key, thread, connect, address, args, seen !== undefined);
      seen?.push(...r.seen);
      return r.text;
    },
  }));
  const { wall } = await import(src("ops/fibers.ts"));
  mock.method(wall, "now", () => NOW);
  // The modules held to the program, each a copy of its own made after the mocks (`?held`): one loaded before them,
  // as another's real import loads it, keeps the real modules it was linked to.
  const held = (p: string) => import(`${src(p)}?held`);
  mods = {
    archive: await held("sessions/archive.ts"),
    cold: await held("sessions/cold.ts"),
    policy: await held("sessions/archive-policy.ts"),
    chatArchive: await held("sessions/chat-archive.ts"),
    clones: await import(src("sessions/clones.ts")),
    agentHome: await import(src("sessions/agent-home.ts")),
    others: await held("sessions/others.ts"),
    peerFiles: await held("sessions/peer-files.ts"),
    relay: await held("sessions/relay.ts"),
    remote: await import(src("jobs/remote.ts")),
    bus: await import(src("mesh/bus.ts")),
    mbReader: await import(src("read/mb-reader.ts")),
    packedMb: await import(src("sessions/packed-mb.ts")),
  };
}

// ---------------------------------------------------------------------------------------------------------------
// The program's side

const dirs: string[] = [];
after(() => {
  program?.close();
  void mods?.packedMb.peekPackedProgram?.()?.trimIdle?.();
  for (const d of dirs) {
    spawnSync("chmod", ["-R", "u+rwx", d]);
    rmSync(d, { recursive: true, force: true });
  }
});

let mbWorld: World | null = null;
const mbw = () => mbWorld!;

/// What the program asked, answered from the world it plays on.
async function answerCall(name: string, args: Json[]): Promise<Json> {
  const w = mbw();
  const dot = name.indexOf(".");
  const [part, method] = [name.slice(0, dot), name.slice(dot + 1)];
  switch (part) {
    case "store":
      if (method === "relayedTo") return [...w.store.relayedTo(args[0])];
      return (w.store as Json)[method](...args);
    case "hub":
      switch (method) {
        case "has":
          return args[0] === "locateAsync" ? w.hub.live.locateAsync != null : w.hub[args[0]] != null;
        case "hasPeers":
          return w.hub.peers() !== null;
        case "hasChat":
          return w.hub.chatOf(args[0]) !== undefined;
        case "chatPost":
          return w.hub.chat(args[0]).post(args[1], args[2], args[3]);
        case "setOpening":
          return w.hub.openings.set(args[0], args[1]);
        case "pid":
          return process.pid;
      }
      return w.hub[method](...args);
    case "live":
      if (method === "locate") return w.hub.live.locateAsync(args[0]);
      return w.hub.live[method](...args);
    case "peers.call".slice(0, 5): {
      const call = w.hub.peers()!;
      const request = { ...args[1] };
      if (request.$file !== undefined) {
        const f = request.$file;
        delete request.$file;
        mods.bus.withBytes(request, (async function* () { yield readFileSync(f.path).subarray(f.offset, f.end); })());
      }
      const answer = await call(args[0], request);
      const bytes = mods.bus.bytesOf(answer);
      if (bytes === null) return answer;
      const parts: Buffer[] = [];
      for await (const p of bytes) parts.push(p);
      return { ...answer, $bytes: Buffer.concat(parts).toString("base64") };
    }
    case "fn":
      return w.fns[method]!(...args);
    case "log":
      return w.tell(`log.${method}`, args[0], args[1], args[2] ?? null);
    case "policy":
      return method === "mine" ? w.policyMine(args[0]) : w.policyTitle(args[0]);
    case "chat": {
      const surface = w.surfaces.get(args[0]);
      if (method === "has") return typeof surface?.[args[1]] === "function";
      return surface[method](...args.slice(1));
    }
    case "clones":
      switch (method) {
        case "reposDir":
          return join(w.data, "repos");
        case "indexRepos":
          return w.clonesIndex;
        case "changed":
          return w.tell("clones.changed", args[0]);
        case "run":
          return fakeGit(w, args[1])[0];
        case "kill":
          return w.cloning.get(args[0])?.({ ok: false, stderr: "killed" });
      }
  }
  throw new Error(`no part ${name}`);
}

/// git clone as the world runs it: a clone of the address made at the temporary path, or what it fails with.
function fakeGit(w: World, args: string[]): [Promise<{ ok: boolean; stderr: string }>, () => void] {
  const [url, temp] = args.slice(-2) as [string, string];
  const id = temp.split("/").at(-1)!.slice(".cloning-".length);
  if (url.includes("fail")) return [Promise.resolve({ ok: false, stderr: `Cloning into '${temp}'...\nfatal: repository 'https://user:tok@example.com/x' not found\n` }), () => {}];
  if (url.includes("hang")) {
    const p = new Promise<{ ok: boolean; stderr: string }>((resolve) => w.cloning.set(id, resolve));
    return [p, () => w.cloning.get(id)?.({ ok: false, stderr: "killed" })];
  }
  mkdirSync(join(temp, ".git"), { recursive: true });
  writeFileSync(join(temp, ".git", "config"), `[core]\n[remote "origin"]\n\turl = ${url}\n`);
  return [Promise.resolve({ ok: true, stderr: "" }), () => {}];
}

class Program {
  #child: ChildProcess;
  #next = 0;
  #waiting = new Map<number, (v: Json) => void>();
  constructor(binary: string) {
    const shell = mkdtempSync(join(tmpdir(), "session-storage-shell-"));
    dirs.push(shell);
    this.#child = spawn(binary, ["--builder", "harness-session-storage", "--shell-dir", shell], { stdio: ["pipe", "pipe", "inherit"] });
    createInterface({ input: this.#child.stdout! }).on("line", (line) => {
      const said = JSON.parse(line);
      if (said.call !== undefined) {
        void (async () => {
          try {
            const value = await answerCall(said.name, said.args);
            this.#write({ ret: said.call, value: value === undefined ? { $undef: 1 } : value });
          } catch (e) {
            this.#write({ ret: said.call, throw: { kind: (e as Error).constructor.name === "Thrown" ? (e as Thrown).kind : (e as Error).constructor.name, message: (e as Error).message } });
          }
        })();
        return;
      }
      this.#waiting.get(said.id)?.(said);
      this.#waiting.delete(said.id);
    });
  }
  #write(v: Json) {
    this.#child.stdin!.write(`${JSON.stringify(v)}\n`);
  }
  ask(op: string, ...args: Json[]): Promise<Json> {
    const id = ++this.#next;
    return new Promise((resolve) => {
      this.#waiting.set(id, resolve);
      this.#write({ id, op, args });
    });
  }
  close() {
    this.#child.stdin!.end();
  }
}

let program: Program | null = null;

// ---------------------------------------------------------------------------------------------------------------
// Playing both

/// The worlds' own paths and what is random in what they say made one.
function norm(w: World, v: Json): Json {
  const text = JSON.stringify(v === undefined ? null : v) ?? "null";
  return JSON.parse(
    text
      .split(w.root).join("<root>")
      .replace(/[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}/g, "<uuid>")
      .replace(/c-[0-9a-f]{10}/g, "c-<id>")
      .replace(/remote\/served\/[0-9a-f]{64}/g, "remote/served/<hash>")
      .replace(/\.part-[0-9a-f]{8}/g, ".part-<id>")
      .replace(/\.reading-\d+/g, ".reading-<n>"),
  );
}

/// An outcome: what was answered, or what was thrown.
type Outcome = { value: Json } | { error: string; kind?: string; code?: string };

async function tsDo(w: World, f: () => Json): Promise<Outcome> {
  tsWorld = w;
  try {
    const value = await f();
    return { value: value instanceof Map ? [...value] : value === undefined ? null : value };
  } catch (e) {
    const err = e as Error & { code?: string };
    return { error: err.message, kind: err.constructor.name === "Error" ? "Error" : err.constructor.name, ...(err.code !== undefined ? { code: err.code } : {}) };
  }
}

async function mbDo(w: World, op: string, ...args: Json[]): Promise<Outcome> {
  mbWorld = w;
  const said = await program!.ask(op, ...args.map((a) => (a === undefined ? null : a)));
  if (said.error !== undefined) return { error: said.error.message, kind: said.error.kind, ...(said.error.code !== undefined ? { code: said.error.code } : {}) };
  return { value: said.value };
}

/// What a workspace's tar holds, each entry's name, kind, mode, link and bytes, its times left out.
function tarHeld(path: string): string {
  const tar = zstdDecompressSync(readFileSync(path));
  const out: string[] = [];
  let long: string | null = null;
  for (let at = 0; at + 512 <= tar.length; ) {
    const h = tar.subarray(at, at + 512);
    if (h.every((b) => b === 0)) break;
    const field = (from: number, n: number) => h.subarray(from, from + n).toString("latin1").replace(/\0.*$/s, "");
    const size = parseInt(field(124, 12).trim() || "0", 8);
    const type = field(156, 1);
    const body = tar.subarray(at + 512, at + 512 + size);
    at += 512 + Math.ceil(size / 512) * 512;
    if (type === "L") {
      long = body.toString("latin1").replace(/\0.*$/s, "");
      continue;
    }
    out.push(JSON.stringify([long ?? field(0, 100), type, field(100, 8), field(157, 100), body.toString("base64")]));
    long = null;
  }
  return out.join("\n");
}

/// Every path under `dir` with its kind, mode, bytes' hash (or its link), in order.
function tree(dir: string, skip: (rel: string) => boolean = () => false): Json[] {
  const out: Json[] = [];
  const walk = (at: string, rel: string) => {
    for (const name of readdirSync(at).sort()) {
      const path = join(at, name);
      const r = rel === "" ? name : `${rel}/${name}`;
      if (skip(r)) continue;
      const st = lstatSync(path);
      if (st.isSymbolicLink()) out.push([r, "link", readlinkSync(path)]);
      else if (st.isDirectory()) {
        out.push([r, "dir", (st.mode & 0o777).toString(8)]);
        walk(path, r);
      } else {
        // (a tar by what it holds, not when it was made: a directory a step changed has the time it changed)
        const bytes = name.endsWith(".tar.zst") ? tarHeld(path) : readFileSync(path).toString("latin1").split(dir).join("<root>");
        out.push([r, "file", (st.mode & 0o777).toString(8), createHash("sha256").update(bytes, "latin1").digest("hex").slice(0, 16)]);
      }
    }
  };
  if (existsSync(dir)) walk(dir, "");
  return out;
}

/// Plays one step on both: the TypeScript's on `a`, the program's on `b`; their outcomes the same, worlds' own paths
/// aside. `field`: how the outcome's value is compared (by default whole).
async function both(label: string, a: World, b: World, tsf: () => Json, op: string, ...args: (Json | ((w: World) => Json))[]): Promise<Outcome> {
  const x = await tsDo(a, tsf);
  const y = await mbDo(b, op, ...args.map((g) => (typeof g === "function" ? (g as (w: World) => Json)(b) : g)));
  assert.deepStrictEqual(norm(b, y), norm(a, x), `${label}: the program answered otherwise`);
  return x;
}

/// The two worlds' files and what they were told, the same.
function same(label: string, a: World, b: World, skip?: (rel: string) => boolean) {
  assert.deepStrictEqual(norm(b, tree(b.root, skip)), norm(a, tree(a.root, skip)), `${label}: the files differ`);
  assert.deepStrictEqual(norm(b, b.told), norm(a, a.told), `${label}: what the station was told differs`);
}

/// Two worlds made alike by `make`.
function twins(name: string, make: (w: World) => void): [World, World] {
  const a = new World(`ss-${name}-ts-`);
  const b = new World(`ss-${name}-mb-`);
  make(a);
  make(b);
  return [a, b];
}

/// Fixed times on everything under `dir` (a tar keeps them).
function stamp(dir: string) {
  const walk = (at: string) => {
    for (const name of readdirSync(at)) {
      const p = join(at, name);
      const st = lstatSync(p);
      if (st.isDirectory()) walk(p);
      if (!st.isSymbolicLink()) utimesSync(p, 1_700_000_000, 1_700_000_000);
    }
  };
  walk(dir);
  utimesSync(dir, 1_700_000_000, 1_700_000_000);
}

function put(path: string, text: string | Buffer, mode?: number) {
  mkdirSync(dirname(path), { recursive: true });
  writeFileSync(path, text);
  if (mode !== undefined) chmodSync(path, mode);
}

function session(w: World, key: string, over: Partial<Session> = {}): Session {
  const s: Session = {
    key, workspace: join(w.data, "sessions", "c", key, "workspace"), cwd: null, archivedAt: null, archivedBy: null, running: false, runtime: "claude",
    model: "opus", profile: "p1", connect: "ember", title: `chat ${key}`, ws: "W1", ...over,
  };
  w.sessions.set(key, s);
  mkdirSync(s.workspace as string, { recursive: true });
  return s;
}

function thread(w: World, id: number, over: Partial<Thread> = {}, members: { session: string; connect: string }[] = []): Thread {
  const t: Thread = { id, surface: "ember", channel: `CHAT${id}`, threadTs: `1.${id}`, home: null, title: null, autoTitle: null, hiddenAt: null, hiddenBy: null, createdAt: NOW - id * 1000, ...over };
  w.threads.push(t);
  w.members.set(id, members);
  return t;
}

// ---------------------------------------------------------------------------------------------------------------
// The scenarios

async function main() {
  const binary = (await import("./mb-harness.ts")).mbHarnessBinary();
  if (binary === null) {
    test("session storage in MoonBit", { skip: "the tests' MoonBit program (stillfail-reader-harness) is not built here" }, () => {});
    return;
  }
  await installMocks();
  program = new Program(binary);
  const { archive, cold, policy, chatArchive, clones, agentHome, others, peerFiles, relay, remote, bus } = mods;

  test("words and names: links, addresses, times, git addresses, mentions", { timeout: 120_000 }, async () => {
    const [a, b] = twins("words", () => {});
    const refs = [
      "https://app.still.fail/o/W1/st-1/key-1", "see https://x/o/W1/st-1/a%2Fb+c) more", "…/chats/k%20y?x", "https://x/w/W2/s/st-9/chats/kk", "x?history=h%41&entry=12#",
      "history=&entry=3", "/o/only/two", "plain-key", "https://x/w/ /s/st/chats/k", "https://x/w/W/s/st?/chats/k", "/o//st/k", "/o/W//k",
    ];
    for (const r of refs) {
      await both(`linkedSession ${r}`, a, b, () => others.linkedSession(r), "linkedSession", r);
      await both(`linkedStation ${r}`, a, b, () => others.linkedStation(r), "linkedStation", r);
      await both(`linkedWorkspace ${r}`, a, b, () => others.linkedWorkspace(r), "linkedWorkspace", r);
    }
    for (const [s, sep, n] of [["a/b/c/d", "/", 3], ["abc", "/", 2], ["a//b", "/", 5], ["", "/", 1]] as const) await both(`splitN ${s}`, a, b, () => others.splitN(s, sep, n), "splitN", s, sep, n);
    const entries = [
      { kind: "tool_call", tool: "Bash", at: "2026-01-01T00:00:00.000Z", text: "  ls -la  " }, { kind: "tool_result", ok: false, at: null, text: "x".repeat(150) },
      { kind: "message", subagent: true, at: null, text: "中文😀 ok" },
    ];
    await both("formatSteps", a, b, () => others.formatSteps(7, entries, 100), "formatSteps", 7, entries, 100);
    for (const r of ["remote tasks are not enabled here", "no task key", "other"]) await both(`fromBefore ${r}`, a, b, () => others.fromBefore(r), "fromBefore", r);
    const addresses = ["C123/1700000000.000100", "oc_abc/om_x1", "oc_abc/omt_x1", "0123456789abcdef/0123456789abcdef", "d_0123456789abcdef01234567/d_0123456789abcdef01234567", "s_0123456789abcdef01234567/t_0123456789abcdef", "s_0123456789abcdef01234567/t_0123456789abcdeF", "x_0123456789abcdef01234567/x_0123456789abcdef01234567", " CHAT/1.2 ", "c1/1.2", "C1/12", "C1/1.x", "nope"];
    const { parseThreadAddress } = await import(src("agents/instructions.ts"));
    for (const t of addresses) await both(`parseThreadAddress ${t}`, a, b, () => parseThreadAddress(t), "parseThreadAddress", t);
    const { iso } = await import(src("read/transcript.ts"));
    for (const ms of [0, NOW, -1, 253402300799999, 1234]) await both(`iso ${ms}`, a, b, () => iso(ms), "iso", ms);
    const { percentDecode } = await import(src("api/request.ts"));
    for (const s of ["a%20b+c", "%e4%b8%ad", "%zz%4", "%ff", "100%"]) await both(`percentDecode ${s}`, a, b, () => percentDecode(s), "percentDecode", s);
    for (const [p, e] of [["/a/b.jsonl", "jsonl.archive-lock"], ["/a/.hidden", "x"], ["/a/b.tar.zst", ""], ["/a/b", "zst"]]) await both(`withExtension ${p}`, a, b, () => archive.withExtension(p, e), "withExtension", p, e);
    const urls = [
      "owner/name", "owner/name.git", "o/..", "https://github.com/a/b", "HTTP://user:tok@h.com/x/y", "ssh://-x/y", "ssh://u@-x/y", "git://h/", "git@github.com:a/b.git", "-x",
      "a b", "file:///etc", "ext::sh", "u@h::x", "u@-h:x", "  owner/name  ", 7, "https://h.com", "https://@/x",
    ];
    for (const u of urls) await both(`cloneUrl ${u}`, a, b, () => clones.cloneUrl(u), "cloneUrl", u);
    for (const u of ["https://user:tok@github.com/a/b.git", "http://tok@h/x", "ssh://git:pw@h/x", "git@h:a/b", "https://h/x"]) {
      await both(`safeUrl ${u}`, a, b, () => clones.safeUrl(u), "safeUrl", u);
    }
    const { repoName, originIn } = await import(src("sessions/presets.ts"));
    for (const u of ["https://github.com/a/b.git", "git@github.com:a/b.git", "ssh://git@h.com/a/b/", "git+ssh://h/x", " h/a "]) await both(`repoName ${u}`, a, b, () => repoName(u), "repoName", u);
    for (const c of ['[remote "origin"]\n\turl = git@github.com:a/b.git\n', '[core]\n', '[remote "origin"]\n  fetch = x\n  url = https://h/x/y\n']) await both(`originIn`, a, b, () => originIn(c), "originIn", c);
    const people = [{ id: "U1", name: "Ann" }, { id: "U2", name: "Ann Lee", aka: "李" }, { id: "U3", name: "bo_" }];
    for (const n of ["hi @Ann Lee and @Ann, @李 x@Ann @Annie @bo_ @bo_x", "no mention", "@Ann", "email a@Ann"]) {
      await both(`mentioned ${n}`, a, b, () => relay.mentioned(n, people, (id: string) => `<m:${id}>`), "mentioned", n, people);
    }
  });

  test("the archive policy: checked, its changes said, saved and viewed", { timeout: 120_000 }, async () => {
    const [a, b] = twins("policy", (w) => {
      session(w, "s1");
      w.decisions = [
        { session: "s1", at: NOW - 1000, detail: { result: { selected: "landed" }, accepted: true } },
        { session: "s2", at: NOW - 900, detail: { result: { selected: "uncertain" } } },
        { session: "s1", at: NOW - 800, detail: { result: { selected: "answered" }, accepted: false } },
        { session: "other-1", at: NOW - 700, detail: { result: { selected: "answered" } } },
        { session: "s3", at: NOW - 600, detail: {} },
        { session: "s4", at: NOW - 9 * 86_400_000, detail: { result: { selected: "landed" } } },
      ];
    });
    const D = policy.DEFAULT_POLICY;
    const inputs: Json[] = [
      D, null, { policy: " " }, { policy: "x".repeat(4001), options: [] }, { policy: "p" }, { policy: "p", options: [{}] },
      { policy: "p", options: [{ name: "a", archive: true }, { name: "b", archive: false }] },
      { policy: "p", options: [{ name: "a", archive: true }, { name: "a", archive: false }] },
      { policy: "p", options: [{ name: "a", archive: true }, { name: "b", archive: true }] },
      { policy: "p", options: [{ name: "a", archive: false }, { name: "b", archive: false }] },
      { policy: "p", options: [{ name: "a", archive: "yes" }, { name: "b", archive: false }] },
      { policy: "p", options: [{ id: "Bad", name: "a", archive: true }, { name: "b", archive: false }] },
      { policy: "p", options: [{ id: "option_2", name: "a", archive: true }, { name: "b", archive: false }] },
      { policy: "p", options: [{ id: "x", name: "a", archive: true }, { id: "x", name: "b", archive: false }] },
      { policy: "p", options: [{ name: "名".repeat(41), archive: true }, { name: "b", archive: false }] },
      { policy: "p", options: [{ name: "a", rubric: "r".repeat(401), archive: true }, { name: "b", archive: false }] },
      { policy: "p", options: [{ name: "", archive: true }, { name: "b", archive: false }] },
      [1, 2],
    ];
    for (const [i, p] of inputs.entries()) await both(`checkedPolicy ${i}`, a, b, () => policy.checkedPolicy(p), "checkedPolicy", p);
    const edited = { ...D, policy: `${D.policy} 再看看`, options: [...D.options.slice(1).map((o: Json) => (o.id === "landed" ? { ...o, archive: false, name: "落地" } : o.id === "dropped" ? { ...o, rubric: "x" } : o)), { id: "new", name: "新", rubric: "", archive: true }] };
    const reordered = { ...D, options: [...D.options].reverse() };
    for (const [x, y] of [[D, D], [D, edited], [edited, D], [D, reordered]]) await both("changeSummary", a, b, () => policy.changeSummary(x, y), "changeSummary", x, y);
    await both("policyQuestion", a, b, () => policy.policyQuestion(edited), "policyQuestion", edited);
    const r = { selected: "landed", probabilities: { landed: 0.5, answered: 0.25, uncertain: 0.25 } };
    await both("archiveMass", a, b, () => policy.archiveMass(r, D), "archiveMass", r, D);
    for (const t of [0.7, 0.8]) await both(`recommends ${t}`, a, b, () => policy.recommends(r, D, t), "recommends", r, D, t);
    await both("policyChecks", a, b, () => policy.policyChecks(a.decisions, (s: string) => !s.startsWith("other")), "policyChecks", a.decisions, ["s1", "s2", "s3", "s4"]);
    await both("currentPolicy (default)", a, b, () => policy.currentPolicy(a.store, "W1"), "currentPolicy", "W1");
    await both("savePolicy (bad)", a, b, () => policy.savePolicy(a.store, { policy: "" }, { kind: "agent", session: "s1" }, "W1"), "savePolicy", { policy: "" }, { kind: "agent", session: "s1" }, "W1");
    await both("savePolicy (same)", a, b, () => policy.savePolicy(a.store, D, { kind: "agent", session: "s1" }, "W1"), "savePolicy", D, { kind: "agent", session: "s1" }, "W1");
    await both("savePolicy", a, b, () => policy.savePolicy(a.store, edited, { kind: "agent", session: "s1" }, "W1"), "savePolicy", edited, { kind: "agent", session: "s1" }, "W1");
    await both("policyView (agent)", a, b, () => policy.policyView(a.store, "W1", a.policyMine, a.policyTitle, { ws: "W1" }), "policyView", "W1", { ws: "W1" }, null);
    await both("savePolicy (person)", a, b, () => policy.savePolicy(a.store, D, { kind: "person", email: "p@x", name: null }, null), "savePolicy", D, { kind: "person", email: "p@x", name: null }, null);
    await both("policyView (person)", a, b, () => policy.policyView(a.store, null, a.policyMine, a.policyTitle, {}), "policyView", null, {}, null);
    const checks = policy.policyChecks(a.decisions);
    await both("policyView (counted)", a, b, () => policy.policyView(a.store, "none", a.policyMine, a.policyTitle, {}, checks), "policyView", "none", {}, checks);
    same("policy", a, b);
  });

  test("a transcript and a workspace put away, read from, restored and emptied", { timeout: 120_000 }, async () => {
    const [a, b] = twins("archive", (w) => {
      const room = join(w.data, "sessions", "c", "s1");
      const ws = join(room, "workspace");
      put(join(ws, "src", "main.ts"), "export const x = 1;\n");
      put(join(ws, "uploads", "a.txt"), "abc");
      put(join(ws, "uploads", "pic.png"), Buffer.from([1, 2, 3, 4]));
      put(join(ws, "bin", "run.sh"), "#!/bin/sh\n", 0o755);
      symlinkSync("src/main.ts", join(ws, "link-to-main"));
      put(join(w.root, "repo", ".git", "worktrees", "wt", "HEAD"), "ref: x\n");
      put(join(ws, "wt", ".git"), "gitdir: ../../../../../../repo/.git/worktrees/wt\n");
      put(join(ws, "gone-wt", ".git"), "gitdir: /nowhere/at/all\n");
      mkdirSync(join(ws, "locked-dir", "inner"), { recursive: true });
      put(join(ws, "locked-dir", "inner", "f"), "f");
      chmodSync(join(ws, "locked-dir", "inner"), 0o500);
      const t = join(w.data, "transcripts", "claude", "p", "t1.jsonl");
      put(t, Array.from({ length: 400 }, (_, i) => JSON.stringify({ i, text: "line ".repeat(30) })).join("\n") + "\n");
      put(join(w.data, "transcripts", "claude", "p", "t1", "subagents", "agent-1.jsonl"), '{"a":1}\n');
      stamp(join(w.data, "sessions"));
    });
    const room = (w: World) => join(w.data, "sessions", "c", "s1");
    const t1 = (w: World) => join(w.data, "transcripts", "claude", "p", "t1.jsonl");
    const sub = (w: World) => join(w.data, "transcripts", "claude", "p", "t1", "subagents", "agent-1.jsonl");
    await both("jsonlFiles", a, b, async () => { const out: string[] = []; await archive.jsonlFilesSoon(join(a.data, "transcripts"), out); return out.sort(); }, "jsonlFiles", (w: World) => join(w.data, "transcripts"), []);
    await both("packFile", a, b, () => archive.packFile(t1(a)), "packFile", t1);
    await both("packFile (only the copy)", a, b, () => archive.packFile(t1(a)), "packFile", t1);
    await both("packFile sub", a, b, () => archive.packFile(sub(a)), "packFile", sub);
    same("transcripts packed", a, b);
    await both("jsonlFiles (packed)", a, b, async () => { const out: string[] = [t1(a)]; await archive.jsonlFilesSoon(join(a.data, "transcripts"), out); return out; }, "jsonlFiles", (w: World) => join(w.data, "transcripts"), [t1(b)]);
    await both("segmentFile (in segments already)", a, b, () => archive.segmentFile(t1(a)), "segmentFile", t1);
    await both("restoreFile", a, b, () => archive.restoreFile(t1(a)), "restoreFile", t1);
    await both("restoreFile (nothing put away)", a, b, () => archive.restoreFile(t1(a)), "restoreFile", t1);
    same("transcript restored", a, b);
    await both("holdsMore (not packed)", a, b, () => archive.holdsMore(room(a)), "holdsMoreRoom", room);
    await both("packWorkspace", a, b, () => archive.packWorkspace(room(a)), "packWorkspace", room);
    same("workspace packed", a, b);
    await both("packWorkspace (packed already)", a, b, () => archive.packWorkspace(room(a)), "packWorkspace", room);
    for (const rel of ["uploads/a.txt", "uploads\\pic.png", "./uploads/./a.txt", "uploads/none", "src/main.ts"]) {
      await both(`workspaceFile ${rel}`, a, b, async () => { const got = await archive.withLock(room(a), () => archive.workspaceFile(room(a), rel)); return got === null ? null : got.toString("base64"); }, "workspaceFile", room, rel);
    }
    await both("holdsMore (packed)", a, b, () => archive.holdsMore(room(a)), "holdsMoreRoom", room);
    // Written meanwhile: overlaid on what is restored.
    for (const w of [a, b]) put(join(room(w), "workspace", "new.txt"), "new");
    await both("restoreWorkspace", a, b, () => archive.restoreWorkspace(room(a)), "restoreWorkspace", room);
    same("workspace restored", a, b);
    for (const w of [a, b]) stamp(join(w.data, "sessions"));
    await both("packWorkspace again", a, b, () => archive.packWorkspace(room(a)), "packWorkspace", room);
    for (const w of [a, b]) put(join(room(w), "workspace.tar.zst.reading-9"), "left");
    await both("emptyWorkspace", a, b, () => archive.emptyWorkspace(room(a)), "emptyWorkspace", room);
    same("workspace emptied", a, b);
    await both("holdsMore (emptied)", a, b, () => archive.holdsMore(room(a)), "holdsMoreRoom", room);
    await both("restoreWorkspace (nothing packed)", a, b, () => archive.restoreWorkspace(room(a)), "restoreWorkspace", room);
    for (const w of [a, b]) {
      mkdirSync(join(w.root, "ro", "deep"), { recursive: true });
      put(join(w.root, "ro", "deep", "f"), "f");
      chmodSync(join(w.root, "ro", "deep"), 0o500);
      chmodSync(join(w.root, "ro"), 0o500);
    }
    await both("removeTree (read-only)", a, b, () => archive.removeTree(join(a.root, "ro")), "removeTree", (w: World) => join(w.root, "ro"));
    await both("removeTree (none)", a, b, () => archive.removeTree(join(a.root, "ro")), "removeTree", (w: World) => join(w.root, "ro"));
    same("removed", a, b);
  });

  test("cold storage: an archived session's room cleaned, packed, found cold, emptied and restored", { timeout: 120_000 }, async () => {
    const [a, b] = twins("cold", (w) => {
      const s1 = session(w, "s1", { archivedAt: NOW - 10 * 86_400_000 });
      const ws = s1.workspace as string;
      put(join(ws, "README.md"), "# s1\n");
      put(join(ws, "app", "package.json"), "{}");
      put(join(ws, "app", "node_modules", "dep", "index.js"), "module.exports = 1;\n");
      put(join(ws, "uploads", "a.txt"), "abc");
      const t = join(w.data, "transcripts", "claude", "proj", "rt-1.jsonl");
      put(t, '{"type":"user"}\n'.repeat(50));
      put(join(w.data, "transcripts", "claude", "proj", "rt-1", "subagents", "a.jsonl"), '{"x":1}\n');
      w.sources.set("s1", [{ id: "rt-1", runtime: "claude", profile: null }]);
      w.located.set("s1", { runtime: "claude", paths: [t, join(w.root, "outside", "x.jsonl")] });
      put(join(w.data, "archive", "transcripts", "s1.jsonl.zst"), "legacy copy");
      session(w, "s2");
      w.inUse = ["s2"];
      const s3 = session(w, "s3", { archivedAt: NOW - 1000 });
      w.inUse.push("s4");
      session(w, "s4", { cwd: s3.workspace });
      session(w, "s5", { archivedAt: NOW - 1000 });
      w.jobs = [{ sessionKey: "s5", cwd: "/tmp" }];
      stamp(join(w.data, "sessions"));
    });
    const rooms = (w: World) => new cold.ColdRooms(() => w.hub);
    const ra = rooms(a);
    for (const key of ["s1", "s2", "s3", "s5", "none"]) await both(`archiveRoom ${key}`, a, b, async () => { await (ra as Json).findRoom(key); return ra.archiveRoom(key); }, "archiveRoom", key);
    await both("isCold (before)", a, b, () => ra.isCold("s1"), "isCold", "s1");
    await both("historyFiles", a, b, () => ra.historyFilesSoon("s1", true), "historyFiles", "s1", true);
    await both("historyFiles (unknown)", a, b, () => ra.historyFilesSoon("nope", false), "historyFiles", "nope", false);
    // Left running in the workspace by what ran there: stopped as it is packed.
    const strays = [a, b].map((w) => {
      const child = spawn("sleep", ["300"], { cwd: join(w.data, "sessions", "c", "s1", "workspace", "app"), stdio: "ignore" });
      return new Promise<string | null>((resolve) => child.on("exit", (_code, signal) => resolve(signal)));
    });
    await both("pack", a, b, () => ra.pack("s1"), "pack", "s1");
    assert.deepStrictEqual(await Promise.all(strays), ["SIGTERM", "SIGTERM"], "what was left running stopped");
    same("packed", a, b);
    await both("isCold", a, b, () => ra.isCold("s1"), "isCold", "s1");
    await both("holdsMore", a, b, () => ra.holdsMore("s1"), "holdsMore", "s1");
    await both("expire (archived after)", a, b, () => ra.expire("s1", NOW - 20 * 86_400_000), "expire", "s1", NOW - 20 * 86_400_000);
    same("not expired", a, b);
    await both("restore", a, b, () => ra.restore("s1"), "restore", "s1");
    same("restored", a, b);
    await both("pack again", a, b, () => ra.pack("s1"), "pack", "s1");
    await both("expire", a, b, () => ra.expire("s1", NOW), "expire", "s1", NOW);
    same("expired", a, b);
    await both("holdsMore (expired)", a, b, () => ra.holdsMore("s1"), "holdsMore", "s1");
    await both("restore (expired)", a, b, () => ra.restore("s1"), "restore", "s1");
    same("restored after expiry", a, b);
    for (const w of [a, b]) {
      put(join(w.data, "archive", "transcripts", "s1.jsonl.zst"), "legacy copy");
      put(join(w.data, "archive", "transcripts", "s3.jsonl.zst"), "legacy of s3");
    }
    await both("finishLegacyCopies", a, b, () => ra.finishLegacyCopies(), "finishLegacyCopies");
    same("legacy copies", a, b);
    await both("segmentHistories", a, b, () => ra.segmentHistories(), "segmentHistories");
    await both("segmentHistories (said)", a, b, () => ra.segmentHistories(), "segmentHistories");
    same("segmented", a, b);
    await both("restore (unknown)", a, b, () => ra.restore("nope"), "restore", "nope");
  });

  test("chat_archive here and on another station", { timeout: 120_000 }, async () => {
    const refused = (m: string) => new remote.Refused(m);
    const [a, b] = twins("chat-archive", (w) => {
      session(w, "s1");
      session(w, "s2", { archivedBy: "manual" });
      session(w, "s3");
      session(w, "x1", { ws: "W2" });
      w.wsOfKey.set("x1", "W2");
      thread(w, 1, { home: "s1" }, [{ session: "s1", connect: "ember" }]);
      thread(w, 2, { home: "s2" }, [{ session: "s2", connect: "ember" }]);
      thread(w, 3, { surface: "slack" }, [{ session: "s3", connect: "slack1" }]);
      thread(w, 4, { hiddenBy: "manual" }, []);
      thread(w, 5, { home: "x1" }, [{ session: "x1", connect: "ember" }]);
      thread(w, 6, {}, [{ session: "s3", connect: "ember" }]);
      w.links.set("s1", "https://app/o/W1/st-here/s1");
      w.peer = async (_station: string, request: Json) => {
        if (request.chat.includes("old")) throw refused("remote tasks are not enabled on this station");
        if (request.chat.includes("down")) throw new Error("connection lost");
        if (request.chat.includes("empty")) return {};
        return { text: `Archived there: ${request.chat}` };
      };
    });
    const cases: [string, Json][] = [
      ["s1", { chat: "s2" }], ["s1", { chat: "s3" }], ["s1", { chat: "CHAT4/1.4" }], ["s1", { chat: "s1" }], ["s1", { chat: "CHAT6/1.6" }],
      ["s1", { chat: "https://app/o/W1/st-here/s2?history=s2" }], ["s1", { chat: "x1" }], ["s1", { chat: " " }], ["s1", {}],
      ["s1", { chat: "https://app/o/W1/st-there/k" }], ["s1", { chat: "https://app/o/W1/st-there/old" }], ["s1", { chat: "https://app/o/W1/st-there/down" }],
      ["s1", { chat: "https://app/o/W1/st-there/empty" }],
    ];
    for (const [key, args] of cases) await both(`chatArchive ${JSON.stringify(args)}`, a, b, () => chatArchive.chatArchive(a.hub, key, args), "chatArchive", key, args);
    for (const req of [{ chat: "s3" }, { chat: "" }, { chat: "CHAT5/1.5" }]) {
      await both(`archiveForPeer ${JSON.stringify(req)}`, a, b, () => chatArchive.archiveForPeer(a.hub, req, "W1"), "archiveForPeer", req, "W1");
    }
    for (const w of [a, b]) w.peer = null;
    await both("chatArchive (no peers)", a, b, () => chatArchive.chatArchive(a.hub, "s1", { chat: "https://app/o/W1/st-there/k" }), "chatArchive", "s1", { chat: "https://app/o/W1/st-there/k" });
    same("chat archive", a, b);
  });

  test("other chats read and named, here and across stations, their attachments fetched", { timeout: 120_000 }, async () => {
    const big = Buffer.alloc(17 * 1024 * 1024, 7);
    const [a, b] = twins("others", (w) => {
      session(w, "s1");
      session(w, "s2", { model: null, archivedAt: NOW - 5 });
      session(w, "x1", { ws: "W2" });
      w.wsOfKey.set("x1", "W2");
      session(w, "x2", { ws: "W2" });
      w.wsOfKey.set("x2", "W2");
      thread(w, 1, { home: "s1", title: "First chat", firstText: "hello there", last: { text: "last   words\nhere", createdAt: NOW - 50 } }, [{ session: "s1", connect: "ember" }]);
      thread(w, 2, { home: "s2", autoTitle: "auto", hiddenAt: NOW }, [{ session: "s2", connect: "ember" }, { session: "s1", connect: "ember" }]);
      thread(w, 3, { surface: "slack", channel: "C9", threadTs: "1700000000.000001" }, [{ session: "s1", connect: "slack1" }]);
      thread(w, 4, {}, []);
      thread(w, 5, { home: "x1" }, [{ session: "x1", connect: "ember" }]);
      thread(w, 6, { home: "x2" }, [{ session: "x2", connect: "ember" }]);
      w.shares.set("x1", { to: [{ workspace: "W1" }], write: false });
      w.lapsedShares.add("x2");
      w.links.set("s1", "https://app/o/W1/st-here/s1");
      w.links.set("s2", "https://app/o/W1/st-here/s2");
      w.outside = [{ link: "https://app/o/W2/st-x/x1", workspaceName: "Other  ws", title: "A shared one", write: true }];
      w.pages.set("s1", (before: number, limit: number) => ({ start: Math.max(0, Math.min(before, 10) - limit), end: 10, entries: Array.from({ length: Math.min(limit, Math.min(before, 10)) }, (_, i) => ({ kind: "message", text: `step ${i}`, at: null })) }));
      w.pages.set("s2", () => ({ start: 0, end: 0, entries: [] }));
      w.peer = async (_station: string, request: Json) => {
        if (request.method === "session.read") {
          if (request.args.chat.includes("old")) throw new remote.Refused("unknown task key");
          return { text: `read there\n- /there/uploads/small.txt (3 bytes)\n- /there/uploads/big.bin (x)`, files: [{ path: "/there/uploads/small.txt", name: "small.txt", size: 3 }, { path: "/there/uploads/big.bin", size: big.length }, { path: 7 }] };
        }
        if (request.method === "session.file") {
          if (request.path.endsWith("small.txt")) return bus.withBytes({ size: 3 }, (async function* () { yield Buffer.from("abc"); })());
          if (request.path.endsWith("big.bin")) return bus.withBytes({ size: big.length }, (async function* () { yield big; })());
          if (request.path.endsWith("chunks.txt")) return request.offset === 0 ? { data: Buffer.from("ab").toString("base64"), size: 4, eof: false } : { data: Buffer.from("cd").toString("base64"), size: 4, eof: true };
          if (request.path.endsWith("short.txt")) return bus.withBytes({ size: 9 }, (async function* () { yield Buffer.from("abc"); })());
          throw new remote.Refused("remote tasks are not enabled");
        }
        throw new Error("no such method");
      };
    });
    const names = ["s1", "s2", "CHAT1/1.1", "C9/1700000000.000001", "CHAT4/1.4", "https://app/o/W1/st/s1?x", "x?history=s1&entry=3", "https://app/o/W2/st/x1", "https://app/o/W2/st/x2", "https://app/o/W2/st/x3",
      "x1", "nope", "", "CHAT5/1.5", "https://app/w/W2/s/st/chats/x1"];
    for (const n of names) {
      for (const ws of ["W1", null]) {
        await both(`named ${n} ${ws}`, a, b, () => others.named(a.hub, n, ws), "named", n, ws);
        await both(`named ${n} ${ws} (to write)`, a, b, () => others.named(a.hub, n, ws, true), "named", n, ws, true);
      }
    }
    for (const t of [a.thread(1), a.thread(4), a.thread(5)]) await both(`threadIn ${t!.id}`, a, b, () => others.threadIn(a.hub, t, "W1"), "threadIn", (w: World) => w.thread(t!.id as number), "W1");
    await both("scopeOf", a, b, () => others.scopeOf(a.hub, "x1"), "scopeOf", "x1");
    for (const r of ["https://app/o/W1/st-there/k", "https://app/o/W1/st-here/k", "plain"]) await both(`elsewhere ${r}`, a, b, () => others.elsewhere(a.hub, "s1", r), "elsewhere", "s1", r);
    for (const k of ["s1", "s2", "x1"]) await both(`sessionThreadOf ${k}`, a, b, () => others.sessionThreadOf(a.hub, k), "sessionThreadOf", k);
    for (const args of [{}, { limit: 1 }, { limit: "2" }, { limit: "nan" }, { query: "FIRST" }, { query: "zzz" }, { query: "shared" }, { limit: 500 }]) {
      await both(`chatList ${JSON.stringify(args)}`, a, b, () => others.chatList(a.hub, "s1", args), "chatList", "s1", args);
    }
    for (const w of [a, b]) w.threadListMode = true;
    for (const w of [a, b]) w.hub.threadList = async () => w.threadRows();
    for (const args of [{}, { query: "auto" }]) await both(`chatList (threadList) ${JSON.stringify(args)}`, a, b, () => others.chatList(a.hub, "s1", args), "chatList", "s1", args);
    for (const args of [{ chat: "s2" }, { chat: "CHAT1/1.1", limit: 5 }, { chat: 7 }, {}]) {
      for (const seen of [true, false]) {
        await both(`chatRead ${JSON.stringify(args)} ${seen}`, a, b, async () => { const s: Json[] | undefined = seen ? [] : undefined; const text = await others.chatRead(a.hub, "s1", args, s, "W1"); return { text, seen: s ?? [] }; }, "chatRead", "s1", args, seen, "W1");
      }
    }
    for (const args of [{ chat: "s1" }, { chat: "s1", limit: 3, before: 5 }, { chat: "x?history=s1&entry=6", limit: 4 }, { chat: "s1", before: -3, max_chars: "x" }, { chat: "s2" }, { chat: "CHAT2/1.2" }, { chat: "CHAT4/1.4" }, { chat: "s1", before: 0 }]) {
      await both(`sessionHistory ${JSON.stringify(args)}`, a, b, () => others.sessionHistory(a.hub, args, "W1"), "sessionHistory", args, "W1");
    }
    for (const req of [{ tool: "chat_read", session: "k", args: { chat: "s2" } }, { tool: "session_history", args: { chat: "s1" } }, { tool: "x", args: { chat: "s1" } }, { tool: "chat_read", args: { chat: " " } }, { tool: "chat_read", args: [1] }]) {
      await both(`forPeer ${JSON.stringify(req)}`, a, b, () => others.forPeer(a.hub, "peer-1", req, "W1"), "forPeer", "peer-1", req, "W1");
    }
    for (const req of [{ method: "session.read", tool: "chat_read", args: { chat: "s2" } }, { method: "session.read", tool: "session_history", args: { chat: "s2" } }, { method: "session.read", args: { chat: "CHAT1/1.1" } }, { method: "session.file", chat: "s1" }, { method: "session.put", to: "s2" }, { method: "session.message", to: "zz" }, { method: "x" }]) {
      await both(`chatsTouched ${JSON.stringify(req)}`, a, b, () => others.chatsTouched(a.hub, req), "chatsTouched", req);
    }
    for (const args of [{ chat: "https://app/o/W1/st-there/k", limit: 3 }, { chat: "https://app/o/W1/st-there/k", fetch: ["/there/uploads/big.bin", "/there/uploads/chunks.txt", "/there/uploads/short.txt", "/there/uploads/none", 4] }, { chat: "https://app/o/W1/st-there/old" }]) {
      await both(`readAfar ${JSON.stringify(args)}`, a, b, () => others.readAfar(a.hub, "s1", "st-there-station-id", "chat_read", args), "readAfar", "s1", "st-there-station-id", "chat_read", args);
      same(`readAfar ${JSON.stringify(args)}`, a, b);
    }
    for (const w of [a, b]) w.peer = null;
    await both("readAfar (no peers)", a, b, () => others.readAfar(a.hub, "s1", "st", "chat_read", { chat: "x" }), "readAfar", "s1", "st", "chat_read", { chat: "x" });
    same("others", a, b);
  });

  test("files between stations: a chat's attachments served, sent along, staged and claimed", { timeout: 120_000 }, async () => {
    const [a, b] = twins("peer-files", (w) => {
      const s1 = session(w, "s1");
      session(w, "s2");
      thread(w, 1, { home: "s1" }, [{ session: "s1", connect: "ember" }]);
      put(join(s1.workspace as string, "uploads", "a.txt"), "abcdef");
      put(join(s1.workspace as string, "uploads", "pic.png"), Buffer.alloc(300 * 1024, 3));
      mkdirSync(join(s1.workspace as string, "uploads", "dir"));
      symlinkSync(join(s1.workspace as string, "uploads", "a.txt"), join(s1.workspace as string, "uploads", "link.txt"));
      put(join(s1.workspace as string, "notes.md"), "notes");
      const archived = session(w, "s3", { archivedAt: NOW - 5 });
      thread(w, 3, { home: "s3" }, [{ session: "s3", connect: "ember" }]);
      put(join(archived.workspace as string, "uploads", "kept.txt"), "kept bytes");
      stamp(join(w.data, "sessions"));
      put(join(w.data, "remote", "served", "old"), "old");
      utimesSync(join(w.data, "remote", "served", "old"), (NOW - 2 * 86_400_000) / 1000, (NOW - 2 * 86_400_000) / 1000);
      put(join(w.data, "remote", "served", "fresh"), "fresh");
      utimesSync(join(w.data, "remote", "served", "fresh"), NOW / 1000, NOW / 1000);
      w.peer = async (_station: string, request: Json) => {
        if (request.name === "nobytes.txt" && mods.bus.bytesOf(request) !== null) throw new bus.NoBytes("no bytes");
        return { ok: true };
      };
    });
    const up = (w: World, name: string) => join(w.data, "sessions", "c", "s1", "workspace", "uploads", name);
    await both("pack s3's workspace", a, b, () => archive.packWorkspace(join(a.data, "sessions", "c", "s3")), "packWorkspace", (w: World) => join(w.data, "sessions", "c", "s3"));
    const asks: [string, (w: World) => Json][] = [
      ["chunk", (w) => ({ chat: "s1", path: up(w, "a.txt"), offset: 2 })],
      ["whole", (w) => ({ chat: "CHAT1/1.1", path: up(w, "a.txt"), whole: true, offset: 1 })],
      ["big chunk", (w) => ({ chat: "s1", path: up(w, "pic.png"), offset: 0 })],
      ["past end", (w) => ({ chat: "s1", path: up(w, "a.txt"), offset: 99 })],
      ["a directory", (w) => ({ chat: "s1", path: up(w, "dir") })],
      ["a link", (w) => ({ chat: "s1", path: up(w, "link.txt") })],
      ["not uploads", (w) => ({ chat: "s1", path: join(w.data, "sessions", "c", "s1", "workspace", "notes.md") })],
      ["dotted", (w) => ({ chat: "s1", path: join(up(w, "x"), "..", "a.txt") })],
      ["no chat", (w) => ({ chat: "", path: up(w, "a.txt") })],
      ["archived", (w) => ({ chat: "s3", path: join(w.data, "sessions", "c", "s3", "workspace", "uploads", "kept.txt"), offset: 0 })],
      ["archived on", (w) => ({ chat: "s3", path: join(w.data, "sessions", "c", "s3", "workspace", "uploads", "kept.txt"), offset: 4, whole: true })],
      ["archived gone", (w) => ({ chat: "s3", path: join(w.data, "sessions", "c", "s3", "workspace", "uploads", "none.txt") })],
    ];
    const answered = async (w: World, v: Json) => {
      const bytes = v === null || typeof v !== "object" ? null : bus.bytesOf(v);
      if (v?.$file !== undefined) {
        const { $file, ...rest } = v;
        return { ...rest, bytes: readFileSync($file.path).subarray($file.offset, $file.end).toString("base64") };
      }
      if (bytes === null) return v;
      const parts: Buffer[] = [];
      for await (const p of bytes) parts.push(p);
      return { ...v, bytes: Buffer.concat(parts).toString("base64") };
    };
    for (const [label, ask] of asks) {
      const x = await tsDo(a, async () => answered(a, await peerFiles.fileForPeer(a.hub, ask(a), "W1")));
      const y0 = await mbDo(b, "fileForPeer", ask(b), "W1");
      const y = "value" in y0 ? { value: await answered(b, y0.value) } : y0;
      assert.deepStrictEqual(norm(b, y), norm(a, x), `fileForPeer ${label}`);
    }
    same("served", a, b);
    await both("sendable", a, b, () => peerFiles.sendable(a.hub, "s1", ["uploads/a.txt", up(a, "pic.png")]), "sendable", "s1", (w: World) => ["uploads/a.txt", up(w, "pic.png")]);
    for (const given of [["none"], ["uploads/dir"], Array(11).fill("x")]) await both(`sendable ${given[0]}`, a, b, () => peerFiles.sendable(a.hub, "s1", given), "sendable", "s1", given);
    for (const w of [a, b]) put(up(w, "nobytes.txt"), Buffer.alloc(600 * 1024, 9));
    const files = (w: World) => [{ path: up(w, "a.txt"), name: "a.txt", size: 6 }, { path: up(w, "nobytes.txt"), name: "nobytes.txt", size: 600 * 1024 }, { path: up(w, "a.txt"), name: "again.txt", size: 6 }];
    const sentA = await tsDo(a, () => peerFiles.sendAlong(a.hub.peers()!, "st", "s1", "to-1", files(a)));
    const sentB = await mbDo(b, "sendAlong", "st", "s1", "to-1", files(b));
    assert.deepStrictEqual(norm(b, sentB), norm(a, sentA), "sendAlong");
    same("sent along", a, b);
    const puts: [string, Json][] = [
      ["whole", { session: "k", to: "s2", id: "f1", size: 3, $bytes: "abc" }],
      ["whole short", { session: "k", to: "s2", id: "f2", size: 5, $bytes: "abc" }],
      ["whole over", { session: "k", to: "s2", id: "f3", size: 2, $bytes: "abc" }],
      ["whole no size", { session: "k", to: "s2", id: "f4", $bytes: "abc" }],
      ["whole too big", { session: "k", to: "s2", id: "f5", size: 60 * 1024 * 1024, $bytes: "" }],
      ["whole nobody", { session: "k", to: "zz", id: "f6", size: 1, $bytes: "a" }],
      ["chunk 0", { session: "k", to: "s2", id: "c1", offset: 0, data: Buffer.from("hello ").toString("base64") }],
      ["chunk gap", { session: "k", to: "s2", id: "c1", offset: 99, data: "" }],
      ["chunk 1", { session: "k", to: "s2", id: "c1", offset: 6, data: Buffer.from("world").toString("base64"), final: true }],
      ["chunk no offset", { session: "k", to: "s2", id: "c2" }],
      ["chunk big", { session: "k", to: "s2", id: "c3", offset: 0, data: Buffer.alloc(300 * 1024).toString("base64") }],
    ];
    for (const [label, req] of puts) {
      const tsReq = { ...req };
      if (tsReq.$bytes !== undefined) {
        const bytes = Buffer.from(tsReq.$bytes, "utf8");
        delete tsReq.$bytes;
        bus.withBytes(tsReq, (async function* () { yield bytes; })());
      }
      const mbReq = { ...req, ...(req.$bytes !== undefined ? { $bytes: Buffer.from(req.$bytes, "utf8").toString("base64") } : {}) };
      await both(`putForPeer ${label}`, a, b, () => peerFiles.putForPeer(a.hub, "peer-1", tsReq, "W1"), "putForPeer", "peer-1", mbReq, "W1");
    }
    same("staged", a, b, (rel) => rel.endsWith(".part"));
    for (const given of [[{ id: "f1", name: "hello.txt" }, { id: "c1", name: " " }], [{ id: "missing", name: "m" }], "x", null, [{ id: "f1" }]]) {
      await both(`claim ${JSON.stringify(given)}`, a, b, () => peerFiles.claim(a.hub, "peer-1", "k", "s2", given), "claim", "peer-1", "k", "s2", given);
    }
    same("claimed", a, b, (rel) => rel.endsWith(".part"));
  });

  test("clones into the repository cache: started, found there, failed, dropped", { timeout: 120_000 }, async () => {
    const [a, b] = twins("clones", (w) => {
      put(join(w.data, "repos", "kept", ".git", "config"), '[remote "origin"]\n\turl = git@github.com:team/kept.git\n');
      mkdirSync(join(w.data, "repos", ".cloning-c-0000000000"), { recursive: true });
      mkdirSync(join(w.data, "repos", "app"), { recursive: true });
      mkdirSync(join(w.data, "repos", "org-app"), { recursive: true });
      w.clonesIndex = [{ repo: "github.com/team/local", path: "/somewhere/local" }];
    });
    const made = (w: World) => new clones.Clones({ reposDir: () => join(w.data, "repos"), now: () => NOW, index: { repos: async () => w.clonesIndex }, run: (args: string[]) => { const [done, kill] = fakeGit(w, args); return { done, kill }; } });
    const ca = made(a);
    const changed = (tag: string) => () => tsWorld!.tell("clones.changed", tag);
    // (the TypeScript's clones done with the disk: none it started under way but those that hang, and none's temporary
    // folder left. Waited for as a fact, not a count of the loop's turns: its mkdir, rm and rename take as many as the
    // disk does, and one left under way answered the next start as running where the program's was there, on CI)
    const started = new Set<string>();
    const settle = async () => {
      for (;;) {
        const going = ["W1", "W2", null].flatMap((ws) => ca.list(ws)).filter((c: Json) => c.state === "cloning");
        const temps = readdirSync(join(a.data, "repos")).filter((n) => n.startsWith(".cloning-")).map((n) => n.slice(".cloning-".length));
        const done = going.every((c: Json) => c.url.includes("hang")) && temps.every((id) => !started.has(id) || going.some((c: Json) => c.id === id));
        if (done) return;
        await new Promise((r) => setImmediate(r));
      }
    };
    const step = async (label: string, given: Json, ws: string | null) => {
      const x = await tsDo(a, () => ca.start(ws, given, "ann@x", changed(label)));
      if ("value" in x && x.value?.state === "cloning") started.add(x.value.id);
      await settle();
      const y = await mbDo(b, "clonesStart", ws, given, "ann@x", label);
      if (!label.startsWith("hang")) await mbDo(b, "settle");
      assert.deepStrictEqual(norm(b, y), norm(a, x), `clones.start ${label}`);
    };
    await step("kept", "git@github.com:team/kept", null);
    await step("local", "https://github.com/team/local.git", "W1");
    await step("new", "org/app", "W1");
    await step("again", "https://github.com/org/app", "W1");
    await step("fails", "https://user:tok@example.com/fail/x", "W1");
    await step("bad", "file:///x", "W1");
    await step("hang", "https://h.com/hang/x", "W2");
    await step("hang again", "https://h.com/hang/x", "W2");
    for (const ws of ["W1", "W2", null]) await both(`clones.list ${ws}`, a, b, () => ca.list(ws), "clonesList", ws);
    const hangA = ca.list("W2")[0].id;
    const hangB = (await mbDo(b, "clonesList", "W2") as Json).value[0].id;
    await tsDo(a, async () => { ca.drop("W2", hangA); await settle(); });
    await mbDo(b, "clonesDrop", "W2", hangB);
    await mbDo(b, "settle");
    const failedA = ca.list("W1").find((c: Json) => c.state === "failed").id;
    const failedB = (await mbDo(b, "clonesList", "W1") as Json).value.find((c: Json) => c.state === "failed").id;
    const d1 = await tsDo(a, () => ca.drop("W1", failedA));
    const d2 = await mbDo(b, "clonesDrop", "W1", failedB);
    assert.deepStrictEqual(d2, d1);
    await both("clones.drop (none)", a, b, () => ca.drop("W1", "c-none"), "clonesDrop", "W1", "c-none");
    for (const ws of ["W1", "W2"]) await both(`clones.list after ${ws}`, a, b, () => ca.list(ws), "clonesList", ws);
    same("clones", a, b);
  });

  test("the agents' homes: made, skills written and linked, transcripts shared", { timeout: 120_000 }, async () => {
    const [a, b] = twins("agent-home", (w) => {
      const home = join(w.data, "agent");
      put(join(home, "MEMORY.md"), "# memory\n");
      put(join(home, "skills", "team-skill", "SKILL.md"), "team\n");
      put(join(home, "skills", "stillfail-jobs", "SKILL.md"), "old text\n");
      put(join(home, "skills", agentHome.FEEDBACK_SKILL, "SKILL.md"), "fb\n");
      put(join(w.root, "site", "machine", "SKILL.md"), "machine\n");
      mkdirSync(join(w.root, "site", "team-skill"), { recursive: true });
      mkdirSync(join(w.root, "site", ".hidden"), { recursive: true });
      symlinkSync(join(w.root, "site", "removed"), join(home, "skills", "removed"));
      const p1 = join(w.data, "homes", "p1");
      mkdirSync(p1, { recursive: true });
      symlinkSync(join(home, "MEMORY.md"), join(p1, "CLAUDE.md"));
      symlinkSync(join(home, "skills"), join(p1, "skills"));
      mkdirSync(join(p1, "grok", "skills"), { recursive: true });
      symlinkSync(join(home, "skills", "team-skill"), join(p1, "grok", "skills", "team-skill"));
      put(join(p1, "grok", "skills", "own", "SKILL.md"), "own\n");
      put(join(p1, "projects", "proj", "t.jsonl"), "aaa\n");
      put(join(p1, "projects", "proj", "grown.jsonl"), "ab");
      put(join(w.data, "transcripts", "claude", "proj", "grown.jsonl"), "abc");
      put(join(p1, "projects", "proj", "differs.jsonl"), "xyz");
      put(join(w.data, "transcripts", "claude", "proj", "differs.jsonl"), "abc");
      put(join(w.data, "homes", "gone", "sessions", "2026", "r.jsonl"), "r\n");
      put(join(w.data, "homes", "gone2", "sessions", "only-file"), "f\n");
      put(join(w.root, "outside-home", "projects", "x.jsonl"), "x\n");
      const work = join(w.root, "work");
      mkdirSync(join(work, ".claude", "skills"), { recursive: true });
      symlinkSync(join(home, "skills", "removed"), join(work, ".claude", "skills", "removed"));
      put(join(work, ".agents", "skills", "team-skill", "SKILL.md"), "preset's\n");
    });
    const home = (w: World) => join(w.data, "agent");
    const source = () => join(stationDir, "src", "skills");
    for (const [ws, h] of [["W1", "W1"], [null, "W1"], ["W2", null], ["W2", "W1"], ["bad/ws", "W1"]]) {
      await both(`workspaceAgentHomePath ${ws}`, a, b, () => agentHome.workspaceAgentHomePath(home(a), ws, h), "workspaceAgentHomePath", home, ws, h);
    }
    await both("writeBuiltinSkills", a, b, () => agentHome.writeBuiltinSkills(home(a), false, join(a.root, "site")), "writeBuiltinSkills", home, false, source, (w: World) => join(w.root, "site"));
    same("skills written", a, b, (rel) => rel.startsWith("skills-src"));
    // (moving off here: stillfail-move taken away, then written again as it is on)
    await both("writeBuiltinSkills, moving off", a, b, () => agentHome.writeBuiltinSkills(home(a), false, join(a.root, "site"), false), "writeBuiltinSkills", home, false, source, (w: World) => join(w.root, "site"), false);
    same("skills written, moving off", a, b, (rel) => rel.startsWith("skills-src"));
    await both("writeBuiltinSkills, moving on", a, b, () => agentHome.writeBuiltinSkills(home(a), false, join(a.root, "site"), true), "writeBuiltinSkills", home, false, source, (w: World) => join(w.root, "site"), true);
    await both("workspaceAgentHome", a, b, () => agentHome.workspaceAgentHome(home(a), "W2", "W1"), "workspaceAgentHome", home, "W2", "W1", source, null);
    await both("workspaceAgentHome (made)", a, b, () => agentHome.workspaceAgentHome(home(a), "W2", "W1"), "workspaceAgentHome", home, "W2", "W1", source, null);
    await both("agentHomes", a, b, () => agentHome.agentHomes(home(a)), "agentHomes", home);
    const profiles = (w: World) => [{ id: "p1", runtimes: ["claude", "grok"], home: join(w.data, "homes", "p1") }, { id: "p2", runtimes: ["codex"], home: join(w.root, "outside-home") }];
    await both("unlinkAgentHome", a, b, () => agentHome.unlinkAgentHome(home(a), profiles(a)), "unlinkAgentHome", home, profiles);
    same("unlinked", a, b, (rel) => rel.startsWith("skills-src"));
    await both("sessionSkills", a, b, () => agentHome.sessionSkills(join(a.root, "work"), join(home(a), "skills")), "sessionSkills", (w: World) => join(w.root, "work"), (w: World) => join(home(w), "skills"));
    await both("sessionSkills (none)", a, b, () => agentHome.sessionSkills(join(a.root, "work2"), join(a.root, "noskills")), "sessionSkills", (w: World) => join(w.root, "work2"), (w: World) => join(w.root, "noskills"));
    same("session skills", a, b, (rel) => rel.startsWith("skills-src"));
    await both("linkTranscripts", a, b, () => agentHome.linkTranscripts(a.data, profiles(a)), "linkTranscripts", (w: World) => w.data, profiles);
    await both("linkTranscripts (again)", a, b, () => agentHome.linkTranscripts(a.data, profiles(a)), "linkTranscripts", (w: World) => w.data, profiles);
    same("transcripts shared", a, b, (rel) => rel.startsWith("skills-src"));
  });

  test("a chat relayed to a channel or a thread", { timeout: 120_000 }, async () => {
    const [a, b] = twins("relay", (w) => {
      session(w, "s1", { connect: "slack-b" });
      session(w, "s2");
      thread(w, 1, { home: "s1", title: "Plan [v2]" }, [{ session: "s1", connect: "ember" }]);
      thread(w, 2, {}, []);
      thread(w, 3, { surface: "surface-slack-a", channel: "C2", threadTs: "1700000000.000002" }, [{ session: "s2", connect: "slack-a" }]);
      w.links.set("s1", "https://app/o/W1/st/s1");
      w.relayed.set("slack-a", [["C1", NOW - 10]]);
      w.connects = [
        { id: "slack-a", kind: "slack", enabled: true, bind: { runtime: "claude", profile: "p1" } },
        { id: "slack-b", kind: "slack", enabled: true, bind: { runtime: "codex" } },
        { id: "lark-1", kind: "feishu", enabled: true, workspace: "W1", bind: { runtime: "claude", model: "opus" } },
        { id: "off", kind: "slack", enabled: false, bind: {} },
        { id: "grp", kind: "group", enabled: true, bind: {} },
        { id: "elsewhere", kind: "slack", enabled: true, workspace: "W9", bind: {} },
        { id: "broken", kind: "slack", enabled: true, bind: {} },
      ];
      const told = (what: string, ...args: Json[]) => w.tell(`chat.${what}`, ...args);
      w.surfaces.set("slack-a", {
        places: async () => [{ id: "C1", name: "general", kind: "channel" }, { id: "C3", name: "Alpha", kind: "channel" }, { id: "C4", name: "beta", kind: "channel" }, { id: "C2", name: "dev", kind: "channel" }],
        begin: async (channel: string, text: string) => { told("begin", "slack-a", channel, text); return { thread: { channel, threadTs: "1800000000.000001" }, ts: "1800000000.000001" }; },
        post: async (ref: Json, text: string) => { told("post", "slack-a", ref, text); return "1800000000.000009"; },
        botName: () => "Bot A", identity: () => ({ team: "Team", botImage: "" }), workspace: () => "T1", joins: () => true,
        openPlaces: async () => [{ id: "C7", name: "open", kind: "channel" }],
        join: async (channel: string) => told("join", "slack-a", channel),
        threadOf: (link: string) => (link.includes("/archives/C2/p") ? { channel: "C2", threadTs: "1700000000.000002" } : link.includes("/archives/C4/p") ? { channel: "C4", threadTs: "1700000000.000004" } : null),
        peopleIn: async () => [{ id: "U1", name: "Ann" }],
        mention: (id: string) => `<@${id}>`, userOf: async (email: string) => (email === "ann@x" ? "U1" : null),
        permalink: (t: Json) => `https://slack/archives/${t.channel}/p${t.threadTs}`, edit: () => {},
      });
      w.surfaces.set("slack-b", { places: async () => [{ id: "D1", name: "zed", kind: "channel" }], begin: async () => ({ thread: { channel: "D1", threadTs: "1.1" }, ts: "1.1" }), post: async () => "1", workspace: () => "", joins: () => false });
      w.surfaces.set("lark-1", {
        places: async () => [{ id: "oc_g", name: "群", kind: "topics" }, { id: "oc_h", name: "Group", kind: "group" }], platform: () => "lark", workspace: () => "tenant",
        begin: async (channel: string, text: string) => { told("begin", "lark-1", channel, text); return { thread: { channel, threadTs: "om_1" }, ts: "om_1" }; }, post: async () => "x",
        openPlaces: async () => { throw new Error("no"); },
      });
      w.surfaces.set("broken", { places: async () => { throw new Error("token revoked"); }, begin: async () => ({}) , workspace: () => null });
      w.surfaces.set("elsewhere", { places: async () => [], begin: async () => ({}), workspace: () => "" });
    });
    await both("relayPlaces", a, b, () => relay.relayPlaces(a.hub, a.thread(1)), "relayPlaces", (w: World) => w.thread(1));
    await both("relayPlaces (no agent)", a, b, () => relay.relayPlaces(a.hub, a.thread(2)), "relayPlaces", (w: World) => w.thread(2));
    for (const target of [{ connect: "slack-a", channel: "C1" }, { link: "https://x/archives/C4/p1" }, { connect: "nope", channel: "C1" }, { link: "https://x/none" }, { connect: "slack-a", channel: "C9" }]) {
      await both(`relayPeople ${JSON.stringify(target)}`, a, b, () => relay.relayPeople(a.hub, a.thread(1), target), "relayPeople", (w: World) => w.thread(1), target);
    }
    const relays: [Json, Json, string][] = [
      [{ name: "Ann", email: "ann@x" }, { connect: "slack-a", channel: "C1" }, "  see @Ann here  "],
      [{ name: "Bob", email: "bob@x" }, { connect: "lark-1", channel: "oc_g" }, ""],
      [{ name: "Bob", email: "bob@x" }, { connect: "lark-1", channel: "oc_h" }, "note"],
      [{ name: "Bob", email: "bob@x" }, { connect: "slack-a", channel: "C7", join: true }, ""],
      [{ name: "Bob", email: "bob@x" }, { link: "https://x/archives/C4/p1", connect: "slack-a" }, "thread"],
      [{ name: "Bob", email: "bob@x" }, { link: "https://x/archives/C2/p1" }, ""],
      [{ name: "Bob", email: "bob@x" }, { connect: "slack-a", channel: "C8", join: true }, ""],
    ];
    for (const [who, target, note] of relays) {
      await both(`relay ${JSON.stringify(target)}`, a, b, () => relay.relay(a.hub, a.thread(1), who, target, note), "relay", (w: World) => w.thread(1), who, target, note);
      same(`relay ${JSON.stringify(target)}`, a, b);
    }
  });
}

if (!process.execArgv.includes("--experimental-test-module-mocks")) {
  const { mbHarnessBinary } = await import("./mb-harness.ts");
  const skip = mbHarnessBinary() === null ? "the tests' MoonBit program (stillfail-reader-harness) is not built here" : false;
  test("session storage in MoonBit does as the TypeScript (run with module mocks)", { skip }, () => {
    const env = { ...process.env };
    delete env.NODE_TEST_CONTEXT;
    const run = spawnSync(process.execPath, ["--experimental-test-module-mocks", "--no-warnings", "--import", join(stationDir, "test/setup-env.mjs"), "--test", self], {
      cwd: stationDir,
      env,
      encoding: "utf8",
      maxBuffer: 256 * 1024 * 1024,
    });
    if (run.status !== 0) assert.fail(`${run.stdout}\n${run.stderr}`.split("\n").slice(-400).join("\n"));
  });
} else {
  await main();
}
