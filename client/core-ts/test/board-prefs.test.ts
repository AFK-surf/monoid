// A workspace's board as this device keeps it (the prefs' `boardViews`, `boardGroups`, `boardDrafts`): shown as a
// board or not, how its columns are grouped, the drafts its 待派发 keeps; each workspace its own, refused where wrong.
import assert from "node:assert/strict";
import { test } from "node:test";
import type { Core } from "../src/core.ts";
import type { FakeHost } from "../src/testing.ts";
import { apply, call, subscribe, v } from "./helpers.ts";
import { started } from "./station-fixture.ts";

// deno-lint-ignore no-explicit-any
type J = any;

/// A call answered: its `ok`, or its error (what else came stays to be read).
async function ask(host: FakeHost, core: Core, ui: number, id: number, name: string, params: unknown): Promise<J> {
  call(core, ui, id, name, params);
  await host.settle();
  const i = host.emitted.findIndex(([, m]) => (m as J).id === id && ("ok" in (m as J) || "error" in (m as J)));
  if (i < 0) throw new Error(`${name} not answered`);
  const [[, m]] = host.emitted.splice(i, 1);
  return m as J;
}

const draft = (n: number, more: J = {}) => ({ id: `new:board-${n}`, title: `第 ${n} 件事`, station: "w1/st", stationName: "Willow", ...more });

test("a_workspaces_board_view_and_grouping_are_kept_each_its_own_and_none_goes_back_to_the_list", async () => {
  const { host, core } = await started();
  const ui = core.connect();
  subscribe(core, ui, 1, { topic: "prefs" });
  await host.settle();
  const values = new Map();
  apply(host, values);
  assert.deepEqual([v(values, 1).boardViews, v(values, 1).boardGroups], [{}, {}]);
  await ask(host, core, ui, 2, "prefs.set", { boardViews: { w1: "board" }, boardGroups: { w1: "station", w2: "person" } });
  apply(host, values);
  assert.deepEqual(v(values, 1).boardViews, { w1: "board" });
  assert.deepEqual(v(values, 1).boardGroups, { w1: "station", w2: "person" });
  await ask(host, core, ui, 3, "prefs.set", { boardViews: { w1: null }, boardGroups: { w2: null } });
  apply(host, values);
  assert.deepEqual([v(values, 1).boardViews, v(values, 1).boardGroups], [{}, { w1: "station" }]);
  for (const [id, bad] of [[4, { boardViews: { w1: "list" } }], [5, { boardViews: { w1: true } }], [6, { boardGroups: { w1: "date" } }]] as [number, J][]) {
    assert.equal((await ask(host, core, ui, id, "prefs.set", bad)).error.code, "invalid_params");
  }
  apply(host, values);
  assert.deepEqual([v(values, 1).boardViews, v(values, 1).boardGroups], [{}, { w1: "station" }]);
  core.close();
});

test("a_workspaces_drafts_are_kept_whole_the_newest_200_none_left_as_an_empty_list_and_a_wrong_one_refused", async () => {
  const { host, core } = await started();
  const ui = core.connect();
  subscribe(core, ui, 1, { topic: "prefs" });
  await host.settle();
  const values = new Map();
  apply(host, values);
  assert.deepEqual(v(values, 1).boardDrafts, {});
  await ask(host, core, ui, 2, "prefs.set", { boardDrafts: { w1: [draft(2), draft(1)], w2: [draft(9)] } });
  apply(host, values);
  assert.deepEqual(v(values, 1).boardDrafts.w1, [draft(2), draft(1)]);
  // (newest first: the 200 newest kept)
  const many = Array.from({ length: 230 }, (_, i) => draft(230 - i));
  await ask(host, core, ui, 3, "prefs.set", { boardDrafts: { w1: many } });
  apply(host, values);
  assert.equal(v(values, 1).boardDrafts.w1.length, 200);
  assert.deepEqual([v(values, 1).boardDrafts.w1[0].id, v(values, 1).boardDrafts.w1[199].id], ["new:board-230", "new:board-31"]);
  // (none left: no empty list kept, nor one put to null)
  await ask(host, core, ui, 4, "prefs.set", { boardDrafts: { w1: [], w2: null } });
  apply(host, values);
  assert.deepEqual(v(values, 1).boardDrafts, {});
  const wrong: J[] = [
    [draft(1, { id: "" })],
    [draft(1, { id: "x".repeat(121) })],
    [draft(1, { title: "   " })],
    [draft(1, { title: "x".repeat(4001) })],
    [draft(1, { station: "" })],
    [draft(1, { stationName: 7 })],
    [{ id: "new:board-1", title: "t", station: "w1/st" }],
    "draft",
    [null],
  ];
  for (const [i, bad] of wrong.entries()) {
    assert.equal((await ask(host, core, ui, 10 + i, "prefs.set", { boardDrafts: { w1: bad } })).error.code, "invalid_params", JSON.stringify(bad).slice(0, 80));
  }
  apply(host, values);
  assert.deepEqual(v(values, 1).boardDrafts, {});
  core.close();
});
