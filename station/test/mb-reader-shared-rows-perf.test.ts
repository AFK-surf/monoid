// D68 bulk readops parity, query-plan and scale regression tests for `shared_rows` / `listed_threads` / `said_of_batch` /
// `author_names_preloaded` / `original_runtime` prefetch (station/mb/src/readops/shared.mbt, shared_sql.mbt,
// chatparts.mbt, people.mbt).
import assert from "node:assert/strict";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import { digest } from "../../client/core-ts/src/digest.ts";
import { wall } from "../src/ops/fibers.ts";
import { mbReaderBinary } from "../src/read/mb-reader.ts";
import { Readers } from "../src/read/pool.ts";
import { Store, newMessage } from "../src/store/store.ts";
import { readersOf } from "./reference.ts";

const binary = mbReaderBinary();

test("D68 bulk readops matches TS reference 0-diff across all edge cases", { skip: binary === null ? "the MoonBit program is not built here" : false }, async () => {
  const data = mkdtempSync(join(tmpdir(), "mb-reader-d68-parity-"));
  writeFileSync(join(data, "config.json"), JSON.stringify({
    connects: [
      { id: "team-b", kind: "slack", slack: { botName: "BotB", team: { id: "TB", name: "Team B" } } },
      { id: "team-a", kind: "slack", slack: { botName: "BotA", team: { id: "TA", name: "Team A" } } },
      { id: "fs", kind: "feishu", feishu: { tenant: { name: "FeishuCo" } } },
    ],
    automaticDecisions: { completion: { enabled: true } },
  }));
  writeFileSync(join(data, "slack-names.json"), JSON.stringify({
    "u:TA:U1": { person: { name: "Alice", email: "alice@x", picture: "https://p/a.png" } },
    "u:TB:U2": { person: { name: "Bob", email: "bob@x" } },
    "c:TA:C1": { channel: "eng" },
  }));
  writeFileSync(join(data, "feishu-names.json"), JSON.stringify({
    "c:fs:oc_1": { channel: "Group One" },
  }));
  const store = Store.open(join(data, "stillfail.db"), join(data, "archive"));
  const db = store.db;
  const now = wall.now();
  const session = (key: string, extra: Record<string, unknown> = {}) =>
    store.insertSession({ key, connect: "chat", runtime: "claude", profile: "cc", workspace: "/w", token: key, createdAt: 1, lastActiveAt: 1000, ws: "w", ...extra } as Parameters<Store["insertSession"]>[0]);

  // Sessions with different waitingAsync states (job / led) and runtime histories.
  session("wait-job", { lastActiveAt: 9000, createdBy: "p@x", model: "opus" });
  session("wait-led", { lastActiveAt: 8900, createdBy: "p@x", model: "opus" });
  session("led-child-live", { lastActiveAt: 8800, createdBy: "p@x" });
  session("led-child-done", { lastActiveAt: 8700, createdBy: "p@x" });
  session("led-child-arch", { lastActiveAt: 8600, createdBy: "p@x" });
  session("no-wait", { lastActiveAt: 8500, createdBy: "p@x" });
  session("hist-orig", { lastActiveAt: 8400, runtime: "codex", model: "gpt" });
  session("hist-rs", { lastActiveAt: 8300, runtime: "codex", model: "gpt" });
  session("hist-fallback", { lastActiveAt: 8200, runtime: "grok", model: "g1" });
  session("multi-a", { lastActiveAt: 8100, connect: "team-b" });
  session("multi-b", { lastActiveAt: 8000, connect: "team-a" });
  session("arch-emoji", { lastActiveAt: 7900, createdBy: "p@x" });
  session("arch-quote", { lastActiveAt: 7800, createdBy: "p@x" });
  session("arch-space200", { lastActiveAt: 7700, createdBy: "p@x" });
  session("arch-nostate", { lastActiveAt: 7600, createdBy: "p@x" });

  db.prepare("UPDATE sessions SET original_runtime = 'claude' WHERE key = 'hist-orig'").run();
  db.prepare("UPDATE sessions SET original_runtime = NULL WHERE key IN ('hist-rs', 'hist-fallback')").run();
  db.prepare("INSERT INTO runtime_sessions(session_key, id, runtime, profile, at) VALUES ('hist-rs', 'rs1', 'dsh', 'p', 10), ('hist-rs', 'rs2', 'codex', 'p', 20)").run();

  // Jobs: one non-watch running (triggers waitingAsync), one watch running (must NOT trigger waitingAsync), one exited.
  db.prepare("INSERT INTO jobs(id,session_key,name,command,cwd,port,token,state,started_at,restarts,log,watch) VALUES ('j1','wait-job','build','true','/',NULL,'t1','running',100,0,'/dev/null',0)").run();
  db.prepare("INSERT INTO jobs(id,session_key,name,command,cwd,port,token,state,started_at,restarts,log,watch) VALUES ('j2','no-wait','watch-ci','true','/',NULL,'t2','running',100,0,'/dev/null',1)").run();
  db.prepare("INSERT INTO jobs(id,session_key,name,command,cwd,port,token,state,started_at,restarts,log,watch) VALUES ('j3','no-wait','done-job','true','/',NULL,'t3','exited',100,0,'/dev/null',0)").run();

  // Led chats: active led triggers waitingAsync; all_done / stopped / archived do not.
  db.prepare("UPDATE sessions SET archived_at = 5000 WHERE key = 'led-child-arch'").run();
  db.prepare("INSERT INTO opened_chats(child_station,child,parent_station,parent,key,title,created_at,led,state) VALUES ('','led-child-live','','wait-led','k1','Live child',1,1,'working')").run();
  db.prepare("INSERT INTO opened_chats(child_station,child,parent_station,parent,key,title,created_at,led,state) VALUES ('','led-child-done','','no-wait','k2','Done child',2,1,'all_done')").run();
  db.prepare("INSERT INTO opened_chats(child_station,child,parent_station,parent,key,title,created_at,led,state) VALUES ('','led-child-arch','','no-wait','k3','Arch child',3,1,'working')").run();

  let ts = 0;
  const say = (t: number, kind: "person" | "agent" | "station", author: string, text: string, extra: Record<string, unknown> = {}) => {
    const at = String(++ts);
    store.insertMessage({ ...newMessage(t, at, kind, author, text), at: now - 50_000 + ts * 10, ...extra } as ReturnType<typeof newMessage>);
    return Number(db.prepare("SELECT MAX(n) AS n FROM entries WHERE thread = ?").get(t)!.n);
  };
  const edit = (t: number, target: number, text: string, quotes: unknown[] = []) => {
    const n = Number(db.prepare("SELECT COALESCE(MAX(n), 0) AS n FROM entries WHERE thread = ?").get(t)!.n) + 1;
    db.prepare("INSERT INTO entries(thread, n, ts, kind, target, author_kind, author, text, quotes, at) VALUES (?, ?, ?, 'edit', ?, 'person', 'p@x', ?, ?, ?)").run(
      t, n, String(++ts), target, text, quotes.length ? JSON.stringify(quotes) : null, now - 40_000 + ts * 10,
    );
  };
  const chat = (key: string, title: string | null, members: string[], archive = false) => {
    const id = store.openThread("chat", "CHAT", key, title, null).id;
    db.prepare("UPDATE threads SET home = ? WHERE id = ?").run(members[0], id);
    for (const m of members) store.joinThread(id, m, "chat");
    if (archive) {
      db.prepare("UPDATE threads SET hidden_at = 6000, hidden_by = 'manual' WHERE id = ?").run(id);
      for (const m of members) db.prepare("UPDATE sessions SET archived_at = 6000, archived_by = 'manual' WHERE key = ?").run(m);
    }
    return id;
  };

  // Live chats with historical agent messages lacking agentIdentity.runtime
  const tJob = chat("wait-job", "Waiting Job", ["wait-job"]);
  say(tJob, "person", "p@x", "run build");
  say(tJob, "agent", "wait-job", "building...");

  const tLed = chat("wait-led", "Waiting Led", ["wait-led"]);
  say(tLed, "agent", "wait-led", "delegated");

  const tNoWait = chat("no-wait", "No Wait", ["no-wait"]);
  say(tNoWait, "person", "p@x", "status?");

  const tOrig = chat("hist-orig", "Hist Orig", ["hist-orig"]);
  say(tOrig, "agent", "hist-orig", "from original_runtime");

  const tRs = chat("hist-rs", "Hist RS", ["hist-rs"]);
  say(tRs, "agent", "hist-rs", "from runtime_sessions");

  const tFb = chat("hist-fallback", "Hist Fallback", ["hist-fallback"]);
  say(tFb, "agent", "hist-fallback", "from sessions.runtime");

  // Clear agent_identity on those 3 threads to simulate historical agent messages before per-message identity.
  db.prepare("UPDATE entries SET agent_identity = NULL WHERE thread IN (?, ?, ?)").run(tOrig, tRs, tFb);

  // Slack origin with multiple thread_sessions having different connects (team-b joined first, team-a second -> MIN is team-a).
  const slack = store.openThread("slack:TA", "C1", "2000.1", null, null).id;
  store.joinThread(slack, "multi-a", "team-b");
  store.joinThread(slack, "multi-b", "team-a");
  say(slack, "person", "U1", "hello from slack origin " + "x".repeat(320));
  const tMulti = chat("multi", null, ["multi-a", "multi-b"]);
  say(tMulti, "person", "p@x", "untitled chat with slack origin");

  // Archived chat with >200 chars + non-BMP emoji + leading whitespace + edit
  const tEmoji = chat("arch-emoji", null, ["arch-emoji"], true);
  const emojiMsg = say(tEmoji, "person", "p@x", "initial short text");
  edit(tEmoji, emojiMsg, "   \t " + "🚀".repeat(120) + "a".repeat(120) + "   ");

  // Archived chat with space right at code point 200 followed by non-space at 201 (must preserve space at 200!)
  const tSpace200 = chat("arch-space200", "Space 200", ["arch-space200"], true);
  say(tSpace200, "person", "p@x", "  " + "a".repeat(199) + "   tail-after-200");

  // Archived chat with whitespace-only text (\t\n\u3000) + quotes -> quotedOnly: true
  const tQuote = chat("arch-quote", "Quoted Arch", ["arch-quote"], true);
  const qMsg = say(tQuote, "person", "p@x", "will be edited to whitespace");
  edit(tQuote, qMsg, " \t\n\u3000 ", [{ author: "p@x", text: "quoted body", comment: "" }]);

  // Archived chat with missing thread_state row
  const tNoState = chat("arch-nostate", "No State", ["arch-nostate"], true);
  say(tNoState, "person", "p@x", "hi");
  say(tNoState, "agent", "arch-nostate", "yo");
  say(tNoState, "person", "p@x", "bye");
  db.prepare("DELETE FROM thread_state WHERE thread = ?").run(tNoState);

  const readers = (mb: string | null) => {
    const r = readersOf(data, mb);
    r.names.set("p@x", "Pat");
    return r;
  };
  const worker = readers(null);
  const program = readers(binary);
  const read = (r: Readers, op: string, args: unknown, lang: "zh" | "en") =>
    r.read(op, args, lang).then((t) => JSON.parse(t), (e: Error & { status?: number }) => ({ error: e.message, status: e.status }));
  const viewer = { email: "p@x", workspace: "w", home: true };

  const compareAll = async () => {
    const checks: [string, unknown][] = [
      ["sharedOf", { sessions: null, threads: null }],
      ["sharedOf", { sessions: ["wait-job", "hist-rs", "arch-emoji"], threads: [tMulti, tNoState] }],
      ["sharedChats", { viewer, sessions: null, threads: null }],
      ["sharedChats", { viewer, sessions: ["wait-led", "no-wait"], threads: [tOrig] }],
      ["chats", { viewer, archived: false }],
      ["chats", { viewer, archived: true }],
    ];
    for (const [op, args] of checks) {
      const got = await read(program, op, args, "en");
      const want = await read(worker, op, args, "en");
      assert.deepEqual(got, want, `mismatch on ${op} ${JSON.stringify(args)}`);
    }
    // changed for chats (archived=true & false) and sharedChats with held digests
    for (const [op, args] of [
      ["chats", { viewer, archived: false }],
      ["chats", { viewer, archived: true }],
      ["sharedChats", { viewer, sessions: null, threads: null }],
    ] as const) {
      const whole = (await read(worker, op, args, "en")) as Record<string, unknown>[];
      const held: Record<string, string> = {};
      whole.forEach((row, i) => {
        if (i % 2 === 0) held[String(row.id)] = digest(row);
      });
      const got = await read(program, "changed", { op, args, id: "id", held }, "en");
      const want = await read(worker, "changed", { op, args, id: "id", held }, "en");
      assert.deepEqual(got, want, `mismatch on changed/${op}`);
    }
  };

  try {
    await compareAll();
    // Verify key expected fields were actually exercised.
    const live = (await read(program, "chats", { viewer, archived: false }, "en")) as Record<string, any>[];
    const byId = new Map(live.map((r) => [r.id, r]));
    assert.equal(byId.get("wait-job")?.agents?.[0]?.waitingAsync, true);
    assert.equal(byId.get("wait-led")?.agents?.[0]?.waitingAsync, true);
    assert.equal(byId.get("no-wait")?.agents?.[0]?.waitingAsync, undefined);
    assert.equal(byId.get("hist-orig")?.last?.authorRuntime, "claude");
    // Without runtime_sessions_ordered index, hist-rs falls back to sessions.runtime ("codex").
    assert.equal(byId.get("hist-rs")?.last?.authorRuntime, "codex");
    assert.equal(byId.get("hist-fallback")?.last?.authorRuntime, "grok");

    // With runtime_sessions_ordered index present, hist-rs resolves its earliest runtime_sessions row ("dsh").
    db.exec("CREATE INDEX runtime_sessions_ordered ON runtime_sessions(session_key, at)");
    await compareAll();
    const liveOrdered = (await read(program, "chats", { viewer, archived: false }, "en")) as Record<string, any>[];
    const byIdOrdered = new Map(liveOrdered.map((r) => [r.id, r]));
    assert.equal(byIdOrdered.get("hist-rs")?.last?.authorRuntime, "dsh");

    const arch = (await read(program, "chats", { viewer, archived: true }, "en")) as Record<string, any>[];
    const archById = new Map(arch.map((r) => [r.id, r]));
    assert.equal(archById.get("arch-quote")?.last?.quotedOnly, true);
    assert.equal([...archById.get("arch-emoji")!.last.text].length, 200);
    assert.equal(archById.get("arch-space200")?.last?.text, "a".repeat(199) + " ");

    // said_other_known = 0 fallback (bounded scan)
    db.exec("UPDATE thread_state SET said_other_known = 0; DELETE FROM said_state_guard");
    await compareAll();

    // >64 consecutive messages by same person with said_other_known = 0 -> reader raises 503 said pending:,
    // which Readers catches to prepare thread_state.said_other_known = 1 and retry, matching TS reference 0-diff.
    for (let i = 0; i < 66; i++) say(tNoWait, "person", "p@x", `burst ${i}`);
    db.exec("UPDATE thread_state SET said_other_known = 0; DELETE FROM said_state_guard");
    const pendingGot = await read(program, "chats", { viewer, archived: false }, "en");
    const st = db.prepare("SELECT said_other_known FROM thread_state WHERE thread = ?").get(tNoWait) as { said_other_known: number } | undefined;
    assert.equal(st?.said_other_known, 1, "said_of_batch must trigger said_pending preparation when >64 consecutive messages by same person");
    const pendingWant = await read(worker, "chats", { viewer, archived: false }, "en");
    assert.deepEqual(pendingGot, pendingWant);

    // Restore said_other_known for remaining checks
    db.prepare("UPDATE thread_state SET said_other_known = 1, said_other_n = 1 WHERE thread = ?").run(tNoWait);
    // merged_read_ready = false fallback
    db.exec("DROP INDEX IF EXISTS entries_edits");
    await compareAll();
  } finally {
    worker.close();
    program.close();
    store.close();
    rmSync(data, { recursive: true, force: true });
  }
});

