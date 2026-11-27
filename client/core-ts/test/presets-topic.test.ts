// A workspace's presets on a station (the `presets` topic): read as a page shows them and again once
// one is made; the one picked for a new chat there is kept on this device and goes with the chat as it is made.
import assert from "node:assert/strict";
import { test } from "node:test";
import { Deferred, Effect, Queue } from "effect";
import { apply as applyOps } from "../src/delta.ts";
import { answers, apply, call, readsOf, subscribe, v } from "./helpers.ts";
import { Core } from "../src/core.ts";
import { base, overview, started, stationLater, stationReplies } from "./station-fixture.ts";
import type { HttpRequest } from "../src/host.ts";
import { CoreError } from "../src/error.ts";
import type { StationAddr } from "../src/station/addr.ts";
import { HostWire, type RequestHead, type StationWire } from "../src/station/wire.ts";
import { logKey, PRESETS } from "../src/station/link.ts";
import { KEEP_MS, Memory, type Keeper } from "../src/station/memory.ts";
import { jsonResponse, type FakeHost } from "../src/testing.ts";
import { work } from "../src/work.ts";

const S = "ws/st";
const preset = (id: string, name: string) => ({ id, name, dirs: [{ path: `/repos/${id}`, repo: `github.com/acme/${id}` }], instructions: "", createdBy: "a@x.com", createdAt: 1, updatedAt: 1 });
const candidate = { path: "/repos/app", name: "app", repo: "github.com/acme/app", chats: 3, lastAt: 2 };
const profile = {
  id: "p1", name: "p1@x.com", runtime: "claude", runtimes: ["claude"], access: { kind: "subscription", key: "" }, home: "/h", homeExists: true, model: null, models: ["claude-opus-5-5"],
  env: [], usedBy: [], loginCommand: "", check: { state: "ok", detail: "", checkedAt: 1 }, quota: { state: "ok", windows: [], detail: null, checkedAt: 1 },
};

test("a_picker_subscribing_over_the_client_protocol_gets_the_repositories", async () => {
  const said: Record<string, unknown> = {
    ...base(),
    "GET /overview": { ...overview, profiles: [profile] },
    "GET /presets": { presets: [], candidates: [candidate] },
  };
  const { host, core, push } = await started(said as never);
  const ui = core.connect();
  const values = new Map<number, unknown>();
  // The app first opens a new chat, whose view reads each station's presets, then opens the folder picker.
  core.receiveJson(ui, JSON.stringify({ id: 1, subscribe: { topic: "newChat", scope: "ws" }, keyed: true }));
  await host.settle();
  apply(host, values);
  assert.ok(host.requests.flatMap(readsOf).some((u) => u.endsWith("/admin/api/presets")));
  core.receiveJson(ui, JSON.stringify({ id: 2, subscribe: { topic: "presets", station: S }, keyed: true }));
  await host.settle();
  const emitted = host.takeEmitted().map(([, message]) => message as { id?: number; value?: { candidates: { name: string }[] }; error?: unknown });
  const answer = emitted.find((message) => message.id === 2);
  assert.ok(answer?.value, `the picker must receive the cached folders, got ${JSON.stringify(answer)}`);
  assert.deepEqual(answer.value.candidates.map((c) => c.name), ["app"]);
  values.set(2, answer.value);
  // A scan completed after the picker opened: the same subscription receives the new repository.
  said["GET /presets"] = { presets: [], candidates: [candidate, { ...candidate, path: "/repos/lib", name: "lib", repo: "github.com/acme/lib" }] };
  push("presets", {});
  await host.settle();
  apply(host, values);
  assert.deepEqual(v(values, 2).candidates.map((c: { name: string }) => c.name), ["app", "lib"]);
  core.close();
});

test("presets_are_read_as_shown_again_once_one_is_made_and_the_one_picked_goes_with_a_new_chat", async () => {
  const said: Record<string, unknown> = {
    ...base(),
    "GET /overview": { ...overview, profiles: [profile] },
    "GET /presets": { presets: [preset("app", "App")], candidates: [candidate] },
    "POST /presets": preset("lib", "Lib"),
    "POST /sessions": { key: "chat:c-new", thread: { id: 9, threadTs: "9.0" } },
  };
  const { host, core } = await started(said as never);
  const reads = () => host.requests.flatMap(readsOf).filter((u) => u.endsWith("/admin/api/presets")).length;
  assert.equal(reads(), 0, "not read until a page shows them");
  const ui = core.connect();
  const values = new Map<number, unknown>();
  subscribe(core, ui, 1, { topic: "presets", station: S });
  subscribe(core, ui, 2, { topic: "newChat", scope: "ws" });
  await host.settle();
  apply(host, values);
  assert.equal(reads(), 1);
  assert.deepEqual(v(values, 1).presets.map((p: { name: string }) => p.name), ["App"]);
  assert.equal(v(values, 1).candidates[0].chats, 3);
  assert.equal(v(values, 2).preset, "", "none picked yet");

  // One made: read again, the list as it is now.
  said["GET /presets"] = { presets: [preset("app", "App"), preset("lib", "Lib")], candidates: [candidate] };
  call(core, ui, 3, "preset.add", { station: S, name: "Lib", dirs: ["/repos/lib"] });
  await host.settle();
  apply(host, values);
  const made = host.requests.find((r) => r.method === "POST" && r.url.endsWith("/admin/api/presets"));
  assert.deepEqual(JSON.parse(new TextDecoder().decode(made!.body!)), { name: "Lib", dirs: ["/repos/lib"], instructions: "" });
  assert.equal(reads(), 2);
  assert.deepEqual(v(values, 1).presets.map((p: { name: string }) => p.name), ["App", "Lib"]);

  // Picked for the station's new chats: the page says so, and the chat made there is opened with it.
  call(core, ui, 4, "newChat.pick", { scope: "ws", preset: "lib", presetStation: S });
  await host.settle();
  apply(host, values);
  assert.equal(v(values, 2).preset, "lib");
  assert.equal(v(values, 2).presetName, "Lib", "named as the station says, the page asking nothing more");
  assert.equal(v(values, 2).presetStation, S);
  assert.deepEqual(v(values, 2).presets, [
    { id: "app", name: "App", station: S, stationName: "studio", summary: "app", dirName: "app", dirRepo: "github.com/acme/app" },
    { id: "lib", name: "Lib", station: S, stationName: "studio", summary: "lib", dirName: "lib", dirRepo: "github.com/acme/lib", used: true },
  ]);
  assert.deepEqual(v(values, 2).presetMarks, [{ name: "lib", repo: "github.com/acme/lib" }], "the one picked's marks, its control's look");
  call(core, ui, 5, "newChat.create", { station: S, key: v(values, 2).next });
  await host.settle();
  const asked = host.requests.find((r) => r.method === "POST" && r.url.endsWith("/admin/api/sessions"));
  const body = JSON.parse(new TextDecoder().decode(asked!.body!));
  assert.equal(body.preset, "lib", "this station's: by its id");
  assert.equal(body.presetCopy, undefined);

  // Gone from the station: no longer picked, nor sent with a chat.
  said["GET /presets"] = { presets: [preset("app", "App")], candidates: [candidate] };
  said["DELETE /presets/lib"] = { ok: true };
  call(core, ui, 6, "preset.delete", { station: S, id: "lib" });
  await host.settle();
  call(core, ui, 7, "newChat.pick", { scope: "ws", station: "st" });
  await host.settle();
  apply(host, values);
  assert.equal(v(values, 2).preset, "");
  core.close();
});

test("presets_shown_are_read_again_as_the_station_tells_they_changed", async () => {
  // (the machine's repositories found after 添加目录 was opened: they come into it as it stands)
  const said: Record<string, unknown> = { ...base(), "GET /presets": { presets: [], candidates: [] } };
  const s = await started(said as never);
  const ui = s.core.connect();
  const values = new Map<number, unknown>();
  subscribe(s.core, ui, 1, { topic: "presets", station: S });
  await s.host.settle();
  apply(s.host, values);
  assert.deepEqual(v(values, 1).candidates, []);
  said["GET /presets"] = { presets: [], candidates: [candidate] };
  s.push("presets", {});
  await s.host.settle();
  apply(s.host, values);
  assert.deepEqual(v(values, 1).candidates.map((c: { name: string }) => c.name), ["app"]);
  s.core.close();
});

test("a_repository_cloned_onto_the_station_shows_as_it_goes_and_an_older_station_sends_no_clones", async () => {
  // (a station from before sends no `clones`: none)
  const said: Record<string, unknown> = { ...base(), "GET /presets": { presets: [], candidates: [candidate] } };
  const s = await started(said as never);
  const ui = s.core.connect();
  const values = new Map<number, unknown>();
  subscribe(s.core, ui, 1, { topic: "presets", station: S });
  await s.host.settle();
  apply(s.host, values);
  assert.deepEqual(v(values, 1).clones, []);

  // Started: the station answers at once, the page reads the list again and shows it cloning.
  const cloning = { id: "c1", url: "https://github.com/acme/lib.git", repo: "github.com/acme/lib", name: "lib", state: "cloning", by: "a@x.com", startedAt: 5 };
  said["POST /presets/clone"] = cloning;
  said["GET /presets"] = { presets: [], candidates: [candidate], clones: [cloning] };
  call(s.core, ui, 2, "preset.clone", { station: S, url: "acme/lib" });
  await s.host.settle();
  const emitted = s.host.takeEmitted();
  const answer = answers(emitted, 2) as { ok?: { id: string; state: string } } | undefined;
  assert.equal(answer?.ok?.state, "cloning", JSON.stringify(answer));
  assert.equal(answer?.ok?.id, "c1");
  const asked = s.host.requests.find((r) => r.method === "POST" && r.url.endsWith("/admin/api/presets/clone"));
  assert.deepEqual(JSON.parse(new TextDecoder().decode(asked!.body!)), { url: "acme/lib" });
  for (const [, message] of emitted) {
    const m = message as Record<string, unknown>;
    if (m.id !== 1) continue;
    if ("value" in m) values.set(1, m.value);
    else if ("delta" in m) values.set(1, applyOps(values.get(1), m.delta as never));
  }
  assert.deepEqual(v(values, 1).clones.map((c: { name: string; state: string; error: string }) => [c.name, c.state, c.error]), [["lib", "cloning", ""]]);

  // Failed, then dropped.
  said["GET /presets"] = { presets: [], candidates: [candidate], clones: [{ ...cloning, state: "failed", error: "fatal: repository not found" }] };
  s.push("presets", {});
  await s.host.settle();
  apply(s.host, values);
  assert.equal(v(values, 1).clones[0].error, "fatal: repository not found");
  said["DELETE /presets/clones/c1"] = { ok: true };
  said["GET /presets"] = { presets: [], candidates: [candidate], clones: [] };
  call(s.core, ui, 3, "preset.cloneDrop", { station: S, id: "c1" });
  await s.host.settle();
  apply(s.host, values);
  assert.ok(s.host.requests.some((r) => r.method === "DELETE" && r.url.endsWith("/admin/api/presets/clones/c1")));
  assert.deepEqual(v(values, 1).clones, []);
  s.core.close();
});

