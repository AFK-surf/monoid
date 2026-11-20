// The Rust core's views/admin.rs tests, ported.
import assert from "node:assert/strict";
import { test } from "node:test";
import { holdLanguage } from "../src/i18n.ts";
import { admin, feedback, list, overview, sources, user, workspace } from "../src/views/admin.ts";
import { CoreError } from "../src/error.ts";
import { relays } from "../src/views/admin-relays.ts";

holdLanguage();
// deno-lint-ignore no-explicit-any
type J = any;
const NOW = 1_790_000_000;
const DAY = 86_400;

const users = (): J => ({
  users: [
    { sub: "a", email: "ann@x.io", name: "Ann", picture: "", created_at: NOW - 2 * DAY, last_seen: NOW - 3600, admission: "code", workspaces: [{ id: "w1", name: "产品", role: "owner" }], beta: false, may_create: true, creator: true },
    { sub: "b", email: "bob@y.io", name: "", picture: "", created_at: NOW - 40 * DAY, last_seen: NOW - 35 * DAY, admission: null, workspaces: [], beta: true, may_create: false, blocked: true },
    { sub: "c", email: "cat@x.io", name: "Cat", picture: "", created_at: NOW - 10 * DAY, last_seen: null, admission: "invitation", workspaces: [{ id: "w1", name: "产品", role: "member" }] },
  ],
});
const workspaces = (): J => ({
  workspaces: [
    {
      id: "w1", name: "产品", created_at: NOW - 2 * DAY, created_by: { sub: "a", email: "ann@x.io", name: "Ann", picture: "" }, seats: 2,
      members: [{ sub: "a", email: "ann@x.io", name: "Ann", picture: "", role: "owner", added_at: 1, last_seen: NOW - 3600 }, { sub: "c", email: "cat@x.io", name: "Cat", picture: "", role: "member", added_at: 2 }],
      stations: [{ id: "s1", name: "studio", version: "0.1.1212", last_seen: NOW - 60 }, { id: "s2", name: "nas", version: "0.1.1104", last_seen: null }], invitations: [],
    },
    { id: "w2", name: "设计", created_at: NOW - 5 * DAY, created_by: null, members: [], stations: [], invitations: [{ id: "i", role: "member", email: null, inviter: "Ann", expires_at: NOW + DAY }] },
  ],
});
const reports = (): J => ({
  feedback: [
    {
      id: "F2", number: 2, channel: "beta", station: { id: "s1", name: "studio" }, workspace: { id: "w1", name: "产品" }, account: null,
      title: "发送后消息消失", body: "## 步骤\n1. 发一条", area: "web", reporter: "Ann (Slack)", context: { version: "0.1.1212", session: "chat:c-1", extra: { a: 1 } },
      logs: "line 1\nline 2", status: "new", created_at: NOW - 60, updated_at: NOW - 60,
    },
    {
      id: "F1", number: 1, channel: "stable", station: null, workspace: null, account: { sub: "a", email: "ann@x.io", name: "" },
      title: "图标糊了", body: "看着糊", area: "android", reporter: "", context: null, logs: null, status: "fixed", created_at: NOW - DAY, updated_at: NOW,
    },
  ],
});
const ids = (v: J) => v.rows.map((r: J) => r.id);
const count = (v: J, filter: string) => v.filters.find((f: J) => f.id === filter).count;

test("users_are_found_filtered_and_sorted", () => {
  const all = list("users", users(), "", null, null, null, NOW);
  assert.deepEqual(ids(all), ["a", "b", "c"]);
  assert.deepEqual([count(all, "stuck"), count(all, "blocked"), count(all, "dormant"), count(all, "new")], [1, 1, 2, 1]);
  assert.equal(all.rows[1].title, "bob@y.io");
  assert.deepEqual(all.rows[1].marks.map((m: J) => m.label), ["已封禁", "尚未加入", "测试版"]);
  assert.equal(all.rows[0].line, "ann@x.io · 产品");
  const found = list("users", users(), "X.IO 产品", "all", "name", null, NOW);
  assert.deepEqual([ids(found), count(found, "stuck")], [["a", "c"], 0]);
  const page = list("users", users(), "", "dormant", "created", 1, NOW);
  assert.deepEqual([ids(page), page.more, page.found], [["c"], true, 2]);
});

