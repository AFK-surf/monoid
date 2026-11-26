// What the agent is told about its situation, appended to the runtime's own system prompt, and how messages are put to
// it. A change to how agents work gets a note in migrations.ts too, for the sessions begun before it.
import { constants } from "node:fs";
import { lstat, open, readdir, readFile } from "node:fs/promises";
import { createHash } from "node:crypto";
import { dirname, join } from "node:path";
import { portableName } from "../ops/paths.ts";
import type { MessageRow, PendingMessage, WidgetModel } from "../store/store.ts";
import type { BackgroundTask } from "./runtime.ts";
import { type CardChoice, STILLFAIL_SURFACE } from "../store/rows.ts";
import { STATION_AUTHOR } from "../store/rows.ts";


/// What points an agent at moving a station's things, said only where moving is on (move/station.ts `on`).
export const MOVE_LINE = " To move chats, or a whole station, to another station, skill stillfail-move.";

/// Concise always-on project & tag classification rules, included only when `FEATURES.projects` is active on this station.
export const PROJECTS_BLOCK = `\n- A project is any conceptual ongoing workstream or area of work (e.g. office CI, ops, a client, a product, research — not limited to GitHub repos or folders). Once the chat's topic is clear, silently classify it with chat_configure into an existing project (or "" to leave unclassified); wait if the opening is vague. Tags (0–3) are optional: prefer existing workspace tags, and when unsure leave tags empty instead of inventing ad-hoc tags.\n- To create a new project (even if a person asks), call project_manage with action="propose" to post a silent confirmation bar — creating a project does not auto-assign the current chat, and a proposal is not a blocking question (never end need_human for it).\n- Before managing projects or tags (listing all, editing notes/refs, renaming, merging, bulk reclassifying, cleaning tags), read skill stillfail-projects.`;

/// `project`: the directory the runtime runs in, for a session begun outside still.fail (in a terminal) and continued here.
/// `memory`: the workspace's memory as it is now (`readMemory`). `site`: what the deployment adds (`readSiteInstructions`).
/// `station`: this station's name ("" where it has none). `move`: whether moving to another station is on here (every
/// station's since 2026-11-21; a test's may say not): where it is not, its skill is not named. `projects`: whether
/// workspace project classification (`FEATURES.projects`) is on here. `person`: the email of who the session is for
/// (actor.ts `personOf`; "" where none is known), whose `skills/people/` file is named.
export function sessionInstructions(workspace: string, project: string | null, repos_dir: string, memory_path: string, memory: string, site = "", station = "", move = true, projects = false, person = ""): string {
  const projectLine = project === null ? "" : `- Project directory: ${project}. This session began outside still.fail (in a terminal on this machine) and goes on here: you run in that directory and keep working on it as before. The session workspace below is for scratch files only.\n`;
  const told = instructions(projectLine, workspace, repos_dir, memory_path, station, projects, personTag(person));
  return (move ? told : told.replace(MOVE_LINE, "")) + (site === "" ? "" : `\n\n${site}`) + (memory === "" ? "" : `\n\n<memory path="${memory_path}">\n${memory}\n</memory>`);
}

/// The most of the deployment's text an agent is told: a few lines that point at its skills, not a manual.
export const SITE_INSTRUCTIONS_MAX = 4096;

/// What the deployment the station runs in adds to every session's instructions (`STILLFAIL_SITE_INSTRUCTIONS`: a file,
/// read as the station starts), after still.fail's own: a machine that runs the station as part of itself (a Monoid
/// Machine) says what it is and which of its skills to read. None by default, and none when the file does not read;
/// cut at SITE_INSTRUCTIONS_MAX.
export async function readSiteInstructions(env: NodeJS.ProcessEnv = process.env): Promise<string> {
  const path = env.STILLFAIL_SITE_INSTRUCTIONS;
  if (!path) return "";
  const text = (await readFile(path, "utf8").catch(() => "")).trim();
  return text.length > SITE_INSTRUCTIONS_MAX ? text.slice(0, SITE_INSTRUCTIONS_MAX) : text;
}

/// The workspace's memory as it is now, told after the instructions: given with them, not by the runtime's home (a
/// profile serves every workspace, sessions/agent-home.ts). Read off the station's thread, at each process's opening,
/// hard-capped at `MEMORY_INJECT_HARD_MAX`, followed by the current station's `skills/machines/<stationTag>.md` (capped
/// at `STATION_MEMORY_MAX`) when `station` is non-empty, the person the session is for's `skills/people/<personTag>.md`
/// (capped at `PERSON_MEMORY_MAX`) when `person` is an email, and `overgrown` (computed on the untruncated `MEMORY.md`).
/// Read only: nothing is made or written.
export async function readMemory(path: string, station = "", person = ""): Promise<string> {
  const rawMemory = (await readFile(path, "utf8").catch(() => "")).trim();
  const grown = overgrown([["MEMORY.md", rawMemory], ...(await skillsBeside(path))]);
  const rawBytes = Buffer.byteLength(rawMemory, "utf8");
  const memory = rawBytes > MEMORY_INJECT_HARD_MAX
    ? `${truncateUtf8(rawMemory, MEMORY_INJECT_HARD_MAX)}\n\n[still.fail: MEMORY.md truncated at ${kb(MEMORY_INJECT_HARD_MAX)} (actual ${kb(rawBytes)}); read ${path} for the full file and condense or move non-global entries to skills/<project>/, skills/machines/, or skills/people/]`
    : rawMemory;
  let stationBlock = "";
  if (station.trim() !== "") {
    const stationPath = join(dirname(path), "skills", "machines", `${stationTag(station)}.md`);
    const body = await cappedMemory(stationPath, STATION_MEMORY_MAX, "station memory");
    if (body !== null) stationBlock = `<station-memory station="${escapeAttr(station)}" path="${escapeAttr(stationPath)}">\n${body}\n</station-memory>`;
  }
  let personBlock = "";
  const tag = personTag(person);
  if (tag !== "") {
    const personPath = join(dirname(path), "skills", "people", `${tag}.md`);
    const body = await cappedMemory(personPath, PERSON_MEMORY_MAX, "person memory");
    if (body !== null) personBlock = `<person-memory person="${escapeXmlAttr(person.trim().toLowerCase())}" path="${escapeXmlAttr(personPath)}">\n${body}\n</person-memory>`;
  }
  return [memory, stationBlock, personBlock, grown].filter((part) => part !== "").join("\n\n");
}

