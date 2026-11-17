// What the app's 用量 is given of a workspace whose usage is spread over stations as a real one's is (2026-11-16):
// three stations, one of them come six days ago (`detailSince`), one subscription shared by all three under each its own
// profile's id, a Slack person one station knows the email of and another (that took the connect over) does not, chats
// deleted since they spent, enough people and models that the days' legend takes two lines on a phone. Each value is
// made by the core's own views (views/usage.ts usageView, views/usage-summary.ts usageSummary, the accounts as
// views/profiles.ts workspaceProfiles lists them) and shaped as it goes out (conform `UsageView`), for the app's fixture
// `settings-usage-real` (apps/mbui/src/sfapp/settings/usage_real.mbt: its screens' sweeps and the page's pictures).
// USAGE_APP_WRITE=1 writes it; otherwise this fails where it is not what the core makes now.
import assert from "node:assert/strict";
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { test } from "node:test";
import { conform } from "../src/conform.ts";
import { holdLanguage } from "../src/i18n.ts";
import { workspaceProfiles } from "../src/views/profiles.ts";
import { localDay, usageView, type Source } from "../src/views/usage.ts";
import { usageSummary } from "../src/views/usage-summary.ts";

holdLanguage();
// deno-lint-ignore no-explicit-any
type J = any;

const FILE = join(import.meta.dirname, "../../../apps/mbui/src/sfapp/settings/usage_real.mbt");
const write = process.env.USAGE_APP_WRITE === "1";

const DAY_MS = 86_400_000;
/// 2026-11-16 12:00 at UTC+8.
const NOW = Date.UTC(2026, 10, 16, 4, 0, 0);
const OFFSET = 480;
const day = (back: number) => localDay(NOW - back * DAY_MS, OFFSET);

/// A number of its own for each (station, day, which) in [0, 1): the same every run.
function noise(...parts: (string | number)[]): number {
  let h = 2166136261;
  for (const c of parts.join("|")) h = Math.imul(h ^ c.charCodeAt(0), 16777619) >>> 0;
  return (h % 10_000) / 10_000;
}

const MODELS = ["claude-opus-5-5", "claude-sonnet-5", "gpt-6", "claude-haiku-5", "kimi-k3", "gemini-3-pro"];
const PRICES = { rows: [
  { model: "claude-opus-5-5", input: 5, cacheRead: 0.5, cacheWrite: 6.25, output: 25 },
  { model: "claude-sonnet-5", input: 3, cacheRead: 0.3, cacheWrite: 3.75, output: 15 },
  { model: "claude-haiku-5", input: 1, cacheRead: 0.1, cacheWrite: 1.25, output: 5 },
  { model: "gpt-6", input: 2.5, cacheRead: 0.25, output: 15 },
  { model: "kimi-k3", input: 0.6, cacheRead: 0.15, output: 2.5 },
  { model: "gemini-3-pro", input: 2, cacheRead: 0.2, output: 12 },
] };

type Plan = { address: string; id: string; name: string; days: number; people: string[]; profiles: string[]; threads: number[]; gone: number[] };
const STATIONS: Plan[] = [
  { address: "ws/willow", id: "st-willow", name: "Willow", days: 60, people: ["lin@cue.surf", "slack:T1:U02", "zhao@cue.surf", "slack:T1:U05"], profiles: ["cc", "sh-team"], threads: [1, 2, 3, 4, 5], gone: [41, 42, 43] },
  { address: "ws/maple", id: "st-maple", name: "Maple", days: 60, people: ["slack:T1@st-willow:U02", "wu@cue.surf", "chen@cue.surf"], profiles: ["sh-team-m", "kimi"], threads: [11, 12, 13, 14], gone: [51, 52] },
  // (come six days ago: said from then on)
  { address: "ws/birch", id: "st-birch", name: "Birch", days: 6, people: ["lin@cue.surf", "slack:T1@st-willow:U05"], profiles: ["sh-team-b"], threads: [21, 22], gone: [61] },
];
const TITLES: Record<number, string> = {
  1: "整理发布清单", 2: "给设置页加一个深色模式开关", 3: "排查列表滚动卡顿", 4: "补充支付回调单元测试", 5: "#ops 夜间构建",
  11: "夜里的构建又失败了", 12: "迁移账单服务到新集群", 13: "复盘上周的线上故障", 14: "#design 评审",
  21: "Birch 上的模拟器跑测试", 22: "压测新的同步协议",
};

