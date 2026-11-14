// The workspace's connects (connects/remote.ts) as a part of the agents' side: on the station a connect runs on, its
// platform's events routed to the station a chat of their thread runs on, the calls of those chats answered, the connect
// moved to another station by hand (POST /connects/:id/move); on the station a chat runs on, the events taken and the
// connect's surface asked; on every one, whether a connect being added runs on another station already.
import { createHash } from "node:crypto";
import { readFileSync, rmSync } from "node:fs";
import { appendFile, mkdir, readFile, rename, rm, writeFile } from "node:fs/promises";
import { dirname, join } from "node:path";
import { Effect, Layer } from "effect";
import type { Route } from "../api/admin.ts";
import { error, input, ok, Refused, segment } from "../api/request.ts";
import type { Inbox } from "../mesh/bus.ts";
import { log } from "../ops/log.ts";
import { stationLang, tr } from "../ops/i18n.ts";
import { Agents } from "../sessions/agents.ts";
import { type ChatEvent, markNotice } from "../sessions/chat.ts";
import type { ConnectKind } from "../sessions/config.ts";
import type { Hub } from "../sessions/hub.ts";
import { ControlPlane, Parts, Paths, Peers, StationConfig, Store } from "../services.ts";
import type { Store as StoreT } from "../store/store.ts";
import type { NameBook } from "./names.ts";
import { BOTS, CALL, EVENT, LIST, MOVED, ROUTE, ROUTED, RemoteConnects, RemoteSurface, TAKE, type Described, type Known, answerCall, describe, knownIn, knownOf, localOf, threadOfEvent } from "./remote.ts";

type Json = any;

/// What a connect's secret is known by across the workspace without being said: its platform's token (Slack's bot
/// token, a Comma line's token) or its app (Feishu's), hashed. Null: one that has none yet.
export function fingerprint(kind: string, own: Json): string | null {
  const secret = kind === "feishu" ? own?.appId : kind === "comma" ? own?.token : own?.botToken;
  return typeof secret === "string" && secret !== "" ? createHash("sha256").update(`${kind}\n${secret}`).digest("hex") : null;
}

export type WorkspaceConnectsDeps = {
  data: string;
  hub: () => Hub;
  store: StoreT;
  config: { raw(): Json; update(f: (raw: Json) => void): void };
  /// This station's id, and its home workspace.
  here: () => string;
  home: () => string | null;
  /// The stations of one of this station's workspaces (the cloud's roster: `{id, name}`); none of any other.
  stations: (ws: string) => Json[];
  bus: { ask(station: string, request: Json): Promise<Json>; on(method: string, inbox: Inbox): void };
  /// Each platform's names book.
  names: (kind: ConnectKind) => NameBook | null;
};