test("a_preset_applies_its_optional_station_and_model_when_picked_or_leaves_them_unrestricted", async () => {
  const p2 = {
    ...profile,
    id: "p2",
    name: "p2@x.com",
    models: ["claude-opus-5-5", "claude-sonnet-5-5"],
  };
  const presetBound = {
    id: "review",
    name: "Code Review",
    dirs: [],
    instructions: "Review carefully.",
    autoStation: true,
    model: { model: "claude-sonnet-5-5", runtime: "claude", effort: "high" },
    createdBy: "a@x.com",
    createdAt: 1,
    updatedAt: 1,
  };
  const presetFree = {
    id: "free",
    name: "Free Prompt",
    dirs: [],
    instructions: "Just instructions.",
    createdBy: "a@x.com",
    createdAt: 1,
    updatedAt: 1,
  };
  const said: Record<string, unknown> = {
    ...base(),
    "GET /overview": { ...overview, claudeTui: true, autoChats: { enabled: true, canEdit: true }, profiles: [p2] },
    "GET /presets": { presets: [presetBound, presetFree], candidates: [candidate] },
  };
  const { host, core } = await started(said as never);
  const ui = core.connect();
  const values = new Map<number, unknown>();
  subscribe(core, ui, 1, { topic: "presets", station: S });
  subscribe(core, ui, 2, { topic: "newChat", scope: "ws" });
  await host.settle();
  apply(host, values);
  assert.equal(v(values, 2).pick.value.model, "claude-opus-5-5");

  call(core, ui, 10, "pick.defaultTui", { tui: true });

  // Picking a preset with a model applies that model and effort.
  call(core, ui, 3, "newChat.pick", { scope: "ws", preset: "review", presetStation: S });
  await host.settle();
  apply(host, values);
  assert.equal(core.inner.choose.create(S).tui, undefined);
  assert.equal(v(values, 2).preset, "review");
  assert.equal(v(values, 2).pick.value.model, "claude-sonnet-5-5");
  assert.equal(v(values, 2).pick.value.effort, "high");

  // Picking an unrestricted preset leaves the station and the model as they were picked before it: the bound one was
  // the preset's, never written over the person's own.
  call(core, ui, 4, "newChat.pick", { scope: "ws", preset: "free", presetStation: S });
  await host.settle();
  apply(host, values);
  assert.equal(core.inner.choose.create(S).tui, true);
  assert.equal(v(values, 2).preset, "free");
  assert.equal(v(values, 2).presetModel, false);
  assert.equal(v(values, 2).pick.value.model, "claude-opus-5-5");

  // `connect-new:preset` starts unrestricted (`value.model === null`) while still populating panel options/efforts,
  // saves via `pick.save`, and resets to unrestricted via `pick.set({ clear: true })`.
  subscribe(core, ui, 5, { topic: "pick", station: S, of: "connect-new:preset" });
  await host.settle();
  apply(host, values);
  assert.equal(v(values, 5).value.model, undefined);
  assert.equal(v(values, 5).option, "claude-opus-5-5");
  assert.equal(v(values, 5).draft.tui, undefined);
  assert.equal(v(values, 5).changed, true);

  call(core, ui, 6, "pick.save", { station: S, of: "connect-new:preset", model: "claude-opus-5-5", effort: "medium" });
  await host.settle();
  apply(host, values);
  assert.equal(v(values, 5).value.model, "claude-opus-5-5");
  assert.equal(v(values, 5).value.effort, "medium");

  call(core, ui, 7, "pick.set", { station: S, of: "connect-new:preset", clear: true });
  await host.settle();
  apply(host, values);
  assert.equal(v(values, 5).value.model, undefined);
  core.close();
});

test("what_a_preset_binds_is_not_changed_on_the_page_nor_sent_otherwise", async () => {
  const p2 = { ...profile, id: "p2", name: "p2@x.com", models: ["claude-opus-5-5", "claude-sonnet-5-5"] };
  const bound = {
    id: "review", name: "Code Review", dirs: [], instructions: "", model: { model: "claude-sonnet-5-5", runtime: "claude", effort: "high" },
    createdBy: "a@x.com", createdAt: 1, updatedAt: 1,
  };
  const elsewhere = { id: "far", name: "Far", dirs: [], instructions: "", station: "ws/other", createdBy: "a@x.com", createdAt: 1, updatedAt: 1 };
  const said: Record<string, unknown> = {
    ...base(),
    "GET /overview": { ...overview, profiles: [p2] },
    "GET /presets": { presets: [bound, elsewhere], candidates: [candidate] },
    "POST /sessions": { key: "chat:c-new", thread: { id: 9, threadTs: "9.0" } },
  };
  const { host, core } = await started(said as never);
  const ui = core.connect();
  const values = new Map<number, unknown>();
  // (what a call answered, the values it changed taken as `apply` takes them)
  const answered = (id: number): Record<string, unknown> | undefined => {
    const out = host.takeEmitted();
    for (const [, m] of out) {
      const x = m as Record<string, unknown>;
      if ("value" in x) values.set(x.id as number, x.value);
      else if ("delta" in x) values.set(x.id as number, applyOps(values.get(x.id as number), x.delta as never));
    }
    return answers(out, id);
  };
  subscribe(core, ui, 1, { topic: "presets", station: S });
  subscribe(core, ui, 2, { topic: "newChat", scope: "ws" });
  await host.settle();
  apply(host, values);
  assert.equal(v(values, 2).pick.value.model, "claude-opus-5-5");
  assert.equal(v(values, 2).presetModel, false);

  // Its model: shown as the preset's, the control not to open, a pick of another refused saying how to have it.
  call(core, ui, 3, "newChat.pick", { scope: "ws", preset: "review", presetStation: S });
  await host.settle();
  apply(host, values);
  assert.equal(v(values, 2).presetModel, true);
  assert.equal(v(values, 2).presetStations, false);
  assert.equal(v(values, 2).pick.value.model, "claude-sonnet-5-5");
  assert.equal(v(values, 2).pick.value.effort, "high");
  call(core, ui, 4, "newChat.pick", { scope: "ws", station: "st", model: "claude-opus-5-5" });
  await host.settle();
  const refused = answered(4) as { error?: { message: string } };
  assert.match(refused.error?.message ?? "", /Code Review/);
  assert.equal(v(values, 2).pick.value.model, "claude-sonnet-5-5", "nothing changed");
  call(core, ui, 5, "newChat.create", { station: S, key: v(values, 2).next });
  await host.settle();
  const made = host.requests.find((r) => r.method === "POST" && r.url.endsWith("/admin/api/sessions"));
  const body = JSON.parse(new TextDecoder().decode(made!.body!));
  assert.equal(body.model, "claude-sonnet-5-5");
  assert.equal(body.effort, "high");
  assert.equal(body.preset, "review");

  // None picked: the person's own choice again, never written over by the preset's.
  call(core, ui, 6, "newChat.pick", { scope: "ws", preset: "", presetStation: "" });
  await host.settle();
  apply(host, values);
  assert.equal(v(values, 2).presetModel, false);
  assert.equal(v(values, 2).pick.value.model, "claude-opus-5-5");

  // Its stations: only those it names offered; none of them here, so no chat is made on this one, and it says how.
  call(core, ui, 7, "newChat.pick", { scope: "ws", preset: "far", presetStation: S });
  await host.settle();
  apply(host, values);
  assert.equal(v(values, 2).presetStations, true);
  assert.deepEqual(v(values, 2).stations.map((s: { id: string }) => s.id), ["st"], "the one it is on, held while no other is up");
  call(core, ui, 8, "newChat.pick", { scope: "ws", station: "st" });
  await host.settle();
  assert.match(((answered(8) as { error?: { message: string } }).error?.message) ?? "", /Far/);
  const before = host.requests.length;
  call(core, ui, 9, "newChat.create", { station: S, key: v(values, 2).next });
  await host.settle();
  assert.ok("error" in (answered(9) ?? {}), "refused before anything is asked of the station");
  assert.equal(host.requests.slice(before).filter((r) => r.method === "POST" && r.url.endsWith("/admin/api/sessions")).length, 0);
  core.close();
});

