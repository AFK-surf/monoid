// What the shipped reader's `--sessions` program (station/mb/src/reader) asks and tells Node, read from both sources
// as they are. Each call is matched to the branch of Node's shell that really receives it:
//
// - a session actor's (actor_base.mbt, actor_run.mbt): its `node.*` RPCs to the cases of mb-actor.ts `asked()` past
//   its `agent` block, its bare `"t"` to the `f === "t"` there, its `agent_do` calls to the `agent` block's cases or a
//   method a runtime's session declares (station/src/agents/, never mb-actor.ts's own), its `deps` to SessionDeps, its
//   `store` calls to the store, its tells to `told()`;
// - `#jobs` (jobs.mbt), `#live` (live.mbt) and `#remote` (remote*.mbt): what they ask through `jnode`/`jstore`,
//   `lnode` and `rnode`/`rstore` (each helper's prefix read from its source), and what they tell, to
//   station/src/jobs/jobs.ts, station/src/sessions/live.ts and station/src/jobs/remote.ts.
//
// This is the reader ↔ Node contract every release runs on (station/AGENTS.md); the frozen whole station in MoonBit
// (station_main) is held apart, by mb-station-contracts.test.ts. Each matcher is also run on a source changed to break
// it, so that a matcher that passes everything fails here.
import assert from "node:assert/strict";
import { readdirSync, readFileSync, statSync } from "node:fs";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { test } from "node:test";

const station = fileURLToPath(new URL("..", import.meta.url));
const reader = join(station, "mb", "src", "reader");

const read = (p: string) => readFileSync(p, "utf8");
const walk = (dir: string, keep: (p: string) => boolean): string[] =>
  readdirSync(dir).flatMap((n) => {
    const p = join(dir, n);
    return statSync(p).isDirectory() ? walk(p, keep) : keep(p) ? [p] : [];
  });
const tsSources = (dir: string) => walk(dir, (p) => p.endsWith(".ts") && !p.endsWith(".test.ts")).map(read).join("\n");

/// A source by name: what each matcher reads, so a test can hand it a changed one.
type Sources = Record<string, string>;

/// The literals `re` captures in each source, each with where it is first.
function literals(sources: Sources, names: string[], re: RegExp): Map<string, string> {
  const out = new Map<string, string>();
  for (const name of names) {
    const text = sources[name]!;
    for (const m of text.matchAll(re)) if (!out.has(m[1]!)) out.set(m[1]!, `${name}:${text.slice(0, m.index!).split("\n").length}`);
  }
  return out;
}

/// A class method of `text` from `header` to its closing brace (two spaces in).
function method(text: string, header: string): string {
  const start = text.indexOf(header);
  assert.ok(start >= 0, `no ${header}`);
  const end = text.indexOf("\n  }\n", start);
  assert.ok(end > start, `no end of ${header}`);
  return text.slice(start, end + 4);
}

/// The `case "…":` literals of `snippet` at exactly `indent` spaces: one switch's own, not a nested one's.
function casesAt(snippet: string, indent: number): Set<string> {
  return new Set([...snippet.matchAll(new RegExp(`^ {${indent}}case "([^"]+)":`, "gm"))].map((m) => m[1]!));
}

