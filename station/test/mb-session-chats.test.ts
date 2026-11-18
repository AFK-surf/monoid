// The chats' own logic in MoonBit (station/mb src/session_chats, the reader's `--builder harness-session-chats`) held
// to the TypeScript it is written from (src/sessions/conversations.ts, messages.ts, chat.ts, decision.ts,
// card-place.ts, presets.ts, opened.ts, review.ts, cc.ts, internal.ts, titles.ts, title-completion.ts,
// regenerate-title.ts, local-links.ts, image-size.ts, page.ts, neighbours.ts, config.ts): each case run by both, its
// answer (or what it threw) the same; where it asks the station, each asked of a hub of its own made the same way (the
// program's asks answered by its twin, `call`), and the hubs' own records of what was asked of them and what they keep
// afterwards the same. What other parts of the station give these (src/sessions/args.ts, others.ts, the readers, the
// agents' profiles) the program asks for as `dep.*`, answered by those parts themselves.
import assert from "node:assert/strict";
import { type ChildProcess, spawn } from "node:child_process";
import { mkdtempSync, rmSync } from "node:fs";
import { copyFile, mkdir, open, readFile, readdir, rename, rm, stat, symlink, writeFile } from "node:fs/promises";
import { homedir } from "node:os";
import { resolve } from "node:path";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { createInterface } from "node:readline";
import { after, mock, test } from "node:test";
import { mbReaderBinary } from "../src/read/mb-reader.ts";
import { sizeOf } from "../src/sessions/image-size.ts";
import { pageOrigin, sessionPage } from "../src/sessions/page.ts";
import { INTERNAL_BOT_USER, InternalChat, chatKey, chatWorkspace, isInternalChannel, nextTsAt } from "../src/sessions/internal.ts";
import { isNotice, markNotice, splitForSlack, toolStatus } from "../src/sessions/chat.ts";
import { parseThreadAddress, threadAddress } from "../src/agents/instructions.ts";
import { cleanTitle, nameChat, untitledChat } from "../src/sessions/titles.ts";
import { links, percentDecode } from "../src/sessions/local-links.ts";
import { setStationLang, stationLang, tr } from "../src/ops/i18n.ts";
import { log as stationLog } from "../src/ops/log.ts";
import { wall } from "../src/ops/fibers.ts";
import { allowedIn, hubConfig, profilesFor, runtimeTitle, sameModel, spelling } from "../src/sessions/config.ts";
import { profileRuntimes } from "../src/agents/profiles.ts";
import { modelKey } from "../src/read/usage.ts";
import { agyBaseModel } from "../src/agents/agy.ts";
import { devinFusionBase, splitDevinFusion } from "../src/agents/devin.ts";
import { cc, ccText } from "../src/sessions/cc.ts";
import { CcSessionsUnavailable } from "../src/store/cc-thread-index.ts";
import { MessageWriteBusy } from "../src/store/store.ts";
import { CARD_OCCUPIED, cardPlace, postCard, recordPostedCard } from "../src/sessions/card-place.ts";
import { chatNamed, fromPeer, postFrom, sender, senderTitleIfReady, sessionSend } from "../src/sessions/messages.ts";
import { Refused } from "../src/jobs/remote.ts";
import { fromBefore, linkedSession, linkedStation, named as namedChat, peersOf, reachable, scopeOf, sessionThreadOf } from "../src/sessions/others.ts";
import { given as givenTitle, titleOf } from "../src/read/views.ts";
import { aboutTs, cardArg, cardSaid, declaredStr, firstLine, isSlackMethod, jsNumber, jsString, needArg, placeFigures, saidAs, slackWithFiles, stateArg } from "../src/sessions/args.ts";
import { isSlackWrite } from "../src/tools/mcp.ts";
import { iso } from "../src/read/transcript.ts";
import { threadsToldOf } from "../src/sessions/afresh.ts";
import { formatHistory } from "../src/agents/instructions.ts";
import { fileURLToPath } from "node:url";
import { shownFactsSoon } from "../src/sessions/image-size.ts";
import { claim, sendAlong, sendable } from "../src/sessions/peer-files.ts";
import { attach, chatHistory, chatLeave, chatPost, chatState, mayStage, slackApi, slackConnectOf, staged, target, threadHistory, unheld } from "../src/sessions/conversations.ts";
import { makeStore as makeReadStore, statePendingCard as readStatePendingCard, stateQuestion as readStateQuestion } from "../src/read/store.ts";
import { loadMesh } from "../src/mesh/native.ts";
import { PlaceRefused } from "../src/ops/places.ts";
import { chatCreate, createForPeer, noticeForPeer, settled } from "../src/sessions/opened.ts";
import { newSession } from "../src/sessions/lifecycle.ts";
import { USED_WITHIN_MS, askWhich, candidates as modelCandidates, choose } from "../src/sessions/model-choice.ts";
import { contextAsked } from "../src/sessions/context-cap.ts";
import { acceptsCompletion, byDecisionPriority, completionQuestion, decide, decisionPriority, discover, fingerprint, parse as decisionParse, profileFilesRead, request as decisionRequest, resolvedModel, validate as validateDecision } from "../src/sessions/decision.ts";
import { policyStamp, policyWs, review, startReview, undecided } from "../src/sessions/review.ts";
import { archiveMass, policyFrom, policyQuestion, recommends } from "../src/sessions/archive-policy.ts";
import { usable } from "../src/sessions/pool.ts";
import { Presets, RepoIndex, candidates as presetCandidates, keepCopy, originIn, originOf, presetCopyInput, presetCopyOf, presetInput, presetInstructions, presetRefusal, readPresetsFile, repoIcon, repoName, shortPath } from "../src/sessions/presets.ts";
import { completeTitle, titleCompletion } from "../src/sessions/title-completion.ts";
import { regenerateTitle } from "../src/sessions/regenerate-title.ts";
import { canonical, goneKept, modelOf, newerRecord, recordOf, recordsKept, stationsOf } from "../../client/core-ts/src/preset-records.ts";
import { accessKind, apiSource, dshRoute, expandRoute, profileEnv, profileVia } from "../src/agents/profiles.ts";
import { endpoints, find as findSource } from "../src/agents/providers.ts";
import zhStation from "../../client/i18n/catalog/zh/station.json" with { type: "json" };
import enStation from "../../client/i18n/catalog/en/station.json" with { type: "json" };

const binary = mbReaderBinary();
const skip = binary === null ? "the MoonBit program (stillfail-reader) is not built here" : false;

type Json = any;
const dirs: string[] = [];
const fresh = (prefix: string) => {
  const d = mkdtempSync(join(tmpdir(), prefix));
  dirs.push(d);
  return d;
};

/// What a hub answers a name the program asks by: `dep.*` (another part's function), `store.*`, `hub.*`, `chat.*`
/// (`hub.chat(connect)`'s), `actor.*` (`hub.actors.get(key)`'s), `db.*` (`hub.store.db`'s statements).
export type Answerer = (name: string, args: Json[], callback: (id: number) => (...a: Json[]) => Promise<Json>) => Promise<Json>;

/// What a thrown error is told as: its kind (its class's name; a refusal of a place with its code) and its message.
export const kindOf = (e: unknown): string => {
  if (!(e instanceof Error)) return "";
  const said = (e as unknown as { kind?: unknown }).kind;
  if (typeof said === "string") return said;
  const code = (e as { code?: unknown }).code;
  const name = e.constructor.name === "Error" ? "" : e.constructor.name;
  return name === "PlaceRefused" && typeof code === "string" ? `${name}:${code}` : name;
};

/// JSON of what an answer is (undefined as null, as the wire says it).
const wire = (v: unknown): Json => (v === undefined ? null : JSON.parse(JSON.stringify(v) ?? "null"));

/// The program, asked a case at a time.
class Program {
  #child: ChildProcess;
  #answer: ((v: Json) => void) | null = null;
  #callbacks: ((v: Json) => void)[] = [];
  answerer: Answerer = async (name) => { throw new Error(`no hub to ask ${name}`); };
  constructor() {
    this.#child = spawn(binary!, ["--builder", "harness-session-chats", "--shell-dir", fresh("session-chats-shell-")], { stdio: ["pipe", "pipe", "inherit"] });
    createInterface({ input: this.#child.stdout! }).on("line", (line) => this.#heard(JSON.parse(line)));
  }
  #say(v: Json) {
    this.#child.stdin!.write(`${JSON.stringify(v)}\n`);
  }
  #heard(said: Json) {
    if (typeof said.call === "string") {
      const callback = (id: number) => (...a: Json[]) => new Promise<Json>((done, failed) => {
        this.#callbacks.push((r) => ("cbThrew" in r ? failed(Object.assign(new Error(r.cbThrew), { kind: r.kind })) : done(r.cbResult)));
        this.#say({ cb: id, args: wire(a) });
      });
      void this.answerer(said.call, said.args, callback).then(
        (v) => this.#say({ result: v !== null && typeof v === "object" && (v as Json).$u === 1 ? v : wire(v) }),
        (e) => this.#say({ threw: e instanceof Error ? e.message : String(e), kind: kindOf(e), data: wire(e !== null && typeof e === "object" ? Object.fromEntries(Object.entries(e)) : null) }),
      );
      return;
    }
    if ("cbResult" in said || "cbThrew" in said) {
      this.#callbacks.shift()?.(said);
      return;
    }
    const answer = this.#answer;
    this.#answer = null;
    answer?.(said);
  }
  ask(v: Json): Promise<Json> {
    return new Promise((resolve) => {
      this.#answer = resolve;
      this.#say(v);
    });
  }
  close() {
    this.#child.stdin!.end();
  }
}

let program: Program | null = null;
const mb = async () => {
  if (program === null) {
    program = new Program();
    await program.ask({ op: "words", zh: zhStation, en: enStation, product: "still.fail" });
  }
  return program;
};
after(() => {
  program?.close();
  for (const d of dirs) rmSync(d, { recursive: true, force: true });
});

/// What a TypeScript function gives, as the program says it: `{ok}` or `{error, kind}`.
export async function settledTs(f: () => unknown): Promise<Json> {
  try {
    return { ok: wire(await f()) };
  } catch (e) {
    return { error: e instanceof Error ? e.message : String(e), kind: kindOf(e) };
  }
}

/// A pure function of the program's by its TypeScript name, given the same arguments.
export async function mbFn(name: string, ...args: Json[]): Promise<Json> {
  return (await mb()).ask({ op: "fn", name, args: wire(args) });
}

/// One that asks the station, its asks answered by `answer`.
export async function mbWorld(answer: Answerer, name: string, ...args: Json[]): Promise<Json> {
  const p = await mb();
  p.answerer = answer;
  try {
    return await p.ask({ op: "world", name, args: wire(args) });
  } finally {
    p.answerer = async (n) => { throw new Error(`no hub to ask ${n}`); };
  }
}

export async function mbLang(lang: "zh" | "en") {
  await (await mb()).ask({ op: "lang", lang });
}

/// Both, the same: a pure function.
export async function same(name: string, ts: () => unknown, ...args: Json[]) {
  const want = await settledTs(ts);
  const got = await mbFn(name, ...args);
  if ("error" in want) {
    assert.deepEqual({ error: got.error, kind: got.kind }, want, `${name}(${JSON.stringify(args).slice(0, 300)})`);
  } else {
    assert.deepEqual(got, want, `${name}(${JSON.stringify(args).slice(0, 300)})`);
  }
}


// ── pure: image-size, page, internal, chat, titles, local-links ───────────────────────────────────────────────────

const u8 = (...xs: number[]) => Uint8Array.from(xs);
const asc = (s: string) => [...s].map((c) => c.charCodeAt(0));
const be32 = (n: number) => [(n >>> 24) & 255, (n >>> 16) & 255, (n >>> 8) & 255, n & 255];
const box = (type: string, body: number[]) => [...be32(body.length + 8), ...asc(type), ...body];

/// Pictures and films as their headers say them, and bytes that say nothing (or lie).
function pictures(): number[][] {
  const png = (w: number, h: number) => [0x89, ...asc("PNG\r\n\x1a\n"), 0, 0, 0, 13, ...asc("IHDR"), ...be32(w), ...be32(h), 8, 6, 0, 0, 0];
  const gif = (w: number, h: number) => [...asc("GIF89a"), w & 255, w >> 8, h & 255, h >> 8, 0, 0];
  const webp = (kind: string, rest: number[]) => [...asc("RIFF"), 0, 0, 0, 0, ...asc("WEBP"), ...asc(kind), ...rest];
  const vp8 = webp("VP8 ", [0, 0, 0, 0, 0, 0, 0, 0x9d, 0x01, 0x2a, 0x20, 0x03, 0x58, 0x02, 0, 0]);
  const vp8l = webp("VP8L", [0, 0, 0, 0, 0x2f, 0x1f, 0xc0, 0x15, 0x00, 0, 0, 0, 0, 0]);
  const vp8x = webp("VP8X", [0, 0, 0, 0, 0, 0, 0, 0, 0x7f, 0x02, 0, 0xdf, 0x01, 0, 0]);
  const exif = (o: number, le: boolean) => {
    const u16 = (n: number) => (le ? [n & 255, n >> 8] : [n >> 8, n & 255]);
    const u32 = (n: number) => (le ? [n & 255, (n >> 8) & 255, (n >> 16) & 255, n >>> 24] : be32(n));
    return [...asc("Exif"), 0, 0, ...asc(le ? "II" : "MM"), ...u16(42), ...u32(8), ...u16(1), ...u16(0x0112), ...u16(3), ...u32(1), ...u16(o), 0, 0];
  };
  const jpeg = (w: number, h: number, note: number[] | null, pad = 0) => [
    0xff, 0xd8,
    ...(note ? [0xff, 0xe1, (note.length + 2) >> 8, (note.length + 2) & 255, ...note] : []),
    ...Array(pad).fill(0xff),
    0xff, 0xdb, 0, 4, 1, 2,
    0xff, 0xc4, 0, 3, 9,
    0xff, 0xc0, 0, 11, 8, h >> 8, h & 255, w >> 8, w & 255, 3, 1, 1, 1,
    0xff, 0xd9,
  ];
  const matrix = (turned: boolean) => turned ? [0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0xff, 0xff, 0, 0, 0, 0, 0, 0, ...Array(16).fill(0), 0x40, 0, 0, 0] : [0, 1, 0, 0, ...Array(12).fill(0), 0, 1, 0, 0, ...Array(12).fill(0), 0x40, 0, 0, 0];
  const tkhd = (w: number, h: number, turned: boolean, v1 = false) => box("tkhd", [v1 ? 1 : 0, 0, 0, 0, ...Array(v1 ? 48 : 36).fill(0), ...matrix(turned), ...be32(w * 65536), ...be32(h * 65536)]);
  const mdhd = (scale: number, length: number) => box("mdhd", [0, 0, 0, 0, ...be32(0), ...be32(0), ...be32(scale), ...be32(length), 0, 0, 0, 0]);
  const mvhd = (scale: number, length: number) => box("mvhd", [0, 0, 0, 0, ...be32(0), ...be32(0), ...be32(scale), ...be32(length), ...Array(80).fill(0)]);
  const stsz = (n: number) => box("stsz", [0, 0, 0, 0, ...be32(0), ...be32(n)]);
  const film = (w: number, h: number, turned: boolean, opts: { v1?: boolean; audio?: boolean; frames?: number; mdhd?: [number, number]; mvhd?: [number, number] } = {}) => [
    ...box("ftyp", [...asc("isom"), 0, 0, 2, 0]),
    ...box("moov", [
      ...(opts.mvhd ? mvhd(...opts.mvhd) : []),
      ...(opts.audio ? box("trak", tkhd(0, 0, false)) : []),
      ...box("trak", [...tkhd(w, h, turned, opts.v1), ...box("mdia", [...(opts.mdhd ? mdhd(...opts.mdhd) : []), ...box("minf", box("stbl", opts.frames ? stsz(opts.frames) : []))])]),
    ]),
  ];
  return [
    png(1920, 1080), png(0, 10), png(4294967295, 2), png(1, 1).slice(0, 23), gif(640, 480), gif(0, 5), vp8, vp8l, vp8x, vp8.slice(0, 29),
    jpeg(4032, 3024, null), jpeg(4032, 3024, exif(6, true)), jpeg(4032, 3024, exif(8, false)), jpeg(100, 50, exif(1, true)), jpeg(100, 50, exif(6, true), 5),
    jpeg(100, 50, [...asc("Exif"), 0, 0, ...asc("XX"), 0, 42]), jpeg(7, 9, null).slice(0, 20), [0xff, 0xd8, 0xff, 0xda], [0xff, 0xd8, 0xff, 0xe0, 0, 1],
    film(1920, 1080, false), film(1920, 1080, true, { frames: 300, mdhd: [600, 6000] }), film(640, 360, false, { audio: true, v1: true, mvhd: [1000, 12345] }),
    film(640, 360, false, { mdhd: [0, 5], mvhd: [1000, 4294967295], frames: 0 }), film(10, 10, false).slice(0, 60),
    [], [1, 2, 3], asc("not a picture at all, just words"),
  ];
}

test("image-size: a picture's or film's size, as the core reads it", { skip }, async () => {
  for (const p of pictures()) await same("sizeOf", () => sizeOf(u8(...p)), p);
});

test("page: the app's origin and a session's page", { skip }, async () => {
  for (const o of ["https://app.still.fail", "https://app.monoid.build", "https://x.example", ""]) {
    for (const c of ["stable", "beta"] as const) await same("pageOrigin", () => pageOrigin(o, c), o, c);
  }
  const base = { origin: "https://app.still.fail", workspace: "w1", station: "s9" };
  for (const key of ["chat:c-1", "slack:T1/C2/1700000000.000100", "a b/ç?&=#é😀", "-_.!~*'()"]) await same("sessionPage", () => sessionPage(base, "W", key), base, "W", key);
});

test("internal: its channels, keys, workspaces and timestamps", { skip }, async () => {
  for (const c of ["CHAT", "EMBER", "C123", "chat", ""]) await same("isInternalChannel", () => isInternalChannel(c), c);
  for (const [id, made] of [["c-1", []], ["c-1", ["ember:c-1"]], ["c-1", ["chat:c-1", "ember:c-1"]], ["c-2", ["chat:c-1"]]] as [string, string[]][]) {
    await same("chatKey", () => chatKey(id, (k) => made.includes(k)), id, made);
  }
  for (const [d, k] of [["/data", "chat:c-1"], ["/data/", "ember:c-2"], ["rel", "slack:a:b"], ["/d", "nocolon"]]) await same("chatWorkspace", () => chatWorkspace(d!, k!), d, k);
  // (each side's own last ts, set alike first: they only go up within a process)
  for (const now of [1_700_000_000_123, 1_700_000_000_123, 1_700_000_000_000, 5, 1_700_000_001_999.5]) {
    await same("nextTsAt", () => nextTsAt(now), now);
  }
  const chat = new InternalChat();
  for (const user of ["local", INTERNAL_BOT_USER, "a@b.c"]) await same("internalUserName", () => chat.userName(user), user);
  await same("internalPost", () => chat.post({ channel: "C1", threadTs: "1.2" }, "x", []), "C1", "1.2", 0);
});

test("chat: notices, Slack's split, a tool's status, thread addresses", { skip }, async () => {
  for (const t of ["hi", "hi\u2063", "hi\u2063  \n", "", "\u2063x"]) {
    await same("markNotice", () => markNotice(t), t);
    await same("isNotice", () => isNotice(t), t);
  }
  const long = ["a".repeat(30), "b".repeat(5), "", "c".repeat(12), "😀".repeat(9)].join("\n");
  for (const [text, limit] of [[long, 10], [long, 25], [long, 3], ["", 5], ["\n\n\nabc\n\n", 2], ["x".repeat(100), 7], ["p1\n\np2\n\np3", 6]] as [string, number][]) {
    await same("splitForSlack", () => splitForSlack(text, limit), text, limit);
  }
  for (const lang of ["zh", "en"] as const) {
    setStationLang(lang);
    await mbLang(lang);
    for (const tool of ["Read", "mcp__stillfail__chat_post", "mcp__x", "Bash", "WebSearch", "web_fetch", "Task", "slack_api", "feishu_api", "TodoWrite", "Weird", "MCP__A__LS"]) {
      await same("toolStatus", () => toolStatus(tool), tool);
    }
  }
  setStationLang("zh");
  await mbLang("zh");
  for (const a of ["C1/1700000000.000100", " C1/1.2 ", "oc_abc/om_x1", "oc_abc/omt_x1", "0123456789abcdef/0123456789abcdef", "d_0123456789abcdef01234567/d_0123456789abcdef01234567", "s_0123456789abcdef01234567/t_0123456789abcdef", "s_0123456789abcdef01234567/t_0123456789abcdeF", "x_0123456789abcdef01234567/x_0123456789abcdef01234567", "d_0123456789abcdef0123456/d_0123456789abcdef0123456", "c1/1.2", "C1/1", "C1/1.a", "nope", "CHAT/1794883315.950000", "oc_/om_x"]) {
    await same("parseThreadAddress", () => parseThreadAddress(a), a);
  }
  await same("threadAddress", () => threadAddress("C1", "2.3"), "C1", "2.3");
});

