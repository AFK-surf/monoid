// An agent's execution history as the clients show it: what actually ran, put together here so every
// client draws the same thing. Messages in and out, state marks and the agent's own words are boundaries; the tool
// calls and thinking between two boundaries fold into one group, named by its latest call (shapes: HistoryView).
import { agentsOf, args, doing, epochMs, importantCall, kindOf, type Known, tasksOf, told, toolName } from "./activity.ts";
import * as format from "./format.ts";
import * as brand from "./brand.ts";
import { current, t } from "./i18n.ts";
import { lineOf, markdown, type MdStore } from "./markdown.ts";
import * as present from "./present.ts";
import { money } from "./views/usage.ts";
import { isStationAuthor } from "./titles.ts";
import { sentFrom } from "./sent-from.ts";
import { withoutMentions } from "./titles.ts";
import { cleanCommand, cleanPath, closeCut, isOpaqueId, summaryCommand } from "./tool-step.ts";

// deno-lint-ignore no-explicit-any
type J = any;

/// What a history is read with besides its transcript.
export type Context = {
  threads: J[];
  members: J[];
  slackUsers: string[];
  botUserId: string | null;
  botName: string;
  /// The Slack people the station's agents heard from, by Slack id: what their mentions are shown as.
  slackNames?: [string, string][];
  runtime: string;
  started: boolean;
  offsetMin: number;
  workspaces: Map<string, format.SlackWorkspace>;
  /// Now, for the day a turn's time is said with (a turn of today says only its clock); absent: every turn says its clock alone.
  now?: number;
  /// The workspace's stations' names by id, for the calls that work on one (station_task); absent: none known.
  stations?: ReadonlyMap<string, string>;
  /// Where the trees of its Markdown are kept on the device (markdown.ts); absent: read here only.
  md?: MdStore;
};

/// An entry in this device's words: a call's result that is in its script's output, which its station leaves the
/// words of to the client (station/src/read/transcript.ts `inScript`).
function worded(e: J): J {
  return e?.inScript === true && e.text === "" ? { ...e, text: t("station.transcript.inScriptOutput") } : e;
}

// ── What is kept between two makings of a history ──
//
// A chat's page makes its history again whole as anything it read changes: while its agent works, its steps in flight,
// its phase and its usage change many times a second, and its transcript grows an entry or two at a time. Made afresh
// each time, a long one (a thousand entries, calls with inputs of tens of KB) took 250 ms on a phone and up to 8.7 s on
// a desktop each time (Cloud Trace `ms.history.make`, 0.1.10103 to 0.1.10130). So what it makes is kept, each part by what it
// is made of, and taken again only where all of that is the same: an input read as JSON by its words (argsOf), an
// entry's own facts by the entry (`entryKept`), an item shown by its first entry with every entry, step, word of its
// context, tree of Markdown and name it read (`Shown`), and a page's items whole by its entries (`Page`).
// `presentHistoryUncached` makes the same with nothing kept, what this is held to (history.test.ts).

/// How many inputs, and how many of their characters, `argsOf` keeps.
const ARGS_KEPT = 4096;
const ARGS_KEPT_CHARS = 4_000_000;
const argsKept = new Map<string, Record<string, J> | null>();
let argsKeptChars = 0;
/// Off while `presentHistoryUncached` makes a history: nothing kept is read or kept then.
let keeping = true;

/// A call's input read as JSON (activity.ts `args`), read once while kept: the history reads one call's input in
/// many places, and again each time it is made. What it answers is shared, so read-only (frozen).
function argsOf(text: string): Record<string, J> | null {
  if (!keeping) return args(text);
  const hit = argsKept.get(text);
  if (hit !== undefined) return hit;
  const a = args(text);
  if (a !== null) Object.freeze(a);
  argsKept.set(text, a);
  argsKeptChars += text.length;
  while (argsKept.size > ARGS_KEPT || (argsKeptChars > ARGS_KEPT_CHARS && argsKept.size > 1)) {
    const oldest = argsKept.keys().next().value as string;
    argsKept.delete(oldest);
    argsKeptChars -= oldest.length;
  }
  return a;
}

/// What is made of one entry alone: the entry as this device words it (`worded`, in its language), its call's phase,
/// whether its thought says anything.
type EntryKept = { lang?: string; worded?: J; phase?: "explore" | "act" | null; blank?: boolean };
const entryKept = new WeakMap<object, EntryKept>();

function keptOf(e: J): EntryKept | null {
  if (!keeping || e === null || typeof e !== "object") return null;
  let k = entryKept.get(e);
  if (k === undefined) entryKept.set(e, (k = {}));
  return k;
}

function wordedKept(e: J): J {
  if (e?.inScript !== true || e.text !== "") return e;
  const k = keptOf(e);
  if (k === null) return worded(e);
  const lang = current();
  if (k.lang !== lang) [k.lang, k.worded] = [lang, worded(e)];
  return k.worded;
}

/// What an item shown reads of its context besides its entries, one object for equal ones (`sigOf`): an item made
/// with the same object read the same.
type Sig = {
  lang: string;
  brand: string;
  threads: J[];
  members: J[];
  slackUsers: string[];
  botUserId: string | null;
  botName: string;
  slackNames: [string, string][] | undefined;
  offsetMin: number;
  workspaces: Map<string, format.SlackWorkspace>;
  stations: ReadonlyMap<string, string> | undefined;
};
const SIG_FIELDS = ["lang", "brand", "threads", "members", "slackUsers", "botUserId", "botName", "slackNames", "offsetMin", "workspaces", "stations"] as const;
const SIGS_KEPT = 8;
const sigs: Sig[] = [];

/// Whether two values say the same: the same object, or arrays, maps and plain objects of the same. The page makes
/// some of its context anew each time (views.ts `slackWorkspaces`, `stationNames`, the Slack people it filters).
function same(a: unknown, b: unknown): boolean {
  if (a === b) return true;
  if (a === null || b === null || typeof a !== "object" || typeof b !== "object") return false;
  if (a instanceof Map || b instanceof Map) {
    if (!(a instanceof Map) || !(b instanceof Map) || a.size !== b.size) return false;
    for (const [k, v] of a) if (!b.has(k) || !same(v, b.get(k))) return false;
    return true;
  }
  if (Array.isArray(a) || Array.isArray(b)) {
    if (!Array.isArray(a) || !Array.isArray(b) || a.length !== b.length) return false;
    for (let i = 0; i < a.length; i++) if (!same(a[i], b[i])) return false;
    return true;
  }
  const ka = Object.keys(a);
  if (ka.length !== Object.keys(b).length) return false;
  const has = Object.prototype.hasOwnProperty;
  for (const k of ka) if (!has.call(b, k) || !same((a as J)[k], (b as J)[k])) return false;
  return true;
}

function sigOf(cx: Context): Sig {
  const now: Sig = {
    lang: current(),
    brand: brand.name(),
    threads: cx.threads,
    members: cx.members,
    slackUsers: cx.slackUsers,
    botUserId: cx.botUserId,
    botName: cx.botName,
    slackNames: cx.slackNames,
    offsetMin: cx.offsetMin,
    workspaces: cx.workspaces,
    stations: cx.stations,
  };
  const at = sigs.findIndex((s) => SIG_FIELDS.every((f) => same(s[f], now[f])));
  if (at < 0) {
    sigs.unshift(now);
    if (sigs.length > SIGS_KEPT) sigs.pop();
    return now;
  }
  const kept = sigs[at];
  // The latest objects, so that the next time they are found by reference.
  Object.assign(kept, now);
  if (at > 0) sigs.unshift(...sigs.splice(at, 1));
  return kept;
}

/// What an item shown was made of: its context, the entries and steps it read (`deps`), the trees of Markdown it was
/// given (`md`) and the tasks' and agents' names it looked up (`names`), each to be the same to take it again.
type Shown = {
  sig: Sig;
  deps: unknown[];
  md: [string, unknown][];
  names: [0 | 1, string, string | undefined][];
  out: J;
  final: J;
  turn: { at: number | null; time: string | null } | null;
};
const shownKept = new WeakMap<object, Shown>();

/// A page of a history made last: its entries and context, and the items it showed.
type Page = { held: J[]; from: number; sig: Sig; day: number | null; base: number; shown: J[]; made: Shown[] };
const PAGES_KEPT = 8;
const pages: Page[] = [];

/// How much of a history was made afresh (items, not taken again): what history.test.ts holds the keeping to.
export const historyMade = { items: 0 };

function mdSame(made: Shown, store: MdStore | undefined): boolean {
  for (const [text, md] of made.md) if (markdown(text, store) !== md) return false;
  return true;
}

function pageOf(held: J[], from: number, sig: Sig, day: number | null, store: MdStore | undefined): Page | null {
  for (let p = 0; p < pages.length; p++) {
    const page = pages[p];
    if (page.from !== from || page.sig !== sig || page.day !== day || page.held.length !== held.length) continue;
    let all = true;
    for (let i = 0; i < held.length && all; i++) all = page.held[i] === held[i];
    if (!all || !page.made.every((m) => mdSame(m, store))) continue;
    if (p > 0) pages.unshift(...pages.splice(p, 1));
    return page;
  }
  return null;
}

function kindKey(kind: string): string {
  return ["read", "search", "edit", "command", "web", "agent", "thread"].includes(kind) ? kind : "other";
}

function did(kind: string, n: number): string {
  return t(`core-logic.history.did.${kindKey(kind)}`, { n });
}

function line(text: string, max: number): string {
  return Array.from(text.split("\n")[0] ?? "").slice(0, max).join("");
}

function jsExecCommand(text: string): string | null {
  const m = /(?:"cmd"|cmd|"command"|command)\s*:\s*("(?:[^"\\]|\\.)*")/.exec(text);
  if (!m?.[1]) return null;
  try {
    const parsed = JSON.parse(m[1]);
    return typeof parsed === "string" && parsed.trim() !== "" ? summaryCommand(parsed) : null;
  } catch {
    return null;
  }
}

