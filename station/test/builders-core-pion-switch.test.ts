// Real dual-engine production switch tests for all 10 `builders_core` SQLite builders:
//   archive-marks, session-bindings, session-counts, signin-save, post-blocks,
//   usage-retire, widget-sources, card-posts, closed-cards, people-since.
//
// Invariants verified WITHOUT ever passing an explicit `binary` override to any production builder:
// 1. Default `mb` genuinely spawns the real MoonBit `stillfail-reader` binary (never `stillfail-pion`).
// 2. Switching via `STILLFAIL_READER_<MODE>=pion` or `config.readers` (once the non-blocking
//    `--version` capability probe resolves) genuinely spawns the real `stillfail-pion` binary
//    and produces 0-diff SQLite table/cursor/schema state against the MoonBit run.
// 3. When an older `stillfail-pion` binary on disk omits `modes:` from `--version`, all 10 SQLite
//    modes safely fall back to MoonBit without hanging or looping and log `pion-binary-unsupported-mode`.
import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { chmodSync, copyFileSync, existsSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { DatabaseSync } from "node:sqlite";
import { after, test } from "node:test";
import { Effect } from "effect";
import { hearLines, type Line } from "../src/ops/log.ts";
import { platform } from "../src/platform/index.ts";
import { ArchiveMarkBuilder } from "../src/read/archive-mark-builder.ts";
import { CardPostsBuilder, ClosedCardsBuilder, PeopleSinceBuilder } from "../src/read/card-posts-builder.ts";
import {
  mbReaderBinary,
  pionBinary,
  probePionSupportedModes,
  resetReaderSelectionStateForTest,
} from "../src/read/mb-reader.ts";
import { type ReaderMode, readerModeEnvKey, type ReaderSelectConfig } from "../src/read/reader-select.ts";
import { SessionBindingsBuilder } from "../src/read/session-bindings-builder.ts";
import { WidgetSourcesBuilder } from "../src/read/widget-sources-builder.ts";
import { PostBlockBuilder } from "../src/sessions/post-block-builder.ts";
import { buildSessionCounts } from "../src/sessions/session-count-builder.ts";
import { Store } from "../src/store/store.ts";
import { installCompactUsage } from "../src/store/usage-compact.ts";
import type { UsageCall, UsageFor } from "../src/store/usage.ts";
import { retireAfterPrevious } from "../src/usage/module.ts";
import { SigninSaveBuilder } from "../src/vault/signin-save-builder.ts";
import { installArchiveMarkIndex } from "./reference/backfill/archive-mark-index.ts";
import { installCardPosts } from "./reference/backfill/card-post-index.ts";
import { installSessionBindingsIndex } from "./reference/backfill/session-bindings-index.ts";
import { installSessionCounts } from "./reference/backfill/session-counts.ts";
import { installSigninSaveIndex } from "./reference/backfill/signin-save-index.ts";
import { stopUsageIndexes } from "./reference/backfill/usage-retire.ts";
import { installWidgetSources } from "./reference/backfill/widget-sources.ts";
import { pinnedPion } from "./pion-pinned.ts";

const tempDirs: string[] = [];
after(() => {
  for (const dir of tempDirs) rmSync(dir, { recursive: true, force: true });
});

function freshDir(prefix = "builders-core-switch-"): string {
  const dir = mkdtempSync(join(tmpdir(), prefix));
  tempDirs.push(dir);
  return dir;
}

const skipPosix = platform.os === "windows" ? "POSIX shell wrappers are not directly spawnable on Windows" : false;

function makeRecordingWrapper(dir: string, name: string, realBin: string, logFile: string): string {
  const wrapper = join(dir, name);
  const sh = [
    "#!/bin/sh",
    `printf '%s\\n' "$*" >> ${JSON.stringify(logFile)}`,
    `exec ${JSON.stringify(realBin)} "$@"`,
    "",
  ].join("\n");
  writeFileSync(wrapper, sh, "utf8");
  chmodSync(wrapper, 0o755);
  return wrapper;
}

function makeLegacyPionStub(dir: string, name: string, logFile: string): string {
  const stub = join(dir, name);
  const sh = [
    "#!/bin/sh",
    `printf '%s\\n' "$*" >> ${JSON.stringify(logFile)}`,
    'if [ "${1:-}" = "--version" ]; then',
    '  printf "stillfail-pion 0.0.1-legacy (linux-x64)\\n"',
    "  exit 0",
    "fi",
    'echo "legacy stub does not support SQLite builder $*" >&2',
    "exit 2",
    "",
  ].join("\n");
  writeFileSync(stub, sh, "utf8");
  chmodSync(stub, 0o755);
  return stub;
}

function readSpawns(logFile: string): string[] {
  if (!existsSync(logFile)) return [];
  return readFileSync(logFile, "utf8").split("\n").map((s) => s.trim()).filter(Boolean);
}

function clearSpawns(logFile: string): void {
  writeFileSync(logFile, "", "utf8");
}

async function withEnv<T>(overrides: Record<string, string | undefined>, fn: () => Promise<T>): Promise<T> {
  const saved = new Map<string, string | undefined>();
  for (const [k, v] of Object.entries(overrides)) {
    saved.set(k, process.env[k]);
    if (v === undefined) delete process.env[k];
    else process.env[k] = v;
  }
  resetReaderSelectionStateForTest();
  try {
    return await fn();
  } finally {
    for (const [k, v] of saved) {
      if (v === undefined) delete process.env[k];
      else process.env[k] = v;
    }
    resetReaderSelectionStateForTest();
  }
}

const CORE_MODES: readonly ReaderMode[] = [
  "archive-marks",
  "session-bindings",
  "session-counts",
  "signin-save",
  "post-blocks",
  "usage-retire",
  "widget-sources",
  "card-posts",
  "closed-cards",
  "people-since",
];

type Fixture = {
  readonly mode: ReaderMode;
  readonly seedPath: string;
  readonly run: (dbPath: string, archiveDir: string, readers?: () => ReaderSelectConfig) => Promise<void>;
  readonly snapshot: (dbPath: string) => string;
};

function makeSeed(dir: string, label: string, setup: (store: Store) => void): string {
  const seedPath = join(dir, `${label}-seed.db`);
  const store = Store.open(seedPath, join(dir, `${label}-archive`));
  try {
    setup(store);
    store.db.exec("PRAGMA wal_checkpoint(TRUNCATE)");
  } finally {
    store.close();
  }
  return seedPath;
}

function buildFixtures(dir: string): Fixture[] {
  const allJson = (db: DatabaseSync, sql: string) => JSON.stringify(db.prepare(sql).all());
  const masterJson = (db: DatabaseSync) =>
    allJson(db, "SELECT type, name, tbl_name, sql FROM sqlite_master ORDER BY type, name");

  // 1. archive-marks
  const archiveMarksSeed = makeSeed(dir, "archive-marks", (store) => {
    const db = store.db;
    for (const row of db.prepare("SELECT name FROM sqlite_master WHERE type='trigger' AND (name LIKE 'archive_pin_%' OR name LIKE 'archive_keep_%')").all() as { name: string }[]) {
      db.exec(`DROP TRIGGER ${row.name}`);
    }
    db.exec("DROP TABLE archive_pin_rows; DROP TABLE archive_keep_rows; DROP TABLE archive_pin_replaced; DROP TABLE archive_keep_replaced; DROP TABLE archive_mark_meta");
    const pin = db.prepare("INSERT INTO pins(viewer, session, at) VALUES (?, ?, ?)");
    for (let i = 0; i < 300; i++) pin.run(`p${i % 7}`, `s-${i % 97}`, i);
    const keep = db.prepare("INSERT INTO kept_chats(viewer, thread) VALUES (?, ?)");
    for (let i = 0; i < 120; i++) keep.run(`p${i % 5}`, i * 2);
    installArchiveMarkIndex(db);
  });

  // 2. session-bindings
  const sessionBindingsSeed = makeSeed(dir, "session-bindings", (store) => {
    const db = store.db;
    for (const row of db.prepare("SELECT name FROM sqlite_master WHERE type='trigger' AND name LIKE 'session_binding_%'").all() as { name: string }[]) {
      db.exec(`DROP TRIGGER ${row.name}`);
    }
    db.exec("DROP TABLE session_binding_rows; DROP TABLE session_binding_replaced; DROP TABLE session_binding_meta");
    const bind = db.prepare("INSERT INTO bindings(connect, session_key) VALUES (?, ?)");
    for (let i = 0; i < 320; i++) bind.run(i % 7 === 0 ? null : `c-${i}`, `s-${i % 40}`);
    installSessionBindingsIndex(db);
  });

  // 3. session-counts
  const sessionCountsSeed = makeSeed(dir, "session-counts", (store) => {
    const db = store.db;
    for (const row of db.prepare("SELECT name FROM sqlite_master WHERE type='trigger' AND name LIKE 'session_count_%'").all() as { name: string }[]) {
      db.exec(`DROP TRIGGER ${row.name}`);
    }
    db.exec("DROP TABLE session_count_seen; DROP TABLE session_count_replaced; DROP TABLE session_count_groups; DROP TABLE session_count_totals; DROP TABLE session_count_meta");
    const put = db.prepare("INSERT INTO sessions (rowid,key,connect,scope,runtime,profile,workspace,token,created_at,last_active_at,ws) VALUES (?,?,?,'thread','claude','cc','/w',?,1,1,?)");
    db.exec("BEGIN");
    for (let i = 1; i <= 300; i++) put.run(i, `s${i}`, ["x", "y"][i % 2], `t${i}`, i % 3 === 0 ? null : `w${i % 4}`);
    db.exec("COMMIT");
    installSessionCounts(db);
  });

  // 4. signin-save
  const signinSaveSeed = join(dir, "signin-save-seed.db");
  {
    const db = new DatabaseSync(signinSaveSeed);
    try {
      db.exec(`PRAGMA journal_mode = WAL;
        CREATE TABLE signin_asks (id TEXT PRIMARY KEY, session TEXT NOT NULL, owner TEXT NOT NULL, status TEXT NOT NULL, body TEXT NOT NULL);
        CREATE INDEX signin_asks_by_session ON signin_asks (session, status);`);
      const put = db.prepare("INSERT INTO signin_asks (id, session, owner, status, body) VALUES (?, ?, 'p', ?, ?)");
      db.exec("BEGIN");
      for (let n = 0; n < 150; n++) {
        put.run(`t${n}`, "target", ["done", "pending", "aaa"][n % 3]!, JSON.stringify(n === 42 ? { save: "wanted-save" } : { save: `s-${n}` }));
      }
      db.exec("COMMIT");
      installSigninSaveIndex(db);
      db.exec("PRAGMA wal_checkpoint(TRUNCATE)");
    } finally {
      db.close();
    }
  }

  // 5. post-blocks
  let postBlocksThread = 0;
  const postBlocksSeed = makeSeed(dir, "post-blocks", (store) => {
    const db = store.db;
    postBlocksThread = store.openThread("ember", "CHAT", "pb-a", null, null).id;
    db.exec("BEGIN");
    const put = db.prepare("INSERT INTO entries(thread,n,kind,author_kind,author,text,at) VALUES (?,?,?,?,?,'t',1)");
    for (let n = 1; n <= 160; n++) put.run(postBlocksThread, n, "message", n % 2 === 0 ? "agent" : "person", `a${n % 3}`);
    db.exec("COMMIT");
    db.exec("DELETE FROM post_blocks; DELETE FROM post_blocks_coverage; UPDATE post_blocks_meta SET fresh = 0");
  });

  // 6. usage-retire
  const usageRetireSeed = makeSeed(dir, "usage-retire", (store) => {
    const HOUR = 3_600_000;
    const of: UsageFor = { turn: null, person: "p", thread: null, profile: "cc" };
    const mkCall = (id: string, at: number, input: number): UsageCall => ({
      id, at, model: "m", subagent: false, fast: false,
      input, cacheRead: 0, cacheWrite: 0, cacheWriteLong: 0, output: 1, calls: 1, context: 100, window: 1000,
    });
    store.insertSession({ key: "a", connect: "ember", runtime: "claude", profile: "cc", workspace: "/w/a", token: "a", ws: "A", createdAt: 0, lastActiveAt: 0 });
    store.recordUsage("/a", { session: "a", offset: 120, model: "m" }, "claude", Array.from({ length: 120 }, (_, i) => [mkCall(`a${i}`, i * HOUR / 4, i + 1), of]));
    store.db.exec(`UPDATE usage SET rollup_counted = 0; UPDATE usage_15m_meta SET since = ${40 * HOUR}`);
    installCompactUsage(store.db);
    store.db.exec("CREATE TABLE usage_detail_x (k TEXT, n INTEGER, PRIMARY KEY (k, n)) WITHOUT ROWID;");
    for (let i = 0; i < 40; i++) store.db.prepare("INSERT INTO usage_detail_x VALUES (?, ?)").run(`k${i % 3}`, i);
    stopUsageIndexes(store.db);
  });

  // 7. widget-sources (includes malformed attachments so `widget_source_invalid` is populated)
  let widgetThread = 0;
  const widgetSourcesSeed = makeSeed(dir, "widget-sources", (store) => {
    const db = store.db;
    widgetThread = store.openThread("ember", "CHAT", "ws-a", null, null).id;
    const put = db.prepare("INSERT INTO entries(thread, n, kind, author_kind, author, at, attachments, letter) VALUES (?, ?, 'message', 'agent', 'a', ?, ?, NULL)");
    const files = (n: number) => JSON.stringify([{ path: `/w/${n}.html`, name: `${n}.html` }]);
    db.exec("BEGIN");
    for (let n = 1; n <= 160; n++) {
      const att = n % 8 === 0 ? files(n) : n % 37 === 0 ? "not json" : n % 41 === 0 ? '["{bad"]' : "[]";
      put.run(widgetThread, n, n, att);
    }
    db.exec("COMMIT");
    const objs = db.prepare("SELECT type,name FROM sqlite_master WHERE name LIKE 'widget_source_%' AND type IN ('trigger','table')").all() as { type: string; name: string }[];
    for (const type of ["trigger", "table"] as const) {
      for (const obj of objs.filter((x) => x.type === type)) db.exec(`DROP ${type.toUpperCase()} "${obj.name}"`);
    }
    installWidgetSources(db);
  });

  // 8. card-posts
  let cardThread = 0;
  const cardPostsSeed = makeSeed(dir, "card-posts", (store) => {
    const db = store.db;
    const objs = db.prepare("SELECT type,name FROM sqlite_master WHERE name LIKE 'card_post%' AND type IN ('trigger','table')").all() as { type: string; name: string }[];
    for (const type of ["trigger", "table"] as const) {
      for (const obj of objs.filter((x) => x.type === type)) db.exec(`DROP ${type.toUpperCase()} "${obj.name}"`);
    }
    cardThread = store.openThread("ember", "CHAT", "cp-a", null, null).id;
    const put = db.prepare("INSERT INTO entries(thread,n,kind,target,author_kind,author,at,card,options) VALUES(?,?,'message',NULL,'agent','a',?,?,?)");
    db.exec("BEGIN");
    for (let n = 1; n <= 160; n++) put.run(cardThread, n, n, n % 3 === 0 ? "{}" : null, n % 5 === 0 ? '["ok"]' : null);
    db.exec("COMMIT");
    installCardPosts(db);
  });

  // 9 & 10. closed-cards & people-since
  let lookupThread = 0;
  const lookupSeed = makeSeed(dir, "lookups", (store) => {
    const db = store.db;
    lookupThread = store.openThread("ember", "CHAT", "lk-a", null, null).id;
    const entry = db.prepare("INSERT INTO entries(thread,n,kind,author_kind,author,text,at,ts) VALUES(?,?,'message',?,'x','t',?,?)");
    const close = db.prepare("INSERT INTO closed_cards(thread,n,viewer,at) VALUES(?,?,?,?)");
    db.exec("BEGIN");
    for (let n = 1; n <= 90; n++) {
      entry.run(lookupThread, n, n % 3 === 0 ? "person" : "agent", n * 5, n % 4 === 0 ? `ts-${n}` : null);
      close.run(lookupThread, n, "p0", n * 7);
    }
    db.exec("COMMIT");
    db.exec("DROP INDEX closed_cards_thread_at; DROP INDEX entries_people_since");
  });

  return [
    {
      mode: "archive-marks",
      seedPath: archiveMarksSeed,
      run: async (dbPath, _archiveDir, readers) => {
        const b = new ArchiveMarkBuilder(dbPath, readers ? { readers } : {});
        try { await b.readyIndex(); } finally { await b.close(); }
      },
      snapshot: (dbPath) => {
        const db = new DatabaseSync(dbPath);
        try {
          return JSON.stringify([
            masterJson(db),
            allJson(db, "SELECT kind, version, last_rowid, end_rowid, complete FROM archive_mark_meta ORDER BY kind"),
            allJson(db, "SELECT session, position FROM archive_pin_rows ORDER BY session, position"),
            allJson(db, "SELECT thread, position FROM archive_keep_rows ORDER BY thread, position"),
          ]);
        } finally { db.close(); }
      },
    },
    {
      mode: "session-bindings",
      seedPath: sessionBindingsSeed,
      run: async (dbPath, _archiveDir, readers) => {
        const b = new SessionBindingsBuilder(dbPath, readers ? { readers } : {});
        try { await b.readyIndex(); } finally { await b.close(); }
      },
      snapshot: (dbPath) => {
        const db = new DatabaseSync(dbPath);
        try {
          return JSON.stringify([
            masterJson(db),
            allJson(db, "SELECT id, version, last_rowid, end_rowid, complete FROM session_binding_meta"),
            allJson(db, "SELECT session, binding_rowid, connect FROM session_binding_rows ORDER BY session, binding_rowid"),
          ]);
        } finally { db.close(); }
      },
    },
    {
      mode: "session-counts",
      seedPath: sessionCountsSeed,
      run: async (dbPath, archiveDir, readers) => {
        const store = Store.open(dbPath, archiveDir);
        const h = buildSessionCounts(store, Promise.resolve(), undefined, readers);
        try {
          const ok = await h.ready;
          assert.equal(ok, true, "buildSessionCounts must complete");
        } finally {
          await h.close();
          store.close();
        }
      },
      snapshot: (dbPath) => {
        const db = new DatabaseSync(dbPath);
        try {
          return JSON.stringify([
            masterJson(db),
            allJson(db, "SELECT version, last_rowid, end_rowid, complete FROM session_count_meta"),
            allJson(db, "SELECT session, connect, ws FROM session_count_seen ORDER BY session"),
            allJson(db, "SELECT kind, ws, connect, n FROM session_count_groups ORDER BY kind, ws, connect"),
            allJson(db, "SELECT kind, ws, n FROM session_count_totals ORDER BY kind, ws"),
          ]);
        } finally { db.close(); }
      },
    },
    {
      mode: "signin-save",
      seedPath: signinSaveSeed,
      run: async (dbPath, _archiveDir, readers) => {
        const db = new DatabaseSync(dbPath);
        let settled = false;
        const { promise, resolve: resolveDone } = Promise.withResolvers<string | null>();
        const b = new SigninSaveBuilder(
          db,
          (_pending, body) => { settled = true; resolveDone(body); },
          readers ? { readers } : {},
        );
        try {
          b.wait("target", "wanted-save", "done");
          const found = await promise;
          assert.equal(settled, true);
          assert.ok(found !== null && found.includes("wanted-save"), `expected wanted-save body, got ${found}`);
        } finally {
          await b.close();
          db.close();
        }
      },
      snapshot: (dbPath) => {
        const db = new DatabaseSync(dbPath);
        try {
          return JSON.stringify([
            masterJson(db),
            allJson(db, "SELECT ask, session, save FROM signin_save_lookup ORDER BY ask"),
            allJson(db, "SELECT session, status, row, done FROM signin_save_progress ORDER BY session"),
          ]);
        } finally { db.close(); }
      },
    },
    {
      mode: "post-blocks",
      seedPath: postBlocksSeed,
      run: async (dbPath, archiveDir, readers) => {
        const store = Store.open(dbPath, archiveDir);
        const b = new PostBlockBuilder(store, Promise.resolve(), undefined, readers);
        try {
          await b.ready([{ thread: postBlocksThread, n: 1 }]);
        } finally {
          await b.close();
          store.close();
        }
      },
      snapshot: (dbPath) => {
        const db = new DatabaseSync(dbPath);
        try {
          return JSON.stringify([
            masterJson(db),
            allJson(db, "SELECT thread, author, bucket FROM post_blocks ORDER BY thread, author, bucket"),
            allJson(db, "SELECT thread, cursor, complete FROM post_blocks_coverage ORDER BY thread"),
          ]);
        } finally { db.close(); }
      },
    },
    {
      mode: "usage-retire",
      seedPath: usageRetireSeed,
      run: async (dbPath, archiveDir, readers) => {
        const store = Store.open(dbPath, archiveDir);
        try {
          const ok = await Effect.runPromise(retireAfterPrevious(store, Promise.resolve(), undefined, readers));
          assert.equal(ok, true, "retireAfterPrevious must succeed");
        } finally {
          store.close();
        }
      },
      snapshot: (dbPath) => {
        const db = new DatabaseSync(dbPath);
        try {
          const usageTables = (db.prepare("SELECT name FROM sqlite_master WHERE type='table' AND name LIKE 'usage%' AND name <> 'usage_counter' ORDER BY name").all() as { name: string }[]).map((r) => r.name);
          const usageRows = usageTables.map((name) => [name, (db.prepare(`SELECT * FROM "${name}"`).all() as object[]).map((r) => JSON.stringify(r)).sort()]);
          return JSON.stringify([
            masterJson(db),
            usageTables,
            usageRows,
          ]);
        } finally { db.close(); }
      },
    },
    {
      mode: "widget-sources",
      seedPath: widgetSourcesSeed,
      run: async (dbPath, _archiveDir, readers) => {
        const b = new WidgetSourcesBuilder(dbPath, readers ? { readers } : {});
        try { await b.ready([widgetThread]); } finally { await b.close(); }
      },
      snapshot: (dbPath) => {
        const db = new DatabaseSync(dbPath);
        try {
          const invalidCount = (db.prepare("SELECT COUNT(*) AS n FROM widget_source_invalid").get() as { n: number }).n;
          assert.ok(invalidCount > 0, `expected non-empty widget_source_invalid, got ${invalidCount}`);
          return JSON.stringify([
            masterJson(db),
            allJson(db, "SELECT thread, n, slot, path, at, name FROM widget_source_rows ORDER BY thread, n, slot"),
            allJson(db, "SELECT thread, n FROM widget_source_invalid ORDER BY thread, n"),
            allJson(db, "SELECT thread, last_n, end_n, complete FROM widget_source_scopes ORDER BY thread"),
          ]);
        } finally { db.close(); }
      },
    },
    {
      mode: "card-posts",
      seedPath: cardPostsSeed,
      run: async (dbPath, _archiveDir, readers) => {
        const b = new CardPostsBuilder(dbPath, readers ? { readers } : {});
        try { await b.ready([cardThread]); } finally { await b.close(); }
      },
      snapshot: (dbPath) => {
        const db = new DatabaseSync(dbPath);
        try {
          return JSON.stringify([
            masterJson(db),
            allJson(db, "SELECT thread, n FROM card_posts ORDER BY thread, n"),
            allJson(db, "SELECT thread, last_n, end_n, phase FROM card_post_scopes ORDER BY thread"),
          ]);
        } finally { db.close(); }
      },
    },
    {
      mode: "closed-cards",
      seedPath: lookupSeed,
      run: async (dbPath, _archiveDir, readers) => {
        const b = new ClosedCardsBuilder(dbPath, readers ? { readers } : {});
        try { await b.ready([lookupThread]); } finally { await b.close(); }
      },
      snapshot: (dbPath) => {
        const db = new DatabaseSync(dbPath);
        try {
          return JSON.stringify([
            masterJson(db),
            allJson(db, "SELECT source_rowid, thread, n, at FROM legacy_closed_cards ORDER BY thread, n"),
            allJson(db, "SELECT thread, last_n, end_n, complete FROM legacy_closed_scopes ORDER BY thread"),
          ]);
        } finally { db.close(); }
      },
    },
    {
      mode: "people-since",
      seedPath: lookupSeed,
      run: async (dbPath, _archiveDir, readers) => {
        const b = new PeopleSinceBuilder(dbPath, readers ? { readers } : {});
        try { await b.ready([lookupThread]); } finally { await b.close(); }
      },
      snapshot: (dbPath) => {
        const db = new DatabaseSync(dbPath);
        try {
          return JSON.stringify([
            masterJson(db),
            allJson(db, "SELECT source_rowid, thread, n, at, ts FROM legacy_people_time_rows ORDER BY thread, n"),
            allJson(db, "SELECT thread, last_n, end_n, complete FROM legacy_people_time_scopes ORDER BY thread"),
          ]);
        } finally { db.close(); }
      },
    },
  ];
}

test("all 10 builders_core modes: real MB default, real Pion switch (env + config.readers) with 0-diff, and legacy stub fallback", { skip: skipPosix }, async (t) => {
  const realMb = mbReaderBinary();
  const explicitPion = pinnedPion();
  const realPion = pionBinary();

  if (realMb === null) {
    if (process.env.CI) assert.fail("stillfail-reader binary is required in CI");
    t.skip("stillfail-reader not built here");
    return;
  }
  if (explicitPion) {
    assert.ok(realPion !== null, `STILLFAIL_PION_READER is set (${explicitPion}) but resolved to null`);
  } else if (realPion === null) {
    t.skip("STILLFAIL_PION_READER / built stillfail-pion binary not present in this environment");
    return;
  }

  const dir = freshDir();
  const mbLog = join(dir, "mb-spawns.log");
  const pionLog = join(dir, "pion-spawns.log");
  const legacyLog = join(dir, "legacy-pion-spawns.log");
  const mbWrap = makeRecordingWrapper(dir, "wrap-mb", resolve(realMb), mbLog);
  const pionWrap = makeRecordingWrapper(dir, "wrap-pion", resolve(realPion!), pionLog);
  const legacyStub = makeLegacyPionStub(dir, "stub-legacy-pion", legacyLog);

  const fixtures = buildFixtures(dir);
  assert.equal(fixtures.length, CORE_MODES.length);

  // Clear any per-mode env overrides so tests are isolated.
  const cleanEnv: Record<string, string | undefined> = {
    STILLFAIL_MB_READER: mbWrap,
    STILLFAIL_PION_READER: pionWrap,
    STILLFAIL_READER_ENGINE: undefined,
  };
  for (const mode of CORE_MODES) cleanEnv[readerModeEnvKey(mode)] = undefined;

  for (let idx = 0; idx < fixtures.length; idx++) {
    const f = fixtures[idx]!;
    const useConfig = idx % 2 === 1;

    // 1. Default `mb`: must spawn MB wrapper and NEVER Pion wrapper.
    clearSpawns(mbLog);
    clearSpawns(pionLog);
    const mbDb = join(dir, `${f.mode}-mb.db`);
    copyFileSync(f.seedPath, mbDb);
    await withEnv(cleanEnv, async () => {
      await f.run(mbDb, join(dir, `${f.mode}-mb-arch`));
    });
    const mbSpawns = readSpawns(mbLog);
    const pionSpawnsOnDefault = readSpawns(pionLog);
    assert.ok(
      mbSpawns.some((line) => line.includes(`--builder ${f.mode}`)),
      `${f.mode}: default mb must spawn MB reader with --builder ${f.mode}, got ${JSON.stringify(mbSpawns)}`,
    );
    assert.equal(
      pionSpawnsOnDefault.length,
      0,
      `${f.mode}: default mb must never spawn Pion binary, got ${JSON.stringify(pionSpawnsOnDefault)}`,
    );
    const mbSnap = f.snapshot(mbDb);

    // 2. Switch to Pion via env (`STILLFAIL_READER_<MODE>=pion`) or `config.readers` after async `--version` probe.
    clearSpawns(mbLog);
    clearSpawns(pionLog);
    const pionDb = join(dir, `${f.mode}-pion.db`);
    copyFileSync(f.seedPath, pionDb);
    const envForPion: Record<string, string | undefined> = { ...cleanEnv };
    if (!useConfig) envForPion[readerModeEnvKey(f.mode)] = "pion";
    const readersCfg: (() => ReaderSelectConfig) | undefined = useConfig
      ? () => ({ readers: { [f.mode]: "pion" } })
      : undefined;

    await withEnv(envForPion, async () => {
      const supported = await probePionSupportedModes(pionWrap);
      assert.ok(supported !== null && supported.has(f.mode), `${f.mode}: probed stillfail-pion must advertise ${f.mode}`);
      clearSpawns(pionLog); // clear the `--version` probe line so we assert the real `--builder` spawn below
      await f.run(pionDb, join(dir, `${f.mode}-pion-arch`), readersCfg);
    });
    const mbSpawnsOnPion = readSpawns(mbLog);
    const pionSpawns = readSpawns(pionLog);
    assert.equal(
      mbSpawnsOnPion.length,
      0,
      `${f.mode}: pion switch must NOT spawn MB reader, got ${JSON.stringify(mbSpawnsOnPion)}`,
    );
    assert.ok(
      pionSpawns.some((line) => line.includes(`--builder ${f.mode}`)),
      `${f.mode}: pion switch must spawn real stillfail-pion with --builder ${f.mode}, got ${JSON.stringify(pionSpawns)}`,
    );
    assert.equal(f.snapshot(pionDb), mbSnap, `${f.mode}: Pion DB snapshot must match MB 0-diff`);
  }

  // 3. Legacy Pion binary on disk (omits `modes:` in `--version`): all 10 SQLite modes safely fall back to MB.
  const logs: Line[] = [];
  hearLines((l) => logs.push(l));
  try {
    await withEnv({
      ...cleanEnv,
      STILLFAIL_PION_READER: legacyStub,
      STILLFAIL_READER_ENGINE: "pion",
    }, async () => {
      const supported = await probePionSupportedModes(legacyStub);
      assert.ok(supported !== null, "legacy stub --version probe must succeed");
      for (const mode of CORE_MODES) {
        assert.equal(supported.has(mode), false, `legacy stub must not advertise ${mode}`);
      }
      clearSpawns(legacyLog);
      for (const f of fixtures) {
        clearSpawns(mbLog);
        const fbDb = join(dir, `${f.mode}-fallback.db`);
        copyFileSync(f.seedPath, fbDb);
        await f.run(fbDb, join(dir, `${f.mode}-fb-arch`));
        const mbSpawns = readSpawns(mbLog);
        assert.ok(
          mbSpawns.some((line) => line.includes(`--builder ${f.mode}`)),
          `${f.mode}: legacy stub must fall back cleanly to MB reader`,
        );
      }
      assert.equal(
        readSpawns(legacyLog).length,
        0,
        "legacy stub must never be spawned for any unsupported SQLite builder mode",
      );
    });
    const unsupportedWarns = logs.filter(
      (l) => l.level === "WARN" && l.message === "reader engine fallback" && l.fields.reason === "pion-binary-unsupported-mode",
    );
    assert.equal(unsupportedWarns.length, CORE_MODES.length, `expected 1 deduped fallback warn per mode, got ${unsupportedWarns.length}`);
  } finally {
    hearLines(null);
  }
});

const MB_FAIL_PREFIX = /^\S+:\d+:\d+-\d+:\d+@\S+ FAILED: /;

function normalizeErr(res: Record<string, unknown>): Record<string, unknown> {
  if (typeof res.error === "string") {
    return { ...res, error: res.error.replace(MB_FAIL_PREFIX, "") };
  }
  return res;
}

async function runBuilderLines(
  binary: string,
  mode: ReaderMode,
  dbPath: string,
  lines: readonly string[],
): Promise<Record<string, unknown>[]> {
  return new Promise((resolveRun, rejectRun) => {
    const child = spawn(binary, ["--builder", mode, "--db", dbPath], {
      stdio: ["pipe", "pipe", "pipe"],
      windowsHide: true,
    });
    let stdout = "";
    let stderr = "";
    child.stdout!.on("data", (c: Buffer) => { stdout += c.toString("utf8"); });
    child.stderr!.on("data", (c: Buffer) => { stderr += c.toString("utf8"); });
    const timer = setTimeout(() => {
      child.kill("SIGKILL");
      rejectRun(new Error(`builder ${mode} timed out; stderr=${stderr}`));
    }, 30_000);
    child.on("error", (err) => { clearTimeout(timer); rejectRun(err); });
    child.on("close", (code, signal) => {
      clearTimeout(timer);
      if (signal !== null || code !== 0) {
        rejectRun(new Error(`builder ${mode} exited code=${code} signal=${signal}; stderr=${stderr}`));
        return;
      }
      try {
        const out = stdout.split("\n").filter((l) => l.length > 0).map((l) => normalizeErr(JSON.parse(l) as Record<string, unknown>));
        resolveRun(out);
      } catch (err) {
        rejectRun(err);
      }
    });
    for (const line of lines) child.stdin!.write(`${line}\n`);
    child.stdin!.end();
  });
}

test("dual-engine 0-diff regressions: usage-retire large finite float, post-blocks Int64 saturation, and 9-mode dispatch boundaries", async (t) => {
  const realMb = mbReaderBinary();
  const explicitPion = pinnedPion();
  const realPion = pionBinary();

  if (realMb === null) {
    if (process.env.CI) assert.fail("stillfail-reader binary is required in CI");
    t.skip("stillfail-reader not built here");
    return;
  }
  if (explicitPion) {
    assert.ok(realPion !== null, `STILLFAIL_PION_READER is set (${explicitPion}) but resolved to null`);
  } else if (realPion === null) {
    t.skip("STILLFAIL_PION_READER / built stillfail-pion binary not present in this environment");
    return;
  }

  const dir = freshDir("builders-core-reg-");

  // 1. Astra P1: usage-retire large finite REAL (`since=2e30`, `at=1e30`, `rollup_counted=0`).
  {
    const seed = makeSeed(dir, "usage-large-float", (store) => {
      const of: UsageFor = { turn: null, person: "p", thread: null, profile: "cc" };
      const call: UsageCall = {
        id: "big-1", at: 1_000_000, model: "m", subagent: false, fast: false,
        input: 10, cacheRead: 0, cacheWrite: 0, cacheWriteLong: 0, output: 1, calls: 1, context: 100, window: 1000,
      };
      store.insertSession({ key: "big", connect: "ember", runtime: "claude", profile: "cc", workspace: "/w/big", token: "big", ws: "W", createdAt: 0, lastActiveAt: 0 });
      store.recordUsage("/big", { session: "big", offset: 1, model: "m" }, "claude", [[call, of]]);
      store.db.exec(`
        UPDATE usage SET at = 1e30, rollup_counted = 0 WHERE id = 'big-1';
        UPDATE usage_15m_meta SET since = 2e30 WHERE id = 1;
      `);
    });
    const mbDb = join(dir, "usage-large-mb.db");
    const pionDb = join(dir, "usage-large-pion.db");
    copyFileSync(seed, mbDb);
    copyFileSync(seed, pionDb);

    // Step 1: must return {done:false}, set since=1e30, rollup_counted=1; Step 2: {done:true}, since=null.
    const mbStep1 = await runBuilderLines(realMb, "usage-retire", mbDb, ["{}"]);
    const pionStep1 = await runBuilderLines(realPion!, "usage-retire", pionDb, ["{}"]);
    assert.deepStrictEqual(pionStep1, [{ done: false }]);
    assert.deepStrictEqual(pionStep1, mbStep1, "usage-retire large float batch 1 response");

    for (const [label, p] of [["mb", mbDb], ["pion", pionDb]] as const) {
      const db = new DatabaseSync(p);
      try {
        const meta = db.prepare("SELECT since FROM usage_15m_meta WHERE id = 1").get() as { since: number | null };
        const row = db.prepare("SELECT rollup_counted FROM usage WHERE id = 'big-1'").get() as { rollup_counted: number };
        assert.equal(meta.since, 1e30, `${label}: since after batch 1 must be 1e30`);
        assert.equal(row.rollup_counted, 1, `${label}: rollup_counted after batch 1 must be 1`);
      } finally { db.close(); }
    }

    const mbStep2 = await runBuilderLines(realMb, "usage-retire", mbDb, ["{}"]);
    const pionStep2 = await runBuilderLines(realPion!, "usage-retire", pionDb, ["{}"]);
    assert.deepStrictEqual(pionStep2, [{ done: true }]);
    assert.deepStrictEqual(pionStep2, mbStep2, "usage-retire large float batch 2 response");
  }

  // 2. Astra P2-1: post-blocks Int64 upper-bound saturation & no-repr binding (`9223372036854775808` and `1e400`).
  {
    const seed = makeSeed(dir, "post-blocks-sat", (store) => {
      const db = store.db;
      db.exec("UPDATE post_blocks_meta SET fresh = 0");
      db.prepare("INSERT INTO entries(thread,n,kind,author_kind,author,text,at) VALUES (?,1,'message','agent','a0','t',1)")
        .run(9223372036854775807n);
      db.exec("DELETE FROM post_blocks; DELETE FROM post_blocks_coverage;");
    });
    const mbDb = join(dir, "pb-sat-mb.db");
    const pionDb = join(dir, "pb-sat-pion.db");
    copyFileSync(seed, mbDb);
    copyFileSync(seed, pionDb);

    const asks = [
      '{"thread":9223372036854775808,"after":1}',
      '{"thread":1e400,"after":1}',
    ];
    const mbRes = await runBuilderLines(realMb, "post-blocks", mbDb, asks);
    const pionRes = await runBuilderLines(realPion!, "post-blocks", pionDb, asks);
    assert.deepStrictEqual(pionRes, mbRes, "post-blocks saturated thread responses must match MB 0-diff");

    const snap = (p: string) => {
      const db = new DatabaseSync(p);
      try {
        const blocks = db.prepare("SELECT * FROM post_blocks ORDER BY thread, author, bucket").all();
        const cov = db.prepare("SELECT typeof(thread) AS ty, CAST(thread AS TEXT) AS thread, cursor, complete FROM post_blocks_coverage ORDER BY thread").all();
        assert.equal(blocks.length, 0, "saturated 2^63/1e400 thread must not match INT64_MAX entry");
        return JSON.stringify({ blocks, cov });
      } finally { db.close(); }
    };
    assert.equal(snap(pionDb), snap(mbDb), "post-blocks saturated thread DB state must match MB 0-diff");
  }

  // 3. Opus P2-1: Table-driven 9-mode dispatch protocol boundaries (dual-engine 0-diff).
  {
    const protoFixtures = buildFixtures(dir);
    const byMode = new Map(protoFixtures.map((f) => [f.mode, f]));
    const cases: readonly { mode: ReaderMode; asks: readonly string[] }[] = [
      { mode: "session-bindings", asks: ['{"scope":"other"}', '{"scope":"all","scope":"other"}'] },
      { mode: "session-counts", asks: ["{bad json", "123"] },
      { mode: "signin-save", asks: ["{}", "123"] },
      { mode: "post-blocks", asks: ['{"thread":1}', '{"thread":"1","after":1}'] },
      { mode: "usage-retire", asks: ['{"drop":1}', '{"drop":true,"drop":false}'] },
      { mode: "widget-sources", asks: ['{"thread":"1"}', "{}"] },
      { mode: "card-posts", asks: ['{"thread":"1"}', "{}"] },
      { mode: "closed-cards", asks: ['{"thread":"1"}', "{}"] },
      { mode: "people-since", asks: ['{"thread":"1"}', "{}"] },
    ];
    for (const c of cases) {
      const f = byMode.get(c.mode)!;
      const mbDb = join(dir, `proto-${c.mode}-mb.db`);
      const pionDb = join(dir, `proto-${c.mode}-pion.db`);
      copyFileSync(f.seedPath, mbDb);
      copyFileSync(f.seedPath, pionDb);
      const mbOut = await runBuilderLines(realMb, c.mode, mbDb, c.asks);
      const pionOut = await runBuilderLines(realPion!, c.mode, pionDb, c.asks);
      assert.deepStrictEqual(pionOut, mbOut, `${c.mode} protocol boundary responses must match MB 0-diff`);
    }
  }
});