test("emails_given_rights_before_a_sign_in_are_listed_with_the_users_and_have_a_page", () => {
  const v = { ...users(), pending: [{ email: "dan@z.io", beta: true, may_create: true, added_at: NOW - DAY }, { email: "eve@z.io", beta: false, may_create: false, added_at: NOW - 3 * DAY }] };
  const all = list("users", v, "", null, null, null, NOW);
  assert.equal(all.total, 5);
  // Never seen, they sort among those never seen, by when they were added.
  assert.deepEqual(ids(all), ["a", "b", "email:dan@z.io", "email:eve@z.io", "c"]);
  const dan = all.rows[2];
  assert.deepEqual([dan.title, dan.line, dan.marks.map((m: J) => m.label), dan.last_seen], ["dan@z.io", "首次登录后开通：测试版、标准版", ["未登录", "测试版"], null]);
  assert.equal(all.rows[3].line, "首次登录后开通：尚未开通任何资格");
  // Nothing an account did is said of them; what they were given is.
  assert.deepEqual([count(all, "stuck"), count(all, "dormant"), count(all, "new"), count(all, "active")], [1, 2, 1, 1]);
  assert.deepEqual([count(all, "pending"), count(all, "beta"), count(all, "creators")], [2, 2, 2]);
  assert.deepEqual(ids(list("users", v, "dan", null, null, null, NOW)), ["email:dan@z.io"]);
  // Nor are they users in the overview.
  assert.equal(overview(v, workspaces(), { codes: [] }, undefined, NOW, 0).stats[0].value, 3);

  const page = user("email:dan@z.io", v, workspaces(), undefined, NOW);
  assert.deepEqual([page.pending, page.email, page.admission, page.beta, page.mayCreate, page.mayCreateFixed, page.blocked, page.workspaces], [true, "dan@z.io", "未登录", true, true, false, null, []]);
  assert.throws(() => user("email:nobody@z.io", v, workspaces(), undefined, NOW));
  // From a cloud from before it, there are none.
  assert.equal(list("users", users(), "", null, null, null, NOW).total, 3);
});

test("a_code_with_the_test_channel_says_so", () => {
  const v = list("invite-codes", { codes: [{ code: "AAAA-BBBB-CCCC", note: "", beta: true, created_at: NOW - 60, expires_at: NOW + DAY, revoked_at: null, used_at: null, used_by: null, workspace: null }] }, "", null, null, null, NOW);
  assert.deepEqual(v.rows[0].marks.map((m: J) => m.label), ["可用", "测试版"]);
});

test("workspaces_say_what_is_off", () => {
  const all = list("workspaces", workspaces(), "", null, null, null, NOW);
  assert.deepEqual(ids(all), ["w1", "w2"]);
  assert.deepEqual([count(all, "bare"), count(all, "outdated"), count(all, "full"), count(all, "invited")], [1, 1, 1, 1]);
  assert.equal(all.rows[0].state, "online");
  assert.equal(all.rows[1].line, "前成员 创建 · 0 人 · 0 台 station");
  assert.deepEqual(ids(list("workspaces", workspaces(), "nas", null, null, null, NOW)), ["w1"]);
});

test("a_users_page_counts_their_workspaces", () => {
  let page = user("a", users(), workspaces(), null, NOW);
  assert.equal(page.workspaces[0].line, "Owner · 2 人 · 2 台 station");
  assert.deepEqual([page.mayCreate, page.mayCreateFixed], [true, true]);
  page = user("b", users(), workspaces(), null, NOW);
  assert.deepEqual([page.admission, page.mayCreateFixed, page.blocked], ["尚未加入", false, true]);
  assert.throws(() => user("z", users(), workspaces(), null, NOW));
});

test("a_workspaces_page_has_its_people_and_stations", () => {
  const page = workspace("w1", workspaces(), users(), NOW);
  assert.equal(page.people, "2 / 2");
  assert.deepEqual([page.stations[1].state, page.stations[1].outdated], ["error", true]);
  assert.equal(page.members[1].last_seen, null);
  assert.equal(page.members[0].role, "Owner");
});

test("an unlimited station count is shown without a cap and the admin can set one", () => {
  const input = workspaces();
  input.workspaces[0].stations_unlimited = true;
  let page = workspace("w1", input, users(), NOW);
  assert.equal(page.stationCount, "2");
  assert.deepEqual(page.limits, { members: 2, stations: null });
  delete input.workspaces[0].stations_unlimited;
  input.workspaces[0].station_seats = 64;
  page = workspace("w1", input, users(), NOW);
  assert.equal(page.stationCount, "2 / 64");
  assert.deepEqual(page.limits, { members: 2, stations: 64 });
  delete input.workspaces[0].station_seats;
  assert.equal(workspace("w1", input, users(), NOW).limits, null, "an older cloud gives no station limit");
});

test("the_overview_points_at_lists", () => {
  let v = overview(users(), workspaces(), { codes: [] }, null, NOW, 480);
  assert.equal(v.stats[0].value, 3);
  assert.equal(v.weeks.length, 12);
  assert.equal(v.weeks[11].count, 1);
  assert.deepEqual(v.todo.map((x: J) => [x.list, x.filter]), [["users", "stuck"], ["workspaces", "bare"], ["workspaces", "stale"], ["workspaces", "outdated"]]);
  v = overview(users(), workspaces(), { codes: [] }, reports(), NOW, 480);
  assert.deepEqual([v.todo[0].text, v.todo[0].list, v.todo[0].filter], ["1 个新反馈", "feedback", "new"]);
});

