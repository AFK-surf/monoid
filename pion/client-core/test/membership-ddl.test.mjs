// Real `node:sqlite` TS DDL verification + real TS `client/core-ts/src/accounts.ts` `readStored()`
// parity test for Slice 2B (`MembershipAuthority`):
// 1. Initializes a real `node:sqlite` DatabaseSync using the REAL TS `MIGRATIONS` + `ensureSaid` +
//    `ensureKept` + `ensureMdKept` + `ensureMoved` from `client/core-ts/src/db/schema.ts`.
// 2. Seeds EVERY table for `ws-drop` (`ws-drop/st-1`, exclusive bare `st-drop-only`) AND `ws-keep`
//    (`ws-keep/st-1`, shared bare `st-shared`), plus wildcard-sensitive workspace `ws_drop` (`_` char!).
// 3. Runs EVERY SQL statement emitted by Pion's `sync::drop_workspace_sql_plan` directly against
//    `node:sqlite` (zero mocked SQL!), asserting 0 SQL errors across `station.address`, `draft`,
//    `account_doc("usage:<ws>")`, `said`, `workspace_pref`, and all 15 per-station tables, complete
//    deletion of `ws-drop`, and 100% preservation of `ws-keep` + `ws_drop` + `st-shared`.
// 4. Passes Pion's `sync::serialize_stored_accounts` output through REAL TS `Accounts.load()`
//    (`client/core-ts/src/accounts.ts:50-69` `readStored`) to verify exact `"access_expires"` parity.

import assert from "node:assert/strict";
import { execFileSync, spawn } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { DatabaseSync } from "node:sqlite";
import { after, before, test } from "node:test";
import { fileURLToPath } from "node:url";

import { Effect } from "../../../client/core-ts/node_modules/effect/dist/index.js";
import {
  MIGRATIONS,
  ensureSaid,
  ensureKept,
  ensureFilesKept,
  ensureMdKept,
  ensureSlackSaid,
  ensureSlackWho,
  ensureMoved,
  ensureSharedSidecar,
} from "../../../client/core-ts/src/db/schema.ts";
import { Accounts } from "../../../client/core-ts/src/accounts.ts";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const repoRoot = path.resolve(__dirname, "../../..");
const pioncBin = process.env.PIONC || path.join(os.homedir(), ".pion/bin/pionc");

class ParityClient {
  constructor(binPath) {
    this.proc = spawn(binPath, [], { stdio: ["pipe", "pipe", "pipe"] });
    this.buf = "";
    this.queue = [];
    this.stderr = "";
    this.proc.stderr.on("data", (d) => { this.stderr += d.toString("utf8"); });
    this.proc.stdout.on("data", (chunk) => {
      this.buf += chunk.toString("utf8");
      let nl;
      while ((nl = this.buf.indexOf("\n")) >= 0) {
        const line = this.buf.slice(0, nl);
        this.buf = this.buf.slice(nl + 1);
        const waiter = this.queue.shift();
        if (waiter) {
          try { waiter.resolve(JSON.parse(line)); }
          catch (e) { waiter.reject(new Error(`Bad JSON from parity_cli: ${line}\n${e}`)); }
        }
      }
    });
    this.proc.on("exit", (code) => {
      while (this.queue.length > 0) {
        this.queue.shift().reject(new Error(`parity_cli exited with code ${code}: ${this.stderr}`));
      }
    });
  }
  call(op, args = {}) {
    return new Promise((resolve, reject) => {
      this.queue.push({ resolve, reject });
      this.proc.stdin.write(`${JSON.stringify({ op, args })}\n`);
    }).then((resp) => {
      if ("err" in resp) throw new Error(`parity_cli error on ${op}: ${resp.err}`);
      return resp.ok;
    });
  }
  close() {
    this.proc.stdin.end();
    this.proc.kill();
  }
}

let rpc;
let builtBin = null;

before(() => {
  builtBin = path.join(os.tmpdir(), `pion-client-core-membership-ddl-${process.pid}`);
  execFileSync(pioncBin, ["build", "-o", builtBin, "pion/client-core/packages/parity_cli"], {
    cwd: repoRoot,
    stdio: "inherit",
  });
  rpc = new ParityClient(builtBin);
});

