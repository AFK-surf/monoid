// An account's last hours are read by their index alone (store/profile-hours.ts): GET /profiles/pace's two reads, the
// allowances' hours and the calls' (usage_15m's quarters added up by hour), look at the PACE_HOURS asked, however many
// hours are kept before them.
import assert from "node:assert/strict";
import { DatabaseSync } from "node:sqlite";
import { test } from "node:test";
import { HOUR_MS, PACE_HOURS, QUOTA_HOURS_READ, SPEND_HOURS_READ, installProfileHours } from "../src/store/profile-hours.ts";
import { installUsage15m } from "../src/store/usage-15m.ts";

const NOW_HOUR = 900_000;
const FROM = NOW_HOUR - PACE_HOURS;

/// A database with the hours' tables and the quarters, and `old` hours older than PACE_HOURS of each of five accounts
/// (their allowances and their calls) before the last PACE_HOURS of each; `seen` counts each row a statement's WHERE
/// reaches.
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
  const seen = { n: 0 };
  d.function("seen", () => (seen.n++, 1));
  const call = d.prepare("INSERT INTO usage (id, at, session, profile, runtime, model, input, cache_read, cache_write, cache_write_long, output) VALUES (?, ?, 's', ?, 'claude', 'claude-opus-5-5', 1, 0, 0, 0, 1)");
  const quota = d.prepare("INSERT INTO profile_quota_hours (profile, hour, windows_json, at) VALUES (?, ?, '[]', ?)");
  let id = 0;
  // (allowances' hours older than kept, as a station whose cut had not come yet would hold them; calls of every hour)
  for (let h = FROM - old; h <= NOW_HOUR; h++) {
    for (let p = 0; p < 5; p++) {
      call.run(`u${id++}`, h * HOUR_MS + 1, `p${p}`);
      quota.run(`p${p}`, h, h * HOUR_MS);
    }
  }
  return { d, seen };
}

test("GET /profiles/pace's reads look at the PACE_HOURS asked alone, however many hours are kept before them", () => {
  const counted: number[][] = [];
  for (const old of [100, 1000]) {
    const { d, seen } = db(old);
    const read = (sql: string, where: string, from: number) => {
      seen.n = 0;
      assert.ok(sql.includes(where), where);
      const rows = d.prepare(sql.replace(where, `${where} AND seen()`)).all(from);
      return [rows.length, seen.n] as const;
    };
    const [qRows, qSeen] = read(QUOTA_HOURS_READ, "WHERE hour >= ?", FROM);
    const [sRows, sSeen] = read(SPEND_HOURS_READ, "WHERE quarter >= ?", FROM * 4);
    counted.push([qSeen, sSeen]);
    assert.equal(qSeen, qRows, "each allowance's hour looked at is one given");
    assert.equal(qRows, (PACE_HOURS + 1) * 5);
    // (each hour's calls one quarter's row an account here: each row looked at is an hour given)
    assert.equal(sSeen, sRows, "each quarter looked at is one given");
    assert.equal(sRows, (PACE_HOURS + 1) * 5);
    const plan = (sql: string, from: number) => (d.prepare(`EXPLAIN QUERY PLAN ${sql}`).all(from) as { detail: string }[]).map((r) => r.detail).join("; ");
    assert.match(plan(QUOTA_HOURS_READ, FROM), /SEARCH profile_quota_hours USING INDEX profile_quota_hours_hour \(hour>\?\)/);
    const spend = plan(SPEND_HOURS_READ, FROM * 4);
    assert.match(spend, /SEARCH usage_15m USING INDEX usage_15m_quarter \(quarter>\?\)/, spend);
    d.close();
  }
  assert.deepEqual(counted[0], counted[1]);
});
