// An account's last hours (store/profile-hours.ts, accounts/pace.ts, GET /profiles/pace): an allowance kept as its
// hour's and cut where it is written, the calls' spending read of usage_15m by hour and model, and the
// read given only the accounts the viewer's workspace may run on.
import assert from "node:assert/strict";
import { describe, test } from "node:test";
import { writeFileSync } from "node:fs";
import { join } from "node:path";
import { DatabaseSync } from "node:sqlite";
import { Accounts } from "../src/accounts/index.ts";
import { checkConfig } from "../src/accounts/check.ts";
import { agyAllowance, agyScopeForModel } from "../src/accounts/agy-quota.ts";
import { paceView, spendScopes, spendWeight } from "../src/accounts/pace.ts";
import { routes } from "../src/api/routes/accounts.ts";
import type { Request } from "../src/api/request.ts";
import { ConfigFile } from "../src/ops/config.ts";
import { Store } from "../src/store/store.ts";
import { HOUR_MS, PACE_HOURS } from "../src/store/profile-hours.ts";
import { fingerprint } from "../src/sessions/decision.ts";
import { temp } from "./accounts-fakes.ts";
import { testClock } from "./hub-fakes.ts";

/// A store on a clock the test sets.
function storeAt(start: number) {
  const time = { now: start };
  const clock = { ...testClock().clock, currentTimeMillisUnsafe: () => time.now };
  return { store: Store.open(":memory:", null, clock), time };
}

const quota = (at: number, used: number, fable = 10) => ({
  state: "ok", checkedAt: at, detail: null,
  windows: [{ label: "5 小时", usedPercent: used / 2, resetsAt: at + 2 * HOUR_MS, minutes: 300 }, { label: "每周", usedPercent: used, resetsAt: at + 50 * HOUR_MS, minutes: 10080 }],
  scoped: [{ label: "每周 · Fable", usedPercent: fable, resetsAt: at + 50 * HOUR_MS, minutes: 10080, scope: "Fable" }],
});

let ids = 0;
function call(store: Store, at: number, profile: string | null, runtime: string, model: string | null, tokens: { input?: number; output?: number; cacheRead?: number } = {}) {
  store.db.prepare(`INSERT INTO usage (id, at, session, profile, runtime, model, input, cache_read, cache_write, cache_write_long, output)
    VALUES (?, ?, 's', ?, ?, ?, ?, ?, 0, 0, ?)`).run(`u${ids++}`, at, profile, runtime, model, tokens.input ?? 0, tokens.cacheRead ?? 0, tokens.output ?? 0);
}

