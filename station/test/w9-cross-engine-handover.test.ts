// A station handing over to the next while a session's turn runs, the next running its sessions' program (`--sessions`)
// in the other engine: MoonBit `stillfail-reader` to Pion `stillfail-pion`, and back (the roll back). The next takes
// the turn up where it was: the same runtime session, the same turn, nothing prompted again, what is said after the
// handover reaching it once, and the turn ending once with its state.
//
// The engine of each station's program is the one its `readers.sessions` says (agents/mb-program.ts
// `registerSessionsReaderConfig`, what services.ts gives a station), checked by the spawn each station made of it.
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { delimiter, dirname, join } from "node:path";
import { after, before, test } from "node:test";
import { fileURLToPath } from "node:url";
import { CodexDriver } from "../src/agents/codex.ts";
import { GrokDriver } from "../src/agents/grok.ts";
import { outFile, runnerId } from "../src/agents/process.ts";
import type { AgentDriver } from "../src/agents/runtime.ts";
import {
  registerSessionsReaderConfig,
  setSessionsSpawnObserverForTest,
  type SessionsSpawnEvent,
} from "../src/agents/mb-program.ts";
import { mbReaderBinary, pionBinary, resetReaderSelectionStateForTest } from "../src/read/mb-reader.ts";
import { hubConfig } from "../src/sessions/config.ts";
import { Hub, handoverFile, sessionKey } from "../src/sessions/hub.ts";
import { InternalChat } from "../src/sessions/internal.ts";
import { newSession, say } from "../src/sessions/lifecycle.ts";
import { Store } from "../src/store/store.ts";
import { openAgentsDoor } from "../src/tools/http.ts";
import { chatTools } from "../src/tools/chat.ts";
import { McpEndpoint } from "../src/tools/mcp.ts";
import { FakeDriver, Rig, message, reply, settle } from "./hub-fakes.ts";
import { pinnedPion } from "./pion-pinned.ts";

type Engine = "mb" | "pion";

const missing =
  mbReaderBinary() === null
    ? "the MoonBit program is not built here (station/mb/build.sh)"
    : pionBinary() === null
      ? "no stillfail-pion was given (native.ts run pion-reader sets STILLFAIL_PION_READER)"
      : null;
// (a run given a Pion reader that is not there fails rather than skips: pion-pinned.ts)
if (missing !== null && pinnedPion() !== undefined) throw new Error(`STILLFAIL_PION_READER=${pinnedPion()} given but ${missing}`);
const skip = missing ?? false;

// Each station's engine from its `readers.sessions` alone: the variables above it are this run's, not the test's.
const saved = { sessions: process.env.STILLFAIL_READER_SESSIONS, require: process.env.STILLFAIL_REQUIRE_PION_SESSIONS };
const spawns: SessionsSpawnEvent[] = [];
before(() => {
  delete process.env.STILLFAIL_READER_SESSIONS;
  delete process.env.STILLFAIL_REQUIRE_PION_SESSIONS;
  resetReaderSelectionStateForTest();
  setSessionsSpawnObserverForTest((event) => {
    if (!event.ready) spawns.push(event);
  });
});
after(() => {
  setSessionsSpawnObserverForTest(null);
  for (const [key, value] of [["STILLFAIL_READER_SESSIONS", saved.sessions], ["STILLFAIL_REQUIRE_PION_SESSIONS", saved.require]] as const) {
    if (value === undefined) delete process.env[key];
    else process.env[key] = value;
  }
  resetReaderSelectionStateForTest();
});

/// A rig whose stations run their sessions' program in the engine `engine.now` names as each starts one.
function engineRig(first: Engine) {
  const engine = { now: first };
  const rig = new Rig();
  const unregister = registerSessionsReaderConfig(rig.dir, () => ({ readers: { sessions: engine.now } }));
  return { rig, engine, unregister };
}

/// The programs spawned since `from` (an index of `spawns`): their engines, each its own process, none a fallback.
function spawnedSince(from: number): SessionsSpawnEvent[] {
  const made = spawns.slice(from);
  for (const s of made) assert.equal(s.fallback, false, `a ${s.engine} program spawned as a fallback: ${s.binary}`);
  return made;
}