export function hint(text: string, tool = ""): string {
  const name = toolName(tool);
  if (name.endsWith(" on Web")) {
    const a = argsOf(text);
    const q = typeof a?.query === "string" && a.query ? a.query : name.slice(0, -7).replace(/^["']|["']$/g, "");
    return line(q, 160);
  }
  const a = argsOf(text);
  if (!a) {
    const jsCmd = name === "exec" ? jsExecCommand(text) : null;
    if (jsCmd) return line(jsCmd, 160);
    return line(text, 160);
  }
  const kind = kindOf(tool, a);
  const keys =
    kind === "search"
      ? [
          "pattern",
          "Pattern",
          "query",
          "Query",
          "queries",
          "path",
          "Path",
          "target_directory",
          "DirectoryPath",
          "SearchDirectory",
          "SearchPath",
          "file_path",
          "target_file",
          "url",
          "description",
          "toolSummary",
          "summary",
          "prompt",
          "Prompt",
          "message",
          "Message",
          "text",
          "reason",
          "title",
          "Role",
          "to",
          "Recipient",
          "recipient",
        ]
      : [
          "command",
          "cmd",
          "CommandLine",
          "file_path",
          "target_file",
          "path",
          "Path",
          "target_directory",
          "DirectoryPath",
          "SearchDirectory",
          "SearchPath",
          "pattern",
          "Pattern",
          "url",
          "query",
          "Query",
          "queries",
          "description",
          "toolSummary",
          "summary",
          "prompt",
          "Prompt",
          "message",
          "Message",
          "text",
          "reason",
          "title",
          "Role",
          "to",
          "Recipient",
          "recipient",
        ];
  const ID_HINT_KEYS = new Set(["to", "Recipient", "recipient", "agent_id", "agentId", "conversationId"]);
  const key = keys.find((k) => {
    const v = a[k];
    if (v === undefined || v === null || v === "") return false;
    if (ID_HINT_KEYS.has(k) && typeof v === "string" && isOpaqueId(v)) return false;
    return true;
  });
  const fallbackKey = key === undefined
    ? Object.keys(a).find((k) => k !== "toolSummary" && !k.startsWith("_") && typeof a[k] === "string" && a[k].trim() !== "" && !isOpaqueId(a[k]))
    : undefined;
  const activeKey = key ?? fallbackKey;
  const value = activeKey !== undefined ? a[activeKey] : undefined;
  const raw = typeof value === "string" ? value : Array.isArray(value) ? value.map((p) => (typeof p === "string" ? p : "")).join(" ") : "";
  const isCmd = activeKey === "command" || activeKey === "cmd" || activeKey === "CommandLine";
  const isPath =
    activeKey === "file_path" ||
    activeKey === "target_file" ||
    activeKey === "path" ||
    activeKey === "Path" ||
    activeKey === "target_directory" ||
    activeKey === "DirectoryPath" ||
    activeKey === "SearchDirectory" ||
    activeKey === "SearchPath";
  const cleaned = isCmd ? summaryCommand(raw) : isPath ? cleanPath(raw) : raw;
  if (cleaned !== "") return line(cleaned, 160);
  if (tool.startsWith("File ")) return line(cleanPath(tool.slice(5).trim()), 160);
  if (kind === "command" && !["Bash", "bash", "run_command", "run_terminal_command", "exec", "exec_command", "shell", "local_shell"].includes(toolName(tool))) {
    return line(summaryCommand(toolName(tool)), 160);
  }
  return "";
}

function describe(text: string): string | null {
  const a = argsOf(text);
  const d = typeof a?.description === "string"
    ? a.description
    : typeof a?.toolSummary === "string"
    ? a.toolSummary
    : typeof a?.summary === "string"
    ? a.summary
    : null;
  if (d === null || d.trim() === "") return null;
  return line(d.trim(), 160);
}

function fileOf(text: string, tool = ""): string | null {
  const a = argsOf(text);
  if (a) {
    for (const k of ["file_path", "target_file", "path", "Path", "notebook_path"]) {
      if (typeof a[k] === "string" && a[k] !== "") return cleanPath(a[k]);
    }
  }
  if (tool.startsWith("File ")) {
    const p = tool.slice(5).trim();
    if (p !== "") return cleanPath(p);
  }
  return null;
}

function lineRangeOf(text: string): [number, number] | null {
  const a = argsOf(text);
  if (!a) return null;
  const start = typeof a.StartLine === "number" ? a.StartLine : typeof a.start_line === "number" ? a.start_line : undefined;
  const end = typeof a.EndLine === "number" ? a.EndLine : typeof a.end_line === "number" ? a.end_line : undefined;
  if (start !== undefined && end !== undefined && end >= start) {
    return [start, end];
  }
  if (typeof a.offset === "number" && typeof a.limit === "number" && a.limit > 0) {
    const from = Math.max(1, a.offset);
    return [from, from + a.limit - 1];
  }
  if (typeof a.limit === "number" && a.limit > 0 && a.offset === undefined && start === undefined) {
    return [1, a.limit];
  }
  return null;
}

function stepName(tool: string, text: string): string {
  const name = toolName(tool);
  if (name.endsWith(" on Web")) return "WebSearch";
  const a = argsOf(text);
  if (name === "edit" || name === "edit_file" || name === "replace_file_content" || name === "multi_replace_file_content" || name === "search_replace") return "Edit";
  if (name === "write" || name === "write_file" || name === "write_to_file") return "Write";
  if (name === "read" || name === "read_file" || name === "view_file_outline" || name === "view_code_item" || name === "read_image" || name === "view_image") return "Read";
  if (name.startsWith("File ")) {
    if (a && (a.Target !== undefined || a.Replacement !== undefined || a.old_string !== undefined || a.new_string !== undefined)) return "Edit";
    if (a && (a.Content !== undefined || a.content !== undefined)) return "Write";
    return "Read";
  }
  if (name === "bash" || name === "run_command" || name === "run_terminal_command" || name === "exec_command" || name === "shell" || name === "local_shell" || name === "write_stdin" || name === "wait" || name === "job_output") return "Bash";
  if (name === "grep" || name === "grep_search") return "Grep";
  if (name === "glob" || name === "find_by_name" || name === "find_file_by_name" || name === "list_dir" || name === "LS") return "Glob";
  if (name === "web_search" || name === "search_web" || name === "read_url_content" || name === "web__run") return "WebSearch";
  if (name === "web_fetch") return "WebFetch";
  if (name === "search_tool") return "ToolSearch";
  if (name === "subagent" || name === "spawn_agent" || name === "invoke_subagent" || name === "define_subagent" || name === "manage_subagents" || name === "swarm" || name === "send_message" || name === "SendMessage" || name === "followup_task" || name === "list_agents" || name === "wait_agent") return "Agent";
  if (kindOf(tool, a) === "command" && (a?.CommandLine !== undefined || /^(?:cd|git|pnpm|npm|node|cargo|python3?|sh|bash|zsh|rg|ls|cat|mkdir|rm|cp|mv|curl|gh)\b/.test(name))) {
    return "Bash";
  }
  return name;
}

const THOUGHT_BOILERPLATE_LINE =
  /^(?:I'm thinking(?: through how to approach this)?\.?|I am thinking(?: through how to approach this)?\.?|Let's think(?:\s+through\s+this|\s+about\s+this)?\.?|Thinking(?:\s+process)?(?:\.{3}|…|:)?|Thought\s+process:?|Process:?|Reasoning:?|(?:\d+\.\s*)?(?:\*\*)?(?:Analyze the Request|Analysis|Summary|Plan|Context|Goal|Steps|Next Steps|Approach|Findings|Observations):(?:\*\*)?|`?\d{4}-\d{2}-\d{2}T[\d:.]+Z`?[),.;:]*)$/i;

function cleanThoughtText(raw: string): string {
  const lines = raw.split(/\r?\n/);
  let i = 0;
  while (i < lines.length && (lines[i]!.trim() === "" || THOUGHT_BOILERPLATE_LINE.test(lines[i]!.trim()))) {
    i++;
  }
  const rest = lines.slice(i).join("\n").trim();
  return rest;
}

/// A message a prompt carried; `station`: a notice of the station's own (via="station"; "ember" before), not a person's; `agent`: an
/// agent's (marked `bot`: another session's letter, a bot in the thread), its words Markdown.
export type Sourced = { user: string; name: string | null; ts: string; text: string; thread: string | null; slack: boolean; station: boolean; agent: boolean };

/// What a station notice told its agent, read back from the words it was given (jobs.ts `named` and its notices,
/// opened.ts `notice`): a job's own words (`said`), or an event of a job's or of a chat it opened, in a line with what
/// more it carried (a job's last lines, its error, the chat's words); null for words of any other kind.
export type Notice =
  | { kind: "said"; name: string; said: string }
  | { kind: "event"; line: string; failed: boolean; chat: boolean; more: string | null; output: boolean };

const CHAT_ENDS: Record<string, [string, boolean]> = {
  "ended its turn all_done": ["done", false],
  "needs a person": ["human", false],
  "stopped with an error": ["failed", true],
  "was stopped by a person": ["stopped", false],
};

export function readNotice(text: string, stations?: ReadonlyMap<string, string>): Notice | null {
  const remote = /^Remote task (\S+) on (\S+): ([\s\S]*)$/.exec(text);
  if (remote) return remoteNotice(remote[1], stations?.get(remote[2]) ?? remote[2].slice(0, 8), remote[3]);
  const chat = /^The chat you opened, "(.+?)"(?: \(\S+\))?, (ended its turn all_done|needs a person|stopped with an error|was stopped by a person)(?:: ([\s\S]*?))?(?:\. They are asked there; help if you can, or wait)?\. Read it with chat_read; write to its agent with session_send to its link\.$/.exec(text);
  if (chat) {
    const [how, failed] = CHAT_ENDS[chat[2]];
    return { kind: "event", line: t(`core-logic.history.notice.chat.${how}`, { name: chat[1] }), failed, chat: true, more: chat[3] || null, output: false };
  }
  const restarted = text.startsWith("The station restarted; ");
  const job = /^(Job|Service) "(.+?)" \([^()\s,]+(?:, port \d+)?\) ([\s\S]*)$/.exec(restarted ? text.slice("The station restarted; ".length) : text);
  if (!job) return null;
  const [, kind, name, rest] = job;
  const what = t(kind === "Service" ? "core-logic.history.notice.service" : "core-logic.history.notice.job");
  const event = (key: string, failed: boolean, more: string | null = null, output = false, args: Record<string, string | number> = {}): Notice =>
    ({ kind: "event", line: t(`core-logic.history.notice.${key}`, { what, name, ...args }), failed, chat: false, more, output });
  if (!restarted && rest.startsWith("says: ")) return { kind: "said", name, said: rest.slice("says: ".length) };
  if (restarted && rest === "was started again.") return event("restarted", false);
  const unstarted = /^could not be started again: ([\s\S]*)$/.exec(rest);
  if (unstarted) return event("unstarted", true, unstarted[1]);
  const stopped = /^was stopped by (.+) from still\.fail's page\.$/.exec(rest);
  if (stopped) return event("stopped", false, null, false, { who: stopped[1] });
  const ended = /^ended with (?:exit code (-?\d+)|a signal)(; the station starts it again(?: in [\d.]+ s)?)?\.(?:\nIts last lines:\n```\n([\s\S]*)\n```)?$/.exec(rest);
  if (ended) {
    const again = ended[2] !== undefined ? "Again" : "";
    const code = ended[1] !== undefined ? Number(ended[1]) : null;
    return code !== null ? event(`exited${again}`, code !== 0, ended[3] ?? null, true, { code }) : event(`signaled${again}`, true, ended[3] ?? null, true);
  }
  return null;
}

/// What another station said of a task it runs for this session (remote.ts `settle`: its `task.get` answer as JSON, cut
/// short when long, or why it is no longer followed): its end in a line with its last lines, or what it said.
function remoteNotice(key: string, station: string, rest: string): Notice | null {
  const what = t("core-logic.history.notice.remote");
  const event = (k: string, failed: boolean, name: string, more: string | null = null, args: Record<string, string | number> = {}): Notice =>
    ({ kind: "event", line: t(`core-logic.history.notice.${k}`, { what, name: `${name} · ${station}`, ...args }), failed, chat: false, more, output: more !== null });
  if (!rest.startsWith("{")) return / is no longer followed\./.test(rest) ? event("lost", true, key) : null;
  let got: J;
  try {
    got = JSON.parse(rest);
  } catch {
    const cut = CLIPPED.exec(rest);
    if (!cut) return null;
    try {
      got = JSON.parse(closeCut(rest.slice(0, cut.index)));
    } catch {
      return null;
    }
  }
  const job = got?.job;
  const name = typeof job?.name === "string" && job.name !== "" ? job.name : key;
  const log = typeof got?.log === "string" && got.log.trim() !== "" ? got.log.replace(/\n+$/, "") : null;
  const state = typeof job?.state === "string" ? job.state : "";
  if (state === "" || state === "running") {
    // Its notices, newest first; cut short before its state, what it told is not known.
    const said = Array.isArray(got?.notices) ? got.notices.find((n: J) => typeof n?.text === "string")?.text : undefined;
    return said !== undefined ? { kind: "said", name, said } : event("remoteNews", false, name);
  }
  if (state === "stopped") return event("remoteStopped", false, name, log);
  const code = typeof job.exitCode === "number" ? job.exitCode : null;
  return code !== null ? event("exited", code !== 0, name, log, { code }) : event("signaled", true, name, log);
}

function attr(attrs: string, name: string): string | null {
  const key = `${name}="`;
  let from = 0;
  for (;;) {
    const at = attrs.indexOf(key, from);
    if (at < 0) return null;
    if (at === 0 || attrs[at - 1] === " ") {
      const rest = attrs.slice(at + key.length);
      const end = rest.indexOf('"');
      return end < 0 ? null : rest.slice(0, end);
    }
    from = at + key.length;
  }
}

/// Whether a tag's attributes carry `name` bare (`bot`), not inside a quoted value.
function bare(attrs: string, name: string): boolean {
  return attrs.replace(/"[^"]*"/g, '""').split(/\s+/).includes(name);
}

function tagEnd(text: string, open: number): number | null {
  let quoted = false;
  for (let i = open; i < text.length; i++) {
    const c = text[i];
    if (c === '"') quoted = !quoted;
    else if (c === ">" && !quoted) return i;
  }
  return null;
}

const unescape = (v: string) => v.replaceAll("&quot;", '"').replaceAll("&amp;", "&");

/// How the station ends words it cut to its length (station/src/read/transcript.ts `clip`).
const CLIPPED = /\n… \(\d+ more characters\)$/;

/// A message's words up to its closing tag; a prompt the station cut short before it, to the end.
function body(text: string, openEnd: number, closeTag: string): [string, number] | null {
  const start = text.startsWith("\n", openEnd) ? openEnd + 1 : openEnd;
  const at = text.indexOf(closeTag, start);
  if (at < 0) return CLIPPED.test(text) ? [text.slice(start), text.length] : null;
  const inner = text.slice(start, at);
  return [inner.endsWith("\n") ? inner.slice(0, -1) : inner, at + closeTag.length];
}

/// Splits a prompt still.fail built into the chat messages it carried and still.fail's own words around them.
export function parsePrompt(text: string): [Sourced[], string] {
  const messages: Sourced[] = [];
  let rest = "";
  let at = 0;
  for (;;) {
    const open = text.indexOf("<message ", at);
    if (open < 0) break;
    // still.fail's instructions given to a session continued from a terminal (station instructions.ts
    // `continuedHere`) show the shape of a message (thread="CHANNEL/THREAD_TS"): they carry none.
    const told = text.indexOf("<stillfail-instructions>", at);
    if (told >= 0 && told < open) {
      const end = text.indexOf("</stillfail-instructions>", told);
      const past = end < 0 ? text.length : end + "</stillfail-instructions>".length;
      rest += text.slice(at, past);
      at = past;
      continue;
    }
    const headEnd = tagEnd(text, open);
    if (headEnd === null) break;
    const b = body(text, headEnd + 1, "</message>");
    if (!b) break;
    const attrs = text.slice(open + 9, headEnd);
    const from = unescape(attr(attrs, "from") ?? "");
    let named: [string, string] | null = null;
    if (from.endsWith(")")) {
      const inner = from.slice(0, -1);
      const cut = inner.lastIndexOf(" (");
      if (cut >= 0) {
        const id = inner.slice(cut + 2);
        if (id !== "" && !/[() ]/.test(id)) named = [inner.slice(0, cut), id];
      }
    }
    messages.push({
      user: named ? named[1] : from,
      name: named ? named[0] : null,
      ts: attr(attrs, "ts") ?? "",
      text: b[0],
      thread: attr(attrs, "thread"),
      // A person in a Feishu chat is told as one in Slack is.
      slack: attr(attrs, "via") === "slack" || attr(attrs, "via") === "feishu",
      station: isStationAuthor(attr(attrs, "via")),
      agent: bare(attrs, "bot"),
    });
    rest += text.slice(at, open);
    at = b[1];
  }
  rest += text.slice(at);
  const second = rest;
  rest = "";
  at = 0;
  for (;;) {
    const open = second.indexOf('<slack user="', at);
    if (open < 0) break;
    const headEnd = tagEnd(second, open);
    if (headEnd === null) break;
    const b = body(second, headEnd + 1, "</slack>");
    if (!b) break;
    const attrs = second.slice(open + 7, headEnd);
    messages.push({ user: attr(attrs, "user") ?? "", name: null, ts: attr(attrs, "ts") ?? "", text: b[0], thread: null, slack: true, station: false, agent: bare(attrs, "bot") });
    rest += second.slice(at, open);
    at = b[1];
  }
  rest += second.slice(at);
  const note = rest
    .replace(/<card-state\b[^>]*>[\s\S]*?(?:<\/card-state>|$)/g, "")
    .replace(/^\[Delivered at [^\n]+\]\n?/gm, "")
    .split("\n")
    .filter((l) => !(l.startsWith("(Thread ") && l.endsWith(")") && l.includes(" had messages before you were brought in;")))
    .join("\n");
  return [messages, note.trim()];
}

/// Cleans station-injected prompt wrappers (`[Quote] From ...`, `Attached files:`, pasted-text instructions) in a
/// received user message so the person's own words stay front and center in the execution history.
export function cleanReceivedMessageText(raw: string): string {
  let cleaned = raw.replace(
    /(?:^|\n\n)\[Quote\] From [^\n]+:\n((?:>[^\n]*(?:\n|$))+)(?:Their comment on it:[ \t]*([^\n]*)(?:\n|$))?/g,
    (full, passage: string, comment?: string) => {
      const leadingBreak = full.startsWith("\n\n") ? "\n\n" : "";
      const nonEmpty = passage
        .split("\n")
        .map((l) => l.replace(/^>\s?/, "").trim())
        .filter((l) => l !== "");
      const first = nonEmpty[0] ?? "";
      const clipped = Array.from(first).slice(0, 100).join("");
      const suffix = nonEmpty.length > 1 || clipped.length < first.length ? " …" : "";
      const quoteLine = clipped !== "" ? `> ${clipped}${suffix}` : "";
      const commentLine = comment !== undefined && comment.trim() !== "" ? comment.trim() : "";
      const combined = [quoteLine, commentLine].filter(Boolean).join("\n");
      return combined !== "" ? `${leadingBreak}${combined}\n` : leadingBreak;
    },
  );
  cleaned = cleaned.replace(
    /(?:\n\n|^)The user pasted text into the composer; its full contents are in these text attachments\. Read them as part of the user's message:\n(?:- [^\n]+(?:\n|$))+/g,
    "",
  );
  cleaned = cleaned.replace(
    /(?:\n\n|^)Attached files:\n((?:- [^\n]+(?:\n|$))+)/g,
    (_full, list: string) => {
      const names = list
        .trim()
        .split("\n")
        .map((l) => {
          const m = /^- \/.*? \((.+), \d+ bytes\)$/.exec(l.trim());
          if (m?.[1]) return m[1];
          const p = l.replace(/^- /, "").trim();
          return p.split("/").pop() || p;
        })
        .filter(Boolean);
      return names.length > 0 ? `\n[附件: ${names.join(", ")}]` : "";
    },
  );
  return cleaned.replace(/\n{3,}/g, "\n\n").trim();
}

/// Work the agent started on its own that told it how it ended (Claude Code's `<task-notification>`): a background command
/// or a sub-agent, its name, how it ended and, a sub-agent's, what it answered.
export type Task = { agent: boolean; name: string; status: string; code: number | null; result: string | null };

function inner(block: string, tag: string, last = false): string | null {
  const open = block.indexOf(`<${tag}>`);
  if (open < 0) return null;
  const from = open + tag.length + 2;
  const close = last ? block.lastIndexOf(`</${tag}>`) : block.indexOf(`</${tag}>`, from);
  return (close < from ? block.slice(from) : block.slice(from, close)).trim();
}

/// Takes the task notifications out of still.fail's words to the agent: what they told, and the words left.
export function parseTasks(note: string): [Task[], string] {
  const tasks: Task[] = [];
  let rest = "";
  let at = 0;
  for (;;) {
    const open = note.indexOf("<task-notification>", at);
    if (open < 0) break;
    const close = note.indexOf("</task-notification>", open);
    const end = close < 0 ? note.length : close + "</task-notification>".length;
    const block = note.slice(open, close < 0 ? note.length : close);
    const summary = inner(block, "summary") ?? "";
    // "Background command "…" completed (exit code 0)", "… failed with exit code 1", "Agent "…" finished".
    const said = /^(Background command|Agent) "([\s\S]*)" (?:completed|failed|finished|was stopped)/.exec(summary);
    const code = /exit code (\d+)\)?$/.exec(summary);
    tasks.push({
      agent: said ? said[1] === "Agent" : inner(block, "result") !== null,
      name: said ? said[2] : summary,
      status: inner(block, "status") ?? "",
      code: code ? Number(code[1]) : null,
      result: inner(block, "result", true) || null,
    });
    rest += note.slice(at, open);
    at = end;
  }
  rest += note.slice(at);
  return [tasks, rest.trim()];
}

