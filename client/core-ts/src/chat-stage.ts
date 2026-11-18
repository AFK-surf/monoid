// Where a chat stands for its viewer, one rule for every place that says it (2026-11-16, the status refactor): the
// board's columns (`boardStageOf`), what the bell's 待处理 and the sidebar's counts hold (`needsViewer`), the app's
// badge and its notices. Three things kept apart: what its agents are doing (the station's facts: a turn running, a
// wait on work they started, a watch kept), what it asks and of whom (a card, an agent's need: its decider), and what
// the viewer read. A chat a chat's agent leads (chat_create for me: `opener.led`) asks that agent, never a person.
// Pure functions of a row as its station gives it (a list's record), and of who looks.
import * as decisions from "./decisions.ts";
import { t } from "./i18n.ts";
import * as present from "./present.ts";
import { arr as arrU, get as getU, str as strU } from "./util.ts";

// deno-lint-ignore no-explicit-any
type J = any;
const arr = (v: unknown): J[] => arrU(v) ?? [];
const get = (v: unknown, k: string): J => getU(v, k);

/// The board's columns but 待派发 (drafts are the device's): 等你处理, 监控中, 进行中, 待收口.
export type BoardStage = "wait" | "watch" | "run" | "done";

/// Whether an agent leads the chat (chat_create for me): it asks that agent, not a person.
export function isLedSubchat(row: J): boolean {
  return decisions.led(row);
}

/// Whether one of its agents keeps a watch running: it stays 监控中 while the watch wakes it, whatever the turn says.
export function hasActiveWatch(agents: J[]): boolean {
  return present.watches(agents);
}

/// Whether the viewer started a chat (a row that does not say: whether they take part in it).
export function startedBy(row: J, me: J): boolean {
  const creator = get(row, "creator");
  const who = typeof creator === "string" ? creator : (strU(get(creator, "email")) || strU(get(creator, "id")) || null);
  return me === null || me === undefined || who === null ? get(row, "mine") === true : present.isViewer(me, who, []);
}

/// Whether the chat went wrong for the viewer: an agent of a chat they take part in and started failed.
export function failedForViewer(row: J, me: J): boolean {
  return get(row, "mine") === true && present.rowState(arr(get(row, "agents"))) === "failed" && startedBy(row, me);
}

/// What the viewer let go of besides the row (`gone`: the failures they let go, as views/marks.ts `failureOf` names
/// them, `failureOf` naming this row's; `unsent`: a message sent here that did not go).
export type ViewerOpts = { gone?: ReadonlySet<string> | readonly string[]; failureOf?: () => string; unsent?: boolean };

/// Whether the chat needs the viewer now, read or not: a message of theirs that did not go, a card or need whose
/// decider they are (not let go), or it went wrong for them (a failure not let go). Never a chat an agent leads.
export function needsViewer(row: J, me: J, opts: ViewerOpts = {}): boolean {
  if (isLedSubchat(row)) return false;
  if (opts.unsent === true || get(row, "unsent") === true) return true;
  if (decisions.forViewer(row, me) !== null) return true;
  if (!failedForViewer(row, me)) return false;
  const gone = opts.gone;
  if (gone === undefined || opts.failureOf === undefined) return true;
  const id = opts.failureOf();
  return !(Array.isArray(gone) ? gone.includes(id) : (gone as ReadonlySet<string>).has(id));
}

/// Whether it asks something of someone else (a colleague decides its card or need): at work for the viewer.
export function hasOpenAskForOthers(row: J, me: J): boolean {
  return !isLedSubchat(row) && decisions.undecided(row).length > 0 && decisions.forViewer(row, me) === null;
}

/// Who decides what it asks when that is someone else (a colleague decides its card or need), as the workspace names
/// them: a member's name, the starter's as its row says them, else their address; null when it asks nobody else.
export function otherDecider(row: J, me: J, members: J[]): string | null {
  if (!hasOpenAskForOthers(row, me)) return null;
  const d = decisions.undecided(row)[0];
  const creator = get(row, "creator");
  const who = decisions.decider(d.card, creator);
  if (who === null) return null;
  const started = typeof get(d.card, "assignee") !== "string" ? strU(get(creator, "name")) || strU(get(get(creator, "shown"), "name")) || null : null;
  return present.memberName(members, who) ?? started ?? who;
}