/// The station after `rig.hub`, its program in `to`: handed over to while its session's turn runs, it takes it up.
async function handOverTo(rig: Rig, engine: { now: Engine }, to: Engine) {
  const handed = await rig.hub.handOver();
  // (the one handed over lets go of what it ran, its program too, as its process ends)
  await rig.hub.shutdown();
  engine.now = to;
  const claude = new FakeDriver("claude");
  const hub = rig.newHub({ chats: (id) => (id === "cl" ? rig.chat : undefined), drivers: [claude, new FakeDriver("codex")] });
  rig.hub = hub;
  rig.claude = claude;
  const from = spawns.length;
  await hub.takeUp();
  await settle();
  return { handed, claude, made: () => spawnedSince(from) };
}

// (the same engine on both, as every handover was before: what the two across hold to)
const ENDS: [Engine, Engine][] = [
  ["mb", "pion"],
  ["pion", "mb"],
  ["mb", "mb"],
  ["pion", "pion"],
];

for (const [from, to] of ENDS) {
  test(`a turn running as the station hands over is taken up by the next in ${to} (from ${from}), nothing lost or said twice`, { skip }, async () => {
    const at = spawns.length;
    const { rig, engine, unregister } = engineRig(from);
    try {
      const m = message({ text: "<@UBOT> build it" });
      await rig.accept(m);
      await settle();
      const key = sessionKey("cl", "C1", m.threadTs);
      const old = rig.claude.last();
      assert.equal(old.prompts.length, 1, "its first prompt");
      assert.ok(old.prompts[0]!.includes("build it"), old.prompts[0]);
      assert.deepEqual(spawnedSince(at).map((s) => s.engine), [from], `the first station's program is ${from}'s`);
      const firstPid = spawnedSince(at)[0]!.pid;

      // Its turn under way on the first station: a step of it said, a post made, a message steered in.
      old.says("half of it built");
      await rig.call(key, "chat_post", { to: `C1/${m.threadTs}`, text: "built half, going on" });
      await rig.accept(reply(m, "9100.1", "also the tests please"));
      await settle();
      old.reads();
      await settle();
      assert.deepEqual(old.steers.length, 1, "the reply steered into its turn");
      assert.ok(old.steers[0]!.includes("also the tests please"), old.steers[0]);
      const turnsBefore = rig.store.listTurns(key);
      assert.equal(turnsBefore.length, 1);
      assert.equal(turnsBefore[0]!.summary.endedAt, null, "its turn runs");
      assert.equal(rig.store.getSession(key)!.running, true);

      const next = await handOverTo(rig, engine, to);
      assert.equal(next.handed.sessions.length, 1, "its session handed over");
      const made = next.made();
      assert.deepEqual(made.map((s) => s.engine), [to], `the next station's program is ${to}'s`);
      assert.notEqual(made[0]!.pid, firstPid, "a program of its own");

      // Taken up: the same runtime session, its turn running, nothing prompted or steered again.
      const taken = next.claude.last();
      assert.equal(next.claude.count(), 1, "one session taken up, none opened");
      assert.equal(taken.sessionId, old.sessionId);
      assert.equal(taken.busy(), true);
      assert.equal(taken.prompts.length, 0, "not prompted again");
      assert.equal(taken.steers.length, 0, "what was steered before is not steered again");
      assert.equal(rig.hub.processState(key), "running");
      assert.equal(rig.store.getSession(key)!.running, true);

      // Its turn goes on there: a step, a message steered in once, a post, its state; it ends once.
      taken.says("the rest built");
      await rig.accept(reply(m, "9100.2", "and the docs"));
      await settle();
      assert.equal(taken.steers.length, 1, "steered on the next station");
      assert.ok(taken.steers[0]!.includes("and the docs"), taken.steers[0]);
      assert.equal(old.steers.length, 1, "nothing reaches the session handed over");
      // (read by its model: what was steered in is what its post answers)
      taken.reads();
      await settle();
      await rig.call(key, "chat_post", { to: `C1/${m.threadTs}`, text: "all built", kind: "all_done", done: "built it with tests and docs" });
      taken.complete();
      await settle();

      assert.deepEqual(taken.prompts, [], "not nudged: its state was said");
      assert.equal(rig.hub.processState(key), "warm");
      assert.equal(rig.store.getSession(key)!.running, false);
      const turns = rig.store.listTurns(key);
      assert.equal(turns.length, 1, "one turn, from the first station to its end on the next");
      assert.equal(turns[0]!.id, turnsBefore[0]!.id);
      assert.notEqual(turns[0]!.summary.endedAt, null);
      assert.deepEqual([turns[0]!.summary.outcome, turns[0]!.summary.ending], ["completed", "all_done"]);
      assert.deepEqual(rig.store.pendingMessages(key), []);
      // (each post once, in order)
      assert.deepEqual(rig.chat.texts(), ["built half, going on", "all built"]);
    } finally {
      unregister();
      await rig.close();
    }
  });
}