const kb = (n: number) => `${Math.ceil(n / 1024)} KB`;

/// A memory file at `path` as it is injected: at most `max` UTF-8 bytes of it, trimmed, with a note naming the file when
/// it is longer (`what` says whose memory it is); null when it is missing, empty, or not to be read (`readBounded`).
async function cappedMemory(path: string, max: number, what: string): Promise<string | null> {
  const read = await readBounded(path, max + MEMORY_READ_SLACK);
  if (read === null) return null;
  const trimmedBytes = Buffer.byteLength(read.text, "utf8");
  if (!read.overCap && trimmedBytes <= max) return read.text;
  const actual = read.overCap ? read.totalBytes : trimmedBytes;
  return `${truncateUtf8(read.text, max)}\n\n[still.fail: ${what} truncated at ${kb(max)} (actual ${kb(actual)}); read ${path} for the full file and condense it]`;
}

/// Length of the longest prefix of `buf` that ends on a complete UTF-8 code point boundary.
function utf8CompletePrefixLen(buf: Buffer): number {
  const end = buf.length;
  if (end === 0) return 0;
  let i = end - 1;
  while (i > 0 && end - i < 4 && (buf[i]! & 0xc0) === 0x80) i--;
  const lead = buf[i]!;
  const need = lead < 0x80 ? 1 : (lead & 0xe0) === 0xc0 ? 2 : (lead & 0xf0) === 0xe0 ? 3 : (lead & 0xf8) === 0xf0 ? 4 : 1;
  return end - i < need ? i : end;
}

/// Safely read a memory file: skip non-regular files (including symlinks) and owner-only (`0600`) private files, and
/// read at most `cap` bytes so huge files are never pulled whole into memory. Opened without following a link where the
/// system can (`O_NOFOLLOW`) and looked at again once open, so a file swapped for a link meanwhile is not read either.
async function readBounded(path: string, cap: number): Promise<{ text: string; totalBytes: number; overCap: boolean } | null> {
  const unread = (st: { isFile(): boolean; mode: number; size: number }) => !st.isFile() || (st.mode & 0o077) === 0 || st.size === 0;
  try {
    if (unread(await lstat(path))) return null;
  } catch {
    return null;
  }
  let fh;
  try {
    fh = await open(path, constants.O_RDONLY | (constants.O_NOFOLLOW ?? 0));
    const st = await fh.stat();
    if (unread(st)) return null;
    const overCap = st.size > cap;
    const toRead = overCap ? cap : st.size;
    const buf = Buffer.allocUnsafe(toRead);
    let offset = 0;
    while (offset < toRead) {
      const { bytesRead } = await fh.read(buf, offset, toRead - offset, offset);
      if (bytesRead === 0) break;
      offset += bytesRead;
    }
    const slice = buf.subarray(0, offset);
    const validEnd = offset < st.size ? utf8CompletePrefixLen(slice) : offset;
    const text = slice.subarray(0, validEnd).toString("utf8").trim();
    if (text === "") return null;
    return { text, totalBytes: st.size, overCap };
  } catch {
    return null;
  } finally {
    await fh?.close().catch(() => {});
  }
}

/// The most a memory file holds before an agent is told to condense it, in bytes (MEMORY.md, a team skill's SKILL.md),
/// and the longest line of one. Every session of the workspace reads MEMORY.md and a project's skill whole: one that
/// grew into a log of progress (skills/stillfail/SKILL.md reached 165 KB on 2026-11-15, 49 "status" sections that
/// contradicted each other) costs each session tens of thousands of tokens and misleads it. A merge keeps both
/// versions where two stations changed one place (share/memory.ts, merged by station/mb src/memory), so what came
/// twice is the agents' to tidy too.
export const MEMORY_MOST = 8 * 1024;
export const MEMORY_INJECT_HARD_MAX = 16 * 1024;
export const STATION_MEMORY_MAX = 4 * 1024;
export const PERSON_MEMORY_MAX = 4 * 1024;
/// How much past its cap a station's or person's memory file is read (`readBounded`): enough to say how long it is.
const MEMORY_READ_SLACK = 4096;
export const SKILL_MOST = 24 * 1024;
export const LINE_MOST = 1500;

const WINDOWS_RESERVED_TAG = /^(?:CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])$/i;

/// A station's name as a safe filename stem: letters, digits, `_` and `-` alone, truncated at 40 complete Unicode code
/// points, trailing `-` stripped, and guarded against Windows reserved device names.
export function stationTag(station: string): string {
  const cleaned = station.replace(/[^\p{L}\p{N}_-]+/gu, "-").replace(/^-+|-+$/g, "");
  const cut = Array.from(cleaned).slice(0, 40).join("").replace(/-+$/, "");
  if (cut === "") return "station";
  return WINDOWS_RESERVED_TAG.test(cut) ? `${cut}-station` : cut;
}

const PERSON_TAG_MOST = 80;
const PORTABLE_RESERVED = /^(?:con|prn|aux|nul|com[0-9¹²³]|lpt[0-9¹²³])(?:\.|$)/i;

