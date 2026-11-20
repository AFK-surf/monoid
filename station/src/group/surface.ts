// A group connect as a chat surface: the station as a member of an IM community of AFK-surf/group (`im/2`), as it is a
// bot in Slack or Feishu (connects/surface.ts keeps its link up, connected again after a wait that doubles whenever it
// goes). Its link (link.ts) is let in by the connect's key, and by the code it joins with the first time; then the
// anchor's stream (`GET /events`) tells it each event of its spaces as it is taken, and `POST /sync` what each space
// took since the last event taken of it (threads.ts), so nothing is taken twice and nothing said while it was away is
// lost. Every event is checked as the IM's devices check it (event.ts: its id worked out again, its signature its
// device's), and what the station says is an event signed by the connect's key, its device's own count after its last.
//
// A space's stream is a thread (the IM's session keys them so: the space's id for its lobby, `<space>/<topic>`): the
// lobby is `<space>/<space>`, a topic `<space>/<topic>`, each a session of its own (the hub names and groups a chat by
// its channel, the space). A message's ts is its event's place in its space (`aseq`), which every event has, an answer
// to a card too. Every message of a direct space calls the agent; in a space, one that mentions the bot (`@name`),
// answers one of its messages or opens a topic that does, and the rest go to a session that follows that stream already
// (the hub's rule, as Slack's threads: chat_leave stops it until the next mention; the station never leaves the space).
//
// What the IM has for an agent besides words: a card goes as a decision (`decision.ask`, its options or a field), its
// answer (`decision.resolve`) handed to the session as the person's message; while the agent works, what it does is
// the stream's live state (`POST /spaces/<id>/live`, gone once it ends), whose Stop (`stop` on the stream) stops the
// turn; and a secret a member hands it end to end (`im-secret/1` to this device, or the anchor's `secret` in passing)
// reaches the session as a file of its uploads, never in a message's words, a log or what the station keeps.
import { open, readFile, stat } from "node:fs/promises";
import { extname } from "node:path";
import { type KeyObject, createHash, randomBytes } from "node:crypto";
import { type Clock, Effect } from "effect";
import type { CardEnd } from "../connects/card-ends.ts";
import type { BotIdentity } from "../connects/connections.ts";
import { channelKey, personKey } from "../connects/keys.ts";
import type { NameBook } from "../connects/names.ts";
import { type Run, StatusLine } from "../connects/status.ts";
import { ConnectedSurface } from "../connects/surface.ts";
import { accept } from "../mesh/accept.ts";
import type { Connection, Endpoints } from "../mesh/endpoint.ts";
import { Reader, writeLine } from "../mesh/wire.ts";
import { wall } from "../ops/fibers.ts";
import { stationLang, tr } from "../ops/i18n.ts";
import { log } from "../ops/log.ts";
import { type ChatMessage, type Handler, type InboundFile, type Member, type Person, type Place, type ThreadRef, splitForSlack } from "../sessions/chat.ts";
import type { Attachment } from "../store/store.ts";
import { Hlc, LOBBY, type Stamped, deviceOfKey, eventId, signEvent, signingKey, stampedOf } from "./event.ts";
import { GroupLink, GroupUnreached, SseLines } from "./link.ts";
import type { GroupThreads } from "./threads.ts";

type Json = any;

/// A file a message carries, as the anchor keeps it (store.mbt `FileRef`).
export type FileRef = { sha256: string; name: string; mime: string; size: number; width?: number; height?: number };
/// A message (a post, or a decision asked) as the station heard it.
type Said = { id: string; space: string; topic: string; aseq: number; kind: string; author: string; text: string; files: FileRef[]; replyTo: string; deleted: boolean };
type Space = { id: string; kind: "direct" | "space"; name: string; members: string[] };
type Topic = { title: string; by: string; branchedFrom: string };

/// The longest words of one message, in characters (the anchor's `text_most` counts UTF-16 units: 20,000, so a part of
/// 10,000 characters, two units each at most, always fits).
const CHARS_MOST = 10_000;
/// The most files one message carries (the anchor's `files_most`).
const FILES_MOST = 10;
/// The largest file an anchor takes (512 MiB, its `file_most`): a larger one is refused here before it is read.
export const FILE_MOST = 512 * 1024 * 1024;
/// A file larger than this goes a piece of this at a time (`im/2` wave 4): its SHA-256 worked out as it is read, then
/// put from what the anchor has of it already on, so neither side holds more of it than a piece.
export const PIECE = 1024 * 1024;
/// The largest file an anchor from before pieces takes, whole in one ask.
const WHOLE_MOST = 32 * 1024 * 1024;
/// How much of a file's head is read for a picture's size.
const HEAD = 256 * 1024;
/// So many answers in a row that take nothing more of a file before it is given up.
const STALLED_MOST = 3;
/// A topic's title, at most (the anchor's `space_name_most`).
const TITLE_MOST = 60;
/// The most options a decision has, and the longest its label, the line under it, a field's hint and a live state's
/// words are (the anchor's `options_most`, `option_most`; its live state's 200).
const OPTIONS_MOST = 8;
const OPTION_MOST = 200;
const LIVE_MOST = 200;
/// So many of a stream's last messages are kept in memory (history and quotes answered without asking the anchor).
const TAIL_MOST = 200;
/// The most pages of a space's events a history read asks of the anchor (500 events each).
const HISTORY_PAGES = 40;
/// The control stream's ping: how often, and how long it may go unanswered before the link is taken for dead.
const PING_MS = 15_000;
const STALE_MS = 45_000;
/// How often a live state still shown is said again: the anchor lets one go 90 s after it was last said.
const LIVE_AGAIN_MS = 60_000;
/// The least time between two changes of a stream's live state.
const LIVE_INTERVAL_MS = 2_000;
/// So many closed decisions are kept to know an answer to one.
const CLOSED_KEPT = 256;
/// So many secrets' ids are kept to know one handed again (by both ways).
const SECRETS_SEEN = 256;

const MIMES: Record<string, string> = {
  ".png": "image/png", ".jpg": "image/jpeg", ".jpeg": "image/jpeg", ".gif": "image/gif", ".webp": "image/webp", ".svg": "image/svg+xml",
  ".pdf": "application/pdf", ".txt": "text/plain", ".md": "text/markdown", ".json": "application/json", ".csv": "text/csv", ".html": "text/html",
  ".mp4": "video/mp4", ".mov": "video/quicktime", ".webm": "video/webm", ".mp3": "audio/mpeg", ".zip": "application/zip",
};
const mimeOf = (name: string) => MIMES[extname(name).toLowerCase()] ?? "application/octet-stream";

const escapeRegExp = (s: string) => s.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");

/// Whether `text` mentions `name` as `@name` (in any case), not as the start of a longer ASCII word.
export function mentions(text: string, name: string): boolean {
  if (name === "") return false;
  return new RegExp(`(^|[^A-Za-z0-9_])@${escapeRegExp(name)}(?![A-Za-z0-9_])`, "iu").test(text);
}

/// A card's question as the words of a message (where the anchor takes no decision): its question, then each option
/// numbered, and how to answer.
export function cardWords(text: string, card: Json, lang = stationLang()): { words: string; options: string[] } {
  const options = card?.type === "options" && Array.isArray(card.options) ? card.options.map((o: Json) => String(o?.label ?? "")).filter((l: string) => l !== "") : [];
  const lines = [text.trimEnd()];
  if (options.length > 0) {
    lines.push("", ...options.map((label: string, i: number) => `${i + 1}. ${label}`), "", tr(lang, "station.group.answerOptions"));
  } else if (card?.type === "text") {
    lines.push("", tr(lang, "station.group.answerText"));
  }
  return { words: lines.join("\n").replace(/^\n+/, ""), options };
}

