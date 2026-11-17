// mb/src/acp and mb/src/reader/agents_own.mbt: the program's reading of the ACP runtimes' (Antigravity CLI, Grok Build, Devin, Hermes Agent) output held to the TypeScript station's
// (test/reference/live.ts) line for line: the cases' file of what the TypeScript says (as_typescript_said_test.mbt,
// which the program's own tests hold it to) is what it says now; the cases through the program itself, written by a
// process under a real runner, alike; what a crash reads again of an output, alike.
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { test } from "node:test";
import { ACP, ACP_REPLAYS, said_file, written } from "./runtime-cases.ts";
import { replayedByProgram, throughProgram } from "./runtime-program.ts";

test("what the TypeScript says of the cases is what the program's tests hold it to", () => {
  assert.equal(readFileSync(said_file("acp"), "utf8"), written("acp"), "run `node test/runtime-cases.ts` in station/");
});

test("the cases through the program: its events and the lines Node reads, as the TypeScript's", async () => {
  await throughProgram("acp", ACP);
});

test("what a crash left of the output, read again by the program, as the TypeScript read it", async () => {
  await replayedByProgram("acp", ACP_REPLAYS);
});
