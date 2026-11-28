// Where a chat a chat's agent opened stands (present.openedState, views.ts #openedState): made of its agents as the
// row's line reads them (agentStated), and of its card through decisions.presentRow only where it has one. Each state
// said as it was when each agent was presented whole (present.session) and every row went through presentRow.
import assert from "node:assert/strict";
import { test } from "node:test";
import * as decisions from "../src/decisions.ts";
import { holdLanguage } from "../src/i18n.ts";
import * as present from "../src/present.ts";

holdLanguage();

// deno-lint-ignore no-explicit-any
type J = any;

/// As #openedState made it before: every agent presented whole, every row through presentRow.
function was(row: J): { mark: string | null; text: string | null; lead: string | null } {
  const agents: J[] = Array.isArray(row?.agents) ? row.agents : [];
  const shown = decisions.presentRow({ ...row, unread: false, agents: agents.map((a: J) => present.session(a)) });
  const line = present.rowStateLine(shown);
  return { mark: present.rowState(agents), text: line === null ? null : line[0], lead: line === null || line[3] === null ? null : line[3].kind };
}

const agent = (key: string, patch: J = {}): J => ({
  key, connect: "c1", profile: "p1", runtime: "claude", model: "claude-opus-5-5", effort: "high", process: "cold", pending: 0, lastTurn: null,
  runtimeSessionId: `rs-${key}`, contextActions: ["compact", "clear"], ...patch,
});
const row = (patch: J = {}): J => ({ id: "c", session: "c", thread: 7, title: "子任务", agents: [agent("c")], last: null, unread: true, mine: false, lastActiveAt: 1, ...patch });
const ended = (patch: J): J => ({ endedAt: 1000, outcome: "ok", about: { thread: 7, seq: 3 }, ...patch });
const card = (seq: number, patch: J = {}): J => ({ seq, card: { type: "text", placeholder: "sk_" }, message: { seq, ts: `${seq}.0`, text: "Stripe 的测试 key 是多少？", authorName: "Claude" }, before: [], ...patch });
const need = (seq: number, patch: J = {}): J => ({ seq, message: { seq, ts: `${seq}.0`, text: "要你看一下这个方案", authorName: "Claude" }, ...patch });

