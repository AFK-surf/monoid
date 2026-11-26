// The presence socket to the control plane (the Rust station's main.rs `presence`, `connect`, `apply_state`): open while
// the station answers is the station online; the cloud pushes on it where the station is, its relays and roster, and
// what it takes back. Signed at connect like enrollment. Reconnects with backoff; once removed from its workspace, asks
// again only now and then, or at once when enrolled anew meanwhile. Which control plane, and how it is spoken to, is
// the provider's (provider.ts), read anew at every connect.
import { readFileSync } from "node:fs";
import { mkdir, rename, rm, writeFile } from "node:fs/promises";
import { join } from "node:path";
import { Clock, Effect, Stream, SubscriptionRef } from "effect";
import WebSocket from "ws";
import { log } from "../ops/log.ts";
import { nowSecs } from "../ops/files.ts";
import { version } from "../ops/version.ts";
import { type Cloud as CloudState, type RigSelf, MODE_PENDING_S, isRevocation, joinedOf, joinedPendingPath, pendingLockPath, rigGrantsPath, rigsOf, waysSaidOf } from "./state.ts";
import { type Entry, asEntry, entryHash, fold } from "../../../shared/lock.ts";
import { hashOf } from "../../../shared/log-keep.ts";
import type { StationKey } from "./key.ts";
import type { CloudSaid } from "./plane.ts";
import { type ProviderSpec, signedHeaders } from "./provider.ts";
import { wall } from "../ops/fibers.ts";
import { type Ways, waysOf } from "../mesh/ways.ts";
import { globalRelaysOf } from "../mesh/global-relays.ts";

/// The cloud expects a "ping" this often and drops a station silent for three of them.
const PING_MS = 30_000;
/// How the cloud closes the socket of a station removed from its workspace.
const CLOSE_REMOVED = 4004;
/// How the cloud closes a station's socket as another of the same station's (its key) connects (cloud/src/station.ts).
export const CLOSE_REPLACED = 4000;
/// So many sockets in a row replaced before they held a heartbeat (`steady`): another station connects with this one's
/// key (a copy of its data on another machine, a second process here). One station's own new socket replaces its old
/// one once, a handover's twice at most, and the one replaced does not connect again.
export const REPLACED_IN_A_ROW = 3;
/// How long a station whose key another uses waits before it connects again: each connecting replaces the other, so
/// at the backoff's start the two took each other's place every second (2026-11-16), and the relays its endpoint too.
export const CONFLICT_BACKOFF_MS = 60_000;
/// What presence.json says of it, for `stillfail status`.
export const CONFLICT_ERROR = "another station is using this station's key: still.fail cloud keeps replacing one's presence socket with the other's; stop the other or enroll one of them again";
const CONNECT_TIMEOUT_MS = 20_000;
/// How long the roster the cloud said last counts as reached once its socket ended. A socket the cloud closes is back
/// within seconds (one station's about every 20 minutes, 2026-10-29): those seconds are not shown as cut off. The roster itself
/// is taken on past this (cloud/state.ts `peersCurrent`), until the station is removed.
export const ROSTER_GRACE_MS = 60_000;


/// Whether the station is online at still.fail cloud, and since when or why not: <data>/run/presence.json, for
/// `stillfail status`.
/// Each write after the one before (in the order said), whole: to a file of this process's beside it, renamed into place.
function presenceWriter(data: string): (online: boolean, error: string | null, conflict?: boolean) => void {
  const path = join(data, "run", "presence.json");
  let written: Promise<void> = Promise.resolve();
  return (online, error, conflict = false) => {
    const text = JSON.stringify({ online, at: nowSecs(), error, ...(conflict ? { conflict } : {}) }) + "\n";
    written = written
      .then(async () => {
        await mkdir(join(data, "run"), { recursive: true });
        await writeFile(`${path}.${process.pid}`, text);
        await rename(`${path}.${process.pid}`, path);
      })
      .catch((e: Error) => log.warn("presence", "presence.json not written", { error: e.message }));
  };
}

/// What the presence socket is given: cloud.json and its changes, the key, whether the station answers, and the
/// provider it is enrolled with.
export type PresenceParts = {
  cloud: { state: CloudState; changes: Stream.Stream<void> };
  key: StationKey;
  up: SubscriptionRef.SubscriptionRef<boolean>;
  spec: () => ProviderSpec;
  /// What the cloud tells the station of besides its state (plane.ts `told`).
  said?: (event: CloudSaid) => void;
  /// The heartbeat's timer (tests: theirs).
  every?: (ms: number, f: () => void) => () => void;
};

/// Whether another station uses this one's key, as its sockets end (`ended`) and hold (`steady`): REPLACED_IN_A_ROW
/// replaced in a row before they held is a conflict, which only a socket that held a heartbeat ends. Not on its open:
/// the other takes its place again a moment later, and `stillfail status` would flicker back to normal.
export class Replaced {
  inARow = 0;
  conflict = false;
  private readonly told: (conflict: boolean) => void;
  constructor(told: (conflict: boolean) => void = () => {}) {
    this.told = told;
  }

