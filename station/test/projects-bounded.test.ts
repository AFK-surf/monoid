import assert from "node:assert/strict";
import { test } from "node:test";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { Store } from "../src/store/store.ts";

test("projects.names and renameProjectInWorkspace use partial indexes, resist starvation from >1000 other-ws/archived rows, and update locked threads on rename", () => {
  const dir = mkdtempSync(join(tmpdir(), "sf-projects-bounded-"));
  const store = Store.open(join(dir, "stillfail.db"));
  try {
    const addThread = (key: string, ws: string, project: string | null, tags: string[] | null, opts?: { archived?: boolean; hidden?: boolean; left?: boolean; locked?: boolean }) => {
      store.insertSession({
        key,
        connect: "chat",
        runtime: "claude",
        profile: "p1",
        workspace: join(dir, key),
        token: `tok-${key}`,
        createdAt: 1000,
        lastActiveAt: 1000,
        ws,
      });
      const t = store.openThread("chat", "CHAT", `${key}.000001`, null, "a@example.com");
      store.joinThread(t.id, key, "chat");
      if (project !== null || tags !== null) {
        store.setThreadClassification(t.id, {
          ...(project !== null ? { project } : {}),
          ...(tags !== null ? { tags } : {}),
          ...(opts?.locked ? { lock: true } : {}),
          force: true,
        });
      }
      if (opts?.archived) store.db.prepare("UPDATE sessions SET archived_at = 2000 WHERE key = ?").run(key);
      if (opts?.hidden) store.db.prepare("UPDATE threads SET hidden_at = 2000 WHERE id = ?").run(t.id);
      if (opts?.left) store.db.prepare("UPDATE thread_sessions SET left_at = 2000 WHERE thread = ? AND session = ?").run(t.id, key);
      return t.id;
    };

    // Seed 1,050 other-workspace / archived / hidden / left threads with project & tags so naive LIMIT-before-filter would starve ws-a!
    for (let i = 0; i < 600; i++) {
      addThread(`s-other-${i}`, "ws-other", "aaa-noise", ["noise-tag"]);
    }
    for (let i = 0; i < 300; i++) {
      addThread(`s-arch-${i}`, "ws-a", "bbb-archived", ["arch-tag"], { archived: true });
    }
    for (let i = 0; i < 100; i++) {
      addThread(`s-hid-${i}`, "ws-a", "ccc-hidden", ["hid-tag"], { hidden: true });
    }
    for (let i = 0; i < 50; i++) {
      addThread(`s-left-${i}`, "ws-a", "ddd-left", ["left-tag"], { left: true });
    }

    // Seed 5 active threads in ws-a (including 1 project_locked = 1 thread).
    const lockedId = addThread("s-proj-0", "ws-a", "still.fail", ["bug", "ci"], { locked: true });
    addThread("s-proj-1", "ws-a", "still.fail", ["perf"]);
    addThread("s-proj-2", "ws-a", "still.fail", ["bug", "ci"]);
    addThread("s-proj-3", "ws-a", "farview", ["perf"]);
    addThread("s-proj-4", "ws-a", "farview", ["bug", "ci"]);

    // Verify EXPLAIN QUERY PLAN uses partial indexes.
    const planSkip = store.db.prepare(
      `EXPLAIN QUERY PLAN
       SELECT t.project AS project
       FROM threads t INDEXED BY threads_project
       WHERE t.project IS NOT NULL AND t.project != '' AND t.project > ?
       ORDER BY t.project
       LIMIT 1`,
    ).all("") as { detail: string }[];
    assert.ok(planSkip.some((r) => r.detail.includes("threads_project")), `expected threads_project index, got: ${JSON.stringify(planSkip)}`);

    const planTags = store.db.prepare(
      `EXPLAIN QUERY PLAN
       SELECT t.tags
       FROM threads t INDEXED BY threads_tags
       WHERE t.tags IS NOT NULL AND t.hidden_at IS NULL
         AND EXISTS (SELECT 1 FROM thread_sessions m JOIN sessions s ON s.key = m.session WHERE m.thread = t.id AND m.left_at IS NULL AND s.archived_at IS NULL AND s.ws = ?)
       ORDER BY t.id DESC
       LIMIT 400`,
    ).all("ws-a") as { detail: string }[];
    assert.ok(planTags.some((r) => r.detail.includes("threads_tags")), `expected threads_tags index, got: ${JSON.stringify(planTags)}`);

    const planRename = store.db.prepare(
      `EXPLAIN QUERY PLAN
       SELECT t.id
       FROM threads t INDEXED BY threads_project
       WHERE t.project = ? AND t.project IS NOT NULL AND t.project != '' AND t.id > ?
         AND EXISTS (SELECT 1 FROM thread_sessions m JOIN sessions s ON s.key = m.session WHERE m.thread = t.id AND s.ws = ?)
       ORDER BY t.id
       LIMIT 500`,
    ).all("still.fail", 0, "ws-a") as { detail: string }[];
    assert.ok(planRename.some((r) => r.detail.includes("threads_project")), `expected threads_project index, got: ${JSON.stringify(planRename)}`);

    // Skip-scan & SQL-filtered tags find ws-a's projects and tags cleanly despite 1,050 noise rows!
    const names = store.workspaceProjectNames("ws-a", "ws-a", 10);
    assert.deepEqual(names.projects, [
      { name: "still.fail", count: 3 },
      { name: "farview", count: 2 },
    ]);
    assert.deepEqual(names.tags, [
      { name: "bug", count: 3 },
      { name: "ci", count: 3 },
      { name: "perf", count: 2 },
    ]);

    // Limit is respected.
    const limited = store.workspaceProjectNames("ws-a", "ws-a", 1);
    assert.equal(limited.projects.length, 1);
    assert.equal(limited.tags.length, 1);

    // Rename updates ALL matching ws-a threads (including lockedId, keeping project_locked = 1) with small batchLimit pagination,
    // and never touches ws-other's threads.
    addThread("s-other-same-name", "ws-other", "still.fail", null);
    const ren = store.renameProjectInWorkspace("ws-a", "ws-a", "still.fail", "monoid-station", 1);
    assert.equal(ren.updated, 3);
    assert.equal(ren.skippedLocked, 0);
    const afterLocked = store.getThread(lockedId)!;
    assert.equal(afterLocked.project, "monoid-station");
    assert.equal(afterLocked.projectLocked, true);
    const otherNames = store.workspaceProjectNames("ws-other", "ws-a", 10);
    assert.ok(otherNames.projects.some((p) => p.name === "still.fail" && p.count === 1));
  } finally {
    store.close();
    rmSync(dir, { recursive: true, force: true });
  }
});

