// End to end, with the real Claude driver under the real runner (studio only: the runner is a native build) and the
// fake `claude` (test/fake): a message in the station's own chat starts a turn; the agent calls chat_post through the
// MCP endpoint over HTTP (src/tools/http.ts) with its session's token; the post is recorded in the chat; the turn
// ends all_done, not nudged.
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { delimiter, dirname, join } from "node:path";
import { test } from "node:test";
import { fileURLToPath } from "node:url";
import { ClaudeDriver } from "../src/agents/claude.ts";
import { CodexDriver } from "../src/agents/codex.ts";
import { CursorDriver } from "../src/agents/cursor.ts";
import { DshDriver } from "../src/agents/dsh.ts";
import { GrokDriver } from "../src/agents/grok.ts";
import { HermesDriver } from "../src/agents/hermes.ts";
import type { AgentDriver } from "../src/agents/runtime.ts";
import { outFile, runnerId } from "../src/agents/process.ts";
import { hubConfig } from "../src/sessions/config.ts";
import { Hub, handoverFile } from "../src/sessions/hub.ts";
import { InternalChat } from "../src/sessions/internal.ts";
import { newSession, say } from "../src/sessions/lifecycle.ts";
import { chatTools } from "../src/tools/chat.ts";
import { McpEndpoint } from "../src/tools/mcp.ts";
import { openAgentsDoor } from "../src/tools/http.ts";
import { Store } from "../src/store/store.ts";

const fake = join(dirname(fileURLToPath(import.meta.url)), "fake");
process.env.PATH = `${fake}${delimiter}${process.env.PATH}`;

test("a message in the station's chat: a turn starts, the agent posts through the MCP endpoint, the turn ends all_done", async () => {
  // Short: the runners' sockets live under it (104 bytes at most on macOS).
  const data = mkdtempSync(process.platform === "win32" ? join(tmpdir(), "he-") : "/tmp/he-");
  const home = join(data, "homes", "cc");
  mkdirSync(home, { recursive: true });
  // A login in its file: nothing is looked for in the keychain.
  writeFileSync(join(home, ".credentials.json"), "{}");
  const config = hubConfig({ profiles: [{ id: "cc", runtime: "claude", home: "homes/cc" }], maxNudges: 1 }, data);
  const store = Store.open(join(data, "stillfail.db"));
  const driver = new ClaudeDriver({ data });
  let url = "";
  const hub = new Hub({ config: () => config, store, chats: () => undefined, drivers: [driver], mcpUrl: () => url, internal: new InternalChat() });
  const mcp = new McpEndpoint((token) => store.sessionByToken(token)?.key, chatTools(hub));
  const served = await openAgentsDoor({ port: 0 }, mcp, () => ({ status: 400, body: { error: "no jobs" } }));
  url = served.url;
  try {
    assert.deepEqual(await (await fetch(url.replace(/\/mcp$/, "/health"))).json(), { ok: true });
    const [key, thread] = newSession(hub, { runtime: "claude", createdBy: "ada@x.com" });
    say(hub, thread.id, "ada@x.com", "post:hello from the agent");
    // Its turn: started, posted, ended.
    // Real processes: looked at every 25 ms (no deadline).
    while (store.lastTurn(key)?.endedAt == null) await new Promise((r) => setTimeout(r, 25));
    const said = store.messagesBefore(thread.id, null, 10).map((m) => [m.authorKind, m.author, m.text]);
    assert.deepEqual(said, [
      ["person", "ada@x.com", "post:hello from the agent"],
      ["agent", key, "hello from the agent"],
    ]);
    const turns = store.listTurns(key);
    assert.equal(turns.length, 1, "not nudged");
    assert.deepEqual([turns[0]!.summary.outcome, turns[0]!.summary.ending, turns[0]!.summary.need], ["completed", "all_done", "answered the question that was asked"]);
    assert.ok(!store.getSession(key)!.running);
    assert.deepEqual(store.pendingMessages(key), []);
    // Its process read in the program, its events were given its actor there: Node only said each batch taken.
    const posted = hub.program()!.posted;
    assert.equal(posted.get("event") ?? 0, 0, `events said through Node: ${JSON.stringify([...posted])}`);
    assert.ok((posted.get("routed") ?? 0) > 0, JSON.stringify([...posted]));
  } finally {
    await hub.shutdown();
    await served.close(1000);
    store.close();
    rmSync(data, { recursive: true, force: true });
  }
});

