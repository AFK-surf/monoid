// Where a Feishu chat's words go (「会话怎么分」), kept in <data>/feishu-threads.json: for each chat, the
// message its conversation began with (the thread's ts: what is said in the chat outside topics is one conversation,
// until someone starts a new one), and for each topic its first message (what the station replies to, to answer in it).
import { readFileSync } from "node:fs";
import { PrivateFile } from "../ops/files.ts";
import { log } from "../ops/log.ts";

type Kept = Record<string, { chats?: Record<string, string>; topics?: Record<string, string>; seen?: Record<string, number> }>;
type Receiving = { latest: number; pending: Map<string | symbol, { before: number; reading?: boolean }> };

export class FeishuThreads {
  readonly path: string;
  private readonly file: PrivateFile;
  private kept: Kept = {};
  private receiving = new Map<string, Receiving>();

  constructor(path: string) {
    this.path = path;
    this.file = new PrivateFile(path);
    try {
      const v = JSON.parse(readFileSync(path, "utf8")); // sync: read once, before the station serves
      if (v !== null && typeof v === "object" && !Array.isArray(v)) this.kept = v;
    } catch (error) {
      if ((error as NodeJS.ErrnoException).code !== "ENOENT") log.warn("feishu", "feishu threads file unreadable; starting empty", { error: (error as Error).message });
    }
  }

  private of(connect: string) {
    const at = (this.kept[connect] ??= {});
    at.chats ??= {};
    at.topics ??= {};
    at.seen ??= {};
    return at as { chats: Record<string, string>; topics: Record<string, string>; seen: Record<string, number> };
  }

  /// Kept in memory at once, written off the main thread (those asked while a write is on its way: the latest after it).
  private save() {
    this.file.write(JSON.stringify(this.kept)).catch((error) => {
      log.warn("feishu", "feishu threads not kept", { error: (error as Error).message });
    });
  }

  /// Once what was changed is written.
  written(): Promise<void> {
    return this.file.written();
  }

  /// The conversation a chat is in now, if it has begun one.
  current(connect: string, chat: string): string | null {
    return this.kept[connect]?.chats?.[chat] ?? null;
  }

  /// A conversation of the chat begins with `message`.
  begin(connect: string, chat: string, message: string) {
    this.of(connect).chats[chat] = message;
    this.save();
  }

  /// The chats with a conversation, and each one's safe reconnect position (ms): what is read again after the
  /// station was away (Feishu does not send what was said meanwhile).
  conversations(connect: string): [string, number][] {
    const at = this.kept[connect];
    return Object.keys(at?.chats ?? {}).map((chat) => [chat, at?.seen?.[chat] ?? 0]);
  }

  /// A message said at `when` was heard in `chat` (kept when it is the latest).
  heard(connect: string, chat: string, when: number) {
    const seen = this.of(connect).seen;
    if (!(when > (seen[chat] ?? 0))) return;
    seen[chat] = when;
    this.save();
  }

  /// A delivery holds the reconnect cursor before itself until the hub keeps it. A failure leaves it held for retry;
  /// a newer delivery finishing first cannot skip it. Only the safe cursor is written, so a restart reads it again.
  taking(connect: string, chat: string, message: string, when: number): () => void {
    if (!(when > 0)) return () => {};
    const finish = this.hold(connect, chat, message, when - 1);
    return () => finish(when);
  }

  /// Live events must not move the cursor past history still being read. A bounded page run keeps its last position
  /// held until a later catch-up takes it up. Each run owns its hold, including overlapping reconnects.
  catchingUp(connect: string, chat: string, since: number): (through: number, complete: boolean) => void {
    const finish = this.hold(connect, chat, Symbol("catch-up"), since);
    return (through, complete) => finish(through, complete ? undefined : Math.max(since, through - 1));
  }

  private hold(connect: string, chat: string, id: string | symbol, before: number) {
    const key = `${connect}\0${chat}`;
    let at = this.receiving.get(key);
    if (!at) this.receiving.set(key, at = { latest: this.of(connect).seen[chat] ?? before, pending: new Map() });
    // Only a history run can take up ended runs. Never release a run that was still reading when this one began:
    // its connection may have newer history than this request's snapshot, even if it ends first.
    const ended = typeof id === "symbol" ? [...at.pending].filter(([, held]) => held.reading === false) : [];
    let held = at.pending.get(id);
    if (!held) at.pending.set(id, held = { before, ...(typeof id === "symbol" ? { reading: true } : {}) });
    const checkpoint = () => {
      let safe = at.latest;
      for (const pending of at.pending.values()) safe = Math.min(safe, pending.before);
      const seen = this.of(connect).seen;
      if (seen[chat] !== safe) { seen[chat] = safe; this.save(); }
      if (at.pending.size === 0) this.receiving.delete(key);
    };
    checkpoint();
    return (when: number, keepBefore?: number) => {
      // A duplicate may have been kept by another concurrent delivery already.
      if (at.pending.get(id) !== held) return;
      at.latest = Math.max(at.latest, when);
      for (const [old, pending] of ended) if (at.pending.get(old) === pending) at.pending.delete(old);
      if (typeof id === "symbol") held.reading = false;
      if (keepBefore === undefined) at.pending.delete(id);
      else held.before = Math.max(held.before, keepBefore);
      checkpoint();
    };
  }

  /// A topic's first message, once heard.
  topicRoot(connect: string, topic: string): string | null {
    return this.kept[connect]?.topics?.[topic] ?? null;
  }

  heardTopic(connect: string, topic: string, root: string) {
    const topics = this.of(connect).topics;
    if (topics[topic] === root) return;
    topics[topic] = root;
    this.save();
  }
}
