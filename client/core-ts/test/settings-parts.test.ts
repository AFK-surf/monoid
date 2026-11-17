// What the connects and the settings' automatic decisions and archiving read of a station's overview, kept beside it
// (schema.ts overviewConnectsOf, overviewSettingsOf; data.ts overviewConnects, overviewSettings): the same as what
// they read of the whole (views.ts connectsPartOf, present.ts overview), whatever the overview says, where no part is
// kept (made of the overview by SQLite as it is read: an older core's triggers) and where the overview is shown with
// what is being done to it here; told as it changes, not with the rest of the overview.
import assert from "node:assert/strict";
import { test } from "node:test";
import { DatabaseSync } from "node:sqlite";
import { Data } from "../src/data.ts";
import { NodeSql } from "../src/hosts/node-sql.ts";
import type { Topic } from "../src/protocol.ts";
import { observe } from "../src/reactive.ts";
import { Runner } from "../src/runtime.ts";
import { FakeHost, flush } from "../src/testing.ts";
import { run } from "./run.ts";

// deno-lint-ignore no-explicit-any
type J = any;

const ST = "w/a";
const overview = (station = ST): Topic => ({ topic: "overview", station });

/// What the connects read of an overview, as views.ts connectsPartOf and #connectOf read it of the whole.
const connectsOf = (o: J) => {
  const list = (v: unknown) => (Array.isArray(v) ? v : []);
  const object = o !== null && typeof o === "object" && !Array.isArray(o);
  return { connects: list(object ? o.connects : undefined), slackApps: list(object ? o.slackApps : undefined), profiled: !object || list(o.profiles).length > 0, connectRuntimeChange: object && o.connectRuntimeChange === true };
};
/// What the settings read of an overview: its automatic decisions and archiving, as it has them.
const settingsOf = (o: J) => {
  if (o === null || typeof o !== "object" || Array.isArray(o)) return undefined;
  const out: J = {};
  for (const k of Object.keys(o)) if (k === "automaticDecisions" || k === "archiving") out[k] = o[k];
  return out;
};

const OVERVIEWS: [string, J][] = [
  ["everything", { connects: [{ id: "c1", kind: "slack", name: "一" }], slackApps: [{ appId: "A1" }], profiles: [{ id: "p1", named: ["m"] }], connectRuntimeChange: true, archiving: { mode: "reviewed", days: 7 }, automaticDecisions: { settings: { completion: { enabled: true } }, recent: [{ at: 5 }] }, processes: [{ pgid: 1 }] }],
  ["none of them", { processes: [] }],
  ["not lists", { connects: { no: 1 }, slackApps: "x", profiles: {}, connectRuntimeChange: "yes", archiving: null, automaticDecisions: 3 }],
  ["no profile", { connects: [], profiles: [] }],
  ["not an object", [1, 2, 3]],
  ["a number", 42],
];

function fresh() {
  const host = new FakeHost();
  host.openDbHook = (name) => {
    let sql = host.sqls.get(name);
    if (sql === undefined) host.sqls.set(name, (sql = new NodeSql(new DatabaseSync(":memory:"), true)));
    return sql;
  };
  const runner = new Runner(host.time.clock);
  const data = new Data(host, runner, { owner: () => "s1" });
  // What reads each part is told (made again) as it changes: counted.
  const told: string[] = [];
  const heard = (name: string, read: () => unknown) => observe(() => void read(), (job) => {
    told.push(name);
    job();
  });
  return { host, runner, data, told, hear: () => [heard("$overview-connects", () => data.overviewConnects(ST)), heard("$overview-settings", () => data.overviewSettings(ST))] };
}

test("what_the_connects_and_settings_read_of_an_overview_is_kept_beside_it_as_the_whole_says_it", async () => {
  const { host, runner, data } = fresh();
  await run(data.open(["s1"]));
  assert.equal(data.overviewConnects(ST), undefined, "none held");
  assert.equal(data.overviewSettings(ST), undefined, "none held");
  const sql = host.sqls.values().next().value as NodeSql;
  for (const [name, o] of OVERVIEWS) {
    // (written whole again first: the part the test took away below made anew)
    data.set(overview(), { before: name });
    await flush();
    data.set(overview(), o);
    await flush();
    assert.deepEqual(data.overviewConnects(ST), connectsOf(o), `${name}: connects`);
    assert.deepEqual(data.overviewSettings(ST), settingsOf(o), `${name}: settings`);
    // No part kept (an older core's triggers put the row in without these columns): made of the overview as read.
    sql.run("UPDATE station_part SET connects = NULL, settings = NULL WHERE address = ?", [ST]);
    const again = new Data(host, runner, { owner: () => "s1" });
    await run(again.open(["s1"]));
    assert.deepEqual(again.overviewConnects(ST), connectsOf(o), `${name}: connects, made as read`);
  }
  runner.shutdown();
});

test("the_connects_and_settings_are_told_as_they_change_not_with_the_rest_of_the_overview", async () => {
  const { runner, data, told, hear } = fresh();
  await run(data.open(["s1"]));
  const o: J = { ...OVERVIEWS[0]![1] };
  data.set(overview(), o);
  await flush();
  hear();
  told.length = 0;
  data.set(overview(), { ...o, processes: [{ pgid: 2 }], counts: { running: 3 } });
  await flush();
  assert.deepEqual(told.filter((t) => t === "$overview-connects" || t === "$overview-settings"), [], "the rest changed: neither told");
  data.set(overview(), { ...o, connects: [...o.connects, { id: "c2" }] });
  await flush();
  assert.deepEqual(told.filter((t) => t === "$overview-connects" || t === "$overview-settings"), ["$overview-connects"]);
  assert.equal((data.overviewConnects(ST) as J).connects.length, 2);
  told.length = 0;
  data.set(overview(), { ...o, connects: [...o.connects, { id: "c2" }], archiving: { mode: "off" } });
  await flush();
  assert.deepEqual(told.filter((t) => t === "$overview-connects" || t === "$overview-settings"), ["$overview-settings"]);
  assert.deepEqual((data.overviewSettings(ST) as J).archiving, { mode: "off" });
  runner.shutdown();
});

test("an_overview_shown_with_what_is_being_done_to_it_here_gives_its_connects_and_settings_of_what_is_shown", async () => {
  const { runner, data, told, hear } = fresh();
  await run(data.open(["s1"]));
  const o: J = { profiles: [{ id: "p1", runtime: "claude", named: ["a"] }], connects: [{ id: "c1" }], archiving: { mode: "reviewed" } };
  data.set(overview(), o);
  await flush();
  hear();
  told.length = 0;
  assert.equal(data.beginModels(ST, "p1", ["a", "b"]), true);
  assert.ok(told.includes("$overview-connects") && told.includes("$overview-settings"), "told as it is shown otherwise");
  const shown = data.shared(overview());
  assert.deepEqual(data.overviewConnects(ST), connectsOf(shown));
  assert.deepEqual(data.overviewSettings(ST), settingsOf(shown));
  told.length = 0;
  data.endModels(ST, "p1");
  assert.ok(told.includes("$overview-connects") && told.includes("$overview-settings"), "told as it is shown as held again");
  assert.deepEqual(data.overviewConnects(ST), connectsOf(o));
  runner.shutdown();
});