  /// A socket ended: with the close code the cloud gave (none: it broke), having held a heartbeat or not.
  ended(code: number | null, held: boolean) {
    if (code === CLOSE_REPLACED && !held) this.inARow++;
    else if (code !== null) this.inARow = 0;
    if (this.inARow >= REPLACED_IN_A_ROW && !this.conflict) {
      this.conflict = true;
      log.error("presence", "another station is using this station's key (presence socket replaced repeatedly)", { inARow: this.inARow });
      this.told(true);
    }
  }

  /// A socket held a heartbeat (the cloud answered its first ping).
  steady() {
    this.inARow = 0;
    if (!this.conflict) return;
    this.conflict = false;
    log.info("presence", "this station's presence socket holds again: no other station uses its key now");
    this.told(false);
  }
}

/// Keeps the socket for good (until interrupted): open while the station is up.
export const presence = ({ cloud, key, up, spec, said, every = wall.every }: PresenceParts) => Effect.gen(function* () {
  const until = (wanted: boolean) => SubscriptionRef.changes(up).pipe(Stream.filter((now) => now === wanted), Stream.runHead);
  let backoff = 1000;
  const writePresence = presenceWriter(cloud.state.data);
  const replaced = new Replaced((conflict) => writePresence(!conflict, conflict ? CONFLICT_ERROR : null, conflict));
  for (;;) {
    if (!(yield* SubscriptionRef.get(up))) {
      yield* until(true);
      backoff = 1000;
    }
    const s = cloud.state;
    s.reload();
    if (s.removed()) {
      // The cloud forgot the station as it removed it: only enrolling it again (by the station, which changes
      // cloud.json) brings it back, and nothing else is asked until then.
      writePresence(false, "removed from its workspace; enroll it again to bring it back");
      yield* cloud.changes.pipe(Stream.filter(() => !s.removed()), Stream.runHead);
      continue;
    }
    const started = yield* Clock.currentTimeMillis;
    const plane = spec();
    // The socket, until it ends or the station stops answering (then it is closed: offline at the cloud).
    const notAnswering = { why: `station not answering; went offline at ${plane.name}`, code: null, held: false };
    const ended = yield* Effect.result(Effect.raceFirst(connect(s, key, plane, said, every, replaced, writePresence), Effect.as(until(false), notAnswering)));
    lapse(s);
    if (ended._tag === "Success") replaced.ended(ended.success.code, ended.success.held);
    const why = ended._tag === "Success" ? ended.success.why : failureText(ended.failure);
    writePresence(false, replaced.conflict ? `${CONFLICT_ERROR} (${why})` : why, replaced.conflict);
    if (ended._tag === "Success") {
      // (each replaced socket said once a conflict is known: replaced.ended said it)
      if (!replaced.conflict) log.info("presence", why);
    } else log.warn("presence", `no presence socket to ${plane.name}`, { error: why });
    // A socket that held a while starts over quickly; failing again and again backs off to a minute; another station
    // on this key waits the minute at once.
    if ((yield* Clock.currentTimeMillis) - started > 60_000) backoff = 1000;
    if (replaced.conflict) backoff = CONFLICT_BACKOFF_MS;
    yield* Effect.sleep(backoff); // timer: a retry after a failure, with a backoff
    backoff = Math.min(backoff * 2, 60_000);
  }
});

/// What a failed socket says: every address's own error when they all failed (Node's AggregateError, whose message is
/// empty: the log said only `error=`).
export function failureText(error: Error): string {
  const each = error instanceof AggregateError ? error.errors.map((e) => (e instanceof Error ? e.message : String(e))).filter((m) => m.length > 0) : [];
  return each.length > 0 ? each.join("; ") : error.message || error.name;
}

/// The roster said last, no longer reached once ROSTER_GRACE_MS passed with no fresh one; not taken at all at once when
/// the station was removed.
export function lapse(s: CloudState, after: (ms: number, f: () => void) => unknown = wall.after) {
  if (s.removed()) {
    s.lapsed();
    return;
  }
  const said = s.rostersSaid;
  after(ROSTER_GRACE_MS, () => {
    if (s.rostersSaid === said) s.lapsed();
  });
}

/// Whether `event` is something the cloud tells of besides the station's state (a release out, the models' catalog
/// changed), told to `said`.
function cloudSaid(event: unknown, said?: (event: CloudSaid) => void): boolean {
  const type = (event as { type?: unknown } | null)?.type;
  if (type === "release") said?.({ type });
  else if (type === "models") {
    const etag = (event as { etag?: unknown }).etag;
    said?.(typeof etag === "string" ? { type, etag } : { type });
  } else return false;
  return true;
}

