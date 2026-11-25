// A runtime added on a station newer than this app (RuntimeKind, an open set): what names it is left out of what is
// shown, as the station leaves it out for an app that does not name it (station/src/read/runtime-view.ts), rather than
// failing the whole page; and the chats' list says to update the app (conform.ts `unknownWords`, views.ts `#chatsOf`).
import assert from "node:assert/strict";
import { test } from "node:test";
import { conform, forgetUnknownWords, unknownWords } from "../src/conform.ts";
import { t } from "../src/i18n.ts";
import { apply, subscribe } from "./helpers.ts";
import { base, started } from "./station-fixture.ts";

// deno-lint-ignore no-explicit-any
type J = any;

test("an_unknown_runtime_is_left_out_where_it_may_be_and_still_wrong_where_nothing_holds_it", async () => {
  forgetUnknownWords();
  try {
    // An option holding it is absent (a message's author: the message stays).
    const by = conform("MessageBy", { name: "Nova", runtime: "nova" }) as J;
    assert.deepEqual(by.ok, { name: "Nova" });
    // An item of a list that needs it is dropped; the others stay.
    const agents = conform({ vec: "RowAgent" }, [
      { runtime: "claude", agentText: "Claude" },
      { runtime: "nova", agentText: "Nova" },
    ]) as J;
    assert.deepEqual(agents.ok.map((a: J) => a.runtime), ["claude"]);
    assert.deepEqual(conform({ vec: "RuntimeKind" }, ["codex", "nova", "pi"]), { ok: ["codex", "pi"] });
    assert.deepEqual(conform({ map: "RuntimeKind" }, { a: "nova", b: "claude" }), { ok: { b: "claude" } });
    // Nothing to leave it out of: wrong, as before.
    const alone = conform("RowAgent", { runtime: "nova", agentText: "Nova" });
    assert.ok("error" in alone && alone.error.startsWith("runtime: unknown variant `nova`"), JSON.stringify(alone));
    // A closed set is as it was: an unknown word in a list is wrong, not dropped.
    assert.ok("error" in conform({ vec: "Lead" }, ["nobody-knows"]));
    // Told once each, in the order met.
    conform("MessageBy", { name: "Zed", runtime: "zed" });
    conform("MessageBy", { name: "Nova", runtime: "nova" });
    assert.deepEqual(unknownWords("RuntimeKind"), ["nova", "zed"]);
  } finally {
    forgetUnknownWords();
  }
});

test("a_chat_whose_agent_runs_an_unknown_runtime_still_shows_and_the_list_says_to_update_the_app", async () => {
  forgetUnknownWords();
  const answers = base();
  const shared = answers["GET /chats?shared=1"] as J[];
  answers["GET /chats?shared=1"] = [{ ...shared[0], agents: [{ ...shared[0].agents[0], runtime: "nova" }] }];
  const s = await started(answers);
  try {
    const values = new Map<number, unknown>();
    subscribe(s.core, 1, 2, { topic: "chats", scope: "ws" });
    await s.host.time.pass(1000, 250);
    apply(s.host, values);
    const list = values.get(2) as J;
    assert.ok(list !== undefined && list.days !== undefined, `the list shows: ${JSON.stringify(list)}`);
    const rows = list.days.flatMap((d: J) => d.chats ?? d.rows ?? d.items ?? []);
    assert.equal(rows.length, 1, JSON.stringify(list.days));
    assert.deepEqual(rows[0].agents, []);
    const runtimes = "nova";
    const said = s.host.appKeys === true ? t("core-views.station.unknownRuntime", { runtimes }) : t("core-views.station.unknownRuntimePage", { runtimes });
    assert.deepEqual(list.trouble, { text: said, state: "incompatible", retry: false });
  } finally {
    s.core.close();
    forgetUnknownWords();
  }
});
