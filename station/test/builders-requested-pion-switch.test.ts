// Real dual-engine production switch, Permit interleaving, cross-token guard safety,
// usage-check startup failure & numeric id repr, cc-index dual-lane & latest priority,
// error-message parity, and static transaction guard tests for `builders_requested`:
//   turn-counts, said, cc-index, usage-check.
import assert from "node:assert/strict";
import { spawn, type ChildProcess } from "node:child_process";
import {
  chmodSync,
  copyFileSync,
  existsSync,
  mkdirSync,
  mkdtempSync,
  readdirSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { DatabaseSync } from "node:sqlite";
import { after, test } from "node:test";
import { fileURLToPath } from "node:url";
import { hearLines, type Line } from "../src/ops/log.ts";
import { platform } from "../src/platform/index.ts";
import { CcIndexBuilder } from "../src/read/cc-index-builder.ts";
import {
  mbReaderBinary,
  pionBinary,
  probePionSupportedModes,
  resetReaderSelectionStateForTest,
} from "../src/read/mb-reader.ts";
import { type ReaderMode, readerModeEnvKey, type ReaderSelectConfig } from "../src/read/reader-select.ts";
import { SaidBuilder } from "../src/read/said-builder.ts";
import { TurnBuilder } from "../src/read/turn-builder.ts";
import { addSessionTurns } from "../src/store/schema.ts";
import { Store } from "../src/store/store.ts";
import { MinuteReader } from "../src/usage/minute-reader.ts";
import { installCcIndex } from "./reference/backfill/cc-thread-index.ts";

const REQUESTED_MODES: readonly ReaderMode[] = ["turn-counts", "said", "cc-index", "usage-check"];
const LINE_TIMEOUT_MS = 20_000;
const MB_FAIL_PREFIX = /^\S+:\d+:\d+-\d+:\d+@\S+ FAILED: /;

const tempDirs: string[] = [];
after(() => {
  for (const dir of tempDirs) rmSync(dir, { recursive: true, force: true });
});

function freshDir(prefix = "builders-requested-switch-"): string {
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

function resolveBinaries(t: { skip: (msg: string) => void }): { realMb: string; realPion: string } | null {
  const realMb = mbReaderBinary();
  const explicitPion = process.env.STILLFAIL_PION_READER?.trim();
  const realPion = pionBinary();

  if (realMb === null) {
    if (process.env.CI) assert.fail("stillfail-reader binary is required in CI");
    t.skip("stillfail-reader not built here");
    return null;
  }
  if (explicitPion) {
    assert.ok(realPion !== null, `STILLFAIL_PION_READER is set (${explicitPion}) but resolved to null`);
  } else if (realPion === null) {
    t.skip("STILLFAIL_PION_READER / built stillfail-pion binary not present in this environment");
    return null;
  }
  return { realMb: resolve(realMb), realPion: resolve(realPion!) };
}

class RawLineProc {
  readonly #child: ChildProcess;
  readonly #lines: string[] = [];
  readonly #waiters: Array<{ resolve: (line: string | null) => void; reject: (err: Error) => void; timer: NodeJS.Timeout }> = [];
  #carry: Buffer = Buffer.alloc(0);
  #stderr = "";
  #closed = false;
  readonly #exitPromise: Promise<{ code: number | null; signal: NodeJS.Signals | null }>;

  constructor(binary: string, args: string[]) {
    const child = spawn(binary, args, { stdio: ["pipe", "pipe", "pipe"], windowsHide: true });
    this.#child = child;
    child.stdin!.on("error", () => {});
    child.stderr!.on("data", (c: Buffer) => { this.#stderr += c.toString("utf8"); });
    child.stdout!.on("data", (c: Buffer) => {
      this.#carry = this.#carry.length === 0 ? c : Buffer.concat([this.#carry, c]);
      for (let nl = this.#carry.indexOf(0x0a); nl >= 0; nl = this.#carry.indexOf(0x0a)) {
        const line = this.#carry.subarray(0, nl).toString("utf8");
        this.#carry = this.#carry.subarray(nl + 1);
        const w = this.#waiters.shift();
        if (w) {
          clearTimeout(w.timer);
          w.resolve(line);
        } else {
          this.#lines.push(line);
        }
      }
    });
    this.#exitPromise = new Promise((done) => {
      child.on("close", (code, signal) => {
        this.#closed = true;
        for (const w of this.#waiters.splice(0)) {
          clearTimeout(w.timer);
          w.resolve(null);
        }
        done({ code, signal });
      });
    });
  }

  get stderr(): string {
    return this.#stderr;
  }

  writeRaw(data: string | Buffer): void {
    this.#child.stdin!.write(data);
  }

  endStdin(): void {
    this.#child.stdin!.end();
  }

  nextLine(): Promise<string | null> {
    if (this.#lines.length > 0) return Promise.resolve(this.#lines.shift()!);
    if (this.#closed) return Promise.resolve(null);
    return new Promise((resolveLine, rejectLine) => {
      const timer = setTimeout(() => {
        rejectLine(new Error(`timed out waiting for stdout line; stderr=${this.#stderr}`));
      }, LINE_TIMEOUT_MS);
      this.#waiters.push({ resolve: resolveLine, reject: rejectLine, timer });
    });
  }

  async nextJson(): Promise<Record<string, unknown>> {
    const line = await this.nextLine();
    assert.notEqual(line, null, `expected JSON line, got EOF; stderr=${this.#stderr}`);
    const parsed = JSON.parse(line!) as Record<string, unknown>;
    if (typeof parsed.error === "string") {
      parsed.error = parsed.error.replace(MB_FAIL_PREFIX, "");
    }
    return parsed;
  }

  async waitExit(): Promise<{ code: number | null; signal: NodeJS.Signals | null; trailing: string }> {
    const res = await this.#exitPromise;
    return { ...res, trailing: this.#carry.toString("utf8") };
  }

  async finish(): Promise<{ code: number | null; signal: NodeJS.Signals | null }> {
    this.#child.stdin!.end();
    const res = await this.#exitPromise;
    assert.equal(this.#lines.length, 0, `unexpected trailing stdout lines: ${JSON.stringify(this.#lines)}`);
    assert.equal(this.#carry.length, 0, `unexpected trailing stdout bytes: ${this.#carry.toString("utf8")}`);
    return res;
  }

  async kill(): Promise<void> {
    if (this.#child.exitCode === null && this.#child.signalCode === null) this.#child.kill("SIGKILL");
    await this.#exitPromise;
  }
}

// ── Seed helpers ──

function forgetTurnCounts(db: DatabaseSync): void {
  db.exec(`
    DROP TRIGGER IF EXISTS session_turns_add;
    DROP TRIGGER IF EXISTS session_turns_drop;
    DROP TRIGGER IF EXISTS session_turns_before_insert;
    DROP TRIGGER IF EXISTS session_turns_move;
    DROP TABLE IF EXISTS session_turns_guard;
    DROP TABLE session_turns
  `);
}

function makeTurnCountsSeed(dir: string, label: string): string {
  const path = join(dir, `${label}-turns.db`);
  const store = Store.open(path, join(dir, `${label}-turns-archive`));
  try {
    for (const key of ["A", "B", "empty"]) {
      store.insertSession({
        key,
        connect: "ember",
        runtime: "claude",
        profile: "cc",
        workspace: `/w/${key}`,
        token: key,
        createdAt: 1,
        lastActiveAt: 1,
      });
    }
    const put = store.db.prepare("INSERT INTO turns(rowid,id,session_key,kind,started_at) VALUES (?, ?, ?, 'input', ?)");
    store.db.exec("BEGIN");
    for (let n = 0; n < 300; n++) put.run(n - 100, `a-${n}`, "A", n < 150 ? 1 : n);
    for (let n = 0; n < 5; n++) put.run(n + 1000, `b-${n}`, "B", n + 1);
    store.db.exec("COMMIT");
    forgetTurnCounts(store.db);
    addSessionTurns(store.db);
    store.db.exec("PRAGMA wal_checkpoint(TRUNCATE)");
    return path;
  } finally {
    store.close();
  }
}

function makeSaidSeed(dir: string, label: string): { path: string; longThread: number; shortThread: number } {
  const path = join(dir, `${label}-said.db`);
  const store = Store.open(path, join(dir, `${label}-said-archive`));
  try {
    store.insertSession({
      key: "s0",
      connect: "ember",
      runtime: "claude",
      profile: "cc",
      workspace: "/w/s0",
      token: "s0",
      createdAt: 1,
      lastActiveAt: 1,
    });
    const longThread = store.openThread("ember", "CHAT", `${label}-long`, null, null).id;
    const shortThread = store.openThread("ember", "CHAT", `${label}-short`, null, null).id;
    store.joinThread(longThread, "s0", "ember");
    store.joinThread(shortThread, "s0", "ember");
    const put = store.db.prepare("INSERT INTO entries(thread,n,kind,author_kind,author,ts,at) VALUES (?,?,'message',?,?,?,?)");
    store.db.exec("BEGIN");
    put.run(longThread, 1, "agent", "s0", "first-long", 1);
    for (let n = 2; n <= 300; n++) put.run(longThread, n, "person", "me", `l-${n}`, n);
    put.run(shortThread, 1, "agent", "s0", "first-short", 1);
    put.run(shortThread, 2, "person", "me", "s-2", 2);
    store.db.exec("COMMIT");
    store.db.prepare("UPDATE thread_state SET said_other_known=0 WHERE thread IN (?,?)").run(longThread, shortThread);
    store.db.exec("PRAGMA wal_checkpoint(TRUNCATE)");
    return { path, longThread, shortThread };
  } finally {
    store.close();
  }
}

function makeCcSeed(dir: string, label: string): string {
  const path = join(dir, `${label}-cc.db`);
  const store = Store.open(path, join(dir, `${label}-cc-archive`));
  try {
    const db = store.db;
    for (const key of ["long", "short", "none"]) {
      store.insertSession({
        key,
        connect: "ember",
        runtime: "claude",
        profile: "cc",
        workspace: `/w/${key}`,
        token: key,
        createdAt: 1,
        lastActiveAt: 1,
      });
    }
    const thread = db.prepare("INSERT INTO threads(surface,channel,thread_ts,created_at) VALUES(?,'C',?,?)");
    const member = db.prepare("INSERT INTO thread_sessions(thread,session,connect,joined_at) VALUES(?,?,'slack',?)");
    const say = db.prepare("INSERT INTO entries(thread,n,kind,author_kind,author,text,at) VALUES(?,1,'message','person','me','x',?)");
    db.exec("BEGIN");
    for (let n = 0; n < 200; n++) {
      const id = Number(thread.run(n === 5 ? "stillfail" : "slack:one", `long-${n}`, n).lastInsertRowid);
      member.run(id, "long", n);
      if (n % 3 === 0) say.run(id, 1000 + n);
      if (n === 4 || n === 8) member.run(id, "short", n);
    }
    db.exec("COMMIT");
    installCcIndex(db);
    db.exec("PRAGMA wal_checkpoint(TRUNCATE)");
    return path;
  } finally {
    store.close();
  }
}

function makeUsageSeed(dir: string, label: string, sql = ""): string {
  const path = join(dir, `${label}-usage.db`);
  const store = Store.open(path, join(dir, `${label}-usage-archive`));
  try {
    if (sql) store.db.exec(sql);
    store.db.exec("PRAGMA wal_checkpoint(TRUNCATE)");
    return path;
  } finally {
    store.close();
  }
}

function snapshotTurnCounts(dbPath: string): string {
  const db = new DatabaseSync(dbPath);
  try {
    return JSON.stringify({
      counts: db.prepare("SELECT session, n FROM session_turns ORDER BY session").all(),
      guards: db.prepare("SELECT session, boundary_at, boundary_rowid FROM session_turns_guard ORDER BY session").all(),
    });
  } finally {
    db.close();
  }
}

function snapshotSaid(dbPath: string): string {
  const db = new DatabaseSync(dbPath);
  try {
    return JSON.stringify({
      state: db.prepare("SELECT thread, said_n, said_other_n, said_other_known FROM thread_state ORDER BY thread").all(),
      guards: db.prepare("SELECT thread, author, other_n, ready FROM said_state_guard ORDER BY thread").all(),
    });
  } finally {
    db.close();
  }
}

function snapshotCc(dbPath: string): string {
  const db = new DatabaseSync(dbPath);
  try {
    return JSON.stringify({
      sessions: db.prepare("SELECT session, scan_after, scan_end, complete FROM cc_sessions ORDER BY session").all(),
      rows: db.prepare("SELECT * FROM cc_session_rows ORDER BY session, thread").all(),
      dirty: db.prepare("SELECT session, thread FROM cc_session_dirty ORDER BY session, thread").all(),
      dispatch: db.prepare("SELECT thread, after_session, through_session FROM cc_order_dispatch ORDER BY thread").all(),
      turn: db.prepare("SELECT * FROM cc_order_turn").all(),
      chatScopes: db.prepare("SELECT * FROM session_chat_scopes ORDER BY session").all(),
      chatRows: db.prepare("SELECT * FROM session_chat_rows ORDER BY session, thread").all(),
      latestScopes: db.prepare("SELECT * FROM latest_thread_scopes ORDER BY session").all(),
      latestRows: db.prepare("SELECT * FROM latest_thread_rows ORDER BY session, member_rowid").all(),
      latestMembers: db.prepare("SELECT * FROM latest_thread_members ORDER BY thread, session").all(),
    });
  } finally {
    db.close();
  }
}

// ── Test 1: Production TS switch (default MB, env/config Pion switch, 0-diff, legacy fallback) ──

test("builders_requested: real MB default, real Pion switch (env + config.readers) with 0-diff, and legacy stub fallback", { skip: skipPosix }, async (t) => {
  const bins = resolveBinaries(t);
  if (!bins) return;

  const dir = freshDir();
  const mbLog = join(dir, "mb-spawns.log");
  const pionLog = join(dir, "pion-spawns.log");
  const legacyLog = join(dir, "legacy-pion-spawns.log");
  const mbWrap = makeRecordingWrapper(dir, "wrap-mb", bins.realMb, mbLog);
  const pionWrap = makeRecordingWrapper(dir, "wrap-pion", bins.realPion, pionLog);
  const legacyStub = makeLegacyPionStub(dir, "stub-legacy-pion", legacyLog);

  const turnsSeed = makeTurnCountsSeed(dir, "switch");
  const saidSeed = makeSaidSeed(dir, "switch");
  const ccSeed = makeCcSeed(dir, "switch");
  const usageSeed = makeUsageSeed(
    dir,
    "switch",
    "UPDATE remote_run_progress SET done = 0; INSERT INTO usage_chat_dirty_scope(session, kind, ws) VALUES ('s', 2, 'A')",
  );

  const cleanEnv: Record<string, string | undefined> = {
    STILLFAIL_MB_READER: mbWrap,
    STILLFAIL_PION_READER: pionWrap,
    STILLFAIL_READER_ENGINE: undefined,
    [readerModeEnvKey("turn-counts")]: undefined,
    [readerModeEnvKey("said")]: undefined,
    [readerModeEnvKey("cc-index")]: undefined,
    [readerModeEnvKey("usage-check")]: undefined,
  };

  type ModeCase = {
    readonly mode: ReaderMode;
    readonly seedPath: string;
    readonly useConfig: boolean;
    readonly run: (dbPath: string, cfg?: () => ReaderSelectConfig) => Promise<string>;
  };

  const cases: readonly ModeCase[] = [
    {
      mode: "turn-counts",
      seedPath: turnsSeed,
      useConfig: false, // STILLFAIL_READER_TURN_COUNTS=pion
      run: async (dbPath, cfg) => {
        const priority = new SharedArrayBuffer(8);
        const builder = new TurnBuilder(dbPath, { priority, readers: cfg });
        try {
          await builder.ready(["A", "B", "empty"]);
          assert.equal(Atomics.load(new Int32Array(priority), 1), 0, "permit released");
          return snapshotTurnCounts(dbPath);
        } finally {
          await builder.close();
        }
      },
    },
    {
      mode: "said",
      seedPath: saidSeed.path,
      useConfig: true, // config.readers.said = "pion"
      run: async (dbPath, cfg) => {
        const priority = new SharedArrayBuffer(8);
        const builder = new SaidBuilder(dbPath, { priority, readers: cfg });
        try {
          await builder.ready([saidSeed.longThread, saidSeed.shortThread]);
          assert.equal(Atomics.load(new Int32Array(priority), 1), 0, "permit released");
          return snapshotSaid(dbPath);
        } finally {
          await builder.close();
        }
      },
    },
    {
      mode: "cc-index",
      seedPath: ccSeed,
      useConfig: false, // STILLFAIL_READER_CC_INDEX=pion
      run: async (dbPath, cfg) => {
        const builder = new CcIndexBuilder(dbPath, { readers: cfg });
        try {
          await builder.ready(["long", "short", "none"]);
          await builder.readyNames(["long", "short"]);
          await builder.readyLatest(["long", "short"]);
          return snapshotCc(dbPath);
        } finally {
          await builder.close();
        }
      },
    },
    {
      mode: "usage-check",
      seedPath: usageSeed,
      useConfig: true, // config.readers["usage-check"] = "pion"
      run: async (dbPath, cfg) => {
        const reader = new MinuteReader(dbPath, { readers: cfg });
        try {
          const out: string[] = [];
          const said = (p: Promise<void>) => p.then(() => "ok", (e: Error) => e.message);
          for (const v of [null, { workspace: "A", home: false }, { workspace: "B", home: true }]) {
            out.push(await said(reader.readyChats(v)));
          }
          out.push(await said(reader.readyRemote()));
          return JSON.stringify(out);
        } finally {
          await reader.close();
        }
      },
    },
  ];

  for (const c of cases) {
    // 1. Default `mb` spawns MB reader only.
    clearSpawns(mbLog);
    clearSpawns(pionLog);
    const mbDb = join(dir, `${c.mode}-mb.db`);
    copyFileSync(c.seedPath, mbDb);
    const mbOut = await withEnv(cleanEnv, () => c.run(mbDb));
    assert.ok(
      readSpawns(mbLog).some((l) => l.includes(`--builder ${c.mode}`)),
      `${c.mode}: default mb must spawn MB reader`,
    );
    assert.equal(readSpawns(pionLog).length, 0, `${c.mode}: default mb must not spawn Pion`);

    // 2. Switch to Pion via env or config.readers.
    clearSpawns(mbLog);
    clearSpawns(pionLog);
    const pionDb = join(dir, `${c.mode}-pion.db`);
    copyFileSync(c.seedPath, pionDb);
    const envForPion: Record<string, string | undefined> = { ...cleanEnv };
    if (!c.useConfig) envForPion[readerModeEnvKey(c.mode)] = "pion";
    const cfgForPion: (() => ReaderSelectConfig) | undefined = c.useConfig
      ? () => ({ readers: { [c.mode]: "pion" } })
      : undefined;

    const pionOut = await withEnv(envForPion, async () => {
      const supported = await probePionSupportedModes(pionWrap);
      assert.ok(supported !== null && supported.has(c.mode), `${c.mode}: probed stillfail-pion must advertise ${c.mode}`);
      clearSpawns(pionLog);
      return c.run(pionDb, cfgForPion);
    });
    assert.equal(readSpawns(mbLog).length, 0, `${c.mode}: pion switch must NOT spawn MB reader`);
    assert.ok(
      readSpawns(pionLog).some((l) => l.includes(`--builder ${c.mode}`)),
      `${c.mode}: pion switch must spawn real stillfail-pion`,
    );
    assert.equal(pionOut, mbOut, `${c.mode}: Pion output/tables must match MB 0-diff`);
  }

  // 3. Legacy Pion stub omitting `modes:` -> safe fallback to MB + 1 deduped warn per mode.
  const logs: Line[] = [];
  hearLines((l) => logs.push(l));
  try {
    await withEnv(
      {
        ...cleanEnv,
        STILLFAIL_PION_READER: legacyStub,
        STILLFAIL_READER_ENGINE: "pion",
      },
      async () => {
        const supported = await probePionSupportedModes(legacyStub);
        assert.ok(supported !== null, "legacy stub --version probe must succeed");
        for (const mode of REQUESTED_MODES) {
          assert.equal(supported.has(mode), false, `legacy stub must not advertise ${mode}`);
        }
        clearSpawns(legacyLog);
        for (const c of cases) {
          clearSpawns(mbLog);
          const fbDb = join(dir, `${c.mode}-fb.db`);
          copyFileSync(c.seedPath, fbDb);
          await c.run(fbDb);
          assert.ok(
            readSpawns(mbLog).some((l) => l.includes(`--builder ${c.mode}`)),
            `${c.mode}: legacy stub must fall back to MB reader`,
          );
        }
        assert.equal(readSpawns(legacyLog).length, 0, "legacy stub must never be spawned for unsupported modes");
      },
    );
    const warns = logs.filter(
      (l) => l.level === "WARN" && l.message === "reader engine fallback" && l.fields.reason === "pion-binary-unsupported-mode",
    );
    assert.deepStrictEqual(
      warns.map((w) => w.fields.mode).sort(),
      [...REQUESTED_MODES].sort(),
      `expected exactly 1 deduped fallback warn per mode, got ${JSON.stringify(warns.map((w) => w.fields.mode))}`,
    );
  } finally {
    hearLines(null);
  }
});

// ── Test 2: Permit cancel(A)+ask(B) interleaving & cross-token delete safety (MB vs Pion 0-diff) ──

test("turn-counts & said: Permit cancel(A)+ask(B) same-chunk interleaving and cross-token delete safety (MB vs Pion 0-diff)", async (t) => {
  const bins = resolveBinaries(t);
  if (!bins) return;
  const dir = freshDir("permit-interleave-");

  // 2a. turn-counts: same-chunk cancel(A)+ask(B) with late grant, late deny, and cross-token protection.
  const turnsSeed = makeTurnCountsSeed(dir, "interleave");
  for (const [label, bin] of [
    ["mb", bins.realMb],
    ["pion", bins.realPion],
  ] as const) {
    // Late grant
    {
      const dbPath = join(dir, `tc-grant-${label}.db`);
      copyFileSync(turnsSeed, dbPath);
      const db = new DatabaseSync(dbPath);
      const proc = new RawLineProc(bin, ["--builder", "turn-counts", "--db", dbPath]);
      try {
        proc.writeRaw('{"session":"A"}\n');
        assert.deepStrictEqual(await proc.nextJson(), { take: true });
        proc.writeRaw('{"permit":true}\n');
        assert.deepStrictEqual(await proc.nextJson(), { done: false });
        assert.equal(
          (db.prepare("SELECT count(*) AS n FROM session_turns_guard WHERE session='A'").get() as { n: number }).n,
          1,
        );

        // Same chunk: cancel(A) + ask(B) + empty line
        proc.writeRaw('\n{"session":"A","cancel":true}\n{"session":"B"}\n');
        assert.deepStrictEqual(await proc.nextJson(), { take: true }, `${label}: cancel(A) asks permit`);
        proc.writeRaw('{"permit":true}\n');
        assert.deepStrictEqual(await proc.nextJson(), { give: true }, `${label}: cancel(A) gives permit`);
        assert.equal(
          (db.prepare("SELECT count(*) AS n FROM session_turns_guard WHERE session='A'").get() as { n: number }).n,
          0,
          `${label}: A guard deleted`,
        );
        // Deferred B now asks permit
        assert.deepStrictEqual(await proc.nextJson(), { take: true }, `${label}: deferred B asks permit`);
        proc.writeRaw('{"permit":true}\n');
        assert.deepStrictEqual(await proc.nextJson(), { done: false }, `${label}: deferred B step 1`);
        assert.equal((await proc.finish()).code, 0);
      } finally {
        await proc.kill();
        db.close();
      }
    }

    // Cross-token delete ineffective: replace A's guard token externally before cancel(A).
    {
      const dbPath = join(dir, `tc-xtoken-${label}.db`);
      copyFileSync(turnsSeed, dbPath);
      const db = new DatabaseSync(dbPath);
      const proc = new RawLineProc(bin, ["--builder", "turn-counts", "--db", dbPath]);
      try {
        proc.writeRaw('{"session":"A"}\n');
        assert.deepStrictEqual(await proc.nextJson(), { take: true });
        proc.writeRaw('{"permit":true}\n');
        assert.deepStrictEqual(await proc.nextJson(), { done: false });
        const origTok = (db.prepare("SELECT token FROM session_turns_guard WHERE session='A'").get() as { token: string }).token;
        assert.match(origTok, /^\d+-\d+-\d+$/, `${label}: guard token format <wall_ms>-<seq>-<pid>`);

        db.prepare("UPDATE session_turns_guard SET token='foreign-token' WHERE session='A'").run();
        proc.writeRaw('{"session":"A","cancel":true}\n');
        assert.deepStrictEqual(await proc.nextJson(), { take: true });
        proc.writeRaw('{"permit":true}\n');
        assert.deepStrictEqual(await proc.nextJson(), { give: true });
        const remaining = db.prepare("SELECT token FROM session_turns_guard WHERE session='A'").get() as { token: string } | undefined;
        assert.equal(remaining?.token, "foreign-token", `${label}: cross-token cancel must NOT delete foreign guard`);
        assert.equal((await proc.finish()).code, 0);
      } finally {
        await proc.kill();
        db.close();
      }
    }
  }

  // 2b. said: same-chunk cancel(long)+ask(short), cross-token protection, and ready=1 guard preservation.
  const saidSeed = makeSaidSeed(dir, "interleave");
  for (const [label, bin] of [
    ["mb", bins.realMb],
    ["pion", bins.realPion],
  ] as const) {
    const dbPath = join(dir, `said-xtoken-${label}.db`);
    copyFileSync(saidSeed.path, dbPath);
    const db = new DatabaseSync(dbPath);
    const proc = new RawLineProc(bin, ["--builder", "said", "--db", dbPath]);
    try {
      proc.writeRaw(`${JSON.stringify({ thread: saidSeed.longThread })}\n`);
      assert.deepStrictEqual(await proc.nextJson(), { take: true });
      proc.writeRaw('{"permit":true}\n');
      assert.deepStrictEqual(await proc.nextJson(), { done: false });
      const origTok = (
        db.prepare("SELECT token FROM said_state_guard WHERE thread=?").get(saidSeed.longThread) as { token: string }
      ).token;
      assert.match(origTok, /^\d+-\d+-\d+$/, `${label}: said guard token format`);

      // Mark ready=1 -> cancel must NOT delete ready=1 guard even with matching token
      db.prepare("UPDATE said_state_guard SET ready=1 WHERE thread=?").run(saidSeed.longThread);
      proc.writeRaw(`${JSON.stringify({ thread: saidSeed.longThread, cancel: true })}\n${JSON.stringify({ thread: saidSeed.shortThread })}\n`);
      assert.deepStrictEqual(await proc.nextJson(), { take: true });
      proc.writeRaw('{"permit":true}\n');
      assert.deepStrictEqual(await proc.nextJson(), { give: true });
      const readyRow = db.prepare("SELECT token, ready FROM said_state_guard WHERE thread=?").get(saidSeed.longThread) as
        | { token: string; ready: number }
        | undefined;
      assert.equal(readyRow?.token, origTok, `${label}: cancel must NOT delete ready=1 guard`);
      assert.equal(readyRow?.ready, 1);

      // Deferred shortThread now asks permit
      assert.deepStrictEqual(await proc.nextJson(), { take: true });
      proc.writeRaw('{"permit":true}\n');
      assert.deepStrictEqual(await proc.nextJson(), { done: false });

      // Cross-token check on shortThread (ready=0, but token replaced)
      db.prepare("UPDATE said_state_guard SET token='foreign-said-token' WHERE thread=?").run(saidSeed.shortThread);
      proc.writeRaw(`${JSON.stringify({ thread: saidSeed.shortThread, cancel: true })}\n`);
      assert.deepStrictEqual(await proc.nextJson(), { take: true });
      proc.writeRaw('{"permit":true}\n');
      assert.deepStrictEqual(await proc.nextJson(), { give: true });
      const shortRow = db.prepare("SELECT token FROM said_state_guard WHERE thread=?").get(saidSeed.shortThread) as
        | { token: string }
        | undefined;
      assert.equal(shortRow?.token, "foreign-said-token", `${label}: cross-token said cancel must NOT delete foreign guard`);
      assert.equal((await proc.finish()).code, 0);
    } finally {
      await proc.kill();
      db.close();
    }
  }
});

// ── Test 3: cc-index latest priority, independent cancel, existing=false, and invalid request parity ──

test("cc-index: latest priority over name, latest ignores cancel, independent cc/names cancel, and error messages (MB vs Pion 0-diff)", async (t) => {
  const bins = resolveBinaries(t);
  if (!bins) return;
  const dir = freshDir("cc-parity-");
  const seed = makeCcSeed(dir, "parity");
  const mbDb = join(dir, "cc-mb.db");
  const pionDb = join(dir, "cc-pion.db");
  copyFileSync(seed, mbDb);
  copyFileSync(seed, pionDb);

  const mbProc = new RawLineProc(bins.realMb, ["--builder", "cc-index", "--db", mbDb]);
  const pionProc = new RawLineProc(bins.realPion, ["--builder", "cc-index", "--db", pionDb]);
  try {
    const asks = [
      "", // empty line skipped silently
      '{"session":null}', // invalid request
      "{bad-json", // invalid request
      '{"session":"ghost-session"}', // plain cc step uses existing=false -> tracks ghost-session
      '{"session":"long"}',
      '{"session":"long","cancel":true}', // cancels cc lane
      '{"session":"long","name":true}',
      '{"session":"long","name":true,"cancel":true}', // cancels names lane
      '{"session":"long","name":true,"latest":true,"cancel":true}', // latest ignores cancel
      '{"session":"long","name":true,"latest":true}', // latest takes priority over name
    ];
    for (const raw of asks) {
      mbProc.writeRaw(`${raw}\n`);
      pionProc.writeRaw(`${raw}\n`);
      if (raw === "" || raw.includes('"cancel":true')) continue;
      const [m, p] = await Promise.all([mbProc.nextJson(), pionProc.nextJson()]);
      assert.deepStrictEqual(p, m, `cc-index mismatch on ask ${raw}`);
    }
    // Verify ghost-session was tracked in cc_sessions in both
    assert.equal(snapshotCc(pionDb), snapshotCc(mbDb), "cc-index tables 0-diff");
    assert.equal((await mbProc.finish()).code, 0);
    assert.equal((await pionProc.finish()).code, 0);
  } finally {
    await Promise.all([mbProc.kill(), pionProc.kill()]);
  }
});

// ── Test 4: usage-check startup complete() failure exit code & empty stdout, id repr/Int64, chats/home dispatch ──

test("usage-check: startup failure exit/stdout parity, complete banner, id numeric repr/Int64 boundaries, chats/home dispatch (MB vs Pion 0-diff)", async (t) => {
  const bins = resolveBinaries(t);
  if (!bins) return;
  const dir = freshDir("usage-parity-");

  // 4a. Startup complete() failure: corrupt remote_run_progress (missing `done` column) -> both exit non-zero with empty stdout.
  {
    const badDb = makeUsageSeed(dir, "bad-startup", "DROP TABLE remote_run_progress; CREATE TABLE remote_run_progress(id INTEGER PRIMARY KEY);");
    const mbProc = new RawLineProc(bins.realMb, ["--builder", "usage-check", "--db", badDb]);
    const pionProc = new RawLineProc(bins.realPion, ["--builder", "usage-check", "--db", badDb]);
    try {
      const [mbLine, pionLine] = await Promise.all([mbProc.nextLine(), pionProc.nextLine()]);
      const [mbExit, pionExit] = await Promise.all([mbProc.waitExit(), pionProc.waitExit()]);
      assert.equal(mbLine, null, "MB must emit empty stdout on startup complete() failure");
      assert.equal(pionLine, null, "Pion must emit empty stdout on startup complete() failure");
      assert.equal(mbExit.trailing, "", "MB trailing stdout must be empty");
      assert.equal(pionExit.trailing, "", "Pion trailing stdout must be empty");
      assert.notEqual(mbExit.code, 0, "MB must exit non-zero on startup failure");
      assert.equal(pionExit.code, mbExit.code, "Pion exit code must match MB on startup failure");
    } finally {
      await Promise.all([mbProc.kill(), pionProc.kill()]);
    }
  }

  // 4b. Fresh DB (complete=true): emits {"complete":true} first, then keeps answering stdin lines.
  {
    const freshDb = makeUsageSeed(dir, "fresh-complete");
    const mbProc = new RawLineProc(bins.realMb, ["--builder", "usage-check", "--db", freshDb]);
    const pionProc = new RawLineProc(bins.realPion, ["--builder", "usage-check", "--db", freshDb]);
    try {
      const [mbBanner, pionBanner] = await Promise.all([mbProc.nextLine(), pionProc.nextLine()]);
      assert.equal(mbBanner, '{"complete":true}');
      assert.equal(pionBanner, mbBanner);
      mbProc.writeRaw('{"id":9007199254740993,"remote":true}\n');
      pionProc.writeRaw('{"id":9007199254740993,"remote":true}\n');
      const [mbAns, pionAns] = await Promise.all([mbProc.nextLine(), pionProc.nextLine()]);
      assert.equal(mbAns, '{"id":9007199254740993}');
      assert.equal(pionAns, mbAns);
      assert.equal((await mbProc.finish()).code, 0);
      assert.equal((await pionProc.finish()).code, 0);
    } finally {
      await Promise.all([mbProc.kill(), pionProc.kill()]);
    }
  }

  // 4c. Incomplete DB: exact raw line 0-diff on numeric id repr, Int64 boundaries, missing id, invalid JSON, home literal false vs truthy/0/null/"false".
  {
    const dirtyDb = makeUsageSeed(
      dir,
      "dirty-repr",
      "UPDATE remote_run_progress SET done = 0; INSERT INTO usage_chat_dirty_scope(session, kind, ws) VALUES ('h', 1, '')",
    );
    const mbProc = new RawLineProc(bins.realMb, ["--builder", "usage-check", "--db", dirtyDb]);
    const pionProc = new RawLineProc(bins.realPion, ["--builder", "usage-check", "--db", dirtyDb]);
    try {
      const lines = [
        "", // empty line skipped silently
        '{"id":9007199254740993,"chats":{"workspace":"A","home":false}}',
        '{"id":9223372036854775808,"chats":{"workspace":"A","home":true}}',
        '{"id":-9223372036854775808,"chats":{"workspace":"A","home":0}}',
        '{"id":1e400,"chats":{"workspace":"A","home":"false"}}',
        '{"id":"str-id","chats":{"workspace":"A","home":null}}',
        '{"chats":null}', // missing id -> null
        '{"id":7,"remote":true}',
        "{not-json", // invalid JSON -> remote_ready with id: null
      ];
      for (const raw of lines) {
        mbProc.writeRaw(`${raw}\n`);
        pionProc.writeRaw(`${raw}\n`);
        if (raw === "") continue;
        const [mRaw, pRaw] = await Promise.all([mbProc.nextLine(), pionProc.nextLine()]);
        assert.equal(pRaw, mRaw, `usage-check raw JSON mismatch for ${raw}`);
      }
      assert.equal((await mbProc.finish()).code, 0);
      assert.equal((await pionProc.finish()).code, 0);
    } finally {
      await Promise.all([mbProc.kill(), pionProc.kill()]);
    }
  }
});

// ── Test 5: Invalid request error message parity across all 4 modes ──

test("builders_requested: invalid request error messages match MB 0-diff across all 4 modes", async (t) => {
  const bins = resolveBinaries(t);
  if (!bins) return;
  const dir = freshDir("err-msg-");
  const dbPath = makeUsageSeed(dir, "err", "UPDATE remote_run_progress SET done = 0");

  const checks: Array<{ mode: ReaderMode; input: string; wantError: string }> = [
    { mode: "turn-counts", input: '{"session":123}', wantError: "invalid old turn counts preparation request" },
    { mode: "said", input: '{"thread":"nope"}', wantError: "invalid sidebar said state preparation request" },
    { mode: "cc-index", input: '{"session":false}', wantError: "invalid session conversation preparation request" },
    { mode: "usage-check", input: "{bad", wantError: "historical remote task statistics are unavailable" },
  ];

  for (const c of checks) {
    const mbProc = new RawLineProc(bins.realMb, ["--builder", c.mode, "--db", dbPath]);
    const pionProc = new RawLineProc(bins.realPion, ["--builder", c.mode, "--db", dbPath]);
    try {
      mbProc.writeRaw(`${c.input}\n`);
      pionProc.writeRaw(`${c.input}\n`);
      const [m, p] = await Promise.all([mbProc.nextJson(), pionProc.nextJson()]);
      assert.deepStrictEqual(p, m, `${c.mode}: mismatch on ${c.input}`);
      assert.equal(p.error, c.wantError, `${c.mode}: expected exact error text`);
      assert.equal((await mbProc.finish()).code, 0);
      assert.equal((await pionProc.finish()).code, 0);
    } finally {
      await Promise.all([mbProc.kill(), pionProc.kill()]);
    }
  }
});

// ── Test 6: Static SQLite lexical transaction guard + real closure-body mutation detection ──

function findRawTxViolations(filename: string, source: string): string[] {
  const violations: string[] = [];
  const forbidden = new Set(["BEGIN", "COMMIT", "END", "SAVEPOINT", "RELEASE", "ROLLBACK"]);
  const strRe = /"(?:\\.|[^"\\])*"/g;
  const lines = source.split("\n");
  for (let idx = 0; idx < lines.length; idx++) {
    const line = lines[idx]!;
    const stripped = line.replace(/\/\/.*$/, "");
    for (const m of stripped.matchAll(strRe)) {
      const lit = m[0].slice(1, -1);
      const upper = lit.trim().toUpperCase();
      for (const kw of forbidden) {
        if (new RegExp(`(?:^|;)\\s*${kw}\\b`).test(upper)) {
          violations.push(`${filename}:${idx + 1}: forbidden raw tx SQL "${kw}" in ${m[0]}`);
        }
      }
    }
  }
  return violations;
}

test("builders_requested static SQLite transaction guard: 0 violations and catches real closure-body mutations", () => {
  const srcDir = resolve(fileURLToPath(new URL("../../pion/station/packages/builders_requested/src", import.meta.url)));
  const files = readdirSync(srcDir)
    .filter((f) => f.endsWith(".pion") && !f.endsWith("_test.pion"))
    .sort();
  assert.deepStrictEqual(files, ["cc_index.pion", "said.pion", "turn_counts.pion", "usage_check.pion"]);

  for (const file of files) {
    const src = readFileSync(join(srcDir, file), "utf8");
    assert.deepStrictEqual(
      findRawTxViolations(file, src),
      [],
      `${file} must contain zero raw transaction SQL`,
    );
  }

  // Real in-memory closure-body mutations must be detected on all 4 files.
  const mutations: Array<{ file: string; needle: string; inject: string }> = [
    { file: "turn_counts.pion", needle: "fn(tx : sql_db::Db)", inject: 'let _ = tx.exec("COMMIT")' },
    { file: "said.pion", needle: "fn(sp : sql_db::Db)", inject: 'let _ = sp.exec("RELEASE said_scan")' },
    { file: "cc_index.pion", needle: "fn(tx : sql_db::Db)", inject: 'let _ = tx.exec("BEGIN IMMEDIATE")' },
    { file: "usage_check.pion", needle: "pub fn usage_complete(", inject: 'let _ = db.exec("SAVEPOINT bad_sp")' },
  ];
  for (const mut of mutations) {
    const src = readFileSync(join(srcDir, mut.file), "utf8");
    const pos = src.indexOf(mut.needle);
    assert.ok(pos >= 0, `expected ${mut.needle} in ${mut.file}`);
    const mutated = src.slice(0, pos) + mut.inject + "\n" + src.slice(pos);
    const hits = findRawTxViolations(mut.file, mutated);
    assert.ok(hits.length > 0, `expected static guard to catch injected raw tx SQL in ${mut.file}`);
  }
});
