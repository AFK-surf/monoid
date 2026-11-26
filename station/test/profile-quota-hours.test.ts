// An account's last hours (store/profile-hours.ts, accounts/pace.ts, GET /profiles/pace): an allowance kept as its
// hour's and cut where it is written, the calls' spending read of usage_15m by hour and model, and the
// read given only the accounts the viewer's workspace may run on.
import assert from "node:assert/strict";
import { describe, test } from "node:test";
import { writeFileSync } from "node:fs";
import { join } from "node:path";
import { DatabaseSync } from "node:sqlite";
import { Accounts } from "../src/accounts/index.ts";
import { learn as learnCatalog } from "../src/accounts/catalog.ts";
import { checkConfig } from "../src/accounts/check.ts";
import { agyAllowance, agyScopeForModel } from "../src/accounts/agy-quota.ts";
import { paceView, spendScopes, spendWeight } from "../src/accounts/pace.ts";
import { routes } from "../src/api/routes/accounts.ts";
import type { Request } from "../src/api/request.ts";
import { ConfigFile } from "../src/ops/config.ts";
import { Store } from "../src/store/store.ts";
import { HOUR_MS, PACE_HOURS, SPEED_QUARTER_HOURS } from "../src/store/profile-hours.ts";
import { fingerprint } from "../src/sessions/decision.ts";
import { temp } from "./accounts-fakes.ts";
import { testClock } from "./hub-fakes.ts";