/// A card as a decision's body (the IM's `decision.ask`): its question, its options (each its label, the line under
/// it and whether it is the one recommended) or a field to type into.
export function decisionBody(text: string, card: Json): Json {
  // (as the anchor takes them: 8 options at most, each label once, a label, a line under it and a hint 200 characters)
  const cut = (s: string) => Array.from(s).slice(0, OPTION_MOST).join("");
  if (card?.type === "text") return { text, input: "text", options: [], placeholder: cut(typeof card.placeholder === "string" ? card.placeholder : ""), files: [] };
  const seen = new Set<string>();
  const options = (Array.isArray(card?.options) ? card.options : [])
    .filter((o: Json) => typeof o?.label === "string" && o.label.trim() !== "")
    .map((o: Json) => ({ ...o, label: cut(o.label) }))
    .filter((o: Json) => !seen.has(o.label) && (seen.add(o.label), true))
    .slice(0, OPTIONS_MOST)
    .map((o: Json) => ({ label: o.label, ...(typeof o.detail === "string" && o.detail !== "" ? { detail: cut(o.detail) } : {}), ...(o.recommended === true ? { recommended: true } : {}) }));
  return { text, input: "options", options, files: [] };
}

/// The thread of a space's stream, and the stream of a thread.
export const threadOf = (space: string, topic: string): ThreadRef => ({ channel: space, threadTs: topic === LOBBY || topic === "" ? space : topic });
export const streamOf = (thread: ThreadRef): { space: string; topic: string } => ({ space: thread.channel, topic: thread.threadTs === thread.channel ? LOBBY : thread.threadTs });
/// A stream's key, as the IM's session says it (session.mbt `stream_of`).
export const streamKey = (space: string, topic: string) => (topic === LOBBY || topic === "" ? space : `${space}/${topic}`);

const filesOf = (v: unknown): FileRef[] =>
  (Array.isArray(v) ? v : []).filter((f) => typeof f?.sha256 === "string" && /^[0-9a-f]{64}$/.test(f.sha256)).map((f) => ({ sha256: f.sha256, name: typeof f.name === "string" ? f.name : "", mime: typeof f.mime === "string" ? f.mime : "", size: typeof f.size === "number" ? f.size : 0, ...(f.width > 0 && f.height > 0 ? { width: f.width, height: f.height } : {}) }));
const text = (v: unknown) => (typeof v === "string" ? v : "");
/// What came of a file put a piece at a time, as the anchor answers it (`{have}`; 0 where it says none).
const haveOf = (body: Buffer): number => {
  try {
    const have = JSON.parse(body.toString())?.have;
    return typeof have === "number" && Number.isSafeInteger(have) && have >= 0 ? have : 0;
  } catch {
    return 0;
  }
};
/// A character the anchor takes in no name (roster.mbt `unseen`): a control or format character, a line or paragraph
/// separator, half of a pair.
const unseen = (v: number) =>
  v < 0x20 || (v >= 0x7f && v <= 0x9f) || v === 0xad || (v >= 0x600 && v <= 0x605) || v === 0x61c || v === 0x6dd || v === 0x70f || v === 0x180e ||
  (v >= 0x200b && v <= 0x200f) || (v >= 0x2028 && v <= 0x202e) || (v >= 0x2060 && v <= 0x2064) || (v >= 0x2066 && v <= 0x206f) || v === 0xfeff ||
  (v >= 0xfff9 && v <= 0xfffb) || (v >= 0xd800 && v <= 0xdfff) || v === 0xe0001 || (v >= 0xe0020 && v <= 0xe007f);
/// A topic's title as the anchor takes one (roster.mbt `name_of`): a control character a space, what else is not seen
/// left out, trimmed, 60 characters at most; "" where nothing is left.
export function topicTitle(title: string): string {
  const kept = Array.from(title).flatMap((c) => {
    const v = c.codePointAt(0)!;
    return v < 0x20 ? [" "] : unseen(v) ? [] : [c];
  });
  const trim = (cs: string[]) => {
    let a = 0;
    let b = cs.length;
    while (a < b && cs[a] === " ") a++;
    while (b > a && cs[b - 1] === " ") b--;
    return cs.slice(a, b);
  };
  return trim(trim(kept).slice(0, TITLE_MOST)).join("");
}

/// What the agent does, as the stream's live state: said to the anchor as it changes (and again while it stands, so
/// the anchor keeps it), taken back ("done") as the turn ends.
class GroupLive extends StatusLine {
  private readonly tell: (status: string, messageTs: string | null) => Promise<boolean>;
  private readonly runs: Run;
  private standing = "";
  private again = false;

  constructor(run: Run, tell: (status: string, messageTs: string | null) => Promise<boolean>) {
    super(run, LIVE_INTERVAL_MS);
    this.runs = run;
    this.tell = tell;
  }

  protected async show(status: string): Promise<boolean> {
    const shown = await this.tell(status, this.messageTs);
    if (shown) this.standing = status;
    if (shown && status !== "" && !this.again) {
      this.again = true;
      const loop: Effect.Effect<void> = Effect.sleep(LIVE_AGAIN_MS).pipe( // timer: a heartbeat that keeps the anchor's live state (its 90 s)
        Effect.andThen(Effect.promise(async () => (this.standing === "" ? false : (await this.tell(this.standing, this.messageTs), true)))),
        Effect.flatMap((more) => (more ? loop : Effect.sync(() => void (this.again = false)))),
      );
      void this.runs(loop).catch(() => {});
    }
    return shown;
  }
}

export type GroupSurfaceOptions = {
  connect: string;
  /// The anchor's endpoint id (64 hex) and its relays; where it is besides (a test's).
  server: string;
  relays: string[];
  ips?: string[];
  /// The connect's key (32 bytes, hex): this device in the community, what its events are signed by.
  key: string;
  /// The code it joins by (an invitation, a device code) while it has not; null once it has.
  code: string | null;
  /// The name it joins as, and is renamed to where the anchor has another.
  botName: string | null;
  threads: GroupThreads;
  book?: NameBook | null;
  /// What binds its endpoint: the station's mesh addon (tests: a mesh in memory).
  endpoints: Endpoints;
  clock?: Clock.Clock;
  pingMs?: number;
  staleMs?: number;
  backoffMs?: number;
  onHeard?: () => void;
  /// 16 hex: a topic's id drawn (tests: one of theirs).
  topicId?: () => string;
};