test("handed over from mb to pion and back to mb within one turn: one turn, each message once, ended once", { skip }, async () => {
  const at = spawns.length;
  const { rig, engine, unregister } = engineRig("mb");
  try {
    const m = message({ text: "<@UBOT> migrate it" });
    await rig.accept(m);
    await settle();
    const key = sessionKey("cl", "C1", m.threadTs);
    const first = rig.claude.last();
    const turn = rig.store.listTurns(key)[0]!.id;

    const toPion = await handOverTo(rig, engine, "pion");
    const second = toPion.claude.last();
    assert.equal(second.sessionId, first.sessionId);
    await rig.accept(reply(m, "9200.1", "on pion now"));
    await settle();
    assert.equal(second.steers.length, 1);

    const back = await handOverTo(rig, engine, "mb");
    const third = back.claude.last();
    assert.equal(third.sessionId, first.sessionId);
    assert.equal(third.busy(), true);
    assert.deepEqual([third.prompts, third.steers], [[], []], "nothing given again after the roll back");
    await rig.accept(reply(m, "9200.2", "back on mb"));
    await settle();
    assert.equal(third.steers.length, 1);
    assert.ok(third.steers[0]!.includes("back on mb"), third.steers[0]);
    assert.equal(second.steers.length, 1, "nothing reaches the pion station handed over");

    await rig.call(key, "chat_state", { kind: "all_done", done: "migrated and rolled back" });
    third.complete();
    await settle();
    assert.equal(rig.hub.processState(key), "warm");
    const turns = rig.store.listTurns(key);
    assert.deepEqual(turns.map((t) => t.id), [turn], "the one turn");
    assert.deepEqual([turns[0]!.summary.outcome, turns[0]!.summary.ending], ["completed", "all_done"]);
    assert.deepEqual(spawnedSince(at).map((s) => s.engine), ["mb", "pion", "mb"], "one program a station, in its engine");
  } finally {
    unregister();
    await rig.close();
  }
});

// With the real drivers under the real runner and the fake runtimes (test/fake), as hub-e2e.test.ts: the runtime's
// output is read by the sessions' program (mb-agents.ts `AgentsHost`), so the next station's, of the other engine,
// reads on where the first one's stopped (Codex: `replay` from the offsets `codex.ts` keeps; an ACP runtime taken up
// after a crash: `replayOwn` of its output).

const fake = join(dirname(fileURLToPath(import.meta.url)), "fake");
process.env.PATH = `${fake}${delimiter}${process.env.PATH}`;
const fifos = process.platform === "win32" ? "fifos" : false;

