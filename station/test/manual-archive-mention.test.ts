// A platform's thread whose agent was archived by hand: the agent is out of it as after chat_leave, with nothing said
// there, until someone mentions it (hub.ts `acceptInTurn`). A still.fail chat stays refused until a person restores it.
import assert from "node:assert/strict";
import { existsSync } from "node:fs";
import { dirname, join } from "node:path";
import { test } from "node:test";
import { sessionKey } from "../src/sessions/hub.ts";
import { archive, archiveBy, archiveChat, ensureConversationChat, newSession, say as sayIn } from "../src/sessions/lifecycle.ts";
import type { ChatSurface, InboundMessage } from "../src/sessions/chat.ts";
import { AUTO, MANUAL } from "../src/store/store.ts";
import { type FakeChat, type FakeDriver, Rig, reply, say, settle } from "./hub-fakes.ts";

const note = (id: string) => ({ id, name: `${id}.txt`, size: 7, url: `https://files.slack.com/${id}` });

/// Everything the platform was given of the station.
const given = (chat: FakeChat) => ({ posts: [...chat.posts], edits: [...chat.edits], stands: [...chat.stands], calls: [...chat.calls] });

/// The texts recorded in a thread.
const texts = (r: Rig, m: InboundMessage) => r.said(r.thread(m.channel, m.threadTs).id).map((e) => e.text);

/// The prompts and steers a runtime's sessions had that say `words`.
const heard = (driver: FakeDriver, words: string) => driver.sessions.flatMap((s) => [...s.prompts, ...s.steers]).filter((p) => p.includes(words)).length;

/// Ends the turn under way of `key`, whose process is `driver`'s last.
async function ended(r: Rig, driver: FakeDriver, key: string) {
  await r.call(key, "chat_state", { kind: "final" });
  driver.last().complete();
  await settle();
}

/// A thread whose agent's turn has ended, then archived by hand.
async function archivedThread(r: Rig) {
  const m = say("<@UBOT> look at the build");
  await r.accept(m);
  await settle();
  const key = sessionKey("cl", "C1", m.threadTs);
  await ended(r, r.claude, key);
  archive(r.hub, key, true);
  await settle();
  return { m, key };
}

const archived = (r: Rig, key: string) => [r.session(key).archivedAt !== null, r.session(key).archivedBy];

test("archiving by hand says nothing in the thread; what does not mention the agent is recorded alone, for it to read once mentioned", async () => {
  const r = new Rig();
  const m = say("<@UBOT> look at the build");
  await r.accept(m);
  await settle();
  const key = sessionKey("cl", "C1", m.threadTs);
  await ended(r, r.claude, key);
  const before = given(r.chat);
  archive(r.hub, key, true);
  await settle();
  assert.deepEqual(given(r.chat), before, "no word of leaving");
  const row = r.session(key);
  r.chat.shared.set("F1", "content");
  await r.accept(reply(m, "9999.1", "the plan is X", { files: [note("F1")] }));
  await r.accept(reply(m, "9999.2", "", { files: [note("F1")] }));
  await settle();
  assert.deepEqual(given(r.chat), before, "no notice");
  assert.deepEqual(r.chat.downloads, []);
  assert.ok(!existsSync(join(row.workspace, "uploads")));
  const threadId = r.thread("C1", m.threadTs).id;
  const [plan, file] = r.said(threadId).slice(-2);
  assert.equal(plan!.text, "the plan is X");
  assert.equal(file!.text, "");
  assert.deepEqual([plan!.attachments, file!.attachments], [[], []]);
  const deferred = r.store.deferredFiles(threadId, [plan!.n, file!.n]);
  assert.deepEqual(deferred.get(plan!.n)?.map((f) => f.name), ["F1.txt"]);
  assert.deepEqual(deferred.get(file!.n)?.map((f) => f.name), ["F1.txt"]);
  assert.deepEqual(r.session(key), row, "archived, shown and last active as it was");
  assert.equal(r.store.pendingMessages(key).length, 0);
  assert.equal(heard(r.claude, "the plan is X"), 0);
  await r.accept(reply(m, "9999.3", "<@UBOT> do as said above", { addressed: true }));
  await settle();
  assert.equal(heard(r.claude, "do as said above"), 1);
  assert.equal(heard(r.claude, "the plan is X"), 0, "not given it");
  const hist = await r.call(key, "chat_history", { to: `C1/${m.threadTs}` });
  assert.ok(hist.includes("the plan is X") && hist.includes("F1.txt"), hist);
  await r.close();
});