test("titles: a title as a chat shows it", { skip }, async () => {
  for (const t of ["  Fix   the\tbuild.  ", "修好构建。。", "a".repeat(40), "😀".repeat(31), "", "  \u3000 ", "one.two...", "x . . ", "trailing space before stop .", "\u00a0nbsp\u00a0"]) {
    await same("cleanTitle", () => cleanTitle(t), t);
  }
});

/// Markdown with links of every kind the reading knows, and what is no link.
const MARKDOWN = [
  "see [a](/tmp/a.txt) and ![img](</tmp/b c.png> \"t\") and [nested [x]](file:///tmp/n%20x)",
  "`[code](/no)` and ```\n[fenced](/no)\n``` then [after](/yes)",
  "[ref]: /tmp/ref.md\nuse [ref] and [text][ref] and [Ref][]\n",
  "  [r2]:   <file:///tmp/r 2>  \"title\"\n[r2]",
  "<file:///tmp/auto.txt> and <file:/x y> and [a](<bad\n>)",
  "\\[escaped](/no) \\![x](/y) [p](a\\)b) [q](x(y)z) [t](/u 'title') [w](/v (paren))",
  "[unclosed](/a",
  "~~~\n[in tilde](/no)\n~~~~\n[out](/o%41%zz)",
  "``` `x`\n[not a fence](/f)\n```",
  "``a ` b`` [k](/k) `unclosed [m](/m)",
  "[x]:\n[y]: <> rest\n[z]: <abc def\n[y] [z]",
  "[![inner](/i.png)](/outer)",
  "[a](\t/tab\n)",
  "[b](/b \"unclosed)",
  "[%E4%B8%AD](/%E4%B8%AD%E6%96%87.md) [bad](/%ff%fe) [bom](%EF%BB%BFx)",
  "",
];

test("local-links: what Markdown finds of links, and a destination decoded", { skip }, async () => {
  for (const t of MARKDOWN) await same("links", () => links(t), t);
  for (const t of ["/a%20b", "%zz%4", "%E4%B8%AD", "%ff", "%EF%BB%BFbom", "plain", "%2F%2f"]) await same("percentDecode", () => percentDecode(t), t);
});

// ── the hubs: one for the TypeScript, its twin for the program ───────────────────────────────────────────────────

/// What a case's hub is made of, made anew for each of the two: its store's, its own and its surfaces' methods, its
/// actors', its database's statements, and its state (`heldPosts`, `openings`, ... as the hub holds them).
export type World = {
  store?: Record<string, (...a: Json[]) => Json>;
  hub?: Record<string, (...a: Json[]) => Json>;
  /// Its properties that are no method (`places`, `presets`, `accounts`, `drivers`, `logins`, ...), as given.
  props?: Record<string, Json>;
  chats?: Record<string, Record<string, (...a: Json[]) => Json>>;
  actors?: Record<string, Record<string, (...a: Json[]) => Json>>;
  db?: { get?: (sql: string, ...a: Json[]) => Json; all?: (sql: string, ...a: Json[]) => Json; exec?: (sql: string) => void };
  deps?: Record<string, (...a: Json[]) => Json>;
};

/// A hub made of `w` for the TypeScript, with its record of what was asked of it.
export function tsHub(w: World): { hub: Json; log: Json[] } {
  const log: Json[] = [];
  const rec = (name: string, f: ((...a: Json[]) => Json) | undefined, args: Json[]) => {
    log.push([name, wire(args.map((a) => (typeof a === "function" ? "<fn>" : a !== null && typeof a === "object" && !Array.isArray(a) && Object.getPrototypeOf(a) !== Object.prototype && Object.getPrototypeOf(a) !== null ? "<effect>" : a)))]);
    if (f === undefined) throw new Error(`the case's hub has no ${name}`);
    return f(...args);
  };
  const methods = (prefix: string, table: Record<string, (...a: Json[]) => Json> | undefined) =>
    new Proxy({}, {
      get: (_t, prop) => (typeof prop !== "string" ? undefined : table?.[prop] === undefined ? undefined : (...a: Json[]) => rec(`${prefix}.${prop}`, table[prop], a)),
      has: (_t, prop) => typeof prop === "string" && table?.[prop] !== undefined,
    });
  const chats = new Map(Object.entries(w.chats ?? {}).map(([c, t]) => [c, methods(`chat.${c}`, t)]));
  const actors = new Map(Object.entries(w.actors ?? {}).map(([k, t]) => [k, methods(`actor.${k}`, t)]));
  const db = {
    prepare: (sql: string) => ({
      get: (...a: Json[]) => rec("db.get", w.db?.get, [sql, ...a]),
      all: (...a: Json[]) => rec("db.all", w.db?.all, [sql, ...a]),
    }),
    exec: (sql: string) => rec("db.exec", w.db?.exec, [sql]),
  };
  const store = methods("store", w.store);
  Object.defineProperty(store, "db", { value: db });
  const own = w.hub ?? {};
  const hub: Json = new Proxy({}, {
    get: (_t, prop) => {
      if (typeof prop !== "string") return undefined;
      if (prop === "store") return new Proxy(store, { get: (t, p) => (p === "db" ? db : (t as Json)[p]) });
      if (prop === "actors") return actors;
      if (prop === "chat") return (c: string) => { const s = chats.get(c); if (!s) throw new Error(`no connect ${c}`); return s; };
      if (prop === "chatOf") return (c: string) => chats.get(c);
      if (w.props && prop in w.props) return w.props[prop];
      const f = own[prop];
      return f === undefined ? undefined : (...a: Json[]) => rec(`hub.${prop}`, f, a);
    },
    set: (_t, prop, v) => { (w.props ??= {})[prop as string] = v; return true; },
  });
  return { hub, log };
}

/// Its twin for the program: the program's asks answered as `tsHub` answers the TypeScript's, recorded the same way.
export function mbHub(w: World): { answer: Answerer; log: Json[]; hub: Json } {
  const { hub, log } = tsHub(w);
  const handles = new Map<number, unknown>();
  const ids = new WeakMap<object, number>();
  let next = 0;
  const handle = (v: object, tag: "$fn" | "$obj") => {
    let id = ids.get(v);
    if (id === undefined) ids.set(v, (id = ++next));
    handles.set(id, v);
    return { [tag]: id };
  };
  const out = (v: unknown): Json => {
    if (v === undefined) return { $u: 1 };
    if (typeof v === "function") return handle(v, "$fn");
    if (v instanceof Map) return [...v.entries()];
    if (v !== null && typeof v === "object" && "$handle" in v) return handle((v as Json).$handle, "$obj");
    return v;
  };
  const answer: Answerer = async (name, args, callback) => {
    const given = args.map((a) => {
      if (a === null || typeof a !== "object" || Array.isArray(a)) return a;
      if (typeof a.$cb === "number") {
        const f = callback(a.$cb);
        return (...x: Json[]) => f(...x.map((y) => (typeof y === "function" ? handle(y, "$fn") : y === undefined ? { $u: 1 } : y)));
      }
      if (typeof a.$fn === "number" || typeof a.$obj === "number") return handles.get(a.$fn ?? a.$obj);
      if (a.$u === 1 && Object.keys(a).length === 1) return undefined;
      return a;
    });
    const [part, ...rest] = name.split(".");
    const method = rest.join(".");
    const props = w.props ?? {};
    switch (part) {
      case "dep": {
        const f = w.deps?.[method];
        if (f === undefined) throw new Error(`the case gives no dep.${method}`);
        return out(await f.call(hub, ...given));
      }
      case "fn": return out(await (given[0] as (...a: Json[]) => Json)(...given.slice(1)));
      case "store": return out(await hub.store[method](...given));
      case "hub": {
        switch (method) {
          case "has": return hub[given[0]] != null;
          case "isNull": return hub[given[0]] === null;
          case "storeHas": return typeof hub.store[given[0]] === "function";
          case "chatHasApi": return typeof hub.chat(given[0]).api === "function";
          case "chatHas": return typeof hub.chatOf(given[0])?.[given[1]] === "function";
          case "chatProp": return out(hub.chat(given[0])[given[1]]);
          case "sameChat": return hub.chat(given[0]) === hub.chat(given[1]);
          case "chatOfExists": return hub.chatOf(given[0]) !== undefined;
          case "hasActor": return hub.actors.get(given[0]) !== undefined;
          case "actorId": { const a = hub.actors.get(given[0]); return a === undefined ? null : handle(a, "$obj").$obj; }
          case "fetchedFor": return out(await hub.fetched(hub.chat(given[0]), ...given.slice(1)));
          default: return out(await hub[method](...given));
        }
      }
      case "chat": {
        const c = hub.chat(given[0]);
        return typeof c[method] === "function" ? out(await c[method](...given.slice(1))) : out(c[method] === undefined ? undefined : c[method]);
      }
      case "chatOf": {
        const c = hub.chatOf(given[0]);
        return typeof c?.[method] === "function" ? out(await c[method](...given.slice(1))) : { $u: 1 };
      }
      case "actor": {
        const a = hub.actors.get(given[0]);
        return a === undefined ? null : out(await a[method](...given.slice(1)));
      }
      case "db": return out(method === "exec" ? hub.store.db.exec(given[0]) : hub.store.db.prepare(given[0])[method](...given.slice(1)));
      case "log": log.push([`log.${method}`, wire(given)]); return null;
      case "wall": log.push([`wall.${method}`, wire(given)]); return null;
      case "state": return out(stateOp(props, method, given));
      case "drivers": return hub.drivers?.get(given[0]) !== undefined;
      case "driver": return handle(await hub.drivers.get(given[0]).open(given[1], given[2]), "$obj");
      case "agent": {
        const agent = given[0] as Json;
        if (method === "waitEvents") { await new Promise((r) => setImmediate(r)); return null; }
        return out(await agent[method](...given.slice(1)));
      }
      case "random": return method === "uuid" ? crypto.randomUUID() : [...crypto.getRandomValues(new Uint8Array(given[0]))].map((b) => b.toString(16).padStart(2, "0")).join("");
      case "net": {
        const r: Response = await (globalThis.fetch as Json)(given[0], given[1]);
        const text = await r.text();
        return { ok: r.ok, status: r.status, chunks: text === "" ? [] : [text] };
      }
      case "fs": return out(await fsOp(method, given));
      case "os": return homedir();
      case "path": return resolve(...(given as string[]));
      case "files": {
        if (method === "profileFilesRead") return null;
        try { return await readFile(given[0], "utf8"); } catch { return null; }
      }
      default: {
        const target = props[part];
        if (target === undefined) throw new Error(`no part ${part} (${name})`);
        const f = target[method];
        return out(typeof f === "function" ? await f.apply(target, given) : f);
      }
    }
  };
  return { answer, log, hub };
}

/// What the program asks of the hub's own state (its held posts, the openings of relayed chats, title requests).
function stateOp(props: Json, op: string, a: Json[]): unknown {
  const held: Map<string, Map<string, Json>> = (props.heldPosts ??= new Map());
  const openings: Map<number, Json> = (props.openings ??= new Map());
  const titles: Map<number, string> = (props.titleRequests ??= new Map());
  switch (op) {
    case "heldGet": return held.get(a[0])?.get(a[1]);
    case "heldEnsure": if (!held.has(a[0])) held.set(a[0], new Map()); return null;
    case "heldSize": return held.get(a[0])?.size ?? 0;
    case "heldDeleteOldest": { const m = held.get(a[0])!; m.delete(m.keys().next().value!); return null; }
    case "heldSet": held.get(a[0])!.set(a[1], a[2]); return null;
    case "heldDelete": held.get(a[0])?.delete(a[1]); return null;
    case "heldCountNext": return (props.heldCount = (props.heldCount ?? 0) + 1);
    case "openingGet": { const o = openings.get(a[0]); return o === undefined ? null : { ...o, $id: a[0] }; }
    case "openingClaim": { const o = openings.get(a[0]); if (o) o.claimed = a[2]; return null; }
    case "openingDelete": openings.delete(a[0]); return null;
    case "openingIs": return openings.has(a[0]);
    case "titleRequestSet": titles.set(a[0], a[1]); return null;
    case "titleRequestGet": return titles.get(a[0]) ?? null;
    case "titleRequestDelete": titles.delete(a[0]); return null;
    default: throw new Error(`no state op ${op}`);
  }
}

/// The files the program asks of (as the station's own file system answers).
async function fsOp(op: string, a: Json[]): Promise<unknown> {
  switch (op) {
    case "readText": return await readFile(a[0], "utf8");
    case "writeFile": await writeFile(a[0], a[1]); return null;
    case "rename": await rename(a[0], a[1]); return null;
    case "mkdir": await mkdir(a[0], { recursive: true }); return null;
    case "rm": await rm(a[0], { recursive: true, force: true }); return null;
    case "copyFile": await copyFile(a[0], a[1]); return null;
    case "symlink": await symlink(a[0], a[1], a[2]); return null;
    case "readdir": return await readdir(a[0]);
    case "readdirTypes": return (await readdir(a[0], { withFileTypes: true })).map((e) => ({ name: e.name, isFile: e.isFile(), isDirectory: e.isDirectory() }));
    case "readBase64": return (await readFile(a[0])).toString("base64");
    case "stat": {
      try {
        const s = await stat(a[0]);
        return { isFile: s.isFile(), isDirectory: s.isDirectory(), size: s.size, mtimeMs: s.mtimeMs };
      } catch (e) {
        throw Object.assign(new Error((e as Error).message), { code: (e as { code?: string }).code });
      }
    }
    case "readHead": {
      const fh = await open(a[0], "r");
      try {
        const buf = Buffer.alloc(a[1]);
        let got = 0;
        for (;;) {
          const { bytesRead } = await fh.read(buf, got, buf.length - got, got);
          if (bytesRead === 0) break;
          got += bytesRead;
          if (got === buf.length) break;
        }
        return { text: buf.subarray(0, Math.min(got, a[2])).toString("utf8"), got };
      } finally {
        await fh.close();
      }
    }
    default: throw new Error(`no fs op ${op}`);
  }
}

/// Both run against hubs made alike by `make`: the same answer, and the same asked of each hub.
/// What is made at random each time (a new chat's key, a uuid, a preset's id) said the same, so two runs compare.
export const unrandom = (v: Json): Json =>
  JSON.parse(JSON.stringify(v ?? null).replace(/chat:c-[0-9a-f]{10}/g, "chat:c-*").replace(/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/g, "<uuid>").replace(/p-[0-9a-f]{10}/g, "p-*"));

export async function sameWorld(name: string, make: (mb: boolean) => World, ts: (hub: Json) => unknown, ...args: Json[]) {
  const a = tsHub(make(false));
  const want = unrandom(await settledTs(() => withLog(a.log, () => ts(a.hub))));
  const b = mbHub(make(true));
  const got = unrandom(await mbWorld(b.answer, name, ...args));
  a.log.splice(0, a.log.length, ...unrandom(a.log));
  b.log.splice(0, b.log.length, ...unrandom(b.log));
  const label = `${name}(${JSON.stringify(args).slice(0, 200)})`;
  if ("error" in want) assert.deepEqual({ error: got.error, kind: got.kind }, want, label);
  else assert.deepEqual(got, want, label);
  assert.deepEqual(b.log, a.log, `${label}: what was asked of the hub`);
  return { a, b, want, got };
}

// ── titles: a chat named by its agent ─────────────────────────────────────────────────────────────────────────────

test("titles: naming a chat, and the chat still unnamed", { skip }, async () => {
  const thread = { id: 7, channel: "CHAT", threadTs: "1.000001", title: null, autoTitle: null, hiddenAt: null };
  const cases: [string, Json, Json][] = [
    ["new", { title: null, changes: 0, n: 0 }, {}],
    ["same", { title: "Build fix", changes: 0, n: 3 }, {}],
    ["often", { title: "Old", changes: 2, n: 3 }, {}],
    ["too little", { title: "Old", changes: 1, n: 3 }, { said: 2, watch: false }],
    ["watch", { title: "Old", changes: 1, n: 3 }, { said: 2, watch: true }],
    ["enough", { title: "Old", changes: 0, n: 3 }, { said: 5, watch: false }],
    ["people", { title: null, changes: 0, n: 0 }, { row: { ...thread, title: "Theirs" } }],
    ["gone", { title: null, changes: 0, n: 0 }, { row: null }],
  ];
  for (const [, auto, o] of cases) {
    for (const given of ["Build fix", "  Build   fix.  ", "", "New name"]) {
      const make = (): World => {
        let a = { ...auto };
        return {
          store: {
            getThread: () => ("row" in o ? o.row : thread),
            autoTitle: () => a,
            peopleSaidAfter: () => o.said ?? 0,
            hasActiveWatch: () => o.watch ?? false,
            setAutoTitle: (_t: number, title: string, changed: boolean) => { a = { title, changes: a.changes + (changed ? 1 : 0), n: 9 }; },
          },
        };
      };
      await sameWorld("nameChat", make, (hub) => nameChat(hub, thread as Json, given), thread, given);
    }
  }
  const sessions = (states: Json[]) => (): World => ({
    store: {
      latestThread: (k: string) => (k === "none" ? null : { thread: k === "hidden" ? { ...thread, hiddenAt: 5 } : k === "named" ? { ...thread, title: "x" } : k === "auto" ? { ...thread, autoTitle: "y" } : thread, connect: "ember" }),
      firstText: () => (states.length === 0 ? null : "hello"),
      threadSessions: () => [{ session: "me", connect: "ember" }, ...states.map((_s, i) => ({ session: `s${i}`, connect: "ember" }))],
      lastTurn: (k: string) => states[Number(k.slice(1))]?.last ?? null,
      hasPending: (k: string) => states[Number(k.slice(1))]?.pending ?? false,
    },
    hub: { processState: (k: string) => states[Number(k.slice(1))]?.process ?? "idle" },
  });
  for (const key of ["me", "none", "hidden", "named", "auto"]) await sameWorld("untitledChat", sessions([{}]), (hub) => untitledChat(hub, key), key);
  for (const states of [[], [{}], [{ process: "running" }], [{ pending: true }], [{ last: { endedAt: null } }], [{ last: { endedAt: 3, declared: "waiting" } }], [{ last: { endedAt: 3, declared: "all_done" } }, { process: "running" }]]) {
    await sameWorld("untitledChat", sessions(states), (hub) => untitledChat(hub, "me"), "me");
  }
});

// ── config: what the hub reads of config.json ─────────────────────────────────────────────────────────────────────

const PROFILE_DEPS = { profileRuntimes, modelKey, agyBaseModel, splitDevinFusion, devinFusionBase };