test("a_preset_that_binds_a_model_starts_only_on_stations_that_run_it_never_on_another_model", async () => {
  // `ws/st` (studio) runs Sonnet, `ws/st2` (mini) only Opus, both answering at the same origin: which one a request is
  // for, as the wire says (the user, 2026-11-14: an Argon preset switched to another station ran another model).
  const AT = "x-test-station";
  const wire = (h: FakeHost) => {
    const inner = new HostWire(h);
    return { request: (station: StationAddr, head: RequestHead, body: Uint8Array) => inner.request(station, { ...head, headers: [...head.headers, [AT, station.station]] }, body) } as StationWire;
  };
  const sonnet = { ...profile, id: "p2", name: "p2@x.com", models: ["claude-opus-5-5", "claude-sonnet-5-5"] };
  const bound = {
    id: "review", name: "Code Review", dirs: [], instructions: "", model: { model: "claude-sonnet-5-5", runtime: "claude", effort: "high" },
    createdBy: "a@x.com", createdAt: 1, updatedAt: 1,
  };
  const nowhere = { ...bound, id: "fable", name: "Fable", model: { model: "claude-fable-5-2", runtime: "claude" } };
  const { host, core } = await started({ ...base(), "POST /sessions": { key: "chat:c-new", thread: { id: 9, threadTs: "9.0" } } } as never, 0, wire, (x) => {
    x.cloud.also = { stations: [{ id: "st", name: "studio", online: true, last_seen: null }, { id: "st2", name: "mini", online: true, last_seen: null }] };
    stationReplies(x.host, (req: HttpRequest) => {
      const asked = `${req.method} ${req.url.replace("https://stillfail.test/admin/api", "")}`;
      const mini = req.headers.some(([k, val]) => k === AT && val === "st2");
      if (asked === "GET /overview") return { ...overview, profiles: [mini ? profile : sonnet] };
      if (asked === "GET /presets") return mini ? { presets: [], candidates: [] } : { presets: [bound, nowhere], candidates: [candidate] };
      return undefined;
    });
  });
  const ui = core.connect();
  const values = new Map<number, unknown>();
  const answered = (id: number) => answers(host.takeEmitted(), id) as { error?: { message: string } } | undefined;
  subscribe(core, ui, 1, { topic: "newChat", scope: "ws" });
  await host.time.pass(500);
  await host.settle();
  apply(host, values);
  // On mini before the preset is picked: picking it moves the page to a station that runs its model.
  call(core, ui, 2, "newChat.pick", { scope: "ws", station: "st2" });
  await host.settle();
  apply(host, values);
  assert.equal(v(values, 1).station.id, "st2");
  call(core, ui, 3, "newChat.pick", { scope: "ws", preset: "review", presetStation: S });
  await host.settle();
  apply(host, values);
  assert.equal(v(values, 1).station.id, "st");
  assert.equal(v(values, 1).pick.value.model, "claude-sonnet-5-5");
  // Made again, the page asks each station whether it runs the preset's model of the models it made of that station's
  // overview already, not each made anew (six times a page, a second and more on a phone before its model showed):
  // its own station's alone, as with no preset.
  const made = work.models;
  call(core, ui, 30, "newChat.pick", { scope: "ws", preset: "review", presetStation: S });
  await host.settle();
  apply(host, values);
  assert.equal(work.models - made, 1, "only the station it is on, as the page shows it");
  // Mini is not offered, and asked for it is refused saying why, the page as it was.
  assert.deepEqual(v(values, 1).stations.map((s: { id: string }) => s.id), ["st"]);
  call(core, ui, 4, "newChat.pick", { scope: "ws", station: "st2" });
  await host.settle();
  assert.match(answered(4)?.error?.message ?? "", /Code Review/);
  apply(host, values);
  assert.equal(v(values, 1).station.id, "st");

  // A preset whose model no station runs: the page stays, says so, and makes no chat on another model.
  call(core, ui, 5, "newChat.pick", { scope: "ws", preset: "fable", presetStation: S });
  await host.settle();
  apply(host, values);
  assert.equal(v(values, 1).station.id, "st");
  assert.match(v(values, 1).problem, /Fable/);
  assert.equal(v(values, 1).pick.value.model, "claude-fable-5-2", "its control shows the preset's model, never the station's first");
  const before = host.requests.length;
  call(core, ui, 6, "newChat.create", { station: S, key: v(values, 1).next });
  await host.settle();
  assert.match(answered(6)?.error?.message ?? "", /Fable/);
  assert.equal(host.requests.slice(before).filter((r) => r.method === "POST" && r.url.endsWith("/admin/api/sessions")).length, 0);
  core.close();
});

test("presets_and_jobLog_clear_link_memory_on_same_owner_downgrade_and_do_not_fallback_on_error", async () => {
  const said: Record<string, unknown> = {
    ...base(),
    "GET /overview": { ...overview, profiles: [profile] },
    "GET /presets": { presets: [preset("app", "App")], candidates: [candidate] },
    "GET /jobs/j1/log?lines=200": { text: "secret-log-line\n", outputAt: 1, follows: false },
  };
  const { host, core } = await started(said as never);

  const ui = core.connect();
  const values = new Map<number, unknown>();
  subscribe(core, ui, 1, { topic: "presets", station: S });
  subscribe(core, ui, 2, { topic: "jobLog", station: S, job: "j1", lines: 200 });
  await host.settle();
  apply(host, values);
  assert.deepEqual(v(values, 1).presets.map((p: { id: string }) => p.id), ["app"]);
  assert.equal(v(values, 2).lines[0].runs[0].text, "secret-log-line");

  // Same-owner downgrade bumps workspace authGen while link stays connected:
  // link.memory must clear presets & jobLog synchronously, and 403 on refresh must surface error (never stale cache).
  stationLater(host, (req) => {
    if (req.method === "GET" && (req.url.endsWith("/admin/api/presets") || req.url.includes("/admin/api/jobs/j1/log"))) {
      return Promise.resolve(jsonResponse(403, { error: "forbidden" }));
    }
    return undefined;
  });
  const link = core.inner.stations.link(S);
  assert.ok(link, "station link remains connected on same-owner downgrade");
  assert.equal(link.memory.has(PRESETS), true, "presets was populated in link.memory before downgrade");
  assert.equal(link.memory.has(logKey("j1", 200)), true, "jobLog was populated in link.memory before downgrade");
  host.takeEmitted();
  core.inner.store.authGen.syncWorkspace("ws", "owner:a@x.com:role:restricted");
  assert.equal(link.memory.has(PRESETS), false, "presets must be cleared from link.memory on auth boundary");
  assert.equal(link.memory.has(logKey("j1", 200)), false, "jobLog must be cleared from link.memory on auth boundary");

  core.inner.stations.refreshWorkspace("ws");
  await host.settle();
  const emitted = host.takeEmitted().map(([, m]) => m as { id?: number; value?: unknown; error?: unknown });
  const pMsg = emitted.find((m) => m.id === 1 && m.error !== undefined);
  const lMsg = emitted.find((m) => m.id === 2 && m.error !== undefined);
  assert.ok(pMsg?.error !== undefined, `presets must surface error instead of stale value, got ${JSON.stringify(emitted)}`);
  assert.ok(lMsg?.error !== undefined, `jobLog must surface error instead of stale value, got ${JSON.stringify(emitted)}`);
  core.close();
});

test("unloaded_persisted_jobLog_is_wiped_from_disk_on_same_owner_downgrade_and_sse_clears_old_error", async () => {
  const said: Record<string, unknown> = {
    ...base(),
    "GET /overview": { ...overview, profiles: [profile] },
    "GET /presets": { presets: [preset("app", "App")], candidates: [candidate] },
    "GET /jobs/j-disk/log?lines=200": { text: "fresh-after-downgrade\n", outputAt: 2, follows: false },
  };
  const { host, core, push } = await started(said as never);

  // Persist a jobLog directly to the keeper disk layer WITHOUT loading it into link.memory in-memory map.
  const diskKey = logKey("j-disk", 200);
  core.inner.data.keepStationMemory(S, diskKey, { lines: [{ n: 0, runs: [{ text: "old-disk-secret" }] }], outputAt: 1 });
  assert.ok(core.inner.data.stationMemory(S, diskKey) !== undefined, "seeded persisted jobLog on disk");

  // Same-owner downgrade bumps workspace authGen: disk record must be wiped before any lazy memory.get().
  core.inner.store.authGen.syncWorkspace("ws", "owner:a@x.com:role:restricted");
  assert.equal(core.inner.data.stationMemory(S, diskKey), undefined, "unloaded persisted jobLog must be deleted from disk on auth boundary");
  const link = core.inner.stations.link(S);
  assert.ok(link);
  assert.equal(link.memory.get(diskKey), undefined, "lazy memory.get() must not resurrect old persisted jobLog after downgrade");

  // Verify SSE job-log clears any stale link.errors entry for that jobLog topic and projects the new log.
  const ui = core.connect();
  const values = new Map<number, unknown>();
  stationLater(host, (req) => {
    if (req.method === "GET" && req.url.includes("/admin/api/jobs/j-disk/log")) {
      return Promise.resolve(jsonResponse(403, { error: "forbidden" }));
    }
    return undefined;
  });
  subscribe(core, ui, 1, { topic: "jobLog", station: S, job: "j-disk", lines: 200 });
  await host.settle();
  const errMsgs = host.takeEmitted().map(([, m]) => m as { id?: number; error?: unknown });
  assert.ok(errMsgs.some((m) => m.id === 1 && m.error !== undefined), "initial 403 error recorded");

  push("job-log", { id: "j-disk", lines: 200, text: "sse-live-line\n", outputAt: 3 });
  await host.settle();
  apply(host, values);
  assert.equal(v(values, 1).lines[0].runs[0].text, "sse-live-line", "SSE job-log must clear old error and project new log");
  core.close();
});

