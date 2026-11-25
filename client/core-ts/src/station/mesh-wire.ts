// What the still.fail core does with the device's mesh (mesh.ts, which knows none of it; station/wire.rs `MeshWire`):
// each request to a station on the link to its address, a read asked again on the link put in its place and on another
// way when its own is slow, a write gone unanswered asked again with its key; the cloud's credentials as the mesh
// presents them, the device's claim for a workspace's lock said with them (lock.ts); a station's refusals for that
// lock; what an app's main endpoint takes (a trusted device met face to face); a station's protocol and what the
// mesh is made with for it (`STATION_MESH`); the core's own mesh, brought up on first use.
import { LeafLinks } from "./mesh-leaf.ts";
import { Deferred, Effect, Fiber, type Result } from "effect";
import type { Credential } from "../cloud.ts";
import type { Inner } from "../core.ts";
import { hooks } from "../core/execute.ts";
import { CoreError } from "../error.ts";
import { t } from "../i18n.ts";
import type { Iroh } from "../iroh.ts";
import { claimBy } from "../lock.ts";
import { BULK_SLOW_BPS, HOT_RELAYS, IDLE_HOT_RELAYS, type CredentialSource, type Link, Mesh, type MeshEnv, type Presented, type Reply, relayHost, SPEED_MIN_BYTES, SPEED_SLOW_MIN_MS } from "../mesh.ts";
import { PAIR_ALPN } from "../pair.ts";
import * as prefs from "../prefs.ts";
import { RELAY, type Place, type Status } from "../status.ts";
import { route } from "../route.ts";
import { utf8 } from "../util.ts";
import type { StationAddr } from "./addr.ts";
import { BATCH_LINES, BULK, BULK_LANE, IDEMPOTENCY_KEY, IDEMPOTENT, NDJSON, NO_HEDGE, READS } from "./requests.ts";
import type { LinkNet, PeerDiag, RequestHead, ScreenAsk, StationWire, TerminalAsk, WireReply, WireSocket } from "./wire.ts";
import { RECHECKING } from "./words.ts";

/// The header a station's reply to a screen's view says the token its frames go as datagrams under with
/// (station/src/mesh/screens.ts `answerScreen`).
const DGRAM_HEADER = "x-screen-dgram";

// deno-lint-ignore no-explicit-any
type J = any;

/// The protocol a station takes a device's links on (station/src/mesh/serve.ts `ALPN`).
export const ALPN = utf8("stillfail/admin/1");

/// What a mesh to stations is made with, whatever it runs on (`meshEnv`, and a test's own mesh): their protocol; what
/// each line of a link's control stream says after its credential (`protocol`: 2, the hello a station has always been
/// sent); its peers looked up on the LAN and in the DHT (under still.fail's names: client/shell, station/native/mesh);
/// the key what stations said of their addresses is kept under on the device.
export const STATION_MESH = { alpn: ALPN, says: { protocol: 2 }, lookup: true, addressesKey: "station-addresses" } satisfies Partial<MeshEnv>;

/// How often a read gone slow looks again for another way to be asked on, while there is none.
const HEDGE_RECHECK_MS = 250;
/// How many links in a row a read is asked again on when each is found gone under it.
const LOST_TRIES = 3;
/// How long a write gone unanswered is asked again with its key.
export const RECHECK_MS = 5 * 60 * 1000;
/// Elapsed time and average throughput below which a crawling bulk body aborts to switch to a clearly better standby.
export const BULK_CRAWL_MS = 8_000;
export const BULK_CRAWL_BPS = 32 * 1024;
/// Silent period (0 B/s) after which a stalled bulk body checks for a clearly better standby and aborts to switch.
export const BULK_STALL_MS = 4_000;
/// How long a station stays active after a foreground request before it may return to idle relay narrowing / pings.
export const IDLE_GRACE_MS = 60_000;
/// Station-scoped UI topics whose presence keeps that station active (not passive sidebar summaries).
const ACTIVE_STATION_TOPICS = new Set([
  "chat",
  "thread",
  "live",
  "session",
  "drive",
  "stationResources",
  "jobLog",
  "machineLoginScreen",
  "stationRates",
  "hostLive",
  "host",
  "net",
  "way",
  "stationUsage",
  "stationMove",
  "memory",
  "presets",
  "profilePace",
  "stationSearch",
  "filePeek",
  "messagePeek",
]);

export function unconfirmed(why: CoreError): CoreError {
  return new CoreError("unconfirmed", t("station.core.unconfirmed", { why: why.message }));
}

function mayRepeat(head: RequestHead, idempotent: boolean): boolean {
  return head.method.toUpperCase() === "GET" || onlyReads(head) || (idempotent && head.headers.some(([k]) => k.toLowerCase() === IDEMPOTENCY_KEY));
}

