// Real dual-engine production switch, stateful trigger/schema-change, SIGKILL restart,
// Int64 saturation, SQLITE_BUSY, and static transaction guard tests for `builders_stateful`:
//   archive-last, page-letters.
//
// Invariants verified WITHOUT ever passing an explicit `binary` override to any production builder:
// 1. Default `mb` genuinely spawns the real MoonBit `stillfail-reader` binary (never `stillfail-pion`).
// 2. Switching via `STILLFAIL_READER_ARCHIVE_LAST=pion` or `config.readers["page-letters"]="pion"`
//    (once the non-blocking `--version` capability probe resolves) genuinely spawns the real
//    `stillfail-pion` binary through `Readers.prepareArchiveLast` / `Readers.preparePageLetters`
//    and produces 0-diff SQLite tables + `sqlite_master` (including trigger DDL) against MoonBit.
// 3. A legacy `stillfail-pion` binary omitting `modes:` from `--version` safely falls back to MB
//    and logs one deduped `pion-binary-unsupported-mode` warning per mode.
// 4. Within one long-lived builder process, an external trigger drop/tamper (bumping
//    `PRAGMA schema_version`) invalidates the cached install state, triggers automatic reinstall
//    with a new epoch, and keeps full tables + `sqlite_master` 0-diff against MoonBit.
// 5. Mid-flight `SIGKILL` during multi-batch execution followed by process restart resumes cleanly
//    to `done === true` with 0-diff tables + `sqlite_master`.
// 6. Int64 upper-bound saturation (`9223372036854775808`, `1e400`), invalid/duplicate-key requests,
//    and deterministic `SQLITE_BUSY` held-lock recovery match MoonBit 0-diff.
// 7. Single-pass SQLite lexical transaction guard scans `builders_stateful/src/*.pion` with zero
//    violations and catches real in-memory mutations (`tx_db.exec("COMMIT")`) on both files.
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
import {
  mbReaderBinary,
  pionBinary,
  probePionSupportedModes,
  resetReaderSelectionStateForTest,
} from "../src/read/mb-reader.ts";
import { Readers } from "../src/read/pool.ts";
import { type ReaderMode, readerModeEnvKey, type ReaderSelectConfig } from "../src/read/reader-select.ts";
import { Store } from "../src/store/store.ts";

const STATEFUL_MODES: readonly ReaderMode[] = ["archive-last", "page-letters"];
const ASK_TIMEOUT_MS = 30_000;
const MB_FAIL_PREFIX = /^\S+:\d+:\d+-\d+:\d+@\S+ FAILED: /;
const HEX32_RE = /^[0-9a-f]{32}$/;

const tempDirs: string[] = [];
after(() => {
  for (const dir of tempDirs) rmSync(dir, { recursive: true, force: true });
});