/// A person's email as a safe filename stem of `skills/people/` (what `skill_read {name: "people", file: "<tag>.md"}`
/// reads), "" for anything that is not one email (`local`, `slack:…`, empty, no `@` or more than one). The email
/// trimmed and lower-cased is kept as it is when it holds only `[a-z0-9._@-]`, starts with none of `._-`, ends with
/// neither `.` nor `-`, has no `..`, is not a Windows reserved name and is at most 80 characters
/// (`kuan.sun@hypershell.tech`). Otherwise it is `_`, what of it may stay cut to 66, `-` and 12 hex digits of its
/// SHA-256: at most 80 characters, never reserved, never another email's, and never a kept one's (none starts with `_`).
export function personTag(person: string): string {
  const email = person.trim().toLowerCase();
  if (email === "" || email === "local" || email.startsWith("slack:")) return "";
  const at = email.indexOf("@");
  if (at <= 0 || at === email.length - 1 || email.indexOf("@", at + 1) !== -1 || /\s/.test(email)) return "";
  const plain = /^[a-z0-9._@-]+$/.test(email) && !/^[._-]|[.-]$|\.\./.test(email) && !PORTABLE_RESERVED.test(email) && email.length <= PERSON_TAG_MOST && portableName(`${email}.md`);
  if (plain) return email;
  const kept = email.replace(/[^a-z0-9._@-]+/g, "-").replace(/\.{2,}/g, ".").replace(/^[._-]+/, "").slice(0, PERSON_TAG_MOST - 14).replace(/[.-]+$/, "");
  const hash = createHash("sha256").update(email).digest("hex").slice(0, 12);
  return kept === "" ? `_${hash}` : `_${kept}-${hash}`;
}

/// Truncate `text` to at most `maxBytes` UTF-8 bytes, preferring a `\n` line boundary when it is within `LINE_MOST`
/// bytes of `maxBytes`, and otherwise cutting at a complete Unicode code point boundary (never splitting a multi-byte
/// UTF-8 character or UTF-16 surrogate pair).
function truncateUtf8(text: string, maxBytes: number): string {
  if (Buffer.byteLength(text, "utf8") <= maxBytes) return text;
  if (maxBytes <= 0) return "";
  let bytes = 0;
  let lastNewline = -1;
  let bytesAtLastNewline = 0;
  let end = 0;
  for (let i = 0; i < text.length; ) {
    const cp = text.codePointAt(i)!;
    const step = cp > 0xffff ? 2 : 1;
    const cpBytes = cp <= 0x7f ? 1 : cp <= 0x7ff ? 2 : cp <= 0xffff ? 3 : 4;
    if (cp === 0x0a) {
      lastNewline = i;
      bytesAtLastNewline = bytes;
    }
    if (bytes + cpBytes > maxBytes) break;
    bytes += cpBytes;
    i += step;
    end = i;
  }
  const cut = lastNewline > 0 && bytesAtLastNewline >= maxBytes - LINE_MOST ? lastNewline : end;
  return text.slice(0, cut);
}

/// The team skills' SKILL.md beside the memory at `path` (`skills/<name>/SKILL.md`), as [relative path, text].
async function skillsBeside(path: string): Promise<[string, string][]> {
  const dir = join(dirname(path), "skills");
  const names = await readdir(dir, { withFileTypes: true }).catch(() => []);
  const out: [string, string][] = [];
  for (const e of names) {
    if (!e.isDirectory()) continue;
    const text = await readFile(join(dir, e.name, "SKILL.md"), "utf8").catch(() => null);
    if (text !== null) out.push([`skills/${e.name}/SKILL.md`, text]);
  }
  return out.sort(([a], [b]) => (a < b ? -1 : 1));
}

/// What of `files` ([relative path, text]) is past MEMORY_MOST, SKILL_MOST or LINE_MOST, as a note to the agent; "" when
/// nothing is.
export function overgrown(files: [string, string][]): string {
  const kb = (n: number) => `${Math.ceil(n / 1024)} KB`;
  const said: string[] = [];
  for (const [rel, text] of files) {
    const bytes = Buffer.byteLength(text, "utf8");
    const most = rel === "MEMORY.md" ? MEMORY_MOST : SKILL_MOST;
    const long = text.split("\n").filter((l) => Buffer.byteLength(l, "utf8") > LINE_MOST).length;
    const why = [bytes > most ? `${kb(bytes)}, past ${kb(most)}` : "", long > 0 ? `${long} line${long === 1 ? "" : "s"} past ${LINE_MOST} bytes` : ""].filter((x) => x !== "");
    if (why.length > 0) said.push(`- ${rel}: ${why.join("; ")}`);
  }
  if (said.length === 0) return "";
  return `[still.fail: this memory has grown past what an agent can use: condense a file you touch before you add to it]\n${said.join("\n")}\nKeep the lasting rules and facts, one line each; drop progress, status and handover notes (they belong in a chat's own workspace); keep one of what is said twice and the newest of what contradicts.`;
}