/// One socket, signed at connect like enrollment: succeeds with why it ended when the cloud closes it (its code, and
/// whether it held a heartbeat first), fails when it can't be had or breaks; closed when interrupted.
const connect = (s: CloudState, key: StationKey, plane: ProviderSpec, said: ((event: CloudSaid) => void) | undefined, every: (ms: number, f: () => void) => () => void, replaced: Replaced, writePresence: ReturnType<typeof presenceWriter>) =>
  Effect.callback<{ why: string; code: number | null; held: boolean }, Error>((resume) => {
    let created: WebSocket | undefined;
    let ping: (() => void) | undefined;
    let unlisten = () => {};
    let unlistenWays = () => {};
    try {
      const state = s.state!;
      const ts = nowSecs();
      // New clouds read the canonical proof; old clouds their original one.
      const headers = signedHeaders(plane.connectPrefixes, state.station, ts, (prefix) => key.sign(`${prefix}-station-connect-v1:${state.origin}:${state.station}:${ts}`), { version: version() });
      const url = `${state.origin.replace("http", "ws")}${plane.connectPath}`;
      const regional = plane.provider === "stillfail" && s.transport.eligible(state.origin, plane.provider);
      const socket = created = regional ? s.transport.websocket(url, headers, WebSocket) : new WebSocket(url, { headers, handshakeTimeout: CONNECT_TIMEOUT_MS });
      let answered = true;
      let held = false;
      const send = (frame: unknown) => socket.send(JSON.stringify(frame));
      const open = () => socket.readyState === WebSocket.OPEN;
      const { tell, askPending } = planeTeller(s, send, open);
      // The workspaces' ways, to still.fail's cloud alone (Comma's plane keeps none: provider.ts).
      const tellWays = plane.provider === "stillfail" ? waysTeller(s, waysOf(s), send, open) : () => {};
      tell();
      unlisten = s.listen(() => {
        replaySkippedRigFrame(s, (frame) => open() && send(frame));
        tell();
        tellWays();
      });
      if (plane.provider === "stillfail") unlistenWays = waysOf(s).listen(tellWays);
      let failed: Error | null = null;
      socket.on("unexpected-response", (_, response) => {
        if (response.statusCode === 404) {
          removed(s, 404);
          failed = new Error("station removed");
        } else {
          failed = new Error(`${plane.name} answered ${response.statusCode}`);
        }
        socket.terminate();
      });
      socket.on("error", (error) => (failed ??= error));
      socket.on("open", () => {
        takenBack(s, plane);
        // Another station on this key still, until this socket holds (Replaced).
        writePresence(true, replaced.conflict ? CONFLICT_ERROR : null, replaced.conflict);
        log.info("presence", `online at ${plane.name}`);
        tellWays();
        // The cloud's answering is in the machine's time.
        ping = every(PING_MS, () => { // timer: a heartbeat that keeps the connection
          // No pong since the last ping: gone even if the socket has not noticed.
          if (!answered) {
            failed = new Error(`${plane.name} stopped answering`);
            socket.terminate();
            return;
          }
          answered = false;
          socket.send("ping");
          askPending();
        });
      });
      socket.on("message", (data, binary) => {
        if (binary) return;
        const text = data.toString();
        if (text === "pong") {
          answered = true;
          if (!held) {
            held = true;
            replaced.steady();
          }
          return;
        }
        // Each frame is told by its parsed `type`, never by where that field sits in the text: a provider's encoder may
        // put it anywhere (Comma's map encoder puts it last).
        let body: any;
        try {
          body = JSON.parse(text);
        } catch {
          return;
        }
        if (cloudSaid(body, said)) return;
        if (body?.type === "tool") tool(s, plane, socket, body);
        else applyFrame(s, body, (frame) => socket.readyState === WebSocket.OPEN && socket.send(JSON.stringify(frame)));
      });
      socket.on("close", (code, reason) => {
        ping?.();
        unlisten();
        unlistenWays();
        if (code === CLOSE_REMOVED) removed(s, CLOSE_REMOVED);
        // With its code and reason: replaced by another socket of this station's (4000), silent (4008), the cloud restarting (1001, 1012)…
        const why = reason.length > 0 ? `${code} ${reason.toString("utf8")}` : String(code);
        resume(failed ? Effect.fail(failed) : Effect.succeed({ why: `${plane.name} closed the presence socket (${why})`, code, held }));
      });
      return Effect.sync(() => {
        ping?.();
        unlisten();
        unlistenWays();
        if (regional) socket.terminate();
        else socket.close();
      });
    } catch (error) {
      // Connection preparation can fail before a socket emits an error. Keep the same status and retry path.
      ping?.();
      unlisten();
      unlistenWays();
      if (created) {
        created.removeAllListeners();
        created.on("error", () => {});
        created.terminate();
      }
      resume(Effect.fail(error instanceof Error ? error : new Error(String(error))));
      return Effect.void;
    }
  });

/// What a station tells the plane of its locks on one socket (`send`, while `open`): the entries it took from devices
/// and other stations since the socket opened (the plane keeps the lock for whoever asks it next): the home
/// workspace's, and each joined one's (`workspace` says which); and the locks joining named, asked for (pendingAsks).
/// `tell` as cloud.json changes, `askPending` as the station hears it joined and at each ping.
export function planeTeller(s: CloudState, send: (frame: unknown) => void, open: () => boolean) {
  const told = new Map<string, number>();
  const asked = new Set<string>();
  const askPending = () => {
    if (!open()) return;
    for (const ws of pendingAsks(s, asked)) send(ws === null ? { type: "lock.get", after: -1 } : { type: "lock.get", after: -1, workspace: ws });
  };
  const tell = () => {
    for (const m of s.memberships()) {
      const ws = m.home ? null : m.workspace;
      const seq = s.chain(ws)?.state?.seq;
      const plane = ws === null ? s.planeLockSeq : (s.planeLockSeqs.get(ws) ?? null);
      const was = told.get(m.workspace) ?? (s.chain(ws)?.state?.seq ?? -1);
      if (!told.has(m.workspace)) told.set(m.workspace, was);
      if (seq === undefined || !open() || plane === null) continue;
      // (a plane whose chain parted from the one gone by here, this station's having moved to another branch since the
      // plane said its head, at the same place too: given what it goes by from where they part, planeParted)
      if (!planeOnChain(s, ws, plane)) {
        planeParted(s, ws, send);
        continue;
      }
      if (seq <= was) continue;
      const entries = s.lockAfter(Math.max(plane, -1), ws);
      if (entries.length > 0) send({ type: "lock.put", entries, ...(ws === null ? {} : { workspace: ws }) });
      told.set(m.workspace, seq);
    }
    askPending();
  };
  return { tell, askPending };
}