const STATES: [string, J][] = [
  ["idle", row()],
  ["idle_no_agents", row({ agents: [] })],
  ["run", row({ agents: [agent("c", { process: "running" })] })],
  ["run_turn_open", row({ agents: [agent("c", { lastTurn: { endedAt: null, outcome: null } })] })],
  ["queued", row({ agents: [agent("c", { pending: 2 })] })],
  ["block_need_help", row({ agents: [agent("c", { lastTurn: ended({ ending: "need_help", need: "确认旧缓存目录清理方案" }) })] })],
  ["block_declared", row({ agents: [agent("c", { lastTurn: ended({ declared: "need_decision" }) })] })],
  ["block_need_let_go", row({ agents: [agent("c", { lastTurn: ended({ ending: "need_help", need: "确认" }) })], need: need(4, { dismissed: true }), state: "block" })],
  ["block_need_waiting", row({ agents: [agent("c", { lastTurn: ended({ ending: "need_help", need: "确认" }) })], need: need(4), state: "block" })],
  ["card_pending", row({ card: card(5), agents: [agent("c", { lastTurn: ended({ ending: "need_help" }) })], state: "block" })],
  ["card_pending_idle", row({ card: card(5) })],
  ["card_pending_while_running", row({ card: card(5), agents: [agent("c", { process: "running" })] })],
  ["card_dismissed", row({ card: card(5, { dismissed: true }), agents: [agent("c", { lastTurn: ended({ ending: "need_help" }) })], state: "block" })],
  ["card_dismissed_done", row({ card: card(5, { dismissed: true }), agents: [agent("c", { lastTurn: ended({ ending: "final" }) })] })],
  ["decision_pending", row({ decision: { seq: 6, options: ["好", "不好"], message: { seq: 6, text: "**选哪个？**" } } })],
  ["decision_dismissed", row({ decision: { seq: 6, options: ["好"], dismissed: true, message: { seq: 6, text: "选哪个？" } }, agents: [agent("c", { lastTurn: ended({ ending: "final" }) })] })],
  ["failed", row({ agents: [agent("c", { lastTurn: ended({ outcome: "failed", detail: "boom" }) })] })],
  ["failed_start", row({ agents: [agent("c", { startFailed: true, pending: 1 })] })],
  ["unexpected", row({ agents: [agent("c", { lastTurn: ended({ outcome: "error" }) })] })],
  ["aborted", row({ agents: [agent("c", { lastTurn: ended({ outcome: "aborted" }) })] })],
  ["waiting", row({ agents: [agent("c", { lastTurn: ended({ ending: "waiting", waitFor: "CI", waitSeconds: 600 }) })] })],
  ["waiting_no_what", row({ agents: [agent("c", { lastTurn: ended({ ending: "waiting" }) })] })],
  ["watching", row({ agents: [agent("c", { watch: { id: "j1" }, lastTurn: ended({ ending: "waiting", waitFor: "部署" }) })] })],
  ["watching_off", row({ agents: [agent("c", { watch: { id: "j1" }, lastTurn: ended({ ending: "waiting", waitFor: "部署", waitWatch: false }) })] })],
  ["all_done", row({ agents: [agent("c", { lastTurn: ended({ ending: "final" }) })] })],
  ["all_done_with_need", row({ agents: [agent("c", { lastTurn: ended({ ending: "final", need: "去 staging 看一下" }) })] })],
  ["all_done_about_elsewhere", row({ agents: [agent("c", { lastTurn: ended({ ending: "final", about: { thread: 9, seq: 1 } }) })] })],
  ["mixed_agents", row({ agents: [agent("a", { lastTurn: ended({ ending: "final" }) }), agent("b", { lastTurn: ended({ outcome: "failed" }) }), agent("c", { process: "running" })] })],
  ["two_done_one_waiting", row({ agents: [agent("a", { lastTurn: ended({ ending: "final" }) }), agent("b", { lastTurn: ended({ ending: "waiting", waitFor: "review" }) })] })],
  ["agents_not_all_objects", row({ agents: [null, "bad", agent("c", { process: "running" })] })],
  ["card_null_need_not_a_need", row({ card: null, need: "confirm" })],
  ["agent_with_stale_shown_fields", row({ agents: [agent("c", { lastTurn: ended({ ending: "final" }), statusText: "旧的", mark: "run", tone: "bad", badgeText: "x" })] })],
];

test("a_chat_opened_stands_as_it_did_when_its_agents_were_presented_whole", () => {
  const kinds = new Set<string>();
  for (const [name, r] of STATES) {
    const now = present.openedState(r);
    assert.deepEqual(now, was(r), name);
    kinds.add(`${now.mark}/${now.lead}`);
  }
  // (the states cover each mark and each lead the line has)
  for (const k of ["null/null", "run/null", "block/need", "block/decision", "null/decision", "failed/null", "run/wait", "null/watch", "null/done"]) {
    assert.ok(kinds.has(k), `${k} among ${[...kinds].join(", ")}`);
  }
});

test("a_chat_opened_is_read_never_written", () => {
  for (const [name, r] of STATES) {
    const frozen = structuredClone(r);
    const deep = (v: J): J => {
      if (v !== null && typeof v === "object") {
        Object.freeze(v);
        for (const x of Object.values(v)) deep(x);
      }
      return v;
    };
    deep(r);
    present.openedState(r);
    assert.deepEqual(r, frozen, name);
  }
});

test("a_chat_opened_given_no_record_stands_nowhere", () => {
  for (const r of [null, undefined, {}]) assert.deepEqual(present.openedState(r), { mark: null, text: null, lead: null }, String(r));
  assert.deepEqual(present.openedState({}), was({}));
});