// A Codex app-server's thread's notifications read in the program (mb agents_codex.mbt) are given its session's actor
// there too: Node only says each batch taken, and keeps where each turn began.
test("a message to a Codex session: its turns' events go to its actor in the program, none through Node", async () => {
  const data = mkdtempSync(process.platform === "win32" ? join(tmpdir(), "hx-") : "/tmp/hx-");
  const skills = join(data, "skills");
  mkdirSync(skills, { recursive: true });
  const bundle = join(data, "cert.pem");
  writeFileSync(bundle, "");
  const config = hubConfig({ profiles: [{ id: "cx", runtime: "codex", home: "homes/cx", access: { kind: "opencode-go", key: "k" } }], maxNudges: 1 }, data);
  const store = Store.open(join(data, "stillfail.db"));
  const driver = new CodexDriver({ data, hostSkills: skills, caBundle: bundle });
  let url = "";
  const hub = new Hub({ config: () => config, store, chats: () => undefined, drivers: [driver], mcpUrl: () => url, internal: new InternalChat() });
  const mcp = new McpEndpoint((token) => store.sessionByToken(token)?.key, chatTools(hub));
  const served = await openAgentsDoor({ port: 0 }, mcp, () => ({ status: 400, body: { error: "no jobs" } }));
  url = served.url;
  try {
    const [key, thread] = newSession(hub, { runtime: "codex", createdBy: "ada@x.com" });
    say(hub, thread.id, "ada@x.com", "slow:3");
    // Real processes: looked at every 25 ms (no deadline). Its turn and the one that nudges it, both ended.
    while (store.listTurns(key).length < 2 || store.lastTurn(key)?.endedAt == null) await new Promise((r) => setTimeout(r, 25));
    const turns = store.listTurns(key);
    assert.deepEqual(turns.map((t) => t.summary.outcome), ["completed", "completed"]);
    assert.ok(!store.getSession(key)!.running);
    const posted = hub.program()!.posted;
    assert.equal(posted.get("event") ?? 0, 0, `events said through Node: ${JSON.stringify([...posted])}`);
    assert.ok((posted.get("routed") ?? 0) > 0, JSON.stringify([...posted]));
  } finally {
    await hub.shutdown();
    await served.close(1000);
    store.close();
    rmSync(data, { recursive: true, force: true });
  }
});

/// A station of Codex sessions on one profile (one app-server), in `data`: its hub, its store, its MCP door.
async function codexStation(data: string, env: Record<string, string> = {}) {
  const skills = join(data, "skills");
  mkdirSync(skills, { recursive: true });
  const bundle = join(data, "cert.pem");
  writeFileSync(bundle, "");
  const config = hubConfig({ profiles: [{ id: "cx", runtime: "codex", home: "homes/cx", access: { kind: "opencode-go", key: "k" }, env }], maxNudges: 1 }, data);
  const store = Store.open(join(data, "stillfail.db"));
  const driver = new CodexDriver({ data, hostSkills: skills, caBundle: bundle });
  let url = "";
  const hub = new Hub({ config: () => config, store, chats: () => undefined, drivers: [driver], mcpUrl: () => url, internal: new InternalChat() });
  const mcp = new McpEndpoint((token) => store.sessionByToken(token)?.key, chatTools(hub));
  const served = await openAgentsDoor({ port: 0 }, mcp, () => ({ status: 400, body: { error: "no jobs" } }));
  url = served.url;
  return { hub, store, served };
}

/// Real processes: looked at every 25 ms, failing past `limitMs` saying what never came (what was lost would hang the
/// test file otherwise).
async function until(done: () => boolean, what: string, limitMs = 30_000) {
  const start = performance.now();
  while (!done()) {
    if (performance.now() - start > limitMs) assert.fail(`not within ${limitMs} ms: ${what}`);
    await new Promise((r) => setTimeout(r, 25));
  }
}

// Two sessions on one app-server: a line of the program's says both threads' events, each a batch of its own, which
// their actors take one after the other; the first taken lets go of none of the other's (2026-11-15: it let go of all
// told up to the same place, the other session's events lost).
test("two Codex sessions on one app-server at once: each one's events go to its own actor, none lost", async () => {
  const data = mkdtempSync(process.platform === "win32" ? join(tmpdir(), "hy-") : "/tmp/hy-");
  const { hub, store, served } = await codexStation(data);
  try {
    const sessions = [0, 1, 2, 3].map(() => newSession(hub, { runtime: "codex", createdBy: "ada@x.com" }));
    for (const [, thread] of sessions) say(hub, thread.id, "ada@x.com", "slow:8");
    // Each its turn and the one that nudges it, both ended.
    await until(() => sessions.every(([key]) => store.listTurns(key).length >= 2 && store.lastTurn(key)?.endedAt != null), "every session's turns ended");
    // (a batch let go of before its actor took it never ends that actor's turn: the wait above fails then)
    for (const [key] of sessions) {
      assert.deepEqual(store.listTurns(key).map((t) => t.summary.outcome), ["completed", "completed"], key);
      assert.ok(!store.getSession(key)!.running, key);
    }
    const posted = hub.program()!.posted;
    assert.equal(posted.get("event") ?? 0, 0, `events said through Node: ${JSON.stringify([...posted])}`);
    assert.ok((posted.get("routed") ?? 0) > sessions.length, JSON.stringify([...posted]));
  } finally {
    await hub.shutdown();
    await served.close(1000);
    store.close();
    rmSync(data, { recursive: true, force: true });
  }
});

