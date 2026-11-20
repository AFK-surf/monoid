// Wave 2 · Track F conformance & real-library interop tests for MoonBit Node/npm replacements:
//   1. `station/mb/src/sql` (`sql.c` + `sql.mbt`, replaces `better-sqlite3`) vs Node `node:sqlite`
//   2. `libs/base/src/net` (`Socket`, `Listener`, `pipe_duplex`, replaces `node:net`) vs real `node:net` TCP
//   3. `station/mb/src/packed` (`--builder packed`, replaces tar/zip cold-archive streaming)
import assert from "node:assert/strict";
import { type ChildProcess, spawn } from "node:child_process";
import { createHash, randomBytes } from "node:crypto";
import {
  existsSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  realpathSync,
  rmSync,
  statSync,
  writeFileSync,
} from "node:fs";
import { connect as netConnect, createServer as netServer, type Server, type Socket } from "node:net";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { createInterface } from "node:readline";
import { DatabaseSync } from "node:sqlite";
import { after, test } from "node:test";
import { mbReaderBinary } from "../src/read/mb-reader.ts";
import { PackedProgram } from "../src/sessions/packed-mb.ts";
import { mbHarnessBinary } from "./mb-harness.ts";
import { gnuHeader, padding, tarOfHeaders } from "./reference/workspace-archive.ts";

const readerBin = mbReaderBinary();
const harnessBin = mbHarnessBinary();
const skipHarness =
  harnessBin === null
    ? "the MoonBit test harness (stillfail-reader-harness) is not built here"
    : process.platform === "win32"
      ? "Unix-only conformance tests"
      : false;
const skipReader =
  readerBin === null
    ? "the MoonBit program (stillfail-reader) is not built here"
    : process.platform === "win32"
      ? "Unix-only conformance tests"
      : false;

const dirs: string[] = [];
const fresh = (what: string) => {
  const dir = realpathSync(mkdtempSync(join(tmpdir(), `sf-trackf-${what}-`)));
  dirs.push(dir);
  return dir;
};

const children: ChildProcess[] = [];
const servers: Server[] = [];
let packedProg: PackedProgram | null = null;

after(async () => {
  await packedProg?.close();
  for (const s of servers) {
    await new Promise<void>((r) => s.close(() => r()));
  }
  const left = children.filter((c) => c.exitCode === null && c.signalCode === null);
  for (const c of left) c.kill("SIGKILL");
  await Promise.all(
    left.map((c) =>
      c.exitCode === null && c.signalCode === null
        ? new Promise<void>((r) => c.once("exit", () => r()))
        : undefined,
    ),
  );
  for (const d of dirs) rmSync(d, { recursive: true, force: true });
});

type HarnessClient = {
  call: (op: string, payload?: Record<string, unknown>) => Promise<{ ok?: any; error?: string }>;
  ok: (op: string, payload?: Record<string, unknown>) => Promise<any>;
  close: () => Promise<void>;
};

function startSqlNetHarness(): HarnessClient {
  const child = spawn(harnessBin!, ["--builder", "harness-sql-net", "--shell-dir", fresh("shell")], {
    stdio: ["pipe", "pipe", "pipe"],
  });
  children.push(child);
  let stderr = "";
  child.stderr!.on("data", (d) => (stderr += d));
  let nextId = 0;
  const pending = new Map<number, (msg: any) => void>();
  createInterface({ input: child.stdout! }).on("line", (line) => {
    const msg = JSON.parse(line);
    const resolve = pending.get(msg.id);
    if (resolve) {
      pending.delete(msg.id);
      resolve(msg);
    }
  });
  child.on("exit", (code, signal) => {
    for (const [, resolve] of pending) {
      resolve({ error: `harness exited prematurely (code=${code}, signal=${signal}): ${stderr}` });
    }
    pending.clear();
  });
  const call = (op: string, payload: Record<string, unknown> = {}) =>
    new Promise<{ ok?: any; error?: string }>((resolve) => {
      const id = ++nextId;
      pending.set(id, resolve);
      child.stdin!.write(`${JSON.stringify({ id, op, ...payload })}\n`);
    });
  const ok = async (op: string, payload: Record<string, unknown> = {}) => {
    const r = await call(op, payload);
    assert.equal(r.error, undefined, `${op} failed: ${r.error}`);
    return r.ok;
  };
  const close = async () => {
    child.stdin!.end();
    if (child.exitCode === null && child.signalCode === null) {
      await new Promise<void>((r) => child.once("exit", () => r()));
    }
  };
  return { call, ok, close };
}

const sha256 = (b: Buffer) => createHash("sha256").update(b).digest("hex");

// ═══════════════════════════════════════════════════════════════════════════════
// 1. station/mb/src/sql (replaces better-sqlite3) vs Node node:sqlite
// ═══════════════════════════════════════════════════════════════════════════════