const instructions = (project: string, workspace: string, repos_dir: string, memory_path: string, station: string, projects: boolean, person: string) => `You work on this machine for people who write to you from still.fail chats, Slack threads, Feishu chats, group (IM) chats and Comma Tasks.

Messages:
- Each message comes as <message via="web|slack|feishu|group|comma" thread="…" from="…" ts="…">: thread is the conversation to answer in. sent_at is the message's time in UTC; recorded_at is when the station recorded it if its identifier does not encode a time. ts is the original message identifier. A delivery says when it was handed to you in UTC. via="station" is a notice (a job ended): act on it and tell whoever asked for the work.
- One session can hear several threads: answer each in its own. Not every message is for you; other agents are bots: build on their work and mention them when you need something.
- before="TS" means it was written before your post TS, without seeing it.
- A chat_post is held back when messages you have not read came in its thread first; read them, then send it unchanged with send=<its id> if it still stands, or post what fits now.
- A message headed 来自/From <a chat's link> is a letter from another chat's agent: answer it with session_send to that link. A chat headed 由…领导的/Led by <a chat's link> is a part of that chat's work: work in it with chat_post; its leader hears how your turns end and is who you ask (need_human reaches it, not a person); report your conclusions and their evidence apart, and what you would drop, found no gain in, or think needs a person as a proposal for it to decide. One headed …为你开的/Opened for you by <a chat's link> is your person's: work for them as in any chat. One headed 由…开的/Opened by: its opener hears how your turns end.
- Told to stop following a Slack, Feishu or group thread: say so in a sentence and chat_leave it.
- Write in the language the chat's people write in. Code, commits and pull requests follow their repository.

Answering:
- Only chat_post reaches people; your ordinary output reaches nobody. chat_post to=<the message's thread>.
- A subagent you start says nothing itself: it hands its result back to you, and you post what people need. Never have one post to the chat, end the turn, write to another chat's agent or write to Slack.
- Give the chat a title (a few words) with your first post once its topic is clear: what the whole chat is for, never the step you are on.${projects ? PROJECTS_BLOCK : ""}
- Post the answer, results and questions; when a request or change will take more than a couple of minutes, reply briefly first with the cause and plan rather than staying silent until the end, and post brief progress updates during long multi-step waits.
- Ask only when a real choice blocks the work. When people would answer by picking or confirming, attach an options card (card.assignee: the deciding person's email, from their message's from; an email your runtime calls its user's is the account you run on, not a person here); when they must type a value, a text card. Do not ask about what is already decided or authorized.
- Where people gave a principle, decide by it yourself: do not bring them the steps or small choices; ask only what it does not settle and cannot be undone, or only they can decide. Anything that makes someone wait is a decision: ask it plainly.
- Told off with nothing new found, do not change your answer or give a new date: work out what they want, then say it again.
- Asked to do something as another chat did, read that chat from its start first (what was asked there, what it used), and never have people carry words between chats. Another chat's agent asking this chat to take up a large piece of another line of work: ask this chat's people first.
- Before fixing a bug, look whether someone already opened or merged a fix (pull requests by its issue, its words and its files; the files' recent commits).
- Never ask people to run a command or paste a secret: use the login tool for logins (skill stillfail-login), the vault for credentials (skill stillfail-vault).
- For visible results show them (skills stillfail-show, stillfail-viz). For other chats, agents, Slack or Feishu APIs and archive policy, read skill stillfail-chats. To move chats, or a whole station, to another station, skill stillfail-move. To lead other chats or subagents toward one goal, skill stillfail-leading. When you do not have a skill that your instructions or a tool's description names, read it with skill_read by its name.

End every turn with one state, given as kind on your last chat_post or with chat_state:
- all_done with done: only when nothing people asked for in the chat is left (no next step of yours, no unmerged branch, no open question): what was finished and the evidence (a commit, a release, the answer given). A step of a longer goal done is not all_done.
- need_human with need: what a person must give, decide or check, asked first in a visible message. Not for what they already decided or told you to do.
- waiting with for and seconds: only for your own work that runs on and brings you back (a background command or agent, a job, a loop watching CI).
- Otherwise do not end the turn: a post that says what you do next means you go on doing it now.

Formatting: GitHub Markdown everywhere. Differences:
| | still.fail chat (thread CHAT/… or EMBER/…) | Slack | Feishu | group |
|---|---|---|---|---|
| mention | write the name | <@USER_ID> | <at id=OPEN_ID></at> | @name |
| files (chat_post files=[paths]) | ![](shot.png) places an image, [name](file) a file | uploaded below the text | sent below the text | sent with the text |
| math | \\(…\\) and \\[…\\] | Unicode plain text | Unicode plain text | Unicode plain text |
Write file names as \`code\`.

Where you work:
${project}- Session workspace: ${workspace}: scratch files, clones and worktrees. Only files sent in the chat outlive it; push what must last.
- Shared repository cache: ${repos_dir}: canonical clones; open a detached worktree in your workspace to read or change one (never edit the cache directly), and batch independent reads and searches in parallel rather than slicing files through the shell.
- A repository's AGENTS.md (or CLAUDE.md) files, its root's and each directory's down to where you change code, are its rules: read them first (you may be told them as you reach a directory) and keep them true in what you change.

Memory:
- The memory and skills are the same on every station of this workspace: the stations keep them level, an edit here reaching the others within seconds.${station === "" ? "" : ` You are on station ${station}.`} A line or skill marked [<station>] came from that station before the memory was shared.
- Route memory into four layers (even when asked to "remember globally", place each fact in the right layer rather than dumping everything into MEMORY.md):
  1. Global memory ${memory_path} (<= 8 KB, injected below; hard-capped at 16 KB): only cross-project, cross-person, cross-machine rules that would break things if forgotten, one concise line each.
  2. Project memory: skills/<project>/SKILL.md beside it, description starting "项目记忆：". Before working out a project's build or workflow from source, search kinds=["skill"].
  3. Machine/environment memory: ${station === "" ? "skills/machines/<station-tag>.md" : `skills/machines/${stationTag(station)}.md`} (indexed by skills/machines/SKILL.md with valid YAML frontmatter \`name\` and \`description\`) for per-machine paths, build hosts, accounts and ops pitfalls; the current station's file is auto-injected at session start (<station-memory>, capped at 4 KB), read other machines on demand with \`skill_read {name: "machines", file: "<tag>.md"}\`.
  4. People & preferences: ${person === "" ? "skills/people/<person-tag>.md" : `skills/people/${person}.md`} (indexed by skills/people/SKILL.md with valid YAML frontmatter \`name\` and \`description\`; the tag is the person's email in lower case) for team roles and personal communication preferences; ${person === "" ? "the file of the person a session is for" : "this file, of the person this session is for,"} is auto-injected at session start (<person-memory>, capped at 4 KB), read other people's on demand with \`skill_read {name: "people", file: "<tag>.md"}\`, never pile into MEMORY.md.
- A file named *.conflict-<station>.* beside a skill's is that station's version made at the same time and not merged: merge what it adds into the skill and delete it.
- Keep memory short and consistent: lasting rules and facts only, never progress, status or handover notes (those go in your chat's workspace); before writing, check whether the target file already has an entry on the same topic and update/replace it in place rather than appending duplicates. Where two stations changed one place at once the merge keeps both versions: keep one. No credentials.`;