export class GroupSurface extends ConnectedSurface {
  protected readonly kind = "group";
  readonly connect: string;
  readonly server: string;
  private readonly link: GroupLink;
  private readonly threads: GroupThreads;
  private readonly code: string | null;
  private readonly wanted: string | null;
  private readonly linkPingMs: number;
  private readonly linkStaleMs: number;
  private readonly heardHook: () => void;
  private readonly clockOf: Clock.Clock | undefined;
  private readonly topicId: () => string;
  private readonly key: KeyObject;
  /// This device (the key's public half).
  readonly deviceId: string;
  private readonly hlc = new Hlc();
  /// Whether it was let in since it started: then it says no code again.
  private joined = false;
  /// The spaces it is in, as last heard, and their topics (by `<space>/<topic>`).
  private spaceRows = new Map<string, Space>();
  private topics = new Map<string, Topic>();
  /// Where each space's events were taken to in this run (what the next sync goes on from).
  private cursors = new Map<string, number>();
  /// Spaces first heard of in this run, their events up to the place they had then taken as history (`floor`); of those
  /// first heard of in a sync as a run began (`provisional`), an event the stream then tells at or under it was taken
  /// after the stream opened: new after all.
  private floors = new Map<string, number>();
  private provisional = new Set<string>();
  /// Spaces whose every event this run took, from their first: their streams' tails are their whole.
  private whole = new Set<string>();
  /// Each stream's last messages (`TAIL_MOST`), and each kept message by its id and its place.
  private tails = new Map<string, Said[]>();
  private byId = new Map<string, Said>();
  private byAseq = new Map<string, Said>();
  /// Streams whose tail let messages go.
  private cut = new Set<string>();
  /// The members' names, by id.
  private members = new Map<string, string>();
  /// The decisions it asked that wait (by their event's id), and each stream's card still waiting: its ts, its event and
  /// its options (to read a number said after it). A person's next message there closes it, answered or not
  /// (`answered`), as does its end on the station (`cardEnded`).
  private asks = new Map<string, { stream: string; ts: string }>();
  private asked = new Map<string, { ts: string; id: string; options: string[] }>();
  /// Its decisions closed so (their ids, the last `CLOSED_KEPT`): an answer to one after is no word to the agent.
  private closed = new Set<string>();
  /// Secrets handed it, until the session fetched them (by their file's id), and those already taken.
  private secrets = new Map<string, Buffer>();
  private secretsSeen = new Set<string>();
  /// Events go one at a time, in order (the stream's, a sync's); and what it says, one event at a time.
  private taking: Promise<unknown> = Promise.resolve();
  private saying: Promise<unknown> = Promise.resolve();
  private handler: Handler | null = null;
  private acceptingSecrets = false;

  constructor(options: GroupSurfaceOptions) {
    if (!/^[0-9a-f]{64}$/.test(options.server)) throw new Error("group.server is the IM anchor's endpoint id (64 hex)");
    if (!/^[0-9a-f]{64}$/.test(options.key)) throw new Error("group.key is missing");
    super({ connect: options.connect, book: options.book ?? null, pingMs: options.pingMs ?? PING_MS, staleMs: options.staleMs ?? STALE_MS, backoffMs: options.backoffMs, clock: options.clock, onHeard: options.onHeard });
    this.connect = options.connect;
    this.server = options.server;
    this.threads = options.threads;
    this.code = options.code;
    this.wanted = options.botName;
    this.linkPingMs = options.pingMs ?? PING_MS;
    this.linkStaleMs = options.staleMs ?? STALE_MS;
    this.heardHook = options.onHeard ?? (() => {});
    this.clockOf = options.clock;
    this.topicId = options.topicId ?? (() => randomBytes(8).toString("hex"));
    this.key = signingKey(options.key);
    this.deviceId = deviceOfKey(this.key);
    this.link = new GroupLink({ endpoints: options.endpoints, secretKey: Buffer.from(options.key, "hex"), server: options.server, relays: options.relays, ...(options.ips ? { ips: options.ips } : {}) });
  }

  private now(): number {
    return this.clockOf?.currentTimeMillisUnsafe() ?? wall.now();
  }

  /// This device's endpoint id: what the anchor knows the connect's key by.
  device(): Promise<string> {
    return this.link.device();
  }

  /// Let in: dialled anew (a code said only until it joined), its name set where it was asked for another.
  private async letIn(): Promise<BotIdentity> {
    const hello = !this.joined && this.code !== null ? { credential: this.code, ...(this.wanted !== null ? { name: this.wanted } : {}) } : { credential: "" };
    let me = await this.link.connect(hello);
    this.joined = true;
    if (me.joined) log.info("group", "joined the community", { connect: this.connect, member: me.member });
    if (this.wanted !== null && this.wanted !== me.name) {
      const renamed = await this.link.ask("POST", "/me/name", { name: this.wanted }).catch(() => null);
      if (renamed?.status === 200) me = { ...me, name: this.wanted };
      else log.warn("group", "the bot's name not set on the anchor", { connect: this.connect, status: renamed?.status ?? null });
    }
    return { team: "", teamId: this.server, url: "", botUserId: me.member, botName: me.name, botImage: null, botId: "" };
  }

  protected identify(): Promise<BotIdentity> {
    return this.letIn();
  }

  protected async address(): Promise<string> {
    return this.server;
  }

  /// "@name", as people there write it.
  mention(user: string): string {
    const name = this.members.get(user) ?? this.names.get(user)?.name ?? user;
    return `@${name}`;
  }

  /// Not said: the IM shows a link as its words, and every new session would post one.
  sessionLink(): string | null {
    return null;
  }

  async stop() {
    await super.stop();
    await this.link.close();
  }

  /// `f` after what is being taken, in turn.
  private inTurn<T>(f: () => Promise<T>): Promise<T> {
    const turn = this.taking.then(f);
    this.taking = turn.catch(() => {});
    return turn;
  }

  /// One run of its link: let in again where it went, the anchor's stream opened, what each space took meanwhile
  /// synced, then each event taken in order, the control stream pinged meanwhile. Ends as the stream does; fails (so
  /// its backoff counts) where it could not be opened, or the link stopped answering.
  runSocket(_url: string, handler: Handler): Effect.Effect<void, Error> {
    const self = this;
    this.handler = handler;
    this.acceptSecrets();
    const run = Effect.callback<void, Error>((resume) => {
      let cancel = () => {};
      let over = false;
      void (async () => {
        if (!self.link.open()) {
          const me = await self.letIn();
          if (me.botUserId !== self.me?.botUserId || me.botName !== self.me?.botName) {
            self.me = me;
            self.changed();
          }
        }
        const reply = await self.link.stream("GET", "/events");
        cancel = reply.cancel;
        if (over) return reply.cancel();
        if (reply.status !== 200) {
          reply.cancel();
          throw new GroupUnreached(`the event stream was answered ${reply.status}`);
        }
        await self.readMembers().catch((e) => log.warn("group", "members not read", { connect: self.connect, error: (e as Error).message }));
        // (the stream follows from its answer on: what it tells after is what this sync did not have)
        await self.inTurn(async () => {
          self.provisional.clear();
          await self.sync(handler, true);
        });
        self.setStatus(true, null);
        const sse = new SseLines();
        for await (const chunk of reply.chunks) {
          self.heardHook();
          for (const [event, data] of sse.feed(chunk)) if (event !== "") await self.inTurn(() => self.take(event, data, handler));
        }
        // (ended: dialled again at once, as a socket the platform closed is; the link down fails that, on the backoff)
        self.setStatus(false, null);
      })().then(
        () => resume(Effect.void),
        (e) => resume(Effect.fail(e as Error)),
      );
      return Effect.sync(() => {
        over = true;
        cancel();
      });
    });
    const watch = Effect.forever( // timer: a heartbeat of the link (its ping on the control stream)
      Effect.sleep(this.linkPingMs).pipe(
        Effect.andThen(
          Effect.tryPromise({ try: () => this.link.ping(), catch: (e) => e as Error }).pipe(
            Effect.timeoutOrElse({ duration: this.linkStaleMs, orElse: () => Effect.fail(new GroupUnreached(`the server did not answer for ${this.linkStaleMs / 1000}s`)) }),
          ),
        ),
      ),
    );
    return Effect.raceFirst(run, watch).pipe(Effect.ensuring(Effect.sync(() => this.link.drop("its run ended"))));
  }

