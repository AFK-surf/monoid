// 实验性功能 and the test channel's features (src/features.ts): what each stage gives on each channel, the switches
// kept on the device (`prefs.experimental`), ids not registered let go, and 试用新对话页's older `chatPage` read and let go.
import assert from "node:assert/strict";
import { test } from "node:test";
import * as brand from "../src/brand.ts";
import type { Data } from "../src/data.ts";
import * as prefs from "../src/prefs.ts";
import type { Core } from "../src/core.ts";
import { experimentalItemsOf, experimentalOf, featureEnabled, FEATURES, featuresOf, type FeatureSpec } from "../src/features.ts";
import type { FakeHost } from "../src/testing.ts";
import { apply, call, subscribe, v } from "./helpers.ts";
import { started } from "./station-fixture.ts";

// deno-lint-ignore no-explicit-any
type J = any;

const REGISTRY: Record<string, FeatureSpec> = {
  page: { stage: "experimental" },
  lab: { stage: "experimental", betaOnly: true },
  term: { stage: "beta" },
};

async function ask(host: FakeHost, core: Core, ui: number, id: number, name: string, params: unknown): Promise<J> {
  call(core, ui, id, name, params);
  await host.settle();
  const i = host.emitted.findIndex(([, m]) => (m as J).id === id && ("ok" in (m as J) || "error" in (m as J)));
  if (i < 0) throw new Error(`${name} not answered`);
  const [[, m]] = host.emitted.splice(i, 1);
  return m as J;
}

test("each_stage_on_each_channel", () => {
  const none = {};
  // beta: on on the test channel, off on stable, whatever is kept
  assert.equal(featureEnabled("term" as never, none, true, REGISTRY), true);
  assert.equal(featureEnabled("term" as never, none, false, REGISTRY), false);
  assert.equal(featureEnabled("term" as never, { experimental: { term: true } }, false, REGISTRY), false);
  // experimental: off on both channels till switched on
  for (const test of [true, false]) {
    assert.equal(featureEnabled("page" as never, none, test, REGISTRY), false);
    assert.equal(featureEnabled("page" as never, { experimental: { page: true } }, test, REGISTRY), true);
  }
  // betaOnly: off on the test channel till switched on, never on stable
  assert.equal(featureEnabled("lab" as never, none, true, REGISTRY), false);
  assert.equal(featureEnabled("lab" as never, { experimental: { lab: true } }, true, REGISTRY), true);
  assert.equal(featureEnabled("lab" as never, { experimental: { lab: true } }, false, REGISTRY), false);
  assert.deepEqual(featuresOf({ experimental: { page: true, lab: true } }, false, REGISTRY), { page: true, lab: false, term: false });
  assert.deepEqual(featuresOf({}, true, REGISTRY), { page: false, lab: false, term: true });
  // the page lists the experimental ones the channel shows, never a beta one
  assert.deepEqual(experimentalItemsOf({ experimental: { lab: true } }, true, REGISTRY), [
    { id: "page", enabled: false },
    { id: "lab", enabled: true },
  ]);
  assert.deepEqual(experimentalItemsOf({}, false, REGISTRY), [{ id: "page", enabled: false }]);
  assert.deepEqual(experimentalItemsOf({}, false, { term: { stage: "beta" } }), []);
});

test("unknown_and_graduated_switches_are_ignored", () => {
  assert.deepEqual(experimentalOf({ experimental: { page: true, gone: true, term: true, lab: "yes" } }, REGISTRY), { page: true });
  assert.deepEqual(experimentalOf({ experimental: [true] }, REGISTRY), {});
  assert.deepEqual(experimentalOf(null, REGISTRY), {});
});

test("the_older_chat_page_choice_reads_as_its_switch", () => {
  assert.equal(featureEnabled("chatPage", { chatPage: "nodes" }, false), true);
  assert.equal(featureEnabled("chatPage", { chatPage: "nodes", experimental: { board: true } }, true), true);
  assert.equal(featureEnabled("chatPage", {}, true), false);
  assert.deepEqual(Object.keys(FEATURES), ["chatPage", "farviewNative", "board", "terminal", "stationMove"]);
});