test("ephemeral_jobLog_presets_and_coldstart_screens_terminals_authDigest_readonly_and_delayed_seed", async () => {
  // 1. Ephemeral prefixes ([PRESETS, LOG_KEY]) never read from or write to keeper.
  const disk = new Map<string, unknown>([
    [PRESETS, { presets: [preset("ro-old", "RO Old")], candidates: [] }],
    [logKey("j-ro", 200), { lines: [{ n: 0, runs: [{ text: "ro-secret" }] }], outputAt: 1 }],
  ]);
  let writes = 0;
  const readOnlyKeeper: Keeper = {
    read: (k) => disk.get(k),
    write: () => { writes++; },
    bound: () => {},
    now: () => 1000,
    later: () => {},
  };
  const mem = new Memory(readOnlyKeeper, [], [PRESETS, "jobLog\n"]);
  assert.equal(mem.get(PRESETS), undefined, "ephemeral presets must never lazy-load from keeper");
  assert.equal(mem.get(logKey("j-ro", 200)), undefined, "ephemeral jobLog must never lazy-load from keeper");
  mem.set(PRESETS, { presets: [preset("ro-new", "RO New")], candidates: [] });
  mem.set(logKey("j-ro", 200), { lines: [{ n: 0, runs: [{ text: "ro-new-log" }] }], outputAt: 2 });
  assert.equal(writes, 0, "ephemeral keys must never write to keeper");
  const restarted = new Memory(readOnlyKeeper, [], [PRESETS, "jobLog\n"]);
  assert.equal(restarted.get(PRESETS), undefined);
  assert.equal(restarted.get(logKey("j-ro", 200)), undefined);

  // 2. Writable DB cold-start screens/terminals: matching authDigest shows known:true, confirmed:false;
  //    mismatched authDigest or read-only DB returns undefined; deep-link screen.view still calls GET /screens.
  const said: Record<string, unknown> = {
    ...base(),
    "GET /overview": { ...overview, profiles: [profile] },
    "GET /presets": { presets: [preset("app", "App")], candidates: [candidate] },
    "GET /screens": { screens: [{ id: "desktop", kind: "desktop", title: "Main", width: 1280, height: 800, viewers: [], controlledBy: [] }], browser: true },
    "GET /terminals": { terminals: [{ id: "t-1", by: "a@x.com", cwd: "/tmp", at: 1, looking: [] }] },
  };
  const { host, core } = await started(said as never);
  const link = core.inner.stations.link(S);
  assert.ok(link);
  const curDigest = core.inner.store.authGen.workspaceDigest("ws");
  assert.ok(typeof curDigest === "string" && curDigest.length > 0);

  // Matching authDigest + matching non-denied capRev on writable DB -> known:true, confirmed:false.
  const sRev = ((core.inner.data.device.get("auth", `capRev:${S}:screens`) as { rev?: number } | undefined)?.rev ?? 0) + 1;
  const tRev = ((core.inner.data.device.get("auth", `capRev:${S}:terminals`) as { rev?: number } | undefined)?.rev ?? 0) + 1;
  core.inner.data.device.put("auth", `capRev:${S}:screens`, { rev: sRev, denied: false });
  core.inner.data.device.put("auth", `capRev:${S}:terminals`, { rev: tRev, denied: false });
  link.memory.deletePrefix("screens");
  link.memory.deletePrefix("terminals");
  core.inner.data.keepStationMemory(S, "screens", { screens: [{ id: "desktop", kind: "desktop", title: "Cached", width: 800, height: 600, viewers: [], controlledBy: [] }], outdated: false, authDigest: curDigest, capRev: sRev });
  core.inner.data.keepStationMemory(S, "terminals", { terminals: [{ id: "t-cached", by: "a@x.com", cwd: "/old", at: 1, looking: [] }], outdated: false, authDigest: curDigest, capRev: tRev });
  assert.equal(core.inner.stations.isConfirmed("screens", S), false);
  assert.equal(core.inner.stations.isConfirmed("terminals", S), false);
  assert.equal((core.inner.stations.screens(S)?.screens[0] as { title?: string })?.title, "Cached");
  assert.equal((core.inner.stations.terminals(S)?.terminals[0] as { id?: string })?.id, "t-cached");

  // Read-only DB: even with matching authDigest, unconfirmed cold-start rows MUST return undefined.
  const db = core.inner.data.of(S);
  assert.ok(db);
  (db as { readOnly: boolean }).readOnly = true;
  assert.equal(core.inner.data.isStationWritable(S), false);
  assert.equal(core.inner.stations.screens(S), undefined, "read-only DB must never resurrect unconfirmed screens even with matching authDigest");
  assert.equal(core.inner.stations.terminals(S), undefined, "read-only DB must never resurrect unconfirmed terminals even with matching authDigest");
  (db as { readOnly: boolean }).readOnly = false;
  assert.equal(core.inner.data.isStationWritable(S), true);

  // Deep-link screen.view on cold-start cached (unconfirmed) screen MUST still call GET /screens first;
  // if GET /screens returns 403, fail closed with phase: "denied" and 0 screenView attempts (and wipe disk row).
  let link403 = true;
  stationLater(host, (req) => {
    if (link403 && req.method === "GET" && req.url.endsWith("/admin/api/screens")) {
      return Promise.resolve(jsonResponse(403, { error: "forbidden" }));
    }
    return undefined;
  });
  const ui = core.connect();
  const values = new Map<number, unknown>();
  subscribe(core, ui, 1, { topic: "screens", station: S });
  subscribe(core, ui, 2, { topic: "terminals", station: S });
  subscribe(core, ui, 3, { topic: "presets", station: S });
  await host.settle();
  apply(host, values);
  assert.equal(v(values, 1).known, true, "cold-start writable DB shows cached screens for display");
  assert.equal(v(values, 1).confirmed, false, "cold-start cached screens stay confirmed: false");

  const beforeDeepLinkReqs = host.requests.length;
  host.takeEmitted();
  call(core, ui, 91, "screen.view", { station: S, screen: "desktop", view: "v-deeplink", codecs: ["jpeg"] });
  await host.settle();
  const deepLinkMsgs = host.takeEmitted().map(([, m]) => m as { id?: number; value?: { state?: { phase?: string } } });
  assert.ok(deepLinkMsgs.some((m) => m.id === 91 && m.value?.state?.phase === "denied"), "deep-link screen.view must confirm via GET /screens and fail closed on 403");
  const deepLinkReqs = host.requests.slice(beforeDeepLinkReqs);
  assert.ok(deepLinkReqs.some((r) => r.method === "GET" && r.url.endsWith("/admin/api/screens")), "deep-link screen.view must issue GET /screens when unconfirmed");
  assert.equal(deepLinkReqs.filter((r) => r.url.includes("/screens/")).length, 0, "must not open screenView stream after 403");
  assert.equal(core.inner.data.stationMemory(S, "screens"), undefined, "403 on writable DB must wipe screens from disk so restart never resurrects");
  link403 = false;

  // Non-downgrade auth boundary re-fetches active screens/terminals/presets and restores confirmed: true.
  const beforeReqs = host.requests.length;
  core.inner.store.authGen.syncWorkspace("ws", "owner:a@x.com:trusted:1");
  await host.settle();
  apply(host, values);
  const afterUrls = host.requests.slice(beforeReqs).map((r) => `${r.method} ${r.url}`);
  assert.ok(afterUrls.some((u) => u.endsWith("/admin/api/screens")));
  assert.ok(afterUrls.some((u) => u.endsWith("/admin/api/terminals")));
  assert.ok(afterUrls.some((u) => u.endsWith("/admin/api/presets")));
  assert.equal(v(values, 1).confirmed, true);
  assert.equal(v(values, 2).confirmed, true);
  assert.equal(v(values, 3).presets[0].id, "app");
  core.close();

  // 3. Opus P1: delayed workspaceDigest seeding after initial cold-start compute automatically re-computes screens/terminals to known:true, confirmed:false.
  const { host: h2, core: c2 } = await started(said as never);
  const link2 = c2.inner.stations.link(S);
  assert.ok(link2);
  // Simulate cold start before workspaceDigest is seeded for a fresh workspace "ws-late":
  const S2 = "ws-late/st";
  const lateAuth = c2.inner.store.authGen;
  let seededCalls = 0;
  const unsub = lateAuth.onWorkspaceDigestSeeded((ws) => {
    if (ws === "ws-late") seededCalls++;
  });
  assert.equal(lateAuth.syncWorkspace("ws-late", "owner:a@x.com:role:admin"), false, "first seed must not bump authGen");
  assert.equal(seededCalls, 1, "first seed must notify onWorkspaceDigestSeeded");
  assert.equal(lateAuth.syncWorkspace("ws-late", "owner:a@x.com:role:admin"), false, "identical digest must not re-notify");
  assert.equal(seededCalls, 1);
  unsub();

  // Verify StationsSync re-notifies screens/terminals topics when workspaceDigest is seeded late.
  const ui2 = c2.connect();
  const vals2 = new Map<number, unknown>();
  // Force a fresh unseeded digest state by syncing a second station's workspace via onWorkspaceDigestSeeded hook:
  const onChangeHits: string[] = [];
  const origOnChange = c2.inner.stations.onChange.bind(c2.inner.stations);
  c2.inner.stations.onChange = (addr, what) => {
    onChangeHits.push(`${addr}:${what}`);
    origOnChange(addr, what);
  };
  assert.equal(lateAuth.syncWorkspace("ws-late2", "owner:a@x.com:role:admin"), false);
  // Seeded workspace with no links does not emit spurious onChange for S:
  assert.equal(onChangeHits.filter((x) => x.startsWith(`${S}:`)).length, 0);
  // Restore and verify link2 with matching digest + capRev after seed computes known:true, confirmed:false:
  c2.inner.stations.onChange = origOnChange;
  const sRev2 = ((c2.inner.data.device.get("auth", `capRev:${S}:screens`) as { rev?: number } | undefined)?.rev ?? 0) + 1;
  c2.inner.data.device.put("auth", `capRev:${S}:screens`, { rev: sRev2, denied: false });
  link2.memory.deletePrefix("screens");
  c2.inner.data.keepStationMemory(S, "screens", { screens: [{ id: "desktop", kind: "desktop", title: "LateSeed", width: 800, height: 600, viewers: [], controlledBy: [] }], outdated: false, authDigest: c2.inner.store.authGen.workspaceDigest("ws"), capRev: sRev2 });
  subscribe(c2, ui2, 1, { topic: "screens", station: S });
  await h2.settle();
  apply(h2, vals2);
  assert.equal(v(vals2, 1).known, true);
  assert.equal(v(vals2, 1).confirmed, false);
  assert.equal(v(vals2, 1).screens[0].title, "LateSeed");
  assert.equal(S2.startsWith("ws-late/"), true);
  c2.close();
});