function rowsOf(s: Plan): J[] {
  const rows: J[] = [];
  for (let back = 0; back < s.days; back++) {
    const d = day(back);
    for (const [i, thread] of [...s.threads, ...s.gone].entries()) {
      const gone = s.gone.includes(thread);
      // (the chats deleted since spent in the last week alone, as much as their agents did then)
      if (gone && back > 6) continue;
      const r = noise(s.address, d, thread);
      if (!gone && r < 0.35) continue;
      const calls = Math.round(4 + r * 60);
      const model = MODELS[(i + Math.floor(r * 7)) % MODELS.length]!;
      const person = s.people[(i + back) % s.people.length]!;
      const profile = model === "kimi-k3" && s.profiles.includes("kimi") ? "kimi" : s.profiles[(i + back) % s.profiles.length]!;
      const cost = gone ? 0 : Math.round(r * 900) / 100;
      rows.push({ day: d, session: `chat:c-${thread}`, thread, person, profile, runtime: model.startsWith("claude") ? "claude" : "codex", model, calls,
        input: calls * 1200, cacheRead: calls * 9800, cacheWrite: calls * 300, output: calls * 420, cost });
    }
  }
  // the deleted chats' cost: $428 over the last week, shared out among them
  const gone = rows.filter((r) => s.gone.includes(r.thread));
  const share = { "ws/willow": 260, "ws/maple": 120, "ws/birch": 48 }[s.address]!;
  const each = Math.floor((share / gone.length) * 100) / 100;
  gone.forEach((r, i) => (r.cost = i === gone.length - 1 ? Math.round((share - each * (gone.length - 1)) * 100) / 100 : each));
  return rows;
}

function historyOf(s: Plan): J {
  const days: J[] = [];
  const back = s.days === 60 ? 330 : s.days;
  for (let b = 0; b < back; b++) {
    const r = noise("history", s.address, b);
    if (r < 0.2) continue;
    days.push({ day: day(b), runtime: "claude", model: "claude-opus-5-5", tokens: Math.round(r * 9e7 * (1 + (back - b) / back)), calls: Math.round(r * 900) });
  }
  return { days, cards: 412, picked: 301, places: s.address === "ws/maple" ? { ember: 210, slack: 96 } : { ember: 380, slack: 54, feishu: 12 }, archived: s.days === 60 ? 640 : 18, remoteRuns: s.days === 60 ? 212 : 9 };
}

const PEOPLE: Record<string, J> = {
  "lin@cue.surf": { id: "lin@cue.surf", name: "lin@cue.surf", email: "lin@cue.surf", via: "cloud" },
  "zhao@cue.surf": { id: "zhao@cue.surf", name: "zhao@cue.surf", email: "zhao@cue.surf", via: "cloud" },
  "wu@cue.surf": { id: "wu@cue.surf", name: "wu@cue.surf", email: "wu@cue.surf", via: "cloud" },
  "chen@cue.surf": { id: "chen@cue.surf", name: "chen@cue.surf", email: "chen@cue.surf", via: "cloud" },
  // (Willow heard the Slack people's emails; Maple and Birch, that took the connect over, have not)
  "slack:T1:U02": { id: "slack:T1:U02", name: "Ana", email: "ana@cue.surf", via: "slack" },
  "slack:T1:U05": { id: "slack:T1:U05", name: "Kai", email: "kai@cue.surf", via: "slack" },
  "slack:T1@st-willow:U02": { id: "slack:T1@st-willow:U02", name: "U02", email: null, via: "slack" },
  "slack:T1@st-willow:U05": { id: "slack:T1@st-willow:U05", name: "U05", email: null, via: "slack" },
};
const MEMBERS = [
  { email: "lin@cue.surf", name: "林" }, { email: "ana@cue.surf", name: "Ana" }, { email: "zhao@cue.surf", name: "赵" },
  { email: "wu@cue.surf", name: "吴" }, { email: "chen@cue.surf", name: "陈" }, { email: "kai@cue.surf", name: "Kai" },
];

