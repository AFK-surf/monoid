// What the launcher kept of what it did to recover (station/native/launcher/src/lifecycle.rs `record`), said by the
// station that comes up next (src/ops/launcher-events.ts): each event once, with only its own fields, at its level.
import assert from "node:assert/strict";
import { existsSync, mkdirSync, readdirSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import { launcherEventOf, reportLauncherEvents } from "../src/ops/launcher-events.ts";
import { tempDir } from "./temp-dir.ts";

function dataWith(lines: string[] | null): string {
  const data = tempDir(join(tmpdir(), "launcher-events-"));
  mkdirSync(join(data, "run"));
  if (lines !== null) writeFileSync(join(data, "run", "launcher-events.jsonl"), lines.join("\n") + "\n");
  return data;
}

function heard() {
  const said: { level: string; message: string; fields: Record<string, unknown> }[] = [];
  return { said, emit: (level: "error" | "warn", message: string, fields: Record<string, unknown>) => void said.push({ level, message, fields }) };
}

const HUNG = { at: 1795091426000, kind: "node_hung_killed", level: "error", pid: 4242, version: "0.1.1000", uptimeMs: 3600000, heartbeatTimeoutMs: 90000, healthAgeMs: 92000, rssBytes: 734003200, openFds: 812, heldMaxMs: 1200, front: "ok", presenceOnline: true, relayConflict: false };

test("each event is said once at its level, and the file is gone", async () => {
  const data = dataWith([JSON.stringify(HUNG), JSON.stringify({ at: 1, kind: "front_gone", level: "warn", retries: 2 })]);
  const { said, emit } = heard();
  assert.equal(await reportLauncherEvents(data, emit), 2);
  const { level: _, ...fields } = HUNG;
  assert.deepEqual(said, [
    { level: "error", message: "node_hung_killed", fields },
    { level: "warn", message: "front_gone", fields: { at: 1, kind: "front_gone", retries: 2 } },
  ]);
  assert.deepEqual(readdirSync(join(data, "run")), [], "neither the file nor the one taken is left");
  assert.equal(await reportLauncherEvents(data, emit), 0, "said once");
  assert.equal(said.length, 2);
});

test("no file: nothing said", async () => {
  const data = dataWith(null);
  const { said, emit } = heard();
  assert.equal(await reportLauncherEvents(data, emit), 0);
  assert.deepEqual(said, []);
  assert.equal(await reportLauncherEvents(join(data, "none"), emit), 0, "nor a run/ at all");
});

test("lines that are not events are passed over", async () => {
  const data = dataWith(["{\"at\":1,\"kind\":\"node_cra", "", "[1,2]", "null", "{\"at\":2}", JSON.stringify({ at: 3, kind: "handoff_failed", level: "warn", reason: "the new station exited with 1 before it was ready" })]);
  const { said, emit } = heard();
  assert.equal(await reportLauncherEvents(data, emit), 1);
  assert.deepEqual(said, [{ level: "warn", message: "handoff_failed", fields: { at: 3, kind: "handoff_failed", reason: "the new station exited with 1 before it was ready" } }]);
  assert.equal(existsSync(join(data, "run", "launcher-events.jsonl")), false);
});

test("only the launcher's own fields are said", () => {
  const event = launcherEventOf(JSON.stringify({ at: 5, kind: "node_crashed", level: "error", pid: 7, how: "was ended by signal 9", taken: true, failures: 0, home: "/Users/someone", token: "secret", nested: { a: 1 } }));
  assert.deepEqual(event, { level: "error", kind: "node_crashed", fields: { at: 5, kind: "node_crashed", pid: 7, how: "was ended by signal 9", taken: true, failures: 0 } });
});

test("with no level said, a kill or a crash is an error and the rest warnings", () => {
  const level = (kind: string, said?: string) => launcherEventOf(JSON.stringify({ at: 1, kind, ...(said ? { level: said } : {}) }))?.level;
  assert.deepEqual(["node_hung_killed", "node_crashed", "front_hung_killed", "front_gone", "handoff_failed", "retiring_killed", "something_new"].map((k) => level(k)), ["error", "error", "error", "warn", "warn", "warn", "warn"]);
  assert.equal(level("front_gone", "error"), "error", "as the launcher said it");
  assert.equal(level("node_crashed", "info"), "error", "a level it does not know: by its kind");
});
