// The Rust core's views/usage.rs tests, ported.
import assert from "node:assert/strict";
import { test } from "node:test";
import { conform } from "../src/conform.ts";
import { CoreError } from "../src/error.ts";
import { holdLanguage, tr } from "../src/i18n.ts";
import { count, countIn, localDay, money, priceTables, scale, usageView, type Source } from "../src/views/usage.ts";

holdLanguage();
// deno-lint-ignore no-explicit-any
type J = any;

const row = (day: string, person: string, thread: number, profile: string, model: string, calls: number, cost: number | null): J => ({
  day, session: "chat:c-1", thread, person, profile, runtime: "claude", model, calls, input: 10 * calls, cacheRead: 90 * calls, cacheWrite: 0, output: calls, cost,
});
const station = (rows: J[]): J => ({
  since: 0, reading: false, rows,
  threads: { "7": { title: "修登录", surface: "ember", home: "chat:c-1", archived: false }, "8": { title: "#ops", surface: "slack:T1", home: "chat:c-2", archived: true } },
  people: { "a@x": { id: "a@x", name: "a@x", email: "a@x", via: "cloud" }, "slack:ds:U1": { id: "slack:ds:U1", name: "阿一", email: "a@x", via: "slack" }, "b@x": { id: "b@x", name: "b@x", email: "b@x", via: "cloud" } },
  profiles: { cc: { name: "公司账号", runtime: "claude" } },
});
const NOW = 1_790_913_600_000;
const ok = (v: J) => ({ ok: v });

test("recent totals wait for every station even when one has already answered", () => {
  const ready: Source = { address: "ws/a", name: "alpha", online: true,
    value: ok(station([row("2026-10-02", "a@x", 7, "cc", "claude-opus-5-5", 1, 3)])) };
  const pending: Source = { address: "ws/b", name: "beta", online: true,
    value: ok({ ...station([]), detailsPreparing: true }) };
  for (const sources of [[ready, pending], [pending, ready]]) {
    const view = usageView(sources, 7, NOW, 480, {}, []);
    assert.equal(view.detailsPreparing, true);
    assert.equal(view.wait.reading, true);
    assert.equal(view.empty, true, "incomplete totals cannot be shared as a whole");
  }
  const complete = usageView([ready, { ...pending, value: ok(station([])) }], 7, NOW, 480, {}, []);
  assert.notEqual(complete.detailsPreparing, true);
  assert.equal(complete.wait.reading, false);
  assert.equal(complete.empty, false);
  assert.equal(complete.tiles[0].value, "$3.00");
});

