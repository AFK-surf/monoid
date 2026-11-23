// What of config.json the shared chat list is made with (read/views.ts `rowsMadeWith`): agents.ts tells every device to
// read the whole chat list again (`chat-changed`) only where it changed, never for a profile shared or checked.
import assert from "node:assert/strict";
import { test } from "node:test";
import { rowsMadeWith } from "../src/read/views.ts";

const base = {
  connects: [{ id: "ds", kind: "slack", slack: { botName: "ember", botToken: "xoxb-1" } }],
  automaticDecisions: { completion: { enabled: false } },
  profiles: [{ id: "cc", runtime: "claude", home: "homes/cc" }],
};

test("a profile added, shared or edited leaves what the chat list is made with as it was", () => {
  const before = rowsMadeWith(base);
  const shared = { ...base, profiles: [...base.profiles, { id: "borrowed", runtime: "codex", home: "homes/b", share: { from: "other" } }] };
  assert.equal(rowsMadeWith(shared), before);
  assert.equal(rowsMadeWith({ ...base, profiles: [{ ...base.profiles[0]!, models: ["opus"] }] }), before);
  // A connect's token is not what a row shows either.
  assert.equal(rowsMadeWith({ ...base, connects: [{ ...base.connects[0]!, slack: { botName: "ember", botToken: "xoxb-2" } }] }), before);
});

test("a connect added, removed or renamed, or the archive review turned on, changes it", () => {
  const before = rowsMadeWith(base);
  assert.notEqual(rowsMadeWith({ ...base, connects: [...base.connects, { id: "fs", kind: "feishu" }] }), before);
  assert.notEqual(rowsMadeWith({ ...base, connects: [] }), before);
  assert.notEqual(rowsMadeWith({ ...base, connects: [{ ...base.connects[0]!, slack: { botName: "flint" } }] }), before);
  assert.notEqual(rowsMadeWith({ ...base, automaticDecisions: { completion: { enabled: true } } }), before);
});