/// What a station tells still.fail's cloud of its workspaces' ways on one socket (`send`, while `open`): the record it
/// keeps of each workspace it is in (mesh/ways.ts), as the socket opens and as one changes, each record once a socket.
/// The cloud keeps the newest of its stations' (cloud/src/directory.ts `#waysPut`) for those that reach no station yet:
/// an app from before the stations kept them, and a browser or a device new to the workspace, which learn its relays
/// only from `/v1/me` (2026-11-16, Hypershell: still.fail's relays off on its stations, the web app reached none). Only
/// told, never waited on, and the station never goes by it back once it keeps a record (mesh/ways.ts `view`). A rig
/// tells none: the cloud takes none of it.
export function waysTeller(s: CloudState, ways: Ways, send: (frame: unknown) => void, open: () => boolean): () => void {
  const told = new Map<string, string>();
  return () => {
    if (!open()) return;
    for (const m of s.fullMemberships()) {
      const r = ways.record(m.workspace);
      if (r === null || told.get(m.workspace) === `${r.at}:${r.station}`) continue;
      told.set(m.workspace, `${r.at}:${r.station}`);
      send({ type: "ways.put", workspace: m.workspace, relays: r.relays.map((x) => x.url), off: r.off, at: r.at, station: r.station });
    }
  };
}

/// A device tool request pushed on the socket (`{type: "tool", id, request}`, contract §8 presence transport): run
/// by the mesh's tools and answered `{type: "tool_result", id, response}`. Only a provider with device tools pushes
/// them.
function tool(s: CloudState, plane: ProviderSpec, socket: WebSocket, body: any) {
  if (typeof body.id !== "string") return;
  // Locked, the control plane pushes no tools: a gateway the lock names calls them itself (mesh/tools.ts).
  const run = plane.tools && s.locked() === null ? s.toolCalls : null;
  const reply = (response: unknown) => {
    if (socket.readyState === WebSocket.OPEN) socket.send(JSON.stringify({ type: "tool_result", id: body.id, response }));
  };
  if (run === null) reply({ ok: false, error: { code: "unavailable", message: "this station takes no device tools now" } });
  else run(body.request).then(reply, (e) => reply({ ok: false, error: { code: "invalid_request", message: (e as Error).message } }));
}

/// The cloud says the station is out of its workspace: marked in cloud.json, kept through restarts.
function removed(s: CloudState, code: number) {
  if (s.removed()) return;
  log.warn("presence", "this station was removed from its workspace; it stops its work and refuses connections", { code });
  s.update((st) => {
    st.removed_at = nowSecs();
    st.removed_code = code;
  });
}

/// The cloud took the socket: a station it had removed is in its workspace again.
function takenBack(s: CloudState, plane: ProviderSpec) {
  if (!s.removed()) return;
  log.info("presence", `${plane.name} takes this station again; back to work`);
  s.update((st) => {
    delete st.removed_at;
    delete st.removed_code;
  });
}

/// Workspaces listed as rig-mode by the plane's last `state` frame that had no local `RigSelf` yet (e.g. the frame
/// arrived during `joinWorkspace` before `cloud.json` was written). Kept per `CloudState` so that as soon as
/// `cloud.json` gains `RigSelf` for one of them, the saved frame is replayed and its peers/lock take effect without
/// waiting for the next cloud frame.
const skippedRigState = new WeakMap<CloudState, { skipped: Set<string>; frame: any }>();

/// Replay the last `state` frame if `cloud.json` now has local `RigSelf` for any workspace that was skipped because
/// it was listed as rig-mode before its local `RigSelf` was written.
export function replaySkippedRigFrame(s: CloudState, send: (frame: unknown) => unknown = () => {}): boolean {
  const saved = skippedRigState.get(s);
  if (!saved || saved.skipped.size === 0) return false;
  let ready = false;
  for (const ws of saved.skipped) {
    if (s.rigIn(ws) !== null) {
      ready = true;
      break;
    }
  }
  if (!ready) return false;
  skippedRigState.delete(s);
  applyFrame(s, saved.frame, send);
  return true;
}

/// What the cloud pushes: where the station is and what it is called, its relays, roster and grant keys, what it
/// takes back; the workspace lock's head, and its entries when asked (`send` answers on the socket). Once a lock is
/// pinned, the station stays in its workspace and at its origin whatever the frame says, and the roster and gateways
/// are only those the lock names too (cloud/state.ts `filtered`).
export function applyState(s: CloudState, text: string, send: (frame: unknown) => unknown = () => {}) {
  let body: any;
  try {
    body = JSON.parse(text);
  } catch {
    return;
  }
  applyFrame(s, body, send);
}