test("bug_reports_are_listed_by_status_and_channel", () => {
  const all = list("feedback", reports(), "", null, null, null, NOW);
  assert.deepEqual(ids(all), ["F2", "F1"]);
  assert.deepEqual([count(all, "new"), count(all, "fixed"), count(all, "beta"), count(all, "stable")], [1, 1, 1, 1]);
  assert.equal(all.rows[0].number, "FB-2");
  assert.equal(all.rows[0].line, "Web · 产品 · studio · Ann (Slack)");
  assert.equal(all.rows[1].line, "Android · ann@x.io");
  assert.deepEqual(all.rows[0].marks.map((m: J) => m.label), ["新反馈", "测试版"]);
  assert.deepEqual(ids(list("feedback", reports(), "fb-1", null, null, null, NOW)), ["F1"]);
  assert.deepEqual(ids(list("feedback", reports(), "STUDIO 步骤", null, null, null, NOW)), ["F2"]);
  assert.deepEqual(ids(list("feedback", reports(), "", "fixed", null, null, NOW)), ["F1"]);
});

test("a_bug_reports_page_has_all_of_it_in_text_too", () => {
  let page = feedback("F2", reports());
  assert.deepEqual([page.number, page.status, page.channelLabel], ["FB-2", "new", "测试版"]);
  assert.equal(page.statuses.length, 4);
  const context = page.context.map((c: J) => [c.key, c.value]);
  assert.ok(context.some(([k, v]: J) => k === "version" && v === "0.1.1212") && context.some(([k, v]: J) => k === "extra" && v === '{"a":1}'), JSON.stringify(context));
  const text: string = page.text;
  assert.ok(text.startsWith("FB-2 发送后消息消失\n"), text);
  for (const part of ["渠道: 测试版 (beta)", "Station: studio (s1)", "Workspace: 产品 (w1)", "反馈人: Ann (Slack)", "## 步骤", "session: chat:c-1", "```\nline 1\nline 2\n```"]) assert.ok(text.includes(part), `${part} in ${text}`);
  page = feedback("F1", reports());
  assert.deepEqual([page.logs, page.context.length, page.account.title], [null, 0, "ann@x.io"]);
  assert.ok(!page.text.includes("## 日志"));
  assert.throws(() => feedback("F9", reports()));
  assert.deepEqual(list("feedback", {}, "", null, null, null, NOW).rows, []);
});

test("the_relays_page_says_each_relays_load_now_and_over_the_range", () => {
  // A whole hour in UTC, so the day's buckets fall on local hours (UTC+8).
  const now = NOW - (NOW % 3600);
  const day = (f: (i: number) => number | null) => ({ start: now - 287 * 300, step: 300, sent: Array.from({ length: 288 }, (_, i) => f(i)), recv: Array.from({ length: 288 }, () => 1000), open: Array.from({ length: 288 }, (_, i) => (i === 10 ? 71 : 3)), dropped: [] });
  const week = { start: now - 167 * 3600, step: 3600, sent: Array.from({ length: 168 }, () => 10), recv: [], open: [], dropped: [] };
  const answer = {
    relays: [
      { url: "https://app.still.fail", name: "Cloudflare", at: now - 30, now: { sent: 14_336, recv: 2048, dropped: 0.021, rx: null, tx: null }, open: 71, load1: null, today: { bytes: 4.5 * 1024 ** 3, frames: 1000 }, limits: { bytes: 5 * 1024 ** 3, frames: 20_000_000 }, day: day((i) => (i < 5 ? null : 2048)), week },
      { url: "https://47.76.247.168", name: "香港", at: now - 3600, now: null, open: null, load1: null, today: { bytes: 0, frames: 0 }, day: day(() => null), week },
      { url: "https://39.105.157.122", name: "北京", at: now - 10, now: { sent: 0, recv: 0, dropped: 0.3, rx: 50_000, tx: 64_000 }, open: 2, load1: 0.04, today: { bytes: 0, frames: 0 }, day: day(() => 0), week },
      { url: "https://relay.example", name: "深圳", at: null, now: null, open: null, load1: null, today: { bytes: 0, frames: 0 }, day: day(() => null), week },
    ],
  };
  const v = relays(answer, null, now, 480);
  assert.equal(v.range, "day");
  assert.deepEqual(v.ranges.map((r: J) => r.label), ["24 小时", "7 天"]);
  const [cf, hk, bj, sz] = v.relays;
  assert.deepEqual([cf.state, hk.state, bj.state, sz.state], ["online", "offline", "online", "error"]);
  assert.deepEqual([cf.seen, hk.seen, sz.seen], ["刚刚更新", "1 小时前更新", "暂无数据"]);
  // Never heard from: nothing but that.
  assert.deepEqual([sz.numbers, sz.charts, sz.ticks], [[], [], []]);
  assert.deepEqual(cf.numbers, [
    { label: "发送", value: "14 KB/s" },
    { label: "接收", value: "2.0 KB/s" },
    { label: "在线连接", value: "71" },
    { label: "丢包率", value: "2.1%" },
    { label: "今日用量", value: "4.5 GB / 5.0 GB · 90%", tone: "amber" },
  ]);
  assert.deepEqual(hk.numbers.map((n: J) => n.value), ["–", "–", "–", "–"]);
  assert.deepEqual(bj.numbers.slice(3), [{ label: "丢包率", value: "30.0%", tone: "red" }, { label: "网卡", value: "出 63 KB/s · 入 49 KB/s" }, { label: "负载", value: "0.04" }]);
  assert.deepEqual(cf.charts.map((c: J) => [c.id, c.peak, c.series.map((s: J) => s.id)]), [["rate", "峰值 2.0 KB/s", ["sent", "recv"]], ["open", "峰值 71", ["open"]]]);
  assert.equal(cf.charts[0].series[0].values[0], null);
  // Every six hours, local: four marks a day.
  assert.equal(cf.ticks.length, 4);
  assert.ok(cf.ticks.every((tick: J) => ["00:00", "06:00", "12:00", "18:00"].includes(tick.label)));
  const w = relays(answer, "week", now, 480);
  assert.equal(w.range, "week");
  assert.equal(w.relays[0].charts[0].series[0].values.length, 168);
  assert.ok(w.relays[0].ticks.every((tick: J) => /^\d+\/\d+$/.test(tick.label)));
});