  private async readMembers() {
    const answer = await this.link.ask("GET", "/members");
    if (answer.status !== 200) return;
    for (const m of JSON.parse(answer.body.toString())?.members ?? []) this.heardMember(m);
  }

  private heardMember(m: Json) {
    if (typeof m?.id !== "string" || typeof m?.name !== "string") return;
    const known = this.members.get(m.id);
    this.members.set(m.id, m.name);
    this.names.set(m.id, { name: m.name, email: "" });
    if (known !== undefined && known !== m.name) this.book?.person(personKey(this.connect, m.id), async () => ({ name: m.name, email: "" }), (had) => had.name !== m.name);
  }

  /// A space as the anchor says it is now (its row: `space_json`).
  private heardSpace(j: Json): Space | null {
    if (typeof j?.id !== "string") return null;
    const s: Space = { id: j.id, kind: j.kind === "direct" ? "direct" : "space", name: text(j.name), members: Array.isArray(j.members) ? j.members.filter((m: unknown) => typeof m === "string") : [] };
    this.spaceRows.set(s.id, s);
    if (s.kind === "space" && s.name !== "") this.book?.channel(channelKey(this.connect, s.id), async () => s.name);
    return s;
  }

  /// Where a space's events were taken to (0: none).
  private cursor(space: string): number {
    return this.cursors.get(space) ?? this.threads.space(this.connect, space)?.aseq ?? 0;
  }

  /// What each space took after what was taken of it, taken in, in order; spaces left let go of. A space first heard of
  /// has what it had then taken as history (`first`: as a run begins, where the stream may tell some of it again).
  private async sync(handler: Handler, first = false) {
    for (;;) {
      const since: Record<string, number> = {};
      for (const id of new Set([...Object.keys(this.threads.spaces(this.connect)), ...this.cursors.keys()])) since[id] = this.cursor(id);
      const answer = await this.link.ask("POST", "/sync", { since });
      if (answer.status !== 200) throw new GroupUnreached(`the anchor did not answer what this device lacks (${answer.status})`);
      const said = JSON.parse(answer.body.toString());
      for (const id of Array.isArray(said?.left) ? said.left : []) if (typeof id === "string") this.left(id);
      for (const j of Array.isArray(said?.spaces) ? said.spaces : []) {
        const s = this.heardSpace(j);
        if (s === null || this.threads.space(this.connect, s.id) !== undefined || this.floors.has(s.id)) continue;
        const floor = typeof j.last_aseq === "number" ? j.last_aseq : 0;
        this.floors.set(s.id, floor);
        if (first) this.provisional.add(s.id);
        this.whole.add(s.id);
        this.cursors.set(s.id, 0);
        // (history: what was there before is not asked again of a station started again)
        this.threads.took(this.connect, s.id, floor);
      }
      if (said?.dseq !== null && typeof said?.dseq === "object") for (const [space, n] of Object.entries(said.dseq)) if (typeof n === "number") this.threads.said(this.connect, space, n, "");
      for (const j of Array.isArray(said?.events) ? said.events : []) await this.heard(j, handler);
      if (said?.more !== true) return;
    }
  }

  /// A space this member is in no more.
  private left(space: string) {
    this.spaceRows.delete(space);
    this.cursors.delete(space);
    this.floors.delete(space);
    this.provisional.delete(space);
    this.whole.delete(space);
    for (const k of [...this.tails.keys()]) {
      if (k !== space && !k.startsWith(`${space}/`)) continue;
      for (const m of this.tails.get(k)!) {
        this.byId.delete(m.id);
        this.byAseq.delete(`${space}#${m.aseq}`);
      }
      this.tails.delete(k);
      this.cut.delete(k);
    }
    for (const k of [...this.topics.keys()]) if (k.startsWith(`${space}/`)) this.topics.delete(k);
    this.threads.forget(this.connect, space);
  }

  /// One event of the stream.
  async take(event: string, data: string, handler: Handler) {
    let told: Json;
    try {
      told = JSON.parse(data);
    } catch {
      return;
    }
    if (event === "event") return this.heard(told?.stamped, handler, true);
    if (event === "space") {
      const s = this.heardSpace(told);
      // (a space it is put in while it listens: what it had then is history, what comes after is not)
      if (s !== null && this.threads.space(this.connect, s.id) === undefined && !this.floors.has(s.id)) {
        const floor = typeof told.last_aseq === "number" ? told.last_aseq : 0;
        this.floors.set(s.id, floor);
        this.whole.add(s.id);
        this.cursors.set(s.id, 0);
        this.threads.took(this.connect, s.id, floor);
        await this.sync(handler);
      }
      return;
    }
    if (event === "left" && typeof told?.space === "string") return this.left(told.space);
    if (event === "member") return this.heardMember(told);
    if (event === "stop") return this.stopPressed(told, handler);
    if (event === "secret") return this.secretHeard(told, handler);
  }

  /// A stamped event, taken once in its space's order: folded into what the station keeps of the space, handed to the
  /// hub where it is a person's word to it. One after a gap is what the next sync brings, with those before it.
  private async heard(j: Json, handler: Handler, streamed = false) {
    const aseq = typeof j?.aseq === "number" ? j.aseq : 0;
    const space = typeof j?.event?.space === "string" ? j.event.space : "";
    if (aseq < 1 || space === "") return;
    const at = this.cursor(space);
    if (aseq <= at) {
      // (taken as history in the sync a run began with, though the stream says it was taken after it opened)
      const floor = this.floors.get(space);
      if (streamed && this.provisional.has(space) && floor !== undefined && aseq <= floor) {
        const s = stampedOf(j);
        if (s !== null) await this.toHub(s, handler);
      }
      return;
    }
    if (aseq > at + 1) {
      if (streamed) await this.sync(handler);
      return;
    }
    const s = stampedOf(j);
    this.cursors.set(space, aseq);
    if (s === null) {
      log.warn("group", "an event not signed by its device: not taken", { connect: this.connect, space, aseq });
      this.threads.took(this.connect, space, aseq);
      return;
    }
    this.hlc.saw(s.event.hlc[0], s.event.hlc[1]);
    const said = this.fold(s);
    const floor = this.floors.get(space) ?? 0;
    if (aseq > floor) await this.toHub(s, handler);
    this.threads.took(this.connect, space, aseq, said ? streamKey(space, s.event.topic) : undefined);
  }

