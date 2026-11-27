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
import { createHash } from "node:crypto";
import { existsSync, readdirSync, readFileSync, statSync } from "node:fs";
import { join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { test } from "node:test";

const station = fileURLToPath(new URL("..", import.meta.url));
const reader = join(station, "mb", "src", "reader");
const pionStationPkgs = resolve(station, "..", "pion", "station", "packages");

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

const PSEUDO_FILES = () => readdirSync(reader).filter((n) => /^(jobs|live|remote.*|dirsync.*)\.mbt$/.test(n)).map((n) => `reader/${n}`);

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

// ── Pion `--sessions` RPC/tell/store/deps/agent contract framework (Wave 8 §2.5.4) ──

function pionSessionsSources(pkgsDir: string = pionStationPkgs): Sources {
  assert.ok(existsSync(pkgsDir), `pion/station/packages directory missing: ${pkgsDir}`);
  const out: Sources = {
    "src/sessions/mb-actor.ts": read(join(station, "src", "sessions", "mb-actor.ts")),
    "src/sessions/actor.ts": read(join(station, "src", "sessions", "actor.ts")),
    "src/agents": tsSources(join(station, "src", "agents")),
    "src/store": tsSources(join(station, "src", "store")),
    "src/jobs/jobs.ts": read(join(station, "src", "jobs", "jobs.ts")),
    "src/sessions/live.ts": read(join(station, "src", "sessions", "live.ts")),
    "src/jobs/remote.ts": read(join(station, "src", "jobs", "remote.ts")),
  };
  const foundByPkg = new Map<string, number>();
  for (const entry of readdirSync(pkgsDir, { withFileTypes: true }).sort((a, b) => a.name.localeCompare(b.name))) {
    if (!entry.isDirectory()) continue;
    if (!entry.name.startsWith("sessions_") && entry.name !== "reader_sessions") continue;
    const srcDir = join(pkgsDir, entry.name, "src");
    if (!existsSync(srcDir)) continue;
    const files = readdirSync(srcDir).filter((n) => n.endsWith(".pion") && !n.endsWith("_test.pion")).sort();
    foundByPkg.set(entry.name, files.length);
    for (const f of files) {
      out[`pion/${entry.name}/${f}`] = read(join(srcDir, f));
    }
  }
  for (const required of ["sessions_core", "reader_sessions"]) {
    assert.ok(
      (foundByPkg.get(required) ?? 0) > 0,
      `required Pion package "${required}" missing or has no production src/*.pion in ${pkgsDir}`,
    );
  }
  return out;
}

/// Validates Pion `--sessions` helper calls (`rpc_k`, `deps_k`, `store_k`, `agent_do_k`,
/// `jnode_k`, `jstore_k`, `lnode_k`, `rnode_k`, `rstore_k`, `tell`) against the real TS handlers.
function pionSessionsWrong(s: Sources): string[] {
  const pionFiles = Object.keys(s).filter((k) => k.startsWith("pion/"));
  const mbActor = s["src/sessions/mb-actor.ts"]!;
  const asked = method(mbActor, "  async asked(f: string");
  const agentStart = asked.indexOf('    if (part === "agent") {');
  assert.ok(agentStart >= 0, "mb-actor.ts asked() has no agent block");
  const agentEnd = asked.indexOf("\n    }\n", agentStart);
  assert.ok(agentEnd > agentStart, "mb-actor.ts asked() agent block has no end");
  const agentBlock = asked.slice(agentStart, agentEnd);
  const nodeBlock = asked.slice(agentEnd);
  const agentCases = casesAt(agentBlock, 8);
  const nodeCases = casesAt(nodeBlock, 6);
  const tAnswered = /^ {4}if \(f === "t"\) return /m.test(nodeBlock);
  const toldCases = casesAt(method(mbActor, "  told(f: string, args: Json[]) {"), 6);

  const actorTs = s["src/sessions/actor.ts"]!;
  const depsStart = actorTs.indexOf("export type SessionDeps =");
  assert.ok(depsStart >= 0, "actor.ts has no SessionDeps");
  const depsText = `${actorTs.slice(depsStart)}\n${mbActor}`;
  const methods = sessionMethods(s["src/agents"]!);
  const storeText = `${mbActor}\n${actorTs}\n${s["src/store"]}`;

  const wrong: string[] = [];

  // 1. Actor `gen.rpc_k(host, key, "node.xxx" | "t", ...)` (3-arg), `rpc_k(key, "node.xxx" | "t", ...)` (2-arg),
  //    AND `rpc_direct_k(key, "node.xxx" | "agent.xxx" | "t", ...)` (2-arg).
  //    Using negative lookahead `(?!\s*")` on the 3rd arg of the 2-arg pattern ensures a literal key in
  //    `gen.rpc_k(host, "s1", "node.xxx", ...)` is NEVER misread as `f`.
  const rpcCalls = new Map<string, string>();
  for (const name of pionFiles) {
    const text = s[name]!;
    for (const m of text.matchAll(/\brpc_k\(\s*[^,]+,\s*[^,]+,\s*"([^"]+)"\s*,/g)) {
      const f = m[1]!;
      const line = text.slice(0, m.index!).split("\n").length;
      if (!rpcCalls.has(f)) rpcCalls.set(f, `${name}:${line}`);
    }
    for (const m of text.matchAll(/\brpc(?:_direct)?_k\(\s*[^,]+,\s*"([^"]+)"\s*,(?!\s*")/g)) {
      const f = m[1]!;
      const line = text.slice(0, m.index!).split("\n").length;
      if (!rpcCalls.has(f)) rpcCalls.set(f, `${name}:${line}`);
    }
  }
  for (const [f, where] of rpcCalls) {
    if (f === "t") {
      if (!tAnswered) wrong.push(`${where} asks "t", which mb-actor.ts asked() no longer answers`);
    } else if (f.startsWith("node.")) {
      const name = f.slice("node.".length);
      if (!nodeCases.has(name)) {
        wrong.push(`${where} asks "${f}", which no \`case "${name}":\` of mb-actor.ts asked()'s node switch answers${agentCases.has(name) ? " (only its agent block has it)" : ""}`);
      }
    } else if (f.startsWith("agent.")) {
      const name = f.slice("agent.".length);
      if (!agentCases.has(name) && !methods.has(name)) {
        wrong.push(`${where} asks "${f}", answered neither by mb-actor.ts asked()'s agent block nor a runtime session's method`);
      }
    } else if (!f.startsWith("store.") && !f.startsWith("deps.")) {
      wrong.push(`${where} asks "${f}", a part mb-actor.ts asked() does not dispatch`);
    }
  }

  // 2. Actor `deps_k(a, "xxx", ...)`
  for (const [name, where] of literals(s, pionFiles, /\bdeps_k\(\s*[^,]+,\s*"([^"]+)"/g)) {
    if (!new RegExp(`\\b${name}\\??\\s*[(:]`).test(depsText)) {
      wrong.push(`${where} calls deps_k "${name}", missing from SessionDeps / mb-actor.ts`);
    }
  }

  // 3. Actor `store_k(a, "xxx", ...)` AND `store_direct_k(key, "xxx", ...)`
  for (const [name, where] of literals(s, pionFiles, /\bstore(?:_direct)?_k\(\s*[^,]+,\s*"([^"]+)"/g)) {
    if (!new RegExp(`\\b${name}\\??\\s*\\(`).test(storeText)) {
      wrong.push(`${where} calls store_k "${name}", missing in mb-actor.ts / station/src/store/`);
    }
  }

  // 4. Actor `agent_do_k(a, g, "xxx", ...)`
  for (const [name, where] of literals(s, pionFiles, /\bagent_do_k\(\s*[^,]+,\s*[^,]+,\s*"([^"]+)"/g)) {
    if (!agentCases.has(name) && !methods.has(name)) {
      wrong.push(`${where} calls agent_do_k "${name}", answered neither by mb-actor.ts asked()'s agent block nor a runtime session's method`);
    }
  }

  // 5. Pseudo-actors `jnode_k`/`jstore_k`, `lnode_k`, `rnode_k`/`rstore_k`, and `tell` (both 2-arg and 3-arg forms)
  const pionPseudo = [
    { key: "jobs_key", node: "jnode_k", store: "jstore_k", prefix: "node.", ts: "src/jobs/jobs.ts", asked: "  private async asked(f: string", told: "  private told(f: string" },
    { key: "live_key", node: "lnode_k", store: null, prefix: "", ts: "src/sessions/live.ts", asked: "  async #asked(f: string", told: "  #tellOf(f: string" },
    { key: "remote_key", node: "rnode_k", store: "rstore_k", prefix: "node.", ts: "src/jobs/remote.ts", asked: "  private async asked(f: string", told: "  private told(f: string" },
  ] as const;

  const pseudoToldByKey = new Map<string, Set<string>>();
  for (const p of pionPseudo) {
    const ts = s[p.ts]!;
    const pAsked = method(ts, p.asked);
    const pTold = method(ts, p.told);
    const askedNames = new Set([...casesAt(pAsked, 6), ...compared(pAsked)]);
    const toldNames = new Set([...casesAt(pTold, 6), ...compared(pTold)]);
    pseudoToldByKey.set(p.key, toldNames);

    for (const [name, where] of literals(s, pionFiles, new RegExp(`\\b${p.node}\\(\\s*"([^"]+)"`, "g"))) {
      if (!askedNames.has(p.prefix + name)) {
        wrong.push(`${where} asks ${p.key} "${p.prefix}${name}" (${p.node}), which ${p.ts} asked() does not answer`);
      }
    }
    if (p.store !== null) {
      for (const [name, where] of literals(s, pionFiles, new RegExp(`\\b${p.store}\\(\\s*"([^"]+)"`, "g"))) {
        if (!storeHas(s["src/store"]!, name)) {
          wrong.push(`${where} asks ${p.key} "store.${name}" (${p.store}), no method of station/src/store/`);
        }
      }
    }
  }

  const checkTell = (name: string, index: number, text: string, keyExpr: string, verb: string) => {
    const line = text.slice(0, index).split("\n").length;
    const where = `${name}:${line}`;
    if (pseudoToldByKey.has(keyExpr)) {
      if (!pseudoToldByKey.get(keyExpr)!.has(verb)) {
        wrong.push(`${where} tells ${keyExpr} "${verb}", which its TS handler does not handle`);
      }
    } else if (!toldCases.has(verb)) {
      wrong.push(`${where} tells "${verb}", which mb-actor.ts told() does not handle`);
    }
  };
  for (const name of pionFiles) {
    const text = s[name]!;
    for (const m of text.matchAll(/\btell\(\s*[^,]+,\s*([^,]+),\s*"([^"]+)"\s*,/g)) {
      checkTell(name, m.index!, text, m[1]!.trim(), m[2]!);
    }
    for (const m of text.matchAll(/\btell\(\s*([^,]+),\s*"([^"]+)"\s*,(?!\s*")/g)) {
      checkTell(name, m.index!, text, m[1]!.trim(), m[2]!);
    }
  }

  // Tight lower bounds on Pion `--sessions` contract extraction so silent regex regressions fail loudly.
  assert.ok(rpcCalls.size >= 14, `Pion --sessions rpc_k calls read: ${rpcCalls.size}`);
  return wrong;
}