test("the_relays_page_has_a_card_of_the_directorys_own_load_its_calls_an_hour_and_the_sockets_still_on_it", () => {
  const now = NOW - (NOW % 3600);
  const hours = (f: (i: number) => number) => Array.from({ length: 168 }, (_, i) => f(i));
  const directory = {
    at: now,
    calls: { start: now - 167 * 3600, step: 3600, families: { workspaces: hours((i) => i), sockets: hours(() => 2), push: hours(() => 0) } },
    held: { devices: 3, stations: 0 }, live: { accounts: 40, stations: 7 }, waiting: 0, bytes: 5 * 1024 ** 2,
  };
  const card = relays({ relays: [], directory }, null, now, 480).relays.at(-1)!;
  assert.deepEqual([card.name, card.state], ["目录对象 primary", "online"]);
  assert.deepEqual(card.numbers, [
    { label: "近一小时调用", value: String(167 + 2) },
    { label: "仍在它上面的连接", value: "设备 3 · 站点 0", tone: "amber" },
    { label: "持有连接的对象", value: "账号 40 · 站点 7" },
    { label: "待重试的通知", value: "0" },
    { label: "存储", value: "5.0 MB" },
  ]);
  // All of its calls first, then a chart for each family that served some, the most first (one that served nothing
  // has none): a line each, so each can be read. The day is the last 24 hours, marked every six.
  assert.deepEqual(card.charts.map((c: J) => [c.id, c.label, c.peak, c.series.length, c.series[0].values.length, c.series[0].values.at(-1)]), [
    ["calls", "每小时调用", "峰值 169", 1, 24, 169],
    ["workspaces", "工作区", "峰值 167", 1, 24, 167],
    ["sockets", "连接", "峰值 2", 1, 24, 2],
  ]);
  assert.equal(card.ticks.length, 4);
  const week = relays({ relays: [], directory }, "week", now, 480).relays.at(-1)!;
  assert.deepEqual(week.charts.map((c: J) => c.series[0].values.length), [168, 168, 168]);
  // The most in what is shown comes first, whatever the order they are counted in.
  const busy = { ...directory, calls: { ...directory.calls, families: { workspaces: hours(() => 1), sockets: hours(() => 2) } } };
  assert.deepEqual(relays({ relays: [], directory: busy }, null, now, 480).relays.at(-1)!.charts.map((c: J) => c.id), ["calls", "sockets", "workspaces"]);
  // A still.fail cloud from before says nothing of it: no card.
  assert.equal(relays({ relays: [] }, null, now, 480).relays.length, 0);
});

test("the_relays_page_keeps_the_clouds_list_each_relay_removable_but_its_own_with_how_it_came_its_ways_in_and_the_tokens_not_used", () => {
  const now = NOW - (NOW % 3600);
  const seen = { at: null, now: null, open: null, load1: null, today: { bytes: 0, frames: 0 }, day: {}, week: {} };
  const answer = {
    relays: [
      { ...seen, url: "https://app.still.fail", name: "Cloudflare" },
      { ...seen, url: "https://47.76.247.168", name: "香港" },
      { ...seen, url: "https://tokyo.example:8445", name: "东京" },
      { ...seen, url: "https://seoul.example", name: "首尔" },
    ],
    registry: {
      own: "https://app.still.fail",
      relays: [
        { url: "https://47.76.247.168", name: "香港", target: null, added_at: now - 99, added_by: "config", enrolled: false },
        { url: "https://39.105.157.122/", name: "北京", target: "https://47.76.247.168", added_at: now - 99, added_by: "config", enrolled: false },
        { url: "https://tokyo.example:8445", name: "东京", target: null, added_at: now - 9, added_by: "token:ops@x.io", enrolled: true },
        { url: "https://seoul.example", name: "", target: null, added_at: now - 9, added_by: "ops@x.io", enrolled: false },
      ],
      tokens: [{ name: "大阪", url: null, target: null, expires_at: now + 3 * 3600 }, { name: "首尔2", url: "https://seoul2.example", target: null, expires_at: now + 600 }],
    },
  };
  const v = relays(answer, null, now, 480);
  assert.equal(v.manage, true);
  assert.deepEqual(v.relays.map((r: J) => [r.name, r.removable, r.how?.join(" · ")]), [
    ["Cloudflare", false, "云自带的中继，不能删除"],
    ["香港", true, "47.76.247.168 · 从部署配置导入 · 负载按来源 IP 认定"],
    ["东京", true, "tokyo.example:8445 · 用令牌接入"],
    ["首尔", true, "seoul.example · ops@x.io 添加 · 负载按来源 IP 认定"],
  ]);
  assert.deepEqual(v.relays[1].entries, [{ url: "https://39.105.157.122/", name: "北京", host: "39.105.157.122", target: "https://47.76.247.168" }]);
  assert.deepEqual(v.tokens.map((k: J) => [k.name, k.line]), [["大阪", "地址由 relay 接入时自报 · 3 小时后过期"], ["首尔2", "seoul2.example · 10 分钟后过期"]]);
  // A still.fail cloud from before says nothing of its list: nothing to keep from here.
  const before = relays({ relays: answer.relays }, null, now, 480);
  assert.deepEqual([before.manage, before.tokens, before.relays.map((r: J) => r.removable)], [false, [], [false, false, false, false]]);
});