test("workspaceProjectNames is never starved by 500 lex-earlier other-workspace projects and returns exact count > 1000", () => {
  const dir = mkdtempSync(join(tmpdir(), "sf-projects-exact-"));
  const store = Store.open(join(dir, "stillfail.db"));
  try {
    const add = (key: string, ws: string, project: string) => {
      store.insertSession({
        key,
        connect: "chat",
        runtime: "claude",
        profile: "p1",
        workspace: join(dir, key),
        token: `tok-${key}`,
        createdAt: 1000,
        lastActiveAt: 1000,
        ws,
      });
      const t = store.openThread("chat", "CHAT", `${key}.000001`, null, "a@example.com");
      store.joinThread(t.id, key, "chat");
      store.setThreadClassification(t.id, { project, force: true });
    };
    // 500 distinct lex-earlier projects in ws-other
    for (let i = 0; i < 500; i++) {
      add(`o-${i}`, "ws-other", `aaa-${String(i).padStart(4, "0")}`);
    }
    // 1,001 active threads in ws-a with a lex-later project name
    for (let i = 0; i < 1001; i++) {
      add(`a-${i}`, "ws-a", "zzz-target");
    }

    assert.equal(store.hasActiveProjectInWorkspace("ws-a", "ws-a", "zzz-target"), true);
    assert.equal(store.hasActiveProjectInWorkspace("ws-a", "ws-a", "aaa-0001"), false);
    const res = store.workspaceProjectNames("ws-a", "ws-a", 10);
    assert.deepEqual(res.projects, [{ name: "zzz-target", count: 1001 }]);
  } finally {
    store.close();
    rmSync(dir, { recursive: true, force: true });
  }
});
