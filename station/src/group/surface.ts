// A group connect as a chat surface: the station as a member of an IM server of AFK-surf/group, as it is a bot in
// Slack or Feishu (connects/surface.ts keeps its link up, connected again after a wait that doubles whenever it goes).
// Its link (link.ts) is let in by the connect's key, and by the code it joins with the first time; then the server's
// event stream (`GET /events`) tells it what is said in its conversations, gone on from where it was (`since`) or, where
// the server cannot, read again from each conversation's last message taken (`?after=`, threads.ts), so nothing is
// taken twice and nothing said while it was away is lost.
//
// A conversation is a thread: its id is both the channel and the thread's ts (`<conv>/<conv>`, not one channel `GROUP`
// for all: the hub names and groups a chat by its channel, so every conversation would show as the same one), its
// messages' numbers their ts. Every
// message of a private chat calls the agent; in a group, one that mentions the bot (`@name`) does, and the rest go to a
// session that follows the group already (the hub's rule, as Slack's threads: chat_leave stops it until the next
// mention; the station never leaves the group on the server). A message's files are fetched as the hub records it;
// what an agent posts goes as one message, its files uploaded first, a card as its question and numbered options in
// the words (answered by their number or words, which the agent is handed as the option's words).
import { randomUUID } from "node:crypto";
import { readFile, stat } from "node:fs/promises";
import { extname } from "node:path";
import { type Clock, Effect } from "effect";
import type { CardEnd } from "../connects/card-ends.ts";
import type { BotIdentity } from "../connects/connections.ts";
import { channelKey, personKey } from "../connects/keys.ts";
import type { NameBook } from "../connects/names.ts";
import { StatusLine } from "../connects/status.ts";
import { ConnectedSurface } from "../connects/surface.ts";
import type { Endpoints } from "../mesh/endpoint.ts";
import { stationLang, tr } from "../ops/i18n.ts";
import { log } from "../ops/log.ts";
import { type ChatMessage, type Handler, type InboundFile, type Member, type Person, type Place, type ThreadRef, splitForSlack } from "../sessions/chat.ts";
import type { Attachment } from "../store/store.ts";
import { GroupLink, GroupUnreached, RESUMED, SseLines } from "./link.ts";
import type { GroupThreads } from "./threads.ts";

type Json = any;

/// A message as the server says it (protocol.ts `Message`, and the files, edits and deletions of the server's that
/// has them).
export type GroupMessage = {
  n: number;
  id: string;
  from: string;
  text: string;
  at: number;
  files?: { id: string; name: string; mime?: string; size: number; sha256?: string; width?: number; height?: number }[];
  replyTo?: number;
  edited?: number;
  deleted?: number;
};
/// A conversation as a member's list has it (protocol.ts `Listed`; `last` only there).
type Conversation = { id: string; kind: "private" | "group"; members: string[]; name: string | null; last?: number };

/// The longest text of one message, in bytes (the server's TEXT_MOST): an agent's longer words go as several.
const TEXT_MOST = 16 * 1024;
/// So many characters at most a message (four bytes each at most).
const CHARS_MOST = TEXT_MOST / 4;
/// The most a read of a conversation gives (the server's READ_MOST).
const READ_MOST = 500;
/// The largest file a group server takes (32 MiB): a larger one is refused here before it is read.
const FILE_MOST = 32 * 1024 * 1024;
/// The control stream's ping: how often, and how long it may go unanswered before the link is taken for dead.
const PING_MS = 15_000;
const STALE_MS = 45_000;

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

/// A card's question as the words of a message: its question, then each option numbered, and how to answer.
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

/// Nothing is said in a conversation while the agent works: the IM has no status line.
class Quiet extends StatusLine {
  protected async show(): Promise<boolean> {
    return true;
  }
}