test("a mention restores an agent archived by hand: recorded and delivered, with no notice, and what follows reaches it", async () => {
  const r = new Rig();
  const { m, key } = await archivedThread(r);
  const home = ensureConversationChat(r.hub, key, "ada@example.com", null);
  archive(r.hub, key, true);
  await settle();
  assert.notEqual(r.store.getThread(home.id)!.hiddenAt, null);
  const before = given(r.chat);
  r.chat.shared.set("F1", "content");
  await r.accept(reply(m, "9999.1", "<@UBOT> one more thing", { addressed: true, files: [note("F1")] }));
  await settle();
  assert.deepEqual(archived(r, key), [false, null]);
  assert.notEqual(r.session(key).shownAt, null, "as shown again by hand");
  assert.equal(r.store.getThread(home.id)!.hiddenAt, null, "its own chat too");
  assert.deepEqual(given(r.chat).posts, before.posts, "no notice");
  assert.equal(texts(r, m).filter((t) => t.includes("one more thing")).length, 1);
  assert.deepEqual(r.chat.downloads, [], "deferred until fetched by agent");
  assert.equal(heard(r.claude, "one more thing"), 1);
  assert.equal(heard(r.claude, "id=F1"), 1);
  await r.call(key, "chat_history", { to: `C1/${m.threadTs}`, fetch: ["F1"] });
  assert.deepEqual(r.chat.downloads, ["F1"]);
  await ended(r, r.claude, key);
  await r.accept(reply(m, "9999.2", "and another thing"));
  await settle();
  assert.equal(heard(r.claude, "and another thing"), 1);
  await r.close();
});

test("shown again by hand, an agent hears what is said from then on, mentioned or not", async () => {
  const r = new Rig();
  const { m, key } = await archivedThread(r);
  await r.accept(reply(m, "9999.1", "while away"));
  archive(r.hub, key, false);
  await settle();
  assert.equal(heard(r.claude, "while away"), 0);
  await r.accept(reply(m, "9999.2", "back now"));
  await settle();
  assert.deepEqual(archived(r, key), [false, null]);
  assert.equal(heard(r.claude, "back now"), 1);
  await r.close();
});

for (const first of ["cl", "gpt"] as const) {
  test(`an agent the station archived comes back with any message, one archived by hand beside it not (${first}'s connect first)`, async () => {
    const r = new Rig();
    const { m, key } = await archivedThread(r);
    const other = sessionKey("gpt", "C1", m.threadTs);
    await r.accept(reply(m, "9999.1", "<@UGPT> your turn", { addressed: true }), "gpt");
    await settle();
    await ended(r, r.codex, other);
    archiveBy(r.hub, other, true, AUTO);
    await settle();
    assert.equal(r.store.manuallyArchived(r.thread("C1", m.threadTs).id), true, "no one shown, one by hand");
    const before = [given(r.chat).posts, given(r.gptChat).posts];
    for (const c of [r.chat, r.gptChat]) c.shared.set("F1", "content");
    const said = reply(m, "9999.2", "anyone there?", { files: [note("F1")] });
    for (const c of first === "cl" ? ["cl", "gpt"] : ["gpt", "cl"]) await r.accept(said, c);
    await settle();
    assert.deepEqual(archived(r, other), [false, null]);
    assert.deepEqual(archived(r, key), [true, MANUAL]);
    assert.deepEqual([heard(r.codex, "anyone there?"), heard(r.claude, "anyone there?")], [1, 0]);
    assert.equal(r.store.pendingMessages(key).length, 0);
    await r.call(other, "chat_history", { to: `C1/${m.threadTs}`, fetch: ["F1"] });
    const [file] = r.said(r.thread("C1", m.threadTs).id).find((e) => e.text === "anyone there?")!.attachments;
    assert.equal(dirname(file!.path), join(r.session(other).workspace, "uploads"));
    assert.deepEqual([given(r.chat).posts, given(r.gptChat).posts], before);
    await r.close();
  });
}