test("a_bug_making_a_view_is_thrown_for_the_store_to_report_and_a_core_error_is_the_views", () => {
  const view = (list: string, id?: string) => ({ topic: "adminItem", account: "a", list, ...(id ? { id } : {}) });
  // The page's own error (no such user) is the view's value.
  const missing = admin(view("users", "nobody"), (_, l) => ({ ok: l === "users" ? users() : workspaces() }), NOW * 1000, 0);
  assert.ok(missing && "err" in missing && missing.err instanceof CoreError && missing.err.code === "http_404");
  // A bug is not passed off as a CoreError (the web host sends one by its toJSON: a TypeError has none, and took the
  // whole core down as "t.error.toJSON is not a function"): it is thrown, for the store to fail this topic with.
  assert.throws(() => admin(view("feedback", "F1"), () => ({ ok: { get feedback(): J { throw new TypeError("a bug"); } } }), NOW * 1000, 0), TypeError);
});

// ── the console's operations (D3) ──

const replied = (): J => {
  const r = reports();
  r.feedback[0].replies = [
    { id: "r1", from: "team", by: "ops@x.io", text: "能再说说步骤吗？", created_at: NOW - 50, delivery: "delivered", delivered_at: NOW - 40 },
    { id: "r2", from: "reporter", by: "session:chat:c-1", text: "刷新后复现", created_at: NOW - 30, delivery: null, delivered_at: null },
  ];
  r.feedback[0].updated_at = NOW - 30;
  r.feedback[1].replies = [{ id: "r3", from: "team", by: "feedback-monitor", text: "已修复", created_at: NOW - 20, delivery: "pending", delivered_at: null }];
  return r;
};

test("a_report_the_reporter_answered_last_awaits_the_team_and_the_overview_says_so", () => {
  const all = list("feedback", replied(), "", null, null, null, NOW);
  // Those whose last word is the reporter's: one to answer.
  assert.equal(count(all, "replied"), 1);
  assert.deepEqual(ids(list("feedback", replied(), "", "replied", null, null, NOW)), ["F2"]);
  assert.deepEqual(all.rows[0].marks.map((m: J) => [m.label, m.tone]), [["新反馈", "amber"], ["待跟进", "amber"], ["测试版", "accent"]]);
  assert.deepEqual(all.rows[1].marks.map((m: J) => m.label), ["已修复"]);
  assert.ok(all.rows[1].line.endsWith(" · 1 条回复"), all.rows[1].line);
  // The default order is still when each came; by when each last changed on asking.
  assert.deepEqual(all.sorts.map((s: J) => s.id), ["created", "updated"]);
  assert.deepEqual(ids(list("feedback", replied(), "", null, "updated", null, NOW)), ["F1", "F2"]);
  // What was said in a reply is found too.
  assert.deepEqual(ids(list("feedback", replied(), "刷新后", null, null, null, NOW)), ["F2"]);
  const v = overview(users(), workspaces(), { codes: [] }, replied(), NOW, 480);
  assert.deepEqual(v.todo.slice(0, 2).map((x: J) => [x.text, x.filter]), [["1 个新反馈", "new"], ["1 个反馈待跟进", "replied"]]);
});

test("reports_are_narrowed_by_area_after_their_tab_and_each_area_counts_what_the_words_found", () => {
  const plain = list("feedback", reports(), "", "fixed", null, null, NOW);
  assert.equal(plain.filter, "fixed");
  assert.equal(plain.area, "");
  const v = list("feedback", reports(), "", "all@web", null, null, NOW);
  assert.deepEqual([ids(v), v.filter, v.area], [["F2"], "all", "web"]);
  assert.equal(v.areas[0].count, 2);
  assert.deepEqual(v.areas.filter((a: J) => a.count > 0).map((a: J) => [a.id, a.label, a.count]), [["", "全部范围", 2], ["android", "Android", 1], ["web", "Web", 1]]);
  // The tab's counts are of the area's.
  assert.deepEqual([count(v, "new"), count(v, "fixed")], [1, 0]);
  assert.deepEqual(ids(list("feedback", reports(), "", "fixed@web", null, null, NOW)), []);
  assert.deepEqual(ids(list("feedback", reports(), "", "@android", null, null, NOW)), ["F1"]);
});