export const NUDGE = `Your turn ended without a state, so nobody knows where the chat stands. Only a real unresolved need requires need_human. A factual answer alone does not need a follow-up question; do not invent one. If you still need something after answering a clarification, visibly ask for it; need alone is only a status summary. If you ask a person to choose or confirm, post the question with a card. Do not reopen a decision the user already made. Decide whether anything in it is still unfinished, then end the turn with exactly one:
- all_done: nothing in the chat is left unfinished at all. Post the result with chat_post kind "all_done" (or chat_state "all_done" if you already posted it), with done: why nothing is left, naming the evidence (a commit, a release, a person's confirmation, the answer given).
- need_human: a person has to give, do, decide, confirm or verify something (a card you posted included), or answer a question you asked: kind "need_human" with need, what they have to give, do or decide (to verify: where, how and what to look at). If work you started is pending too, mention it after the ask in need.
- waiting: only work you started that will bring you back on its own (a background command or agent, a job, a loop watching CI), with nothing asked of anyone, and nothing else you can do meanwhile: "waiting" (chat_post, or chat_state if you already posted) with seconds, your estimate of how long until it does, and for, what you wait for. Waiting on a person is need_human.
- Otherwise: continue the work.`;

/// Its turn ended in a state and the chat `to` it was in still has no title.
export const nameUntitled = (to: string) => `The chat ${to} still has no title, and nobody is at work in it now. Give it one: chat_post with only to "${to}" and title, a few words on what it is about in the language its people use. Post nothing else, then record again the state you just ended with (chat_state, with the same done or need).`;

export const RESUME_AFTER_RESTART = `The station restarted while you were in the middle of a turn, so that turn was cut off. Check where you were (files, git state, anything you started), then continue. Post only if people need to know.`;

export const GO_ON_AFTER_AUTH = `Your last turn stopped on an authentication error. The station reopened the runtime to reload its credentials. Continue the unfinished work from this conversation. First check the transcript, files and any operations already started; do not repeat completed actions. If an action's outcome is uncertain, verify it before retrying. Post only if people need to know.`;
export const GO_ON_AFTER_CODEX_UPDATE = `Your last turn stopped because Codex was too old for the selected model. The station updated Codex and reopened this conversation. Continue the unfinished work from this conversation. First check the transcript, files and any operations already started; do not repeat completed actions. If an action's outcome is uncertain, verify it before retrying. Post only if people need to know.`;

export const GO_ON_AFTER_SPENT = `Your last turn was cut off: the account it ran on hit its usage limit. You now run on another account (or runtime or model). Check where you were, then continue the work. Do not announce the switch itself, but if what remains will take more than a couple of minutes and people have not yet been told the plan or where things stand, post a brief progress note before going on.`;

export const GO_ON_AFTER_OVERLOADED = `Your last turn was cut off: the model was at capacity (the provider's side, not your account), and the station waited a while before trying again. Check where you were, then continue the work. Post only if people need to know.`;

export const GO_ON_AFTER_FAILED = `Your last turn failed (the model service or the connection to it went wrong), and a person asked to try again. Check where you were, then continue the work. Post only if people need to know.`;

export const GO_ON_AFTER_UNANSWERED = `Your last turns ended without a state (or without reaching anyone), and the station stopped asking; a person asked to try again. Check where you were, then post what people still need to see (your answer, results, questions) and end the turn with a state as usual.`;

export const GO_ON_AFTER_REFILL = `Your last turn was cut off: the account it ran on hit its usage limit, and no other account could take over. Its allowance should have refilled by now. Check where you were, then continue the work. Post only if people need to know.`;

export const TOOLS_LOST = `Your last turn could not reach the station's tools (chat_post, chat_state and the rest failed or were not connected), so nothing you said reached anyone. The station restarted your process; the tools work again. Check where you were, then post what people still need to see (your answer, results, questions) and end the turn with a state as usual.`;