export type GroupSurfaceOptions = {
  connect: string;
  /// The server's endpoint id (64 hex) and its relays; where it is besides (a test's).
  server: string;
  relays: string[];
  ips?: string[];
  /// The connect's key (32 bytes, hex): this device on the server.
  key: string;
  /// The code it joins by (an invitation, a device code) while it has not; null once it has.
  code: string | null;
  /// The name it joins as, and is renamed to where the server has another.
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
  /// Whether it was let in since it started: then it says no code again.
  private joined = false;
  /// The conversations it is in, as last heard.
  private conversations = new Map<string, Conversation>();
  /// Conversations it was put in while it listened (an event said so) and has taken no message of yet: the first
  /// message the stream gives of one is the first that is new to it.
  private joining = new Set<string>();
  /// Conversations first heard of in this run's listing, their last number taken as history: one the stream then says
  /// it was made or put in (after the stream opened, before the listing) is joining after all.
  private provisional = new Set<string>();
  /// The members' names, by id.
  private members = new Map<string, string>();
  /// Each conversation's card still waiting: its message's number and its options, by their number. A person's next
  /// message there closes it, answered or not (`answered`), as does its end on the station (`cardEnded`).
  private asked = new Map<string, { ts: string; options: string[] }>();
  /// Events go one at a time, in order.
  private taking: Promise<void> = Promise.resolve();

  constructor(options: GroupSurfaceOptions) {
    if (!/^[0-9a-f]{64}$/.test(options.server)) throw new Error("group.server is the IM server's endpoint id (64 hex)");
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
    this.link = new GroupLink({ endpoints: options.endpoints, secretKey: Buffer.from(options.key, "hex"), server: options.server, relays: options.relays, ...(options.ips ? { ips: options.ips } : {}) });
  }

  /// This device's endpoint id: what the server knows the connect's key by.
  device(): Promise<string> {
    return this.link.device();
  }

  /// Let in: dialled anew (a code said only until it joined), its name set where it was asked for another.
  private async letIn(): Promise<BotIdentity> {
    const hello = !this.joined && this.code !== null ? { credential: this.code, ...(this.wanted !== null ? { name: this.wanted } : {}) } : { credential: "" };
    let me = await this.link.connect(hello);
    this.joined = true;
    if (me.joined) log.info("group", "joined the server", { connect: this.connect, member: me.member });
    if (this.wanted !== null && this.wanted !== me.name) {
      const renamed = await this.link.ask("POST", "/me/name", { name: this.wanted }).catch(() => null);
      if (renamed?.status === 200) me = { ...me, name: this.wanted };
      else log.warn("group", "the bot's name not set on the server", { connect: this.connect, status: renamed?.status ?? null });
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

  /// One run of its link: let in again where it went, its event stream opened from where the last one was, what was
  /// said meanwhile read where that cannot be, then each event taken in order, the control stream pinged meanwhile.
  /// Ends as the stream does; fails (so its backoff counts) where it could not be opened, or the link stopped answering.
  runSocket(_url: string, handler: Handler): Effect.Effect<void, Error> {
    const self = this;
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
        const since = self.threads.since(self.connect);
        const reply = await self.link.stream("GET", since === null ? "/events" : `/events?since=${encodeURIComponent(since)}`);
        cancel = reply.cancel;
        if (over) return reply.cancel();
        if (reply.status !== 200) {
          reply.cancel();
          throw new GroupUnreached(`the event stream was answered ${reply.status}`);
        }
        self.provisional.clear();
        await self.readMembers().catch((e) => log.warn("group", "members not read", { connect: self.connect, error: (e as Error).message }));
        const resumed = since !== null && reply.headers[RESUMED] === "1";
        if (!resumed) await self.catchUp(handler);
        self.setStatus(true, null);
        const sse = new SseLines();
        for await (const chunk of reply.chunks) {
          self.heardHook();
          for (const [event, data, id] of sse.feed(chunk)) {
            if (event !== "") await self.take(event, data, handler);
            if (id !== null) self.threads.heardEvent(self.connect, id);
          }
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
    for (const m of JSON.parse(answer.body.toString())?.members ?? []) {
      if (typeof m?.id !== "string" || typeof m?.name !== "string") continue;
      this.members.set(m.id, m.name);
      this.names.set(m.id, { name: m.name, email: "" });
    }
  }

  private async listed(): Promise<Conversation[]> {
    const answer = await this.link.ask("GET", "/conversations");
    if (answer.status !== 200) throw new Error(`the conversations were answered ${answer.status}`);
    const out: Conversation[] = [];
    for (const c of JSON.parse(answer.body.toString())?.conversations ?? []) {
      if (typeof c?.id !== "string") continue;
      const conversation: Conversation = { id: c.id, kind: c.kind === "group" ? "group" : "private", members: Array.isArray(c.members) ? c.members.filter((m: unknown) => typeof m === "string") : [], name: typeof c.name === "string" ? c.name : null, last: typeof c.last === "number" ? c.last : 0 };
      this.conversations.set(c.id, conversation);
      out.push(conversation);
    }
    return out;
  }

  /// What was said in its conversations since the last message taken of each; one first heard of is taken as it is now.
  async catchUp(handler: Handler) {
    for (const c of await this.listed()) {
      const last = this.threads.last(this.connect, c.id);
      if (last === undefined) {
        if (!this.joining.has(c.id)) {
          this.threads.took(this.connect, c.id, c.last ?? 0);
          this.provisional.add(c.id);
        }
        continue;
      }
      if ((c.last ?? 0) > last) await this.readAfter(c, last, handler);
    }
  }

  /// Its messages after `after`, each taken in order.
  private async readAfter(c: Conversation, after: number, handler: Handler) {
    for (let from = after; ; ) {
      const answer = await this.link.ask("GET", `/conversations/${encodeURIComponent(c.id)}/messages?after=${from}`);
      if (answer.status !== 200) return;
      const read = JSON.parse(answer.body.toString());
      const messages: GroupMessage[] = Array.isArray(read?.messages) ? read.messages : [];
      for (const m of messages) await this.heard(c, m, handler);
      if (read?.more !== true || messages.length === 0) return;
      from = messages[messages.length - 1]!.n;
    }
  }

  private async conversationOf(id: string): Promise<Conversation | null> {
    const known = this.conversations.get(id);
    if (known) return known;
    await this.listed().catch(() => []);
    return this.conversations.get(id) ?? null;
  }

  /// One event of the stream.
  async take(event: string, data: string, handler: Handler) {
    let told: Json;
    try {
      told = JSON.parse(data);
    } catch {
      return;
    }
    if (event === "conversation" && typeof told?.id === "string") {
      const had = this.conversations.get(told.id);
      this.conversations.set(told.id, { id: told.id, kind: told.kind === "group" ? "group" : "private", members: Array.isArray(told.members) ? told.members : [], name: typeof told.name === "string" ? told.name : null, last: had?.last });
      if (typeof told.name === "string" && told.kind === "group") this.book?.channel(channelKey(this.connect, told.id), async () => told.name);
      if (this.threads.last(this.connect, told.id) === undefined || this.provisional.delete(told.id)) {
        this.threads.forget(this.connect, told.id);
        this.joining.add(told.id);
      }
      return;
    }
    if (event === "left" && typeof told?.conversation === "string") {
      this.conversations.delete(told.conversation);
      this.joining.delete(told.conversation);
      this.threads.forget(this.connect, told.conversation);
      return;
    }
    if (event === "member" && typeof told?.id === "string" && typeof told?.name === "string") {
      this.members.set(told.id, told.name);
      this.names.set(told.id, { name: told.name, email: "" });
      this.book?.person(personKey(this.connect, told.id), async () => ({ name: told.name, email: "" }), (known) => known.name !== told.name);
      return;
    }
    if (event === "missed") return this.catchUp(handler);
    if ((event === "message" || event === "message_updated") && typeof told?.conversation === "string" && typeof told?.n === "number") {
      const c = await this.conversationOf(told.conversation);
      if (c === null) return;
      if (event === "message_updated") return this.updated(c, told, handler);
      let last = this.threads.last(this.connect, c.id);
      if (last === undefined) {
        // (put in it while listening: what came before this is history)
        this.joining.delete(c.id);
        last = told.n - 1;
        this.threads.took(this.connect, c.id, last);
      }
      if (told.n > last + 1) await this.readAfter(c, last, handler);
      await this.heard(c, told, handler);
    }
  }

  /// A message, taken once (by its number): handed to the hub unless it is the bot's own or was deleted.
  private async heard(c: Conversation, m: GroupMessage, handler: Handler) {
    const last = this.threads.last(this.connect, c.id) ?? 0;
    if (m.n <= last) return;
    if (m.from !== this.botUserId() && m.deleted === undefined) {
      const addressed = c.kind === "private" || mentions(m.text, this.botName());
      const files: InboundFile[] = (m.files ?? []).filter((f) => typeof f?.id === "string").map((f) => ({ id: f.id, name: f.name || f.id, size: f.size ?? 0, url: `${c.id}/${f.id}` }));
      await handler({
        type: "message",
        message: { channel: c.id, threadTs: c.id, ts: String(m.n), user: m.from, text: this.answered(c.id, m.text), addressed, ...(files.length > 0 ? { files } : {}), ...(typeof m.replyTo === "number" ? { quoted: String(m.replyTo) } : {}) },
      });
    }
    this.threads.took(this.connect, c.id, m.n);
  }

  /// An edit of a message taken (a deletion is not taken: the station keeps what was said).
  private async updated(c: Conversation, m: GroupMessage, handler: Handler) {
    if (m.deleted !== undefined || m.from === this.botUserId()) return;
    if (m.n > (this.threads.last(this.connect, c.id) ?? 0)) return;
    await handler({ type: "changed", channel: c.id, threadTs: c.id, ts: String(m.n), text: m.text });
  }

  /// A person's message where a card waits: it closes the card (a person's next message does, a decision or not), and
  /// one that is an option's number is that option's words. Called once a message (`heard`).
  private answered(conversation: string, text: string): string {
    const waiting = this.asked.get(conversation);
    if (waiting === undefined) return text;
    this.asked.delete(conversation);
    const n = /^\s*(\d{1,2})\s*$/.exec(text);
    const label = n === null ? undefined : waiting.options[Number(n[1]) - 1];
    return label === undefined ? text : label;
  }

  /// A card that stopped waiting on the station (withdrawn, replaced, closed): a number said after it is a number. Only
  /// the card it was (by its message's number): one posted since stays.
  async cardEnded(thread: ThreadRef, ts: string, _text: string, _card: Json, _end: CardEnd): Promise<void> {
    if (this.asked.get(thread.threadTs)?.ts === ts) this.asked.delete(thread.threadTs);
  }

  private async upload(conversation: string, file: Attachment): Promise<string> {
    const size = (await stat(file.path)).size;
    if (size > FILE_MOST) throw new Error(`${file.name} is ${size} bytes, more than the server takes (${FILE_MOST})`);
    const bytes = await readFile(file.path);
    const shape = imageSize(bytes);
    const query = `name=${encodeURIComponent(file.name)}&mime=${encodeURIComponent(mimeOf(file.name))}${shape === null ? "" : `&width=${shape.width}&height=${shape.height}`}`;
    const answer = await this.link.ask("POST", `/conversations/${encodeURIComponent(conversation)}/files?${query}`, bytes);
    const id = answer.status < 300 ? JSON.parse(answer.body.toString())?.file?.id : undefined;
    if (typeof id !== "string") throw new Error(`the server did not take ${file.name} (${answer.status}: ${answer.body.toString().slice(0, 200)})`);
    return id;
  }

  private async send(conversation: string, text: string, files: string[]): Promise<GroupMessage> {
    const body: Json = { id: randomUUID() };
    if (text !== "") body.text = text;
    if (files.length > 0) body.files = files;
    const answer = await this.link.ask("POST", `/conversations/${encodeURIComponent(conversation)}/messages`, body);
    const message = answer.status < 300 ? JSON.parse(answer.body.toString())?.message : undefined;
    if (typeof message?.n !== "number") throw new Error(`the server did not take the message (${answer.status}: ${answer.body.toString().slice(0, 200)})`);
    this.threads.took(this.connect, conversation, message.n);
    return message;
  }

  /// The agent's words (a card's question and options with them) and its files, as one message where they fit; its
  /// number stands for the whole.
  async post(thread: ThreadRef, message: string, files: Attachment[], card?: Json | null): Promise<string> {
    const conversation = thread.threadTs;
    let text = message;
    let options: string[] | null = null;
    if (card && (card.type === "options" || card.type === "text")) {
      const said = cardWords(message, card);
      text = said.words;
      options = said.options;
      this.asked.delete(conversation);
    }
    const ids: string[] = [];
    for (const file of files) ids.push(await this.upload(conversation, file));
    const parts = text === "" ? [""] : splitForSlack(text, CHARS_MOST);
    let first: GroupMessage | null = null;
    for (const [i, part] of parts.entries()) {
      const sent = await this.send(conversation, part, i === 0 ? ids : []);
      first ??= sent;
    }
    if (first === null) throw new Error("nothing to post");
    if (options !== null && options.length > 0) this.asked.set(conversation, { ts: String(first.n), options });
    return String(first.n);
  }

  async download(file: InboundFile): Promise<Uint8Array> {
    const at = file.url?.indexOf("/") ?? -1;
    if (file.url === null || at < 0) throw new Error("the server does not give its contents");
    const answer = await this.link.ask("GET", `/conversations/${encodeURIComponent(file.url.slice(0, at))}/files/${encodeURIComponent(file.url.slice(at + 1))}`);
    if (answer.status !== 200) throw new Error(`the server answered ${answer.status} for ${file.name}`);
    return answer.body;
  }

  private messageOf(m: GroupMessage, conversation: string): ChatMessage {
    const files: InboundFile[] = (m.files ?? []).map((f) => ({ id: f.id, name: f.name || f.id, size: f.size ?? 0, url: `${conversation}/${f.id}` }));
    return { ts: String(m.n), user: m.from, text: m.text, fromBot: m.from === this.botUserId(), ...(files.length > 0 ? { files } : {}) };
  }

  /// What the conversation said before `before` (a message's number), its last `limit`.
  history(thread: ThreadRef, before: string, limit: number): Promise<ChatMessage[]> {
    return (async () => {
      const n = Number(before);
      const most = Math.max(1, Math.min(READ_MOST, Math.trunc(limit)));
      const query = Number.isSafeInteger(n) && n > 0 ? `last=${most}&before=${n}` : `last=${most}`;
      const answer = await this.link.ask("GET", `/conversations/${encodeURIComponent(thread.threadTs)}/messages?${query}`);
      if (answer.status !== 200) return [];
      const messages: GroupMessage[] = JSON.parse(answer.body.toString())?.messages ?? [];
      return messages.filter((m) => m.deleted === undefined).map((m) => this.messageOf(m, thread.threadTs));
    })();
  }

  /// The message a reply quotes; null for the bot's own and where it cannot be read.
  async quoted(thread: ThreadRef, ts: string): Promise<ChatMessage | null> {
    try {
      const n = Number(ts);
      if (!Number.isSafeInteger(n) || n < 1) return null;
      const answer = await this.link.ask("GET", `/conversations/${encodeURIComponent(thread.threadTs)}/messages?last=1&before=${n + 1}`);
      const m: GroupMessage | undefined = answer.status === 200 ? JSON.parse(answer.body.toString())?.messages?.[0] : undefined;
      if (m === undefined || m.n !== n || m.from === this.botUserId() || m.deleted !== undefined) return null;
      return this.messageOf(m, thread.threadTs);
    } catch {
      return null;
    }
  }

  /// The groups it is in.
  async places(): Promise<Place[]> {
    return (await this.listed()).filter((c) => c.kind === "group").map((c) => ({ id: c.id, name: c.name ?? c.id, kind: "group" as const }));
  }

  async peopleIn(channel: string): Promise<Member[]> {
    const c = await this.conversationOf(channel);
    if (this.members.size === 0) await this.readMembers().catch(() => {});
    return (c?.members ?? []).filter((m) => m !== this.botUserId()).map((m) => ({ id: m, name: this.members.get(m) ?? m }));
  }

  /// The group's conversation from now on, begun with `message`.
  async begin(channel: string, message: string): Promise<{ thread: ThreadRef; ts: string }> {
    const thread = { channel, threadTs: channel };
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

  /// A group's name; a private chat's the other member's.
  knownChannel(channel: string): string | null {
    const read = async () => {
      const c = await this.conversationOf(channel);
      if (c === null) return null;
      if (c.kind === "group") return c.name;
      const other = c.members.find((m) => m !== this.botUserId());
      return other === undefined ? null : ((await this.lookUp(other))?.name ?? null);
    };
    if (!this.book) return this.conversations.get(channel)?.name ?? null;
    return this.book.channel(channelKey(this.connect, channel), read);
  }

  async channelName(channel: string): Promise<string | null> {
    const c = await this.conversationOf(channel);
    return c?.kind === "group" ? c.name : null;
  }

  protected statusLine(): StatusLine {
    return new Quiet(this.run, 60_000);
  }
}

/// A picture's size, read of its head (PNG, GIF, JPEG, WebP), so the server can say it before it is fetched; null for
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