test("sql conformance: transactions (atomic commit, exception rollback, nested savepoints, read-only mode)", { skip: skipHarness }, async () => {
  const h = startSqlNetHarness();
  const dir = fresh("sql-tx");
  const dbPath = join(dir, "tx.db");
  try {
    const { handle } = await h.ok("sql.create", { path: dbPath, wait: 2000 });
    await h.ok("sql.exec", { handle, sql: "CREATE TABLE items (id INTEGER PRIMARY KEY, name TEXT NOT NULL)" });

    // Atomic commit
    const commitRes = await h.ok("sql.write", {
      handle,
      steps: [
        { op: "run", sql: "INSERT INTO items (id, name) VALUES (?, ?)", params: [1, "alpha"] },
        { op: "run", sql: "INSERT INTO items (id, name) VALUES (?, ?)", params: [2, "beta"] },
      ],
    });
    assert.deepEqual(commitRes.changes, [1, 1]);
    const rowsAfterCommit = (await h.ok("sql.all", { handle, sql: "SELECT id, name FROM items ORDER BY id" })).rows;
    assert.deepEqual(rowsAfterCommit, [
      { id: 1, name: "alpha" },
      { id: 2, name: "beta" },
    ]);

    // Exception rollback: insert 3 then fail -> row 3 must not persist
    const rbRes = await h.call("sql.write", {
      handle,
      steps: [
        { op: "run", sql: "INSERT INTO items (id, name) VALUES (?, ?)", params: [3, "gamma"] },
        { op: "fail", message: "simulated abort" },
      ],
    });
    assert.ok(rbRes.error?.includes("simulated abort"), `expected simulated abort, got ${rbRes.error}`);
    const rowsAfterRb = (await h.ok("sql.all", { handle, sql: "SELECT id, name FROM items ORDER BY id" })).rows;
    assert.deepEqual(rowsAfterRb, [
      { id: 1, name: "alpha" },
      { id: 2, name: "beta" },
    ]);

    // Nested savepoints inside db.write: outer insert persists, inner savepoint rolled back
    await h.ok("sql.write", {
      handle,
      steps: [
        { op: "run", sql: "INSERT INTO items (id, name) VALUES (?, ?)", params: [3, "outer"] },
        { op: "exec", sql: "SAVEPOINT sp_inner" },
        { op: "run", sql: "INSERT INTO items (id, name) VALUES (?, ?)", params: [4, "inner_reverted"] },
        { op: "exec", sql: "ROLLBACK TO sp_inner" },
        { op: "exec", sql: "RELEASE sp_inner" },
      ],
    });
    const rowsAfterSp = (await h.ok("sql.all", { handle, sql: "SELECT id, name FROM items ORDER BY id" })).rows;
    assert.deepEqual(rowsAfterSp, [
      { id: 1, name: "alpha" },
      { id: 2, name: "beta" },
      { id: 3, name: "outer" },
    ]);

    // Parity check with node:sqlite on the exact same DB file
    const ndb = new DatabaseSync(dbPath, { readOnly: true });
    try {
      const nodeRows = ndb.prepare("SELECT id, name FROM items ORDER BY id").all();
      assert.deepEqual(
        nodeRows.map((r: any) => ({ id: r.id, name: r.name })),
        rowsAfterSp,
      );
    } finally {
      ndb.close();
    }

    // Read-only mode via SQLite URI (?mode=ro) AND PRAGMA query_only = ON
    const { handle: ro } = await h.ok("sql.attach", { path: `file:${dbPath}?mode=ro`, wait: 1000 });
    const roRead = (await h.ok("sql.all", { handle: ro, sql: "SELECT COUNT(*) AS n FROM items" })).rows;
    assert.equal(roRead[0].n, 3);
    const roWrite = await h.call("sql.run", { handle: ro, sql: "INSERT INTO items (id, name) VALUES (?, ?)", params: [99, "no"] });
    assert.ok(roWrite.error && /readonly/i.test(roWrite.error), `expected readonly error, got ${roWrite.error}`);
    await h.ok("sql.close", { handle: ro });

    // PRAGMA query_only = ON rejects writes on a read-write connection
    await h.ok("sql.exec", { handle, sql: "PRAGMA query_only = ON" });
    const qoWrite = await h.call("sql.run", { handle, sql: "INSERT INTO items (id, name) VALUES (?, ?)", params: [100, "no"] });
    assert.ok(qoWrite.error && /readonly/i.test(qoWrite.error), `expected readonly error under query_only, got ${qoWrite.error}`);
    await h.ok("sql.exec", { handle, sql: "PRAGMA query_only = OFF" });

    // Db::known snapshot caching inside vs outside transaction
    const known = await h.ok("sql.known_tx", { handle });
    assert.deepEqual(known.outside, [1, 2]);
    assert.deepEqual(known.inside, [3, 3, 4]);

    await h.ok("sql.close", { handle });
  } finally {
    await h.close();
  }
});