  /// What an event changes of what the station keeps of its space; whether it is a message.
  private fold(s: Stamped): boolean {
    const e = s.event;
    const b = e.body ?? {};
    if (e.device === this.deviceId) this.threads.said(this.connect, e.space, e.dseq, s.id);
    switch (e.kind) {
      case "space.create": {
        const had = this.spaceRows.get(e.space);
        if (!had) this.spaceRows.set(e.space, { id: e.space, kind: e.space.startsWith("d_") ? "direct" : "space", name: text(b.name), members: Array.isArray(b.members) ? b.members : [] });
        return false;
      }
      case "space.members": {
        const had = this.spaceRows.get(e.space);
        if (!had) return false;
        const gone = new Set<string>([...(Array.isArray(b.remove) ? b.remove : []), ...(b.leave === true ? [e.author] : [])]);
        const members = [...new Set([...had.members, ...(Array.isArray(b.add) ? b.add : [])])].filter((m) => !gone.has(m));
        this.spaceRows.set(e.space, { ...had, members, name: typeof b.name === "string" ? b.name : had.name });
        return false;
      }
      case "topic.open":
        if (typeof b.topic === "string") this.topics.set(`${e.space}/${b.topic}`, { title: text(b.title), by: e.author, branchedFrom: text(b.branched_from) });
        return false;
      case "topic.patch": {
        const had = this.topics.get(`${e.space}/${text(b.topic)}`);
        if (had && typeof b.title === "string") had.title = b.title;
        return false;
      }
      case "msg.post":
      case "decision.ask": {
        const m: Said = { id: s.id, space: e.space, topic: e.topic, aseq: s.aseq, kind: e.kind, author: e.author, text: text(b.text), files: filesOf(b.files), replyTo: text(b.reply_to), deleted: false };
        const key = streamKey(e.space, e.topic);
        const tail = this.tails.get(key) ?? [];
        tail.push(m);
        while (tail.length > TAIL_MOST) {
          const gone = tail.shift()!;
          this.byId.delete(gone.id);
          this.byAseq.delete(`${gone.space}#${gone.aseq}`);
          this.cut.add(key);
        }
        this.tails.set(key, tail);
        this.byId.set(m.id, m);
        this.byAseq.set(`${e.space}#${s.aseq}`, m);
        return true;
      }
      case "msg.edit": {
        const m = this.byId.get(text(b.target));
        if (m && m.author === e.author && !m.deleted) m.text = text(b.text);
        return false;
      }
      case "msg.unsend": {
        const m = this.byId.get(text(b.target));
        if (m && m.author === e.author) {
          m.deleted = true;
          m.text = "";
          m.files = [];
        }
        return false;
      }
      default:
        return false;
    }
  }

  /// Whether a topic is about the bot: its title mentions it, or it was branched from the bot's message or one that
  /// mentions it.
  private topicAboutBot(space: string, topic: string): boolean {
    if (topic === LOBBY) return false;
    const t = this.topics.get(`${space}/${topic}`);
    if (t === undefined) return false;
    if (mentions(t.title, this.botName())) return true;
    const from = t.branchedFrom === "" ? undefined : this.byId.get(t.branchedFrom);
    return from !== undefined && (from.author === this.botUserId() || mentions(from.text, this.botName()));
  }

  /// An event handed to the hub where it is a person's word to the agent: a message (a decision a person asked too), an
  /// edit of one, an answer to one of the bot's decisions.
  private async toHub(s: Stamped, handler: Handler) {
    const e = s.event;
    const b = e.body ?? {};
    if (e.author === this.botUserId()) return;
    const thread = threadOf(e.space, e.topic);
    const stream = streamKey(e.space, e.topic);
    const ts = String(s.aseq);
    if (e.kind === "msg.post" || e.kind === "decision.ask") {
      const m = this.byAseq.get(`${e.space}#${s.aseq}`);
      const words = text(b.text);
      const space = this.spaceRows.get(e.space);
      const replied = m?.replyTo ? this.byId.get(m.replyTo) : undefined;
      const firstOfTopic = e.topic !== LOBBY && (this.tails.get(stream)?.length ?? 0) <= 1 && !this.cut.has(stream);
      const addressed = space?.kind === "direct" || mentions(words, this.botName()) || replied?.author === this.botUserId() || (firstOfTopic && this.topicAboutBot(e.space, e.topic));
      const files: InboundFile[] = filesOf(b.files).map((f) => ({ id: f.sha256, name: f.name || f.sha256, size: f.size, url: `${e.space}/${f.sha256}` }));
      // (what it answers, or where its topic was branched from: the message its reader is shown first)
      const origin = firstOfTopic && replied === undefined ? this.topics.get(`${e.space}/${e.topic}`)?.branchedFrom : undefined;
      const quoted = replied ?? (origin ? this.byId.get(origin) : undefined);
      await handler({
        type: "message",
        message: { channel: thread.channel, threadTs: thread.threadTs, ts, user: e.author, text: this.answered(stream, words), addressed, ...(files.length > 0 ? { files } : {}), ...(quoted !== undefined ? { quoted: String(quoted.aseq) } : {}) },
      });
      return;
    }
    if (e.kind === "msg.edit") {
      const m = this.byId.get(text(b.target));
      if (m === undefined || m.author !== e.author || m.deleted) return;
      await handler({ type: "changed", channel: thread.channel, threadTs: thread.threadTs, ts: String(m.aseq), text: text(b.text) });
      return;
    }
    if (e.kind === "decision.resolve") {
      const target = text(b.target);
      const asked = this.asks.get(target);
      const known = this.byId.get(target);
      // (someone else's decision, or one of its own a person's message or the station closed: no word to the agent)
      if (this.closed.has(target) || (asked === undefined && known !== undefined && known.author !== this.botUserId())) return;
      this.asks.delete(target);
      if (asked !== undefined && this.asked.get(asked.stream)?.id === target) this.asked.delete(asked.stream);
      // (one asked before the station started again, whose ask it no longer has: to a session that follows the stream)
      const addressed = asked !== undefined || known !== undefined || this.spaceRows.get(e.space)?.kind === "direct";
      await handler({ type: "message", message: { channel: thread.channel, threadTs: thread.threadTs, ts, user: e.author, text: text(b.choice), addressed } });
    }
  }

  /// A person's message where a card waits: it closes the card (a person's next message does, a decision or not), and
  /// one that is an option's number is that option's words.
  private answered(stream: string, words: string): string {
    const waiting = this.asked.get(stream);
    if (waiting === undefined) return words;
    this.asked.delete(stream);
    this.close(waiting.id);
    const n = /^\s*(\d{1,2})\s*$/.exec(words);
    const label = n === null ? undefined : waiting.options[Number(n[1]) - 1];
    return label === undefined ? words : label;
  }

  /// A card that stopped waiting on the station (withdrawn, replaced, closed): a number said after it is a number, an
  /// answer to it no word to the agent. Only the card it was (by its ts): one posted since stays.
  async cardEnded(thread: ThreadRef, ts: string, _text: string, _card: Json, _end: CardEnd): Promise<void> {
    const { space, topic } = streamOf(thread);
    const stream = streamKey(space, topic);
    const waiting = this.asked.get(stream);
    if (waiting?.ts !== ts) return;
    this.asked.delete(stream);
    this.close(waiting.id);
  }

  /// One of its decisions closed other than by its answer.
  private close(id: string) {
    this.asks.delete(id);
    this.closed.add(id);
    if (this.closed.size > CLOSED_KEPT) this.closed.delete(this.closed.values().next().value!);
  }

  /// Stop pressed on a stream's live state: the turn working for it is stopped (where it is this bot's, or anyone's).
  private async stopPressed(told: Json, handler: Handler) {
    const space = text(told?.space);
    if (!this.spaceRows.has(space)) return;
    const target = text(told?.target);
    if (target !== "" && target !== this.botUserId()) return;
    const thread = threadOf(space, text(told?.topic) || LOBBY);
    const ts = text(told?.message_ts) || String(typeof told?.at === "number" ? told.at : this.now());
    // (pressed on what is shown now: never too early for the turn that shows it)
    await handler({ type: "stop", channel: thread.channel, threadTs: thread.threadTs, ts, localAt: null });
  }