test("same_gen_sse_beats_older_inflight_get_and_403_clears_screens_terminals_confirmation", async () => {
  const said: Record<string, unknown> = {
    ...base(),
    "GET /overview": { ...overview, profiles: [profile] },
    "GET /screens": { screens: [{ id: "desktop", kind: "desktop", title: "Main", width: 1280, height: 800, viewers: [], controlledBy: [] }], browser: true },
    "GET /terminals": { terminals: [{ id: "t-1", by: "a@x.com", cwd: "/tmp", at: 1, looking: [] }] },
  };
  const { host, core, push } = await started(said as never);
  const ui = core.connect();
  const values = new Map<number, unknown>();
  subscribe(core, ui, 1, { topic: "terminals", station: S });
  await host.settle();
  apply(host, values);
  assert.equal(v(values, 1).confirmed, true);
  assert.deepEqual(v(values, 1).terminals.map((t: { id: string }) => t.id), ["t-1"]);

  // 1. Start a slow GET /terminals returning stale t-1; while in flight, SSE reports t-1 ended (empty list).
  let releaseStale!: (r: ReturnType<typeof jsonResponse>) => void;
  const staleGate = new Promise<ReturnType<typeof jsonResponse>>((resolve) => { releaseStale = resolve; });
  let interceptMode: "stale" | "forbidden" | "none" = "stale";
  stationLater(host, (req) => {
    if (req.method === "GET" && req.url.endsWith("/admin/api/terminals")) {
      if (interceptMode === "stale") {
        interceptMode = "none";
        return staleGate;
      }
      if (interceptMode === "forbidden") {
        interceptMode = "none";
        return Promise.resolve(jsonResponse(403, { error: "forbidden" }));
      }
    }
    return undefined;
  });

  // Trigger a same-gen snapshot which starts slow GET /terminals in the same auth generation as the active SSE stream.
  core.inner.stations.snapshot(S);
  await host.settle();
  // Newer SSE arrives in the same generation with empty terminals list.
  push("terminals", { terminals: [] });
  await host.settle();
  apply(host, values);
  assert.equal(v(values, 1).confirmed, true);
  assert.deepEqual(v(values, 1).terminals, [], "SSE updates terminals to empty");

  // Release the older in-flight GET: its seq is behind SSE, so it MUST be dropped and not resurrect t-1.
  releaseStale(jsonResponse(200, { terminals: [{ id: "t-1", by: "a@x.com", cwd: "/tmp", at: 1, looking: [] }] }));
  await host.settle();
  apply(host, values);
  assert.deepEqual(v(values, 1).terminals, [], "stale in-flight GET must not overwrite newer SSE");

  // 2. 403 on GET /terminals immediately clears confirmed state and stale rows.
  push("terminals", { terminals: [{ id: "t-2", by: "a@x.com", cwd: "/tmp", at: 2, looking: [] }] });
  await host.settle();
  apply(host, values);
  assert.equal(v(values, 1).confirmed, true);
  assert.equal(v(values, 1).terminals.length, 1);

  interceptMode = "forbidden";
  core.inner.stations.snapshot(S);
  await host.settle();
  apply(host, values);
  assert.equal(v(values, 1).confirmed, false, "403 must clear confirmed state");
  assert.equal(v(values, 1).denied, true, "403 must project denied: true");
  assert.deepEqual(v(values, 1).terminals, [], "403 must clear stale terminal rows");

  // 3. When GET /screens returns 403, screen.view fails closed with phase "denied" and never opens a screenView stream.
  let screensForbidden = true;
  stationLater(host, (req) => {
    if (screensForbidden && req.method === "GET" && req.url.endsWith("/admin/api/screens")) {
      return Promise.resolve(jsonResponse(403, { error: "forbidden" }));
    }
    return undefined;
  });
  core.inner.stations.snapshot(S);
  await host.settle();
  assert.equal(core.inner.stations.isDenied("screens", S), true, "403 on GET /screens marks screens denied");
  const beforeStreamReqs = host.requests.length;
  host.takeEmitted();
  call(core, ui, 99, "screen.view", { station: S, screen: "desktop", view: "v-denied", codecs: ["jpeg"] });
  await host.settle();
  const emitted = host.takeEmitted().map(([, m]) => m as { id?: number; value?: { state?: { phase?: string } } });
  assert.ok(emitted.some((m) => m.id === 99 && m.value?.state?.phase === "denied"), "screen.view must report phase: denied");
  const streamReqs = host.requests.slice(beforeStreamReqs).filter((r) => r.url.includes("/screens/"));
  assert.equal(streamReqs.length, 0, "screen.view must not open a screen stream when screens is denied");
  screensForbidden = false;
  core.close();
});

test("screenGone_advances_seq_even_when_absent_and_reconnecting_screen_view_aborts_on_403", async () => {
  const said: Record<string, unknown> = {
    ...base(),
    "GET /overview": { ...overview, profiles: [profile] },
    "GET /screens": { screens: [{ id: "desktop", kind: "desktop", title: "Main", width: 1280, height: 800, viewers: [], controlledBy: [] }, { id: "browser:u_1", kind: "browser", title: "Tab 1", userTab: true, width: 1280, height: 800, viewers: [], controlledBy: [] }], browser: true },
    "GET /terminals": { terminals: [] },
    "POST /screens/browser%3Au_1/close": { ok: true },
  };
  let streamAttempts = 0;
  const wireFactory = (h: FakeHost): StationWire =>
    Object.assign(new HostWire(h), {
      screen: () => {
        streamAttempts++;
        return Effect.fail(new CoreError("network", "transient drop"));
      },
    });
  const { host, core } = await started(said as never, 0, wireFactory);
  const ui = core.connect();
  const values = new Map<number, unknown>();
  subscribe(core, ui, 1, { topic: "screens", station: S });
  await host.settle();
  apply(host, values);
  assert.equal(v(values, 1).confirmed, true);

  // 1. Start a slow GET /screens returning stale browser:u_1; meanwhile close browser:u_1 (even if already absent locally).
  let releaseStaleScreens!: (r: ReturnType<typeof jsonResponse>) => void;
  const staleScreensGate = new Promise<ReturnType<typeof jsonResponse>>((resolve) => { releaseStaleScreens = resolve; });
  let screensMode: "stale" | "forbidden" | "none" = "stale";
  stationLater(host, (req) => {
    if (req.method === "GET" && req.url.endsWith("/admin/api/screens")) {
      if (screensMode === "stale") {
        screensMode = "none";
        return staleScreensGate;
      }
      if (screensMode === "forbidden") {
        screensMode = "none";
        return Promise.resolve(jsonResponse(403, { error: "forbidden" }));
      }
    }
    return undefined;
  });

  // Clear local screens memory so screenGone sees !changed (absent), then start stale GET and call screen.close.
  core.inner.stations.snapshot(S);
  await host.settle();
  core.inner.stations.link(S)?.memory.deletePrefix("screens");
  call(core, ui, 50, "screen.close", { station: S, screen: "browser:u_1" });
  await host.settle();

  // Release the older in-flight GET: #screensWithout unconditionally bumped #screensSeq, so stale GET must be dropped.
  releaseStaleScreens(jsonResponse(200, {
    screens: [
      { id: "desktop", kind: "desktop", title: "Main", width: 1280, height: 800, viewers: [], controlledBy: [] },
      { id: "browser:u_1", kind: "browser", title: "Tab 1", userTab: true, width: 1280, height: 800, viewers: [], controlledBy: [] },
    ],
    browser: true,
  }));
  await host.settle();
  apply(host, values);
  assert.equal(core.inner.stations.screens(S), undefined, "older in-flight GET /screens must be dropped after screenGone even when local list was absent");

  // 2. Active screen.view in reconnect backoff receives 403 on GET /screens:
  //    must immediately abort to phase: "denied" and emit zero further screenView stream requests.
  core.inner.stations.snapshot(S);
  await host.settle();
  apply(host, values);
  assert.equal(v(values, 1).confirmed, true);

  host.takeEmitted();
  call(core, ui, 88, "screen.view", { station: S, screen: "desktop", view: "v-reconn", codecs: ["jpeg"] });
  await host.settle();
  assert.equal(streamAttempts, 1, "initial screenView attempt made before backoff");

  // While viewer is sleeping in reconnect backoff, GET /screens returns 403.
  screensMode = "forbidden";
  core.inner.stations.snapshot(S);
  await host.settle();
  const emittedAfter403 = host.takeEmitted().map(([, m]) => m as { id?: number; value?: { state?: { phase?: string } } });
  assert.ok(emittedAfter403.some((m) => m.id === 88 && m.value?.state?.phase === "denied"), "reconnecting screen.view must abort immediately to phase: denied on 403");

  // Advance clock past all reconnect backoff windows: zero additional screenView stream requests may fire.
  await host.time.pass(60_000, 1_000);
  assert.equal(streamAttempts, 1, "denied screen.view must never issue further screenView requests after 403");
  core.close();
});

