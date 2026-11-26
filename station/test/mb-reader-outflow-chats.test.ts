// The chats a Comma connect sends of the workspace (`outflowChats`) by the MoonBit reader (station/mb
// src/readops/outflowchats.mbt; read/pool.ts MOVED) as the worker reads them, on the same data: chats working, done
// and unread by who started them, needing a card's assignee or whoever started it, failed, archived, a Slack thread
// named by its first line, one a Comma Router wrote in, one of another workspace; all since a time, or pages of them
// by their cursor, with and without where the session pages are, of the home workspace and of another; before the
// chats' order is prepared (the pool prepares it and asks again).
import assert from "node:assert/strict";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import { mbReaderBinary } from "../src/read/mb-reader.ts";
import { Readers } from "../src/read/pool.ts";
import { Store, newMessage } from "../src/store/store.ts";
import { REFERENCE, readersOf } from "./reference.ts";

const binary = mbReaderBinary();

test("the MoonBit reader reads the chats a Comma connect sends as the worker does", { skip: binary === null ? "the MoonBit program is not built here" : false }, async () => {
  const data = mkdtempSync(join(tmpdir(), "mb-reader-outflow-chats-"));
  writeFileSync(join(data, "config.json"), JSON.stringify({ connects: [{ id: "team", slack: { team: { id: "T1", name: "Team" } } }] }));
  writeFileSync(join(data, "slack-names.json"), JSON.stringify({ "u:T1:U1": { person: { name: "Ann", email: "Ann@X" } } }));
  const store = Store.open(join(data, "stillfail.db"), join(data, "archive"));
  const db = store.db;
  const session = (key: string, extra: Record<string, unknown> = {}) =>
    store.insertSession({ key, connect: "ember", runtime: "claude", profile: "cc", workspace: "/w", token: key, createdAt: 1, lastActiveAt: 1, ...extra } as Parameters<Store["insertSession"]>[0]);
  let ts = 0;
  const say = (t: number, kind: "person" | "agent", author: string, text: string, at: number, extra: Record<string, unknown> = {}) => {
    store.insertMessage({ ...newMessage(t, String(++ts), kind, author, text), at, ...extra } as ReturnType<typeof newMessage>);
    return Number(db.prepare("SELECT MAX(n) AS n FROM entries WHERE thread = ?").get(t)!.n);
  };
  const turn = (id: string, key: string, started: number, ended: number | null, outcome: string | null, declared: string | null, extra = "") =>
    db.prepare(`INSERT INTO turns(id,session_key,kind,started_at,ended_at,outcome,declared,need,detail${extra ? ",about_thread,about_n,about_ts" : ""}) VALUES (?,?,'input',?,?,?,?,?,?${extra ? ",?,?,'x'" : ""})`)
      .run(...[id, key, started, ended, outcome, declared, declared === "need_help" ? " a key " : null, outcome === "failed" ? "  it broke\nwhy" : null, ...(extra ? extra.split(",").map(Number) : [])]);
  const chat = (key: string, title: string | null, members: string[], by: string | null = "p@x") => {
    const id = store.openThread("ember", "CHAT", key, title, by).id;
    for (const m of members) store.joinThread(id, m, "ember");
    return id;
  };
  for (const key of ["work", "done", "need", "card", "fail", "arch", "router"]) session(key, { createdBy: "p@x" });
  session("far", { ws: "w2" });
  session("slacky", { connect: "team", createdBy: "slack:team:U1" });
  session("a b/é?", { createdBy: "p@x" });
  const work = chat("work", "Working", ["work", "far", "a b/é?"]);
  turn("w0", "a b/é?", 1150, null, null, null);
  say(work, "person", "p@x", "go", 1000);
  turn("w1", "work", 1100, null, null, null);
  const done = chat("done", "Done", ["done"]);
  say(done, "person", "p@x", "please", 1000);
  say(done, "agent", "done", "done it", 1200);
  turn("d1", "done", 1100, 1300, "completed", "all_done");
  const need = chat("need", null, ["need"]);
  say(need, "agent", "need", "need a key", 1500);
  turn("n1", "need", 1400, 1600, "completed", "need_help");
  const card = chat("card", "Card", ["card", "need"]);
  const asked = say(card, "agent", "card", "pick", 1700, { card: { type: "options", options: [{ label: "Ship", recommended: true }], assignee: "  Boss@X " } });
  turn("c1", "card", 1650, 1750, "completed", "need_decision", `${card},${asked}`);
  session("secret", { createdBy: "p@x" });
  const secretChat = chat("secret", "Secret", ["secret"]);
  say(secretChat, "agent", "secret", "approve vault", 1760, { card: { vault: { request: "req_1" }, assignee: " Sec@X " } });
  turn("s1", "secret", 1755, 1780, "completed", "need_help");
  const fail = chat("fail", "Fail", ["fail"], null);
  say(fail, "person", "q@x", "try", 1800);
  turn("f1", "fail", 1800, 1900, "failed", null);
  const arch = chat("arch", "Archived", ["arch"]);
  say(arch, "person", "p@x", "old", 2000);
  say(arch, "agent", "arch", "done before it went", 2040);
  db.prepare("UPDATE threads SET hidden_at = 2100 WHERE id = ?").run(arch);
  turn("a1", "arch", 2000, 2050, "completed", "all_done");
  const router = chat("router", "Router", ["router"]);
  say(router, "person", "slack:team:R1", "do this", 2200);
  db.prepare("INSERT INTO comma_router_connects (thread, connect, at) VALUES (?, 'st1/team', 2200)").run(router);
  db.prepare("INSERT INTO comma_task_participants (thread, connect, email, at) VALUES (?, 'st1/team', 'alice@x', 2200)").run(router);
  db.prepare("INSERT INTO reads (viewer, thread, n, at) VALUES ('p@x', ?, 99, 1)").run(router);
  turn("r1", "router", 2200, 2300, "completed", "all_done");
  const slack = store.openThread("slack:T1", "C1", "1.1", null, null).id;
  store.joinThread(slack, "slacky", "team");
  say(slack, "person", "U1", "<@U9>  first   line\nmore", 2400);
  const far = chat("far", "Far", ["far"]);
  say(far, "person", "z@x", "elsewhere", 2500);
  for (const key of ["ansCard", "closedCard", "ansNeed", "ansSysCard"]) session(key, { createdBy: "p@x" });
  const ansCard = chat("ansCard", "Answered Card", ["ansCard"]);
  const ansCardN = say(ansCard, "agent", "ansCard", "pick", 2600, { card: { type: "options", options: [{ label: "Go" }], assignee: "boss@x" } });
  turn("ac1", "ansCard", 2590, 2610, "completed", "need_decision", `${ansCard},${ansCardN}`);
  say(ansCard, "person", "boss@x", "Go", 2620);
  const closedCard = chat("closedCard", "Closed Card", ["closedCard"]);
  const closedCardN = say(closedCard, "agent", "closedCard", "pick", 2700, { card: { type: "options", options: [{ label: "Skip", action: "close" }], assignee: "boss@x" } });
  turn("cc1", "closedCard", 2690, 2710, "completed", "need_decision", `${closedCard},${closedCardN}`);
  db.prepare("INSERT INTO closed_cards(thread, n, viewer, at) VALUES (?, ?, 'boss@x', 2720)").run(closedCard, closedCardN);
  const ansNeed = chat("ansNeed", "Answered Need", ["ansNeed"]);
  const ansNeedN = say(ansNeed, "agent", "ansNeed", "which env?", 2800);
  turn("an1", "ansNeed", 2790, 2810, "completed", "need_help", `${ansNeed},${ansNeedN}`);
  say(ansNeed, "person", "p@x", "prod", 2820);
  const ansSysCard = chat("ansSysCard", "Answered With System Card", ["ansSysCard"]);
  say(ansSysCard, "agent", "ansSysCard", "approve vault", 2900, { card: { vault: { request: "req_2" }, assignee: "sec2@x" } });
  const ansSysOptN = say(ansSysCard, "agent", "ansSysCard", "pick too", 2910, { card: { type: "options", options: [{ label: "Yes" }], assignee: "boss@x" } });
  turn("as1", "ansSysCard", 2890, 2920, "completed", "need_decision", `${ansSysCard},${ansSysOptN}`);
  say(ansSysCard, "person", "boss@x", "Yes", 2930);
  const worker = new Readers(data, 1, REFERENCE);
  const program = readersOf(data, binary);
  const read = (r: Readers, op: string, args: unknown, lang: "zh" | "en") => r.read(op, args, lang).then((t) => JSON.parse(t), (e: Error & { status?: number }) => ({ error: e.message, status: e.status }));
  const pages = { origin: "https://app.x", workspace: "home ws", station: "st1" };
  const all = async (r: Readers) => {
    const out: unknown[] = [];
    for (const lang of ["zh", "en"] as const) {
      for (const since of [0, 1650, 99999, "x"]) {
        out.push(await read(r, "outflowChats", { since }, lang));
        out.push(await read(r, "outflowChats", { since, pages }, lang));
        out.push(await read(r, "outflowChats", { since, ws: { workspace: "w2", home: false } }, lang));
      }
      for (const [limit, before] of [[3, undefined], [3, "2200.0"], [2, "1700.5"], [0, "x.y"], [5000, "2400"], [2.5, " 2400 .0x10"]] as const)
        out.push(await read(r, "outflowChats", { since: 0, limit, before, pages }, lang));
    }
    return out;
  };
  try {
    const first = await all(program);
    assert.deepEqual(first, await all(worker));
    const said = JSON.stringify(first);
    for (const sign of ["\"state\":\"working\"", "\"kind\":\"done\"", "\"kind\":\"need\"", "\"waitsFor\":[\"boss@x\"]", "\"card\":\"options\"", "\"waitsFor\":[\"sec@x\"]", "\"card\":\"secret\"", "\"kind\":\"failed\"", "\"note\":\"it broke\"", "\"archived\":true",
      "\"router\":true", "\"routerConnects\":[\"st1/team\"]", "\"connectParticipants\":{\"st1/team\":[\"alice@x\"]}", "\"participants\":[\"p@x\",\"q@x\"]", "\"participants\":[\"ann@x\"]", "\"title\":\"first line\"", "\"url\":\"https://app.x/o/home ws/st1/", "a%20b%2F%C3%A9%3F", "\"more\":true", "\"next\":", "\"name\":\"Ann\"", "\"surface\":\"stillfail\""])
      assert.ok(said.includes(sign), sign);
    const homeChats = new Map(((first[0] as { chats: Array<Record<string, unknown>> }).chats).map((c) => [c.thread, c]));
    assert.equal(homeChats.get(ansCard)?.state, "working");
    assert.equal("attention" in (homeChats.get(ansCard) ?? {}), false);
    assert.equal(homeChats.get(closedCard)?.state, "ended");
    assert.equal("attention" in (homeChats.get(closedCard) ?? {}), false);
    assert.equal(homeChats.get(ansNeed)?.state, "working");
    assert.equal("attention" in (homeChats.get(ansNeed) ?? {}), false);
    assert.equal(homeChats.get(ansSysCard)?.state, "need_human");
    assert.deepEqual(homeChats.get(ansSysCard)?.attention, { kind: "need", waitsFor: ["sec2@x"], note: null, card: "secret" });
  } finally {
    worker.close(); program.close();
    store.close();
    rmSync(data, { recursive: true, force: true });
  }
});
