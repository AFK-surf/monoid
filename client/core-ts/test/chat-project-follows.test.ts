import assert from "node:assert/strict";
import { test } from "node:test";
import { apply, subscribe, v } from "./helpers.ts";
import { base, started, threadView } from "./station-fixture.ts";

// A chat's project changed at its station (by a member elsewhere or by an agent) comes to an open chat's header with
// its row (`chat-shared`), though the thread as the page read it still says the old one.
test("an_open_chat_shows_the_project_its_row_has_now_not_the_one_its_thread_was_read_with", async () => {
  const answers = base();
  answers["GET /threads"] = [{ ...threadView(7, 3), title: "部署", project: "3D Artifact", projectLocked: true }];
  const shared = answers["GET /chats?shared=1"] as Record<string, unknown>[];
  answers["GET /chats?shared=1"] = [{ ...shared[0], project: "3D Artifact", projectLocked: true }];
  const s = await started(answers);
  try {
    const ui = s.core.connect();
    const values = new Map();
    subscribe(s.core, ui, 1, { topic: "chat", station: "ws/st", thread: 7, session: null });
    await s.host.time.pass(100, 10);
    apply(s.host, values);
    assert.equal(v(values, 1)?.project, "3D Artifact", "as it opens");
    // As the station tells it (api/events.ts): the row as it is now, and that the chat changed.
    const now = { ...shared[0], project: "团队运营", projectLocked: true };
    answers["GET /chats?shared=1"] = [now];
    s.push("chat-shared", now);
    s.push("chat-changed", { thread: 7 });
    await s.host.time.pass(3_000, 50);
    apply(s.host, values);
    assert.equal(v(values, 1)?.project, "团队运营", "the row's project, not the thread's as first read");
    assert.equal(v(values, 1)?.projectLocked, true);
  } finally { s.core.close(); }
});