test("the_switches_are_kept_on_the_device_and_shown_with_the_prefs", async () => {
  const { host, core } = await started();
  const ui = core.connect();
  subscribe(core, ui, 1, { topic: "prefs" });
  await host.settle();
  const values = new Map();
  apply(host, values);
  const test = brand.isTestChannel();
  assert.equal(v(values, 1).testChannel, test);
  assert.deepEqual(v(values, 1).experimental, {});
  assert.equal(v(values, 1).features.board, false);
  assert.equal(v(values, 1).features.terminal, test);
  assert.deepEqual(v(values, 1).experimentalItems.map((i: J) => i.id), ["chatPage", "farviewNative", "board"]);

  assert.ok((await ask(host, core, ui, 2, "prefs.set", { experimental: { board: true, farviewNative: true } })).ok !== undefined);
  apply(host, values);
  assert.deepEqual(v(values, 1).experimental, { board: true, farviewNative: true });
  assert.equal(v(values, 1).features.board, true);
  assert.deepEqual(v(values, 1).experimentalItems.filter((i: J) => i.enabled).map((i: J) => i.id), ["farviewNative", "board"]);

  // refused: an id not registered, a beta one, a value not a switch
  assert.equal((await ask(host, core, ui, 3, "prefs.set", { experimental: { gone: true } })).error.code, "invalid_params");
  assert.equal((await ask(host, core, ui, 4, "prefs.set", { experimental: { terminal: true } })).error.code, "invalid_params");
  assert.equal((await ask(host, core, ui, 5, "prefs.set", { experimental: { board: "on" } })).error.code, "invalid_params");

  // off: let go of (null or false), the map gone with its last
  await ask(host, core, ui, 6, "prefs.set", { experimental: { board: null } });
  await ask(host, core, ui, 7, "prefs.set", { experimental: { farviewNative: false } });
  apply(host, values);
  assert.deepEqual(v(values, 1).experimental, {});
  assert.equal(v(values, 1).features.board, false);
  core.close();
});

test("the_chat_page_switch_takes_over_the_older_choice", async () => {
  const { host, core } = await started();
  const ui = core.connect();
  subscribe(core, ui, 1, { topic: "prefs" });
  await host.settle();
  const values = new Map();
  // an older app's choice reads as the switch on
  await ask(host, core, ui, 2, "prefs.set", { chatPage: "nodes" });
  apply(host, values);
  assert.equal(v(values, 1).chatPage, "nodes");
  assert.equal(v(values, 1).experimental.chatPage, true);
  assert.equal(v(values, 1).features.chatPage, true);
  // turned off here: the older choice goes with it
  await ask(host, core, ui, 3, "prefs.set", { experimental: { chatPage: null } });
  apply(host, values);
  assert.equal(v(values, 1).chatPage, undefined);
  assert.equal(v(values, 1).features.chatPage, false);
  // on again and off by the older field: both go
  await ask(host, core, ui, 4, "prefs.set", { experimental: { chatPage: true } });
  apply(host, values);
  assert.equal(v(values, 1).features.chatPage, true);
  await ask(host, core, ui, 5, "prefs.set", { chatPage: null });
  apply(host, values);
  assert.equal(v(values, 1).features.chatPage, false);
  assert.deepEqual(v(values, 1).experimental, {});
  core.close();
});

test("switches_of_features_gone_are_let_go_as_the_prefs_are_next_written", () => {
  // what an older build kept of a feature since graduated, or of one never registered
  let kept: J = { experimental: { board: true, graduated: true } };
  const data = { get: () => kept, set: (_: unknown, v: unknown) => (kept = v) } as unknown as Data;
  prefs.set(data, { motion: "reduce" }, false, 0);
  assert.deepEqual(kept.experimental, { board: true });
  kept = { experimental: { graduated: true } };
  prefs.set(data, { motion: "reduce" }, false, 0);
  assert.equal("experimental" in kept, false);
});
