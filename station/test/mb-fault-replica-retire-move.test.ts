// The MoonBit station (`stillfail-reader run`, no Node on its PATH) through what the TypeScript's own retirement
// tests hold (replica-retire), two real stations over real loopback iroh: a station's retirement previewed as what it
// holds (its chats, accounts of its home workspace, connects), its start refused while retiring is switched off
// (replica/AGENTS.md, module.ts RETIRE_STARTS) with nothing written nor asked of the other, and the whole station
// moved instead (station_move `all`, what replaces it): refused while the station picked is down with nothing changed
// here, then every chat, transcript, room (nested, executable), account and connect on the station picked beside its
// own chat, the station left answering its old chats with where they went. Under scripts/native.ts run (mesh runner
// archive-rs reader launcher).
import assert from "node:assert/strict";
import { randomBytes } from "node:crypto";
import { chmodSync, existsSync, mkdirSync, statSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { test } from "node:test";
import { FakeFeishu } from "./feishu-fake.ts";
import { setupRetireHarness, skip, closers, given, readJson, http, treeOf, findNamed, rows, handedTo, pair, texts, chat, movePage, itemOf } from "./mb-fault-replica-retire-harness.ts";

setupRetireHarness();

// ── 2. a station's retirement previewed and refused; the whole station moved instead ──

test("a station's retirement previewed as what it holds, its start refused while retiring is switched off, nothing written nor asked of the other; moved whole instead: refused while the station picked is down, nothing changed; then its chats, transcripts, rooms, account and connect on the station picked beside its own chat, the station left answering its old chats with where they went", { skip, timeout: 300_000 }, async () => {
  const feishu = await FakeFeishu.start();
  closers.push(() => void feishu.close());
  const leavingProfiles = [{ id: "lk", name: "Leaving key", runtime: "claude", home: "homes/lk", access: { kind: "anthropic-api", key: "sk-ant-leaving-only" }, models: ["claude-opus-5-5"] }];
  const takerProfiles = [{ id: "tk", name: "Taker key", runtime: "claude", home: "homes/tk", access: { kind: "anthropic-api", key: "sk-ant-taker-only" }, models: ["claude-opus-5-5"] }];
  const connects = [{ id: "f1", kind: "feishu", enabled: true, name: "Leaving bot", bind: { runtime: "claude" }, feishu: { appId: "cli_leaving", appSecret: "sec-leaving", domain: "feishu" } }];
  const { a, b, stations, start, store, started } = await pair(
    ["leaving", "taker"],
    [{ language: "en", updateChannel: "beta", profiles: leavingProfiles, connects, maxNudges: 0 }, { language: "en", updateChannel: "beta", profiles: takerProfiles, maxNudges: 0 }],
    [{ STILLFAIL_FEISHU_API: feishu.base }, { STILLFAIL_FEISHU_API: feishu.base }],
  );
  let [leaving, taker] = stations;
  const both = () => `leaving: ${leaving.err()}\ntaker: ${taker.err()}`;
  const storeL = store(a.data);
  const storeT = store(b.data);

  // two chats on the station leaving, a room with nested and executable files; the taker's own chat
  const l1 = await chat(leaving.door, storeL, "lk", "the first chat, on the station leaving", both);
  const l2 = await chat(leaving.door, storeL, "lk", "the second chat, on the station leaving", both);
  const ws1 = storeL.getSession(l1.key)!.workspace;
  writeFileSync(join(ws1, "notes.md"), "# notes\nwritten on the station leaving\n");
  mkdirSync(join(ws1, "deep", "er"), { recursive: true });
  writeFileSync(join(ws1, "deep", "er", "blob.bin"), randomBytes(200_000));
  writeFileSync(join(ws1, "run.sh"), "#!/bin/sh\necho moved\n");
  chmodSync(join(ws1, "run.sh"), 0o755);
  const room1 = treeOf(ws1);
  // (a new session is written no instructions file: give the second room a file of its own to carry)
  writeFileSync(join(storeL.getSession(l2.key)!.workspace, "plan.md"), "# plan\n");
  const room2 = treeOf(storeL.getSession(l2.key)!.workspace);
  const t1 = await chat(taker.door, storeT, "tk", "the taker's own chat", both);
  const takerOwn = await texts(taker.door, t1.thread);
  const said1 = await texts(leaving.door, l1.thread);
  const said2 = await texts(leaving.door, l2.thread);
  // (each chat's runtime session, from the fake's notes: the transcripts that go along are named by it)
  const sidOf = (n: number) => started()[n]!.split(" ")[2]!;
  const [sid1, sid2] = [sidOf(0), sidOf(1)];
  await given("f1 connected", async () => (await http(leaving.door, "/admin-api/overview")).json?.connects?.find((c: any) => c.id === "f1")?.connection?.state === "connected", both);

  // ── the preview: this station's chats of its home workspace, its own account and its connect ──
  const preview = await http(leaving.door, "/admin-api/retire/preview");
  assert.equal(preview.status, 200, preview.text);
  const shown = preview.json;
  assert.equal(shown.home, true, preview.text);
  assert.equal(shown.chats + shown.archived, 2, preview.text);
  assert.equal(shown.archived, 0, preview.text);
  assert.deepEqual(shown.accounts.map((x: any) => [x.id, x.name]), [["lk", "Leaving key"]]);
  assert.deepEqual(shown.accountsStay, []);
  assert.deepEqual(shown.connects.map((c: any) => c.id), ["f1"]);
  assert.deepEqual(shown.jobs, []);

  // ── its start refused while retiring is switched off: said in words, nothing written, the other asked nothing ──
  const retire = await http(leaving.door, "/admin-api/retire", { body: { to: b.id } });
  assert.equal(retire.status, 409, retire.text);
  assert.match(String(retire.json?.error), /switched off for now|暂时关闭/);
  assert.equal(existsSync(join(a.data, "replica", "retiring.json")), false, "nothing written");
  const overviewOf = async (port: number) => (await http(port, "/admin-api/overview")).json;
  assert.equal((await overviewOf(leaving.door)).copies?.retiring ?? null, null, JSON.stringify((await overviewOf(leaving.door)).copies));
  assert.deepEqual((await overviewOf(taker.door)).copies?.taking ?? [], [], "the station picked told nothing");
  assert.equal(handedTo(a.data, l1.key), null);

  // ── moved whole to the station picked while it is down: refused in words naming it, nothing held or changed here ──
  await given("the chats movable to the taker", async () => itemOf(await movePage(leaving.door, b.id), "chats", l1.key)?.state === "here", async () => `${JSON.stringify(await movePage(leaving.door, b.id))}; ${both()}`, 30_000);
  const wsBefore = rows<{ key: string; ws: string | null }>(a.data, "SELECT key, ws FROM sessions ORDER BY key");
  await taker.stop();
  const down = await http(leaving.door, "/admin-api/move", { body: { to: b.id, all: true } });
  if (down.status === 202) {
    // (taken, then failed in the turn: said on the page, nothing gone)
    await given("the whole move toward the station down ended", async () => (await movePage(leaving.door, b.id))?.moving === null, async () => `${JSON.stringify(await movePage(leaving.door, b.id))}; ${both()}`, 90_000);
  } else {
    assert.equal(down.status, 409, down.text);
    assert.match(String(down.json?.error), /taker/, down.text);
  }
  for (const k of [l1.key, l2.key]) assert.equal(handedTo(a.data, k), null, k);
  assert.deepEqual(treeOf(ws1), room1);
  assert.deepEqual(await texts(leaving.door, l1.thread), said1);
  assert.deepEqual(rows<{ key: string; ws: string | null }>(a.data, "SELECT key, ws FROM sessions ORDER BY key"), wsBefore, "nothing held as handed or coming");
  assert.deepEqual(readJson(join(a.data, "config.json")).profiles.map((p: any) => p.id), ["lk"], "its account still here");
  assert.deepEqual(readJson(join(a.data, "config.json")).connects.map((c: any) => c.id), ["f1"], "its connect still here");

  // ── the station picked back: moved whole, every chat there ──
  taker = await start(1);
  await given("the chats movable to the taker again", async () => {
    const page = await movePage(leaving.door, b.id);
    return page?.moving === null && [l1.key, l2.key].every((k) => itemOf(page, "chats", k)?.state === "here" && itemOf(page, "chats", k)?.cannot === undefined);
  }, async () => `${JSON.stringify(await movePage(leaving.door, b.id))}; ${both()}`, 45_000);
  const moved = await http(leaving.door, "/admin-api/move", { body: { to: b.id, all: true } });
  assert.equal(moved.status, 202, moved.text);
  const done = await given("everything there", async () => {
    const page = await movePage(leaving.door, b.id);
    return page?.moving === null && [l1.key, l2.key].every((k) => itemOf(page, "chats", k)?.state === "there") ? page : null;
  }, async () => `${JSON.stringify(await movePage(leaving.door, b.id))}; ${both()}`, 120_000);
  assert.equal(itemOf(done, "connects", `f1@${a.id}`)?.state, "there", JSON.stringify(done));
  const account = done.modules.find((m: any) => m.id === "accounts")?.items ?? [];
  assert.deepEqual(account.map((x: any) => [x.label, x.state]), [["Leaving key", "there"]], JSON.stringify(account));

  // the chats there beside its own, their messages and rooms as they were (nested, executable)
  for (const k of [l1.key, l2.key]) assert.equal(handedTo(a.data, k)?.station, b.id, k);
  const there1 = await given("the first chat on the taker", () => storeT.getSession(l1.key), both);
  const there2 = await given("the second chat on the taker", () => storeT.getSession(l2.key), both);
  assert.deepEqual(treeOf(there1.workspace), room1);
  assert.deepEqual(treeOf(there2.workspace), room2);
  assert.equal(statSync(join(there1.workspace, "run.sh")).mode & 0o777, 0o755);
  const thread1 = storeT.sessionThreads(l1.key)[0]!.thread.id;
  const thread2 = storeT.sessionThreads(l2.key)[0]!.thread.id;
  assert.deepEqual(await texts(taker.door, thread1), said1);
  assert.deepEqual(await texts(taker.door, thread2), said2);
  assert.deepEqual(await texts(taker.door, t1.thread), takerOwn, "the taker's own chat as it was");
  assert.notEqual(thread1, t1.thread);
  // their transcripts under the taker's data directory
  for (const sid of [sid1, sid2]) assert.ok(findNamed(b.data, `${sid}.jsonl`).length >= 1, `${sid}'s transcript on the taker`);

  // the account (its host) and the connect on the taker, the station left keeping only a borrowed copy of the account
  // and no connect: of its home workspace, they move (move/AGENTS.md accounts: a whole move moves a login's host)
  const cfgT = readJson(join(b.data, "config.json"));
  const cfgL = readJson(join(a.data, "config.json"));
  const hosted = (cfgT.profiles as any[]).filter((p) => p.access?.key === "sk-ant-leaving-only");
  assert.equal(hosted.length, 1, JSON.stringify(cfgT.profiles));
  assert.equal(hosted[0].share?.borrowed, undefined, "hosted on the taker now");
  assert.ok((cfgT.profiles as any[]).some((p) => p.id === "tk" && p.access?.key === "sk-ant-taker-only"), "the taker's own account stays");
  assert.deepEqual((cfgL.profiles as any[]).map((p) => [p.id, p.share?.borrowed, p.share?.host]), [["lk", true, b.id]], "borrowed from the taker on the station left");
  assert.deepEqual((cfgT.connects as any[]).map((c) => [c.id, c.kind, c.feishu?.appId, c.enabled]), [[`f1@${a.id}`, "feishu", "cli_leaving", true]]);
  assert.deepEqual(cfgL.connects ?? [], [], "the connect gone from the station left");

  // ── the station left answers its old chats with where they went, runs nothing for them ──
  const turnsHere = storeL.listTurns(l1.key).length;
  const stale = await http(leaving.door, `/admin-api/threads/${l1.thread}/messages`, { body: { text: "to the station left" } });
  assert.equal(stale.status, 409, stale.text);
  assert.deepEqual([stale.json.moved?.session, stale.json.moved?.station, stale.json.moved?.there], [l1.key, b.id, thread1], stale.text);
  const goneTo = await http(leaving.door, `/admin-api/moved?session=${encodeURIComponent(l1.key)}`);
  assert.equal(goneTo.status, 200, goneTo.text);
  assert.deepEqual(goneTo.json.moved.map((m: any) => [m.session, m.station, m.there]).sort(), [[l1.key, b.id, thread1], [l2.key, b.id, thread2]].sort());
  // ── and the chat goes on on the taker, its runtime session taken up there ──
  const onTaker = await http(taker.door, `/admin-api/threads/${thread1}/messages`, { body: { text: "said on the taker" } });
  assert.ok(onTaker.status < 300, onTaker.text);
  await given("the taker's turn on the moved chat", async () => (await texts(taker.door, thread1)).includes("taker-reply-2"), async () => `${JSON.stringify(await texts(taker.door, thread1))}; ${both()}`, 30_000);
  assert.ok(started().includes(`taker resume ${sid1}`), JSON.stringify(started()));
  assert.equal(storeL.listTurns(l1.key).length, turnsHere, "nothing ran on the station left");
  await Promise.all([leaving.stop(), taker.stop()]);
});