const RAW_CONFIGS: Json[] = [
  {},
  { profiles: [{ id: "p1", runtime: "codex", models: [" gpt-6 ", "gpt-6", "", "openai/gpt-6.1"], name: "  ", home: "homes/p1", model: "" }] },
  {
    profiles: [
      { id: "m", runtime: "claude", machine: true, name: "b@x.com（本机）", home: "/abs", backgroundOnMessage: false, enabled: false, withheld: ["w2", "", 3] },
      { id: "l", runtime: "codex", machine: true, name: "Local Codex", models: ["a"] },
      { id: "api", access: { kind: "anthropic-api", key: "k" }, models: [] },
      { id: "none", runtime: "dsh", access: { kind: "subscription" } },
    ],
    connects: [
      { id: "c1", kind: "feishu", mode: "single-session", requireMention: false, bind: { runtime: "codex", profiles: [" a ", "a", "", 7, "b"], model: "m", effort: "" }, workspace: "w9", slack: { botName: "", x: 1 } },
      { id: "c2", bind: { profile: "p" }, enabled: false },
      { id: "c3", kind: "group", mode: "multi-session", requireMention: false, bind: { runtime: "nope", profiles: ["solo"] }, slack: { botName: "Bot" } },
      { kind: "comma" },
    ],
    maxNudges: 5, askToName: false, automaticDecisions: { completion: { enabled: true, model: "jev-latest" } }, warmMinutes: 1.5, maxWarmClaude: 0,
    autoArchiveDays: -2, slackArchiveDays: 0.5, autoArchiveReviewed: true, archivedWorkspaceDays: 30, afreshWhenCold: true, afreshAbove: 0, agentHome: "/agent",
  },
  { afreshAbove: -1, warmMinutes: "x", agentHome: "rel/home", automaticDecisions: { completion: { model: 3 } } },
];

test("config: config.json as the hub reads it, a model's spelling and where a profile may run", { skip }, async () => {
  const found = { p1: ["gpt-6", "GPT-6.2", "", "openai/gpt-6.1", "gpt-7"], l: ["b"], api: ["claude-x"] };
  for (const raw of RAW_CONFIGS) {
    const make = (): World => ({ deps: PROFILE_DEPS });
    await sameWorld("hubConfig", make, () => hubConfig(raw, "/data", (id) => (found as Json)[id] ?? null), raw, "/data", found);
  }
  const profiles: Json[] = [
    { models: ["gpt-6", "openai/gpt-6.1"], runtimes: ["codex"] },
    { models: ["gemini-4-carbon", "claude-opus-5-5"], runtimes: ["agy"] },
    { models: ["fusion-claude-opus-5-5-sidekick-swe-2", "swe-2"], runtimes: ["devin"] },
    { models: ["claude-opus-5-5"], runtimes: ["devin"] },
  ];
  for (const p of profiles) {
    for (const m of ["gpt-6", "gpt-6.1", "OpenAI/GPT-6.1", "gemini-4-carbon-high", "claude-opus-5-5-medium", "fusion-claude-opus-5-5-high-sidekick-swe-2", "fusion-claude-opus-5-5-sidekick-swe-3", "nope"]) {
      await sameWorld("spelling", () => ({ deps: PROFILE_DEPS }), () => spelling(p, m), p, m);
    }
  }
  for (const [a, b] of [["gpt-6", "gpt-6"], ["openai/gpt-6.1", "gpt-6.1"], ["a", "b"]]) await sameWorld("sameModel", () => ({ deps: PROFILE_DEPS }), () => sameModel(a!, b!), a, b);
  const shareds: Json[] = [{}, { withheld: ["w2"] }, { share: { borrowed: true, workspaces: ["w1"] } }, { share: { borrowed: true, workspaces: "w1" } }, { share: { borrowed: false, workspaces: ["w3"] } }];
  for (const p of shareds) for (const [ws, home] of [[null, null], [null, "w1"], ["w2", "w1"], ["w1", "w1"], ["w3", null], ["w2", null]]) {
    await same("allowedIn", () => allowedIn(p, ws ?? null, home ?? null), p, ws, home);
  }
  const config = { profiles: [{ id: "a", runtimes: ["codex"], enabled: true }, { id: "b", runtimes: ["claude", "codex"], enabled: false }, { id: "c", runtimes: ["codex"], withheld: ["w2"] }] };
  for (const connect of [{ bind: { runtime: "codex" } }, { bind: { runtime: "codex" }, workspace: "w2" }, { bind: { runtime: "claude" } }]) {
    await same("profilesFor", () => profilesFor(config as Json, connect as Json, "w1"), config, connect, "w1");
  }
  for (const r of ["claude", "codex", "dsh", "grok", "cursor", "hermes", "agy", "pi", "devin"]) await same("runtimeTitle", () => runtimeTitle(r as Json), r);
});

// ── cc: a message copied to the chat's Slack and Feishu threads ───────────────────────────────────────────────────

test("cc: who said it, and a copy to each thread ticked (or what did not go, said in the chat)", { skip }, async () => {
  for (const lang of ["zh", "en"] as const) {
    setStationLang(lang);
    await mbLang(lang);
    for (const [who, said] of [["Ann", "hello"], ["a@b.c", ""], ["x", "line\\nline"]]) await same("ccText", () => ccText(who!, said!), who, said);
  }
  setStationLang("zh");
  await mbLang("zh");
  const thread = { id: 1, channel: "CHAT", threadTs: "1.1" };
  const slack = { id: 2, channel: "C1", threadTs: "9.1", surface: "slack:T1" };
  const feishu = { id: 3, channel: "oc_x", threadTs: "om_y", surface: "feishu:z" };
  const group = { id: 4, channel: "abc", threadTs: "abc", surface: "group:q" };
  const variants: Json[] = [
    { picked: [[slack, "s"], [feishu, "f"]], to: [2, 3] },
    { picked: [[slack, "s"], [feishu, "f"], [group, "g"]], to: [3, 9], userOf: { f: "ou_1" } },
    { picked: [[slack, "s"]], to: [2], userOf: { s: "U9" }, mention: true },
    { picked: [[slack, "s"], [group, "g"]], to: [2, 4], fail: ["s", "g"] },
    { picked: [[group, "g"]], to: [4], fail: ["g", "ember"] },
    { unavailable: true, to: [2] },
    { unavailable: true, prepare: true, picked: [[slack, "s"]], to: [2] },
    { broken: true, to: [2] },
    { picked: [[slack, "s"]], to: [2], noChat: true },
  ];
  for (const v of variants) {
    const make = (): World => {
      let tries = 0;
      const surface = (c: string) => ({
        post: async (_where: Json, text: string) => { if (v.fail?.includes(c)) throw new Error(`${c} refused: ${text.slice(0, 5)}`); return `ts-${c}`; },
        userOf: async (email: string) => v.userOf?.[c] ?? (email === "boom" ? Promise.reject(new Error("x")) : null),
        ...(v.mention ? { mention: (u: string) => `<@${u}|m>` } : {}),
      });
      return {
        store: {
          ccThreads: () => {
            tries++;
            if (v.broken) throw new Error("the store is broken");
            if (v.unavailable && (tries === 1 || !v.prepare)) throw Object.assign(new CcSessionsUnavailable(["k1", "k2"]), {});
            return (v.picked ?? []).map(([t, c]: [Json, string]) => ({ thread: t, connect: c }));
          },
          getThread: () => (v.noChat ? null : thread),
          threadSessions: () => [{ session: "k", connect: "ember" }],
          insertMessage: () => [7],
        },
        hub: v.prepare ? { prepareCcSessions: async () => {} } : {},
        chats: { s: surface("s"), f: surface("f"), g: surface("g"), ember: surface("ember") },
      };
    };
    const run = async (hub: Json) => cc(hub, 1, "Ann", "ann@x.com", "hi there", [], v.to);
    // (the threads are copied to at once: their order is no part of it)
    const a = tsHub(make());
    const want = await settledTs(() => withLog(a.log, () => run(a.hub)));
    const b = mbHub(make());
    const got = await mbWorld(b.answer, "cc", 1, "Ann", "ann@x.com", "hi there", [], v.to);
    assert.deepEqual(got, want, JSON.stringify(v));
    assert.deepEqual(sorted(b.log), sorted(a.log), `${JSON.stringify(v)}: what was asked of the hub`);
  }
});

const sorted = (log: Json[]) => [...log].map((x) => JSON.stringify(x)).sort();

/// The station's log as the TypeScript writes it, into the hub's record of the case.
async function withLog<T>(into: Json[], f: () => Promise<T> | T): Promise<T> {
  const warn = mock.method(stationLog, "warn", (part: string, words: string, fields: Json) => { into.push(["log.warn", wire([part, words, fields])]); });
  const info = mock.method(stationLog, "info", (part: string, words: string, fields: Json) => { into.push(["log.info", wire([part, words, fields])]); });
  const sleep = mock.method(wall, "sleep", async (ms: number) => { into.push(["wall.sleep", [ms]]); });
  try {
    return await f();
  } finally {
    warn.mock.restore();
    info.mock.restore();
    sleep.mock.restore();
  }
}

// ── card-place: where a long-lived operation's card stands ────────────────────────────────────────────────────────

class Occupied extends Error {}

test("card-place: a card's place, and a card posted only while it is still wanted", { skip }, async () => {
  const st = { thread: { id: 5, channel: "CHAT", threadTs: "1.1" }, connect: "ember" };
  for (const [thread, ts] of [[null, "1"], [5, null], [5, "1.5"], [5, "1.6"]] as [number | null, string | null][]) {
    for (const v of [{ ready: true, header: null }, { ready: true, header: [{ ts: "1.5" }, 1] }, { ready: false }, { old: true, header: [{ ts: "1.6" }] }, { gone: true }] as Json[]) {
      const make = (): World => ({
        store: {
          sessionThreadById: () => (v.gone ? null : st),
          ...(v.old ? { pendingCardHeader: () => v.header } : { pendingCardHeaderIfReady: () => (v.ready ? v.header : undefined) }),
        },
      });
      await sameWorld("cardPlace", make, (hub) => cardPlace(hub.store, "k", thread, ts), "k", thread, ts);
    }
  }
  const variants: Json[] = [
    { occupied: false },
    { occupied: true },
    { occupied: true, header: [{ ts: "x" }] },
    { occupied: true, gone: true },
    { occupied: true, needed: [true, false] },
    { occupied: true, needed: [false] },
    { occupied: false, busy: 3 },
    { occupied: true, unready: 1, prepare: true },
    { occupied: true, unready: 1 },
    { occupied: true, card: null },
    { occupied: true, identity: true },
    { occupied: true, otherWhileInserting: true },
  ];
  for (const v of variants) {
    const card = "card" in v ? v.card : { type: "options", options: [{ label: "a" }] };
    const make = (mb: boolean): World => {
      let busy = v.busy ?? 0;
      let unready = v.unready ?? 0;
      let inserts = 0;
      let header: Json = v.header ?? null;
      return {
        store: {
          sessionThreadById: () => (v.gone ? null : st),
          pendingCardHeaderIfReady: () => (unready > 0 ? (unready--, undefined) : header),
          insertMessage: mb
            ? async (_m: Json, before?: () => Promise<unknown>) => { inserts++; if (busy > 0) { busy--; throw new MessageWriteBusy(); } if (v.otherWhileInserting) header = [{ ts: "y" }]; if (before) await before(); return [40 + inserts]; }
            : (_m: Json, before?: () => void) => { inserts++; if (busy > 0) { busy--; throw new MessageWriteBusy(); } if (v.otherWhileInserting) header = [{ ts: "y" }]; before?.(); return [40 + inserts]; },
        },
        hub: { shared: () => {}, ...(v.prepare ? { prepareCardPosts: async () => {} } : {}) },
        chats: { ember: { post: async () => "1.900" } },
        actors: v.identity ? { k: { messageIdentity: () => ({ model: "m", effort: null, runtime: "codex" }) } } : {},
      };
    };
    const occupied = v.occupied ? (why: string) => new Occupied(why) : null;
    const neededOf = () => { let i = 0; return v.needed ? () => v.needed[i++] ?? true : undefined; };
    await sameWorld("postCard", make, (hub) => postCard(hub, "k", st as Json, "ask", card, occupied, neededOf()), "k", st, "ask", card, v.occupied ? "Occupied" : null, v.needed ?? null);
    await sameWorld("recordPostedCard", make, (hub) => recordPostedCard(hub, "k", st as Json, "ask", card, "1.7", occupied, neededOf(), hub.actors.get("k")?.messageIdentity() ?? undefined), "k", st, "ask", card, "1.7", v.occupied ? "Occupied" : null, v.needed ?? null);
  }
  assert.equal(CARD_OCCUPIED.length > 0, true);
});

// ── messages: session_send, a letter between chats ────────────────────────────────────────────────────────────────

/// The parts of the station the chats' code stands on, as they are (they are other parts' own; given the program as
/// `dep.*`, each run against the program's hub).
const STATION_DEPS: Record<string, (...a: Json[]) => Json> = {
  ...PROFILE_DEPS,
  linkedStation, linkedSession, fromBefore,
  sessionThreadOf(this: Json, key: string) { return sessionThreadOf(this, key); },
  named(this: Json, to: string, ws: string | null, write: boolean) { return namedChat(this, to, ws, write); },
  scopeOf(this: Json, key: string) { return scopeOf(this, key); },
  reachable(this: Json, key: string, ws: string | null, write: boolean) { return reachable(this, key, ws, write); },
  peersOf(this: Json, key: string) { return peersOf(this, key); },
  given: givenTitle, titleOf,
  keep: async (files: Json[]) => files,
  sendable(this: Json, key: string, paths: string[]) { return sendable(this, key, paths); },
  sendAlong: (call: Json, station: string, key: string, to: string, files: Json[]) => sendAlong(call, station, key, to, files),
  claim(this: Json, peer: string, from: string, to: string, files: Json) { return claim(this, peer, from, to, files); },
  slackWithFiles, placeFigures, firstLine, cardSaid, isSlackMethod, isSlackWrite, stateArg, needArg, cardArg, iso,
  threadsToldOf(this: Json, key: string) { return threadsToldOf(this, key); },
  formatHistory: (messages: Json[], surface: string, address: string, key: string, names: Json[], cards: Json[]) => formatHistory(messages, surface, address, key, new Map(names), new Map(cards)),
  fileURLToPath: (d: string) => { try { return fileURLToPath(new URL(d)); } catch { return null; } },
  shownFactsSoon,
  newSession(this: Json, options: Json) { return newSession(this, options); },
  candidates: (profiles: Json[], runtime: Json, leads?: boolean) => modelCandidates(profiles, runtime, leads),
  choose: (cands: Json[], used: Json[], leads: Json[]) => choose(cands, used, leads),
  askWhich: (ask: Json[], where: string) => askWhich(ask, where),
  USED_WITHIN_MS: () => USED_WITHIN_MS,
  contextAsked: (v: Json, lang: Json) => contextAsked(v, lang),
  usable: (h: Json) => usable(h),
  policyFrom: (saved: Json) => policyFrom(saved),
  policyQuestion: (p: Json) => policyQuestion(p),
  recommends: (r: Json, p: Json, t: number) => recommends(r, p, t),
  archiveMass: (r: Json, p: Json) => archiveMass(r, p),
  accessKind: (p: Json) => accessKind(p),
  profileEnv: (p: Json, r: Json) => profileEnv(p, r),
  apiSource: (p: Json) => apiSource(profileVia(p)) ?? null,
  opencodeGo: () => { const source = findSource("opencode-go"); const at = source && endpoints(source, undefined, undefined); return source && at ? [source, at] : null; },
  parseUrl: (u: Json) => { try { const x = new URL(u); return { href: x.href, protocol: x.protocol, hostname: x.hostname, username: x.username, password: x.password, search: x.search, hash: x.hash }; } catch { return null; } },
  dshRoute: (p: Json) => dshRoute(p),
  expandRoute: (env: Json, route: string) => expandRoute(env, route),
  localeCompare: (a: string, b: string) => a.localeCompare(b),
  prepareLocalLinks: (text: string, paths: string[], workspace: string) => loadMesh().prepareLocalLinks(text, paths, workspace),
  makeReadStore(this: Json, dataDir: string) { return { $handle: makeReadStore(this.store.db, dataDir) }; },
  readStateQuestion: (store: Json, key: string, threads: number[], ts: string) => readStateQuestion(store, key, threads, ts),
  readStatePendingCard: (store: Json, threads: number[]) => readStatePendingCard(store, threads),
};

/// A small world of chats: sessions with their threads, the letters and messages kept, the deliveries made.
function chatsWorld(o: Json = {}) {
  return (mb: boolean): World => {
    const sessions: Json = {
      me: { key: "me", title: o.myTitle ?? null, workspace: o.workspace ?? "/w/me", createdBy: "ann@x.com", runtime: "codex", ws: o.ws ?? null, connect: "ember" },
      other: { key: "other", title: null, workspace: o.workspace ?? "/w/other", createdBy: "bob@x.com", runtime: "claude", ws: o.otherWs ?? null, connect: "ember" },
      third: { key: "third", title: "Third's own", workspace: "/w/third", runtime: "claude", ws: null, connect: "slack1" },
    };
    const threads: Json = {
      1: { id: 1, surface: "ember", channel: "CHAT", threadTs: "1.000001", title: "Mine", autoTitle: null, home: "me", createdBy: "ann@x.com", hiddenAt: null },
      2: { id: 2, surface: "ember", channel: "CHAT", threadTs: "2.000002", title: null, autoTitle: "Theirs auto", home: "other", createdBy: "bob@x.com", hiddenAt: null },
      3: { id: 3, surface: "slack:T1", channel: "C9", threadTs: "3.000003", title: null, autoTitle: null, home: null, createdBy: null, hiddenAt: null },
    };
    const members: Json = { 1: [{ session: "me", connect: "ember" }], 2: [{ session: "other", connect: "ember" }, ...(o.both ? [{ session: "me", connect: "ember" }] : [])], 3: [{ session: "third", connect: "slack1" }] };
    const homeOf: Json = { me: 1, other: 2, third: null };
    let n = 100;
    let ts = 0;
    void mb;
    return {
      store: {
        getSession: (k: string) => (o.gone === k ? null : sessions[k] ?? null),
        sessionHomeThread: (k: string) => (homeOf[k] ? { thread: threads[homeOf[k]], connect: "ember" } : null),
        latestThread: (k: string) => (k === "third" ? { thread: threads[3], connect: "slack1" } : homeOf[k] ? { thread: threads[homeOf[k]], connect: "ember" } : null),
        latestThreadIfReady: (k: string) => (o.notReady ? undefined : k === "third" ? { thread: threads[3], connect: "slack1" } : null),
        firstText: (t: number) => (t === 3 ? "the first words in slack" : "hello"),
        threadSessions: (t: number) => members[t] ?? [],
        threadsAt: (c: string, t: string) => Object.values(threads).filter((x: Json) => x.channel === c && x.threadTs === t),
        handedTo: (k: string) => (o.handed?.[k] ?? null),
        manuallyArchived: (t: number) => o.archived === t,
        openerOf: (k: string) => o.opener?.[k] ?? null,
        insertLetter: () => ++n,
        insertMessage: () => [++n],
        chatShare: () => null,
        sessionThreads: () => [],
        usedChatShare: () => {},
      },
      hub: {
        link: (k: string) => (o.noLinks ? undefined : `https://app.still.fail/o/W1/S1/${k}`),
        nextTs: () => `9.${String(++ts).padStart(6, "0")}`,
        config: () => ({ dataDir: "/data" }),
        deliver: () => {}, deliverLetter: () => {},
        peers: () => (o.peers === undefined ? null : async (station: string, request: Json) => o.peers(station, request)),
        workspaces: () => o.workspaces ?? [],
        wsOf: () => o.ws ?? null,
        inWorkspace: (k: string, ws: string) => (sessions[k]?.ws ?? null) === ws,
      },
      chats: {
        ember: { post: async () => `8.${String(++ts).padStart(6, "0")}` },
        slack1: { post: async (_w: Json, text: string, files: Json[]) => { if (o.missingScope && files.length > 0) throw new Error("missing_scope"); return `7.${text.length}`; } },
      },
      actors: o.identity ? { me: { messageIdentity: () => ({ model: "gpt-6", effort: "high", runtime: "codex" }) } } : {},
      deps: STATION_DEPS,
    };
  };
}

