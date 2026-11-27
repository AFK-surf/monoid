// The workspace's connects (connects/remote.ts) as a part of the agents' side: on the station a connect runs on, its
// platform's events routed to the station a chat of their thread runs on, the calls of those chats answered, the connect
// moved to another station by hand (POST /connects/:id/move); on the station a chat runs on, the events taken and the
// connect's surface asked; on every one, whether a connect being added runs on another station already.
import { createHash } from "node:crypto";
import { readFileSync, readdirSync } from "node:fs";
import { appendFile, mkdir, readFile, rename, rm, writeFile } from "node:fs/promises";
import { dirname, join } from "node:path";
import { Clock, Duration, Effect, Layer } from "effect";
import type { Route } from "../api/admin.ts";
import { error, input, ok, Refused, segment } from "../api/request.ts";
import { type Inbox, NoLink, Refused as Declined } from "../mesh/bus.ts";
import { mayHaveRun } from "../mesh/peer.ts";
import { log } from "../ops/log.ts";
import { stationLang, tr } from "../ops/i18n.ts";
import { Agents } from "../sessions/agents.ts";
import { type ChatEvent, markNotice } from "../sessions/chat.ts";
import type { ConnectKind } from "../sessions/config.ts";
import { type Hub, Retiring } from "../sessions/hub.ts";
import { ControlPlane, Parts, Paths, Peers, StationConfig, Store } from "../services.ts";
import type { Store as StoreT } from "../store/store.ts";
import { isSlackWrite } from "../tools/mcp.ts";
import { lessBusy } from "../../../shared/station-busy.ts";
import type { NameBook } from "./names.ts";
import { BOTS, CALL, EVENT, HOLDS, LIST, MOVED, ROUTE, ROUTED, RemoteConnects, RemoteSurface, TAKE, type Described, type Known, answerCall, describe, knownIn, knownOf, localOf, threadOfEvent } from "./remote.ts";

type Json = any;

/// What a connect's secret is known by across the workspace without being said: its platform's token (Slack's bot
/// token, a Comma line's token, a group connect's key) or its app (Feishu's), hashed. Null: one that has none yet.
export function fingerprint(kind: string, own: Json): string | null {
  const secret = kind === "feishu" ? own?.appId : kind === "comma" ? own?.token : kind === "group" ? own?.key : own?.botToken;
  return typeof secret === "string" && secret !== "" ? createHash("sha256").update(`${kind}\n${secret}`).digest("hex") : null;
}

export type WorkspaceConnectsDeps = {
  data: string;
  hub: () => Hub;
  store: StoreT;
  config: { raw(): Json; updateSoon(f: (raw: Json) => void): Promise<unknown> };
  /// This station's id, and its home workspace.
  here: () => string;
  home: () => string | null;
  /// The stations of one of this station's workspaces (the cloud's roster: `{id, name}`); none of any other.
  stations: (ws: string) => Json[];
  bus: { ask(station: string, request: Json): Promise<Json>; on(method: string, inbox: Inbox): void; heard?(f: (peer: string) => void): void };
  /// Each platform's names book.
  names: (kind: ConnectKind) => NameBook | null;
  /// This station's own `describe` payload (load, mode, sessions) without sending a peer RPC to itself.
  selfLoad?: () => Promise<Json>;
  /// Effect Clock sleep for bounding `describe` RPC waits (no raw setTimeout).
  sleep?: (ms: number) => Promise<void>;
  /// Timeout per `describe` RPC when balancing across a multi-station allowlist (default 1500 ms).
  describeTimeoutMs?: number;
  /// Settles once this station has connected its own connects as it starts (agents.ts `connectsReady`): a call that
  /// comes before then for one of them waits for it rather than being told the connect does not run here.
  connectsReady?: () => Promise<void>;
  /// How long such a call waits at most (default 15 s).
  connectsReadyTimeoutMs?: number;
  /// How long `connect.event` waits for a `message` event's `hub.receive` (which may download large thread
  /// history/attachments) before acknowledging acceptance early so the caller never hits peer `ANSWER_MS` (default 5 s).
  acceptWaitMs?: number;
  /// The Effect clock that bounds that wait (the timer ends once the connects are ready); without it, `sleep` does.
  clock?: Clock.Clock;
};

const DESCRIBE_TIMEOUT_MS = 1_500;
const CONNECTS_READY_TIMEOUT_MS = 15_000;
const ACCEPT_WAIT_MS = 5_000;
const AMBIGUOUS_RELAY = "peer request timed out; execution may have happened";

/// Whether a failed `connect.event` forward may already have reached and begun executing on the target station.
/// Relies on `peer.ts`'s `mayHaveRun` (set only after bytes were written onto the peer stream) so pre-write dial/open
/// failures and bare callee read timeouts still fail over cleanly, while post-write timeouts/drops and relayed
/// ambiguous failures pin the thread instead of spawning duplicate sessions across stations.
export function mayHaveTaken(error: unknown): boolean {
  if (error instanceof NoLink) return false;
  if (error instanceof Declined) return error.message.startsWith(AMBIGUOUS_RELAY);
  return mayHaveRun(error);
}

export class WorkspaceConnects {
  readonly remote: RemoteConnects;
  private readonly d: WorkspaceConnectsDeps;
  /// The files a chat of another station posts, until they are posted.
  private readonly uploads: string;
  readonly #uploadsCleared: Promise<void>;
  readonly #files = new Set<Promise<unknown>>();

  #file<T>(work: Promise<T>): Promise<T> {
    this.#files.add(work);
    void work.then(() => this.#files.delete(work), () => this.#files.delete(work));
    return work;
  }

