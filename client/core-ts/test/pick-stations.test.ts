// A model control's panel (`pick`) and a new chat's page (`newChat`) read the workspace's stations by what they show:
// each one's name, mark, whether it is up and joined, and its profiles as its page has them, never its page nor its
// row, which its machine's readings (`host`) and how it is reached (`way`) make again every few seconds. On a phone
// (0.1.10130, 2026-11-18) an open panel read every station's page with the models each could run (`stationsWhole`),
// made again with the panel as any of them came: 42 times in a row, 3.16 s. And the models another station could lend
// are made once a profile and a minute, not again as each draft is changed in the panel.
import assert from "node:assert/strict";
import { test } from "node:test";
import { Choose } from "../src/choose.ts";
import { holdLanguage } from "../src/i18n.ts";
import type { Topic } from "../src/protocol.ts";
import { borrowable, models, sourced } from "../src/views/models.ts";
import { work, workSince } from "../src/work.ts";
import { CHAT, UP, fixture, hostReading, more, OPENS, records, STATIONS } from "./real-size.ts";
import { setup } from "./views-rig.ts";

holdLanguage();

// deno-lint-ignore no-explicit-any
type J = any;

const PICK: Topic = { topic: "pick", station: CHAT.station, of: "new" };

/// The workspace of real size (real-size.ts) with a new chat's page and its model control's panel open, each view made
/// counted by its topic.
async function opened() {
  let choose: Choose | undefined;
  const t = setup({ all: true, owners: ({ host, store, data, views }) => [(choose = new Choose({ store, data, now: () => host.nowMs(), agent: (s, k) => views.agent(s, k) }))] });
  const base = t.host.nowMs();
  for (const [table, k, value] of records(base)) t.data.put(table, k, value);
  t.store.subscribe(1, 1, { topic: "newChat", scope: "ws" }, true);
  t.store.subscribe(1, 2, PICK, true);
  for (let round = 0; round < 2; round++) {
    for (const [topic, value] of [...fixture(base, OPENS), ...more(base)]) t.set(topic, value);
    await t.host.time.pass(100);
  }
  t.host.takeEmitted();
  const made = new Map<string, number>();
  const compute = t.router.compute.bind(t.router);
  t.router.compute = (topic) => {
    made.set(topic.topic, (made.get(topic.topic) ?? 0) + 1);
    return compute(topic);
  };
  return { t, choose: choose!, made, base };
}

test("an_open_model_panel_reads_no_stations_page_and_is_not_made_again_as_their_machines_readings_come", async () => {
  const { t, made, base } = await opened();
  const pick = t.store.get(PICK) as J;
  assert.ok(pick.options.length > 20, "the panel's models");
  assert.ok(!t.store.liveTopics().some((topic) => topic.topic === "stationsWhole" || topic.topic === "station"), "no station's page, no stations whole");
  // Each station up's machine read and its way measured anew, 20 times.
  for (let i = 1; i <= 20; i++) {
    for (const [n, at] of UP.entries()) {
      const st = STATIONS.findIndex((s) => `ws/${s.id}` === at);
      t.set({ topic: "host", station: at }, hostReading(base + i * 1000, st, 0.2 + ((i + n) % 7) * 0.05));
      t.set({ topic: "way", station: at }, { via: i % 2 === 0 ? "direct" : "relay", rttMs: 18 + i + n });
    }
    await t.host.time.pass(100);
  }
  assert.equal(made.get("pick") ?? 0, 0, "the panel not made again");
  assert.equal(made.get("stationsWhole") ?? 0, 0, "no stations whole made");
  assert.equal(made.get("station") ?? 0, 0, "no station's page made");
  assert.ok((made.get("stations") ?? 0) > 0, "(the stations' list, which shows them, made again)");
  assert.deepEqual(t.store.get(PICK), pick, "the panel as it was");
});

test("drafts_changed_in_an_open_panel_make_no_lent_model_again", async () => {
  const { t, choose, made } = await opened();
  choose.set(CHAT.station, "new", { otherStations: true });
  await t.host.time.pass(100);
  const pick = t.store.get(PICK) as J;
  const lendable = pick.options.filter((o: J) => o.availability === "borrowable");
  assert.ok(lendable.length > 0, "other stations lend it models");
  const before = made.get("pick") ?? 0;
  const pages = made.get("newChat") ?? 0;
  const from = { ...work };
  const efforts = ["low", "medium", "high"];
  for (let i = 0; i < 10; i++) {
    choose.set(CHAT.station, "new", i % 2 === 0 ? { effort: efforts[i % 3] } : { model: pick.options[i % 4].model });
    await t.host.time.pass(100);
  }
  const makes = (made.get("pick") ?? 0) - before;
  assert.equal(makes, 10, "the panel made again for each draft");
  // (its own station's models once each time, and the new chat's page's, made again with it; main made every model of
  // every profile each other station lends again too)
  assert.equal(workSince(from).models, makes + (made.get("newChat") ?? 0) - pages, "its own station's models alone");
  const after = t.store.get(PICK) as J;
  assert.deepEqual(after.options.filter((o: J) => o.availability === "borrowable").map((o: J) => [o.model, o.borrow]), lendable.map((o: J) => [o.model, o.borrow]));
});

test("the_panels_models_are_those_every_stations_page_with_its_models_would_give", async () => {
  // What the panel offered as it read `stationsWhole` (views.ts, kept for its own tests): its station's own models
  // said where their accounts are, then those the others up could lend, each the same.
  const { t, choose } = await opened();
  choose.set(CHAT.station, "new", { otherStations: true });
  t.store.subscribe(1, 3, { topic: "stationsWhole", scope: "ws" }, true);
  await t.host.time.pass(100);
  const whole = t.store.get({ topic: "stationsWhole", scope: "ws" });
  const overview = t.store.get({ topic: "overview", station: CHAT.station });
  const now = t.host.nowMs();
  const own = models(overview, now);
  const was = [...sourced(own, overview, whole), ...borrowable(whole, CHAT.station, own, null, now)];
  const pick = t.store.get(PICK) as J;
  const options = pick.options.map(({ usual: _u, usualText: _t, liked: _l, ...o }: J) => o);
  assert.ok(was.some((o) => o.availability === "borrowable"));
  assert.deepEqual(JSON.parse(JSON.stringify(options)), JSON.parse(JSON.stringify(was)));
});