test("messages: who a letter is from, and session_send to a chat here or on another station", { skip }, async () => {
  for (const [surface, title, link] of [["ember", "A [b] c", "https://x/y"], ["slack:T", "a & <b> | c", "https://x/y"], ["ember", "t", null], ["feishu:z", "t", null]] as [string, string, string | null][]) {
    await same("chatNamed", () => chatNamed(surface, title, link), surface, title, link);
  }
  for (const lang of ["zh", "en"] as const) {
    setStationLang(lang);
    await mbLang(lang);
    for (const key of ["me", "other", "third", "nobody"]) {
      await sameWorld("sender", chatsWorld(), (hub) => sender(hub, key), key);
      await sameWorld("senderTitleIfReady", chatsWorld({ notReady: key === "third" }), (hub) => senderTitleIfReady(hub, key), key);
    }
    const sends: [Json, Json][] = [
      [{}, { to: "", text: "x" }],
      [{}, { to: "other", text: "  " }],
      [{}, { to: "other", text: "x".repeat(200_001) }],
      [{}, { to: "other", text: "hello other" }],
      [{ identity: true }, { to: "CHAT/2.000002", text: "by address" }],
      [{}, { to: "https://app.still.fail/o/W1/S1/other", text: "by link" }],
      [{}, { to: "me", text: "myself" }],
      [{ both: true }, { to: "other", text: "both in it" }],
      [{ both: true }, { to: "CHAT/2.000002", text: "both in it" }],
      [{ archived: 2 }, { to: "other", text: "archived" }],
      [{}, { to: "nobody", text: "nobody" }],
      [{ gone: "me" }, { to: "other", text: "from no one" }],
      [{ noLinks: true }, { to: "third", text: "no links" }],
      [{ peers: async (_s: string, r: Json) => ({ thread: "CHAT/5.5", title: "Far chat", link: "https://app.still.fail/o/W1/S2/far", got: r.method }) }, { to: "https://app.still.fail/o/W1/S2/far", text: "far away" }],
      [{ peers: async () => ({}) }, { to: "https://app.still.fail/o/W1/S2/far", text: "far, says little" }],
      [{ peers: async () => { throw new Refused("remote tasks are not enabled"); } }, { to: "https://app.still.fail/o/W1/S2/far", text: "old station" }],
      [{ peers: async () => { throw new Refused("no such chat"); } }, { to: "https://app.still.fail/o/W1/S2/far", text: "refused" }],
      [{ peers: async () => { throw new Error("timed out"); } }, { to: "https://app.still.fail/o/W1/S2/far", text: "timeout" }],
      [{}, { to: "https://app.still.fail/o/W1/S2/far", text: "no peers" }],
      [{ handed: { other: { station: "S3" } }, peers: async (s: string) => ({ thread: `at ${s}` }) }, { to: "other", text: "handed" }],
      [{ ws: "W1", workspaces: ["W1"], peers: async (_s: string, r: Json) => ({ title: r.workspace }) }, { to: "https://app.still.fail/o/W1/S2/far", text: "scoped" }],
    ];
    for (const [o, args] of sends) await sameWorld("sessionSend", chatsWorld(o), (hub) => sessionSend(hub, "me", args), "me", args);
  }
  setStationLang("zh");
  await mbLang("zh");
  const peers: [Json, Json, string | null][] = [
    [{}, { to: "other", session: "far1", text: "from far", from: { title: "Far", link: "https://x/far" } }, null],
    [{}, { to: "other", session: "far1", text: " " }, null],
    [{}, { to: "nobody", session: "far1", text: "x" }, null],
    [{ archived: 2 }, { to: "other", session: "far1", text: "x" }, null],
    [{ opener: { other: { parentStation: "S2", parent: "far1", led: true } } }, { to: "other", session: "far1", text: "opening", opened: true, from: { title: " " } }, null],
    [{ opener: { other: { parentStation: "S2", parent: "far1", led: false } } }, { to: "other", session: "far1", text: "opening", opened: true }, null],
    [{ opener: { other: { parentStation: "S9", parent: "far1", led: null } } }, { to: "other", session: "far1", text: "not its opener", opened: true }, null],
    [{ handed: { other: { station: "S3" } }, peers: async (s: string, r: Json) => ({ thread: `at ${s}`, ws: r.workspace ?? null }) }, { to: "other", session: "far1", text: "on" }, "W1"],
    [{ handed: { other: { station: "S2" } }, peers: async () => ({}) }, { to: "other", session: "far1", text: "back to sender" }, null],
    [{ otherWs: "W2" }, { to: "other", session: "far1", text: "other workspace" }, "W1"],
  ];
  for (const [o, request, ws] of peers) await sameWorld("fromPeer", chatsWorld(o), (hub) => fromPeer(hub, "S2", request, ws), "S2", request, ws);
  for (const opened of [false, true]) {
    for (const o of [{}, { opener: { other: { led: false } } }, { missingScope: true }, { missingScope: true, noLinks: true }]) {
      const thread = (o as Json).missingScope ? { thread: { id: 3, surface: "slack:T1", channel: "C9", threadTs: "3.000003" }, connect: "slack1" } : { thread: { id: 2, surface: "ember", channel: "CHAT", threadTs: "2.000002" }, connect: "ember" };
      const files = (o as Json).missingScope ? [{ name: "fig.html", path: "/w/f.html", size: 3 }] : [];
      await sameWorld("postFrom", chatsWorld(o), (hub) => postFrom(hub, thread as Json, "me", "Mine", "https://x/me", "text", ["other", "me"], files as Json, opened), thread, "me", "Mine", "https://x/me", "text", ["other", "me"], files, opened);
    }
  }
});

// ── conversations: chat_post, chat_state, chat_history, chat_leave, slack_api ─────────────────────────────────────

const HERE = { id: 1, surface: "ember", channel: "CHAT", threadTs: "1.000001", title: null, autoTitle: null, hiddenAt: null };
const SLACK = { id: 3, surface: "slack:T1", channel: "C9", threadTs: "3.000003", title: null, autoTitle: null, hiddenAt: null };

/// A session `me` in a still.fail chat (CHAT/1.000001) and a Slack thread (C9/3.000003), with its actor and what its
/// store keeps; `o` changes what each says.
function postWorld(o: Json = {}) {
  return (mb: boolean): World => {
    let n = 50;
    let pending: Json = o.pendingCard ?? null;
    const listeners: ((c: Json) => void)[] = [];
    let changedOnce = false;
    let busy = o.busy ?? 0;
    const messages: Json[] = o.messages ?? [];
    const threadOf = (ch: string, ts: string) => (ch === "CHAT" && ts === "1.000001" ? { thread: HERE, connect: "ember" } : ch === "C9" && ts === "3.000003" ? { thread: SLACK, connect: "slack1" } : null);
    const actor = {
      messageIdentity: () => (o.identity ? { model: "gpt-6", effort: "high", runtime: "codex" } : null),
      currentTurnId: () => o.turn ?? "t1",
      postedForTurn: async () => {}, postedNow: async () => {}, goesOn: async () => {}, need: async () => {}, about: async () => {}, declare: async () => {}, waitFor: async () => {},
      unreadIn: () => (o.unread ?? []).map((ts: string) => ({ message: { ts } })),
      stateForTurn: mb
        ? async (_t: Json, _k: Json, _w: Json, _a: Json, _wa: Json, write: (save: (a: Json) => void) => Promise<unknown>) => { if (o.writeState) await write(() => {}); return o.stateRecorded ?? true; }
        : async (_t: Json, _k: Json, _w: Json, _a: Json, _wa: Json, write: (save: (a: Json) => void) => void) => { if (o.writeState) write(() => {}); return o.stateRecorded ?? true; },
    };
    const surface = (c: string) => ({
      post: async (_where: Json, text: string, files: Json[]) => { if (o.missingScope && c === "slack1" && files.length > 0) throw new Error("missing_scope"); if (o.postFails) throw new Error("post refused"); return `5.${String(++n).padStart(6, "0")}`; },
      ...(c === "slack1" ? { cards: o.cards ?? true, loginCards: o.loginCards ?? false, edit: async () => o.editOk ?? true, api: async (method: string, params: Json) => (o.apiFails ? Promise.reject(new Error("invalid_auth")) : { ok: true, method, ts: method === "chat.postMessage" ? "6.000001" : undefined, echo: params, big: o.big ? "x".repeat(70_000) : undefined }), answerFiles: () => [], userName: async (u: string) => (u === "U1" ? "Una" : null) } : {}),
    });
    return {
      store: {
        getSession: (k: string) => (k === "me" ? { key: "me", workspace: o.workspace ?? "/w/me", runtime: "codex", connect: o.connect ?? "ember", ws: null } : null),
        sessionThread: (_k: string, ch: string, ts: string) => threadOf(ch, ts),
        sessionThreadById: (_k: string, id: number) => (o.goneWhileChecking ? null : id === 1 ? { thread: HERE, connect: "ember" } : id === 3 ? { thread: SLACK, connect: "slack1" } : null),
        recentSessionThreads: () => ({ threads: [{ thread: HERE, connect: "ember" }, { thread: SLACK, connect: "slack1" }], more: o.more ?? false }),
        manuallyArchived: (id: number) => o.archived === id,
        cardAt: () => o.cardAt ?? null,
        withdrawCard: () => o.withdraws ?? true,
        insertMessage: () => [++n],
        pendingBefore: () => o.pending ?? [],
        pendingCard: (id: number) => (pending && pending[0].thread === id ? pending : null),
        messageAt: (thread: number, ts: string) => messages.find((m) => m.thread === thread && m.ts === ts) ?? null,
        messageNumberAt: (thread: number, ts: string) => messages.find((m) => m.thread === thread && m.ts === ts)?.n ?? null,
        entriesBetween: (thread: number, a: number) => messages.filter((m) => m.thread === thread && m.n === a).map((m) => ({ card: m.card ?? null, options: null })),
        askingMessage: (thread: number, a: number) => (o.asking && messages.some((m) => m.thread === thread && m.n === a) ? { n: a } : null),
        messageAtIfReady: (thread: number, ts: string) => messages.find((m) => m.thread === thread && m.ts === ts) ?? null,
        editMessage: () => {}, editMessageIfReady: () => true,
        hasSessionActiveWatch: () => o.watching ?? false,
        leaveThread: () => {},
        messagesBefore: () => messages,
        messagePageEntries: () => messages.map((m) => ({ kind: "message", n: m.n, card: m.card ?? null, options: m.options ?? null })),
        cardChoices: () => new Map(o.choices ?? []),
        getThread: () => HERE, autoTitle: () => ({ title: null, changes: 0, n: 0 }), setAutoTitle: () => {}, peopleSaidAfter: () => 0, hasActiveWatch: () => false,
        subscribe: (f: (c: Json) => void) => { listeners.push(f); return () => {}; },
        threadOfMessage: () => (o.inThread ? { threadTs: "4.000004" } : null),
        threadAt: (_s: Json, _c: string, ts: string) => (ts === "4.000004" ? { id: 4 } : null),
        threadSessions: (id: number) => (id === 4 ? [{ session: "someone", connect: o.sameBot ? "slack1" : "slack2" }] : []),
        openThread: () => ({ id: 8 }),
        joinThread: () => o.joined ?? true,
      },
      hub: {
        link: () => (o.noLink ? undefined : "https://app.still.fail/o/W1/S1/me"),
        config: () => ({ dataDir: "/data", profiles: o.profiles ?? [], connects: o.connects ?? [] }),
        shared: () => {},
        fork: () => {},
        workspaces: () => ["W1"],
        wsOf: () => "W1",
        surface: (c: string) => `slack:${c}`,
        fetched: async () => ({ attachments: [{ name: "a.png", path: "/w/a.png", size: 3, extra: 1 }], text: "one not saved" }),
        ...(o.stateQuestion ? { stateQuestion: async () => { if (o.changeDuringRead && !changedOnce) { changedOnce = true; for (const l of listeners) l({ type: "thread", id: 1 }); } return o.stateQuestion; } } : {}),
        ...(o.statePendingCard !== undefined ? { statePendingCard: async () => o.statePendingCard } : {}),
        ...(o.historyMessages ? { historyMessages: async () => messages } : {}),
        ...(o.legacy ? { prepareLegacyEdits: async () => {} } : {}),
      },
      props: {
        heldPosts: o.held ?? new Map(), heldCount: o.heldCount ?? 0, openings: o.openings ? new Map(o.openings.map((x: Json) => [x[0], { ...x[1] }])) : new Map(),
        places: { mac: o.mac ?? false, protects: (path: string) => path.startsWith("/Users/x/Documents"), file: async (path: string, into: string) => { if (o.placeGone && path.endsWith(":12")) throw new PlaceRefused("gone", "not there"); return path.startsWith("/Users/x/Documents") ? `${into}/copied/${path.split("/").pop()}` : path; } },
        stoppingSignal: new AbortController().signal,
        ...(o.logins ? { logins: { page: (id: string) => (id === "L1" ? "https://login.example/L1" : undefined) } } : {}),
      },
      chats: { ember: surface("ember"), slack1: surface("slack1") },
      actors: o.noActor ? {} : { me: actor },
      db: {
        get: (sql: string, ...a: Json[]) => (sql.startsWith("PRAGMA main.data_version") ? { data_version: o.version ?? 1 } : sql.startsWith("PRAGMA busy_timeout") ? { timeout: 5000 } : sql.includes("lower(author)") ? (o.wrote?.includes(a[1]) ? { 1: 1 } : undefined) : undefined),
        all: (sql: string) => (sql.includes("thread_people") ? (o.people ?? []).map((author: string) => ({ author })) : []),
        exec: (sql: string) => { if (busy > 0 && sql === "BEGIN IMMEDIATE") { busy--; throw Object.assign(new Error("database is locked"), { errcode: 5 }); } },
      },
      deps: STATION_DEPS,
    };
  };
}

/// chat_post as its tool calls it: a held post sent by send put back first.
function postHeld(hub: Json, args: Json) {
  const held = unheld(hub, "me", args);
  return chatPost(hub, "me", held.args, held);
}

const PEOPLE_CARD = { type: "options", options: [{ label: "Yes" }, { label: "No" }], assignee: "ann@x.com" };

test("conversations: chat_post, every way it goes", { skip }, async () => {
  const cases: [Json, Json][] = [
    [{}, { to: "CHAT/1.000001", text: "hello" }],
    [{}, { to: "CHAT/1.000001", text: "  " }],
    [{}, { to: "nope", text: "x" }],
    [{}, { to: 5, text: "x" }],
    [{}, { to: "CHAT/9.000009", text: "x" }],
    [{ archived: 1 }, { to: "CHAT/1.000001", text: "x" }],
    [{}, { to: "CHAT/1.000001", text: "done", kind: "all_done", done: "已合进 main 82f108a5，测试版 1389 已发" }],
    [{}, { to: "CHAT/1.000001", text: "done", kind: "all_done" }],
    [{}, { to: "CHAT/1.000001", text: "x", about: "1.1" }],
    [{}, { to: "CHAT/1.000001", text: "pick", kind: "need_human", need: "pick one", card: PEOPLE_CARD }],
    [{ statePendingCard: [1, 51, "5.000051"] }, { to: "CHAT/1.000001", text: "pick", kind: "need_human", need: "pick one", card: PEOPLE_CARD }],
    [{ statePendingCard: null }, { to: "CHAT/1.000001", text: "q?", kind: "need_human", need: "an answer" }],
    [{ statePendingCard: null, writeState: true }, { to: "CHAT/1.000001", text: "q?", kind: "need_human", need: "an answer" }],
    [{ statePendingCard: null, writeState: true, busy: 2 }, { to: "CHAT/1.000001", text: "q?", kind: "need_human", need: "an answer" }],
    [{ statePendingCard: null, stateRecorded: false }, { to: "CHAT/1.000001", text: "q", kind: "need_human", need: "x", card: PEOPLE_CARD }],
    [{ pendingCard: [{ thread: 1, n: 7, ts: "1.7", createdAt: 3 }] }, { to: "CHAT/1.000001", text: "still?", kind: "need_human", need: "the answer" }],
    [{}, { to: "CHAT/1.000001", text: "x", kind: "need_decision" }],
    [{}, { to: "CHAT/1.000001", text: "**Pick** one\nmore", kind: "need_decision", options: ["a", "b"] }],
    [{ messages: [{ thread: 1, n: 9, ts: "1.9", authorKind: "agent", author: "me", text: "my question", card: { type: "text" } }], pendingCard: [{ thread: 1, n: 9, ts: "1.9" }] }, { to: "CHAT/1.000001", text: "again", kind: "need_human", need: "x", about: "1.9" }],
    [{ messages: [{ thread: 1, n: 9, ts: "1.9", authorKind: "agent", author: "me", text: "my question", card: { type: "text" } }] }, { to: "CHAT/1.000001", text: "again", kind: "need_human", need: "x", about: "1.9" }],
    [{ messages: [{ thread: 1, n: 9, ts: "1.9", authorKind: "person", author: "ann", text: "theirs" }] }, { to: "CHAT/1.000001", text: "again", kind: "need_human", need: "x", about: "1.9" }],
    [{ messages: [{ thread: 1, n: 9, ts: "1.9", authorKind: "agent", author: "me", text: "plain question" }], asking: true }, { to: "CHAT/1.000001", text: "again", kind: "need_human", need: "x", about: "1.9" }],
    [{ messages: [{ thread: 1, n: 9, ts: "1.9", authorKind: "agent", author: "me", text: "q" }] }, { to: "CHAT/1.000001", text: "x", kind: "all_done", done: "已合进 main 82f108a5，测试版 1389 已发", about: "1.9" }],
    [{ messages: [{ thread: 1, n: 9, ts: "1.9", authorKind: "agent", author: "me", text: "q" }] }, { to: "CHAT/1.000001", text: "x", kind: "need_human", need: "x", about: "1.9", card: PEOPLE_CARD }],
    [{ stateQuestion: { kind: "missing" } }, { to: "CHAT/1.000001", text: "x", kind: "need_human", need: "x", about: "1.9" }],
    [{ stateQuestion: { kind: "answered" } }, { to: "CHAT/1.000001", text: "x", kind: "need_human", need: "x", about: "1.9" }],
    [{ stateQuestion: { kind: "found", about: [1, 9, "1.9"] } }, { to: "CHAT/1.000001", text: "x", kind: "need_human", need: "x", about: "1.9" }],
    [{ stateQuestion: { kind: "found", about: [1, 9, "1.9"] }, changeDuringRead: true }, { to: "CHAT/1.000001", text: "x", kind: "need_human", need: "x", about: "1.9" }],
    [{ stateQuestion: { kind: "found", about: [1, 9, "1.9"] }, writeState: true }, { to: "CHAT/1.000001", text: "x", kind: "need_human", need: "x", about: "1.9" }],
    [{ pending: ["1.4"], unread: ["1.5", "1.4"] }, { to: "CHAT/1.000001", text: "late", kind: "all_done", done: "已合进 main 82f108a5，测试版 1389 已发" }],
    [{ pending: ["1.4"], heldCount: 7 }, { to: "CHAT/1.000001", text: "late" }],
    [{ unread: ["1.5"], noActor: false }, { to: "CHAT/1.000001", text: "late", title: "A title" }],
    [{}, { to: "CHAT/1.000001", withdraw: "1.9" }],
    [{}, { to: "CHAT/1.000001", withdraw: " " }],
    [{}, { to: "CHAT/1.000001", withdraw: "1.9", text: "x" }],
    [{ cardAt: { vault: { request: "V1" } } }, { to: "CHAT/1.000001", withdraw: "1.9" }],
    [{ withdraws: false }, { to: "CHAT/1.000001", withdraw: "1.9" }],
    [{}, { to: "CHAT/1.000001", title: "  Naming it.  " }],
    [{}, { to: "CHAT/1.000001", title: " " }],
    [{}, { to: "CHAT/1.000001", title: "x", kind: "all_done" }],
    [{ archived: 1 }, { to: "CHAT/1.000001", title: "x" }],
    [{}, { to: "C9/3.000003", text: "to slack", kind: "need_human", need: "x", card: { type: "options", options: [{ label: "a" }] } }],
    [{ cards: false }, { to: "C9/3.000003", text: "to slack", card: { type: "options", options: [{ label: "a" }] } }],
    [{}, { to: "C9/3.000003", text: "", card: { type: "options", options: [{ label: "a" }] } }],
    [{ loginCards: true, logins: true }, { to: "C9/3.000003", text: "sign in", card: { type: "login", login: "L1" } }],
    [{ loginCards: true, logins: true }, { to: "C9/3.000003", text: "sign in", card: { type: "login", login: "L2" } }],
    [{}, { to: "C9/3.000003", text: "sign in", card: { type: "login", login: "L1", station: "S2" } }],
    [{ profiles: [{ name: "Ann@x.com" }], people: ["bob@y.com"] }, { to: "CHAT/1.000001", text: "q", card: { ...PEOPLE_CARD, assignee: "ann@x.com" } }],
    [{ profiles: [{ email: "ann@x.com" }], wrote: ["ann@x.com"] }, { to: "CHAT/1.000001", text: "q", card: { ...PEOPLE_CARD, assignee: "ann@x.com" } }],
    [{ profiles: [{ email: "ann@x.com" }] }, { to: "CHAT/1.000001", text: "q", card: { ...PEOPLE_CARD, assignee: "ann@x.com" } }],
    [{ openings: [[3, { session: "me", ts: "3.000003", claimed: false }]], messages: [{ thread: 3, n: 1, ts: "3.000003", text: "Relayed here" }] }, { to: "C9/3.000003", text: "first post" }],
    [{ openings: [[3, { session: "me", ts: "3.000003", claimed: true }]] }, { to: "C9/3.000003", text: "second" }],
    [{ openings: [[3, { session: "other", ts: "3.000003", claimed: false }]] }, { to: "C9/3.000003", text: "not mine" }],
    [{ openings: [[3, { session: "me", ts: "3.000003", claimed: false }]], messages: [{ thread: 3, n: 1, ts: "3.000003", text: "Relayed" }], editOk: false }, { to: "C9/3.000003", text: "no edit" }],
    [{ openings: [[3, { session: "me", ts: "3.000003", claimed: false }]], messages: [{ thread: 3, n: 1, ts: "3.000003", text: "Relayed" }], legacy: true }, { to: "C9/3.000003", text: "legacy" }],
    [{ openings: [[3, { session: "me", ts: "3.000003", claimed: false }]] }, { to: "C9/3.000003", text: "no opening message" }],
    [{ postFails: true }, { to: "CHAT/1.000001", text: "fails" }],
    [{ identity: true, noActor: false }, { to: "CHAT/1.000001", text: "with identity", kind: "need_human", need: "decide" }],
    [{ noActor: true }, { to: "CHAT/1.000001", text: "no actor", kind: "all_done", done: "已合进 main 82f108a5，测试版 1389 已发" }],
  ];
  for (const [o, args] of cases) {
    await sameWorld("chatPost", postWorld(o), (hub) => postHeld(hub, args), "me", args);
  }
});