after(() => {
  if (rpc) rpc.close();
  if (builtBin && fs.existsSync(builtBin)) fs.unlinkSync(builtBin);
});

function createRealTsSchemaDb() {
  const db = new DatabaseSync(":memory:");
  for (const m of MIGRATIONS) {
    db.exec(m);
  }
  const sqlShim = {
    exec: (q) => { db.exec(q); },
    all: (q, params = []) => {
      const stmt = db.prepare(q);
      stmt.setReturnArrays(true);
      return stmt.all(...params);
    },
    run: (q, params = []) => db.prepare(q).run(...params),
  };
  ensureSaid(sqlShim);
  ensureKept(sqlShim);
  ensureFilesKept(sqlShim);
  ensureMdKept(sqlShim);
  ensureSlackSaid(sqlShim);
  ensureSlackWho(sqlShim);
  ensureMoved(sqlShim);
  ensureSharedSidecar(sqlShim);
  return db;
}

function seedOptionalTablesForStation(db, ws, st, tag, otherSt = null) {
  db.prepare(
    "INSERT OR REPLACE INTO file_kept (station, session, name, kind, type, size, used, bytes) VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
  ).run(st, `sess-${tag}`, `img-${tag}.png`, "thumb", "image/png", 16, 1000, "AAAA");
  db.prepare("INSERT OR REPLACE INTO md_kept (station, key, of, size, used, json) VALUES (?, ?, ?, ?, ?, ?)").run(
    st,
    `md-${tag}`,
    `chat-${tag}`,
    12,
    1000,
    "{}",
  );
  db.prepare(
    "INSERT OR REPLACE INTO slack_said (station, session, i, k, out, call, user, who, at, dest, text, failed, refused) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
  ).run(st, `sess-${tag}`, 1, 0, 0, null, "U123", "Alice", 1000, "C1", `slack msg ${tag}`, 0, 0);
  db.prepare(
    "INSERT OR REPLACE INTO slack_who (station, user, first, who, at) VALUES (?, ?, ?, ?, ?)",
  ).run(st, "U123", 1000, "Alice", 1000);
  db.prepare("INSERT OR REPLACE INTO log_use (kind, station, id, opened, evicted) VALUES (?, ?, ?, ?, ?)").run(
    "chat",
    st,
    `chat-${tag}`,
    1000,
    0,
  );
  db.prepare(
    "INSERT OR REPLACE INTO shared_sidecar (station, id, digest, said, named, quoted_only, local_admin) VALUES (?, ?, ?, ?, ?, ?, ?)",
  ).run(st, `chat-${tag}`, `dig-${tag}`, null, null, 0, 0);
  db.prepare("INSERT OR REPLACE INTO shared_mark (station, kind, k, v) VALUES (?, ?, ?, ?)").run(
    st,
    "read",
    "10",
    "1",
  );
  db.prepare(
    "INSERT OR REPLACE INTO shared_meta (station, me, selves, lang, hidden_known, muted_known, no_route_build) VALUES (?, ?, ?, ?, ?, ?, ?)",
  ).run(st, "alice@still.fail", "[]", "zh", 0, 0, null);
  // Seed workspace-level new-chat draft (`new:<ws>` -> station=ws, chat='new').
  db.prepare("INSERT OR REPLACE INTO draft (station, chat, json) VALUES (?, ?, ?)").run(
    ws,
    "new",
    JSON.stringify({ text: `new-chat-draft-${tag}` }),
  );
  if (otherSt) {
    // Seed BOTH directions of `moved` (`station = st` AND `there_station = st`).
    db.prepare(
      "INSERT OR REPLACE INTO moved (station, session, there_station, thread, there, at, came) VALUES (?, ?, ?, ?, ?, ?, ?)",
    ).run(st, `mv-from-${tag}`, otherSt, 10, 20, 1000, 0);
    db.prepare(
      "INSERT OR REPLACE INTO moved (station, session, there_station, thread, there, at, came) VALUES (?, ?, ?, ?, ?, ?, ?)",
    ).run(otherSt, `mv-to-${tag}`, st, 20, 10, 1000, 1);
  }
}

