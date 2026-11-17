// A single-session connect's binding follows the order people choose it in, even when making a session waits on
// the disk. Its first incoming message can make a session too; that and a person's choice share the same order.
import assert from "node:assert/strict";
import { test } from "node:test";
import { bindSingle, newSession } from "../src/sessions/lifecycle.ts";
import { Rig, given, say, settle } from "./hub-fakes.ts";

test("a later binding is not replaced by a new session still being made", async () => {
  const r = new Rig();
  const entered = Promise.withResolvers<void>(), release = Promise.withResolvers<void>();
  const create = r.hub.createSession.bind(r.hub);
  try {
    const [chosen] = await newSession(r.hub, { runtime: "claude", createdBy: "local" });
    r.hub.createSession = async (...args) => {
      entered.resolve();
      await release.promise;
      await create(...args);
    };
    const first = bindSingle(r.hub, "team", null, "new", "local");
    await given(entered.promise, "the new session starts being made");
    const second = bindSingle(r.hub, "team", chosen, null, "local");
    release.resolve();
    const [fresh, selected] = await Promise.all([first, second]);
    assert.notEqual(fresh, chosen);
    assert.equal(selected, chosen);
    assert.equal(r.store.binding("team"), chosen, "the person's later choice stays bound");
  } finally {
    release.resolve();
    r.hub.createSession = create;
    await r.close();
  }
});

test("a binding waits for an incoming message's first session and is kept afterwards", async () => {
  const r = new Rig();
  const entered = Promise.withResolvers<void>(), release = Promise.withResolvers<void>();
  const create = r.hub.createSession.bind(r.hub);
  try {
    const [chosen] = await newSession(r.hub, { runtime: "claude", createdBy: "local" });
    r.hub.createSession = async (...args) => {
      entered.resolve();
      await release.promise;
      await create(...args);
    };
    const incoming = r.accept(say("<@UTEAM> first"), "team");
    await given(entered.promise, "the first message starts making a session");
    const selected = bindSingle(r.hub, "team", chosen, null, "local");
    release.resolve();
    await Promise.all([incoming, selected]);
    await settle();
    assert.equal(r.store.binding("team"), chosen, "the first message's session cannot replace the later choice");
    await r.accept(say("<@UTEAM> next", { channel: "C2" }), "team");
    await settle();
    assert.ok(r.claude.sessions.find((s) => s.options.route === chosen)?.prompts.some((p) => p.includes("next")), "the next message goes to the chosen session");
  } finally {
    release.resolve();
    r.hub.createSession = create;
    await r.close();
  }
});

test("a new session failing does not prevent the next binding", async () => {
  const r = new Rig();
  const entered = Promise.withResolvers<void>(), release = Promise.withResolvers<void>();
  const create = r.hub.createSession.bind(r.hub);
  try {
    const [chosen] = await newSession(r.hub, { runtime: "claude", createdBy: "local" });
    r.hub.createSession = async () => {
      entered.resolve();
      await release.promise;
      throw new Error("disk refused the new session");
    };
    const first = assert.rejects(bindSingle(r.hub, "team", null, "new", "local"), /disk refused/);
    await given(entered.promise, "the new session starts being made");
    const second = bindSingle(r.hub, "team", chosen, null, "local");
    release.resolve();
    await Promise.all([first, second]);
    assert.equal(r.store.binding("team"), chosen);
    r.hub.createSession = create;
    const fresh = await bindSingle(r.hub, "team", null, "after failure", "local");
    assert.equal(r.store.binding("team"), fresh, "the queue also accepts another new session");
  } finally {
    release.resolve();
    r.hub.createSession = create;
    await r.close();
  }
});
