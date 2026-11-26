// The MoonBit station (`stillfail-reader run`, no Node on its PATH), two real stations over real loopback iroh: a
// hand-over's faults: a file changed, added and deleted while its first pass is sent is there as it was when the chat
// was held, and the station taking it killed mid-transfer leaves the chat working here, moved once that station is
// back. Under scripts/native.ts run (mesh runner archive-rs reader launcher).
import assert from "node:assert/strict";
import { randomBytes } from "node:crypto";
import { existsSync, readdirSync, readFileSync, unlinkSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { test } from "node:test";
import { setupRetireHarness, skip, given, readJson, http, treeOf, handedTo, pair, texts, chat, movePage, itemOf } from "./mb-fault-replica-retire-harness.ts";

setupRetireHarness();

// ── 3. a hand-over's faults: files changing as they are sent, the station taking them killed ──

/// The step of the newest hand-over out of `data` of `key` (`replica/handover/out/<id>.json`).
function outStep(data: string, key: string): string | null {
  const dir = join(data, "replica", "handover", "out");
  if (!existsSync(dir)) return null;
  let best: any = null;
  for (const f of readdirSync(dir).filter((n) => n.endsWith(".json"))) {
    const o = readJson(join(dir, f));
    if (o === null || (o.key !== key && o.session !== key && !(Array.isArray(o.keys) && o.keys.includes(key)))) continue;
    if (best === null || (o.at ?? 0) >= (best.at ?? 0)) best = o;
  }
  return best?.step ?? null;
}

test("a chat's files changed, added and deleted while its first pass is sent: there as they were when it was held; the station taking it killed mid-transfer: the chat goes on here with its files, and moves once that station is back", { skip, timeout: 300_000 }, async () => {
  const profiles = [{ id: "cc", name: "Claude", runtime: "claude", home: "homes/cc", access: { kind: "anthropic-api", key: "sk-ant-faults-test" }, models: ["claude-opus-5-5"] }];
  const config = { language: "en", updateChannel: "beta", profiles, maxNudges: 0 };
  const { a, b, stations, start, store } = await pair(["leaving", "taker"], [config, config]);
  let [leaving, taker] = stations;
  const both = () => `leaving: ${leaving.err()}\ntaker: ${taker.err()}`;
  const storeL = store(a.data);
  const storeT = store(b.data);
  // (a big file, so the first pass is under way long enough to change the room under it, yet sent within CI's slice)
  const big = () => randomBytes(48 * 1024 * 1024);

  // ── changed as it is sent ──
  const c1 = await chat(leaving.door, storeL, "cc", "the chat whose files change", both);
  const ws1 = storeL.getSession(c1.key)!.workspace;
  writeFileSync(join(ws1, "big.bin"), big());
  writeFileSync(join(ws1, "notes.md"), "before the move\n");
  writeFileSync(join(ws1, "doomed.txt"), "deleted as it is sent\n");
  await given("the chat movable", async () => itemOf(await movePage(leaving.door, b.id), "chats", c1.key)?.state === "here", async () => `${JSON.stringify(await movePage(leaving.door, b.id))}; ${both()}`, 30_000);
  assert.equal((await http(leaving.door, "/admin-api/move", { body: { to: b.id, module: "chats", item: c1.key, withNeeds: true } })).status, 202);
  await given("its first pass under way", () => outStep(a.data, c1.key) === "files", () => `step=${outStep(a.data, c1.key)}; ${both()}`, 30_000);
  writeFileSync(join(ws1, "notes.md"), "changed while it was sent, longer than before\n");
  unlinkSync(join(ws1, "doomed.txt"));
  writeFileSync(join(ws1, "added.txt"), "added while it was sent\n");
  const stepAfter = outStep(a.data, c1.key);
  assert.ok(stepAfter === "files" || stepAfter === "held", `the changes made before the chat was held (now ${stepAfter})`);
  const expected = treeOf(ws1);
  await given("the chat there", async () => {
    const page = await movePage(leaving.door, b.id);
    return page?.moving === null && itemOf(page, "chats", c1.key)?.state === "there";
  }, async () => `${JSON.stringify(await movePage(leaving.door, b.id))}; step=${outStep(a.data, c1.key)}; ${both()}`, 120_000);
  const there1 = await given("the chat on the taker", () => storeT.getSession(c1.key), both);
  const got = treeOf(there1.workspace);
  assert.deepEqual(got, expected, "the room as it was when held: changed, added, deleted");
  assert.equal(readFileSync(join(there1.workspace, "notes.md"), "utf8"), "changed while it was sent, longer than before\n");
  assert.equal(existsSync(join(there1.workspace, "doomed.txt")), false);

  // ── the station taking it killed mid-transfer ──
  const c2 = await chat(leaving.door, storeL, "cc", "the chat whose taker is killed", both);
  const ws2 = storeL.getSession(c2.key)!.workspace;
  writeFileSync(join(ws2, "big.bin"), big());
  writeFileSync(join(ws2, "notes.md"), "kept whatever happens\n");
  const room2 = treeOf(ws2);
  const said2 = await texts(leaving.door, c2.thread);
  await given("the second chat movable", async () => itemOf(await movePage(leaving.door, b.id), "chats", c2.key)?.state === "here", async () => `${JSON.stringify(await movePage(leaving.door, b.id))}; ${both()}`, 30_000);
  // (the turn's end read from what the station keeps of it, move/turn.json and move/last.json: a move page asked while
  // the station picked is down plans afresh, out of any turn, and waits out each of its questions of it)
  const lastOf = () => readJson(join(a.data, "move", "last.json"))?.w1 ?? null;
  const lastBefore = lastOf()?.at ?? 0;
  assert.equal((await http(leaving.door, "/admin-api/move", { body: { to: b.id, module: "chats", item: c2.key, withNeeds: true } })).status, 202);
  await given("its first pass under way", () => outStep(a.data, c2.key) === "files", () => `step=${outStep(a.data, c2.key)}; ${both()}`, 30_000);
  await taker.kill();
  const ended = await given("the move toward the killed station ended", () => {
    const last = lastOf();
    return !existsSync(join(a.data, "move", "turn.json")) && last !== null && last.at > lastBefore ? last : null;
  }, () => `last=${JSON.stringify(lastOf())}; step=${outStep(a.data, c2.key)}; ${both()}`, 90_000);
  // the chat here as it was: not handed, its files and messages
  assert.deepEqual(ended.failed?.item, { module: "chats", id: c2.key }, JSON.stringify(ended));
  assert.match(String(ended.failed?.error), /^The chat did not go to taker and goes on here: /, JSON.stringify(ended));
  assert.deepEqual(ended.done, [], JSON.stringify(ended));
  assert.equal(handedTo(a.data, c2.key), null);
  assert.deepEqual(treeOf(ws2), room2);
  assert.deepEqual(await texts(leaving.door, c2.thread), said2);
  // and it goes on here
  const turns = storeL.listTurns(c2.key).filter((t) => t.summary.endedAt != null).length;
  assert.ok((await http(leaving.door, `/admin-api/threads/${c2.thread}/messages`, { body: { text: "still here after the failed move" } })).status < 300);
  await given("the chat answered here after the failed move", () => storeL.listTurns(c2.key).filter((t) => t.summary.endedAt != null).length > turns, both, 30_000);

  // ── the station back: moved, its files byte for byte ──
  taker = await start(1);
  const room2now = treeOf(ws2);
  const failed = await given("the second chat movable again", async () => {
    const page = await movePage(leaving.door, b.id);
    const i = itemOf(page, "chats", c2.key);
    return page?.moving === null && i?.state === "failed" && i?.cannot === undefined ? i : null;
  }, async () => `${JSON.stringify(await movePage(leaving.door, b.id))}; ${both()}`, 60_000);
  // said why the move did not go and what to do, in the words of the request the kill cut: its files' sending, the ask
  // that followed them, or (the station found gone in the turn) any later one
  assert.match(String(failed.error), /^(?:the other station did not answer(?: while its files were being sent)?: (?:move it|try) again once it answers|taker does not answer: nothing more is asked of it in this move\. Move again once it is up\.)$/, JSON.stringify(failed));
  assert.equal((await http(leaving.door, "/admin-api/move", { body: { to: b.id, module: "chats", item: c2.key, withNeeds: true } })).status, 202);
  await given("the second chat there", async () => {
    const page = await movePage(leaving.door, b.id);
    return page?.moving === null && itemOf(page, "chats", c2.key)?.state === "there";
  }, async () => `${JSON.stringify(await movePage(leaving.door, b.id))}; ${both()}`, 120_000);
  const there2 = await given("the second chat on the taker", () => storeT.getSession(c2.key), both);
  assert.deepEqual(treeOf(there2.workspace), room2now);
  const thread2 = storeT.sessionThreads(c2.key)[0]!.thread.id;
  const saidThere = await texts(taker.door, thread2);
  for (const t of [...said2, "still here after the failed move"]) assert.equal(saidThere.filter((x) => x === t).length, 1, `${t} once: ${JSON.stringify(saidThere)}`);
  await Promise.all([leaving.stop(), taker.stop()]);
});
