// Every topic named by a chat's session (`session`) answers a chat a new chat's page became, named by the key it was
// sent under (`new:…`) all along: by routing it to the session its station made it under (routing.ts OF_A_SESSION), or
// by following the key itself (SESSION_FOLLOWS_KEY). A topic named so that is neither would answer that chat as none
// once it is made (2026-11-17: its page's "…" empty, `chatRow`; its bug reports' replies gone, `chatFeedback`).
import assert from "node:assert/strict";
import { test } from "node:test";
import { TOPICS } from "../src/protocol.ts";
import { OF_A_SESSION, SESSION_FOLLOWS_KEY } from "../src/core/routing.ts";

test("every_topic_named_by_a_chats_session_answers_a_new_chats_key", () => {
  const named = Object.entries(TOPICS).filter(([, spec]) => "session" in spec).map(([name]) => name).sort();
  const answered = [...OF_A_SESSION, ...SESSION_FOLLOWS_KEY].sort();
  assert.deepEqual(named, answered);
});