test("days_split_by_who_and_lists_ranked_by_cost", () => {
  assert.equal(localDay(NOW, 480), "2026-10-02");
  const rows = [
    row("2026-10-02", "a@x", 7, "cc", "claude-opus-5-5", 10, 3.0),
    row("2026-10-02", "slack:ds:U1", 8, "cc", "claude-opus-5-5", 5, 1.0),
    row("2026-10-01", "b@x", 7, "gone", "gpt-6", 4, null),
    row("2026-09-20", "b@x", 7, "cc", "claude-opus-5-5", 100, 100.0),
  ];
  const sources: Source[] = [{ address: "ws/st", name: "studio", online: true, value: ok(station(rows)) }];
  const members = [{ email: "a@x", name: "阿一", picture: "https://p/a" }];
  const v = usageView(sources, 7, NOW, 480, { id: "b@x", email: "b@x" }, members);
  assert.equal(v.tiles[0].value, "≥$4.00");
  assert.equal(v.tiles[1].value, "19 次");
  const daily = v.daily;
  assert.deepEqual([daily.length, daily[6].label, daily[6].today], [7, "10/2", true]);
  assert.deepEqual(v.series, [{ key: "a@x", name: "阿一", costText: "$4.00" }, { key: "b@x", name: "你", costText: "$0" }]);
  assert.deepEqual(daily[6].parts, [4.0, 0.0]);
  // what the chart says of a day, the core's: its name where picked, its date under its bar, each part's share
  assert.deepEqual([daily[6].name, daily[5].name, daily[5].tick, v.many], ["今天", "10/1", "10/1", false]);
  assert.deepEqual(daily[6].shares, [1, 0]);
  // (10/1's spending has no price: nothing to share)
  assert.deepEqual(daily[5].shares, [0, 0]);
  const list = (k: number) => v.lists[k].items;
  const people = list(0);
  assert.deepEqual([people[0].title, people[0].shareText, people[0].person.shown.picture], ["阿一", "100%", "https://p/a"]);
  const chats = list(1);
  assert.deepEqual([chats[0].title, chats[0].chat], ["修登录", { station: "ws/st", session: "chat:c-1" }]);
  // each chat said with who it was for and its model, the most of each, then where it is
  assert.deepEqual([chats[0].sub, chats[1].sub, chats[1].chat], ["阿一 · Opus 5.5", "阿一 · Opus 5.5 · Slack · 已归档", { station: "ws/st", session: "chat:c-2" }]);
  // one person, one model: neither said of a chat, nor any list of one told apart
  const one = usageView([{ address: "ws/st", name: "studio", online: true, value: ok(station([row("2026-10-02", "a@x", 7, "cc", "claude-opus-5-5", 10, 3.0)])) }], 7, NOW, 480, { id: "a@x", email: "a@x" }, []);
  assert.deepEqual([one.lists[1].items[0].sub, one.lists.map((l: J) => l.parts.length)], [null, [0, 0, 0, 0]]);
  const profiles = list(2);
  assert.deepEqual([profiles[0].title, profiles[1].title], ["公司账号", "gone（已删除）"]);
  const models = list(3);
  assert.deepEqual([models[0].title, models[1].sub], ["Opus 5.5", "无价目，不计入费用"]);
  assert.deepEqual(v.notes, ["4 次调用的模型无价目，未计入费用"]);
});

test("an_account_says_the_model_it_used_the_most_tokens_of", () => {
  const rows = [
    row("2026-10-02", "a@x", 7, "cc", "claude-opus-5-5", 3, 3.0),
    row("2026-10-02", "a@x", 7, "cc", "claude-sonnet-5", 2, 0.5),
    row("2026-10-01", "a@x", 7, "cc", "claude-sonnet-5", 2, 0.5),
    row("2026-09-20", "a@x", 7, "cc", "claude-haiku-5", 100, 1.0),
  ];
  const sources: Source[] = [{ address: "ws/st", name: "studio", online: true, value: ok(station(rows)) }];
  const v = usageView(sources, 7, NOW, 480, { id: "a@x", email: "a@x" }, []);
  // (Sonnet's 4 calls the most tokens in the 7 days, though Opus cost more; Haiku's before them not counted)
  assert.equal(v.lists[2].items[0].topModel, "最多 Sonnet 5");
  assert.equal(v.lists[3].items[0].topModel, undefined);
});

test("thirty_days_say_a_date_a_week_under_their_bars", () => {
  const v = usageView([{ address: "ws/st", name: "studio", online: true, value: ok(station([row("2026-10-02", "a@x", 7, "cc", "claude-opus-5-5", 1, 1.0)])) }], 30, NOW, 480, { id: "a@x", email: "a@x" }, []);
  assert.equal(v.many, true);
  const ticks = v.daily.map((d: any) => d.tick);
  assert.deepEqual([ticks.length, ticks[29], ticks[28], ticks[22], ticks[21]], [30, "今天", "", "9/25", ""]);
  assert.equal(v.daily[28].shares.every((x: number) => x === 0), true);
});