/// A station over `data` with one profile and its driver, its sessions' program in `engine.now`: its hub, its store,
/// its MCP door.
async function station(data: string, engine: { now: Engine }, profile: Record<string, unknown>, driver: AgentDriver) {
  const unregister = registerSessionsReaderConfig(data, () => ({ readers: { sessions: engine.now } }));
  const config = hubConfig({ profiles: [profile], maxNudges: 1 }, data);
  const store = Store.open(join(data, "stillfail.db"));
  let url = "";
  const hub = new Hub({ config: () => config, store, chats: () => undefined, drivers: [driver], mcpUrl: () => url, internal: new InternalChat() });
  const mcp = new McpEndpoint((token) => store.sessionByToken(token)?.key, chatTools(hub));
  const served = await openAgentsDoor({ port: 0 }, mcp, () => ({ status: 400, body: { error: "no jobs" } }));
  url = served.url;
  let closed = false;
  const close = async () => {
    if (closed) return;
    closed = true;
    await hub.shutdown();
    await served.close(1000);
    store.close();
    unregister();
  };
  return { hub, store, close };
}

function codexStation(data: string, engine: { now: Engine }, dump: string) {
  const skills = join(data, "skills");
  mkdirSync(skills, { recursive: true });
  const bundle = join(data, "cert.pem");
  writeFileSync(bundle, "");
  const profile = { id: "cx", runtime: "codex", home: "homes/cx", access: { kind: "opencode-go", key: "k" }, env: { FAKE_DUMP: dump } };
  return station(data, engine, profile, new CodexDriver({ data, hostSkills: skills, caBundle: bundle }));
}

function grokStation(data: string, engine: { now: Engine }) {
  return station(data, engine, { id: "p", runtime: "grok", home: "homes/grok", access: { kind: "subscription" } }, new GrokDriver({ data }));
}

/// Real processes: looked at every 25 ms, failing past `limitMs` saying what never came (what was lost would hang the
/// test file otherwise), as hub-e2e.test.ts.
async function until(done: () => boolean, what: string, limitMs = 30_000) {
  const start = performance.now();
  while (!done()) {
    if (performance.now() - start > limitMs) assert.fail(`not within ${limitMs} ms: ${what}`);
    await new Promise((r) => setTimeout(r, 25));
  }
}

