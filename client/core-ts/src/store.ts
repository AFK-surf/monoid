// Topics: their current values, who subscribes, and when a value goes out (store.rs).
//
// A topic comes alive with its first subscriber (the store calls the Source to start it) and is stopped a minute after
// its last one leaves; its value stays cached until then. `set` stores a value and schedules its emission; emissions
// are coalesced over COALESCE_MS, one window for all topics, so topics changed together go out together, in the order
// they changed; a topic's first value goes out on the next turn instead. A subscriber's first message is the whole
// value, the next ones only what changed (delta.ts), and an unchanged value sends nothing; one subscribed `from` another
// of its subscriptions to the same topic (a list's first rows, more of them asked now) gets its first value as what
// changed from that one's, not the whole of it again (#firstFrom); one asked again by a client that kept what it was
// sent as it let go of the topic (`have`: the token of what it holds, digest.ts `token`) gets `same` where it is that
// still, else what changed from that (#first).
// Code inside the core can
// `watch` a topic; a derived topic is `invalidate`d and computed by its source when its emission goes out. While no page
// is in view (`inView`), what changed is kept from the subscribers and goes out as one difference per topic once one is.
import { Effect } from "effect";
import { computed, observe, signal, tracking, untracked, type Derived, type Source as ReactiveSource } from "./reactive.ts";
import { type AnyOp, diffKeyed, heavier, type Kept, share, specOf } from "./collections.ts";
import { diff, largerThan, type Op } from "./delta.ts";
import { Moments } from "./clock.ts";
import { Output } from "./output.ts";
import { CoreError } from "./error.ts";
import type { Host } from "./host.ts";
import { t } from "./i18n.ts";
import * as present from "./present.ts";
import { topicDebug, topicKey, type ClientId, type CoreMessage, type RequestId, type Topic, type WireGen } from "./protocol.ts";
import { AuthGenTracker, topicScopeOf, type AuthBoundaryEvent } from "./auth-gen.ts";
import { DEVICE_GLOBAL_TOPIC_SET, evaluateTopicPolicy, isKnownTopic, KEPT_PER_CLIENT, sanitizeKeptValue, topicsWhere } from "./topic-policy.ts";
import { laterSleep, type Runner } from "./runtime.ts";
import { Kind, type Span, type Tracer } from "./trace.ts";
import { readAfresh } from "./markdown.ts";
import { spent, spentSince, timed } from "./spent.ts";
import { equal, sharedValue } from "./util.ts";
import { holds } from "./data.ts";
import { token } from "./digest.ts";
import { walked, walkingAs, work } from "./work.ts";

export const COALESCE_MS = 50;
export const EVICT_AFTER_MS = 60_000;
/// Topics of words typed (the `@` menu's, a search's): one let go of before the last of its kind is not made again till
/// it is asked again (#flushOf). Derived from `topic-policy.ts`.
export const ASKED_BY_WORDS: ReadonlySet<string> = topicsWhere((p) => p.askedByWords === true);
/// Expensive derived topics that should not recompute while idle during their eviction grace window (#flushOf).
/// Derived from `topic-policy.ts`.
const LAZY_WHEN_IDLE: ReadonlySet<string> = topicsWhere((p) => p.lazyWhenIdle === true);
/// A topic of words typed by its kind: its name and where it looks.
function wordsKind(topic: Topic): string {
  if (topic.topic === "chatSubchats") return `${topic.topic}\u0001${String(topic.station ?? "")}\u0001${String(topic.thread ?? "")}\u0001${String(topic.session ?? "")}`;
  if (topic.topic === "stationSearch") return `${topic.topic}\u0001${String(topic.station ?? "")}`;
  return `${topic.topic}\u0001${String(topic.scope ?? "")}`;
}
/// How many values let go of keeping them (`keep`) are remembered for a client (#kept), the least recently let go of
/// forgotten first: the app keeps the lists its places open on, a workspace's eight or so, its last 8 chats, and the
/// read-only topics of the pages, panels and cards it opened lately (apps/mbui/src/sfbase/source.mbt `topic_kept`,
/// `topic_policy_gen.mbt`; 96 of every name together, `kept_most_by`). One it keeps past these, asked again, is still
/// answered `same` where its value is the same object still (a token needs nothing remembered), and whole where it is not.
export { KEPT_PER_CLIENT };
/// The topics a page opens with, each first subscriber's wait for its first value a trace of its own (`<topic>.open`,
///): how long a chat took to show, and how much of that the core spent making it.
const OPENED = new Set(["chat"]);
/// Rounds of emissions that held the core this long are told (`core.flush`): what made the core busy as a page waited
/// for it. At most one a minute, saying how many there were and the worst of them: one a round was 1375 spans a phone
/// sent in two hours, more than anything else it sent (2026-10-31).
const FLUSH_HELD_MS = 50;
const FLUSH_TOLD_EVERY_MS = 60_000;
/// What an app acts on while none of its pages is in view (its notices, its icon's badge, a download ready saved, a
/// copy between stations: the topics it watches whatever page shows): these go out then too. Derived from `topic-policy.ts`.
const UNSEEN: ReadonlySet<string> = topicsWhere((p) => p.unseen === true);

/// A topic's value's token (digest.ts `token`): of the value object, nothing of it read; one that is no object, of its
/// content, hashed (counted: work.ts `versions`).
function tokenOf(v: unknown): string {
  if (v === null || typeof v !== "object") work.versions++;
  return token(v);
}

/// A value or the error a topic shows.
export type Value = { ok: unknown } | { err: CoreError };

export function sameValue(a: Value | undefined, b: Value | undefined): boolean {
  if (a === undefined || b === undefined) return a === b;
  if ("ok" in a) return "ok" in b && equal(a.ok, b.ok);
  return "err" in b && a.err.equals(b.err);
}

/// Whoever produces a kind of topic (the station module, the accounts module).
export interface Source {
  /// The topic got its first subscriber: fetch it and keep it current.
  start(topic: Topic): void;
  /// The topic is subscribed to or watched again in the while it is kept after the last went (not started anew).
  resume?(topic: Topic): void;
  /// The topic's last subscriber and watcher left (entering the eviction grace window).
  idle?(topic: Topic): void;
  /// Nobody has subscribed for a while: stop streams and timers for it.
  stop(topic: Topic): void;
  /// The current value of a topic marked stale, as it goes out; undefined while it has none.
  compute?(topic: Topic): Value | undefined;
  /// Whether a topic with no value yet waits on a station for it (nothing it shows is on the device), not only on what
  /// it is computed from being computed: its subscribers are told so (`waiting`).
  waits?(topic: Topic): boolean;
  /// The topic's first value has gone out to its subscribers: what only keeps it current from now on may start.
  opened?(topic: Topic): void;
}