function seedAllTablesForStation(db, ws, st, tag) {
  db.prepare("INSERT OR REPLACE INTO workspace (id, json, confirmed) VALUES (?, ?, ?)").run(
    ws,
    JSON.stringify({ id: ws, name: `WS ${tag}` }),
    1000,
  );
  db.prepare("INSERT OR REPLACE INTO workspace_pref (workspace, key, json) VALUES (?, ?, ?)").run(
    ws,
    "theme",
    JSON.stringify({ mode: tag }),
  );
  db.prepare("INSERT OR REPLACE INTO account_doc (name, json, confirmed) VALUES (?, ?, ?)").run(
    `usage:${ws}`,
    JSON.stringify({ cost: 42, tag }),
    1000,
  );
  db.prepare("INSERT OR REPLACE INTO account_doc (name, json, confirmed) VALUES (?, ?, ?)").run(
    `vaults:${ws}`,
    JSON.stringify({ vaults: [{ id: `v-${tag}` }] }),
    1000,
  );
  // Real TS DDL: `station` primary key column is `address`, NEVER `station`!
  db.prepare("INSERT OR REPLACE INTO station (address, kind, json, confirmed) VALUES (?, ?, ?, ?)").run(
    st,
    "overview",
    JSON.stringify({ id: st, name: `Station ${tag}` }),
    1000,
  );
  db.prepare("INSERT OR REPLACE INTO slack_app (station, connect, json, confirmed) VALUES (?, ?, ?, ?)").run(
    st,
    `conn-${tag}`,
    "{}",
    1000,
  );
  db.prepare("INSERT OR REPLACE INTO list (station, list, confirmed, rev) VALUES (?, ?, ?, ?)").run(
    st,
    "chats",
    1000,
    1,
  );
  db.prepare(
    "INSERT OR REPLACE INTO chat (station, archived, id, ord, thread, session, client_key, last_active, pinned_at, unread, mine, running, tone, asks, desk, json) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
  ).run(st, 0, `chat-${tag}`, 1.0, 10, `sess-${tag}`, null, 5000, null, 1, 1, 0, null, 0, 0, "{}");
  db.prepare(
    "INSERT OR REPLACE INTO session (station, key, listed, ord, summary) VALUES (?, ?, ?, ?, ?)",
  ).run(st, `sess-${tag}`, 1, 1.0, `Summary ${tag}`);
  db.prepare(
    "INSERT OR REPLACE INTO thread (station, id, listed, last, read, unread, sort_at, created_at, json) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
  ).run(st, 10, 1, 1, 0, 1, 5000, 1000, "{}");
  db.prepare("INSERT OR REPLACE INTO thread_member (station, session, thread) VALUES (?, ?, ?)").run(
    st,
    `sess-${tag}`,
    10,
  );
  // Inserting a message into `entry` also populates `said` via the real TS `said_put` trigger!
  db.prepare("INSERT OR REPLACE INTO entry (station, thread, n, json) VALUES (?, ?, ?, ?)").run(
    st,
    10,
    1,
    JSON.stringify({ thread: 10, n: 1, kind: "message", text: `secret message ${tag}`, at: 5000 }),
  );
  db.prepare("INSERT OR REPLACE INTO transcript (station, session, i, json) VALUES (?, ?, ?, ?)").run(
    st,
    `sess-${tag}`,
    0,
    "{}",
  );
  db.prepare("INSERT OR REPLACE INTO job (station, id, session, open, ord, chat, json) VALUES (?, ?, ?, ?, ?, ?, ?)").run(
    st,
    `job-${tag}`,
    `sess-${tag}`,
    1,
    1.0,
    `chat-${tag}`,
    "{}",
  );
  db.prepare("INSERT OR REPLACE INTO outbox (station, thread, json) VALUES (?, ?, ?)").run(st, 10, "{}");
  db.prepare("INSERT OR REPLACE INTO pending (key, station, json) VALUES (?, ?, ?)").run(`ck-${tag}`, st, "{}");
  db.prepare("INSERT OR REPLACE INTO first (station, session, json) VALUES (?, ?, ?)").run(st, `sess-${tag}`, "{}");
  db.prepare("INSERT OR REPLACE INTO changing (station, id, json) VALUES (?, ?, ?)").run(st, 1, "{}");
  db.prepare("INSERT OR REPLACE INTO draft (station, chat, json) VALUES (?, ?, ?)").run(st, `chat-${tag}`, JSON.stringify({ text: tag }));
}