function applyFrame(s: CloudState, body: any, send: (frame: unknown) => unknown) {
  if (body?.type === "state") {
    const meshRelays = globalRelaysOf(body.mesh_relays);
    // A workspace it joined taking over from a home it was taken out of: its lock goes along (cloud/state.ts `succeed`).
    // So too, its home not locked (which the plane moves at its word), any workspace this station keeps a lock for, or
    // one joining named, listed now or not, its old home gone or not: else that lock, joined workspaces' only, would
    // be left behind and the workspace taken as the plane says.
    const was = s.state;
    const incomingJoined = joinedOf(body.workspaces);
    const moved = was !== null && typeof body.workspace === "string" && body.workspace !== was.workspace;
    const oldHomeStillIn = moved && incomingJoined.some((j) => j.workspace === was.workspace);
    const keptThere = moved && s.chain() === null && (s.chain(body.workspace) !== null || s.pendingLock(body.workspace) !== null);
    const took = moved && (oldHomeStillIn
      ? s.succeed(body.workspace, true)
      : (keptThere || (was.joined ?? []).some((j) => j.workspace === body.workspace)) && s.succeed(body.workspace, false));
    const locked = s.chain() !== null;
    const wrongHome = locked && s.state !== null && typeof body.workspace === "string" && body.workspace !== s.state.workspace && !took;
    if (locked && s.state && ((typeof body.workspace === "string" && body.workspace !== s.state.workspace && !took) || (typeof body.origin === "string" && body.origin !== s.state.origin))) {
      log.warn("lock", "the control plane moves this station; the workspace lock keeps it where it is", { workspace: body.workspace, origin: body.origin });
    }
    const wasRigByWs = new Map<string, RigSelf>();
    if (was !== null) {
      if (was.workspace && was.rig !== undefined) wasRigByWs.set(was.workspace, was.rig);
      for (const j of was.joined ?? []) if (j.rig !== undefined) wasRigByWs.set(j.workspace, j.rig);
    }
    s.setPlaneLists(Array.isArray(body.peers) ? body.peers : [], Array.isArray(body.gateway_keys) ? body.gateway_keys.filter((k: unknown): k is string => typeof k === "string") : undefined);
    // Current before it is told, so whoever hears of the new roster reads it as current.
    s.peersCurrent = Array.isArray(body.peers);
    s.reached = s.peersCurrent;
    s.rostersSaid = (s.rostersSaid ?? 0) + 1;
    const clearedRigWorkspaces: string[] = [];
    const skippedRigWs = new Set<string>();
    s.update((st) => {
      for (const k of ["workspace", "workspace_name", "name", "origin", "relay_url"] as const) {
        if (locked && (k === "origin" || (k === "workspace" && !took))) continue;
        if (typeof body[k] === "string") st[k] = body[k];
      }
      if (!wrongHome) {
        if (typeof body.workspace_emoji === "string" && body.workspace_emoji !== "") st.workspace_emoji = body.workspace_emoji;
        else delete st.workspace_emoji;
        if (typeof body.workspace_icon === "string" && body.workspace_icon !== "") st.workspace_icon = body.workspace_icon;
        else delete st.workspace_icon;
      }
      if (Array.isArray(body.relay_urls)) st.relay_urls = body.relay_urls.filter((u: unknown) => typeof u === "string");
      st.mesh_relays = meshRelays;
      if (Array.isArray(body.stillfail_relays)) st.stillfail_relays = body.stillfail_relays.filter((u: unknown): u is string => typeof u === "string");
      else delete st.stillfail_relays;
      // The home workspace's own relays and ways turned off as the plane kept them: what mesh/ways.ts takes first.
      const ways = waysSaidOf(body.ways);
      if (ways !== null) st.ways = ways;
      else delete st.ways;
      // Kept as said; once locked, credentials are checked with the lock's keys instead (cloud/state.ts `grantKeys`).
      if (body.grant_keys && typeof body.grant_keys === "object" && !Array.isArray(body.grant_keys)) st.grant_keys = body.grant_keys;
      if (Array.isArray(body.revocations) && body.revocations.every(isRevocation)) st.revocations = body.revocations;
      // Prune stale pending mode requests first so we know which workspaces are authorised to transition.
      const listedRigOf = (raw: any): string | null => (raw !== null && typeof raw === "object" && typeof raw.owner === "string" ? (raw.owner as string) : null);
      const fresh = (at: number) => nowSecs() - at <= MODE_PENDING_S;
      if (st.rig_pending !== undefined) {
        for (const [ws, entry] of Object.entries(st.rig_pending)) if (!fresh(entry.at)) delete st.rig_pending[ws];
        if (Object.keys(st.rig_pending).length === 0) delete st.rig_pending;
      }
      if (st.rig_due !== undefined) {
        st.rig_due = st.rig_due.filter((ws) => st.rig_pending?.[ws] !== undefined);
        if (st.rig_due.length === 0) delete st.rig_due;
      }
      if (st.full_pending !== undefined) {
        for (const [ws, entry] of Object.entries(st.full_pending)) if (!fresh(entry.at)) delete st.full_pending[ws];
        if (Object.keys(st.full_pending).length === 0) delete st.full_pending;
      }
      const listedByWs = new Map<string, string | null>();
      const rawRigsByWs = new Map<string, ReturnType<typeof rigsOf>>();
      if (!wrongHome && st.workspace) {
        listedByWs.set(st.workspace, listedRigOf(body.rig));
        rawRigsByWs.set(st.workspace, rigsOf(body.rigs));
      }
      if (Array.isArray(body.workspaces)) {
        for (const j of body.workspaces) {
          if (typeof j?.workspace === "string" && j.workspace !== "") {
            listedByWs.set(j.workspace, listedRigOf(j.rig));
            rawRigsByWs.set(j.workspace, rigsOf(j.rigs));
          }
        }
      }
      // Preserve local RigSelf per workspace ID (never changed by control-plane frames alone, nor lost when home/joined swap).
      const homeRig = wasRigByWs.get(st.workspace);
      if (homeRig !== undefined) st.rig = homeRig;
      else delete st.rig;
      // The workspaces it joined besides its home one: never duplicate `st.workspace`, and never admit a rig-listed
      // workspace as a full workspace before local `RigSelf` (or matching `rig_pending`) is recorded on disk.
      const joined: typeof incomingJoined = [];
      for (const j of incomingJoined) {
        if (j.workspace === st.workspace) continue;
        const jRig = wasRigByWs.get(j.workspace);
        const listedRig = listedByWs.get(j.workspace) ?? null;
        if (jRig !== undefined) {
          const { rigs: _, ...rest } = j;
          joined.push({ ...rest, rig: jRig });
        } else if (listedRig !== null) {
          if (st.rig_pending?.[j.workspace]?.owner === listedRig) {
            const { rig: _, ...rest } = j;
            joined.push(rest);
          } else {
            skippedRigWs.add(j.workspace);
          }
        } else {
          const { rig: _, ...rest } = j;
          joined.push(rest);
        }
      }
      for (const prev of st.joined ?? []) if (!joined.some((j) => j.workspace === prev.workspace)) s.leftJoined(prev.workspace);
      if (joined.length > 0) st.joined = joined;
      else delete st.joined;
      // Missing roster means an old cloud: never keep peers from another binding. Who may call the device tools
      // (Comma's gateways): only from a control plane that names them.
      const { peers, gateways } = s.filtered(st);
      st.peers = Array.isArray(body.peers) ? peers : [];
      if (Array.isArray(body.gateway_keys)) st.gateway_keys = gateways;
      // Mode transitions per workspace, run BEFORE assigning `rigs` so a `rig -> full` frame keeps that frame's `rigs`.
      const checkMode = (ws: string, hasRig: boolean, clearRig: () => void) => {
        if (!listedByWs.has(ws)) return;
        const listedRig = listedByWs.get(ws)!;
        if (!hasRig) {
          const pend = st.rig_pending?.[ws];
          if (pend !== undefined && listedRig === pend.owner) {
            st.rig_due = [...(st.rig_due ?? []).filter((w) => w !== ws), ws];
          }
        } else {
          const fullPend = st.full_pending?.[ws];
          if (fullPend !== undefined && listedRig === null) {
            log.warn("presence", "this rig is listed as a whole station, as its person signed: it becomes one", { workspace: ws });
            clearRig();
            delete st.full_pending![ws];
            if (Object.keys(st.full_pending!).length === 0) delete st.full_pending;
            clearedRigWorkspaces.push(ws);
          }
        }
      };
      if (st.workspace) checkMode(st.workspace, st.rig !== undefined, () => { delete st.rig; });
      for (const j of st.joined ?? []) checkMode(j.workspace, j.rig !== undefined, () => { delete j.rig; });
      // Assign `rigs` per workspace after mode transitions so `rig -> full` retains this frame's `rigs`.
      const homeRigs = rawRigsByWs.get(st.workspace) ?? rigsOf(body.rigs);
      if (homeRigs.length > 0 && st.rig === undefined) st.rigs = homeRigs;
      else delete st.rigs;
      for (const j of st.joined ?? []) {
        const jr = rawRigsByWs.get(j.workspace) ?? [];
        if (jr.length > 0 && j.rig === undefined) j.rigs = jr;
        else delete j.rigs;
      }
    });
    if (skippedRigWs.size > 0) skippedRigState.set(s, { skipped: skippedRigWs, frame: body });
    else skippedRigState.delete(s);
    // When no rig workspaces remain at all, remove grants.json; otherwise Rig's cloud listener clears each workspace's grants individually.
    if (clearedRigWorkspaces.length > 0 && s.rigMemberships().length === 0) {
      void rm(rigGrantsPath(s.data), { force: true }).catch((error) => log.warn("presence", "the grants of this station as a rig were not removed", { error: (error as Error).message }));
    }
    syncLock(s, body.lock, send);
    // Each joined workspace's lock too, level with the plane's.
    if (Array.isArray(body.workspaces)) {
      for (const j of body.workspaces) if (typeof j?.workspace === "string" && s.state?.joined?.some((x) => x.workspace === j.workspace)) syncLock(s, j.lock, send, j.workspace);
    }
  } else if (body?.type === "revoke" && isRevocation(body)) {
    // Of the workspace it names (planes of before say none: the home one's).
    const named: unknown = (body as any).workspace;
    s.update((st) => {
      const elsewhere = typeof named === "string" && named !== st.workspace;
      const joined = elsewhere ? st.joined?.find((j) => j.workspace === named) : undefined;
      if (elsewhere && joined === undefined) return;
      const of = joined ?? st;
      of.revocations = of.revocations.filter((r) => !(r.kind === body.kind && r.id === body.id));
      of.revocations.push({ kind: body.kind, id: body.id, at: body.at });
    });
  } else if (body?.type === "lock" && Array.isArray(body.entries)) {
    takeFromPlane(s, body.entries, typeof body.workspace === "string" && body.workspace !== s.state?.workspace ? body.workspace : null, send);
  }
}