function freshDir(prefix = "builders-stateful-switch-"): string {
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

function normalizeErr(res: Record<string, unknown>): Record<string, unknown> {
  if (typeof res.error === "string") {
    return { ...res, error: res.error.replace(MB_FAIL_PREFIX, "") };
  }
  return res;
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

type Waiter = {
  resolve: (res: Record<string, unknown>) => void;
  reject: (err: Error) => void;
  timer: NodeJS.Timeout;
};

class BuilderProc {
  readonly #child: ChildProcess;
  readonly #waiting: Waiter[] = [];
  #carry: Buffer = Buffer.alloc(0);
  #stderr = "";
  #ending = false;
  #protocolError: Error | null = null;
  readonly #closed: Promise<{ code: number | null; signal: NodeJS.Signals | null }>;

  constructor(binary: string, mode: ReaderMode, dbPath: string) {
    const child = spawn(binary, ["--builder", mode, "--db", dbPath], {
      stdio: ["pipe", "pipe", "pipe"],
      windowsHide: true,
    });
    this.#child = child;
    child.stdin!.on("error", () => {});
    child.stderr!.on("data", (c: Buffer) => { this.#stderr += c.toString("utf8"); });
    child.stdout!.on("data", (c: Buffer) => this.#onData(c));
    this.#closed = new Promise((done) => {
      let ended = false;
      const finish = (code: number | null, signal: NodeJS.Signals | null) => {
        if (ended) return;
        ended = true;
        if (!this.#ending) {
          this.#fail(`builder ${mode} exited unexpectedly (code=${code}, signal=${signal}); stderr=${this.#stderr}`);
        }
        this.#rejectAll(new Error(`builder ${mode} exited (code=${code}, signal=${signal}); stderr=${this.#stderr}`));
        done({ code, signal });
      };
      child.on("error", (err) => {
        this.#fail(`builder ${mode} spawn error: ${err.message}`);
        if (child.pid === undefined) finish(null, null);
      });
      child.on("close", (code, signal) => finish(code, signal));
    });
  }

  #rejectAll(err: Error) {
    for (const w of this.#waiting.splice(0)) {
      clearTimeout(w.timer);
      w.reject(err);
    }
  }

  #fail(msg: string) {
    if (this.#protocolError === null) this.#protocolError = new Error(msg);
    this.#rejectAll(this.#protocolError);
    this.#child.kill("SIGKILL");
  }

  #onData(chunk: Buffer) {
    this.#carry = this.#carry.length === 0 ? chunk : Buffer.concat([this.#carry, chunk]);
    for (let nl = this.#carry.indexOf(0x0a); nl >= 0; nl = this.#carry.indexOf(0x0a)) {
      const line = this.#carry.subarray(0, nl).toString("utf8");
      this.#carry = this.#carry.subarray(nl + 1);
      let parsed: Record<string, unknown>;
      try {
        parsed = normalizeErr(JSON.parse(line) as Record<string, unknown>);
      } catch {
        return this.#fail(`stdout emitted non-JSON line: ${JSON.stringify(line.slice(0, 200))}`);
      }
      const w = this.#waiting.shift();
      if (w === undefined) return this.#fail(`stdout emitted unsolicited line: ${line.slice(0, 200)}`);
      clearTimeout(w.timer);
      w.resolve(parsed);
    }
  }

  ask(rawLine: string): Promise<Record<string, unknown>> {
    if (this.#protocolError !== null) return Promise.reject(this.#protocolError);
    return new Promise((resolveAsk, rejectAsk) => {
      const timer = setTimeout(() => {
        this.#fail(`ask timed out after ${ASK_TIMEOUT_MS}ms; stderr=${this.#stderr}`);
      }, ASK_TIMEOUT_MS);
      this.#waiting.push({ resolve: resolveAsk, reject: rejectAsk, timer });
      this.#child.stdin!.write(`${rawLine}\n`, (err) => {
        if (err) this.#fail(`stdin write failed: ${err.message}`);
      });
    });
  }

  async end(): Promise<void> {
    this.#ending = true;
    try {
      if (this.#protocolError !== null) throw this.#protocolError;
      assert.equal(this.#waiting.length, 0, "no ask left unanswered");
      this.#child.stdin!.end();
      const { code, signal } = await this.#closed;
      assert.equal(signal, null, `ended by signal ${signal}; stderr=${this.#stderr}`);
      assert.equal(code, 0, `exit code ${code}; stderr=${this.#stderr}`);
      assert.equal(this.#carry.length, 0, `trailing stdout bytes: ${this.#carry.toString("utf8")}`);
    } finally {
      this.#rejectAll(new Error("proc ended"));
      if (this.#child.exitCode === null && this.#child.signalCode === null) this.#child.kill("SIGKILL");
    }
  }

  async sigkill(): Promise<void> {
    this.#ending = true;
    this.#rejectAll(new Error("killed"));
    // Deliver SIGKILL before tearing down stdin so the child cannot observe EOF and exit 0 first.
    this.#child.kill("SIGKILL");
    const { signal } = await this.#closed;
    this.#child.stdin!.destroy();
    assert.equal(signal, "SIGKILL", `expected SIGKILL exit, got signal=${signal}`);
  }
}

function makeArchiveLastSeed(dir: string, label: string): { seedPath: string; threads: number[] } {
  const seedPath = join(dir, `${label}-seed.db`);
  const store = Store.open(seedPath, join(dir, `${label}-archive`));
  try {
    const put = store.db.prepare(
      "INSERT INTO entries(thread,n,kind,author_kind,author,text,ts,at,letter) VALUES(?,?,?,'person','me','x',?,?,?)",
    );
    const threads = [260, 150, 3, 0, -1].map((tail, i) => {
      const thread = store.openThread("ember", "CHAT", `${label}-${i}`, null, "me").id;
      store.db.exec("BEGIN");
      if (tail >= 0) put.run(thread, 1, "message", `m${i}`, 100 + i, null);
      for (let n = 2; n <= Math.max(tail, 3) + 1 && tail !== 0; n++) {
        put.run(thread, n, "edit", `e${i}-${n}`, n, n % 3 === 0 ? "{}" : null);
      }
      store.db.exec("COMMIT");
      return thread;
    });
    store.db.exec("PRAGMA wal_checkpoint(TRUNCATE)");
    return { seedPath, threads };
  } finally {
    store.close();
  }
}

function makePageLettersSeed(dir: string, label: string, dropIndex = false): { seedPath: string; threads: number[] } {
  const seedPath = join(dir, `${label}-seed.db`);
  const store = Store.open(seedPath, join(dir, `${label}-archive`));
  try {
    const put = store.db.prepare(
      "INSERT INTO entries(thread,n,kind,letter,ts,author_kind,author,text,at) VALUES(?,?,?,?,?,'agent','a','x',?)",
    );
    const threads = [320, 180, 3].map((size, i) => {
      const thread = store.openThread("ember", "CHAT", `${label}-${i}`, null, null).id;
      store.db.exec("BEGIN");
      for (let n = 1; n <= size; n++) {
        put.run(thread, n, n % 4 === 0 ? "status" : "message", n % 3 === 0 ? null : "{}", `t${i}-${n}`, n);
      }
      store.db.exec("COMMIT");
      return thread;
    });
    if (dropIndex) store.db.exec("DROP INDEX entries_letters");
    store.db.exec("PRAGMA wal_checkpoint(TRUNCATE)");
    return { seedPath, threads };
  } finally {
    store.close();
  }
}

function snapshotArchiveLast(dbPath: string): string {
  const db = new DatabaseSync(dbPath);
  try {
    const master = db.prepare("SELECT type, name, tbl_name, sql FROM sqlite_master ORDER BY type, name").all();
    const meta = db.prepare("SELECT id, version, epoch FROM archive_last_meta ORDER BY id").all() as {
      id: number;
      version: number;
      epoch: string;
    }[];
    assert.equal(meta.length, 1, "archive_last_meta must have 1 row");
    assert.match(meta[0]!.epoch, HEX32_RE, `archive_last_meta.epoch must be 32-char hex, got ${meta[0]!.epoch}`);
    const guards = db.prepare(
      "SELECT typeof(thread) AS ty, CAST(thread AS TEXT) AS thread, epoch, before_n, at, ready FROM archive_last_guard ORDER BY thread",
    ).all() as { ty: string; thread: string; epoch: string; before_n: number | null; at: number | null; ready: number }[];
    for (const g of guards) {
      assert.equal(g.epoch, meta[0]!.epoch, `guard epoch must match current meta epoch for thread ${g.thread}`);
    }
    return JSON.stringify({
      master,
      metaVersion: meta[0]!.version,
      guards: guards.map(({ ty, thread, before_n, at, ready }) => ({ ty, thread, before_n, at, ready })),
    });
  } finally {
    db.close();
  }
}

function snapshotPageLetters(dbPath: string): string {
  const db = new DatabaseSync(dbPath);
  try {
    const master = db.prepare("SELECT type, name, tbl_name, sql FROM sqlite_master ORDER BY type, name").all();
    const meta = db.prepare("SELECT id, version, epoch FROM page_letter_meta ORDER BY id").all() as {
      id: number;
      version: number;
      epoch: number;
    }[];
    assert.equal(meta.length, 1, "page_letter_meta must have 1 row");
    const scopes = db.prepare(
      "SELECT typeof(thread) AS ty, CAST(thread AS TEXT) AS thread, token, epoch, cursor_n, end_n, complete FROM page_letter_scopes ORDER BY thread",
    ).all() as {
      ty: string;
      thread: string;
      token: string;
      epoch: number;
      cursor_n: number | null;
      end_n: number | null;
      complete: number;
    }[];
    const tokenByThread = new Map<string, string>();
    for (const s of scopes) {
      assert.match(s.token, HEX32_RE, `scope token must be 32-char hex, got ${s.token}`);
      tokenByThread.set(s.thread, s.token);
    }
    const rows = db.prepare(
      "SELECT CAST(thread AS TEXT) AS thread, token, n FROM page_letter_rows ORDER BY thread, n",
    ).all() as { thread: string; token: string; n: number }[];
    const dirty = db.prepare(
      "SELECT CAST(thread AS TEXT) AS thread, token, n FROM page_letter_dirty ORDER BY thread, n",
    ).all() as { thread: string; token: string; n: number }[];
    const garbage = db.prepare(
      "SELECT CAST(thread AS TEXT) AS thread, token FROM page_letter_garbage ORDER BY thread, token",
    ).all() as { thread: string; token: string }[];
    for (const g of garbage) {
      assert.match(g.token, HEX32_RE, `garbage token must be 32-char hex, got ${g.token}`);
    }
    // Map each active token to "active" and non-active tokens (e.g. from older epochs in garbage) to "stale",
    // then sort deterministically by (thread, n, tok) so random hex token ordering never perturbs ties.
    const tagToken = (thread: string, token: string) => (tokenByThread.get(thread) === token ? "active" : "stale");
    const cmpTagged = (
      a: { thread: string; tok: string; n: number },
      b: { thread: string; tok: string; n: number },
    ) => (a.thread < b.thread ? -1 : a.thread > b.thread ? 1 : a.n - b.n || (a.tok < b.tok ? -1 : a.tok > b.tok ? 1 : 0));
    return JSON.stringify({
      master,
      meta,
      scopes: scopes.map(({ ty, thread, epoch, cursor_n, end_n, complete }) => ({
        ty,
        thread,
        epoch,
        cursor_n,
        end_n,
        complete,
      })),
      rows: rows.map((r) => ({ thread: r.thread, tok: tagToken(r.thread, r.token), n: r.n })).sort(cmpTagged),
      dirty: dirty.map((d) => ({ thread: d.thread, tok: tagToken(d.thread, d.token), n: d.n })).sort(cmpTagged),
      garbageCountByThread: garbage.reduce<Record<string, number>>((acc, g) => {
        acc[g.thread] = (acc[g.thread] ?? 0) + 1;
        return acc;
      }, {}),
    });
  } finally {
    db.close();
  }
}

test("builders_stateful: real MB default, real Pion switch (env + config.readers) via Readers with 0-diff, and legacy stub fallback", { skip: skipPosix }, async (t) => {
  const bins = resolveBinaries(t);
  if (!bins) return;

  const dir = freshDir();
  const mbLog = join(dir, "mb-spawns.log");
  const pionLog = join(dir, "pion-spawns.log");
  const legacyLog = join(dir, "legacy-pion-spawns.log");
  const mbWrap = makeRecordingWrapper(dir, "wrap-mb", bins.realMb, mbLog);
  const pionWrap = makeRecordingWrapper(dir, "wrap-pion", bins.realPion, pionLog);
  const legacyStub = makeLegacyPionStub(dir, "stub-legacy-pion", legacyLog);

  const archiveSeed = makeArchiveLastSeed(dir, "switch-al");
  const lettersSeed = makePageLettersSeed(dir, "switch-pl");

  const cleanEnv: Record<string, string | undefined> = {
    STILLFAIL_MB_READER: mbWrap,
    STILLFAIL_PION_READER: pionWrap,
    STILLFAIL_READER_ENGINE: undefined,
    [readerModeEnvKey("archive-last")]: undefined,
    [readerModeEnvKey("page-letters")]: undefined,
  };

  type ModeCase = {
    readonly mode: ReaderMode;
    readonly seedPath: string;
    readonly useConfig: boolean;
    readonly run: (dataDir: string, cfg?: () => ReaderSelectConfig) => Promise<void>;
    readonly snap: (dbPath: string) => string;
  };

  const cases: readonly ModeCase[] = [
    {
      mode: "archive-last",
      seedPath: archiveSeed.seedPath,
      useConfig: false, // via STILLFAIL_READER_ARCHIVE_LAST=pion
      run: async (dataDir, cfg) => {
        const readers = new Readers(dataDir, 1, undefined, 1, cfg ? { readers: cfg } : {});
        try {
          await readers.prepareArchiveLast(archiveSeed.threads);
        } finally {
          readers.close();
        }
      },
      snap: snapshotArchiveLast,
    },
    {
      mode: "page-letters",
      seedPath: lettersSeed.seedPath,
      useConfig: true, // via config.readers["page-letters"] = "pion"
      run: async (dataDir, cfg) => {
        const readers = new Readers(dataDir, 1, undefined, 1, cfg ? { readers: cfg } : {});
        try {
          await readers.preparePageLetters(lettersSeed.threads);
        } finally {
          readers.close();
        }
      },
      snap: snapshotPageLetters,
    },
  ];

  for (const c of cases) {
    // 1. Default `mb`: spawns MB reader only, never Pion.
    clearSpawns(mbLog);
    clearSpawns(pionLog);
    const mbDir = join(dir, `${c.mode}-mb`);
    mkdirSync(mbDir, { recursive: true });
    const mbDb = join(mbDir, "stillfail.db");
    copyFileSync(c.seedPath, mbDb);
    await withEnv(cleanEnv, () => c.run(mbDir));
    const mbSpawns = readSpawns(mbLog);
    const pionSpawnsDefault = readSpawns(pionLog);
    assert.ok(
      mbSpawns.some((l) => l.includes(`--builder ${c.mode}`)),
      `${c.mode}: default mb must spawn MB reader, got ${JSON.stringify(mbSpawns)}`,
    );
    assert.equal(pionSpawnsDefault.length, 0, `${c.mode}: default mb must not spawn Pion`);
    const mbSnap = c.snap(mbDb);

    // 2. Switch to Pion via env (`STILLFAIL_READER_ARCHIVE_LAST=pion`) or `config.readers["page-letters"]="pion"`.
    clearSpawns(mbLog);
    clearSpawns(pionLog);
    const pionDir = join(dir, `${c.mode}-pion`);
    mkdirSync(pionDir, { recursive: true });
    const pionDb = join(pionDir, "stillfail.db");
    copyFileSync(c.seedPath, pionDb);
    const envForPion: Record<string, string | undefined> = { ...cleanEnv };
    if (!c.useConfig) envForPion[readerModeEnvKey(c.mode)] = "pion";
    const cfgForPion: (() => ReaderSelectConfig) | undefined = c.useConfig
      ? () => ({ readers: { [c.mode]: "pion" } })
      : undefined;

    await withEnv(envForPion, async () => {
      const supported = await probePionSupportedModes(pionWrap);
      assert.ok(supported !== null && supported.has(c.mode), `${c.mode}: probed stillfail-pion must advertise ${c.mode}`);
      clearSpawns(pionLog);
      await c.run(pionDir, cfgForPion);
    });
    const mbSpawnsPion = readSpawns(mbLog);
    const pionSpawns = readSpawns(pionLog);
    assert.equal(mbSpawnsPion.length, 0, `${c.mode}: pion switch must NOT spawn MB reader, got ${JSON.stringify(mbSpawnsPion)}`);
    assert.ok(
      pionSpawns.some((l) => l.includes(`--builder ${c.mode}`)),
      `${c.mode}: pion switch must spawn real stillfail-pion, got ${JSON.stringify(pionSpawns)}`,
    );
    assert.equal(c.snap(pionDb), mbSnap, `${c.mode}: Pion tables + sqlite_master must match MB 0-diff`);
  }

  // 3. Legacy Pion stub omitting `modes:` -> safe fallback to MB + deduped `pion-binary-unsupported-mode`.
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
        for (const mode of STATEFUL_MODES) {
          assert.equal(supported.has(mode), false, `legacy stub must not advertise ${mode}`);
        }
        clearSpawns(legacyLog);
        for (const c of cases) {
          clearSpawns(mbLog);
          const fbDir = join(dir, `${c.mode}-fb`);
          mkdirSync(fbDir, { recursive: true });
          copyFileSync(c.seedPath, join(fbDir, "stillfail.db"));
          await c.run(fbDir);
          const mbSpawns = readSpawns(mbLog);
          assert.ok(
            mbSpawns.some((l) => l.includes(`--builder ${c.mode}`)),
            `${c.mode}: legacy stub must fall back to MB reader`,
          );
        }
        assert.equal(readSpawns(legacyLog).length, 0, "legacy stub must never be spawned for unsupported modes");
      },
    );
    const warns = logs.filter(
      (l) => l.level === "WARN" && l.message === "reader engine fallback" && l.fields.reason === "pion-binary-unsupported-mode",
    );
    assert.equal(warns.length, STATEFUL_MODES.length, `expected 1 deduped fallback warn per mode, got ${warns.length}`);
  } finally {
    hearLines(null);
  }
});

test("builders_stateful: stateful schema_version cache + external trigger drop/tamper reinstall parity (0-diff)", async (t) => {
  const bins = resolveBinaries(t);
  if (!bins) return;
  const dir = freshDir("builders-stateful-schema-");

  // 1. archive-last: single running process -> thread A -> external DROP TRIGGER + tamper -> thread B -> auto reinstall.
  {
    const { seedPath, threads } = makeArchiveLastSeed(dir, "schema-al");
    const mbDb = join(dir, "schema-al-mb.db");
    const pionDb = join(dir, "schema-al-pion.db");
    copyFileSync(seedPath, mbDb);
    copyFileSync(seedPath, pionDb);

    const mbProc = new BuilderProc(bins.realMb, "archive-last", mbDb);
    const pionProc = new BuilderProc(bins.realPion, "archive-last", pionDb);
    try {
      // Run thread 0 to completion so triggers are installed and schema_version is cached in-process.
      for (let step = 0; step < 20; step++) {
        const ask = JSON.stringify({ thread: threads[0] });
        const [mbRes, pionRes] = await Promise.all([mbProc.ask(ask), pionProc.ask(ask)]);
        assert.deepStrictEqual(pionRes, mbRes, `archive-last thread 0 step ${step}`);
        if (mbRes.done === true) break;
      }
      assert.equal(snapshotArchiveLast(pionDb), snapshotArchiveLast(mbDb), "archive-last after thread 0");

      const readEpoch = (p: string) => {
        const db = new DatabaseSync(p);
        try {
          return (db.prepare("SELECT epoch FROM archive_last_meta WHERE id=1").get() as { epoch: string }).epoch;
        } finally {
          db.close();
        }
      };
      const mbEpochBefore = readEpoch(mbDb);
      const pionEpochBefore = readEpoch(pionDb);

      // External connection drops one trigger and tampers another (removing archive_last_v1 mark),
      // bumping PRAGMA schema_version while the builder processes stay alive.
      for (const p of [mbDb, pionDb]) {
        const ext = new DatabaseSync(p);
        try {
          ext.exec("DROP TRIGGER archive_last_update;");
          ext.exec("DROP TRIGGER archive_last_delete;");
          ext.exec("CREATE TRIGGER archive_last_delete BEFORE DELETE ON entries BEGIN SELECT 1; END;");
        } finally {
          ext.close();
        }
      }

      // Now ask the SAME running processes to process thread 1.
      for (let step = 0; step < 20; step++) {
        const ask = JSON.stringify({ thread: threads[1] });
        const [mbRes, pionRes] = await Promise.all([mbProc.ask(ask), pionProc.ask(ask)]);
        assert.deepStrictEqual(pionRes, mbRes, `archive-last thread 1 after tamper step ${step}`);
        if (mbRes.done === true) break;
      }

      assert.notEqual(readEpoch(mbDb), mbEpochBefore, "MB must rotate epoch after trigger tamper");
      assert.notEqual(readEpoch(pionDb), pionEpochBefore, "Pion must rotate epoch after trigger tamper");
      // Also re-process thread 0 under the new epoch so all guards match the rotated epoch cleanly.
      for (let step = 0; step < 20; step++) {
        const ask = JSON.stringify({ thread: threads[0] });
        const [mbRes, pionRes] = await Promise.all([mbProc.ask(ask), pionProc.ask(ask)]);
        assert.deepStrictEqual(pionRes, mbRes, `archive-last thread 0 re-run step ${step}`);
        if (mbRes.done === true) break;
      }
      assert.equal(
        snapshotArchiveLast(pionDb),
        snapshotArchiveLast(mbDb),
        "archive-last full tables + sqlite_master after trigger tamper/reinstall must be 0-diff",
      );
    } finally {
      await Promise.all([mbProc.end(), pionProc.end()]);
    }
  }

  // 2. page-letters: single running process -> thread A -> external DROP TRIGGER + tamper -> thread B -> auto reinstall.
  {
    const { seedPath, threads } = makePageLettersSeed(dir, "schema-pl");
    const mbDb = join(dir, "schema-pl-mb.db");
    const pionDb = join(dir, "schema-pl-pion.db");
    copyFileSync(seedPath, mbDb);
    copyFileSync(seedPath, pionDb);

    const mbProc = new BuilderProc(bins.realMb, "page-letters", mbDb);
    const pionProc = new BuilderProc(bins.realPion, "page-letters", pionDb);
    try {
      for (let step = 0; step < 20; step++) {
        const ask = JSON.stringify({ thread: threads[0] });
        const [mbRes, pionRes] = await Promise.all([mbProc.ask(ask), pionProc.ask(ask)]);
        assert.deepStrictEqual(pionRes, mbRes, `page-letters thread 0 step ${step}`);
        if (mbRes.done === true) break;
      }
      assert.equal(snapshotPageLetters(pionDb), snapshotPageLetters(mbDb), "page-letters after thread 0");

      for (const p of [mbDb, pionDb]) {
        const ext = new DatabaseSync(p);
        try {
          ext.exec("DROP TRIGGER page_letter_delete;");
          ext.exec("DROP TRIGGER page_letter_insert;");
          ext.exec("CREATE TRIGGER page_letter_insert BEFORE INSERT ON entries BEGIN SELECT 1; END;");
        } finally {
          ext.close();
        }
      }

      // Ask the SAME running processes to process thread 1 and re-process thread 0 (which queues old scope to garbage).
      for (const thread of [threads[1]!, threads[0]!]) {
        for (let step = 0; step < 20; step++) {
          const ask = JSON.stringify({ thread });
          const [mbRes, pionRes] = await Promise.all([mbProc.ask(ask), pionProc.ask(ask)]);
          assert.deepStrictEqual(pionRes, mbRes, `page-letters thread ${thread} after tamper step ${step}`);
          if (mbRes.done === true) break;
        }
      }

      // Epoch must have incremented from 1 -> 2 and thread 0's stale scope must be queued in page_letter_garbage.
      for (const [label, p] of [["mb", mbDb], ["pion", pionDb]] as const) {
        const db = new DatabaseSync(p);
        try {
          const meta = db.prepare("SELECT epoch FROM page_letter_meta WHERE id=1").get() as { epoch: number };
          assert.equal(meta.epoch, 2, `${label}: page_letter_meta.epoch must increment to 2 after reinstall`);
          const garb = db.prepare("SELECT COUNT(*) AS n FROM page_letter_garbage WHERE thread=?").get(threads[0]!) as { n: number };
          assert.equal(garb.n, 1, `${label}: stale scope for thread 0 must be queued in page_letter_garbage`);
        } finally {
          db.close();
        }
      }
      assert.equal(
        snapshotPageLetters(pionDb),
        snapshotPageLetters(mbDb),
        "page-letters full tables + sqlite_master after trigger tamper/reinstall must be 0-diff",
      );
    } finally {
      await Promise.all([mbProc.end(), pionProc.end()]);
    }
  }
});

test("builders_stateful: mid-flight SIGKILL crash and restart resumes cleanly with 0-diff", async (t) => {
  const bins = resolveBinaries(t);
  if (!bins) return;
  const dir = freshDir("builders-stateful-kill-");

  // 1. archive-last: 260-edit thread needs 5 batches; SIGKILL after 2 batches, restart, finish to done=true.
  {
    const { seedPath, threads } = makeArchiveLastSeed(dir, "kill-al");
    const mbDb = join(dir, "kill-al-mb.db");
    const pionDb = join(dir, "kill-al-pion.db");
    copyFileSync(seedPath, mbDb);
    copyFileSync(seedPath, pionDb);

    const ask = JSON.stringify({ thread: threads[0] });
    const mb1 = new BuilderProc(bins.realMb, "archive-last", mbDb);
    const pion1 = new BuilderProc(bins.realPion, "archive-last", pionDb);
    for (let i = 0; i < 2; i++) {
      const [m, p] = await Promise.all([mb1.ask(ask), pion1.ask(ask)]);
      assert.deepStrictEqual(p, { done: false });
      assert.deepStrictEqual(p, m);
    }
    await Promise.all([mb1.sigkill(), pion1.sigkill()]);

    const mb2 = new BuilderProc(bins.realMb, "archive-last", mbDb);
    const pion2 = new BuilderProc(bins.realPion, "archive-last", pionDb);
    try {
      let finished = false;
      for (let i = 0; i < 20; i++) {
        const [m, p] = await Promise.all([mb2.ask(ask), pion2.ask(ask)]);
        assert.deepStrictEqual(p, m, `archive-last post-SIGKILL step ${i}`);
        if (m.done === true) {
          finished = true;
          break;
        }
      }
      assert.equal(finished, true, "archive-last must finish after SIGKILL restart");
      assert.equal(snapshotArchiveLast(pionDb), snapshotArchiveLast(mbDb), "archive-last post-SIGKILL 0-diff");
    } finally {
      await Promise.all([mb2.end(), pion2.end()]);
    }
  }

  // 2. page-letters (both with and without entries_letters index): SIGKILL after 2 batches, restart, finish.
  for (const dropIndex of [false, true]) {
    const label = dropIndex ? "kill-pl-noindex" : "kill-pl-idx";
    const { seedPath, threads } = makePageLettersSeed(dir, label, dropIndex);
    const mbDb = join(dir, `${label}-mb.db`);
    const pionDb = join(dir, `${label}-pion.db`);
    copyFileSync(seedPath, mbDb);
    copyFileSync(seedPath, pionDb);

    const ask = JSON.stringify({ thread: threads[0] });
    const mb1 = new BuilderProc(bins.realMb, "page-letters", mbDb);
    const pion1 = new BuilderProc(bins.realPion, "page-letters", pionDb);
    for (let i = 0; i < 2; i++) {
      const [m, p] = await Promise.all([mb1.ask(ask), pion1.ask(ask)]);
      assert.deepStrictEqual(p, { done: false });
      assert.deepStrictEqual(p, m);
    }
    await Promise.all([mb1.sigkill(), pion1.sigkill()]);

    const mb2 = new BuilderProc(bins.realMb, "page-letters", mbDb);
    const pion2 = new BuilderProc(bins.realPion, "page-letters", pionDb);
    try {
      let finished = false;
      for (let i = 0; i < 20; i++) {
        const [m, p] = await Promise.all([mb2.ask(ask), pion2.ask(ask)]);
        assert.deepStrictEqual(p, m, `${label} post-SIGKILL step ${i}`);
        if (m.done === true) {
          finished = true;
          break;
        }
      }
      assert.equal(finished, true, `${label} must finish after SIGKILL restart`);
      assert.equal(snapshotPageLetters(pionDb), snapshotPageLetters(mbDb), `${label} post-SIGKILL 0-diff`);
    } finally {
      await Promise.all([mb2.end(), pion2.end()]);
    }
  }
});

test("builders_stateful: Int64 upper-bound saturation (2^63, 1e400), invalid/duplicate asks, and deterministic SQLITE_BUSY", async (t) => {
  const bins = resolveBinaries(t);
  if (!bins) return;
  const dir = freshDir("builders-stateful-edge-");

  for (const mode of STATEFUL_MODES) {
    const seedPath = join(dir, `edge-${mode}-seed.db`);
    let normalThread = 0;
    {
      const store = Store.open(seedPath, join(dir, `edge-${mode}-archive`));
      try {
        normalThread = store.openThread("ember", "CHAT", `edge-${mode}`, null, "me").id;
        store.db.prepare(
          "INSERT INTO entries(thread,n,kind,author_kind,author,text,ts,at,letter) VALUES(?,1,'message','agent','a','hi','t1',555,'{}')",
        ).run(normalThread);
        // Seed an entry at INT64_MAX (9223372036854775807n) to prove 2^63 / 1e400 saturation binds as REAL 9.223372036854776e18
        // (matching MoonBit `Json::number(thread.to_double())` empty repr) rather than matching INT64_MAX.
        store.db.prepare(
          "INSERT INTO entries(thread,n,kind,author_kind,author,text,ts,at,letter) VALUES(?,1,'message','agent','a','max','tmax',999,'{}')",
        ).run(9223372036854775807n);
        store.db.exec("PRAGMA wal_checkpoint(TRUNCATE)");
      } finally {
        store.close();
      }
    }

    const mbDb = join(dir, `edge-${mode}-mb.db`);
    const pionDb = join(dir, `edge-${mode}-pion.db`);
    copyFileSync(seedPath, mbDb);
    copyFileSync(seedPath, pionDb);

    const mbProc = new BuilderProc(bins.realMb, mode, mbDb);
    const pionProc = new BuilderProc(bins.realPion, mode, pionDb);
    try {
      // 1. Int64 upper-bound saturation + invalid requests + duplicate keys.
      const asks = [
        '{"thread":9223372036854775808}',
        '{"thread":1e400}',
        "{}",
        '{"thread":"1"}',
        "{bad json",
        '{"thread":1,"thread":"bad"}',
      ];
      for (const ask of asks) {
        const [m, p] = await Promise.all([mbProc.ask(ask), pionProc.ask(ask)]);
        assert.deepStrictEqual(p, m, `${mode}: ask=${ask} response must match MB 0-diff`);
      }

      // Verify neither saturated request matched the INT64_MAX entry.
      if (mode === "archive-last") {
        assert.equal(snapshotArchiveLast(pionDb), snapshotArchiveLast(mbDb), "archive-last saturation DB 0-diff");
      } else {
        assert.equal(snapshotPageLetters(pionDb), snapshotPageLetters(mbDb), "page-letters saturation DB 0-diff");
        const db = new DatabaseSync(pionDb);
        try {
          const cnt = (db.prepare("SELECT COUNT(*) AS n FROM page_letter_rows").get() as { n: number }).n;
          assert.equal(cnt, 0, "page-letters saturated 2^63/1e400 must not match INT64_MAX entry");
        } finally {
          db.close();
        }
      }

      // 2. Deterministic SQLITE_BUSY: hold BEGIN IMMEDIATE on external connections, send valid ask,
      // assert both MB and Pion return `{"done":false}` with no error, then release and verify recovery.
      const mbLock = new DatabaseSync(mbDb);
      const pionLock = new DatabaseSync(pionDb);
      try {
        mbLock.exec("BEGIN IMMEDIATE");
        pionLock.exec("BEGIN IMMEDIATE");
        const normalAsk = JSON.stringify({ thread: normalThread });
        const [mbBusy, pionBusy] = await Promise.all([mbProc.ask(normalAsk), pionProc.ask(normalAsk)]);
        assert.deepStrictEqual(pionBusy, { done: false }, `${mode}: Pion must return retryable busy {done:false}`);
        assert.deepStrictEqual(pionBusy, mbBusy, `${mode}: busy response must match MB 0-diff`);
      } finally {
        mbLock.exec("ROLLBACK");
        pionLock.exec("ROLLBACK");
        mbLock.close();
        pionLock.close();
      }

      // After releasing the lock, the same builder processes must recover and finish cleanly.
      const normalAsk = JSON.stringify({ thread: normalThread });
      const [mbAfter, pionAfter] = await Promise.all([mbProc.ask(normalAsk), pionProc.ask(normalAsk)]);
      assert.deepStrictEqual(pionAfter, { done: true }, `${mode}: Pion must recover to done=true after lock release`);
      assert.deepStrictEqual(pionAfter, mbAfter, `${mode}: recovery response must match MB 0-diff`);

      if (mode === "archive-last") {
        assert.equal(snapshotArchiveLast(pionDb), snapshotArchiveLast(mbDb), "archive-last post-busy 0-diff");
      } else {
        assert.equal(snapshotPageLetters(pionDb), snapshotPageLetters(mbDb), "page-letters post-busy 0-diff");
      }
    } finally {
      await Promise.all([mbProc.end(), pionProc.end()]);
    }
  }
});

// ── Static SQLite transaction guard + real file mutation test ──

type SqlToken =
  | { kind: "word"; upper: string }
  | { kind: "semi" }
  | { kind: "other" };

function unescapePionString(raw: string): string {
  let out = "";
  for (let i = 0; i < raw.length; i++) {
    const ch = raw[i]!;
    if (ch === "\\" && i + 1 < raw.length) {
      const next = raw[i + 1]!;
      if (next === "n") out += "\n";
      else if (next === "r") out += "\r";
      else if (next === "t") out += "\t";
      else out += next;
      i++;
    } else {
      out += ch;
    }
  }
  return out;
}

function isSqlIdentStart(code: number): boolean {
  return (
    (code >= 65 && code <= 90) ||
    (code >= 97 && code <= 122) ||
    code === 95 ||
    (code >= 0x80 && code !== 0xfeff)
  );
}

function isSqlIdentPart(code: number): boolean {
  return isSqlIdentStart(code) || (code >= 48 && code <= 57) || code === 36; // digits and '$'
}

function tokenizeSql(sql: string): SqlToken[] {
  const tokens: SqlToken[] = [];
  let i = 0;
  const n = sql.length;
  while (i < n) {
    const ch = sql[i]!;
    const code = sql.charCodeAt(i);
    if (
      ch === " " ||
      ch === "\t" ||
      ch === "\r" ||
      ch === "\n" ||
      ch === "\f" ||
      ch === "\v" ||
      code === 0xfeff
    ) {
      i++;
      continue;
    }
    if (ch === "-" && i + 1 < n && sql[i + 1] === "-") {
      i += 2;
      while (i < n && sql[i] !== "\n") i++;
      continue;
    }
    if (ch === "/" && i + 1 < n && sql[i + 1] === "*") {
      i += 2;
      while (i + 1 < n && !(sql[i] === "*" && sql[i + 1] === "/")) i++;
      i = Math.min(i + 2, n);
      continue;
    }
    if (ch === "'" || ch === '"' || ch === "`") {
      const quote = ch;
      i++;
      while (i < n) {
        if (sql[i] === quote) {
          if (i + 1 < n && sql[i + 1] === quote) {
            i += 2;
            continue;
          }
          i++;
          break;
        }
        i++;
      }
      tokens.push({ kind: "other" });
      continue;
    }
    if (ch === "[") {
      i++;
      while (i < n && sql[i] !== "]") i++;
      if (i < n) i++;
      tokens.push({ kind: "other" });
      continue;
    }
    if (ch === ";") {
      tokens.push({ kind: "semi" });
      i++;
      continue;
    }
    if (isSqlIdentStart(code)) {
      const start = i;
      i++;
      while (i < n && isSqlIdentPart(sql.charCodeAt(i))) {
        i++;
      }
      tokens.push({ kind: "word", upper: sql.slice(start, i).toUpperCase() });
      continue;
    }
    tokens.push({ kind: "other" });
    i++;
  }
  return tokens;
}

/// Single-pass SQLite lexical transaction guard:
/// Each string literal is scanned independently (trigger state NEVER carries across literals,
/// expressions, or functions), handling UTF-8 BOM, SQLite `$` identifiers, and trigger statement
/// boundary `END` inside `CREATE [TEMP|TEMPORARY] TRIGGER ... BEGIN ... END`.
function findRawTxControlViolations(filename: string, source: string): string[] {
  const violations: string[] = [];
  const forbiddenHeads = new Set(["BEGIN", "COMMIT", "END", "SAVEPOINT", "RELEASE", "ROLLBACK"]);
  const lines = source.split("\n");
  for (let idx = 0; idx < lines.length; idx++) {
    const line = lines[idx]!;
    const trimmed = line.trim();
    if (trimmed.startsWith("//")) continue;
    const litRe = /"((?:\\.|[^"\\])*)"/g;
    let m: RegExpExecArray | null;
    while ((m = litRe.exec(line)) !== null) {
      const literal = m[1]!;
      const tokens = tokenizeSql(unescapePionString(literal));
      let atStmtStart = true;
      let inTriggerHeader = false;
      let inTriggerBody = false;
      let atTriggerStmtStart = false;

      for (let t = 0; t < tokens.length; t++) {
        const tok = tokens[t]!;
        if (inTriggerBody) {
          if (tok.kind === "semi") {
            atTriggerStmtStart = true;
          } else if (atTriggerStmtStart && tok.kind === "word" && tok.upper === "END") {
            inTriggerBody = false;
            atTriggerStmtStart = false;
            atStmtStart = false;
          } else {
            atTriggerStmtStart = false;
          }
          continue;
        }
        if (inTriggerHeader) {
          if (tok.kind === "word" && tok.upper === "BEGIN") {
            inTriggerHeader = false;
            inTriggerBody = true;
            atTriggerStmtStart = true;
          } else if (tok.kind === "semi") {
            inTriggerHeader = false;
            atStmtStart = true;
          }
          continue;
        }
        if (tok.kind === "semi") {
          atStmtStart = true;
          continue;
        }
        if (!atStmtStart) continue;
        atStmtStart = false;
        if (tok.kind !== "word") continue;

        if (tok.upper === "CREATE") {
          const t1 = tokens[t + 1];
          const t2 = tokens[t + 2];
          if (
            (t1?.kind === "word" && t1.upper === "TRIGGER") ||
            (t1?.kind === "word" &&
              (t1.upper === "TEMP" || t1.upper === "TEMPORARY") &&
              t2?.kind === "word" &&
              t2.upper === "TRIGGER")
          ) {
            inTriggerHeader = true;
          }
          continue;
        }

        if (!forbiddenHeads.has(tok.upper)) continue;
        violations.push(`${filename}:${idx + 1}: forbidden raw transaction SQL "${tok.upper}" in literal "${literal}"`);
      }
    }
  }
  return violations;
}