function taskText(task: Task): string {
  const what = task.agent ? "agent" : "command";
  const how = task.status === "completed" ? "done" : task.status === "failed" ? (task.code !== null ? "failed_code" : "failed") : task.status === "killed" ? "stopped" : "other";
  return t(`core-logic.history.task.${what}.${how}`, { name: task.name, code: task.code ?? 0, status: task.status });
}

function mentions(text: string, cx: Context): string {
  const bots: [string, string][] = cx.botUserId !== null ? [[cx.botUserId, cx.botName]] : [];
  return present.mentions(text, bots.concat(cx.slackNames ?? []), cx.members);
}

type Step = { call: number; result: number | null; unwrapped?: boolean; firstEntry?: number; scriptCount?: number; scriptTools?: string };
type Item =
  | { kind: "received"; i: number }
  | { kind: "text"; i: number }
  | { kind: "post"; step: number }
  | { kind: "mark"; mark: string; seconds: number | null; what: string | null; why: string | null }
  | { kind: "group"; rows: Row[] };
/// A group's thinking and calls, in the order they came: a thought by its timeline index, a call by its step.
type Row = { thought: number } | { step: number };

/// Whether a transcript entry begins an item whatever stands before it: a prompt, the agent's own words, a message it
/// posts, a state it ends its turn with. A thought or any other call goes on with the group before it, a result with
/// its call.
export function beginsItem(e: J): boolean {
  const kind = typeof e?.kind === "string" ? e.kind : "";
  if (kind === "tool_result" || kind === "thinking") return false;
  if (kind !== "tool_call") return true;
  if (e.subagent === true) return false;
  const name = toolName(typeof e.tool === "string" ? e.tool : "");
  const a = argsOf(typeof e.text === "string" ? e.text : "");
  return (name === "chat_post" && typeof a?.text === "string") || (name === "chat_state" && typeof a?.kind === "string");
}

