// Where a chat stands for its viewer (src/chat-stage.ts): the board's column, what needs them, what is just delivered.
import assert from "node:assert/strict";
import { test } from "node:test";
import * as stage from "../src/chat-stage.ts";
import { holdLanguage } from "../src/i18n.ts";

holdLanguage();
// deno-lint-ignore no-explicit-any
type J = any;

const me = { id: "lin@x.com", email: "lin@x.com" };
const creator = (email: string) => ({ id: email, email, name: email.split("@")[0] });
const done = (extra: J = {}): J => ({ key: "s1", process: "cold", lastTurn: { declared: "final", outcome: "completed", startedAt: 1, endedAt: 2 }, ...extra });
const card = (seq: number, assignee?: string): J => ({
  seq,
  card: { type: "options", options: [{ label: "A" }, { label: "B" }], ...(assignee ? { assignee } : {}) },
  message: { seq, ts: "9.1", text: "A or B?", authorName: "Claude" },
  before: [],
});
const blocked = (): J => ({ key: "s1", process: "cold", lastTurn: { declared: "block", ending: "need_help", outcome: "completed", startedAt: 1, endedAt: 2 } });

test("a_card_the_viewer_decides_waits_for_them_read_or_not", () => {
  const row: J = { mine: true, creator: creator("lin@x.com"), agents: [blocked()], card: card(5), unread: true };
  assert.equal(stage.boardStageOf(row, me), "wait");
  assert.equal(stage.boardStageOf({ ...row, unread: false }, me), "wait", "looked at, not answered: it still waits");
  assert.equal(stage.needsViewer({ ...row, unread: false }, me), true);
});

test("a_card_a_colleague_decides_is_at_work_for_the_viewer", () => {
  const row: J = { mine: true, creator: creator("lin@x.com"), agents: [blocked()], card: card(5, "ana@x.com") };
  assert.equal(stage.needsViewer(row, me), false);
  assert.equal(stage.hasOpenAskForOthers(row, me), true);
  assert.equal(stage.boardStageOf(row, me), "run");
  assert.equal(stage.boardStageOf(row, { id: "ana@x.com", email: "ana@x.com" }), "wait");
});

test("a_chat_an_agent_leads_needs_no_person", () => {
  const row: J = { mine: true, creator: creator("lin@x.com"), opener: { session: "p", led: true }, agents: [blocked()], card: card(5) };
  assert.equal(stage.isLedSubchat(row), true);
  assert.equal(stage.needsViewer(row, me), false);
  assert.equal(stage.hasOpenAskForOthers(row, me), false);
});

test("a_watch_kept_stays_watching_while_its_watch_wakes_it", () => {
  const watch = { names: ["CI"], since: 1, at: 2 };
  const running: J = { key: "s1", process: "running", lastTurn: { startedAt: 3, endedAt: null }, watch };
  assert.equal(stage.boardStageOf({ mine: true, agents: [running] }, me), "watch");
  assert.equal(stage.boardStageOf({ mine: true, agents: [done({ watch })] }, me), "watch");
  // (one that needs the viewer comes first, watch or not)
  const row: J = { mine: true, creator: creator("lin@x.com"), agents: [{ ...blocked(), watch }], card: card(5) };
  assert.equal(stage.boardStageOf(row, me), "wait");
});

test("a_leader_waiting_on_a_chat_it_leads_or_a_job_is_at_work", () => {
  const ended: J = { mine: true, agents: [done()] };
  assert.equal(stage.boardStageOf(ended, me), "done");
  assert.equal(stage.boardStageOf({ ...ended, agents: [done({ waitingAsync: true })] }, me), "run");
  const leads: J = { ...ended, opened: [{ session: "c", led: true, active: true }] };
  assert.equal(stage.boardStageOf(leads, me), "run");
  assert.equal(stage.subchatsLabel(leads), "1 个子会话进行中");
  const finished: J = { ...ended, opened: [{ session: "c", led: true }] };
  assert.equal(stage.boardStageOf(finished, me), "done");
  assert.equal(stage.subchatsLabel(finished), null);
});

test("a_failure_needs_the_viewer_who_started_it_until_let_go", () => {
  const failed: J = { key: "s1", process: "cold", lastTurn: { outcome: "failed", startedAt: 1, endedAt: 2 } };
  const row: J = { mine: true, creator: creator("lin@x.com"), agents: [failed] };
  assert.equal(stage.boardStageOf(row, me), "wait");
  assert.equal(stage.boardStageOf(row, me, { gone: ["x"], failureOf: () => "x" }), "done");
  assert.equal(stage.boardStageOf({ ...row, creator: creator("zhou@x.com") }, me), "done", "someone else's: told to whoever started it");
});

test("ended_unread_is_delivered_read_is_settled_and_says_nothing_more", () => {
  const row: J = { mine: true, agents: [done()], unread: true };
  assert.equal(stage.deliverable(row, stage.boardStageOf(row, me)), true);
  assert.deepEqual(stage.stageFields(row, me), {}, "an ended chat carries no byte more: its unread says it delivered");
  assert.equal(stage.settledOf({ ...row, unread: false }, "done"), true);
  assert.equal(stage.deliverable({ ...row, unread: false }, "done"), false);
  assert.deepEqual(stage.stageFields({ mine: true, agents: [], pending: true }, me), { stage: "run" });
});