test("every Pion --sessions RPC, store, deps, agent_do and tell is handled in Node", () => {
  const wrong = pionSessionsWrong(pionSessionsSources());
  assert.deepEqual(wrong, [], wrong.join("\n"));
});

test("Pion --sessions source discovery fails loudly on missing packages root or missing required package", () => {
  assert.throws(
    () => pionSessionsSources(join(pionStationPkgs, "__definitely_missing_root__")),
    /directory missing/,
  );
  // Existing directory that lacks `sessions_core` and `reader_sessions` must also throw.
  assert.throws(
    () => pionSessionsSources(station),
    /required Pion package/,
  );
});

test("Pion --sessions matcher negative 1: catches real gen.rpc_k(host, key, ...), rpc_direct_k, store_direct_k, and 2-arg rpc_k for agent-only node.* and missing \"t\"", () => {
  const base = pionSessionsSources();
  const s1: Sources = {
    ...base,
    "pion/sessions_actors/synth.pion": [
      'gen.rpc_k(host, a.key, "node.noSuchMethod", [], mirror, k)',
      'gen.rpc_k(host, "literal-key", "node.holding", [], mirror, k)',
      'rpc_k(a.key, "t", [])',
      'self.rpc_direct_k(a.key, "node.noSuchDirect", [], k)',
      'self.rpc_direct_k(a.key, "agent.noSuchDirectAgent", [], k)',
      'self.store_direct_k(a.key, "noSuchDirectStore", [], k)',
    ].join("\n"),
  };
  const wrong1 = pionSessionsWrong(s1);
  assert.ok(wrong1.some((w) => w.includes('"node.noSuchDirect"')), wrong1.join("\n"));
  assert.ok(wrong1.some((w) => w.includes('"agent.noSuchDirectAgent"')), wrong1.join("\n"));
  assert.ok(wrong1.some((w) => w.includes('"noSuchDirectStore"')), wrong1.join("\n"));
  assert.ok(wrong1.some((w) => w.includes('"node.noSuchMethod"')), wrong1.join("\n"));
  assert.ok(wrong1.some((w) => w.includes('"node.holding"') && w.includes("only its agent block")), wrong1.join("\n"));
  assert.ok(!wrong1.some((w) => w.includes('"literal-key"')), `literal key must not be misparsed as RPC fn: ${wrong1.join("\n")}`);
  const mbActor = base["src/sessions/mb-actor.ts"]!;
  const wrong2 = pionSessionsWrong({ ...s1, "src/sessions/mb-actor.ts": mbActor.replace(/^ {4}if \(f === "t"\) return .*\n/m, "") });
  assert.ok(wrong2.some((w) => w.includes('asks "t"')), wrong2.join("\n"));
});