test("screenGone_does_not_swallow_inflight_403_and_inflight_handshakes_abort_cleanly_on_403", async () => {
  const said: Record<string, unknown> = {
    ...base(),
    "GET /overview": { ...overview, profiles: [profile] },
    "GET /screens": { screens: [{ id: "desktop", kind: "desktop", title: "Main", width: 1280, height: 800, viewers: [], controlledBy: [] }, { id: "browser:u_1", kind: "browser", title: "Tab 1", userTab: true, width: 1280, height: 800, viewers: [], controlledBy: [] }], browser: true },
    "GET /terminals": { terminals: [] },
    "POST /screens/browser%3Au_1/close": { ok: true },
  };
  let handshakeMode: "hang" | "open-then-hang-reopen" = "hang";
  let firstCanceled = 0;
  let reopenCanceled = 0;
  let screenCalls = 0;
  const wireFactory = (h: FakeHost): StationWire =>
    Object.assign(new HostWire(h), {
      screen: () => {
        screenCalls++;
        if (handshakeMode === "hang") {
          return Effect.gen(function* () {
            yield* Effect.addFinalizer(() => Effect.sync(() => { firstCanceled++; }));
            return yield* Effect.never;
          });
        }
        // open-then-hang-reopen: 1st call returns an open socket; 2nd call (reopen) hangs in its own scope.
        if (screenCalls === 2) {
          return Effect.gen(function* () {
            const q = yield* Queue.unbounded<Uint8Array | null>();
            return {
              reply: { status: 200, headers: [["content-type", "application/x-stillfail-screen"]] as [string, string][], body: { take: Queue.take(q) }, via: null },
              send: { write: () => Effect.void, finish: () => {} },
            };
          });
        }
        return Effect.gen(function* () {
          yield* Effect.addFinalizer(() => Effect.sync(() => { reopenCanceled++; }));
          return yield* Effect.never;
        });
      },
    });
  const { host, core, push } = await started(said as never, 0, wireFactory);
  const ui = core.connect();
  const values = new Map<number, unknown>();
  subscribe(core, ui, 1, { topic: "screens", station: S });
  await host.settle();
  apply(host, values);
  assert.equal(v(values, 1).confirmed, true);

  // 1. Astra r9 P1-1: screenGone during in-flight GET /screens must NOT swallow an in-flight 403.
  let releaseInflight!: (r: ReturnType<typeof jsonResponse>) => void;
  let activeGate = new Promise<ReturnType<typeof jsonResponse>>((resolve) => { releaseInflight = resolve; });
  let interceptScreens: "gate" | "403" | "none" = "gate";
  let releaseOpenBrowser: ((r: ReturnType<typeof jsonResponse>) => void) | null = null;
  let openBrowserGate: Promise<ReturnType<typeof jsonResponse>> | null = null;
  stationLater(host, (req) => {
    if (req.method === "GET" && req.url.endsWith("/admin/api/screens")) {
      if (interceptScreens === "gate") {
        interceptScreens = "none";
        return activeGate;
      }
      if (interceptScreens === "403") {
        interceptScreens = "none";
        return Promise.resolve(jsonResponse(403, { error: "forbidden" }));
      }
    }
    if (openBrowserGate !== null && req.method === "POST" && req.url.endsWith("/admin/api/screens/browser")) {
      return openBrowserGate;
    }
    return undefined;
  });
  core.inner.stations.snapshot(S);
  await host.settle();
  // Local optimistic screenGone advances #screensSeq (NOT #screensConfirmSeq).
  call(core, ui, 60, "screen.close", { station: S, screen: "browser:u_1" });
  await host.settle();
  // In-flight GET /screens answers 403: must take effect (not swallowed by screenGone).
  releaseInflight(jsonResponse(403, { error: "forbidden" }));
  await host.settle();
  apply(host, values);
  assert.equal(core.inner.stations.isDenied("screens", S), true, "403 must take effect even after screenGone advanced #screensSeq");
  assert.equal(v(values, 1).denied, true);
  assert.equal(v(values, 1).confirmed, false);

  // Verify newer station-confirmed SSE DOES suppress an older in-flight 403.
  let releaseOld403!: (r: ReturnType<typeof jsonResponse>) => void;
  activeGate = new Promise<ReturnType<typeof jsonResponse>>((resolve) => { releaseOld403 = resolve; });
  interceptScreens = "gate";
  core.inner.stations.snapshot(S);
  await host.settle();
  // Newer SSE arrives with confirmed screens (bumps #screensConfirmSeq).
  push("screens", { screens: [{ id: "desktop", kind: "desktop", title: "Main", width: 1280, height: 800, viewers: [], controlledBy: [] }], browser: true });
  await host.settle();
  apply(host, values);
  assert.equal(v(values, 1).confirmed, true);
  // Older in-flight 403 arrives late: must be ignored because #screensConfirmSeq advanced.
  releaseOld403(jsonResponse(403, { error: "stale forbidden" }));
  await host.settle();
  apply(host, values);
  assert.equal(core.inner.stations.isDenied("screens", S), false, "older 403 must not override newer station confirmation");
  assert.equal(v(values, 1).confirmed, true);

  // 2. Astra r9 P1-2 (first handshake): in-flight requests.screenView is canceled immediately on GET /screens 403.
  handshakeMode = "hang";
  host.takeEmitted();
  call(core, ui, 71, "screen.view", { station: S, screen: "desktop", view: "v-hang1", codecs: ["jpeg"] });
  await host.settle();
  assert.equal(screenCalls, 1);
  assert.equal(firstCanceled, 0);
  interceptScreens = "403";
  core.inner.stations.snapshot(S);
  await host.settle();
  const msgs1 = host.takeEmitted().map(([, m]) => m as { id?: number; value?: { state?: { phase?: string } } });
  assert.ok(msgs1.some((m) => m.id === 71 && m.value?.state?.phase === "denied"), "in-flight first handshake must transition to phase: denied on 403");
  assert.equal(firstCanceled, 1, "in-flight first handshake fiber/scope must be canceled on 403");

  // 3. Astra r9 P1-2 (replacement handshake): reopen scope is closed cleanly when 403 arrives mid-reopen.
  push("screens", { screens: [{ id: "desktop", kind: "desktop", title: "Main", width: 1280, height: 800, viewers: [], controlledBy: [] }], browser: true });
  await host.settle();
  handshakeMode = "open-then-hang-reopen";
  host.takeEmitted();
  call(core, ui, 72, "screen.view", { station: S, screen: "desktop", view: "v-reopen", codecs: ["jpeg"], control: false });
  await host.settle();
  assert.equal(screenCalls, 2);
  // Trigger replacement handshake via screen.control(true)
  call(core, ui, 73, "screen.control", { view: "v-reopen", control: true });
  await host.settle();
  assert.equal(screenCalls, 3, "replacement handshake started");
  assert.equal(reopenCanceled, 0);
  // 403 arrives while replacement handshake is pending: replacement scope MUST be closed and view must enter phase: denied.
  interceptScreens = "403";
  core.inner.stations.snapshot(S);
  await host.settle();
  const msgs2 = host.takeEmitted().map(([, m]) => m as { id?: number; value?: { state?: { phase?: string } } });
  assert.ok(msgs2.some((m) => m.id === 72 && m.value?.state?.phase === "denied"), "replacement handshake must abort to phase: denied on 403");
  assert.equal(reopenCanceled, 1, "replacement handshake scope must be closed with zero leak on 403");

  // 4. Astra r9 P1-2 (opening wait loop): 403 while waiting for an opening tab aborts immediately with 0 screenView calls.
  const callsBeforeOpening = screenCalls;
  openBrowserGate = new Promise<ReturnType<typeof jsonResponse>>((resolve) => { releaseOpenBrowser = resolve; });
  push("screens", { screens: [{ id: "desktop", kind: "desktop", title: "Main", width: 1280, height: 800, viewers: [], controlledBy: [] }], browser: true });
  await host.settle();
  call(core, ui, 74, "screen.openBrowser", { station: S, url: "https://example.com", id: "u_0123456789ab" });
  await host.settle();
  host.takeEmitted();
  call(core, ui, 75, "screen.view", { station: S, screen: "browser:u_0123456789ab", view: "v-opening", codecs: ["jpeg"] });
  await host.settle();
  interceptScreens = "403";
  core.inner.runner.fork(core.inner.stations.readScreens(S));
  await host.settle();
  assert.equal(core.inner.stations.isDenied("screens", S), true, "readScreens GET /screens 403 must set isDenied");
  const msgs3 = host.takeEmitted().map(([, m]) => m as { id?: number; value?: { state?: { phase?: string } } });
  assert.ok(msgs3.some((m) => m.id === 75 && m.value?.state?.phase === "denied"), `opening wait loop must abort to phase: denied on 403, got: ${JSON.stringify(msgs3)}`);
  assert.equal(screenCalls, callsBeforeOpening, "opening wait loop must not invoke screenView after 403");
  releaseOpenBrowser!(jsonResponse(200, { id: "browser:u_0123456789ab" }));
  await host.settle();
  assert.equal(Deferred !== undefined, true);
  core.close();
});

