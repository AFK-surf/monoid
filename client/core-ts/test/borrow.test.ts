// The workspace's models in a station's model control ( 借用): its own, those borrowed from
// another station, those another station could lend it, and borrowing one (a manager's, confirmed first).
import assert from "node:assert/strict";
import { test } from "node:test";
import { Choose } from "../src/choose.ts";
import { holdLanguage } from "../src/i18n.ts";
import type { Topic } from "../src/protocol.ts";
import { borrowable, models, sourced } from "../src/views/models.ts";

holdLanguage();
// deno-lint-ignore no-explicit-any
type J = any;

const profile = (id: string, ms: string[], more: J = {}): J => ({ id, name: `${id}@x.com`, runtime: "claude", runtimes: ["claude"], access: { kind: "subscription" }, models: ms, ...more });
const station = (id: string, name: string, profiles: J[], more: J = {}): J => ({ station: `ws/${id}`, id, name, online: true, joined: false, overview: { sharing: true, profiles }, ...more });

const HERE = "a".repeat(64);
const STUDIO = "b".repeat(64);
const MINI = "c".repeat(64);

function workspace(): J[] {
  return [
    station(HERE, "lab-node", [
      profile("mine", ["claude-opus-5-5"]),
      // A copy Office shares with it.
      profile("go", ["kimi-k3"], { runtimes: ["claude", "codex", "dsh"], access: { kind: "opencode-go", key: "st_1…" }, share: { id: "sh-go", role: "user", host: STUDIO } }),
    ]),
    station(STUDIO, "Office", [
      profile("go", ["kimi-k3"], { runtimes: ["claude", "codex", "dsh"], access: { kind: "opencode-go", key: "st_1…" }, share: { id: "sh-go", role: "host", host: STUDIO, allow: [HERE] } }),
      profile("cx", ["gpt-6-astra"], { runtime: "codex", runtimes: ["codex"], check: { state: "ok", plan: "plus" } }),
      profile("ds", ["deepseek-v4-pro", "claude-opus-5-5"], { runtimes: ["dsh"], access: { kind: "api-provider", key: "sk…" }, share: { id: "sh-ds", role: "host", host: STUDIO, allow: [MINI] } }),
    ], { emoji: "🖥️" }),
    // Down: what it has is not known.
    station(MINI, "TestStation", [profile("m", ["glm-5.2"])], { online: false }),
  ];
}

test("a_station_offers_its_own_models_says_which_are_borrowed_and_lists_what_others_could_lend", () => {
  const ws = workspace();
  const here = ws[0].overview;
  const own = sourced(models(here, 0), here, ws);
  assert.deepEqual(own.map((o: J) => [o.model, o.availability, o.fromText ?? null, o.fromStation ?? null]), [["claude-opus-5-5", "here", null, null], ["kimi-k3", "borrowed", "由 Office 分享", { name: "Office", emoji: "🖥️" }]]);
  const lend = borrowable(ws, `ws/${HERE}`, own, null, 0);
  // Opus is here already; Kimi is borrowed; TestStation is down.
  assert.deepEqual(lend.map((o: J) => [o.model, o.availability, o.fromText, o.runtimes]), [["gpt-6-astra", "borrowable", "在 Office 上", ["codex"]], ["deepseek-v4-pro", "borrowable", "在 Office 上", ["dsh"]]]);
  const ds = lend.find((o: J) => o.model === "deepseek-v4-pro");
  assert.deepEqual(ds.fromStation, { name: "Office", emoji: "🖥️" });
  assert.deepEqual(ds.borrow, { station: `ws/${STUDIO}`, stationName: "Office", profile: "ds", profileName: "ds@x.com", subscription: false, pending: false, allow: [MINI] });
  assert.deepEqual(ds.accounts, { dsh: [] }, "not run here till borrowed");
  assert.equal(lend.find((o: J) => o.model === "gpt-6-astra").borrow.subscription, true);
  // A control whose runtime cannot change: only what runs on it.
  assert.deepEqual(borrowable(ws, `ws/${HERE}`, own, "codex", 0).map((o: J) => o.model), ["gpt-6-astra"]);
  // Shared with every station already: on its way, nothing to ask.
  ws[1].overview.profiles[1].share = { id: "sh-cx", role: "host", host: STUDIO, allow: null };
  assert.equal(borrowable(ws, `ws/${HERE}`, own, "codex", 0)[0].borrow.pending, true);
  // A station this workspace joined neither lends nor borrows; one that cannot share lends nothing.
  assert.deepEqual(borrowable(ws.map((s) => (s.id === HERE ? { ...s, joined: true } : s)), `ws/${HERE}`, own, null, 0), []);
  assert.deepEqual(borrowable(ws.map((s) => (s.id === STUDIO ? { ...s, overview: { ...s.overview, sharing: false } } : s)), `ws/${HERE}`, own, null, 0), []);
});