  // ── secrets ──

  /// The connections other members' devices hand it a secret by, served as they come while the surface runs.
  private acceptSecrets() {
    if (this.acceptingSecrets) return;
    this.acceptingSecrets = true;
    void this.run(
      Effect.scoped(
        accept({ accept: () => this.link.accepted() }, {
          serve: (conn) => this.secretDialled(conn),
          failed: (error) => log.info("group", "a secret's connection ended", { connect: this.connect, error: String(error) }),
          closing: "secret taken",
        }),
      ),
    ).catch(() => {});
  }

  /// One secret on its own connection (`im-secret/1`): taken where its device is a device of the member it says it is
  /// from, in the space it names, and answered.
  private async secretDialled(conn: Connection) {
    const stream = await conn.acceptBi();
    if (stream === null) return;
    const said = await new Reader(stream).line().catch(() => null);
    const space = text(said?.space);
    const from = text(said?.from);
    let ok = false;
    if (this.spaceRows.has(space) && from !== "" && this.link.open()) {
      const answer = await this.link.ask("GET", `/spaces/${encodeURIComponent(space)}/devices?member=${encodeURIComponent(from)}`).catch(() => null);
      const devices: unknown = answer?.status === 200 ? JSON.parse(answer.body.toString())?.devices : [];
      ok = Array.isArray(devices) && devices.includes(conn.remoteId());
    }
    // (answered at once: the device that dialled waits a while, then hands it through the anchor instead)
    await writeLine(stream, ok ? { ok: true } : { ok: false, error: "not a device of that member in that space" });
    await stream.finish().catch(() => {});
    if (ok && this.handler !== null) {
      const handler = this.handler;
      await this.inTurn(() => this.secretHeard(said, handler));
    }
    await stream.stopped().catch(() => {});
  }

  /// A secret handed to the bot: the session told of it by its label, its value a file of its uploads (fetched once, of
  /// memory alone: `download`), never in a message's words. A card waiting there is closed by it, as by any message.
  private async secretHeard(told: Json, handler: Handler) {
    const id = text(told?.id);
    const space = text(told?.space);
    const from = text(told?.from);
    const value = typeof told?.value === "string" ? told.value : null;
    if (id === "" || value === null || from === "" || from === this.botUserId() || !this.spaceRows.has(space) || this.secretsSeen.has(id)) return;
    this.secretsSeen.add(id);
    if (this.secretsSeen.size > SECRETS_SEEN) this.secretsSeen.delete(this.secretsSeen.values().next().value!);
    const label = text(told?.label).slice(0, 80) || "secret";
    const topic = text(told?.topic) || LOBBY;
    const thread = threadOf(space, topic);
    const file = `secret-${id}`;
    this.secrets.set(file, Buffer.from(value, "utf8"));
    this.answered(streamKey(space, topic), "");
    // (between the space's events, its own: a place no event of the space has)
    const ts = `${this.cursor(space)}.${String(Number.parseInt(id.slice(0, 8), 16) || 1).padStart(10, "0")}`;
    const name = this.members.get(from) ?? from;
    const safe = Array.from(label).map((c) => (/[\w.-]/.test(c) ? c : "_")).join("");
    await handler({
      type: "message",
      message: { channel: thread.channel, threadTs: thread.threadTs, ts, user: from, text: tr(stationLang(), "station.group.secretReceived", { label, name }), addressed: true, files: [{ id: file, name: `${safe}.secret`, size: Buffer.byteLength(value), url: `secret:${file}` }] },
    });
  }

  // ── saying ──

  /// An event this device says in a stream: signed after its last there, taken by the anchor. What the anchor gave it
  /// (its id, place and number), or why it refused it.
  private say(space: string, topic: string, kind: string, body: Json): Promise<{ id: string; aseq: number; n: number } | { refused: string }> {
    const turn = this.saying.then(async () => {
      for (let again = 0; ; again++) {
        const kept = this.threads.space(this.connect, space) ?? { aseq: 0, dseq: 0, prev: "" };
        const e = signEvent(this.key, { space, author: this.botUserId(), device: this.deviceId, dseq: kept.dseq + 1, hlc: this.hlc.next(this.now()), prev: kept.prev, topic, kind, body });
        const id = eventId(e);
        this.threads.said(this.connect, space, e.dseq, id);
        const answer = await this.link.ask("POST", "/events", { events: [e] });
        if (answer.status !== 200) throw new Error(`the anchor did not take the message (${answer.status}: ${answer.body.toString().slice(0, 200)})`);
        const r = JSON.parse(answer.body.toString())?.results?.[0];
        if (typeof r?.aseq === "number") return { id, aseq: r.aseq, n: typeof r.n === "number" ? r.n : 0 };
        const why = typeof r?.why === "string" ? r.why : "refused";
        // (this device's count behind the anchor's, as a station's kept state went back: said again after it)
        if (why === "dseq" && again === 0 && this.handler !== null) {
          const handler = this.handler;
          await this.inTurn(() => this.sync(handler));
          continue;
        }
        return { refused: why };
      }
    });
    this.saying = turn.catch(() => {});
    return turn;
  }

  /// A file put into a space: whole in one ask where it is one piece at most, else a piece at a time (`PIECE`), from
  /// what the anchor has of it already on (`GET /spaces/<id>/uploads/<sha256>`); nothing of it held but a piece.
  private async upload(space: string, file: Attachment): Promise<FileRef> {
    const size = (await stat(file.path)).size;
    if (size > FILE_MOST) throw new Error(`${file.name} is ${size} bytes, more than the anchor takes (${FILE_MOST})`);
    const handle = await open(file.path, "r");
    try {
      const piece = Buffer.alloc(Math.min(Math.max(size, 1), PIECE));
      const read = async (at: number, n: number): Promise<Buffer> => {
        let got = 0;
        while (got < n) {
          const { bytesRead } = await handle.read(piece, got, n - got, at + got);
          if (bytesRead === 0) break;
          got += bytesRead;
        }
        if (got !== n) throw new Error(`${file.name} changed as it was read`);
        return piece.subarray(0, n);
      };
      const shape = imageSize(Buffer.from(await read(0, Math.min(size, HEAD, piece.length))));
      const files = `/spaces/${encodeURIComponent(space)}/files?name=${encodeURIComponent(file.name)}&mime=${encodeURIComponent(mimeOf(file.name))}`;
      const sides = shape === null ? "" : `&width=${shape.width}&height=${shape.height}`;
      const took = (answer: { status: number; body: Buffer }): FileRef => {
        const got = answer.status === 200 || answer.status === 201 ? filesOf([JSON.parse(answer.body.toString())?.file])[0] : undefined;
        if (got === undefined) throw new Error(`the anchor did not take ${file.name} (${answer.status}: ${answer.body.toString().slice(0, 200)})`);
        return got;
      };
      if (size <= PIECE) return took(await this.link.ask("POST", `${files}${sides}`, Buffer.from(await read(0, size))));
      const hash = createHash("sha256");
      for (let at = 0; at < size; at += PIECE) hash.update(await read(at, Math.min(PIECE, size - at)));
      const sha = hash.digest("hex");
      const asked = await this.link.ask("GET", `/spaces/${encodeURIComponent(space)}/uploads/${sha}`);
      if (asked.status !== 200) {
        // (an anchor from before pieces: what it takes whole, in one ask)
        if (size > WHOLE_MOST) throw new Error(`${file.name} is ${size} bytes, more than this anchor takes (${WHOLE_MOST}): it takes larger files once it is updated`);
        return took(await this.link.ask("POST", `${files}${sides}`, await readFile(file.path)));
      }
      let have = haveOf(asked.body);
      for (let stalled = 0; ; ) {
        const at = Math.min(have, size);
        const answer = await this.link.ask("POST", `${files}&sha256=${sha}&size=${size}&from=${at}${sides}`, Buffer.from(await read(at, Math.min(PIECE, size - at))));
        if (answer.status !== 202 && answer.status !== 409) return took(answer);
        const now = haveOf(answer.body);
        stalled = now === have ? stalled + 1 : 0;
        if (stalled > STALLED_MOST) throw new Error(`the anchor took none of ${file.name} after ${have} of its ${size} bytes`);
        have = now;
      }
    } finally {
      await handle.close();
    }
  }