test("r11_capRev_survives_readonly_403_restart_and_500_deeplink_and_tap_abort_and_live_digest_seed", async () => {
  // 1. Live active subscription transitions automatically from known:false -> known:true, confirmed:false when workspaceDigest is seeded late.
  const said: Record<string, unknown> = {
    ...base(),
    "GET /overview": { ...overview, profiles: [profile] },
    "GET /screens": { screens: [{ id: "desktop", kind: "desktop", title: "DiskCached", width: 1280, height: 800, viewers: [], controlledBy: [] }], browser: true },
    "GET /terminals": { terminals: [{ id: "t-disk", by: "a@x.com", cwd: "/tmp", at: 1, looking: [] }] },
  };
  const first = await started(said as never);
  const firstDigest = first.core.inner.store.authGen.workspaceDigest("ws");
  assert.ok(firstDigest);
  await first.host.time.pass(KEEP_MS + 1_000, 1_000);
  await Effect.runPromise(first.core.inner.data.written);
  await Effect.runPromise(first.core.inner.data.device.flushTable("auth"));
  first.core.close();

  // Restart with network blocked and personal-lock storage reads delayed so workspaceDigest is NOT seeded yet on initial subscribe.
  const host = first.host;
  host.onFetch(() => new Promise(() => {}));
  host.onFetchStream(() => Effect.never);
  host.takeEmitted();
  const lockGate = Deferred.makeUnsafe<void>();
  const origStorageGet = host.storageGet.bind(host);
  host.storageGet = (k) =>
    k.startsWith("personal-lock-")
      ? Effect.andThen(Deferred.await(lockGate), origStorageGet(k))
      : origStorageGet(k);
  const cold = await Core.create(host, { clock: host.time.clock, sample: 0 });
  assert.equal(cold.inner.store.authGen.hasWorkspaceDigest("ws"), false, "cold start before personal-lock loads must not have workspaceDigest seeded yet");
  const coldUi = cold.connect();
  const coldVals = new Map<number, unknown>();
  subscribe(cold, coldUi, 1, { topic: "screens", station: S });
  subscribe(cold, coldUi, 2, { topic: "terminals", station: S });
  await host.time.pass(100, 10);
  apply(host, coldVals);
  assert.equal(v(coldVals, 1).known, false, "unseeded workspaceDigest MUST start as known: false");
  assert.equal(v(coldVals, 2).known, false, "unseeded workspaceDigest MUST start as known: false");
  // Release personal-lock load so Core naturally seeds workspaceDigest -> onWorkspaceDigestSeeded recomputes active subscriptions.
  Deferred.doneUnsafe(lockGate, Effect.void);
  host.storageGet = origStorageGet;
  await host.settle();
  apply(host, coldVals);
  assert.equal(cold.inner.store.authGen.hasWorkspaceDigest("ws"), true, "workspaceDigest seeded after personal-lock loads");
  assert.equal(v(coldVals, 1).known, true, "once workspaceDigest is seeded, active screens subscription auto-recomputes to known: true");
  assert.equal(v(coldVals, 1).confirmed, false);
  assert.equal(v(coldVals, 2).known, true, "once workspaceDigest is seeded, active terminals subscription auto-recomputes to known: true");
  assert.equal(v(coldVals, 2).confirmed, false);
  cold.close();

  // 2. Read-only DB receives 403 -> capRev watermark flushed to device/auth -> reopen same DB as WRITABLE -> still known: false (no resurrection!).
  const roRun = await started(said as never);
  await roRun.host.time.pass(KEEP_MS + 1_000, 1_000);
  await Effect.runPromise(roRun.core.inner.data.written);
  await Effect.runPromise(roRun.core.inner.data.device.flushTable("auth"));
  const roDb = roRun.core.inner.data.of(S);
  assert.ok(roDb);
  // Flip account DB readOnly during 403 so AccountDb cannot delete the row, while device/auth records capRev denied:true.
  (roDb as { readOnly: boolean }).readOnly = true;
  let force403 = true;
  stationLater(roRun.host, (req) => {
    if (force403 && req.method === "GET" && req.url.endsWith("/admin/api/screens")) {
      return Promise.resolve(jsonResponse(403, { error: "forbidden" }));
    }
    return undefined;
  });
  roRun.core.inner.runner.fork(roRun.core.inner.stations.readScreens(S));
  await roRun.host.settle();
  assert.equal(roRun.core.inner.stations.isDenied("screens", S), true);
  force403 = false;
  (roDb as { readOnly: boolean }).readOnly = false;
  roRun.core.close();

  // Reopen a brand new Core on the SAME host (writable AccountDb still has the old row on disk, device/auth has capRev denied:true):
  roRun.host.onFetch(() => new Promise(() => {}));
  roRun.host.onFetchStream(() => Effect.never);
  roRun.host.takeEmitted();
  const reopened = await Core.create(roRun.host, { clock: roRun.host.time.clock, sample: 0 });
  const rUi = reopened.connect();
  const rVals = new Map<number, unknown>();
  subscribe(reopened, rUi, 1, { topic: "screens", station: S });
  await roRun.host.time.pass(200, 10);
  apply(roRun.host, rVals);
  assert.equal(v(rVals, 1).known, false, "writable restart after read-only 403 must NOT resurrect screens because device/auth capRev is denied");
  assert.equal(v(rVals, 1).confirmed, false);
  reopened.close();

  // 3. Deep-link screen.view on cold-start cached screen + GET /screens returns 500 -> reconnecting with 0 screenView calls.
  let svCalls = 0;
  let tapCanceled = 0;
  let wireMode: "count" | "hang-tap" = "count";
  const wireFactory = (h: FakeHost): StationWire =>
    Object.assign(new HostWire(h), {
      screen: () => {
        svCalls++;
        if (wireMode === "hang-tap") {
          return Effect.gen(function* () {
            yield* Effect.addFinalizer(() => Effect.sync(() => { tapCanceled++; }));
            const q = yield* Queue.unbounded<Uint8Array | null>();
            return {
              reply: { status: 200, headers: [["content-type", "application/x-stillfail-screen"]] as [string, string][], body: { take: Queue.take(q) }, via: null },
              send: { write: () => Effect.void, finish: () => {} },
              tap: () => Effect.never,
            };
          });
        }
        return Effect.fail(new CoreError("network", "should not be called"));
      },
    });
  const dl = await started(said as never, 0, wireFactory);
  const dlLink = dl.core.inner.stations.link(S);
  assert.ok(dlLink);
  const dlDigest = dl.core.inner.store.authGen.workspaceDigest("ws");
  const dlRev = ((dl.core.inner.data.device.get("auth", `capRev:${S}:screens`) as { rev?: number } | undefined)?.rev ?? 0) + 1;
  dl.core.inner.data.device.put("auth", `capRev:${S}:screens`, { rev: dlRev, denied: false });
  dlLink.memory.deletePrefix("screens");
  dl.core.inner.data.keepStationMemory(S, "screens", { screens: [{ id: "desktop", kind: "desktop", title: "Cached500", width: 800, height: 600, viewers: [], controlledBy: [] }], outdated: false, authDigest: dlDigest, capRev: dlRev });
  let screensStatus: 500 | 403 | 200 = 500;
  stationLater(dl.host, (req) => {
    if (req.method === "GET" && req.url.endsWith("/admin/api/screens")) {
      if (screensStatus === 500) return Promise.resolve(jsonResponse(500, { error: "temp error" }));
      if (screensStatus === 403) return Promise.resolve(jsonResponse(403, { error: "forbidden" }));
    }
    return undefined;
  });
  const dlUi = dl.core.connect();
  dl.host.takeEmitted();
  call(dl.core, dlUi, 81, "screen.view", { station: S, screen: "desktop", view: "v-500", codecs: ["jpeg"] });
  await dl.host.settle();
  const msgs500 = dl.host.takeEmitted().map(([, m]) => m as { id?: number; value?: { state?: { phase?: string } } });
  assert.ok(msgs500.some((m) => m.id === 81 && m.value?.state?.phase === "reconnecting"), `500 on unconfirmed deep-link must enter reconnecting, got: ${JSON.stringify(msgs500)}`);
  assert.equal(svCalls, 0, "must never call requests.screenView while GET /screens fails with 500");
  dl.core.receive(dlUi, { kind: "cancel", id: 81, cancel: true });
  await dl.host.settle();

  // 4. Astra P1-3: socket.tap hanging when GET /screens returns 403 -> immediately interrupts runBody, closes socket scope, enters phase: "denied".
  screensStatus = 200;
  dl.core.inner.runner.fork(dl.core.inner.stations.readScreens(S));
  await dl.host.settle();
  assert.equal(dl.core.inner.stations.isConfirmed("screens", S), true);
  wireMode = "hang-tap";
  dl.host.takeEmitted();
  call(dl.core, dlUi, 82, "screen.view", { station: S, screen: "desktop", view: "v-tap", codecs: ["jpeg"] });
  await dl.host.settle();
  assert.equal(svCalls, 1, "screenView opened and now hanging inside socket.tap");
  assert.equal(tapCanceled, 0);
  screensStatus = 403;
  dl.core.inner.runner.fork(dl.core.inner.stations.readScreens(S));
  await dl.host.settle();
  const msgsTap = dl.host.takeEmitted().map(([, m]) => m as { id?: number; value?: { state?: { phase?: string } } });
  assert.ok(msgsTap.some((m) => m.id === 82 && m.value?.state?.phase === "denied"), `403 during socket.tap must enter phase: denied, got: ${JSON.stringify(msgsTap)}`);
  assert.equal(tapCanceled, 1, "socket scope must be closed immediately when 403 interrupts socket.tap");
  dl.core.close();
});