/// The `f === "…"` literals of an if-chain.
const compared = (snippet: string) => new Set([...snippet.matchAll(/\bf === "([^"]+)"/g)].map((m) => m[1]!));

/// Whether `name` is a method of the station's store.
const storeHas = (storeText: string, name: string) => new RegExp(`^\\s+(?:async\\s+)?${name}\\s*[(<]`, "m").test(storeText);

/// The methods a runtime's session has: AgentSession's (station/src/agents/runtime.ts) and those of every class whose
/// name ends in `Session` there, by their heads at a member's indent. A driver's (`…Driver`) are not a session's.
function sessionMethods(agents: string): Set<string> {
  const out = new Set<string>();
  const bodies = [...agents.matchAll(/^export interface AgentSession \{\n[\s\S]*?\n\}\n|^(?:export )?(?:abstract )?class \w*Session\b(?:<[^\n]*?>)?(?: extends [^\n{]*?)?(?: implements [^\n{]*?)? \{\n[\s\S]*?\n\}\n/gm)].map((m) => m[0]);
  assert.ok(bodies.some((b) => b.startsWith("export interface AgentSession")), "station/src/agents/ has no AgentSession");
  assert.ok(bodies.length >= 4, `the runtimes' session classes read: ${bodies.length}`);
  for (const b of bodies) {
    for (const m of b.matchAll(/^ {2}(?:(?:public|protected|private|override|abstract|async|static)\s+)*([A-Za-z_]\w*)\??\s*[(<]/gm)) if (m[1] !== "constructor") out.add(m[1]!);
  }
  return out;
}

const ACTOR_FILES = ["reader/actor_base.mbt", "reader/actor_run.mbt"];

function actorSources(): Sources {
  return {
    "reader/actor_base.mbt": read(join(reader, "actor_base.mbt")),
    "reader/actor_run.mbt": read(join(reader, "actor_run.mbt")),
    "src/sessions/mb-actor.ts": read(join(station, "src", "sessions", "mb-actor.ts")),
    "src/sessions/actor.ts": read(join(station, "src", "sessions", "actor.ts")),
    "src/agents": tsSources(join(station, "src", "agents")),
    "src/store": tsSources(join(station, "src", "store")),
  };
}

/// What a session actor asks or tells that Node's shell (mb-actor.ts) does not receive where it lands.
function actorWrong(s: Sources): string[] {
  const mbActor = s["src/sessions/mb-actor.ts"]!;
  const asked = method(mbActor, "  async asked(f: string");
  const agentStart = asked.indexOf('    if (part === "agent") {');
  assert.ok(agentStart >= 0, "mb-actor.ts asked() has no agent block");
  const agentEnd = asked.indexOf("\n    }\n", agentStart);
  assert.ok(agentEnd > agentStart, "mb-actor.ts asked() agent block has no end");
  const agentBlock = asked.slice(agentStart, agentEnd);
  // (past the store, deps and agent blocks: `"t"`, then `switch (name)` of every `node.*`)
  const nodeBlock = asked.slice(agentEnd);
  const agentCases = casesAt(agentBlock, 8);
  const nodeCases = casesAt(nodeBlock, 6);
  const tAnswered = /^ {4}if \(f === "t"\) return /m.test(nodeBlock);
  const toldCases = casesAt(method(mbActor, "  told(f: string, args: Json[]) {"), 6);
  const actorTs = s["src/sessions/actor.ts"]!;
  const depsStart = actorTs.indexOf("export type SessionDeps =");
  assert.ok(depsStart >= 0, "actor.ts has no SessionDeps");
  const depsText = `${actorTs.slice(depsStart)}\n${mbActor}`;
  // (the default of the agent block calls the runtime session's method of that name: one of AgentSession's, or of a
  // session class of a runtime's, never a driver's (`adopt`) nor MbActor's own `asked` or `told`)
  const methods = sessionMethods(s["src/agents"]!);
  const sessionMethod = (name: string) => methods.has(name);
  const storeText = `${mbActor}\n${actorTs}\n${s["src/store"]}`;

  const wrong: string[] = [];
  // (every literal RPC: a prefix made at the call, `"store." + f`, is the store/deps/agent helpers' below)
  const rpcs = literals(s, ACTOR_FILES, /\bself\.rpc\(\s*[^,]+,\s*"([^"]+)"\s*,/g);
  assert.ok(rpcs.size >= 20, `reader actors' RPCs read: ${rpcs.size}`);
  for (const [f, where] of rpcs) {
    if (f === "t") {
      if (!tAnswered) wrong.push(`${where} asks "t", which mb-actor.ts asked() no longer answers (\`if (f === "t")\`)`);
    } else if (f.startsWith("node.")) {
      const name = f.slice("node.".length);
      if (!nodeCases.has(name)) wrong.push(`${where} asks "${f}", which no \`case "${name}":\` of mb-actor.ts asked()'s node switch answers${agentCases.has(name) ? " (only its agent block has it)" : ""}`);
    } else wrong.push(`${where} asks "${f}", a part mb-actor.ts asked() does not dispatch`);
  }
  const tells = literals(s, ACTOR_FILES, /\bself\.tell\(\s*[^,]+,\s*"([^"]+)"/g);
  assert.ok(tells.size >= 3, `reader actors' tells read: ${tells.size}`);
  for (const [f, where] of tells) if (!toldCases.has(f)) wrong.push(`${where} tells "${f}", which mb-actor.ts told() does not handle`);
  const deps = literals(s, ACTOR_FILES, /\bself\.deps\(\s*[^,]+,\s*"([^"]+)"/g);
  assert.ok(deps.size >= 15, `reader deps calls read: ${deps.size}`);
  for (const [name, where] of deps) if (!new RegExp(`\\b${name}\\??\\s*[(:]`).test(depsText)) wrong.push(`${where} calls deps "${name}", missing from SessionDeps / mb-actor.ts`);
  const agents = literals(s, ACTOR_FILES, /\bself\.agent_do\(\s*[^,]+,\s*[^,]+,\s*"([^"]+)"/g);
  assert.ok(agents.size >= 10, `reader agent calls read: ${agents.size}`);
  for (const [name, where] of agents) {
    // (the agent block's own case, or its default: a method of the runtime session)
    if (!agentCases.has(name) && !sessionMethod(name)) wrong.push(`${where} calls agent "${name}", answered neither by mb-actor.ts asked()'s agent block nor a runtime session's method`);
  }
  const stores = literals(s, ACTOR_FILES, /\bself\.store\(\s*[^,]+,\s*"([^"]+)"/g);
  assert.ok(stores.size >= 20, `reader store calls read: ${stores.size}`);
  for (const [name, where] of stores) if (!new RegExp(`\\b${name}\\??\\s*\\(`).test(storeText)) wrong.push(`${where} calls store "${name}", missing in mb-actor.ts / station/src/store/`);
  return wrong;
}

test("every RPC and tell that reader actors make is handled where it lands in Node mb-actor.ts", () => {
  const wrong = actorWrong(actorSources());
  assert.deepEqual(wrong, [], wrong.join("\n"));
});

test("the actors' matcher fails a node.* RPC only the agent block answers, and a lost \"t\"", () => {
  const s = actorSources();
  assert.match(s["reader/actor_run.mbt"]!, /"node\.uuid"/);
  const holding = actorWrong({ ...s, "reader/actor_run.mbt": s["reader/actor_run.mbt"]!.replace('"node.uuid"', '"node.holding"') });
  assert.ok(holding.some((w) => w.includes('"node.holding"') && w.includes("only its agent block")), holding.join("\n"));
  const mbActor = s["src/sessions/mb-actor.ts"]!;
  assert.match(mbActor, /^ {4}if \(f === "t"\) return .*\n/m);
  const noT = actorWrong({ ...s, "src/sessions/mb-actor.ts": mbActor.replace(/^ {4}if \(f === "t"\) return .*\n/m, "") });
  assert.ok(noT.some((w) => w.includes('asks "t"')), noT.join("\n"));
});

test("the actors' matcher fails an agent_do that only MbActor's own method would answer", () => {
  const s = actorSources();
  const run = s["reader/actor_run.mbt"]!;
  assert.match(run, /self\.agent_do\(([^,]+), ([^,]+), "holding"/);
  const asked = actorWrong({ ...s, "reader/actor_run.mbt": run.replace(/self\.agent_do\(([^,]+), ([^,]+), "holding"/, 'self.agent_do($1, $2, "asked"') });
  assert.ok(asked.some((w) => w.includes('calls agent "asked"')), asked.join("\n"));
});

test("the actors' matcher fails an agent_do that only a driver's method would answer", () => {
  const s = actorSources();
  assert.match(s["src/agents"]!, /^ {2}(?:async\s+)?adopt\s*\(/m, "a driver's adopt, as read");
  const run = s["reader/actor_run.mbt"]!;
  const abort = /self\.agent_do\(([^,]+), ([^,]+), "abort"/;
  assert.match(run, abort);
  const adopt = actorWrong({ ...s, "reader/actor_run.mbt": run.replace(abort, 'self.agent_do($1, $2, "adopt"') });
  assert.ok(adopt.some((w) => w.includes('calls agent "adopt"')), adopt.join("\n"));
});

// ── #jobs, #live and #remote ──

const PSEUDO_FILES = () => readdirSync(reader).filter((n) => /^(jobs|live|remote.*)\.mbt$/.test(n)).map((n) => `reader/${n}`);

function pseudoSources(): Sources {
  const out: Sources = {};
  for (const f of PSEUDO_FILES()) out[f] = read(join(reader, f.slice("reader/".length)));
  out["src/jobs/jobs.ts"] = read(join(station, "src", "jobs", "jobs.ts"));
  out["src/sessions/live.ts"] = read(join(station, "src", "sessions", "live.ts"));
  out["src/jobs/remote.ts"] = read(join(station, "src", "jobs", "remote.ts"));
  out["src/store"] = tsSources(join(station, "src", "store"));
  return out;
}

/// Each pseudo-actor: its key in the program, its helpers' names, and where Node receives what it asks and tells.
const PSEUDO = [
  { key: "jobs_key", node: "jnode", store: "jstore", ts: "src/jobs/jobs.ts", asked: "  private async asked(f: string", told: "  private told(f: string" },
  { key: "live_key", node: "lnode", store: null, ts: "src/sessions/live.ts", asked: "  async #asked(f: string", told: "  #tellOf(f: string" },
  { key: "remote_key", node: "rnode", store: "rstore", ts: "src/jobs/remote.ts", asked: "  private async asked(f: string", told: "  private told(f: string" },
] as const;

/// What a helper (`Actors::jnode` and the like) puts before the name it is given, as its source says: `self.rpc(<key>,
/// "node." + f, …)` says "node.", `self.rpc(<key>, f, …)` nothing.
function prefixOf(s: Sources, files: string[], helper: string, key: string): string {
  const re = new RegExp(`fn Actors::${helper}\\([^)]*\\)[^{]*\\{\\s*self\\.rpc\\(\\s*${key},\\s*(?:"([^"]*)"\\s*\\+\\s*)?f,`);
  for (const f of files) {
    const m = re.exec(s[f]!);
    if (m) return m[1] ?? "";
  }
  assert.fail(`no Actors::${helper} that asks self.rpc(${key}, … f, …) in reader/`);
}

/// What `#jobs`, `#live` and `#remote` ask or tell that Node does not receive.
function pseudoWrong(s: Sources): string[] {
  const files = Object.keys(s).filter((k) => k.startsWith("reader/"));
  const wrong: string[] = [];
  for (const p of PSEUDO) {
    const ts = s[p.ts]!;
    const asked = method(ts, p.asked);
    const told = method(ts, p.told);
    const askedNames = new Set([...casesAt(asked, 6), ...compared(asked)]);
    const toldNames = new Set([...casesAt(told, 6), ...compared(told)]);
    const prefix = prefixOf(s, files, p.node, p.key);
    const asks = literals(s, files, new RegExp(`\\b${p.node}\\(\\s*"([^"]+)"`, "g"));
    assert.ok(asks.size >= 3, `${p.key}'s asks read: ${asks.size}`);
    for (const [name, where] of asks) if (!askedNames.has(prefix + name)) wrong.push(`${where} asks ${p.key} "${prefix}${name}" (Actors::${p.node}), which ${p.ts} asked() does not answer`);
    if (p.store !== null) {
      const storePrefix = prefixOf(s, files, p.store, p.key);
      if (storePrefix !== "store.") wrong.push(`Actors::${p.store} asks ${p.key} "${storePrefix}…", which ${p.ts} asked() does not hand to the store`);
      assert.match(asked, /f\.startsWith\("store\."\)/, `${p.ts} asked() hands store.* to the store no more`);
      for (const [name, where] of literals(s, files, new RegExp(`\\b${p.store}\\(\\s*"([^"]+)"`, "g"))) {
        if (!storeHas(s["src/store"]!, name)) wrong.push(`${where} asks ${p.key} "store.${name}", no method of station/src/store/`);
      }
    }
    const tells = literals(s, files, new RegExp(`\\bself\\.tell\\(\\s*${p.key},\\s*"([^"]+)"`, "g"));
    assert.ok(tells.size >= 1, `${p.key}'s tells read: ${tells.size}`);
    for (const [name, where] of tells) if (!toldNames.has(name)) wrong.push(`${where} tells ${p.key} "${name}", which ${p.ts} does not handle`);
  }
  return wrong;
}

test("every ask and tell of reader #jobs, #live and #remote is handled in Node", () => {
  const wrong = pseudoWrong(pseudoSources());
  assert.deepEqual(wrong, [], wrong.join("\n"));
});

test("the pseudo-actors' matcher fails a node.endGroup that jobs.ts no longer handles", () => {
  const s = pseudoSources();
  const jobs = s["src/jobs/jobs.ts"]!;
  const branch = /\s*else if \(f === "node\.endGroup"\) [^\n]*;/;
  assert.match(jobs, branch);
  const wrong = pseudoWrong({ ...s, "src/jobs/jobs.ts": jobs.replace(branch, "") });
  assert.ok(wrong.some((w) => w.includes('"node.endGroup"') && w.includes("src/jobs/jobs.ts")), wrong.join("\n"));
});

test("the pseudo-actors' matcher fails a jnode whose prefix is no longer node.", () => {
  const s = pseudoSources();
  const jobs = s["reader/jobs.mbt"]!;
  const node = 'self.rpc(jobs_key, "node." + f, args)';
  assert.ok(jobs.includes(node), "jobs.mbt's jnode as read");
  const wrong = pseudoWrong({ ...s, "reader/jobs.mbt": jobs.replace(node, 'self.rpc(jobs_key, "store." + f, args)') });
  assert.ok(wrong.some((w) => w.includes('"store.') && w.includes("Actors::jnode")), wrong.join("\n"));
});