/// The joined workspaces whose lock, named by joining, is to be asked for now: not pinned yet, the plane having one
/// there, not asked for on this connection (`asked`, kept by it). The plane tells the station it joined (a `state`
/// frame) before it answers the join, so that frame came before joining wrote which lock to pin and asked for nothing:
/// the station took none of that workspace's members until a later frame, which may not come for days (2026-10-23).
///
/// The home workspace's (null) too, where a lock to pin was named there since the plane's last frame (a rig its
/// person took in naming the workspace's lock, rig/module.ts `#added`, FB-45): asked for at once, not at the next
/// frame, which may not come for days.
export function pendingAsks(s: CloudState, asked: Set<string>): (string | null)[] {
  const out: (string | null)[] = [];
  const home = s.chain(null) === null && (s.planeLockSeq ?? -1) >= 0 ? pendingLock(s.data) : null;
  if (home !== null && !asked.has(`/${home}`)) {
    asked.add(`/${home}`);
    out.push(null);
  }
  for (const j of s.state?.joined ?? []) {
    if (s.leftOut(j.workspace) !== "pending" || (s.planeLockSeqs.get(j.workspace) ?? -1) < 0) continue;
    const key = `${j.workspace}/${s.pendingLock(j.workspace)}`;
    if (asked.has(key)) continue;
    asked.add(key);
    out.push(j.workspace);
  }
  return out;
}

