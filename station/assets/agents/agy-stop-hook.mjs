// A Stop hook of Antigravity CLI's: notes whether the session's conversation still has background work running
// (subagents, background commands, schedules) when an execution loop stops (`fullyIdle: false` in agy's protojson
// StopHookArgs), so the station does not evict the idle `agy acp` process while that work runs on.
// Writes to <STILLFAIL_AGY_STATE_DIR>/<conversationId>.json (unset for probes, text-only sessions, or processes
// outside the station), one file per conversation so a subagent's own Stop hook never races with or overwrites its
// parent's state. Always answers `{}` so it never blocks Antigravity CLI from stopping.
import { mkdirSync, readFileSync, renameSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";

function finish() {
  process.stdout.write("{}");
  process.exit(0);
}

const stateDir = process.env.STILLFAIL_AGY_STATE_DIR;
if (!stateDir) finish();

let input;
try {
  input = JSON.parse(readFileSync(0, "utf8"));
} catch {
  finish();
}
if (input === null || typeof input !== "object") finish();
if (input.hookEventName !== "Stop") finish();
if (typeof input.conversationId !== "string" || !/^[a-zA-Z0-9_-]+$/.test(input.conversationId)) finish();
if (typeof input.fullyIdle !== "boolean") finish();

try {
  mkdirSync(stateDir, { recursive: true });
  const file = join(stateDir, `${input.conversationId}.json`);
  const tmp = `${file}.${process.pid}.tmp`;
  const payload = JSON.stringify({ fullyIdle: input.fullyIdle, at: Date.now() });
  writeFileSync(tmp, payload);
  try {
    renameSync(tmp, file);
  } catch {
    try {
      writeFileSync(file, payload);
    } finally {
      rmSync(tmp, { force: true });
    }
  }
} catch {}

finish();