test("sql conformance: parameter binding all-type boundaries (NULL, NUL text, Int64 >2^53-1, Double NaN/Inf/-0.0, BLOB)", { skip: skipHarness }, async () => {
  const h = startSqlNetHarness();
  const dir = fresh("sql-types");
  const dbPath = join(dir, "types.db");
  try {
    const { handle } = await h.ok("sql.create", { path: dbPath, wait: 2000 });
    await h.ok("sql.exec", { handle, sql: "CREATE TABLE vals (k TEXT PRIMARY KEY, v)" });

    // NULL, empty string, booleans, fractional double, object JSON
    await h.ok("sql.run", { handle, sql: "INSERT INTO vals VALUES (?, ?)", params: ["null", null] });
    await h.ok("sql.run", { handle, sql: "INSERT INTO vals VALUES (?, ?)", params: ["empty_str", ""] });
    await h.ok("sql.run", { handle, sql: "INSERT INTO vals VALUES (?, ?)", params: ["bool_t", true] });
    await h.ok("sql.run", { handle, sql: "INSERT INTO vals VALUES (?, ?)", params: ["bool_f", false] });
    await h.ok("sql.run", { handle, sql: "INSERT INTO vals VALUES (?, ?)", params: ["pi", 3.141592653589793] });
    await h.ok("sql.run", { handle, sql: "INSERT INTO vals VALUES (?, ?)", params: ["safe_max", 9007199254740991] });
    await h.ok("sql.run", { handle, sql: "INSERT INTO vals VALUES (?, ?)", params: ["safe_min", -9007199254740991] });

    // Special values bound directly from MoonBit (bypassing JSON loss for NaN/Inf/Int64>2^53-1)
    for (const kind of [
      "nan",
      "pos_inf",
      "neg_inf",
      "neg_zero",
      "neg_zero_repr",
      "int64_max",
      "int64_min",
      "over_safe",
      "under_safe",
      "nul_text",
      "empty_blob",
      "large_blob",
    ]) {
      await h.ok("sql.bind_special", {
        handle,
        kind,
        sql: `INSERT INTO vals VALUES ('${kind}', ?)`,
        size: 65536,
      });
    }

    // Verify types & exact values inside SQLite via CAST/typeof/length/hex
    const summary = (
      await h.ok("sql.all", {
        handle,
        sql: "SELECT k, typeof(v) AS ty, length(v) AS len, CAST(v AS TEXT) AS txt FROM vals ORDER BY k",
      })
    ).rows as Array<{ k: string; ty: string; len: number | null; txt: string | null }>;
    const byKey = new Map(summary.map((r) => [r.k, r]));

    assert.equal(byKey.get("null")!.ty, "null");
    assert.equal(byKey.get("empty_str")!.ty, "text");
    assert.equal(byKey.get("empty_str")!.len, 0);
    assert.equal(byKey.get("bool_t")!.ty, "integer");
    assert.equal(byKey.get("bool_t")!.txt, "1");
    assert.equal(byKey.get("bool_f")!.txt, "0");
    assert.equal(byKey.get("pi")!.ty, "real");

    // NaN / +/-Infinity bound as NULL (matching serde/JSON behavior documented in sql.mbt)
    assert.equal(byKey.get("nan")!.ty, "null");
    assert.equal(byKey.get("pos_inf")!.ty, "null");
    assert.equal(byKey.get("neg_inf")!.ty, "null");

    // Int64 precision beyond +/- (2^53 - 1) must be 100% lossless in SQLite
    assert.equal(byKey.get("safe_max")!.ty, "integer");
    assert.equal(byKey.get("safe_max")!.txt, "9007199254740991");
    assert.equal(byKey.get("safe_min")!.txt, "-9007199254740991");
    assert.equal(byKey.get("over_safe")!.ty, "integer");
    assert.equal(byKey.get("over_safe")!.txt, "9007199254740993");
    assert.equal(byKey.get("under_safe")!.ty, "integer");
    assert.equal(byKey.get("under_safe")!.txt, "-9007199254740993");
    assert.equal(byKey.get("int64_max")!.ty, "integer");
    assert.equal(byKey.get("int64_max")!.txt, "9223372036854775807");
    assert.equal(byKey.get("int64_min")!.ty, "integer");
    assert.equal(byKey.get("int64_min")!.txt, "-9223372036854775808");

    // Embedded NUL byte string: full length preserved in SQLite and on readback!
    assert.equal(byKey.get("nul_text")!.ty, "text");
    const nulRow = (await h.ok("sql.first", { handle, sql: "SELECT v, hex(CAST(v AS BLOB)) AS h FROM vals WHERE k = 'nul_text'" })).row;
    assert.equal(nulRow.v, "alpha\0beta\0gamma");
    assert.equal(nulRow.h, Buffer.from("alpha\0beta\0gamma", "utf8").toString("hex").toUpperCase());

    // Empty BLOB & 64 KiB BLOB round-trip
    assert.equal(byKey.get("empty_blob")!.ty, "blob");
    assert.equal(byKey.get("empty_blob")!.len, 0);
    const emptyBlobRow = (await h.ok("sql.first", { handle, sql: "SELECT v FROM vals WHERE k = 'empty_blob'" })).row;
    assert.deepEqual(emptyBlobRow.v, []);

    assert.equal(byKey.get("large_blob")!.ty, "blob");
    assert.equal(byKey.get("large_blob")!.len, 65536);
    const largeBlobRow = (await h.ok("sql.first", { handle, sql: "SELECT v FROM vals WHERE k = 'large_blob'" })).row;
    assert.equal(largeBlobRow.v.length, 65536);
    for (let i = 0; i < 65536; i += 1021) {
      assert.equal(largeBlobRow.v[i], (i * 37 + 11) & 0xff, `blob mismatch at ${i}`);
    }

    // Cross-check exact stored bytes against Node node:sqlite (with readBigInts for Int64!)
    const ndb = new DatabaseSync(dbPath, { readOnly: true });
    try {
      const stmt = ndb.prepare("SELECT v FROM vals WHERE k = ?");
      stmt.setReadBigInts(true);
      assert.equal((stmt.get("int64_max") as any).v, 9223372036854775807n);
      assert.equal((stmt.get("int64_min") as any).v, -9223372036854775808n);
      assert.equal((stmt.get("over_safe") as any).v, 9007199254740993n);
      assert.equal((stmt.get("under_safe") as any).v, -9007199254740993n);
      assert.equal((stmt.get("nul_text") as any).v, "alpha\0beta\0gamma");
      assert.equal(((stmt.get("empty_blob") as any).v as Uint8Array).length, 0);
      assert.equal(((stmt.get("large_blob") as any).v as Uint8Array).length, 65536);
    } finally {
      ndb.close();
    }

    // Wrong parameter count error
    const badParams = await h.call("sql.run", { handle, sql: "INSERT INTO vals VALUES (?, ?)", params: ["only_one"] });
    assert.ok(badParams.error?.includes("Wrong number of parameters"), `got ${badParams.error}`);

    await h.ok("sql.close", { handle });
  } finally {
    await h.close();
  }
});