test("price_tables_keep_station_rates_separate_and_handle_older_stations", () => {
  const source = (name: string, rate: number): Source => ({
    address: name, name, online: true,
    value: ok({ rows: [{ day: "2026-10-02", model: "gpt-6-astra", calls: 1 }], prices: { note: "standard", rows: [{ model: "gpt-6-astra", input: rate, cacheRead: 0.01, output: 50.0 }] } }),
  });
  const tables = priceTables([source("alpha", 10), source("beta", 12), { address: "old", name: "old", online: true, value: ok({}) }], "2026-09-26", "2026-10-02");
  assert.equal(tables[0].rows[0].rates[0].value, "$10");
  assert.equal(tables[1].rows[0].rates[0].value, "$12");
  assert.equal(tables[0].rows[0].rates[1].value, "$0.01");
  assert.deepEqual(tables[2].rows, []);
  assert.ok(tables[2].note.includes("更新 station"));
});

test("price_table_only_lists_counted_models_in_the_selected_period", () => {
  const sources: Source[] = [{
    address: "st", name: "st", online: true,
    value: ok({
      rows: [
        { day: "2026-10-02", model: "openai/gpt-6-astra", calls: 2 },
        { day: "2026-10-01", model: "gpt-6-astra", calls: 3 },
        { day: "2026-09-10", model: "claude-opus-5-5", calls: 1 },
        { day: "2026-10-02", model: "gpt-6-sol", calls: 0 },
        { day: "2026-10-02", model: "new-model", calls: 1 },
      ],
      prices: { rows: [{ model: "gpt-6-astra", input: 10.0, cacheRead: 1.0, output: 50.0 }, { model: "claude-opus-5-5", input: 4.0, cacheWrite: 5.0 }, { model: "gpt-6-sol", input: 2.0 }] },
    }),
  }];
  const short = priceTables(sources, "2026-09-26", "2026-10-02");
  assert.equal(short[0].rows.length, 2);
  assert.equal(short[0].rows[0].model, "gpt-6-astra");
  assert.equal(short[0].rows[0].rates.length, 3);
  assert.equal(short[0].rows[1].model, "new-model（未计价）");
  const long = priceTables(sources, "2026-09-03", "2026-10-02");
  assert.equal(long[0].rows.length, 3);
  assert.equal(long[0].rows[0].rates.length, 4);
});

test("unknown_prices_are_not_shown_as_zero_and_tokens_stay_counted", () => {
  const sources: Source[] = [{ address: "ws/st", name: "studio", online: true, value: ok(station([row("2026-10-02", "a@x", 7, "cc", "unknown-model", 2, null)])) }];
  const v = usageView(sources, 7, NOW, 480, {}, []);
  assert.equal(v.tiles[0].value, "未计价");
  assert.equal(v.tiles[1].value, "2 次");
  assert.equal(v.daily[6].costText, "未计价");
  assert.equal(v.daily[0].costText, "$0");
  for (const list of v.lists) {
    assert.equal(list.items[0].costText, "未计价");
    assert.equal(list.items[0].detail, "2 次调用 · 202 token");
  }
  assert.ok("ok" in conform("UsageView", v));
});