test("a mention of another bot that the archived one's connect saw first brings its files and the message it quotes", async () => {
  const r = new Rig();
  const { m, key } = await archivedThread(r);
  r.gptChat.shared.set("F1", "content");
  (r.gptChat as ChatSurface).quoted = async () => ({ ts: "5.5", user: "U2", text: "the quoted words", fromBot: false });
  const call = reply(m, "9999.1", "<@UGPT> look at this", { files: [note("F1")], quoted: "5.5" });
  await r.accept(call);
  assert.deepEqual(r.said(r.thread("C1", m.threadTs).id).at(-1)!.attachments, []);
  await r.accept({ ...call, addressed: true }, "gpt");
  await r.accept({ ...call, addressed: true }, "gpt");
  await settle();
  const entry = r.said(r.thread("C1", m.threadTs).id).at(-1)!;
  assert.equal(entry.text, "> the quoted words\n\n<@UGPT> look at this");
  assert.deepEqual(entry.attachments, []);
  assert.deepEqual(r.gptChat.downloads, [], "deferred until fetched by agent");
  assert.deepEqual([heard(r.codex, "look at this"), heard(r.codex, "the quoted words"), heard(r.codex, "F1.txt")], [1, 1, 1]);
  await r.call(sessionKey("gpt", "C1", m.threadTs), "chat_history", { to: `C1/${m.threadTs}`, fetch: ["F1"] });
  assert.deepEqual(r.said(r.thread("C1", m.threadTs).id).at(-1)!.attachments.map((a) => a.name), ["F1.txt"]);
  assert.deepEqual(r.gptChat.downloads, ["F1"], "once");
  assert.deepEqual(archived(r, key), [true, MANUAL]);
  await r.close();
});

test("a mention recorded without its files and edited on its platform before they come keeps the edit, its files and quote added", async () => {
  for (const quoted of [undefined, "5.5"]) {
    const r = new Rig();
    const { m } = await archivedThread(r);
    r.gptChat.shared.set("F1", "content");
    (r.gptChat as ChatSurface).quoted = async () => ({ ts: "5.5", user: "U2", text: "the quoted words", fromBot: false });
    const call = reply(m, "9999.1", "<@UGPT> look at this", { files: [note("F1")], ...(quoted !== undefined ? { quoted } : {}) });
    await r.accept(call);
    await r.hub.receive("cl", { type: "changed", channel: "C1", threadTs: m.threadTs, ts: "9999.1", text: "<@UGPT> look at THAT instead" });
    await r.accept({ ...call, addressed: true }, "gpt");
    await settle();
    const entry = r.store.messageAt(r.thread("C1", m.threadTs).id, "9999.1")!;
    assert.equal(entry.text, `${quoted !== undefined ? "> the quoted words\n\n" : ""}<@UGPT> look at THAT instead`);
    assert.deepEqual([heard(r.codex, "THAT instead"), heard(r.codex, "look at this"), heard(r.codex, "F1.txt")], [1, 0, 1]);
    await r.call(sessionKey("gpt", "C1", m.threadTs), "chat_history", { to: `C1/${m.threadTs}`, fetch: ["F1"] });
    const after = r.store.messageAt(r.thread("C1", m.threadTs).id, "9999.1")!;
    assert.equal(after.text, `${quoted !== undefined ? "> the quoted words\n\n" : ""}<@UGPT> look at THAT instead`);
    assert.deepEqual(after.attachments.map((a) => a.name), ["F1.txt"]);
    await r.close();
  }
});

test("a message's latest edit is found by an index, the edits after it alone", async () => {
  const r = new Rig();
  const { m } = await archivedThread(r);
  const thread = r.thread("C1", m.threadTs).id;
  const n = r.store.messageNumberAt(thread, m.ts)!;
  assert.equal(r.store.editedText(thread, n), null);
  for (const text of ["first edit", "second edit"]) r.store.editMessage("slack:T1", "C1", m.threadTs, m.ts, text);
  assert.equal(r.store.editedText(thread, n), "second edit");
  const plan = r.store.db.prepare("EXPLAIN QUERY PLAN SELECT text FROM entries WHERE thread = ?1 AND target = ?2 AND n > ?2 AND kind = 'edit' ORDER BY n DESC LIMIT 1").all(thread, n).map((row) => String(row.detail)).join("\n");
  assert.match(plan, /SEARCH entries USING INDEX entries_edits \(thread=\? AND target=\? AND n>\?\)/);
  assert.doesNotMatch(plan, /TEMP B-TREE/);
  await r.close();
});