  writing(): boolean { return this.#files.size > 0 || this.remote.writing(); }

  async filesWritten(): Promise<void> {
    await this.#uploadsCleared;
    await this.remote.written();
    while (this.#files.size > 0) await Promise.allSettled([...this.#files]);
  }
  /// One event at a time per thread: a conversation's first message is handed on before its next is looked at.
  private readonly gates = new Map<string, Promise<void>>();
  /// In-flight fresh conversation dispatches per (connect, station), so simultaneous arrivals spread immediately.
  private readonly inflight = new Map<string, number>();
  /// Per-connect round-robin cursor across its allowlist, breaking idle ties deterministically.
  private readonly rrCursor = new Map<string, number>();
  /// What a platform says of a workspace whose chats this station hands to another (hub `quiet`), acknowledged and kept
  /// in order, on disk, until it goes there (`moveAll`); one at a time, the kept ones before any after them.
  private readonly heldFile: string;
  private heldTurn: Promise<void> = Promise.resolve();
  /// The workspaces whose kept events went to the station their chats went to, and where the next go at once.
  private readonly heldTo = new Map<string, string>();

  constructor(d: WorkspaceConnectsDeps) {
    this.d = d;
    this.uploads = join(d.data, "run", "connect-uploads");
    this.heldFile = join(d.data, "replica", "held-events.jsonl");
    // What a process before left of the files remote chats posted, taken away off the thread; the first upload waits for it.
    this.#uploadsCleared = this.#file(rm(this.uploads, { recursive: true, force: true })).catch(() => {});
    try {
      const kept = JSON.parse(readFileSync(join(d.data, "replica", "awaiting.json"), "utf8")) as Record<string, string[]>; // sync: read once, before the station serves
      for (const [id, keys] of Object.entries(kept)) if (Array.isArray(keys) && keys.length > 0) this.awaiting.set(id, new Set(keys));
    } catch {}
    this.remote = new RemoteConnects(d.data, d.here, (station, request) => d.bus.ask(station, request), d.names);
    // (the moves under way as this station stopped: settled as it starts and as the station each went to is heard from)
    try {
      for (const name of readdirSync(this.movingDir())) { // sync: read once, before the station serves
        try {
          const m = JSON.parse(readFileSync(join(this.movingDir(), name), "utf8")) as Moving; // sync: read once, before the station serves
          if (typeof m?.id === "string" && typeof m.to === "string") this.moving.set(m.id, m);
        } catch {}
      }
    } catch {}
    d.bus.on(HOLDS, async (peer, request, workspace) => {
      const known = knownIn(request?.connect);
      if (known === null || typeof workspace !== "string" || !this.inWorkspace(workspace, peer)) throw new Error("no such connect");
      return { holds: this.entryOf(localOf(known, d.here())) !== undefined };
    });
    // (a request heard: nothing asked of anyone unless a move of this station's is under way with that one)
    d.bus.heard?.((peer) => {
      if (this.moving.size > 0) void this.settleMoving(peer);
    });
    void this.settleMoving();
    d.bus.on(EVENT, (peer, request, workspace) => this.taken(peer, request, workspace));
    d.bus.on(MOVED, async (_peer, request) => {
      const known = knownIn(request?.connect);
      if (known === null || typeof request?.station !== "string") throw new Error("no such connect");
      this.remote.moved(localOf(known, d.here()), request.station);
      return { ok: true };
    });
    // Whether this station connected its own connects as it started (or will not): after that a call waits no more.
    let readyDone = false;
    const ready = d.connectsReady?.().then(() => void (readyDone = true), () => void (readyDone = true));
    const readyOrTimeout = (ms: number): Promise<unknown> =>
      d.clock !== undefined
        ? Effect.runPromise(Effect.promise(() => ready!).pipe(Effect.timeoutOption(Duration.millis(ms)), Effect.provideService(Clock.Clock, d.clock)))
        : Promise.race([ready!, (d.sleep ?? ((t: number) => Effect.runPromise(Effect.sleep(Duration.millis(t)))))(ms)]);
    const answer = answerCall(async (known: Known, workspace: string | undefined) => {
      const id = localOf(known, d.here());
      const entry = this.entryOf(id);
      if (entry === undefined || this.workspaceOf(entry) !== workspace) return undefined;
      const live = this.own(id);
      if (live !== undefined) return live;
      // A station of the workspace that started as this one did can ask before this one connected its own connects
      // (agents.ts `start`, `along` `taken`): such a call waits for them, bounded, rather than failing the chat there.
      if (readyDone || entry.enabled === false || ready === undefined) return undefined;
      await readyOrTimeout(d.connectsReadyTimeoutMs ?? CONNECTS_READY_TIMEOUT_MS);
      const after = this.entryOf(id);
      return after !== undefined && this.workspaceOf(after) === workspace ? this.own(id) : undefined;
    }, this.uploads, this.#uploadsCleared);
    d.bus.on(CALL, async (peer, request, workspace) => {
      const answered = await answer(peer, request, workspace);
      // A conversation another station's chat began here (chat_post to a Feishu chat): what is said in its thread goes
      // to that station from now on, as a thread whose first message came here and was handed there does.
      if (request?.op === "begin" && peer !== "self" && peer !== d.here()) {
        const known = knownIn(request?.connect);
        const id = known === null ? "" : localOf(known, d.here());
        const entry = this.entryOf(id);
        const thread = answered?.result?.thread;
        if (entry !== undefined && ROUTED.includes(kindOf(entry) as never) && entry.mode !== "single-session" &&
          typeof thread?.channel === "string" && thread.channel !== "" && typeof thread?.threadTs === "string" && thread.threadTs !== "") {
          this.routeHere(id, thread.channel, thread.threadTs, peer);
        }
      }
      // A write another station's chat made here with slack_api in a thread it names, or a new message it posted: that
      // chat took part in its thread (conversations.ts `slackApi`), so what is said there goes to that station too, unless
      // the thread is a chat's here or another station's already.
      if (request?.op === "api" && peer !== "self" && peer !== d.here()) {
        const known = knownIn(request?.connect);
        const id = known === null ? "" : localOf(known, d.here());
        const entry = this.entryOf(id);
        const [method, params] = Array.isArray(request?.args) ? request.args : [];
        const posted = answered?.result?.answer;
        const text = (v: unknown) => (typeof v === "string" && v !== "" ? v : null);
        const named = text(params?.thread_ts);
        const fresh = method === "chat.postMessage" ? text(posted?.ts) : null;
        // (a new message's channel as Slack says it: a person's id given opens their direct message)
        const channel = (fresh !== null ? text(posted?.channel) : null) ?? text(params?.channel) ?? text(params?.channel_id);
        const threadTs = named ?? fresh;
        if (entry !== undefined && kindOf(entry) === "slack" && entry.mode !== "single-session" && typeof method === "string" && isSlackWrite(method) &&
          channel !== null && threadTs !== null && this.d.store.connectThreadStation(id, channel, threadTs) === null) {
          const here = this.d.store.threadAt(this.d.hub().surface(id), channel, threadTs);
          if (here === null || this.d.store.threadSessions(here.id).every((m) => m.connect !== id)) this.routeHere(id, channel, threadTs, peer);
        }
      }
      return answered;
    });
    // Whether one of this station's connects of that workspace has that secret.
    d.bus.on(LIST, async (_peer, request, workspace) => {
      const print = typeof request?.fingerprint === "string" ? request.fingerprint : "";
      return { has: this.entries().some((c) => this.workspaceOf(c) === workspace && fingerprint(kindOf(c), c?.[kindOf(c)]) === print) };
    });
    d.bus.on(TAKE, (peer, request, workspace) => this.take(peer, request, workspace));
    // (the bots of another station's connects, told as they change: its notices are no person's message here)
    d.bus.on(BOTS, async (peer, request, workspace) => {
      if (typeof workspace !== "string" || !this.inWorkspace(workspace, peer)) throw new Error("not a station of this workspace");
      const bots = Array.isArray(request?.bots) ? request.bots.filter((b: unknown): b is string => typeof b === "string" && b !== "").slice(0, 200) : [];
      d.hub().toldBots.set(peer, new Set(bots));
      return { ok: true };
    });
    // (one thread's chat runs on another station from now on, or here again: replica/handover.ts)
    d.bus.on(ROUTE, async (peer, request, workspace) => {
      const known = knownIn(request?.connect);
      const id = known === null ? "" : localOf(known, d.here());
      const entry = this.entryOf(id);
      if (known === null || entry === undefined || typeof workspace !== "string" || this.workspaceOf(entry) !== workspace || !this.inWorkspace(workspace, peer)) throw new Error("no such connect");
      if (typeof request?.channel !== "string" || typeof request?.threadTs !== "string") throw new Error("no such thread");
      this.routeHere(id, request.channel, request.threadTs, typeof request.station === "string" ? request.station : null);
      return { ok: true };
    });
  }

  /// A thread of a connect of this station's: its chat runs on `station` from now on (null, or this one: here).
  private routeHere(id: string, channel: string, threadTs: string, station: string | null): void {
    if (station === null || station === this.d.here()) this.d.store.dropConnectThreadStation(id, channel, threadTs);
    else this.d.store.setConnectThreadStation(id, channel, threadTs, station);
  }

  /// A thread of connect `id` (as this station names it): its chat runs on `station` from now on, said where the connect
  /// runs (here, or asked of the station it runs on, `connect.route`). Not a routed kind: refused.
  async route(id: string, channel: string, threadTs: string, station: string): Promise<void> {
    const entry = this.entryOf(id);
    if (entry !== undefined) {
      if (!ROUTED.includes(kindOf(entry) as never) || entry.mode === "single-session") throw new Error("that connect's chats run only where it runs");
      return this.routeHere(id, channel, threadTs, station);
    }
    const remote = this.remote.surface(id);
    if (remote === undefined) throw new Error(`connect ${id} is not known here`);
    await this.d.bus.ask(remote.station, { method: ROUTE, workspace: remote.described.workspace, connect: knownOf(id, this.d.here()), channel, threadTs, station });
  }

  /// Connect `id` as this station knows it: where it runs and what it says of itself (null: not known here), so that a
  /// station a chat of it is handed to posts through it before it heard any of its events (`learnOf`).
  describedFor(id: string): { station: string; described: Described } | null {
    const own = this.described(id);
    if (own !== null) return { station: this.d.here(), described: own };
    const remote = this.remote.surface(id);
    return remote === undefined ? null : { station: remote.station, described: remote.described };
  }

  /// What another station said of a connect a chat handed here goes through (`describedFor`): learnt, unless it is one
  /// of this station's own.
  learnOf(known: Known, station: string, described: Described): void {
    const id = localOf(known, this.d.here());
    if (this.entryOf(id) !== undefined) return;
    this.remote.learn(id, station, described);
  }

  private entries(): Json[] {
    const raw = this.d.config.raw();
    return Array.isArray(raw?.connects) ? raw.connects : [];
  }
  private entryOf(id: string): Json | undefined {
    return this.entries().find((c) => c?.id === id);
  }
  /// The workspace a connect's chats are of (config.json's `workspace`; absent: the home one).
  private workspaceOf(entry: Json): string | null {
    return typeof entry?.workspace === "string" && entry.workspace !== "" ? entry.workspace : this.d.home();
  }
  private inWorkspace(ws: string, station: string): boolean {
    return this.d.stations(ws).some((p) => p?.id === station);
  }
  /// Station `station` is not in `ws`'s roster any more (removed): never while the roster is not known yet.
  private gone(ws: string, station: string): boolean {
    const roster = this.d.stations(ws);
    return roster.length > 0 && !roster.some((p) => p?.id === station);
  }
  /// Threads (`connect\0channel\0threadTs`) told their chat's station is away, until an event gets there again.
  private readonly awayTold = new Set<string>();
  private isTasksOnly(ws: string, station: string): boolean {
    const p = this.d.stations(ws).find((x) => x?.id === station);
    return p?.mode === "tasks" || (p?.rig !== undefined && p?.rig !== null);
  }
  private nameOf(ws: string, station: string): string {
    return String(this.d.stations(ws).find((p) => p?.id === station)?.name ?? station);
  }
  private inflightCount(connectId: string, stationId: string): number {
    return this.inflight.get(`${connectId}\0${stationId}`) ?? 0;
  }
  private addInflight(connectId: string, stationId: string, delta: number): void {
    const key = `${connectId}\0${stationId}`;
    const next = (this.inflight.get(key) ?? 0) + delta;
    if (next <= 0) this.inflight.delete(key);
    else this.inflight.set(key, next);
  }
  /// Bare station id from either a bare id ("st2") or a `<workspace>/<station_id>` address ("ws1/st2").
  private bareStationId(s: string): string {
    const t = s.trim();
    const slash = t.lastIndexOf("/");
    return slash >= 0 ? t.slice(slash + 1).trim() : t;
  }
  /// The manual allowlist for a connect's new conversations: explicit `stations` (deduped) > `station` > `[here]`.
  private allowlistOf(entry: Json): string[] {
    if (Array.isArray(entry?.stations)) {
      const out = [...new Set<string>(entry.stations.filter((x: unknown): x is string => typeof x === "string").map((x: string) => this.bareStationId(x)).filter((x: string) => x !== ""))];
      if (out.length > 0) return out;
    }
    if (typeof entry?.station === "string") {
      const s = this.bareStationId(entry.station);
      if (s !== "") return [s];
    }
    return [this.d.here()];
  }
  private async boundedDescribe(work: Promise<Json>): Promise<{ ok: Json } | null> {
    const ms = this.d.describeTimeoutMs ?? DESCRIBE_TIMEOUT_MS;
    const sleep = this.d.sleep ?? ((t: number) => Effect.runPromise(Effect.sleep(Duration.millis(t))));
    let out: { ok: Json } | null = null;
    const settled = work.then(
      (ok) => void (out = { ok }),
      () => void (out = null),
    );
    await Promise.race([settled, sleep(ms)]);
    return out;
  }
  private async queryStationLoad(ws: string, station: string): Promise<Json | null> {
    if (station === this.d.here()) {
      if (this.d.selfLoad === undefined) {
        return { sessions: true, load: { running: { turns: 0 }, memory: { totalBytes: null, availableBytes: null } } };
      }
      const got = await this.boundedDescribe(Promise.resolve().then(() => this.d.selfLoad!()));
      return got?.ok ?? null;
    }
    const got = await this.boundedDescribe(this.d.bus.ask(station, { method: "describe", workspace: ws }));
    return got?.ok ?? null;
  }
  /// A connect running here, its surface: config.json's, not one of another station's.
  private own(id: string) {
    const chat = this.d.hub().chatOf(id);
    return chat instanceof RemoteSurface ? undefined : chat;
  }
  private described(id: string): Described | null {
    const connect = this.d.hub().config().connects.find((c) => c.id === id);
    const chat = this.own(id);
    const ws = this.workspaceOf(this.entryOf(id));
    return connect === undefined || chat === undefined || ws === null ? null : describe(connect, ws, chat);
  }

  // ── on the station a chat runs on ────────────────────────────────────────────────────────────────────────────

  private async waitBounded(work: Promise<void>, ms: number): Promise<boolean> {
    let finished = false;
    let failed: { error: unknown } | null = null;
    const settled = work.then(
      () => { finished = true; },
      (error) => { finished = true; failed = { error }; },
    );
    if (this.d.clock !== undefined || this.d.sleep === undefined) {
      const eff = Effect.promise(() => settled).pipe(Effect.timeoutOption(Duration.millis(ms)));
      await Effect.runPromise(this.d.clock !== undefined ? eff.pipe(Effect.provideService(Clock.Clock, this.d.clock)) : eff);
    } else {
      await Promise.race([settled, this.d.sleep(ms)]);
    }
    const err = failed as { error: unknown } | null;
    if (err !== null) throw err.error;
    return finished;
  }

  /// An event of a connect of another station's for a chat here; or one kept on a station retired for one of its
  /// connects that moved here since (`kept`), taken as this station's connect's own (`moveAll`).
  private async taken(peer: string, request: Json, workspace: string | undefined): Promise<Json> {
    const known = knownIn(request?.connect);
    if (request?.kept === true) {
      const id = known === null ? "" : localOf(known, this.d.here());
      const entry = this.entryOf(id);
      if (known === null || typeof workspace !== "string" || entry === undefined || this.workspaceOf(entry) !== workspace || !this.inWorkspace(workspace, peer)) throw new Error("no such connect");
      await this.receive(id, request.event as ChatEvent);
      return { ok: true };
    }
    const d: Described | undefined = request?.described;
    if (known === null || typeof d?.kind !== "string" || typeof workspace !== "string" || d.workspace !== workspace || !this.inWorkspace(workspace, peer)) throw new Error("no such connect");
    const id = localOf(known, this.d.here());
    if (this.entryOf(id) !== undefined) throw new Error("that connect runs on this station");
    const event = request.event as ChatEvent;
    // Refuse message events before learning or accepting while handing this workspace's chats to another station, so
    // the sender receives an explicit Refused error and can cleanly fail over (edits/stops continue as hub.ts does).
    if (event.type === "message" && this.d.hub().quietIn(workspace)) throw new Retiring();
    this.remote.learn(id, peer, d);
    // (its chat was handed from here to another station, and the connect's station not told yet, or the event already
    // on its way: it goes on there, as the connect's station would send it)
    const thread = threadOfEvent(event);
    const moved = this.d.hub().movedTo(id, thread.channel, thread.threadTs);
    if (moved !== null && moved !== this.d.here()) {
      try {
        await this.d.bus.ask(moved, { method: EVENT, workspace, connect: known, described: d, event });
      } catch (e) {
        // Preserve post-write ambiguity across the relay hop so the connect's station pins instead of failing over.
        if (mayHaveTaken(e)) throw new Error(`${AMBIGUOUS_RELAY} — query the same task key`);
        throw e;
      }
      return { ok: true };
    }
    if (event.type !== "message") {
      await this.d.hub().receive(id, event);
      return { ok: true };
    }
    const noteNames = () => {
      // Its people and channel named here as there (the pages read them from this station's names book).
      const chat = this.remote.surface(id);
      chat?.knownPerson(event.message.user);
      chat?.knownChannel(event.message.channel);
    };
    // `hub.receive` on a `message` event may fetch thread history and download tens of MB of attachments over the mesh,
    // exceeding peer RPC `ANSWER_MS` (30 s). Wait up to `acceptWaitMs` so fast completions and refusals return directly;
    // if still downloading, acknowledge acceptance early and let `hub.inThread` finish serially in the background.
    const work = this.d.hub().receive(id, event);
    const waitMs = this.d.acceptWaitMs ?? ACCEPT_WAIT_MS;
    const done = await this.waitBounded(work, waitMs);
    if (done) {
      noteNames();
    } else {
      log.info("connects", "remote message still downloading thread context/files; acknowledging acceptance early", { connect: id, channel: thread.channel, threadTs: thread.threadTs, waitMs });
      void work.then(noteNames, (error) => {
        log.warn("connects", "a remote message failed after acceptance", { connect: id, channel: thread.channel, threadTs: thread.threadTs, error: (error as Error).message });
        const chat = this.remote.surface(id);
        const notice = markNotice(`⚠️ ${tr(stationLang(), "station.slack.sessionFailed", { error: (error as Error).message })}`);
        void chat?.post({ channel: thread.channel, threadTs: thread.threadTs }, notice, []).catch(() => {});
      });
    }
    return { ok: true };
  }

  // ── on the station a connect runs on ─────────────────────────────────────────────────────────────────────────

  private inTurn(at: string, f: () => Promise<void>): Promise<void> {
    const turn = (this.gates.get(at) ?? Promise.resolve()).then(f);
    const tail = turn.catch(() => {});
    this.gates.set(at, tail);
    void tail.then(() => this.gates.get(at) === tail && this.gates.delete(at));
    return turn;
  }

  /// The connects of this station's being handed to another (`move`), from the moment that one is asked to take it: where
  /// it went once taken (null: it was not, and is this station's still). Its socket here closes as config.json loses it,
  /// a few ms after the other's opened (the drill: 1 to 6 ms both open); what Slack gives this one meanwhile, or as the
  /// hand-off goes on, waits for it and goes to the holder (`receive`), never handled here, nor twice: Slack gives each
  /// event to one socket of an app, and acknowledges it once the holder took it.
  private readonly handing = new Map<string, { to: Promise<string | null>; ws: string }>();

  /// The moves of a connect of this station's under way, kept from before it asks the other to take it until it heard
  /// either way (`replica/connects-moving/`): a station that stopped between, or did not hear the other's answer, asks
  /// it whether it holds the connect as it starts and as it is heard from (`settleMoving`): it does, the move ends here
  /// as it would have (this one's entry dropped, its threads its); it does not, it never moved. So one of the two holds
  /// it, never both nor neither, once both are up and have heard each other.
  private readonly moving = new Map<string, Moving>();
  /// Those whose move is asking the other now (settled by its answer, not by `settleMoving`).
  private readonly asking = new Set<string>();
  private movingDir(): string {
    return join(this.d.data, "replica", "connects-moving");
  }
  private movingFile(id: string): string {
    return join(this.movingDir(), `${createHash("sha256").update(id).digest("hex").slice(0, 32)}.json`);
  }
  private async keepMoving(m: Moving): Promise<void> {
    this.moving.set(m.id, m);
    await this.#file(mkdir(this.movingDir(), { recursive: true }));
    await this.#file(writeFile(`${this.movingFile(m.id)}.tmp`, JSON.stringify(m)));
    await this.#file(rename(`${this.movingFile(m.id)}.tmp`, this.movingFile(m.id)));
  }
  private async doneMoving(id: string): Promise<void> {
    this.moving.delete(id);
    await this.#file(rm(this.movingFile(id), { force: true }));
  }
  #settling: Promise<void> = Promise.resolve();

  /// The moves under way (of those to `peer`, where given), settled by asking each station whether it holds the connect.
  settleMoving(peer?: string): Promise<void> {
    const turn = this.#settling.then(async () => {
      for (const m of [...this.moving.values()]) {
        if ((peer !== undefined && m.to !== peer) || this.asking.has(m.id)) continue;
        let holds: boolean;
        try {
          holds = (await this.d.bus.ask(m.to, { method: HOLDS, workspace: m.ws, connect: knownOf(m.id, this.d.here()) }))?.holds === true;
        } catch (e) {
          log.info("connects", "a connect's move under way not settled yet: the station it went to not heard", { connect: m.id, to: m.to, error: (e as Error).message });
          continue;
        }
        if (holds && this.entryOf(m.id) !== undefined) await this.handedOff(m.id, m.to, m.ws, m.localsTo);
        else if (holds) await this.doneMoving(m.id);
        else {
          this.handing.delete(m.id);
          await this.doneMoving(m.id);
        }
        log.info("connects", "a connect's move under way settled", { connect: m.id, to: m.to, there: holds });
      }
    });
    this.#settling = turn.catch(() => {});
    return turn;
  }

  /// What ends a connect's move here once the other took it: its entry dropped, its threads the other's, the chats here
  /// going on through it there, the other stations told; what its socket here still gives goes there (`receive`).
  private async handedOff(id: string, to: string, ws: string, localsTo: string): Promise<void> {
    const d = this.described(id);
    const known = knownOf(id, this.d.here());
    this.handing.set(id, { to: Promise.resolve(to), ws });
    await this.d.config.updateSoon((raw) => {
      raw.connects = (Array.isArray(raw.connects) ? raw.connects : []).filter((c: Json) => c?.id !== id);
    });
    this.d.store.dropConnectThreads(id);
    // The chats here go on through it there.
    if (d !== null && localsTo === this.d.here()) this.remote.learn(id, to, d);
    for (const p of this.d.stations(ws)) {
      if (typeof p?.id !== "string" || p.id === this.d.here() || p.id === to) continue;
      void this.d.bus.ask(p.id, { method: MOVED, workspace: ws, connect: known, station: to }).catch(() => {});
    }
    await this.doneMoving(id);
  }

  private async forward(station: string, id: string, ws: string, event: ChatEvent) {
    const d = this.described(id);
    if (d === null) throw new Error("the connect is not connected");
    await this.d.bus.ask(station, { method: EVENT, workspace: ws, connect: knownOf(id, this.d.here()), described: d, event });
  }

  /// Of each connect moved here that is not routed, the chats of it still on their way here (`move`'s `awaiting`),
  /// kept on disk with what its platform said meanwhile (`awaitingFile`), read as the station starts.
  private readonly awaiting = new Map<string, Set<string>>();
  private awaitingFile(id: string): string {
    return join(this.d.data, "replica", "awaiting", `${createHash("sha256").update(id).digest("hex").slice(0, 32)}.jsonl`);
  }
  private awaitingTurn: Promise<void> = Promise.resolve();
  private inAwaiting(f: () => Promise<void>): Promise<void> {
    const turn = this.awaitingTurn.then(f);
    this.awaitingTurn = turn.catch(() => {});
    return turn;
  }

  /// Connect `id` keeps what it says for chats `keys` until each is here.
  private await(id: string, keys: string[]): Promise<void> {
    return this.inAwaiting(async () => {
      this.awaiting.set(id, new Set([...(this.awaiting.get(id) ?? []), ...keys]));
      await this.saveAwaiting();
    });
  }

  private keepFor(id: string, event: ChatEvent): Promise<void> {
    return this.inAwaiting(async () => {
      if (!this.awaiting.has(id)) return void (await this.d.hub().receive(id, event));
      const file = this.awaitingFile(id);
      await this.#file(mkdir(dirname(file), { recursive: true }));
      await this.#file(appendFile(file, `${JSON.stringify(event)}\n`));
    });
  }

  /// Chats `keys` are here now (replica/handover.ts as it shows them): a connect waiting for no more of its chats takes
  /// what it kept, in order, as it came.
  arrived(keys: string[]): Promise<void> {
    return this.inAwaiting(async () => {
      for (const [id, waiting] of [...this.awaiting]) {
        for (const k of keys) waiting.delete(k);
        if (waiting.size > 0) continue;
        this.awaiting.delete(id);
        await this.saveAwaiting();
        const file = this.awaitingFile(id);
        const lines = (await this.#file(readFile(file, "utf8")).catch(() => "")).split("\n").filter((l) => l !== "");
        await this.#file(rm(file, { force: true }));
        for (const line of lines) {
          try {
            await this.d.hub().receive(id, JSON.parse(line) as ChatEvent);
          } catch (e) {
            log.warn("connects", "an event kept for a chat on its way not taken", { connect: id, error: (e as Error).message });
          }
        }
      }
      await this.saveAwaiting();
    });
  }

  private async saveAwaiting(): Promise<void> {
    const path = join(this.d.data, "replica", "awaiting.json");
    await this.#file(mkdir(dirname(path), { recursive: true }));
    await this.#file(writeFile(`${path}.tmp`, JSON.stringify(Object.fromEntries([...this.awaiting].map(([k, v]) => [k, [...v]])))));
    await this.#file(rename(`${path}.tmp`, path));
  }

  /// The bots of this station's connects as last told to the workspace's other stations, by workspace.
  private readonly botsTold = new Map<string, string>();

  /// This station's connects' bots of `ws` told to its other stations where they changed since they were last told
  /// (as an event of one comes: its bot is known by then), never asked for.
  private tellBots(ws: string): void {
    const bots = [...new Set(this.entries().filter((c) => this.workspaceOf(c) === ws).map((c) => this.own(c.id)?.botUserId() ?? "").filter((b) => b !== ""))].sort();
    const said = JSON.stringify(bots);
    if (this.botsTold.get(ws) === said) return;
    this.botsTold.set(ws, said);
    for (const p of this.d.stations(ws)) {
      if (typeof p?.id !== "string" || p.id === this.d.here()) continue;
      void this.d.bus.ask(p.id, { method: BOTS, workspace: ws, bots }).catch(() => this.botsTold.delete(ws));
    }
  }

  /// What a connect's platform says: to the station a chat of its thread runs on, or a new conversation's to the
  /// station the connect starts them on; the rest to the hub here.
  async receive(id: string, event: ChatEvent): Promise<void> {
    // (a connect being handed to another station, or handed: what its socket here still gives goes there, handled only
    // by the station that holds it; the hand-off failed, it is this one's still)
    const handed = this.handing.get(id);
    if (handed !== undefined) {
      const to = await handed.to;
      // (only while it is not this station's: one of that id here again, added anew by a person, is this one's)
      if (to !== null && (this.entryOf(id) === undefined || this.asking.has(id))) return void (await this.d.bus.ask(to, { method: EVENT, workspace: handed.ws, connect: knownOf(id, this.d.here()), kept: true, event }));
      if (to !== null && this.handing.get(id) === handed) this.handing.delete(id);
    }
    const hub = this.d.hub();
    {
      const entry = this.entryOf(id);
      const ws = entry === undefined ? null : this.workspaceOf(entry);
      if (ws !== null) this.tellBots(ws);
    }
    const connect = hub.config().connects.find((c) => c.id === id);
    const entry = this.entryOf(id);
    const ws = entry === undefined ? null : this.workspaceOf(entry);
    // (a connect that is not routed whose chats are still on their way here: kept for them, in order)
    if (this.awaiting.has(id)) return this.keepFor(id, event);
    if (connect === undefined || ws === null || !ROUTED.includes(connect.kind)) return hub.receive(id, event);
    if (connect.mode === "single-session") return hub.quietIn(ws) ? this.hold(id, ws, event) : hub.receive(id, event);
    const thread = threadOfEvent(event);
    return this.inTurn(`${id}\0${thread.channel}\0${thread.threadTs}`, async () => {
      const there = this.d.store.connectThreadStation(id, thread.channel, thread.threadTs);
      const key = `${id}\0${thread.channel}\0${thread.threadTs}`;
      // (its station is no longer one of the workspace's: the thread is left, said once; what mentions the bot, this
      // message too, starts a new conversation as in any thread it is not in)
      if (there !== null && this.gone(ws, there)) {
        this.d.store.dropConnectThreadStation(id, thread.channel, thread.threadTs);
        this.awayTold.delete(key);
        log.warn("connects", "a chat's station left the workspace; its thread is left", { connect: id, station: there });
        if (event.type === "message") {
          await this.own(id)?.post(thread, markNotice(`⚠️ ${tr(stationLang(), "station.connect.stationGone", { station: this.nameOf(ws, there) })}`), []).catch(() => {});
        }
        if (event.type !== "message" || !event.message.addressed) return;
      } else if (there !== null) {
        try {
          await this.forward(there, id, ws, event);
          this.awayTold.delete(key);
        } catch (e) {
          log.warn("connects", "an event of a chat on another station did not get there", { connect: id, station: there, error: (e as Error).message });
          // (said once while it stays away, and again to each message that mentions the bot)
          if (event.type === "message" && (!this.awayTold.has(key) || event.message.addressed)) {
            this.awayTold.add(key);
            await this.own(id)?.post(thread, markNotice(`⚠️ ${tr(stationLang(), "station.connect.stationAway", { station: this.nameOf(ws, there) })}`), []).catch(() => {});
          }
        }
        return;
      }
      // (its chats here going to another station: kept for it)
      if (hub.quietIn(ws)) return this.hold(id, ws, event);
      // A new conversation starts on the station(s) the connect explicitly allowlists (absent: this one).
      const fresh = event.type === "message" && event.message.addressed && this.d.store.threadAt(hub.surface(id), thread.channel, thread.threadTs) === null;
      if (!fresh) return hub.receive(id, event);
      const here = this.d.here();
      const autoMode = entry?.autoStation === true;
      let rawPool: string[];
      let pool: string[];
      if (autoMode) {
        const seen = new Set<string>();
        const all: string[] = [];
        for (const p of this.d.stations(ws)) {
          if (typeof p?.id === "string") {
            const s = this.bareStationId(p.id);
            if (s !== "" && !seen.has(s)) {
              seen.add(s);
              all.push(s);
            }
          }
        }
        if (here !== "" && !seen.has(here)) {
          seen.add(here);
          all.push(here);
        }
        rawPool = all;
        pool = all.filter((s) => !this.isTasksOnly(ws, s));
      } else {
        rawPool = this.allowlistOf(entry);
        pool = rawPool.filter((s) => (s === here || this.inWorkspace(ws, s)) && !this.isTasksOnly(ws, s));
        if (rawPool.length === 1) {
          const want = pool[0] ?? null;
          if (want === null || want === here) return hub.receive(id, event);
          try {
            await this.forward(want, id, ws, event);
            this.d.store.setConnectThreadStation(id, thread.channel, thread.threadTs, want);
            log.info("connects", "a new conversation runs on another station", { connect: id, station: want });
          } catch (e) {
            if (mayHaveTaken(e)) {
              this.d.store.setConnectThreadStation(id, thread.channel, thread.threadTs, want);
              log.warn("connects", "a new conversation's hand-off was not confirmed in time; pinning to that station without local fallback", { connect: id, station: want, error: (e as Error).message });
              throw e;
            }
            log.warn("connects", "the connect's station for new conversations did not take one; it runs here", { connect: id, station: want, error: (e as Error).message });
            await hub.receive(id, event);
          }
          return;
        }
      }
      // Multi-station manual allowlist or workspace auto-assign allowlist: query live load via peer `describe`
      // (event-driven, no polling) and pick least busy. In `autoMode`, strictly require `acceptAutoChats === true`.
      const probed = await Promise.all(
        pool.map(async (station, idx) => {
          const described = await this.queryStationLoad(ws, station);
          if (described === null || described?.mode === "tasks" || described?.sessions === false) return null;
          if (autoMode && described?.acceptAutoChats !== true) return null;
          const load = described?.load;
          const rawTurns = load?.running?.turns;
          const baseTurns = typeof rawTurns === "number" && Number.isFinite(rawTurns) ? rawTurns : 0;
          const total = load?.memory?.totalBytes;
          const avail = load?.memory?.availableBytes;
          const memRatio = typeof total === "number" && Number.isFinite(total) && total > 0 && typeof avail === "number" && Number.isFinite(avail) && avail >= 0 ? avail / total : -1;
          // Its CPUs too (shared/station-busy.ts): few agents on a machine held full by builds or tasks is no room.
          const share = load?.cpuBusy?.share;
          const cpu = typeof share === "number" && Number.isFinite(share) ? share : null;
          const one = Array.isArray(load?.loadAvg) ? load.loadAvg[0] : null;
          const cores = load?.cpus;
          const loadPerCore = typeof one === "number" && Number.isFinite(one) && typeof cores === "number" && cores > 0 ? one / cores : null;
          return { station, idx, baseTurns, memRatio, cpu, loadPerCore };
        }),
      );
      // Read `inflightCount` and `rrCursor` after the parallel probe settles so simultaneous arrivals spread at once.
      const cursor = pool.length > 0 ? (this.rrCursor.get(id) ?? 0) % pool.length : 0;
      const ranked = probed
        .filter((x): x is NonNullable<typeof x> => x !== null)
        .map((x) => ({ ...x, turns: x.baseTurns + this.inflightCount(id, x.station) }))
        .sort((a, b) => {
          const by = lessBusy({ agents: a.turns, cpu: a.cpu, loadPerCore: a.loadPerCore }, { agents: b.turns, cpu: b.cpu, loadPerCore: b.loadPerCore });
          if (by !== 0) return by;
          if (a.memRatio !== b.memRatio) return b.memRatio - a.memRatio;
          const da = (a.idx - cursor + pool.length) % pool.length;
          const db = (b.idx - cursor + pool.length) % pool.length;
          return da - db;
        });
      for (const candidate of ranked) {
        this.addInflight(id, candidate.station, 1);
        try {
          if (candidate.station === here) {
            await hub.receive(id, event);
          } else {
            await this.forward(candidate.station, id, ws, event);
            this.d.store.setConnectThreadStation(id, thread.channel, thread.threadTs, candidate.station);
            log.info("connects", "a new conversation runs on another station", { connect: id, station: candidate.station });
          }
          this.rrCursor.set(id, (candidate.idx + 1) % pool.length);
          return;
        } catch (e) {
          if (candidate.station !== here && mayHaveTaken(e)) {
            this.d.store.setConnectThreadStation(id, thread.channel, thread.threadTs, candidate.station);
            this.rrCursor.set(id, (candidate.idx + 1) % pool.length);
            log.warn("connects", "a new conversation's hand-off was not confirmed in time; pinning to that station without failing over", { connect: id, station: candidate.station, error: (e as Error).message });
            throw e;
          }
          log.warn("connects", "an allowlisted station for new conversations did not take one; trying next", { connect: id, station: candidate.station, error: (e as Error).message });
        } finally {
          this.addInflight(id, candidate.station, -1);
        }
      }
      // Hard allowlist safety invariant:
      // - In `autoMode`, NEVER fall back to `here` or any non-allowlisted station when 0 allowlisted stations are reachable.
      // - In manual allowlist mode, only fall back to `here` if `here` is explicitly in the allowlist.
      if (!autoMode && pool.includes(here)) {
        await hub.receive(id, event);
        return;
      }
      const names = rawPool.map((s) => this.nameOf(ws, s)).join(tr(stationLang(), "station.list.separator"));
      log.warn("connects", autoMode ? "no workspace-allowlisted station reachable for autoStation connect; refusing local fallback" : "no allowlisted station reachable for new conversation; refusing local fallback", { connect: id, autoStation: autoMode, stations: rawPool });
      await this.own(id)?.post(thread, markNotice(`⚠️ ${tr(stationLang(), "station.connect.stationAway", { station: names })}`), []).catch(() => {});
    });
  }

  // ── one connect, one station ─────────────────────────────────────────────────────────────────────────────────

  /// The station of workspace `ws` a connect of `kind` with this part (its tokens) runs on already, by its name: null
  /// for none (or none that answered).
  async heldBy(ws: string | null, kind: string, own: unknown): Promise<string | null> {
    const print = fingerprint(kind, own);
    if (print === null || ws === null) return null;
    for (const p of this.d.stations(ws)) {
      if (typeof p?.id !== "string" || p.id === this.d.here()) continue;
      const got = await this.d.bus.ask(p.id, { method: LIST, workspace: ws, fingerprint: print }).catch(() => null);
      if (got?.has === true) return this.nameOf(ws, p.id);
    }
    return null;
  }

  /// This station's connects of `ws` (config.json's), and each moved to `to` with the chats here as `to`'s: what a station
  /// retired from `ws` does once its chats are there (replica/retire.ts).
  ownIn(ws: string): string[] {
    return this.entries().filter((c) => this.workspaceOf(c) === ws && typeof c?.id === "string").map((c) => c.id as string);
  }
  /// `ownIn`'s with their kind and mode (move/connects.ts).
  ownKinds(ws: string): { id: string; name: string; kind: string; mode: string }[] {
    return this.namedIn(ws).map((c) => ({ ...c, mode: this.entryOf(c.id)?.mode === "single-session" ? "single-session" : "multi-session" }));
  }
  /// The connects of `ws` added on this station that run on another one now (moved there).
  movedAway(ws: string): { id: string; name: string; kind: string; mode: string }[] {
    return this.remote.connects().filter((c) => c.workspace === ws && !c.id.includes("@")).map((c) => ({ id: c.id, name: c.id, kind: c.kind, mode: c.mode }));
  }
  /// The ids of every connect of this station's.
  ownIds(): string[] {
    return this.entries().filter((c) => typeof c?.id === "string").map((c) => c.id as string);
  }
  /// How connect `id` (as this station names it) goes, its own or another station's (null: not known here).
  kindOf(id: string): { kind: string; mode: string } | null {
    const entry = this.entryOf(id);
    if (entry !== undefined) return { kind: kindOf(entry), mode: entry.mode === "single-session" ? "single-session" : "multi-session" };
    const remote = this.remote.surface(id);
    return remote === undefined ? null : { kind: remote.described.kind, mode: remote.described.mode };
  }
  /// The station connect `id` runs on (null: this one, or not known).
  runsOn(id: string): string | null {
    if (this.entryOf(id) !== undefined) return null;
    return this.remote.surface(id)?.station ?? null;
  }
  /// `ownIn`'s, as the app names them: each one's name (its id where it has none) and kind.
  namedIn(ws: string): { id: string; name: string; kind: string }[] {
    return this.entries().filter((c) => this.workspaceOf(c) === ws && typeof c?.id === "string").map((c) => ({ id: c.id as string, name: typeof c.name === "string" && c.name !== "" ? c.name : (c.id as string), kind: kindOf(c) }));
  }
  /// Each connect is there before what was kept of it goes there, in order, as that station's own connect's (`kept`): a
  /// chat it starts a turn in calls it there (2026-11-14: forwarded before it moved, each such turn failed, the connect
  /// not yet on the station). From then on each event goes there as it comes. One that came on its new socket meanwhile
  /// is in its thread's log by its ts. What did not go stays kept, and goes as this is done again.
  async moveAll(ws: string, to: string): Promise<void> {
    await this.inHeld(async () => {
      // (those kept of a connect moved before this was cut first)
      const own = new Set(this.ownIn(ws));
      await this.sendKept(ws, to, (id) => !own.has(id));
      for (const id of own) {
        await this.move(id, to, null, stationLang(), to);
        await this.sendKept(ws, to, (c) => c === id);
      }
      this.heldTo.set(ws, to);
    });
  }

  /// What was kept of `ws`'s connects that `which` names sent to `to`, where they run now, in order; the rest stays kept.
  private async sendKept(ws: string, to: string, which: (id: string) => boolean): Promise<void> {
    const lines = (await this.#file(readFile(this.heldFile, "utf8")).catch(() => "")).split("\n").filter((l) => l !== "");
    if (lines.length === 0) return;
    const rest: string[] = [];
    for (let i = 0; i < lines.length; i++) {
      let e: Json;
      try {
        e = JSON.parse(lines[i]!);
      } catch {
        continue;
      }
      if (e?.ws !== ws || typeof e.id !== "string" || !which(e.id)) {
        rest.push(lines[i]!);
        continue;
      }
      try {
        await this.d.bus.ask(to, { method: EVENT, workspace: ws, connect: knownOf(e.id, this.d.here()), kept: true, event: e.event });
      } catch (error) {
        await this.writeHeld([...rest, ...lines.slice(i)]);
        throw error;
      }
    }
    await this.writeHeld(rest);
  }

  /// What was kept of `ws`'s platforms while its chats were quiet, taken here after all, in order, as it would have been
  /// as it came: its chats work here again (a retirement called off, or a hand-over that failed: replica/retire.ts).
  async takeHeld(ws: string): Promise<void> {
    const mine: { id: string; event: ChatEvent }[] = [];
    await this.inHeld(async () => {
      const lines = (await this.#file(readFile(this.heldFile, "utf8")).catch(() => "")).split("\n").filter((l) => l !== "");
      if (lines.length === 0) return;
      const rest: string[] = [];
      for (const line of lines) {
        let e: Json;
        try {
          e = JSON.parse(line);
        } catch {
          continue;
        }
        if (e?.ws === ws && typeof e.id === "string") mine.push({ id: e.id, event: e.event as ChatEvent });
        else rest.push(line);
      }
      await this.writeHeld(rest);
    });
    for (const { id, event } of mine) {
      await this.receive(id, event).catch((error) => log.warn("connects", "an event kept while a workspace was quiet not taken", { connect: id, error: (error as Error).message }));
    }
  }

  private inHeld(f: () => Promise<void>): Promise<void> {
    const turn = this.heldTurn.then(f);
    this.heldTurn = turn.catch(() => {});
    return turn;
  }

  /// An event of `ws`'s, whose chats here go to another station: kept, or, once its connects and what was kept went
  /// there, sent there as its connect's there.
  private hold(id: string, ws: string, event: ChatEvent): Promise<void> {
    return this.inHeld(async () => {
      const to = this.heldTo.get(ws);
      if (to !== undefined) return void (await this.d.bus.ask(to, { method: EVENT, workspace: ws, connect: knownOf(id, this.d.here()), kept: true, event }));
      await this.#file(mkdir(dirname(this.heldFile), { recursive: true }));
      await this.#file(appendFile(this.heldFile, `${JSON.stringify({ id, ws, event })}\n`));
    });
  }

  private async writeHeld(lines: string[]): Promise<void> {
    await this.#file(writeFile(`${this.heldFile}.tmp`, lines.map((l) => `${l}\n`).join("")));
    await this.#file(rename(`${this.heldFile}.tmp`, this.heldFile));
  }

  /// A connect moved here: its config.json entry, and its threads' stations (none of those whose chats run here).
  private async take(peer: string, request: Json, workspace: string | undefined): Promise<Json> {
    const known = knownIn(request?.connect);
    const entry = request?.entry;
    if (known === null || entry === null || typeof entry !== "object" || typeof workspace !== "string" || entry.workspace !== workspace || !this.inWorkspace(workspace, peer)) throw new Error("no such connect");
    const id = localOf(known, this.d.here());
    if (this.entryOf(id) !== undefined) throw new Error("that connect runs on this station already");
    // (one handed from here before, back: this station's again)
    this.handing.delete(id);
    // (one of its home workspace says none, as one added here would)
    const { workspace: _, ...rest } = entry;
    await this.d.config.updateSoon((raw) => {
      const connects = Array.isArray(raw.connects) ? raw.connects : (raw.connects = []);
      connects.push({ ...rest, id, ...(workspace !== this.d.home() ? { workspace } : {}) });
    });
    for (const t of Array.isArray(request?.threads) ? request.threads : []) {
      if (typeof t?.channel !== "string" || typeof t?.threadTs !== "string" || typeof t?.station !== "string" || t.station === this.d.here()) continue;
      this.d.store.setConnectThreadStation(id, t.channel, t.threadTs, t.station);
    }
    this.remote.moved(id, this.d.here());
    // (its chats still on their way here: what it says meanwhile is kept for them, delivered once they are here)
    const awaiting = Array.isArray(request?.awaiting) ? request.awaiting.filter((k: unknown): k is string => typeof k === "string") : [];
    if (awaiting.length > 0) await this.await(id, awaiting);
    log.info("connects", "a connect moved here", { connect: id, from: peer });
    return { ok: true };
  }

  /// Moves a connect of this station's to `to`, another of its workspace (`viewer`'s, when a person asks): that
  /// station takes its config.json entry and its threads' stations (this one's, for the chats here, which go on here),
  /// then it is gone from here, and the workspace's other stations are told.
  /// `localsTo`: whose the chats here count as there (this station's, or, as it is retired, the one they went to).
  /// `awaiting`: the chats of it (a connect that is not routed) still here, to come there after it: what its platform
  /// says meanwhile is kept there for them (`arrived`).
  async move(id: string, to: string, viewer: string | null, lang = stationLang(), localsTo = this.d.here(), awaiting: string[] = []): Promise<void> {
    to = this.bareStationId(to);
    const entry = this.entryOf(id);
    const ws = entry === undefined ? null : this.workspaceOf(entry);
    if (entry === undefined || ws === null || (viewer !== null && this.d.home() !== null && ws !== viewer)) throw new Refused(404, `unknown connect ${id}`);
    if (to === this.d.here() || !this.inWorkspace(ws, to)) throw new Refused(400, tr(lang, "station.connect.moveWhere"));
    const known = knownOf(id, this.d.here());
    // (a thread routed elsewhere already, a chat of it handed from here to another station, goes on there)
    const routed = this.d.store.connectThreads(id);
    const seen = new Set(routed.map((t) => `${t.channel}\0${t.threadTs}`));
    const threads = [...routed, ...this.d.store.connectLocalThreads(id).filter((t) => !seen.has(`${t.channel}\0${t.threadTs}`)).map((t) => ({ ...t, station: localsTo }))].filter((t) => t.station !== to);
    // (kept before it is asked: a stop from here on is settled by asking it, as this station starts; settled by its
    // answer meanwhile, not by a settling that asks it first)
    this.asking.add(id);
    const taken = Promise.withResolvers<string | null>();
    this.handing.set(id, { to: taken.promise, ws });
    try {
      await this.keepMoving({ id, to, ws, localsTo });
      await this.d.bus.ask(to, { method: TAKE, workspace: ws, connect: known, entry: { ...entry, workspace: ws }, threads, ...(awaiting.length > 0 ? { awaiting } : {}) });
    } catch (e) {
      this.handing.delete(id);
      this.asking.delete(id);
      taken.resolve(null);
      // (refused there: it did not take it; no answer: it may have, asked as it is heard from, the record kept)
      if (e instanceof Declined) await this.doneMoving(id);
      else void this.settleMoving(to);
      throw e;
    }
    taken.resolve(to);
    this.asking.delete(id);
    await this.handedOff(id, to, ws, localsTo);
    log.info("connects", "connect moved to another station", { connect: id, to });
  }
}

/// A connect's move under way, as kept (`moving`).
type Moving = { id: string; to: string; ws: string; localsTo: string };

const kindOf = (c: Json): string => (typeof c?.kind === "string" ? c.kind : "slack");

export const WorkspaceConnectsLive = Layer.effectDiscard(
  Effect.gen(function* () {
    const { data } = yield* Paths;
    const agents = yield* Agents;
    const bus = yield* Peers;
    const store = yield* Store;
    const config = yield* StationConfig;
    const parts = yield* Parts;
    const cloud = (yield* ControlPlane).state;
    const clock = yield* Clock.clockWith(Effect.succeed);
    const connects = new WorkspaceConnects({
      data, store, config, bus,
      hub: () => agents.hub,
      here: () => cloud.state?.station ?? "",
      home: () => cloud.home(),
      stations: (ws) => cloud.membership(ws)?.peers ?? [],
      names: (kind) => agents.nameBooks.get(kind) ?? null,
      selfLoad: () => agents.remote.selfDescribe(),
      sleep: (ms) => Effect.runPromise(Effect.sleep(Duration.millis(ms)).pipe(Effect.provideService(Clock.Clock, clock))),
      connectsReady: () => agents.connectsReady,
      clock,
    });
    // (the connects of other stations its chats run on, known before the hub asks for them)
    yield* Effect.promise(() => connects.remote.ready());
    agents.surfaces((id) => connects.remote.surface(id));
    agents.connects(() => connects.remote.connects());
    agents.route((id, event) => connects.receive(id, event));
    agents.connectHeld((ws, kind, own) => connects.heldBy(ws, kind, own));
    agents.workspaceConnects = connects;
    agents.retireConnects = { of: (ws) => connects.ownIn(ws), named: (ws) => connects.namedIn(ws), move: (ws, to) => connects.moveAll(ws, to), takeHeld: (ws) => connects.takeHeld(ws) };
    const routes: Route[] = [
      {
        method: "POST",
        pattern: /^\/*connects\/+([^/]+)\/+move\/*$/,
        handle: async (r, [at]) => {
          try {
            const to = input(r).station;
            if (typeof to !== "string" || to === "") throw new Refused(400, tr(r.lang, "station.connect.moveWhere"));
            const id = segment(at!);
            await connects.move(id, to, r.viewer.workspace, r.lang);
            log.info("admin", "connect moved from the admin page", { connect: id, to, by: r.viewer.email });
            return ok(await agents.overview(r.viewer, r.lang));
          } catch (e) {
            if (e instanceof Refused) return error(e.status, e.message);
            log.error("admin", "admin request failed", { path: r.path, error: (e as Error).message });
            return error(500, (e as Error).message);
          }
        },
      },
    ];
    parts.routes(routes);
  }),
);