test("conversations: a post held back, then sent as written", { skip }, async () => {
  const make = (held: Map<string, Map<string, Json>>, count: number, pending: string[]) => postWorld({ held, heldCount: count, pending });
  // (the held posts the hub keeps after each, compared as the program's twin keeps them)
  for (const full of [false, true]) {
    const heldA = new Map<string, Map<string, Json>>(full ? [["me", new Map(Array.from({ length: 20 }, (_, i) => [`held-${i}`, { to: "CHAT/1.000001", text: `${i}` }]))]] : []);
    const heldB = new Map<string, Map<string, Json>>(full ? [["me", new Map(Array.from({ length: 20 }, (_, i) => [`held-${i}`, { to: "CHAT/1.000001", text: `${i}` }]))]] : []);
    const args = { to: "CHAT/1.000001", text: "first try", kind: "all_done", done: "已合进 main 82f108a5，测试版 1389 已发", title: "T" };
    const a = tsHub(make(heldA, 3, ["1.2"])(false));
    const want = await settledTs(() => withLog(a.log, () => postHeld(a.hub, args)));
    const b = mbHub(make(heldB, 3, ["1.2"])(true));
    const got = await mbWorld(b.answer, "chatPost", "me", args);
    assert.deepEqual(got, want);
    assert.deepEqual(b.log, a.log);
    assert.deepEqual([...heldB.get("me")!.entries()], [...heldA.get("me")!.entries()]);
    for (const send of [{ to: "CHAT/1.000001", send: "held-4", kind: "all_done", done: "已合进 main 82f108a5，测试版 1389 已发" }, { to: "CHAT/1.000001", send: "held-4", text: "x" }, { to: "CHAT/2.0", send: "held-4" }, { to: "CHAT/1.000001", send: "held-99" }]) {
      const a2 = tsHub(make(heldA, 4, [])(false));
      const want2 = await settledTs(() => withLog(a2.log, () => postHeld(a2.hub, send)));
      const b2 = mbHub(make(heldB, 4, [])(true));
      const got2 = await mbWorld(b2.answer, "chatPost", "me", send);
      assert.deepEqual(got2, want2, JSON.stringify(send));
      assert.deepEqual(b2.log, a2.log);
      assert.deepEqual([...(heldB.get("me") ?? new Map()).entries()], [...(heldA.get("me") ?? new Map()).entries()]);
    }
  }
});

test("conversations: chat_state, chat_leave, chat_history, the Slack bot and slack_api", { skip }, async () => {
  const states: [Json, Json][] = [
    [{}, { kind: "all_done", done: "已合进 main 82f108a5，测试版 1389 已发" }],
    [{}, { kind: "all_done" }],
    [{}, { kind: "waiting", seconds: 45, for: "CI" }],
    [{}, { kind: "waiting", seconds: "2", for: "CI" }],
    [{}, { kind: "waiting", seconds: 99999, for: "CI" }],
    [{}, { kind: "waiting", seconds: "abc", for: "CI" }],
    [{}, { kind: "waiting", seconds: "nan", for: "CI" }],
    [{}, { kind: "waiting", for: "CI" }],
    [{}, { kind: "waiting", seconds: 30 }],
    [{}, { kind: "waiting", seconds: 30, for: "x", watch: "yes" }],
    [{}, { kind: "waiting", seconds: 30, for: "x", watch: true }],
    [{ watching: true }, { kind: "waiting", seconds: 30, for: "x", watch: true }],
    [{}, {}],
    [{}, { kind: "need_decision" }],
    [{}, { kind: "need_human", need: "x" }],
    [{}, { kind: "block" }],
    [{ pendingCard: [{ thread: 3, n: 4, ts: "3.4", createdAt: 9 }] }, { kind: "need_human", need: "x" }],
    [{ messages: [{ thread: 3, n: 4, ts: "3.4", authorKind: "agent", author: "me", text: "q", card: { type: "text" } }], pendingCard: [{ thread: 3, n: 4, ts: "3.4" }] }, { kind: "need_human", need: "x", about: "3.4" }],
    [{}, { kind: "all_done", done: "已合进 main 82f108a5，测试版 1389 已发", about: "9.9" }],
    [{ messages: [{ thread: 1, n: 2, ts: "1.2", authorKind: "person", author: "a", text: "q" }] }, { kind: "all_done", done: "已合进 main 82f108a5，测试版 1389 已发", about: "1.2" }],
    [{ statePendingCard: [1, 3, "1.3"] }, { kind: "need_human", need: "x" }],
    [{ statePendingCard: null }, { kind: "need_human", need: "x" }],
    [{ statePendingCard: null }, { kind: "block" }],
    [{ statePendingCard: [1, 3, "1.3"], stateRecorded: false }, { kind: "need_human", need: "x" }],
    [{ stateQuestion: { kind: "found", about: [1, 3, "1.3"] } }, { kind: "need_human", need: "x", about: "1.3" }],
    [{ stateQuestion: { kind: "missing" } }, { kind: "need_human", need: "x", about: "1.3" }],
    [{ stateQuestion: { kind: "invalid" } }, { kind: "need_human", need: "x", about: "1.3" }],
    [{ stateQuestion: { kind: "found", about: [1, 3, "1.3"] }, writeState: true }, { kind: "need_human", need: "x", about: "1.3" }],
    [{ noActor: true }, { kind: "waiting", seconds: 30, for: "x" }],
  ];
  for (const [o, args] of states) await sameWorld("chatState", postWorld(o), (hub) => chatState(hub, "me", args), "me", args);
  for (const to of ["CHAT/1.000001", "C9/3.000003", "bad"]) await sameWorld("chatLeave", postWorld(), (hub) => chatLeave(hub, "me", { to }), "me", { to });
  const msgs = [
    { thread: 1, n: 1, ts: "1.1", authorKind: "person", author: "U1", text: "hi", attachments: [{ name: "a.txt", path: "/w/a.txt", size: 1 }] },
    { thread: 1, n: 2, ts: "1.2", authorKind: "agent", author: "me", text: "q", card: { type: "options", options: [{ label: "a" }] }, attachments: [] },
    { thread: 1, n: 3, ts: "1.3", authorKind: "person", author: "U2", text: "x", options: [{ label: "z" }], attachments: [] },
    { thread: 1, n: 4, ts: "1.4", authorKind: "station", author: "station", text: "notice", attachments: [] },
  ];
  for (const [o, args] of [
    [{ messages: msgs, pendingCard: [{ thread: 1, n: 2, ts: "1.2" }], choices: [[3, { by: "U1", option: "z" }]] }, { to: "C9/3.000003" }],
    [{ messages: msgs }, { to: "CHAT/1.000001", limit: 500, before: "1.3" }],
    [{ messages: msgs, historyMessages: true }, { to: "CHAT/1.000001", limit: "7" }],
    [{ messages: [] }, { to: "CHAT/1.000001" }],
    [{ messages: msgs }, { to: "CHAT/1.000001", before: "9.9" }],
    [{ messages: msgs }, { to: "CHAT/1.000001", limit: 0 }],
    [{ messages: msgs }, { to: "CHAT/1.000001", limit: "nan" }],
  ] as [Json, Json][]) {
    await sameWorld("chatHistory", postWorld(o), (hub) => chatHistory(hub, "me", args), "me", args);
    const seen: Json[] = [];
    await sameWorld("threadHistory", postWorld(o), async (hub) => ({ text: await threadHistory(hub, "me", SLACK as Json, "slack1", "named", args, seen), seen }), "me", SLACK, "slack1", "named", args);
  }
  const connects = (list: Json[]) => list.map((c) => ({ kind: "slack", enabled: true, slack: {}, bind: { runtime: "claude" }, ...c }));
  for (const [o, bot] of [
    [{ connect: "slackX" }, null],
    [{ connects: connects([{ id: "slack1" }]) }, null],
    [{ connects: connects([{ id: "slack1" }, { id: "slack2", bind: { runtime: "codex" } }]) }, null],
    [{ connects: connects([{ id: "slack1" }, { id: "slack3" }]) }, null],
    [{ connects: connects([{ id: "slack1", slack: { botName: "Helper" } }, { id: "slack3" }]) }, "helper"],
    [{ connects: connects([{ id: "slack1" }]) }, "nope"],
    [{ connects: [] }, null],
    [{ connects: connects([{ id: "slack1", workspace: "W2" }, { id: "slack1", enabled: false }]) }, null],
  ] as [Json, string | null][]) {
    await sameWorld("slackConnectOf", postWorld(o), (hub) => slackConnectOf(hub, "me", bot), "me", bot);
  }
  const apis: [Json, string, Json, boolean][] = [
    [{ connect: "slack1" }, "conversations.history", { channel: "C9" }, false],
    [{ connect: "slack1" }, "chat.postMessage", { channel: "C9", text: "hi" }, false],
    [{ connect: "slack1", identity: true }, "chat.postMessage", { channel: "C9", text: "hi", thread_ts: "3.000003" }, false],
    [{ connect: "slack1", inThread: true }, "reactions.add", { channel: "C9", timestamp: "4.1" }, false],
    [{ connect: "slack1", inThread: true, sameBot: true }, "chat.update", { channel: "C9", ts: "4.1", text: "x" }, false],
    [{ connect: "slack1", joined: false }, "chat.postMessage", { channel_id: "C9", text: "hi" }, false],
    [{ connect: "slack1" }, "admin.users.list", {}, false],
    [{ connect: "slack1" }, "auth.revoke", {}, false],
    [{ connect: "slack1" }, "Not.A.Method", {}, false],
    [{ connect: "slack1", apiFails: true }, "users.info", { user: "U1" }, false],
    [{ connect: "slack1" }, "files.info", { file: "F1" }, true],
    [{ connect: "slack1", big: true }, "users.list", {}, false],
  ];
  for (const [o, method, params, save] of apis) await sameWorld("slackApi", postWorld(o), (hub) => slackApi(hub, "me", method, params, null, null, save), "me", method, params, null, null, save);
});

test("conversations: files staged out of a protected folder, and attached", { skip }, async () => {
  const dir = fresh("session-chats-files-");
  const ws = join(dir, "me");
  await mkdir(ws, { recursive: true });
  await writeFile(join(ws, "notes.txt"), "notes");
  await writeFile(join(ws, "pic.gif"), Buffer.from([...Buffer.from("GIF89a"), 3, 0, 2, 0, 0, 0]));
  await mkdir(join(ws, "a dir"), { recursive: true });
  for (const [o, args, links] of [
    [{}, { files: ["/Users/x/Documents/a.txt"] }, false],
    [{ mac: true }, { files: [] }, false],
    [{ mac: true }, { files: ["notes.txt"] }, false],
    [{ mac: true }, { text: "see [a](/Users/x/Documents/r.md)" }, true],
    [{ mac: true }, { text: "see [a](/tmp/x.md)" }, true],
    [{ mac: true }, { text: "see [a](/tmp/x.md)" }, false],
  ] as [Json, Json, boolean][]) {
    await sameWorld("mayStage", postWorld(o), (hub) => mayStage(hub, args, links), args, links);
  }
  for (const [o, args, links] of [
    [{ mac: true, workspace: ws }, { files: ["/Users/x/Documents/a.txt", "notes.txt", "/abs/b.txt"] }, false],
    [{ mac: true, workspace: ws }, { text: "see [a](/Users/x/Documents/r.md) and [b](</Users/x/Documents/s t.md>) and [c](/Users/x/Documents/c.rs:12)" }, true],
    [{ mac: true, workspace: ws, placeGone: true }, { text: "see [c](/Users/x/Documents/c.rs:12)" }, true],
    [{ mac: true, workspace: ws }, { text: "plain" }, false],
    [{ mac: true, workspace: ws }, {}, true],
  ] as [Json, Json, boolean][]) {
    await sameWorld("staged", postWorld(o), async (hub) => { const s = await staged(hub, "me", args, links); await s.done(); return { args: s.args }; }, "me", args, links, true);
  }
  const clock = mock.method(Date, "now", () => 1_700_000_000_000);
  try {
    for (const paths of [["notes.txt"], ["pic.gif", join(ws, "notes.txt")], ["missing.txt"], ["a dir"], Array.from({ length: 11 }, () => "notes.txt")]) {
      const out = (mb: boolean) => postWorld({ workspace: ws })(mb);
      const a = tsHub({ ...out(false), hub: { ...out(false).hub, now: () => 1_700_000_000_000 } });
      const want = await settledTs(() => attach(a.hub, "me", paths));
      const b = mbHub({ ...out(true), hub: { ...out(true).hub, now: () => 1_700_000_000_000 } });
      const got = await mbWorld(b.answer, "attach", "me", paths, null);
      assert.deepEqual(got, want, JSON.stringify(paths));
    }
  } finally {
    clock.mock.restore();
  }
});

// ── opened: chat_create, a chat an agent opens for another ────────────────────────────────────────────────────────

/// The opener `me` in its chat, the station's profiles, presets and the other stations as `o` says.
function openedWorld(o: Json = {}) {
  return (mb: boolean): World => {
    void mb;
    let ts = 0;
    const profiles = o.profiles ?? [{ id: "p1", runtimes: ["codex"], models: ["gpt-6", "gpt-6.1"], model: "gpt-6", enabled: true }, { id: "p2", runtimes: ["claude"], models: ["claude-opus-5-5"], enabled: true }];
    const child = (k: string) => ({ id: 70, surface: "ember", channel: "CHAT", threadTs: "7.000007", home: k, createdBy: "ann@x.com", title: null, autoTitle: null });
    return {
      store: {
        getSession: (k: string) => (k === "me" ? { key: "me", title: null, runtime: "codex", ws: o.ws ?? null, createdBy: "ann@x.com", workspace: "/w/me" } : k.startsWith("chat:c-") || k === "kid" ? (o.kidGone ? null : { key: k, title: null, ws: o.kidWs ?? null, workspace: "/w/kid" }) : null),
        openerOf: (k: string) => o.openerOf?.[k] ?? null,
        sessionHomeThread: (k: string) => (k === "me" ? { thread: { id: 1, surface: "ember", channel: "CHAT", threadTs: "1.000001", title: "Lead chat", createdBy: "ann@x.com" }, connect: "ember" } : k.startsWith("chat:c-") || k === "kid" ? { thread: child(k), connect: "ember" } : null),
        latestThread: (k: string) => (k === "me" || k === "kid" ? { thread: { id: 1, surface: "ember", channel: "CHAT", threadTs: "1.000001" }, connect: "ember" } : null),
        homeChat: (k: string) => child(k),
        joinThread: () => true,
        openedWith: () => o.before ?? null,
        insertOpened: () => {},
        insertMessage: () => [++ts],
        insertLetter: () => ++ts,
        messagesBefore: () => o.said ?? [],
        effortsUsedBy: () => o.efforts ?? [],
        modelsUsedBy: () => o.used ?? [],
        firstText: () => "first",
        threadSessions: () => [],
        setOpenedState: () => {},
        openedBy: () => o.records ?? [],
      },
      hub: {
        link: (k: string) => (o.noLinks ? undefined : `https://app.still.fail/o/W1/S1/${k}`),
        nextTs: () => `9.${String(++ts).padStart(6, "0")}`,
        config: () => ({ dataDir: "/data", profiles }),
        profilesIn: () => profiles,
        workspaces: () => ["W1"],
        wsOf: () => o.ws ?? null,
        station: () => "S1",
        inWorkspace: (_k: string, ws: string) => ws === (o.inWs ?? ws),
        peers: () => (o.peers === undefined ? null : async (station: string, request: Json) => o.peers(station, request)),
        deliver: () => {}, deliverLetter: () => {},
        notify: (...a: Json[]) => { if (o.notifyFails) throw new Error("no such session"); void a; },
        now: () => 1_700_000_000_000,
        ...(o.openedChatSaid ? { openedChatSaid: async () => o.openedChatSaid === "yes" } : {}),
      },
      props: {
        internal: true,
        presets: {
          list: async () => o.presets ?? [],
          isHere: (s: string) => s === "S1" || s.endsWith("/S1"),
          nameOf: (s: string, said?: string) => said ?? `name of ${s}`,
          get: async (_ws: Json, id: string) => (o.presets ?? []).find((p: Json) => p.id === id) ?? null,
        },
        clientKeysMade: new Map(),
      },
      chats: { ember: { post: async () => { if (o.postFails) throw new Error("cannot post"); return `8.${String(++ts).padStart(6, "0")}`; } } },
      deps: STATION_DEPS,
    };
  };
}