test("a thread hidden by hand whose agent is still shown: what is said is recorded alone, and a mention shows it again", async () => {
  const r = new Rig();
  const m = say("<@UBOT> look at the build");
  await r.accept(m);
  await settle();
  const key = sessionKey("cl", "C1", m.threadTs);
  await ended(r, r.claude, key);
  const thread = r.thread("C1", m.threadTs);
  r.store.setThreadHidden(thread.id, true, MANUAL);
  r.chat.shared.set("F1", "content");
  await r.accept(reply(m, "9999.1", "not for you", { files: [note("F1")] }));
  await settle();
  assert.equal(r.store.getThread(thread.id)!.hiddenBy, MANUAL);
  assert.equal(heard(r.claude, "not for you"), 0);
  assert.ok(texts(r, m).at(-1)!.startsWith("not for you"));
  assert.deepEqual(r.chat.downloads, []);
  await r.accept(reply(m, "9999.2", "<@UBOT> are you back?", { addressed: true }));
  await settle();
  assert.equal(r.store.getThread(thread.id)!.hiddenAt, null);
  assert.equal(heard(r.claude, "are you back?"), 1);
  await r.close();
});

test("a mention sent twice (Slack's app_mention and message) restores, records and delivers once, and says nothing", async () => {
  const r = new Rig();
  const { m, key } = await archivedThread(r);
  const before = given(r.chat);
  let restores = 0;
  const setArchived = r.store.setArchived.bind(r.store);
  r.store.setArchived = (k, to, by) => {
    if (!to) restores++;
    return setArchived(k, to, by);
  };
  const again = reply(m, "9999.1", "<@UBOT> again please", { addressed: true });
  await Promise.all([r.accept(again), r.accept({ ...again })]);
  await settle();
  assert.equal(restores, 1);
  assert.deepEqual(archived(r, key), [false, null]);
  assert.equal(texts(r, m).filter((t) => t.includes("again please")).length, 1);
  assert.equal(heard(r.claude, "again please"), 1);
  assert.deepEqual(given(r.chat).posts, before.posts);
  await r.close();
});

test("a mention from before the archive, sent again by the platform, does not restore it", async () => {
  const r = new Rig();
  const { m, key } = await archivedThread(r);
  const before = given(r.chat);
  await r.accept(m);
  await settle();
  assert.deepEqual(archived(r, key), [true, MANUAL]);
  assert.deepEqual(given(r.chat), before);
  assert.equal(heard(r.claude, "look at the build"), 1);
  await r.close();
});

test("another bot's first mention in the thread starts that bot alone; the one archived by hand waits for its own", async () => {
  const r = new Rig();
  const { m, key } = await archivedThread(r);
  const other = sessionKey("gpt", "C1", m.threadTs);
  const call = reply(m, "9999.1", "<@UGPT> your turn");
  // The archived bot's connect sees it too, before and after: not its mention.
  await r.accept(call);
  assert.equal(r.store.getSession(other), null);
  await r.accept({ ...call, addressed: true }, "gpt");
  await r.accept(call);
  await settle();
  assert.deepEqual(archived(r, key), [true, MANUAL]);
  assert.deepEqual(archived(r, other), [false, null]);
  assert.equal(heard(r.codex, "your turn"), 1);
  assert.equal(heard(r.claude, "your turn"), 0);
  assert.equal(texts(r, m).filter((t) => t.includes("your turn")).length, 1);
  // What is said there reaches the other alone, its files too, whichever connect sees it first.
  for (const c of [r.chat, r.gptChat]) c.shared.set("F1", "content");
  await r.accept(reply(m, "9999.2", "see this", { files: [note("F1")] }));
  await settle();
  assert.deepEqual(archived(r, key), [true, MANUAL]);
  assert.equal(heard(r.codex, "see this"), 1);
  assert.equal(heard(r.claude, "see this"), 0);
  await r.call(other, "chat_history", { to: `C1/${m.threadTs}`, fetch: ["F1"] });
  const [file] = r.said(r.thread("C1", m.threadTs).id).find((e) => e.text === "see this")!.attachments;
  assert.equal(dirname(file!.path), join(r.session(other).workspace, "uploads"));
  assert.ok(!existsSync(join(r.session(key).workspace, "uploads")), "nothing written where it is put away");
  // Its own mention brings it back, though the other's connect recorded the message first.
  const both = reply(m, "9999.3", "<@UBOT> and you?");
  await r.accept(both, "gpt");
  await r.accept({ ...both, addressed: true });
  await settle();
  assert.deepEqual(archived(r, key), [false, null]);
  assert.equal(heard(r.claude, "and you?"), 1);
  await r.close();
});