test("Slice 2B real node:sqlite TS DDL: drop_workspace_sql_plan deletes every dropped table with 0 SQL errors and preserves sibling/wildcard workspaces", async () => {
  const db = createRealTsSchemaDb();
  try {
    // Seed ws_drop (canonical `ws_drop/st-1` + exclusive bare `st-drop-only`),
    // wildcard-adjacent `wsXdrop` (testing non-LIKE `substr()` safety against `_`),
    // and sibling `ws-keep` (`ws-keep/st-1` + shared bare `st-shared`),
    // across ALL base tables AND ALL optional Pion/TS `ensure_*` tables + `new:<ws>` draft!
    seedAllTablesForStation(db, "ws_drop", "ws_drop/st-1", "drop-canon");
    seedOptionalTablesForStation(db, "ws_drop", "ws_drop/st-1", "drop-canon", "ws-keep/st-1");
    seedAllTablesForStation(db, "ws_drop", "st-drop-only", "drop-bare");
    seedOptionalTablesForStation(db, "ws_drop", "st-drop-only", "drop-bare", "ws-keep/st-1");
    seedAllTablesForStation(db, "wsXdrop", "wsXdrop/st-1", "wildcard-neighbor");
    seedOptionalTablesForStation(db, "wsXdrop", "wsXdrop/st-1", "wildcard-neighbor", "ws-keep/st-1");
    seedAllTablesForStation(db, "ws-keep", "ws-keep/st-1", "keep-canon");
    seedOptionalTablesForStation(db, "ws-keep", "ws-keep/st-1", "keep-canon", "wsXdrop/st-1");
    db.prepare("INSERT OR REPLACE INTO station (address, kind, json, confirmed) VALUES (?, ?, ?, ?)").run(
      "st-shared",
      "overview",
      JSON.stringify({ id: "st-shared", name: "Shared Bare" }),
      1000,
    );
    db.prepare("INSERT OR REPLACE INTO draft (station, chat, json) VALUES (?, ?, ?)").run("st-shared", "c-shared", "{\"text\":\"keep\"}");
    db.prepare("INSERT OR REPLACE INTO account_doc (name, json, confirmed) VALUES (?, ?, ?)").run("me", "{\"workspaces\":[]}", 1000);

    // Fetch exact SQL plan from Pion `sync::drop_workspace_sql_plan` INCLUDING all present optional tables
    // and execute EVERY statement in ONE single SQLite transaction on real `node:sqlite`.
    const optionalTables = [
      "file_kept",
      "md_kept",
      "log_use",
      "slack_said",
      "slack_who",
      "moved",
      "shared_sidecar",
      "shared_meta",
      "shared_mark",
    ];
    const plan = await rpc.call("membership.dropSqlPlan", {
      workspace: "ws_drop",
      stations: ["ws_drop/st-1", "st-drop-only"],
      optionalTables,
    });
    assert.ok(Array.isArray(plan) && plan.length > 50, `expected full drop SQL plan, got ${plan.length}`);

    db.exec("BEGIN IMMEDIATE");
    for (const step of plan) {
      db.prepare(step.sql).run(...step.params);
    }
    db.exec("COMMIT");

    // 1. Verify EVERY single base & optional table has 0 rows remaining for `ws_drop`, `ws_drop/st-1`, and `st-drop-only`.
    assert.equal(db.prepare("SELECT count(*) AS c FROM workspace WHERE id = ?").get("ws_drop").c, 0);
    assert.equal(db.prepare("SELECT count(*) AS c FROM workspace_pref WHERE workspace = ?").get("ws_drop").c, 0);
    assert.equal(db.prepare("SELECT count(*) AS c FROM account_doc WHERE name = ?").get("usage:ws_drop").c, 0);
    assert.equal(db.prepare("SELECT count(*) AS c FROM account_doc WHERE name = ?").get("vaults:ws_drop").c, 0);
    assert.equal(db.prepare("SELECT count(*) AS c FROM draft WHERE station = ? AND chat = 'new'").get("ws_drop").c, 0, "new:<ws> draft purged");
    assert.equal(db.prepare("SELECT count(*) AS c FROM draft WHERE station = ? AND chat = 'new'").get("ws-keep").c, 1, "ws-keep new:<ws> draft preserved");
    assert.equal(db.prepare("SELECT count(*) AS c FROM draft WHERE station = ? AND chat = 'new'").get("wsXdrop").c, 1, "wsXdrop new:<ws> draft preserved");
    assert.equal(db.prepare("SELECT count(*) AS c FROM station WHERE address IN (?, ?)").get("ws_drop/st-1", "st-drop-only").c, 0);

    const perStationTables = [
      "slack_app", "list", "chat", "session", "thread", "thread_member",
      "entry", "transcript", "job", "outbox", "pending", "first",
      "changing", "draft", "said",
      "file_kept", "md_kept", "log_use", "slack_said", "slack_who", "shared_sidecar", "shared_meta", "shared_mark",
    ];
    for (const tbl of perStationTables) {
      const remDrop = db.prepare(`SELECT count(*) AS c FROM ${tbl} WHERE station IN (?, ?)`).get("ws_drop/st-1", "st-drop-only").c;
      assert.equal(remDrop, 0, `expected 0 rows in ${tbl} for dropped workspace stations`);
      const remKeep = db.prepare(`SELECT count(*) AS c FROM ${tbl} WHERE station = ?`).get("ws-keep/st-1").c;
      assert.ok(remKeep >= 1, `expected preserved row in ${tbl} for ws-keep/st-1`);
      const remNeighbor = db.prepare(`SELECT count(*) AS c FROM ${tbl} WHERE station = ?`).get("wsXdrop/st-1").c;
      assert.ok(remNeighbor >= 1, `expected preserved row in ${tbl} for wildcard-neighbor wsXdrop/st-1`);
    }
    // Verify `moved` deletes ONLY rows whose source `station` belongs to `ws_drop`, preserving rows
    // owned by `ws-keep` even when `there_station` pointed at `ws_drop` (Opus R2 P2-1)!
    assert.equal(
      db.prepare("SELECT count(*) AS c FROM moved WHERE station IN (?, ?)").get("ws_drop/st-1", "st-drop-only").c,
      0,
      "moved rows with source station in dropped workspace must be purged",
    );
    assert.ok(
      db.prepare("SELECT count(*) AS c FROM moved WHERE station = 'ws-keep/st-1' AND there_station = 'ws_drop/st-1'").get().c >= 1,
      "moved rows whose source station belongs to surviving ws-keep must be preserved",
    );
    assert.ok(
      db.prepare("SELECT count(*) AS c FROM moved WHERE station = 'ws-keep/st-1' AND there_station = 'wsXdrop/st-1'").get().c >= 1,
      "unrelated moved rows between surviving workspaces preserved",
    );

    // 2. Verify `me`, `ws-keep`, `wsXdrop`, and `st-shared` remain 100% intact.
    assert.equal(db.prepare("SELECT count(*) AS c FROM account_doc WHERE name = 'me'").get().c, 1);
    assert.equal(db.prepare("SELECT count(*) AS c FROM workspace WHERE id = 'ws-keep'").get().c, 1);
    assert.equal(db.prepare("SELECT count(*) AS c FROM workspace WHERE id = 'wsXdrop'").get().c, 1);
    assert.equal(db.prepare("SELECT count(*) AS c FROM station WHERE address = 'st-shared'").get().c, 1);
    assert.equal(db.prepare("SELECT count(*) AS c FROM draft WHERE station = 'st-shared'").get().c, 1);
  } finally {
    db.close();
  }
});