test("opened: chat_create, here and on another station, a key opened again, and the opener told", { skip }, async () => {
  const preset = { id: "pr1", name: "Android", dirs: [{ path: "/repo", repo: "github.com/o/r" }, { path: "/far", repo: null, station: "W1/S2", stationName: "Far" }, { path: "/mine", repo: null, station: "W1/S1" }], instructions: "do it", model: { model: "gpt-6", effort: "high", speed: "fast" } };
  const free = { id: "pr2", name: "Free", dirs: [], instructions: "", stations: ["W1/S2", "W1/S3"] };
  const pinned = { id: "pr3", name: "Pinned", dirs: [{ path: "/x", repo: null, station: "W1/S2" }], instructions: "", station: "W1/S2" };
  const roster = async (_s: string, r: Json) => (r.method === "peers" ? { stations: [{ id: "S1", name: "here" }, { id: "S2", name: "Far" }, { id: "S3" }] } : r.method.startsWith("session.create") ? { session: "far-kid", link: "https://app.still.fail/o/W1/S2/far-kid", thread: "CHAT/2.2", said: false, asked: r } : { ok: r.method });
  const creates: [Json, Json][] = [
    [{}, { key: "k1", for: "me", text: "build android" }],
    [{}, { key: "k1", for: "person", text: "for ann", runtime: "claude", model: "claude-opus-5-5" }],
    [{}, { for: "me", text: "x" }],
    [{}, { key: "x".repeat(121), for: "me", text: "x" }],
    [{}, { key: "k", for: "them", text: "x" }],
    [{}, { key: "k", for: "me" }],
    [{}, { key: "k", for: "me", text: "x", runtime: "nope" }],
    [{}, { key: "k", for: "me", text: "x", fast: "yes" }],
    [{}, { key: "k", for: "me", text: "x", speed: "warp" }],
    [{}, { key: "k", for: "me", text: "x", title: "t".repeat(121) }],
    [{ openerOf: { me: { led: true } } }, { key: "k", for: "me", text: "x" }],
    [{ openerOf: { me: { led: false } } }, { key: "k", for: "me", text: "x", model: "gpt-6.1", effort: "low" }],
    [{ used: [{ runtime: "codex", model: "gpt-6", n: 3 }, { runtime: "claude", model: "claude-opus-5-5", n: 1 }] }, { key: "k", for: "me", text: "chosen", fast: true, speed: "standard", context: 200000 }],
    [{ efforts: [{ effort: "max" }] }, { key: "k", for: "me", text: "usual effort", model: "gpt-6" }],
    [{ presets: [preset] }, { key: "k", for: "me", text: "with preset", preset: "android" }],
    [{ presets: [preset] }, { key: "k", for: "me", text: "with preset", preset: "pr1", model: "x" }],
    [{ presets: [] }, { key: "k", for: "me", text: "x", preset: "none" }],
    [{ presets: [preset, free] }, { key: "k", for: "me", text: "x", preset: "none" }],
    [{ presets: [free] }, { key: "k", for: "me", text: "x", preset: "Free" }],
    [{ presets: [free], peers: roster }, { key: "k", for: "me", text: "x", preset: "Free", station: "S3" }],
    [{ presets: [pinned], peers: roster }, { key: "k", for: "person", text: "x", preset: "Pinned" }],
    [{ presets: [preset], peers: roster }, { key: "k", for: "me", text: "x", preset: "pr1", station: "Far" }],
    [{ peers: roster }, { key: "k", for: "me", text: "far away\nsecond line", station: "S2", title: "Far chat" }],
    [{ peers: roster }, { key: "k", for: "me", text: "x", station: "here" }],
    [{ peers: roster }, { key: "k", for: "me", text: "x", station: "nowhere" }],
    [{}, { key: "k", for: "me", text: "x", station: "S2" }],
    [{ peers: async (s: string, r: Json) => (r.method === "peers" ? { stations: [{ id: "S2" }] } : Promise.reject(new Refused("task key is required"))) }, { key: "k", for: "me", text: "x", station: "S2" }],
    [{ peers: async (s: string, r: Json) => (r.method === "peers" ? { stations: [{ id: "S2" }] } : Promise.reject(new Error("timed out"))) }, { key: "k", for: "me", text: "x", station: "S2", speed: "fast" }],
    [{ peers: async (s: string, r: Json) => (r.method === "peers" ? { stations: [{ id: "S2" }] } : {}) }, { key: "k", for: "me", text: "x", station: "S2" }],
    [{ peers: async (s: string, r: Json) => (r.method === "peers" ? { stations: [{ id: "S2" }] } : r.method === "session.message" ? Promise.reject(new Error("lost")) : { session: "far-kid", said: false }) }, { key: "k", for: "me", text: "x", station: "S2" }],
    [{ peers: async (s: string, r: Json) => (r.method === "peers" ? { stations: [{ id: "S2" }] } : { session: "far-kid", said: true }) }, { key: "k", for: "me", text: "x", station: "S2" }],
    [{ before: { child: "kid", link: "https://x/kid", led: false } }, { key: "k", for: "me", text: "again" }],
    [{ before: { child: "kid", link: null, led: true }, openedChatSaid: "yes" }, { key: "k", for: "me", text: "again" }],
    [{ before: { child: "kid", link: null }, said: [{ author: "me", authorKind: "agent" }] }, { key: "k", for: "me", text: "again" }],
    [{ before: { child: "kid", link: null }, kidGone: true }, { key: "k", for: "me", text: "again" }],
    [{ postFails: true }, { key: "k", for: "me", text: "the opener's chat cannot be posted to" }],
    [{ noLinks: true }, { key: "k", for: "me", text: "no links" }],
  ];
  for (const [o, args] of creates) await sameWorld("chatCreate", openedWorld(o), (hub) => chatCreate(hub, "me", args), "me", args);
  const peerRequests: [Json, Json, string | null][] = [
    [{}, { session: "far1", key: "k", runtime: "codex", model: "gpt-6.1", from: { title: "Far lead" }, led: true }, null],
    [{}, { session: "far1", key: "k", runtime: "codex", choose: true }, "W1"],
    [{}, { session: "far1", key: "k", runtime: "claude", choose: true, runtimeGiven: true, fast: false, speed: "ultrafast", context: 300000 }, null],
    [{}, { key: "k", runtime: "codex" }, null],
    [{}, { session: "far1", runtime: "codex" }, null],
    [{}, { session: "far1", key: "k", runtime: "nope" }, null],
    [{}, { session: "far1", key: "k", runtime: "codex", method: "session.create.preset", presetCopy: { id: "p", name: "Copy", dirs: [{ path: "/a", station: "x", guides: [], elsewhere: "S2" }], instructions: "i", model: { model: "gpt-6", runtime: "codex" }, stations: ["S1"] } }, null],
    [{}, { session: "far1", key: "k", runtime: "codex", method: "session.create.preset", presetCopy: { name: "" } }, null],
    [{ before: { child: "kid" } }, { session: "far1", key: "k", runtime: "codex" }, null],
    [{ before: { child: "kid" }, kidGone: true }, { session: "far1", key: "k", runtime: "codex" }, null],
    [{ before: { child: "kid" }, inWs: "W9" }, { session: "far1", key: "k", runtime: "codex" }, "W1"],
    [{}, { session: "far1", key: "k", runtime: "codex", effort: "low", inherited: true, model: "unknown-model" }, null],
  ];
  for (const [o, request, ws] of peerRequests) await sameWorld("createForPeer", openedWorld(o), (hub) => createForPeer(hub, "S2", request, ws), "S2", request, ws);
  for (const [o, state, words] of [
    [{}, "all_done", "done well"],
    [{ openerOf: { kid: { parentStation: "", parent: "me", led: true } } }, "need_human", "pick"],
    [{ openerOf: { kid: { parentStation: "", parent: "me", led: null } } }, "failed", ""],
    [{ openerOf: { kid: { parentStation: "", parent: "me", led: false } } }, "stopped", null],
    [{ openerOf: { kid: { parentStation: "", parent: "me", led: true } }, notifyFails: true }, "all_done", "x"],
    [{ openerOf: { kid: { parentStation: "S2", parent: "far1", led: true } }, peers: async () => ({ told: true }) }, "all_done", "x"],
    [{ openerOf: { kid: { parentStation: "S2", parent: "far1", led: true } } }, "need_human", "x"],
    [{ openerOf: { kid: { parentStation: "S2", parent: "far1", led: true } }, peers: async () => { throw new Error("unreachable"); } }, "failed", "x"],
  ] as [Json, string, string | null][]) {
    await sameWorld("settled", openedWorld(o), async (hub) => { settled(hub, "kid", state as Json, words); await quiet(hub.__log ?? []); }, "kid", state, words);
  }
  for (const [o, request, ws] of [
    [{ records: [{ childStation: "S2", child: "far-kid", title: "Far", link: "https://x/far", led: true }] }, { session: "far-kid", to: "me", state: "need_human", words: "decide" }, null],
    [{ records: [{ childStation: "S2", child: "far-kid", title: null, link: null, led: null }] }, { session: "far-kid", to: "me", state: "all_done", title: "Said title" }, "W1"],
    [{ records: [] }, { session: "far-kid", to: "me", state: "all_done" }, null],
    [{}, { session: "far-kid", to: "me", state: "weird" }, null],
    [{ inWs: "W9" }, { session: "far-kid", to: "me", state: "all_done" }, "W1"],
  ] as [Json, Json, string | null][]) {
    await sameWorld("noticeForPeer", openedWorld(o), (hub) => noticeForPeer(hub, "S2", request, ws), "S2", request, ws);
  }
});

// ── decision: a decision model asked, and what a profile decides with ─────────────────────────────────────────────

/// The network as a case gives it: each request recorded into `into`, answered by `answer`.
function netOf(into: () => Json[], answer: (url: string, init: Json) => { status?: number; body: string } | Error) {
  return mock.method(globalThis, "fetch", async (url: string, init: Json = {}) => {
    const body = typeof init.body === "string" ? JSON.parse(init.body) : null;
    const headers = { ...(init.headers ?? {}) };
    if ("x-opencode-session" in headers) headers["x-opencode-session"] = "<uuid>";
    into().push(["net.fetch", url, init.method ?? "GET", headers, body]);
    const a = answer(url, init);
    if (a instanceof Error) throw a;
    return new Response(a.body, { status: a.status ?? 200 });
  });
}

const JEV_ANSWER = (p: Record<string, number>) => JSON.stringify({ answers: { decision: { type: "choice", probabilities: p } }, model: "jev-7" });
const LOGPROBS = (tokens: [string, number][]) => JSON.stringify({ choices: [{ logprobs: { content: [{ top_logprobs: tokens.map(([token, logprob]) => ({ token, logprob })) }] } }] });

test("decision: what is asked of a decision model and how its answer is read", { skip }, async () => {
  const q = completionQuestion();
  await same("completionQuestion", () => completionQuestion());
  const jev = { provider: "jev", endpoint: "https://api.typesafe.ai/v1/systemone", model: "jev-latest", apiKey: "k", sessionHeader: false, threshold: 0.85 };
  const chat = { ...jev, provider: "chat_logprobs", endpoint: "https://x.example/v1/chat/completions", model: "qwen-flash" };
  const ds = { ...chat, model: "DeepSeek-v4-flash" };
  const state = { agent: "k", conversations: [{ thread: 1, messages: [{ text: "hi 😀" }] }] };
  for (const c of [jev, chat, ds]) await same("request", () => decisionRequest(c as Json, q, state), c, q, state);
  await same("request", () => decisionRequest(jev as Json, { instructions: "x", criteria: [["a", "b"]] }, state), jev, { instructions: "x", criteria: [["a", "b"]] }, state);
  const raws: [Json, Json][] = [
    [jev, JSON.parse(JEV_ANSWER({ agent_work: 0.05, complete: 0.9, human_needed: 0.03, uncertain: 0.02 }))],
    [jev, JSON.parse(JEV_ANSWER({ agent_work: 0.25, complete: 0.25, human_needed: 0.25, uncertain: 0.25 }))],
    [jev, JSON.parse(JEV_ANSWER({ complete: 1 }))],
    [jev, JSON.parse(JEV_ANSWER({ agent_work: 0.5, complete: "x" as unknown as number, human_needed: 0.25, uncertain: 0.25 }))],
    [jev, { answers: { decision: { type: "text" } } }],
    [jev, { answers: { decision: { type: "choice", probabilities: [1] } } }],
    [jev, JSON.parse(JEV_ANSWER({ agent_work: 0.5, complete: 0.6, human_needed: 0.25, uncertain: 0.25 }))],
    [chat, JSON.parse(LOGPROBS([["A", Math.log(0.1)], ["B", Math.log(0.8)], ["C", Math.log(0.06)], ["D", Math.log(0.04)]]))],
    [chat, JSON.parse(LOGPROBS([["B", Math.log(0.97)]]))],
    [chat, JSON.parse(LOGPROBS([["B", Math.log(0.5)]]))],
    [chat, JSON.parse(LOGPROBS([["B", 0.1]]))],
    [chat, JSON.parse(LOGPROBS([["B", Math.log(0.6)], ["B", Math.log(0.4)]]))],
    [chat, JSON.parse(LOGPROBS([["A", "x"] as Json]))],
    [chat, { choices: [{ logprobs: { content: [] } }] }],
    [chat, { choices: [{ logprobs: { content: [{}] } }] }],
    [chat, {}],
  ];
  for (const [c, raw] of raws) await same("parse", () => decisionParse(c as Json, q, raw), c, q, raw);
  for (const r of [{ selected: "complete", probabilities: { complete: 0.9 } }, { selected: "complete", probabilities: { complete: 0.8 } }, { selected: "uncertain", probabilities: { complete: 0.99 } }]) {
    await same("acceptsCompletion", () => acceptsCompletion(r as Json, 0.85), r, 0.85);
  }
  const names = ["gpt-6", "jev-latest", "qwen-3-flash", "deepseek-v4-flash", "gemini-flash-lite", "gpt-6-mini", "glm-5", "o9-reasoner", "claude-thinking", "a-nano", "Zeta", "alpha"];
  for (const m of names) await same("decisionPriority", () => decisionPriority(m), m);
  await same("sortByDecisionPriority", () => [...names].sort(byDecisionPriority), names);
  const configs = [jev, chat, { ...jev, endpoint: "http://localhost:9/x" }, { ...jev, endpoint: "http://remote/x" }, { ...jev, endpoint: "https://u:p@x/y" }, { ...jev, endpoint: "https://x/y?q=1" }, { ...jev, endpoint: "not a url" }, { ...jev, model: " " }, { ...jev, threshold: 0.4 }, { ...jev, threshold: 1.2 }];
  for (const c of configs) await sameWorld("validate", () => ({ deps: STATION_DEPS }), () => validateDecision(c as Json), c);
  let log: Json[] = [];
  const answers: [Json, { status?: number; body: string } | Error][] = [
    [jev, { body: JEV_ANSWER({ agent_work: 0.05, complete: 0.9, human_needed: 0.03, uncertain: 0.02 }) }],
    [{ ...chat, sessionHeader: true, apiKey: "" }, { body: LOGPROBS([["A", Math.log(0.1)], ["B", Math.log(0.8)], ["C", Math.log(0.06)], ["D", Math.log(0.04)]]) }],
    [jev, { status: 429, body: "slow down" }],
    [jev, { body: "not json" }],
    [jev, { body: "x".repeat(256_001) }],
    [jev, new Error("refused")],
  ];
  for (const [c, a] of answers) {
    const net = netOf(() => log, () => a);
    try {
      log = [];
      const want = await settledTs(() => decide(c as Json, q, state));
      const wantLog = log;
      log = [];
      const got = await mbWorld(mbHub({ deps: STATION_DEPS }).answer, "decide", c, q, state);
      assert.deepEqual(got, want);
      assert.deepEqual(log, wantLog);
    } finally {
      net.mock.restore();
    }
  }
  const big = { agent: "k", text: "x".repeat(97_000) };
  await sameWorld("decide", () => ({ deps: STATION_DEPS }), () => decide(jev as Json, q, big), jev, q, big);
});

test("decision: a profile's connection, its fingerprint, its verified model, and what discovery finds", { skip }, async () => {
  const home = fresh("decision-home-");
  await writeFile(join(home, "config.toml"), 'model_provider = "acme" # the provider\n[model_providers.acme]\nbase_url = "https://acme.example/v1/"\nenv_key = "ACME_KEY"\nname = \'Acme\'\n[other]\nx = "y"\n');
  const openai = fresh("decision-openai-");
  await writeFile(join(openai, "auth.json"), JSON.stringify({ OPENAI_API_KEY: "sk-from-auth" }));
  const bad = fresh("decision-bad-");
  await writeFile(join(bad, "config.toml"), 'model_provider = "bad\\q"\n');
  const profiles: Json[] = [
    { id: "jev", runtime: "claude", runtimes: ["claude"], env: { TYPESAFE_API_KEY: "tk" }, home: "/h", named: ["a"], models: ["jev-1", "qwen-flash"] },
    { id: "jev2", runtime: "claude", runtimes: ["claude"], env: { JEV_API_KEY: "jk", TYPESAFE_BASE_URL: "https://jev.example/v2/" }, home: "/h", named: [], models: [], model: "m" },
    { id: "go", access: { kind: "opencode-go", key: " gk " }, runtimes: ["claude", "codex"], home: "/h", named: [], models: ["qwen-3-flash", "glm-5"] },
    { id: "acme", runtime: "codex", runtimes: ["codex"], home, env: { ACME_KEY: "ak" }, named: [], models: ["acme-mini"] },
    { id: "openai", runtime: "codex", runtimes: ["codex"], home: openai, named: [], models: [] },
    { id: "nokey", runtime: "codex", runtimes: ["codex"], home: fresh("decision-nokey-"), named: [], models: [] },
    { id: "bad", runtime: "codex", runtimes: ["codex"], home: bad, named: [], models: [] },
    { id: "claude", runtime: "claude", runtimes: ["claude"], home: "/h", named: [], models: [] },
  ];
  for (const p of profiles) {
    await profileFilesRead(p);
    await sameWorld("fingerprint", () => ({ deps: STATION_DEPS }), () => fingerprint(p), p);
    const fp = fingerprint(p);
    for (const cap of [
      { state: "ready", fingerprint: fp, provider: "jev", models: ["jev-1"], model: "jev-1" },
      { state: "ready", fingerprint: fp, provider: "chat_logprobs", models: ["qwen-3-flash", "acme-mini"], model: null },
      { state: "ready", fingerprint: "stale", provider: "jev", models: ["jev-1"] },
      { state: "unavailable", fingerprint: fp, provider: "jev" },
    ]) {
      for (const chosen of ["jev-1", "acme-mini", "qwen-3-flash", null, "other"]) {
        await sameWorld("resolvedModel", () => ({ deps: STATION_DEPS }), () => resolvedModel(p, cap as Json, chosen), p, cap, chosen);
      }
    }
  }
  let log: Json[] = [];
  const net = netOf(() => log, (url, init) => {
    if (url.endsWith("/models")) return { body: JSON.stringify({ data: [{ id: "list-flash" }, { id: "big-model" }, { nope: 1 }] }) };
    const body = JSON.parse(init.body);
    const model = body.model as string;
    if (model.includes("bad")) return { status: 500, body: "" };
    if (body.questions) return { body: JEV_ANSWER(model === "jev-latest" ? { agent_work: 0.02, complete: 0.95, human_needed: 0.02, uncertain: 0.01 } : { agent_work: 0.5, complete: 0.4, human_needed: 0.05, uncertain: 0.05 }) };
    return { body: LOGPROBS(model.includes("flash") || model.includes("mini") ? [["A", Math.log(0.97)], ["B", Math.log(0.01)], ["C", Math.log(0.01)], ["D", Math.log(0.01)]] : [["B", Math.log(0.97)]]) };
  });
  try {
    for (const p of profiles) {
      for (const check of [{ state: "ok", models: ["bad-flash", "x-mini"] }, { state: "login" }, { state: "ok" }]) {
        log = [];
        const want = unrandom(await settledTs(() => discover(p, check as Json)));
        const wantLog = log;
        log = [];
        const got = unrandom(await mbWorld(mbHub({ deps: STATION_DEPS, hub: { now: () => 1_000 } }).answer, "discover", p, check));
        assert.deepEqual(got, want, `${p.id} ${JSON.stringify(check)}`);
        assert.deepEqual(log, wantLog, `${p.id}: what was asked of the network`);
      }
    }
  } finally {
    net.mock.restore();
  }
});


// ── review: whether a chat that ended all_done has anything left in it ────────────────────────────────────────────

