// A station handing over to the next while a session's turn runs, the next running its sessions' program (`--sessions`)
// in the other engine: MoonBit `stillfail-reader` to Pion `stillfail-pion`, and back (the roll back). The next takes
// the turn up where it was: the same runtime session, the same turn, nothing prompted again, what is said after the
// handover reaching it once, and the turn ending once with its state.
//
// The engine of each station's program is the one its `readers.sessions` says (agents/mb-program.ts
// `registerSessionsReaderConfig`, what services.ts gives a station), checked by the spawn each station made of it.
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { constants, existsSync, mkdirSync, mkdtempSync, readFileSync, realpathSync, rmSync, writeFileSync } from "node:fs";
import { open, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { delimiter, dirname, join } from "node:path";
import { after, before, test } from "node:test";
import { fileURLToPath } from "node:url";
import { CodexDriver } from "../src/agents/codex.ts";
import { GrokDriver } from "../src/agents/grok.ts";
import { endRunner, outFile, runnerId } from "../src/agents/process.ts";
import { liveRunners } from "../src/agents/runner.ts";
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
import type { LiveMessage } from "../src/sessions/live.ts";
import { newSession, say } from "../src/sessions/lifecycle.ts";
import { Store } from "../src/store/store.ts";
import { openAgentsDoor } from "../src/tools/http.ts";
import { chatTools } from "../src/tools/chat.ts";
import { McpEndpoint } from "../src/tools/mcp.ts";
import { FakeDriver, Rig, message, reply, settle } from "./hub-fakes.ts";
import { pinnedPion } from "./pion-pinned.ts";

type Engine = "mb" | "pion";

const MB = mbReaderBinary();
const PION = pionBinary();
const requireDual = process.env.STILLFAIL_REQUIRE_DUAL_READER === "1";
// (a run given a Pion reader that is not there, or asked for both, fails rather than skips: pion-pinned.ts)
if (PION === null && (pinnedPion() !== undefined || requireDual)) throw new Error(`STILLFAIL_PION_READER=${pinnedPion() ?? "unset"} given, but no stillfail-pion is there`);
if (MB === null && requireDual) throw new Error("STILLFAIL_REQUIRE_DUAL_READER=1, but the MoonBit program is not built here");
const skip =
  MB === null
    ? "the MoonBit program is not built here (station/mb/build.sh)"
    : PION === null
      ? "no stillfail-pion was given (native.ts run pion-reader sets STILLFAIL_PION_READER)"
      : false;
const BINARY: Record<Engine, string | null> = { mb: MB === null ? null : realpathSync(MB), pion: PION === null ? null : realpathSync(PION) };
if (skip === false) assert.notEqual(BINARY.mb, BINARY.pion, "the two engines are two programs");

// Each station's engine from its `readers.sessions` alone: the variables above it are this run's, not the test's.
// The fake runtimes (test/fake) are found on PATH by the real drivers, for this file's tests alone.
const fake = join(dirname(fileURLToPath(import.meta.url)), "fake");
const saved = { sessions: process.env.STILLFAIL_READER_SESSIONS, require: process.env.STILLFAIL_REQUIRE_PION_SESSIONS, path: process.env.PATH };
const spawns: SessionsSpawnEvent[] = [];
/// The pids of the programs that said they were ready.
const ready = new Set<number>();
before(() => {
  delete process.env.STILLFAIL_READER_SESSIONS;
  delete process.env.STILLFAIL_REQUIRE_PION_SESSIONS;
  process.env.PATH = `${fake}${delimiter}${saved.path ?? ""}`;
  resetReaderSelectionStateForTest();
  setSessionsSpawnObserverForTest((event) => {
    if (!event.ready) spawns.push(event);
    else if (event.pid !== null) ready.add(event.pid);
  });
});
after(() => {
  setSessionsSpawnObserverForTest(null);
  for (const [key, value] of [["STILLFAIL_READER_SESSIONS", saved.sessions], ["STILLFAIL_REQUIRE_PION_SESSIONS", saved.require], ["PATH", saved.path]] as const) {
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

/// The programs spawned since `from` (an index of `spawns`): each of its engine's binary, none a fallback, each its
/// own process.
function spawnedSince(from: number): SessionsSpawnEvent[] {
  const made = spawns.slice(from);
  for (const s of made) {
    assert.equal(s.fallback, false, `a ${s.engine} program spawned as a fallback: ${s.binary}`);
    assert.equal(realpathSync(s.binary), BINARY[s.engine as Engine], `a ${s.engine} program spawned from ${s.binary}`);
    assert.ok(s.pid !== null && s.pid > 0, `a ${s.engine} program with no pid`);
  }
  assert.equal(new Set(made.map((s) => s.pid)).size, made.length, `each program its own process: ${made.map((s) => s.pid)}`);
  return made;
}

/// Every program spawned since `from` said it was ready, and they are of `engines` in turn (one each, a station's).
function programsWere(from: number, engines: Engine[]): SessionsSpawnEvent[] {
  const made = spawnedSince(from);
  assert.deepEqual(made.map((s) => s.engine), engines, "one program a station, in its engine");
  for (const s of made) assert.ok(ready.has(s.pid!), `the ${s.engine} program ${s.pid} said it was ready`);
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
      const firstPid = programsWere(at, [from])[0]!.pid;

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
      assert.ok(ready.has(made[0]!.pid!), "the next station's program said it was ready");

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
      programsWere(at, [from, to]);
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
    assert.equal(toPion.claude.count(), 1, "one session taken up, none opened");
    assert.equal(second.busy(), true);
    assert.deepEqual([second.prompts.length, second.steers.length], [0, 0], "nothing given again on pion");
    await rig.accept(reply(m, "9200.1", "on pion now"));
    await settle();
    assert.equal(second.steers.length, 1);

    const back = await handOverTo(rig, engine, "mb");
    const third = back.claude.last();
    assert.equal(third.sessionId, first.sessionId);
    assert.equal(back.claude.count(), 1, "one session taken up, none opened");
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
    programsWere(at, ["mb", "pion", "mb"]);
    assert.equal(first.prompts.length, 1, "prompted once, on the first station");
  } finally {
    unregister();
    await rig.close();
  }
});

// With the real drivers under the real runner and the fake runtimes (test/fake), as hub-e2e.test.ts: the runtime's
// output is read by the sessions' program (mb-agents.ts `AgentsHost`), so the next station's, of the other engine,
// reads on where the first one's stopped. Codex: handed over, the snapshot's place (`Host.adopt`), or with no snapshot
// left, what the program reads again from the offsets the store keeps (`AgentsHost.replay`); an ACP runtime taken up
// after a crash: `replayOwn` of its output. What each station showed live of the turn, and what the runtime was
// written (FAKE_DUMP.stdin), say nothing was lost or given twice.

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
type Station = Awaited<ReturnType<typeof station>>;

function codexStation(data: string, engine: { now: Engine }, dump: string) {
  const skills = join(data, "skills");
  mkdirSync(skills, { recursive: true });
  const bundle = join(data, "cert.pem");
  writeFileSync(bundle, "");
  const profile = { id: "cx", runtime: "codex", home: "homes/cx", access: { kind: "opencode-go", key: "k" }, env: { FAKE_DUMP: dump } };
  return station(data, engine, profile, new CodexDriver({ data, hostSkills: skills, caBundle: bundle }));
}

function grokStation(data: string, engine: { now: Engine }, dump: string) {
  const profile = { id: "p", runtime: "grok", home: "homes/grok", access: { kind: "subscription" }, env: { FAKE_DUMP: dump } };
  return station(data, engine, profile, new GrokDriver({ data }));
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

/// Lets a fake runtime's gate go (its fifo written), failing past `limitMs` where nothing opens the fifo to read it (the
/// runtime gone): opened to read here then, so that the write ends and nothing is left waiting on it.
async function letGo(fifo: string, limitMs = 30_000) {
  let timer: ReturnType<typeof setTimeout> | undefined;
  const written = writeFile(fifo, "go");
  const late = new Promise<never>((_, reject) => {
    timer = setTimeout(() => {
      void (async () => {
        const reader = await open(fifo, constants.O_RDONLY | constants.O_NONBLOCK).catch(() => null);
        await written.catch(() => {});
        await reader?.close();
        reject(new Error(`not within ${limitMs} ms: ${fifo} read by the runtime`));
      })();
    }, limitMs);
  });
  try {
    await Promise.race([written, late]);
  } finally {
    clearTimeout(timer);
  }
}

/// What a station shows live of `key` from now on (sessions/live.ts `subscribe`): the steps in flight as it begins
/// (`steps`), then each step started, in order. (A text's deltas are counted for the rate, not told: live.mbt.)
function shown(hub: Hub, key: string) {
  const got: LiveMessage[] = [];
  const id = hub.live.subscribe(key, 0, 0, (m) => void got.push(m));
  return {
    got,
    /// The steps started since, as `<step>:<id>`.
    started: () => got.flatMap((m) => (m.type === "step" && m.event.kind === "start" ? [`${m.event.step}:${m.event.id}`] : [])),
    stop: () => hub.live.unsubscribe(key, id),
  };
}

/// The JSON lines the fake runtimes of `dump` were written, in order.
function written(dump: string): Json[] {
  const at = `${dump}.stdin`;
  return existsSync(at) ? readFileSync(at, "utf8").split("\n").filter(Boolean).map((l) => JSON.parse(l)) : [];
}
type Json = any;

/// What the stations of a test left running (one failing between the handover and the next taking it up): ended.
async function endLeft(data: string) {
  for (const info of await liveRunners(data).catch(() => [])) await endRunner(data, info.id, "left by a test", info).catch(() => false);
}

/// The programs spawned since `from`: some, each of `engine`, each ready.
function allOf(from: number, engine: Engine, who: string): SessionsSpawnEvent[] {
  const made = spawnedSince(from);
  assert.ok(made.length > 0, `${who} spawned a program`);
  assert.deepEqual([...new Set(made.map((s) => s.engine))], [engine], `${who}'s programs: ${made.map((s) => s.engine)}`);
  for (const s of made) assert.ok(ready.has(s.pid!), `${who}'s ${s.engine} program ${s.pid} said it was ready`);
  return made;
}

/// Each of the deltas `d<i> ` the fake Codex wrote, as many times as it wrote it to its output.
function deltasWritten(out: string, n: number): number[] {
  const text = readFileSync(out, "utf8");
  return Array.from({ length: n }, (_, i) => text.split(`"delta":"d${i} "`).length - 1);
}

// (a station that crashed leaves a Codex turn running whose session the next station cannot take up yet: hub.ts
// `adoptOne` gives the driver no `resume` where there is no snapshot, which codex.ts `adoptOn` needs, so the session
// is left cold with its turn running for good; these run, and are counted as todo, until that is fixed)
const NO_SNAPSHOT_CODEX = "hub.ts adoptOne: a Codex session with no snapshot is taken up without `resume` (codex.ts adoptOn throws)";

for (const [from, to] of ENDS.slice(0, 2)) {
  for (const snapshot of [true, false]) {
    const how = snapshot ? "handed over" : "left with no snapshot";
    test(`a Codex turn ${how} while it writes is read on by the next station's ${to} program (from ${from}) and ends there once`, { skip: skip || fifos, todo: snapshot ? false : NO_SNAPSHOT_CODEX }, async () => {
      const data = mkdtempSync("/tmp/w9x-");
      const dump = join(data, "dump");
      const engine = { now: from };
      const at = spawns.length;
      let first: Station | null = null;
      let next: Station | null = null;
      try {
        first = await codexStation(data, engine, dump);
        const gate = `${dump}.held`;
        for (const part of ["a", "b"]) execFileSync("/usr/bin/mkfifo", [`${gate}.${part}`]);
        const [key, thread] = await newSession(first.hub, { runtime: "codex", createdBy: "ada@x.com" });
        const before = shown(first.hub, key);
        say(first.hub, thread.id, "ada@x.com", "gate:6:3:held");
        await until(() => first!.store.getSession(key)?.running === true && first!.store.lastTurn(key) !== undefined, "its turn begun");
        // (three of its deltas written, the turn waiting for the rest; read by the first station's program and shown)
        const out = outFile(data, runnerId("codex", "cx"));
        await until(() => existsSync(out) && readFileSync(out, "utf8").includes('"delta":"d2 "'), "three of its deltas written");
        await until(() => before.started().length > 0, "its reply's step shown by the first station");
        const step = before.started();
        assert.equal(step.length, 1, `one step shown by the first station: ${step}`);
        before.stop();
        const begun = first.store.listTurns(key);
        assert.equal(begun.length, 1, "its one turn");
        await first.hub.handOver();
        assert.equal(first.hub.program()?.posted.get("event") ?? 0, 0);
        await first.close();
        const old = allOf(at, from, "the first station");
        // (a station that ended with no handover: what it read is where the store says, the rest read again)
        if (!snapshot) rmSync(handoverFile(data), { force: true });

        engine.now = to;
        const mark = spawns.length;
        next = await codexStation(data, engine, dump);
        await next.hub.takeUp();
        const after = shown(next.hub, key);
        await letGo(`${gate}.a`);
        await until(() => existsSync(`${gate}.said`), "the rest of its deltas written");
        await letGo(`${gate}.b`);
        const store = next.store;
        // (its turn and the one that nudges it, no state said)
        await until(() => store.listTurns(key).length >= 2 && store.lastTurn(key)?.endedAt != null && !store.getSession(key)!.running, "its turns ended on the next station");
        after.stop();
        const turns = store.listTurns(key);
        assert.deepEqual(turns.map((t) => t.summary.outcome), ["completed", "completed"], "its turn, ended on the next station once, and the nudge's");
        assert.equal(turns[0]!.id, begun[0]!.id, "the turn handed over is the one that ended");
        // Its reply's step shown once, by the first station; the next station shows only the nudge's step after it.
        assert.deepEqual(before.started(), step, "shown by the first station");
        const later = after.started();
        assert.equal(later.length, 1, `the nudge's step alone shown by the next station: ${later}`);
        assert.ok(!later.includes(step[0]!), `its reply's step shown again: ${later}`);
        // Each of its deltas written once (its turn was not given again), all six of them.
        assert.deepEqual(deltasWritten(out, 6), [1, 1, 1, 1, 1, 1], "each delta written once");
        // Its runtime was given the prompt once and the nudge once, nothing steered.
        const said = written(dump);
        const starts = said.filter((l) => l.method === "turn/start").map((l) => JSON.stringify(l.params.input));
        assert.equal(starts.length, 2, `turn/start: ${starts.length}`);
        assert.equal(starts.filter((s) => s.includes("gate:6:3:held")).length, 1, "the prompt given once");
        assert.equal(said.filter((l) => l.method === "turn/steer").length, 0, "nothing steered");
        // (taken up with no snapshot, the turn the next station did not start is said started by its driver: codex.ts
        // `adoptOn`; every other event of the output's goes to its actor in the program)
        const posted = next.hub.program()!.posted;
        assert.equal(posted.get("event") ?? 0, snapshot ? 0 : 1, `events said through Node: ${JSON.stringify([...posted])}`);
        assert.ok((posted.get("routed") ?? 0) > 0, JSON.stringify([...posted]));
        const made = allOf(mark, to, "the next station");
        for (const s of made) assert.ok(!old.some((o) => o.pid === s.pid), "the next station's programs are its own");
      } finally {
        await first?.close();
        await next?.close();
        await endLeft(data);
        rmSync(data, { recursive: true, force: true });
      }
    });
  }

  test(`an ACP (Grok Build) turn running as the station crashes is read on by the next station's ${to} program (from ${from}) and ends there once`, { skip }, async () => {
    const data = mkdtempSync(process.platform === "win32" ? join(tmpdir(), "w9g-") : "/tmp/w9g-");
    const dump = join(data, "dump");
    const engine = { now: from };
    const at = spawns.length;
    let first: Station | null = null;
    let next: Station | null = null;
    try {
      first = await grokStation(data, engine, dump);
      const [key, thread] = await newSession(first.hub, { runtime: "grok", createdBy: "ada@x.com" });
      // Its reply read by the first station's program and taken by Node (hub-e2e.test.ts says why that and not only
      // its runner having written it).
      const before = shown(first.hub, key);
      say(first.hub, thread.id, "ada@x.com", "test-hold");
      await until(() => first!.store.getSession(key)?.running === true && first!.store.lastTurn(key) !== undefined, "its turn begun");
      const out = outFile(data, runnerId("grok", key));
      await until(() => existsSync(out) && readFileSync(out, "utf8").includes('"text":"hold'), "its reply written");
      await until(() => before.started().length > 0, "its reply read by the first station");
      const step = before.started();
      assert.equal(step.length, 1, `one step shown by the first station: ${step}`);
      before.stop();
      const begun = first.store.listTurns(key);
      assert.equal(begun.length, 1, "its one turn");
      await first.hub.handOver();
      await first.close();
      const old = allOf(at, from, "the first station");
      // (a crash leaves no snapshot: the runners alone, what its output says read again)
      rmSync(handoverFile(data), { force: true });

      engine.now = to;
      const mark = spawns.length;
      next = await grokStation(data, engine, dump);
      await next.hub.takeUp();
      assert.equal(next.store.getSession(key)?.running, true, "its turn still running");
      const after = shown(next.hub, key);
      say(next.hub, thread.id, "ada@x.com", "go on");
      const store = next.store;
      await until(() => store.listTurns(key).length >= 2 && store.lastTurn(key)?.endedAt != null && !store.getSession(key)!.running, "its turns ended on the next station");
      after.stop();
      const turns = store.listTurns(key);
      assert.deepEqual(turns.map((t) => t.summary.outcome), ["completed", "completed"], "its turn, ended on the next station once, and the nudge's");
      assert.equal(turns[0]!.id, begun[0]!.id, "the turn of the station that crashed is the one that ended");
      // Its reply's step shown once, by the first station (what it heard goes on in it); the next station shows only
      // the nudge's steps (its thought and its reply), not that one again.
      assert.deepEqual(before.started(), step, "shown by the first station");
      const later = after.started();
      assert.deepEqual(later.map((s) => s.split(":")[0]), ["thinking", "text"], `the nudge's steps alone shown by the next station: ${later}`);
      assert.ok(!later.includes(step[0]!), `its reply's step shown again: ${later}`);
      assert.equal(readFileSync(out, "utf8").split('"text":"hold').length - 1, 1, "its reply written once");
      // Its runtime was given the prompt once, the message once (interjected), and the nudge once.
      const said = written(dump);
      const prompts = said.filter((l) => l.method === "session/prompt").map((l) => JSON.stringify(l.params.prompt));
      assert.equal(prompts.length, 2, `session/prompt: ${prompts.length}`);
      assert.equal(prompts.filter((p) => p.includes("test-hold")).length, 1, "the prompt given once");
      const told = said.filter((l) => l.method === "_x.ai/interject");
      assert.equal(told.length, 1, `interjected: ${told.length}`);
      assert.ok(JSON.stringify(told[0].params).includes("go on"));
      // (the turn taken up after a crash is said started by its driver: own-process.ts `adoptOn`; the rest in the program)
      const posted = next.hub.program()!.posted;
      assert.equal(posted.get("event") ?? 0, 1, `events said through Node: ${JSON.stringify([...posted])}`);
      assert.ok((posted.get("routed") ?? 0) > 0, JSON.stringify([...posted]));
      const made = allOf(mark, to, "the next station");
      for (const s of made) assert.ok(!old.some((o) => o.pid === s.pid), "the next station's programs are its own");
    } finally {
      await first?.close();
      await next?.close();
      await endLeft(data);
      rmSync(data, { recursive: true, force: true });
    }
  });
}