test("a_station_come_lately_takes_no_days_from_the_others", () => {
  // (2026-11-16: a station joined six days before, its detailSince the latest, left the 30 days' first 24 and the week
  // before empty for every station)
  const old = row("2026-09-30", "a@x", 7, "cc", "claude-opus-5-5", 2, 10);
  const recent = row("2026-10-01", "a@x", 7, "cc", "claude-opus-5-5", 1, 2);
  const weekBefore = row("2026-09-22", "a@x", 7, "cc", "claude-opus-5-5", 4, 4);
  const monthAgo = row("2026-09-05", "a@x", 7, "cc", "claude-opus-5-5", 3, 7);
  const today = row("2026-10-02", "a@x", 7, "cc", "claude-opus-5-5", 1, 3);
  const long = NOW - 60 * 86_400_000;
  const sources: Source[] = [
    { address: "ws/a", name: "a", online: true, value: ok({ ...station([today]), from: long, detailSince: NOW - 86_400_000 }) },
    { address: "ws/b", name: "b", online: true, value: ok({ ...station([monthAgo, weekBefore, old, recent]), from: long }) },
    // (a station just set up says nothing of when it began: it holds back no day and is not noted)
    { address: "ws/c", name: "c", online: true, value: ok({ ...station([]), from: long, detailSince: null }) },
  ];
  const v = usageView(sources, 7, NOW, 480, {}, []);
  assert.deepEqual([v.daily[4].costText, v.daily[4].callsText, v.daily[4].cost], ["$10.00", "2 次调用", 10]);
  assert.deepEqual([v.daily[5].costText, v.daily[6].costText], ["$2.00", "$3.00"]);
  assert.deepEqual([v.tiles[0].value, v.tiles[1].value], ["$15.00", "4 次"]);
  // the week before is b's to say: against it
  assert.deepEqual([v.tiles[0].change, v.tiles[0].trend], ["↑275%", "up"]);
  assert.deepEqual(v.notes, ["a 的记录从 10 月 1 日开始"]);
  // 30 days: every day of b's, the first 24 too
  const month = usageView(sources, 30, NOW, 480, {}, []);
  assert.equal(month.daily.find((d: J) => d.day === "2026-09-05").costText, "$7.00");
  assert.equal(month.tiles[0].value, "$26.00");
  // a day before a's began: b's alone, not "—"
  const earlier = usageView(sources, 7, NOW, 480, {}, [], { day: "2026-09-30" });
  assert.deepEqual([earlier.tiles[0].value, earlier.empty], ["$10.00", false]);
  // (a's own rows from before it began are not its to say)
  const own = usageView([{ ...sources[0], value: ok({ ...station([old, today]), from: long, detailSince: NOW - 86_400_000 }) }], 7, NOW, 480, {}, []);
  assert.equal(own.tiles[0].value, "$3.00");
});

test("one_account_on_several_stations_is_one_row_and_its_allowance_counts_it_once", () => {
  const rows = (profile: string, cost: number) => [row("2026-10-02", "a@x", 7, profile, "claude-opus-5-5", 1, cost)];
  const quota = { state: "ok", windows: [{ label: "5h", usedPercent: 40, mark: "5H", left: 60, level: "ok", checkedAt: 0 }], checkedAt: 0 };
  // (as the accounts' page has them: one account a share hosted on a, borrowed by b and c, its profile's id each its own)
  const accounts = [{ key: "sh-team@x", title: "team@x", profile: { quota, planText: "Ultra 5x" }, members: [
    { station: "ws/a", profileId: "sh-1" }, { station: "ws/b", profileId: "sh-1b" }, { station: "ws/c", profileId: "sh-1c" },
  ] }];
  const sources: Source[] = [
    // (b's own word for it: none; c's: a name its copy had)
    { address: "ws/a", name: "alpha", online: true, value: ok({ ...station(rows("sh-1", 3)), profiles: { "sh-1": { name: "团队订阅" } } }) },
    { address: "ws/b", name: "beta", online: true, value: ok({ ...station(rows("sh-1b", 2)), profiles: {} }) },
    { address: "ws/c", name: "gamma", online: true, value: ok({ ...station([...rows("sh-1c", 1), ...rows("gone", 0.5)]), profiles: {} }) },
  ];
  const v = usageView(sources, 7, NOW, 480, {}, [], {}, accounts);
  const profiles = v.lists[2].items;
  assert.deepEqual(profiles.map((p: J) => [p.key, p.title, p.sub, p.costText]), [
    ["sh-team@x", "team@x", "Ultra 5x · alpha、beta、gamma", "$6.00"],
    ["ws/c/gone", "gone（已删除）", "gamma", "$0.50"],
  ]);
  assert.deepEqual(v.accounts.map((a: J) => [a.key, a.costText]), [["sh-team@x", "$6.00"]]);
  // seen alone, by its key: its calls on every station
  const alone = usageView(sources, 7, NOW, 480, {}, [], { only: { list: "profiles", key: "sh-team@x" } }, accounts);
  assert.deepEqual([alone.only.title, alone.tiles[0].value], ["team@x · Ultra 5x", "$6.00"]);
  // split by the accounts: each part's cost beside its name
  const split = usageView(sources, 7, NOW, 480, {}, [], { split: "profiles" }, accounts);
  assert.equal(split.series[0].name, "team@x · Ultra 5x");
  assert.deepEqual(split.series.map((x: J) => [x.key, x.costText]), [["sh-team@x", "$6.00"], ["ws/c/gone", "$0.50"]]);
});