/// A station with chats ended all_done and an account that decides, as `o` says; the network answers with `pick`.
function reviewWorld(o: Json = {}) {
  const jevProfile = { id: "jev", runtime: "claude", runtimes: ["claude"], env: { TYPESAFE_API_KEY: "tk" }, home: "/h", named: [], models: ["jev-latest"], enabled: true };
  return (mb: boolean): World => {
    void mb;
    let now = 1_000;
    const entries: Json = { ...(o.entries ?? { 1: 5, 2: 9 }) };
    let reads = 0;
    const capability = o.capability ?? { state: "ready", fingerprint: fingerprint(jevProfile as Json), provider: "jev", models: ["jev-latest"], model: "jev-latest" };
    const live = o.live ?? [{ key: "a", running: false }, { key: "b", running: true }, { key: "c", running: false }, { key: "d", running: false }];
    return {
      store: {
        archivePolicy: (ws: Json) => o.policies?.[String(ws)] ?? null,
        recordDecision: () => { if (o.recordFails) throw new Error("full"); },
        setArchiveVerdict: () => {},
        recentSessionThreads: (k: string) => ({ threads: (o.threads?.[k] ?? [1, 2]).map((id: number) => ({ thread: { id }, connect: "ember" })), more: false }),
        lastEntry: (id: number) => { reads++; if (o.moves && reads > o.moves) entries[id] = (entries[id] ?? 0) + 1; return entries[id] ?? 0; },
        messagesBefore: (id: number, _from: Json, limit: number) => (o.messages?.[id] ?? [{ authorKind: "person", author: "a", text: "please", ts: "1.1", attachments: [] }, { authorKind: "agent", author: "k", text: "done", ts: "1.2", attachments: [{}] }]).slice(-limit),
        pendingCard: (id: number) => (o.pending === id ? [{ ts: "1.3", text: "still asking", thread: id, n: 3 }] : null),
        suggestArchive: () => {}, clearArchiveSuggestion: () => {},
        liveSessions: () => live,
        lastTurn: (k: string) => (o.turns?.[k] !== undefined ? o.turns[k] : { endedAt: 5, ending: "all_done" }),
        hasUndelivered: (k: string) => o.undelivered === k,
        lastDecision: (k: string) => o.decisions?.[k] ?? null,
        archiveSuggested: (id: number) => (o.suggested ?? []).includes(id),
        prepareDecisionSessions: async () => { o.prepared = true; },
      },
      hub: {
        config: () => ({ profiles: o.profiles ?? [jevProfile], automaticDecisions: { completion: { enabled: o.enabled ?? true, model: o.model ?? "jev-latest" } } }),
        wsOf: (k: Json) => (typeof k === "string" ? (o.wsOf?.[k] ?? null) : (o.wsOf?.[k.key] ?? null)),
        workspaces: () => ["W1"],
        now: () => (now += 7),
        ...(o.latest ? { latestMessages: async (id: number, limit: number) => (o.messages?.[id] ?? []).slice(-limit) } : {}),
        ...(o.reviewPending ? { reviewPendingCard: async () => [{ ts: "9.9", text: "from the reader" }] } : {}),
      },
      props: { accounts: { healthOf: (id: string) => (o.health?.[id] ?? { check: { state: "ok", decision: capability }, quota: null }) } },
      deps: STATION_DEPS,
    };
  };
}

test("review: the archive review of a chat, which chats are undecided, and the sweep", { skip }, async () => {
  const policy = { change: { id: 4 }, policy: { policy: "Archive what is finished", options: [{ id: "done", name: "Done", rubric: "Nothing left", archive: true }, { id: "open", name: "Open", rubric: "Something left", archive: false }] } };
  const pick = (selected: string, p = 0.95) => (url: string, init: Json) => {
    void url;
    const body = JSON.parse(init.body);
    const names = Object.keys(body.questions.decision.criteria);
    const probabilities = Object.fromEntries(names.map((n) => [n, n === selected ? p : (1 - p) / (names.length - 1)]));
    return { body: JEV_ANSWER(probabilities) };
  };
  const huge = Array.from({ length: 450 }, (_, i) => ({ authorKind: i % 2 ? "agent" : "person", author: "x", text: "y".repeat(500), ts: `1.${i}`, attachments: [] }));
  const cases: [Json, (u: string, i: Json) => Json][] = [
    [{}, pick("complete")],
    [{}, pick("agent_work")],
    [{ policies: { null: policy } }, pick("done")],
    [{ policies: { null: policy } }, pick("open")],
    [{ policies: { W2: policy }, wsOf: { k: "W2" } }, pick("done", 0.6)],
    [{ enabled: false }, pick("complete")],
    [{ model: "other-model" }, pick("complete")],
    [{ health: { jev: { check: { state: "login" } } } }, pick("complete")],
    [{ moves: 2 }, pick("complete")],
    [{ messages: { 1: huge, 2: [] }, pending: 1 }, pick("complete")],
    [{ messages: { 1: huge }, latest: true, reviewPending: true }, pick("complete")],
    [{ threads: { k: [] } }, pick("complete")],
    [{ recordFails: true }, pick("complete")],
    [{}, () => ({ status: 500, body: "" })],
    [{ profiles: [] }, pick("complete")],
  ];
  for (const [o, answer] of cases) {
    let into: Json[] = [];
    const net = netOf(() => into, answer);
    try {
      const a = tsHub(reviewWorld(o)(false));
      into = a.log;
      const want = await settledTs(() => withLog(a.log, () => review(a.hub, "k")));
      const b = mbHub(reviewWorld(o)(true));
      into = b.log;
      const got = await mbWorld(b.answer, "review", "k");
      assert.deepEqual(got, want, JSON.stringify(o).slice(0, 200));
      assert.deepEqual(b.log, a.log, `${JSON.stringify(o).slice(0, 200)}: what was asked of the hub`);
    } finally {
      net.mock.restore();
    }
  }
  const sweeps: Json[] = [
    {},
    { turns: { a: null, c: { endedAt: null, ending: "all_done" }, d: { endedAt: 3, ending: "need_help" } } },
    { undelivered: "a", suggested: [1, 2] },
    { policies: { null: policy }, decisions: { a: { policyAt: 4, threads: [[1, 5], [2, 9]], result: {}, error: null }, c: { policyAt: 4, threads: [[1, 5], [2, 8]], result: {} }, d: { policyAt: 0, threads: [[1, 5], [2, 9]], result: {} } } },
    { suggested: [1, 2], decisions: { a: { policyAt: 0 } }, wsOf: { c: "W2" }, policies: { W2: policy } },
    { threads: { a: [], c: [1], d: [2] }, decisions: { c: { threads: [[1, 4], [1, 5]], result: {}, error: null } } },
    { enabled: false },
    { profiles: [] },
  ];
  for (const o of sweeps) {
    await sameWorld("undecided", reviewWorld(o), (hub) => undecided(hub), );
    for (const k of ["a", "k"]) {
      await sameWorld("policyWs", reviewWorld(o), (hub) => policyWs(hub, k), k);
      await sameWorld("policyStamp", reviewWorld(o), (hub) => policyStamp(hub, k), k);
    }
    let into: Json[] = [];
    const net = netOf(() => into, pick("complete"));
    try {
      const a = tsHub(reviewWorld(o)(false));
      into = a.log;
      const want = await settledTs(() => withLog(a.log, async () => { const n = await startReview(a.hub); await quiet(a.log); return n; }));
      const b = mbHub(reviewWorld(o)(true));
      into = b.log;
      const got = await mbWorld(b.answer, "startReview");
      assert.deepEqual(got, want, JSON.stringify(o));
      assert.deepEqual(b.log, a.log, `${JSON.stringify(o)}: what the sweep asked of the hub`);
    } finally {
      net.mock.restore();
    }
  }
});

/// What the TypeScript set going without waiting for it (a sweep, a notice to another station) run to its end: the turns
/// of the loop it takes, its fakes answering at once, until the hub's record stops growing.
async function quiet(log: Json[]) {
  let still = 0;
  let seen = -1;
  while (still < 20) {
    await new Promise((r) => setImmediate(r));
    if (log.length === seen) still++;
    else {
      seen = log.length;
      still = 0;
    }
  }
}

// ── presets: what a chat starts knowing ───────────────────────────────────────────────────────────────────────────

test("presets: records as both sides keep them, a preset's words and refusals", { skip }, async () => {
  const live = (o: Json) => ({ id: "a1", name: "A", dirs: [{ path: "/p", repo: null, station: "W/S1" }], instructions: "", createdBy: "x@y", createdAt: 1, updatedAt: 5, owner: "sub1", rev: 2, home: "S1", ...o });
  const gone = (o: Json) => ({ id: "a1", owner: "sub1", rev: 2, gone: true, updatedAt: 5, ...o });
  for (const [a, b] of [[live({}), live({ rev: 3 })], [live({}), gone({})], [live({ updatedAt: 9 }), live({})], [live({ name: "B" }), live({ name: "C" })], [gone({ updatedAt: 1 }), gone({ updatedAt: 2 })]]) {
    await same("newerRecord", () => newerRecord(a as Json, b as Json), a, b);
  }
  for (const v of [{ b: [1, { z: null, a: "é" }], a: true, "10": 1, "2": 2 }, [undefined, 1.5, "x"], "s", 3, null]) await same("canonical", () => canonical(v), v);
  const many = Array.from({ length: 205 }, (_, i) => gone({ id: `g${i}`, owner: i % 2 ? "o1" : "o1", updatedAt: i % 7, rev: (i % 3) + 1 }));
  for (const g of [[gone({})], many, [...many, gone({ id: "x", owner: "" })]]) await same("goneKept", () => goneKept(g as Json), g);
  const records = Object.fromEntries(many.map((g) => [g.id, g]));
  await same("recordsKept", () => recordsKept({ ...records, live: live({ id: "live" }) } as Json), { ...records, live: live({ id: "live" }) });
  for (const m of [undefined, null, "x", { model: " " }, { model: " m ", runtime: " codex ", effort: "", fast: true, speed: "fast", context: 200000, profile: " p ", profiles: [" a ", "a", "", 3, "b"] }, { model: "m", context: 1.5, speed: "warp" }]) {
    await same("modelOf", () => modelOf(m), m);
  }
  for (const o of [{}, { stations: [" a ", "a"] }, { stations: ["a", "b"] }, { stations: [] }, { station: " s " }, { autoStation: true }, { stations: "x", station: "y" }]) await same("stationsOf", () => stationsOf(o), o);
  const raws: Json[] = [
    live({}), gone({}), null, [], { ...live({}), id: "bad id" }, { ...live({}), owner: 3 }, { ...live({}), rev: 0 }, { ...live({}), updatedAt: -1 },
    { ...live({}), name: " " }, { ...live({}), name: "n".repeat(61) }, { ...live({}), instructions: "i".repeat(20_001) }, { ...live({}), dirs: "x" },
    { ...live({}), dirs: [{ path: "" }] }, { ...live({}), dirs: [{ path: "/a" }] }, { ...live({}), dirs: [{ path: "/a", station: "s", repo: "" }, { path: "/a", station: "s" }] },
    { ...live({}), dirs: Array.from({ length: 21 }, (_, i) => ({ path: `/d${i}`, station: "s" })) }, { ...live({}), createdAt: undefined }, { ...live({}), createdAt: 1.5 },
    { ...live({}), home: "" }, { ...live({}), stations: ["x", "y"], model: { model: "m" }, createdBy: undefined },
  ];
  for (const r of raws) await same("recordOf", () => recordOf(r), r);
  for (const lang of ["zh", "en"] as const) {
    for (const [p, here, asked] of [
      [{ name: "P", model: { model: "m", runtime: "codex" } }, "S1", { runtime: "codex", model: "m" }],
      [{ name: "P", model: { model: "m", runtime: "codex" } }, "S1", { runtime: "claude", model: "m" }],
      [{ name: "P", model: { model: "m" } }, null, { runtime: "claude", model: "n" }],
      [{ name: "P", station: "W/S2" }, "S1", { runtime: "codex", model: null }],
      [{ name: "P", stations: ["W/S2", "S1"] }, "S1", { runtime: "codex", model: null }],
      [{ name: "P", stations: ["W/S2"] }, null, { runtime: "codex", model: null }],
    ] as [Json, string | null, Json][]) {
      await same("presetRefusal", () => presetRefusal(p, here, asked, lang), p, here, asked, lang);
    }
  }
  for (const config of ['[core]\n[remote "origin"]\n\turl = git@github.com:o/r.git\n', '[remote "origin"]\nurl=https://github.com/o/r.git/\n', '[remote "up"]\nurl = x\n', '[remote "origin"]\n  fetch = +refs\n  url = ssh://git@host:22/o/r\n', '[remote "origin"]\nurl =   \n']) {
    await same("originIn", () => originIn(config), config);
  }
  for (const url of ["git@github.com:o/r.git", "https://github.com/o/r.git", "https://u:p@gitlab.com/g/s/r/", "git+ssh://git@x.org/a/b.git", "file:///tmp/x", "plain/path", " git@h:x "]) await same("repoName", () => repoName(url), url);
  const copies: Json[] = [
    { id: "p", name: "Kit", dirs: [], instructions: "" },
    { id: "p", name: "Kit", dirs: [{ path: "/a", repo: "github.com/o/r" }, { path: "/b", repo: null, elsewhere: "Far" }, { path: "/c", repo: "github.com/o/c", elsewhere: "Far", skills: ["s1"] }, { path: "/d", repo: null, skills: ["s2", "s3"], guides: [{ file: "AGENTS.md", text: "be good", whole: true }, { file: "CLAUDE.md", text: "long", whole: false }] }], instructions: "people's words" },
  ];
  for (const c of copies) await same("presetInstructions", () => presetInstructions(c), c);
  for (const v of [null, { name: "" }, { name: "n".repeat(61) }, { id: "i", name: " Copy ", dirs: [{ path: "/a", station: "s", stationName: "n", guides: [], skills: [], elsewhere: "E" }, { nope: 1 }], instructions: "x".repeat(20_005), model: { model: "m" }, stations: ["s1"] }, { name: "N", stations: ["a", "b"] }, { name: "N", stations: [] }]) {
    await same("presetCopyInput", () => presetCopyInput(v), v);
  }
});

/// A presets.json, as written by a station from before and by this one.
const PRESETS_FILE = {
  presets: [
    { id: "old", name: "Old", dirs: [{ path: "/repo", repo: "github.com/o/r" }], instructions: "x", createdBy: "ann@x.com", createdAt: 1, updatedAt: 2 },
    { id: "theirs", name: "Theirs", dirs: [{ path: "/t", repo: null, station: "W1/S2", stationName: "Two" }], instructions: "", createdBy: "bob@x.com", createdAt: 1, updatedAt: 3, owner: "bob", rev: 4, home: "S2", models: { lead: { model: "gpt-6" } } },
    { id: "mine", name: "Mine", dirs: [], instructions: "", createdBy: "ann@x.com", createdAt: 1, updatedAt: 3, owner: "ann", rev: 2, home: "S1", stations: ["W1/S1", "W1/S3"] },
    { id: "100", name: "Number", dirs: [], instructions: "", owner: "ann", rev: 1, home: "S1" },
    { name: "no id" },
  ],
  gone: [{ id: "was", owner: "", rev: 3, gone: true, updatedAt: 9 }, { id: "bad", gone: true }],
};

test("presets: the file a workspace keeps them in, changed by an app from before and carried by a device", { skip }, async () => {
  const dirs = fresh("presets-dirs-");
  await mkdir(join(dirs, "plain"), { recursive: true });
  await mkdir(join(dirs, "clone", ".git"), { recursive: true });
  await writeFile(join(dirs, "clone", ".git", "config"), '[remote "origin"]\n\turl = git@github.com:o/clone.git\n');
  await mkdir(join(dirs, "clone", ".git", "worktrees", "wt"), { recursive: true });
  await mkdir(join(dirs, "wt"), { recursive: true });
  await writeFile(join(dirs, "wt", ".git"), `gitdir: ${join(dirs, "clone", ".git", "worktrees", "wt")}\n`);
  const ann = { sub: "ann", email: "Ann@x.com" };
  const nobody = { sub: "", email: "z@x.com" };
  const ops: [string, Json[]][] = [
    ["presets.list", [null]], ["presets.listed", [null]], ["presets.get", [null, "mine"]], ["presets.get", [null, "nope"]],
    ["presets.kept", [null, ann]], ["presets.others", [null, ann]], ["presets.kept", [null, nobody]],
    ["presets.add", [null, { name: " New ", dirs: [join(dirs, "plain"), { path: join(dirs, "clone") }, join(dirs, "plain"), { path: "/far", station: "W1/S2", stationName: "Two", repo: "r" }], instructions: " do ", stations: ["W1/S1"], model: { model: "gpt-6" } }, "ann@x.com", "ann"]],
    ["presets.add", [null, { name: "" }, "ann@x.com", ""]],
    ["presets.add", [null, { name: "Bad", dirs: ["/no/such/dir/at/all"] }, "a", ""]],
    ["presets.add", [null, { name: "Bad", dirs: [""] }, "a", ""]],
    ["presets.add", [null, { name: "WT", dirs: [join(dirs, "wt"), "~"] }, "a", ""]],
    ["presets.put", [null, "old", { name: "Old renamed" }, ann]],
    ["presets.put", [null, "theirs", { name: "T2", dirs: ["/no/such"] }, ann]],
    ["presets.put", [null, "nope", { name: "x" }]],
    ["presets.delete", [null, "100", ann]],
    ["presets.delete", [null, "nope"]],
    ["presets.carry", [null, ann, [
      { id: "mine", name: "Mine 2", dirs: [], instructions: "", owner: "ann", rev: 3, updatedAt: 10, home: "S1" },
      { id: "theirs", name: "x", owner: "ann", rev: 9, updatedAt: 1, home: "S1" },
      { id: "fresh", name: "Fresh", owner: "ann", rev: 1, updatedAt: 1, home: "S9", dirs: [{ path: "/f", station: "W1/S9" }] },
      { id: "fresh", name: "Fresh", owner: "ann", rev: 1, updatedAt: 1, home: "S9", dirs: [{ path: "/f", station: "W1/S9" }] },
      { id: "x", owner: "bob", rev: 1, updatedAt: 1, name: "B", home: "S1" },
      { id: "bad id" },
      { id: "was", owner: "ann", rev: 1, gone: true, updatedAt: 1 },
      { id: "old", name: "Old", owner: "ann", rev: 5, updatedAt: 1, home: "S1" },
    ]]],
    ["presets.carry", [null, nobody, [{ id: "y", name: "Y", owner: "", rev: 1, updatedAt: 1, home: "S1" }]]],
    ["presets.kept", [null, ann]],
    ["presets.carry", [null, ann, Array.from({ length: 3 }, (_, i) => ({ id: `g${i}`, owner: "ann", rev: 1, gone: true, updatedAt: i }))]],
    ["presets.record", [null, { id: "r", name: "R", dirs: [{ path: "/a", repo: null }, { path: "/b", repo: "x", station: "W/S5" }], instructions: "", autoStation: true, model: { model: "m" }, createdBy: "", createdAt: 0, updatedAt: 0, owner: "", rev: 1, home: "S1" }]],
    ["presets.isHere", ["W1/S1"]], ["presets.isHere", ["S2"]], ["presets.nameOf", ["W1/S2", "Said"]], ["presets.nameOf", ["W1/S7"]],
  ];
  const homeA = fresh("presets-a-");
  const homeB = fresh("presets-b-");
  for (const h of [homeA, homeB]) await writeFile(join(h, "presets.json"), JSON.stringify(PRESETS_FILE));
  let clock = 1_000;
  const place = { station: () => "S1", workspace: (ws: string | null) => ws ?? "W1", stationName: (id: string) => (id === "S2" ? "Two (known)" : null) };
  const ts = new Presets(() => homeA, () => clock, place);
  for (const [op, args] of ops) {
    clock += 1;
    const method = op.slice("presets.".length);
    const want = unrandom(await settledTs(() => (ts as Json)[method](...args)));
    const b = mbHub({ props: { presets: { home: () => homeB, now: () => clock, ...place } } });
    const got = unrandom(await mbWorld(b.answer, op, ...args));
    assert.deepEqual(got, want, `${op}(${JSON.stringify(args).slice(0, 120)})`);
    assert.equal(unrandom(await readFile(join(homeB, "presets.json"), "utf8")), unrandom(await readFile(join(homeA, "presets.json"), "utf8")), `${op}: presets.json`);
  }
  const noStation = new Presets(() => homeA, () => clock);
  const want = await settledTs(() => noStation.kept(null, ann));
  const got = await mbWorld(mbHub({ props: { presets: { home: () => homeB, now: () => clock, station: () => null } } }).answer, "presets.kept", null, ann);
  assert.deepEqual(unrandom(got), unrandom(want));
  for (const home of [homeA, join(dirs, "none")]) await sameWorld("readPresetsFile", () => ({}), () => readPresetsFile(home, "S1"), home, "S1");
  for (const path of [join(dirs, "clone"), join(dirs, "wt"), join(dirs, "plain")]) await sameWorld("originOf", () => ({}), () => originOf(path), path);
  for (const path of [homedir(), join(homedir(), "x"), "/elsewhere"]) await sameWorld("shortPath", () => ({}), () => shortPath(path), path);
});