  /// The agent's words and its files, as one message where they fit, a card as a decision (its words where the anchor
  /// takes none); the first one's ts stands for the whole.
  async post(thread: ThreadRef, message: string, files: Attachment[], card?: Json | null): Promise<string> {
    const { space, topic } = streamOf(thread);
    const stream = streamKey(space, topic);
    const asking = card && (card.type === "options" || card.type === "text") ? card : null;
    if (asking) {
      const was = this.asked.get(stream);
      if (was) this.close(was.id);
      this.asked.delete(stream);
    }
    const refs: FileRef[] = [];
    for (const file of files) refs.push(await this.upload(space, file));
    const parts = message === "" ? [""] : splitForSlack(message, CHARS_MOST);
    for (let at = FILES_MOST; at < refs.length; at += FILES_MOST) parts.push("");
    let first: string | null = null;
    for (const [i, part] of parts.entries()) {
      const carried = refs.slice(i * FILES_MOST, (i + 1) * FILES_MOST);
      const fileJson = carried.map((f) => ({ ...f }));
      if (i === 0 && asking) {
        const ts = await this.ask(space, topic, stream, part, fileJson, asking);
        first ??= ts;
        continue;
      }
      const r = await this.say(space, topic, "msg.post", { text: part, files: fileJson });
      if ("refused" in r) throw new Error(`the anchor did not take the message (${r.refused})`);
      first ??= String(r.aseq);
    }
    if (first === null) throw new Error("nothing to post");
    return first;
  }

  /// A card asked as a decision, waiting: its ts. Where the anchor takes no such decision, its question and numbered
  /// options go as words.
  private async ask(space: string, topic: string, stream: string, part: string, files: Json[], card: Json): Promise<string> {
    const body = { ...decisionBody(part, card), files };
    const r = await this.say(space, topic, "decision.ask", body);
    if (!("refused" in r)) {
      const options = Array.isArray(body.options) ? body.options.map((o: Json) => o.label) : [];
      this.asks.set(r.id, { stream, ts: String(r.aseq) });
      this.asked.set(stream, { ts: String(r.aseq), id: r.id, options });
      return String(r.aseq);
    }
    // (an anchor from before decisions, or one that takes none of these: its words, answered by number)
    log.info("group", "a card asked as words", { connect: this.connect, why: r.refused });
    const said = cardWords(part, card);
    const words = await this.say(space, topic, "msg.post", { text: said.words, files });
    if ("refused" in words) throw new Error(`the anchor did not take the message (${words.refused})`);
    if (said.options.length > 0) this.asked.set(stream, { ts: String(words.aseq), id: words.id, options: said.options });
    return String(words.aseq);
  }

  /// What the agent does in a stream, said as its live state ("": done).
  private async live(thread: ThreadRef, status: string, messageTs: string | null): Promise<boolean> {
    const { space, topic } = streamOf(thread);
    if (!this.link.open()) return false;
    const answer = await this.link
      .ask("POST", `/spaces/${encodeURIComponent(space)}/live`, { topic, state: status === "" ? "done" : "working", text: Array.from(status).slice(0, LIVE_MOST).join(""), stoppable: status !== "", ...(messageTs !== null ? { message_ts: messageTs } : {}) })
      .catch(() => null);
    // (an anchor with no live state answers 404: nothing to show it again)
    return answer !== null && answer.status !== 503;
  }

  async download(file: InboundFile): Promise<Uint8Array> {
    if (file.url?.startsWith("secret:")) {
      const id = file.url.slice("secret:".length);
      const value = this.secrets.get(id);
      this.secrets.delete(id);
      if (value === undefined) throw new Error("the secret was fetched already");
      return value;
    }
    const at = file.url?.indexOf("/") ?? -1;
    if (file.url === null || at < 0) throw new Error("the anchor does not give its contents");
    const answer = await this.link.ask("GET", `/spaces/${encodeURIComponent(file.url.slice(0, at))}/files/${encodeURIComponent(file.url.slice(at + 1))}`);
    if (answer.status !== 200) throw new Error(`the anchor answered ${answer.status} for ${file.name}`);
    return answer.body;
  }

  private messageOf(m: Said): ChatMessage {
    const files: InboundFile[] = m.files.map((f) => ({ id: f.sha256, name: f.name || f.sha256, size: f.size, url: `${m.space}/${f.sha256}` }));
    return { ts: String(m.aseq), user: m.author, text: m.text, fromBot: m.author === this.botUserId(), ...(files.length > 0 ? { files } : {}) };
  }

  /// A space's events after `after`, read of the anchor (500 at most), checked.
  private async eventsAfter(space: string, after: number): Promise<Stamped[]> {
    const answer = await this.link.ask("GET", `/spaces/${encodeURIComponent(space)}/events?after=${after}`);
    if (answer.status !== 200) return [];
    const got = JSON.parse(answer.body.toString())?.events;
    return (Array.isArray(got) ? got : []).map(stampedOf).filter((s): s is Stamped => s !== null);
  }

  /// What a stream said before `before` (an event's place), its last `limit` (where a topic was branched from is its
  /// first message's quote: `toHub`). Of what is kept where the station heard the space from its first event, else
  /// read of the anchor.
  history(thread: ThreadRef, before: string, limit: number): Promise<ChatMessage[]> {
    return (async () => {
      const { space, topic } = streamOf(thread);
      const key = streamKey(space, topic);
      const b = Number.isFinite(Number(before)) && Number(before) > 0 ? Math.ceil(Number(before)) : Number.POSITIVE_INFINITY;
      const most = Math.max(1, Math.min(TAIL_MOST, Math.trunc(limit)));
      const kept = (this.tails.get(key) ?? []).filter((m) => m.aseq < b);
      let said: Said[];
      if (kept.length >= most || (this.whole.has(space) && !this.cut.has(key))) said = kept;
      else {
        said = [];
        const edits = new Map<string, Said>();
        for (let after = 0, page = 0; page < HISTORY_PAGES && after + 1 < b; page++) {
          const got = await this.eventsAfter(space, after);
          if (got.length === 0) break;
          for (const s of got) {
            after = s.aseq;
            if (s.aseq >= b) break;
            const e = s.event;
            const target = edits.get(text(e.body?.target));
            if (e.kind === "msg.edit" && target && target.author === e.author) target.text = text(e.body?.text);
            if (e.kind === "msg.unsend" && target && target.author === e.author) target.deleted = true;
            if ((e.kind !== "msg.post" && e.kind !== "decision.ask") || e.topic !== topic) continue;
            const m: Said = { id: s.id, space, topic, aseq: s.aseq, kind: e.kind, author: e.author, text: text(e.body?.text), files: filesOf(e.body?.files), replyTo: text(e.body?.reply_to), deleted: false };
            edits.set(m.id, m);
            said.push(m);
            if (said.length > most) said.shift();
          }
        }
      }
      return said.filter((m) => !m.deleted).slice(-most).map((m) => this.messageOf(m));
    })();
  }

