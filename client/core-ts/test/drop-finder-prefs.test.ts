// How external file drops into a chat behave on this device (the prefs' `dropFinder`): path inserts local path text, or none keeps the default; refused where wrong.
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

test("external_drop_paths_setting_is_kept_on_this_device_and_none_restores_default", async () => {
  const { host, core } = await started();
  const ui = core.connect();
  subscribe(core, ui, 1, { topic: "prefs" });
  await host.settle();
  const values = new Map();
  apply(host, values);
  assert.equal(v(values, 1).dropFinder, undefined);
  await ask(host, core, ui, 2, "prefs.set", { dropFinder: "path" });
  apply(host, values);
  assert.equal(v(values, 1).dropFinder, "path");
  for (const [id, bad] of [[3, { dropFinder: "file" }], [4, { dropFinder: true }], [5, { dropFinder: "" }]] as [number, J][]) {
    assert.equal((await ask(host, core, ui, id, "prefs.set", bad)).error.code, "invalid_params");
  }
  apply(host, values);
  assert.equal(v(values, 1).dropFinder, "path");
  await ask(host, core, ui, 6, "prefs.set", { dropFinder: null });
  apply(host, values);
  assert.equal(v(values, 1).dropFinder, undefined);
});
