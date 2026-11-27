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
/// line `code`, a fenced block of code `pre`.
export type WordsRun = { text: string; link?: string; ref?: true; to?: LinkTo; b?: true; i?: true; s?: true; code?: true; pre?: true };

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
/// A list's item: its mark at the start of a line, words after it.
const ITEM = /^( *)[-*] (?=\S)/gm;

function wordsOf(text: string, marks = false): WordsRun[] {
  const out: WordsRun[] = [];
  const plain = (part: string) => {
    for (const bit of bareLinks(part)) {
      if (typeof bit === "string") {
        if (bit !== "") out.push({ text: bit });
      } else {
        const to = linkTo(bit.url);
        out.push({ text: bit.url, link: bit.url, ...(to?.chat ? { ref: true as const } : {}), ...(to ? { to } : {}) });
      }
    }
  };
  const linked = (part: string) => {
    for (const each of splitBy(part, REF_LINK)) {
      if (typeof each === "string") plain(each);
      else {
        const to = linkTo(each[2]!);
        out.push({ text: each[1]!, link: each[2]!, ref: true, ...(to ? { to } : {}) });
      }
    }
  };
  // (a composer's marks, in what is not sent yet: draftWords)
  const referring = (part: string) => {
    if (!marks) return linked(part);
    for (const each of splitBy(part, REF_MARK)) {
      if (typeof each === "string") linked(each);
      else out.push({ text: each[1]!, ref: true });
    }
  };
  if (!/[*_~`]/.test(text) && !/^ *- \S/m.test(text)) {
    referring(text);
    return out;
  }
  for (const block of splitBy(text, FENCE)) {
    if (typeof block !== "string") {
      if (block[1] !== "") out.push({ text: block[1]!, pre: true });
      continue;
    }
    for (const part of splitBy(block.replace(ITEM, "$1• "), CODE)) {
      if (typeof part === "string") referring(part);
      else out.push({ text: /^ .*\S.* $/.test(part[2]!) ? part[2]!.slice(1, -1) : part[2]!, code: true });
    }
  }
  return emphasized(out);
}

type Mark = "**" | "__" | "~~" | "*" | "_";
const STYLE = { "**": "b", "__": "b", "~~": "s", "*": "i", "_": "i" } as const;
const space = (c: string) => c === "" || /\s/.test(c);
/// A letter or a digit of a word, ASCII's or not (Chinese): what `_` inside a word is between, never a mark there.
const wordy = (c: string) => c !== "" && !/[\s!-/:-@[-`{-~]/.test(c);
const ascii = (c: string) => /[0-9A-Za-z]/.test(c);

/// `runs` with the marks of emphasis in their words (what is no link and no code) taken out and what is between a
/// pair set so, links and code between them too. A pair is on one line: a mark opens before what is no space and
/// closes after what is no space; `_` opens only after a space or what opens a bracket or a quote and closes only at a
/// word's end (a name's or a path's `_` is no mark: `a_b_c`, `/a/__init__.py`), and a lone `*` is none between ASCII
/// letters or digits (`2*3*4`).
function emphasized(runs: WordsRun[]): WordsRun[] {
  // its pieces in order: words, a mark (words too unless it finds its pair), another run whole
  type Piece = { text: string; run?: WordsRun; mark?: Mark; gone?: true };
  const pieces: Piece[] = [];
  const from: ("b" | "i" | "s")[][] = [];
  const to: ("b" | "i" | "s")[][] = [];
  let open: { mark: Mark; at: number }[] = [];
  const meet = (mark: Mark, opens: boolean, closes: boolean) => {
    const at = pieces.length;
    pieces.push({ text: mark, mark });
    let was = -1;
    if (closes) for (let k = open.length - 1; k >= 0; k--) if (open[k]!.mark === mark) { was = k; break; }
    if (was >= 0 && open[was]!.at < at - 1) {
      const start = open[was]!.at;
      open = open.slice(0, was);
      pieces[start]!.gone = true;
      pieces[at]!.gone = true;
      (from[start] ??= []).push(STYLE[mark]);
      (to[at] ??= []).push(STYLE[mark]);
    } else if (opens) open.push({ mark, at });
  };
  for (let r = 0; r < runs.length; r++) {
    const run = runs[r]!;
    if (run.link !== undefined || run.ref || run.code || run.pre) {
      if (run.text.includes("\n")) open = [];
      pieces.push({ text: run.text, run });
      continue;
    }
    const text = run.text;
    // (what stands before its first letter and after its last: another run's words, a letter to these marks)
    const before = r > 0 ? "a" : "";
    const after = r + 1 < runs.length ? "a" : "";
    let at = 0;
    let words = 0;
    const said = (end: number) => {
      if (end > words) pieces.push({ text: text.slice(words, end) });
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
      at = end;
      const two = (c + c) as Mark;
      const one = c as Mark;
      if (n === 2) meet(two, opens, closes);
      else if (n === 1) {
        if (c === "*" && ascii(prev) && ascii(next)) pieces.push({ text: c });
        else meet(one, opens, closes);
      } else if (open.length > 0 && open[open.length - 1]!.mark === one) {
        // (`***` closing what `***` opened: the inner one first)
        meet(one, false, closes);
        meet(two, opens, closes);
      } else {
        meet(two, opens, closes);
        meet(one, opens, false);
      }
    }
    said(text.length);
  }
  if (!pieces.some((p) => p.gone)) return runs;
  const out: WordsRun[] = [];
  const on = { b: 0, i: 0, s: 0 };
  for (let k = 0; k < pieces.length; k++) {
    const p = pieces[k]!;
    for (const style of from[k] ?? []) on[style]++;
    for (const style of to[k] ?? []) on[style]--;
    if (p.gone) continue;
    const set: { b?: true; i?: true; s?: true } = { ...(on.b > 0 ? { b: true as const } : {}), ...(on.i > 0 ? { i: true as const } : {}), ...(on.s > 0 ? { s: true as const } : {}) };
    const last = out[out.length - 1];
    if (!p.run && last && last.link === undefined && !last.ref && !last.code && !last.pre && !last.b === !set.b && !last.i === !set.i && !last.s === !set.s) last.text += p.text;
    else out.push(p.run ? (p.run.pre ? p.run : { ...p.run, ...set }) : { text: p.text, ...set });
  }
  return out;
}

/// What is being written, and what was sent from here before the core has it as a message (its outbox's `words`
/// otherwise), in the runs its message will be drawn in: the composer's marks (`@[its title]`) references to their chats
/// (their links the core's till sent: refs.ts), the rest read as personWords reads it.
export function draftWords(text: string): WordsRun[] {
  return wordsOf(text, true);
}
