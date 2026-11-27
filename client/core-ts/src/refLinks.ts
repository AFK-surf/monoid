// still.fail's links as what is written names them, read alike by every client: a reference to another chat (in the
// composer a short mark, `@[its title]`; sent, a link, `[its title](its page)`), the link a chat is given away by, and
// the chat, screen or 共享调试 a link names. Read as a message or a draft is drawn, so the web takes them as they are
// , as it takes markdown.ts's words; nothing here reads the device or the station. The core's own
// keeping of a mark's link until it is sent is refs.ts's.

import { bareLinks } from "./bareLinks.ts";
import { shaped, sharedValue } from "./util.ts";

/// A reference as the composer holds it.
export const REF_MARK = /@\[([^\]\n]{1,120})\]/g;
/// A reference as sent: a link to a chat's page, or its still.fail link (…/o/<workspace>/<station>/<key>, as copied).
export const REF_LINK = /\[([^\]\n]{1,120})\]\((\S*?(?:\/chats\/|\/o\/[^/\s)]+\/[^/\s)]+\/)[^\s)]+)\)/g;

/// Text split into its plain runs and the parts `pattern` finds (with its groups).
export function splitBy(text: string, pattern: RegExp): (string | RegExpExecArray)[] {
  const parts: (string | RegExpExecArray)[] = [];
  let at = 0;
  for (const m of text.matchAll(new RegExp(pattern.source, "g"))) {
    if (m.index > at) parts.push(text.slice(at, m.index));
    parts.push(m as RegExpExecArray);
    at = m.index + m[0].length;
  }
  if (at < text.length) parts.push(text.slice(at));
  return parts;
}