test("D68 bulk SQL plans avoid full table scans on entries", () => {
  const data = mkdtempSync(join(tmpdir(), "mb-reader-d68-plan-"));
  const store = Store.open(join(data, "stillfail.db"), join(data, "archive"));
  const db = store.db;
  try {
    const plans: [string, string, unknown[]][] = [
      [
        "listed_last_said_all",
        `SELECT t.thread, m.n FROM thread_state t
          CROSS JOIN entries m ON m.thread = t.thread AND m.n = t.said_n AND m.kind = 'message'
          LEFT JOIN entries e ON e.thread = m.thread
            AND e.n = (SELECT MAX(x.n) FROM entries x WHERE x.thread = m.thread AND x.target = m.n)`,
        [],
      ],
      [
        "listed_last_said_of",
        `SELECT t.thread, m.n FROM json_each(?1) req
          CROSS JOIN thread_state t ON t.thread = req.value
          CROSS JOIN entries m ON m.thread = t.thread AND m.n = t.said_n AND m.kind = 'message'
          LEFT JOIN entries e ON e.thread = m.thread
            AND e.n = (SELECT MAX(x.n) FROM entries x WHERE x.thread = m.thread AND x.target = m.n)`,
        ["[1,2]"],
      ],
      [
        "listed_first_text_all",
        `SELECT t.thread, substr(CASE WHEN e.n IS NULL THEN m.text ELSE e.text END, 1, 300) AS t
          FROM thread_state t
          CROSS JOIN entries m ON m.thread = t.thread AND m.n = t.person_n AND m.kind = 'message'
          LEFT JOIN entries e ON e.thread = m.thread
            AND e.n = (SELECT MAX(x.n) FROM entries x WHERE x.thread = m.thread AND x.target = m.n)`,
        [],
      ],
      [
        "said_batch",
        `SELECT t.value AS thread, e.n, s.said_n, g.ready
          FROM json_each(?1) t
          LEFT JOIN entries e ON e.thread = t.value
            AND e.n = (SELECT MAX(n) FROM entries INDEXED BY entries_said WHERE thread = t.value AND kind = 'message' AND letter IS NULL)
          LEFT JOIN thread_state s ON s.thread = t.value
          LEFT JOIN said_state_guard g ON g.thread = t.value`,
        ["[1,2]"],
      ],
    ];
    for (const [name, sql, params] of plans) {
      const rows = db.prepare(`EXPLAIN QUERY PLAN ${sql}`).all(...(params as [])) as { detail: string }[];
      const details = rows.map((r) => r.detail).join("\n");
      assert.ok(!/\bSCAN\s+entries\b/i.test(details), `${name} must not full-scan entries:\n${details}`);
    }
  } finally {
    store.close();
    rmSync(data, { recursive: true, force: true });
  }
});