/// How many of a page's first entries go on with an item begun before it (a group's calls and thoughts, a call's
/// result): all of them where none begins one.
export function carriedOver(timeline: readonly J[]): number {
  const at = timeline.findIndex(beginsItem);
  return at < 0 ? timeline.length : at;
}

export function presentHistory(live: J, cx: Context): J {
  return make(live, cx, true);
}

/// The same history made afresh, nothing of an earlier making taken again: what `presentHistory` is held to.
export function presentHistoryUncached(live: J, cx: Context): J {
  return make(live, cx, false);
}

function make(live: J, cx: Context, keep: boolean): J {
  const was = keeping;
  keeping = keep;
  try {
    return made(live, cx, keep);
  } finally {
    keeping = was;
  }
}

function made(live: J, cx: Context, keep: boolean): J {
  const held: J[] = Array.isArray(live?.timeline) ? live.timeline : [];
  const from = typeof live?.first === "number" ? live.first : 0;
  const sig = keep ? sigOf(cx) : null;
  const day = cx.now !== undefined ? format.localDay(cx.now, cx.offsetMin) : null;
  // The same entries in the same context: the items it showed, as they were (its steps in flight, its phase or its
  // usage are what changed).
  let page = sig !== null ? pageOf(held, from, sig, day, cx.md) : null;
  if (page === null) {
    page = itemsOf(held, from, cx, sig, day);
    if (sig !== null) {
      pages.unshift(page);
      if (pages.length > PAGES_KEPT) pages.pop();
    }
  }
  const { shown, base } = page;

  const pushedNow = pushed(live, cx.runtime);
  const liveSteps = pushedNow.liveSteps.map(({ id, text }) => ({ id, text }));
  const phase = pushedNow.phase;
  const { usage, usageLine } = usageOf(live?.usage);
  const loaded = live?.loaded === true;
  // Why its first read failed (it is read again), and how the page before stands: being read, or why it was not.
  const failed = typeof live?.failed === "string" && live.failed !== "" ? live.failed : null;
  const older = live?.older === "reading" || live?.older === "failed" ? live.older : null;
  let edge: string;
  let empty: boolean;
  if (!loaded && shown.length === 0) [edge, empty] = [t("core-logic.history.edge.loading"), true];
  else if (shown.length === 0 && liveSteps.length === 0 && phase === null && base === 0) {
    const why = live?.offline === true ? "core-logic.history.edge.offline" : cx.started ? "core-logic.history.edge.missing" : "core-logic.history.edge.not_started";
    [edge, empty] = [t(why), true];
  } else if (base > 0 && older === "failed") [edge, empty] = [t("core-logic.history.edge.earlier_failed", { why: String(live.olderFailed ?? "") }), false];
  else if (base > 0) [edge, empty] = [t("core-logic.history.edge.earlier"), false];
  else [edge, empty] = [t("core-logic.history.edge.start"), false];
  return { items: shown, live: liveSteps, phase, usage, usageLine, edge, empty, loaded, more: base > 0, ...(failed !== null && !loaded && shown.length === 0 ? { failed } : {}), ...(base > 0 && older !== null ? { older } : {}) };
}

/// Where a waiting mark's wait is over: what moves the agent on, a prompt bringing it back or a call of its own after
/// the mark (it went on working instead; a later state stands in its place); -1 while nothing has. Words it posts as
/// its turn ends are part of the ending, not more work.
function waitEnd(timeline: J[], mark: number): number {
  for (let j = mark + 1; j < timeline.length; j++) {
    const e = timeline[j];
    if (e?.subagent === true) continue;
    const kind = typeof e?.kind === "string" ? e.kind : "";
    const posting = kind === "tool_call" && toolName(typeof e.tool === "string" ? e.tool : "") === "chat_post" && typeof argsOf(typeof e.text === "string" ? e.text : "")?.kind !== "string";
    if (kind === "user" || (kind === "tool_call" && !posting)) return j;
  }
  return -1;
}

