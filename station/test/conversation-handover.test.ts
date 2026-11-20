import assert from "node:assert/strict";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import { DatabaseSync } from "node:sqlite";
import { sessionKey } from "../src/sessions/hub.ts";
import { importRows, newCtx } from "../src/store/handover.ts";
import { Store } from "../src/store/store.ts";
import { backfillConversationsStep } from "../src/sessions/conversation-backfill.ts";
import { message } from "./hub-fakes.ts";
import { WS, A, B, world, endTurn } from "./move-world.ts";

test("two-agent conversation moves together and preserves conv across round-trip A -> B -> A", async () => {
  const w = world();
  const a = w.get(A);
  const b = w.get(B);
  const first = message({ text: "<@UBOT> hi" });
  await a.connects.receive("cl", { type: "message", message: first });
  await a.connects.receive("gpt", { type: "message", message: first });
  const cl = sessionKey("cl", first.channel, first.threadTs);
  const gpt = sessionKey("gpt", first.channel, first.threadTs);
  await endTurn(a, cl);
  await endTurn(a, gpt, "codex");

  const anchor = a.rig.store.conversationOf(cl);
  assert.equal(a.rig.store.conversationOf(gpt), anchor);
  assert.deepEqual(a.moves.handover.together(cl), [cl, gpt].sort());
  assert.deepEqual(a.moves.handover.together(gpt), [cl, gpt].sort());
  assert.equal(a.moves.handover.chatOf(cl), a.moves.handover.chatOf(gpt));

  const out = await a.moves.scheduler.move(WS, B, { module: "chats", item: cl });
  await w.quiet();
  assert.equal(out.failed, null, JSON.stringify(out));
  assert.equal(b.rig.store.conversationOf(cl), anchor);
  assert.equal(b.rig.store.conversationOf(gpt), anchor);
  assert.deepEqual(b.rig.store.membersOf(anchor).sort(), [cl, gpt].sort());

  // Move back from B to A.
  const back = await a.moves.scheduler.back(WS, B, { module: "chats", item: cl });
  await w.quiet();
  assert.equal(back.failed, null, JSON.stringify(back));
  assert.equal(a.rig.store.conversationOf(cl), anchor);
  assert.equal(a.rig.store.conversationOf(gpt), anchor);
  assert.deepEqual(a.rig.store.membersOf(anchor).sort(), [cl, gpt].sort());
});

test("handover import into an old station without sessions.conv drops conv cleanly; later upgrade restores grouping", () => {
  const dir = mkdtempSync(join(tmpdir(), "conv-old-handover-"));
  try {
    // Source store (new station with conv column).
    const src = Store.open(join(dir, "src.db"));
    const t = src.openThread("slack:T1", "C1", "1.0", "Slack thread", "U1");
    src.insertSession({
      key: "slack:cl:C1:1.0", connect: "cl", scope: "thread", runtime: "claude", profile: "cc",
      workspace: join(dir, "w1"), token: "tok-1", createdAt: 1000, lastActiveAt: 1000, ws: null,
    });
    src.insertSession({
      key: "slack:gpt:C1:1.0", connect: "gpt", scope: "thread", runtime: "codex", profile: "cx",
      workspace: join(dir, "w2"), token: "tok-2", createdAt: 2000, lastActiveAt: 2000, ws: null,
    });
    src.joinThread(t.id, "slack:cl:C1:1.0", "cl");
    src.joinThread(t.id, "slack:gpt:C1:1.0", "gpt");
    assert.equal(src.conversationOf("slack:gpt:C1:1.0"), "slack:cl:C1:1.0");

    // Export rows from source.
    const sessionRows = [
      ...src.chatPage("sessions", "slack:cl:C1:1.0", null, 10),
      ...src.chatPage("sessions", "slack:gpt:C1:1.0", null, 10),
    ];
    assert.equal(sessionRows.find((r) => r.key === "slack:gpt:C1:1.0")?.conv, "slack:cl:C1:1.0");

    // Target DB simulating an old station without the `conv` column.
    const dstPath = join(dir, "dst.db");
    const init = Store.open(dstPath);
    init.close();
    const raw = new DatabaseSync(dstPath);
    raw.exec("DROP INDEX IF EXISTS sessions_conv");
    raw.exec("DROP INDEX IF EXISTS sessions_conv_todo");
    raw.exec("DROP INDEX IF EXISTS sessions_conv_grouped");
    raw.exec("ALTER TABLE sessions DROP COLUMN conv");
    const colsBefore = (raw.prepare("SELECT name FROM pragma_table_info('sessions')").all() as { name: string }[]).map((x) => x.name);
    assert.equal(colsBefore.includes("conv"), false);

    // Import into old schema: `conv` is dropped cleanly by columnsOf().
    const ctx = newCtx({ from: A, here: B, fromData: dir, toData: dir, connects: {}, profiles: {}, ws: "" });
    const touched = { sessions: new Set<string>(), threads: new Set<number>() };
    importRows(raw, ctx, "sessions", sessionRows, touched);
    const imported = raw.prepare("SELECT key FROM sessions ORDER BY key").all() as { key: string }[];
    assert.deepEqual(imported.map((r) => r.key), ["slack:cl:C1:1.0", "slack:gpt:C1:1.0"].sort());

    // Also import the thread + thread_sessions so upgrade backfill can regroup them.
    const tRows = src.chatPage("threads", t.id, null, 10);
    importRows(raw, ctx, "threads", tRows, touched);
    const tsRows = src.chatPage("thread_sessions", t.id, null, 10, ["slack:cl:C1:1.0", "slack:gpt:C1:1.0"]);
    importRows(raw, ctx, "thread_sessions", tsRows, touched);
    raw.close();

    // Reopen with new Store (adds `conv` column) and run background backfill step.
    const upgraded = Store.open(dstPath);
    upgraded.showChat(["slack:cl:C1:1.0", "slack:gpt:C1:1.0"], null);
    const settled = new Set<number>();
    let after = "";
    for (;;) {
      const step = backfillConversationsStep(upgraded, after, settled);
      if (step.done || step.after === null) break;
      after = step.after;
    }
    assert.equal(upgraded.conversationOf("slack:cl:C1:1.0"), "slack:cl:C1:1.0");
    assert.equal(upgraded.conversationOf("slack:gpt:C1:1.0"), "slack:cl:C1:1.0");
    assert.deepEqual(upgraded.membersOf("slack:cl:C1:1.0").sort(), ["slack:cl:C1:1.0", "slack:gpt:C1:1.0"].sort());
    upgraded.close();
    src.close();
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});