/// Keeps a watched topic subscribed; `drop` lets the topic go like a UI unsubscribing.
export class Watch {
  #store: Store;
  #topic: Topic;
  #id: number;
  #dropped = false;
  constructor(store: Store, topic: Topic, id: number) {
    this.#store = store;
    this.#topic = topic;
    this.#id = id;
  }
  drop(): void {
    if (this.#dropped) return;
    this.#dropped = true;
    this.#store.unwatch(this.#topic, this.#id);
  }
}

type Entry = {
  topic: Topic;
  value?: Value;
  usage: ReactiveSource<number>;
  input: ReactiveSource<ReactiveInput>;
  read: Derived<Value | undefined>;
  selections: WeakMap<(value: Value | undefined) => unknown, WeakMap<object, Derived<unknown>>>;
  stop?: () => void;
  job?: () => void;
  /// What its source's objects were kept as in its value (collections.ts `share`): a source that keeps what it made and
  /// hands it again is given the object kept, by one lookup. Its own: another topic keeps the same object as another.
  kept?: Kept;
  /// The value last sent to the subscribers; the next emission is the difference to it.
  sent?: Value;
  /// What would go out of it changed without a subscriber (#sentHolds no longer): it needs output when a page next asks
  /// for it, not `sent`.
  outputDirty?: boolean;
  /// Its value changed while no page was in view: what changed goes out once one is (`inView`).
  unseen?: boolean;
  /// Who subscribes, and whether it takes keyed ops (collections.ts).
  subscribers: [ClientId, RequestId, boolean][];
  watchers: [number, () => void][];
  stale: boolean;
  emitScheduled: boolean;
  idle: number | null;
  /// How its value goes out (output.ts).
  output?: Output;
  /// A page's first subscriber waiting for its first value (OPENED): its trace, and what the core spent making it.
  opening?: { span: Span; workMs: number; computes: number; mdFrom: number; spentFrom: Record<string, number> };
  /// Its source told its first value went out (or was made where nobody subscribes): `Source.opened`, once.
  openedTold?: boolean;
  /// Its subscribers told it waits on a station (Source.waits), while it has no value.
  waiting?: boolean;
  /// Authoritative authorization and vault generations when `value`/`input`/`sent` were produced.
  authGen: number;
  vaultGen: number;
};

type ReactiveInput = { mode: "direct"; value?: Value } | { mode: "derived" };

type Out = { value: unknown } | { delta: AnyOp[] } | { error: CoreError };

function whole(v: Value): Out {
  return "ok" in v ? { value: v.ok } : { error: v.err };
}

function to(out: Out, id: RequestId, gen?: WireGen): CoreMessage {
  if ("value" in out) return gen ? { id, value: out.value, ...gen } : { id, value: out.value };
  if ("delta" in out) return gen ? { id, delta: out.delta, ...gen } : { id, delta: out.delta };
  return gen ? { id, error: out.error, ...gen } : { id, error: out.error };
}

export class Store {
  readonly host: Host;
  readonly runner: Runner;
  /// Authoritative `(account, workspace)` authorization generation and independent per-vault lock generation tracker.
  readonly authGen = new AuthGenTracker();
  readonly #topics = new Map<string, Entry>();
  readonly #subscriptions = new Map<string, Topic>();
  /// A keyed subscriber's `from` (`client/id` to the id of the client's other subscription), till its first value goes.
  readonly #from = new Map<string, RequestId>();
  /// A subscriber's `have` (`client/id` to the token of what it holds), till its first value goes (#first).
  readonly #have = new Map<string, string>();
  /// Connected clients registered with a connection instance id (`Core.connect`).
  readonly #connIds = new Map<ClientId, number>();
  /// Clients whose initial `{ id: 0, auth }` snapshot has not been emitted yet.
  readonly #pendingSnapshots = new Set<ClientId>();
  readonly #authNotReady = new Set<ClientId>();
  readonly #authFailed = new Set<ClientId>();
  readonly #deferredEmits = new Map<ClientId, { msg: CoreMessage; isRpc: boolean }[]>();
  /// Clients for which protected write RPCs must carry explicit `CallAuth` (all production hosts + `syncAuth` + auth-aware clients).
  readonly #authEnforced = new Set<ClientId>();
  /// Optional authorization gate checked before reading held data or computing/emitting topic values.
  #authorize: ((topic: Topic, authGen: number, vaultGen: number) => boolean) | null = null;
  /// What each client holds of the topics it let go of keeping them (`keep`), by topic key: the value it was last sent
  /// (sanitized for `station`/`profiles`/`stationPart(profiles)`), its token, and the `(authGen, vaultGen)` it belonged to.
  readonly #kept = new Map<ClientId, Map<string, { topic: Topic; ok: unknown; v: string; authGen: number; vaultGen: number }>>();
  /// Records `(conn, topicKey, topic, authGen, vaultGen)` per client for every `keep` token issued, so `#first` token
  /// fast-path (`tokenOf(value.ok) === have`) enforces client, connection, exact topicKey, and generation match even after `#kept` evicts past 96.
  readonly #tokenScope = new Map<ClientId, Map<string, { conn: number; key: string; topic: Topic; authGen: number; vaultGen: number }>>();
  #source: Source | null = null;
  #idleCount = 0;
  /// The topic of words typed let go of last, of each kind (wordsKind): kept made as any topic is (#flushOf).
  readonly #wordsLetGo = new Map<string, { key: string; topic: Topic }>();
  #watchCount = 0;
  #firstPending = new Map<string, Entry>();
  #updatesPending = new Map<string, Entry>();
  #pumping = false;
  /// Background work waiting till no page waits on the store (`answered`).
  #whenAnswered: (() => void)[] = [];
  #windowOpen = false;
  #soon = false;
  #held: ((topic: Topic) => unknown) | null = null;
  #release_: ((topic: Topic) => void) | null = null;
  /// One-shot callback invoked when a non-error `chats` topic value is emitted to an active subscriber;
  /// returning `true` consumes the hook (core.ts filters to the selected startup workspace).
  onFirstChats: ((scope: string) => boolean) | null = null;
  #clock = false;
  #clockOn = false;
  #shaped = false;
  #inView = true;
  /// The rounds that held the core since `core.flush` last went out: how many, for how long, and the worst.
  #heldRounds: { from: number; rounds: number; ms: number; worst: { ms: number; topics: number; slowest: string; slowestMs: number; parts: [string, number][] } | null } | null = null;

  readonly #tracer: Tracer | null;
  readonly #moments: Moments;