test("D68 medium-scale (500 archived + 100 live) parity and millisecond timings", { skip: binary === null ? "the MoonBit program is not built here" : false }, async () => {
  const data = mkdtempSync(join(tmpdir(), "mb-reader-d68-scale-"));
  const store = Store.open(join(data, "stillfail.db"), join(data, "archive"));
  const db = store.db;
  const now = wall.now();
  let ts = 0;
  for (let i = 0; i < 600; i++) {
    const archived = i < 500;
    const key = `s-${i}`;
    store.insertSession({
      key,
      connect: "chat",
      runtime: i % 2 === 0 ? "claude" : "codex",
      profile: "p",
      workspace: "/w",
      token: key,
      createdAt: 1000 + i,
      lastActiveAt: 10_000 + i,
      ws: "w",
      createdBy: "p@x",
    } as Parameters<Store["insertSession"]>[0]);
    const id = store.openThread("chat", "CHAT", key, `Chat ${i}`, null).id;
    db.prepare("UPDATE threads SET home = ? WHERE id = ?").run(key, id);
    store.joinThread(id, key, "chat");
    store.insertMessage({ ...newMessage(id, String(++ts), "person", "p@x", `question ${i}`), at: now - 100_000 + ts } as ReturnType<typeof newMessage>);
    store.insertMessage({ ...newMessage(id, String(++ts), "agent", key, `answer ${i} ` + "z".repeat(250)), at: now - 100_000 + ts } as ReturnType<typeof newMessage>);
    if (archived) {
      db.prepare("UPDATE threads SET hidden_at = ?, hidden_by = 'auto' WHERE id = ?").run(20_000 + i, id);
      db.prepare("UPDATE sessions SET archived_at = ?, archived_by = 'auto' WHERE key = ?").run(20_000 + i, key);
    }
  }

  const viewer = { email: "p@x", workspace: "w", home: true };
  const worker = readersOf(data, null);
  const program = readersOf(data, binary);
  try {
    const gotArch = JSON.parse(await program.read("chats", { viewer, archived: true }, "en")) as Record<string, unknown>[];
    const wantArch = JSON.parse(await worker.read("chats", { viewer, archived: true }, "en")) as Record<string, unknown>[];
    assert.equal(gotArch.length, 500);
    assert.deepEqual(gotArch, wantArch);

    const gotLive = JSON.parse(await program.read("sharedChats", { viewer, sessions: null, threads: null }, "en")) as Record<string, unknown>[];
    const wantLive = JSON.parse(await worker.read("sharedChats", { viewer, sessions: null, threads: null }, "en")) as Record<string, unknown>[];
    assert.equal(gotLive.length, 100);
    assert.deepEqual(gotLive, wantLive);

    const held: Record<string, string> = {};
    for (const row of gotArch) held[String(row.id)] = digest(row);
    const gotChanged = JSON.parse(await program.read("changed", { op: "chats", args: { viewer, archived: true }, id: "id", held }, "en"));
    assert.equal(gotChanged.rows.length, 0);
    assert.equal(gotChanged.order.length, 500);
  } finally {
    worker.close();
    program.close();
    store.close();
    rmSync(data, { recursive: true, force: true });
  }
});