test("sql conformance: constraints (UNIQUE/NOT NULL/FOREIGN KEY/CHECK), statement reuse/eviction, WAL concurrency & busy_timeout", { skip: skipHarness }, async () => {
  const h = startSqlNetHarness();
  const dir = fresh("sql-constraints-wal");
  const dbPath = join(dir, "wal.db");
  try {
    const { handle: db1 } = await h.ok("sql.create", { path: dbPath, wait: 2000 });
    await h.ok("sql.exec", {
      handle: db1,
      sql: `
        PRAGMA journal_mode = WAL;
        PRAGMA foreign_keys = ON;
        CREATE TABLE parents (id INTEGER PRIMARY KEY);
        CREATE TABLE children (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          parent_id INTEGER NOT NULL REFERENCES parents(id),
          code TEXT UNIQUE NOT NULL,
          age INTEGER CHECK (age >= 0)
        );
      `,
    });
    await h.ok("sql.run", { handle: db1, sql: "INSERT INTO parents (id) VALUES (?)", params: [1] });
    const insSql = "INSERT INTO children (parent_id, code, age) VALUES (?, ?, ?)";
    assert.equal((await h.ok("sql.run", { handle: db1, sql: insSql, params: [1, "A", 10] })).changes, 1);

    // last_insert_rowid() & changes
    const rowid1 = (await h.ok("sql.first", { handle: db1, sql: "SELECT last_insert_rowid() AS id" })).row.id;
    assert.equal(rowid1, 1);

    // 1. UNIQUE violation
    const uErr = await h.call("sql.run", { handle: db1, sql: insSql, params: [1, "A", 11] });
    assert.ok(uErr.error && /UNIQUE constraint failed/i.test(uErr.error), `expected UNIQUE error, got: ${uErr.error}`);

    // 2. NOT NULL violation
    const nnErr = await h.call("sql.run", { handle: db1, sql: insSql, params: [1, null, 11] });
    assert.ok(nnErr.error && /NOT NULL constraint failed/i.test(nnErr.error), `expected NOT NULL error, got: ${nnErr.error}`);

    // 3. FOREIGN KEY violation
    const fkErr = await h.call("sql.run", { handle: db1, sql: insSql, params: [999, "B", 11] });
    assert.ok(fkErr.error && /FOREIGN KEY constraint failed/i.test(fkErr.error), `expected FOREIGN KEY error, got: ${fkErr.error}`);

    // 4. CHECK violation
    const ckErr = await h.call("sql.run", { handle: db1, sql: insSql, params: [1, "C", -5] });
    assert.ok(ckErr.error && /CHECK constraint failed/i.test(ckErr.error), `expected CHECK error, got: ${ckErr.error}`);

    // Prepared statement must be cleanly reset after all 4 errors and remain reusable!
    assert.equal((await h.ok("sql.run", { handle: db1, sql: insSql, params: [1, "B", 20] })).changes, 1);
    const rowid2 = (await h.ok("sql.first", { handle: db1, sql: "SELECT last_insert_rowid() AS id" })).row.id;
    assert.equal(rowid2, 2);

    // UPDATE / DELETE changes count
    assert.equal((await h.ok("sql.run", { handle: db1, sql: "UPDATE children SET age = age + 1 WHERE parent_id = ?", params: [1] })).changes, 2);
    assert.equal((await h.ok("sql.run", { handle: db1, sql: "UPDATE children SET age = 0 WHERE parent_id = ?", params: [999] })).changes, 0);

    // Statement cache eviction past KEPT_MOST (256 distinct statements) without leaking handles
    for (let i = 0; i < 270; i++) {
      const r = (await h.ok("sql.first", { handle: db1, sql: `SELECT ${i} AS n` })).row;
      assert.equal(r.n, i);
    }

    // WAL mode two-connection concurrent read/write + busy_timeout
    const { handle: db2 } = await h.ok("sql.attach", { path: dbPath, wait: 50 });
    await h.ok("sql.exec", { handle: db1, sql: "BEGIN IMMEDIATE" });
    await h.ok("sql.run", { handle: db1, sql: insSql, params: [1, "WAL_TX", 30] });

    // Reader db2 sees committed snapshot (2 rows) while db1 holds write lock!
    const snap = (await h.ok("sql.first", { handle: db2, sql: "SELECT COUNT(*) AS n FROM children" })).row.n;
    assert.equal(snap, 2);

    // Writer db2 hits busy_timeout (50 ms) and returns SQLITE_BUSY ("database is locked")
    const busyRes = await h.call("sql.run", { handle: db2, sql: insSql, params: [1, "CONFLICT", 40] });
    assert.ok(busyRes.error && /locked/i.test(busyRes.error), `expected busy/locked error, got: ${busyRes.error}`);
    assert.equal(await h.ok("sql.is_busy", { message: busyRes.error }), true);

    // Commit db1 -> db2 now sees 3 rows and can write cleanly
    await h.ok("sql.exec", { handle: db1, sql: "COMMIT" });
    const afterCommit = (await h.ok("sql.first", { handle: db2, sql: "SELECT COUNT(*) AS n FROM children" })).row.n;
    assert.equal(afterCommit, 3);
    assert.equal((await h.ok("sql.run", { handle: db2, sql: insSql, params: [1, "AFTER_WAL", 41] })).changes, 1);

    // Schema metadata helpers
    const meta = await h.ok("sql.meta", { handle: db1, kind: "table", name: "children" });
    assert.equal(meta.has_schema, true);
    assert.ok(typeof meta.master_sql === "string" && meta.master_sql.includes("CREATE TABLE children"));
    assert.equal(typeof meta.schema_version, "number");

    await h.ok("sql.close", { handle: db2 });
    await h.ok("sql.close", { handle: db1 });
  } finally {
    await h.close();
  }
});