// Handed over while its turn writes: what the program held of it is told before the sessions are, nothing read after
// it, and the next station takes the turn up where it was, to its end.
test("a Codex turn handed over while it writes is taken up by the next station and ends there", { skip: process.platform === "win32" ? "fifos" : false }, async () => {
  const data = mkdtempSync("/tmp/hz-");
  const dump = join(data, "dump");
  const first = await codexStation(data, { FAKE_DUMP: dump });
  let next: Awaited<ReturnType<typeof codexStation>> | null = null;
  try {
    const gate = `${dump}.held`;
    for (const part of ["a", "b"]) execFileSync("/usr/bin/mkfifo", [`${gate}.${part}`]);
    const [key, thread] = newSession(first.hub, { runtime: "codex", createdBy: "ada@x.com" });
    say(first.hub, thread.id, "ada@x.com", "gate:6:3:held");
    await until(() => first.store.getSession(key)?.running === true && first.store.lastTurn(key) !== undefined, "its turn begun");
    // (three of its deltas written, the turn waiting for the rest)
    const out = outFile(data, runnerId("codex", "cx"));
    await until(() => existsSync(out) && readFileSync(out, "utf8").includes('"delta":"d2 "'), "three of its deltas written");
    await first.hub.handOver();
    await first.served.close(1000);
    next = await codexStation(data, { FAKE_DUMP: dump });
    await next.hub.takeUp();
    await writeFile(`${gate}.a`, "go");
    await until(() => existsSync(`${gate}.said`), "the rest of its deltas written");
    await writeFile(`${gate}.b`, "go");
    const store = next.store;
    // (its turn and the one that nudges it, no state said: both ended before the station is let go, as below; let go
    // between them, the nudge's app-server started as it shut down: mb-agents-closed.test.ts)
    await until(() => store.listTurns(key).length >= 2 && store.lastTurn(key)?.endedAt != null && !store.getSession(key)!.running, "its turns ended on the next station");
    assert.deepEqual(store.listTurns(key).map((t) => t.summary.outcome), ["completed", "completed"], "its turn, ended on the next station, and the nudge's");
    const posted = next.hub.program()!.posted;
    assert.equal(posted.get("event") ?? 0, 0, `events said through Node: ${JSON.stringify([...posted])}`);
  } finally {
    // (the one handed over let go of what it ran: its own parts end)
    await first.hub.shutdown();
    await next?.hub.shutdown();
    await next?.served.close(1000);
    next?.store.close();
    first.store.close();
    rmSync(data, { recursive: true, force: true });
  }
});

// DeepSeek Harness', Cursor's and the ACP runtimes' processes read in the program (mb agents_own.mbt) give their
// sessions' actors there their events as Claude Code's do: Node only says each batch taken.
const OWN: { runtime: string; profile: Record<string, unknown>; driver: (data: string) => AgentDriver }[] = [
  { runtime: "dsh", profile: { access: { kind: "opencode-go", key: "k1" }, model: "m1" }, driver: (data) => new DshDriver({ data }) },
  { runtime: "cursor", profile: { access: { kind: "subscription" }, env: { CURSOR_API_KEY: "crsr_k1" } }, driver: (data) => new CursorDriver({ data, sdk: join(fake, "cursor-sdk") }) },
  { runtime: "grok", profile: { access: { kind: "subscription" } }, driver: (data) => new GrokDriver({ data }) },
  { runtime: "hermes", profile: { access: { kind: "env" }, model: "openrouter:test" }, driver: (data) => new HermesDriver({ data }) },
];

/// A station of sessions of `runtime`'s, in `data`: its hub, its store, its MCP door.
async function ownStation(data: string, own: (typeof OWN)[number]) {
  const config = hubConfig({ profiles: [{ id: "p", runtime: own.runtime, home: `homes/${own.runtime}`, ...own.profile }], maxNudges: 1 }, data);
  const store = Store.open(join(data, "stillfail.db"));
  let url = "";
  const hub = new Hub({ config: () => config, store, chats: () => undefined, drivers: [own.driver(data)], mcpUrl: () => url, internal: new InternalChat() });
  const mcp = new McpEndpoint((token) => store.sessionByToken(token)?.key, chatTools(hub));
  const served = await openAgentsDoor({ port: 0 }, mcp, () => ({ status: 400, body: { error: "no jobs" } }));
  url = served.url;
  return { hub, store, served };
}