  constructor(host: Host, runner: Runner, tracer: Tracer | null = null) {
    this.host = host;
    this.runner = runner;
    this.#tracer = tracer;
    this.#moments = new Moments(() => host.nowMs(), runner);
    this.authGen.onBoundary((event) => this.#onAuthBoundary(event));
  }

  /// Registers a connected client with its unique connection instance id and emits (or schedules) the authoritative auth snapshot.
  /// When `ready` is false (production `Core.connect()` while `device/auth` `connSeq` is being persisted), no `{ id: 0, auth }`
  /// snapshot or conn-tagged message is emitted until `markClientAuthReady(client)` is called after persistence succeeds.
  registerClient(client: ClientId, connId: number, immediate = true, ready = true): void {
    this.#connIds.set(client, connId);
    if (!ready) {
      this.#authNotReady.add(client);
      this.#pendingSnapshots.add(client);
      return;
    }
    this.#authNotReady.delete(client);
    if (immediate) {
      this.#pendingSnapshots.delete(client);
      this.#deferredEmits.delete(client);
      this.host.emit(client, { id: 0, auth: this.authGen.snapshot(connId) });
      return;
    }
    this.#pendingSnapshots.add(client);
    this.runner.fork(Effect.yieldNow.pipe(Effect.andThen(Effect.sync(() => this.#flushAuthSnapshot(client)))));
  }

  /// Updates `client`'s `connId` before `markClientAuthReady` (e.g., if reloading `device/auth` discovered a higher persisted `connSeq`).
  updateClientConn(client: ClientId, connId: number): void {
    if (!this.#connIds.has(client)) return;
    this.#connIds.set(client, connId);
  }

  /// Marks `client`'s `connId` as durably persisted, emits the authoritative `{ id: 0, auth }` snapshot, and drains any
  /// deferred emissions. Any deferred message tagged with a stale `conn !== activeConn` is rejected as `auth_stale`
  /// (for RPCs, without `conn`) or dropped (for non-RPCs).
  markClientAuthReady(client: ClientId): void {
    const activeConn = this.#connIds.get(client);
    if (activeConn === undefined) return;
    const wasAuthFailed = this.#authFailed.has(client);
    this.#authNotReady.delete(client);
    this.#authFailed.delete(client);
    this.#flushAuthSnapshot(client);
    const queued = this.#deferredEmits.get(client);
    if (queued) {
      this.#deferredEmits.delete(client);
      for (const entry of queued) {
        const msgConn =
          "conn" in entry.msg && typeof (entry.msg as { conn?: unknown }).conn === "number"
            ? (entry.msg as { conn: number }).conn
            : undefined;
        if (msgConn !== undefined && msgConn !== activeConn) {
          if (entry.isRpc && "id" in entry.msg && typeof entry.msg.id === "number" && entry.msg.id > 0) {
            this.host.emit(client, { id: entry.msg.id, error: new CoreError("auth_stale", t("core-misc.auth.stale")) });
          }
          continue;
        }
        this.host.emit(client, entry.msg);
      }
    }
    if (wasAuthFailed) {
      for (const [at, topic] of this.#subscriptions) {
        const slash = at.indexOf("/");
        if (slash < 0 || Number(at.slice(0, slash)) !== client) continue;
        if (DEVICE_GLOBAL_TOPIC_SET.has(topic.topic)) continue;
        const entry = this.#topics.get(topicKey(topic));
        if (entry === undefined || entry.sent === undefined) continue;
        if (!this.#isAuthorized(topic)) continue;
        const id = Number(at.slice(slash + 1));
        const gen = this.#wireGen(client, topic);
        this.host.emit(client, to(whole(entry.sent), id, gen));
      }
    }
  }

  /// Whether `client`'s handshake `device/auth` persistence failed (and has not yet recovered via `syncAuth` or auto-retry).
  isAuthFailed(client: ClientId): boolean {
    return this.#authFailed.has(client);
  }

  /// Aborts an unpersisted handshake for `client`: marks `#authFailed` (preserving `#authEnforced`), never emits the
  /// unpersisted `connId`, fails only queued RPCs (`isRpc === true`) explicitly without `conn` (never misreporting
  /// subscription values as RPC errors), and clears handshake state so recovery can establish a fresh `connId`.
  failClientAuth(client: ClientId, _err: unknown): void {
    const queued = this.#deferredEmits.get(client);
    this.#authFailed.add(client);
    this.#deferredEmits.delete(client);
    this.#connIds.delete(client);
    this.#pendingSnapshots.delete(client);
    this.#authNotReady.delete(client);
    if (queued) {
      const seenRpc = new Set<number>();
      for (const { msg, isRpc } of queued) {
        if (isRpc && "id" in msg && typeof msg.id === "number" && msg.id > 0 && !seenRpc.has(msg.id)) {
          seenRpc.add(msg.id);
          this.host.emit(client, { id: msg.id, error: new CoreError("storage_failed", t("core-logic.status.db.full")) });
        }
      }
    }
  }

  /// Emits the `{ id: 0, auth }` snapshot for `client` if ready (`force` re-emits even when an
  /// earlier snapshot was already sent, e.g. when a UI attaches to a pre-started core).
  flushAuthSnapshot(client: ClientId, force = false): void {
    if (force) {
      if (this.#authFailed.has(client)) return;
      if (this.#connIds.has(client)) this.#pendingSnapshots.add(client);
    }
    this.#flushAuthSnapshot(client);
  }

  #flushAuthSnapshot(client: ClientId): void {
    if (this.#authNotReady.has(client)) return;
    if (!this.#pendingSnapshots.delete(client)) return;
    const connId = this.#connIds.get(client);
    if (connId === undefined) return;
    this.host.emit(client, { id: 0, auth: this.authGen.snapshot(connId) });
  }

  /// Emits `msg` to `client`, deferring until `device/auth` persistence completes if `client` is awaiting handshake
  /// persistence. If persistence failed (`#authFailed`), RPCs receive an explicit `storage_failed` error without `conn`,
  /// only conn-free device-global frames pass through, and all protected subscription frames are dropped. Once ready,
  /// any late message tagged with a stale `conn !== activeConn` is rejected as `auth_stale` (RPC) or dropped.
  emitClient(client: ClientId, msg: CoreMessage, isRpc = false, deviceGlobal = false): void {
    if (this.#authNotReady.has(client)) {
      let q = this.#deferredEmits.get(client);
      if (!q) this.#deferredEmits.set(client, (q = []));
      q.push({ msg, isRpc });
      return;
    }
    if (this.#authFailed.has(client)) {
      if (isRpc && "id" in msg && typeof msg.id === "number" && msg.id > 0) {
        this.host.emit(client, {
          id: msg.id,
          error: new CoreError("storage_failed", t("core-logic.status.db.full")),
        });
      } else if (deviceGlobal && !("conn" in msg && typeof (msg as { conn?: unknown }).conn === "number")) {
        this.host.emit(client, msg);
      }
      return;
    }
    const activeConn = this.#connIds.get(client);
    const msgConn =
      "conn" in msg && typeof (msg as { conn?: unknown }).conn === "number"
        ? (msg as { conn: number }).conn
        : undefined;
    if (activeConn !== undefined && msgConn !== undefined && msgConn !== activeConn) {
      if (isRpc && "id" in msg && typeof msg.id === "number" && msg.id > 0) {
        this.host.emit(client, { id: msg.id, error: new CoreError("auth_stale", t("core-misc.auth.stale")) });
      }
      return;
    }
    this.#flushAuthSnapshot(client);
    this.host.emit(client, msg);
  }

  /// Returns the connection instance id of a registered client (0 if unregistered).
  connOf(client: ClientId): number {
    return this.#connIds.get(client) ?? 0;
  }

  /// Marks a connected client as requiring explicit `CallAuth` on protected write RPCs.
  setAuthEnforced(client: ClientId): void {
    this.#authEnforced.add(client);
  }

  /// Whether protected write RPCs from `client` must carry explicit `CallAuth`.
  isAuthEnforced(client: ClientId): boolean {
    return this.#authEnforced.has(client);
  }

  /// Sets the authorization gate consulted before reading held records, computing derived topics, or writing back.
  setAuthorize(authorize: ((topic: Topic, authGen: number, vaultGen: number) => boolean) | null): void {
    this.#authorize = authorize;
  }

  /// Captures the current `(authGen, vaultGen)` for a topic so async producers can validate write-backs.
  readGen(topic: Topic): { authGen: number; vaultGen: number } {
    return { authGen: this.authGen.authGenOf(topic), vaultGen: this.authGen.vaultGenOf(topic) };
  }

  /// Whether `topic` is currently authorized to read/emit positive cached data (errors are never blocked).
  isAuthorized(topic: Topic): boolean {
    return this.#isAuthorized(topic);
  }

  #isAuthorized(topic: Topic): boolean {
    if (this.#authorize === null) return true;
    return this.#authorize(topic, this.authGen.authGenOf(topic), this.authGen.vaultGenOf(topic));
  }

  #wireGen(client: ClientId, topic: Topic): WireGen | undefined {
    const conn = this.#connIds.get(client);
    if (conn === undefined) return undefined;
    const scope = topicScopeOf(topic);
    const authGen = this.authGen.authGenOf(topic);
    if (scope.kind === "vault" || scope.kind === "vaultWorkspace") {
      const vaultGen = this.authGen.vaultGenOf(topic);
      return { conn, authGen, vaultGen };
    }
    return { conn, authGen };
  }

  #recordTokenScope(client: ClientId, topic: Topic, v: string, authGen: number, vaultGen: number): void {
    const conn = this.#connIds.get(client) ?? 0;
    let byClient = this.#tokenScope.get(client);
    if (byClient === undefined) this.#tokenScope.set(client, (byClient = new Map()));
    const key = topicKey(topic);
    const entryKey = `${key}\u0001${v}`;
    byClient.delete(entryKey);
    byClient.set(entryKey, { conn, key, topic, authGen, vaultGen });
    if (byClient.size > KEPT_PER_CLIENT * 4) {
      byClient.delete(byClient.keys().next().value!);
    }
  }

  #tokenMatchesScope(client: ClientId, topic: Topic, v: string, authGen: number, vaultGen: number): boolean {
    const byClient = this.#tokenScope.get(client);
    if (!byClient) return false;
    const key = topicKey(topic);
    const rec = byClient.get(`${key}\u0001${v}`);
    if (!rec) return false;
    const conn = this.#connIds.get(client) ?? 0;
    return rec.conn === conn && rec.key === key && rec.authGen === authGen && rec.vaultGen === vaultGen;
  }

  /// Invalidates the entire projection pipeline (entry.sent, entry.input, entry.value, entry.read,
  /// pending queues, #kept, #from, #have) for all topics matching `event`, leaving unrelated scopes untouched.
  #onAuthBoundary(event: AuthBoundaryEvent): void {
    for (const [key, entry] of this.#topics) {
      if (!this.authGen.matches(entry.topic, event)) continue;
      entry.sent = undefined;
      entry.value = undefined;
      entry.kept = undefined;
      entry.output?.stop();
      entry.output = undefined;
      entry.outputDirty = true;
      entry.stale = true;
      entry.waiting = false;
      entry.authGen = this.authGen.authGenOf(entry.topic);
      entry.vaultGen = this.authGen.vaultGenOf(entry.topic);
      entry.input.set({ mode: "derived" });
      if (this.#firstPending.get(key) === entry) this.#firstPending.delete(key);
      if (this.#updatesPending.get(key) === entry) this.#updatesPending.delete(key);
      for (const [client, id] of entry.subscribers) {
        const at = `${client}/${id}`;
        this.#from.delete(at);
        this.#have.delete(at);
      }
      if (entry.subscribers.length > 0) {
        entry.emitScheduled = true;
        this.#updatesPending.set(key, entry);
        this.#wakePending(false);
      } else {
        entry.emitScheduled = false;
      }
    }
    for (const kept of this.#kept.values()) {
      for (const [key, rec] of [...kept]) {
        if (this.authGen.matches(rec.topic, event)) kept.delete(key);
      }
    }
    for (const byClient of this.#tokenScope.values()) {
      for (const [key, rec] of [...byClient]) {
        if (this.authGen.matches(rec.topic, event)) byClient.delete(key);
      }
    }
    for (const [kind, rec] of [...this.#wordsLetGo]) {
      if (this.authGen.matches(rec.topic, event)) this.#wordsLetGo.delete(kind);
    }
    for (const [client, connId] of this.#connIds) {
      if (this.#authNotReady.has(client)) continue;
      if (this.#pendingSnapshots.delete(client)) {
        this.host.emit(client, { id: 0, auth: this.authGen.snapshot(connId) });
      } else {
        this.host.emit(client, { id: 0, auth: this.authGen.toBoundaryMessage(connId, event) });
      }
    }
  }

  setSource(source: Source): void {
    this.#source = source;
  }

  /// Where the values of the data's topics are read (data.ts): they have no value of their own here. `release` is told
  /// when such a topic goes (what was loaded for it can go).
  setHeld(held: (topic: Topic) => unknown, release?: (topic: Topic) => void): void {
    this.#held = held;
    this.#release_ = release ?? null;
  }

  #heldValue(topic: Topic): unknown {
    return this.#held ? this.#held(topic) : undefined;
  }

  #start(topic: Topic): void {
    this.#source?.start(topic);
    // A held topic goes out as it is read when its emission goes (not read now: a list only watched is not loaded).
    if (this.#held !== null && holds(topic)) this.invalidate(topic);
  }

  /// A topic owns its signal nodes for precisely as long as the store owns the topic.
  #newEntry(topic: Topic): Entry {
    let entry: Entry;
    const usage = signal(0, () => this.#release(topic));
    const input = signal<ReactiveInput>({ mode: "direct" });
    const read = computed(() => {
      const authorized = this.#isAuthorized(topic);
      const curAuthGen = this.authGen.authGenOf(topic);
      const curVaultGen = this.authGen.vaultGenOf(topic);
      const state = input.get();
      if (state.mode === "direct") {
        if (entry.authGen !== curAuthGen || entry.vaultGen !== curVaultGen) return undefined;
        if (!authorized && state.value !== undefined && "ok" in state.value) return undefined;
        return state.value;
      }
      const computedValue = this.#compute(topic);
      if (computedValue !== undefined) {
        if (!authorized && "ok" in computedValue) return undefined;
        return computedValue;
      }
      if (entry.authGen !== curAuthGen || entry.vaultGen !== curVaultGen) return undefined;
      if (!authorized && entry.value !== undefined && "ok" in entry.value) return undefined;
      return entry.value;
    });
    entry = {
      topic,
      usage,
      input,
      read,
      selections: new WeakMap(),
      subscribers: [],
      watchers: [],
      stale: false,
      emitScheduled: false,
      idle: null,
      authGen: this.authGen.authGenOf(topic),
      vaultGen: this.authGen.vaultGenOf(topic),
    };
    return entry;
  }

  /// The data changed a topic's value: it goes out, and whatever watches it hears now.
  changed(topic: Topic): void {
    this.invalidate(topic);
    const entry = this.#topics.get(topicKey(topic));
    if (!entry) return;
    for (const [, w] of [...entry.watchers]) w();
  }

  /// Adds a subscriber; sends the cached value at once if there is one, and starts the topic if it was not live.
  subscribe(
    client: ClientId,
    id: RequestId,
    topic: Topic,
    keyed = false,
    from?: RequestId,
    have?: string,
    clientGen?: WireGen,
  ): void {
    this.unsubscribe(client, id);
    const key = topicKey(topic);
    this.#subscriptions.set(`${client}/${id}`, topic);
    const curAuthGen = this.authGen.authGenOf(topic);
    const curVaultGen = this.authGen.vaultGenOf(topic);
    const conn = this.#connIds.get(client);
    const clientGenOk =
      clientGen === undefined ||
      ((clientGen.conn === undefined || conn === undefined || clientGen.conn === conn) &&
        (clientGen.authGen === undefined || clientGen.authGen === curAuthGen) &&
        (clientGen.vaultGen === undefined || clientGen.vaultGen === curVaultGen));
    if (clientGenOk) {
      if (keyed && from !== undefined) this.#from.set(`${client}/${id}`, from);
      if (have !== undefined) this.#have.set(`${client}/${id}`, have);
    }
    let entry = this.#topics.get(key);
    const started = entry === undefined;
    if (!entry) {
      entry = this.#newEntry(topic);
      this.#topics.set(key, entry);
    }
    const resumed = entry.idle !== null;
    const authorized = this.#isAuthorized(topic);
    // Its last client output predates changes made while the page was closed, or a generation boundary.
    if (entry.authGen !== curAuthGen || entry.vaultGen !== curVaultGen || !authorized) {
      entry.sent = undefined;
      entry.value = undefined;
      entry.outputDirty = true;
      entry.stale = true;
      entry.authGen = curAuthGen;
      entry.vaultGen = curVaultGen;
      entry.input.set({ mode: "derived" });
    } else if (entry.outputDirty && entry.subscribers.length === 0) {
      entry.sent = undefined;
    }
    entry.subscribers.push([client, id, keyed]);
    entry.idle = null;
    const cached = authorized ? entry.sent : undefined;
    if (cached === undefined && this.#updatesPending.get(key) === entry) {
      this.#updatesPending.delete(key);
      this.#firstPending.set(key, entry);
      this.#wakePending(true);
    }
    const deviceGlobal = DEVICE_GLOBAL_TOPIC_SET.has(topic.topic);
    if (cached !== undefined) {
      const gen = this.#wireGen(client, topic);
      this.emitClient(client, this.#first(client, id, topic, keyed, cached, gen) ?? to(whole(cached), id, gen), false, deviceGlobal);
    } else {
      if (entry.waiting === true) {
        const gen = this.#wireGen(client, topic);
        this.emitClient(client, gen ? { id, waiting: true, ...gen } : { id, waiting: true }, false, deviceGlobal);
      }
      if (entry.opening === undefined && this.#tracer !== null && OPENED.has(topic.topic)) {
        const span = this.#tracer.root(`${topic.topic}.open`, Kind.Internal);
        // (made anew, or kept from a page shown a moment ago and let go: its view made again either way)
        span.set("stillfail.anew", started);
        entry.opening = { span, workMs: 0, computes: 0, mdFrom: readAfresh.chars, spentFrom: { ...spent } };
      }
    }
    if (started) this.#start(topic);
    else {
      if (resumed) this.#source?.resume?.(topic);
      // A held topic only watched in the core so far (by a view) has never gone out: it does now, not when it next
      // changes (#flush sends nothing of one that has no subscriber).
      if (cached === undefined && this.#held !== null && holds(topic)) this.#sendHeld(entry);
    }
    if (entry.outputDirty && this.#held !== null && holds(topic)) {
      // Held values are read from Data, not kept in the entry while only watched.
      this.#sendHeld(entry);
    } else if (entry.outputDirty && !entry.emitScheduled) {
      entry.emitScheduled = true;
      this.#scheduleEmit(topic);
    }
    this.#tick();
  }

  /// Whether any page is in view (Attend.shown). While none is, what changes is not sent: an app behind draws nothing,
  /// and a phone's keeps every message for its first frame back, all of them handed on in it (a few minutes behind was
  /// a hundred differences of the same few topics; hours behind, a first frame the system gave up waiting for,
  /// 2026-11-02). In view
  /// again, each topic changed meanwhile sends one difference, to its value now.
  inView(on: boolean): void {
    if (on === this.#inView) return;
    this.#inView = on;
    if (!on) return;
    this.#moments.check();
    for (const entry of this.#topics.values()) {
      if (!entry.unseen) continue;
      entry.unseen = false;
      if (entry.emitScheduled) continue;
      entry.emitScheduled = true;
      this.#scheduleEmit(entry.topic);
    }
  }

  /// Re-checks waiting deadline moments against the wall clock (e.g. after wake/reconnect).
  checkMoments(): void {
    this.#moments.check();
  }

  /// Sends every value through its shape.
  setShaped(): void {
    this.#shaped = true;
  }

  /// Starts the minute clock: times in words go out fresh each minute while anything is shown. The clock's signals
  /// move on (present.ts `clockAt`); only what read a grain that changed is made again.
  setClock(): void {
    this.#clockOn = true;
    this.#tick();
  }

  #tick(): void {
    if (!this.#clockOn || this.#clock) return;
    this.#clock = true;
    const now = this.host.nowMs();
    const next = (Math.floor(now / 60_000) + 1) * 60_000 + 1000;
    this.runner.fork(
      laterSleep(Math.max(next - now, 0)).pipe(
        Effect.andThen(
          Effect.sync(() => {
            this.#clock = false;
            if (![...this.#topics.values()].some((e) => e.subscribers.length > 0 && present.ticks(e.topic))) return;
            const at = this.host.nowMs();
            present.clockAt({ now: at, offsetMin: this.host.utcOffsetMin(at) });
            this.#tick();
          }),
        ),
      ),
    );
  }

  /// What went out of a topic is out of date though its value is not (output.ts): it goes out again, shaped anew.
  #again(entry: Entry): void {
    if (this.#topics.get(topicKey(entry.topic)) !== entry || entry.emitScheduled) return;
    entry.emitScheduled = true;
    this.#scheduleEmit(entry.topic);
  }

  /// `keep`: the client keeps what it holds of the topic (protocol.ts): answered `{id, v}`, the token of that, the
  /// last message for `id`: what went to it before (a difference already on its way) it has applied by then. That value
  /// is remembered for the client (#kept), to send what changed from it as it asks again.
  unsubscribe(client: ClientId, id: RequestId, keep = false): void {
    const at = `${client}/${id}`;
    const topic = this.#subscriptions.get(at);
    if (!topic) {
      if (keep) this.host.emit(client, { id, v: null });
      return;
    }
    this.#subscriptions.delete(at);
    this.#from.delete(at);
    this.#have.delete(at);
    const entry = this.#topics.get(topicKey(topic));
    if (keep) {
      const known = isKnownTopic(topic.topic);
      const policy = known ? evaluateTopicPolicy(topic.topic, topic) : null;
      const gen = this.#wireGen(client, topic);
      const deviceGlobal = DEVICE_GLOBAL_TOPIC_SET.has(topic.topic);
      if ((policy !== null && (policy.sensitive || policy.retention === "live" || policy.keep <= 0)) || !this.#isAuthorized(topic)) {
        // Unconditional security ceiling: sensitive/live topics never retain kept values; still complete unsubscribe.
        this.emitClient(client, gen ? { id, v: null, ...gen } : { id, v: null }, false, deviceGlobal);
      } else {
        // (what went to it last: the value it holds, every message to it going out in order; none, where none went)
        const curAuthGen = this.authGen.authGenOf(topic);
        const curVaultGen = this.authGen.vaultGenOf(topic);
        const sameGen = entry !== undefined && entry.authGen === curAuthGen && entry.vaultGen === curVaultGen;
        const had = sameGen && entry.subscribers.some(([c, i]) => c === client && i === id) ? entry.sent : undefined;
        const sanitized = had !== undefined && "ok" in had ? sanitizeKeptValue(topic.topic, had.ok, topic) : undefined;
        const v = sanitized !== undefined ? tokenOf(sanitized) : null;
        if (sanitized !== undefined && v !== null) {
          this.#keep(client, topicKey(topic), topic, sanitized, v, curAuthGen, curVaultGen);
          this.#recordTokenScope(client, topic, v, curAuthGen, curVaultGen);
        }
        this.emitClient(client, gen ? { id, v, ...gen } : { id, v }, false, deviceGlobal);
      }
    }
    if (!entry) return;
    entry.subscribers = entry.subscribers.filter(([c, i]) => !(c === client && i === id));
    if (entry.subscribers.length === 0 && entry.sent === undefined && this.#firstPending.get(topicKey(topic)) === entry) {
      const key = topicKey(topic);
      this.#firstPending.delete(key);
      this.#updatesPending.set(key, entry);
    }
    if (entry.subscribers.length === 0 && entry.opening) {
      entry.opening.span.cancel();
      entry.opening = undefined;
    }
    this.#release(topic);
  }

  /// Subscribes from inside the core: starts the topic if it was not live and calls `onChange` after each change of
  /// it, until the watch is dropped.
  watch(topic: Topic, onChange: () => void): Watch {
    const key = topicKey(topic);
    const id = ++this.#watchCount;
    let entry = this.#topics.get(key);
    const started = entry === undefined;
    if (!entry) {
      entry = this.#newEntry(topic);
      this.#topics.set(key, entry);
    }
    const resumed = entry.idle !== null;
    entry.watchers.push([id, onChange]);
    entry.idle = null;
    if (started) this.#start(topic);
    else {
      if (resumed) this.#source?.resume?.(topic);
      if (entry.stale && !entry.emitScheduled) {
        entry.emitScheduled = true;
        this.#scheduleEmit(topic);
      }
    }
    return new Watch(this, topic, id);
  }

  unwatch(topic: Topic, id: number): void {
    const entry = this.#topics.get(topicKey(topic));
    if (!entry) return;
    entry.watchers = entry.watchers.filter(([w]) => w !== id);
    this.#release(topic);
  }

  /// Starts the eviction grace if nobody subscribes to or watches the topic any more.
  #release(topic: Topic): void {
    const idle = ++this.#idleCount;
    const entry = this.#topics.get(topicKey(topic));
    if (!entry || entry.subscribers.length > 0 || entry.watchers.length > 0 || entry.usage.hasSubscribers()) return;
    entry.idle = idle;
    this.#source?.idle?.(topic);
    if (ASKED_BY_WORDS.has(topic.topic)) this.#wordsLetGo.set(wordsKind(topic), { key: topicKey(topic), topic });
    this.runner.fork(laterSleep(EVICT_AFTER_MS).pipe(Effect.andThen(Effect.sync(() => this.#evict(topic, idle)))));
  }

  /// A UI went away: drops all its subscriptions, and what it kept of those it let go of.
  dropClient(client: ClientId): void {
    const ids = [...this.#subscriptions.keys()].filter((k) => k.startsWith(`${client}/`)).map((k) => Number(k.slice(k.indexOf("/") + 1)));
    for (const id of ids) this.unsubscribe(client, id);
    this.#kept.delete(client);
    this.#connIds.delete(client);
    this.#pendingSnapshots.delete(client);
    this.#authNotReady.delete(client);
    this.#authFailed.delete(client);
    this.#deferredEmits.delete(client);
    this.#authEnforced.delete(client);
    this.#tokenScope.delete(client);
  }

  /// Client `client` let go of topic `key` keeping `ok`, of token `v`: remembered for it (#kept), the least recently
  /// let go of forgotten past KEPT_PER_CLIENT.
  #keep(client: ClientId, key: string, topic: Topic, ok: unknown, v: string, authGen: number, vaultGen: number): void {
    let kept = this.#kept.get(client);
    if (kept === undefined) this.#kept.set(client, (kept = new Map()));
    kept.delete(key);
    kept.set(key, { topic, ok, v, authGen, vaultGen });
    if (kept.size > KEPT_PER_CLIENT) kept.delete(kept.keys().next().value!);
  }

  /// How many values are remembered for `client` (#kept), for tests.
  keptOf(client: ClientId): number {
    return this.#kept.get(client)?.size ?? 0;
  }

  /// Returns the sanitized kept value remembered for `client` and `topic` (for tests).
  keptValueOf(client: ClientId, topic: Topic): unknown {
    return this.#kept.get(client)?.get(topicKey(topic))?.ok;
  }

  /// Stores a topic's new value (or its error) and schedules sending it. A topic that is not live, unauthorized,
  /// or whose captured `expectedGen` is older than the current generation is ignored.
  set(topic: Topic, value: Value, expectedGen?: { authGen: number; vaultGen: number }): void {
    const entry = this.#topics.get(topicKey(topic));
    if (!entry) return;
    const curAuthGen = this.authGen.authGenOf(topic);
    const curVaultGen = this.authGen.vaultGenOf(topic);
    if (expectedGen && (expectedGen.authGen !== curAuthGen || expectedGen.vaultGen !== curVaultGen)) return;
    if ("ok" in value && !this.#isAuthorized(topic)) return;
    if ("ok" in value) sharedValue(value.ok);
    entry.authGen = curAuthGen;
    entry.vaultGen = curVaultGen;
    entry.value = value;
    const schedule = !entry.emitScheduled;
    entry.emitScheduled = true;
    const watchers = entry.watchers.map(([, w]) => w);
    if (schedule) this.#scheduleEmit(topic);
    entry.input.set({ mode: "direct", value });
    for (const w of watchers) w();
  }

  /// Replaces a topic's value by what `change` makes of it (a new value: the one kept is shared, and never changed in
  /// place), then schedules sending it. Does nothing if the topic has no value yet or generation changed.
  update(topic: Topic, change: (value: unknown) => unknown, expectedGen?: { authGen: number; vaultGen: number }): void {
    const entry = this.#topics.get(topicKey(topic));
    if (!entry || !entry.value || !("ok" in entry.value)) return;
    const curAuthGen = this.authGen.authGenOf(topic);
    const curVaultGen = this.authGen.vaultGenOf(topic);
    if (expectedGen && (expectedGen.authGen !== curAuthGen || expectedGen.vaultGen !== curVaultGen)) return;
    if (entry.authGen !== curAuthGen || entry.vaultGen !== curVaultGen || !this.#isAuthorized(topic)) return;
    entry.value = { ok: sharedValue(change(entry.value.ok)) };
    const schedule = !entry.emitScheduled;
    entry.emitScheduled = true;
    const watchers = entry.watchers.map(([, w]) => w);
    if (schedule) this.#scheduleEmit(topic);
    entry.input.set({ mode: "direct", value: entry.value });
    for (const w of watchers) w();
  }

  /// Marks a live topic's value out of date and schedules its emission.
  invalidate(topic: Topic): void {
    const entry = this.#topics.get(topicKey(topic));
    if (!entry) return;
    entry.stale = true;
    entry.input.set({ mode: "derived" });
    const schedule = !entry.emitScheduled;
    entry.emitScheduled = true;
    if (schedule) this.#scheduleEmit(topic);
  }

  /// A held topic's value goes out to its subscribers as it is now: read as its emission goes (#flush, `stale`), from
  /// Data, or what its source says where Data holds nothing. What reads it in the core is not told it changed: it reads
  /// it from Data too (value()) and was told of each change as Data made it (changed), so it has what goes out already.
  /// (`invalidate` here made every view that read it again, nothing changed: the app subscribing a workspace's record,
  /// which the views of its chat list and marks read, made the marks of the workspace just left again, 8 ms in Hermes
  /// on a Mac Studio, 2026-11-11.)
  #sendHeld(entry: Entry): void {
    entry.stale = true;
    if (entry.emitScheduled) return;
    entry.emitScheduled = true;
    this.#scheduleEmit(entry.topic);
  }

  /// Invalidates every live topic `pick` chooses.
  invalidateAll(pick: (topic: Topic) => boolean): void {
    for (const topic of this.liveTopics().filter(pick)) this.invalidate(topic);
  }

  #entryForRead(topic: Topic): Entry | undefined {
    const key = topicKey(topic);
    let entry = this.#topics.get(key);
    if (tracking()) {
      const started = entry === undefined;
      if (!entry) {
        entry = this.#newEntry(topic);
        this.#topics.set(key, entry);
      }
      entry.usage.get();
      const resumed = entry.idle !== null;
      entry.idle = null;
      if (started) untracked(() => this.#start(topic));
      else if (resumed) {
        untracked(() => {
          this.#source?.resume?.(topic);
          if (entry!.stale && !entry!.emitScheduled) {
            entry!.emitScheduled = true;
            this.#scheduleEmit(topic);
          }
        });
      }
    }
    return entry;
  }

  /// The topic's value or error; undefined while it has neither or while unauthorized for positive data.
  value(topic: Topic): Value | undefined {
    const entry = this.#entryForRead(topic);
    const authorized = this.#isAuthorized(topic);
    // Held values come straight from Data, but changes to their topics must still invalidate their readers.
    const held = authorized ? this.#heldValue(topic) : undefined;
    if (entry && (held !== undefined || (this.#held !== null && holds(topic)))) void entry.input.get();
    if (held !== undefined) {
      return { ok: held };
    }
    if (!authorized) {
      if (entry) {
        const cur = entry.value;
        if (cur !== undefined && "err" in cur) return cur;
        void entry.input.get();
      }
      return undefined;
    }
    const value = entry?.read.get();
    if (value === undefined) return undefined;
    if ("err" in value) return value;
    // With a data center, a value of its topics here is only what was last sent.
    return this.#held !== null && holds(topic) ? undefined : value;
  }

  /// Reads one part of a topic. A reader is only made again if the selected part changes.
  select<T>(topic: Topic, pick: (value: Value | undefined) => T, same: (a: T, b: T) => boolean = equal): T {
    const entry = this.#entryForRead(topic);
    if (!entry) return pick(this.value(topic));
    let selections = entry.selections.get(pick);
    if (!selections) {
      selections = new WeakMap();
      entry.selections.set(pick, selections);
    }
    let selected = selections.get(same) as Derived<T> | undefined;
    if (!selected) {
      let made = false;
      let previous: T;
      selected = computed(() => {
        const next = pick(this.value(topic));
        if (made && same(previous, next)) return previous;
        made = true;
        return (previous = next);
      });
      selections.set(same, selected as Derived<unknown>);
    }
    return selected.get();
  }

  get(topic: Topic): unknown {
    const v = this.value(topic);
    return v && "ok" in v ? v.ok : undefined;
  }

  /// Whether a UI subscribes to the topic now.
  subscribed(topic: Topic): boolean {
    return (this.#topics.get(topicKey(topic))?.subscribers.length ?? 0) > 0;
  }

  /// Whether anything shows the topic now: a UI subscribes to it, or a view built from it is watched (a page open).
  inUse(topic: Topic): boolean {
    const entry = this.#topics.get(topicKey(topic));
    return entry !== undefined && (entry.subscribers.length > 0 || entry.watchers.length > 0 || entry.usage.hasSubscribers());
  }

  /// Whether a newly opened view is waiting for its first value to be made.
  firstValuesPending(): boolean {
    return this.#firstPending.size > 0;
  }

  /// Whether a page waits on the store: a first value to be made, or, while the pump runs, a change of a topic
  /// something subscribes to or watches (#nextUpdate) that it is to send in that run.
  #pagesWait(): boolean {
    return this.#firstPending.size > 0 || (this.#pumping && this.#nextUpdate(false) !== undefined);
  }

  /// Background work's turn (the rows of a list loaded behind its first screen, the sync's slices): at once where no page
  /// waits on the store (#pagesWait), else once the pump has sent what pages wait for. The pump yields to the JS loop
  /// between topics so that what comes in (a UI's message, a host's answer) is taken, and that yield cannot tell the
  /// core's other fibers from what came in: each fiber's yield is a turn of the loop of its own (Effect's scheduler a
  /// `setImmediate` a fiber, in Hermes hermes-globals.ts's `setTimeout(0)`, run in the engine's queue in the order set
  /// among the tasks posted to it). So work no page waits for waits here itself, told by the pump as it is done (never
  /// a poll), before each step it takes; it goes on a turn of its own after that, not on the pump's.
  answered(): Effect.Effect<void> {
    return Effect.suspend(() => {
      if (!this.#pagesWait()) return Effect.void;
      return Effect.callback<void>((resume) => {
        this.#whenAnswered.push(() => resume(Effect.yieldNow));
      }).pipe(Effect.andThen(this.answered()));
    });
  }

  /// A background step's turn: the JS loop's next (what came in is taken), and then `answered`.
  turn(): Effect.Effect<void> {
    return Effect.andThen(Effect.yieldNow, this.answered());
  }

  /// No page waits on the store any more: the background work waiting for it (`answered`) goes on.
  #answered(): void {
    if (this.#whenAnswered.length === 0 || this.#pagesWait()) return;
    const waiting = this.#whenAnswered;
    this.#whenAnswered = [];
    for (const go of waiting) go();
  }

  /// Topics with at least one subscriber (or within their eviction grace).
  liveTopics(): Topic[] {
    return [...this.#topics.values()].map((e) => e.topic);
  }

  #scheduleEmit(topic: Topic): void {
    const key = topicKey(topic);
    const entry = this.#topics.get(key);
    if (!entry) return;
    const first = entry.sent === undefined && entry.openedTold !== true && entry.subscribers.length > 0;
    this.#firstPending.delete(key);
    this.#updatesPending.delete(key);
    (first ? this.#firstPending : this.#updatesPending).set(key, entry);
    this.#wakePending(first);
  }

  #wakePending(first: boolean): void {
    if (this.#pumping) return;
    if (first) {
      if (this.#soon) return;
      this.#soon = true;
    } else {
      if (this.#windowOpen) return;
      this.#windowOpen = true;
    }
    this.runner.fork((first ? Effect.yieldNow : Effect.sleep(COALESCE_MS)).pipe(Effect.andThen(this.#flushPending())));
  }

  #flushPending(): Effect.Effect<void> {
    return Effect.gen({ self: this }, function* () {
      if (this.#pumping) return;
      this.#pumping = true;
      this.#windowOpen = false;
      this.#soon = false;
      let wasFirst = false;
      try {
        while (this.#firstPending.size > 0 || this.#updatesPending.size > 0) {
          // A new page takes its turn immediately after background work; alternating while both queues have work
          // also gives already queued updates a turn if pages keep opening. An update of a topic nobody subscribes
          // to or watches (let go of, kept a while for its page coming back) waits behind both: the marks of a
          // workspace just left were made again, 8 ms in Hermes, ahead of the chat list and the jobs of the one
          // switched to (2026-11-11).
          const update = this.#nextUpdate(this.#firstPending.size === 0);
          const first: boolean = this.#firstPending.size > 0 && (update === undefined || !wasFirst);
          const [key, entry] = first ? this.#firstPending.entries().next().value! : update!;
          (first ? this.#firstPending : this.#updatesPending).delete(key);
          if (this.#topics.get(key) !== entry || !entry.emitScheduled) continue;
          wasFirst = first;
          const topic = entry.topic;
          const t0 = this.host.monotonicMs();
          const spentFrom = this.#tracer !== null ? { ...spent } : null;
          this.#flush(topic);
          this.#heldFor(topic, t0, spentFrom);
          if (this.#firstPending.size > 0 || this.#updatesPending.size > 0) {
            // What comes in meanwhile is taken between topics (a subscribe arriving now answered in this run, in its
            // order; a run that goes on and on keeps no message out); the core's background work is not: it waits
            // for what pages wait for (`answered`), told here once that is out.
            this.#answered();
            yield* Effect.yieldNow;
          }
        }
      } finally {
        this.#pumping = false;
        this.#answered();
        if (!this.runner.closed) {
          if (this.#firstPending.size > 0) this.#wakePending(true);
          else if (this.#updatesPending.size > 0) this.#wakePending(false);
        }
      }
    });
  }

  /// The update to take next: the first queued of a topic something subscribes to or watches; else, with `idle`, the
  /// first queued at all.
  #nextUpdate(idle: boolean): [string, Entry] | undefined {
    for (const pending of this.#updatesPending) {
      const entry = pending[1];
      if (entry.subscribers.length > 0 || entry.watchers.length > 0) return pending;
    }
    return idle ? this.#updatesPending.entries().next().value : undefined;
  }

  #heldFor(topic: Topic, t0: number, spentFrom: Record<string, number> | null): void {
    const now = this.host.monotonicMs();
    const held = now - t0;
    if (held < FLUSH_HELD_MS || this.#tracer === null) return;
    // (the first told at once; then each a minute after the one before)
    const first = this.#heldRounds === null;
    const h = (this.#heldRounds ??= { from: now, rounds: 0, ms: 0, worst: null });
    h.rounds++;
    h.ms += held;
    if (h.worst === null || held > h.worst.ms) h.worst = { ms: held, topics: 1, slowest: topic.topic, slowestMs: held, parts: spentFrom ? spentSince(spentFrom) : [] };
    if (!first && now - h.from < FLUSH_TOLD_EVERY_MS) return;
    const span = this.#tracer.root("core.flush", Kind.Internal);
    span.set("stillfail.rounds", h.rounds);
    span.set("stillfail.rounds_ms", Math.round(h.ms));
    const w = h.worst!;
    span.set("stillfail.held_ms", Math.round(w.ms));
    span.set("stillfail.topics", w.topics);
    span.set("stillfail.slowest", w.slowest);
    span.set("stillfail.slowest_ms", Math.round(w.slowestMs));
    for (const [part, ms] of w.parts) span.set(`stillfail.ms.${part}`, Math.round(ms));
    span.end();
    this.#heldRounds = { from: now, rounds: 0, ms: 0, worst: null };
  }

  /// What the source makes of a topic now, kept shared (frozen when that is checked). A source that throws making it
  /// fails this topic, which says why, not the core and every other topic with it (a chat's view writing on a frozen
  /// message took the whole core down once, and the page stayed on 正在读取对话).
  #compute(topic: Topic): Value | undefined {
    let value: Value | undefined;
    // (what it walks counted to it: work.ts `walkingAs`)
    const was = walkingAs(topic.topic);
    walked.recomputes++;
    try {
      value = this.#source?.compute?.(topic);
    } catch (error) {
      console.error(`computing ${topicDebug(topic)} failed`, error);
      return { err: new CoreError("internal", t("core-misc.compute", { topic: topicDebug(topic), reason: error instanceof Error ? error.message : String(error) })) };
    } finally {
      walkingAs(was);
    }
    if (value !== undefined && "ok" in value) sharedValue(value.ok);
    return value;
  }

  #flush(topic: Topic): void {
    // (what making it and sending it walks counted to it: work.ts `walkingAs`)
    const was = walkingAs(topic.topic);
    try {
      this.#flushOf(topic);
    } finally {
      walkingAs(was);
    }
  }

  #flushOf(topic: Topic): void {
    const entry = this.#topics.get(topicKey(topic));
    if (!entry) return;
    if (entry.idle !== null && entry.stale && (LAZY_WHEN_IDLE.has(topic.topic) || (ASKED_BY_WORDS.has(topic.topic) && this.#wordsLetGo.get(wordsKind(topic))?.key !== topicKey(topic)))) {
      // Let go of, of words typed, other words let go of since (or lazy-when-idle topics such as `profilesOverview`):
      // made again only as it is asked again (subscribe: outputDirty / watch: resumed), never meanwhile; the words let
      // go of last are kept as any topic is, for the page that comes back to them. Each letter typed in the `@` menu
      // left a `chatSearch` of every workspace's chats, made again at every change of any chat for a minute, one after
      // another on the core's one thread (in Hermes, at a workspace of thousands of chats, seconds a change: a new chat's
      // send waited behind them, 2026-11-17).
      entry.emitScheduled = false;
      entry.outputDirty = true;
      return;
    }
    entry.emitScheduled = false;
    const stale = entry.stale;
    entry.stale = false;
    const job = entry.job;
    entry.job = undefined;
    job?.();
    const curAuthGen = this.authGen.authGenOf(topic);
    const curVaultGen = this.authGen.vaultGenOf(topic);
    const authorized = this.#isAuthorized(topic);
    if (entry.authGen !== curAuthGen || entry.vaultGen !== curVaultGen) {
      entry.value = undefined;
      entry.sent = undefined;
      entry.authGen = curAuthGen;
      entry.vaultGen = curVaultGen;
      entry.input.set({ mode: "derived" });
    }
    const isHeld = this.#held !== null && holds(topic);
    let computed: Value | undefined;
    const workFrom = entry.opening ? this.host.monotonicMs() : 0;
    if (stale) {
      if (isHeld && entry.subscribers.length === 0) {
        // Only watched: who watches it reads what is held (and heard of its changes as they were made); what is read
        // here is only what its source says when nothing is held (an error), so nothing is loaded for it.
        entry.outputDirty = true;
        const said = this.#compute(topic);
        const was = entry.value;
        if (said === undefined ? was === undefined || !("err" in was) : sameValue(was, said)) return;
        entry.value = said;
        for (const [, w] of [...entry.watchers]) w();
        return;
      }
      const held = authorized ? this.#heldValue(topic) : undefined;
      // A direct set after an invalidation is visible immediately; the queued recomputation still follows it.
      if (held === undefined && entry.input.get().mode !== "derived") entry.input.set({ mode: "derived" });
      if (held !== undefined) computed = { ok: held };
      else {
        entry.stop ??= observe(() => { entry.read.get(); }, (next) => {
          entry.job = next;
          // A direct write already schedules this entry; it only needs its observer refreshed.
          if (entry.input.get().mode === "direct" && !entry.stale) return;
          entry.stale = true;
          const schedule = !entry.emitScheduled;
          entry.emitScheduled = true;
          if (schedule) this.#scheduleEmit(topic);
        });
        computed = entry.read.get();
      }
    }
    const now = this.#topics.get(topicKey(topic));
    if (!now) return;
    if (this.authGen.authGenOf(topic) !== curAuthGen || this.authGen.vaultGenOf(topic) !== curVaultGen) {
      return;
    }
    if (!this.#isAuthorized(topic) && (computed === undefined || "ok" in computed) && (now.value === undefined || "ok" in now.value)) {
      now.value = undefined;
      now.sent = undefined;
      now.outputDirty = true;
      return;
    }
    let changed: (() => void)[] = [];
    // What equals the last value is the last value's (collections.ts share): what did not change goes on as the same
    // objects, which the diff and the items' shaping step over.
    // (only what goes out: what reads a topic in the core reads what its source made) What `share` did not give back as
    // the last value differs from it: not compared again.
    let shared = false;
    if (now.subscribers.length > 0 && computed !== undefined && "ok" in computed && now.value !== undefined && "ok" in now.value && now.value.ok !== computed.ok) {
      const kept = share(now.value.ok, computed.ok, specOf(topic), (now.kept ??= new WeakMap()));
      computed = kept === now.value.ok ? now.value : { ok: sharedValue(kept) };
      shared = true;
    }
    if (computed !== undefined && computed !== now.value && (shared || !sameValue(now.value, computed))) {
      // What is held tells its watchers as it changes (changed): only an error is news to them here.
      const news = !isHeld || "err" in computed || (now.value !== undefined && "err" in now.value);
      now.value = computed;
      if (news) changed = now.watchers.map(([, w]) => w);
    }
    if (now.value === undefined) {
      if (now.opening) {
        now.opening.workMs += this.host.monotonicMs() - workFrom;
        now.opening.computes++;
      }
      // Nothing to show yet: whoever shows it told once if that waits on a station, not on the core (a page opening
      // then shows what is to come at once, and otherwise waits for what the device holds).
      if (now.waiting !== true && now.subscribers.length > 0 && this.#source?.waits?.(topic) === true) {
        now.waiting = true;
        const deviceGlobal = DEVICE_GLOBAL_TOPIC_SET.has(topic.topic);
        for (const [client, id] of now.subscribers) {
          const gen = this.#wireGen(client, topic);
          this.emitClient(client, gen ? { id, waiting: true, ...gen } : { id, waiting: true }, false, deviceGlobal);
        }
        now.opening?.span.set("stillfail.waiting", true);
      }
      return;
    }
    now.waiting = false;
    if (now.subscribers.length === 0) {
      // Internal readers use the value above, not its client representation. Keep the last output for a reopening
      // page, and make the new one only when there is a subscriber to receive it. Out of date only where it is: a
      // value made again the same (a pref written at every switch of workspace, read whole by several views) left the
      // chat list it went into sent whole again as its page came back (69 KB, parsed on the app's frame thread), and
      // `profiles` shaped again (5 ms in Hermes, 2026-11-11). What is held is read from Data, not here: out of date.
      if (isHeld || !this.#sentHolds(now)) now.outputDirty = true;
      for (const w of changed) w();
      if (now.value !== undefined) this.#opened(now);
      return;
    }
    if (!this.#inView && now.sent !== undefined && !UNSEEN.has(topic.topic)) {
      // No page in view: what changed goes out once one is (inView), not shaped till then.
      now.unseen = true;
      for (const w of changed) w();
      return;
    }
    now.outputDirty = false;
    const nowMs = this.host.nowMs();
    const c: present.Clock = { now: nowMs, offsetMin: this.host.utcOffsetMin(nowMs), reached: (at, later) => this.#moments.reached(at, later) };
    let value: Value = now.value;
    if ("ok" in value) {
      // What is decorated is a copy (output.ts): not what is kept.
      now.output ??= new Output(() => this.#again(now));
      const output = now.output;
      const ok = value.ok;
      const out = timed(`${topic.topic}.shape`, () => output.shape(topic, ok, c, this.#shaped));
      value = "ok" in out ? { ok: out.ok } : { err: new CoreError("shape", t("core-misc.shape", { topic: topicDebug(topic), at: out.error })) };
    }
    // What goes out: to a subscriber taking keyed ops, its lists changed item by item; to the others, the old ops.
    let out: Out | null;
    let keyedOut: Out | null;
    const sent = now.sent;
    const subscribers = [...now.subscribers];
    if (sent !== undefined && "ok" in sent && "ok" in value) {
      const next = value.ok;
      const delta = (ops: Op[]): Out | null => (ops.length === 0 ? null : largerThan(ops, next) ? { value: next } : { delta: ops });
      const spec = specOf(topic);
      out = subscribers.some(([, , k]) => !k || !spec) ? delta(diff(sent.ok, next)) : null;
      if (spec && subscribers.some(([, , k]) => k)) {
        const ops = diffKeyed(sent.ok, next, spec);
        keyedOut = ops.length === 0 ? null : heavier(ops, next) ? { value: next } : { delta: ops };
      } else keyedOut = out;
    } else if (sent !== undefined && sameValue(sent, value)) out = keyedOut = null;
    else out = keyedOut = whole(value);
    now.sent = value;
    if (now.opening) {
      // Its first value going out: how long it took, and how much of it was the core making it (the rest it waited:
      // for what it is made from, or for the core busy with something else)
      const { span } = now.opening;
      const work = now.opening.workMs + this.host.monotonicMs() - workFrom;
      span.set("stillfail.work_ms", Math.round(work));
      span.set("stillfail.computes", now.opening.computes + 1);
      // (Markdown read afresh meanwhile, by it or by whatever else the core did: words not kept here nor on the device)
      span.set("stillfail.md_chars", readAfresh.chars - now.opening.mdFrom);
      // where the core's time went meanwhile, by part (spent.ts): this chat's making and whatever else ran
      for (const [part, ms] of spentSince(now.opening.spentFrom)) span.set(`stillfail.ms.${part}`, Math.round(ms));
      if ("err" in value) span.fail();
      span.end();
      now.opening = undefined;
    }
    for (const w of changed) w();
    const deviceGlobal = DEVICE_GLOBAL_TOPIC_SET.has(topic.topic);
    for (const [client, id, keyed] of subscribers) {
      const o = keyed ? keyedOut : out;
      const gen = this.#wireGen(client, topic);
      // (its first value: `same`, or what changed from what the client holds, where it says so)
      const first = sent === undefined ? this.#first(client, id, topic, keyed, value, gen) : null;
      if (first) this.emitClient(client, first, false, deviceGlobal);
      else if (o) this.emitClient(client, to(o, id, gen), false, deviceGlobal);
    }
    if (topic.topic === "chats" && !("err" in value) && this.onFirstChats !== null && subscribers.length > 0) {
      if (this.onFirstChats(String(topic.scope ?? ""))) this.onFirstChats = null;
    }
    this.#opened(now);
  }

  /// A topic's first value made and gone out where it has subscribers: its source told so, once (`Source.opened`).
  #opened(entry: Entry): void {
    if (entry.openedTold) return;
    entry.openedTold = true;
    this.#source?.opened?.(entry.topic);
  }

  /// Whether what went out of the topic last (`sent`) is what would go out of it now: an error that went out as it is,
  /// or what its output made of the very value it holds, said in the same words, nothing that making read changed
  /// since (output.ts `kept`). What makes it otherwise while nobody subscribes: a value made again that differs, or
  /// one `set` or `update`d (a new object, equal or not); a change kept from the subscribers while no page was in view
  /// (`unseen`, not shaped); what went out told out of date (#again: the clock moved on past its words, an item's
  /// computed); the language, the product's name, the minute where it says times in words; the last shaping failed.
  #sentHolds(entry: Entry): boolean {
    const { sent, value, output } = entry;
    if (sent === undefined || value === undefined) return false;
    if ("err" in value) return sent === value;
    if (!("ok" in sent) || output === undefined) return false;
    const at = this.host.nowMs();
    const kept = output.kept(entry.topic, value.ok, { now: at, offsetMin: this.host.utcOffsetMin(at) }, this.#shaped);
    return kept !== null && kept.ok === sent.ok;
  }

  /// The first message of subscriber `id` of `client` (`keyed`: it takes keyed ops) to topic `topic`, whose value going
  /// out is `value`, where it need not be the value whole; none where it goes whole. In this order:
  /// - `{id, same: true}` where it was asked with `have` and `value` is the one of that token (the same object), or what
  ///   changed from what the client was remembered to keep under it (#kept) is nothing: nothing of it sent;
  /// - its `from`'s (#firstFrom): what changed from another of its subscriptions held now (a list's first rows, more
  ///   of them asked), which differs from it by the rows asked and what changed this moment; what was kept is as old as
  ///   the while the topic was let go of, all that changed meanwhile in what changed from it: the lighter as a rule;
  /// - `{id, delta, kept: true}` where it was asked with `have` and that is the token of what the client was
  ///   remembered to keep of this topic (#kept): what changed from that, as a held subscriber's change goes (keyed ops
  ///   for a keyed one of a topic with keyed lists, plain else), unless it weighs more than the value (`heavier`,
  ///   `largerThan`, as #flush decides).
  /// An error, nothing remembered, another token (another run's, one forgotten): none. Its `from` and `have` are
  /// forgotten either way, and what was remembered of the topic for the client: its first message gone, the client keeps
  /// none of it after.
  #first(client: ClientId, id: RequestId, topic: Topic, keyed: boolean, value: Value, gen?: WireGen): CoreMessage | null {
    const at = `${client}/${id}`;
    const have = this.#have.get(at);
    this.#have.delete(at);
    const kept = this.#kept.get(client);
    const had = kept?.get(topicKey(topic));
    if (had !== undefined) kept!.delete(topicKey(topic));
    const known = isKnownTopic(topic.topic);
    const policy = known ? evaluateTopicPolicy(topic.topic, topic) : null;
    if (policy?.sensitive) {
      this.#from.delete(at);
      return null;
    }
    const curAuthGen = this.authGen.authGenOf(topic);
    const curVaultGen = this.authGen.vaultGenOf(topic);
    const allowKeep = policy === null || (policy.retention !== "live" && policy.keep > 0);
    const validHad = allowKeep && had !== undefined && had.v === have && had.authGen === curAuthGen && had.vaultGen === curVaultGen ? had : undefined;
    // The value the client holds still (the same object in the same connection/authGen/vaultGen), nothing worked out;
    // else what changed from what it holds, where that is remembered (#kept). For `station`/`profiles`, `had.ok` is
    // sanitized so fresh sensitive fields are patched in via delta rather than skipped with `same: true`.
    const same =
      allowKeep &&
      have !== undefined &&
      "ok" in value &&
      tokenOf(value.ok) === have &&
      this.#tokenMatchesScope(client, topic, have, curAuthGen, curVaultGen);
    const spec = keyed ? specOf(topic) : null;
    const ops = !same && have !== undefined && validHad !== undefined && "ok" in value ? (spec ? diffKeyed(validHad.ok, value.ok, spec) : diff(validHad.ok, value.ok)) : null;
    if (same || (ops !== null && ops.length === 0)) {
      this.#from.delete(at);
      return gen ? { id, same: true, ...gen } : { id, same: true };
    }
    const from = keyed ? this.#firstFrom(client, id, topic, value, gen) : null;
    this.#from.delete(at);
    if (from !== null) return from;
    if (ops === null || !("ok" in value)) return null;
    if (spec) return heavier(ops as AnyOp[], value.ok) ? null : gen ? { id, delta: ops, kept: true, ...gen } : { id, delta: ops, kept: true };
    return largerThan(ops as Op[], value.ok) ? null : gen ? { id, delta: ops, kept: true, ...gen } : { id, delta: ops, kept: true };
  }

  /// The first value `value` of topic `topic` going to subscriber `id` of `client` as what changed from what its
  /// `from` has: that subscription's topic's value as last sent, which the client holds, the messages to it going in
  /// order. None when it has no `from`, or that one is gone, has another topic's name, has no value, crosses an
  /// auth/vault generation, is `sensitive`, or the difference would be heavier than the value: it goes whole then.
  #firstFrom(client: ClientId, id: RequestId, topic: Topic, value: Value, gen?: WireGen): CoreMessage | null {
    const at = `${client}/${id}`;
    const from = this.#from.get(at);
    if (from === undefined) return null;
    this.#from.delete(at);
    const topicPolicy = evaluateTopicPolicy(topic.topic, topic);
    if (topicPolicy.sensitive) return null;
    const other = this.#subscriptions.get(`${client}/${from}`);
    if (!other || other.topic !== topic.topic || !("ok" in value)) return null;
    const otherPolicy = evaluateTopicPolicy(other.topic, other);
    if (otherPolicy.sensitive || otherPolicy.retention !== topicPolicy.retention) return null;
    if (!equal(topicScopeOf(topic), topicScopeOf(other))) return null;
    const topicKeys = Object.keys(topic).filter((k) => k !== "limit");
    const otherKeys = Object.keys(other).filter((k) => k !== "limit");
    if (topicKeys.length !== otherKeys.length || !topicKeys.every((k) => Object.hasOwn(other, k) && equal(topic[k], other[k]))) {
      return null;
    }
    const entry = this.#topics.get(topicKey(other));
    const base = entry?.sent;
    const curAuthGen = this.authGen.authGenOf(topic);
    const curVaultGen = this.authGen.vaultGenOf(topic);
    if (
      !entry ||
      !base ||
      !("ok" in base) ||
      entry.authGen !== curAuthGen ||
      entry.vaultGen !== curVaultGen ||
      !entry.subscribers.some(([c, i, k]) => c === client && i === from && k)
    ) {
      return null;
    }
    const spec = specOf(topic);
    if (!spec) return null;
    const ops = diffKeyed(base.ok, value.ok, spec);
    return heavier(ops, value.ok) ? null : gen ? { id, delta: ops, from, ...gen } : { id, delta: ops, from };
  }

  #evict(topic: Topic, idle: number): void {
    const key = topicKey(topic);
    const entry = this.#topics.get(key);
    if (!entry || entry.idle !== idle) return;
    // Gone before its source hears: what the source asks of the live topics then no longer has it.
    this.#topics.delete(key);
    if (ASKED_BY_WORDS.has(topic.topic)) {
      const kind = wordsKind(topic);
      if (this.#wordsLetGo.get(kind)?.key === key) this.#wordsLetGo.delete(kind);
    }
    entry.stop?.();
    entry.output?.stop();
    if (this.#firstPending.get(key) === entry) this.#firstPending.delete(key);
    if (this.#updatesPending.get(key) === entry) this.#updatesPending.delete(key);
    this.#source?.stop(topic);
    if (holds(topic)) this.#release_?.(topic);
  }
}