test("presets: what a chat opened with one keeps, its folders' instructions and skills", { skip }, async () => {
  const src = fresh("presets-src-");
  const repo = join(src, "repo");
  await mkdir(join(repo, ".claude", "skills", "build"), { recursive: true });
  await writeFile(join(repo, ".claude", "skills", "build", "SKILL.md"), "build");
  await mkdir(join(repo, ".agents", "skills", "build"), { recursive: true });
  await writeFile(join(repo, ".agents", "skills", "build", "SKILL.md"), "build again");
  await mkdir(join(repo, ".agents", "skills", "noskill"), { recursive: true });
  await writeFile(join(repo, "AGENTS.md"), "  Be careful.\n\n");
  await writeFile(join(repo, "CLAUDE.md"), "é".repeat(9000));
  await mkdir(join(repo, ".claude"), { recursive: true });
  await writeFile(join(repo, ".claude", "CLAUDE.md"), "short");
  const other = join(src, "other");
  await mkdir(join(other, ".claude", "skills", "build"), { recursive: true });
  await writeFile(join(other, ".claude", "skills", "build", "SKILL.md"), "other build");
  const copy = { id: "p", name: "Kit", dirs: [{ path: repo, repo: "github.com/o/r" }, { path: "/far", repo: null, elsewhere: "Far" }, { path: other, repo: null }, { path: join(src, "missing"), repo: null }], instructions: "x" };
  const wsA = fresh("presets-ws-a-");
  const wsB = fresh("presets-ws-b-");
  const want = await settledTs(() => keepCopy(wsA, copy as Json));
  const got = await mbWorld(mbHub({}).answer, "keepCopy", wsB, copy);
  assert.deepEqual(got, want);
  assert.equal(await readFile(join(wsB, ".stillfail-preset.json"), "utf8"), await readFile(join(wsA, ".stillfail-preset.json"), "utf8"));
  assert.deepEqual((await readdir(join(wsB, ".claude", "skills"))).sort(), (await readdir(join(wsA, ".claude", "skills"))).sort());
  for (const ws of [wsA, fresh("presets-ws-none-")]) await sameWorld("presetCopyOf", () => ({}), () => presetCopyOf(ws), ws);
  const homeA = fresh("presets-keep-a-");
  const homeB = fresh("presets-keep-b-");
  for (const h of [homeA, homeB]) await writeFile(join(h, "presets.json"), JSON.stringify({ presets: [{ id: "k", name: "K", dirs: [{ path: repo, repo: null, station: "W1/S1" }, { path: "/t", repo: null, station: "W1/S2", stationName: "Two" }, { path: "/u", repo: null, station: "S9" }], instructions: "i", owner: "a", rev: 1, home: "S1" }] }));
  const place = { station: () => "S1", stationName: (id: string) => (id === "S2" ? "Two (known)" : null) };
  const wantKeep = await settledTs(() => new Presets(() => homeA, () => 1, place).keepFor(fresh("presets-kf-a-"), null, "k"));
  const gotKeep = await mbWorld(mbHub({ props: { presets: { home: () => homeB, now: () => 1, ...place } } }).answer, "presets.keepFor", fresh("presets-kf-b-"), null, "k");
  assert.deepEqual(gotKeep, wantKeep);
});

test("presets: the folders offered for a new preset, a repository's picture, and the machine's repositories", { skip }, async () => {
  const root = fresh("presets-repos-");
  const repos = join(root, "repos");
  const mk = async (name: string, origin: string | null, worktrees: string[] = []) => {
    await mkdir(join(repos, name, ".git"), { recursive: true });
    if (origin !== null) await writeFile(join(repos, name, ".git", "config"), `[remote "origin"]\n\turl = ${origin}\n`);
    for (const [i, w] of worktrees.entries()) {
      await mkdir(join(repos, name, ".git", "worktrees", `w${i}`), { recursive: true });
      await writeFile(join(repos, name, ".git", "worktrees", `w${i}`, "gitdir"), w);
    }
  };
  await mk("alpha", "git@github.com:o/alpha.git", ["/data/sessions/chat/k1/workspace/alpha/.git", "/data/sessions/chat/k2/workspace/alpha/.git", "/data/sessions/chat/k1/workspace/b/.git"]);
  await mk("beta", null);
  await mk("Gamma", "https://github.com/o/gamma");
  await mkdir(join(repos, ".cloning"), { recursive: true });
  await writeFile(join(repos, "file"), "x");
  await writeFile(join(repos, "alpha", "logo.png"), Buffer.from("png-bytes"));
  await mkdir(join(repos, "alpha", "public"), { recursive: true });
  await writeFile(join(repos, "alpha", "public", "apple-touch-icon@2x.png"), Buffer.from("touch"));
  await writeFile(join(repos, "alpha", "icon-huge.png"), Buffer.alloc(30_000));
  await writeFile(join(repos, "alpha", "favicon.ico"), Buffer.from("ico"));
  await mkdir(join(repos, "beta", "docs"), { recursive: true });
  await writeFile(join(repos, "beta", "docs", "logo.jpeg"), Buffer.from("jpeg"));
  const found = [{ path: join(root, "mine", "gamma"), name: "gamma", repo: "github.com/o/gamma", chats: 1, lastAt: 5 }, { path: "/x/delta", name: "delta", repo: null, chats: 0, lastAt: 1, icon: "data:image/png;base64,AA" }];
  const presets = [{ updatedAt: 7, dirs: [{ path: "/p/zeta", repo: "github.com/o/zeta" }, { path: "/far", repo: null, station: "W1/S2" }, { path: "/near", repo: null, station: "W1/S1" }, { path: join(repos, "beta"), repo: null }] }];
  const want = await settledTs(() => presetCandidates(repos, presets as Json, found as Json, (s) => s.endsWith("/S1")));
  const got = await mbWorld(mbHub({ deps: STATION_DEPS }).answer, "candidates", repos, presets, found, ["W1/S1"]);
  assert.deepEqual(got, want);
  for (const r of [join(repos, "alpha"), join(repos, "beta"), join(repos, "Gamma")]) await sameWorld("repoIcon", () => ({}), () => repoIcon(r), r);
  const home = join(root, "home");
  await mkdir(join(home, "code", "one", ".git"), { recursive: true });
  await writeFile(join(home, "code", "one", ".git", "config"), '[remote "origin"]\n\turl = git@github.com:o/one.git\n');
  await writeFile(join(home, "code", "one", ".git", "index"), "i");
  await mkdir(join(home, "code", "node_modules", "x", ".git"), { recursive: true });
  await mkdir(join(home, "a", "b", "c", "d", "e", ".git"), { recursive: true });
  await mkdir(join(home, "a", "b", "two", ".git"), { recursive: true });
  await mkdir(join(home, ".hidden", "r", ".git"), { recursive: true });
  await mkdir(join(home, "Documents", "r", ".git"), { recursive: true });
  await mkdir(join(home, "guarded", "r", ".git"), { recursive: true });
  await mkdir(join(home, "data", "r", ".git"), { recursive: true });
  const fileA = join(root, "index-a.json");
  const fileB = join(root, "index-b.json");
  let now = 1_000_000;
  const options = (file: string) => ({ roots: () => [home], file: () => file, now: () => now, besides: () => [join(home, "data")], guarded: (d: string) => d.endsWith("/guarded") });
  const index = new RepoIndex(options(fileA));
  const list = async (d: string) => (await readdir(d, { withFileTypes: true })).map((e) => ({ name: e.name, isDirectory: e.isDirectory() }));
  const mbIndex = { ...options(fileB), list };
  await mbWorld(mbHub({}).answer, "repoIndex.reset");
  for (const step of [0, 1, 2]) {
    if (step === 2) now += 11 * 60 * 1000;
    const wantRepos = await index.repos();
    await index.walk();
    const b = mbHub({ props: { repoIndex: mbIndex } });
    const gotRepos = await mbWorld(b.answer, "repoIndex.repos");
    assert.deepEqual(gotRepos.ok.repos, wantRepos, `step ${step}`);
    if (gotRepos.ok.due) await mbWorld(b.answer, "repoIndex.walk");
    assert.deepEqual(JSON.parse(await readFile(fileB, "utf8")), JSON.parse(await readFile(fileA, "utf8")), `step ${step}: the index kept`);
  }
});

// ── title-completion and regenerate-title: a chat's title asked anew ──────────────────────────────────────────────

/// A profile as the accounts give one (with its spelling of a model).
const runOn = (p: Json) => ({ ...p, spelling(model: string) { return spelling(p, model); } });

const TITLE_PROFILES: Json[] = [
  { id: "ds", access: { kind: "api-provider", provider: "deepseek", key: "dk" }, runtimes: ["dsh"], models: ["deepseek-v4-pro", "deepseek-v4-flash"], home: "/h" },
  { id: "go", access: { kind: "opencode-go", key: "gk" }, runtimes: ["claude", "codex", "dsh", "pi"], models: ["qwen-3-flash"], model: "qwen-3-flash", home: "/h" },
  { id: "anth", access: { kind: "anthropic-api", key: "ak" }, runtimes: ["claude", "dsh", "pi"], models: [], home: "/h" },
  { id: "or", access: { kind: "api-provider", provider: "openrouter", key: "none" }, runtimes: ["claude", "dsh"], models: ["openai/gpt-6"], home: "/h" },
  { id: "codex", runtime: "codex", runtimes: ["codex"], models: ["gpt-6"], home: "/h" },
  { id: "plain", runtime: "claude", runtimes: ["claude"], models: [], home: "/h" },
];

test("title-completion: which profiles answer a title themselves, and what is asked of them", { skip }, async () => {
  for (const p of TITLE_PROFILES) {
    for (const model of [null, "deepseek-v4-flash", "gpt-6", ""]) {
      await sameWorld("titleCompletion", () => ({ deps: STATION_DEPS }), () => titleCompletion(runOn(p) as Json, model, "chat:c-1"), p, model, "chat:c-1");
    }
  }
  const config = { endpoint: "https://api.deepseek.com/chat/completions", key: "dk", model: "deepseek-v4-flash", headers: { "x-opencode-session": "stillfail-k" } };
  const answers: { status?: number; body: string }[] = [
    { body: JSON.stringify({ choices: [{ message: { content: "Build fix" } }] }) },
    { body: JSON.stringify({ choices: [{ message: { content: "x", tool_calls: [{}] } }] }) },
    { body: JSON.stringify({ choices: [{ message: { content: null } }] }) },
    { status: 401, body: "no" },
    { body: "x".repeat(256_001) },
  ];
  for (const a of answers) {
    for (const c of [config, { ...config, key: "" }]) {
      let log: Json[] = [];
      const net = netOf(() => log, () => a);
      try {
        const want = await settledTs(() => completeTitle(c, "instructions", "input", new AbortController().signal));
        const wantLog = log;
        log = [];
        const got = await mbWorld(mbHub({}).answer, "completeTitle", c, "instructions", "input");
        assert.deepEqual(got, want);
        assert.deepEqual(log, wantLog);
      } finally {
        net.mock.restore();
      }
    }
  }
});

test("regenerate-title: a new title from a text-only session of one of the chat's agents", { skip }, async () => {
  const rows = (list: Json[]) => list.map((r) => ({ key: "chat:c-1", model: null, runtime: "codex", archivedAt: null, workspace: "/w", cwd: null, effort: null, profile: "codex", ...r }));
  const world = (o: Json) => (mb: boolean): World => {
    void mb;
    let revision = 1;
    const agent = (events: (e: Json) => void) => ({
      busy: () => o.busy ?? false,
      abort: async () => {},
      dispose: async () => {},
      prompt: async () => {
        const emit = () => {
          for (const e of o.events ?? [
            { type: "live", event: { kind: "start", step: "text", id: "t1" } },
            { type: "live", event: { kind: "delta", field: "text", id: "t1", text: "“Fix the " } },
            { type: "live", event: { kind: "delta", field: "text", id: "t1", text: "build”" } },
            { type: "turnEnded", outcome: { kind: "completed" } },
          ]) events(e);
        };
        if (o.later) setImmediate(emit);
        else emit();
      },
    });
    return {
      store: {
        getThread: () => (o.gone ? null : { id: 7 }),
        titleRevision: () => (o.revised ? revision++ : revision),
        messagesBefore: () => o.messages ?? [{ authorKind: "person", text: "please fix the build" }, { authorKind: "agent", text: "on it" }, { authorKind: "ember", text: "notice" }, { authorKind: "person", text: "  " }],
        firstText: () => "please fix the build",
        setGeneratedTitle: () => {},
      },
      hub: o.latest ? { latestMessages: async () => [{ authorKind: "agent", text: "from the reader" }] } : {},
      props: {
        accounts: { profile: (id: string) => (o.noProfile === id ? null : runOn(TITLE_PROFILES.find((p) => p.id === id) ?? TITLE_PROFILES[4])), allows: () => o.allows ?? true },
        drivers: new Map(Object.entries(o.drivers ?? { codex: { open: async (_opts: Json, events: (e: Json) => void) => agent(events) }, claude: { open: async (_opts: Json, events: (e: Json) => void) => agent(events) } })),
      },
      deps: STATION_DEPS,
    };
  };
  const cases: [Json, Json[]][] = [
    [{}, rows([{}])],
    [{ later: true }, rows([{}])],
    [{}, rows([{ runtime: "claude", profile: "plain", model: "claude-x" }])],
    [{}, []],
    [{ noProfile: "codex" }, rows([{}])],
    [{ allows: false }, rows([{}])],
    [{}, rows([{ archivedAt: 5 }])],
    [{}, rows([{ runtime: "dsh", profile: "plain" }])],
    [{ drivers: {} }, rows([{}])],
    [{ gone: true }, rows([{}])],
    [{ messages: [] }, rows([{}])],
    [{ latest: true }, rows([{}])],
    [{ revised: true }, rows([{}])],
    [{ events: [{ type: "live", event: { kind: "start", step: "tool", id: "x" } }, { type: "turnEnded", outcome: { kind: "completed" } }] }, rows([{}])],
    [{ events: [{ type: "turnEnded", outcome: { kind: "failed" } }] }, rows([{}])],
    [{ events: [{ type: "closed" }] }, rows([{}])],
    [{ events: [{ type: "live", event: { kind: "start", step: "text", id: "t1" } }, { type: "live", event: { kind: "delta", field: "text", id: "t1", text: "two\nlines" } }, { type: "turnEnded", outcome: { kind: "completed" } }] }, rows([{}])],
    [{ events: [{ type: "live", event: { kind: "start", step: "text", id: "s", subagent: true } }, { type: "live", event: { kind: "delta", field: "text", id: "s", text: "sub" } }, { type: "turnEnded", outcome: { kind: "completed" } }] }, rows([{}])],
  ];
  for (const [o, members] of cases) {
    const make = world(o);
    const a = tsHub(make(false));
    const want = unrandom(await settledTs(() => regenerateTitle(a.hub, 7, members)));
    const b = mbHub(make(true));
    const got = unrandom(await mbWorld(b.answer, "regenerateTitle", 7, members));
    assert.deepEqual(got, want, JSON.stringify(o));
    assert.deepEqual(unrandom(b.log), unrandom(a.log), `${JSON.stringify(o)}: what was asked of the hub`);
  }
  let log: Json[] = [];
  const net = netOf(() => log, () => ({ body: JSON.stringify({ choices: [{ message: { content: "「Deep title」" } }] }) }));
  try {
    const members = rows([{ runtime: "dsh", profile: "ds", model: "deepseek-v4-flash" }]);
    const want = await settledTs(() => regenerateTitle(tsHub(world({})(false)).hub, 7, members));
    const wantLog = log;
    log = [];
    const got = await mbWorld(mbHub(world({})(true)).answer, "regenerateTitle", 7, members);
    assert.deepEqual(got, want);
    assert.deepEqual(log, wantLog);
  } finally {
    net.mock.restore();
  }
});

// ── what is left: a letter's header, the arguments chat_post reads, a turn's end told, the post blocks ────────────

test("the rest: headers, arguments, notices and what a delivery waits for", { skip }, async () => {
  for (const lang of ["zh", "en"] as const) {
    setStationLang(lang);
    await mbLang(lang);
    for (const [surface, opened, led] of [["ember", false, null], ["ember", true, true], ["slack:T", true, false], ["ember", true, null]] as [string, boolean, boolean | null][]) {
      await same("header", () => headerOf(surface, "Lead [chat]", "https://x/l", opened, led), surface, "Lead [chat]", "https://x/l", opened, led);
    }
  }
  setStationLang("zh");
  await mbLang("zh");
  for (const v of [5, "5", " -2.5e3 ", "+.5", "1.", "inf", "-Infinity", "NaN", "0x10", "", "1e", ".", null, true, [], "007"]) {
    await same("jsNumber", () => { const n = jsNumber(v); return n === null ? null : Number.isNaN(n) ? "NaN" : !Number.isFinite(n) ? (n > 0 ? "Infinity" : "-Infinity") : n; }, v);
  }
  for (const v of ["s", null, 3, { a: 1 }, [1, "x"], true]) await same("jsString", () => jsString(v), v);
  for (const k of [{ kind: "all_done" }, { kind: "need_help" }, { kind: "waiting", seconds: 3 }]) {
    await same("declaredStr", () => declaredStr(k as Json), k);
    await same("saidAs", () => saidAs(k as Json), k);
  }
  for (const a of [{}, { about: null }, { about: " 1.2 " }, { about: 3 }, { about: "  " }]) await same("aboutTs", () => aboutTs(a), a);
  for (const [title, link, state, words, led] of [["T", "https://x", "all_done", "fine", true], ["T", null, "need_human", "", true], ["T", null, "failed", "boom", null], ["T", "l", "stopped", null, false], ["T", null, "need_human", "decide", false]] as Json[]) {
    await same("notice", () => openedNotice(title, link, state, words, led), title, link, state, words, led);
  }
  const deliveries = [[{ thread: 1, n: 5 }, { thread: 2, n: 3 }, { thread: 1, n: 2 }], []];
  for (const d of deliveries) await same("postBlockThreads", () => [...postBlockThreads(d)], d);
  for (const [complete, cursor, after] of [[true, null, 3], [false, null, 3], [false, 4, 3], [false, 5, 3], [false, 2, 3]] as [boolean, number | null, number][]) {
    await same("postBlockAnswered", () => complete || (cursor !== null && !(cursor > after + 1)), complete, cursor, after);
  }
});

/// messages.ts's header of a letter (not exported: the first line of what `postFrom` keeps).
function headerOf(surface: string, title: string, link: string | null, opened: boolean, led: boolean | null): string {
  const key = !opened ? "station.session.from" : led === true ? "station.session.ledBy" : led === false ? "station.session.openedForYou" : "station.session.openedBy";
  return tr(stationLang(), key, { from: chatNamed(surface, title, link) });
}

/// opened.ts's notice to an opener (not exported: what `settled` tells it).
function openedNotice(title: string, link: string | null, state: string, words: string | null, led: boolean | null): string {
  const chat = link !== null ? `"${title}" (${link})` : `"${title}"`;
  const said = words !== null && words !== "" ? `: ${words}` : "";
  if (led === true) {
    const ended = state === "need_human" ? `asks you${said}. It is yours to decide (session_send it your answer), or to take to your person in your own chat, with what you checked; no person was asked` : state === "failed" ? `stopped with an error${said}` : state === "stopped" ? "was stopped by a person" : `ended its turn all_done${said}`;
    return `The chat you lead, ${chat}, ${ended}. Its words are its claims: check against your goal ledger before you tell anyone, yourself in the code or data any it gives up, finds no gain in or says needs your person, and anything against your person's rules (skill stillfail-leading). Read it with chat_read; write to its agent with session_send to its link.`;
  }
  const ended = state === "need_human" ? `needs a person${said}. They are asked there; help if you can, or wait` : state === "failed" ? `stopped with an error${said}` : state === "stopped" ? "was stopped by a person" : `ended its turn all_done${said}`;
  return `The chat you opened, ${chat}, ${ended}. Read it with chat_read; write to its agent with session_send to its link.`;
}

/// post-block-builder.ts's grouping of a delivery's messages by thread (its `ready`), each from its first.
function postBlockThreads(messages: { thread: number; n: number }[]): [number, number][] {
  const threads = new Map<number, number>();
  for (const message of messages) threads.set(message.thread, Math.min(threads.get(message.thread) ?? message.n, message.n));
  return [...threads];
}