test("one_person_heard_on_several_stations_and_platforms_is_one", () => {
  const sources: Source[] = [
    // (a knows the Slack person's email)
    { address: "ws/a", name: "alpha", online: true, value: ok({ ...station([row("2026-10-02", "slack:ds:U9", 7, "cc", "gpt-6", 1, 1)]),
      people: { "slack:ds:U9": { id: "slack:ds:U9", name: "Foo", email: "foo@cue.surf", via: "slack" } } }) },
    // (b took the connect over from a: it says the person with a's station, and has not heard their email)
    { address: "ws/b", name: "beta", online: true, value: ok({ ...station([row("2026-10-02", "slack:ds@st-a:U9", 7, "cc", "gpt-6", 1, 2)]),
      people: { "slack:ds@st-a:U9": { id: "slack:ds@st-a:U9", name: "U9", email: null, via: "slack" } } }) },
    // (c heard them on the web, as their account)
    { address: "ws/c", name: "gamma", online: true, value: ok({ ...station([row("2026-10-02", "foo@cue.surf", 7, "cc", "gpt-6", 1, 4)]),
      people: { "foo@cue.surf": { id: "foo@cue.surf", name: "foo@cue.surf", email: "foo@cue.surf", via: "cloud" } } }) },
  ];
  const members = [{ email: "foo@cue.surf", name: "福", picture: "https://p/foo" }];
  const v = usageView(sources, 7, NOW, 480, {}, members);
  const people = v.lists[0].items;
  assert.deepEqual(people.map((p: J) => [p.key, p.title, p.costText, p.person.shown.picture]), [["foo@cue.surf", "福", "$7.00", "https://p/foo"]]);
  // nobody knows their email: still one, by the connect they were heard on
  const none = usageView(sources.slice(1).map((s) => s.address === "ws/b" ? s : { ...s, value: ok({ ...station([row("2026-10-02", "slack:ds:U9", 7, "cc", "gpt-6", 1, 1)]), people: {} }) }), 7, NOW, 480, {}, []);
  assert.deepEqual(none.lists[0].items.map((p: J) => [p.key, p.costText]), [["slack:ds:u9", "$3.00"]]);
});

test("the_chats_no_station_names_are_one_row_with_what_they_cost", () => {
  const rows = [
    row("2026-10-02", "a@x", 7, "cc", "gpt-6", 1, 2),
    row("2026-10-02", "a@x", 41, "cc", "gpt-6", 3, 300),
    row("2026-10-01", "a@x", 42, "cc", "gpt-6", 2, 128),
  ];
  const sources: Source[] = [
    { address: "ws/a", name: "alpha", online: true, value: ok(station(rows)) },
    { address: "ws/b", name: "beta", online: true, value: ok(station([row("2026-10-02", "a@x", 43, "cc", "gpt-6", 1, 0)])) },
  ];
  const v = usageView(sources, 7, NOW, 480, {}, [], { split: "chats" });
  const chats = v.lists[1].items;
  const gone = chats.filter((c: J) => c.deleted === true);
  assert.equal(gone.length, 1);
  // (last, though they cost the most together)
  assert.equal(chats[chats.length - 1].key, "deleted/all");
  assert.deepEqual([gone[0].key, gone[0].title, gone[0].sub, gone[0].costText, gone[0].chat, gone[0].calls, gone[0].shareText, gone[0].tokensText],
    ["deleted/all", "已删除的对话", "3 个对话已删除", "$428", null, 6, "100%", "606"]);
  assert.equal(v.series[0].key, "deleted/all");
  assert.equal(v.series[0].costText, "$428");
  const shaped = conform("UsageView", v) as J;
  assert.ok("ok" in shaped);
  const shapedGone = shaped.ok.lists[1].items.find((c: J) => c.key === "deleted/all");
  assert.deepEqual([shapedGone.deleted, shapedGone.costText, shapedGone.title], [true, "$428", "已删除的对话"]);
  assert.equal(tr("en", "core-views.usage.deleted_chat"), "Deleted chats");
});