/// A request that only reads though it is no GET (requests.ts READS).
function onlyReads(head: RequestHead): boolean {
  return head.headers.some(([k]) => k.toLowerCase() === READS);
}

/// What the wire needs of the core: the mesh (brought up on first use), each workspace's credentials and waits.
export type MeshWireEnv = {
  mesh: () => Effect.Effect<Mesh, CoreError>;
  /// The mesh if it is up already.
  meshNow: () => Mesh | null;
  credentials: (workspace: string) => CredentialSource;
  /// The relays a workspace has of its own, the ways it turned off (`Mesh.link`).
  relays: (workspace: string) => string[];
  off?: (workspace: string) => string[];
  status: (workspace: string) => Status;
  /// The workspace lock (views/lock.ts): a station refused this device for it (`theirs`: how far its own lock goes, as
  /// it said; `told`: the chains of the person's own lock it keeps and the last entries of its lock, as it told them);
  /// why a station is not asked now.
  lockRefused?: (workspace: string, station: string, theirs: unknown, told?: { person?: unknown; entries?: unknown; out?: unknown; left?: unknown }) => CoreError | null;
  lockWaiting?: (workspace: string, station: string) => CoreError | null;
};

/// Each request goes on the link to its station's address (`Mesh.link`): its workspace's.
export class MeshWire implements StationWire {
  readonly #env: MeshWireEnv;
  /// The addresses whose stations said they keep writes to once.
  readonly #idempotent = new Set<string>();
  /// By station address: until when a recent foreground request keeps the station active.
  readonly #activeUntil = new Map<string, number>();
  /// By station address: open interactive duplex sockets (screen, terminal, farview, socket).
  readonly #liveSockets = new Map<string, number>();

  constructor(env: MeshWireEnv) {
    this.#env = env;
  }

  /// Whether `addr` has an open interactive socket or handled a foreground request within `IDLE_GRACE_MS`.
  isActive(addr: string, now: number): boolean {
    return (this.#liveSockets.get(addr) ?? 0) > 0 || (this.#activeUntil.get(addr) ?? -Infinity) > now;
  }

  #noteActive(addr: string, mesh: Mesh): void {
    this.#activeUntil.set(addr, mesh.now() + IDLE_GRACE_MS);
    mesh.refreshIdle?.(addr);
  }

  #holdSocket(addr: string, mesh: Mesh): Effect.Effect<void, never, import("effect").Scope.Scope> {
    return Effect.suspend(() => {
      this.#liveSockets.set(addr, (this.#liveSockets.get(addr) ?? 0) + 1);
      mesh.refreshIdle?.(addr);
      return Effect.addFinalizer(() =>
        Effect.sync(() => {
          const left = (this.#liveSockets.get(addr) ?? 0) - 1;
          if (left > 0) this.#liveSockets.set(addr, left);
          else this.#liveSockets.delete(addr);
        }),
      );
    });
  }