/// What the core's store says of the stations of `ws` that a model control reads (`values`): each one's overview, its
/// profiles as its page has them and its link, the workspace's list of them and their rows (never their pages).
function stand(ws: J[], values: Map<string, unknown>): void {
  for (const s of ws) {
    values.set(`overview ${s.station}`, s.overview);
    values.set(`stationPart ${s.station}`, s.overview.profiles);
    values.set(`link ${s.station}`, { state: s.online ? "online" : "offline" });
  }
  values.set("stations", ws);
  values.set("workspace", { stations: ws.map((s) => ({ id: s.id, name: s.name, ...(s.emoji ? { emoji: s.emoji } : {}), ...(s.joined ? { joined: true } : {}) })) });
}

/// A model control on the first station of `ws`, its core's store and records stood in for (`values`, `records`).
function control(ws: J[], role: string, values = new Map<string, unknown>(), records = new Map<string, unknown>()) {
  stand(ws, values);
  const keyOf = (t: Topic) => (t.topic === "overview" || t.topic === "link" || (t.topic === "stationPart" && t.part === "profiles") ? `${t.topic} ${t.station}` : String(t.topic));
  const store: J = { get: (t: Topic) => values.get(keyOf(t)), value: (t: Topic) => (values.has(keyOf(t)) ? { ok: values.get(keyOf(t)) } : undefined), select: (t: Topic, pick: (v: J) => unknown) => pick(store.value(t)), watch: () => ({ drop() {} }), invalidate() {} };
  const data: J = { record: (_: string, k: string) => records.get(k), put: (_: string, k: string, v: unknown) => records.set(k, v), shared: (t: Topic) => (t.topic === "workspace" ? { role } : undefined), mes: () => [] };
  return new Choose({ store, data, now: () => 0, agent: () => null });
}

test("a_model_panel_defaults_to_its_station_including_shared_models_and_filters_stars_and_makers_too", () => {
  const choose = control(workspace(), "admin");
  const at = `ws/${HERE}`;
  choose.like(at, "gpt-6-astra", true);
  choose.like(at, "kimi-k3", true);
  const pick = (): J => (choose.compute({ topic: "pick", station: at, of: "new" }) as J).ok;
  const here = pick();
  assert.deepEqual(here.options.map((o: J) => [o.model, o.availability]), [
    ["claude-opus-5-5", "here"], ["kimi-k3", "borrowed"],
  ]);
  assert.equal(here.otherStations, false);
  assert.ok(here.liked.includes("kimi-k3"));
  assert.ok(!here.liked.includes("gpt-6-astra"));
  assert.ok(!here.makers.some((m: J) => m.id === "openai" || m.id === "deepseek"));
  choose.set(at, "new", { otherStations: true });
  const all = pick();
  assert.equal(all.otherStations, true);
  assert.ok(all.options.some((o: J) => o.model === "gpt-6-astra" && o.availability === "borrowable"));
  assert.ok(all.liked.includes("gpt-6-astra"));
  assert.ok(all.makers.some((m: J) => m.id === "openai"));
  assert.deepEqual(all.value, here.value, "showing other stations does not change the selected model");
  choose.save(at, "new", { effort: "low" });
  assert.equal(pick().otherStations, true, "saving an effort keeps the panel's filter");
  choose.set(at, "new", { otherStations: false });
  assert.deepEqual(pick().options.map((o: J) => o.model), here.options.map((o: J) => o.model));
  choose.set(at, "new", { otherStations: true });
  choose.set(at, "new", { open: true });
  assert.equal(pick().otherStations, false, "each opening starts with this station");
  choose.set(at, "new", { otherStations: true });
  choose.stop({ topic: "pick", station: at, of: "new" });
  assert.equal(pick().otherStations, false, "a closed subscription releases the filter");
});