test("a thread hidden by hand with another agent's mention: shown again, and only that agent started", async () => {
  const r = new Rig();
  const { m, key } = await archivedThread(r);
  const thread = r.thread("C1", m.threadTs);
  r.store.setThreadHidden(thread.id, true, MANUAL);
  await r.accept(reply(m, "9999.1", "<@UGPT> your turn", { addressed: true }), "gpt");
  await settle();
  assert.equal(r.store.getThread(thread.id)!.hiddenAt, null);
  assert.deepEqual(archived(r, key), [true, MANUAL]);
  assert.equal(heard(r.codex, "your turn"), 1);
  await r.close();
});

test("a thread hidden by hand, its agent archived by the station since: a mention restores both", async () => {
  const r = new Rig();
  const m = say("<@UBOT> look at the build");
  await r.accept(m);
  await settle();
  const key = sessionKey("cl", "C1", m.threadTs);
  await ended(r, r.claude, key);
  const thread = r.thread("C1", m.threadTs);
  r.store.setThreadHidden(thread.id, true, MANUAL);
  r.store.setArchived(key, true, AUTO);
  await r.accept(reply(m, "9999.1", "not for you"));
  await settle();
  assert.deepEqual(archived(r, key), [true, AUTO]);
  await r.accept(reply(m, "9999.2", "<@UBOT> are you back?", { addressed: true }));
  await settle();
  assert.deepEqual(archived(r, key), [false, null]);
  assert.equal(r.store.getThread(thread.id)!.hiddenAt, null);
  assert.equal(heard(r.claude, "are you back?"), 1);
  await r.close();
});

for (const teamRequireMention of [true, false]) {
  test(`a single-session connect's agent archived by hand hears no chatter and comes back on a mention (requireMention ${teamRequireMention})`, async () => {
    const r = new Rig({ teamRequireMention });
    const m = say("<@UTEAM> build A");
    await r.accept(m, "team");
    await settle();
    const key = r.store.binding("team")!;
    await ended(r, r.claude, key);
    archive(r.hub, key, true);
    await settle();
    const before = given(r.teamChat);
    const chatter = say("anyone around?", { addressed: false, channel: "C2" });
    await r.accept(chatter, "team");
    await r.accept(reply(m, "9999.1", "and tests too"), "team");
    await settle();
    assert.equal(r.store.threadAt("slack:T1", "C2", chatter.threadTs), null, "no thread opened for it");
    assert.deepEqual(archived(r, key), [true, MANUAL]);
    assert.deepEqual(given(r.teamChat), before);
    assert.equal(heard(r.claude, "anyone around?") + heard(r.claude, "and tests too"), 0);
    // A mention in a thread it was never in.
    await r.accept(say("<@UTEAM> build B", { channel: "C3" }), "team");
    await settle();
    assert.equal(r.store.binding("team"), key, "the same session");
    assert.equal(r.store.listSessions().length, 1);
    assert.deepEqual(archived(r, key), [false, null]);
    assert.equal(heard(r.claude, "build B"), 1);
    assert.deepEqual(given(r.teamChat).posts, before.posts);
    // Back in the thread it had, too.
    await r.accept(reply(m, "9999.2", "still there?"), "team");
    await settle();
    assert.equal(heard(r.claude, "still there?"), 1);
    await r.close();
  });
}

test("agents of one conversation are archived together, and a mention of either restores them all", async () => {
  for (const mentioned of ["cl", "gpt"] as const) {
    const r = new Rig();
    const m = say("<@UBOT> <@UGPT> look");
    await r.accept(m);
    await r.accept(m, "gpt");
    await settle();
    const keys = [sessionKey("cl", "C1", m.threadTs), sessionKey("gpt", "C1", m.threadTs)];
    assert.equal(r.store.conversationOf(keys[1]!), keys[0], "one conversation");
    await ended(r, r.claude, keys[0]!);
    await ended(r, r.codex, keys[1]!);
    archive(r.hub, keys[0]!, true);
    await settle();
    assert.deepEqual(keys.map((k) => archived(r, k)), [[true, MANUAL], [true, MANUAL]]);
    const before = [given(r.chat).posts, given(r.gptChat).posts];
    const back = reply(m, "9999.1", "back again");
    // Both connects see it, the one it mentions last.
    await r.accept(back, mentioned === "cl" ? "gpt" : "cl");
    await r.accept({ ...back, addressed: true }, mentioned);
    await settle();
    assert.deepEqual(keys.map((k) => archived(r, k)), [[false, null], [false, null]], mentioned);
    assert.deepEqual([given(r.chat).posts, given(r.gptChat).posts], before);
    assert.deepEqual([heard(r.claude, "back again"), heard(r.codex, "back again")], [1, 1], "as any message of the thread, to each once");
    await r.close();
  }
});