/// The control plane's lock head against this station's, in `ws` (the home workspace when null): asks for what it
/// lacks, gives what the plane lacks (the plane only keeps and carries the lock: a station brings it back what it
/// lost). Where none is pinned, it asks only for a lock `enroll --lock` (or joining) named. Its entries are taken only
/// where they go on from the head (cloud/state.ts `keepLock` says why); it is given what follows its head where that is
/// on the chain this station goes by, and where its chain parted from it (it kept an entry that lost, or that no
/// station took) what this station goes by from there, as another keeper's (`planeParted`): a plane of today keeps it
/// by the rules' fork choice and comes to the stations' chain (cloud/src/lock.ts `keepLockAt`), one from before
/// refuses it as before.
function syncLock(s: CloudState, head: any, send: (frame: unknown) => unknown, ws: string | null = null) {
  const theirs = head !== null && typeof head === "object" && Number.isSafeInteger(head.seq) ? (head.seq as number) : -1;
  const which = ws === null ? {} : { workspace: ws };
  // A cloud from before locks says nothing of one: nothing is given to it.
  if (ws === null) s.planeLockSeq = head === undefined ? null : theirs;
  else s.planeLockSeqs.set(ws, head === undefined ? null : theirs);
  const hashes = (s.planeLockHashes ??= new Map());
  if (theirs >= 0 && typeof head?.hash === "string") hashes.set(ws ?? "", head.hash);
  else hashes.delete(ws ?? "");
  const mine = s.chain(ws)?.state?.seq;
  if (mine === undefined) {
    // (a joined workspace that turned its lock on after this station joined it, this station not in it then: its lock,
    // pinned once it names this station, takeFromPlane). What joining named to pin is read only where the plane has a
    // lock to bring: not at every frame of a workspace with none.
    if (theirs >= 0 && ((ws === null ? pendingLock(s.data) : s.pendingLock(ws)) !== null || (ws !== null && s.leftOut(ws) === "unpinned"))) send({ type: "lock.get", after: -1, ...which });
    return;
  }
  // The plane's lock another than the one pinned here: turned off and on again while this station was not there to hear
  // it. Asked for the rest of its own (the plane keeps a chain turned off): its `disable` lets it go.
  const genesis = s.chain(ws)?.state?.genesis;
  if (head !== null && typeof head === "object" && typeof head.genesis === "string" && genesis !== undefined && head.genesis !== genesis) send({ type: "lock.get", after: mine, genesis, ...which });
  else if (!planeOnChain(s, ws, theirs)) planeParted(s, ws, send);
  else if (theirs > mine) send({ type: "lock.get", after: mine, ...which });
  else if (theirs < mine) send({ type: "lock.put", entries: s.lockAfter(theirs, ws), ...which });
}

/// Whether the control plane's head of `ws`'s lock (`seq`, its hash as its frame said) is on the chain this station goes
/// by, or may be: further than it goes (what it lacks is asked for), none, or a plane that says no hash.
function planeOnChain(s: CloudState, ws: string | null, seq: number): boolean {
  const hash = s.planeLockHashes?.get(ws ?? "");
  if (seq < 0 || hash === undefined) return true;
  const at = s.lockAfter(seq - 1, ws)[0];
  if (at !== undefined && at.seq === seq) return hashOf(at) === hash;
  // Further: unless it is an entry kept here off the chain.
  return !s.lockKept(ws).some((e) => hashOf(e) === hash);
}

/// At most this many entries a `lock.put` brings the plane (cloud/src/directory.ts takes no more at once).
const PUT_MOST = 256;