export class WorkspaceConnects {
  readonly remote: RemoteConnects;
  private readonly d: WorkspaceConnectsDeps;
  /// The files a chat of another station posts, until they are posted.
  private readonly uploads: string;
  /// One event at a time per thread: a conversation's first message is handed on before its next is looked at.
  private readonly gates = new Map<string, Promise<void>>();
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
    rmSync(this.uploads, { recursive: true, force: true });
    try {
      const kept = JSON.parse(readFileSync(join(d.data, "replica", "awaiting.json"), "utf8")) as Record<string, string[]>; // sync: read once, before the station serves
      for (const [id, keys] of Object.entries(kept)) if (Array.isArray(keys) && keys.length > 0) this.awaiting.set(id, new Set(keys));
    } catch {}
    this.remote = new RemoteConnects(d.data, d.here, (station, request) => d.bus.ask(station, request), d.names);
    d.bus.on(EVENT, (peer, request, workspace) => this.taken(peer, request, workspace));
    d.bus.on(MOVED, async (_peer, request) => {
      const known = knownIn(request?.connect);
      if (known === null || typeof request?.station !== "string") throw new Error("no such connect");
      this.remote.moved(localOf(known, d.here()), request.station);
      return { ok: true };
    });
    d.bus.on(
      CALL,
      answerCall((known: Known, workspace: string | undefined) => {
        const id = localOf(known, d.here());
        const entry = this.entryOf(id);
        return entry !== undefined && this.workspaceOf(entry) === workspace ? this.own(id) : undefined;
      }, this.uploads),
    );
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
  private nameOf(ws: string, station: string): string {
    return String(this.d.stations(ws).find((p) => p?.id === station)?.name ?? station);
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
    this.remote.learn(id, peer, d);
    const event = request.event as ChatEvent;
    // (its chat was handed from here to another station, and the connect's station not told yet, or the event already
    // on its way: it goes on there, as the connect's station would send it)
    const thread = threadOfEvent(event);
    const moved = this.d.hub().movedTo(id, thread.channel, thread.threadTs);
    if (moved !== null && moved !== this.d.here()) {
      await this.d.bus.ask(moved, { method: EVENT, workspace, connect: known, described: d, event });
      return { ok: true };
    }
    await this.d.hub().receive(id, event);
    // Its people and channel named here as there (the pages read them from this station's names book).
    if (event.type === "message") {
      const chat = this.remote.surface(id);
      chat?.knownPerson(event.message.user);
      chat?.knownChannel(event.message.channel);
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
      await mkdir(dirname(file), { recursive: true });
      await appendFile(file, `${JSON.stringify(event)}\n`);
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
        const lines = (await readFile(file, "utf8").catch(() => "")).split("\n").filter((l) => l !== "");
        await rm(file, { force: true });
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
    await mkdir(dirname(path), { recursive: true });
    await writeFile(`${path}.tmp`, JSON.stringify(Object.fromEntries([...this.awaiting].map(([k, v]) => [k, [...v]]))));
    await rename(`${path}.tmp`, path);
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
      if (there !== null) {
        try {
          await this.forward(there, id, ws, event);
        } catch (e) {
          log.warn("connects", "an event of a chat on another station did not get there", { connect: id, station: there, error: (e as Error).message });
          if (event.type === "message") {
            await this.own(id)?.post(thread, markNotice(`⚠️ ${tr(stationLang(), "station.connect.stationAway", { station: this.nameOf(ws, there) })}`), []).catch(() => {});
          }
        }
        return;
      }
      // (its chats here going to another station: kept for it)
      if (hub.quietIn(ws)) return this.hold(id, ws, event);
      // A new conversation starts on the station the connect names (absent, or not of its workspace: this one).
      const want = typeof entry.station === "string" ? entry.station : null;
      const fresh = event.type === "message" && event.message.addressed && this.d.store.threadAt(hub.surface(id), thread.channel, thread.threadTs) === null;
      if (!fresh || want === null || want === this.d.here() || !this.inWorkspace(ws, want)) return hub.receive(id, event);
      try {
        await this.forward(want, id, ws, event);
        this.d.store.setConnectThreadStation(id, thread.channel, thread.threadTs, want);
        log.info("connects", "a new conversation runs on another station", { connect: id, station: want });
      } catch (e) {
        log.warn("connects", "the connect's station for new conversations did not take one; it runs here", { connect: id, station: want, error: (e as Error).message });
        await hub.receive(id, event);
      }
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
    const lines = (await readFile(this.heldFile, "utf8").catch(() => "")).split("\n").filter((l) => l !== "");
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
      const lines = (await readFile(this.heldFile, "utf8").catch(() => "")).split("\n").filter((l) => l !== "");
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
      await mkdir(dirname(this.heldFile), { recursive: true });
      await appendFile(this.heldFile, `${JSON.stringify({ id, ws, event })}\n`);
    });
  }

  private async writeHeld(lines: string[]): Promise<void> {
    await writeFile(`${this.heldFile}.tmp`, lines.map((l) => `${l}\n`).join(""));
    await rename(`${this.heldFile}.tmp`, this.heldFile);
  }

  /// A connect moved here: its config.json entry, and its threads' stations (none of those whose chats run here).
  private async take(peer: string, request: Json, workspace: string | undefined): Promise<Json> {
    const known = knownIn(request?.connect);
    const entry = request?.entry;
    if (known === null || entry === null || typeof entry !== "object" || typeof workspace !== "string" || entry.workspace !== workspace || !this.inWorkspace(workspace, peer)) throw new Error("no such connect");
    const id = localOf(known, this.d.here());
    if (this.entryOf(id) !== undefined) throw new Error("that connect runs on this station already");
    // (one of its home workspace says none, as one added here would)
    const { workspace: _, ...rest } = entry;
    this.d.config.update((raw) => {
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
    const entry = this.entryOf(id);
    const ws = entry === undefined ? null : this.workspaceOf(entry);
    if (entry === undefined || ws === null || (viewer !== null && this.d.home() !== null && ws !== viewer)) throw new Refused(404, `unknown connect ${id}`);
    if (to === this.d.here() || !this.inWorkspace(ws, to)) throw new Refused(400, tr(lang, "station.connect.moveWhere"));
    const d = this.described(id);
    const known = knownOf(id, this.d.here());
    // (a thread routed elsewhere already, a chat of it handed from here to another station, goes on there)
    const routed = this.d.store.connectThreads(id);
    const seen = new Set(routed.map((t) => `${t.channel}\0${t.threadTs}`));
    const threads = [...routed, ...this.d.store.connectLocalThreads(id).filter((t) => !seen.has(`${t.channel}\0${t.threadTs}`)).map((t) => ({ ...t, station: localsTo }))].filter((t) => t.station !== to);
    await this.d.bus.ask(to, { method: TAKE, workspace: ws, connect: known, entry: { ...entry, workspace: ws }, threads, ...(awaiting.length > 0 ? { awaiting } : {}) });
    this.d.config.update((raw) => {
      raw.connects = (Array.isArray(raw.connects) ? raw.connects : []).filter((c: Json) => c?.id !== id);
    });
    this.d.store.dropConnectThreads(id);
    // The chats here go on through it there.
    if (d !== null && localsTo === this.d.here()) this.remote.learn(id, to, d);
    for (const p of this.d.stations(ws)) {
      if (typeof p?.id !== "string" || p.id === this.d.here() || p.id === to) continue;
      void this.d.bus.ask(p.id, { method: MOVED, workspace: ws, connect: known, station: to }).catch(() => {});
    }
    log.info("connects", "connect moved to another station", { connect: id, to });
  }
}

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
    const connects = new WorkspaceConnects({
      data, store, config, bus,
      hub: () => agents.hub,
      here: () => cloud.state?.station ?? "",
      home: () => cloud.home(),
      stations: (ws) => cloud.membership(ws)?.peers ?? [],
      names: (kind) => agents.nameBooks.get(kind) ?? null,
    });
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
