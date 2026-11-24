// An account's last hours are read by their keys alone (store/profile-hours.ts): GET /profiles/pace's reads, the
// allowances' hours (every profile's, or one's) and the calls' (usage_15m's quarters added up by hour, and their times
// by quarter), look at the hours asked, however many hours are kept before them.
import assert from "node:assert/strict";
import { DatabaseSync } from "node:sqlite";
import { test } from "node:test";
import {
  HOUR_MS, PACE_HOURS, QUOTA_HOURS_FOR_PROFILE_READ, QUOTA_HOURS_READ, SPEED_QUARTER_HOURS, SPEED_QUARTERS_READ, SPEND_HOURS_READ, installProfileHours,
} from "../src/store/profile-hours.ts";
import { installUsage15m } from "../src/store/usage-15m.ts";

const NOW_HOUR = 900_000;
const FROM = NOW_HOUR - PACE_HOURS;
const SPEED_FROM = (NOW_HOUR - SPEED_QUARTER_HOURS) * 4;

/// A database with the hours' tables and the quarters, and `old` hours older than PACE_HOURS of each of five accounts
/// (their allowances and their calls, their times known) before the last PACE_HOURS of each, two of them in a joined
/// workspace's session; `seen` counts each row a statement's WHERE reaches.
function db(old: number) {
  const d = new DatabaseSync(":memory:");
  d.exec(`CREATE TABLE sessions (key TEXT PRIMARY KEY, ws TEXT);
    CREATE TABLE usage (id TEXT PRIMARY KEY, at INTEGER NOT NULL, session TEXT NOT NULL, turn TEXT, thread INTEGER, person TEXT, profile TEXT,
    runtime TEXT NOT NULL, model TEXT, subagent INTEGER NOT NULL DEFAULT 0, fast INTEGER NOT NULL DEFAULT 0, input INTEGER NOT NULL,
    cache_read INTEGER NOT NULL, cache_write INTEGER NOT NULL, cache_write_long INTEGER NOT NULL, output INTEGER NOT NULL,
    calls INTEGER NOT NULL DEFAULT 1, context INTEGER, context_window INTEGER);
    CREATE INDEX usage_at ON usage (at);`);
  installProfileHours(d);
  installUsage15m(d, 0);
  d.exec("INSERT INTO sessions (key, ws) VALUES ('s', NULL), ('j', 'W2')");
  const seen = { n: 0 };
  // (given a row's column, so that it is asked of each row the read reaches)
  d.function("seen", (_row: unknown) => (seen.n++, 1));
  const call = d.prepare(`INSERT INTO usage (id, at, session, profile, runtime, model, input, cache_read, cache_write, cache_write_long, output, gen_ms, gen_output)
    VALUES (?, ?, ?, ?, 'claude', 'claude-opus-5-5', 1, 0, 0, 0, 1, 1000, 1)`);
  const quota = d.prepare("INSERT INTO profile_quota_hours (profile, hour, windows_json, at) VALUES (?, ?, '[]', ?)");
  let id = 0;
  // (allowances' hours older than kept, as a station whose cut had not come yet would hold them; calls of every hour)
  for (let h = FROM - old; h <= NOW_HOUR; h++) {
    for (let p = 0; p < 5; p++) {
      call.run(`u${id++}`, h * HOUR_MS + 1, p < 2 ? "j" : "s", `p${p}`);
      quota.run(`p${p}`, h, h * HOUR_MS);
    }
  }
  return { d, seen };
}

test("GET /profiles/pace's reads look at the hours asked alone, however many hours are kept before them", () => {
  const counted: number[][] = [];
  for (const old of [100, 1000]) {
    const { d, seen } = db(old);
    assert.deepEqual((d.prepare("SELECT scope FROM usage_scope_totals ORDER BY scope").all() as { scope: string }[]).map((r) => r.scope), ["", "W2"]);
    const read = (sql: string, where: string, column: string, ...args: (string | number)[]) => {
      seen.n = 0;
      assert.ok(sql.includes(where), where);
      const rows = d.prepare(sql.replace(where, `${where} AND seen(${column})`)).all(...args);
      return [rows.length, seen.n] as const;
    };
    const [qRows, qSeen] = read(QUOTA_HOURS_READ, "WHERE hour >= ?", "hour", FROM);
    const [oRows, oSeen] = read(QUOTA_HOURS_FOR_PROFILE_READ, "WHERE profile = ? AND hour >= ?", "hour", "p3", FROM);
    const [sRows, sSeen] = read(SPEND_HOURS_READ, "u.quarter >= ?", "u.quarter", FROM * 4);
    const [vRows, vSeen] = read(SPEED_QUARTERS_READ, "u.quarter >= ?", "u.quarter", SPEED_FROM);
    counted.push([qSeen, oSeen, sSeen, vSeen]);
    assert.equal(qSeen, qRows, "each allowance's hour looked at is one given");
    assert.equal(qRows, (PACE_HOURS + 1) * 5);
    assert.equal(oSeen, oRows, "each of the profile's hours looked at is one given");
    assert.equal(oRows, PACE_HOURS + 1);
    // (each hour's calls one quarter's row an account here, of one workspace: each row looked at is an hour given)
    assert.equal(sSeen, sRows, "each quarter looked at is one given");
    assert.equal(sRows, (PACE_HOURS + 1) * 5);
    assert.equal(vSeen, vRows, "each quarter's times looked at are one given");
    assert.equal(vRows, (SPEED_QUARTER_HOURS + 1) * 5);
    const plan = (sql: string, ...args: (string | number)[]) =>
      (d.prepare(`EXPLAIN QUERY PLAN ${sql}`).all(...args) as { detail: string }[]).map((r) => r.detail).join("; ");
    assert.match(plan(QUOTA_HOURS_READ, FROM), /SEARCH profile_quota_hours USING INDEX profile_quota_hours_hour \(hour>\?\)/);
    const one = plan(QUOTA_HOURS_FOR_PROFILE_READ, "p3", FROM);
    assert.match(one, /SEARCH profile_quota_hours USING PRIMARY KEY \(profile=\? AND hour>\?\)/, one);
    // (each workspace's quarters a range of usage_15m's key, in order, not its quarters' index looked up again)
    const spend = plan(SPEND_HOURS_READ, FROM * 4);
    assert.match(spend, /SEARCH u USING PRIMARY KEY \(scope=\? AND quarter>\?\)/, spend);
    const speed = plan(SPEED_QUARTERS_READ, SPEED_FROM);
    assert.match(speed, /SEARCH u USING PRIMARY KEY \(scope=\? AND quarter>\?\)/, speed);
    d.close();
  }
  assert.deepEqual(counted[0], counted[1]);
});