/// Its runtime session could not be taken up, so a new one started: where its earlier conversation is, for it to read
/// (its execution history reads the runtime sessions it ran in as one); `terminal`: the machine's own transcript of the
/// terminal session it was continued from.
export const resumeLost = (key: string, threads: string[], terminal: string | null = null) => `Your earlier conversation could not be restored: this is a new one. Before you answer, read back what you need from where it is: ${terminal === null ? "" : `this session began in a terminal, and what was said there is in ${terminal} (its runtime's own transcript: read it from its end); `}session_history with chat ${key} (the latest entries first; older ones with before)${threads.length === 0 ? "" : `, and chat_history for ${threads.join(", ")}`}.`;

/// It goes on in a new runtime session: the earlier one is not taken up; it reads back what it needs from it.
export const afresh = (key: string, threads: string[]) => `This is a new conversation: your earlier one in this session is no longer used. Before you act on what comes below, read back from it what you need: session_history with chat ${key} (the latest entries first; older ones with before)${threads.length === 0 ? "" : `, and chat_history for ${threads.join(", ")}`}.`;

/// Its chats have this many messages (more than `LONG_CHAT`) as its context is compacted or it goes on in a new
/// conversation: what people asked early on is a summary now, or not loaded at all, and an agent going on from that
/// drifts from it.
export const longChat = (count: number, threads: string[]) => `This chat is long (${count} messages), and most of it is no longer in front of you. Before you go on, read back what people said in it${threads.length === 0 ? "" : ` (chat_history for ${threads.join(", ")}, older pages with before)`}: their requests, decisions and corrections from the start. Check that what you are doing still follows them, so that you do not drift from what they asked.`;

/// From how many messages in its chats a session compacted or gone on afresh is told to read back what people said
/// (`longChat`).
export const LONG_CHAT = 20;

/// Its context was cleared by hand (session.clear, `-clear`): a new conversation that reads its chats back, and what it did
/// before (its execution history) only when it needs it.
export const cleared = (key: string, threads: string[]) => `People cleared your context: this is a new conversation in the same chat, and your earlier one in this session is no longer loaded. Read the chat back before you act on what comes below${threads.length === 0 ? "" : `: chat_history for ${threads.join(", ")}`}. Your earlier work (session_history with chat ${key}) is not to be read back by default: only when you need something from it.`;

/// Its process was ended with work going in the background (agents/runtime.ts `background`), which ended with it:
/// `resumable` are the subagents SendMessage takes up where they stopped.
export const backgroundStopped = (tasks: BackgroundTask[], resumable: string[]) => `The station ended your earlier process (people stopped you, or it moved this session to another account, took a change to it or started it again), and the work it had going in the background was stopped with it. None of it will report back:
${tasks.map((t) => `- ${t.kind === "agent" ? "subagent" : "background command"} ${t.id}${t.description === "" ? "" : ` (${t.description})`}${resumable.includes(t.id) ? ": SendMessage to it goes on from where it stopped" : ""}`).join("\n")}
Before you wait on any of it, check where each got to and start again what is still needed.`;

/// Its turn ended waiting, and the station ended its process at that turn's end: the background work it waits on is
/// gone (told above it, `backgroundStopped`).
export const BACKGROUND_STOPPED_WAITING = `You ended your last turn waiting, but what you waited on was stopped with your process (see above), so it will never bring you back. Check where it got to (a run it watched may already be done), act on that, and watch again what is still going before you wait.`;

/// The agent said it would wait this long, and nothing has brought it back.
export const waitOver = (seconds: number) => `You said you were waiting on work you started (${seconds} seconds), and nothing has brought you back yet. Check on it now.
- If it is done: pick up its results and carry on. If nothing was watching it (you would have been told when it ended), start a watch the next time instead of waiting on a guessed duration.
- If it is still running: make sure something will tell you when it ends or fails (a background command or agent, a job with watch, a loop polling CI that exits on the first failure), do whatever else you can meanwhile, and only then end the turn waiting again. If it truly cannot be watched, wait the shortest it could still take.
- If it has stopped or is stuck: say so in the thread, and fix or restart it if you can.`;

/// The session has cycled through waiting turns without posting in the chat for this many minutes: an update asked of
/// it, or left to it (as the person who started it set: progress-prefs.ts, the core's).
export const silentProgress = (minutes: number, strength: "require" | "remind") =>
  strength === "require"
    ? `You have not posted in the chat for ${minutes} minutes. Before you wait again or start another step, post a brief progress update with chat_post.`
    : `You have not posted in the chat for ${minutes} minutes. If there is progress people would want to know, post a brief update with chat_post; if there is nothing new to say, go on without posting.`;

/// The first turn in still.fail of a session begun in a terminal: from now on it works as still.fail's sessions do.
export const continuedHere = (instructions: string) => `This session began in a terminal and now goes on in still.fail: what people say comes as messages below, and nothing you write as ordinary output reaches them any more; answer with the station's tools. How still.fail works, from now on:

<stillfail-instructions>
${instructions}
</stillfail-instructions>`;

/// What an agent is told of a card it asked a person to decide in its chat (secret_use, secret_save, phone_use): the tool
/// call does not wait for the decision, which comes later as a notice; a call held would hold the agent's turn, and
/// with it everything else said in the chat meanwhile.
export const UNDECIDED = "You are told in this session when it is decided: meanwhile go on with what does not need it (answer the chat, other work); with nothing else left, end your turn need_human (about the card).";

/// A conversation address as the agent sees and names it.
export const threadAddress = (channel: string, threadTs: string) => `${channel}/${threadTs}`;

export function parseThreadAddress(value: string): [string, string] | null {
  const v = value.trim();
  const at = v.indexOf("/");
  if (at < 0) return null;
  const [channel, ts] = [v.slice(0, at), v.slice(at + 1)];
  // A Feishu chat's: its chat id and the message or topic it began with.
  if (/^oc_[A-Za-z0-9]+$/.test(channel) && /^om(t)?_[A-Za-z0-9]+$/.test(ts)) return [channel, ts];
  // A group connect's: its space's id, twice for its lobby, or with a topic's (src/group: a space's stream is a thread).
  if (/^[ds]_[0-9a-f]{24}$/.test(channel) && (ts === channel || /^t_[0-9a-f]{16}$/.test(ts))) return [channel, ts];
  const dot = ts.indexOf(".");
  if (dot < 0) return null;
  const [secs, micros] = [ts.slice(0, dot), ts.slice(dot + 1)];
  const ok = /^[A-Z0-9]+$/.test(channel) && /^[0-9]+$/.test(secs) && /^[0-9]+$/.test(micros);
  return ok ? [channel, ts] : null;
}

const escapeAttr = (value: string) => value.replaceAll("&", "&amp;").replaceAll('"', "&quot;");
/// `value` as an XML attribute's text, its markup characters too (a person's email is theirs to spell).
const escapeXmlAttr = (value: string) => escapeAttr(value).replaceAll("<", "&lt;").replaceAll(">", "&gt;");

/// A message's words as the agent reads them: quotes (which message, whose, the file of it quoted, the passage as a
/// blockquote, then the comment), then the words, then the files as paths (not a quoted message's file: the agent had
/// it with that message, and is only pointed back at it).
export function messageForAgent(m: MessageRow): string {
  const again = new Set<string>();
  const parts = m.quotes.map((q) => {
    let whose: string;
    if (q.role === "agent") whose = "your own earlier message";
    else if (q.role === "page") {
      // A mark on a web service's page in a preview: its own screenshot (`file`), or the whole page's from clients before.
      const shot = q.file ? m.attachments.find((a) => a.name === q.file) : undefined;
      whose = shot
        ? `a web page shown in the chat's preview (${q.author}), marked with its number in its own screenshot ${shot.path}`
        : `a web page shown in the chat's preview (${q.author}), marked with its number in the attached screenshot`;
    } else if (q.role === "image") whose = `an image marked in the chat (${q.author}), its number pinned on the marked image attached`;
    else if (q.role === "pdf") whose = `a PDF shown in the chat's preview (${q.author})`;
    else if (q.role === "file") whose = `a file shown in the chat's preview (${q.author}), its lines and heading in the file's own text`;
    else whose = `a message from ${q.author}`;
    let which = q.ts !== null && q.ts !== undefined ? `${whose} ${q.ts} in this conversation` : whose;
    // A file of that message quoted (an image or a video held in the chat): the message carries it again for the chat to
    // show, the agent only where it is.
    const quoted = q.file && q.role !== "page" && q.role !== "image" ? m.attachments.find((a) => a.name === q.file) : undefined;
    if (quoted) {
      which += `, its file ${quoted.path} (sent with that message, not again)`;
      again.add(quoted.path);
    }
    const passage = q.text.split("\n").map((l) => `> ${l}`);
    const comment = q.comment === "" ? "" : `\nTheir comment on it: ${q.comment}`;
    return `[Quote] From ${which}:\n${passage.join("\n")}${comment}`;
  });
  parts.push(m.text);
  const pasted = m.attachments.filter(a => /^pasted-text-[0-9a-f-]{36}\.txt$/.test(a.name));
  if (pasted.length) parts.push(`The user pasted text into the composer; its full contents are in these text attachments. Read them as part of the user's message:\n${pasted.map(a => `- ${a.path}`).join("\n")}`);
  const attached = m.attachments.filter((a) => !again.has(a.path));
  if (attached.length > 0) parts.push(`Attached files:\n${attached.map((a) => `- ${a.path} (${a.name}, ${a.size} bytes)`).join("\n")}`);
  return parts.filter((p) => p !== "").join("\n\n");
}

const via = (surface: string) => (surface === STILLFAIL_SURFACE ? "web" : surface.startsWith("feishu:") ? "feishu" : surface.startsWith("comma:") ? "comma" : surface.startsWith("group:") ? "group" : "slack");

/// The still.fail app a message was sent from, as an attribute; nothing for one that did not say.
const clientAttr = (m: MessageRow) => (m.client !== null && m.client !== undefined ? ` client="${escapeAttr(m.client)}"` : "");

/// Slack and app message IDs are seconds since the epoch; Comma's and a group's are sequence numbers, and Feishu's are opaque.
/// For the latter two only the time the station recorded the message is known (which can be later than it was sent).
function timeAttr(m: MessageRow, surface: string): string {
  const numeric = via(surface) !== "comma" && via(surface) !== "feishu" && via(surface) !== "group" && /^\d{10}(?:\.\d+)?$/.test(m.ts) ? Number(m.ts) * 1000 : NaN;
  const sent = Number.isFinite(numeric) && numeric <= 8.64e15 ? numeric : null;
  const recorded = Number.isFinite(m.createdAt) && m.createdAt > 0 && m.createdAt <= 8.64e15 ? m.createdAt : null;
  const at = sent ?? recorded;
  return at === null ? "" : ` ${sent === null ? "recorded_at" : "sent_at"}="${new Date(at).toISOString()}"`;
}

/// Messages handed to a session, each with its source and sender, and a hint where a thread is new to it.
/// `posts`: the agent's first post in a message's thread made after it (by ts), said as its `before`.
export function formatInbound(messages: PendingMessage[], newThreads: Set<number>, names: Map<string, string>, selves: Map<string, string>, posts: Map<PendingMessage, string> = new Map(), cards: Map<PendingMessage, { ended: Pick<MessageRow, "author" | "ts">; current: Pick<MessageRow, "ts"> | null; special: string | null }> = new Map(), selfKey = ""): string {
  const lines: string[] = [];
  const hinted = new Set<number>();
  for (const p of messages) {
    const m = p.message;
    const address = threadAddress(p.channel, p.threadTs);
    // Something was said before it: earlier entries, or (Slack) a reply rather than the thread's first message.
    const before = m.n > 1 || (p.surface !== STILLFAIL_SURFACE && m.ts !== p.threadTs);
    if (newThreads.has(m.thread) && before && !hinted.has(m.thread)) {
      hinted.add(m.thread);
      lines.push(`(Thread ${address} had messages before you were brought in; read them with chat_history to="${address}" if they matter.)`);
    }
    const self = selves.get(p.connect);
    const you = self !== undefined ? ` you="${escapeAttr(self)}"` : "";
    const agent = m.authorKind === "agent";
    const name = names.get(m.author);
    const from = agent ? (name ?? "another agent") : name !== undefined ? `${name} (${m.author})` : m.author;
    const post = posts.get(p);
    const sentBefore = post !== undefined ? ` before="${escapeAttr(post)}"` : "";
    lines.push(`<message via="${via(p.surface)}" connect="${escapeAttr(p.connect)}"${you} thread="${address}"${timeAttr(m, p.surface)} from="${escapeAttr(from)}"${agent ? " bot" : ""}${clientAttr(m)} ts="${m.ts}"${sentBefore}>\n${messageForAgent(m)}\n</message>`);
    const change = cards.get(p);
    if (change !== undefined) {
      const whose = change.ended.author === selfKey ? "Your card" : "A card";
      const now = change.current === null ? "No newer card is pending." : `A newer card (message ts ${change.current.ts}) is pending; the person may not have seen it.`;
      const next = change.ended.author !== selfKey ? "The agent that posted it can decide whether to ask again."
        : change.special !== null ? `The underlying login or authorization may still be pending. ${change.special}`
        : "If the decision is still needed and no newer card asks it, ask again with a new card.";
      lines.push(`<card-state thread="${escapeAttr(address)}" ts="${escapeAttr(change.ended.ts)}">${whose} is no longer pending after this message. The message is not necessarily a decision; read what it says. ${now} ${next}</card-state>`);
    }
  }
  return lines.join("\n");
}

/// How long ago, in words an agent reads: minutes up to an hour, hours and minutes up to a day, then days and hours.
function agoWords(ms: number): string {
  const minutes = Math.floor(Math.max(0, ms) / 60_000);
  if (minutes < 1) return "less than a minute";
  if (minutes < 60) return `${minutes} min`;
  const hours = Math.floor(minutes / 60);
  if (hours < 24) return minutes % 60 === 0 ? `${hours} h` : `${hours} h ${minutes % 60} min`;
  return hours % 24 === 0 ? `${Math.floor(hours / 24)} d` : `${Math.floor(hours / 24)} d ${hours % 24} h`;
}

/// One line of a card's question, cut to what recalls it.
const recalled = (text: string) => {
  const line = [...text.replace(/\s+/g, " ").trim()];
  return line.length > 200 ? `${line.slice(0, 200).join("")}…` : line.join("");
};

/// What people chose on the agent's cards with an option that closes them (no message was sent then), said before what
/// it is handed now (`now`, ms): when each was chosen, so it is not read as what the new messages are about. Empty
/// when none.
export function formatCardChoices(choices: CardChoice[], names: Map<string, string>, now: number): string {
  if (choices.length === 0) return "";
  const lines = choices.map((c) => {
    const name = names.get(c.by);
    const by = name !== undefined ? `${name} (${c.by})` : c.by;
    const thread = c.where === null ? "" : ` thread="${escapeAttr(threadAddress(c.where[0], c.where[1]))}"`;
    const card = c.ts === null ? "" : ` card="${escapeAttr(c.ts)}"`;
    const asked = c.question === null || c.question.trim() === "" ? "" : `Asked: ${recalled(c.question)}\n`;
    return `<card-choice${thread}${card} by="${escapeAttr(by)}" at="${(c.at / 1000).toFixed(6)}" ago="${agoWords(now - c.at)}">\n${asked}Chosen: ${c.option}\n</card-choice>`;
  });
  return `[Earlier choices on your cards, told to you now. Each closed its card when it was made (at, ago) without sending you a message, so this is the first you hear of it. They are settled and not new: what you are handed after them is not about them unless it says so. Do not answer a choice by itself or ask it again.]\n${lines.join("\n")}`;
}

/// What people chose in widgets the agent posted, riding along with messages it is handed anyway; empty when none.
export function formatWidgetModels(models: WidgetModel[]): string {
  if (models.length === 0) return "";
  const lines = models.map((w) => (w.thread ? `- ${w.name} in ${threadAddress(w.thread[0], w.thread[1])}: ${w.model}` : `- ${w.name}: ${w.model}`));
  return `A widget you posted has state for you (the person's choices in it; not a message to answer by itself):\n${lines.join("\n")}`;
}

/// A thread's messages for chat_history: people by name, this session's own posts as "you", other agents and the
/// station marked as bots.
export function formatHistory(messages: MessageRow[], surface: string, address: string, selfKey: string, names: Map<string, string>, cards: Map<number, { card: any; pending: boolean; chose?: { by: string; option: string } }> = new Map()): string {
  return messages
    .map((m) => {
      const from = m.authorKind === "agent" && m.author === selfKey ? "you" : m.authorKind === STATION_AUTHOR ? "station" : names.has(m.author) ? `${names.get(m.author)} (${m.author})` : m.author;
      const bot = m.authorKind !== "person" && from !== "you" ? " bot" : "";
      const found = cards.get(m.n);
      let card = "";
      if (found !== undefined) {
        const options = Array.isArray(found.card?.options) ? found.card.options : undefined;
        const facts = { type: found.card?.type, ...(options === undefined ? {} : { options }), ...(typeof found.card?.placeholder === "string" ? { placeholder: found.card.placeholder } : {}),
          ...(typeof found.card?.vault?.request === "string" ? { request: found.card.vault.request } : {}),
          ...(typeof found.card?.adb?.request === "string" ? { phoneRequest: found.card.adb.request } : {}),
          ...(typeof found.card?.signin?.site === "string" ? { site: found.card.signin.site } : {}),
          ...(typeof found.card?.login === "string" ? { login: found.card.login } : {}),
          ...(typeof found.card?.station === "string" ? { station: found.card.station } : {}) };
        // Closed by a choice that sent no message: nothing else in the thread says what was chosen.
        const chose = found.chose === undefined ? "" : `; ${found.chose.by} chose ${JSON.stringify(found.chose.option)}, which closed it without a message`;
        card = `\n[Answer card: ${found.pending ? "pending" : "no longer pending"}${chose}; ${JSON.stringify(facts)}]`;
      }
      return `<message via="${via(surface)}" thread="${address}"${timeAttr(m, surface)} from="${escapeAttr(from)}"${bot}${clientAttr(m)} ts="${m.ts}">\n${messageForAgent(m)}${card}\n</message>`;
    })
    .join("\n");
}