test("what_goes_out_keeps_each_tiles_words_under_it_and_each_parts_cost", () => {
  const rows = [row("2026-10-02", "a@x", 7, "cc", "gpt-6", 10, 3), row("2026-10-02", "b@x", 8, "cc", "gpt-6", 4, 1)];
  const v = usageView([{ address: "ws/st", name: "studio", online: true, value: ok(station(rows)) }], 7, NOW, 480, {}, []);
  const shaped = conform("UsageView", v) as J;
  assert.ok("ok" in shaped);
  // (the tiles' words under them: dropped by the shape before, the page drew none)
  assert.deepEqual(shaped.ok.tiles.map((x: J) => x.sub), ["按 API 标准单价估算", "日均 2 次", "缓存命中 90%", "平均每次 1"]);
  assert.deepEqual(shaped.ok.series.map((x: J) => [x.key, x.costText]), [["a@x", "$3.00"], ["b@x", "$1.00"]]);
});

test("unknown_people_keep_their_usage_and_the_view_decodes", () => {
  for (const reference of [null, "missing@x"]) {
    const unknown = row("2026-10-02", "", 7, "cc", "gpt-6", 2, 3.0);
    unknown.person = reference;
    const sources: Source[] = [{ address: "ws/st", name: "studio", online: true, value: ok(station([unknown, row("2026-10-02", "a@x", 7, "cc", "gpt-6", 1, 1.0)])) }];
    const v = usageView(sources, 7, NOW, 480, {}, []);
    const decoded = conform("UsageView", v) as J;
    assert.ok("ok" in decoded, JSON.stringify(decoded));
    const people = decoded.ok.lists[0].items;
    assert.equal(decoded.ok.tiles[0].value, "$4.00");
    assert.equal(decoded.ok.tiles[1].value, "3 次");
    assert.equal(people[0].title, "未知用户");
    // (who each is and what each cost are the view's own: what goes out says them in words)
    assert.equal(v.lists[0].items[0].person ?? null, null);
    assert.equal(v.lists[0].items[0].cost, 3.0);
    assert.equal(v.lists[0].items[1].person.via, "cloud");
    assert.deepEqual([people[0].person, people[0].cost], [undefined, undefined]);
  }
});

test("stations_that_cannot_say_are_noted_and_one_not_read_yet_is_loading", () => {
  const sources: Source[] = [
    { address: "ws/a", name: "alpha", online: true, value: undefined },
    { address: "ws/b", name: "beta", online: true, value: { err: new CoreError("http_404", "no", 404) } },
    { address: "ws/c", name: "gamma", online: false, value: undefined },
  ];
  const v = usageView(sources, 30, NOW, 0, {}, []);
  assert.deepEqual([v.wait.reading, v.empty, v.daily.length], [true, true, 30]);
  assert.deepEqual(v.notes, ["beta 的 station 尚未更新到支持记录用量的版本", "gamma 离线，其用量未计入"]);
});

test("numbers_read_as_people_say_them", () => {
  assert.deepEqual([money(1911.16), money(191.4), money(12.346), money(0.004), money(0)], ["$1,911", "$191", "$12.35", "<$0.01", "$0"]);
  assert.deepEqual([count(9850), count(29_443), count(17_146_455), count(4_914_110_860)], ["9,850", "2.9 万", "1715 万", "49.1 亿"]);
  const en = (n: number) => countIn("en", n);
  assert.deepEqual([en(9850), en(29_443), en(17_146_455), en(4_914_110_860)], ["9,850", "29.4K", "17.1M", "4.9B"]);
  assert.deepEqual([tr("en", "core-views.usage.calls", { n: en(1) }), tr("en", "core-views.usage.calls", { n: en(29_443) })], ["1 call", "29.4K calls"]);
});