test("a_model_panels_station_filter_stays_with_its_station_and_can_expand_an_empty_local_list", () => {
  const ws = workspace();
  const choose = control(ws, "admin");
  const at = `ws/${HERE}`;
  const pick = (station: string): J => (choose.compute({ topic: "pick", station, of: "new" }) as J).ok;
  choose.set(at, "new", { otherStations: true });
  const office = pick(`ws/${STUDIO}`);
  assert.ok(office.options.some((o: J) => o.model === "gpt-6-astra"));
  assert.ok(office.options.every((o: J) => o.availability !== "borrowable"));
  assert.equal(office.otherStations, undefined, "no expansion control without additional models");

  ws[0].overview.profiles = [];
  const empty = control(ws, "admin");
  const emptyPick = (): J => (empty.compute({ topic: "pick", station: at, of: "new" }) as J).ok;
  assert.deepEqual(emptyPick().options, []);
  assert.equal(emptyPick().otherStations, false, "the empty list still offers the borrowing entry");
  empty.set(at, "new", { otherStations: true });
  assert.ok(emptyPick().options.length > 0);
  assert.ok(emptyPick().options.every((o: J) => o.availability === "borrowable"));
});

test("picking_another_stations_model_asks_to_borrow_it_and_borrowing_shares_it_with_this_station", () => {
  const of = "connect-new:f";
  const at = `ws/${HERE}`;
  const choose = control(workspace(), "admin");
  choose.set(at, of, { otherStations: true });
  choose.set(at, of, { model: "deepseek-v4-pro" });
  const v: J = (choose.compute({ topic: "pick", station: at, of }) as J).ok;
  assert.equal(v.option, "deepseek-v4-pro");
  assert.deepEqual([v.borrow.note, v.borrow.title, v.borrow.action, v.borrow.confirmAction, v.borrow.allowed], ["此 Profile 位于 Office，尚未分享给此 station。", "将账号分享至此 station", "去分享", "确认分享", true]);
  assert.equal(v.borrow.lines.length, 3);
  assert.ok(v.borrow.lines[1].includes("副本"), v.borrow.lines[1]);
  assert.ok(v.borrow.lines[2].includes("环境"), v.borrow.lines[2]);
  // Not saved till borrowed.
  assert.throws(() => choose.save(at, of), /请先将此模型的账号分享/);
  choose.set(at, of, { otherStations: false });
  const hidden: J = (choose.compute({ topic: "pick", station: at, of }) as J).ok;
  assert.ok(!hidden.options.some((o: J) => o.model === "deepseek-v4-pro"));
  assert.deepEqual(hidden.draft, v.draft, "hiding other stations keeps the pending choice");
  assert.deepEqual(hidden.borrow, v.borrow, "the pending borrow keeps its checks");
  // Borrowed: Office is asked to share the profile with this station too, as a manager may.
  const { op } = choose.borrow(at, of) as J;
  assert.equal(op.target.station, `ws/${STUDIO}`);
  assert.equal(op.path, "/profiles/ds/share");
  assert.deepEqual(op.body, { on: true, allow: [MINI, HERE], among: [HERE] });
  // A member may not; a model of this station's own needs nothing.
  const member = control(workspace(), "member");
  member.set(at, of, { model: "deepseek-v4-pro" });
  const m: J = (member.compute({ topic: "pick", station: at, of }) as J).ok;
  assert.deepEqual([m.borrow.allowed, m.borrow.why], [false, "此 Profile 尚未分享给此 station，请联系 owner 或 admin 分享。"]);
  assert.throws(() => member.borrow(at, of), /owner 或 admin/);
  choose.set(at, of, { model: "gpt-6-astra" });
  const subscription: J = (choose.compute({ topic: "pick", station: at, of }) as J).ok;
  assert.match(subscription.borrow.lines[0], /「cx@x.com · Plus」/);
  assert.deepEqual(choose.borrow(at, of).op.body, { on: true, allow: [HERE] }, "a new share is limited to this station");
  choose.set(at, of, { model: "claude-opus-5-5" });
  assert.equal((choose.compute({ topic: "pick", station: at, of }) as J).ok.borrow, null);
  assert.throws(() => choose.borrow(at, of), /无需分享/);
});