test("a_reports_page_has_its_replies_whether_the_team_can_reply_and_its_own_read_whole", () => {
  const page = feedback("F2", replied());
  assert.deepEqual(page.replies.map((r: J) => [r.from, r.authorLabel, r.deliveryLabel]), [["team", "ops@x.io", "已送达"], ["reporter", "反馈方", null]]);
  assert.equal(page.canReply, true);
  assert.ok(page.text.includes("## 回复\n\nops@x.io: 能再说说步骤吗？\n反馈方: 刷新后复现\n"), page.text);
  // An account's report has no chat to reply in.
  const mine = feedback("F1", replied());
  assert.deepEqual([mine.canReply, mine.replies[0].authorLabel, mine.replies[0].deliveryLabel], [false, "反馈机器人", "待送达"]);
  assert.ok(mine.replyHint.includes("账号"));
  // The list carries no logs: its row shown while the report's own is read, said to be coming; then its own, whole.
  const slim = replied();
  slim.feedback[0].logs = null;
  slim.feedback[0].has_logs = true;
  const view = { topic: "adminItem", account: "a", list: "feedback", id: "FB-2" };
  assert.deepEqual(sources(view), [{ topic: "admin", account: "a", list: "feedback" }, { topic: "admin", account: "a", list: "feedback/FB-2" }]);
  const lists: Record<string, J> = { feedback: { ok: slim } };
  const read = (_: string, l: string) => lists[l];
  let shown: J = admin(view, read, NOW * 1000, 0);
  assert.deepEqual([shown.ok.id, shown.ok.logs, shown.ok.logsLoading], ["F2", null, true]);
  lists["feedback/FB-2"] = { ok: { item: replied().feedback[0] } };
  shown = admin(view, read, NOW * 1000, 0);
  assert.deepEqual([shown.ok.id, shown.ok.logs, shown.ok.logsLoading], ["F2", "line 1\nline 2", false]);
  // Any report by its number, though the list holds it no more.
  const old = { ...replied().feedback[1], id: "F0", number: 0 };
  lists["feedback/FB-0"] = { ok: { item: old } };
  assert.equal((admin({ ...view, id: "FB-0" }, read, NOW * 1000, 0) as J).ok.number, "FB-0");
});

test("a_machine_in_several_workspaces_is_counted_once_and_those_that_only_run_tasks_count_too", () => {
  const v = workspaces();
  // s1 is in both; a rig of Ann's in the second.
  v.workspaces[1].stations = [{ id: "s1", name: "studio", version: "0.1.1212", last_seen: NOW - 60 }];
  v.workspaces[1].rigs = [{ id: "r1", name: "ci-runner", owner: "a", owner_email: "ann@x.io", owner_name: "Ann", version: "0.1.1213", last_seen: NOW - 120, enrolled_at: 1 }];
  const o = overview(users(), v, { codes: [] }, null, NOW, 480);
  const stations = o.stats.find((s: J) => s.label === "Station");
  // s1, s2 and r1: three machines, two of them seen today.
  assert.deepEqual([stations.value, stations.note], [3, "2 台今天已连接"]);
  // A rig is a machine: the workspace is not bare, and its version is the newest.
  assert.equal(count(list("workspaces", v, "", null, null, null, NOW), "bare"), 0);
  const page = workspace("w2", v, users(), NOW);
  assert.deepEqual(page.rigs.map((r: J) => [r.name, r.ownerTitle, r.version, r.outdated, r.state]), [["ci-runner", "Ann", "0.1.1213", false, "online"]]);
  assert.equal(page.stationCount, "2");
  assert.equal(workspace("w1", v, users(), NOW).stations[0].outdated, true);
  assert.deepEqual(ids(list("workspaces", v, "ci-runner", null, null, null, NOW)), ["w2"]);
});

test("a_workspaces_plan_is_said_in_words_and_its_own_limits_can_be_given_back", () => {
  const v = workspaces();
  v.workspaces[0].plan = "enterprise";
  v.workspaces[1].plan = "standard";
  assert.deepEqual([workspace("w1", v, users(), NOW).plan, workspace("w1", v, users(), NOW).customLimits], ["企业版", true]);
  assert.deepEqual([workspace("w2", v, users(), NOW).plan, workspace("w2", v, users(), NOW).customLimits], ["标准版", false]);
  // A cloud from before plans says none.
  assert.equal(workspace("w1", workspaces(), users(), NOW).plan, null);
});