test("Pion --sessions matcher negative 2: catches agent_do_k calling MbActor or driver methods", () => {
  const base = pionSessionsSources();
  const s: Sources = {
    ...base,
    "pion/sessions_actors/synth.pion": 'agent_do_k(a, g, "asked", [])\nagent_do_k(a, g, "adopt", [])\n',
  };
  const wrong = pionSessionsWrong(s);
  assert.ok(wrong.some((w) => w.includes('calls agent_do_k "asked"')), wrong.join("\n"));
  assert.ok(wrong.some((w) => w.includes('calls agent_do_k "adopt"')), wrong.join("\n"));
});

test("Pion --sessions matcher negative 3: catches unknown jnode_k/jstore_k/lnode_k/rnode_k/rstore_k", () => {
  const base = pionSessionsSources();
  const s: Sources = {
    ...base,
    "pion/sessions_jobs_live/synth.pion": 'jnode_k("noSuchJobOp", [])\njstore_k("noSuchJobStore", [])\nlnode_k("noSuchLiveOp", [])\n',
    "pion/sessions_remote/synth.pion": 'rnode_k("noSuchRemoteOp", [])\nrstore_k("noSuchRemoteStore", [])\n',
  };
  const wrong = pionSessionsWrong(s);
  assert.ok(wrong.some((w) => w.includes('"node.noSuchJobOp"')), wrong.join("\n"));
  assert.ok(wrong.some((w) => w.includes('"store.noSuchJobStore"')), wrong.join("\n"));
  assert.ok(wrong.some((w) => w.includes('"noSuchLiveOp"')), wrong.join("\n"));
  assert.ok(wrong.some((w) => w.includes('"node.noSuchRemoteOp"')), wrong.join("\n"));
  assert.ok(wrong.some((w) => w.includes('"store.noSuchRemoteStore"')), wrong.join("\n"));
});

