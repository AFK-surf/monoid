import assert from "node:assert/strict";
import { test } from "node:test";
import { CONFIGURE, configureForPeer } from "../src/sessions/chat-configure.ts";
import { hubConfig } from "../src/sessions/config.ts";
import { archiveBy, newSession } from "../src/sessions/lifecycle.ts";
import { LIST, listForPeer } from "../src/sessions/others.ts";
import { MANUAL } from "../src/store/rows.ts";
import { Rig, settle } from "./hub-fakes.ts";

const withModels = (r: Rig) => {
  r.raw.profiles = [
    { id: "cc", runtime: "claude", home: "homes/cc", models: ["claude-opus-4-6", "claude-sonnet-4-6"] },
    { id: "cx", runtime: "codex", home: "homes/cx", models: ["gpt-5.4"] },
  ];
  r.config = hubConfig(r.raw, r.dir);
  return r;
};

const web = (over: { runtime?: "claude" | "codex"; model?: string; effort?: string; createdBy?: string; ws?: string; title?: string } = {}) => ({
  runtime: over.runtime ?? ("claude" as const),
  model: over.model ?? "claude-opus-4-6",
  effort: over.effort ?? "medium",
  createdBy: over.createdBy ?? "ada@example.com",
  ws: over.ws,
  title: over.title,
});

test("chat_configure inspects and updates a session's model, effort and runtime locally", async () => {
  const r = withModels(new Rig({ link: true }));
  try {
    const [caller] = await newSession(r.hub, web({ model: "claude-opus-4-6", effort: "high" }));
    const [other, thread] = await newSession(r.hub, web({ model: "claude-sonnet-4-6", effort: "low" }));
    await settle();

    // Inspect own session when chat is omitted or "self".
    const own = JSON.parse(await r.call(caller, "chat_configure", {}));
    assert.equal(own.session, caller);
    assert.equal(own.runtime, "claude");
    assert.equal(own.model, "claude-opus-4-6");
    assert.equal(own.effort, "high");
    assert.equal(own.created_by, "ada@example.com");
    assert.deepEqual(JSON.parse(await r.call(caller, "chat_configure", { chat: "self" })), own);

    // Update another chat by link.
    const link = r.hub.link(other)!;
    const changed = JSON.parse(await r.call(caller, "chat_configure", { chat: link, model: "claude-opus-4-6", effort: "high" }));
    assert.equal(changed.updated, true);
    assert.equal(changed.before.model, "claude-sonnet-4-6");
    assert.equal(changed.after.model, "claude-opus-4-6");
    assert.equal(changed.after.effort, "high");
    assert.equal(r.store.getSession(other)!.model, "claude-opus-4-6");
    assert.equal(r.store.getSession(other)!.effort, "high");

    // Update by thread address, switching runtime explicitly.
    const switched = JSON.parse(await r.call(caller, "chat_configure", { chat: `CHAT/${thread.threadTs}`, runtime: "codex", model: "gpt-5.4", effort: "high" }));
    assert.equal(switched.after.runtime, "codex");
    assert.equal(switched.after.model, "gpt-5.4");
    assert.equal(r.store.getSession(other)!.runtime, "codex");

    // A page showing another session's history configures the page's chat, not the history session.
    const [history] = await newSession(r.hub, web({ model: "claude-sonnet-4-6" }));
    const histLink = `${link}?history=${encodeURIComponent(history)}&entry=1`;
    await r.call(caller, "chat_configure", { chat: histLink, runtime: "claude", model: "claude-opus-4-6" });
    assert.equal(r.store.getSession(other)!.runtime, "claude");
    assert.equal(r.store.getSession(history)!.model, "claude-sonnet-4-6");
  } finally {
    await r.close();
  }
});

test("chat_configure infers runtime from model when unique across workspace profiles", async () => {
  const r = new Rig({ link: true });
  try {
    r.raw.profiles = [
      { id: "cc", runtime: "claude", home: "homes/cc", models: ["claude-opus-4-6", "claude-sonnet-4-6"] },
      { id: "cx", runtime: "codex", home: "homes/cx", models: ["gpt-5.4"] },
    ];
    r.config = hubConfig(r.raw, r.dir);
    const [caller] = await newSession(r.hub, web({ runtime: "claude", model: "claude-opus-4-6" }));
    const [other] = await newSession(r.hub, web({ runtime: "claude", model: "claude-sonnet-4-6" }));
    await settle();

    const moved = JSON.parse(await r.call(caller, "chat_configure", { chat: other, model: "gpt-5.4" }));
    assert.equal(moved.after.runtime, "codex");
    assert.equal(moved.after.model, "gpt-5.4");
    assert.equal(r.store.getSession(other)!.runtime, "codex");
  } finally {
    await r.close();
  }
});

test("chat_configure applies a preset's model config and refuses conflicting overrides", async () => {
  const r = withModels(new Rig({ link: true }));
  try {
    await r.hub.presets.add(null, { name: "Fast Codex", dirs: [], instructions: "", model: { runtime: "codex", model: "gpt-5.4", effort: "high" } }, "local");
    await r.hub.presets.add(null, { name: "No Model", dirs: [], instructions: "" }, "local");
    const [caller] = await newSession(r.hub, web({ model: "claude-opus-4-6" }));
    const [other] = await newSession(r.hub, web({ model: "claude-sonnet-4-6" }));
    await settle();

    assert.match(await r.refused(caller, "chat_configure", { chat: other, preset: "Fast Codex", model: "claude-opus-4-6" }), /cannot be combined/);
    assert.match(await r.refused(caller, "chat_configure", { chat: other, preset: "No Model" }), /does not configure a model/);
    const applied = JSON.parse(await r.call(caller, "chat_configure", { chat: other, preset: "Fast Codex" }));
    assert.equal(applied.after.runtime, "codex");
    assert.equal(applied.after.model, "gpt-5.4");
    assert.equal(applied.after.effort, "high");
  } finally {
    await r.close();
  }
});

