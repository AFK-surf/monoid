// Run by w9-cross-engine-handover.test.ts in a process of its own: a station whose sessions' program is in the engine
// it is given, left by its test with an ACP (Grok Build) process opening a session it had before (initialize answered
// and taken, session/load held), and then killed (SIGKILL), as a station crashes: no snapshot, nothing let go of, and
// nothing of it left in the test's own process (its sessions' program, `AgentsHost`). Says on stdout, as one JSON line,
// the session's key, its runner and its sessions' programs once it stands so, and waits to be killed.
// argv: <data> <dump> <mb|pion>
import { execFileSync } from "node:child_process";
import { existsSync, readFileSync } from "node:fs";
import { join } from "node:path";
import { GrokDriver } from "../../src/agents/grok.ts";
import { registerSessionsReaderConfig, setSessionsSpawnObserverForTest } from "../../src/agents/mb-program.ts";
import { ackedOffset, findRunner, outFile, runnerId } from "../../src/agents/process.ts";
import { hubConfig } from "../../src/sessions/config.ts";
import { Hub } from "../../src/sessions/hub.ts";
import { InternalChat } from "../../src/sessions/internal.ts";
import { newSession, say } from "../../src/sessions/lifecycle.ts";
import { Store } from "../../src/store/store.ts";
import { chatTools } from "../../src/tools/chat.ts";
import { openAgentsDoor } from "../../src/tools/http.ts";
import { McpEndpoint } from "../../src/tools/mcp.ts";

const [data, dump, engine] = process.argv.slice(2) as [string, string, "mb" | "pion"];
/// The sessions' programs it spawned, by pid: of which engine, from which binary, a fallback or not, ready or not.
const programs = new Map<number, { pid: number; engine: string; binary: string; fallback: boolean; ready: boolean }>();
setSessionsSpawnObserverForTest((event) => {
  if (event.pid === null) return;
  const had = programs.get(event.pid);
  if (!event.ready) programs.set(event.pid, { pid: event.pid, engine: event.engine, binary: event.binary, fallback: event.fallback, ready: had?.ready ?? false });
  else if (had) had.ready = true;
  else programs.set(event.pid, { pid: event.pid, engine: event.engine, binary: event.binary, fallback: event.fallback, ready: true });
});
registerSessionsReaderConfig(data, () => ({ readers: { sessions: engine } }));

/// Real processes: looked at every 25 ms, giving up past `limitMs` (the test then fails on this process's end).
async function until(done: () => boolean | Promise<boolean>, what: string, limitMs = 30_000) {
  const start = performance.now();
  while (!(await done())) {
    if (performance.now() - start > limitMs) throw new Error(`not within ${limitMs} ms: ${what}`);
    await new Promise((r) => setTimeout(r, 25));
  }
}
const written = () => (existsSync(`${dump}.stdin`) ? readFileSync(`${dump}.stdin`, "utf8").split("\n").filter(Boolean).map((l) => JSON.parse(l)) : []);

const profile = { id: "p", runtime: "grok", home: "homes/grok", access: { kind: "subscription" }, env: { FAKE_DUMP: dump } };
const config = hubConfig({ profiles: [profile], maxNudges: 1 }, data);
const store = Store.open(join(data, "stillfail.db"));
let url = "";
const hub = new Hub({ config: () => config, store, chats: () => undefined, drivers: [new GrokDriver({ data })], mcpUrl: () => url, internal: new InternalChat() });
const mcp = new McpEndpoint((token) => store.sessionByToken(token)?.key, chatTools(hub));
url = (await openAgentsDoor({ port: 0 }, mcp, () => ({ status: 400, body: { error: "no jobs" } }))).url;

const [key, thread] = await newSession(hub, { runtime: "grok", createdBy: "ada@x.com" });
// A turn of its own first: the store knows its session's id from then on.
say(hub, thread.id, "ada@x.com", "say:hello");
await until(() => store.listTurns(key).length >= 2 && store.lastTurn(key)?.endedAt != null && !store.getSession(key)!.running, "its first turns ended");
const id = store.getSession(key)!.runtimeSessionId;
if (!id) throw new Error("its session's id not kept");
// Its process gone (ended by its pid, as the fake said it): the next message opens it again by its id (session/load),
// held there.
const pids = readFileSync(dump, "utf8").split("\n").filter(Boolean).map((l) => JSON.parse(l).pid as number);
if (pids.length !== 1) throw new Error(`${pids.length} processes of it`);
execFileSync("/usr/bin/mkfifo", [`${dump}.load.a`]);
process.kill(pids[0]!, "SIGKILL");
await until(() => hub.processState(key) === "cold", "its process gone");
say(hub, thread.id, "ada@x.com", "say:again");
await until(() => written().some((l) => l.method === "session/load" && l.params.sessionId === id), "its session asked to open again");
const runner = runnerId("grok", key);
const info = await findRunner(data, runner);
if (!info) throw new Error("no runner of it");
// (initialize answered and taken by the station: its output acknowledged past it)
const out = outFile(data, runner);
await until(() => existsSync(out) && readFileSync(out, "utf8").includes('"protocolVersion"'), "initialize answered");
await until(async () => (await ackedOffset(info, out)).at > 0, "initialize's answer acknowledged");
process.stdout.write(`${JSON.stringify({ key, runner, programs: [...programs.values()] })}\n`);
// (until it is killed)
await new Promise(() => {});
