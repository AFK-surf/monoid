// GET /events, the overview, the local status and the machine's sample as the MoonBit program makes them (station/mb
// src/events, reader `--builder harness-events`) held to the TypeScript station's (api/events.ts, event-log.ts,
// seen.ts, runtime-compat.ts, oldest.ts, routes/events.ts, overview.ts, status.ts, host.ts) on the same world: every
// stream's text as its client heard it (each `id:`, `event:` and `data:` line, in order), each answer's headers,
// what was read and in what order, what went over to the next process; and the overview, the status and the host's
// sample field for field, as JSON's text.
//
// An event stream's script is played on a world of the test's (`World`, its MoonBit twin station/mb/src/events/
// world.mbt): what the store and the readers say (each read answered after what is done now, as an async function
// is), the sessions at work as they are now (`heldNow`, answered when the script says), a clock of the test's moved in
// steps (`advance`), and a station process replaced (`handover`, `restart`, `gone`).
import assert from "node:assert/strict";
import { mkdtempSync, readFileSync, existsSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { after, test } from "node:test";
import { Events } from "../src/api/events.ts";
import { EventLog } from "../src/api/event-log.ts";
import { elsewhere, went, sessionSeen, threadSeen, jobSeen } from "../src/api/seen.ts";
import { runtimeCompatible, clientRuntimes } from "../src/api/runtime-compat.ts";
import { runtimeView, OMIT } from "../src/read/runtime-view.ts";
import { buildOf, coreTooOld, OLDEST_CORE } from "../src/api/oldest.ts";
import { routes as eventRoutes } from "../src/api/routes/events.ts";
import { sees } from "../src/store/rows.ts";
import { MbProcess, mbReaderBinary } from "../src/read/mb-reader.ts";
import { createRequire, syncBuiltinESMExports } from "node:module";
import { homedir } from "node:os";
import { overview } from "../src/api/overview.ts";
import { statusOf, routeOf, statusServer } from "../src/api/status.ts";
import { Host, hostInfo } from "../src/api/host.ts";
import { platform } from "../src/platform/index.ts";
import { catalog, learn } from "../src/accounts/catalog.ts";
import { policyFrom } from "../src/sessions/archive-policy.ts";
import { DecisionSessionsUnavailable } from "../src/store/legacy-decision-session.ts";
import { SESSION_CHAT_MANY, SESSION_CHAT_VERSION } from "../src/store/session-chat-index.ts";
import { Fibers, wall } from "../src/ops/fibers.ts";
import { shapesMbt } from "../mb/src/events/gen-shapes.ts";
import { settle, testClock } from "./hub-fakes.ts";

const binary = mbReaderBinary();
const skip = binary === null ? "the MoonBit program (stillfail-reader) is not built here" : false;

type Json = any;
const dirs: string[] = [];
let program: MbProcess | null = null;
const waiting: ((answer: Json) => void)[] = [];
after(async () => {
  await program?.terminate();
  for (const d of dirs) rmSync(d, { recursive: true, force: true });
});
function fresh(prefix: string): string {
  const dir = mkdtempSync(join(tmpdir(), prefix));
  dirs.push(dir);
  return dir;
}

/// What the program answers an ask (harness.mbt `answer_of`), one at a time.
function mb(ask: Json): Promise<Json> {
  if (program === null) {
    program = new MbProcess(binary!, ["--builder", "harness-events", "--shell-dir", fresh("events-mb-shell-")]);
    program.on("message", (answer: Json) => waiting.shift()?.(answer));
    program.on("error", (error: Error) => { throw error; });
  }
  return new Promise((resolve) => {
    waiting.push(resolve);
    program!.postMessage(ask);
  });
}

// ── the world ───────────────────────────────────────────────────────────────────────────────────────────────────

const viewer = (email: string, workspace: string, more: Json = {}) => ({ sub: `sub-${email}`, email, name: email, role: "member", workspace, device: `d-${email}`, ...more });
const viewerKey = (v: Json, lang: string) => `${v.email}\0${v.workspace}\0${lang}`;

/// The store as seen.ts asks it, of the world's data.
function storeOf(world: Json): Json {
  return {
    sessionWs: (key: string) => (key in (world.sessions ?? {}) ? (world.sessions[key].ws ?? null) : undefined),
    threadSessions: (id: number) => ((world.threads ?? {})[String(id)] ?? []).map((session: string) => ({ session })),
    getJob: (id: string) => ((world.jobs ?? {})[id] !== undefined ? { sessionKey: world.jobs[id] } : null),
    getSession: (key: string) => (key in (world.sessions ?? {}) ? { key } : null),
    getThread: (id: number) => (String(id) in (world.threads ?? {}) ? { id } : null),
    handedTo: (key: string) => (world.handed ?? {})[key] ?? null,
  };
}

/// An event stream's script played on the TypeScript station: what world.mbt `play` gives.
async function playTs(script: Json[], data: Json): Promise<Json> {
  const world: Json = { ...data };
  const clock = testClock();
  const reads: Json[] = [];
  const live = new Map<string, Set<(m: unknown) => void>>();
  const logins = new Map<string, Set<(s: Json) => void>>();
  let heldPending: { resolve: (v: Json) => void; reject: (e: Error) => void }[] = [];
  let listener: (c: Json) => void = () => {};
  const file = join(fresh("events-ts-"), "events.json");
  const store = storeOf(world);
  const read = async (op: string, args: Json) => {
    reads.push([op, args]);
    if (op === "summary") {
      const during = world.duringSummary?.[args.key];
      if (during !== undefined) {
        delete world.duringSummary;
        listener(during);
      }
      const s = world.summaries?.[args.key];
      if (s === "fail") throw new Error("summary failed");
      return JSON.stringify(s ?? { key: args.key });
    }
    if (op === "job") {
      const j = world.jobsRead?.[String(args.id)];
      if (j === undefined) throw new Error(`no job ${args.id}`);
      return JSON.stringify(j);
    }
    if (op === "sharedOf") {
      if (world.sharedFails === true) throw new Error("sharedOf failed");
      const rows: Json[] = world.shared ?? [];
      if (args.sessions === null) return JSON.stringify({ rows, scope: null });
      const ids = [...args.sessions, ...args.threads.map(String)];
      return JSON.stringify({ rows: rows.filter((r) => ids.includes(String(r.id ?? ""))), scope: ids });
    }
    throw new Error(op);
  };
  const make = (previous: { pid: number | null; gone: Promise<void> }, run: string) => {
    const events = new Events({
      readers: { read } as never,
      said: (_thread, entries, lang) => {
        if (entries.some((e: Json) => "boom" in e)) throw new Error("said failed");
        return entries.map((e: Json) => ({ n: e.n, text: e.text, lang }));
      },
      subscribe: (l) => ((listener = l as never), () => {}),
      host: async () => {
        if (world.host === "fail") throw new Error("host failed");
        return world.host ?? null;
      },
      jobLog: (id) => (world.logs !== undefined && id in world.logs ? `/nonexistent-stillfail-events/${id}` : null),
      logNow: async (id) => world.logs?.[id] ?? null,
      sessionExists: (key) => key in (world.sessions ?? {}),
      liveSeen: (v, key) => key in (world.sessions ?? {}) && sees(v, world.sessions[key].ws ?? null),
      seen: (v, of) => ("session" in of ? sessionSeen(store, v, of.session) : "thread" in of ? threadSeen(store, v, of.thread) : jobSeen(store, v, of.job)),
      clock: clock.clock,
      handover: { file, previous },
    });
    (events as Json).log = new EventLog(run);
    events.follow({
      live: (key, from, last, send, brief) => {
        reads.push(["live", key, from, last ?? null, brief]);
        if (!live.has(key)) live.set(key, new Set());
        live.get(key)!.add(send);
        return () => void live.get(key)!.delete(send);
      },
      held: () => world.held ?? [],
      heldNow: (keys) => {
        reads.push(["heldNow", keys]);
        return new Promise((resolve, reject) => heldPending.push({ resolve, reject }));
      },
      overview: async (v, lang) => {
        reads.push(["overview", viewerKey(v, lang)]);
        return world.overviews?.[`${v.email}|${lang}`] ?? { viewer: v.email, lang };
      },
      processState: (key) => world.states?.[key],
      followed: () => void reads.push(["followed"]),
      loginScreen: (id, send) => {
        if (!logins.has(id)) logins.set(id, new Set());
        logins.get(id)!.add(send as never);
        return () => void logins.get(id)!.delete(send as never);
      },
      inVault: (v, vault) => (world.vaults?.[vault] ?? []).includes(v.email),
    });
    return events;
  };
  const run = data.run ?? "0a0b0c0d";
  // (none held the station before: nothing to take up)
  let events = make({ pid: null, gone: Promise.resolve() }, run);
  await settle();
  const heard = new Map<string, { text: string; answer: Json; close?: () => void }>();
  const handed: (string | null)[] = [];
  let gone: () => void = () => {};
  const lastId = (text: string) => [...text.matchAll(/^id: (.*)$/gm)].at(-1)?.[1] ?? null;
  for (const step of script) {
    switch (step.do) {
      case "world":
        Object.assign(world, step.set);
        break;
      case "open": {
        const h: { text: string; answer: Json; close?: () => void } = { text: "", answer: null };
        const since = typeof step.since === "string" ? step.since : step.since?.heard !== undefined ? lastId(heard.get(step.since.heard)?.text ?? "") : null;
        heard.set(step.name, h);
        const lang = (step.lang ?? "zh").trim();
        void events.open(step.viewer, lang, step.host === true, step.live ?? [], step.logs ?? [], since, step.brief === true, step.logins ?? [], step.running === true).then(
          (answer) => {
            h.answer = { headers: answer.headers };
            const body = answer.body as Json;
            h.close = () => void body.return();
            const headers: Record<string, string> = step.runtimes === undefined ? {} : { "stillfail-runtimes": step.runtimes };
            const shown = runtimeCompatible({ method: "GET", path: "/events", headers, body: Buffer.alloc(0), query: [], viewer: step.viewer, lang } as never, answer);
            if (shown.body === answer.body) body.relay((text: string) => (h.text += text), () => {});
            else void (async () => { for await (const piece of shown.body as AsyncIterable<Buffer>) h.text += piece.toString(); })();
          },
          () => (h.answer = { error: true }),
        );
        break;
      }
      case "close":
        heard.get(step.name)?.close?.();
        break;
      case "change":
        listener(step.change);
        break;
      case "overviewChanged":
        events.overviewChanged();
        break;
      case "rowsChanged":
        events.rowsChanged(step.viewer ?? null, step.made === true);
        break;
      case "screens":
        events.screens((lang) => step.byLang[lang] ?? null);
        break;
      case "tell":
        events.tell(step.event, step.data, step.of, step.to);
        break;
      case "machineLogins":
        events.machineLogins(step.data, step.limited, step.of);
        break;
      case "presets":
        events.presetsChanged();
        break;
      case "heldTold":
        events.heldTold(step.key, step.message);
        break;
      case "heldNow": {
        const pending = heldPending;
        heldPending = [];
        for (const p of pending) step.fail === true ? p.reject(new Error("failed")) : p.resolve(step.now);
        break;
      }
      case "live":
        for (const send of [...(live.get(step.key) ?? [])]) send(step.message);
        break;
      case "login":
        for (const send of [...(logins.get(step.id) ?? [])]) send(step.screen);
        break;
      case "advance": {
        const chunk = step.step ?? 1000;
        for (let left = step.ms; left > 0; left -= Math.min(chunk, left)) {
          await clock.adjust(Math.min(chunk, left));
          await settle();
        }
        break;
      }
      case "handover":
        await events.handOver();
        handed.push(existsSync(file) ? readFileSync(file, "utf8") : null);
        break;
      case "restart": {
        let resolve!: () => void;
        const promise = new Promise<void>((r) => (resolve = r));
        gone = resolve;
        events = make({ pid: step.from ?? null, gone: promise }, step.run ?? run);
        break;
      }
      case "gone":
        gone();
        break;
      default:
        throw new Error(`no step ${step.do}`);
    }
    await settle();
  }
  const names = [...heard.keys()];
  return {
    streams: Object.fromEntries(names.map((n) => [n, heard.get(n)!.text])),
    answers: Object.fromEntries(names.map((n) => [n, heard.get(n)!.answer])),
    reads,
    handed,
    at: (events as Json).log.at(),
  };
}

/// Both stations given the same script and world: the same, frame for frame.
async function same(script: Json[], world: Json) {
  const ts = await playTs(script, world);
  const moon = await mb({ op: "events", script, world });
  assert.equal(moon.error, undefined, `the program failed: ${moon.error}`);
  for (const name of Object.keys(ts.streams)) {
    const frames = (t: string) => t.split("\n\n");
    assert.deepEqual(frames(moon.streams[name] ?? ""), frames(ts.streams[name]), `${name}'s stream, frame for frame`);
  }
  assert.deepEqual(moon.answers, ts.answers, "the answers' headers");
  assert.deepEqual(moon.reads, ts.reads, "what was read, in order");
  assert.deepEqual(moon.handed, ts.handed, "what went over to the next process");
  assert.equal(moon.at, ts.at, "where the log is");
  assert.deepEqual(moon, ts);
  return ts;
}

// ── the scripts ─────────────────────────────────────────────────────────────────────────────────────────────────

const A = viewer("a@x", "w1", { role: "owner", home: true });
const B = viewer("B@x", "w2", { home: false });
const C = viewer("c@x", "w1", { role: "viewer" });
const A2 = { ...A, device: "phone", lockDevice: { base: "b", proof: "p" } };

const WORLD = {
  run: "5eed01",
  sessions: { s1: { ws: null }, s2: { ws: "w2" }, s3: { ws: null }, s4: { ws: "handed:w1" } },
  threads: { "1": ["s1"], "2": ["s2"], "3": [], "4": ["s3", "s2"] },
  jobs: { j1: "s1", j2: "s2" },
  logs: { j1: { text: "line one\n", outputAt: 5 }, j2: { text: null, outputAt: null } },
  jobsRead: { j1: { id: "j1", state: "running", session: "s1" }, j2: { id: "j2", state: "done" } },
  host: { hostname: "h", cpuBusy: 0.5, checkedAt: 1, uptimeSec: 2 },
  shared: [
    { id: "s1", ws: null, title: "one" },
    { id: "s2", ws: "w2", title: "two" },
    { id: "1", ws: null, title: "thread one" },
  ],
  states: { s1: "running" },
  held: ["s1", "s2", "s3"],
  vaults: { v1: ["a@x"] },
  summaries: { s3: { key: "s3", runtime: "hermes", title: "three" }, s2: { key: "s2", runtime: "codex", "10": "ten", "2": "two" } },
  overviews: { "a@x|zh": { counts: { sessions: 2 }, profiles: [{ id: "p", runtime: "pi" }], viewer: "a" } },
};

test("a workspace's streams, frame for frame: shared rows, the sessions at work, what each viewer sees", { skip }, async () => {
  await same([
    { do: "open", name: "a1", viewer: A, running: true, host: true, logs: [["j1", 10], ["nope", 5]], logins: ["lg1"] },
    { do: "open", name: "b1", viewer: B, running: true, logs: [["j2", 3]], runtimes: "claude,codex,dsh,grok,cursor,devin,hermes,agy,pi" },
    { do: "open", name: "c1", viewer: C, runtimes: "claude, codex,BAD", live: [["s1", 0, null], ["s3", 4, 2]] },
    { do: "open", name: "a-en", viewer: A2, lang: "en", running: true },
    // What the sessions at work did while each was read as it is now, after it, in order.
    { do: "heldTold", key: "s1", message: { step: 1 } },
    { do: "heldTold", key: "s2", message: { step: "b", key: "old" } },
    { do: "heldTold", key: "s3", message: { step: 3 } },
    { do: "heldNow", now: { s1: [{ step: 0 }], s2: [{ step: "a" }], s3: [] } },
    { do: "heldTold", key: "s1", message: { step: 2 } },
    { do: "live", key: "s1", message: { entry: 1 } },
    { do: "live", key: "s3", message: { entry: 2 } },
    { do: "login", id: "lg1", screen: { rows: ["$ a", "b", "", "", "", "", "", "", "", "", "x"], cursor: { x: 1, y: 0 }, echo: true, live: true } },
    { do: "login", id: "lg1", screen: { rows: ["$ a", "c", "", "", "", "", "", "", "", "", "y", "z"], cursor: { x: 0, y: 1 }, echo: false, live: true } },
    { do: "change", change: { type: "session", key: "s1", pending: 1 } },
    { do: "change", change: { type: "session", key: "s2" } },
    { do: "change", change: { type: "session", key: "s3", pending: 0 } },
    { do: "change", change: { type: "session", key: "gone" } },
    { do: "change", change: { type: "thread", id: 1, entries: [{ n: 1, text: "hi", extra: true }] } },
    { do: "change", change: { type: "thread", id: 2, entries: [] } },
    { do: "change", change: { type: "thread", id: 4, entries: [{ n: 9 }] } },
    { do: "change", change: { type: "thread", id: 3, entries: [{ n: 2, boom: 1 }] } },
    { do: "change", change: { type: "letters", id: 1, letters: [{ n: 1, text: "letter" }] } },
    { do: "change", change: { type: "read", viewer: "A@X", thread: 1, n: 3 } },
    { do: "change", change: { type: "hidden", viewer: "a@x", thread: 2, hidden: true } },
    { do: "change", change: { type: "muted", viewer: "b@x", thread: 2, muted: false } },
    { do: "change", change: { type: "pins", viewer: "a@x", session: "s1" } },
    { do: "change", change: { type: "pins", viewer: "a@x" } },
    { do: "change", change: { type: "dismissed", viewer: "a@x", card: { thread: 1, n: 4 }, kept: { thread: 1, ts: 2 } } },
    { do: "change", change: { type: "dismissed", viewer: "b@x" } },
    { do: "change", change: { type: "job", id: "j1" } },
    { do: "change", change: { type: "job", id: "missing" } },
    { do: "change", change: { type: "jobRemoved", id: "j2", session: "s2" } },
    { do: "change", change: { type: "chatMark", thread: 1, session: "s1", mark: "star", n: 2 } },
    { do: "change", change: { type: "chatMark", thread: null, session: "s2", mark: "x" } },
    { do: "change", change: { type: "identities", viewer: "a@x" } },
    { do: "change", change: { type: "processes" } },
    { do: "world", set: { overviews: { "a@x|zh": { counts: { sessions: 3 } } } } },
    { do: "change", change: { type: "decisionChecks" } },
    { do: "change", change: { type: "unknown-kind" } },
    { do: "screens", byLang: { zh: [{ id: 1, name: "屏" }], en: [{ id: 1, name: "screen" }] } },
    { do: "tell", event: "vault", data: { v: 1 }, of: "vault\0v1", to: { vault: "v1", workspace: "w1" } },
    { do: "tell", event: "people", data: { p: 1 }, of: "people", to: { subs: ["sub-c@x", "sub-B@x"] } },
    { do: "machineLogins", data: { login: { id: "m", log: "secret" } }, limited: { login: { id: "m" } }, of: "m" },
    { do: "presets" },
    { do: "rowsChanged", viewer: "c@x" },
    { do: "rowsChanged" },
    { do: "world", set: { logs: { j1: { text: "line one\nline two\n", outputAt: 9 }, j2: { text: "two", outputAt: null } } } },
    { do: "advance", ms: 5000 },
    { do: "world", set: { host: { hostname: "h", cpuBusy: 0.5, checkedAt: 7, uptimeSec: 9 } } },
    { do: "advance", ms: 10000 },
    { do: "world", set: { host: { hostname: "h", cpuBusy: 0.75, checkedAt: 7, uptimeSec: 9 } } },
    { do: "advance", ms: 11000 },
    { do: "world", set: { host: null } },
    { do: "advance", ms: 10000 },
    { do: "world", set: { host: "up" } },
    { do: "advance", ms: 10000 },
    { do: "change", change: { type: "session", key: "s1", pending: null } },
    { do: "change", change: { type: "moved", key: "s2", station: "st2", thread: 2, there: 7, ws: "w2" } },
    { do: "change", change: { type: "threadRemoved", id: 3 } },
    { do: "change", change: { type: "sessionRemoved", key: "s3" } },
    { do: "close", name: "a1" },
    { do: "close", name: "b1" },
    { do: "close", name: "a-en" },
  ], WORLD);
});

test("a stream that comes back is told what it missed; a shared row moves and goes", { skip }, async () => {
  await same([
    { do: "open", name: "a1", viewer: A },
    { do: "open", name: "b1", viewer: B },
    { do: "open", name: "old", viewer: C },
    { do: "change", change: { type: "session", key: "s1" } },
    { do: "close", name: "a1" },
    { do: "world", set: { shared: [{ id: "s1", ws: "w2", title: "moved" }, { id: "s2", ws: "w2", title: "two" }, { id: 7, title: "number" }] } },
    { do: "change", change: { type: "session", key: "s1" } },
    { do: "change", change: { type: "usage", from: 100 } },
    { do: "change", change: { type: "usage", from: 50 } },
    { do: "change", change: { type: "usage" } },
    { do: "advance", ms: 30000 },
    { do: "open", name: "a2", viewer: A, since: { heard: "a1" } },
    { do: "open", name: "a3", viewer: A, since: "5eed01.1" },
    { do: "open", name: "a4", viewer: A, since: "another.3" },
    { do: "open", name: "a5", viewer: A, since: "5eed01.99999" },
    { do: "advance", ms: 31000 },
    { do: "change", change: { type: "usage", from: 10 } },
    { do: "world", set: { shared: [{ id: "s2", ws: "w2", title: "two again" }] } },
    { do: "rowsChanged" },
    { do: "change", change: { type: "usage", from: 5 } },
    { do: "advance", ms: 60000, step: 5000 },
    { do: "change", change: { type: "usage", from: "70" } },
    { do: "change", change: { type: "usage", from: 90 } },
    { do: "advance", ms: 60000, step: 5000 },
    { do: "change", change: { type: "usage", from: 80 } },
    { do: "change", change: { type: "usage", from: null } },
    { do: "advance", ms: 60000, step: 5000 },
    { do: "close", name: "a2" },
    { do: "close", name: "b1" },
    { do: "close", name: "a3" },
    { do: "close", name: "a4" },
    { do: "close", name: "a5" },
    { do: "close", name: "old" },
    // Nobody follows: what is told is made a while for one coming back, then nothing before can be.
    { do: "change", change: { type: "session", key: "s2", pending: 2 } },
    { do: "advance", ms: 3_000_000, step: 1_000_000 },
    { do: "open", name: "back", viewer: B, since: { heard: "b1" } },
    { do: "close", name: "back" },
    { do: "advance", ms: 3_600_001, step: 3_600_001 },
    { do: "open", name: "late", viewer: B, since: { heard: "back" } },
    { do: "close", name: "late" },
  ], WORLD);
});

test("the shared list unread ends its streams and what was told; a summary read across a taking is read again", { skip }, async () => {
  await same([
    { do: "open", name: "a1", viewer: A },
    { do: "open", name: "c1", viewer: C },
    { do: "world", set: { duringSummary: { s1: { type: "session", key: "s1", pending: 4 } } } },
    { do: "change", change: { type: "session", key: "s1" } },
    { do: "world", set: { sharedFails: true } },
    { do: "change", change: { type: "session", key: "s3" } },
    { do: "open", name: "a2", viewer: A, since: { heard: "a1" } },
    { do: "world", set: { sharedFails: false, summaries: { s3: "fail" } } },
    { do: "open", name: "a3", viewer: A, since: { heard: "c1" } },
    { do: "change", change: { type: "session", key: "s3" } },
    { do: "heldNow", now: {} },
    { do: "close", name: "c1" },
    { do: "close", name: "a3" },
  ], WORLD);
});

test("the sessions at work: a failed look, a viewer who sees none, a stream from before naming its own", { skip }, async () => {
  await same([
    { do: "open", name: "a1", viewer: A, running: true, live: [["s1", 0, null]] },
    { do: "open", name: "b1", viewer: B, running: true },
    { do: "heldTold", key: "s1", message: { a: 1 } },
    { do: "heldNow", fail: true },
    { do: "heldTold", key: "s1", message: { a: 2 } },
    { do: "world", set: { held: [] } },
    { do: "open", name: "a2", viewer: A, running: true },
    { do: "heldTold", key: "s3", message: "words" },
    { do: "close", name: "a1" },
    { do: "close", name: "b1" },
    { do: "close", name: "a2" },
  ], WORLD);
});

test("a station process replaced: what it told goes on in the next, streams resumed, what came meanwhile after", { skip }, async () => {
  await same([
    { do: "open", name: "a1", viewer: A2 },
    { do: "open", name: "b1", viewer: B },
    { do: "change", change: { type: "session", key: "s1", pending: 1 } },
    { do: "change", change: { type: "processes" } },
    { do: "change", change: { type: "usage", from: 3 } },
    { do: "change", change: { type: "usage", from: 1 } },
    { do: "handover", pid: process.pid },
    { do: "change", change: { type: "session", key: "s2" } },
    { do: "restart", from: process.pid, run: "0ff1ce" },
    { do: "open", name: "a2", viewer: A, since: { heard: "a1" } },
    { do: "change", change: { type: "thread", id: 1, entries: [{ n: 5, text: "meanwhile" }] } },
    { do: "change", change: { type: "session", key: "s1" } },
    { do: "gone" },
    { do: "open", name: "b2", viewer: B, since: { heard: "b1" } },
    { do: "change", change: { type: "session", key: "s2" } },
    { do: "handover", pid: process.pid },
    { do: "restart", from: 1, run: "0ff1ce" },
    { do: "gone" },
    { do: "open", name: "b3", viewer: B, since: { heard: "b2" } },
    { do: "close", name: "b3" },
    { do: "handover", pid: process.pid },
    { do: "restart", from: null, run: "abba" },
    { do: "open", name: "b4", viewer: B },
    { do: "gone" },
    { do: "advance", ms: 3_700_000, step: 3_700_000 },
    { do: "handover", pid: process.pid },
    { do: "restart", from: process.pid, run: "ab" },
    { do: "advance", ms: 3_600_001, step: 3_600_001 },
    { do: "gone" },
    { do: "open", name: "b5", viewer: B, since: { heard: "b4" } },
    { do: "close", name: "b5" },
  ], WORLD);
});

// ── the log, the shapes, what a request asks ────────────────────────────────────────────────────────────────────

test("the log: kept by count, bytes and time, a thing said whole kept once, handed over and gone on from", { skip }, async () => {
  const keeps = { ms: 1000, most: 4, bytes: 400 };
  const script: Json[] = [];
  for (let i = 0; i < 12; i++) script.push({ do: "append", event: i % 3 === 0 ? "overview" : "session", data: { i, text: "x".repeat(i * 7) }, to: i % 2 ? { lang: "zh" } : {}, now: i * 150, ...(i % 3 === 0 ? { of: "overview\0a" } : {}) });
  script.splice(5, 0, { do: "has", since: "ab.2" }, { do: "after", since: "ab.3" }, { do: "state" });
  script.push({ do: "has", since: "ab.9" }, { do: "has", since: "ab.007" }, { do: "has", since: "AB.9" }, { do: "after", since: "ab.8" }, { do: "at" }, { do: "kept" }, { do: "state" });
  script.push({ do: "from", now: 2000 }, { do: "state" }, { do: "after", since: "ab.10" });
  script.push({ do: "from", now: 1700, kept: { run: "ab", seq: 3, forgotten: 1, events: [{ n: 2, to: {}, text: "t", at: 1600 }, { n: 3, to: {}, text: "u", at: 1650, of: "o" }] } }, { do: "after", since: "ab.1" }, { do: "kept" });
  for (const bad of [{ run: "XY", seq: 1, forgotten: 0, events: [] }, { run: "ab", seq: 1, forgotten: 2, events: [] }, { run: "ab", seq: 3, forgotten: 0, events: [{ n: 1, text: "a", at: 0 }, { n: 1, text: "b", at: 0 }] }, { run: "ab", seq: 1.5, forgotten: 0, events: [] }])
    script.push({ do: "from", now: 0, kept: bad });
  script.push({ do: "clear" }, { do: "at" }, { do: "has", since: "ab.3" });
  const ts: Json[] = [];
  let log = new EventLog<Json>("ab", keeps);
  for (const s of script) {
    switch (s.do) {
      case "append": ts.push(log.append(s.event, s.data, s.to, s.now, s.of).text); break;
      case "has": ts.push(log.has(s.since)); break;
      case "after": ts.push(log.after(s.since).map((e) => e.text)); break;
      case "at": ts.push(log.at()); break;
      case "clear": log.clear(); break;
      case "state": ts.push(log.state()); break;
      case "kept": ts.push(JSON.parse(JSON.stringify(log.kept()))); break;
      case "from":
        try { log = EventLog.from(structuredClone(s.kept ?? log.kept()), s.now, keeps); ts.push("ok"); } catch { ts.push("not a log"); }
        break;
    }
  }
  assert.deepEqual(await mb({ op: "log", run: "ab", keeps, script }), ts);
});

test("shapes.mbt is what gen-shapes.ts makes of the client's shapes now", () => {
  assert.equal(readFileSync(new URL("../mb/src/events/shapes.mbt", import.meta.url), "utf8"), shapesMbt(), "made again: node station/mb/src/events/gen-shapes.ts");
});

/// What runtime-compat.ts makes for a core that takes these runtimes, of shapes with runtimes in them.
const OLD = { "stillfail-runtimes": "claude,codex" };
const VALUES: [Json, Json][] = [
  ["Overview", { profiles: [{ id: "a", runtime: "claude", models: [] }, { id: "b", runtime: "pi" }], connects: [{ id: "c", bind: { runtime: "hermes", model: null } }], processes: [{ runtime: "agy", pid: 1 }], other: { runtime: "pi" } }],
  ["Session", { key: "k", runtime: "pi", title: "t" }],
  ["Session", { key: "k", runtime: "claude", agents: [{ runtime: "pi" }] }],
  [{ vec: "Session" }, [{ key: "a", runtime: "codex" }, { key: "b", runtime: "hermes" }, null]],
  ["SessionDetail", { session: { key: "a", runtime: "pi" }, messages: [{ authorRuntime: "pi", text: "x" }] }],
  ["ChatThread", { id: 1, entries: [{ authorRuntime: "hermes", text: "hi" }, { authorRuntime: "claude" }] }],
  [{ vec: "ChatItem" }, [{ id: "1", agents: [{ runtime: "pi" }, { runtime: "codex" }] }]],
  ["Message", { authorRuntime: "pi", text: "said" }],
  [{ opt: "RuntimeKind" }, "pi"],
  [{ map: "RuntimeKind" }, { a: "pi", b: "codex" }],
  [{ tuple: ["RuntimeKind", "string"] }, ["pi", "x", "extra"]],
  [{ tuple: ["RuntimeKind"] }, ["codex", "x"]],
  ["RuntimeKind", "devin"],
  ["Nothing", { runtime: "pi" }],
  ["Overview", null],
];

test("a core from before a runtime: what it is told and answered, shaped alike", { skip }, async () => {
  const headerSets: Record<string, string>[] = [OLD, { "Stillfail-Runtimes": "claude , pi,codex" }, {}, { "stillfail-runtimes": "" }];
  for (const headers of headerSets) {
    const supported = clientRuntimes(headers);
    for (const [type, value] of VALUES) {
      const view = runtimeView(type, value, supported);
      assert.deepEqual(await mb({ op: "view", headers: Object.entries(headers), type, value }), view === OMIT ? { omit: true } : view === undefined ? {} : { value: view }, `${JSON.stringify(type)} ${JSON.stringify(value)}`);
    }
  }
  const frames = [
    `id: a.1\nevent: session\ndata: ${JSON.stringify({ key: "k", runtime: "pi" })}`,
    `id: a.2\nevent: session\ndata: ${JSON.stringify({ key: "k", runtime: "codex", "2": 1 })}`,
    `event: overview\ndata: ${JSON.stringify(VALUES[0]![1])}`,
    `id: a.3\nevent: thread\ndata: ${JSON.stringify({ id: 1, entries: [{ authorRuntime: "pi" }, "x"] })}`,
    `event: live\ndata: {"runtime":"pi"}`,
    `retry: 3000`,
    `: ping`,
    `id: a.4`,
  ];
  for (const text of frames) {
    const ts = await (async () => {
      let out = "";
      const body = (async function* () { yield Buffer.from(`${text}\n\n`); })();
      const shown = runtimeCompatible({ method: "GET", path: "/events/", headers: OLD, body: Buffer.alloc(0) } as never, { status: 200, headers: {}, body } as never);
      for await (const piece of shown.body as AsyncIterable<Buffer>) out += piece.toString();
      return out;
    })();
    assert.equal((await mb({ op: "compat-frame", headers: Object.entries(OLD), text })) + "\n\n", ts, text);
  }
  const answers: [string, Json, string?][] = [
    ["/overview", VALUES[0]![1]],
    ["/sessions/", [{ key: "a", runtime: "pi" }, { key: "b", runtime: "claude" }]],
    ["/sessions/k", { session: { key: "a", runtime: "pi" } }],
    ["/sessions/k", { key: "a", runtime: "pi" }],
    ["/threads", [{ id: 1, entries: [{ authorRuntime: "pi" }] }]],
    ["/threads/4/entries", { entries: [{ authorRuntime: "pi", n: 1 }, { authorRuntime: "claude" }] }],
    ["/chats", [{ id: "x", agents: [{ runtime: "hermes" }] }]],
    ["/profiles/p1", { overview: VALUES[0]![1], id: "p1" }],
    ["/connects", VALUES[0]![1]],
    ["/me/slack", { overview: { profiles: [{ runtime: "pi" }] } }],
    ["/jobs", [{ runtime: "pi" }]],
    ["/batch", { answers: [{ status: 200, body: [{ key: "a", runtime: "pi" }] }, { status: 200, body: { key: "b", runtime: "pi" } }, { status: 404, body: { error: "x" } }, { status: 200, body: { x: 1 } }] }, JSON.stringify({ gets: ["/sessions?x=1", "/sessions/b", "/sessions/c", 5] })],
  ];
  for (const lang of ["zh", "en"] as const) {
    for (const [path, body, request] of answers) {
      const answer = { status: 200, headers: { "content-type": "application/json", "content-length": "9", "cache-control": "no-store" }, body: Buffer.from(JSON.stringify(body)) };
      const ts = runtimeCompatible({ method: "GET", path, headers: OLD, body: Buffer.from(request ?? ""), lang } as never, answer as never);
      const moon = await mb({ op: "compat-answer", path, headers: Object.entries(OLD), body: request ?? "", lang, answer: { status: 200, headers: Object.entries(answer.headers), body: JSON.stringify(body) } });
      assert.deepEqual(moon, { status: ts.status, headers: ts.headers, body: (ts.body as Buffer).toString() }, `${lang} ${path}`);
    }
  }
});

test("what GET /events asks for, of the viewer's workspace only; what seen.ts says of a path", { skip }, async () => {
  const world = { sessions: { s1: { ws: null }, s2: { ws: "w2" }, s4: { ws: "handed:w1" }, "a b": { ws: null }, "é+": { ws: "w2" } }, threads: { "1": ["s1"], "2": ["s2"], "3": [], "5": ["s4"] }, jobs: { j1: "s1", j2: "s2" }, handed: { s4: { station: "st", ws: null, thread: 5, there: 9 } } };
  const store = storeOf(world);
  const queries: [string, string][][] = [
    [["live", "s1"], ["from", "12.7"], ["last", "3"], ["live", "s2"], ["live", "nope"], ["live", "s1"], ["from", " "], ["last", "+0"], ["live", "s1"], ["from", "1e400"], ["live", "s1"], ["from", "-4"], ["last", "x"], ["live", "s1"], ["from", "0x1f"], ["live", "s1"], ["from", "abc"]],
    [["job", "j1"], ["lines", "5000"], ["job", "j2"], ["job", "j9"], ["lines", "0"], ["job", "j1"], ["lines", "+7"], ["job", "j1"]],
    [["login", "abc"], ["login", "ABC"], ["login", "x".repeat(41)], ["host", "1"], ["host", "0"], ["since", "a.1"], ["since", "b.2"], ["brief", "1"], ["running", "1"], ["shared", "true"]],
  ];
  for (const v of [A, B, C]) {
    for (const query of queries) {
      let asked: Json = null;
      const events = { open: async (...args: Json[]) => { asked = args; return { status: 200, headers: {}, body: Buffer.alloc(0) }; } };
      const [route] = eventRoutes({ events, sessionExists: (k: string) => k in world.sessions, store } as never);
      await route!.handle({ method: "GET", path: "/events", query, headers: {}, body: Buffer.alloc(0), viewer: v, lang: "zh" } as never, []);
      const [, , host, live, logs, since, brief, logins, running] = asked;
      assert.deepEqual(await mb({ op: "query", world, viewer: v, query }), { host, live, logs, since, brief, logins, running }, `${v.email} ${JSON.stringify(query)}`);
    }
    const paths = ["/sessions/s1", "//sessions//s2/x", "/sessions/a%20b", "/sessions/a+b", "/sessions/%C3%A9%2B", "/sessions/%C3", "/sessions/%E2%82", "/sessions/nope", "/threads/1", "/threads/+2", "/threads/-3", "/threads/2x", "/threads/5", "/threads/99999999999999999999", "/jobs/j1", "/jobs/j2", "/jobs/none", "/other/x", "/sessions/", "/sessions/s4", "sessions/s2"];
    assert.deepEqual(await mb({ op: "seen", world, viewer: v, paths }), { elsewhere: paths.map((p) => elsewhere(store, p, v)), went: paths.map((p) => went(store, p, v)) }, v.email);
  }
  const builds = ["0.1.7916", "0.1.7917", "7000", " 0.12.999 ", "0.1.1000", "0.1.0", "1.1.8000", "0.1.x", "", "0.1.", "00009000", "0.1.99999999999999999999"];
  assert.deepEqual(await mb({ op: "oldest", builds, oldest: OLDEST_CORE }), { buildOf: builds.map((b) => buildOf(b)), tooOld: builds.map((b) => coreTooOld({ "Stillfail-Build": b })) });
  const texts = ["", " 12 ", "+3", "-0", "1.", ".5", "1e3", "1E-2", "0x1F", "0b101", "0o17", "-0x1", "Infinity", "-Infinity", "+Infinity", "inf", "1e", "12abc", "007", "\t\n 4 ", "1_000", "9007199254740993"];
  assert.deepEqual(await mb({ op: "numbers", texts }), JSON.parse(JSON.stringify(texts.map((t) => Number(t)))));
});

test("another station's task is its workspace's, whichever is this station's home: seen.ts and the program alike", { skip }, async () => {
  const jobs = { jw1: "remote:w1:st:a", jw2: "remote:w2:st:b", jw3: "remote:w3:st:c", jcolon: "remote:w2:st:d:e", jshort: "remote:w2",
    jempty: "remote:w2:st:", jslash: "remote:w2/x:st:f", jnone: "remote::st:g", jline: "remote:w2:st:h\ni", jgone: "nobody", jhere: "s2" };
  const world = { sessions: { s2: { ws: "w2" } }, threads: {}, jobs, handed: {} };
  const store = storeOf(world);
  const paths = Object.keys(jobs).map((id) => `/jobs/${id}`);
  const homes = ["jw1", "jshort", "jempty", "jslash", "jnone", "jline", "jgone"];
  const seenOf: [Json, string[]][] = [[A, homes], [C, homes], [B, ["jw2", "jcolon", "jhere"]], [viewer("d@x", "w3", { home: false }), ["jw3"]]];
  for (const [v, seen] of seenOf) {
    const said = await mb({ op: "seen", world, viewer: v, paths });
    assert.deepEqual(said, { elsewhere: paths.map((p) => elsewhere(store, p, v)), went: paths.map((p) => went(store, p, v)) }, v.email);
    assert.deepEqual(Object.keys(jobs).filter((_, i) => said.elsewhere[i] === null), seen, v.email);
  }
});

// ── the overview, the local status, the machine ─────────────────────────────────────────────────────────────────

const require = createRequire(import.meta.url);
const osModule = require("node:os");
const fsPromises = require("node:fs/promises");

/// `patch`'s properties set on `target` for as long as `f` runs (builtin modules' named exports along with them).
async function patched<A>(target: Json, patch: Json, f: () => Promise<A>): Promise<A> {
  const before = Object.fromEntries(Object.keys(patch).map((k) => [k, Object.getOwnPropertyDescriptor(target, k)]));
  for (const [k, v] of Object.entries(patch)) Object.defineProperty(target, k, { value: v, configurable: true, writable: true });
  syncBuiltinESMExports();
  try {
    return await f();
  } finally {
    for (const [k, d] of Object.entries(before)) d === undefined ? delete target[k] : Object.defineProperty(target, k, d);
    syncBuiltinESMExports();
  }
}

/// GET /overview on a world, by the TypeScript station: what overview_harness gives.
async function overviewTs(world: Json, script: Json[]): Promise<Json> {
  const w: Json = structuredClone(world);
  const reads: Json[] = [];
  let readable: string[] = [...(w.readable ?? [])];
  const sessionWs = (key: string) => (key in (w.sessions ?? {}) ? (w.sessions[key].ws ?? null) : undefined);
  const store: Json = {
    overviewSessionCounts: (_viewer: Json, ids: Json[]) => {
      reads.push(["counts", ids.map((id) => id ?? null)]);
      const c = w.counts;
      return c !== null && typeof c === "object" ? { total: typeof c.total === "number" ? c.total : 0, byConnect: new Map(Object.entries(c.byConnect ?? {}).filter(([, v]) => typeof v === "number")) } : null;
    },
    sessionWs,
    listProcesses: () => w.processes ?? [],
    now: () => w.now ?? 0,
    binding: (id: string) => w.bindings?.[id] ?? null,
    slackIdentities: (email: string) => w.slack?.[email] ?? [],
    decisionsVersion: () => w.decisionsVersion ?? 0,
    prepareDecisionSessions: async () => {
      reads.push(["prepareDecisions"]);
      w.accounts.ready = true;
    },
    getSession: (s: string) => (w.sessions?.[s] ? { title: w.sessions[s].title ?? null, runtime: w.sessions[s].runtime } : null),
    sessionChat: () => null,
    archivePolicy: (ws: string | null) => w.policySaved?.[ws ?? ""] ?? null,
    latestDecisionsSince: () => [],
    db: {
      exec: () => {},
      prepare: (sql: string) => ({
        get: (arg?: string) => (sql.includes("session_chat_meta") && !sql.includes("thread_sessions") ? { version: SESSION_CHAT_VERSION } : sql === SESSION_CHAT_MANY ? (readable.includes(arg!) ? undefined : { 1: 1 }) : { complete: 0 }),
      }),
    },
  };
  const hub: Json = {
    processes: () => new Map(w.hubProcesses ?? []),
    get waitForSessionCounts() { return "countsAfterWait" in w ? async () => {
      reads.push(["waitCounts"]);
      const ready = Boolean(w.countsAfterWait);
      if (ready) w.counts = w.countsAfterWait;
      return ready;
    } : null; },
    config: () => ({ dataDir: w.dataDir ?? "/data" }),
    get policyChecks() { return "policyChecks" in w ? async (since: number) => {
      reads.push(["policyChecks", since]);
      return w.policyChecks;
    } : null; },
    get prepareSessionChatNames() { return w.chatNames === true ? async (missing: string[]) => {
      reads.push(["prepareNames", [...missing]]);
      readable.push(...missing);
    } : null; },
  };
  const accounts = () => w.accounts ? {
    ...(w.accounts.homes === true ? { homesReadSoon: async () => void reads.push(["homes"]) } : {}),
    profilesView: () => w.accounts.profiles ?? [],
    loginsView: () => w.accounts.logins ?? [],
    apiProviders: () => w.accounts.apiProviders ?? [],
    machineLogins: () => w.accounts.machineLogins ?? [],
    decisionModels: () => w.accounts.decisionModels ?? [],
    automaticDecisionsView: (viewer: Json, options: Json) => {
      reads.push(["decisions", viewer.email]);
      if (w.accounts.ready !== true) throw new DecisionSessionsUnavailable();
      return {
        canEdit: viewer.role === "owner" || viewer.role === "admin",
        rule: w.accounts.rule ?? null,
        recent: (w.accounts.checks ?? []).filter((c: Json) => options.visible(c.session)).map((c: Json) => ({ session: c.session, title: options.title(String(c.session ?? "")), option: c.option })),
      };
    },
  } : undefined;
  const deps = (): Json => ({
    store,
    hub,
    cloud: { get state() { return w.cloud ?? null; }, membership: (ws: string) => w.memberships?.[ws] ?? null, get reached() { return w.reached === true; } },
    config: () => w.config,
    accounts: accounts(),
    updates: w.updates ? { get: (lang: string) => w.updates[lang] ?? [] } : undefined,
    connectKinds: new Map(Object.entries(w.connectKinds ?? {}).map(([kind, own]: [string, Json]) => [kind, { shown: (c: Json) => ({ ...(own.shown ?? {}), name: `${kind}:${String(c.id ?? "")}` }), connection: () => own.connection ?? null }])),
    permissions: "permissions" in w ? () => w.permissions : undefined,
    rootView: async (p: string) => w.roots?.[p] ?? { path: p, name: p, state: "missing" },
  });
  const answers: Json[] = [];
  const env = process.env.STILLFAIL_TEST_HOST;
  if (w.testHost === true) process.env.STILLFAIL_TEST_HOST = "1";
  else delete process.env.STILLFAIL_TEST_HOST;
  try {
    await patched(platform, {
      groupMemory: async (pgids: number[]) => {
        reads.push(["memory", pgids]);
        return new Map(Object.entries(w.memory ?? {}).filter(([, v]) => typeof v === "number").map(([k, v]) => [Number(k), v]));
      },
    }, () => patched(fsPromises, {
      statfs: async () => {
        if (w.statfs === undefined || w.statfs === null) throw new Error("no statfs");
        return w.statfs;
      },
    }, async () => {
      for (const step of script) {
        if (step.do === "world") {
          Object.assign(w, step.set);
          if (step.set.readable !== undefined) readable = [...step.set.readable];
          if ("testHost" in step.set) {
            if (step.set.testHost === true) process.env.STILLFAIL_TEST_HOST = "1";
            else delete process.env.STILLFAIL_TEST_HOST;
          }
        } else if (step.do === "advance") w.now = (w.now ?? 0) + step.ms;
        else if (step.do === "overview") {
          try {
            answers.push({ value: JSON.parse(JSON.stringify(await overview(deps(), step.viewer, step.lang ?? "zh"))) });
          } catch (error) {
            answers.push({ error: (error as Error).message });
          }
        }
      }
    }));
  } finally {
    if (env === undefined) delete process.env.STILLFAIL_TEST_HOST;
    else process.env.STILLFAIL_TEST_HOST = env;
  }
  return { answers, reads };
}

test("the overview: each viewer's, field for field, the decisions kept and their chats' names read as they are ready", { skip }, async () => {
  learn({
    "claude-opus-5-5": { name: "Opus", maker: "anthropic", makerName: "Anthropic", family: "Claude", context: 1_000_000 },
    "gemini-4-carbon": { maker: "google", context: 2_000_000 },
    "4": { maker: "numbers", context: 7 },
    "plain": { name: "plain" },
  });
  const viewerOf = (email: string, workspace: string, more: Json = {}) => ({ sub: `s-${email}`, email, name: email, role: "member", workspace, device: "d", ...more });
  const owner = viewerOf("o@x", "w1", { role: "owner", home: true });
  const joined = viewerOf("j@x", "w2", { role: "admin", home: false, lockId: "L" });
  const reader = viewerOf("r@x", "w1", { role: "viewer" });
  const world = {
    homedir: homedir(),
    spotlight: platform.hasSpotlight,
    catalog: catalog().models,
    now: 1_000_000,
    dataDir: "/data",
    config: {
      connects: [
        { id: "c1", kind: "slack", bind: { runtime: "claude", model: "", profiles: [" p1 ", "p1", "", 3, "p2"] }, createdBy: { id: "u", name: "U" }, station: "st" },
        { id: "c2", workspace: "w2", mode: "single-session", requireMention: false, enabled: false, bind: { profile: "solo", effort: "high" }, kind: "feishu" },
        { id: "c3", workspace: "", mode: "multi-session", requireMention: false, bind: { profiles: ["only"] }, createdBy: { id: "" } },
        { id: "c4", workspace: "w9" },
        { kind: "group", mode: "single-session" },
      ],
      agentEnv: { HTTPS_PROXY: "http://user:pass@proxy:8080", API_KEY: "sk-0123456789abcdef", short: "1234", "1BAD": "x", B: 5, Z_LAST: "zz", a_lower: "secret-ish 🙂🙂🙂🙂🙂🙂🙂🙂" },
      afreshWhenCold: true,
      afreshAbove: -1,
      telemetry: { logs: false },
      network: { congestion: "bbr" },
      autoArchiveDays: -3,
      slackArchiveDays: 2.5,
      autoArchiveReviewed: true,
      drive: { roots: ["/a/../b/./c", "relative", 7, "/x"], workspaces: { w2: ["/w2root/"] } },
      search: { personal: true },
      automaticDecisions: { on: true },
    },
    counts: { total: 9, byConnect: { c1: 4, c2: 2 } },
    hubProcesses: [["s1", "running"], ["s2", "warm"], ["s3", "running"], ["gone", "running"]],
    sessions: { s1: { ws: null, title: "One", runtime: "claude" }, s2: { ws: "w2", title: null }, s3: { ws: null }, s4: { ws: "w2", title: "Four", runtime: "pi" } },
    processes: [{ pgid: 11, runtime: "claude", session: "s1" }, { pgid: 12, runtime: "job" }, { pgid: 13, runtime: "codex" }],
    memory: { "11": 2048, "13": 1535 },
    statfs: { bavail: 10, bsize: 4096, blocks: 100 },
    bindings: { c2: "s2" },
    connectKinds: { feishu: { shown: { team: "T", extra: 1 }, connection: { state: "connected" } }, group: { shown: {} } },
    slack: { "o@x": [{ team: "T", user: "U" }] },
    roots: { "/b/c": { path: "/b/c", name: "c", state: "ok" } },
    cloud: { origin: "https://app", station: "st1", workspace: "w1", workspace_name: "Home", name: "station" },
    memberships: { w2: { workspace: "w2", workspace_name: "Two", name: null } },
    reached: true,
    updates: { zh: [{ v: "1" }], en: [{ v: "one" }] },
    decisionsVersion: 3,
    policyChecks: { options: { complete: { count: 2, chats: [{ session: "s1", at: 5 }, { session: "s4", at: 6, title: "kept?" }] } }, checked: 4, failed: 1 },
    policyOf: { "": policyFrom(null), w2: policyFrom(null) },
    policySaved: { w2: { change: { at: 9, summary: "edited", by: { kind: "agent", session: "s4" } } } },
    chatNames: true,
    readable: ["s1"],
    accounts: {
      ready: false, homes: true,
      profiles: [{ id: "p1", models: ["anthropic/claude-opus-5-5[1m]", "gemini-4-carbon-high", "unknown", 5, "4", "toString", "plain"] }, { id: "p2" }],
      logins: [{ id: "l" }], apiProviders: [{ id: "api" }], machineLogins: [{ id: "m" }], decisionModels: ["m1"], rule: "r",
      checks: [{ session: "s1", option: "complete" }, { session: "s4", option: "x" }, { session: "s3" }, { session: 5 }],
    },
  };
  const script: Json[] = [
    { do: "overview", viewer: owner, lang: "zh" },
    { do: "overview", viewer: joined, lang: "en" },
    { do: "overview", viewer: reader },
    { do: "advance", ms: 3000 },
    { do: "world", set: { memory: { "11": 4096 } } },
    { do: "overview", viewer: owner },
    { do: "advance", ms: 3000 },
    { do: "overview", viewer: owner },
    { do: "world", set: { decisionsVersion: 4, readable: [] } },
    { do: "overview", viewer: owner },
    { do: "advance", ms: 61_000 },
    { do: "world", set: { counts: null, countsAfterWait: { total: 1, byConnect: {} } } },
    { do: "overview", viewer: joined },
    { do: "world", set: { counts: null, countsAfterWait: false, cloud: null } },
    { do: "overview", viewer: owner },
    { do: "world", set: { counts: { total: 2 }, cloud: { removed_at: 7, workspace: "w1" }, permissions: { screen: "granted" }, testHost: true, chatNames: false } },
    { do: "overview", viewer: owner },
    { do: "world", set: { accounts: null, updates: null, permissions: null, statfs: null, testHost: false, config: null } },
    { do: "overview", viewer: reader },
  ];
  const ts = await overviewTs(world, script);
  const moon = await mb({ op: "overview", world, script });
  assert.equal(moon.error, undefined, `the program failed: ${moon.error}`);
  for (const [i, a] of ts.answers.entries()) assert.deepEqual(moon.answers[i], a, `overview ${i}`);
  assert.deepEqual(moon.reads, ts.reads);
  assert.equal(JSON.stringify(moon.answers), JSON.stringify(ts.answers), "the same text");
});

test("the local status: what it says, how a request is routed, a watch told each change once", { skip }, async () => {
  const inputs: Json[] = [
    { version: "0.1.9", cloud: null, reached: false, running: [], processes: [], waiting: [] },
    {
      version: "0.1.10", cloud: { origin: "https://o", workspace: "w", workspace_name: "", station: "st" }, reached: true,
      running: [{ key: "a", title: "A", since: 5 }, { key: "b", title: null, since: null }, { key: "c", title: "C", since: 9 }, { key: "d", title: "D", since: 5 }],
      processes: [["a", "running"], ["e", "running"], ["f", "warm"], ["a", "warm"], ["g", "cold"], ["h", "warm"]],
      waiting: [{ key: "h", title: "H", need: "say", endedAt: 3 }, { key: "e", title: "E", need: null, endedAt: 4 }, { key: "i", title: null, need: "x", endedAt: 1 }],
      health: { front: "linked", presenceOnline: true },
    },
    { version: "v", cloud: { workspace: "w", removed_at: 1 }, reached: true, running: Array.from({ length: 60 }, (_, i) => ({ key: `k${i}`, title: null, since: i % 7 })), processes: [], waiting: [] },
  ];
  const statusInput = (i: Json) => ({ ...i, processes: new Map(i.processes) });
  const routes: [string | undefined, string | undefined][] = [
    ["GET", "/v1/status"], ["GET", "/v1/status?watch=1"], ["GET", "/v1/status?watch=0"], ["GET", "/v1/status?watch=false"], ["GET", "/v1/status?watch"],
    ["GET", "/v1/status?x=1&watch=%31"], ["GET", "/v1/status?watch=+"], ["GET", "/healthz"], ["GET", "/healthz?x"], ["POST", "/v1/status"], [undefined, "/healthz"],
    ["GET", undefined], ["GET", "/v1/../v1/status"], ["GET", "/v1/./status#x"], ["GET", "//host/v1/status"], ["GET", "/v1/status/"], ["GET", "\\v1\\status?watch=yes"], ["GET", "v1/status"],
  ];
  const script: Json[] = [
    { do: "ask", name: "early", method: "GET", url: "/v1/status" },
    { do: "set", input: inputs[1] },
    { do: "ask", name: "once", method: "GET", url: "/v1/status" },
    { do: "ask", name: "health", method: "GET", url: "/healthz" },
    { do: "ask", name: "none", method: "GET", url: "/nope" },
    { do: "ask", name: "w1", method: "GET", url: "/v1/status?watch=1" },
    { do: "changed" },
    { do: "advance", ms: 499 },
    { do: "set", input: inputs[0] },
    { do: "changed" },
    { do: "advance", ms: 1 },
    { do: "ask", name: "w2", method: "GET", url: "/v1/status?watch=true" },
    { do: "changed" },
    { do: "advance", ms: 500 },
    { do: "set", input: inputs[2] },
    { do: "changed" },
    { do: "leave", name: "w1" },
    { do: "advance", ms: 600 },
    { do: "leave", name: "w2" },
    { do: "changed" },
    { do: "set", input: inputs[1] },
    { do: "ask", name: "w3", method: "GET", url: "/v1/status?watch=1" },
    { do: "changed" },
    { do: "close" },
    { do: "advance", ms: 600 },
  ];
  const clock = testClock();
  const time = new Fibers("status", clock.clock);
  let current: Json = null;
  const listeners: (() => void)[] = [];
  const server = statusServer(() => {
    if (current === null) throw new Error("starting");
    return statusOf(statusInput(current));
  }, (f) => (listeners.push(f), () => {}), time);
  const heard: Record<string, string> = {};
  const answers: Json[] = [];
  const closes: Record<string, () => void> = {};
  for (const step of script) {
    switch (step.do) {
      case "set": current = step.input; break;
      case "changed": for (const f of listeners) f(); break;
      case "advance": await clock.adjust(step.ms); break;
      case "ask": {
        heard[step.name] = "";
        const answer: Json = { name: step.name };
        const res: Json = {
          writeHead: (status: number, headers: Json) => ((answer.status = status), (answer.type = headers["content-type"]), res),
          write: (text: string) => void (heard[step.name] += text),
          end: (text?: string) => void (heard[step.name] += text ?? ""),
          on: (event: string, f: () => void) => void (event === "close" && (closes[step.name] = f)),
        };
        server.server.emit("request", { method: step.method, url: step.url }, res);
        answers.push(answer);
        break;
      }
      case "leave": closes[step.name]?.(); break;
      case "close": server.close(); break;
    }
    await settle();
  }
  await time.close();
  const ts = { statuses: inputs.map((i) => statusOf(statusInput(i))), routes: routes.map(([m, u]) => String(routeOf(m, u))), answers, heard };
  assert.deepEqual(await mb({ op: "status", inputs, routes, script }), JSON.parse(JSON.stringify(ts)));
});

/// The wall's clock of a test: timers fired in the order they are due, each at its time, all it set going settled.
function wallClock() {
  let now = 0;
  let seq = 0;
  const timers: { due: number; seq: number; period: number | null; f: () => void; live: boolean }[] = [];
  const add = (ms: number, period: number | null, f: () => void) => {
    const t = { due: now + Math.max(0, ms), seq: ++seq, period, f, live: true };
    timers.push(t);
    return () => void (t.live = false);
  };
  return {
    patch: {
      now: () => now,
      after: (ms: number, f: () => void) => add(ms, null, f),
      every: (ms: number, f: () => void) => add(ms, ms, f),
      sleep: (ms: number) => new Promise<void>((resolve) => void add(ms, null, resolve)),
    },
    now: () => now,
    async advance(to: number) {
      for (;;) {
        const due = timers.filter((t) => t.live && t.due <= to).sort((a, b) => a.due - b.due || a.seq - b.seq)[0];
        if (due === undefined) break;
        now = due.due;
        if (due.period !== null) (due.due += due.period), (due.seq = ++seq);
        else due.live = false;
        due.f();
        await settle();
      }
      now = to;
    },
  };
}

test("the machine's sample: kept ten seconds, a slow look stood in for, the ticks looked at again, the CPUs' minute", { skip }, async () => {
  const world: Json = {
    dataDir: "/data", hostname: "mac.local", cpus: 8, loadavg: [2.345, 1.5, 0.004], arch: process.arch, os: "macos",
    sample: { osName: "macOS 27", cpuModel: "M9", uptimeSec: 100, memory: { totalBytes: 10, usedBytes: 5, swapUsedBytes: 0 }, ownRss: 77 },
    statfs: { bavail: 3, bsize: 512, blocks: 9 },
    ticks: [[100, 1000], [100, 1000], [100, 1000], [150, 1100], [300, 1500], [300, 1500], [900, 2500], [1000, 3000]],
    gpus: [{ name: "G", busy: 0.1 }], gpusCached: [{ name: "G", busy: 0 }],
  };
  const script: Json[] = [
    { do: "info", name: "direct", last: { at: -70_000, ticks: [1, 2] } },
    { do: "advance", ms: 1 },
    { do: "sample", name: "first" },
    { do: "sample", name: "joined" },
    { do: "advance", ms: 3000, step: 100 },
    { do: "sample", name: "kept" },
    { do: "advance", ms: 9000, step: 1000 },
    { do: "world", set: { sampleDelay: 1000, gpusDelay: 1000, gpus: null } },
    { do: "sample", name: "stale" },
    { do: "advance", ms: 2000, step: 100 },
    { do: "sample", name: "fresh" },
    { do: "world", set: { sampleDelay: 0, gpusDelay: 0 } },
    { do: "follow" },
    { do: "advance", ms: 31_000, step: 1000 },
    { do: "recent", name: "minute" },
    { do: "advance", ms: 60_000, step: 5000 },
    { do: "recent", name: "later" },
    { do: "unfollow" },
    { do: "world", set: { ticks: [[5, 10], [5, 10]], os: "windows" } },
    { do: "advance", ms: 61_000, step: 61_000 },
    { do: "sample", name: "unmoved" },
    { do: "advance", ms: 3000, step: 100 },
    { do: "world", set: { ticks: [], statfs: null, testHost: true } },
    { do: "advance", ms: 70_000, step: 70_000 },
    { do: "sample", name: "test host" },
    { do: "info", name: "test info" },
    { do: "advance", ms: 1000, step: 100 },
  ];
  const clock = wallClock();
  const w: Json = structuredClone(world);
  const reads: Json[] = [];
  let given = 0;
  const later = <A>(name: string, value: A): Promise<A> => (w[`${name}Delay`] > 0 ? new Promise((resolve) => void clock.patch.after(w[`${name}Delay`], () => resolve(value))) : Promise.resolve(value));
  const out: Json[] = [];
  const env = process.env.STILLFAIL_TEST_HOST;
  delete process.env.STILLFAIL_TEST_HOST;
  try {
    await patched(wall, clock.patch, () => patched(platform.host, {
      cpuTicks: () => {
        const all = w.ticks ?? [];
        const t = all.length === 0 ? null : all[Math.min(given, all.length - 1)];
        given++;
        reads.push(["ticks", clock.now()]);
        return later("ticks", t);
      },
      sample: () => {
        reads.push(["sample", clock.now()]);
        return later("sample", w.sample);
      },
    }, () => patched(platform, { os: w.os }, () => patched(osModule, {
      hostname: () => w.hostname, availableParallelism: () => w.cpus, loadavg: () => w.loadavg,
    }, () => patched(fsPromises, {
      statfs: async () => {
        if (w.statfs === null) throw new Error("no statfs");
        return w.statfs;
      },
    }, async () => {
      const host = new Host(w.dataDir, {
        read: () => {
          reads.push(["gpus", clock.now()]);
          return later("gpus", w.gpus);
        },
        cached: () => w.gpusCached ?? null,
      } as never);
      let stop: (() => void) | null = null;
      const said = (name: string) => (value: Json) => void out.push({ name, at: clock.now(), value: JSON.parse(JSON.stringify(value)) });
      for (const step of script) {
        switch (step.do) {
          case "world":
            Object.assign(w, step.set);
            if (step.set.os !== undefined) (platform as Json).os = step.set.os;
            if (step.set.testHost === true) process.env.STILLFAIL_TEST_HOST = "1";
            break;
          case "advance": {
            const chunk = step.step ?? step.ms;
            for (let left = step.ms; left > 0; left -= Math.min(chunk, left)) await clock.advance(clock.now() + Math.min(chunk, left));
            break;
          }
          case "sample": void host.sample().then(said(step.name)); break;
          case "recent": void host.recentBusy().then(said(step.name)); break;
          case "info": void hostInfo(w.dataDir, step.last ? { at: step.last.at, ticks: step.last.ticks } : null).then(said(step.name)); break;
          case "follow": stop = host.follow(); break;
          case "unfollow": stop?.(); break;
        }
        await settle();
      }
    })))));
  } finally {
    if (env === undefined) delete process.env.STILLFAIL_TEST_HOST;
    else process.env.STILLFAIL_TEST_HOST = env;
  }
  assert.deepEqual(await mb({ op: "host", world, script }), { answers: out, reads });
});