// ═══════════════════════════════════════════════════════════════════════════════
// 2. libs/base/src/net (replaces node:net) real TCP interop with Node node:net
// ═══════════════════════════════════════════════════════════════════════════════

test("net conformance: half-close FIN both ways with real Node node:net server", { skip: skipHarness }, async () => {
  const h = startSqlNetHarness();
  try {
    // Direction A: Node server sends payload + FIN first, waits for MB's reply + FIN
    // The server sees MB's FIN on this process's event loop, after the harness may have answered: wait for it.
    let resolveGotA!: (b: Buffer) => void;
    const serverGotA = new Promise<Buffer>((r) => {
      resolveGotA = r;
    });
    const srvA = netServer({ allowHalfOpen: true }, (sock) => {
      const chunks: Buffer[] = [];
      sock.on("data", (c) => chunks.push(c));
      sock.on("end", () => {
        resolveGotA(Buffer.concat(chunks));
        sock.destroy();
      });
      sock.write(Buffer.from("hello-from-node-before-fin"));
      sock.end(); // send FIN while keeping read half open!
    });
    servers.push(srvA);
    await new Promise<void>((r) => srvA.listen(0, "127.0.0.1", () => r()));
    const portA = (srvA.address() as any).port;

    const resA = await h.ok("net.connect_half_close", {
      port: portA,
      send_hex: Buffer.from("reply-after-peer-fin").toString("hex"),
      wait_eof_first: true,
    });
    assert.equal(Buffer.from(resA.received_hex, "hex").toString("utf8"), "hello-from-node-before-fin");
    assert.equal(resA.closed_after_eof, false, "socket must stay open for writing after peer FIN");
    assert.equal(resA.closed_after_end, true, "socket must close once both halves ended");
    assert.equal((await serverGotA).toString("utf8"), "reply-after-peer-fin");

    // Direction B: MB sends payload + FIN first, then reads Node's delayed reply + FIN
    const srvB = netServer({ allowHalfOpen: true }, (sock) => {
      const chunks: Buffer[] = [];
      sock.on("data", (c) => chunks.push(c));
      sock.on("end", () => {
        const req = Buffer.concat(chunks).toString("utf8");
        sock.end(`echo:${req}`);
      });
    });
    servers.push(srvB);
    await new Promise<void>((r) => srvB.listen(0, "127.0.0.1", () => r()));
    const portB = (srvB.address() as any).port;

    const resB = await h.ok("net.connect_half_close", {
      port: portB,
      send_hex: Buffer.from("mb-sends-fin-first").toString("hex"),
      wait_eof_first: false,
    });
    assert.equal(resB.closed_after_end, false, "socket must stay open for reading after local FIN");
    assert.equal(resB.closed_after_eof, true, "socket must close once peer FIN arrives");
    assert.equal(Buffer.from(resB.received_hex, "hex").toString("utf8"), "echo:mb-sends-fin-first");
  } finally {
    await h.close();
  }
});

