// A station's mode changed through a whole core (src/rigs.ts by way of core.ts): under way in `doing` while it goes,
// and the workspace's view the cloud answers held at once, so the page follows with no event of the cloud's (a press
// of 改为只执行任务 showed nothing till the next event or read, 2026-11-20).
import assert from "node:assert/strict";
import { test } from "node:test";
import { Effect } from "effect";
import { callStation } from "../src/core/calls.ts";
import type { HttpRequest, HttpResponse } from "../src/host.ts";
import { parseRig } from "../src/rigs.ts";
import { jsonResponse } from "../src/testing.ts";
import { apply, call, subscribe, v } from "./helpers.ts";
import { base, started, stationLater } from "./station-fixture.ts";

// deno-lint-ignore no-explicit-any
type J = any;

const SUB = "s1";
const PATH = "/v1/workspaces/ws/stations/st";
/// Another whole station of the workspace's, which carries what the rig's person signs to make it whole again.
const NAS = { id: "st2", name: "nas", online: true, last_seen: null };

test("a station's mode changed is under way while it goes, and what the cloud answers is its page at once", async () => {
  // (an app's device, which holds the person's keys)
  const s = await started({ ...base(), "POST /mode": { ok: true }, "POST /rigs/st/full": { ok: true } }, 0, undefined, (h) => void (h.host.appKeys = true));
  const { host, core } = s;
  // (the person's own lock, as a rig pins it: one of theirs already)
  const real = core.inner.adb.personal();
  const mine: Record<string, unknown> = {
    refresh: () => Effect.void, standing: () => "member", root: () => "ROOT", signRig: () => Effect.succeed({ signed: true }), entries: () => [],
  };
  const personal = new Proxy(real, {
    get: (to, key) => (typeof key === "string" && key in mine ? mine[key] : typeof (to as J)[key] === "function" ? (to as J)[key].bind(to) : (to as J)[key]),
  });
  core.inner.adb.personal = () => personal;
  const asked: string[] = [];
  let answer: (res: HttpResponse) => void = () => {};
  stationLater(host, (req: HttpRequest) => {
    const path = req.url.replace("https://stillfail.test", "");
    if (path.startsWith("/v1/")) asked.push(`${req.method} ${path}`);
    if (req.method !== "PATCH" || path !== PATH) return undefined;
    return new Promise((done) => (answer = done));
  });
  const ui = core.connect();
  const values = new Map<number, unknown>();
  subscribe(core, ui, 1, { topic: "doing" });
  subscribe(core, ui, 2, { topic: "workspace", workspace: "ws" });
  await host.settle();
  apply(host, values);
  assert.deepEqual(v(values, 2).stations.map((x: J) => x.id), ["st"]);

  for (const [mode, view] of [
    ["tasks", { id: "ws", role: "owner", members: [{ sub: SUB, email: "a@x.com", role: "owner" }], stations: [NAS], rigs: [{ id: "st", name: "studio", owner: SUB, owner_email: "a@x.com", owner_name: "A" }] }],
    ["full", { id: "ws", role: "owner", members: [{ sub: SUB, email: "a@x.com", role: "owner" }], stations: [NAS, { id: "st", name: "studio", online: true, last_seen: null }] }],
  ] as const) {
    asked.length = 0;
    call(core, ui, 3, "rig.setMode", { workspace: "ws", station: "st", mode });
    await host.time.passUntil(1000, () => asked.includes(`PATCH ${PATH}`));
    await host.settle();
    apply(host, values);
    // Under way, about that station, while the cloud has not answered.
    assert.deepEqual(v(values, 1).doing.map((d: J) => [d.call, d.params.station, d.stage]), [["rig.setMode", "st", "running"]], mode);
    // Answered with the workspace's view: held at once, no event and no read of the workspace again.
    answer(jsonResponse(200, view));
    await host.settle();
    apply(host, values);
    assert.deepEqual(v(values, 2).stations.map((x: J) => x.id), view.stations.map((x) => x.id), mode);
    assert.deepEqual((v(values, 2).rigs ?? []).map((x: J) => x.id), "rigs" in view ? ["st"] : [], mode);
    assert.ok(!asked.includes("GET /v1/workspaces/ws"), asked.join());
    assert.deepEqual(v(values, 1).doing, [], mode);
  }
  core.close();
});

test("a station's mode change is about that station; a rig's log about none", () => {
  assert.equal(callStation({ kind: "rig", call: parseRig("rig.setMode", { workspace: "ws", station: "st", mode: "tasks" })! }), "ws/st");
  assert.equal(callStation({ kind: "rig", call: parseRig("rig.log", { workspace: "ws", rig: "r1" })! }), null);
});