describe("an account's last hours", () => {
  test("an allowance read is kept as its hour's, the last reading of the hour, and those PACE_HOURS before it go as it is written", () => {
    const start = 500_000 * HOUR_MS;
    const { store, time } = storeAt(start);
    store.setProfileQuota("cc", quota(start + 60_000, 20));
    store.setProfileQuota("cc", quota(start + 30 * 60_000, 24));
    // Unread or refused says nothing of an hour.
    store.setProfileQuota("cc", { state: "unavailable", windows: [], checkedAt: start + 40 * 60_000 });
    let read = store.profileHours(start / HOUR_MS);
    assert.equal(read.quotas.length, 1);
    assert.deepEqual(read.quotas[0]!.windows.map((w) => [w.label, w.scope, w.usedPercent, w.minutes]), [
      ["5 小时", null, 12, 300], ["每周", null, 24, 10080], ["每周 · Fable", "Fable", 10, 10080],
    ]);
    // An hour each, up to 193 hours later: the oldest goes as the newest is written.
    for (let h = 1; h <= PACE_HOURS + 1; h++) store.setProfileQuota("cc", quota(start + h * HOUR_MS, 30));
    const rows = store.db.prepare("SELECT hour FROM profile_quota_hours WHERE profile = 'cc' ORDER BY hour").all() as { hour: number }[];
    assert.equal(rows.length, PACE_HOURS + 1);
    assert.equal(rows[0]!.hour, start / HOUR_MS + 1);
    time.now = start + (PACE_HOURS + 1) * HOUR_MS;
    read = store.profileHours(time.now / HOUR_MS);
    assert.equal(read.quotas.length, PACE_HOURS + 1);
    store.forgetProfileHours("cc");
    assert.equal(store.profileHours(time.now / HOUR_MS).quotas.length, 0);
    store.close();
  });

  test("an allowance with windows is kept in one transaction, one without in one statement", () => {
    const start = 550_000 * HOUR_MS;
    const { store } = storeAt(start);
    store.setProfileQuota("cc", quota(start - PACE_HOURS * HOUR_MS - HOUR_MS, 5));
    const said: string[] = [];
    // (on the database under the store's timing proxy, which calls its exec)
    const exec = DatabaseSync.prototype.exec;
    store.db.exec = function (this: DatabaseSync, sql: string) { said.push(sql); return exec.call(this, sql); };
    store.setProfileQuota("cc", quota(start + 60_000, 20));
    assert.deepEqual(said, ["BEGIN IMMEDIATE", "COMMIT"], "the status, its hour and the old hours' cut committed once");
    const rows = store.db.prepare("SELECT hour FROM profile_quota_hours WHERE profile = 'cc'").all() as { hour: number }[];
    assert.deepEqual(rows.map((r) => r.hour), [start / HOUR_MS], "the hour PACE_HOURS before it let go");
    assert.equal((store.profileStatus().get("cc")!.quota as { checkedAt: number }).checkedAt, start + 60_000);
    said.length = 0;
    store.setProfileQuota("cc", { state: "unavailable", windows: [], checkedAt: start + 120_000 });
    assert.deepEqual(said, [], "no hour to keep: a single write, no transaction");
    assert.equal((store.profileStatus().get("cc")!.quota as { state: string }).state, "unavailable");
    store.close();
  });

  test("the calls' spending is usage_15m's, added up by hour and model, as they are written, grown, replaced and taken", () => {
    const start = 600_000 * HOUR_MS;
    const { store } = storeAt(start);
    // (the hour's four quarters added up: two of them here)
    call(store, start + 5, "cc", "claude", "claude-opus-5-5", { input: 1_000_000 });
    call(store, start + 20 * 60_000, "cc", "claude", "claude-opus-5-5", { output: 1_000_000 });
    call(store, start + HOUR_MS, "cc", "claude", "claude-fable-5-2", { output: 100_000 });
    call(store, start + HOUR_MS, null, "claude", "claude-opus-5-5", { output: 100_000 });
    const of = () => store.profileHours(start / HOUR_MS + 1).spend.map((s) => [s.hour - start / HOUR_MS, s.model, s.calls, s.input, s.output]);
    assert.deepEqual(of(), [[0, "claude-opus-5-5", 2, 1_000_000, 1_000_000], [1, "claude-fable-5-2", 1, 0, 100_000]]);
    // A response grown, one taken off, and one written again in its place.
    store.db.prepare("UPDATE usage SET output = 2000000 WHERE id = ?").run(`u${ids - 3}`);
    store.db.prepare("DELETE FROM usage WHERE id = ?").run(`u${ids - 4}`);
    assert.deepEqual(of(), [[0, "claude-opus-5-5", 1, 0, 2_000_000], [1, "claude-fable-5-2", 1, 0, 100_000]]);
    store.db.prepare(`INSERT OR REPLACE INTO usage (id, at, session, profile, runtime, model, input, cache_read, cache_write, cache_write_long, output)
      VALUES (?, ?, 's', 'cc', 'claude', 'claude-fable-5-2', 0, 0, 0, 0, 300000)`).run(`u${ids - 2}`, start + HOUR_MS);
    assert.deepEqual(of(), [[0, "claude-opus-5-5", 1, 0, 2_000_000], [1, "claude-fable-5-2", 1, 0, 300_000]]);
    // Hours before the PACE_HOURS asked are not read.
    assert.deepEqual(store.profileHours(start / HOUR_MS + PACE_HOURS + 1).spend.map((s) => s.hour - start / HOUR_MS), [1]);
    store.close();
  });

  test("an hour's spending weighs its list price, a model without one a middling price, and counts against its model's window", () => {
    const of = (model: string | null, t: Partial<{ input: number; output: number; cacheRead: number; fast: boolean }>) =>
      spendWeight({ hour: 0, profile: "p", runtime: "claude", model, calls: 1, input: t.input ?? 0, cacheRead: t.cacheRead ?? 0, cacheWrite: 0, cacheWriteLong: 0, output: t.output ?? 0, fast: t.fast ?? false });
    assert.equal(of("claude-opus-5-5", { output: 1_000_000 }), 20);
    assert.equal(of("claude-opus-5-5", { output: 1_000_000, fast: true }), 40);
    assert.equal(of("no-such-model", { input: 1_000_000, cacheRead: 1_000_000, output: 1_000_000 }), 6.1);
    assert.deepEqual(spendScopes("claude", "claude-fable-5-2"), ["Fable", ""]);
    assert.deepEqual(spendScopes("claude", "claude-opus-5-5"), [""]);
    assert.deepEqual(spendScopes("codex", "gpt-6.1-terra"), [""]);
  });

  test("an Antigravity account's calls count against the windows its allowance names, by the scope it gives them", () => {
    assert.deepEqual(spendScopes("agy", "gemini-4-carbon"), ["gemini"]);
    assert.deepEqual(spendScopes("agy", "gemini-4-hydrogen-high"), ["gemini"]);
    assert.deepEqual(spendScopes("agy", "google/gemini-4-argon[high]"), ["gemini", "Argon"]);
    assert.deepEqual(spendScopes("agy", "us.google.gemma-3-27b"), ["gemini"]);
    assert.deepEqual(spendScopes("agy", null), ["gemini"]);
    assert.deepEqual(spendScopes("agy", "claude-opus-5-5"), ["3p"]);
    assert.deepEqual(spendScopes("agy", "anthropic/claude-fable-5-2"), ["3p"]);
    assert.deepEqual(spendScopes("agy", "gpt-6.1-terra"), ["3p"]);
    // (the rule the station's pool picks an account's window by, the same)
    for (const m of [null, "", "gemini-4-carbon", "google/gemini-4-argon[high]", "us.google.gemma-3-27b", "claude-opus-5-5", "gpt-6.1-terra", "grok-5"]) {
      assert.equal(spendScopes("agy", m)[0], agyScopeForModel(m), String(m));
    }
    // An hour of each kept as the allowance said it, and the hours spent: each scope spent is one of a window kept.
    const H0 = 700_000;
    const { windows, scoped } = agyAllowance({ command: { data: { groups: [
      { name: "Gemini Models", buckets: [
        { id: "gemini-weekly", window: "weekly", remaining_fraction: 0.6, reset_time: "2026-11-23T04:49:34Z" },
        { id: "gemini-5h", window: "5h", remaining_fraction: 0.8, reset_time: "2026-11-16T09:49:34Z" },
      ] },
      { name: "Claude and GPT models", buckets: [
        { id: "3p-weekly", window: "weekly", remaining_fraction: 0.9, reset_time: "2026-11-22T13:43:14Z" },
        { id: "3p-5h", window: "5h", remaining_fraction: 1, reset_time: "2026-11-16T09:58:00Z" },
      ] },
      { name: "Gemini 4 Argon", buckets: [{ id: "gemini-argon-wtu-weekly", window: "weekly", remaining_fraction: 0.87, reset_time: "2026-11-23T04:25:54Z" }] },
    ] } } });
    const hour = (model: string) => ({ hour: H0 - 1, profile: "ag", runtime: "agy", model, calls: 1, input: 0, cacheRead: 0, cacheWrite: 0, cacheWriteLong: 0, output: 1_000_000, fast: false });
    const view = paceView(H0 * HOUR_MS, {
      quotas: [{ profile: "ag", hour: H0 - 1, at: H0 * HOUR_MS - 1, windows: [...windows, ...scoped].map((w) => ({ label: w.label, scope: w.scope ?? null, usedPercent: w.usedPercent, resetsAt: w.resetsAt, minutes: w.minutes ?? null })) }],
      spend: [hour("gemini-4-carbon"), hour("gemini-4-argon"), hour("claude-opus-5-5")],
    }, () => true);
    const kept = new Set(view.profiles.ag!.quotas[0]!.windows.map((w) => w.scope));
    const spent = view.profiles.ag!.spend.map((s) => s.scope);
    assert.deepEqual(spent, ["3p", "Argon", "gemini"]);
    for (const scope of spent) assert.ok(kept.has(scope), `${scope} of ${[...kept]}`);
  });

  test("GET /profiles/pace gives the hours of the accounts the viewer's workspace may run on, none of another's", async () => {
    const data = temp("pace-routes");
    writeFileSync(join(data, "config.json"), JSON.stringify({
      profiles: [
        { id: "cc", runtime: "claude", home: "homes/cc", withheld: ["W2"] },
        { id: "cx", runtime: "codex", home: "homes/cx" },
      ],
      connects: [],
    }));
    const config = new ConfigFile(data);
    config.check = checkConfig;
    const start = 800_000 * HOUR_MS;
    const { store, time } = storeAt(start);
    const accounts = new Accounts({
      data, store, config, loginCommands: { claude: "/bin/false", codex: "/bin/false" } as never, machine: null, checkOnStart: false,
      check: async () => ({ state: "ok", detail: "", models: [], checkedAt: 0 }),
      quota: null,
      discover: async (profile) => ({ state: "unsupported", detail: "", model: null, provider: null, models: [], fingerprint: fingerprint(profile) }),
      workspaces: () => ["W1", "W2"],
    });
    accounts.start();
    const table = routes({ accounts, overview: () => ({}) });
    const get = async (viewer: Request["viewer"]): Promise<any> => {
      const r: Request = { method: "GET", path: "/profiles/pace", query: [], headers: {}, body: Buffer.from(""), viewer, lang: "zh" };
      for (const route of table) {
        const found = route.method === "GET" ? route.pattern.exec(r.path) : null;
        if (found) return JSON.parse(String((await route.handle(r, found.slice(1))).body));
      }
      throw new Error("no route");
    };
    try {
      store.setProfileQuota("cc", quota(start - 2 * HOUR_MS, 40));
      store.setProfileQuota("cx", quota(start - HOUR_MS, 10));
      call(store, start - HOUR_MS + 1, "cc", "claude", "claude-fable-5-2", { output: 1_000_000 });
      call(store, start - HOUR_MS + 2, "cx", "codex", "gpt-6.1-terra", { output: 1_000_000 });
      const home = { sub: "s", email: "o@example.com", name: "", role: "owner", workspace: "W1", device: "d" };
      const seen = await get(home);
      assert.equal(seen.nowAt, start);
      assert.equal(seen.fromHour, start / HOUR_MS - PACE_HOURS);
      assert.deepEqual(Object.keys(seen.profiles).sort(), ["cc", "cx"]);
      assert.deepEqual(seen.profiles.cc.quotas.map((q: any) => q.hour - start / HOUR_MS), [-2]);
      assert.deepEqual(seen.profiles.cc.spend, [{ hour: start / HOUR_MS - 1, scope: "", weight: 40 }, { hour: start / HOUR_MS - 1, scope: "Fable", weight: 40 }]);
      assert.deepEqual(seen.profiles.cx.spend, [{ hour: start / HOUR_MS - 1, scope: "", weight: 5 }]);
      // A joined workspace the account is withheld from sees none of it.
      const joined = { ...home, workspace: "W2", home: false };
      assert.deepEqual(Object.keys((await get(joined)).profiles), ["cx"]);
      // Read again in the same minute: what was read then, until an allowance is kept.
      call(store, start - HOUR_MS + 3, "cx", "codex", "gpt-6.1-terra", { output: 1_000_000 });
      assert.deepEqual((await get(home)).profiles.cx.spend, [{ hour: start / HOUR_MS - 1, scope: "", weight: 5 }]);
      time.now = start + 60_000;
      assert.deepEqual((await get(home)).profiles.cx.spend, [{ hour: start / HOUR_MS - 1, scope: "", weight: 10 }]);
    } finally {
      accounts.close();
      store.close();
    }
  });
});