test("the_bars_scale_is_a_round_top_cut_in_two_or_three_steps_each_said_short", () => {
  const of = (max: number) => { const s = scale(max); return [s.top, s.ticks.map((t) => t.label)]; };
  assert.deepEqual(of(5351), [6000, ["2k", "4k", "6k"]]);
  assert.deepEqual(of(27), [30, ["10", "20", "30"]]);
  assert.deepEqual(of(10), [10, ["5", "10"]]);
  assert.deepEqual(of(1200), [1500, ["500", "1k", "1.5k"]]);
  assert.deepEqual(of(7400), [7500, ["2.5k", "5k", "7.5k"]]);
  assert.deepEqual(of(0.42), [0.6, ["0.2", "0.4", "0.6"]]);
  assert.deepEqual(of(2_400_000), [3_000_000, ["1M", "2M", "3M"]]);
  assert.deepEqual(scale(0), { top: 0, ticks: [] });
  // each step's line at its value: the last the top
  const s = scale(5351);
  assert.deepEqual(s.ticks.map((t) => t.value), [2000, 4000, 6000]);
});

test("each_total_said_against_the_days_before_as_many", () => {
  const rows = [
    row("2026-10-02", "a@x", 7, "cc", "claude-opus-5-5", 12, 6.0),
    row("2026-09-30", "a@x", 7, "cc", "claude-opus-5-5", 10, 5.0),
    row("2026-09-25", "a@x", 7, "cc", "claude-opus-5-5", 10, 4.0),
    // (before the days before: in neither)
    row("2026-09-10", "a@x", 7, "cc", "claude-opus-5-5", 500, 500.0),
  ];
  const read = (from: number, since = 0) => [{ address: "ws/st", name: "studio", online: true, value: ok({ ...station(rows), from, since }) }];
  const v = usageView(read(NOW - 60 * 86_400_000), 7, NOW, 480, { id: "a@x", email: "a@x" }, []);
  assert.deepEqual(v.tiles.map((x: J) => [x.change, x.trend]), [["↑175%", "up"], ["↑120%", "up"], ["↑120%", "up"], ["↑120%", "up"]]);
  assert.deepEqual([v.versus, v.period], ["比前 7 天", "近 7 天"]);
  // read only from within the days before (an older core's 30 days for 30), or recorded only since then: none said
  assert.equal(usageView(read(NOW - 10 * 86_400_000), 7, NOW, 480, { id: "a@x", email: "a@x" }, []).tiles[0].change, null);
  assert.equal(usageView(read(NOW - 60 * 86_400_000, NOW - 10 * 86_400_000), 7, NOW, 480, { id: "a@x", email: "a@x" }, []).tiles[0].change, null);
  // nothing spent before: none
  const fresh = [{ address: "ws/st", name: "studio", online: true, value: ok({ ...station(rows.slice(0, 2)), from: NOW - 60 * 86_400_000 }) }];
  assert.equal(usageView(fresh, 7, NOW, 480, { id: "a@x", email: "a@x" }, []).tiles[0].change, null);
  assert.ok("ok" in conform("UsageView", v));
});

test("the_days_split_by_the_list_picked_and_one_seen_alone", () => {
  const rows = [
    row("2026-10-02", "a@x", 7, "cc", "claude-opus-5-5", 10, 3.0),
    row("2026-10-02", "a@x", 8, "cc", "claude-sonnet-5", 4, 1.0),
    row("2026-10-01", "b@x", 7, "cc", "claude-sonnet-5", 2, 2.0),
  ];
  const sources: Source[] = [{ address: "ws/st", name: "studio", online: true, value: ok(station(rows)) }];
  const me = { id: "a@x", email: "a@x" };
  // several people: split by them; asked, by the models
  assert.equal(usageView(sources, 7, NOW, 480, me, []).split, "people");
  const byModel = usageView(sources, 7, NOW, 480, me, [], { split: "models" });
  assert.deepEqual([byModel.split, byModel.series.map((s: J) => s.name), byModel.daily[6].parts], ["models", ["Opus 5.5", "Sonnet 5"], [3, 1]]);
  // one person alone: only their calls, the days split by their models (one person: the models' by default)
  const alone = usageView(sources, 7, NOW, 480, me, [], { only: { list: "people", key: "b@x" } });
  assert.deepEqual([alone.only, alone.split, alone.tiles[1].value, alone.lists[0].items.length], [{ list: "people", key: "b@x", title: "b@x" }, "models", "2 次", 1]);
  // a model alone, and a list that cannot be (a chat opens instead)
  assert.equal(usageView(sources, 7, NOW, 480, me, [], { only: { list: "models", key: "claude-sonnet-5" } }).tiles[1].value, "6 次");
  assert.equal(usageView(sources, 7, NOW, 480, me, [], { only: { list: "chats", key: "ws/st/7" } }).only, null);
  assert.ok("ok" in conform("UsageView", alone));
});