  /// The message a reply quotes (by its place in its space); null for the bot's own and where it cannot be read.
  async quoted(thread: ThreadRef, ts: string): Promise<ChatMessage | null> {
    try {
      const aseq = Number(ts);
      if (!Number.isSafeInteger(aseq) || aseq < 1) return null;
      const space = thread.channel;
      let m = this.byAseq.get(`${space}#${aseq}`);
      if (m === undefined) {
        const s = (await this.eventsAfter(space, aseq - 1))[0];
        if (s === undefined || s.aseq !== aseq || (s.event.kind !== "msg.post" && s.event.kind !== "decision.ask")) return null;
        m = { id: s.id, space, topic: s.event.topic, aseq, kind: s.event.kind, author: s.event.author, text: text(s.event.body?.text), files: filesOf(s.event.body?.files), replyTo: "", deleted: false };
      }
      if (m.author === this.botUserId() || m.deleted) return null;
      return this.messageOf(m);
    } catch {
      return null;
    }
  }

  /// The spaces (not direct ones) it is in: a chat relayed to one goes on in a topic of its own there (`begin`).
  async places(): Promise<Place[]> {
    return [...this.spaceRows.values()].filter((s) => s.kind === "space").map((s) => ({ id: s.id, name: s.name || s.id, kind: "space" as const }));
  }

  async peopleIn(channel: string): Promise<Member[]> {
    if (this.members.size === 0) await this.readMembers().catch(() => {});
    return (this.spaceRows.get(channel)?.members ?? []).filter((m) => m !== this.botUserId()).map((m) => ({ id: m, name: this.members.get(m) ?? m }));
  }

  /// A topic of its own opened in the space (`topic.open`, called `title`), begun with `message`: the conversation from
  /// now on, `<space>/<topic>`. Where the anchor takes no topic of the station's, the space's lobby.
  async begin(channel: string, message: string, title = ""): Promise<{ thread: ThreadRef; ts: string }> {
    const topic = `t_${this.topicId()}`;
    const opened = await this.say(channel, topic, "topic.open", { topic, title: topicTitle(title) || "still.fail" });
    if ("refused" in opened) {
      log.warn("group", "a topic not opened for a relayed chat: its space's lobby instead", { connect: this.connect, space: channel, why: opened.refused });
      const lobby = threadOf(channel, LOBBY);
      return { thread: lobby, ts: await this.post(lobby, message, []) };
    }
    const thread = threadOf(channel, topic);
    return { thread, ts: await this.post(thread, message, []) };
  }

  protected async lookUp(user: string): Promise<Person | null> {
    if (!this.members.has(user)) await this.readMembers().catch(() => {});
    const name = this.members.get(user);
    return name === undefined ? null : { name, email: "" };
  }

  /// Members of the IM have no email there.
  protected async lookUpEmail(): Promise<string | null> {
    return null;
  }

  knownPerson(user: string): Person | null {
    if (!this.book) return this.names.get(user) ?? null;
    return this.book.person(personKey(this.connect, user), () => this.lookUp(user));
  }

  /// A space's name; a direct one's the other member's.
  knownChannel(channel: string): string | null {
    const read = async () => {
      const s = this.spaceRows.get(channel);
      if (s === undefined) return null;
      if (s.kind === "space") return s.name || null;
      const other = s.members.find((m) => m !== this.botUserId());
      return other === undefined ? null : ((await this.lookUp(other))?.name ?? null);
    };
    if (!this.book) return this.spaceRows.get(channel)?.name || null;
    return this.book.channel(channelKey(this.connect, channel), read);
  }

  async channelName(channel: string): Promise<string | null> {
    const s = this.spaceRows.get(channel);
    return s?.kind === "space" ? s.name || null : null;
  }

  protected statusLine(thread: ThreadRef): StatusLine {
    return new GroupLive(this.run, (status, messageTs) => this.live(thread, status, messageTs));
  }
}

/// A picture's size, read of its head (PNG, GIF, JPEG, WebP), so the anchor can say it before it is fetched; null for
/// what is none of these or says no size.
export function imageSize(b: Uint8Array): { width: number; height: number } | null {
  const v = new DataView(b.buffer, b.byteOffset, b.byteLength);
  const ascii = (at: number, n: number) => (b.length >= at + n ? String.fromCharCode(...b.subarray(at, at + n)) : "");
  const sized = (width: number, height: number) => (Number.isInteger(width) && Number.isInteger(height) && width > 0 && height > 0 ? { width, height } : null);
  if (b.length >= 24 && b[0] === 0x89 && ascii(1, 3) === "PNG" && ascii(12, 4) === "IHDR") return sized(v.getUint32(16), v.getUint32(20));
  if (b.length >= 10 && (ascii(0, 6) === "GIF87a" || ascii(0, 6) === "GIF89a")) return sized(v.getUint16(6, true), v.getUint16(8, true));
  if (b.length >= 4 && b[0] === 0xff && b[1] === 0xd8) {
    let i = 2;
    while (i + 4 <= b.length) {
      if (b[i] !== 0xff) return null;
      const marker = b[i + 1]!;
      if (marker === 0xff) {
        i += 1;
        continue;
      }
      if (marker === 0x01 || (marker >= 0xd0 && marker <= 0xd8)) {
        i += 2;
        continue;
      }
      if (marker === 0xd9 || marker === 0xda) return null;
      const length = v.getUint16(i + 2);
      // (a frame's start: every SOFn but DHT C4, JPG C8 and DAC CC)
      if (marker >= 0xc0 && marker <= 0xcf && marker !== 0xc4 && marker !== 0xc8 && marker !== 0xcc) {
        return i + 9 <= b.length ? sized(v.getUint16(i + 7), v.getUint16(i + 5)) : null;
      }
      i += 2 + length;
    }
    return null;
  }
  if (b.length >= 30 && ascii(0, 4) === "RIFF" && ascii(8, 4) === "WEBP") {
    const chunk = ascii(12, 4);
    if (chunk === "VP8 " && b[23] === 0x9d && b[24] === 0x01 && b[25] === 0x2a) return sized(v.getUint16(26, true) & 0x3fff, v.getUint16(28, true) & 0x3fff);
    if (chunk === "VP8L" && b[20] === 0x2f) {
      const bits = v.getUint32(21, true);
      return sized((bits & 0x3fff) + 1, ((bits >>> 14) & 0x3fff) + 1);
    }
    if (chunk === "VP8X") return sized((b[24]! | (b[25]! << 8) | (b[26]! << 16)) + 1, (b[27]! | (b[28]! << 8) | (b[29]! << 16)) + 1);
  }
  return null;
}