  request(station: StationAddr, head: RequestHead, body: Uint8Array, wrote?: (sent: number) => void): Effect.Effect<WireReply, CoreError, import("effect").Scope.Scope> {
    const env = this.#env;
    const self = this;
    const idempotent = this.#idempotent;
    const workspace = station.workspace;
    const id = station.station;
    const key = station.toString();
    const address = { station: key };
    // A station that refused this device for the workspace lock is not asked again until the lock moves on.
    const waits = env.lockWaiting?.(workspace, id);
    if (waits) return Effect.fail(waits);
    // Refused for it: noted (this device asks to be confirmed), and said as the lock has it (which workspace, where).
    const refusedFor = (e: CoreError) => (e.code === "lock_unconfirmed" ? (env.lockRefused?.(workspace, id, e instanceof LockUnconfirmed ? e.lock : null, e instanceof LockUnconfirmed ? { person: e.person, entries: e.entries, out: e.out, left: e.left } : undefined) ?? e) : e);
    return Effect.mapError(Effect.gen(function* () {
      const status = env.status(workspace);
      const credentials = env.credentials(workspace);
      const theirs = env.relays(workspace);
      const off = env.off?.(workspace);
      const asker = `${head.method.toUpperCase()} ${route(head.path)}`;
      const mesh = yield* waiting(status, RELAY, t("station.core.connecting"), env.mesh());
      // Kept current in the background (requests.ts NO_HEDGE) or routed as a bulk transfer (BULK, BULK_LANE):
      // wire-only marks, stripped before sending to any station.
      const bulk = head.headers.some(([k]) => k.toLowerCase() === BULK);
      const laneHeader = head.headers.find(([k]) => k.toLowerCase() === BULK_LANE)?.[1];
      const laneParsed = laneHeader !== undefined ? Number(laneHeader) : Number.NaN;
      const lane = Number.isInteger(laneParsed) && laneParsed >= 0 ? laneParsed : null;
      const noHedge = head.headers.some(([k]) => k.toLowerCase() === NO_HEDGE);
      const write = !["GET", "HEAD"].includes(head.method.toUpperCase()) && !onlyReads(head);
      if (!noHedge || write) self.#noteActive(key, mesh);
      const sent: RequestHead = noHedge || bulk || laneHeader !== undefined
        ? { ...head, headers: head.headers.filter(([k]) => { const low = k.toLowerCase(); return low !== NO_HEDGE && low !== BULK && low !== BULK_LANE; }) }
        : head;
      const pickLink = (attempt = 0) =>
        bulk && lane !== null && typeof mesh.bulkLinkAt === "function"
          ? mesh.bulkLinkAt(key, lane + attempt, credentials, theirs, off, asker)
          : bulk && typeof mesh.bulkLink === "function"
            ? mesh.bulkLink(key, credentials, theirs, off, asker)
            : mesh.link(key, credentials, theirs, off, asker);
      const link = yield* waiting(status, address, t("station.core.connecting"), pickLink());
      const repeats = mayRepeat(head, idempotent.has(key));
      // Asked on more than one way (or again), the body is told of as far as the furthest has gone.
      let furthest = 0;
      const told = wrote && ((n: number) => { if (n > furthest) wrote((furthest = n)); });
      // A body of SPEED_MIN_BYTES or more times the way it goes on as it goes (`Mesh.timed` times only what comes back,
      // and a part uploaded is answered in a few bytes): a way found slow while a part is still on it is told at once
      // (`Mesh.noteSpeed`, once each time it is asked), so the next part goes on a faster way rather than minutes on it.
      const timesBody = body.length >= SPEED_MIN_BYTES && typeof mesh.noteSpeed === "function";
      const ask = (l: Link) => {
        const askedAt = mesh.now();
        const wayKey = timesBody ? (typeof l.speedKey === "function" ? l.speedKey() : l.path() === "relay" ? l.via() : null) : null;
        let early = false;
        const onSent = wayKey === null
          ? told
          : (n: number) => {
            told?.(n);
            if (early || n < SPEED_MIN_BYTES) return;
            const elapsed = mesh.now() - askedAt;
            if (elapsed >= 1_000 && (n / elapsed) * 1000 < BULK_SLOW_BPS) {
              early = true;
              mesh.noteSpeed(key, wayKey, n, elapsed);
            }
          };
        return Effect.map(l.request(sent, body, onSent), (reply) => [l, reply, askedAt] as [Link, Reply, number]);
      };
      let answered: [Link, Reply, number];
      if (repeats) {
        // Asked on its link; on another way as well if not answered within what its way is expected to take
        // (`hedgeAfter`), or on the link put in its place if its link is replaced meanwhile: the first answer taken.
        const started = mesh.now();
        let gotHead = false;
        let penalized = false;
        const asked = yield* Effect.forkChild(
          Effect.result(
            ask(link).pipe(
              Effect.tap(() => Effect.sync(() => { gotHead = true; })),
              Effect.onInterrupt(() =>
                Effect.sync(() => {
                  if (!gotHead && !penalized) {
                    const elapsed = mesh.now() - started;
                    if (elapsed >= SPEED_SLOW_MIN_MS) {
                      penalized = true;
                      mesh.outran(key, link, elapsed);
                    }
                  }
                }),
              ),
            ),
          ),
        );
        // An answer come too late to be taken: its stream let go (the station stops sending what no one reads).
        const late = ([, reply]: [Link, Reply, number]) => reply.cancel();
        // The other way, as there is one by then (the ways dialled with the link may come through after it).
        const slow = Effect.gen(function* () {
          yield* Effect.sleep(mesh.hedgeAfter(key, link));
          for (;;) {
            const standby = bulk ? (typeof mesh.bulkStandby === "function" ? mesh.bulkStandby(key, link) : null) : mesh.standby(key, link);
            if (standby !== null) return { slow: standby } as const;
            yield* Effect.sleep(HEDGE_RECHECK_MS);
          }
        });
        const first = yield* Effect.raceAllFirst([
          Effect.map(Fiber.join(asked), (r) => ({ asked: r }) as const),
          ...(bulk ? [] : [Effect.as(mesh.replaced(key, link), { replaced: true } as const)]),
          ...(noHedge ? [] : [slow]),
        ]);
        if ("asked" in first) {
          const r = first.asked;
          if (r._tag === "Success") answered = r.success;
          else if (r.failure.code === "mesh" && write) {
            // A write gone and not answered: asked again with its key whenever its station is back, a while.
            const w = status.begin(address, RECHECKING(), true);
            let pause = 1_000;
            answered = yield* Effect.gen(function* () {
              for (let tries = 1; ; tries++) {
                const again = yield* Effect.result(Effect.flatMap(pickLink(tries), ask));
                if (again._tag === "Success") return again.success;
                if (again.failure.code !== "mesh") return yield* Effect.fail(again.failure);
                if (mesh.now() - started >= RECHECK_MS) return yield* Effect.fail(unconfirmed(again.failure));
                yield* Effect.sleep(pause);
                pause = Math.min(pause * 2, 15_000);
              }
            }).pipe(Effect.ensuring(Effect.sync(() => w.end())));
          } else if (r.failure.code === "mesh") {
            // Its link went: asked again on the one in its place, and again while each it is asked on is found gone too
            // (a station restarting drops all its connections at once; a way not told so yet is taken next, side run
            // seed 143365259, 2026-10-17), a few times.
            answered = yield* Effect.gen(function* () {
              for (let tries = 1; ; tries++) {
                const l = yield* waiting(status, address, t("station.core.connecting"), pickLink(tries));
                const again = yield* Effect.result(ask(l));
                if (again._tag === "Success") return again.success;
                if (again.failure.code !== "mesh" || l.closed() === null || tries >= LOST_TRIES) return yield* Effect.fail(again.failure);
              }
            });
          } else return yield* Effect.fail(r.failure);
        } else if ("replaced" in first) {
          // Replaced while under way: asked again on the new one at once, the first answer taken.
          const again = Effect.flatMap(pickLink(), ask);
          answered = yield* firstAnswer(asked, again, late);
        } else {
          // Slow on its way: asked on the next best as well. Answered there first, its way is told how long it kept it.
          answered = yield* firstAnswer(asked, ask(first.slow), late);
          if (answered[0] !== link && !penalized) {
            penalized = true;
            mesh.outran(key, link, mesh.now() - started);
          }
        }
      } else {
        const r = yield* Effect.result(ask(link));
        if (r._tag === "Failure") return yield* Effect.fail(write && r.failure.code === "mesh" ? unconfirmed(r.failure) : r.failure);
        answered = r.success;
      }
      const [l, reply, askedAt] = answered;
      // Its stream goes with the scope it was asked in.
      yield* Effect.addFinalizer(() => Effect.sync(() => reply.cancel()));
      if (reply.headers.some(([k]) => k.toLowerCase() === IDEMPOTENT)) idempotent.add(key);
      const relay = l.path() === "relay" ? l.via() : null;
      const speedVia = typeof l.speedKey === "function" ? l.speedKey() : relay;
      // How fast it comes tells how fast that way is; not an event stream's, which comes as things happen, nor a batch
      // streamed line-by-line, which comes as the station reads each of it. Use the actual response type for batches so
      // an old station falling back to whole JSON still times normally, while keeping Accept: text/event-stream's rule.
      const replyType = (reply.headers.find(([k]) => k.toLowerCase() === "content-type")?.[1] ?? "").split(";", 1)[0]!.trim().toLowerCase();
      const streams =
        head.headers.some(([k, v]) => k.toLowerCase() === "accept" && v.includes("text/event-stream")) ||
        replyType === BATCH_LINES ||
        replyType === NDJSON;
      // The whole body gone and answered: how fast its way took it.
      if (timesBody && speedVia !== null) mesh.noteSpeed(key, speedVia, body.length, Math.max(1, mesh.now() - askedAt));
      const timed = speedVia !== null && !streams ? mesh.timed(key, speedVia, reply.body, bulk) : reply.body;
      let bodyPull = timed;
      if (bulk && repeats && !noHedge && !streams) {
        const crawlStarted = mesh.now();
        let crawlBytes = 0;
        let lastCrawlNote = -Infinity;
        const abortCrawl = (elapsed: number, stalledNow = false): CoreError | null => {
          const now = mesh.now();
          if (now - lastCrawlNote >= BULK_STALL_MS && speedVia !== null && typeof mesh.noteSpeed === "function") {
            const curSpeed = typeof mesh.speed === "function" ? mesh.speed(key, speedVia) : null;
            if (curSpeed === null || curSpeed >= BULK_CRAWL_BPS) {
              const sampleBytes = stalledNow ? 1 : Math.max(crawlBytes, 1);
              const sampleMs = Math.max(elapsed, SPEED_SLOW_MIN_MS);
              mesh.noteSpeed(key, speedVia, sampleBytes, sampleMs, true);
              lastCrawlNote = now;
            }
          }
          if (typeof mesh.betterBulkStandby === "function" && mesh.betterBulkStandby(key, l) !== null) {
            reply.cancel();
            const err = new CoreError("mesh", t("core-logic.mesh.cut"));
            err.cause = "bulk_crawl";
            return err;
          }
          return null;
        };
        bodyPull = {
          take: Effect.gen(function* () {
            const stalled = Effect.gen(function* () {
              for (;;) {
                yield* Effect.sleep(BULK_STALL_MS);
                const err = abortCrawl(mesh.now() - crawlStarted, true);
                if (err !== null) return { stalled: err } as const;
              }
            });
            const winner = yield* Effect.raceFirst(
              Effect.map(Effect.result(timed.take), (read) => ({ read }) as const),
              stalled,
            );
            if ("stalled" in winner) return yield* Effect.fail(winner.stalled);
            if (winner.read._tag === "Failure") return yield* Effect.fail(winner.read.failure);
            const chunk = winner.read.success;
            if (chunk === null) return null;
            crawlBytes += chunk.length;
            const elapsed = mesh.now() - crawlStarted;
            if (elapsed >= BULK_CRAWL_MS && (crawlBytes / elapsed) * 1000 < BULK_CRAWL_BPS) {
              const err = abortCrawl(elapsed);
              if (err !== null) return yield* Effect.fail(err);
            }
            return chunk;
          }),
        };
      }
      // Why the station ended the connection it came on, as its close said (shell, iroh-wasm and node-iroh give it).
      const ended = () => {
        const r = l.conn.closeReason();
        return r !== null && r.kind === "application" ? r.reason : null;
      };
      // A stream gone silent takes the way it came on for gone, not every way to the station (`Mesh.dropWay`).
      const drop = () => mesh.dropWay(key, l);
      return { status: reply.status, headers: reply.headers, body: bodyPull, via: l.path(), relay: relay !== null ? relayHost(relay) : null, ended, drop };
    }), refusedFor);
  }