test("r12_pure_revocation_capRev_sync_403_multicore_merge_503_retry_and_reopen_handoff_zero_leak", async () => {
  const said: Record<string, unknown> = {
    ...base(),
    "GET /overview": { ...overview, profiles: [profile] },
    "GET /screens": { screens: [{ id: "desktop", kind: "desktop", title: "Main", width: 1280, height: 800, viewers: [], controlledBy: [] }], browser: true },
    "GET /terminals": { terminals: [{ id: "t-1", by: "a@x.com", cwd: "/tmp", at: 1, looking: [] }] },
  };

  // 1. Opus P1: repeated SSE confirmations do NOT bump capRev or write device/auth, and cold start still shows known:true, confirmed:false.
  const first = await started(said as never);
  const authBefore = first.core.inner.data.device.get("auth", `capRev:${S}:screens`);
  assert.equal(authBefore, undefined, "normal confirmation must not write capRev to device/auth");
  await first.host.time.pass(KEEP_MS + 1_000, 1_000);
  await Effect.runPromise(first.core.inner.data.written);
  // Burst of SSE updates within KEEP_MS throttle window: disk row stays at capRev=0, device/auth stays untouched.
  for (let i = 0; i < 5; i++) {
    first.push("screens", { screens: [{ id: "desktop", kind: "desktop", title: `Live-${i}`, width: 1280, height: 800, viewers: [], controlledBy: [] }], browser: true });
  }
  await first.host.settle();
  assert.equal(first.core.inner.data.device.get("auth", `capRev:${S}:screens`), undefined, "repeated confirmations must never write device/auth");
  const digest1 = first.core.inner.store.authGen.workspaceDigest("ws")!;
  first.core.close();

  first.host.onFetch(() => new Promise(() => {}));
  first.host.onFetchStream(() => Effect.never);
  first.host.takeEmitted();
  const restarted = await Core.create(first.host, { clock: first.host.time.clock, sample: 0 });
  restarted.inner.store.authGen.syncWorkspace("ws", digest1);
  const rUi = restarted.connect();
  const rVals = new Map<number, unknown>();
  subscribe(restarted, rUi, 1, { topic: "screens", station: S });
  await first.host.time.pass(100, 10);
  apply(first.host, rVals);
  assert.equal(v(rVals, 1).known, true, "throttled disk row with capRev=0 must still show immediately on cold start");
  assert.equal(v(rVals, 1).confirmed, false);
  restarted.close();

  // 2. Astra P1-2: two Cores sharing host storage write different station capRev:* keys -> merge-before-write preserves both.
  const shared = await started(said as never);
  const coreA = shared.core;
  const coreB = await Core.create(shared.host, { clock: shared.host.time.clock, sample: 0 });
  coreA.inner.data.device.put("auth", `capRev:${S}:screens`, { rev: 1, denied: true });
  await Effect.runPromise(coreA.inner.data.device.flushTable("auth"));
  coreB.inner.data.device.put("auth", "capRev:ws/st2:screens", { rev: 2, denied: true });
  await Effect.runPromise(coreB.inner.data.device.flushTable("auth"));
  const rawAuth = await Effect.runPromise(shared.host.storageGet("device/auth"));
  assert.ok(rawAuth !== null);
  const parsedAuth = JSON.parse(new TextDecoder().decode(rawAuth)) as Record<string, { rev: number; denied: boolean }>;
  assert.deepEqual(parsedAuth[`capRev:${S}:screens`], { rev: 1, denied: true }, "Core B flush must preserve Core A's capRev entry");
  assert.deepEqual(parsedAuth["capRev:ws/st2:screens"], { rev: 2, denied: true }, "Core B's own capRev entry must be persisted");
  coreB.close();
  coreA.close();

  // 3. Astra P1-1 (sync 403 even when flushTable("auth") hangs) + P2-3 (503 retries as reconnecting, 0 screenView) + P1-4 (reopen handoff 0 leak).
  let svCount = 0;
  let newScopeClosed = 0;
  let screenMode: "open-for-sync403" | "reopen-then-403" | "fail" = "fail";
  let onOldFinalizer: (() => void) | null = null;
  const wireFactory = (h: FakeHost): StationWire =>
    Object.assign(new HostWire(h), {
      screen: () => {
        svCount++;
        if (screenMode === "open-for-sync403") {
          return Effect.gen(function* () {
            const q = yield* Queue.unbounded<Uint8Array | null>();
            return {
              reply: { status: 200, headers: [["content-type", "application/x-stillfail-screen"]] as [string, string][], body: { take: Queue.take(q) }, via: null },
              send: { write: () => Effect.void, finish: () => {} },
            };
          });
        }
        if (screenMode === "reopen-then-403") {
          if (svCount === 2) {
            return Effect.gen(function* () {
              yield* Effect.addFinalizer(() => Effect.sync(() => { onOldFinalizer?.(); }));
              const q = yield* Queue.unbounded<Uint8Array | null>();
              return {
                reply: { status: 200, headers: [["content-type", "application/x-stillfail-screen"]] as [string, string][], body: { take: Queue.take(q) }, via: null },
                send: { write: () => Effect.void, finish: () => {} },
              };
            });
          }
          return Effect.gen(function* () {
            yield* Effect.addFinalizer(() => Effect.sync(() => { newScopeClosed++; }));
            const q = yield* Queue.unbounded<Uint8Array | null>();
            return {
              reply: { status: 200, headers: [["content-type", "application/x-stillfail-screen"]] as [string, string][], body: { take: Queue.take(q) }, via: null },
              send: { write: () => Effect.void, finish: () => {} },
            };
          });
        }
        return Effect.fail(new CoreError("network", "unexpected screenView"));
      },
    });

  const run3 = await started(said as never, 0, wireFactory);
  const ui3 = run3.core.connect();
  let screensReply: 503 | 403 | 200 = 503;
  stationLater(run3.host, (req) => {
    if (req.method === "GET" && req.url.endsWith("/admin/api/screens")) {
      if (screensReply === 503) return Promise.resolve(jsonResponse(503, { error: "service unavailable" }));
      if (screensReply === 403) return Promise.resolve(jsonResponse(403, { error: "forbidden" }));
    }
    return undefined;
  });

  // 3a. Astra P2-3: GET /screens 503 on unconfirmed screen enters reconnecting (NOT denied) with 0 screenView calls.
  const link3 = run3.core.inner.stations.link(S)!;
  link3.memory.deletePrefix("screens");
  run3.host.takeEmitted();
  call(run3.core, ui3, 91, "screen.view", { station: S, screen: "desktop", view: "v-503", codecs: ["jpeg"] });
  await run3.host.settle();
  const msgs503 = run3.host.takeEmitted().map(([, m]) => m as { id?: number; value?: { state?: { phase?: string } } });
  assert.ok(msgs503.some((m) => m.id === 91 && m.value?.state?.phase === "reconnecting"), `503 on GET /screens must enter reconnecting, got: ${JSON.stringify(msgs503)}`);
  assert.equal(msgs503.some((m) => m.id === 91 && m.value?.state?.phase === "denied"), false, "503 on GET /screens must not be misclassified as denied");
  assert.equal(svCount, 0, "0 screenView calls on 503");
  run3.core.receive(ui3, { kind: "cancel", id: 91, cancel: true });
  await run3.host.settle();

  // 3b. Astra P1-1: even while storageSet("device/auth") hangs, 403 synchronously aborts active viewer to phase: "denied".
  screensReply = 200;
  run3.core.inner.runner.fork(run3.core.inner.stations.readScreens(S));
  await run3.host.settle();
  screenMode = "open-for-sync403";
  call(run3.core, ui3, 92, "screen.view", { station: S, screen: "desktop", view: "v-sync403", codecs: ["jpeg"] });
  await run3.host.settle();
  assert.equal(svCount, 1);
  const origStorageSet = run3.host.storageSet.bind(run3.host);
  const writeGate = Deferred.makeUnsafe<void>();
  run3.host.storageSet = (k, b) => (k === "device/auth" ? Effect.andThen(Deferred.await(writeGate), origStorageSet(k, b)) : origStorageSet(k, b));
  run3.host.takeEmitted();
  screensReply = 403;
  run3.core.inner.runner.fork(run3.core.inner.stations.readScreens(S));
  await run3.host.settle();
  assert.equal(run3.core.inner.stations.isDenied("screens", S), true, "403 must synchronously mark denied even while flushTable hangs");
  const msgsSync = run3.host.takeEmitted().map(([, m]) => m as { id?: number; value?: { state?: { phase?: string } } });
  assert.ok(msgsSync.some((m) => m.id === 92 && m.value?.state?.phase === "denied"), `active viewer must abort synchronously even when flushTable hangs, got: ${JSON.stringify(msgsSync)}`);
  run3.host.storageSet = origStorageSet;
  Deferred.doneUnsafe(writeGate, Effect.void);
  await run3.host.settle();

  // 3c. Astra P1-4: reopen succeeds, then 403 fires during old attempt's teardown before next loop iteration -> new scope closed exactly once (0 leak).
  screensReply = 200;
  run3.push("screens", { screens: [{ id: "desktop", kind: "desktop", title: "Main", width: 1280, height: 800, viewers: [], controlledBy: [] }], browser: true });
  await run3.host.settle();
  screenMode = "reopen-then-403";
  call(run3.core, ui3, 93, "screen.view", { station: S, screen: "desktop", view: "v-handoff", codecs: ["jpeg"], control: false });
  await run3.host.settle();
  assert.equal(svCount, 2);
  // When old stream's finalizer runs right after reopen hands off `ready`, fire a synchronous 403 denial:
  onOldFinalizer = () => {
    onOldFinalizer = null;
    screensReply = 403;
    run3.core.inner.runner.fork(run3.core.inner.stations.readScreens(S));
  };
  run3.host.takeEmitted();
  call(run3.core, ui3, 94, "screen.control", { view: "v-handoff", control: true });
  await run3.host.settle();
  assert.equal(svCount, 3, "replacement handshake opened");
  assert.equal(newScopeClosed, 1, "replacement scope must be closed exactly once with zero leak when 403 fires during handoff");
  const msgsHandoff = run3.host.takeEmitted().map(([, m]) => m as { id?: number; value?: { state?: { phase?: string } } });
  assert.ok(msgsHandoff.some((m) => m.id === 93 && m.value?.state?.phase === "denied"), "view must transition to phase: denied");
  run3.core.close();

  // 4. Opus P1 (r13): 403 -> flush -> 200 recovery (rev+1, denied:false) -> flush -> restart Core
  //    recovers cold-start known:true, confirmed:false, and subsequent repeated confirmations do 0 device/auth storageSet writes.
  const rec = await started(said as never);
  let rec403 = true;
  stationLater(rec.host, (req) => {
    if (rec403 && req.method === "GET" && req.url.endsWith("/admin/api/screens")) {
      return Promise.resolve(jsonResponse(403, { error: "forbidden" }));
    }
    return undefined;
  });
  rec.core.inner.runner.fork(rec.core.inner.stations.readScreens(S));
  await rec.host.settle();
  await Effect.runPromise(rec.core.inner.data.device.flushTable("auth"));
  assert.equal(rec.core.inner.stations.isDenied("screens", S), true);

  // Recover with 200: bumps rev+1 with denied:false so merge-before-write beats old {rev, denied:true}.
  rec403 = false;
  rec.core.inner.runner.fork(rec.core.inner.stations.readScreens(S));
  await rec.host.settle();
  await rec.host.time.pass(KEEP_MS + 1_000, 1_000);
  await Effect.runPromise(rec.core.inner.data.written);
  await Effect.runPromise(rec.core.inner.data.device.flushTable("auth"));

  // Subsequent repeated SSE + GET confirmations MUST do 0 device/auth storageSet writes.
  let authStorageWrites = 0;
  const origRecSet = rec.host.storageSet.bind(rec.host);
  rec.host.storageSet = (k, b) => {
    if (k === "device/auth") authStorageWrites++;
    return origRecSet(k, b);
  };
  for (let i = 0; i < 4; i++) {
    rec.push("screens", { screens: [{ id: "desktop", kind: "desktop", title: `Recovered-${i}`, width: 1280, height: 800, viewers: [], controlledBy: [] }], browser: true });
  }
  rec.core.inner.runner.fork(rec.core.inner.stations.readScreens(S));
  await rec.host.settle();
  await Effect.runPromise(rec.core.inner.data.device.flushTable("auth"));
  assert.equal(authStorageWrites, 0, "subsequent confirmations after recovery must perform 0 device/auth storageSet writes");
  rec.host.storageSet = origRecSet;
  const recDigest = rec.core.inner.store.authGen.workspaceDigest("ws")!;
  rec.core.close();

  // Restart Core: cold-start MUST show known:true, confirmed:false.
  rec.host.onFetch(() => new Promise(() => {}));
  rec.host.onFetchStream(() => Effect.never);
  rec.host.takeEmitted();
  const recRestart = await Core.create(rec.host, { clock: rec.host.time.clock, sample: 0 });
  recRestart.inner.store.authGen.syncWorkspace("ws", recDigest);
  const recUi = recRestart.connect();
  const recVals = new Map<number, unknown>();
  subscribe(recRestart, recUi, 1, { topic: "screens", station: S });
  await rec.host.time.pass(100, 10);
  apply(rec.host, recVals);
  assert.equal(v(recVals, 1).known, true, "cold-start after 403 -> 200 recovery must restore known: true");
  assert.equal(v(recVals, 1).confirmed, false);
  recRestart.close();
});