test("the_operators_changes_are_listed_by_kind_in_words_and_found_by_who_and_what", () => {
  const audit = {
    audit: [
      { id: "a3", created_at: NOW - 10, actor: "ops@x.io", action: "relay.token", target: "东京 2", detail: "https://tokyo2.example" },
      { id: "a2", created_at: NOW - 20, actor: "feedback-monitor", action: "feedback.status", target: "FB-12", detail: "fixed" },
      { id: "a1", created_at: NOW - 30, actor: "ann@x.io", action: "user.beta", target: "bob@y.io", detail: "on" },
    ],
  };
  const all = list("audit", audit, "", null, null, null, NOW);
  assert.deepEqual(all.rows.map((r: J) => [r.title, r.line]), [
    ["签发中继令牌 · 东京 2", "ops@x.io · https://tokyo2.example"],
    ["标记反馈 · FB-12", "feedback-monitor · 已修复"],
    ["开通测试版 · bob@y.io", "ann@x.io"],
  ]);
  assert.deepEqual(all.filters.map((f: J) => [f.id, f.count]), [["all", 3], ["users", 1], ["workspaces", 0], ["codes", 0], ["feedback", 1], ["relays", 1], ["keys", 0]]);
  assert.deepEqual(ids(list("audit", audit, "", "relays", null, null, NOW)), ["a3"]);
  assert.deepEqual(ids(list("audit", audit, "bob", null, null, null, NOW)), ["a1"]);
  assert.deepEqual(ids(list("audit", audit, "测试版", null, null, null, NOW)), ["a1"]);
});

test("what_the_cloud_notes_of_rights_given_by_email_and_of_an_invite_code_is_said_in_words", () => {
  const audit = {
    audit: [
      { id: "b2", created_at: NOW - 10, actor: "ops@x.io", action: "code.create", target: "2Y2R-Z4YW-4VWK", detail: "给星河科技 CEO · days=14 · beta" },
      { id: "b1", created_at: NOW - 20, actor: "ops@x.io", action: "pending.set", target: "new@y.io", detail: "beta=on may_create=off" },
    ],
  };
  assert.deepEqual(list("audit", audit, "", null, null, null, NOW).rows.map((r: J) => r.line), [
    "ops@x.io · 给星河科技 CEO · 14 天内有效 · 测试版",
    "ops@x.io · 开通测试版 · 改回免费版",
  ]);
});

test("the_relays_page_charts_what_was_dropped_says_what_the_probes_found_and_keeps_the_clouds_own_relay", () => {
  const now = NOW - (NOW % 3600);
  const day = { start: now - 287 * 300, step: 300, sent: Array.from({ length: 288 }, () => 10), recv: [], open: [], dropped: Array.from({ length: 288 }, (_, i) => (i < 200 ? null : i === 250 ? 0.12 : 0.01)) };
  const line = (network: string, country: string, rtt: number | undefined, loss: number) => ({ probe_country: country, probe_region: "", probe_city: "", probe_asn: 1, probe_network: network, ...(rtt === undefined ? {} : { rtt_avg: rtt }), loss, status: "finished" });
  const answer = {
    relays: [{
      url: "https://app.still.fail", name: "Cloudflare", at: now - 30, now: { sent: 1, recv: 1, dropped: 0, rx: null, tx: null }, open: 1, load1: null, today: { bytes: 0, frames: 0 }, day, week: day,
      probes: { at: now - 600, lines: [line("China Mobile communications", "CN", 80, 0), line("China Mobile", "CN", 100, 0), line("Chinanet", "CN", 320, 10), line("China Unicom", "CN", undefined, 100), line("HKBN", "HK", 9.6, 0), line("Aliyun", "CN", 40, 0)] },
    }],
    registry: {
      own: "https://app.still.fail",
      // The cloud's own named from here: a row of its own, and still never taken off.
      relays: [{ url: "https://app.still.fail", name: "Cloudflare", target: null, added_at: now - 9, added_by: "ops@x.io", enrolled: false }],
      tokens: [{ id: "0123456789abcdef", name: "北京入口", url: null, target: "https://app.still.fail", expires_at: now + 3600 }],
    },
  };
  const v = relays(answer, null, now, 480);
  const cf: J = v.relays[0];
  assert.deepEqual([cf.removable, cf.editable, cf.how], [false, true, ["云自带的中继，不能删除"]]);
  const dropped: J = cf.charts.find((c: J) => c.id === "dropped");
  assert.deepEqual([dropped.label, dropped.peak, dropped.series[0].values[250]], ["丢包率", "峰值 12.0%", 12]);
  assert.deepEqual(cf.probes.items, [
    { label: "移动", value: "90 ms" },
    { label: "电信", value: "320 ms · 丢包 10.0%", tone: "amber" },
    { label: "联通", value: "不通", tone: "red" },
    { label: "香港", value: "10 ms" },
    { label: "国内其他", value: "40 ms" },
  ]);
  assert.equal(cf.probes.seen, "10 分钟前探测");
  assert.deepEqual(v.tokens.map((k: J) => [k.id, k.line]), [["0123456789abcdef", "入口 → Cloudflare · 地址由 relay 接入时自报 · 1 小时后过期"]]);
  // Nothing sampled of what was dropped (the tests' and the clouds' from before): no chart, no probes said.
  const quiet: J = relays({ relays: [{ ...answer.relays[0], probes: undefined, day: { ...day, dropped: [] } }] }, null, now, 480).relays[0];
  assert.deepEqual([quiet.charts.map((c: J) => c.id), quiet.probes], [["rate", "open"], undefined]);
});