for (const [from, to] of ENDS.slice(0, 2)) {
  test(`a Codex turn handed over while it writes is replayed by the next station's ${to} program (from ${from}) and ends there once`, { skip: skip || fifos }, async () => {
    const data = mkdtempSync("/tmp/w9x-");
    const dump = join(data, "dump");
    const engine = { now: from };
    const at = spawns.length;
    const first = await codexStation(data, engine, dump);
    let next: Awaited<ReturnType<typeof codexStation>> | null = null;
    try {
      const gate = `${dump}.held`;
      for (const part of ["a", "b"]) execFileSync("/usr/bin/mkfifo", [`${gate}.${part}`]);
      const [key, thread] = await newSession(first.hub, { runtime: "codex", createdBy: "ada@x.com" });
      say(first.hub, thread.id, "ada@x.com", "gate:6:3:held");
      await until(() => first.store.getSession(key)?.running === true && first.store.lastTurn(key) !== undefined, "its turn begun");
      // (three of its deltas written, the turn waiting for the rest)
      const out = outFile(data, runnerId("codex", "cx"));
      await until(() => existsSync(out) && readFileSync(out, "utf8").includes('"delta":"d2 "'), "three of its deltas written");
      const begun = first.store.listTurns(key);
      assert.equal(begun.length, 1, "its one turn");
      const turn = begun[0]!.id;
      await first.hub.handOver();
      assert.equal(first.hub.program()?.posted.get("event") ?? 0, 0);
      await first.close();
      const before = spawnedSince(at);
      assert.ok(before.length > 0 && before.every((s) => s.engine === from), `the first station's programs: ${before.map((s) => s.engine)}`);

      engine.now = to;
      const mark = spawns.length;
      next = await codexStation(data, engine, dump);
      await next.hub.takeUp();
      await writeFile(`${gate}.a`, "go");
      await until(() => existsSync(`${gate}.said`), "the rest of its deltas written");
      await writeFile(`${gate}.b`, "go");
      const store = next.store;
      // (its turn and the one that nudges it, no state said)
      await until(() => store.listTurns(key).length >= 2 && store.lastTurn(key)?.endedAt != null && !store.getSession(key)!.running, "its turns ended on the next station");
      const turns = store.listTurns(key);
      assert.deepEqual(turns.map((t) => t.summary.outcome), ["completed", "completed"], "its turn, ended on the next station once, and the nudge's");
      assert.equal(turns[0]!.id, turn, "the turn handed over is the one that ended");
      const posted = next.hub.program()!.posted;
      assert.equal(posted.get("event") ?? 0, 0, `events said through Node: ${JSON.stringify([...posted])}`);
      assert.ok((posted.get("routed") ?? 0) > 0, JSON.stringify([...posted]));
      const after = spawnedSince(mark);
      assert.ok(after.length > 0 && after.every((s) => s.engine === to), `the next station's programs: ${after.map((s) => s.engine)}`);
    } finally {
      await first.close();
      await next?.close();
      rmSync(data, { recursive: true, force: true });
    }
  });

  test(`an ACP (Grok Build) turn running as the station crashes is replayed by the next station's ${to} program (from ${from}) and ends there once`, { skip }, async () => {
    const data = mkdtempSync(process.platform === "win32" ? join(tmpdir(), "w9g-") : "/tmp/w9g-");
    const engine = { now: from };
    const at = spawns.length;
    const first = await grokStation(data, engine);
    let next: Awaited<ReturnType<typeof grokStation>> | null = null;
    try {
      const [key, thread] = await newSession(first.hub, { runtime: "grok", createdBy: "ada@x.com" });
      // Its reply read by the first station's program and taken by Node (hub-e2e.test.ts says why that and not only
      // its runner having written it).
      let told = false;
      const watch = first.hub.live.subscribe(key, 0, 0, (m) => {
        if (m.type === "step" && m.event.kind === "start" && m.event.step === "text") told = true;
      });
      say(first.hub, thread.id, "ada@x.com", "test-hold");
      await until(() => first.store.getSession(key)?.running === true && first.store.lastTurn(key) !== undefined, "its turn begun");
      const out = outFile(data, runnerId("grok", key));
      await until(() => existsSync(out) && readFileSync(out, "utf8").includes('"text":"hold'), "its reply written");
      await until(() => told, "its reply read by the first station");
      first.hub.live.unsubscribe(key, watch);
      const begun = first.store.listTurns(key);
      assert.equal(begun.length, 1, "its one turn");
      const turn = begun[0]!.id;
      await first.hub.handOver();
      await first.close();
      const before = spawnedSince(at);
      assert.ok(before.length > 0 && before.every((s) => s.engine === from), `the first station's programs: ${before.map((s) => s.engine)}`);
      // (a crash leaves no snapshot: the runners alone, what its output says read again)
      rmSync(handoverFile(data), { force: true });

      engine.now = to;
      const mark = spawns.length;
      next = await grokStation(data, engine);
      await next.hub.takeUp();
      assert.equal(next.store.getSession(key)?.running, true, "its turn still running");
      say(next.hub, thread.id, "ada@x.com", "go on");
      const store = next.store;
      await until(() => store.listTurns(key).length >= 2 && store.lastTurn(key)?.endedAt != null && !store.getSession(key)!.running, "its turns ended on the next station");
      const turns = store.listTurns(key);
      assert.deepEqual(turns.map((t) => t.summary.outcome), ["completed", "completed"], "its turn, ended on the next station once, and the nudge's");
      assert.equal(turns[0]!.id, turn, "the turn of the station that crashed is the one that ended");
      // (the turn taken up after a crash is said started by its driver: own-process.ts `adoptOn`; the rest in the program)
      const posted = next.hub.program()!.posted;
      assert.equal(posted.get("event") ?? 0, 1, `events said through Node: ${JSON.stringify([...posted])}`);
      assert.ok((posted.get("routed") ?? 0) > 0, JSON.stringify([...posted]));
      const after = spawnedSince(mark);
      assert.ok(after.length > 0 && after.every((s) => s.engine === to), `the next station's programs: ${after.map((s) => s.engine)}`);
    } finally {
      await first.close();
      await next?.close();
      rmSync(data, { recursive: true, force: true });
    }
  });
}