/// A store on a clock the test sets.
function storeAt(start: number) {
  const time = { now: start };
  const clock = { ...testClock().clock, currentTimeMillisUnsafe: () => time.now };
  return { store: Store.open(":memory:", null, clock), time, clock };
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

  test("every profile's allowances' hours from an hour on are those kept from it on, by profile and hour, none with none kept", () => {
    const start = 520_000 * HOUR_MS;
    const { store } = storeAt(start);
    const from = start / HOUR_MS;
    assert.deepEqual(store.profileQuotaHours(from), []);
    const put = store.db.prepare("INSERT INTO profile_quota_hours (profile, hour, windows_json, at) VALUES (?, ?, ?, ?)");
    // (one profile's hours all older than asked, one's first at the hour asked, others older and newer, written apart)
    for (const [profile, hours] of [["mid", [-3, -1, 0, 2, 5]], ["old", [-10, -2, -1]], ["edge", [0, 1]], ["a", [-1, 3]], ["zz", [7, -7, 0]]] as const) {
      for (const h of hours) put.run(profile, from + h, JSON.stringify([{ label: `${profile}${h}`, scope: null, usedPercent: h + 50, resetsAt: null, minutes: null }]), (from + h) * HOUR_MS + 1);
    }
    const want = (store.db.prepare("SELECT profile, hour, at, windows_json FROM profile_quota_hours WHERE hour >= ? ORDER BY profile, hour").all(from) as
      { profile: string; hour: number; at: number; windows_json: string }[]).map((r) => ({ profile: r.profile, hour: r.hour, at: r.at, windows: JSON.parse(r.windows_json) }));
    const got = store.profileQuotaHours(from);
    assert.deepEqual(got, want);
    assert.deepEqual(got.map((q) => [q.profile, q.hour - from]), [["a", 3], ["edge", 0], ["edge", 1], ["mid", 0], ["mid", 2], ["mid", 5], ["zz", 0], ["zz", 7]]);
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

  test("GET /profiles/pace reads again only what changed: an allowance kept its profile's hours, each minute the calls' last two hours, every 15 minutes or as the clock goes back all", async () => {
    const data = temp("pace-cache");
    writeFileSync(join(data, "config.json"), JSON.stringify({
      profiles: [{ id: "cc", runtime: "claude", home: "homes/cc" }, { id: "cx", runtime: "codex", home: "homes/cx" }],
      connects: [],
    }));
    const config = new ConfigFile(data);
    config.check = checkConfig;
    const H = 810_000;
    const t0 = H * HOUR_MS + 50 * 60_000;
    const { store, time, clock } = storeAt(t0);
    const used = { cc: 40 };
    const accounts = new Accounts({
      data, store, config, loginCommands: { claude: "/bin/false", codex: "/bin/false" } as never, machine: null, checkOnStart: false, clock,
      check: async () => ({ state: "ok", detail: "", models: [], checkedAt: 0 }),
      quota: async () => quota(time.now, used.cc) as never,
      discover: async (profile) => ({ state: "unsupported", detail: "", model: null, provider: null, models: [], fingerprint: fingerprint(profile) }),
      workspaces: () => ["W1"],
    });
    accounts.start();
    // What the accounts asked of the store, while `record` says so.
    const asked: [string, ...unknown[]][] = [];
    let record = true;
    // A read that throws once, as the database refusing it would (SQLITE_BUSY, an I/O error).
    const failing = new Set<string>();
    for (const name of ["profileHours", "profileQuotaHours", "profileQuotaHoursFor", "profileSpendHours", "profileSpeedQuarters"] as const) {
      const real = (store[name] as (...a: unknown[]) => unknown).bind(store);
      (store as any)[name] = (...args: unknown[]) => {
        if (record) asked.push([name, ...args]);
        if (failing.delete(name)) throw new Error("database is locked");
        return real(...args);
      };
    }
    const table = routes({ accounts, overview: () => ({}) });
    const home = { sub: "s", email: "o@example.com", name: "", role: "owner", workspace: "W1", device: "d" } as Request["viewer"];
    const get = async (): Promise<any> => {
      asked.length = 0;
      const r: Request = { method: "GET", path: "/profiles/pace", query: [], headers: {}, body: Buffer.from(""), viewer: home, lang: "zh" };
      for (const route of table) {
        const found = route.method === "GET" ? route.pattern.exec(r.path) : null;
        if (found) return JSON.parse(String((await route.handle(r, found.slice(1))).body));
      }
      throw new Error("no route");
    };
    // What a read of all of it now gives.
    const fresh = () => {
      record = false;
      try { return JSON.parse(JSON.stringify(paceView(time.now, store.profileHours(Math.floor(time.now / HOUR_MS)), () => true))); }
      finally { record = true; }
    };
    const spendHours = (view: any, profile: string) => view.profiles[profile].spend.filter((s: any) => s.scope === "").map((s: any) => [s.hour - H, s.weight]);
    try {
      // (an allowance's hour that leaves PACE_HOURS as the next hour comes, and calls of an old hour and the last two)
      store.setProfileQuota("cc", quota((H - PACE_HOURS) * HOUR_MS + 1, 5));
      store.setProfileQuota("cx", quota(t0 - HOUR_MS, 10));
      call(store, (H - PACE_HOURS) * HOUR_MS + 1, "cc", "claude", "claude-opus-5-5", { output: 1_000_000 });
      call(store, (H - 5) * HOUR_MS + 1, "cc", "claude", "claude-opus-5-5", { output: 1_000_000 });
      call(store, (H - 1) * HOUR_MS + 1, "cx", "codex", "gpt-6.1-terra", { output: 1_000_000 });
      let seen = await get();
      assert.deepEqual(asked.map((a) => a[0]), ["profileHours", "profileQuotaHours", "profileSpendHours", "profileSpeedQuarters"]);
      assert.deepEqual(seen, fresh());

      // The same minute, an allowance kept: that profile's hours read again alone, and the calls' not at all; a read of
      // them that fails is asked again the next time.
      time.now = t0 + 1_000;
      used.cc = 60;
      await accounts.refreshQuota("cc");
      failing.add("profileQuotaHoursFor");
      assert.throws(() => accounts.paceView(home), /database is locked/);
      seen = await get();
      assert.deepEqual(asked, [["profileQuotaHoursFor", "cc", H - PACE_HOURS]]);
      assert.deepEqual(seen.profiles.cc.quotas.map((q: any) => [q.hour - H, q.windows[1].usedPercent]), [[-PACE_HOURS, 5], [0, 60]]);
      assert.equal(seen.nowAt, time.now);
      assert.deepEqual(seen, fresh());

      // The next minute: the calls' last two hours read again, those before as they were read.
      time.now = t0 + 60_000;
      call(store, H * HOUR_MS + 2, "cc", "claude", "claude-opus-5-5", { output: 1_000_000 });
      call(store, (H - 1) * HOUR_MS + 2, "cx", "codex", "gpt-6.1-terra", { output: 1_000_000 });
      seen = await get();
      assert.deepEqual(asked, [["profileSpendHours", H - 1], ["profileSpeedQuarters", (H - SPEED_QUARTER_HOURS) * 4]]);
      assert.deepEqual(spendHours(seen, "cc"), [[-PACE_HOURS, 20], [-5, 20], [0, 20]]);
      assert.deepEqual(spendHours(seen, "cx"), [[-1, 10]]);
      assert.deepEqual(seen, fresh());

      // Into the next hour, 11 minutes on: the hour that left PACE_HOURS let go of the allowances' and the calls' alike.
      time.now = (H + 1) * HOUR_MS + 60_000;
      seen = await get();
      assert.deepEqual(asked, [["profileSpendHours", H], ["profileSpeedQuarters", (H + 1 - SPEED_QUARTER_HOURS) * 4]]);
      assert.deepEqual(seen.profiles.cc.quotas.map((q: any) => q.hour - H), [0]);
      assert.deepEqual(spendHours(seen, "cc"), [[-5, 20], [0, 20]]);
      assert.deepEqual(seen, fresh());

      // A call taken in late in an hour three before (the calls from before, usagefill): not read the next minute...
      call(store, (H - 3) * HOUR_MS + 1, "cc", "claude", "claude-opus-5-5", { output: 1_000_000 });
      time.now = (H + 1) * HOUR_MS + 2 * 60_000;
      seen = await get();
      assert.deepEqual(asked.map((a) => a.slice(0, 2)), [["profileSpendHours", H], ["profileSpeedQuarters", (H + 1 - SPEED_QUARTER_HOURS) * 4]]);
      assert.deepEqual(spendHours(seen, "cc"), [[-5, 20], [0, 20]]);
      // ...and read once 15 minutes have gone since all of them were.
      time.now = t0 + 15 * 60_000;
      seen = await get();
      // (the allowances' hours read again with them: what another process kept shows too)
      assert.deepEqual(asked, [["profileQuotaHours", H + 1 - PACE_HOURS], ["profileSpendHours", H + 1 - PACE_HOURS], ["profileSpeedQuarters", (H + 1 - SPEED_QUARTER_HOURS) * 4]]);
      assert.deepEqual(spendHours(seen, "cc"), [[-5, 20], [-3, 20], [0, 20]]);
      assert.deepEqual(seen, fresh());
      // The minute after: the last two hours again, all of them not till 15 minutes on.
      time.now += 60_000;
      seen = await get();
      assert.deepEqual(asked, [["profileSpendHours", H], ["profileSpeedQuarters", (H + 1 - SPEED_QUARTER_HOURS) * 4]]);
      assert.deepEqual(seen, fresh());
      // Back over the hour, a few minutes: all of it read again.
      time.now = H * HOUR_MS + 59 * 60_000;
      seen = await get();
      assert.deepEqual(asked, [["profileQuotaHours", H - PACE_HOURS], ["profileSpendHours", H - PACE_HOURS], ["profileSpeedQuarters", (H - SPEED_QUARTER_HOURS) * 4]]);
      assert.deepEqual(seen, fresh());

      // The clock two hours on: all of it read again.
      time.now += 2 * HOUR_MS + 60_000;
      seen = await get();
      assert.deepEqual(asked.map((a) => a[0]), ["profileQuotaHours", "profileSpendHours", "profileSpeedQuarters"]);
      assert.equal(asked[1]![1], Math.floor(time.now / HOUR_MS) - PACE_HOURS);
      assert.deepEqual(seen, fresh());
      // Gone back three hours: the allowances' hours and the calls' all read again.
      time.now -= 3 * HOUR_MS;
      seen = await get();
      const back = Math.floor(time.now / HOUR_MS) - PACE_HOURS;
      assert.deepEqual(asked, [["profileQuotaHours", back], ["profileSpendHours", back], ["profileSpeedQuarters", (back + PACE_HOURS - SPEED_QUARTER_HOURS) * 4]]);
      assert.deepEqual(seen, fresh());

      // A profile deleted, in the same minute: its hours read again alone (none), the calls' not at all.
      time.now += 1_000;
      await accounts.deleteProfile("cx", home!);
      seen = await get();
      assert.deepEqual(asked, [["profileQuotaHoursFor", "cx", back]]);
      assert.equal(seen.profiles.cx, undefined);
    } finally {
      accounts.close();
      store.close();
    }
  });

  test("GET /profiles/pace?v=2 compresses safely, serves unchanged and profile-level deltas, and preserves v1 compatibility", async () => {
    const data = temp("pace-v2");
    const writeCfg = (profiles: unknown[]) => writeFileSync(join(data, "config.json"), JSON.stringify({ profiles, connects: [] }));
    writeCfg([
      { id: "cc", runtime: "claude", home: "homes/cc" },
      { id: "cx", runtime: "codex", home: "homes/cx" },
    ]);
    const config = new ConfigFile(data);
    config.check = checkConfig;
    const H = 820_000;
    const t0 = H * HOUR_MS + 10 * 60_000;
    const { store, time, clock } = storeAt(t0);
    const used = { cc: 40 };
    const makeAccounts = () => {
      const a = new Accounts({
        data, store, config, loginCommands: { claude: "/bin/false", codex: "/bin/false" } as never, machine: null, checkOnStart: false, clock,
        check: async () => ({ state: "ok", detail: "", models: [], checkedAt: 0 }),
        quota: async () => quota(time.now, used.cc) as never,
        discover: async (profile) => ({ state: "unsupported", detail: "", model: null, provider: null, models: [], fingerprint: fingerprint(profile) }),
        workspaces: () => ["W1", "W2"],
      });
      a.start();
      return a;
    };
    const accounts = makeAccounts();
    const failing = new Set<string>();
    const realFor = store.profileQuotaHoursFor.bind(store);
    (store as any).profileQuotaHoursFor = (...args: [string, number]) => {
      if (failing.delete("profileQuotaHoursFor")) throw new Error("database is locked");
      return realFor(...args);
    };
    const table = routes({ accounts, overview: () => ({}) });
    const home = { sub: "s", email: "o@example.com", name: "", role: "owner", workspace: "W1", device: "d" } as Request["viewer"];
    const joined = { ...home, workspace: "W2", home: false } as Request["viewer"];
    const get = async (viewer: Request["viewer"], query: [string, string][] = []): Promise<any> => {
      const r: Request = { method: "GET", path: "/profiles/pace", query, headers: {}, body: Buffer.from(""), viewer, lang: "zh" };
      for (const route of table) {
        const found = route.method === "GET" ? route.pattern.exec(r.path) : null;
        if (found) return JSON.parse(String((await route.handle(r, found.slice(1))).body));
      }
      throw new Error("no route");
    };
    const applyDelta = (base: any, delta: any) => {
      assert.equal(delta.delta, true);
      assert.equal(delta.base, base.rev);
      const profiles: Record<string, any> = {};
      for (const id of delta.keep) profiles[id] = base.profiles[id];
      for (const [id, p] of Object.entries(delta.profiles)) profiles[id] = p;
      return {
        rev: delta.rev,
        nowAt: delta.nowAt,
        fromHour: delta.fromHour,
        profiles,
        speedHours: delta.speedHours ?? base.speedHours,
        speedQuarters: delta.speedQuarters ?? base.speedQuarters,
      };
    };
    try {
      // Seed quotas including scope: null with "Weekly · Fable" and minutes: null.
      store.setProfileQuota("cc", {
        state: "ok", checkedAt: t0 - HOUR_MS, detail: null,
        windows: [
          { label: "5 小时", usedPercent: 10, resetsAt: t0 + 2 * HOUR_MS, minutes: 300 },
          { label: "Weekly · Fable", usedPercent: 15, resetsAt: t0 + 50 * HOUR_MS, minutes: 10080 },
          { label: "5 小时", usedPercent: 20, resetsAt: t0 + 2 * HOUR_MS, minutes: null },
        ],
        scoped: [{ label: "每周 · Fable", usedPercent: 25, resetsAt: t0 + 50 * HOUR_MS, minutes: 10080, scope: "Fable" }],
      });
      store.setProfileQuota("cx", quota(t0 - HOUR_MS, 20));
      store.db.prepare(`INSERT INTO usage (id, at, session, profile, runtime, model, input, cache_read, cache_write, cache_write_long, output, gen_ms, gen_output)
        VALUES ('sp1', ?, 's', 'cc', 'claude', 'claude-opus-5-5', 0, 0, 0, 0, 1000, 1000, 1000)`).run(t0 - HOUR_MS);

      // v1 keeps all labels intact and is never mutated by v2.
      const v1Before = await get(home);
      const v2Full = await get(home, [["v", "2"]]);
      const v1After = await get(home);
      assert.deepEqual(v1After, v1Before);
      assert.equal(v1After.profiles.cc.quotas[0].windows[0].label, "5 小时");
      assert.equal(v1After.profiles.cc.quotas[0].windows[3].label, "每周 · Fable");

      // v2 window compression rules:
      const w = v2Full.profiles.cc.quotas[0].windows;
      assert.equal("label" in w[0], false, "minutes!=null & scope=null & no ' · ' omits label");
      assert.equal(w[1].label, "Weekly · Fable", "scope=null & ' · ' MUST keep label");
      assert.equal(w[2].label, "5 小时", "minutes=null MUST keep label");
      assert.equal("label" in w[3], false, "minutes!=null & non-empty scope omits label");
      assert.equal(w[3].scope, "Fable");

      // Same rev -> unchanged.
      const unch = await get(home, [["v", "2"], ["sinceRev", v2Full.rev]]);
      assert.deepEqual(unch, { unchanged: true, rev: v2Full.rev });

      // nextMinute with no data change does NOT advance v2 rev, while legacy v1 nowAt still advances.
      time.now += 60_000;
      const unchMin = await get(home, [["v", "2"], ["sinceRev", v2Full.rev]]);
      assert.deepEqual(unchMin, { unchanged: true, rev: v2Full.rev });
      const v1NextMin = await get(home);
      assert.equal(v1NextMin.nowAt, time.now, "legacy v1 nowAt advances on nextMinute");

      // Legacy v1 reflects label-only changes even when v2 omits that label and keeps its rev.
      store.setProfileQuota("cc", {
        state: "ok", checkedAt: t0 - HOUR_MS, detail: null,
        windows: [
          { label: "5 Hours", usedPercent: 10, resetsAt: t0 + 2 * HOUR_MS, minutes: 300 },
          { label: "Weekly · Fable", usedPercent: 15, resetsAt: t0 + 50 * HOUR_MS, minutes: 10080 },
          { label: "5 小时", usedPercent: 20, resetsAt: t0 + 2 * HOUR_MS, minutes: null },
        ],
        scoped: [{ label: "每周 · Fable", usedPercent: 25, resetsAt: t0 + 50 * HOUR_MS, minutes: 10080, scope: "Fable" }],
      });
      time.now += 15 * 60_000;
      const v1Relabeled = await get(home);
      assert.equal(v1Relabeled.profiles.cc.quotas[0].windows[0].label, "5 Hours", "legacy v1 sees updated label");
      const v2Relabeled = await get(home, [["v", "2"], ["sinceRev", v2Full.rev]]);
      assert.deepEqual(v2Relabeled, { unchanged: true, rev: v2Full.rev }, "v2 rev stays unchanged when omitted label changes");

      // Model catalog price update invalidates cached v2 spend weight and advances rev.
      store.db.prepare(`INSERT INTO usage (id, at, session, profile, runtime, model, input, cache_read, cache_write, cache_write_long, output, gen_ms, gen_output)
        VALUES ('sp_cat', ?, 's', 'cc', 'claude', 'custom-priced-model', 1000000, 0, 0, 0, 0, 0, 0)`).run(t0 - HOUR_MS);
      try {
        learnCatalog({ "custom-priced-model": { cost: { input: 1, output: 5 } } });
        time.now += 15 * 60_000;
        const cat1 = await get(home, [["v", "2"]]);
        learnCatalog({ "custom-priced-model": { cost: { input: 10, output: 5 } } });
        const cat2 = await get(home, [["v", "2"], ["sinceRev", cat1.rev]]);
        assert.equal(cat2.unchanged, undefined, "catalog price change must invalidate cached v2 rev");
        assert.equal(cat2.delta, true);
        assert.ok(cat2.profiles.cc, "affected profile cc must be sent in delta");
      } finally {
        learnCatalog({});
      }
      const v2PreDirty = await get(home, [["v", "2"]]);

      // DB read error does NOT advance rev or clear dirty quota profile.
      time.now += 1_000;
      used.cc = 55;
      await accounts.refreshQuota("cc");
      failing.add("profileQuotaHoursFor");
      assert.throws(() => accounts.paceResponse(home, { v: "2", sinceRev: v2PreDirty.rev }), /database is locked/);

      // Retry succeeds -> profile-level delta with cx in keep, cc in profiles.
      const delta1 = await get(home, [["v", "2"], ["sinceRev", v2PreDirty.rev]]);
      const full1 = await get(home, [["v", "2"]]);
      assert.equal(delta1.delta, true);
      assert.deepEqual(delta1.keep, ["cx"]);
      assert.deepEqual(Object.keys(delta1.profiles), ["cc"]);
      assert.equal("speedHours" in delta1, false);
      assert.equal("speedQuarters" in delta1, false);
      assert.deepEqual(applyDelta(v2PreDirty, delta1), full1);

      // Delayed speedQuarters write within 8h triggers full speedQuarters replacement in delta.
      store.db.prepare(`INSERT INTO usage (id, at, session, profile, runtime, model, input, cache_read, cache_write, cache_write_long, output, gen_ms, gen_output)
        VALUES ('sp2', ?, 's', 'cx', 'codex', 'gpt-6.1-sol', 0, 0, 0, 0, 500, 500, 500)`).run(t0 - 3 * HOUR_MS);
      time.now += 60_000;
      const delta2 = await get(home, [["v", "2"], ["sinceRev", full1.rev]]);
      const full2 = await get(home, [["v", "2"]]);
      assert.equal(delta2.delta, true);
      assert.ok(Array.isArray(delta2.speedQuarters) && delta2.speedQuarters.length >= 2);
      assert.deepEqual(applyDelta(full1, delta2), full2);

      // Joined workspace sees both, then withholding cc removes it via delta.
      const jFull1 = await get(joined, [["v", "2"]]);
      assert.deepEqual(Object.keys(jFull1.profiles).sort(), ["cc", "cx"]);
      config.update((raw) => {
        raw.profiles = [
          { id: "cc", runtime: "claude", home: "homes/cc", withheld: ["W2"] },
          { id: "cx", runtime: "codex", home: "homes/cx" },
        ];
      });
      const jDelta = await get(joined, [["v", "2"], ["sinceRev", jFull1.rev]]);
      const jFull2 = await get(joined, [["v", "2"]]);
      assert.equal(jDelta.delta, true);
      assert.deepEqual(jDelta.keep, ["cx"]);
      assert.deepEqual(Object.keys(jDelta.profiles), []);
      assert.deepEqual(applyDelta(jFull1, jDelta), jFull2);
      assert.deepEqual(Object.keys(jFull2.profiles), ["cx"]);

      // Unknown sinceRev falls back to full.
      const unknownFallback = await get(home, [["v", "2"], ["sinceRev", "deadbeef:00000000:1"]]);
      assert.equal(unknownFallback.delta, undefined);
      assert.equal(unknownFallback.unchanged, undefined);
      assert.deepEqual(unknownFallback, full2);

      // Scope cache eviction past 16 workspaces allocates a strictly fresh rev on recreation.
      const firstScope = await get({ ...home, workspace: "WE0", home: false } as Request["viewer"], [["v", "2"]]);
      for (let i = 1; i <= 17; i++) {
        await get({ ...home, workspace: `WE${i}`, home: false } as Request["viewer"], [["v", "2"]]);
      }
      const recreated = await get({ ...home, workspace: "WE0", home: false } as Request["viewer"], [["v", "2"], ["sinceRev", firstScope.rev]]);
      assert.equal(recreated.unchanged, undefined, "evicted scope must fall back to full");
      assert.equal(recreated.delta, undefined);
      assert.notEqual(recreated.rev, firstScope.rev, "recreated scope must allocate a strictly new rev");

      // New Accounts instance (new bootEpoch) falls back to full for old sinceRev.
      const accounts2 = makeAccounts();
      try {
        const res2 = accounts2.paceResponse(home, { v: "2", sinceRev: full2.rev }) as any;
        assert.equal(res2.delta, undefined);
        assert.equal(res2.unchanged, undefined);
        assert.notEqual(res2.rev.split(":")[0], full2.rev.split(":")[0]);
      } finally {
        accounts2.close();
      }
    } finally {
      accounts.close();
      store.close();
    }
  });
});