test("builders_stateful static transaction guard + real file mutation test on archive_last.pion and page_letters.pion", () => {
  // Lexer edge-case checks (UTF-8 BOM, `$` identifiers, trigger boundary END, no cross-literal state).
  assert.ok(findRawTxControlViolations("t.pion", 'let _ = tx_db.exec("\uFEFFBEGIN IMMEDIATE")').length > 0);
  assert.ok(findRawTxControlViolations("t.pion", 'let _ = tx_db.exec("CREATE TRIGGER x BEGIN SELECT NEW.use$case; END; COMMIT")').length > 0);
  assert.ok(
    findRawTxControlViolations("t.pion", 'let a = "CREATE TRIGGER x BEGIN"\nlet _ = tx_db.exec("COMMIT")').length > 0,
    "unclosed trigger literal must never suppress COMMIT in a subsequent literal",
  );
  assert.equal(
    findRawTxControlViolations("t.pion", 'let _ = tx_db.exec("CREATE TRIGGER x BEGIN SELECT CASE WHEN 1 THEN 2 END; END;")').length,
    0,
  );

  // Scan all real business files in pion/station/packages/builders_stateful/src/.
  const srcDir = resolve(fileURLToPath(new URL("../../pion/station/packages/builders_stateful/src", import.meta.url)));
  assert.ok(existsSync(srcDir), `expected ${srcDir} to exist`);
  const files = readdirSync(srcDir).filter((f) => f.endsWith(".pion") && !f.endsWith("_test.pion")).sort();
  assert.deepStrictEqual(files, ["archive_last.pion", "page_letters.pion"]);

  for (const file of files) {
    const content = readFileSync(join(srcDir, file), "utf8");
    assert.deepStrictEqual(
      findRawTxControlViolations(file, content),
      [],
      `${file} must have zero raw transaction SQL violations`,
    );

    // Real mutation test: inject `tx_db.exec("COMMIT")` and `tx_db.exec("BEGIN IMMEDIATE")` into
    // the real file content in memory and assert 100% detection.
    const commitMutated = `${content}\nlet _ = tx_db.exec("COMMIT")\n`;
    const commitHits = findRawTxControlViolations(file, commitMutated);
    assert.equal(commitHits.length, 1, `${file}: injected tx_db.exec("COMMIT") must be detected`);
    assert.match(commitHits[0]!, /"COMMIT"/);

    const beginMutated = `${content}\nlet _ = tx_db.exec("BEGIN IMMEDIATE")\n`;
    const beginHits = findRawTxControlViolations(file, beginMutated);
    assert.equal(beginHits.length, 1, `${file}: injected tx_db.exec("BEGIN IMMEDIATE") must be detected`);
    assert.match(beginHits[0]!, /"BEGIN"/);
  }
});