/// A link to a chat's page (…/chats/<key>, or still.fail cloud's /o/<workspace>/<station>/<key>).
export function isChatLink(href: string | undefined): boolean {
  return !!href && (/\/chats\/[^/?#\s]+\/?(?:[?#]|$)/.test(href) || /^https?:\/\/[^/]+\/o\/[^/]+\/[^/]+\/[^/?#]+\/?(?:[?#]|$)/.test(href));
}

/// The link a chat is given away by: still.fail's, `…/o/<workspace>/<station>/<session>` under `at.cloud` (still.fail
/// cloud's origin; null: none known), which opens it wherever it is pasted and which an agent on any station of the
/// workspace reads it by (chat_read); `history`: an agent's execution history there (session_history), opened at
/// `entry`. A station of no workspace has no such link: its page, under `at.here` (the page's own origin; null: none)
/// and `at.root` (where the page's routes start).
export function shareLink(
  item: { station: string; session: string; id: string },
  at: { cloud: string | null; here: string | null; root: string },
  history?: { key: string; entry?: number | undefined },
): string {
  const slash = item.station.indexOf("/");
  const page = slash >= 0 && at.cloud
    ? `${at.cloud.replace(/\/+$/, "")}/o/${item.station.slice(0, slash)}/${item.station.slice(slash + 1)}/${encodeURIComponent(item.session)}`
    : `${at.here ?? ""}${at.root.replace(/\/+$/, "")}/chats/${encodeURIComponent(item.id)}`;
  return history ? `${page}?history=${encodeURIComponent(history.key)}${history.entry === undefined ? "" : `&entry=${history.entry}`}` : page;
}

/// A chat's link as a reference is sent, to be copied: its words (`shown`: the title on one line, at most 120
/// characters; the link itself for none) and `[shown](link)` (`plain`), which a composer makes a reference again.
export function copiedRef(title: string, link: string): { shown: string; plain: string } {
  const shown = Array.from(title.replace(/[[\]\n]/g, " ").trim() || link).slice(0, 120).join("");
  return { shown, plain: `[${shown}](${link})` };
}

/// The chat a link names, when it is one of a workspace's chats: a still.fail link (`…/o/<workspace>/<station>/<session>`)
/// or its page (`…/w/<workspace>/s/<station>/chats/<id>`), and what follows it when that is its agent's execution
/// history (`?history=<session>`, maybe `&entry=<n>`; else "") or one of its messages (`?message=<seq>`; else ""). Null
/// otherwise.
export function chatOfLink(href: string): { station: string; id: string; history: string; message: string } | null {
  const m = /\/o\/([^/?#\s]+)\/([^/?#\s]+)\/([^/?#\s]+)\/?(\?history=[^&#\s]+(?:&entry=\d+)?|\?message=[1-9]\d{0,14})?$/.exec(href)
    ?? /\/w\/([^/?#\s]+)\/s\/([^/?#\s]+)\/chats\/([^/?#\s]+)\/?(\?history=[^&#\s]+(?:&entry=\d+)?|\?message=[1-9]\d{0,14})?$/.exec(href);
  if (!m) return null;
  try {
    const after = m[4] ?? "";
    const message = after.startsWith("?message=");
    return { station: `${m[1]}/${m[2]}`, id: decodeURIComponent(m[3]!), history: message ? "" : after, message: message ? after : "" };
  } catch {
    return null;
  }
}

/// The chats what is written links to, each link once: in a reference (`[its title](link)`), then written bare
/// (bareLinks.ts); each its link, its station and its key as chatOfLink reads them, a link with no station of its own
/// (`…/chats/<id>`) one of `here`'s.
export function chatsLinked(text: string, here: string): { href: string; station: string; id: string }[] {
  const out: { href: string; station: string; id: string }[] = [];
  const add = (href: string) => {
    if (!isChatLink(href) || out.some((c) => c.href === href)) return;
    const of = chatOfLink(href) ?? ownChat(href, here);
    if (of !== null) out.push({ href, station: of.station, id: of.id });
  };
  for (const m of text.matchAll(/\]\((\S+?)\)/g)) add(m[1]!);
  for (const part of bareLinks(text)) if (typeof part !== "string") add(part.url);
  return out;
}

/// The chat a link with no station of its own names (`…/chats/<id>`): one of `here`'s.
function ownChat(href: string, here: string): { station: string; id: string } | null {
  const m = /\/chats\/([^/?#\s]+)\/?(?:[?#]|$)/.exec(href);
  if (!m) return null;
  try {
    return { station: here, id: decodeURIComponent(m[1]!) };
  } catch {
    return null;
  }
}

/// The station (`<workspace>/<station>`) a link to a chat is on, as chatOfLink reads it; null for a link that does not say.
export function stationOfLink(href: string): string | null {
  const m = /\/o\/([^/?#\s]+)\/([^/?#\s]+)\/[^/?#\s]+/.exec(href) ?? /\/w\/([^/?#\s]+)\/s\/([^/?#\s]+)\/chats\//.exec(href);
  return m ? `${m[1]}/${m[2]}` : null;
}

/// The screen a link names, when it is one of a station's screens (`…/w/<workspace>/s/<station>/screen/<id>`, as its
/// agents' `screen` tool links it): its station (`<workspace>/<station>`) and its id. Null otherwise.
export function screenOfLink(href: string): { station: string; screen: string } | null {
  const m = /^(?:https?:\/\/[^/]+)?\/w\/([^/?#\s]+)\/s\/([^/?#\s]+)\/screen\/([^/?#\s]+)\/?$/.exec(href);
  if (!m) return null;
  try {
    return { station: `${decodeURIComponent(m[1]!)}/${decodeURIComponent(m[2]!)}`, screen: decodeURIComponent(m[3]!) };
  } catch {
    return null;
  }
}

/// The terminal a link names (`…/w/<workspace>/s/<station>/terminal/<id>`): its station and its id. Null otherwise.
export function terminalOfLink(href: string): { station: string; terminal: string } | null {
  const m = /^(?:https?:\/\/[^/]+)?\/w\/([^/?#\s]+)\/s\/([^/?#\s]+)\/terminal\/([^/?#\s]+)\/?$/.exec(href);
  if (!m) return null;
  try {
    return { station: `${decodeURIComponent(m[1]!)}/${decodeURIComponent(m[2]!)}`, terminal: decodeURIComponent(m[3]!) };
  } catch {
    return null;
  }
}

/// The station a link to its 共享调试 names (`…/w/<workspace>/s/<station>/adb`, as its agents' `adb_devices` tool links
/// it), as `<workspace>/<station>`. Null otherwise.
export function adbOfLink(href: string): string | null {
  const m = /^(?:https?:\/\/[^/]+)?\/w\/([^/?#\s]+)\/s\/([^/?#\s]+)\/adb\/?$/.exec(href);
  if (!m) return null;
  try {
    return `${decodeURIComponent(m[1]!)}/${decodeURIComponent(m[2]!)}`;
  } catch {
    return null;
  }
}

/// The web service a link names: a chat's item with its service, as its agent links to it
/// (`…/o/<workspace>/<station>/<chat>?service=<job>`, after a host or alone): its station and its job. Null otherwise.
export function serviceOfLink(href: string): { station: string; job: string } | null {
  const m = /^(?:https?:\/\/[^/]+)?\/o\/([^/?#\s]+)\/([^/?#\s]+)\/[^/?#\s]+\/?\?([^#]*)/.exec(href);
  if (!m) return null;
  // (by hand: Hermes on Android has no URLSearchParams, hermes-safe.test.ts)
  const pair = m[3]!.split("&").find((kv) => kv.startsWith("service="));
  if (!pair || pair.length === 8) return null;
  try {
    return { station: `${decodeURIComponent(m[1]!)}/${decodeURIComponent(m[2]!)}`, job: decodeURIComponent(pair.slice(8)) };
  } catch {
    return null;
  }
}

/// A GitHub pull request's or issue's link (`https://github.com/<owner>/<repo>/pull/<n>`, `…/issues/<n>`, anything
/// after its number): which, its repository and its number; else null. Its card is a rich one (linkTo `peek`), and a
/// pull request is one of a chat's things (things.ts).
export function githubOf(url: string): { kind: "pull" | "issue"; repository: string; number: number } | null {
  const m = /^https?:\/\/(?:www\.)?github\.com\/([^/\s?#]+)\/([^/\s?#]+)\/(pull|issues)\/(\d+)(?:[/?#]|$)/i.exec(url);
  if (m === null) return null;
  return { kind: m[3]!.toLowerCase() === "pull" ? "pull" : "issue", repository: `${m[1]}/${m[2]}`, number: Number(m[4]) };
}

/// What a link is to, as every client draws it: a chat's (`chat`: a reference to it), a screen's, a station's 共享调试 or
/// a chat's web service's (`card`: a card alone in a paragraph, its title bare in a sentence), with what names it; a
/// pull request's or an issue's (`peek`: its card over it is that one's, bars while it is read). Null for any other
/// link. The clients take it from the core with each link (markdown.ts, personWords, things.ts), reading none of it
/// themselves.
export type LinkTo = { chat?: true; card?: "screen" | "terminal" | "adb" | "service"; station?: string; screen?: string; terminal?: string; job?: string; peek?: "pull" | "issue" | "run" };
export function linkTo(href: string): LinkTo | null {
  const chat = isChatLink(href) ? { chat: true as const } : {};
  const screen = screenOfLink(href);
  if (screen) return { ...chat, card: "screen", station: screen.station, screen: screen.screen };
  const terminal = terminalOfLink(href);
  if (terminal) return { ...chat, card: "terminal", station: terminal.station, terminal: terminal.terminal };
  const adb = adbOfLink(href);
  if (adb) return { ...chat, card: "adb", station: adb };
  const service = serviceOfLink(href);
  if (service) return { ...chat, card: "service", station: service.station, job: service.job };
  if (/^https?:\/\/github\.com\/[\w.-]+\/[\w.-]+\/actions\/runs\/\d+(?:\/attempts\/\d+)?\/?(?:[?#]|$)/i.test(href)) return { ...chat, peek: "run" };
  const github = githubOf(href);
  if (github) return { ...chat, peek: github.kind };
  return chat.chat ? chat : null;
}

/// The `@words` the caret is at the end of (`@` and a few letters ask for a chat to refer to), and where its `@` is;
/// null when it is in none.
export function refAt(text: string, caret: number): { start: number; query: string } | null {
  const m = /(?:^|\s)@([^\s@[\]()]{0,40})$/.exec(text.slice(0, caret));
  return m ? { start: caret - m[1]!.length - 1, query: m[1]! } : null;
}

/// The `/words` the caret is at the end of (`/` at start of line or after whitespace asks for a skill of the attached
/// agent to invoke), and where its `/` is; null when it is in none (paths like `a/b` or URLs like `https://...` do not
/// match).
export function skillAt(text: string, caret: number): { start: number; query: string } | null {
  const m = /(?:^|\s)\/([^\s/\\]{0,64})$/.exec(text.slice(0, caret));
  return m ? { start: caret - m[1]!.length - 1, query: m[1]! } : null;
}

/// Where the mark just before `caret` starts (a backspace there takes it whole), or null.
export function markBefore(text: string, caret: number): number | null {
  const m = /@\[[^\]\n]{1,120}\]$/.exec(text.slice(0, caret));
  return m ? m.index : null;
}

/// The marks in what is written, each where it starts and ends and its title (drawn as a chip).
export function marksIn(text: string): { start: number; end: number; title: string }[] {
  return [...text.matchAll(new RegExp(REF_MARK.source, "g"))].map((m) => ({ start: m.index, end: m.index + m[0].length, title: m[1]! }));
}

/// The chats' links in what is pasted as a chat's link is copied (`[its title](its link)`) that name a chat of the
/// workspace of the station `here` is (a station of no workspace: none): where each is in `pasted`, its title, its
/// chat (its station, its key) and what follows its link when it is its agent's execution history or one of its
/// messages (`history`: the composer puts it back on the link it keeps).
export function pastedRefs(pasted: string, here: string): { start: number; end: number; title: string; station: string; id: string; history: string }[] {
  const scope = (station: string) => station.split("/")[0]!;
  if (!here.includes("/")) return [];
  return [...pasted.matchAll(/\[([^\]\n]{1,120})\]\((\S+?)\)/g)].flatMap((m) => {
    const chat = chatOfLink(m[2]!);
    return chat && scope(chat.station) === scope(here) ? [{ start: m.index, end: m.index + m[0].length, title: m[1]!, station: chat.station, id: chat.id, history: chat.history || chat.message }] : [];
  });
}

/// A run of a person's words as the clients draw it: as they wrote it, a web address written bare (`link`), or a
/// reference to a chat (`ref`: its title is `text` where they wrote one, `[title](its page)`; a chat's page written bare
/// is one too, `text` its address, the message's `chats` saying its title). How it is set where they marked it as
/// Markdown marks it (personMarks below), its marks not in `text`: bold `b`, slanted `i`, struck through `s`, code in a
/// line `code`, a fenced block of code `pre`; where in `text` the marks of a list's items start (`li`: each a bullet
/// or its number as written, up to and with the space after it; the rest of its line, wrapped, starts where the mark
/// ends: said in the run its words are in, not as runs of their own, which a chat's page of lists would pay for).
export type WordsRun = { text: string; link?: string; ref?: true; to?: LinkTo; b?: true; i?: true; s?: true; code?: true; pre?: true; li?: number[] };

/// What a person wrote, in runs (WordsRun): references to chats, and web addresses written bare (bareLinks.ts). The one
/// reading the clients draw a person's words by (what is not a message yet: draftWords).
export function personWords(text: string): WordsRun[] {
  const was = wordsKept.get(text);
  if (was !== undefined) {
    wordsKept.delete(text);
    wordsKept.set(text, was);
    return was;
  }
  const out = wordsOf(text);
  // (made once and shared from then on: frozen, and gone out as it is, never shaped again, as markdown.ts's trees are)
  shaped.add(sharedValue(out));
  wordsKept.set(text, out);
  if (wordsKept.size > WORDS_KEPT) wordsKept.delete(wordsKept.keys().next().value!);
  return out;
}

/// How many texts' runs `personWords` keeps (a chat's people's messages read again as it is made again, the latest first).
const WORDS_KEPT = 512;
const wordsKept = new Map<string, WordsRun[]>();

// The few of Markdown's marks read in a person's words (the user, 2026-11-27: only the basic ones): `**bold**`,
// `*slanted*` (`__`, `_` too), `~~struck~~`, `` `code` ``, a fenced block of code, and a line begun `- ` or `* ` an
// item of a list (its mark a bullet). The rest stays as written, as a person's words always were: each line a line,
// no headings, tables, pictures or HTML, since words written with no thought of Markdown must not change (a `#123`,
// an indented line, `a_b_c`, `2*3*4`, a path's `*.ts`). A mark with no partner on its line is words.

/// A fence's lines, the code between them (splitBy reads it with no `m`: a line's ends said as they are).
const FENCE = /(?<=^|\n) {0,3}```[^`\n]*\n([\s\S]*?)\n {0,3}```[ \t]*(?=\n|$)/g;
/// Code in a line: between as many backticks either side, none of that many inside.
const CODE = /(?<!`)(`+)(?!`)([^\n]*?[^`\n])\1(?!`)/g;
/// A list's item: its mark at the start of a line (`-`, `*`, or a number and `.` or `)`), a space, words after it.
const ITEM = /^( *)([-*]|\d{1,9}[.)]) (?=\S)/gm;

/// A run and where it stands in what is written: from `at`, `len` long there (its marks with it).
type Placed = { run: WordsRun; at: number; len: number };

/// How a stretch of what is being written is set in the field it is written in (draftStyles), from `start` to `end`
/// of it: as its message's run will be (`b`, `i`, `s`; `code`: code's face, `pre` too in a block), or a mark itself
/// (`mark`: `**`, a backtick, a fence's line), which stays in the field, drawn lighter; or the mark of a list's item
/// (`li`: `- `, `1. `), drawn as its message draws it, the rest of its line wrapped to where it ends.
export type WordsStyle = { start: number; end: number; b?: true; i?: true; s?: true; code?: true; pre?: true; mark?: true; li?: true };

/// `text` cut by `pattern` (splitBy), each part with where it starts, `base` on.
function cut(text: string, base: number, pattern: RegExp): { at: number; part: string | RegExpExecArray }[] {
  let at = base;
  return splitBy(text, pattern).map((part) => {
    const here = at;
    at += typeof part === "string" ? part.length : part[0].length;
    return { at: here, part };
  });
}

/// What is written read once for both its runs and how its field sets it: `runs` as a message draws them, `set` the
/// stretches of the text they come of (not sorted, one over another where marks are one in another).
function read(text: string, marks: boolean): { runs: WordsRun[]; set: WordsStyle[] } {
  const placed: Placed[] = [];
  const set: WordsStyle[] = [];
  const plain = (part: string, base: number) => {
    let at = base;
    for (const bit of bareLinks(part)) {
      if (typeof bit === "string") {
        if (bit !== "") placed.push({ run: { text: bit }, at, len: bit.length });
        at += bit.length;
      } else {
        const to = linkTo(bit.url);
        placed.push({ run: { text: bit.url, link: bit.url, ...(to?.chat ? { ref: true as const } : {}), ...(to ? { to } : {}) }, at, len: bit.url.length });
        at += bit.url.length;
      }
    }
  };
  const linked = (part: string, base: number) => {
    for (const { at, part: each } of cut(part, base, REF_LINK)) {
      if (typeof each === "string") plain(each, at);
      else {
        const to = linkTo(each[2]!);
        placed.push({ run: { text: each[1]!, link: each[2]!, ref: true, ...(to ? { to } : {}) }, at, len: each[0].length });
      }
    }
  };
  // (a composer's marks, in what is not sent yet: draftWords)
  const referring = (part: string, base: number) => {
    if (!marks) return linked(part, base);
    for (const { at, part: each } of cut(part, base, REF_MARK)) {
      if (typeof each === "string") linked(each, at);
      else placed.push({ run: { text: each[1]!, ref: true }, at, len: each[0].length });
    }
  };
  if (!/[*_~`]/.test(text) && !/^ *(?:-|\d{1,9}[.)]) \S/m.test(text)) {
    referring(text, 0);
    return { runs: placed.map((p) => p.run), set };
  }
  for (const { at, part: block } of cut(text, 0, FENCE)) {
    if (typeof block !== "string") {
      const all = block[0].length;
      const body = at + block[0].indexOf("\n") + 1;
      const code = block[1]!;
      set.push({ start: at, end: body - 1, mark: true }, { start: body + code.length + 1, end: at + all, mark: true });
      if (code !== "") set.push({ start: body, end: body + code.length, code: true, pre: true });
      // (its lines end what is open on the lines before it, though it holds no code)
      placed.push({ run: { text: code, pre: true }, at, len: all });
      continue;
    }
    // (its items' marks, where each stands: runs of their own, a bullet for `-` and `*`, a number as written)
    const items = [...block.matchAll(ITEM)].map((m) => ({ from: at + m.index + m[1]!.length, to: at + m.index + m[0].length, mark: m[2]! }));
    const itemized = (part: string, base: number) => {
      let done = 0;
      for (const item of items) {
        if (item.from < base + done || item.to > base + part.length) continue;
        referring(part.slice(done, item.from - base), base + done);
        placed.push({ run: { text: /\d/.test(item.mark) ? `${item.mark} ` : "• ", li: [] }, at: item.from, len: item.to - item.from });
        set.push({ start: item.from, end: item.to, li: true });
        done = item.to - base;
      }
      referring(part.slice(done), base + done);
    };
    for (const { at: from, part } of cut(block, at, CODE)) {
      if (typeof part === "string") {
        itemized(part, from);
        continue;
      }
      const ticks = part[1]!.length;
      const to = from + part[0].length;
      set.push({ start: from, end: from + ticks, mark: true }, { start: from + ticks, end: to - ticks, code: true }, { start: to - ticks, end: to, mark: true });
      placed.push({ run: { text: /^ .*\S.* $/.test(part[2]!) ? part[2]!.slice(1, -1) : part[2]!, code: true }, at: from, len: part[0].length });
    }
  }
  return { runs: itemsIn(emphasized(placed, set)), set };
}

/// `runs` with each item's mark (a run of its own as they are read, `li`) put in the plain run before it, or the one
/// it begins, where it starts there said in that run's `li`.
function itemsIn(runs: WordsRun[]): WordsRun[] {
  if (!runs.some((r) => r.li)) return runs;
  const plain = (r: WordsRun | undefined) => r !== undefined && r.link === undefined && !r.ref && !r.code && !r.pre && !r.b && !r.i && !r.s;
  const out: WordsRun[] = [];
  for (const r of runs) {
    const last = out[out.length - 1];
    if (!plain(r) || !plain(last)) {
      out.push(r.li ? { text: r.text, li: [0] } : r);
      continue;
    }
    if (r.li) (last!.li ??= []).push(last!.text.length);
    last!.text += r.text;
  }
  return out;
}

function wordsOf(text: string, marks = false): WordsRun[] {
  return read(text, marks).runs;
}

type Mark = "**" | "__" | "~~" | "*" | "_";
const STYLE = { "**": "b", "__": "b", "~~": "s", "*": "i", "_": "i" } as const;
const space = (c: string) => c === "" || /\s/.test(c);
/// A letter or a digit of a word, ASCII's or not (Chinese): what `_` inside a word is between, never a mark there.
const wordy = (c: string) => c !== "" && !/[\s!-/:-@[-`{-~]/.test(c);
const ascii = (c: string) => /[0-9A-Za-z]/.test(c);

/// The runs of `placed` with the marks of emphasis in their words (what is no link and no code) taken out and what is
/// between a pair set so, links and code between them too; each pair's marks and what is between them said in `set`,
/// where they stand in what is written. A pair is on one line: a mark opens before what is no space and
/// closes after what is no space; `_` opens only after a space or what opens a bracket or a quote and closes only at a
/// word's end (a name's or a path's `_` is no mark: `a_b_c`, `/a/__init__.py`), and a lone `*` is none between ASCII
/// letters or digits (`2*3*4`).
function emphasized(placed: Placed[], set: WordsStyle[]): WordsRun[] {
  // its pieces in order: words, a mark (words too unless it finds its pair), another run whole
  type Piece = { text: string; at: number; run?: WordsRun; mark?: Mark; gone?: true };
  const pieces: Piece[] = [];
  const from: ("b" | "i" | "s")[][] = [];
  const to: ("b" | "i" | "s")[][] = [];
  let open: { mark: Mark; at: number }[] = [];
  const meet = (mark: Mark, where: number, opens: boolean, closes: boolean) => {
    const at = pieces.length;
    pieces.push({ text: mark, at: where, mark });
    let was = -1;
    if (closes) for (let k = open.length - 1; k >= 0; k--) if (open[k]!.mark === mark) { was = k; break; }
    if (was >= 0 && open[was]!.at < at - 1) {
      const start = open[was]!.at;
      open = open.slice(0, was);
      pieces[start]!.gone = true;
      pieces[at]!.gone = true;
      (from[start] ??= []).push(STYLE[mark]);
      (to[at] ??= []).push(STYLE[mark]);
      const began = pieces[start]!.at;
      set.push({ start: began, end: began + mark.length, mark: true }, { start: began + mark.length, end: where, [STYLE[mark]]: true }, { start: where, end: where + mark.length, mark: true });
    } else if (opens) open.push({ mark, at });
  };
  for (let r = 0; r < placed.length; r++) {
    const { run, at: base } = placed[r]!;
    if (run.link !== undefined || run.ref || run.code || run.pre || run.li) {
      if (run.text.includes("\n") || run.pre) open = [];
      if (!(run.pre && run.text === "")) pieces.push({ text: run.text, at: base, run });
      continue;
    }
    const text = run.text;
    // (what stands before its first letter and after its last: another run's words, a letter to these marks)
    // (an item's mark ends in its space)
    const before = r > 0 ? (placed[r - 1]!.run.li ? " " : "a") : "";
    const after = r + 1 < placed.length ? (placed[r + 1]!.run.li ? " " : "a") : "";
    let at = 0;
    let words = 0;
    const said = (end: number) => {
      if (end > words) pieces.push({ text: text.slice(words, end), at: base + words });
    };
    while (at < text.length) {
      const c = text[at]!;
      if (c === "\n") {
        open = [];
        at++;
        continue;
      }
      if (c !== "*" && c !== "_" && c !== "~") {
        at++;
        continue;
      }
      let end = at;
      while (text[end] === c) end++;
      const n = end - at;
      const prev = at > 0 ? text[at - 1]! : before;
      const next = end < text.length ? text[end]! : after;
      let opens = !space(next);
      let closes = !space(prev);
      if (c === "_") {
        opens &&= space(prev) || "([{<\"'*~（【「“‘".includes(prev);
        closes &&= !wordy(next);
      }
      if (n > 3 || (c === "~" && n !== 2) || (!opens && !closes)) {
        at = end;
        continue;
      }
      said(at);
      words = end;
      const where = base + at;
      at = end;
      const two = (c + c) as Mark;
      const one = c as Mark;
      if (n === 2) meet(two, where, opens, closes);
      else if (n === 1) {
        if (c === "*" && ascii(prev) && ascii(next)) pieces.push({ text: c, at: where });
        else meet(one, where, opens, closes);
      } else if (open.length > 0 && open[open.length - 1]!.mark === one) {
        // (`***` closing what `***` opened: the inner one first)
        meet(one, where, false, closes);
        meet(two, where + 1, opens, closes);
      } else {
        meet(two, where, opens, closes);
        meet(one, where + 2, opens, false);
      }
    }
    said(text.length);
  }
  if (!pieces.some((p) => p.gone)) return placed.filter((p) => !(p.run.pre && p.run.text === "")).map((p) => p.run);
  const out: WordsRun[] = [];
  const on = { b: 0, i: 0, s: 0 };
  for (let k = 0; k < pieces.length; k++) {
    const p = pieces[k]!;
    for (const style of from[k] ?? []) on[style]++;
    for (const style of to[k] ?? []) on[style]--;
    if (p.gone) continue;
    const set: { b?: true; i?: true; s?: true } = { ...(on.b > 0 ? { b: true as const } : {}), ...(on.i > 0 ? { i: true as const } : {}), ...(on.s > 0 ? { s: true as const } : {}) };
    const last = out[out.length - 1];
    if (!p.run && last && last.link === undefined && !last.ref && !last.code && !last.pre && !last.li && !last.b === !set.b && !last.i === !set.i && !last.s === !set.s) last.text += p.text;
    else out.push(p.run ? (p.run.pre || p.run.li ? p.run : { ...p.run, ...set }) : { text: p.text, ...set });
  }
  return out;
}

/// A new line begun at `caret` of what is being written (the line break just before it), after a list's item: what is
/// written with the next item's mark put in after the break (a number one more), the caret after it; after an item
/// with no words, its mark and the break taken out instead (the list ended, the caret on the line left empty). Null
/// where the line before is no item.
export function itemAfter(text: string, caret: number): { text: string; caret: number } | null {
  if (caret < 1 || text[caret - 1] !== "\n") return null;
  const start = text.lastIndexOf("\n", caret - 2) + 1;
  const m = /^( *)(?:([-*])|(\d{1,9})([.)])) (.*)$/.exec(text.slice(start, caret - 1));
  if (!m) return null;
  if (m[5]!.trim() === "") return { text: text.slice(0, start) + text.slice(caret), caret: start };
  const mark = `${m[1]}${m[2] ?? `${Number(m[3]) + 1}${m[4]}`} `;
  return { text: text.slice(0, caret) + mark + text.slice(caret), caret: caret + mark.length };
}

/// How the field what is being written is in sets it (WordsStyle), its marks kept and drawn lighter, what they mark
/// set as its message will be: stretches apart and in order, each all that holds of it; none where nothing is marked.
export function draftStyles(text: string): WordsStyle[] {
  const { set } = read(text, true);
  if (set.length === 0) return set;
  const edges = [...new Set(set.flatMap((s) => [s.start, s.end]))].sort((a, b) => a - b);
  const out: WordsStyle[] = [];
  for (let k = 0; k + 1 < edges.length; k++) {
    const start = edges[k]!;
    const end = edges[k + 1]!;
    const here: WordsStyle = { start, end };
    for (const s of set) if (s.start <= start && end <= s.end && s.end > s.start) Object.assign(here, s, { start, end });
    if (Object.keys(here).length === 2) continue;
    const last = out[out.length - 1];
    if (last && last.end === start && !last.b === !here.b && !last.i === !here.i && !last.s === !here.s && !last.code === !here.code && !last.pre === !here.pre && !last.mark === !here.mark && !last.li && !here.li) last.end = end;
    else out.push(here);
  }
  return out;
}

/// What is being written, and what was sent from here before the core has it as a message (its outbox's `words`
/// otherwise), in the runs its message will be drawn in: the composer's marks (`@[its title]`) references to their chats
/// (their links the core's till sent: refs.ts), the rest read as personWords reads it.
export function draftWords(text: string): WordsRun[] {
  return wordsOf(text, true);
}