/// A page's items: each taken again where what it was made of is the same (`Shown`), else made.
function itemsOf(held: J[], from: number, cx: Context, sig: Sig | null, day: number | null): Page {
  // A page's first entries that go on with an item begun on the page before are left to that page: an item is shown
  // whole, and is the same item (its key, what it counts) however many pages are loaded. Shown in part, a group cut by
  // a page became another item as the page before came (its key its first loaded entry), and what was read jumped.
  const carried = from > 0 ? carriedOver(held) : 0;
  const timeline: J[] = (carried > 0 ? held.slice(carried) : held).map(wordedKept);
  const base = from + carried;
  const s = (e: J, k: string): string => (typeof e?.[k] === "string" ? e[k] : "");
  const flag = (e: J, k: string): boolean => e?.[k] === true;

  const items: [Item, number, number][] = [];
  const { steps, stepAt } = pair(timeline);
  const known: Known = { stations: cx.stations, tasks: tasksOf(timeline), agents: agentsOf(timeline, cx.threads) };
  let grouping = false;
  let groupSteps = 0;
  let groupPhase: "explore" | "act" | null = null;
  let groupHasAct = false;
  const isReadOnlyCommand = (tool: string, text: string): boolean => {
    const name = toolName(tool);
    if (name === "manage_task" || name === "sleep" || name === "get_output" || name === "command_status" || name === "wait" || name === "job_output") return true;
    const a = argsOf(text);
    if (name === "write_stdin") return typeof a?.chars !== "string" || a.chars === "";
    const raw =
      typeof a?.command === "string"
        ? a.command
        : typeof a?.cmd === "string"
          ? a.cmd
          : typeof a?.CommandLine === "string"
            ? a.CommandLine
            : Array.isArray(a?.command)
              ? a.command.filter((p: J): p is string => typeof p === "string").join(" ")
              : Array.isArray(a?.cmd)
                ? a.cmd.filter((p: J): p is string => typeof p === "string").join(" ")
                : name;
    const cmd = summaryCommand(raw);
    if (!cmd) return false;
    if (/^(?:rg|grep|egrep|fgrep|find|ls|cat|head|tail|wc|sed\s+-n|awk|stat|file|which|type|pwd|echo|ps|lsof)\b/.test(cmd)) return true;
    if (/^git\s+(?:status|log|diff|show|grep|ls-files|ls-tree|branch|rev-parse|remote|tag|blame)\b/.test(cmd)) return true;
    if (/^gh\s+(?:pr\s+(?:view|checks|list|diff|status)|issue\s+(?:view|list)|run\s+(?:view|list))\b/.test(cmd)) return true;
    if (/^(?:node|python3?)\s+.*(?:-[ec])\b/.test(cmd) && !/(?:writeFileSync|appendFileSync|rmSync|unlinkSync|\.write\()/.test(raw)) return true;
    return false;
  };
  const phaseOf = (tool: string, text: string): "explore" | "act" | null => {
    const name = toolName(tool);
    if (name === "station_task") {
      const act = argsOf(text)?.action;
      return act === "prepare" || act === "start" ? "act" : "explore";
    }
    if (name === "job_start") return "act";
    if (name === "job_list" || name === "job_log" || name === "station_list" || name === "device_list" || name === "adb_devices" || name === "screen") return "explore";
    const k = kindOf(tool, argsOf(text));
    if (k === "read" || k === "search" || k === "web" || k === "thread") return "explore";
    if (k === "command") return isReadOnlyCommand(tool, text) ? "explore" : "act";
    if (k === "edit" || k === "agent") return "act";
    return null;
  };
  // Of the entry alone (its tool and its input), so kept with it.
  const phaseOfEntry = (e: J): "explore" | "act" | null => {
    const k = keptOf(e);
    if (k === null) return phaseOf(s(e, "tool"), s(e, "text"));
    if (k.phase === undefined) k.phase = phaseOf(s(e, "tool"), s(e, "text"));
    return k.phase;
  };
  const blankThought = (e: J): boolean => {
    const k = keptOf(e);
    if (k === null) return cleanThoughtText(s(e, "text")) === "";
    if (k.blank === undefined) k.blank = cleanThoughtText(s(e, "text")) === "";
    return k.blank;
  };
  const cover = (i: number) => {
    const last = items[items.length - 1];
    if (last) last[2] = i;
  };
  timeline.forEach((e, i) => {
    const kind = s(e, "kind");
    if (kind === "tool_result") {
      cover(i);
    } else if (kind === "tool_call") {
      const step = stepAt.get(i)!;
      if (steps[step].unwrapped) {
        cover(i);
        return;
      }
      const a = argsOf(s(e, "text"));
      const arg = (k: string) => (typeof a?.[k] === "string" ? (a[k] as string) : null);
      const sub = flag(e, "subagent");
      const name = toolName(s(e, "tool"));
      if (name === "chat_post" && arg("text") !== null && !sub) {
        items.push([{ kind: "post", step }, i, i]);
        grouping = false;
        groupSteps = 0;
        groupPhase = null;
        groupHasAct = false;
      } else if (name === "chat_state" && arg("kind") !== null && !sub) {
        const sec = a?.seconds;
        const what = arg("for")?.trim() || null;
        const why = (arg("done") ?? arg("need"))?.trim() || null;
        items.push([{ kind: "mark", mark: arg("kind") ?? "", seconds: typeof sec === "number" ? Math.trunc(Math.max(sec, 0)) : null, what, why }, i, i]);
        grouping = false;
        groupSteps = 0;
        groupPhase = null;
        groupHasAct = false;
      } else {
        const nextPhase = phaseOfEntry(e);
        if (grouping && groupSteps >= 8) {
          const last = items[items.length - 1];
          const prevRows = last[0].kind === "group" ? last[0].rows : [];
          const hasTrailingThought = prevRows.length > 0 && "thought" in prevRows[prevRows.length - 1];
          const exploreToAct = !groupHasAct && groupPhase === "explore" && nextPhase === "act";
          const shouldSplit =
            (hasTrailingThought && (exploreToAct || groupSteps >= 28)) ||
            (exploreToAct && groupSteps >= 14) ||
            groupSteps >= 48;
          if (shouldSplit) {
            const carriedThoughts: Row[] = [];
            while (prevRows.length > 0 && "thought" in prevRows[prevRows.length - 1]) {
              carriedThoughts.unshift(prevRows.pop()!);
            }
            if (carriedThoughts.length > 0) {
              const firstThought = (carriedThoughts[0] as { thought: number }).thought;
              last[2] = Math.max(last[1], firstThought - 1);
              items.push([{ kind: "group", rows: carriedThoughts }, firstThought, i]);
            } else {
              items.push([{ kind: "group", rows: [] }, i, i]);
            }
            groupSteps = 0;
            groupPhase = null;
            groupHasAct = false;
          }
        }
        if (!grouping) {
          items.push([{ kind: "group", rows: [] }, i, i]);
          grouping = true;
          groupSteps = 0;
          groupPhase = null;
          groupHasAct = false;
        }
        const last = items[items.length - 1];
        if (last[0].kind === "group") {
          last[0].rows.push({ step });
          last[2] = i;
          groupSteps++;
          if (nextPhase !== null) {
            groupPhase = nextPhase;
            if (nextPhase === "act") groupHasAct = true;
          }
        }
      }
    } else if (kind === "thinking") {
      if (blankThought(e)) {
        cover(i);
        return;
      }
      if (!grouping) {
        items.push([{ kind: "group", rows: [] }, i, i]);
        grouping = true;
        groupSteps = 0;
        groupPhase = null;
        groupHasAct = false;
      }
      const last = items[items.length - 1];
      if (last[0].kind === "group") {
        last[0].rows.push({ thought: i });
        last[2] = i;
      }
    } else {
      grouping = false;
      groupSteps = 0;
      groupPhase = null;
      groupHasAct = false;
      items.push([kind === "user" ? { kind: "received", i } : { kind: "text", i }, i, i]);
    }
  });

  const isFailedResult = (rIdx: number | null) =>
    rIdx !== null && (timeline[rIdx]?.ok === false || /^Failed to call [\w.-]+:/.test(s(timeline[rIdx], "text")));
  const failedOf = (step: Step) => isFailedResult(step.result);
  // A post the station held back because a message the agent had not read came first (conversations.ts `NOT_POSTED`):
  // it went out only if a later chat_post sent it by its id. Else what the agent wrote here never reached the chat.
  // [whether it never went out, the entries that say so]
  const unsentOf = (step: Step): [boolean, unknown[]] => {
    if (step.result === null || failedOf(step)) return [false, []];
    const held = /\bNot posted: [\s\S]*?\bHeld as (held-\d+)\b/.exec(s(timeline[step.result], "text"));
    if (held === null) return [false, []];
    for (let j = step.result + 1; j < timeline.length; j++) {
      const e = timeline[j];
      if (s(e, "kind") !== "tool_call" || flag(e, "subagent") || toolName(s(e, "tool")) !== "chat_post" || argsOf(s(e, "text"))?.send !== held[1]) continue;
      const sent = stepAt.get(j);
      const r = sent !== undefined ? steps[sent].result : null;
      // Its answer not yet in: it is being sent.
      if (r === null || (!isFailedResult(r) && !/\bNot posted: /.test(s(timeline[r], "text")))) return [false, [j, e, r === null ? null : timeline[r]]];
    }
    return [true, [timeline.length]];
  };
  for (let idx = items.length - 1; idx >= 0; idx--) {
    const [cur, cFirst, cLast] = items[idx];
    if (cur.kind !== "text" || flag(timeline[cur.i], "subagent")) continue;
    const said = s(timeline[cur.i], "text").trim();
    if (!said) continue;
    const matchPost = (other: [Item, number, number] | undefined): boolean => {
      if (!other || other[0].kind !== "post") return false;
      const st = steps[other[0].step];
      if (failedOf(st)) return false;
      const a = argsOf(s(timeline[st.call], "text"));
      return typeof a?.text === "string" && a.text.trim() === said;
    };
    if (matchPost(items[idx + 1])) {
      items[idx + 1][1] = Math.min(items[idx + 1][1], cFirst);
      items.splice(idx, 1);
    } else if (matchPost(items[idx - 1])) {
      items[idx - 1][2] = Math.max(items[idx - 1][2], cLast);
      items.splice(idx, 1);
    }
  }

  // What an item reads of the page: its place, and each entry and step it is made of (by reference: entries are
  // shared, never changed). A wait reads on to what ended it, or to the end while nothing has.
  const depsOf = (item: Item, first: number, last: number): unknown[] => {
    const deps: unknown[] = [item.kind, base, first, last];
    switch (item.kind) {
      case "received":
      case "text":
        deps.push(item.i, timeline[item.i]);
        break;
      case "post": {
        const st = steps[item.step];
        deps.push(st.call, st.result, timeline[st.call], st.result !== null ? timeline[st.result] : undefined, ...unsentOf(st)[1]);
        break;
      }
      case "mark": {
        deps.push(item.mark, item.seconds, item.what, item.why);
        if (item.mark === "waiting") {
          const end = waitEnd(timeline, first);
          for (let j = first; j <= (end < 0 ? timeline.length - 1 : end); j++) deps.push(timeline[j]);
          deps.push(end < 0 ? timeline.length : -1);
        }
        break;
      }
      case "group":
        for (const r of item.rows) {
          if ("thought" in r) deps.push("t", r.thought, timeline[r.thought]);
          else {
            const st = steps[r.step];
            deps.push("s", st.call, st.result, st.firstEntry, st.scriptCount, st.scriptTools, timeline[st.call], st.result !== null ? timeline[st.result] : undefined);
          }
        }
        break;
    }
    return deps;
  };
  const sameDeps = (a: unknown[], b: unknown[]) => {
    if (a.length !== b.length) return false;
    for (let i = 0; i < a.length; i++) if (a[i] !== b[i]) return false;
    return true;
  };
  const namesSame = (m: Shown) => {
    for (const [which, key, name] of m.names) if ((which === 0 ? known.tasks : known.agents)?.get(key) !== name) return false;
    return true;
  };

  const place = (address: string | null, message: string | null = null) => (address === null ? null : format.place(cx.threads, address, cx.offsetMin, cx.workspaces, message));
  const render = (item: Item, first: number, last: number, md: [string, unknown][], names: [0 | 1, string, string | undefined][]): J => {
    // Each tree of Markdown given and each name looked up, to know that the item made of them stands.
    const mdOf = (text: string) => {
      const tree = markdown(text, cx.md);
      md.push([text, tree]);
      return tree;
    };
    const looked = (which: 0 | 1, map: ReadonlyMap<string, string> | undefined): ReadonlyMap<string, string> | undefined =>
      map === undefined
        ? undefined
        : ({
            get: (key: string) => {
              const name = map.get(key);
              names.push([which, key, name]);
              return name;
            },
          } as unknown as ReadonlyMap<string, string>);
    let v: J;
    switch (item.kind) {
      case "received": {
        const [messages, said] = parsePrompt(s(timeline[item.i], "text"));
        const [tasks, note] = parseTasks(said);
        // The station's own notices: an event of a job's or of a chat it opened, in a line as background work's end is.
        const notices = messages.map((m) => (m.station ? readNotice(m.text, cx.stations) : null));
        const events = notices.flatMap((n) => (n?.kind === "event" ? [n] : []));
        v = {
          kind: "received",
          note: note !== "" ? note : null,
          tasks: tasks.map((task) => answered({
            text: taskText(task),
            agent: task.agent,
            failed: task.status === "failed" || task.status === "killed",
            result: task.result,
            md: task.result !== null ? mdOf(task.result) : null,
          })).concat(events.map((n) => answered({
            text: n.line,
            agent: n.chat,
            failed: n.failed,
            result: n.more,
            // A job's output is a block of code, all of it.
            md: n.more === null ? null : n.output ? (n.more === "" ? [] : [["pre", { code: [0, n.more.length] }]]) : mdOf(n.more),
          }))),
          messages: messages.flatMap((m, k): J[] => {
            // A job's own words, as it wrote them (drawn in a monospaced font); still.fail's of any other kind, as they are.
            const notice = notices[k];
            if (notice?.kind === "event") return [];
            if (notice?.kind === "said") return [{ key: `${m.ts}.${k}`, from: { name: notice.name, slackUser: null, bound: false }, text: notice.said, place: null, notice: "job" }];
            if (m.station) return [{ key: `${m.ts}.${k}`, from: { name: brand.name(), slackUser: null, bound: false }, text: m.text, place: null, notice: "stillfail" }];
            // Another chat's agent's letter (session_send) goes by that chat's name, without the heading, as the chat's
            // page shows it: its station names it only by a session of its own ("another agent" from another station).
            const sent = m.agent ? sentFrom(m.text) : null;
            if (sent !== null) {
              const said = mentions(sent[2], cx);
              const title = withoutMentions(sent[0]).replace(/\s+/g, " ").trim() || mentions(sent[0], cx).replace(/^@/, "");
              return [{ key: m.ts, from: { name: title, slackUser: null, bound: false }, text: said, place: place(m.thread, m.slack ? m.ts : null), md: mdOf(said) }];
            }
            let from: J;
            if (m.slack) {
              const bound = cx.slackUsers.includes(m.user);
              const name = bound ? t("core-logic.history.you") : m.name !== null && m.name !== "" ? m.name : m.user;
              from = { name, slackUser: m.user, bound };
            } else {
              const name = present.memberName(cx.members, m.user) ?? (m.name !== null && m.name !== "" ? m.name : m.user);
              from = { name, slackUser: null, bound: false };
            }
            // A person's words are drawn as they wrote them; an agent's are Markdown, as a chat's page reads them.
            const said = mentions(cleanReceivedMessageText(m.text), cx);
            return [{ key: m.ts, from, text: said, place: place(m.thread, m.slack ? m.ts : null), ...(m.agent ? { md: mdOf(said) } : {}) }];
          }),
        };
        break;
      }
      case "text": {
        const said = s(timeline[item.i], "text");
        const md = mdOf(said);
        v = { kind: "text", text: said, md, line: lineOf(md, said), subagent: flag(timeline[item.i], "subagent") };
        break;
      }
      case "post": {
        const a = argsOf(s(timeline[steps[item.step].call], "text")) ?? {};
        const text = (k: string): string | null => (typeof a[k] === "string" ? a[k] : null);
        const kind = text("kind");
        const said = mentions(text("text") ?? "", cx);
        const isFailed = failedOf(steps[item.step]);
        const unsent = unsentOf(steps[item.step])[0];
        v = { kind: "post", text: said, md: mdOf(said), place: place(text("to")), block: kind === "block" || kind === "need_help" || kind === "need_decision", failed: isFailed, unsent };
        const ends = isFailed || unsent ? null : endsOf(kind);
        if (ends !== null && ends !== "waiting") v.ends = ends;
        break;
      }
      case "mark":
        if (item.mark === "waiting") {
          const at = (i: number): number | null => {
            const v = timeline[i]?.at;
            const ms = typeof v === "string" ? epochMs(v) : null;
            return ms === null ? null : Math.trunc(ms);
          };
          const since = at(first);
          let until: number | null = null;
          if (since !== null) {
            const end = waitEnd(timeline, first);
            if (end >= 0) until = at(end) ?? since;
          }
          const waited = since !== null && until !== null ? (() => {
            const w = Math.trunc(Math.max(until - since, 0) / 1000);
            return item.seconds === null ? w : Math.min(w, item.seconds);
          })() : null;
          const how =
            waited !== null && item.seconds !== null
              ? t("core-logic.history.waited_most", { waited: span(waited), most: span(item.seconds) })
              : waited !== null
                ? t("core-logic.history.waited", { waited: span(waited) })
                : item.seconds !== null
                  ? t("core-logic.history.waiting_most", { most: span(item.seconds) })
                  : t("core-logic.history.waiting");
          // What it waited for (chat_state's `for`) leads, as the activity line says it.
          const text = item.what !== null ? `${item.what} · ${how}` : how;
          v = { kind: "mark", text, wait: since !== null ? { since, until, seconds: item.seconds, what: item.what } : null, ends: "waiting" };
        } else {
          const m = item.mark;
          const baseText =
            m === "final" || m === "all_done"
              ? t("core-logic.history.mark.final")
              : m === "need_human"
                ? t("core-logic.history.mark.human")
                : m === "block" || m === "need_help"
                  ? t("core-logic.history.mark.block")
                  : m === "need_decision"
                    ? t("core-logic.history.mark.decision")
                    : t("core-logic.history.mark.other", { mark: m });
          v = {
            kind: "mark",
            text: item.why !== null ? `${baseText}：${item.why}` : baseText,
          };
          const ends = endsOf(m);
          if (ends !== null) v.ends = ends;
        }
        break;
      case "group":
        v = group(timeline, steps, item.rows, base, { stations: known.stations, tasks: looked(0, known.tasks), agents: looked(1, known.agents) }, mdOf);
        break;
    }
    const kind = v.kind ?? null;
    delete v.kind;
    const out: J = { key: `e${base + first}`, entries: [base + first, base + last], body: { kind, content: v } };
    // Its own work (its steps and thoughts, and the words it says to itself): what 只看收发 leaves out.
    if (kind === "group" || kind === "text") out.work = true;
    return out;
  };
  const makings: Shown[] = items.map(([item, first, last]) => {
    const deps = depsOf(item, first, last);
    // Kept by the entry it begins at: one item of a page begins at each.
    const head = timeline[first];
    const keyed = sig !== null && head !== null && typeof head === "object";
    const kept = keyed ? shownKept.get(head) : undefined;
    if (kept !== undefined && kept.sig === sig && sameDeps(kept.deps, deps) && namesSame(kept) && mdSame(kept, cx.md)) return kept;
    if (sig !== null) historyMade.items++;
    const md: [string, unknown][] = [];
    const names: [0 | 1, string, string | undefined][] = [];
    const out = render(item, first, last, md, names);
    const m: Shown = { sig: sig!, deps, md, names, out, final: out, turn: null };
    if (keyed) shownKept.set(head, m);
    return m;
  });

  // Turns: each prompt that woke the agent (not one of a sub-agent's) begins one, on its item; its time is shown when
  // at least TURN_TIME_GAP_MS (or a local day boundary) has passed since the last shown turn time. Items before the
  // first loaded one belong to a turn that began on an earlier page.
  const TURN_TIME_GAP_MS = 5 * 60_000;
  let lastTurnTimeAt: number | null = null;
  const shown = items.map(([item, first], n) => {
    const m = makings[n];
    let turn: { at: number | null; time: string | null } | null = null;
    if (item.kind === "received" && !flag(timeline[item.i], "subagent")) {
      const rawAt = typeof timeline[first]?.at === "string" ? epochMs(timeline[first].at) : null;
      const at = rawAt === null ? null : Math.trunc(rawAt);
      const showTime =
        at !== null &&
        (lastTurnTimeAt === null ||
          Math.abs(at - lastTurnTimeAt) >= TURN_TIME_GAP_MS ||
          format.localDay(at, cx.offsetMin) !== format.localDay(lastTurnTimeAt, cx.offsetMin));
      if (showTime) lastTurnTimeAt = at;
      turn = { at, time: showTime ? (cx.now !== undefined ? format.dayClock(at, cx.now, cx.offsetMin) : format.clock(at, cx.offsetMin)) : null };
    }
    // What is kept is never changed: an item with its turn is another object, made again only as its turn changes.
    const sameTurn = turn === null ? m.turn === null : m.turn !== null && m.turn.at === turn.at && m.turn.time === turn.time;
    if (!sameTurn) {
      m.turn = turn;
      m.final = turn === null ? m.out : { ...m.out, turn: { ...(turn.at !== null ? { at: turn.at } : {}), ...(turn.time !== null ? { time: turn.time } : {}) } };
    }
    return m.final;
  });
  return { held: sig !== null ? held.slice() : held, from, sig: sig!, day, base, shown, made: makings };
}

/// What a session's calls used (views/brief.ts `usageNow`), as its history shows it: label and value rows, and in a
/// line; and on their own, what its card shows of it (views/brief.ts): the context it carries (how full its window is,
/// when known) and the cost. Nothing before the station has counted any.
export function usageOf(u: J): { usage: J[] | null; usageLine: string | null; context: string | null; contextPercent: number | null; cost: string | null } {
  const isUsage = u !== null && typeof u === "object" && !Array.isArray(u);
  const n = (k: string): number => (isUsage && typeof u[k] === "number" ? u[k] : 0);
  // The context and the cost come from stations since; an older one's usage has neither.
  const has = (k: string): boolean => isUsage && typeof u[k] === "number";
  const contextPercent = has("contextTokens") && n("modelCalls") > 0 && n("contextWindow") > 0 ? format.round((n("contextTokens") / n("contextWindow")) * 100) : null;
  const context = has("contextTokens") && n("modelCalls") > 0
    ? contextPercent !== null
      ? t("core-logic.history.usage.context.of", { n: format.compactNumber(n("contextTokens")), window: format.compactNumber(n("contextWindow")), percent: contextPercent })
      : format.compactNumber(n("contextTokens"))
    : null;
  const cost = has("cost") && n("modelCalls") > 0
    ? n("unpricedCalls") >= n("modelCalls")
      ? t("core-logic.history.usage.cost.unpriced")
      : `${n("unpricedCalls") > 0 ? "≥" : ""}${money(n("cost"))}`
    : null;
  const usage = isUsage
    ? (() => {
        const input = n("inputTokens");
        const cached = n("cachedTokens");
        const rate = input > 0 ? `${format.round((cached / input) * 100)}%` : t("core-logic.history.usage.unreported");
        return [
          { label: t("core-logic.history.usage.calls"), value: t("core-logic.history.usage.calls.value", { n: n("modelCalls") }) },
          { label: t("core-logic.history.usage.input"), value: format.compactNumber(input) },
          { label: t("core-logic.history.usage.cached"), value: format.compactNumber(cached) },
          { label: t("core-logic.history.usage.output"), value: format.compactNumber(n("outputTokens")) },
          { label: t("core-logic.history.usage.hit_rate"), value: rate },
          ...(context !== null ? [{ label: t("core-logic.history.usage.context"), value: context }] : []),
          ...(cost !== null ? [{ label: t("core-logic.history.usage.cost"), value: cost }] : []),
        ];
      })()
    : null;
  const usageLine = isUsage
    ? (() => {
        const input = n("inputTokens");
        const cached = n("cachedTokens");
        const rate = input > 0 ? t("core-logic.history.usage.line.rate", { rate: format.round((cached / input) * 100) }) : "";
        const line = t("core-logic.history.usage.line", { n: n("modelCalls"), input: format.compactNumber(input), rate, output: format.compactNumber(n("outputTokens")) });
        const more = [
          ...(has("contextTokens") && n("modelCalls") > 0 ? [t("core-logic.history.usage.line.context", { n: format.compactNumber(n("contextTokens")) })] : []),
          ...(cost !== null ? [t("core-logic.history.usage.line.cost", { cost })] : []),
        ];
        return [line, ...more].join(" · ");
      })()
    : null;
  return { usage, usageLine, context, contextPercent, cost };
}

/// The state a post or a mark ended its turn in, as the clients colour it: done, waiting on a person, or waiting on work
/// it started; null for one that ended nothing (a progress post) or words the station no longer uses.
function endsOf(kind: string | null): "done" | "human" | "waiting" | null {
  if (kind === "all_done" || kind === "final") return "done";
  if (kind === "need_human" || kind === "block" || kind === "need_help" || kind === "need_decision") return "human";
  if (kind === "waiting") return "waiting";
  return null;
}

/// Work the agent started, as the history shows it: with the line its answer shows closed (lineOf its Markdown).
function answered(task: J): J {
  return { ...task, line: typeof task.result === "string" && Array.isArray(task.md) ? lineOf(task.md, task.result) : null };
}

/// A group of the history; `base`: the transcript entry its timeline starts at (what a step's or thought's `entries` count
/// from: what `history.detail` reads whole, of one in brief).
function group(timeline: J[], steps: Step[], rows: Row[], base: number, known: Known, mdOf: (text: string) => ReturnType<typeof markdown>): J {
  const members = rows.flatMap((r) => ("step" in r ? [r.step] : []));
  const thinking = rows.flatMap((r) => ("thought" in r ? [r.thought] : []));
  const text = (i: number): string => (typeof timeline[i]?.text === "string" ? timeline[i].text : "");
  const tool = (i: number): string => (typeof timeline[i]?.tool === "string" ? timeline[i].tool : "");
  const failedOf = (st: Step) =>
    st.result !== null && (timeline[st.result]?.ok === false || /^Failed to call [\w.-]+:/.test(text(st.result)));
  const counts: [string, string[], number][] = [];
  for (const m of members) {
    const call = steps[m].call;
    const kind = steps[m].scriptCount !== undefined && steps[m].scriptCount! >= 2 ? "other" : kindOf(tool(call), argsOf(text(call)));
    const file = kind === "read" || kind === "edit" ? fileOf(text(call), tool(call)) : null;
    let at = counts.findIndex(([k]) => k === kind);
    if (at < 0) {
      counts.push([kind, [], 0]);
      at = counts.length - 1;
    }
    if (file !== null) {
      if (!counts[at][1].includes(file)) counts[at][1].push(file);
    } else counts[at][2]++;
  }
  const countOf = ([, files, n]: [string, string[], number]) => (files.length === 0 ? n : files.length);
  const ordered = counts.slice().sort((a, b) => {
    if ((a[0] === "other") !== (b[0] === "other")) return a[0] === "other" ? 1 : -1;
    return countOf(b) - countOf(a);
  });
  const fileBrief = (files: string[]): string => {
    const names = Array.from(new Set(files.map((f) => f.split("/").pop() || f))).filter(Boolean);
    if (names.length === 0) return "";
    if (names.length === 1) return `（${names[0]}）`;
    if (names.length === 2) return `（${names[0]}、${names[1]}）`;
    return `（${names[0]}、${names[1]} 等）`;
  };
  const formatTitle = (list: [string, string[], number][]) => {
    const joined = list.map(([k, files, n]) => did(k, files.length === 0 ? n : files.length)).join(t("core-logic.history.did.sep"));
    const chars = Array.from(joined);
    return chars.length > 0 ? chars[0].toUpperCase() + chars.slice(1).join("") : "";
  };
  const formatSummary = (list: [string, string[], number][]) => {
    const joined = list
      .map(([k, files, n]) => {
        const baseText = did(k, files.length === 0 ? n : files.length).replace("读取 thread ", "读取对话 ");
        return (k === "read" || k === "edit") && files.length > 0 ? `${baseText}${fileBrief(files)}` : baseText;
      })
      .join(t("core-logic.history.did.sep"));
    const chars = Array.from(joined);
    return chars.length > 0 ? chars[0].toUpperCase() + chars.slice(1).join("") : "";
  };
  const title = formatTitle(ordered);
  const knownCounts = ordered.filter(([k]) => k !== "other");
  const failed = members.filter((m) => failedOf(steps[m])).length;
  const pending = members.filter((m) => steps[m].result === null).length;
  // a thought's words, read as Markdown, and their first line without its marks
  const thought = (i: number) => {
    const raw = text(i);
    const cleaned = cleanThoughtText(raw) || raw;
    const md = mdOf(cleaned);
    const first = lineOf(md, cleaned);
    return { text: cleaned, md, first };
  };
  let summary: string;
  const lastMember = members[members.length - 1];
  if (lastMember === undefined) {
    summary = t("core-logic.history.thinking", { text: thinking.length > 0 ? Array.from(thought(thinking[0]).first).slice(0, 80).join("") : "" });
  } else if (pending === 0 && members.length > 1 && knownCounts.length > 0) {
    summary = t("core-logic.history.steps", { doing: formatSummary(knownCounts), n: members.length });
  } else {
    const call = steps[lastMember].call;
    // Said as the chat's activity says the call while it runs (activity.ts doing).
    const now = doing(tool(call), text(call), known);
    summary = members.length === 1 ? now : t("core-logic.history.steps", { doing: now, n: members.length });
  }
  const stepTookMs = (st: Step): number | null => {
    const call = timeline[st.call];
    if (st.firstEntry === undefined && typeof call?.callId === "string" && call.callId.includes("#")) return null;
    const result = st.result !== null ? timeline[st.result] : null;
    const b = result && typeof result.at === "string" ? epochMs(result.at) : null;
    const a = typeof call?.at === "string" ? epochMs(call.at) : null;
    if (b !== null && a !== null && b - a >= 50) return b - a;
    if (result && typeof result.text === "string") {
      const mTime = /^Created At:\s*(\S+)\r?\nCompleted At:\s*(\S+)/.exec(result.text);
      if (mTime) {
        const t0 = epochMs(mTime[1] ?? "");
        const t1 = epochMs(mTime[2] ?? "");
        if (t0 !== null && t1 !== null && t1 - t0 >= 50) return t1 - t0;
      }
    }
    return null;
  };
  const step = (m: number) => {
    const st = steps[m];
    const call = timeline[st.call];
    const result = st.result !== null ? timeline[st.result] : null;
    const isFailed = failedOf(st);
    const took = stepTookMs(st);
    const meta = result === null ? t("core-logic.history.step.running") : isFailed ? t("core-logic.history.step.failed") : took !== null ? format.duration(took) : "";
    const callText = text(st.call);
    const callTool = tool(st.call);
    const name = stepName(callTool, callText);
    let said = told(callTool, callText, known) ?? describe(callText);
    let stepHint = hint(callText, callTool);
    if (said === null && st.scriptCount !== undefined) {
      if (st.scriptCount >= 2) {
        said = `执行脚本（含 ${st.scriptCount} 项调用）`;
        if (st.scriptTools) stepHint = st.scriptTools;
      } else {
        said = "执行脚本";
      }
    }
    if (said === null && (name === "Read" || name === "Edit" || name === "Write")) {
      const file = fileOf(callText, callTool);
      if (file !== null) {
        const slash = file.lastIndexOf("/");
        const baseName = slash >= 0 ? file.slice(slash + 1) : file;
        const dirName = slash > 0 ? file.slice(0, slash) : "";
        const range = name === "Read" ? lineRangeOf(callText) : null;
        said = range !== null ? `${baseName} · ${range[0]}–${range[1]} 行` : baseName;
        stepHint = dirName;
      }
    }
    let enrichedCall = callText;
    // Looked up by its target alone (where no names are known none is found): what an item asked is what it read.
    if (known.agents) {
      const a = argsOf(callText);
      if (a) {
        const rawTarget = [a.to, a.recipient, a.Recipient, a.agent_id, a.agentId, a.conversationId, a.chat].find(
          (v): v is string => typeof v === "string" && v.trim() !== "",
        )?.trim();
        if (rawTarget) {
          const direct = known.agents.get(rawTarget);
          const session = rawTarget.includes("/chats/") ? rawTarget.slice(rawTarget.indexOf("/chats/") + 7) : rawTarget;
          const mapped = direct ?? known.agents.get(session);
          if (mapped && a._target === undefined) {
            try {
              const parsed = JSON.parse(callText);
              if (parsed && typeof parsed === "object" && !Array.isArray(parsed)) {
                enrichedCall = JSON.stringify({ ...parsed, _target: mapped, _targetId: rawTarget });
              }
            } catch {
              // keep callText if cut short
            }
          }
        }
      }
    }
    const firstCall = st.firstEntry ?? st.call;
    return {
      said,
      name,
      hint: stepHint,
      meta,
      failed: isFailed,
      call: enrichedCall,
      result: result === null ? null : (result.text ?? ""),
      entries: st.result !== null ? [base + firstCall, base + st.result] : [base + firstCall],
      brief: call?.brief === true || result?.brief === true,
    };
  };
  const isCompletedReadOf = (m: number): string | null => {
    const st = steps[m];
    if (st.result === null || failedOf(st)) return null;
    const callText = text(st.call);
    const callTool = tool(st.call);
    if (stepName(callTool, callText) !== "Read" || describe(callText) !== null) return null;
    return fileOf(callText, callTool);
  };
  const coalescedRead = (run: number[], file: string) => {
    const firstSt = steps[run[0]];
    const slash = file.lastIndexOf("/");
    const baseName = slash >= 0 ? file.slice(slash + 1) : file;
    const dirName = slash > 0 ? file.slice(0, slash) : "";
    const ranges = run.map((m) => lineRangeOf(text(steps[m].call))).filter((r): r is [number, number] => r !== null);
    let rangeText = `共 ${run.length} 次`;
    let minStart: number | undefined;
    let maxEnd: number | undefined;
    if (ranges.length > 0) {
      minStart = Math.min(...ranges.map((r) => r[0]));
      maxEnd = Math.max(...ranges.map((r) => r[1]));
      rangeText = `${minStart}–${maxEnd} 行（共 ${run.length} 段）`;
    }
    let totalTook = 0;
    for (const m of run) {
      const ms = stepTookMs(steps[m]);
      if (ms !== null) totalTook += ms;
    }
    const mergedCall = minStart !== undefined && maxEnd !== undefined
      ? JSON.stringify({ Path: file, StartLine: minStart, EndLine: maxEnd })
      : text(firstSt.call);
    const mergedResult = run.map((m) => {
      const r = steps[m].result !== null ? timeline[steps[m].result!] : null;
      return typeof r?.text === "string" ? r.text : "";
    }).filter((s) => s !== "").join("\n");
    const entries: number[] = [];
    for (const m of run) {
      entries.push(base + steps[m].call);
      if (steps[m].result !== null) entries.push(base + steps[m].result!);
    }
    const isBrief = run.some((m) => timeline[steps[m].call]?.brief === true || (steps[m].result !== null && timeline[steps[m].result!]?.brief === true));
    return {
      said: `${baseName} · ${rangeText}`,
      name: "Read",
      hint: dirName,
      meta: totalTook >= 50 ? format.duration(totalTook) : "",
      failed: false,
      call: mergedCall,
      result: mergedResult,
      entries: [entries[0], entries[entries.length - 1]],
      brief: isBrief,
    };
  };
  const isCompletedEditOf = (m: number): string | null => {
    const st = steps[m];
    if (st.result === null || failedOf(st)) return null;
    const callText = text(st.call);
    const callTool = tool(st.call);
    if (stepName(callTool, callText) !== "Edit" || describe(callText) !== null) return null;
    return fileOf(callText, callTool);
  };
  const coalescedEdit = (run: number[], file: string) => {
    const firstSt = steps[run[0]];
    const slash = file.lastIndexOf("/");
    const baseName = slash >= 0 ? file.slice(slash + 1) : file;
    const dirName = slash > 0 ? file.slice(0, slash) : "";
    const edits: { old_string: string; new_string: string }[] = [];
    for (const m of run) {
      const a = argsOf(text(steps[m].call));
      if (!a) continue;
      if (Array.isArray(a.edits)) {
        for (const e of a.edits) {
          if (e && typeof e === "object") {
            const oldS = typeof e.old_string === "string" ? e.old_string : typeof e.Target === "string" ? e.Target : "";
            const newS = typeof e.new_string === "string" ? e.new_string : typeof e.Replacement === "string" ? e.Replacement : "";
            edits.push({ old_string: oldS, new_string: newS });
          }
        }
      } else {
        const oldS = typeof a.old_string === "string" ? a.old_string : typeof a.Target === "string" ? a.Target : undefined;
        const newS = typeof a.new_string === "string" ? a.new_string : typeof a.Replacement === "string" ? a.Replacement : undefined;
        if (oldS !== undefined && newS !== undefined) edits.push({ old_string: oldS, new_string: newS });
      }
    }
    let totalTook = 0;
    for (const m of run) {
      const ms = stepTookMs(steps[m]);
      if (ms !== null) totalTook += ms;
    }
    const mergedCall = edits.length > 0 ? JSON.stringify({ file_path: file, edits }) : text(firstSt.call);
    const mergedResult = run.map((m) => {
      const r = steps[m].result !== null ? timeline[steps[m].result!] : null;
      return typeof r?.text === "string" ? r.text : "";
    }).filter((s) => s !== "").join("\n");
    const entries: number[] = [];
    for (const m of run) {
      entries.push(base + steps[m].call);
      if (steps[m].result !== null) entries.push(base + steps[m].result!);
    }
    const isBrief = run.some((m) => timeline[steps[m].call]?.brief === true || (steps[m].result !== null && timeline[steps[m].result!]?.brief === true));
    return {
      said: `${baseName} · ${run.length} 处修改`,
      name: "Edit",
      hint: dirName,
      meta: totalTook >= 50 ? format.duration(totalTook) : "",
      failed: false,
      call: mergedCall,
      result: mergedResult,
      entries: [entries[0], entries[entries.length - 1]],
      brief: isBrief,
    };
  };
  const outRows: J[] = [];
  for (let idx = 0; idx < rows.length; idx++) {
    const r = rows[idx];
    if ("thought" in r) {
      outRows.push({ kind: "thought", content: { ...thought(r.thought), entries: [base + r.thought], brief: timeline[r.thought]?.brief === true } });
    } else {
      const readFile = isCompletedReadOf(r.step);
      if (readFile !== null) {
        const run = [r.step];
        while (idx + 1 < rows.length && "step" in rows[idx + 1] && isCompletedReadOf((rows[idx + 1] as { step: number }).step) === readFile) {
          idx++;
          run.push((rows[idx] as { step: number }).step);
        }
        if (run.length > 1) {
          outRows.push({ kind: "step", content: coalescedRead(run, readFile) });
          continue;
        }
      }
      const editFile = isCompletedEditOf(r.step);
      if (editFile !== null) {
        const run = [r.step];
        while (idx + 1 < rows.length && "step" in rows[idx + 1] && isCompletedEditOf((rows[idx + 1] as { step: number }).step) === editFile) {
          idx++;
          run.push((rows[idx] as { step: number }).step);
        }
        if (run.length > 1) {
          outRows.push({ kind: "step", content: coalescedEdit(run, editFile) });
          continue;
        }
      }
      outRows.push({ kind: "step", content: step(r.step) });
    }
  }
  return {
    kind: "group",
    summary,
    title,
    failures: failed,
    pending,
    rows: outRows,
  };
}

/// Seconds in short, as the chat's activity says them: 45s, 3m 20s, 10m, 1h 5m.
function span(s: number): string {
  if (s < 60) return `${s}s`;
  if (s < 3600) return s % 60 === 0 ? `${s / 60}m` : `${Math.trunc(s / 60)}m ${s % 60}s`;
  const h = Math.trunc(s / 3600);
  const m = Math.trunc((s % 3600) / 60);
  return m === 0 ? `${h}h` : `${h}h ${m}m`;
}

/// Each call with its result: a result by its call's id wherever that call stands (Claude Code can write a quick call's
/// result before the call), or (one without) the latest call before it with none yet.
function pair(timeline: J[]): { steps: Step[]; stepAt: Map<number, number> } {
  const steps: Step[] = [];
  const stepAt = new Map<number, number>();
  const byCall = new Map<string, number>();
  timeline.forEach((e, i) => {
    if (e?.kind !== "tool_call") return;
    const step = steps.length;
    steps.push({ call: i, result: null });
    stepAt.set(i, step);
    if (typeof e.callId === "string") byCall.set(e.callId, step);
  });
  let lastStep: number | null = null;
  timeline.forEach((e, i) => {
    if (e?.kind === "tool_call") lastStep = stepAt.get(i)!;
    else if (e?.kind === "tool_result") {
      const step = typeof e.callId === "string" ? byCall.get(e.callId) : lastStep !== null && steps[lastStep].result === null ? lastStep : undefined;
      if (step !== undefined) steps[step].result = i;
    }
  });
  for (let idx = 0; idx < steps.length; idx++) {
    const st = steps[idx];
    const e = timeline[st.call];
    const cid = typeof e?.callId === "string" ? e.callId : "";
    if (!cid || cid.includes("#") || toolName(typeof e?.tool === "string" ? e.tool : "") !== "exec") continue;
    const callText = typeof e?.text === "string" ? e.text : "";
    if (argsOf(callText) !== null) continue;
    const prefix = `${cid}#`;
    const innerSteps: number[] = [];
    for (let j = idx + 1; j < steps.length; j++) {
      const ie = timeline[steps[j].call];
      if (typeof ie?.callId === "string" && ie.callId.startsWith(prefix)) innerSteps.push(j);
      else break;
    }
    const isLoop = /\b(?:for|while)\s*\(|\.\s*(?:map|forEach)\s*\(/.test(callText);
    const allPostOrMark = innerSteps.length > 0 && innerSteps.every((j) => beginsItem(timeline[steps[j].call]));
    if ((innerSteps.length === 1 && !isLoop) || allPostOrMark) {
      st.unwrapped = true;
      const target = steps[innerSteps[innerSteps.length - 1]];
      target.result = st.result;
      target.firstEntry = st.call;
    } else if (innerSteps.length >= 2) {
      st.scriptCount = innerSteps.length;
      const names = Array.from(
        new Set(
          innerSteps.map((j) =>
            stepName(
              typeof timeline[steps[j].call]?.tool === "string" ? timeline[steps[j].call].tool : "",
              typeof timeline[steps[j].call]?.text === "string" ? timeline[steps[j].call].text : "",
            ),
          ),
        ),
      );
      st.scriptTools = names.join("、");
    } else {
      st.scriptCount = 0;
    }
  }
  return { steps, stepAt };
}

/// What the station pushes of the turn beyond its transcript, as the history shows it after its items: the steps in
/// flight (thinking, writing) and where the turn stands with the model.
function pushed(live: J, runtime: string): { liveSteps: { id: string; step: string; text: string }[]; phase: { phase: J; text: string; since: J } | null } {
  const s = (e: J, k: string): string => (typeof e?.[k] === "string" ? e[k] : "");
  const flag = (e: J, k: string): boolean => e?.[k] === true;
  const liveSteps = (Array.isArray(live?.steps) ? live.steps : [])
    .filter((st: J) => !flag(st, "subagent") && s(st, "step") !== "tool")
    .map((st: J) => ({ id: s(st, "id"), step: s(st, "step"), text: s(st, "step") === "text" ? t("core-logic.history.live.writing") : t("core-logic.history.live.thinking") }));
  const p = live?.phase;
  const phase =
    p !== null && typeof p === "object" && !Array.isArray(p)
      ? (() => {
          const name = typeof p.phase === "string" ? p.phase : "";
          const text =
            name === "starting"
              ? t("core-logic.history.phase.starting", { runtime: format.runtimeLabel(runtime) })
              : name === "requesting"
                ? t("core-logic.history.phase.requesting")
                : name === "working"
                  ? t("core-logic.history.phase.working")
                  : t("core-logic.activity.thinking");
          return { phase: p.phase ?? null, text, since: p.since ?? null };
        })()
      : null;
  return { liveSteps, phase };
}

/**
 * The chat's activity: the execution history's latest, in one line. The call it shows running (this turn's, said as
 * its row says it), else what is in flight (thinking, writing, a reply being written), else where the turn stands.
 * `stations`: the workspace's stations' names by id, for a call that works on one (station_task).
 */
export function activity(live: J, stations?: ReadonlyMap<string, string>): J {
  const timeline: J[] = Array.isArray(live?.timeline) ? live.timeline : [];
  const s = (e: J, k: string): string => (typeof e?.[k] === "string" ? e[k] : "");
  let turn = -1;
  timeline.forEach((e, i) => {
    if (s(e, "kind") === "user") turn = i;
  });
  let call: [string, string, boolean] | null = null;
  let replying = false;
  const known: Known = { stations, tasks: tasksOf(timeline), agents: agentsOf(timeline) };
  for (const st of pair(timeline).steps) {
    const e = timeline[st.call];
    if (st.unwrapped || st.call < turn || st.result !== null || e?.subagent === true) continue;
    const name = toolName(s(e, "tool"));
    if (name === "chat_post") replying = true;
    else if (name !== "chat_state") {
      const important = importantCall(s(e, "tool"), s(e, "text"));
      // Of simultaneous steps, keep the most consequential; among equals, show the latest.
      if (call === null || important || !call[2]) call = [s(e, "callId") || `call:${st.call}`, doing(s(e, "tool"), s(e, "text"), known), important];
    }
  }
  const { liveSteps, phase } = pushed(live, "");
  // A reply being written comes as a step before its call is in the transcript.
  const steps: J[] = Array.isArray(live?.steps) ? live.steps : [];
  if (steps.some((st) => st?.subagent !== true && st?.ended !== true && s(st, "step") === "tool" && toolName(s(st, "tool")) === "chat_post")) replying = true;
  const rate = Number.isInteger(live?.rate) && live.rate > 0 ? (live.rate as number) : 0;
  const said = (key: string, word: string) => ({ key, text: rate > 0 ? `${t(word)} · ≈ ${rate} token/s` : t(word) });
  if (call && (!replying || call[2])) return { now: { key: call[0], text: call[1], mono: true, ...(call[2] ? { important: true } : {}) } };
  if (replying) return { now: { ...said("reply", "core-logic.activity.replying"), important: true } };
  const flight = liveSteps.at(-1);
  if (flight) return { now: flight.step === "text" ? said("write", "core-logic.activity.writing") : said("think", "core-logic.activity.thinking") };
  const at = typeof phase?.phase === "string" ? phase.phase : "";
  if (at === "starting") return { now: said("starting", "core-logic.activity.starting") };
  if (at === "requesting") return { now: said("requesting", "core-logic.activity.requesting") };
  if (at === "thinking") return { now: said("think", "core-logic.activity.thinking") };
  if (at === "responding") return { now: said("write", "core-logic.activity.writing") };
  return { now: said("busy", "core-logic.activity.busy") };
}