test("a_new_chat_explains_local_profiles_not_available_to_its_workspace_even_when_another_station_lends", () => {
  const ws = workspace();
  ws[0].overview.profiles = [profile("mine", ["claude-opus-5-5"], { serves: false })];
  const choose = control(ws, "admin");
  const page: J = (choose.compute({ topic: "newChat", scope: "ws" }) as J).ok;
  assert.equal(page.blocked, null);
  assert.match(page.problem, /Profile 尚未向此 workspace 开放/);
  assert.match(page.problem, /分享/);
  choose.set(`ws/${HERE}`, "new", { otherStations: true });
  const pick: J = (choose.compute({ topic: "pick", station: `ws/${HERE}`, of: "new" }) as J).ok;
  assert.ok(pick.options.every((o: J) => o.availability === "borrowable"));
});

test("borrowing_explains_when_a_share_is_missing_or_already_allowed", () => {
  const at = `ws/${HERE}`;
  const of = "new";
  const view = (ws: J[], role: string): J => {
    const choose = control(ws, role);
    choose.set(at, of, { model: "deepseek-v4-pro" });
    return (choose.compute({ topic: "pick", station: at, of }) as J).ok.borrow;
  };
  const ws = workspace();
  assert.equal(view(ws, "admin").note, "此 Profile 位于 Office，尚未分享给此 station。");
  ws[1].overview.profiles[2].share.allow = [MINI, HERE];
  const waiting = view(ws, "admin");
  assert.equal(waiting.note, "此 Profile 已分享给此 station，但尚未收到；可重新分享。");
  assert.equal(waiting.action, "重新分享");
  assert.match(waiting.lines[0], /已将 Profile.*分享给此 station/);
  assert.equal(waiting.allowed, true);
  assert.equal(view(ws, "member").why, "此 Profile 已分享给此 station，但尚未收到；请联系 owner 或 admin 检查。");
  ws[1].overview.profiles[2].share.allow = null;
  const all = view(ws, "admin");
  assert.equal(all.allowed, false);
  assert.match(all.why, /已分享给所有 station.*尚未收到/);
});

test("a_model_borrowed_from_a_controls_panel_is_that_controls_once_borrowed_not_the_one_it_ran_before", () => {
  // (the user, 2026-11-16: 借用完毕后，应该选中借用的模型，而不是回到老的模型)
  const at = `ws/${HERE}`;
  const ws = workspace();
  const values = new Map<string, unknown>();
  const records = new Map<string, unknown>();
  const choose = control(ws, "admin", values, records);
  const ofPick = (of: string): J => (choose.compute({ topic: "pick", station: at, of }) as J).ok;
  assert.equal(ofPick("new").value.model, "claude-opus-5-5");
  choose.set(at, "new", { open: true });
  choose.set(at, "new", { model: "deepseek-v4-pro" });
  const { picks } = choose.borrow(at, "new");
  // Office took the share; the panel shuts, its draft let go of with it.
  ws[1] = { ...ws[1], overview: { ...ws[1].overview, profiles: ws[1].overview.profiles.map((p: J) => (p.id === "ds" ? { ...p, share: { ...p.share, allow: [MINI, HERE] } } : p)) } };
  stand(ws, values);
  choose.lent(at, "new", picks);
  choose.stop({ topic: "pick", station: at, of: "new" });
  // On its way: the control says the model borrowed, its panel opened again picks it, and a chat is not made on another.
  assert.equal(ofPick("new").option, "deepseek-v4-pro");
  assert.notEqual(ofPick("new").borrow, null, "its copy not here yet");
  assert.deepEqual(choose.lentNow(at), [], "not here yet: nothing saved");
  assert.throws(() => choose.create(at), /还在同步/);
  // Its copy come: saved as it was picked, and the station's choice is it from now.
  const copy = { ...ws[1].overview.profiles[2], share: { id: "sh-ds", role: "user", host: STUDIO } };
  ws[0] = { ...ws[0], overview: { ...ws[0].overview, profiles: [...ws[0].overview.profiles, copy] } };
  stand(ws, values);
  assert.deepEqual(choose.lentNow(at), [], "a new chat's pick is the device's own");
  assert.equal(choose.lentOn(at), false);
  assert.equal(ofPick("new").value.model, "deepseek-v4-pro");
  assert.equal(choose.create(at).model, "deepseek-v4-pro");
  // Another model picked while on its way drops what was borrowed for it.
  choose.lent(at, "connect-new:f", { model: "gpt-6-astra", runtime: "codex" });
  choose.set(at, "connect-new:f", { model: "claude-opus-5-5" });
  assert.equal(choose.lentOn(at), false);
});