/// A row's state line (present.rowStateLine's) for the viewer: where it asks a colleague, 等 周 处理：… under the
/// waiting arc in place of what asks the viewer (待处理 · …, 需要你处理：…), as the board has it at work for them.
export function lineForViewer(line: Line, row: J, me: J, members: J[]): Line {
  if (line === null || line[3] === null || (line[3].kind !== "decision" && line[3].kind !== "need")) return line;
  const name = otherDecider(row, me, members);
  if (name === null) return line;
  const asked = decisions.askOf(row, decisions.undecided(row)[0], me).text as string;
  const text = t("core-views.waits_on", { name, text: asked });
  return [text, null, asked, { kind: "wait", rest: text }];
}
type Line = ReturnType<typeof present.rowStateLine>;

/// Whether the viewer may put it away with 待收口's 归档已读: it ended, nothing in it left (present.archivable: each agent
/// all_done, nothing waiting, read, not pinned or kept, recommended where its station reviews), and they started it,
/// since archiving takes it off the whole workspace's lists (swipeAsk asks so for one alone).
export function archiveRead(row: J, me: J): boolean {
  return !isLedSubchat(row) && present.archivable(row) && startedBy(row, me);
}

/// Whether a chat it leads is still at work (its station's `opened`: `led`, `active`).
function leadsActive(row: J): boolean {
  return arr(get(row, "opened")).some((o) => get(o, "led") === true && get(o, "active") === true);
}

/// Whether its agents are at work: asked here and not made yet, not seated yet, a turn running or queued (or ended
/// waiting on work it started), a background job or a chat it leads still going (`waitingAsync`).
export function isRunningOrWaitingAsync(row: J): boolean {
  if (get(row, "pending") === true) return true;
  const agents = arr(get(row, "agents"));
  if (agents.length === 0) return true;
  if (agents.some((a) => {
    const s = present.sessionStatus(a);
    return s === "running" || s === "queued" || get(a, "waitingAsync") === true;
  })) return true;
  return leadsActive(row);
}

/// Whether its agents are seated and none has begun a turn (nothing asked of them yet). Of itself no stage: a chat a
/// connect made waits so for its first message from a person; a chat made here whose first message is still on its way
/// is at work (views.ts #unsentRow, `going`).
export function noTurnBegun(row: J): boolean {
  const agents = arr(get(row, "agents"));
  return agents.length > 0 && agents.every((a) => present.sessionStatus(a) === "idle");
}

/// The board's column of a chat for the viewer, the first that holds: it needs them (等你处理, even while it keeps
/// watch); a watch kept (监控中, while the watch wakes it too); at work, or asking a colleague (进行中); else ended
/// (待收口).
export function boardStageOf(row: J, me: J, opts: ViewerOpts = {}): BoardStage {
  if (needsViewer(row, me, opts)) return "wait";
  if (hasActiveWatch(arr(get(row, "agents")))) return "watch";
  if (isRunningOrWaitingAsync(row) || hasOpenAskForOthers(row, me)) return "run";
  return "done";
}

/// Of the ended (`stage` done): one the viewer has yet to read (a result just delivered).
export function deliverable(row: J, stage: BoardStage): boolean {
  return stage === "done" && get(row, "unread") === true;
}

/// Of the ended: one the viewer read (to archive).
export function settledOf(row: J, stage: BoardStage): boolean {
  return stage === "done" && get(row, "unread") !== true;
}

/// The chats it leads still at work, in words (1 个子会话进行中), for its row; those of them that ended asking it or gone
/// wrong said first (1 个子会话在等它处理: its own agent's to take up, never a person's, so said on its row); null when none is.
export function subchatsLabel(row: J): string | null {
  const active = arr(get(row, "opened")).filter((o) => get(o, "led") === true && get(o, "active") === true);
  if (active.length === 0) return null;
  const asking = active.filter((o) => get(o, "asks") === true).length;
  if (asking > 0) return asking === 1 ? t("core-views.subchats_asking_one") : t("core-views.subchats_asking", { n: asking });
  const n = active.length;
  return n === 1 ? t("core-views.subchats_running_one") : t("core-views.subchats_running", { n });
}

/// What a row says of where it stands besides (ChatItem `stage`, `subchats`, `archiveRead`): each left out at its most
/// common (done, none, not), so that a row of an ended chat carries no byte more than it says. (Delivered is a done
/// row's `unread`: not said again.)
export function stageFields(row: J, me: J, opts: ViewerOpts = {}): J {
  const stage = boardStageOf(row, me, opts);
  const out: J = {};
  if (stage !== "done") out.stage = stage;
  const subchats = subchatsLabel(row);
  if (subchats !== null) out.subchats = subchats;
  if (stage === "done" && archiveRead(row, me)) out.archiveRead = true;
  return out;
}