test("an agent that left the thread and was then archived by hand hears it again once mentioned", async () => {
  const r = new Rig();
  const m = say("<@UBOT> look at the build");
  await r.accept(m);
  await settle();
  const key = sessionKey("cl", "C1", m.threadTs);
  await r.call(key, "chat_leave", { to: `C1/${m.threadTs}` });
  await ended(r, r.claude, key);
  archive(r.hub, key, true);
  await settle();
  await r.accept(reply(m, "9999.1", "<@UBOT> are you back?", { addressed: true }));
  await settle();
  assert.deepEqual(archived(r, key), [false, null]);
  assert.equal(heard(r.claude, "are you back?"), 1);
  await r.close();
});

test("a file sent with the mention is written once the workspace put away is back, from every thread of the agent", async () => {
  let back: () => void = () => {};
  const returned = new Promise<void>((done) => (back = done));
  let restores = 0;
  const r = new Rig({ cold: { isCold: async () => false, pack: () => {}, restore: () => (restores++, returned) } });
  const m = say("<@UTEAM> build A");
  await r.accept(m, "team");
  await settle();
  const key = r.store.binding("team")!;
  await ended(r, r.claude, key);
  archive(r.hub, key, true);
  await settle();
  r.teamChat.shared.set("F1", "content");
  r.teamChat.shared.set("F2", "content");
  // (no agent opens meanwhile: one given the message too soon would wait on the restore, and `settle` on it)
  r.hub.hold("drain");
  const m2 = say("<@UTEAM> the second file", { channel: "C2", files: [note("F2")] });
  await r.accept(reply(m, "9999.1", "<@UTEAM> the first file", { addressed: true, files: [note("F1")] }), "team");
  await r.accept(m2, "team");
  const fetchFirst = r.call(key, "chat_history", { to: `C1/${m.threadTs}`, fetch: ["F1"] });
  const fetchSecond = r.call(key, "chat_history", { to: `C2/${m2.threadTs}`, fetch: ["F2"] });
  await settle();
  const early = [...r.teamChat.downloads];
  const shown = archived(r, key);
  back();
  await Promise.all([fetchFirst, fetchSecond]);
  r.hub.release("drain");
  await settle();
  assert.deepEqual(shown, [false, null], "shown at once");
  assert.equal(restores, 1);
  assert.deepEqual(early, [], "nothing written as it comes back");
  assert.deepEqual([...r.teamChat.downloads].sort(), ["F1", "F2"]);
  assert.deepEqual([heard(r.claude, "the first file"), heard(r.claude, "the second file")], [1, 1]);
  await r.close();
});

test("a still.fail chat archived by hand stays refused until a person restores it", async () => {
  const r = new Rig();
  const { m, key } = await archivedThread(r);
  const home = ensureConversationChat(r.hub, key, "ada@example.com", null);
  archive(r.hub, key, true);
  const [own, chat] = await newSession(r.hub, { runtime: "claude" as const, createdBy: "ada@x.com" });
  archiveChat(r.hub, chat.id, true);
  for (const thread of [home.id, chat.id]) assert.throws(() => sayIn(r.hub, thread, "ada@x.com", "hi"), /手动归档|archived manually/);
  for (const k of [key, own]) assert.deepEqual(archived(r, k), [true, MANUAL]);
  // Restored by the mention in its thread, its chat takes words again.
  await r.accept(reply(m, "9999.1", "<@UBOT> are you back?", { addressed: true }));
  await settle();
  sayIn(r.hub, home.id, "ada@x.com", "hi");
  await settle();
  assert.equal(heard(r.claude, "are you back?"), 1);
  assert.throws(() => sayIn(r.hub, chat.id, "ada@x.com", "hi"), /手动归档|archived manually/);
  await r.close();
});
