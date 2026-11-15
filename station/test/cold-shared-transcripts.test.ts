import assert from "node:assert/strict";
import { existsSync, mkdirSync, realpathSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { test } from "node:test";
import { sessionPlaces, transcriptSources } from "../src/read/transcript.ts";
import { ColdRooms } from "../src/sessions/cold.ts";
import { MANUAL, TRANSCRIPT_IN_USE } from "../src/store/store.ts";
import { Rig } from "./hub-fakes.ts";

test("packing a transcript only checks sessions that could share it", async () => {
  let rig!: Rig;
  const cold = new ColdRooms(() => rig.hub);
  rig = new Rig({ cold });
  try {
    const insert = (key: string, runtime: string, id: string) => {
      rig.store.insertSession({ key, connect: "cl", runtime, profile: runtime === "claude" ? "cc" : "cx", workspace: rig.dir,
        runtimeSessionId: id, token: key, createdAt: 1, lastActiveAt: 1 });
    };
    insert("target", "claude", "shared");
    rig.store.ranIn("target", "shared", "cc");
    rig.store.setArchived("target", true, MANUAL);
    const path = join(rig.config.profiles[0]!.home, "projects", "x", "shared.jsonl");
    mkdirSync(dirname(path), { recursive: true });
    writeFileSync(path, "{}\n");
    const canonical = realpathSync(path);
    // The same id in another runtime is a different transcript; a current id need not have its own history row yet.
    insert("other-runtime", "codex", "shared");
    for (let i = 0; i < 200; i++) {
      insert(`other-${i}`, "claude", `unrelated-${i}`);
      rig.store.ranIn(`other-${i}`, `unrelated-${i}`, "cc");
    }
    const visited: string[] = [];
    const sources = rig.store.runtimeSessionSources.bind(rig.store);
    rig.store.runtimeSessionSources = (key) => { visited.push(key); return sources(key); };
    assert.deepEqual(cold.historyFiles("target", true), [canonical]);
    assert.deepEqual(visited, ["target"], "unrelated sessions do not add transcript lookups");
    const plan = (rig.store.db.prepare(`EXPLAIN QUERY PLAN ${TRANSCRIPT_IN_USE}`).all("shared", "claude", "target") as { detail: string }[])
      .map((step) => step.detail);
    assert.ok(plan.some((step) => step.includes("SEARCH r USING INDEX runtime_sessions_by_id")), plan.join(" | "));
    assert.ok(plan.some((step) => step.includes("SEARCH s USING INDEX sessions_by_runtime_id")), plan.join(" | "));

    // An older runtime transcript still belongs to a shown chat after that chat switches runtime.
    insert("also-shared", "claude", "shared");
    rig.store.ranIn("also-shared", "shared", "cc");
    rig.store.setSessionRuntime("also-shared", "codex", "cx", false, null, null, null, null);
    rig.store.db.prepare("UPDATE runtime_sessions SET runtime = NULL WHERE session_key = ?").run("also-shared");
    assert.equal(rig.store.transcriptInUse("codex", "shared", "other-runtime"), false,
      "a current id already recorded for another runtime is not counted twice");
    rig.store.setRuntimeSessionId("also-shared", "different");
    assert.deepEqual(cold.historyFiles("target", true), [], "a shown session keeps the shared transcript hot");
    rig.store.setArchived("also-shared", true, MANUAL);
    assert.deepEqual(cold.historyFiles("target", true), [canonical], "an idle archived session does not keep it hot");
    rig.store.setRunning("also-shared", true);
    assert.deepEqual(cold.historyFiles("target", true), [], "an archived session at work still keeps it hot");
    rig.store.setRunning("also-shared", false);

    // A current transcript absent from runtime_sessions is still shared by the second session.
    insert("current-only", "claude", "shared");
    assert.deepEqual(cold.historyFiles("target", true), [], "a current id need not have a history row yet");
    assert.deepEqual(cold.historyFiles("target", false), [canonical], "history remains readable even while another uses it");
    rig.store.setArchived("current-only", true, MANUAL);
    assert.deepEqual(cold.historyFiles("target", true), [canonical]);
  } finally { await rig.close(); }
});

test("an archived session's transcripts are found off the station's thread, as they were on it, and packed without being looked for again", async () => {
  let rig!: Rig;
  const cold = new ColdRooms(() => rig.hub);
  rig = new Rig({ cold });
  try {
    rig.store.insertSession({ key: "target", connect: "cl", runtime: "claude", profile: "cc", workspace: rig.dir, runtimeSessionId: "main", token: "target", createdAt: 1, lastActiveAt: 1 });
    rig.store.ranIn("target", "main", "cc");
    rig.store.setArchived("target", true, MANUAL);
    const project = join(rig.config.profiles[0]!.home, "projects", "x");
    mkdirSync(join(project, "main", "subagents", "deep"), { recursive: true });
    writeFileSync(join(project, "main.jsonl"), "{}\n");
    writeFileSync(join(project, "main", "subagents", "a.jsonl"), "{}\n");
    writeFileSync(join(project, "main", "subagents", "deep", "b.jsonl"), "{}\n");
    writeFileSync(join(project, "main", "subagents", "note.txt"), "not a transcript\n");
    const config = rig.hub.config();
    let located = 0;
    rig.hub.live.locateAsync = async (key) => {
      located++;
      const row = rig.store.getSession(key)!;
      return { runtime: "claude", paths: transcriptSources(config.dataDir, config.profiles, rig.store.runtimeSessionSources(key), sessionPlaces(row)).paths };
    };
    const before = cold.historyFiles("target", false);
    assert.equal(before.length, 3);
    assert.deepEqual(await cold.historyFilesSoon("target", false), before);
    assert.deepEqual(await cold.historyFilesSoon("target", true), before);
    // Another shown session on the same transcript keeps it hot, as it did.
    rig.store.insertSession({ key: "other", connect: "cl", runtime: "claude", profile: "cc", workspace: rig.dir, runtimeSessionId: "main", token: "other", createdAt: 1, lastActiveAt: 1 });
    assert.deepEqual(await cold.historyFilesSoon("target", true), []);
    rig.store.setArchived("other", true, MANUAL);
    located = 0;
    assert.equal(await cold["packHistory"]("target", () => true), 0);
    assert.equal(located, 1, "found once, not again for each file packed");
    for (const path of before) assert.ok(existsSync(`${path}.zst`) && !existsSync(path), path);
    // And found again where they were put away, to be restored.
    assert.deepEqual(await cold.historyFilesSoon("target", false), before);
    // A transcript whose directory went after it was located is passed over, the others still found.
    const locate = rig.hub.live.locateAsync;
    rig.hub.live.locateAsync = async (key, signal) => {
      const at = (await locate(key, signal))!;
      return { ...at, paths: [join(rig.config.profiles[0]!.home, "projects", "gone", "old.jsonl"), ...at.paths] };
    };
    assert.deepEqual(await cold.historyFilesSoon("target", false), before);
  } finally { await rig.close(); }
});