function sources(): Source[] {
  return STATIONS.map((s) => {
    const threads: Record<string, J> = {};
    for (const t of s.threads) threads[String(t)] = { title: TITLES[t], surface: TITLES[t]!.startsWith("#") ? "slack:T1" : "ember", home: `chat:c-${t}`, archived: t === 4 };
    const people: Record<string, J> = {};
    for (const p of s.people) people[p] = PEOPLE[p];
    // (each station's own word for its profiles: Birch has not been told its copy's name)
    const profiles: Record<string, J> = s.address === "ws/willow" ? { cc: { name: "公司 Claude", runtime: "claude" }, "sh-team": { name: "团队 Claude", runtime: "claude" } }
      : s.address === "ws/maple" ? { "sh-team-m": { name: "团队 Claude", runtime: "claude" }, kimi: { name: "Kimi", runtime: "kimi" } } : {};
    const value: J = { from: NOW - 60 * DAY_MS, to: NOW, since: s.days === 60 ? NOW - 400 * DAY_MS : NOW - 6 * DAY_MS, reading: false, prices: PRICES, rows: rowsOf(s), threads, people, profiles, remoteRuns: [], history: historyOf(s) };
    if (s.days !== 60) value.detailSince = NOW - 5 * DAY_MS - 4 * 3_600_000;
    return { address: s.address, name: s.name, online: true, value: { ok: value } };
  });
}

/// The accounts as the accounts' page lists them: the team's subscription hosted on Willow, borrowed by the others.
function accounts(): J[] {
  const sub = (id: string, role: string) => ({ id, name: "团队 Claude", email: "team@cue.surf", runtime: "claude", access: { kind: "subscription" }, share: { id: "share-team", role, host: "st-willow", users: role === "host" ? ["st-maple", "st-birch"] : undefined } });
  const stations = [
    { id: "st-willow", station: "ws/willow", name: "Willow", online: true, overview: { sharing: true, profiles: [{ id: "cc", name: "公司 Claude", runtime: "claude", access: { kind: "env" } }, sub("sh-team", "host")] } },
    { id: "st-maple", station: "ws/maple", name: "Maple", online: true, overview: { sharing: true, profiles: [sub("sh-team-m", "user"), { id: "kimi", name: "Kimi", runtime: "kimi", access: { kind: "env" } }] } },
    { id: "st-birch", station: "ws/birch", name: "Birch", online: true, overview: { sharing: true, profiles: [sub("sh-team-b", "user")] } },
  ];
  return workspaceProfiles(stations).items;
}

/// What the app is sent of `usage` at `days`, split by `split` (none: the core's choice): no summary (given apart).
function shaped(days: number, split: string): J {
  const ss = sources();
  const v = usageView(ss, days, NOW, OFFSET, { id: "lin@cue.surf", email: "lin@cue.surf" }, MEMBERS, split === "" ? {} : { split }, accounts());
  const out = conform("UsageView", v) as J;
  assert.ok("ok" in out, JSON.stringify(out));
  return out.ok;
}

function made(): string {
  const summary = conform("UsageView", { ...shaped(7, ""), summary: usageSummary(sources(), NOW, OFFSET, "cue") }) as J;
  assert.ok("ok" in summary);
  let out = "// Made by client/core-ts/test/usage-app.test.ts (USAGE_APP_WRITE=1): what the core sends 用量 of a workspace of three\n"
    + "// stations as real ones are (that file says which), for the fixture's `settings-usage-real`. Do not edit.\n\n"
    + "///|\n/// The `usage` topic's value at `days` split by `split` (\"\": the core's choice), its summary with it; none for another.\n"
    + "pub fn usage_real(days : Int, split : String) -> Json? {\n  let raw = match (days, split) {\n";
  for (const days of [7, 30]) {
    for (const split of ["", "people", "models", "profiles"]) {
      out += `    (${days}, ${JSON.stringify(split)}) =>\n      (\n        #|${JSON.stringify(shaped(days, split))}\n      )\n`;
    }
  }
  out += "    _ => return None\n  }\n  let summary =\n    #|" + JSON.stringify(summary.ok.summary) + "\n";
  out += "  match (@json.parse(raw) catch { _ => return None }) {\n    Object(o) => {\n      let all = o.copy()\n      all[\"summary\"] = @json.parse(summary) catch { _ => Json::null() }\n      Some(Json::object(all))\n    }\n    _ => None\n  }\n}\n";
  return out;
}

test("the_app_is_given_what_the_core_makes_of_a_workspace_spread_over_stations", () => {
  const text = made();
  if (write) writeFileSync(FILE, text);
  else assert.ok(existsSync(FILE) && readFileSync(FILE, "utf8") === text, `${FILE} is not what the core makes now: USAGE_APP_WRITE=1 writes it`);
});
