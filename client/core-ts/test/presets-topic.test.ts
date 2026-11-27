// A workspace's presets on a station (the `presets` topic): read as a page shows them and again once
// one is made; the one picked for a new chat there is kept on this device and goes with the chat as it is made.
import assert from "node:assert/strict";
import { test } from "node:test";
import { apply as applyOps } from "../src/delta.ts";
import { answers, apply, call, readsOf, subscribe, v } from "./helpers.ts";
import { base, overview, started, stationLater, stationReplies } from "./station-fixture.ts";
import type { HttpRequest } from "../src/host.ts";
import type { StationAddr } from "../src/station/addr.ts";
import { HostWire, type RequestHead, type StationWire } from "../src/station/wire.ts";
import { logKey, PRESETS } from "../src/station/link.ts";
import { Memory, type Keeper } from "../src/station/memory.ts";
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

test("ephemeral_memory_never_resurrects_persisted_jobLog_or_presets_across_restart_or_readonly_db", async () => {
  // 1. Ephemeral prefixes ([PRESETS, LOG_KEY]) never read from or write to keeper,
  //    so read-only DBs, lazily-opened DBs, or legacy rows surviving a restart can never resurrect old data.
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
  assert.deepEqual((mem.get(PRESETS) as { presets: { id: string }[] }).presets.map((p) => p.id), ["ro-new"]);

  // Simulated restart with a brand new Memory over the same read-only DB still never resurrects old rows.
  const restarted = new Memory(readOnlyKeeper, [], [PRESETS, "jobLog\n"]);
  assert.equal(restarted.get(PRESETS), undefined);
  assert.equal(restarted.get(logKey("j-ro", 200)), undefined);

  // 2. Cold-start keeper-cached screens/terminals have known: false until confirmed in current authGen;
  //    non-downgrade boundary (e.g. unlock) clears #openingTabs and immediately re-fetches active screens/terminals/presets.
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

  // Cold-start keeper cache WITH matching authDigest -> known: true, confirmed: false (0 flicker, actions blocked).
  const curDigest = core.inner.store.authGen.workspaceDigest("ws");
  assert.ok(typeof curDigest === "string" && curDigest.length > 0, "workspaceDigest is populated");
  link.memory.deletePrefix("screens");
  link.memory.deletePrefix("terminals");
  core.inner.data.keepStationMemory(S, "screens", { screens: [{ id: "desktop", kind: "desktop", title: "Old", width: 800, height: 600, viewers: [], controlledBy: [] }], outdated: false, authDigest: curDigest });
  core.inner.data.keepStationMemory(S, "terminals", { terminals: [{ id: "t-old", by: "a@x.com", cwd: "/old", at: 1, looking: [] }], outdated: false, authDigest: curDigest });
  assert.equal(core.inner.stations.isConfirmed("screens", S), false, "keeper-only screens must not be confirmed");
  assert.equal(core.inner.stations.isConfirmed("terminals", S), false, "keeper-only terminals must not be confirmed");
  assert.ok(core.inner.stations.screens(S) !== undefined, "matching authDigest allows cold-start display");
  assert.ok(core.inner.stations.terminals(S) !== undefined, "matching authDigest allows cold-start display");

  // Cold-start keeper cache with MISMATCHED authDigest (e.g. downgrade/switch account + read-only DB across Link rebuild/restart):
  // MUST return undefined so pre-boundary screens/terminals never resurrect even on a read-only DB.
  link.memory.deletePrefix("screens");
  link.memory.deletePrefix("terminals");
  core.inner.data.keepStationMemory(S, "screens", { screens: [{ id: "desktop", kind: "desktop", title: "WrongAuth", width: 800, height: 600, viewers: [], controlledBy: [] }], outdated: false, authDigest: "stale-owner-digest" });
  core.inner.data.keepStationMemory(S, "terminals", { terminals: [{ id: "t-stale", by: "other@x.com", cwd: "/secret", at: 1, looking: [] }], outdated: false, authDigest: "stale-owner-digest" });
  assert.equal(core.inner.stations.screens(S), undefined, "mismatched authDigest must hide keeper-cached screens");
  assert.equal(core.inner.stations.terminals(S), undefined, "mismatched authDigest must hide keeper-cached terminals");

  // Restore matching authDigest to test cold-start topic projection -> boundary refetch recovery.
  link.memory.deletePrefix("screens");
  link.memory.deletePrefix("terminals");
  core.inner.data.keepStationMemory(S, "screens", { screens: [{ id: "desktop", kind: "desktop", title: "Old", width: 800, height: 600, viewers: [], controlledBy: [] }], outdated: false, authDigest: curDigest });
  core.inner.data.keepStationMemory(S, "terminals", { terminals: [{ id: "t-old", by: "a@x.com", cwd: "/old", at: 1, looking: [] }], outdated: false, authDigest: curDigest });

  const ui = core.connect();
  const values = new Map<number, unknown>();
  subscribe(core, ui, 1, { topic: "screens", station: S });
  subscribe(core, ui, 2, { topic: "terminals", station: S });
  subscribe(core, ui, 3, { topic: "presets", station: S });
  await host.settle();
  apply(host, values);
  assert.equal(v(values, 1).known, true, "cold-start keeper screens stay known: true for display");
  assert.equal(v(values, 1).confirmed, false, "cold-start keeper screens stay confirmed: false before station reply");
  assert.equal(v(values, 2).known, true, "cold-start keeper terminals stay known: true for display");
  assert.equal(v(values, 2).confirmed, false, "cold-start keeper terminals stay confirmed: false before station reply");
  assert.equal(v(values, 3).presets[0].id, "app");

  // Non-downgrade auth boundary (e.g. lock trusted flip / unlock): must immediately re-fetch active screens/terminals/presets
  // so UI recovers confirmed: true instead of getting stuck empty.
  const beforeReqs = host.requests.length;
  core.inner.store.authGen.syncWorkspace("ws", "owner:a@x.com:trusted:1");
  await host.settle();
  apply(host, values);
  const afterUrls = host.requests.slice(beforeReqs).map((r) => `${r.method} ${r.url}`);
  assert.ok(afterUrls.some((u) => u.endsWith("/admin/api/screens")), "onBoundary must re-fetch active screens");
  assert.ok(afterUrls.some((u) => u.endsWith("/admin/api/terminals")), "onBoundary must re-fetch active terminals");
  assert.ok(afterUrls.some((u) => u.endsWith("/admin/api/presets")), "onBoundary must re-fetch active presets");
  assert.equal(v(values, 1).known, true);
  assert.equal(v(values, 1).confirmed, true, "screens recovers confirmed: true after non-downgrade boundary");
  assert.equal(v(values, 2).known, true);
  assert.equal(v(values, 2).confirmed, true, "terminals recovers confirmed: true after non-downgrade boundary");
  assert.equal(v(values, 3).presets[0].id, "app", "presets recovers after non-downgrade boundary");

  // Memory.clearKey keeps key in #looked so a read-only keeper cannot lazy-reload old screens/terminals.
  const roDisk = new Map<string, unknown>([
    ["screens", { screens: [{ id: "desktop", kind: "desktop", title: "RO" }], outdated: false }],
  ]);
  const roMem = new Memory({
    read: (k) => roDisk.get(k),
    write: () => {},
    bound: () => {},
    now: () => 1000,
    later: () => {},
  });
  roMem.clearKey("screens");
  assert.equal(roMem.get("screens"), undefined, "clearKey must keep key in #looked so read-only keeper cannot resurrect it");
  core.close();
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