test("net conformance: fragmented/coalesced writes & 2 MiB full-duplex backpressure through @net.pipe_duplex", { skip: skipHarness }, async () => {
  const h = startSqlNetHarness();
  try {
    // Upstream Node echo server (allowHalfOpen so both directions complete cleanly)
    const upstream = netServer({ allowHalfOpen: true }, (sock) => {
      sock.on("data", (chunk) => {
        if (!sock.write(chunk)) {
          sock.pause();
          sock.once("drain", () => sock.resume());
        }
      });
      sock.on("end", () => sock.end());
    });
    servers.push(upstream);
    await new Promise<void>((r) => upstream.listen(0, "127.0.0.1", () => r()));
    const upstreamPort = (upstream.address() as any).port;

    const { listener_id, port: proxyPort } = await h.ok("net.pipe_proxy_start", { target_port: upstreamPort });

    // Case 1: 60 fragmented small writes of varying sizes (1..512 bytes)
    const fragParts: Buffer[] = [];
    for (let i = 0; i < 60; i++) {
      fragParts.push(randomBytes((i * 19) % 512 + 1));
    }
    const fragExpected = Buffer.concat(fragParts);
    const fragGot = await new Promise<Buffer>((resolve, reject) => {
      const sock = netConnect(proxyPort, "127.0.0.1");
      const out: Buffer[] = [];
      sock.on("data", (d) => out.push(d));
      sock.on("error", reject);
      sock.on("end", () => resolve(Buffer.concat(out)));
      sock.on("connect", () => {
        for (const p of fragParts) sock.write(p);
        sock.end();
      });
    });
    assert.equal(sha256(fragGot), sha256(fragExpected));
    assert.equal(fragGot.length, fragExpected.length);

    // Case 2: 2 MiB payload streaming with backpressure through @net.pipe_duplex
    const bigPayload = randomBytes(2 * 1024 * 1024);
    const bigGot = await new Promise<Buffer>((resolve, reject) => {
      const sock = netConnect(proxyPort, "127.0.0.1");
      const out: Buffer[] = [];
      sock.on("data", (d) => out.push(d));
      sock.on("error", reject);
      sock.on("end", () => resolve(Buffer.concat(out)));
      sock.on("connect", () => {
        let off = 0;
        const pump = () => {
          while (off < bigPayload.length) {
            const end = Math.min(off + 32768, bigPayload.length);
            const ok = sock.write(bigPayload.subarray(off, end));
            off = end;
            if (!ok) {
              sock.once("drain", pump);
              return;
            }
          }
          sock.end();
        };
        pump();
      });
    });
    assert.equal(bigGot.length, bigPayload.length);
    assert.equal(sha256(bigGot), sha256(bigPayload));

    const stats = await h.ok("net.listen_stop", { listener_id });
    assert.equal(stats.accepted, 2);
    assert.deepEqual(stats.errors, []);
  } finally {
    await h.close();
  }
});

test("net conformance: ECONNREFUSED and peer RST error propagation & socket cleanup", { skip: skipHarness }, async () => {
  const h = startSqlNetHarness();
  try {
    // Allocate and immediately close an ephemeral port to get a guaranteed refused port
    const tmpSrv = netServer();
    await new Promise<void>((r) => tmpSrv.listen(0, "127.0.0.1", () => r()));
    const closedPort = (tmpSrv.address() as any).port;
    await new Promise<void>((r) => tmpSrv.close(() => r()));

    const refused = await h.call("net.connect_expect_error", { port: closedPort });
    assert.ok(refused.error, "connecting to closed port must fail");

    // Peer waits for client's 1-byte trigger, then immediately triggers TCP RST (resetAndDestroy)
    const rstSrv = netServer((sock: Socket) => {
      sock.once("data", () => {
        sock.resetAndDestroy();
      });
    });
    servers.push(rstSrv);
    await new Promise<void>((r) => rstSrv.listen(0, "127.0.0.1", () => r()));
    const rstPort = (rstSrv.address() as any).port;

    const rstRes = await h.ok("net.connect_read_rst", { port: rstPort });
    assert.ok(typeof rstRes.error === "string" && rstRes.error.length > 0, `expected RST read error, got ${JSON.stringify(rstRes)}`);
    assert.equal(rstRes.closed, true, "socket must be closed after peer RST");
  } finally {
    await h.close();
  }
});