  reset(station: StationAddr): void {
    this.#env.meshNow()?.dropWay(station.toString());
  }

  races(): boolean {
    return true;
  }

  replaced(station: StationAddr): Effect.Effect<void> {
    const mesh = this.#env.meshNow();
    const link = mesh?.current(station.toString()) ?? null;
    if (mesh === null || link === null) return Effect.never;
    return mesh.replaced(station.toString(), link);
  }

  standing(station: StationAddr): boolean {
    return this.#env.meshNow()?.standing(station.toString()) ?? false;
  }

  healthChange(station: StationAddr, was: boolean): Effect.Effect<boolean> {
    const mesh = this.#env.meshNow();
    return mesh === null ? Effect.never : mesh.healthChange(station.toString(), was);
  }

  net(station: StationAddr): LinkNet | null {
    return this.#env.meshNow()?.net(station.toString()) ?? null;
  }

  way(station: StationAddr): { path: string | null; relay: string | null } | null {
    return this.#env.meshNow()?.way(station.toString()) ?? null;
  }

  bulkLanes(station: StationAddr): number {
    const mesh = this.#env.meshNow();
    if (mesh === null || typeof mesh.fastBulkLinks !== "function") return 1;
    return Math.max(1, mesh.fastBulkLinks(station.toString()).length);
  }

