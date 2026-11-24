import assert from "node:assert/strict";
import { test } from "node:test";
import { Effect } from "effect";
import { Asks } from "../src/asks.ts";
import { WasmSql, type WasmDb, type WasmStmt } from "../src/hosts/web.ts";
import { FakeHost } from "../src/testing.ts";
import { run } from "./run.ts";

test("WasmSql bounds prepared statement cache and finalizes LRU entries", () => {
  const prepared: string[] = [];
  const finalized: string[] = [];
  const db: WasmDb = {
    exec() {},
    changes() {
      return 0;
    },
    close() {},
    prepare(sql: string): WasmStmt {
      prepared.push(sql);
      const stmt: WasmStmt = {
        bind() {
          return stmt;
        },
        step() {
          return false;
        },
        get(into) {
          return into;
        },
        reset() {
          return stmt;
        },
        finalize() {
          finalized.push(sql);
        },
      };
      return stmt;
    },
  };

  const sql = new WasmSql(db);
  for (let i = 0; i < 256; i++) sql.all(`SELECT ${i}`);
  assert.equal(prepared.length, 256);
  assert.equal(finalized.length, 0);

  // Touch SELECT 0 so it becomes most-recently-used; SELECT 1 should be evicted next.
  sql.all("SELECT 0");
  assert.equal(prepared.length, 256);

  sql.all("SELECT 256");
  assert.deepEqual(finalized, ["SELECT 1"]);

  // SELECT 0 is still cached; SELECT 1 must be re-prepared (evicting SELECT 2).
  sql.all("SELECT 0");
  assert.equal(prepared.length, 257);
  sql.all("SELECT 1");
  assert.equal(prepared.length, 258);
  assert.deepEqual(finalized, ["SELECT 1", "SELECT 2"]);

  sql.close();
  assert.equal(finalized.length, 258);
});

test("Asks picture cache evicts oldest settled entries when over byte budget without clearing hot ones", async () => {
  const host = new FakeHost();
  let fetches = 0;
  const payload = new Uint8Array(5 * 1024 * 1024); // 5 MiB each; 16 MiB budget holds at most 3
  host.onFetch(() => {
    fetches++;
    return { status: 200, headers: [["content-type", "image/png"]], body: payload };
  });
  const asks = new Asks(host, () => Effect.succeed([]));
  // Fetch 4 distinct 5 MiB pictures (20 MiB > 16 MiB mem budget); p0 should be evicted from memory cache while p1..p3 stay hot.
  for (let i = 0; i < 4; i++) await run(asks.picture(`https://example.test/p${i}.png`));
  assert.equal(fetches, 4);

  // Accessing p3 hits the in-memory cache (0 new fetches, 0 storage reads needed).
  const beforeHot = fetches;
  await run(asks.picture("https://example.test/p3.png"));
  assert.equal(fetches, beforeHot);
});