// ═══════════════════════════════════════════════════════════════════════════════
// 3. station/mb/src/packed (cold session archive packing) real archive conformance
// ═══════════════════════════════════════════════════════════════════════════════

test("packed conformance: empty archive, special chars, deep paths, path traversal rejection, large round-trip & corrupt/truncated safety", { skip: skipReader }, async () => {
  const mb = (packedProg ??= new PackedProgram({ binary: readerBin! }));
  const root = fresh("packed");

  // 1. Empty workspace archive round-trip
  const emptyDir = join(root, "empty-ws");
  const emptyArc = join(root, "empty.tar.zst");
  const emptyOut = join(root, "empty-out");
  mkdirSync(emptyDir);
  mkdirSync(emptyOut);
  await mb.ask("workspace.pack", { dir: emptyDir, out: emptyArc });
  const emptyRes = await mb.ask<{ refused: unknown[] }>("workspace.unpack", { path: emptyArc, dest: emptyOut });
  assert.deepEqual(emptyRes.refused, []);
  assert.ok(existsSync(emptyOut));

  // 2. Multi-file + empty file + special chars (spaces, CJK, emoji, quotes) + deep path + 2 MiB mixed file
  const richDir = join(root, "rich-ws");
  const deepSub = join(richDir, "a", "b", "c", "d", "e", "f", "g");
  mkdirSync(deepSub, { recursive: true });
  writeFileSync(join(richDir, "empty.txt"), Buffer.alloc(0));
  writeFileSync(join(richDir, "中文 空格 'quote' 😀.txt"), "unicode-content-✓");
  writeFileSync(join(deepSub, "leaf.txt"), "deep-leaf");
  const largeBuf = Buffer.concat([Buffer.alloc(1024 * 1024, 0x61), randomBytes(1024 * 1024)]);
  writeFileSync(join(richDir, "large.bin"), largeBuf);

  const richArc = join(root, "rich.tar.zst");
  const richOut = join(root, "rich-out");
  mkdirSync(richOut);
  await mb.ask("workspace.pack", { dir: richDir, out: richArc });
  const richRes = await mb.ask<{ refused: unknown[] }>("workspace.unpack", { path: richArc, dest: richOut });
  assert.deepEqual(richRes.refused, []);
  assert.equal(statSync(join(richOut, "empty.txt")).size, 0);
  assert.equal(readFileSync(join(richOut, "中文 空格 'quote' 😀.txt"), "utf8"), "unicode-content-✓");
  assert.equal(readFileSync(join(richOut, "a", "b", "c", "d", "e", "f", "g", "leaf.txt"), "utf8"), "deep-leaf");
  assert.equal(sha256(readFileSync(join(richOut, "large.bin"))), sha256(largeBuf));

  // Single-file extraction (`workspace.file`)
  const singleOut = join(root, "single-leaf.txt");
  const fileRes = await mb.ask<{ found: boolean }>("workspace.file", {
    path: richArc,
    wanted: ["a", "b", "c", "d", "e", "f", "g", "leaf.txt"],
    out: singleOut,
  });
  assert.equal(fileRes.found, true);
  assert.equal(readFileSync(singleOut, "utf8"), "deep-leaf");

  // 3. Path traversal safety:
  //   - `..` entries are skipped without writing outside `dest`
  //   - leading `/` is stripped (confined inside `dest`, never written to `/tmp/...`)
  //   - writing through an escaping symlink or hard link outside `dest` is rejected with an error
  const body = Buffer.from("pwned");
  for (const [name, tarPath] of [
    ["dotdot", "../escape.txt"],
    ["nested-dotdot", "sub/../../escape.txt"],
  ] as const) {
    const evilArc = join(root, `evil-${name}.tar.zst`);
    await tarOfHeaders(evilArc, [
      gnuHeader(Buffer.from(tarPath), "0", { size: body.length, mode: 0o644, uid: 0, gid: 0, mtime: 1_700_000_000 }),
      body,
      padding(body.length),
    ]);
    const dest = join(root, `evil-out-${name}`);
    mkdirSync(dest);
    await mb.ask("workspace.unpack", { path: evilArc, dest });
    assert.equal(existsSync(join(root, "escape.txt")), false, `${name} must not write outside dest`);
    assert.equal(existsSync(join(dest, "escape.txt")), false, `${name} must skip traversal entry`);
  }

  // Absolute path: leading `/` stripped so nothing escapes to `/tmp`
  const absArc = join(root, "evil-absolute.tar.zst");
  await tarOfHeaders(absArc, [
    gnuHeader(Buffer.from("/tmp/sf-abs-escape.txt"), "0", { size: body.length, mode: 0o644, uid: 0, gid: 0, mtime: 1_700_000_000 }),
    body,
    padding(body.length),
  ]);
  const absDest = join(root, "evil-out-absolute");
  mkdirSync(absDest);
  await mb.ask("workspace.unpack", { path: absArc, dest: absDest });
  assert.equal(existsSync("/tmp/sf-abs-escape.txt"), false, "absolute path must never write to /tmp");

  // Escaping symlink + file through symlink MUST reject
  const symArc = join(root, "evil-symlink.tar.zst");
  await tarOfHeaders(symArc, [
    gnuHeader(Buffer.from("out"), "2", { size: 0, mode: 0o777, uid: 0, gid: 0, mtime: 1_700_000_000 }, Buffer.from(root)),
    gnuHeader(Buffer.from("out/escape.txt"), "0", { size: body.length, mode: 0o644, uid: 0, gid: 0, mtime: 1_700_000_000 }),
    body,
    padding(body.length),
  ]);
  const symDest = join(root, "evil-out-symlink");
  mkdirSync(symDest);
  await assert.rejects(
    () => mb.ask("workspace.unpack", { path: symArc, dest: symDest }),
    /trying to unpack outside of destination path/,
  );
  assert.equal(existsSync(join(root, "escape.txt")), false, "symlink traversal must not write outside dest");

  // Hard link outside destination MUST reject
  const hardArc = join(root, "evil-hardlink.tar.zst");
  await tarOfHeaders(hardArc, [
    gnuHeader(Buffer.from("h"), "1", { size: 0, mode: 0o644, uid: 0, gid: 0, mtime: 1_700_000_000 }, Buffer.from("../escape.txt")),
  ]);
  const hardDest = join(root, "evil-out-hardlink");
  mkdirSync(hardDest);
  await assert.rejects(
    () => mb.ask("workspace.unpack", { path: hardArc, dest: hardDest }),
    /hard link outside of destination path/,
  );

  // 4. Truncated & tampered archive bytes must error safely without panicking or crashing the builder
  const rawArc = readFileSync(richArc);
  for (const cut of [0, 4, 16, Math.floor(rawArc.length / 2), rawArc.length - 1]) {
    const truncPath = join(root, `trunc-${cut}.tar.zst`);
    const truncOut = join(root, `trunc-out-${cut}`);
    mkdirSync(truncOut);
    writeFileSync(truncPath, rawArc.subarray(0, cut));
    await assert.rejects(() => mb.ask("workspace.unpack", { path: truncPath, dest: truncOut }));
  }
  const tampered = Buffer.from(rawArc);
  tampered[Math.floor(tampered.length / 2)] ^= 0xff;
  const tamperedPath = join(root, "tampered.tar.zst");
  const tamperedOut = join(root, "tampered-out");
  mkdirSync(tamperedOut);
  writeFileSync(tamperedPath, tampered);
  await assert.rejects(() => mb.ask("workspace.unpack", { path: tamperedPath, dest: tamperedOut }));

  // 5. Segmented transcript pack / restore / tampered rejection
  const trSrc = join(root, "transcript.jsonl");
  const trZst = join(root, "transcript.jsonl.zst");
  const trRestored = join(root, "transcript.restored.jsonl");
  const trData = Buffer.from(
    Array.from({ length: 200 }, (_, i) => JSON.stringify({ line: i, text: `msg-${i}-中文-${"x".repeat(64)}` })).join("\n") + "\n",
  );
  writeFileSync(trSrc, trData);
  await mb.ask("pack", { path: trSrc, temp: trZst });
  assert.equal((await mb.ask<{ segmented: boolean }>("segmented", { path: trZst })).segmented, true);
  await mb.ask("restore", { source: trZst, temp: trRestored });
  assert.equal(sha256(readFileSync(trRestored)), sha256(trData));

  const badTr = Buffer.from(readFileSync(trZst));
  badTr[Math.floor(badTr.length / 2)] ^= 0xff;
  const badTrPath = join(root, "transcript.bad.zst");
  writeFileSync(badTrPath, badTr);
  await assert.rejects(() => mb.ask("check", { path: badTrPath }));

  // Builder process must still be alive and healthy after all error cases!
  const verifyOut = join(root, "post-err-ok");
  mkdirSync(verifyOut);
  await mb.ask("workspace.unpack", { path: emptyArc, dest: verifyOut });
  assert.ok(existsSync(verifyOut));
});