test("a_codes_row_carries_each_products_sign_up_link", () => {
  const codes = { codes: [{ code: "AAAA-BBBB-CCCC", note: "", created_at: NOW - 10, expires_at: NOW + DAY, revoked_at: null, used_at: null, used_by: null, workspace: null, url: "https://app.monoid.build/?invite=AAAA-BBBB-CCCC",
    links: [{ product: "monoid", url: "https://app.monoid.build/?invite=AAAA-BBBB-CCCC" }, { product: "still.fail", url: "https://app.still.fail/?invite=AAAA-BBBB-CCCC" }] }] };
  const row = list("invite-codes", codes, "", null, null, null, NOW).rows[0];
  assert.deepEqual(row.links.map((l: J) => l.product), ["monoid", "still.fail"]);
  delete (codes.codes[0] as J).links;
  assert.equal("links" in list("invite-codes", codes, "", null, null, null, NOW).rows[0], false);
});

test("admin_keys_list_filters_sorts_searches_and_marks_states", () => {
  const keys = {
    keys: [
      { id: "ak_1", name: "Ops CLI", prefix: "sfa_11111111", created_by: "u1", created_by_email: "alice@x.io", created_at: NOW - 10 * DAY, expires_at: NOW + 20 * DAY, last_used_at: NOW - 60, revoked_at: null },
      { id: "ak_2", name: "CI Bot", prefix: "sfa_22222222", created_by: "u1", created_by_email: "alice@x.io", created_at: NOW - 2 * DAY, expires_at: null, last_used_at: null, revoked_at: null },
      { id: "ak_3", name: "Expired Key", prefix: "sfa_33333333", created_by: "u2", created_by_email: "bob@x.io", created_at: NOW - 30 * DAY, expires_at: NOW - DAY, last_used_at: NOW - 5 * DAY, revoked_at: null },
      { id: "ak_4", name: "Revoked Key", prefix: "sfa_44444444", created_by: "u1", created_by_email: "alice@x.io", created_at: NOW - 20 * DAY, expires_at: NOW + 10 * DAY, last_used_at: NOW - 15 * DAY, revoked_at: NOW - 3 * DAY },
    ],
  };
  const all = list("keys", keys, "", null, null, null, NOW);
  assert.equal(all.total, 4);
  assert.deepEqual(ids(all), ["ak_2", "ak_1", "ak_4", "ak_3"]);
  assert.deepEqual([count(all, "active"), count(all, "expired"), count(all, "revoked")], [2, 1, 1]);
  assert.deepEqual(all.rows.map((r: J) => [r.id, r.prefix, r.state, r.marks[0].tone]), [
    ["ak_2", "sfa_22222222", "active", "green"],
    ["ak_1", "sfa_11111111", "active", "green"],
    ["ak_4", "sfa_44444444", "revoked", "red"],
    ["ak_3", "sfa_33333333", "expired", "amber"],
  ]);
  // Sort by last_used_at
  const byUsed = list("keys", keys, "", null, "used", null, NOW);
  assert.deepEqual(ids(byUsed), ["ak_1", "ak_3", "ak_4", "ak_2"]);
  // Search by prefix & email
  assert.deepEqual(ids(list("keys", keys, "sfa_3333", null, null, null, NOW)), ["ak_3"]);
  assert.deepEqual(ids(list("keys", keys, "bob@x.io", null, null, null, NOW)), ["ak_3"]);
  // Filter by state
  assert.deepEqual(ids(list("keys", keys, "", "active", null, null, NOW)), ["ak_2", "ak_1"]);
  assert.deepEqual(ids(list("keys", keys, "", "revoked", null, null, NOW)), ["ak_4"]);
});

test("audit_formats_key_create_and_revoke_entries", () => {
  const audit = {
    audit: [
      { id: "k3", created_at: NOW - 5, actor: "alice@x.io", action: "key.revoke", target: "Ops CLI", detail: "sfa_11111111" },
      { id: "k2", created_at: NOW - 10, actor: "alice@x.io", action: "key.create", target: "CI Bot", detail: "sfa_22222222 · never" },
      { id: "k1", created_at: NOW - 20, actor: "alice@x.io", action: "key.create", target: "Ops CLI", detail: "sfa_11111111 · days=90" },
    ],
  };
  const v = list("audit", audit, "", "keys", null, null, NOW);
  assert.equal(count(v, "keys"), 3);
  assert.deepEqual(v.rows.map((r: J) => [r.title, r.line]), [
    ["吊销密钥 · Ops CLI", "alice@x.io · sfa_11111111"],
    ["生成密钥 · CI Bot", "alice@x.io · sfa_22222222 · 永不过期"],
    ["生成密钥 · Ops CLI", "alice@x.io · sfa_11111111 · 90 天内有效"],
  ]);
});
