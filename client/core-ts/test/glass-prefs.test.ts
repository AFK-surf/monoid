// What glass surfaces are made of on this device (the prefs' `glass`: frosted, solid, none liquid glass), and the frost
// an older app sets (`glassFrost`: "0".."100", or none); refused where wrong.
import assert from "node:assert/strict";
import { test } from "node:test";
import type { Core } from "../src/core.ts";
import type { FakeHost } from "../src/testing.ts";
import { apply, call, subscribe, v } from "./helpers.ts";
import { started } from "./station-fixture.ts";

// deno-lint-ignore no-explicit-any
type J = any;

async function ask(host: FakeHost, core: Core, ui: number, id: number, name: string, params: unknown): Promise<J> {
  call(core, ui, id, name, params);
  await host.settle();
  const i = host.emitted.findIndex(([, m]) => (m as J).id === id && ("ok" in (m as J) || "error" in (m as J)));
  if (i < 0) throw new Error(`${name} not answered`);
  const [[, m]] = host.emitted.splice(i, 1);
  return m as J;
}

test("glass_frost_pref_accepts_0_to_100_and_resets_to_none_on_null", async () => {
  const { host, core } = await started();
  const ui = core.connect();
  subscribe(core, ui, 1, { topic: "prefs" });
  await host.settle();
  const values = new Map();
  apply(host, values);
  assert.equal(v(values, 1).glassFrost, undefined);

  for (const [id, ok] of [[2, "0"], [3, "50"], [4, "100"]] as [number, string][]) {
    const res = await ask(host, core, ui, id, "prefs.set", { glassFrost: ok });
    assert.ok("ok" in res, `expected ok for ${ok}`);
    apply(host, values);
    assert.equal(v(values, 1).glassFrost, ok);
  }

  for (const [id, bad] of [
    [5, { glassFrost: "-1" }],
    [6, { glassFrost: "101" }],
    [7, { glassFrost: "05" }],
    [8, { glassFrost: "50%" }],
    [9, { glassFrost: "" }],
    [10, { glassFrost: 50 }],
  ] as [number, J][]) {
    assert.equal((await ask(host, core, ui, id, "prefs.set", bad)).error.code, "invalid_params");
  }
  apply(host, values);
  assert.equal(v(values, 1).glassFrost, "100");

  await ask(host, core, ui, 11, "prefs.set", { glassFrost: null });
  apply(host, values);
  assert.equal(v(values, 1).glassFrost, undefined);
});

test("glass_pref_accepts_frosted_and_solid_and_resets_to_liquid_on_null", async () => {
  const { host, core } = await started();
  const ui = core.connect();
  subscribe(core, ui, 1, { topic: "prefs" });
  await host.settle();
  const values = new Map();
  apply(host, values);
  assert.equal(v(values, 1).glass, undefined);

  for (const [id, ok] of [[2, "frosted"], [3, "solid"]] as [number, string][]) {
    const res = await ask(host, core, ui, id, "prefs.set", { glass: ok });
    assert.ok("ok" in res, `expected ok for ${ok}`);
    apply(host, values);
    assert.equal(v(values, 1).glass, ok);
  }

  for (const [id, bad] of [
    [4, { glass: "liquid" }],
    [5, { glass: "" }],
    [6, { glass: "Frosted" }],
    [7, { glass: 1 }],
  ] as [number, J][]) {
    assert.equal((await ask(host, core, ui, id, "prefs.set", bad)).error.code, "invalid_params");
  }
  apply(host, values);
  assert.equal(v(values, 1).glass, "solid");

  await ask(host, core, ui, 8, "prefs.set", { glass: null });
  apply(host, values);
  assert.equal(v(values, 1).glass, undefined);
});