test("Pion --sessions matcher negative 4: catches unknown actor and pseudo-actor tells (2-arg and 3-arg)", () => {
  const base = pionSessionsSources();
  const s: Sources = {
    ...base,
    "pion/sessions_actors/synth.pion": [
      'gen.tell(host, a.key, "noSuchActorTell", [])',
      'gen.tell(host, jobs_key, "noSuchJobTell", [])',
      'tell(a.key, "noSuchShortTell", [])',
    ].join("\n"),
  };
  const wrong = pionSessionsWrong(s);
  assert.ok(wrong.some((w) => w.includes('tells "noSuchActorTell"')), wrong.join("\n"));
  assert.ok(wrong.some((w) => w.includes('tells jobs_key "noSuchJobTell"')), wrong.join("\n"));
  assert.ok(wrong.some((w) => w.includes('tells "noSuchShortTell"')), wrong.join("\n"));
});

// ── Agents stdout protocol contract (`lines`/`exit`/`closed`/`left`/`frozen`/`ended`/`replayed`/`ownReplayed`) ──

const AGENTS_STDOUT_FRAMES = ["lines", "exit", "closed", "left", "frozen", "ended", "replayed", "ownReplayed"] as const;

function agentsStdoutWrong(mbAgentsTs: string): string[] {
  const saidMethod = method(mbAgentsTs, "  #said(said: Json) {");
  const wrong: string[] = [];
  for (const frame of AGENTS_STDOUT_FRAMES) {
    if (!new RegExp(`\\bsaid\\??\\.${frame}\\b`).test(saidMethod)) {
      wrong.push(`mb-agents.ts #said() does not handle agent stdout frame "${frame}"`);
    }
  }
  return wrong;
}