test("a_day_picked_the_lists_parts_and_each_allowance_beside_what_it_spent", () => {
  const rows = [
    row("2026-10-02", "a@x", 7, "cc", "claude-opus-5-5", 10, 3.0),
    row("2026-10-01", "b@x", 7, "cc", "claude-sonnet-5", 2, 2.0),
    row("2026-10-01", "b@x", 8, "kimi", "kimi-k3", 1, 0.5),
    row("2026-09-30", "c@x", 8, "kimi", "gpt-6", 1, 0.25),
    row("2026-09-29", "d@x", 8, "kimi", "gpt-6", 1, 0.125),
  ];
  const sources: Source[] = [{ address: "ws/st", name: "studio", online: true, value: ok(station(rows)) }];
  const me = { id: "a@x", email: "a@x" };
  // a day picked: the days' bars all of them, the rest of that day alone, against nothing
  const day = usageView(sources, 7, NOW, 480, me, [], { day: "2026-10-01" });
  assert.deepEqual([day.day, day.period, day.tiles[0].value, day.tiles[0].change, day.daily[6].cost], ["2026-10-01", "10/1", "$2.50", null, 3]);
  assert.equal(usageView(sources, 7, NOW, 480, me, [], { day: "2025-01-01" }).day, null);
  // a list's first three and the rest
  const v = usageView(sources, 7, NOW, 480, me, []);
  assert.deepEqual(v.lists[0].parts.map((p: J) => [p.key, p.title, p.costText]), [["a@x", "你", "$3.00"], ["b@x", "b@x", "$2.50"], ["c@x", "未知用户", "$0.25"], ["d@x", "未知用户", "$0.13"]]);
  const five = usageView([{ address: "ws/st", name: "studio", online: true, value: ok(station([...rows, row("2026-09-29", "e@x", 8, "kimi", "gpt-6", 1, 0.125)])) }], 7, NOW, 480, me, []);
  assert.deepEqual(five.lists[0].parts.map((p: J) => [p.key, p.title, p.costText]), [["a@x", "你", "$3.00"], ["b@x", "b@x", "$2.50"], ["c@x", "未知用户", "$0.25"], ["", "其他", "$0.25"]]);
  // a subscription with an allowance, what its copies spent beside it; one without, none
  const quota = { state: "ok", windows: [{ label: "5h", usedPercent: 40, mark: "5H", left: 60, level: "ok", checkedAt: 0 }], checkedAt: 0 };
  const accounts = [
    { key: "a@claude", title: "a@claude", profile: { quota }, members: [{ station: "ws/st", profileId: "cc" }] },
    { key: "kimi", title: "Kimi", profile: { quota: { state: "unsupported", windows: [], checkedAt: 0 } }, members: [{ station: "ws/st", profileId: "kimi" }] },
  ];
  const with_ = usageView(sources, 7, NOW, 480, me, [], {}, accounts);
  assert.deepEqual(with_.accounts.map((a: J) => [a.key, a.costText, a.quota.windows[0].left]), [["a@claude", "$5.00", 60]]);
  assert.ok("ok" in conform("UsageView", with_));
});