/// The control plane's chain of `ws`'s lock parted from the one gone by here: given, once for each head of the plane's
/// and of this station's (found as the plane says its head, or as this station's chain moves), what this station
/// goes by from where the plane's parts from it (that head's nearest entry on this chain, where this station keeps the
/// head aside; else the last PUT_MOST of its chain), with `keep`, as what another keeper took: a plane of today keeps it
/// by the rules' fork choice, so it moves to this chain where that wins, and the entries after it are taken there again
/// (a plane that kept the entry that lost refused every one after the chain that won, 2026-11-12). A plane from before
/// refuses it and says its head again, which is said here already. Nothing is taken from it that would not be before:
/// what it brings is taken only where it goes on from the head (`takeFromPlane`).
function planeParted(s: CloudState, ws: string | null, send: (frame: unknown) => unknown) {
  const key = ws ?? "";
  const hash = s.planeLockHashes?.get(key) ?? "";
  const which = ws === null ? {} : { workspace: ws };
  const said = (s.planeParted ??= new Map());
  const chain = s.lockAfter(-1, ws);
  const both = `${hash}>${chain.length === 0 ? "" : hashOf(chain.at(-1)!)}`;
  if (said.get(key) === both) return;
  said.set(key, both);
  const on = new Set(chain.map(hashOf));
  const kept = new Map(s.lockKept(ws).map((e) => [hashOf(e), e] as const));
  let at = kept.get(hash);
  while (at !== undefined && !on.has(hashOf(at))) at = at.prev === null ? undefined : kept.get(at.prev);
  const entries = at !== undefined ? chain.filter((e) => e.seq > at!.seq).slice(0, PUT_MOST) : chain.slice(-PUT_MOST);
  log.warn("lock", "the control plane's copy of the lock parted from the chain this station goes by; it is given this station's", { plane: hash.slice(0, 12), seq: s.chain(ws)?.state?.seq, from: entries[0]?.seq, ...which });
  if (entries.length > 0) send({ type: "lock.put", entries, keep: true, ...which });
}

/// Entries the control plane brought, of `ws`'s lock (the home workspace's when null): more of the pinned lock, or the
/// lock `enroll --lock` (or joining) named (pinned only when its chain holds that entry).
function takeFromPlane(s: CloudState, raw: unknown[], ws: string | null = null, send: (frame: unknown) => unknown = () => {}) {
  const entries = raw.map(asEntry);
  if (entries.some((e) => e === null)) return log.warn("lock", "the control plane sent a malformed lock entry");
  try {
    if (s.chain(ws) === null) {
      const pending = ws === null ? pendingLock(s.data) : s.pendingLock(ws);
      // A joined workspace that turned its lock on after this station joined it: it takes none of its members (leftOut
      // `unpinned`) until it pins a lock, which no device of it can bring (it refuses them all). Its lock as the plane
      // has it, once that names this station (its owner put it in, `lock.joinStation`): pinned, as it was the plane's
      // word it took for that workspace before (2026-11-04: a workspace's members turned away for two hours, then the
      // station removed from it and added again).
      if (pending === null && ws !== null && s.leftOut(ws) === "unpinned") {
        let named = false;
        try {
          named = fold(entries as Entry[], null).stations.has(s.state?.station ?? "");
        } catch {
          named = false;
        }
        if (named) s.takeLock(entries as Entry[], ws);
        // (moved, its stations a statement adds are said in its people's logs, which the chain never names: offered,
        // pinned once the state its logs and bodies make names this station, fetched of a station of it, mesh/moved-pin.ts;
        // 2026-11-14, the locks' end to end, round 17: 「保护」 after a move left the station unprotected for good)
        else if ((entries as Entry[]).some((e) => e.kind === "moved")) s.offerMoved(ws, entries as Entry[]);
        return;
      }
      if (pending === null) return;
      if (!entries.some((e) => entryHash(e!) === pending)) return log.warn("lock", "the control plane's lock is not the one this station was enrolled with", ws === null ? {} : { workspace: ws });
      s.takeLock(entries as Entry[], ws);
      // Off the thread: pinned now, what joining named to pin is read no more (only while nothing is pinned: syncLock,
      // takeFromPlane, Cloud.leftOut), so its going a moment later changes nothing.
      if (ws !== null) s.pendingTaken(ws);
      void rm(ws === null ? pendingLockPath(s.data) : joinedPendingPath(s.data, ws), { force: true }).catch(() => {});
    } else {
      try {
        s.takeLock(entries as Entry[], ws);
      } finally {
        // What it brought did not bring its head here: its chain parted below the one gone by here.
        const hash = s.planeLockHashes?.get(ws ?? "");
        if (hash !== undefined && s.chain(ws) !== null && !s.lockKept(ws).some((e) => hashOf(e) === hash)) planeParted(s, ws, send);
      }
    }
  } catch (e) {
    log.warn("lock", "the control plane's lock entries were refused", { error: (e as Error).message });
  }
}

/// The lock hash `enroll --lock` left to pin, if any.
export function pendingLock(data: string): string | null {
  try {
    const hash = JSON.parse(readFileSync(pendingLockPath(data), "utf8"))?.hash;
    return typeof hash === "string" && /^[0-9a-f]{64}$/.test(hash) ? hash : null;
  } catch {
    return null;
  }
}