test("chat_configure inspects and updates a chat on another station and refuses cross-workspace shares", async () => {
  const near = withModels(new Rig({ link: true, place: { workspace: "w", station: "near" }, workspaces: ["w", "other"] }));
  const far = withModels(new Rig({ link: true, place: { workspace: "w", station: "far" }, workspaces: ["w"] }));
  try {
    const [caller] = await newSession(near.hub, web({ ws: "w" }));
    const [remote] = await newSession(far.hub, web({ ws: "w", model: "claude-sonnet-4-6" }));
    const link = far.hub.link(remote)!;
    near.hub.onPeer(async (station, request) => {
      assert.equal(station, "far");
      assert.equal(request.method, CONFIGURE);
      return configureForPeer(far.hub, request, "w");
    });

    const seen = JSON.parse(await near.call(caller, "chat_configure", { chat: link }));
    assert.equal(seen.session, remote);
    assert.equal(seen.model, "claude-sonnet-4-6");

    const updated = JSON.parse(await near.call(caller, "chat_configure", { chat: link, model: "claude-opus-4-6", effort: "high" }));
    assert.equal(updated.updated, true);
    assert.equal(far.store.getSession(remote)!.model, "claude-opus-4-6");

    // Cross-workspace writable shared chat cannot be configured locally or via peer.
    const [foreign] = await newSession(near.hub, web({ ws: "other", model: "claude-sonnet-4-6" }));
    near.store.setChatShare(foreign, [{ workspace: "w", name: "W" }], true, "ada@example.com");
    const foreignLink = near.hub.link(foreign)!;
    assert.match(await near.refused(caller, "chat_configure", { chat: foreignLink, model: "claude-opus-4-6" }), /another workspace/);
    await assert.rejects(configureForPeer(near.hub, { chat: foreignLink, change: { model: "claude-opus-4-6" } }, "w"), /another workspace/);
    assert.equal(near.store.getSession(foreign)!.model, "claude-sonnet-4-6");
  } finally {
    await near.close();
    await far.close();
  }
});

test("chat_list shows model and creator, filters by model/created_by/archived, and queries other stations", async () => {
  const near = withModels(new Rig({ link: true, place: { workspace: "w", station: "near" }, workspaces: ["w"] }));
  const far = withModels(new Rig({ link: true, place: { workspace: "w", station: "far" }, workspaces: ["w"] }));
  try {
    const [caller] = await newSession(near.hub, web({ ws: "w", model: "claude-opus-4-6", createdBy: "ada@example.com", title: "Caller" }));
    const [c1] = await newSession(near.hub, web({ ws: "w", model: "claude-sonnet-4-6", createdBy: "ada@example.com", title: "Ada Active" }));
    const [c2] = await newSession(near.hub, web({ ws: "w", model: "claude-sonnet-4-6", createdBy: "ada@example.com", title: "Ada Archived" }));
    const [c3] = await newSession(near.hub, web({ ws: "w", model: "claude-sonnet-4-6", createdBy: "bob@example.com", title: "Bob Active" }));
    archiveBy(near.hub, c2, true, MANUAL);
    const [farChat] = await newSession(far.hub, web({ ws: "w", model: "claude-sonnet-4-6", createdBy: "ada@example.com", title: "Far Active" }));
    await settle();

    // Local filter: model + created_by: "me" + archived: false.
    const mine = await near.call(caller, "chat_list", { model: "sonnet", created_by: "me", archived: false });
    assert.ok(mine.includes("Ada Active"), mine);
    assert.ok(mine.includes("model: claude/claude-sonnet-4-6"), mine);
    assert.ok(mine.includes("by: ada@example.com"), mine);
    assert.ok(!mine.includes("Ada Archived"), mine);
    assert.ok(!mine.includes("Bob Active"), mine);
    assert.ok(!mine.includes("Caller"), mine);
    assert.ok(mine.includes(near.hub.link(c1)!), mine);

    // Archived only.
    const arch = await near.call(caller, "chat_list", { model: "sonnet", created_by: "me", archived: true });
    assert.ok(arch.includes("Ada Archived"), arch);
    assert.ok(!arch.includes("Ada Active"), arch);

    // Cross-station: station: "all" and station: "far".
    near.hub.onPeer(async (station, request) => {
      if (request.method === "peers") return { stations: [{ id: "near", name: "Near" }, { id: "far", name: "Far" }] };
      assert.equal(station, "far");
      assert.equal(request.method, LIST);
      assert.equal(request.args.created_by, "ada@example.com");
      return listForPeer(far.hub, request, "w");
    });

    const all = await near.call(caller, "chat_list", { model: "sonnet", created_by: "me", archived: false, station: "all" });
    assert.ok(all.includes("## Near (this station)"), all);
    assert.ok(all.includes("Ada Active"), all);
    assert.ok(all.includes("## Far"), all);
    assert.ok(all.includes("Far Active"), all);
    assert.ok(all.includes(far.hub.link(farChat)!), all);

    const onlyFar = await near.call(caller, "chat_list", { model: "sonnet", created_by: "me", archived: false, station: "Far" });
    assert.ok(onlyFar.includes("Far Active"), onlyFar);
    assert.ok(!onlyFar.includes("Ada Active"), onlyFar);
    assert.ok(!onlyFar.includes(c3), onlyFar);
  } finally {
    await near.close();
    await far.close();
  }
});
