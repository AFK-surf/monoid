// What the shipped reader's session actors (station/mb/src/reader, `stillfail-reader --sessions`) ask of Node, read
// from both sources as they are: every RPC, tell, dependency, agent call and store call an actor makes is one Node's
// shell of the actors (station/src/sessions/mb-actor.ts, actor.ts's SessionDeps, station/src/agents/,
// station/src/store/) answers. This is the reader ↔ Node contract every release runs on (station/AGENTS.md); the
// frozen whole station in MoonBit (station_main) is held apart, by mb-station-contracts.test.ts.
import assert from "node:assert/strict";
import { readdirSync, readFileSync, statSync } from "node:fs";
import { join, relative } from "node:path";
import { fileURLToPath } from "node:url";
import { test } from "node:test";

const station = fileURLToPath(new URL("..", import.meta.url));
const mb = join(station, "mb", "src");

const read = (p: string) => readFileSync(p, "utf8");
const walk = (dir: string, keep: (p: string) => boolean): string[] =>
  readdirSync(dir).flatMap((n) => {
    const p = join(dir, n);
    return statSync(p).isDirectory() ? walk(p, keep) : keep(p) ? [p] : [];
  });
const tsSources = (dir: string) => walk(dir, (p) => p.endsWith(".ts") && !p.endsWith(".test.ts")).map(read).join("\n");

/// Each literal's first `file:line` among `files`.
function scanLiterals(files: string[], re: RegExp): Map<string, string> {
  const out = new Map<string, string>();
  for (const f of files) {
    const text = read(f);
    for (const m of text.matchAll(re)) {
      const name = m[1]!;
      if (!out.has(name)) out.set(name, `${relative(station, f)}:${text.slice(0, m.index!).split("\n").length}`);
    }
  }
  return out;
}

/// The `case "…":` literals of a TypeScript snippet.
function tsSwitchCases(snippet: string): Set<string> {
  const out = new Set<string>();
  for (const m of snippet.matchAll(/\bcase\s+"([^"]+)"\s*:/g)) out.add(m[1]!);
  return out;
}

test("every RPC and tell that reader actors make is handled in Node mb-actor.ts", () => {
  const readerDir = join(mb, "reader");
  const actorFiles = [join(readerDir, "actor_base.mbt"), join(readerDir, "actor_run.mbt")];
  const mbActorTs = read(join(station, "src", "sessions", "mb-actor.ts"));
  const actorTs = read(join(station, "src", "sessions", "actor.ts"));

  // 1. self.rpc(..., "node.<name>"): mb-actor.ts asked()
  const nodeRpcs = scanLiterals(actorFiles, /\bself\.rpc\(\s*[^,]+,\s*"node\.([^"]+)"/g);
  assert.ok(nodeRpcs.size >= 20, `reader node.* RPCs read: ${nodeRpcs.size} (expected >= 20)`);
  const tsAskedStart = mbActorTs.indexOf("async asked(");
  assert.ok(tsAskedStart >= 0, "mb-actor.ts has no async asked()");
  const tsAskedEnd = mbActorTs.indexOf("\n  #words(", tsAskedStart);
  assert.ok(tsAskedEnd > tsAskedStart, "mb-actor.ts has no #words() after asked()");
  const tsAskedCases = tsSwitchCases(mbActorTs.slice(tsAskedStart, tsAskedEnd));

  // 2. self.tell(..., "node.<name>" | "chat.<name>" | "log"): mb-actor.ts told()
  const actorTells = scanLiterals(actorFiles, /\bself\.tell\(\s*[^,]+,\s*"([^"]+)"/g);
  assert.ok(actorTells.size >= 3, `reader actor tells read: ${actorTells.size} (expected >= 3)`);
  const tsToldStart = mbActorTs.indexOf("told(f: string");
  assert.ok(tsToldStart >= 0, "mb-actor.ts has no told()");
  const tsToldCases = tsSwitchCases(mbActorTs.slice(tsToldStart, tsAskedStart));

  // 3. self.deps(..., "<name>"): actor.ts SessionDeps or mb-actor.ts
  const depsCalls = scanLiterals(actorFiles, /\bself\.deps\(\s*[^,]+,\s*"([^"]+)"/g);
  assert.ok(depsCalls.size >= 15, `reader deps.* calls read: ${depsCalls.size} (expected >= 15)`);
  const tsDepsTypeStart = actorTs.indexOf("export type SessionDeps =");
  assert.ok(tsDepsTypeStart >= 0, "actor.ts has no SessionDeps");
  const tsDepsText = `${actorTs.slice(tsDepsTypeStart)}\n${mbActorTs}`;

  // 4. self.agent_do(..., "<name>"): mb-actor.ts or station/src/agents/
  const agentCalls = scanLiterals(actorFiles, /\bself\.agent_do\(\s*[^,]+,\s*[^,]+,\s*"([^"]+)"/g);
  assert.ok(agentCalls.size >= 10, `reader agent.* calls read: ${agentCalls.size} (expected >= 10)`);
  const tsAgentsText = `${mbActorTs}\n${tsSources(join(station, "src", "agents"))}`;

  // 5. self.store(..., "<name>"): mb-actor.ts, actor.ts or station/src/store/
  const storeCalls = scanLiterals(actorFiles, /\bself\.store\(\s*[^,]+,\s*"([^"]+)"/g);
  assert.ok(storeCalls.size >= 20, `reader store.* calls read: ${storeCalls.size} (expected >= 20)`);
  const tsStoreText = `${mbActorTs}\n${actorTs}\n${tsSources(join(station, "src", "store"))}`;

  const wrong: string[] = [];
  const need = (ok: boolean, why: string) => {
    if (!ok) wrong.push(why);
  };
  for (const [name, where] of nodeRpcs) need(tsAskedCases.has(name), `${where} calls self.rpc(..., "node.${name}"), unhandled in station/src/sessions/mb-actor.ts asked()`);
  for (const [name, where] of actorTells) need(tsToldCases.has(name), `${where} calls self.tell(..., "${name}"), unhandled in station/src/sessions/mb-actor.ts told()`);
  for (const [name, where] of depsCalls) need(new RegExp(`\\b${name}\\??\\s*[(:]`).test(tsDepsText), `${where} calls self.deps(..., "${name}"), missing from SessionDeps / mb-actor.ts`);
  for (const [name, where] of agentCalls) {
    need(tsAskedCases.has(name) || new RegExp(`\\b${name}\\??\\s*\\(`).test(tsAgentsText), `${where} calls self.agent_do(..., "${name}"), unhandled in mb-actor.ts or station/src/agents/`);
  }
  for (const [name, where] of storeCalls) need(new RegExp(`\\b${name}\\??\\s*\\(`).test(tsStoreText), `${where} calls self.store(..., "${name}"), missing in mb-actor.ts / station/src/store/`);
  assert.deepEqual(wrong, [], wrong.join("\n"));
});