for (const own of OWN) {
  test(`a message to a ${own.runtime} session: its turns' events go to its actor in the program, none through Node`, async () => {
    const data = mkdtempSync(process.platform === "win32" ? join(tmpdir(), "ho-") : "/tmp/ho-");
    const { hub, store, served } = await ownStation(data, own);
    try {
      const [key, thread] = newSession(hub, { runtime: own.runtime as never, createdBy: "ada@x.com" });
      say(hub, thread.id, "ada@x.com", "say:hello");
      // Its turn and the one that nudges it (no state said), both ended.
      await until(() => store.listTurns(key).length >= 2 && store.lastTurn(key)?.endedAt != null, "its turns ended");
      assert.deepEqual(store.listTurns(key).map((t) => t.summary.outcome), ["completed", "completed"]);
      assert.ok(!store.getSession(key)!.running);
      const posted = hub.program()!.posted;
      assert.equal(posted.get("event") ?? 0, 0, `events said through Node: ${JSON.stringify([...posted])}`);
      assert.ok((posted.get("routed") ?? 0) > 0, JSON.stringify([...posted]));
    } finally {
      await hub.shutdown();
      await served.close(1000);
      store.close();
      rmSync(data, { recursive: true, force: true });
    }
  });
}

// Its turn running as the station hands over, or as it crashes (no snapshot left: what the program reads again of the
// output says where it stands), taken up by the next station: a message steered into it there ends it, once, its events
// given its actor in the program on both stations.
for (const own of OWN.filter((o) => o.runtime === "dsh" || o.runtime === "grok")) {
  for (const crashed of [false, true]) {
    test(`a ${own.runtime} turn running as the station ${crashed ? "crashes" : "hands over"} is taken up by the next and ends there once`, async () => {
      const data = mkdtempSync(process.platform === "win32" ? join(tmpdir(), "hp-") : "/tmp/hp-");
      const first = await ownStation(data, own);
      let next: Awaited<ReturnType<typeof ownStation>> | null = null;
      try {
        const [key, thread] = newSession(first.hub, { runtime: own.runtime as never, createdBy: "ada@x.com" });
        // Its reply read by the first station's program and taken by Node, which told the runner so (mb agents.mbt
        // `take`, before the live view is given the batch): its runner having written it is not enough, the program
        // may not have read it yet, and a crash then reads none of its turn again (the next station is given it live).
        let told = false;
        const watch = first.hub.live.subscribe(key, 0, 0, (m) => {
          if (m.type === "step" && m.event.kind === "start" && m.event.step === "text") told = true;
        });
        say(first.hub, thread.id, "ada@x.com", "test-hold");
        await until(() => first.store.getSession(key)?.running === true && first.store.lastTurn(key) !== undefined, "its turn begun");
        const out = outFile(data, runnerId(own.runtime as never, key));
        // (dsh's reply whole, Grok Build's in two chunks: "hold", "ing")
        await until(() => existsSync(out) && readFileSync(out, "utf8").includes('"text":"hold'), "its reply written");
        await until(() => told, "its reply read by the first station");
        first.hub.live.unsubscribe(key, watch);
        await first.hub.handOver();
        await first.served.close(1000);
        assert.equal(first.hub.program()?.posted.get("event") ?? 0, 0);
        // (a crash leaves no snapshot: the runners alone)
        if (crashed) rmSync(handoverFile(data), { force: true });
        next = await ownStation(data, own);
        await next.hub.takeUp();
        assert.equal(next.store.getSession(key)?.running, true, "its turn still running");
        say(next.hub, thread.id, "ada@x.com", "go on");
        const store = next.store;
        // (its turn and the one that nudges it, no state said: both ended before the station is let go)
        await until(() => store.listTurns(key).length >= 2 && store.lastTurn(key)?.endedAt != null && !store.getSession(key)!.running, "its turns ended on the next station");
        assert.deepEqual(store.listTurns(key).map((t) => t.summary.outcome), ["completed", "completed"], "its turn, ended on the next station once, and the nudge's");
        // (taken up after a crash, the turn the station did not start is said started by its driver as it takes it up:
        // own-process.ts `adoptOn`; every event of the output's is given its actor in the program)
        const posted = next.hub.program()!.posted;
        assert.equal(posted.get("event") ?? 0, crashed ? 1 : 0, `events said through Node: ${JSON.stringify([...posted])}`);
        assert.ok((posted.get("routed") ?? 0) > 0, JSON.stringify([...posted]));
      } finally {
        await first.hub.shutdown();
        await next?.hub.shutdown();
        await next?.served.close(1000);
        next?.store.close();
        first.store.close();
        rmSync(data, { recursive: true, force: true });
      }
    });
  }
}