test("Slice 2B real TS accounts.ts parity: Pion serialize_stored_accounts (access_expires) loads cleanly in TS Accounts.load() and generates valid Crockford Base32 ULIDs", async () => {
  // 1. Serialize via Pion `sync::serialize_stored_accounts` with Unix epoch SECONDS `access_expires` & `session`.
  const epochSec = 1795816600;
  const serialized = await rpc.call("membership.serializeAccounts", {
    accounts: [
      {
        sub: "sub-alice",
        email: "alice@still.fail",
        name: "Alice",
        picture: "https://img.example/a.png",
        access: "acc-tok-1",
        refresh: "ref-tok-1",
        access_expires: epochSec,
        session: "sess-alice-1",
      },
    ],
  });
  assert.equal(serialized.length, 1);
  assert.equal(serialized[0].access_expires, epochSec);
  assert.equal(serialized[0].session, "sess-alice-1");
  assert.equal("accessExpires" in serialized[0], false, "MUST NOT emit camelCase accessExpires");

  // 2. Feed Pion's exact serialized bytes directly into REAL TS `Accounts.load()` (`client/core-ts/src/accounts.ts:50-69` `readStored`).
  const storeMem = new Map([["accounts", new TextEncoder().encode(JSON.stringify(serialized))]]);
  const storageShim = {
    storageGet: (k) => Effect.sync(() => storeMem.get(k) ?? null),
    storageSet: (k, v) => Effect.sync(() => { storeMem.set(k, v); }),
    storageDelete: (k) => Effect.sync(() => { storeMem.delete(k); }),
  };
  const accounts = await Effect.runPromise(Accounts.load(storageShim));
  assert.equal(accounts.isUnloaded(), false, "TS Accounts.load() must NOT mark Pion accounts as unloaded/corrupt");
  const listed = accounts.list();
  assert.equal(listed.length, 1, "TS Accounts.load() must accept Pion serialized accounts with epoch-second access_expires & session");
  assert.equal(listed[0].sub, "sub-alice");
  assert.equal(listed[0].email, "alice@still.fail");

  // 3. Prove that camelCase `accessExpires` would be discarded by TS `readStored()` (regression guard!).
  const badCamel = [{ ...serialized[0], accessExpires: serialized[0].access_expires }];
  delete badCamel[0].access_expires;
  const badMem = new Map([["accounts", new TextEncoder().encode(JSON.stringify(badCamel))]]);
  const badShim = {
    storageGet: (k) => Effect.sync(() => badMem.get(k) ?? null),
    storageSet: (k, v) => Effect.sync(() => { badMem.set(k, v); }),
    storageDelete: (k) => Effect.sync(() => { badMem.delete(k); }),
  };
  const badLoaded = await Effect.runPromise(Accounts.load(badShim));
  assert.equal(badLoaded.list().length, 0, "TS readStored() rejects camelCase accessExpires");

  // 4. Verify ULID generator matches 26-char Crockford Base32 (`^[0-9A-HJKMNP-TV-Z]{26}$`).
  const ulidRes = await rpc.call("membership.generateUlid", {
    nowMs: 1795813000000,
    randHex: "0123456789abcdef0123456789abcdef",
  });
  assert.equal(ulidRes.valid, true);
  assert.match(ulidRes.ulid, /^[0-9A-HJKMNP-TV-Z]{26}$/);

  // 5. Verify strict `/v1/me` (26-char Crockford Base32 ULID workspace IDs, required `created_at`/`stations`/`members`,
  // missing sub, bad role, duplicate ws id, bad elem) and `/v1/workspaces/<id>` rejection via Pion CLI.
  const validWs1 = "01ARZ3NDEKTSV4RRFFQ69G5FAV";
  const validWs2 = "01ARZ3NDEKTSV4RRFFQ69G5FBW";
  const okMe = await rpc.call("membership.parseCloudMeStrict", {
    payload: {
      user: { sub: "u1" },
      workspaces: [{ id: validWs1, name: "OK", role: "owner", created_at: 1700000000, stations: 1, members: 2 }],
    },
  });
  assert.equal(okMe.ok, true);
  const badMeNonUlid = await rpc.call("membership.parseCloudMeStrict", {
    payload: {
      user: { sub: "u1" },
      workspaces: [{ id: "ws-1", name: "Bad", role: "owner", created_at: 1700000000, stations: 1, members: 1 }],
    },
  });
  assert.equal(badMeNonUlid.ok, false);
  const badMeMissingCreatedAt = await rpc.call("membership.parseCloudMeStrict", {
    payload: {
      user: { sub: "u1" },
      workspaces: [{ id: validWs1, name: "NoCreated", role: "owner", stations: 1, members: 1 }],
    },
  });
  assert.equal(badMeMissingCreatedAt.ok, false);
  const badMeMissingStations = await rpc.call("membership.parseCloudMeStrict", {
    payload: {
      user: { sub: "u1" },
      workspaces: [{ id: validWs1, name: "NoSt", role: "owner", created_at: 1700000000, members: 1 }],
    },
  });
  assert.equal(badMeMissingStations.ok, false);
  const badMeMissingMembers = await rpc.call("membership.parseCloudMeStrict", {
    payload: {
      user: { sub: "u1" },
      workspaces: [{ id: validWs1, name: "NoMem", role: "owner", created_at: 1700000000, stations: 1 }],
    },
  });
  assert.equal(badMeMissingMembers.ok, false);
  const badMeElem = await rpc.call("membership.parseCloudMeStrict", {
    payload: { user: { sub: "u1" }, workspaces: [{ id: validWs1, name: "OK", role: "owner", created_at: 1, stations: 0, members: 1 }, { bad: true }] },
  });
  assert.equal(badMeElem.ok, false);
  const badMeNoSub = await rpc.call("membership.parseCloudMeStrict", {
    payload: { workspaces: [{ id: validWs1, name: "OK", role: "owner", created_at: 1, stations: 0, members: 1 }] },
  });
  assert.equal(badMeNoSub.ok, false);
  const badMeRole = await rpc.call("membership.parseCloudMeStrict", {
    payload: { user: { sub: "u1" }, workspaces: [{ id: validWs1, name: "OK", role: "superadmin", created_at: 1, stations: 0, members: 1 }] },
  });
  assert.equal(badMeRole.ok, false);
  const badMeDup = await rpc.call("membership.parseCloudMeStrict", {
    payload: { user: { sub: "u1" }, workspaces: [{ id: validWs1, name: "A", role: "owner", created_at: 1, stations: 0, members: 1 }, { id: validWs1, name: "B", role: "member", created_at: 1, stations: 0, members: 1 }] },
  });
  assert.equal(badMeDup.ok, false);
  const badMeSlashId = await rpc.call("membership.parseCloudMeStrict", {
    payload: { user: { sub: "u1" }, workspaces: [{ id: "ws/evil", name: "Bad", role: "owner", created_at: 1, stations: 0, members: 1 }] },
  });
  assert.equal(badMeSlashId.ok, false);
  const badMeEmptyName = await rpc.call("membership.parseCloudMeStrict", {
    payload: { user: { sub: "u1" }, workspaces: [{ id: validWs1, name: "", role: "owner", created_at: 1, stations: 0, members: 1 }] },
  });
  assert.equal(badMeEmptyName.ok, false);
  const badWs = await rpc.call("membership.parseCloudWorkspaceStrict", {
    payload: { id: validWs2, name: "Wrong", stations: [] },
    requestedWs: validWs1,
  });
  assert.equal(badWs.ok, false);
  const badWsNonUlid = await rpc.call("membership.parseCloudWorkspaceStrict", {
    payload: { id: "ws-1", name: "NonUlid", stations: [] },
    requestedWs: "ws-1",
  });
  assert.equal(badWsNonUlid.ok, false);
  const badWsStationPrefix = await rpc.call("membership.parseCloudWorkspaceStrict", {
    payload: { id: validWs1, name: "OK", stations: [{ id: validWs2 + "/st-evil", name: "Evil" }] },
    requestedWs: validWs1,
  });
  assert.equal(badWsStationPrefix.ok, false);
});