test("Agents stdout protocol: mb-agents.ts #said() handles all 8 frame types and negative check catches removal", () => {
  const mbAgentsTs = read(join(station, "src", "agents", "mb-agents.ts"));
  assert.deepEqual(agentsStdoutWrong(mbAgentsTs), []);
  const broken = mbAgentsTs.replaceAll("said?.ownReplayed", "said?.removedFrame").replaceAll("said.ownReplayed", "said.removedFrame");
  assert.notEqual(broken, mbAgentsTs);
  const wrong = agentsStdoutWrong(broken);
  assert.ok(wrong.some((w) => w.includes('"ownReplayed"')), wrong.join("\n"));
});

// ── MB reader source SHA-256 drift manifest (alerts when MoonBit reader changes without Pion sync) ──

const MB_READER_SHA256_MANIFEST: Record<string, string> = {
  "actors.mbt": "82c9c5afbae46b3975d8816679d30e0127634ad2a9667268f6dbe2dea8e9a0bf",
  "actor_base.mbt": "185a1015d8625ff90beea0c68d7f1f352b1f132085efa561799872e029393344",
  "actor_store.mbt": "ff1a2ed085f37d4db234e76c29aea86f563aaa219bd5b148871064cd602313cd",
  "actor_run.mbt": "656822b03a70d9a0e772b36bc92bf4b1b84e296089ecf8d8da26900952dfe0a5",
  "jobs.mbt": "736b7df74c87a85c343e343afd9666a46d9c161a3cbe93ef3fe29b01ef90b818",
  "live.mbt": "adca5f31d70d745251d1768939d282269f67114bca3e565d598bfd12993f2171",
  "remote.mbt": "d8573ab63fd84f6d89b47d7a427c3a3a5c592282af00f9b94e6d713a32f4bc7a",
  "remote_files.mbt": "b09322f49e0f45576eade817b29cd4df2808580374582a463c7e84ba04228c53",
  "remote_source.mbt": "f71396b91d4b85079e3834e9de3315a8dc303db64a6a9056633f3f23486ac21e",
  "remote_target.mbt": "fa75ddbceb15095dd894c32434b10f46bf3548efa8101048a24ff52e578fc2dc",
  "dirsync.mbt": "204b1f22ad9c7dea337572cfc0d4299fc4aed4e61d2c3624f1339b4ba3a32ddd",
  "dirsync_source.mbt": "6ed43f5b6c8103122e204d905a861414c839008153310603fae09f7ceb32c920",
  "agents.mbt": "be1e2d950cc9d2b6355b7616a3c1339ad03406b4a80091bb2b1cf023727365c9",
  "agents_codex.mbt": "6373ec1a5bab52bf12abe59206c081204fd3384d5a48fd457d0ad88e69f6a269",
  "agents_own.mbt": "af611cab4213a0f4a134d65a33435c344115c19f4777c1349016a38497d5e6ae",
};

test("MB reader SHA-256 drift manifest matches all 15 ported station/mb/src/reader/*.mbt files", () => {
  const drifted: string[] = [];
  for (const [file, expected] of Object.entries(MB_READER_SHA256_MANIFEST)) {
    const actual = createHash("sha256").update(readFileSync(join(reader, file))).digest("hex");
    if (actual !== expected) {
      drifted.push(`${file}: expected ${expected}, got ${actual} (sync Pion packages/sessions_* and update manifest)`);
    }
  }
  assert.deepEqual(drifted, [], drifted.join("\n"));
});