  diag(station: StationAddr): PeerDiag | null {
    return this.#env.meshNow()?.diag(station.toString()) ?? null;
  }

  measure(station: StationAddr): Effect.Effect<void, CoreError> {
    return Effect.flatMap(this.#env.mesh(), (mesh) => mesh.remeasure(station.toString()));
  }

  socket(station: StationAddr, head: RequestHead): Effect.Effect<WireSocket, CoreError, import("effect").Scope.Scope> {
    const env = this.#env;
    const self = this;
    const key = station.toString();
    return Effect.gen(function* () {
      const status = env.status(station.workspace);
      const mesh = yield* waiting(status, RELAY, t("station.core.connecting"), env.mesh());
      yield* self.#holdSocket(key, mesh);
      const link = yield* waiting(status, { station: key }, t("station.core.connecting"), mesh.link(key, env.credentials(station.workspace), env.relays(station.workspace), env.off?.(station.workspace), `${head.method.toUpperCase()} ${route(head.path)}`));
      const [reply, send] = yield* link.socket(head);
      yield* Effect.addFinalizer(() => Effect.sync(() => reply.cancel()));
      return { reply: { status: reply.status, headers: reply.headers, body: reply.body, via: link.path() }, send };
    });
  }

  screen(station: StationAddr, head: RequestHead, screen: ScreenAsk): Effect.Effect<WireSocket, CoreError, import("effect").Scope.Scope> {
    const env = this.#env;
    const self = this;
    const workspace = station.workspace;
    const key = station.toString();
    const address = { station: key };
    return Effect.gen(function* () {
      const status = env.status(workspace);
      const credentials = env.credentials(workspace);
      const theirs = env.relays(workspace);
      const off = env.off?.(workspace);
      const mesh = yield* waiting(status, RELAY, t("station.core.connecting"), env.mesh());
      yield* self.#holdSocket(key, mesh);
      const link = yield* waiting(status, address, t("station.core.connecting"), mesh.link(key, credentials, theirs, off, "screen"));
      // (its own main id: the link it goes over may be one made for a LAN or a relay, under another; its sound as Opus
      // where what taps the view decodes it, a twentieth of PCM's bytes; its picture and sound as datagrams where the
      // host takes them, under a token of its own the stream takes them by before it asks: client/shell screen_dgram.rs)
      const ask = (l: Link) => {
        const token = screen.peek ? 0 : mesh.mediaToken();
        const more = (taking: boolean) => ({ screen: { ...screen, ...(screen.audio && mesh.decodesOpus() ? { opus: true } : {}), ...(taking ? { datagrams: token } : {}), self: mesh.deviceId() } });
        return Effect.map(l.duplex(head, more, token), ([reply, send]) => {
          // (a station from before sends them on the stream: the stream's own frames, as before)
          const datagrams = reply.datagrams === true && reply.headers.some(([k, v]) => k.toLowerCase() === DGRAM_HEADER && v === String(token));
          return [l, { ...reply, datagrams }, send] as [Link, Reply, import("./wire.ts").SocketOut];
        });
      };
      const late = ([, reply]: [Link, Reply, import("./wire.ts").SocketOut]) => reply.cancel();
      const asked = yield* Effect.forkChild(Effect.result(ask(link)));
      const first = yield* Effect.raceFirst(
        Effect.map(Fiber.join(asked), (r) => ({ asked: r }) as const),
        Effect.as(mesh.replaced(key, link), { replaced: true } as const),
      );
      let answered: [Link, Reply, import("./wire.ts").SocketOut];
      if ("asked" in first) {
        const r = first.asked;
        if (r._tag === "Success") answered = r.success;
        else if (r.failure.code === "mesh") {
          answered = yield* Effect.gen(function* () {
            for (let tries = 1; ; tries++) {
              const l = yield* waiting(status, address, t("station.core.connecting"), mesh.link(key, credentials, theirs, off, "screen"));
              const again = yield* Effect.result(ask(l));
              if (again._tag === "Success") return again.success;
              if (again.failure.code !== "mesh" || l.closed() === null || tries >= LOST_TRIES) return yield* Effect.fail(again.failure);
            }
          });
        } else return yield* Effect.fail(r.failure);
      } else {
        // Replaced while opening (the old link stalled): ask on the new link at once rather than waiting out SOCKET_OPEN_MS.
        const again = Effect.flatMap(mesh.link(key, credentials, theirs, off, "screen"), ask);
        answered = yield* firstAnswer(asked, again, late);
      }
      const [l, reply, send] = answered;
      yield* Effect.addFinalizer(() => Effect.sync(() => reply.cancel()));
      return { reply: { status: reply.status, headers: reply.headers, body: reply.body, via: l.path() }, send, tap: reply.tap, replaced: () => mesh.replaced(key, l), ...(reply.datagrams ? { datagrams: true } : {}) };
    });
  }
  terminal(station: StationAddr, head: RequestHead, terminal: TerminalAsk): Effect.Effect<WireSocket, CoreError, import("effect").Scope.Scope> {
    const env = this.#env;
    const self = this;
    const key = station.toString();
    return Effect.gen(function* () {
      const status = env.status(station.workspace);
      const mesh = yield* waiting(status, RELAY, t("station.core.connecting"), env.mesh());
      yield* self.#holdSocket(key, mesh);
      const link = yield* waiting(status, { station: key }, t("station.core.connecting"), mesh.link(key, env.credentials(station.workspace), env.relays(station.workspace), env.off?.(station.workspace), "terminal"));
      const [reply, send] = yield* link.duplex(head, { terminal });
      yield* Effect.addFinalizer(() => Effect.sync(() => reply.cancel()));
      return { reply: { status: reply.status, headers: reply.headers, body: reply.body, via: link.path() }, send };
    });
  }
  farview(station: StationAddr, head: RequestHead, screen: string): Effect.Effect<WireSocket, CoreError, import("effect").Scope.Scope> {
    const env = this.#env;
    const self = this;
    const key = station.toString();
    return Effect.gen(function* () {
      const status = env.status(station.workspace);
      const mesh = yield* waiting(status, RELAY, t("station.core.connecting"), env.mesh());
      yield* self.#holdSocket(key, mesh);
      const link = yield* waiting(status, { station: key }, t("station.core.connecting"), mesh.link(key, env.credentials(station.workspace), env.relays(station.workspace), env.off?.(station.workspace), "farview"));
      const [reply, send] = yield* link.duplex(head, { farview: { screen } });
      yield* Effect.addFinalizer(() => Effect.sync(() => reply.cancel()));
      return { reply: { status: reply.status, headers: reply.headers, body: reply.body, via: link.path() }, send };
    });
  }
}

/// Whichever answers of an attempt under way (`asked`) and another (`b`); one that fails leaves it to the other. Once
/// one is taken the other is stopped, and an answer it had meanwhile goes to `release`: no one reads it.
function firstAnswer<A>(asked: Fiber.Fiber<Result.Result<A, CoreError>>, b: Effect.Effect<A, CoreError>, release: (answer: A) => void): Effect.Effect<A, CoreError> {
  return Effect.gen(function* () {
    const fb = yield* Effect.forkChild(Effect.result(b));
    const [other, r] = yield* Effect.raceFirst(Effect.map(Fiber.join(asked), (r) => [fb, r] as const), Effect.map(Fiber.join(fb), (r) => [asked, r] as const));
    if (r._tag === "Success") {
      yield* Fiber.interrupt(other);
      const late = yield* Effect.exit(Fiber.join(other));
      if (late._tag === "Success" && late.value._tag === "Success") release(late.value.success);
      return r.success;
    }
    const left = yield* Fiber.join(other);
    if (left._tag === "Success") return left.success;
    return yield* Effect.fail(left.failure);
  });
}

/// An effect said to be waited on (status.ts) while it runs.
function waiting<A>(status: Status, place: Place, what: string, effect: Effect.Effect<A, CoreError>): Effect.Effect<A, CoreError> {
  return Effect.suspend(() => {
    const w = status.begin(place, what, true);
    return effect.pipe(Effect.ensuring(Effect.sync(() => w.end())));
  });
}

/// Why a station takes none of the workspace's members for a security mode (its hello's `lock_station` `why`): the lock
/// it joined with not brought yet, this workspace locked after it joined, or its own workspace locked and this one not.
function lockStationWords(why: unknown, reason: string): string {
  if (why === "pending" || why === "unpinned" || why === "home") return t(`core-logic.mesh.lock_station.${why}`);
  return t("core-logic.mesh.credential_refused_why", { reason });
}

/// A station's refusal of this device for its workspace lock, with how far its own lock goes (`lock`, as it said) and
/// the chains of the person's own lock it keeps (`person`: a device not on it yet finds who may let it in), and the last
/// entries of its lock (`entries`: one taken out of it hears so).
export class LockUnconfirmed extends CoreError {
  readonly lock: unknown;
  readonly person: unknown;
  readonly entries: unknown;
  /// Where the workspace's chain moved: what took this device out (the removal, its `prev` chain, the log entries that
  /// commit to them; station/src/mesh/serve.ts `toldOut`), taken by the rules as any bodies and logs are.
  readonly out: unknown;
  /// Where the workspace's chain moved and the state in force there does not name this device: whom to ask
  /// (station/src/mesh/serve.ts `leftOf`), a hint.
  readonly left: unknown;
  constructor(message: string, lock: unknown, person?: unknown, entries?: unknown, out?: unknown, left?: unknown) {
    super("lock_unconfirmed", message);
    this.lock = lock;
    this.person = person;
    this.entries = entries;
    this.out = out;
    this.left = left;
  }
}

/// A station's refusal of a link's first line for a workspace's lock, as the mesh asks what a refusal is
/// (`MeshEnv.refusal`): by its answer's `code`; null for any other (the credential's, which the mesh says).
export function refusedForLock(answer: J, reason: string): CoreError | null {
  // A station with a workspace lock that does not know this device yet: it waits to be confirmed (lock.ts).
  if (answer.code === "lock_unconfirmed") return new LockUnconfirmed(t("core-logic.mesh.lock_unconfirmed", { reason }), answer.lock ?? null, answer.person, answer.entries, answer.out, answer.left);
  // A station that takes none of this workspace's members for a security mode, its own or this workspace's not
  // brought to it yet (station/src/cloud/state.ts `leftOut`): why, as it said.
  if (answer.code === "lock_station") return new CoreError("lock_station", lockStationWords(answer.why, reason));
  return null;
}

/// The cloud's credential as the mesh presents it (`Presented`): its `lock`, the device's claim, said with it in the
/// link's first line.
export function presented(c: Credential): Presented {
  return { credential: c.credential, also: c.lock ? { lock: c.lock } : null };
}

/// Each workspace's credentials for the mesh: still.fail cloud's (kept on the device), asked with this device's claim
/// for the endpoint (lock.ts `claimBy`, signed by the mesh that is up: `mesh`).
export function credentialsFor(inner: Inner, mesh: () => Mesh | null): (workspace: string) => CredentialSource {
  return (workspace) => (device, fresh) => {
    const up = mesh();
    return Effect.map(inner.cloudSync.credential(workspace, device, fresh, up?.deviceId() ?? null, up ? claimBy(up, workspace, device) : null), presented);
  };
}

/// What an app's main endpoint takes (a trusted device met face to face: views/pair.ts `hooks.lockPair`); a page's
/// nothing (it approves no one).
function takes(inner: Inner): Pick<MeshEnv, "takes" | "incoming"> {
  if (!inner.host.appKeys) return {};
  return { takes: [PAIR_ALPN], incoming: (connection, alpn) => (alpn.length === PAIR_ALPN.length && alpn.every((b, i) => b === PAIR_ALPN[i]) ? hooks.lockPair?.(inner, connection) : connection.close(0, "no such protocol")) };
}

/// Whether `addr` has no visible UI focus, no active station-scoped topic subscription, and no recent foreground wire traffic.
function isStationIdle(inner: Inner, addr: string, wireActive?: (addr: string) => boolean): boolean {
  if (wireActive?.(addr)) return false;
  if (inner.attention?.attend.focusedStations().has(addr)) return false;
  if (typeof inner.store?.liveTopics === "function") {
    for (const t of inner.store.liveTopics()) {
      if (t.station === addr && ACTIVE_STATION_TOPICS.has(t.topic) && inner.store.inUse(t)) return false;
    }
  }
  return true;
}

/// What the core gives its mesh (`Mesh.make`): the host and what runs it, a station's protocol (`STATION_MESH`), what
/// an app's endpoint takes, and what a station refuses a link for besides its credential (a workspace's lock: without
/// it a device waiting to be confirmed is told its credential was refused, and asks the cloud for another at each try).
export function meshEnv(inner: Inner, iroh: Iroh, wireActive?: (addr: string) => boolean): MeshEnv {
  const leaves=new LeafLinks();
  return {
    prepare: leaves.prepare,
    linked: leaves.linked,
    host: inner.host,
    runner: inner.runner,
    tracer: inner.tracer,
    iroh,
    wakes: inner.wakes,
    ...STATION_MESH,
    dht: () => prefs.dhtOn(inner.data),
    ...takes(inner),
    ...(inner.host.appKeys ? { idleHotRelays: IDLE_HOT_RELAYS, idle: (addr) => isStationIdle(inner, addr, wireActive) } : { hotRelays: HOT_RELAYS }),
    refusal: refusedForLock,
  };
}

/// The core's mesh: brought up on first use with the relays any account's `/v1/me` names, the credentials from
/// still.fail cloud (kept on the device).
export function meshWire(inner: Inner): StationWire {
  let mesh: Deferred.Deferred<Mesh, CoreError> | null = null;
  let up: Mesh | null = null;
  let wire!: MeshWire;
  const get = (): Effect.Effect<Mesh, CoreError> =>
    Effect.suspend(() => {
      const iroh = inner.iroh;
      if (iroh === null) return Effect.fail(CoreError.plainly("mesh", "no iroh on this host", t("core-logic.mesh.bind_failed")));
      if (mesh !== null) return Deferred.await(mesh);
      const d = Deferred.makeUnsafe<Mesh, CoreError>();
      mesh = d;
      inner.runner.fork(
        Effect.gen(function* () {
          const made = yield* Effect.result(
            Effect.flatMap(inner.cloudSync.relaysNow(), (relays) => Mesh.make(meshEnv(inner, iroh, (addr) => wire.isActive(addr, inner.host.nowMs())), relays, inner.cloudSync.entriesNow(), inner.cloudSync.entryTargetsNow())),
          );
          if (made._tag === "Success") {
            up = made.success;
            // This run's `/v1/me` may have come while it came up on the relays kept from the last.
            const told = inner.cloudSync.relays;
            if (told !== null) up.retune(told, inner.cloudSync.entriesNow(), inner.cloudSync.entryTargetsNow());
          } else mesh = null;
          Deferred.doneUnsafe(d, made._tag === "Success" ? Effect.succeed(made.success) : Effect.fail(made.failure));
        }),
      );
      return Deferred.await(d);
    });
  inner.mesh = get;
  inner.meshNow = () => up;
  inner.cloudSync.onRelays = (relays, entries, targets) => up?.retune(relays, entries, targets);
  wire = new MeshWire({
    mesh: get,
    meshNow: () => up,
    credentials: credentialsFor(inner, () => up),
    relays: (workspace) => inner.cloudSync.workspaceRelays(workspace),
    off: (workspace) => inner.cloudSync.workspaceOff(workspace),
    status: (workspace) => inner.workspaces.of(workspace).status,
    lockRefused: (workspace, station, theirs, told) => hooks.lockRefused?.(inner, workspace, station, theirs, told) ?? null,
    lockWaiting: (workspace, station) => hooks.lockWaiting?.(inner, workspace, station) ?? null,
  });
  return wire;
}
