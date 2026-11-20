// How a machine's CPU dial says it on this device (the prefs' `cpuDial`): busy, or none for idle; refused where wrong.
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

test("a_machines_cpu_dial_is_kept_busy_on_this_device_and_none_goes_back_to_idle", async () => {
  const { host, core } = await started();
  const ui = core.connect();
  subscribe(core, ui, 1, { topic: "prefs" });
  await host.settle();
  const values = new Map();
  apply(host, values);
  assert.equal(v(values, 1).cpuDial, undefined);
  await ask(host, core, ui, 2, "prefs.set", { cpuDial: "busy" });
  apply(host, values);
  assert.equal(v(values, 1).cpuDial, "busy");
  for (const [id, bad] of [[3, { cpuDial: "idle" }], [4, { cpuDial: true }]] as [number, J][]) {
    assert.equal((await ask(host, core, ui, id, "prefs.set", bad)).error.code, "invalid_params");
  }
  apply(host, values);
  assert.equal(v(values, 1).cpuDial, "busy");
  await ask(host, core, ui, 5, "prefs.set", { cpuDial: null });
  apply(host, values);
  assert.equal(v(values, 1).cpuDial, undefined);
});
