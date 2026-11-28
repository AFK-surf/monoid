// This device's iroh endpoint and its links to stations, over the iroh a host gives (iroh.ts). One endpoint
// per core, its key the device key (storage `device`). A link is to a station's address, `<workspace>/<station>`: a
// station in several workspaces has a link in each, dialled to the same station id. A link is
// opened with this device's member credential for its address's workspace and presents it again every RENEW_MS on its
// control stream; a closed link is opened again on the next request. Wire format (a station's door: station/src/mesh/door.ts,
// wire.ts): the protocol its user names (`MeshEnv.alpn`); the first bi-stream carries `{"credential": …}` lines, each
// with what its user says in every one (`MeshEnv.says`), each further bi-stream one request: a JSON head line
// `{method, path, headers}` then the body; the reply a JSON head line `{status, headers}` then the body, streamed.
//
// All of it runs as fibers (rule 1): an opening is a Deferred everyone asking for the same address meanwhile waits on, a
// link's renewal and its first answer are fibers in the core's scope, a race and a hedge are fibers started as the UI
// comes back, measuring and the day's tally are fibers on the clock.
//
// Only the mesh is here: the endpoints, the ways to a peer and the choice among them, the links, the streams' framing.
// What the still.fail core does with it is station/mesh-wire.ts (a station's requests on their links, asked again and
// on another way; the cloud's credentials and the lock's claim said with them; a lock's refusals; what an app's
// endpoint takes; a station's protocol and what its hello says, its peers looked up, the name its stations' addresses
// are kept under), given here as `MeshEnv` and a `CredentialSource`. This file imports none of that and says none of
// its names, so that another program is built on it (scripts/base.ts holds it so).
import { ed25519 } from "@noble/curves/ed25519.js";
import { dialLine, formatPrepareTrace, type PrepareTrace, record, recordDht, recording, said, stationTag } from "./record.ts";
import { Cause, Clock, Deferred, Effect, Exit, Fiber, Semaphore } from "effect";
import { CoreError, asCoreError, failedIn } from "./error.ts";
import type { BaseHost, Pull } from "./host-of.ts";
import { t } from "./lang.ts";
import type { CloseReason, Iroh, IrohConnection, IrohEndpoint, IrohPath, IrohStream } from "./iroh.ts";
import { laterSleep, type Runner } from "./runtime.ts";
import { Kind, type SpanContext, type Tracer } from "./trace.ts";
import { fromUtf8, hex, localDay, parseJson, sha256, toJsonBytes, utf8 } from "./util.ts";
import type { Wakes } from "./wake.ts";

// deno-lint-ignore no-explicit-any
type J = any;

export const DEVICE_KEY = "device";
export const RENEW_MS = 5 * 60_000;
export const CONNECT_TIMEOUT_MS = 10_000;
/// How long a dial waits for its endpoint to get onto a relay before its CONNECT_TIMEOUT_MS counts all the same
/// (`onARelay`), and how often it looks: soon at first, as a relay is often reached within a few round trips, then less.
export const ONTO_MAX_MS = 30_000;
const ONTO_FIRST_RECHECK_MS = 10;
const ONTO_RECHECK_MS = 1_500;
export const PROBE_MS = 5_000;
export const RACE_GRACE_MS = 1_000;
/// How long a link is given to answer as the UI comes back from a short while away before a new one is dialled beside
/// it: twice its last round trip, within these.
export const WOKEN_ANSWER_MIN_MS = 300;
export const WOKEN_ANSWER_MAX_MS = 1_000;
export const RETIRE_MS = 10_000;
export const REBIND_MS = 5_000;
/// How often each way to a station is pinged (its credential presented again on it, answered by the station itself).
export const TICK_MS = 5_000;
/// How often a settled idle station's healthy main link is pinged while no UI views it (`MeshEnv.idle`).
export const IDLE_TICK_MS = 30_000;
/// A ping not answered by then counts as having taken this long, and as missed.
export const PING_TIMEOUT_MS = 3_000;
/// The ways kept open to a station: the one its requests go on, and up to two others (best interactive and best bulk).
export const KEEP_WAYS = 3;
/// How often the ways not kept open are dialled again, to see whether one became better.
export const EXPLORE_MS = 5 * 60_000;
/// How long a relay whose pinned endpoint timed out without ever connecting is skipped across stations (< EXPLORE_MS).
export const DEAD_RELAY_MS = 4 * 60_000;
/// Cooldown after a single-relay rescue for a main handshake conflict also fails.
export const HANDSHAKE_RESCUE_COOLDOWN_MS = DEAD_RELAY_MS;
/// Pings a way needs answered before it is compared with another.
export const MIN_SAMPLES = 3;
/// Ticks in a row a way must be clearly better than the one requests go on before they move to it.
const BETTER_TICKS = 6;
/// How long requests stay on a way they moved to before they may move again (unless it is gone): a move restarts the
/// event stream and asks the reads under way again, and moving every few minutes between two ways near each other made
/// things worse than staying (2026-10-08).
export const MIN_STAY_MS = 3 * 60_000;
/// Pings in a row a way may miss before it is let go.
const DEAD_PINGS = 3;
/// Relay paths kept open per settled station on the main endpoint when the host exposes relay controls, and how long a
/// station's main links must stay healthy since opening or last relaxing before narrowing.
export const HOT_RELAYS = 2;
export const IDLE_HOT_RELAYS = 1;
export const HOT_SETTLE_MS = 30_000;
/// How often the main endpoint dials a station again whose link on it is gone, while the station was reached direct
/// within DIRECT_RECALL_MS: only it can go direct (each relay's own endpoint is on that relay alone), and waiting out
/// EXPLORE_MS kept a phone on the station's LAN on a relay for minutes after a link of it went quiet (2026-10-17).
export const REDIAL_MAIN_MS = 30_000;
/// How often a station stuck on pinned relays without recent direct recall retries its main endpoint link.
export const MAIN_RECOVER_MS = 60_000;
export const DIRECT_RECALL_MS = 10 * 60_000;
/// The `pinned` of a link on the endpoint that dials a station by its LAN addresses alone: no relay,
/// no hole punching. A path iroh punched through to a station on the LAN stopped answering seconds after it opened, and
/// requests on it waited out iroh's timeout before going back to a relay; a connection
/// dialled by address kept working.
export const LAN = "lan";
/// The `pinned` of a link on the endpoint that dials a station at its Tailscale addresses alone:
/// as the LAN endpoint, no relay and no hole punching, Tailscale carrying it however it does (straight, or
/// through relays of its own when it could not punch through). So it is not taken over the others as a LAN way is: it
/// is compared by how it answers, as a relay's way is.
export const TAILNET = "tailnet";
/// The `pinned` of a link on the endpoint fenced to the relays a workspace left on, before them (`fencedOf`): at home on
/// those alone, never a relay it turned off, and punching holes through them as the main endpoint does. While a workspace
/// turns some of still.fail's relays off, the main endpoint (at home on every one) is not dialled, and without this
/// nothing went direct: a workspace that turned its relays in China off reached its station in Tokyo through a relay
/// alone, seconds a round trip, from a device behind a proxy in Japan (2026-11-16).
const FENCED = "fenced:";
/// The fence of `relays` as a link's `pinned` says it: the same for the same relays, whatever their order.
export function fencedOf(relays: string[]): string {
  return FENCED + relays.map(relayKey).sort().join(" ");
}
function isFenced(pinned: string | null): pinned is string {
  return pinned !== null && pinned.startsWith(FENCED);
}
/// The ways dialled at addresses the station said, each on an endpoint of its own.
export const AT_ADDRESSES = [LAN, TAILNET] as const;
export type AtAddresses = (typeof AT_ADDRESSES)[number];
/// What a workspace turns off (its `ways_off`) to keep its devices off a path iroh punches through: the main endpoint's.
export const DIRECT = "direct";
/// Where each station said a device dials it straight (by address: `{lan, tailnet}`), kept: a run dials them at once,
/// before any relay brought the station's answer (one whose relays cannot be reached is reached on them alone). Under
/// the key its user names (`MeshEnv.addressesKey`), else this one.
export const ADDRESSES_KEY = "peer-addresses";
/// A way direct (on the LAN endpoint, or the main endpoint's punched path) lost within MIN_STAY_MS of the requests moving
/// to it, FLAKY_LOSSES times in a row: no way direct is moved to for DIRECT_HOLD_MS, twice as long each time it happens
/// again, up to DIRECT_HOLD_MAX_MS, unless no other way is up. This avoids repeatedly moving requests to a flaky way and
/// waiting out DEAD_PINGS pings on it before returning to a relay.
const FLAKY_LOSSES = 2;
export const DIRECT_HOLD_MS = 2 * 60_000;
export const DIRECT_HOLD_MAX_MS = 30 * 60_000;
/// While a way on the LAN endpoint answered within this long, the requests keep off the main endpoint unless no other
/// way is up: the LAN way is enough, and the main endpoint's link would only punch one more path to the station
///.
export const LAN_RECALL_MS = DIRECT_RECALL_MS;
/// The least and most a read waits for its answer on its way before it is asked on the next best way as well.
export const HEDGE_FLOOR_MS = 1_000;
export const HEDGE_MAX_MS = 4_000;
/// How much of a request's body goes on a stream at a time when how far it has gone is told of (a part is 4 MB).
export const BODY_STEP = 64 * 1024;
export const NET_DAY_KEY = "net-day";
export const TALLY_EVERY_MS = 60_000;
export const SPEED_KEY = "relay-speed";
/// A reply this long or longer tells how fast a way is; a shorter one is mostly its round trip.
export const SPEED_MIN_BYTES = 512 * 1024;
/// Minimum bytes and elapsed time for recording a slow way early (below BULK_SLOW_BPS) before SPEED_MIN_BYTES arrives.
export const SPEED_SLOW_MIN_BYTES = 64 * 1024;
export const SPEED_CRAWL_MIN_BYTES = 8 * 1024;
export const SPEED_SLOW_MIN_MS = 5_000;
/// What a way's speed is weighed with its round trip by: the time a larger reply (a page of history, an image) takes.
export const TYPICAL_BYTES = 256 * 1024;
/// How long the speed seen on a way counts; then it is found out again, from the replies that come through it.
/// Slow measurements (< BULK_SLOW_BPS) expire much sooner so transient congestion does not poison a way for hours.
export const SPEED_KEPT_MS = 6 * 3600_000;
export const SPEED_SLOW_KEPT_MS = 15 * 60_000;
/// How long the fastest a way was seen at holds against slower replies after it (one slower that came beside others on
/// the way, or as the station read slowly); past it, a slower reply says how fast the way is now: it got slower (a
/// line more crowded, a hop further), and is no longer taken to be as fast as it once was.
export const SPEED_FRESH_MS = 10 * 60_000;
/// How often a way's speed is told to telemetry (`mesh.speed`) at most, for each station and relay: how fast each
/// relay brings replies to devices, beside the network the device is on (the cloud adds it), is how
/// the relays are compared; one a minute is enough for that, and a video's every part would be far too many.
export const SPEED_SAID_MS = 60_000;
/// Reference transfer size for comparing bulk ways (latency + transfer time).
export const BULK_BYTES = 4 * 1024 * 1024;
/// Throughput below which a bulk way is considered slow and triggers on-demand relay exploration.
export const BULK_SLOW_BPS = 512 * 1024;
/// Assumed throughput for an unmeasured direct or relay way when scoring bulk candidates.
export const BULK_PROBE_BPS = 1024 * 1024;
export const BULK_RELAY_PROBE_BPS = 256 * 1024;
/// Minimum interval between on-demand bulk relay explorations for the same peer.
export const BULK_EXPLORE_MS = 60_000;
/// A reply head is a line of JSON; anything longer is not a station talking.
const MAX_HEAD = 64 * 1024;

const noAnswer = () => t("core-logic.mesh.no_answer");
const meshError = (message: string) => new CoreError("mesh", message);
/// The opening's budget ran out. Only an unanswered handshake is evidence that the endpoint may be stuck; a
/// credential or stream stalled after it connected must not rebuild all of that endpoint's relay connections.
class OpeningTimeout extends CoreError {
  readonly connected: boolean;
  readonly frozen: boolean;
  constructor(connected: boolean, frozen = false) {
    super("mesh", noAnswer());
    this.connected = connected;
    this.frozen = frozen;
  }
}
/// Whether a native QUIC/TLS `endpoint.connect` error indicates the handshake hit a peer with a different ALPN
/// (`error 120`) or peer identity certificate (`invalid peer certificate`). Narrowly scoped so offline timeouts,
/// `server refused`, socket/network errors, and post-handshake credential/lock refusals never trigger relay rescue.
function isHandshakeConflictMessage(message: string): boolean {
  if (!message.includes("the cryptographic handshake failed:")) return false;
  return (
    message.includes("error 120:") ||
    message.includes("peer doesn't support any known protocol") ||
    message.includes("invalid peer certificate")
  );
}
/// A `connect` attempt aborted by a cryptographic handshake conflict (ALPN or peer identity mismatch).
class HandshakeConflict extends CoreError {
  constructor(message: string) {
    super("mesh", t("core-logic.mesh.unreached"));
    this.cause = message;
  }
}
/// A connection that failed under the transport (refused, reset, lost on the way): said to people as where it failed
/// (`unreached` dialling, `cut` once it was up), what the transport said kept as its `cause` for telemetry, not shown.
const transportError = (key: "core-logic.mesh.unreached" | "core-logic.mesh.cut") => (e: { message: string }) => {
  const error = meshError(t(key));
  error.cause = e.message;
  return error;
};
const unreached = transportError("core-logic.mesh.unreached");
const cut = transportError("core-logic.mesh.cut");

/// What a credential source gives: the credential, and `also`, what else is said with it in a link's first line (each
/// key a field of that line, after what every line says, `MeshEnv.says`; none in the lines that present it again), null
/// where nothing is. Said
/// each time, so that what a source was given by another (the still.fail cloud's credential, which has a `credential`
/// too) is not taken for it with what goes with it left unsaid.
export type Presented = { credential: string; also: Record<string, unknown> | null };
/// This device's credential for a workspace, for the device's endpoint id; `fresh` asks for a new one.
export type CredentialSource = (device: string, fresh: boolean) => Effect.Effect<Presented, CoreError>;

/// A request's head as it goes to a station: `path` includes `/admin/api`.
export type RequestHead = { method: string; path: string; headers: [string, string][] };

/// How a link to a station runs (`Link.net`).
export type LinkNet = {
  path: string | null;
  relay: string | null;
  rttMs: number | null;
  measured: { measuring: boolean; relays: [string, number | null][]; moved: string | null } | null;
  today: [number, number] | null;
  rxBytes: number;
  txBytes: number;
  /// Packets sent and lost on the way in use (`path` its id) since it opened.
  packets: { path: string; sent: number; lost: number } | null;
  /// Where the station said it is on its LAN (`ip:port`); none from a station that said none.
  lan?: string[];
};

/// One dial attempt of the latest round to a peer (`Mesh.diag`).
export type DialAttempt = {
  via: string;
  outcome: "ok" | "no_answer" | "refused" | "error" | "interrupted";
  stage: "onto" | "credential" | "dial" | "open_bi" | "send" | "hello" | "done";
  totalMs: number;
  error?: string;
};

/// Local connection diagnostics for a peer (`Mesh.diag`).
export type PeerDiag = {
  at: number;
  relays: { url: string; connected: boolean }[];
  lan: string[];
  tailnet: string[];
  attempts: DialAttempt[];
};

/// The client's half of a socket stream.
export interface SocketOut {
  write(bytes: Uint8Array): Effect.Effect<void, CoreError>;
  finish(): void;
}

/// The endpoint's id in an address `<scope>/<id>` (a station's: `<workspace>/<station>`); a bare id stands for itself.
export function endpointId(address: string): string {
  const at = address.lastIndexOf("/");
  return at >= 0 ? address.slice(at + 1) : address;
}

/// The ways to a station as last measured.
export type Measured = { measuring: boolean; relays: [string, number | null][]; moved: string | null };

type Day = { day: number; rx: number; tx: number };
/// Where a station said a device dials it straight, each kind of way's addresses (`ip:port`).
type Said = Record<AtAddresses, string[]>;
/// A kind of way's key for a station address, in the maps of dials at addresses.
const atKey = (kind: AtAddresses, addr: string) => `${kind} ${addr}`;
/// How fast a way to a station was seen bringing a reply (bytes a second; the fastest within SPEED_FRESH_MS of it), and
/// when.
type Speed = { bps: number; at: number };

/// A relay as a key: its URL as written out again, so `https://r` and `https://r/` are one.
function relayKey(relay: string): string {
  try {
    return new URL(relay).href;
  } catch {
    return relay;
  }
}

/// The machine a relay or an entry is on: its URL's hostname, whatever the port; null where it is no URL.
function hostOf(url: string): string | null {
  try {
    return new URL(url).hostname || null;
  } catch {
    return null;
  }
}

/// A relay as people see it named (views.ts relayName): its host, with its port when that is not the default one, so an
/// entry on a relay's machine (`https://39.105.157.122:8443`) is not taken for that relay.
export function relayHost(relay: string): string {
  try {
    return new URL(relay).host || relay;
  } catch {
    return relay;
  }
}

function sameRelay(a: string | null, b: string): boolean {
  if (a === null) return false;
  try {
    return new URL(a).href === new URL(b).href;
  } catch {
    return a === b;
  }
}

/// Only entries whose target is one of this endpoint's relays can be chosen within that relay's connection.
function entryRoutes(relays: string[], entries: string[], targets: Record<string, string>): { entry: string; relay: string }[] {
  return entries.flatMap((entry) => {
    const target = Object.entries(targets).find(([url]) => sameRelay(url, entry))?.[1];
    const relay = relays.find((url) => target !== undefined && sameRelay(url, target));
    return relay === undefined ? [] : [{ entry, relay }];
  });
}

/// The key of the endpoint on one relay alone: the device key's, made over for that relay.
export function pinnedKey(secret: Uint8Array, relay: string): Uint8Array {
  const prefix = utf8("stillfail/relay-endpoint/1\0");
  const r = utf8(relay);
  const all = new Uint8Array(prefix.length + secret.length + r.length);
  all.set(prefix, 0);
  all.set(secret, prefix.length);
  all.set(r, prefix.length + secret.length);
  return sha256(all);
}

/// What a way costs, in ms: its round trip, and what a TYPICAL_BYTES reply takes to come through it at the speed it was
/// seen at (nothing while that is not known: it is found out once requests go that way).
export function cost(ms: number, bps: number | null): number {
  return bps !== null && bps > 0 ? ms + (TYPICAL_BYTES / bps) * 1000 : ms;
}

/// A way as compared with another: what a request is expected to take on it at worst, its round trip and what a
/// TYPICAL_BYTES reply takes to come (`cost`) and twice how much its round trips vary; and how much they vary.
export type Score = { score: number; dev: number };

/// What a way must be quicker by, at least, for requests to move to it: a move re-asks the reads under way and starts
/// the event stream again, worth it only for a gain a person could notice.
export const MOVE_GAIN = 0.3;

/// Whether `other` is clearly better than `cur`: expected quicker by MOVE_GAIN at least, and by more than what the two
/// vary by (half their deviations together), so two ways as good as each other are not swapped back and forth. A way
/// gone erratic scores worse at once by its deviation alone.
export function clearlyBetter(cur: Score, other: Score): boolean {
  return other.score <= cur.score * (1 - MOVE_GAIN) && other.score + (cur.dev + other.dev) / 2 < cur.score;
}

/// One way to a station: a link (on the main endpoint, or on one pinned to a relay) and how it has been answering: its
/// pings' round trips smoothed as TCP smooths its own (RFC 6298: the mean an eighth each time, the mean deviation a
/// quarter).
/// A ping is the link's credential presented again on its control stream, answered by the station: the whole way
/// there and back, the station included, on the connection requests go on. Not QUIC's own estimate, which starts from
/// the handshake (getting onto the relay included) and moves an eighth a keep-alive (2026-10-05).
export class Way {
  readonly link: Link;
  samples = 0;
  srtt = 0;
  dev = 0;
  /// Ticks in a row it was clearly better than the way requests go on.
  better = 0;
  /// Pings in a row not answered.
  missed = 0;
  /// A ping of it is under way (one not answered yet is not sent again over it).
  pinging = false;
  /// How long its last ping answered took, its first too (none answered: null).
  answeredMs: number | null = null;
  /// What its link's replies had brought as it was last pinged: a ping late while more came is not missed (`brought`).
  rx = 0;
  /// Its first ping answered: not counted, it carried the link's own start (its first streams, the station taking the
  /// credential), and smoothed an eighth at a time it kept a way just dialled looking slower than it is.
  warm = false;
  /// Its link's paths as the last tick saw them (`Link.paths`), and which they were (`Link.pathShape`): `Mesh.#watchPaths`.
  saw: string | null = null;
  shape: string | null = null;

  constructor(link: Link) {
    this.link = link;
  }

  /// Whether its link's replies brought anything since this was last asked. A ping waits behind the replies on its line:
  /// a phone downloading through a slow relay missed three pings behind a part of the file, its one connection was let
  /// go as dead, and the download was cut every few seconds (2026-11-07).
  brought(): boolean {
    const more = this.link.came > this.rx;
    this.rx = this.link.came;
    return more;
  }

  note(ms: number): void {
    // Its deviation from nothing at first, not half the first round trip as RFC 6298 starts it (that is for a timeout,
    // kept long to be safe): a way just dialled scored twice its round trip and lost to one no quicker for minutes.
    if (this.samples === 0) {
      this.srtt = ms;
      this.dev = 0;
    } else {
      this.dev = 0.75 * this.dev + 0.25 * Math.abs(ms - this.srtt);
      this.srtt = 0.875 * this.srtt + 0.125 * ms;
    }
    this.samples++;
  }

  /// Where it goes: its relay (as a key), "lan" (the LAN endpoint's), "tailnet" (the Tailscale endpoint's), or
  /// "direct" (a path iroh punched).
  key(): string {
    if (this.link.pinned === LAN || this.link.pinned === TAILNET) return this.link.pinned;
    const p = this.link.chosenPath();
    if (p?.relay != null) return relayKey(p.relay);
    if (p !== undefined) return "direct";
    if (isFenced(this.link.pinned)) return "fenced";
    return this.link.pinned !== null ? relayKey(this.link.pinned) : "main";
  }
}

function closeMessage(reason: CloseReason): string {
  if (reason.kind === "application") {
    switch (reason.reason) {
      case "credential_refused":
        return t("core-logic.mesh.credential_refused");
      case "credential_revoked":
        return t("core-logic.mesh.credential_revoked");
      case "credential_expired":
        return t("core-logic.mesh.credential_expired");
      case "station_removed":
        return t("core-logic.mesh.station_removed");
      default:
        return t("core-logic.mesh.closed_by_station", { reason: reason.reason });
    }
  }
  if (reason.kind === "local") return t("core-logic.mesh.closed");
  if (reason.kind === "timeout") return t("core-logic.mesh.timed_out");
  return t("core-logic.mesh.cut");
}

/// Reads lines off a stream, keeping what followed.
export class Lines {
  readonly #stream: IrohStream;
  carry: Uint8Array = new Uint8Array();

  constructor(stream: IrohStream) {
    this.#stream = stream;
  }

  /// One newline-terminated line; null at the stream's end.
  next(): Effect.Effect<string | null, CoreError> {
    return Effect.gen({ self: this }, function* () {
      for (;;) {
        const at = this.carry.indexOf(10);
        if (at >= 0) {
          const line = fromUtf8(this.carry.subarray(0, at));
          this.carry = this.carry.slice(at + 1);
          return line;
        }
        if (this.carry.length > MAX_HEAD) return yield* Effect.fail(meshError(t("core-logic.mesh.head_too_long")));
        const chunk = yield* Effect.mapError(this.#stream.read(), cut);
        if (chunk === null) {
          if (this.carry.length === 0) return null;
          return yield* Effect.fail(meshError(t("core-logic.mesh.reply_cut")));
        }
        const next = new Uint8Array(this.carry.length + chunk.length);
        next.set(this.carry, 0);
        next.set(chunk, this.carry.length);
        this.carry = next;
      }
    });
  }
}

/// The fields of a control line that are the mesh's own to write: what `MeshEnv.says` may not name.
const OWN_FIELDS = ["credential", "traceparent"];

/// The refusals `MeshEnv.refusal` named: the credential was fine, and another would be refused the same (`Mesh.link`).
const named = new WeakSet<CoreError>();

/// The control stream: credential lines out, answers back.
class Control {
  readonly stream: IrohStream;
  readonly lines: Lines;
  readonly #refusal: MeshEnv["refusal"];
  readonly #says: MeshEnv["says"];
  answers = 0;
  #waiting: Deferred.Deferred<void>[] = [];
  constructor(stream: IrohStream, env: Pick<MeshEnv, "refusal" | "says">) {
    this.stream = stream;
    this.lines = new Lines(stream);
    this.#refusal = env.refusal;
    this.#says = env.says;
  }

  /// A line: the credential, then what every line says (`MeshEnv.says`), then `also`: what its source says with the
  /// credential (`Presented`), in the first line: the still.fail core's, the device's claim for this endpoint, for a
  /// station with a workspace lock (station/mesh-wire.ts).
  /// `traceparent`: the dial's (`mesh.connect`), which the station says with the connection on its log, so the two
  /// records of one connection are found together.
  send(credential: string, also?: Record<string, unknown> | null, traceparent?: string): Effect.Effect<void, CoreError> {
    const line = utf8(`${JSON.stringify({ credential, ...(this.#says ?? {}), ...(also ?? {}), ...(traceparent ? { traceparent } : {}) })}\n`);
    return Effect.mapError(this.stream.write(line), cut);
  }

  /// The station's answer to the credential last sent; fails if it refused.
  answer(): Effect.Effect<J, CoreError> {
    return Effect.gen({ self: this }, function* () {
      const line = yield* this.lines.next();
      if (line === null) return yield* Effect.fail(meshError(t("core-logic.mesh.credential_closed")));
      let answer: J;
      try {
        answer = JSON.parse(line);
      } catch (e) {
        return yield* Effect.fail(CoreError.plainly("mesh", e, t("core-logic.mesh.credential_unreadable")));
      }
      if (answer !== null && typeof answer === "object" && "error" in answer) {
        const reason = typeof answer.error === "string" ? answer.error : JSON.stringify(answer.error);
        if (answer.code === "client_upgrade_required") return yield* Effect.fail(new CoreError("client_upgrade_required", reason));
        // What the peer refuses for besides the credential is its user's to name (`MeshEnv.refusal`).
        const other = this.#refusal?.(answer, reason) ?? null;
        if (other !== null) {
          named.add(other);
          return yield* Effect.fail(other);
        }
        return yield* Effect.fail(new CoreError("credential_refused", t("core-logic.mesh.credential_refused_why", { reason })));
      }
      return answer;
    });
  }

  exchange(credential: string): Effect.Effect<J, CoreError> {
    return Effect.tap(Effect.andThen(this.send(credential), this.answer()), () =>
      Effect.sync(() => {
        this.answers++;
        const waiting = this.#waiting;
        this.#waiting = [];
        for (const d of waiting) Deferred.doneUnsafe(d, Effect.void);
      }),
    );
  }

  nextAnswer(after: number): Effect.Effect<void> {
    return Effect.suspend(() => {
      if (this.answers > after) return Effect.void;
      const d = Deferred.makeUnsafe<void>();
      this.#waiting.push(d);
      return Deferred.await(d);
    });
  }
}

/// A station's reply: its head, and its body as it comes (what came with the head line first).
export type Reply = {
  status: number;
  headers: [string, string][];
  body: Pull<Uint8Array>;
  /// Lets go of it: the stream is stopped both ways (what is not read any more, the station stops sending).
  cancel(): void;
  /// A screen view's body read by the host from here (IrohStream.tap), before any of it was taken; false where it is
  /// not (the host's has none, or it was read already).
  tap?: (call: number, cursor?: boolean) => Effect.Effect<boolean | "cursor">;
  /// Its frames that come as datagrams under the token it was opened with are given among its body (`duplex`'s
  /// `media`): false where the host's stream takes none.
  datagrams?: boolean;
};

function headersOf(v: J): [string, string][] {
  if (v === null || typeof v !== "object" || Array.isArray(v)) return [];
  return Object.entries(v).map(([k, x]) => [k, typeof x === "string" ? x : JSON.stringify(x)]);
}

export class Link {
  readonly conn: IrohConnection;
  readonly endpoint?: IrohEndpoint;
  readonly #control: Control;
  readonly #lock = Semaphore.makeUnsafe(1);
  renewalFailed = false;
  /// The station's refusal of the first credential, once it answered.
  refused: CoreError | null = null;
  credential: string;
  readonly credentials: CredentialSource;
  /// The relay whose own endpoint it is on (LAN, TAILNET: the one dialling stations at their addresses on their LAN, on
  /// their tailnet); null on the main one.
  readonly pinned: string | null;
  counted: [number, number] = [0, 0];
  /// The bytes its replies have brought so far, their heads and bodies (`Way.brought`).
  came = 0;
  /// The station's answer to the first credential, whole, as its line was parsed: its user's to read (who it let in,
  /// what it says of itself); null until it answered, and where it refused (`admitted` waits for it).
  answer: unknown = null;
  /// Where the station said a device on its LAN, on its tailnet, dials it (`ip:port`), in its answer to the first
  /// credential: the answer's `lan` and `tailnet`, which are the mesh's own to read (it dials them).
  lan: string[] = [];
  tailnet: string[] = [];
  /// Done once the station answered the first credential (refused or not).
  readonly answered = Deferred.makeUnsafe<void>();
  /// How its opening went (`open`): ms from its start until the endpoint was on a relay, the connection was made, and
  /// the credential was had; the first credential went as the later of the last two came.
  opened: { onto: number; dialled: number; credential: number } | null = null;
  /// Device timestamp (`nowMs`) when this link's dial started (`HOT_SETTLE_MS`).
  openedAt = 0;
  /// Short synchronous snapshot scope (`Mesh.#withSnap`) so one tick or `net()` call reads `paths`/`stats`/`closeReason`
  /// across the native FFI boundary at most once per link instead of repeatedly in comparators and helpers.
  #snapDepth = 0;
  #pathsSnap: IrohPath[] | null = null;
  #statsSnap: { rxBytes: number; txBytes: number } | null = null;
  #closeSnap: CloseReason | null | undefined = undefined;

  beginSnap(): void {
    this.#snapDepth++;
  }

  endSnap(): void {
    if (this.#snapDepth > 0 && --this.#snapDepth === 0) {
      this.#pathsSnap = null;
      this.#statsSnap = null;
      this.#closeSnap = undefined;
    }
  }

  connPaths(): IrohPath[] {
    if (this.#snapDepth > 0) {
      if (this.#pathsSnap === null) this.#pathsSnap = this.conn.paths();
      return this.#pathsSnap;
    }
    return this.conn.paths();
  }

  connStats(): { rxBytes: number; txBytes: number } {
    if (this.#snapDepth > 0) {
      if (this.#statsSnap === null) this.#statsSnap = this.conn.stats();
      return this.#statsSnap;
    }
    return this.conn.stats();
  }

  connCloseReason(): CloseReason | null {
    if (this.#snapDepth > 0) {
      if (this.#closeSnap === undefined) this.#closeSnap = this.conn.closeReason();
      return this.#closeSnap;
    }
    return this.conn.closeReason();
  }

  constructor(conn: IrohConnection, control: Control, credential: string, credentials: CredentialSource, pinned: string | null, endpoint?: IrohEndpoint) {
    this.conn = conn;
    this.endpoint = endpoint;
    this.#control = control;
    this.credential = credential;
    this.credentials = credentials;
    this.pinned = pinned;
  }

  /// Once the station answered the first credential: its answer (`answer`), or failing with its refusal (`refused`).
  /// A link is handed out as its credential is sent, its requests going already: what must know it was let in first
  /// (who it is there, whether to go on) waits here.
  admitted(): Effect.Effect<unknown, CoreError> {
    return Effect.flatMap(Deferred.await(this.answered), () => (this.refused !== null ? Effect.fail(this.refused) : Effect.succeed(this.answer)));
  }

  /// What its control stream is asked, one exchange at a time.
  controlled<A>(f: (c: Control) => Effect.Effect<A, CoreError>): Effect.Effect<A, CoreError> {
    return this.#lock.withPermits(1)(f(this.#control));
  }

  /// A request's stream, its head and body sent and its reply's head read. Given up before that head (its asker gone, a
  /// read let go of; or failed), the stream goes at once: the station stops what it is sending on it, which no one
  /// would read.
  /// `media`: a token its frames' datagrams are taken under before its head goes (IrohStream.receiveMediaDatagrams), the
  /// head made knowing whether they are (`head` a function); the fourth of what it gives.
  #open(head: J | ((media: boolean) => J), finish: boolean, body: Uint8Array | null, wrote?: (sent: number) => void, media = 0, guard?: () => boolean): Effect.Effect<[IrohStream, Lines, J, boolean], CoreError> {
    let opened: IrohStream | null = null;
    return Effect.gen({ self: this }, function* () {
      const checkGuard = () => (guard && !guard() ? Effect.fail(new CoreError("auth_stale", "auth_stale")) : Effect.void);
      yield* checkGuard();
      const stream = (opened = yield* Effect.mapError(this.conn.openBi(), cut));
      const taking = media > 0 && stream.receiveMediaDatagrams !== undefined ? yield* Effect.orElseSucceed(stream.receiveMediaDatagrams(media), () => false) : false;
      yield* checkGuard();
      const said = typeof head === "function" ? head(taking) : head;
      yield* Effect.mapError(stream.write(utf8(`${JSON.stringify(said)}\n`)), cut);
      // A body that is told of goes a step at a time, each said as the stream takes it (as far as the link lets it).
      if (body !== null && body.length > 0 && wrote) {
        for (let at = 0; at < body.length; at += BODY_STEP) {
          yield* checkGuard();
          const end = Math.min(at + BODY_STEP, body.length);
          yield* Effect.mapError(stream.write(body.subarray(at, end)), cut);
          wrote(end);
        }
      } else if (body !== null && body.length > 0) {
        yield* checkGuard();
        yield* Effect.mapError(stream.write(body), cut);
      }
      if (finish) yield* Effect.mapError(stream.finish(), cut);
      const lines = new Lines(stream);
      const line = yield* lines.next();
      if (line === null) return yield* Effect.fail(meshError(t("core-logic.mesh.no_reply")));
      let reply: J;
      try {
        reply = JSON.parse(line);
      } catch (e) {
        return yield* Effect.fail(CoreError.plainly("mesh", e, t("core-logic.mesh.reply_unreadable")));
      }
      const status = reply?.status;
      if (typeof status !== "number" || !Number.isInteger(status) || status < 0 || status > 65535) return yield* Effect.fail(meshError(t("core-logic.mesh.reply_no_status")));
      return [stream, lines, reply, taking] as [IrohStream, Lines, J, boolean];
    }).pipe(Effect.onExit((exit) => (exit._tag === "Success" ? Effect.void : Effect.sync(() => opened?.reset(0)))));
  }

  static #body(link: Link, stream: IrohStream, lines: Lines): Pull<Uint8Array> & { claim(): Uint8Array | null; restore(prefix: Uint8Array): void } {
    let carry: Uint8Array | null = lines.carry.length > 0 ? lines.carry : null;
    let done = false;
    let started = false;
    return {
      // what came past the reply, none of it taken yet (null once it was): the host's to read from (IrohStream.tap)
      claim: () => {
        if (started) return null;
        const c = carry ?? new Uint8Array(0);
        carry = null;
        return c;
      },
      restore: (prefix) => {
        carry = prefix.length > 0 ? prefix : null;
      },
      take: Effect.suspend(() => {
        started = true;
        if (carry !== null) {
          const c = carry;
          carry = null;
          return Effect.succeed(c);
        }
        if (done) return Effect.succeed(null);
        return Effect.map(
          Effect.tapError(stream.read(), () => Effect.sync(() => (done = true))),
          (chunk) => {
            if (chunk === null) done = true;
            else link.came += chunk.length;
            return chunk;
          },
        );
      }),
    };
  }

  /// One request on its own stream; `wrote`: how much of its body has gone, as it goes.
  request(head: RequestHead, body: Uint8Array, wrote?: (sent: number) => void, guard?: () => boolean): Effect.Effect<Reply, CoreError> {
    const wire = { method: head.method, path: head.path, headers: Object.fromEntries(head.headers) };
    return Effect.mapError(
      Effect.map(this.#open(wire, true, body, wrote, 0, guard), ([stream, lines, reply]) => ({ status: reply.status, headers: headersOf(reply.headers), body: Link.#body(this, stream, lines), cancel: () => stream.reset(0) })),
      (e) => this.refused ?? e,
    );
  }

  /// A preview page's WebSocket on its own stream: the stream stays open both ways.
  socket(head: RequestHead): Effect.Effect<[Reply, SocketOut], CoreError> {
    return this.#duplex({ method: head.method, path: head.path, headers: Object.fromEntries(head.headers), socket: true });
  }

  /// A request whose head line carries further fields (`more`, after its headers) on its own stream, which stays open
  /// both ways: a view of one of the station's screens, its head's `screen` and then the frames (station/mesh-wire.ts).
  /// `media` (with `more` a function of whether it is taken): a token the frames the other end sends as datagrams are
  /// taken under, given among the body (`Reply.datagrams`).
  duplex(head: RequestHead, more: Record<string, unknown> | ((media: boolean) => Record<string, unknown>), media = 0): Effect.Effect<[Reply, SocketOut], CoreError> {
    const wire = (taking: boolean) => ({ method: head.method, path: head.path, headers: Object.fromEntries(head.headers), ...(typeof more === "function" ? more(taking) : more) });
    return this.#duplex(wire, media);
  }

  #duplex(wire: J | ((media: boolean) => J), media = 0): Effect.Effect<[Reply, SocketOut], CoreError> {
    return Effect.map(this.#open(wire, false, null, undefined, media), ([stream, lines, reply, taking]) => {
      const out: SocketOut = {
        write: (bytes) => Effect.mapError(stream.write(bytes), cut),
        finish: () => void Effect.runFork(Effect.ignore(stream.finish())),
      };
      const body = Link.#body(this, stream, lines);
      const tapping = stream.tap;
      // (what came past the reply goes to the host with it, so it reads the frames from their start)
      const tap =
        tapping === undefined
          ? undefined
          : (call: number, cursor?: boolean) =>
              Effect.suspend(() => {
                const prefix = body.claim();
                if (prefix === null) return Effect.succeed(false);
                return Effect.map(Effect.orElseSucceed(tapping.call(stream, call, prefix, cursor), () => false as const), (tapped) => {
                  if (!tapped) body.restore(prefix);
                  return tapped;
                });
              });
      return [{ status: reply.status, headers: headersOf(reply.headers), body, cancel: () => stream.reset(0), tap, ...(taking ? { datagrams: true } : {}) }, out] as [Reply, SocketOut];
    });
  }

  /// A request with no body whose head line carries further fields (`more`, after its headers), on its own stream: this
  /// phone's adb offered to the station, or asked about, its head's `adb` (adb.ts).
  ask(head: RequestHead, more: Record<string, unknown>, guard?: () => boolean): Effect.Effect<Reply, CoreError> {
    const wire = { method: head.method, path: head.path, headers: Object.fromEntries(head.headers), ...more };
    return Effect.map(this.#open(wire, true, null, undefined, 0, guard), ([stream, lines, reply]) => ({ status: reply.status, headers: headersOf(reply.headers), body: Link.#body(this, stream, lines), cancel: () => stream.reset(0) }));
  }

  /// The next stream the station opens on the link; null once it closed.
  accept(): Effect.Effect<IrohStream | null> {
    return this.conn.acceptBi();
  }

  closed(): string | null {
    const r = this.connCloseReason();
    return r === null ? null : closeMessage(r);
  }

  close(): void {
    this.#closeSnap = undefined;
    this.conn.close(0, "closed");
  }

  /// The way it goes by now: the one iroh chose; where a host marks none while the link carries on (iroh keeps one
  /// chosen way an endpoint to another, which two links of one endpoint to the same station, or a way moved between a
  /// machine's interfaces, leaves unmarked: Windows to Windows), the way its packets go, a direct one before a relay's
  /// and the busiest first; with none sent yet, the only way, or the first where the link is pinned to one kind of
  /// direct way (`LAN`, `TAILNET`) or every way is direct. None only where it may still be a relay's.
  #chosen(paths: IrohPath[] = this.connPaths()): IrohPath | undefined {
    const selected = paths.find((p) => p.selected);
    if (selected !== undefined || paths.length === 0) return selected;
    let busiest: IrohPath | undefined;
    for (const p of paths) {
      if (p.txPackets <= 0) continue;
      const direct = p.relay === null;
      if (busiest === undefined || (direct && busiest.relay !== null) || (direct === (busiest.relay === null) && p.txPackets > busiest.txPackets)) busiest = p;
    }
    if (busiest !== undefined) return busiest;
    return paths.length === 1 || this.pinned === LAN || this.pinned === TAILNET || paths.every((p) => p.relay === null) ? paths[0] : undefined;
  }

  chosenPath(): IrohPath | undefined {
    return this.#chosen();
  }

  path(): string | null {
    const p = this.#chosen();
    return p === undefined ? null : p.relay !== null ? "relay" : "direct";
  }

  via(): string | null {
    return this.#chosen()?.relay ?? null;
  }

  /// Key under which this link's throughput is tracked, or null for LAN links and unknown paths.
  speedKey(): string | null {
    if (this.pinned === LAN) return null;
    const p = this.#chosen();
    if (p?.relay != null) return relayKey(p.relay);
    if (this.pinned === TAILNET) return TAILNET;
    if (p !== undefined) return DIRECT;
    return null;
  }

  /// Every way iroh has for it, as a span says them: `*` the one chosen, then where it goes (a relay's host, or a direct
  /// way's address), its round trip, the packets sent and lost on it. What a phone's direct way was, and how it went,
  /// as requests moved off it (2026-10-17: gone 20–30 s after it was taken, on a phone alone).
  paths(): string {
    const paths = this.connPaths();
    const chosen = this.#chosen(paths);
    return paths
      .map((p) => `${p === chosen ? "*" : ""}${p.relay !== null ? relayHost(p.relay) : (p.ip ?? "direct")} ${p.rttMs === null ? "?" : `${Math.round(p.rttMs)}ms`} ${p.txPackets}/${p.lostPackets}`)
      .join("; ");
  }

  /// Which ways iroh has for it, where each goes and the one chosen, without their counts: what changes as one opens, goes
  /// or is chosen.
  pathShape(): string {
    const paths = this.connPaths();
    const chosen = this.#chosen(paths);
    return paths.map((p) => `${p === chosen ? "*" : ""}${p.id}@${p.relay ?? p.ip ?? "direct"}`).join(",");
  }

  /// How this link currently reaches its station (`path` and `relay` host), without reading byte/packet stats.
  way(): { path: string | null; relay: string | null } {
    const selected = this.#chosen();
    const pinnedPath = this.pinned === TAILNET ? TAILNET : this.pinned === LAN ? "direct" : null;
    return {
      path: selected === undefined ? pinnedPath : selected.relay !== null ? "relay" : this.pinned === TAILNET ? TAILNET : "direct",
      relay: selected?.relay ? relayHost(selected.relay) : null,
    };
  }

  net(): LinkNet {
    const selected = this.#chosen();
    const stats = this.connStats();
    // A link pinned to a direct way goes by none other, whatever its host marks.
    const pinnedPath = this.pinned === TAILNET ? TAILNET : this.pinned === LAN ? "direct" : null;
    return {
      path: selected === undefined ? pinnedPath : selected.relay !== null ? "relay" : this.pinned === TAILNET ? TAILNET : "direct",
      relay: selected?.relay ? relayHost(selected.relay) : null,
      rttMs: selected !== undefined ? selected.rttMs : null,
      measured: null,
      today: null,
      rxBytes: stats.rxBytes,
      txBytes: stats.txBytes,
      // The way in use alone: the connection's own counts take in every way iroh tried and dropped, which made a
      // quiet direct link look like it lost a third of its packets.
      packets: selected === undefined ? null : { path: selected.id, sent: selected.txPackets, lost: selected.lostPackets },
    };
  }

  /// What went over it, both ways, since this was last asked.
  uncounted(): [number, number] {
    const stats = this.connStats();
    const [wasRx, wasTx] = this.counted;
    this.counted = [stats.rxBytes, stats.txBytes];
    return [Math.max(stats.rxBytes - wasRx, 0), Math.max(stats.txBytes - wasTx, 0)];
  }

  /// Whether the station answers on it within PROBE_MS: the credential presented again, by a fiber of `runner`'s that
  /// nothing cuts short, in its turn on the control stream behind whatever exchange is out on it (a ping). Its time run
  /// out (or this let go of) before its turn came, nothing is sent; run out with its line sent, its answer is still read
  /// as it comes and counted (`controlAnswers`). So the control stream is never left with a line sent and its answer
  /// unread: the next exchange would read this one's answer for its own.
  answers(runner: Runner): Effect.Effect<boolean> {
    return Effect.suspend(() => {
      let probing = true;
      const done = Deferred.makeUnsafe<boolean>();
      runner.fork(
        Effect.flatMap(
          Effect.result(this.controlled((c) => Effect.suspend(() => (probing ? Effect.as(c.exchange(this.credential), true) : Effect.succeed(false))))),
          (r) => Effect.sync(() => Deferred.doneUnsafe(done, Effect.succeed(r._tag === "Success" && r.success))),
        ),
      );
      return Effect.ensuring(
        Effect.raceFirst(Deferred.await(done), Effect.as(Effect.sleep(PROBE_MS), false)), // timer: a deadline on the answer
        Effect.sync(() => {
          probing = false;
        }),
      );
    });
  }

  controlAnswers(): number {
    return this.#control.answers;
  }

  nextControlAnswer(after: number): Effect.Effect<void> {
    return this.#control.nextAnswer(after);
  }

  usable(): boolean {
    return this.connCloseReason() === null && !this.renewalFailed;
  }
}

/// Controls a `#dialAll` fan-out: `cancelSignal` aborts in-flight dials when a caller discards or supersedes the round;
/// `adopt` gates sibling adoption until the caller commits to the round's winner.
type DialControl = {
  cancelled: boolean;
  readonly cancelSignal: Deferred.Deferred<void>;
  readonly adopt: Deferred.Deferred<boolean>;
};

function makeDialControl(adoptNow = false): DialControl {
  const adopt = Deferred.makeUnsafe<boolean>();
  if (adoptNow) Deferred.doneUnsafe(adopt, Effect.succeed(true));
  return { cancelled: false, cancelSignal: Deferred.makeUnsafe<void>(), adopt };
}

function commitDial(c: DialControl | undefined): void {
  if (c === undefined || c.cancelled) return;
  Deferred.doneUnsafe(c.adopt, Effect.succeed(true));
}

function cancelDial(c: DialControl | undefined): void {
  if (c === undefined || c.cancelled) return;
  c.cancelled = true;
  Deferred.doneUnsafe(c.adopt, Effect.succeed(false));
  Deferred.doneUnsafe(c.cancelSignal, Effect.void);
}

function pinnedIdentity(pinned: string | null): string {
  if (pinned === null) return "main";
  if (pinned === LAN || pinned === TAILNET || isFenced(pinned)) return pinned;
  return relayKey(pinned);
}

/// An opening shared by everyone who asks for the same station address meanwhile.
type Opening = { done: Deferred.Deferred<Link, CoreError>; result: { ok: Link } | { err: CoreError; unanswered: boolean } | null; controls?: DialControl[] };

/// A link tried beside an opening still under way (`hedge`).
type Hedge = { serial: number; credentials: CredentialSource; tx: Deferred.Deferred<Link, CoreError> | null; control: DialControl };

/// What a mesh is made with: where it runs (`host`, `runner`, `tracer`, `iroh`, `wakes`) and what its user's protocol
/// is, none of which it says itself (the still.fail core's: station/mesh-wire.ts `STATION_MESH` and `meshEnv`).
export type MeshEnv = {
  host: BaseHost;
  runner: Runner;
  tracer: Tracer;
  iroh: Iroh;
  /// Program-owned admission to additional transports, on the same endpoint.
  prepare?(address: string, endpoint: IrohEndpoint, trace?: PrepareTrace): Effect.Effect<string | undefined, CoreError>;
  linked?(address: string, link: Link, endpoint: IrohEndpoint): Effect.Effect<void, CoreError>;
  wakes: Wakes;
  /// The protocol its links are dialled on (what the peer's endpoint takes).
  alpn: Uint8Array;
  /// What every line of a link's control stream says after its credential, the first and those that present it again
  /// (its fields, in their order); none: the credential alone. Never `credential` nor `traceparent`, a line's own
  /// (`OWN_FIELDS`): a mesh is not made with one that names them, which would send something else in their place.
  says?: Record<string, unknown>;
  /// Whether the main endpoint looks its peers up (the host's lookup, as its iroh was built: on the LAN and in the
  /// DHT), while it has a relay and is not `relayOnly`; without it a peer is reached by the relays and addresses it is
  /// dialled with alone.
  lookup?: boolean;
  /// Whether that lookup is in the DHT too, read as the main endpoint is bound (none: it is); what it says changed is
  /// taken by `relook`.
  dht?: () => boolean;
  /// Through relays alone: the main endpoint has no IP transports (and looks nothing up), and no peer is dialled at
  /// the addresses it said (its LAN's, its tailnet's).
  relayOnly?: boolean;
  /// Relay paths kept open per settled station on the main endpoint when the host exposes `setDisabledRelays`,
  /// `insertRelay`, and `removeRelay` (unset or <= 0: disabled).
  hotRelays?: number;
  /// Relay paths kept open per settled idle station (`idle` returns true for every open link of that station) on the
  /// main endpoint when the host exposes relay controls (unset or <= 0: disabled).
  idleHotRelays?: number;
  /// Whether `addr` is currently idle (no UI viewing it and no recent foreground request): eligible for `idleHotRelays`
  /// narrowing and slower control-stream keepalive pings (`IDLE_TICK_MS`).
  idle?: (addr: string) => boolean;
  /// The key what its peers said of where they are dialled straight is kept under (`ADDRESSES_KEY` without).
  addressesKey?: string;
  /// The protocols the main endpoint takes connections on, and `incoming` what is done with each (an app, as a trusted
  /// device a new one meets face to face: views/pair.ts).
  takes?: Uint8Array[];
  incoming?: (connection: IrohConnection, alpn: Uint8Array) => void;
  /// What a peer's refusal of a link's first line is, by its answer as parsed (an object with `error`) and the reason
  /// it gave, where it refuses for something else than the credential (the still.fail core's: a workspace's lock,
  /// station/mesh-wire.ts); none, or null: the credential refused (`credential_refused`).
  refusal?: (answer: J, reason: string) => CoreError | null;
};

/// The links are kept by station address (`"<workspace>/<station>"`, `endpointId`; a bare station id stands for
/// itself): a station in two workspaces has a link in each, opened with that workspace's credential, renewed, dropped and
/// opened again on its own; both are dialled to the same endpoint, the station's id. What is the network's alone is kept
/// by station id and shared: how fast replies came through a relay (`speed`), what went over the links today (`today`).
export class Mesh {
  readonly #env: MeshEnv;
  relays: string[];
  /// Ways into a relay through another relay's machine (cloud relays.ts `relay_entries`). The main endpoint treats an
  /// entry as another entrance to that relay, not another relay connection: using the same key on both would make them
  /// displace each other. A pinned endpoint for measurements or workspace restrictions has its own key.
  entries: string[];
  entryTargets: Record<string, string>;
  #endpoint: IrohEndpoint;
  #secret: Uint8Array;
  readonly #links = new Map<string, Opening>();
  #changed: Deferred.Deferred<void>[] = [];
  readonly #racing = new Set<string>();
  #stuck = false;
  /// What each link had sent and taken as the record last said it (#recordWays).
  readonly #recorded = new WeakMap<Link, { rx: number; tx: number; paths: Map<string, [number, number]> }>();
  #reboundAt = -Infinity;
  #rebinding: Deferred.Deferred<IrohEndpoint> | null = null;
  #rebindAgain = false;
  readonly #known: import("./iroh.ts").IrohAddr[] = [];
  readonly #hedges = new Map<string, Hedge>();
  /// Stations whose link is being asked whether it still answers, the UI just back (`#checkWoken`).
  readonly #checking = new Set<string>();
  #serials = 0;
  readonly #pinned = new Map<string, Deferred.Deferred<IrohEndpoint | null>>();
  /// Monotonic wake generation bumped on UI-back / network wakes (immune to same-ms wakes and wall-clock jumps).
  #wakeGen = 0;
  /// Monotonic network-reset generation bumped whenever `#deadRelays` is cleared (`wake.network || wake.retry`).
  #netGen = 0;
  /// The relays of each fence a station was dialled in (`#fence`), by the fence.
  readonly #fences = new Map<string, string[]>();
  /// By address: the ways open to it (the link requests go on among them), each pinged every TICK_MS while it has any.
  readonly #ways = new Map<string, Way[]>();
  readonly #steering = new Set<string>();
  /// Ways let go, closed RETIRE_MS later (what is still coming on them comes meanwhile).
  readonly #retiring = new Set<Link>();
  readonly #exploring = new Set<string>();
  readonly #exploredAt = new Map<string, number>();
  /// By address: when a way to it was last seen going direct, and when the main endpoint last dialled it again.
  readonly #directAt = new Map<string, number>();
  readonly #mainDialledAt = new Map<string, number>();
  /// By address: where the station last said a device dials it straight (kept: `MeshEnv.addressesKey`). By kind and address
  /// (`atKey`): the addresses last dialled on that kind's endpoint, when, and whether a dial is under way.
  readonly #said: Record<string, Said>;
  readonly #tried = new Map<string, string>();
  readonly #atDialledAt = new Map<string, number>();
  readonly #atDialling = new Set<string>();
  /// By address: the addresses a dial on the main endpoint was given when it went unanswered (`#dialAll`).
  readonly #unansweredAt = new Map<string, string>();
  /// By address: monotonic deadline until which a single-relay rescue after a main handshake conflict is cooled down.
  readonly #handshakeRescueCooldown = new Map<string, number>();
  /// In-flight single-relay handshake rescues keyed by `${addr}\0${netGen}` so concurrent openings never stack rescues.
  readonly #handshakeRescuing = new Set<string>();
  /// The addresses whose one connection on the main endpoint was let go unanswered (`#choose`): the next dial goes on
  /// each relay's own endpoint beside it (`#dialAll`).
  readonly #lostMain = new Set<string>();
  /// The addresses whose `#mainOn` dial fanned out to pinned rescue relays (`#unansweredAt` or `#lostMain`): retired
  /// again once `main` is current and healthy (`#prune`).
  readonly #rescued = new Set<string>();
  /// Dials under way on pinned endpoints (their endpoints are not let go meanwhile).
  #dialing = 0;
  /// In-flight pinned dials keyed by `${addr}\0${pinnedIdentity(relay)}\0${netGen}`.
  readonly #inFlightPinned = new Map<string, number>();
  /// Dials under way on the main endpoint (all official relays stay connected meanwhile).
  #mainDialing = 0;
  /// By station id: narrowed logical relay keys (`relayKey`) while settled on the main endpoint; absent when relaxed.
  readonly #hot = new Map<string, Set<string>>();
  /// By station id: when it was last relaxed (`HOT_SETTLE_MS` before narrowing again).
  readonly #relaxedAt = new Map<string, number>();
  /// Serialises `setDisabledRelays` / `insertRelay` / `removeRelay` on `#endpoint`, draining `#syncDirty`.
  readonly #syncLock = Semaphore.makeUnsafe(1);
  #syncDirty = false;
  readonly #endpointRemoved = new Set<string>();
  readonly #appliedDisabled = new Map<string, string>();
  /// By address: the relay requests last moved to (its host), and how many times they moved.
  readonly #moved = new Map<string, string>();
  readonly #moves = new Map<string, number>();
  readonly #movedAt = new Map<string, number>();
  /// By address: whether the way requests last moved to went direct; how many ways direct were lost in a row soon after
  /// they were moved to, and until when no way direct is moved to (FLAKY_LOSSES).
  readonly #movedDirect = new Map<string, boolean>();
  readonly #directLosses = new Map<string, number>();
  readonly #directHeldUntil = new Map<string, number>();
  /// By address: when a way on the LAN endpoint last answered its ping (LAN_RECALL_MS); whether one on the Tailscale
  /// endpoint did since the network last changed (it is dialled again then, as the relays are: `#dialAtIf`).
  readonly #lanAt = new Map<string, number>();
  readonly #tailnetAnswered = new Set<string>();
  /// By address: whether a way to it answers its pings, as the last tick found (`healthy`), and who waits for that to
  /// change (`healthChange`).
  readonly #health = new Map<string, boolean>();
  readonly #healthWaiting = new Map<string, Deferred.Deferred<boolean>[]>();
  #closed = false;
  /// By endpoint: the connections its user made or took on it (`endpoint()`'s dials, `#accepting`'s), none of them
  /// links: an endpoint they are open on counts as in use (`#anyOpen`), and is closed only once they are (`#closeOld`).
  readonly #peers = new WeakMap<IrohEndpoint, Set<IrohConnection>>();
  /// Endpoints bound over that wait for their user's connections to end before they close (`#closeOld`).
  readonly #retired = new Set<IrohEndpoint>();
  /// By endpoint: what `endpoint()` gives of it.
  readonly #shown = new WeakMap<IrohEndpoint, IrohEndpoint>();
  /// By address: the relays its workspace has of its own, and the ways it turned off (its `ways_off`: relays, kinds of
  /// way), as the last `link` to it said.
  readonly #theirs = new Map<string, string[]>();
  readonly #off = new Map<string, string[]>();
  /// By station id: what its links carried today.
  #days: Record<string, Day>;
  #daysChanged = false;
  /// By station id, then relay (`relayKey`): how fast replies came that way.
  readonly #speeds: Record<string, Record<string, Speed>>;
  /// By station id and relay: what replies brought that way in this run (`timed`).
  readonly #came = new Map<string, number>();
  /// When each station's way through each relay last had its speed told (`mesh.speed`), by `#came`'s keys.
  readonly #speedSaid = new Map<string, number>();
  /// Last observed significant slowdown per station and way key, to distinguish sustained throttling from a single dip.
  readonly #slowSeen = new Map<string, { bps: number; at: number }>();
  /// By address: when on-demand bulk relay exploration last ran.
  readonly #bulkExploredAt = new Map<string, number>();
  /// By address: when bulk links were last used, so `#prune` keeps bulk relays while transfers continue.
  readonly #bulkUsedAt = new Map<string, number>();
  /// By relayKey: until when a relay whose pinned endpoint timed out without ever connecting is skipped across stations.
  readonly #deadRelays = new Map<string, number>();
  /// By relayKey: consecutive OpeningTimeout(!connected) failures on a relay that did report connected.
  readonly #deadRelayFails = new Map<string, number>();
  /// By address: wakes an idle `#steer` sleep immediately when the station becomes active or is dropped.
  readonly #steerWakes = new Map<string, Deferred.Deferred<void>>();
  /// By address: the latest dial round's per-route outcomes (`#dialAll`, `diag`).
  readonly #diags = new Map<string, { at: number; attempts: DialAttempt[] }>();

  private constructor(env: MeshEnv, relays: string[], entries: string[], targets: Record<string, string>, endpoint: IrohEndpoint, secret: Uint8Array, days: Record<string, Day>, speeds: Record<string, Record<string, Speed>>, said: Record<string, Said>) {
    this.#env = env;
    this.relays = relays;
    this.entries = entries;
    this.entryTargets = targets;
    this.#endpoint = endpoint;
    this.#secret = secret;
    this.#days = days;
    this.#speeds = speeds;
    this.#said = said;
  }

  /// Binds the endpoint with the stored device key (made and stored the first time). No relays binds without one.
  static make(env: MeshEnv, relays: string[], entries: string[] = [], targets: Record<string, string> = {}): Effect.Effect<Mesh, CoreError> {
    // (its user's mistake, thrown as it is made: no link would say what it means)
    const own = OWN_FIELDS.filter((field) => env.says !== undefined && field in env.says);
    if (own.length > 0) throw new Error(`MeshEnv.says names ${own.join(" and ")}: a control line's own, which the mesh writes`);
    return Effect.gen(function* () {
      const host = env.host;
      const stored = yield* Effect.mapError(host.storageGet(DEVICE_KEY), asCoreError);
      let secret: Uint8Array;
      if (stored !== null && stored.length === 32) secret = stored;
      else {
        secret = new Uint8Array(32);
        host.randomBytes(secret);
        yield* Effect.mapError(host.storageSet(DEVICE_KEY, secret), asCoreError);
      }
      const daysRaw = parseJson(yield* Effect.orElseSucceed(host.storageGet(NET_DAY_KEY), () => null)) as J;
      const days: Record<string, Day> = daysRaw !== null && typeof daysRaw === "object" && !Array.isArray(daysRaw) ? daysRaw : {};
      const speedsRaw = parseJson(yield* Effect.orElseSucceed(host.storageGet(SPEED_KEY), () => null)) as J;
      const speeds: Record<string, Record<string, Speed>> = speedsRaw !== null && typeof speedsRaw === "object" && !Array.isArray(speedsRaw) ? speedsRaw : {};
      const said = saidOf(parseJson(yield* Effect.orElseSucceed(host.storageGet(env.addressesKey ?? ADDRESSES_KEY), () => null)));
      const fresh = entries.filter((e) => !relays.some((r) => sameRelay(r, e)));
      const routes = entryRoutes(relays, fresh, targets);
      const allowlist = Mesh.#allowlist(relays, routes);
      const endpoint = yield* Mesh.#bindMain(env, secret, relays, routes, allowlist);
      const mesh = new Mesh(env, relays, fresh, targets, endpoint, secret, days, speeds, said);
      env.runner.fork(mesh.#accepting(endpoint));
      env.runner.fork(mesh.#watch());
      env.runner.fork(mesh.#tally());
      return mesh;
    });
  }

  /// Deduplicated relay and entry URLs permitted on an endpoint, by normalized URL key.
  static #allowlist(relays: string[], entries: { entry: string; relay: string }[], extra: Iterable<string> = []): string[] {
    const seen = new Set<string>();
    const out: string[] = [];
    for (const url of [...relays, ...entries.map((e) => e.entry), ...extra]) {
      const key = relayKey(url);
      if (seen.has(key)) continue;
      seen.add(key);
      out.push(url);
    }
    return out;
  }

  /// Deduplicated allowlist for the main endpoint: its relays, forwarding entries, and any known workspace relays.
  #mainAllowlist(relays: string[], entries: { entry: string; relay: string }[]): string[] {
    const theirs: string[] = [];
    for (const list of this.#theirs.values()) theirs.push(...list);
    return Mesh.#allowlist(relays, entries, theirs);
  }

  /// The main endpoint, bound as its user says (`MeshEnv`: what it takes, `relayOnly`, `lookup`).
  static #bindMain(
    env: MeshEnv,
    secret: Uint8Array,
    relays: string[],
    relayEntries: { entry: string; relay: string }[],
    relayAllowlist: string[],
  ): Effect.Effect<IrohEndpoint, CoreError> {
    const lookupActive = env.lookup === true && env.relayOnly !== true && relays.length > 0;
    return Mesh.#bind(env.iroh, secret, relays, env.relayOnly === true, env.lookup === true, env.takes, relayEntries, lookupActive ? relayAllowlist : undefined, lookupActive, env.dht?.() ?? true);
  }

  /// An endpoint: one at an address or on one relay alone looks nothing up (`lookup` only with a relay, and IP
  /// transports to go where what it found is).
  static #bind(
    iroh: Iroh,
    secret: Uint8Array,
    relays: string[],
    relayOnly = false,
    lookup = false,
    alpns: Uint8Array[] = [],
    relayEntries: { entry: string; relay: string }[] = [],
    relayAllowlist?: string[],
    allowPublicRelays = false,
    dht = true,
  ): Effect.Effect<IrohEndpoint, CoreError> {
    return Effect.mapError(
      iroh.bind({
        secretKey: secret,
        relayUrls: relays,
        lookup: lookup && !relayOnly && relays.length > 0,
        ...(dht ? {} : { dht: false }),
        relayOnly,
        ...(alpns.length > 0 ? { alpns } : {}),
        ...(relayEntries.length > 0 ? { relayEntries } : {}),
        ...(relayAllowlist !== undefined ? { relayAllowlist, allowPublicRelays } : {}),
      }),
      (e) => CoreError.plainly("mesh", e, t("core-logic.mesh.bind_failed")),
    );
  }

  /// The connections the main endpoint takes (`MeshEnv.takes`), each handed on, until it is closed (bound anew).
  #accepting(endpoint: IrohEndpoint): Effect.Effect<void> {
    const env = this.#env;
    const accept = endpoint.accept;
    if (!accept || !env.incoming || (env.takes ?? []).length === 0) return Effect.void;
    const self = this;
    return Effect.gen(function* () {
      for (;;) {
        const taken = yield* accept.call(endpoint);
        if (taken === null) return;
        // (bound over: what still comes to the old endpoint is not taken, its connections open on it let end)
        if (self.#endpoint !== endpoint) {
          taken.connection.close(0, "rebound");
          return;
        }
        self.#trackPeer(endpoint, taken.connection);
        env.incoming!(taken.connection, taken.alpn);
      }
    });
  }

  #openLinks(): [string, Link][] {
    const out: [string, Link][] = [];
    for (const [addr, o] of this.#links) if (o.result && "ok" in o.result && o.result.ok.usable()) out.push([addr, o.result.ok]);
    return out;
  }

  /// The station's link now, if one is open.
  current(addr: string): Link | null {
    const o = this.#links.get(addr);
    return o?.result && "ok" in o.result ? o.result.ok : null;
  }

  /// Runs a synchronous read/decision step with per-link snapshots of `paths()`, `stats()`, and `closeReason()` so
  /// repeated helpers inside one tick or `net()` reading cross the native FFI boundary at most once per link.
  #withSnap<T>(addr: string, fn: () => T, includeSiblings = false): T {
    const snapped = new Set<Link>();
    const cur = this.current(addr);
    if (cur !== null) snapped.add(cur);
    const ways = this.#ways.get(addr);
    if (ways !== undefined) for (const w of ways) snapped.add(w.link);
    if (includeSiblings) {
      const id = endpointId(addr);
      for (const [a, o] of this.#links) if (endpointId(a) === id && o.result && "ok" in o.result) snapped.add(o.result.ok);
    }
    for (const l of snapped) l.beginSnap();
    try {
      return fn();
    } finally {
      for (const l of snapped) l.endSnap();
    }
  }

  /// How the connection to `addr` runs now, snapping per-link FFI queries across `link.net()`, `measured()`, and `today()`.
  net(addr: string): LinkNet | null {
    const link = this.current(addr);
    if (link === null) return null;
    return this.#withSnap(addr, () => ({ ...link.net(), measured: this.measured(addr), today: this.today(addr), lan: this.lan(addr) }), true);
  }

  /// How `addr` is currently reached (`path` and `relay`), reading only the current link's paths.
  way(addr: string): { path: string | null; relay: string | null } | null {
    return this.current(addr)?.way() ?? null;
  }

  /// Where the station said it is on its LAN, none until it did.
  lan(addr: string): string[] {
    return this.#said[addr]?.lan ?? [];
  }

  /// Local connection diagnostics for `addr`: latest dial round, relay connection states, and known direct addresses.
  diag(addr: string): PeerDiag {
    const d = this.#diags.get(addr);
    return {
      at: d?.at ?? 0,
      relays: this.#endpoint.relayStatus().slice(0, 12),
      lan: this.lan(addr),
      tailnet: this.#said[addr]?.tailnet ?? [],
      attempts: d ? [...d.attempts] : [],
    };
  }

  /// What the station's links carried on this device today, both ways (in every workspace it is reached in).
  today(addr: string): [number, number] {
    const id = endpointId(addr);
    for (const [a, o] of this.#links) if (endpointId(a) === id && o.result && "ok" in o.result) this.#count(a, o.result.ok);
    const d = this.#days[id];
    return d && d.day === this.#localDay() ? [d.rx, d.tx] : [0, 0];
  }

  #count(addr: string, link: Link): void {
    const [rx, tx] = link.uncounted();
    if (rx === 0 && tx === 0) return;
    const today = this.#localDay();
    const id = endpointId(addr);
    let d = this.#days[id];
    if (!d || d.day !== today) {
      d = { day: today, rx: 0, tx: 0 };
      this.#days[id] = d;
    }
    d.rx += rx;
    d.tx += tx;
    this.#daysChanged = true;
  }

  #keepDays(): void {
    if (!this.#daysChanged) return;
    this.#daysChanged = false;
    const today = this.#localDay();
    for (const [id, d] of Object.entries(this.#days)) if (d.day !== today) delete this.#days[id];
    this.#env.runner.fork(Effect.ignore(this.#env.host.storageSet(NET_DAY_KEY, toJsonBytes(this.#days)), { log: "Unhandled", message: "net days kept" }));
  }

  /// How fast replies from a station came through a relay lately (bytes a second); null if none long enough did.
  speed(addr: string, relay: string): number | null {
    const s = this.#speeds[endpointId(addr)]?.[relayKey(relay)];
    if (s === undefined) return null;
    const ttl = s.bps < BULK_SLOW_BPS ? SPEED_SLOW_KEPT_MS : SPEED_KEPT_MS;
    return this.#env.host.nowMs() - s.at < ttl ? s.bps : null;
  }

  /// `bytes` from a station came through `relay` in `ms`. The fastest seen lately counts (SPEED_FRESH_MS): a reply also
  /// comes slower than its way could bring it (the station reading slowly); one seen before that is not kept against how
  /// the way brings replies now. The way the requests go on found slower than it was taken to be: they are moved at once
  /// if another is clearly better now (`#choose`), not after minutes more on it.
  noteSpeed(addr: string, relay: string, bytes: number, ms: number, forceSlow = false): void {
    if (ms <= 0 || bytes <= 0) return;
    const bps = (bytes / ms) * 1000;
    const slowEarly = (bytes >= SPEED_SLOW_MIN_BYTES || forceSlow) && ms >= SPEED_SLOW_MIN_MS && bps < BULK_SLOW_BPS;
    if (bytes < SPEED_MIN_BYTES && !slowEarly) return;
    const now = this.#env.host.nowMs();
    this.#saySpeed(addr, relay, bytes, ms, now);
    const id = endpointId(addr);
    const of = (this.#speeds[id] ??= {});
    const key = relayKey(relay);
    const sk = `${id} ${key}`;
    const was = of[key];
    const before = this.speed(addr, relay);
    let nextBps = bps;
    if (was !== undefined && now - was.at < SPEED_FRESH_MS && was.bps >= bps) {
      if (bps <= was.bps * 0.5) {
        const prev = this.#slowSeen.get(sk);
        if (bytes >= 2 * SPEED_MIN_BYTES || ms >= 5_000 || (prev !== undefined && now - prev.at < SPEED_FRESH_MS)) {
          nextBps = prev !== undefined ? Math.min(bps, Math.round(0.3 * was.bps + 0.7 * bps)) : Math.round(0.25 * was.bps + 0.75 * bps);
          this.#slowSeen.set(sk, { bps, at: now });
        } else {
          this.#slowSeen.set(sk, { bps, at: now });
          return;
        }
      } else {
        return;
      }
    } else {
      this.#slowSeen.delete(sk);
    }
    const slower = before === null || nextBps < before;
    of[key] = { bps: nextBps, at: now };
    for (const [sid, relays] of Object.entries(this.#speeds)) {
      for (const [r, s] of Object.entries(relays)) if (now - s.at >= (s.bps < BULK_SLOW_BPS ? SPEED_SLOW_KEPT_MS : SPEED_KEPT_MS)) delete relays[r];
      if (Object.keys(relays).length === 0) delete this.#speeds[sid];
    }
    this.#env.runner.fork(Effect.ignore(this.#env.host.storageSet(SPEED_KEY, toJsonBytes(this.#speeds)), { log: "Unhandled", message: "speeds kept" }));
    const via = this.current(addr)?.via() ?? null;
    if (slower && via !== null && relayKey(via) === key) this.#choose(addr, "slow");
    if (nextBps < BULK_SLOW_BPS) this.#maybeExploreBulk(addr);
  }

  /// A reply's speed on a way, told to telemetry (`mesh.speed`), at most once every
  /// SPEED_SAID_MS for each station and way: every one seen, slower ones too, not only the fastest that `noteSpeed`
  /// keeps, so the ways' speeds are seen as devices get them, network by network.
  #saySpeed(addr: string, way: string, bytes: number, ms: number, now: number): void {
    const key = relayKey(way);
    const said = `${endpointId(addr)} ${key}`;
    if (now - (this.#speedSaid.get(said) ?? -Infinity) < SPEED_SAID_MS) return;
    this.#speedSaid.set(said, now);
    const found = this.#live(addr).find((w) => w.link.speedKey() === key || w.key() === key);
    const span = this.#env.tracer.span("mesh.speed", Kind.Internal);
    span.own("station", endpointId(addr));
    span.own("via", relayHost(way));
    span.own("bytes", bytes);
    span.own("ms", Math.round(ms));
    span.own("bps", Math.round((bytes / ms) * 1000));
    if (found !== undefined) {
      span.own("current", found.link === this.current(addr));
      span.own("paths", found.link.paths());
    }
    span.end();
  }

  /// The speeds seen on every way let go (the device on another network now).
  #forgetSpeeds(): void {
    this.#slowSeen.clear();
    this.#bulkExploredAt.clear();
    if (Object.keys(this.#speeds).length === 0) return;
    for (const id of Object.keys(this.#speeds)) delete this.#speeds[id];
    this.#env.runner.fork(Effect.ignore(this.#env.host.storageSet(SPEED_KEY, toJsonBytes(this.#speeds)), { log: "Unhandled", message: "speeds kept" }));
  }

  /// A reply's body, timed as it is read: once it has brought SPEED_MIN_BYTES, periodically while reading large bodies,
  /// and again as it ends, how fast its way brought bytes meanwhile is noted for the way it came through: all that came
  /// through it from the station since this one began coming, not this one's alone. Replies side by side share the line,
  /// and each alone said a part of how fast it is: a phone's way to a station through a relay, held at a third of its
  /// speed, lost to ways never tried, each bringing its videos at 35 KB/s (2026-10-28). Told as it is under way, not
  /// after: a way found slow by a reply of megabytes is left at once (`noteSpeed`), not after it took minutes to come.
  timed(addr: string, way: string, body: Pull<Uint8Array>, isBulk = false): Pull<Uint8Array> {
    const key = `${endpointId(addr)} ${relayKey(way)}`;
    let first: number | null = null;
    let from = 0;
    let own = 0;
    let told = false;
    let lastOwn = 0;
    let lastCame = 0;
    let lastAt = 0;
    const minSlowBytes = isBulk ? SPEED_CRAWL_MIN_BYTES : SPEED_SLOW_MIN_BYTES;
    return {
      take: body.take.pipe(
        Effect.tapError(() =>
          isBulk && first !== null
            ? Effect.map(Clock.currentTimeMillis, (now) => {
                const elapsed = now - first!;
                if (elapsed >= SPEED_SLOW_MIN_MS) {
                  const came = this.#came.get(key) ?? from;
                  const bytes = Math.max(came - from, 1);
                  if ((bytes / elapsed) * 1000 < BULK_SLOW_BPS) {
                    this.noteSpeed(addr, way, bytes, elapsed, true);
                  }
                }
              })
            : Effect.void,
        ),
        Effect.flatMap((chunk) =>
          Effect.map(Clock.currentTimeMillis, (now) => {
            const came = (this.#came.get(key) ?? 0) + (chunk?.length ?? 0);
            this.#came.set(key, came);
            if (first === null) {
              if (chunk !== null) [first, from, lastAt, lastCame] = [now, came, now, came];
              return chunk;
            }
            own += chunk?.length ?? 0;
            const elapsed = now - first;
            const slowTotal =
              own >= minSlowBytes &&
              elapsed >= SPEED_SLOW_MIN_MS &&
              ((came - from) / Math.max(1, elapsed)) * 1000 < BULK_SLOW_BPS;
            if (chunk === null) {
              if (own >= SPEED_MIN_BYTES || (!told && slowTotal)) {
                this.noteSpeed(addr, way, came - from, elapsed, isBulk && slowTotal);
              }
            } else if (!told) {
              if (own >= SPEED_MIN_BYTES || slowTotal) {
                told = true;
                lastOwn = own;
                lastCame = came;
                lastAt = now;
                this.noteSpeed(addr, way, came - from, elapsed, isBulk && slowTotal);
              }
            } else if (now - lastAt >= 5_000) {
              const ownDelta = own - lastOwn;
              const bytes = came - lastCame;
              const ms = now - lastAt;
              const slowSlice = ownDelta >= minSlowBytes && (bytes / Math.max(1, ms)) * 1000 < BULK_SLOW_BPS;
              if (ownDelta >= SPEED_MIN_BYTES || slowSlice) {
                lastOwn = own;
                lastCame = came;
                lastAt = now;
                this.noteSpeed(addr, way, bytes, ms, isBulk && slowSlice);
              }
            }
            return chunk;
          }),
        ),
      ),
    };
  }

  #localDay(): number {
    const now = this.#env.host.nowMs();
    return localDay(now, this.#env.host.utcOffsetMin(now));
  }

  #isCurrent(addr: string, link: Link): boolean {
    return this.current(addr) === link;
  }

  #dropIf(addr: string, link: Link): void {
    if (this.#isCurrent(addr, link)) this.dropLink(addr);
  }

  #notify(): void {
    const waiting = this.#changed;
    this.#changed = [];
    for (const d of waiting) Deferred.doneUnsafe(d, Effect.void);
  }

  /// Succeeds once `link` is no longer the station's link (another put in its place, or it was dropped).
  replaced(addr: string, link: Link): Effect.Effect<void> {
    return Effect.suspend(() => {
      const loop: Effect.Effect<void> = Effect.suspend(() => {
        if (!this.#isCurrent(addr, link)) return Effect.void;
        const d = Deferred.makeUnsafe<void>();
        this.#changed.push(d);
        return Effect.andThen(Deferred.await(d), loop);
      });
      return loop;
    });
  }

  /// Puts `next` in place of `old` (if `old` still is), and retires `old`: no more a way to go back to (its link lost
  /// meanwhile, requests went back on it and it was closed under them, 2026-10-15), closed RETIRE_MS later.
  #switch(addr: string, old: Link, next: Link, control?: DialControl): void {
    if (!this.#isCurrent(addr, old) || this.#closed || this.#wayOff(addr, next)) {
      cancelDial(control);
      next.close();
      if (this.#dialing === 0) this.#env.runner.fork(this.#letGo());
      return;
    }
    const prev = this.#links.get(addr);
    if (prev?.controls) for (const c of prev.controls) cancelDial(c);
    const done = Deferred.makeUnsafe<Link, CoreError>();
    Deferred.doneUnsafe(done, Effect.succeed(next));
    this.#links.set(addr, { done, result: { ok: next }, controls: control ? [control] : [] });
    this.#retire(addr, (this.#ways.get(addr) ?? []).find((w) => w.link === old) ?? new Way(old));
    this.#adopt(addr, next);
    commitDial(control);
    this.#notify();
  }

  deviceId(): string {
    return this.#endpoint.id();
  }

  /// Whether a view's sound may be asked as Opus: what taps it decodes it (IrohEndpoint `opus`).
  decodesOpus(): boolean {
    return this.#endpoint.opus?.() === true;
  }

  /// A token a stream may take the frames the other end sends as datagrams under (`Link.duplex`'s `media`), drawn at
  /// random; 0 where the host's streams take none (IrohEndpoint `mediaDatagrams`).
  mediaToken(): number {
    if (this.#endpoint.mediaDatagrams?.() !== true) return 0;
    const b = new Uint8Array(4);
    this.#env.host.randomBytes(b);
    return (((b[0]! << 24) | (b[1]! << 16) | (b[2]! << 8) | b[3]!) >>> 0) || 1;
  }

  /// `message` signed with the device key (an Ed25519 seed), and that key's public half: by the host where it signs
  /// (Host.ed25519Sign: a native app's shell), else here. What this device says is its own (the still.fail core's: that
  /// an endpoint is, to a station with a workspace lock, lock.ts `claimBy`).
  sign(message: Uint8Array): { publicKey: Uint8Array; signature: Uint8Array } {
    const signed = this.#env.host.ed25519Sign?.(this.#secret, message);
    if (signed) return signed;
    return { publicKey: ed25519.getPublicKey(this.#secret), signature: ed25519.sign(message, this.#secret) };
  }

  /// This device's clock.
  now(): number {
    return this.#env.host.nowMs();
  }

  /// The main endpoint as it is bound now, for its user's own connections: what it dials is counted as the endpoint in
  /// use (`#trackPeer`), so it is not bound over beneath them nor closed while they are open. The same object until
  /// it is bound anew.
  endpoint(): IrohEndpoint {
    const e = this.#endpoint;
    let shown = this.#shown.get(e);
    if (shown === undefined) {
      const self = this;
      const connect: IrohEndpoint["connect"] = (addr, alpn, additional, givenUp) => Effect.tap(e.connect(addr, alpn, additional, givenUp), (conn) => Effect.sync(() => self.#trackPeer(e, conn)));
      // (every other part of it the endpoint's own, called on it)
      shown = new Proxy(e, {
        get: (target, key) => {
          if (key === "connect") return connect;
          const v = Reflect.get(target, key, target);
          return typeof v === "function" ? v.bind(target) : v;
        },
      });
      this.#shown.set(e, shown);
    }
    return shown;
  }

  /// A connection of its user's on `endpoint`, counted while it is open.
  #trackPeer(endpoint: IrohEndpoint, conn: IrohConnection): void {
    if (conn.closeReason() !== null) return;
    let peers = this.#peers.get(endpoint);
    if (peers === undefined) {
      peers = new Set();
      this.#peers.set(endpoint, peers);
    }
    peers.add(conn);
    const held = peers;
    this.#env.runner.fork(Effect.andThen(conn.closed(), Effect.sync(() => { held.delete(conn); })));
  }

  /// Whether a connection of its user's is open on `endpoint`.
  #peersOpen(endpoint: IrohEndpoint): boolean {
    const peers = this.#peers.get(endpoint);
    if (peers === undefined) return false;
    let open = false;
    for (const c of [...peers]) {
      if (c.closeReason() !== null) peers.delete(c);
      else open = true;
    }
    return open;
  }

  /// An endpoint bound over closed: at once, or once its user's connections on it ended (a pairing under way on it is
  /// not cut).
  #closeOld(old: IrohEndpoint): void {
    const peers = [...(this.#peers.get(old) ?? [])].filter((c) => c.closeReason() === null);
    if (peers.length === 0) {
      this.#env.runner.fork(old.close());
      return;
    }
    this.#retired.add(old);
    const self = this;
    this.#env.runner.fork(
      Effect.ensuring(
        Effect.gen(function* () {
          yield* Effect.forEach(peers, (c) => c.closed(), { concurrency: "unbounded", discard: true });
          if (!self.#closed) yield* old.close();
        }),
        Effect.sync(() => {
          self.#retired.delete(old);
        }),
      ),
    );
  }

  /// Tells this endpoint, and each bound after it, where a station is (no relay: tests, a LAN).
  addAddr(addr: import("./iroh.ts").IrohAddr): void {
    this.#endpoint.addAddr(addr);
    this.#known.push(addr);
  }

  #anyOpen(): boolean {
    return this.#openLinks().length > 0 || this.#peersOpen(this.#endpoint);
  }

  /// The endpoint bound anew with the same key, the old one closed: at most once in REBIND_MS (`always`: whenever).
  #rebind(always = false): Effect.Effect<IrohEndpoint> {
    return Effect.gen({ self: this }, function* () {
      if (this.#closed) return this.#endpoint;
      if (this.#rebinding !== null) {
        if (always) this.#rebindAgain = true;
        return yield* Deferred.await(this.#rebinding);
      }
      const now = this.#env.host.nowMs();
      if (!always && now - this.#reboundAt < REBIND_MS) {
        record(this.#env.host, "conn rebind", () => `skipped: ${Math.round(now - this.#reboundAt)}ms since the last (REBIND_MS)`);
        return this.#endpoint;
      }
      this.#reboundAt = now;
      const d = Deferred.makeUnsafe<IrohEndpoint>();
      this.#rebinding = d;
      const self = this;
      this.#env.runner.fork(
        Effect.ensuring(
          Effect.gen(function* () {
            const routes = entryRoutes(self.relays, self.entries, self.entryTargets);
            const allowlist = self.#mainAllowlist(self.relays, routes);
            const bound = yield* Effect.result(Mesh.#bindMain(self.#env, self.#secret, self.relays, routes, allowlist));
            record(self.#env.host, "conn rebind", () => `${always ? "relays retold" : "a dial unanswered, nothing open"} -> ${bound._tag === "Failure" ? `failed: ${said(bound.failure.message)}` : "bound"}`);
            if (bound._tag === "Failure") {
              Deferred.doneUnsafe(d, Effect.succeed(self.#endpoint));
              return;
            }
            const endpoint = bound.success;
            if (self.#closed) {
              self.#env.runner.fork(endpoint.close());
              Deferred.doneUnsafe(d, Effect.succeed(self.#endpoint));
              return;
            }
            self.#env.runner.fork(self.#accepting(endpoint));
            for (const addr of self.#known) endpoint.addAddr(addr);
            const old = self.#endpoint;
            self.#endpoint = endpoint;
            self.#endpointRemoved.clear();
            self.#appliedDisabled.clear();
            self.#hot.clear();
            self.#relaxedAt.clear();
            self.#syncDirty = false;
            self.#stuck = false;
            self.#closeOld(old);
            Deferred.doneUnsafe(d, Effect.succeed(endpoint));
          }),
          Effect.sync(() => {
            Deferred.doneUnsafe(d, Effect.succeed(self.#endpoint));
            if (self.#rebinding === d) self.#rebinding = null;
            if (self.#rebindAgain && !self.#closed) {
              self.#rebindAgain = false;
              self.#env.runner.fork(Effect.asVoid(self.#rebind(true)));
            } else if (self.#closed) {
              self.#rebindAgain = false;
            }
          }),
        ),
      );
      return yield* Deferred.await(d);
    });
  }

  /// Told its lookup changed (`MeshEnv.dht`): the main endpoint bound anew as it now says, the links on it closed.
  relook(): void {
    if (!this.#closed) this.#env.runner.fork(Effect.asVoid(this.#rebind(true)));
  }

  /// Told the relays and entries anew: the first `/v1/me` of a run, after the mesh came up on those it kept from the last
  /// (a cloud from before `relay_entries` had the entries among the relays). Dialled as told from now on; the endpoint
  /// is bound anew on the new relays if its were others, the links on it closed (an entry among its relays would keep it
  /// on that entry's relay twice).
  retune(relays: string[], entries: string[], targets: Record<string, string> = {}): void {
    const same = (a: string[], b: string[]) => a.length === b.length && a.every((r, i) => sameRelay(r, b[i]!));
    const fresh = entries.filter((e) => !relays.some((r) => sameRelay(r, e)));
    const beforeRoutes = entryRoutes(this.relays, this.entries, this.entryTargets);
    const afterRoutes = entryRoutes(relays, fresh, targets);
    const sameRoutes = beforeRoutes.length === afterRoutes.length && beforeRoutes.every((r, i) => sameRelay(r.entry, afterRoutes[i]!.entry) && sameRelay(r.relay, afterRoutes[i]!.relay));
    if (this.#closed || (same(this.relays, relays) && same(this.entries, fresh) && sameRoutes)) return;
    const rebind = !same(this.relays, relays);
    this.relays = relays;
    this.entries = fresh;
    this.entryTargets = targets;
    this.#deadRelays.clear();
    this.#deadRelayFails.clear();
    this.#handshakeRescueCooldown.clear();
    this.#relaxAllState();
    if (rebind) this.#env.runner.fork(Effect.asVoid(this.#rebind(true)));
    else if (!sameRoutes) {
      const setEntries = this.#endpoint.setRelayEntries?.bind(this.#endpoint);
      if (setEntries) {
        const update = this.#hasHotMode() ? Effect.andThen(setEntries(afterRoutes), this.#syncRelaysNow()) : setEntries(afterRoutes);
        this.#env.runner.fork(Effect.catch(update, () => Effect.asVoid(this.#rebind(true))));
      } else this.#env.runner.fork(Effect.asVoid(this.#rebind(true)));
    } else this.#scheduleSyncRelays();
  }

  /// The relays a station is dialled and measured on: still.fail's, then its workspace's own. The endpoint stays bound
  /// to still.fail's alone (one that does not answer there would leave it with no home); another relay is reached as
  /// the station's, or on its own endpoint once measured quicker.
  relaysFor(addr: string): string[] {
    const theirs = this.#theirs.get(addr) ?? [];
    return [...this.relays, ...theirs.filter((r) => !this.relays.some((o) => sameRelay(o, r)))].filter((r) => !this.#isOff(addr, r));
  }

  /// Every way a station is dialled through: its relays (`relaysFor`), then the entries (`entries`) but those through
  /// a relay its workspace turned off (`#entryOff`); none while it turned all of still.fail's off.
  #waysFor(addr: string): string[] {
    const relays = this.relaysFor(addr);
    if (this.#isOff(addr, "ours")) return relays;
    return [...relays, ...this.entries.filter((e) => !relays.some((r) => sameRelay(r, e)) && !this.#entryOff(addr, e))];
  }

  /// Whether an entry goes through a relay the station's workspace turned off: the one it leads to
  /// (`entryTargets`), or the one whose machine it is on (an entry is a port of a relay's machine: `https://<its
  /// host>:8443`). Those turned off alone took every entry with them, and a workspace that turned its relays in China
  /// off lost Beijing's way into Hong Kong's as well as the punched paths (2026-11-16).
  #entryOff(addr: string, entry: string): boolean {
    const target = Object.entries(this.entryTargets).find(([url]) => sameRelay(url, entry))?.[1];
    if (target !== undefined && this.#isOff(addr, target)) return true;
    const host = hostOf(entry);
    return this.relays.some((r) => this.#isOff(addr, r) && host !== null && hostOf(r) === host);
  }

  /// The fence the station is dialled in (`FENCED`) while it is not dialled on the main endpoint, where its workspace
  /// leaves paths punched through on: the relays it is dialled through, the entries not among them (each a way to a
  /// relay's own endpoint, which iroh does not take as a home). Null where it does not (the main endpoint dialled,
  /// direct ways turned off, a mesh through relays alone, no relay left).
  #fence(addr: string): string | null {
    if (this.#mainOn(addr) || this.#isOff(addr, DIRECT) || this.#env.relayOnly === true) return null;
    const relays = this.relaysFor(addr);
    if (relays.length === 0) return null;
    const fence = fencedOf(relays);
    if (!this.#fences.has(fence)) this.#fences.set(fence, relays);
    return fence;
  }

  /// Whether the station's workspace turned `way` off (a relay, or a kind of way: LAN, TAILNET, DIRECT, or `ours` for
  /// all of still.fail's relays). A mesh through relays alone (`MeshEnv.relayOnly`) has the ways at an address off for
  /// every station.
  #isOff(addr: string, way: string): boolean {
    if (this.#env.relayOnly === true && (way === LAN || way === TAILNET)) return true;
    const off = this.#off.get(addr) ?? [];
    if (off.includes("ours") && (way === "ours" || this.relays.some((o) => sameRelay(o, way)))) return true;
    return off.some((o) => o === way || sameRelay(o, way));
  }

  /// Whether the station is dialled on the main endpoint: not while its workspace turned off any relay it is at home on
  /// (still.fail's; which one it is on is iroh's to choose, and the station's answers come there) or the paths iroh
  /// punches through, which the main endpoint alone goes on. Each relay left is reached on its own endpoint then.
  #mainOn(addr: string): boolean {
    return !this.#isOff(addr, DIRECT) && !this.#isOff(addr, "ours") && !this.relays.some((r) => this.#isOff(addr, r));
  }

  /// Whether a way open to the station goes a way its workspace turned off.
  #wayOff(addr: string, link: Link): boolean {
    const pinned = link.pinned;
    if (pinned === null) return !this.#mainOn(addr);
    if (pinned === LAN || pinned === TAILNET) return this.#isOff(addr, pinned);
    if (isFenced(pinned)) return pinned !== this.#fence(addr);
    return !this.#waysFor(addr).some((r) => sameRelay(r, pinned));
  }

  /// Told the peer's own relays (`theirs`) and the ways turned off for it (`off`), as they change: what `link` is given,
  /// told as soon as it is known, not only with the next request. Each way open to it that goes a way it may not now is
  /// closed; the requests on such a one move first to a way open that it may go and that answers its pings, and where
  /// none is, the peer is dialled again at once on the ways it may go (the requests on it, if any, go on that: `link`).
  setWays(addr: string, theirs?: readonly string[], off?: readonly string[]): void {
    this.#setWays(addr, theirs, off, true);
  }

  /// `setWays`; not `redial` where a request is opening the link itself (`link`), which dials it.
  #setWays(addr: string, theirs: readonly string[] | undefined, off: readonly string[] | undefined, redial: boolean): void {
    const wasMainOn = this.#mainOn(addr);
    let changed = false;
    let more = false;
    if (theirs !== undefined) {
      const was = this.#theirs.get(addr) ?? [];
      changed = was.length !== theirs.length || was.some((r, i) => r !== theirs[i]);
      more = theirs.some((r) => !was.some((w) => sameRelay(w, r)));
      this.#theirs.set(addr, [...theirs]);
    }
    if (off !== undefined) {
      const was = this.#off.get(addr) ?? [];
      if (was.length !== off.length || was.some((o, i) => o !== off[i])) {
        changed = true;
        // (a way turned on again is one more to dial)
        more ||= was.some((o) => !off.includes(o));
        if (off.length > 0) this.#off.set(addr, [...off]);
        else this.#off.delete(addr);
      }
    }
    if (!changed) return;
    if (!wasMainOn && this.#mainOn(addr)) this.#mainDialledAt.set(addr, this.now());
    this.#handshakeRescueCooldown.delete(addr);
    this.#relaxStationState(endpointId(addr));
    const cur = this.current(addr);
    const curOff = cur !== null && cur.usable() && this.#wayOff(addr, cur);
    if (curOff) {
      const allowed = this.#live(addr).filter((w) => w.link !== cur && w.missed < DEAD_PINGS && !this.#wayOff(addr, w.link));
      const fresh = allowed.filter((w) => w.missed === 0);
      const best = this.#best(addr, this.#takeable(addr, fresh.length > 0 ? fresh : allowed));
      if (best !== null) this.#promote(addr, best, "off");
    }
    // Each way it may not go now closed and let go of, with what came over it counted.
    const ways = this.#ways.get(addr) ?? [];
    const gone = ways.filter((w) => this.#wayOff(addr, w.link));
    for (const w of gone) {
      w.link.close();
      this.#count(addr, w.link);
    }
    if (gone.length > 0) {
      const left = ways.filter((w) => !gone.includes(w));
      if (left.length > 0) this.#ways.set(addr, left);
      else this.#ways.delete(addr);
    }
    const curGone = cur !== null && cur.usable() && this.#wayOff(addr, cur);
    if (curGone) {
      cur.close();
      this.#count(addr, cur);
    }
    const closed = gone.length > 0 || curGone;
    if (redial && !this.#closed) {
      if (curOff && this.current(addr) === cur) {
        // None left to go on: dialled again now on the ways it may go, not as the next request finds it gone; the relay
        // endpoints none goes on then let go.
        this.#env.runner.fork(Effect.andThen(Effect.ignore(this.link(addr, cur.credentials, undefined, undefined, "again"), { log: "Unhandled", message: "link opened" }), this.#letGo()));
      } else if (this.#links.get(addr)?.result === null) {
        // Being opened on the ways of before: tried beside on the ways it may go now (the first through on a way it may
        // not go is let go: `link`).
        const h = this.#hedges.get(addr);
        if (h?.tx) {
          const tx = h.tx;
          h.tx = null;
          this.#env.runner.fork(this.#hedge(addr, h.credentials, tx, h.control));
        }
      } else if (more && cur !== null && cur.usable()) {
        // A way more it may go (a relay of its own added, one turned on again): dialled now, not at the next EXPLORE_MS;
        // on the main endpoint, iroh told of the relays it is on.
        if (this.#mainOn(addr)) {
          const nextAddr = { id: endpointId(addr), relays: this.relaysFor(addr), ips: this.#straightAt(addr) };
          if (this.#hasHotMode()) {
            this.#env.runner.fork(
              Effect.andThen(
                this.#syncRelaysNow(),
                Effect.sync(() => {
                  if (!this.#closed) this.#endpoint.addAddr(nextAddr);
                }),
              ),
            );
          } else this.#endpoint.addAddr(nextAddr);
        } else {
          this.#exploredAt.delete(addr);
          this.#env.runner.fork(this.#explore(addr, cur.credentials));
        }
      }
      if (closed) this.#env.runner.fork(this.#letGo());
    }
    this.#scheduleSyncRelays();
    // (a way turned on again is one more to choose between)
    this.#steerIf(addr);
  }

  #hasRelayControls(endpoint: IrohEndpoint = this.#endpoint): boolean {
    return (
      typeof endpoint.setDisabledRelays === "function" &&
      typeof endpoint.insertRelay === "function" &&
      typeof endpoint.removeRelay === "function"
    );
  }

  #hasHotMode(): boolean {
    if (!this.#hasRelayControls()) return false;
    const active = this.#env.hotRelays;
    const idle = this.#env.idleHotRelays;
    return (typeof active === "number" && active > 0) || (typeof idle === "number" && idle > 0 && typeof this.#env.idle === "function");
  }

  #isIdle(addr: string): boolean {
    return this.#env.idle?.(addr) === true;
  }

  #stationIdle(id: string): boolean {
    const check = this.#env.idle;
    if (typeof check !== "function") return false;
    let any = false;
    for (const [a, o] of this.#links) {
      if (endpointId(a) !== id) continue;
      if (o.result === null) return false;
      if ("ok" in o.result && o.result.ok.usable()) {
        any = true;
        if (!check(a)) return false;
      }
    }
    return any;
  }

  #hotBudgetFor(id: string): number {
    if (!this.#hasRelayControls()) return 0;
    const idle = this.#env.idleHotRelays;
    if (typeof idle === "number" && idle > 0 && this.#stationIdle(id)) return Math.floor(idle);
    const active = this.#env.hotRelays;
    if (typeof active === "number" && active > 0) return Math.floor(active);
    return 0;
  }

  #wakeSteer(addr: string): void {
    const wake = this.#steerWakes.get(addr);
    if (wake !== undefined) {
      this.#steerWakes.delete(addr);
      Deferred.doneUnsafe(wake, Effect.void);
    }
  }

  /// Re-evaluates idle state for `addr` (or every linked station): an idle station turning active wakes its steer
  /// timer and relaxes its narrowed relays at once.
  refreshIdle(addr?: string): void {
    if (this.#closed) return;
    const addrs = addr !== undefined ? [addr] : [...this.#links.keys()];
    for (const a of addrs) {
      if (this.#isIdle(a)) continue;
      this.#wakeSteer(a);
      const id = endpointId(a);
      const hot = this.#hot.get(id);
      if (hot !== undefined) {
        const budget = this.#hotBudgetFor(id);
        if (budget <= 0 || hot.size < budget) this.#relaxStation(id);
      }
    }
  }

  #logicalRelay(url: string): string {
    const target = Object.entries(this.entryTargets).find(([entry]) => sameRelay(entry, url))?.[1];
    return relayKey(target ?? url);
  }

  #hasStationLinks(id: string): boolean {
    for (const [a] of this.#links) if (endpointId(a) === id) return true;
    return false;
  }

  #activeStationIds(): Set<string> {
    const ids = new Set<string>();
    for (const [a] of this.#links) ids.add(endpointId(a));
    return ids;
  }

  #openMainStationIds(): Set<string> {
    const ids = new Set<string>();
    for (const [a, l] of this.#openLinks()) if (l.pinned === null && this.#mainOn(a)) ids.add(endpointId(a));
    return ids;
  }

  /// A station participates in hot-relay narrowing only when it has at least one open link, no opening in flight, every
  /// open link and backup way of it is on the main endpoint (`pinned === null`), and every workspace with a link entry for
  /// it has an empty `off` list (nothing turned off: official relays, custom relays, `direct`, `lan`, `tailnet`, `ours`).
  #stationEligibleForHot(id: string): boolean {
    let hasOpen = false;
    for (const [a, o] of this.#links) {
      if (endpointId(a) !== id) continue;
      if ((this.#off.get(a)?.length ?? 0) > 0 || !this.#mainOn(a)) return false;
      if (o.result === null) return false;
      if ("ok" in o.result && o.result.ok.usable()) {
        if (o.result.ok.pinned !== null) return false;
        hasOpen = true;
      }
      for (const w of this.#live(a)) {
        if (w.link.pinned !== null) return false;
      }
    }
    return hasOpen;
  }

  #allCandidateRelaysForStation(id: string): string[] {
    const seen = new Set<string>();
    const out: string[] = [];
    const add = (url: string) => {
      const k = relayKey(url);
      if (seen.has(k)) return;
      seen.add(k);
      out.push(url);
    };
    for (const r of this.relays) add(r);
    for (const e of this.entries) add(e);
    for (const [a, o] of this.#links) {
      if (endpointId(a) !== id) continue;
      for (const r of this.#theirs.get(a) ?? []) add(r);
      if (o.result && "ok" in o.result && o.result.ok.pinned === null && o.result.ok.usable()) {
        for (const p of o.result.ok.conn.paths()) if (p.relay !== null) add(p.relay);
      }
    }
    return out;
  }

  #desiredDisabledForStation(id: string): string[] {
    const hot = this.#hot.get(id);
    if (hot === undefined || this.#hotBudgetFor(id) <= 0 || !this.#stationEligibleForHot(id)) return [];
    return this.#allCandidateRelaysForStation(id).filter((u) => !hot.has(this.#logicalRelay(u)));
  }

  #wantedRelays(): string[] {
    if (
      this.#mainDialing > 0 ||
      this.#dialing > 0 ||
      (this.#env.takes?.length ?? 0) > 0 ||
      [...this.#links.values()].some((o) => o.result === null)
    ) {
      return [...this.relays];
    }
    const mainStations = this.#openMainStationIds();
    if (mainStations.size === 0) return [...this.relays];
    const union = new Set<string>();
    for (const id of mainStations) {
      const hot = this.#hot.get(id);
      if (hot === undefined) return [...this.relays];
      for (const k of hot) union.add(k);
    }
    return this.relays.filter((r) => union.has(relayKey(r)));
  }

  #syncRelaysNow(): Effect.Effect<void> {
    if (this.#closed || !this.#hasHotMode()) return Effect.void;
    this.#syncDirty = true;
    return this.#syncLock.withPermits(1)(
      Effect.gen({ self: this }, function* () {
        while (this.#syncDirty && !this.#closed && this.#hasHotMode()) {
          this.#syncDirty = false;
          const endpoint = this.#endpoint;
          if (!this.#hasRelayControls(endpoint)) return;

          const stationIds = new Set<string>([
            ...this.#activeStationIds(),
            ...this.#appliedDisabled.keys(),
          ]);
          for (const id of stationIds) {
            if (this.#closed || this.#endpoint !== endpoint) break;
            const disabled = this.#desiredDisabledForStation(id);
            const key = disabled.map(relayKey).sort().join(" ");
            const prev = this.#appliedDisabled.get(id) ?? "";
            if (key === prev) {
              if (key === "") this.#appliedDisabled.delete(id);
              continue;
            }
            const res = yield* Effect.result(endpoint.setDisabledRelays!(id, disabled));
            if (this.#endpoint !== endpoint) break;
            if (res._tag === "Success") {
              if (key === "") this.#appliedDisabled.delete(id);
              else this.#appliedDisabled.set(id, key);
            } else {
              record(this.#env.host, "conn hot", () => `setDisabledRelays(${id.slice(0, 8)}) failed: ${said(res.failure.message)}`);
            }
          }
          if (this.#closed || this.#endpoint !== endpoint || this.#syncDirty) continue;

          const wantedKeys = new Set(this.#wantedRelays().map(relayKey));
          for (const r of this.relays) {
            if (this.#closed || this.#endpoint !== endpoint || this.#syncDirty) break;
            const k = relayKey(r);
            if (!wantedKeys.has(k) || !this.#endpointRemoved.has(k)) continue;
            const res = yield* Effect.result(endpoint.insertRelay!(r));
            if (this.#endpoint !== endpoint) break;
            if (res._tag === "Success") {
              this.#endpointRemoved.delete(k);
            } else {
              record(this.#env.host, "conn hot", () => `insertRelay(${relayHost(r)}) failed: ${said(res.failure.message)}`);
            }
          }
          if (this.#closed || this.#endpoint !== endpoint || this.#syncDirty) continue;

          const wantedAfter = new Set(this.#wantedRelays().map(relayKey));
          for (const r of this.relays) {
            if (this.#closed || this.#endpoint !== endpoint || this.#syncDirty) break;
            const k = relayKey(r);
            if (wantedAfter.has(k) || this.#endpointRemoved.has(k)) continue;
            const res = yield* Effect.result(endpoint.removeRelay!(r));
            if (this.#endpoint !== endpoint) break;
            if (res._tag === "Success") {
              this.#endpointRemoved.add(k);
            } else {
              record(this.#env.host, "conn hot", () => `removeRelay(${relayHost(r)}) failed: ${said(res.failure.message)}`);
            }
          }
        }
      }),
    );
  }

  #scheduleSyncRelays(): void {
    if (this.#closed || !this.#hasHotMode()) return;
    this.#env.runner.fork(this.#syncRelaysNow());
  }

  #disconnectedOfficialRelayKeys(): Set<string> {
    const out = new Set<string>();
    for (const s of this.#endpoint.relayStatus()) {
      if (!s.connected) out.add(relayKey(s.url));
    }
    return out;
  }

  #relaxStationState(id: string): void {
    if (!this.#hasHotMode()) return;
    this.#hot.delete(id);
    if (this.#hasStationLinks(id)) this.#relaxedAt.set(id, this.now());
    else this.#relaxedAt.delete(id);
    this.#syncDirty = true;
  }

  #relaxStation(id: string): void {
    if (!this.#hasHotMode()) return;
    this.#relaxStationState(id);
    this.#scheduleSyncRelays();
  }

  #relaxStationNow(id: string): Effect.Effect<void> {
    if (!this.#hasHotMode()) return Effect.void;
    this.#relaxStationState(id);
    return this.#syncRelaysNow();
  }

  #relaxAllState(): void {
    if (!this.#hasHotMode()) return;
    const now = this.now();
    this.#hot.clear();
    this.#relaxedAt.clear();
    for (const id of this.#activeStationIds()) this.#relaxedAt.set(id, now);
    this.#syncDirty = true;
  }

  #relaxAll(): void {
    if (!this.#hasHotMode()) return;
    this.#relaxAllState();
    this.#scheduleSyncRelays();
  }

  #pickHotForStation(id: string): void {
    const budget = this.#hotBudgetFor(id);
    if (budget <= 0 || this.#hot.has(id)) return;
    if (!this.#stationEligibleForHot(id)) return;
    const now = this.now();
    if (now - (this.#relaxedAt.get(id) ?? -Infinity) < HOT_SETTLE_MS) return;
    const mainLinks: [string, Link][] = [];
    for (const [a, o] of this.#links) {
      if (endpointId(a) !== id) continue;
      if (o.result === null || (this.#off.get(a)?.length ?? 0) > 0 || !this.#mainOn(a)) return;
      if (!("ok" in o.result) || !o.result.ok.usable()) continue;
      const l = o.result.ok;
      if (l.pinned !== null) return;
      if (this.#racing.has(a) || this.#exploring.has(a)) return;
      if (now - l.openedAt < HOT_SETTLE_MS) return;
      const w = this.#live(a).find((x) => x.link === l);
      if (w === undefined || w.missed !== 0 || w.samples < MIN_SAMPLES) return;
      mainLinks.push([a, l]);
    }
    if (mainLinks.length === 0) return;

    const disconnectedOfficial = this.#disconnectedOfficialRelayKeys();
    const perLinkPicks: string[][] = [];
    const bestRttByKey = new Map<string, number>();
    const selectedAcrossLinks = new Set<string>();
    const urlByKey = new Map<string, string>();

    for (const [a, l] of mainLinks) {
      const allowedUrls = this.relaysFor(a);
      const allowed = new Set(allowedUrls.map(relayKey));
      const measuredByKey = new Map<string, { key: string; url: string; rttMs: number; selected: boolean }>();
      for (const p of l.connPaths()) {
        if (p.relay === null || p.rttMs === null) continue;
        const k = this.#logicalRelay(p.relay);
        if (!allowed.has(k) || disconnectedOfficial.has(k)) continue;
        const canonical = allowedUrls.find((r) => relayKey(r) === k) ?? p.relay;
        urlByKey.set(k, canonical);
        const prev = measuredByKey.get(k);
        if (prev === undefined || p.selected || (!prev.selected && p.rttMs < prev.rttMs)) {
          measuredByKey.set(k, { key: k, url: canonical, rttMs: p.rttMs, selected: p.selected || (prev?.selected ?? false) });
        }
        const best = bestRttByKey.get(k);
        if (best === undefined || p.rttMs < best) bestRttByKey.set(k, p.rttMs);
      }
      if (measuredByKey.size < budget) return;

      const ordered = [...measuredByKey.values()].sort((x, y) => x.rttMs - y.rttMs);
      const picked: string[] = [];
      const pickedHosts = new Set<string>();
      const addPick = (item: { key: string; url: string; selected: boolean }) => {
        if (picked.includes(item.key)) return;
        picked.push(item.key);
        const h = hostOf(item.url);
        if (h !== null) pickedHosts.add(h);
        if (item.selected) selectedAcrossLinks.add(item.key);
      };
      const sel = ordered.find((x) => x.selected);
      if (sel !== undefined) addPick(sel);
      for (const item of ordered) {
        if (picked.length >= budget) break;
        const h = hostOf(item.url);
        if (h !== null && pickedHosts.has(h)) continue;
        addPick(item);
      }
      for (const item of ordered) {
        if (picked.length >= budget) break;
        addPick(item);
      }
      if (picked.length < budget) return;
      perLinkPicks.push(picked);
    }

    const unionSet = new Set<string>();
    for (const picked of perLinkPicks) for (const k of picked) unionSet.add(k);
    let finalKeys = [...unionSet];
    if (finalKeys.length > budget) {
      finalKeys.sort((ka, kb) => {
        const sa = selectedAcrossLinks.has(ka) ? 0 : 1;
        const sb = selectedAcrossLinks.has(kb) ? 0 : 1;
        if (sa !== sb) return sa - sb;
        return (bestRttByKey.get(ka) ?? Infinity) - (bestRttByKey.get(kb) ?? Infinity);
      });
      finalKeys = finalKeys.slice(0, budget);
    }
    const chosen = new Set(finalKeys);
    if (!this.#allCandidateRelaysForStation(id).some((u) => !chosen.has(this.#logicalRelay(u)))) return;
    this.#hot.set(id, chosen);
    this.#relaxedAt.delete(id);
    record(this.#env.host, "conn hot", () => `${id.slice(0, 8)} narrowed -> ${[...chosen].map((k) => relayHost(urlByKey.get(k) ?? k)).join(", ")}`);
    this.#scheduleSyncRelays();
  }

  #updateHotOnTick(addr: string): Effect.Effect<void> {
    if (!this.#hasHotMode()) return Effect.void;
    const id = endpointId(addr);
    const budget = this.#hotBudgetFor(id);
    if (budget <= 0 || !this.#stationEligibleForHot(id)) {
      if (this.#hot.has(id)) return this.#relaxStationNow(id);
      return Effect.void;
    }
    const cur = this.current(addr);
    const ways = this.#live(addr);
    const mine = ways.find((w) => w.link === cur);
    if (cur === null || !cur.usable() || mine === undefined || mine.missed >= 1) {
      if (this.#hot.has(id) || mine?.missed === 1) return this.#relaxStationNow(id);
      return Effect.void;
    }
    const hot = this.#hot.get(id);
    if (hot !== undefined) {
      if (hot.size < budget) return this.#relaxStationNow(id);
      if (hot.size > budget) {
        this.#hot.delete(id);
        this.#pickHotForStation(id);
        return Effect.void;
      }
      const disconnectedOfficial = this.#disconnectedOfficialRelayKeys();
      const liveInHot = new Set<string>();
      for (const p of cur.connPaths()) {
        if (p.relay === null) continue;
        const k = this.#logicalRelay(p.relay);
        if (disconnectedOfficial.has(k)) continue;
        if (hot.has(k)) liveInHot.add(k);
      }
      if (liveInHot.size < Math.min(budget, hot.size)) return this.#relaxStationNow(id);
      return Effect.void;
    }
    this.#pickHotForStation(id);
    return Effect.void;
  }

  #dialMain(
    addr: string,
    endpoint: IrohEndpoint,
    relays: string[],
    credentials: CredentialSource,
    fresh: boolean,
    ctx: SpanContext | undefined,
    ips: string[] = [],
    onDone?: (attempt: DialAttempt) => void,
  ): Effect.Effect<Link, CoreError> {
    if (!this.#hasHotMode()) return open(this.#env, endpoint, relays, endpointId(addr), credentials, fresh, null, ctx, ips, addr, onDone);
    return Effect.gen({ self: this }, function* () {
      this.#mainDialing++;
      this.#relaxStationState(endpointId(addr));
      yield* this.#syncRelaysNow();
      return yield* open(this.#env, endpoint, relays, endpointId(addr), credentials, fresh, null, ctx, ips, addr, onDone);
    }).pipe(
      Effect.ensuring(
        Effect.sync(() => {
          this.#mainDialing = Math.max(0, this.#mainDialing - 1);
          this.#scheduleSyncRelays();
        }),
      ),
    );
  }

  /// The link to a station at `addr`, opening it (or opening again a closed one) with a credential from `credentials`,
  /// its workspace's; `theirs`: the relays its workspace has of its own; `off`: the ways it turned off (relays, kinds of
  /// way), none gone that way. The same station at another address (in another workspace) has a link of its own.
  /// `asker`: what waits on it (a request's method and route, `events`, `screen`; `again` when the mesh opens it
  /// itself), said on the dial's span: whether someone was waiting on a slow dial, or it came about in the background.
  link(addr: string, credentials: CredentialSource, theirs?: readonly string[], off?: readonly string[], asker?: string): Effect.Effect<Link, CoreError> {
    return Effect.gen({ self: this }, function* () {
      this.#setWays(addr, theirs, off, false);
      const existing = this.#links.get(addr);
      let fresh = false;
      if (existing) {
        if (existing.result === null) {
          // Being opened: as that dial ends, unless it gave up for no answer before this waited CONNECT_TIMEOUT_MS on
          // it. Begun earlier (while the network was down, perhaps), that says nothing of now: dialled again (side run
          // seed 39248349, 2026-10-30: a read asked as its relay came back was told no answer came, the device not
          // having dialled since).
          const asked = this.now();
          const joined = yield* Effect.result(Deferred.await(existing.done));
          if (joined._tag === "Success") return joined.success;
          const ended = existing.result as Opening["result"];
          const unanswered = ended !== null && "err" in ended && ended.unanswered;
          if (!unanswered || this.now() - asked >= CONNECT_TIMEOUT_MS) return yield* Effect.fail(joined.failure);
          return yield* this.link(addr, credentials, theirs, off, asker);
        }
        if ("ok" in existing.result) {
          if (existing.result.ok.usable()) return existing.result.ok;
          // Refused for something else, which its user named (`MeshEnv.refusal`: the still.fail core's, the workspace
          // lock), the credential was fine: no new one asked of its source each time.
          fresh = existing.result.ok.refused !== null && !named.has(existing.result.ok.refused);
        } else fresh = existing.result.err.code === "credential_refused";
      }
      // Gone, with another way still open: requests go on that one at once.
      if (!fresh && existing !== undefined) {
        const standby = this.#best(addr, this.#takeable(addr, this.#live(addr).filter((w) => w.missed === 0)));
        if (standby !== null) {
          this.#promote(addr, standby, "lost");
          return standby.link;
        }
      }
      const span = this.#env.tracer.span("mesh.connect", Kind.Internal);
      span.own("station", endpointId(addr));
      if (asker !== undefined) span.own("asker", asker);
      let endpoint = this.#endpoint;
      if (this.#stuck && !this.#anyOpen()) {
        span.own("rebound", true);
        endpoint = yield* this.#rebind();
      } else if (this.#stuck) record(this.#env.host, "conn stuck", () => `${stationTag(addr)} not rebound: ${this.#openLinks().length} link(s) open`);
      span.own("relay", relayStatus(endpoint));
      const serial = ++this.#serials;
      const hedged = Deferred.makeUnsafe<Link, CoreError>();
      const firstControl = makeDialControl(false);
      const hedgeControl = makeDialControl(false);
      this.#hedges.set(addr, { serial, credentials, tx: hedged, control: hedgeControl });
      const opening: Opening = { done: Deferred.makeUnsafe<Link, CoreError>(), result: null, controls: [firstControl, hedgeControl] };
      const before = this.#links.get(addr);
      if (before?.controls) for (const c of before.controls) cancelDial(c);
      this.#links.set(addr, opening);
      if (this.#hot.has(endpointId(addr))) this.#relaxStation(endpointId(addr));
      if (before?.result && "ok" in before.result) this.#count(addr, before.result.ok);
      this.#notify();
      const openingWakeGen = this.#wakeGen;
      const first = this.#dialAll(addr, endpoint, credentials, fresh, span.context, firstControl);
      const firstDone = Deferred.makeUnsafe<Link, CoreError>();
      this.#env.runner.fork(
        Effect.map(Effect.result(first), (r) =>
          Deferred.doneUnsafe(firstDone, r._tag === "Success" ? Effect.succeed(r.success) : Effect.fail(r.failure)),
        ),
      );
      const self = this;
      const run = Effect.gen(function* () {
        const raced = yield* Effect.raceFirst(
          Effect.map(Effect.result(Deferred.await(firstDone)), (r) => ({ first: r }) as const),
          Effect.map(Effect.result(Deferred.await(hedged)), (r) => ({ hedged: r }) as const),
        );
        let link: { _tag: "Success"; success: Link } | { _tag: "Failure"; failure: CoreError };
        let winnerControl: DialControl | null = null;
        if ("first" in raced) {
          if (raced.first._tag === "Success") {
            link = raced.first;
            winnerControl = firstControl;
          } else {
            cancelDial(firstControl);
            // Failed: the link tried beside it, if one was.
            const h = self.#hedges.get(addr);
            const tried = h !== undefined && h.serial === serial && h.tx === null;
            if (tried) {
              const other = yield* Effect.result(Deferred.await(hedged));
              if (other._tag === "Success") {
                link = other;
                winnerControl = hedgeControl;
              } else {
                cancelDial(hedgeControl);
                link = raced.first;
              }
            } else {
              cancelDial(hedgeControl);
              link = raced.first;
            }
          }
        } else if (raced.hedged._tag === "Success") {
          span.own("hedged", true);
          link = raced.hedged;
          winnerControl = hedgeControl;
        } else {
          cancelDial(hedgeControl);
          link = yield* Effect.result(Deferred.await(firstDone));
          if (link._tag === "Success") winnerControl = firstControl;
          else cancelDial(firstControl);
        }
        // Come through on a way the station's ways no longer let it go (told them while it was dialled: `setWays`): let
        // go, and the one tried beside it on the ways it may go taken, or it dialled on those now.
        if (link._tag === "Success" && self.#wayOff(addr, link.success)) {
          link.success.close();
          cancelDial(winnerControl ?? undefined);
          winnerControl = null;
          const h = self.#hedges.get(addr);
          const beside = "first" in raced && h !== undefined && h.serial === serial && h.tx === null;
          if (beside) {
            link = yield* Effect.result(Deferred.await(hedged));
            if (link._tag === "Success") winnerControl = hedgeControl;
          }
          if (link._tag === "Success" && self.#wayOff(addr, link.success)) {
            link.success.close();
            cancelDial(winnerControl ?? undefined);
            winnerControl = null;
            const redialControl = makeDialControl(false);
            opening.controls?.push(redialControl);
            link = yield* Effect.result(self.#dialAll(addr, self.#endpoint, credentials, fresh, span.context, redialControl));
            if (link._tag === "Success") winnerControl = redialControl;
          }
        }
        for (const c of opening.controls ?? []) if (c !== winnerControl) cancelDial(c);
        if (winnerControl !== firstControl) {
          self.#env.runner.fork(Effect.map(Effect.result(Deferred.await(firstDone)), (r) => (r._tag === "Success" && (link._tag !== "Success" || r.success !== link.success) ? r.success.close() : undefined)));
        }
        if (winnerControl !== hedgeControl) {
          Deferred.doneUnsafe(hedged, Effect.fail(unreached({ message: "dial cancelled" })));
          self.#env.runner.fork(Effect.map(Effect.result(Deferred.await(hedged)), (r) => (r._tag === "Success" && (link._tag !== "Success" || r.success !== link.success) ? r.success.close() : undefined)));
        }
        if (self.#hedges.get(addr)?.serial === serial) self.#hedges.delete(addr);
        const active = self.#links.get(addr) === opening && !self.#closed;
        if (!active && link._tag === "Success") {
          cancelDial(winnerControl ?? undefined);
          winnerControl = null;
          link.success.close();
          if (self.#dialing === 0) self.#env.runner.fork(self.#letGo());
          link = { _tag: "Failure", failure: unreached({ message: "dial cancelled" }) };
        }
        // (asked before `failedIn` says it with the time it failed at)
        const timeout = link._tag === "Failure" && link.failure instanceof OpeningTimeout ? link.failure : null;
        const unanswered = timeout !== null;
        if (link._tag === "Success") {
          self.#stuck = false;
          const path = link.success.path();
          if (path !== null) span.own("path", path);
          const via = link.success.via();
          if (via !== null) span.own("via", relayHost(via));
          // Where its time went: getting onto a relay, the handshake, the credential; and each way's round trip and
          // packets sent and lost by then (a handshake many round trips long, or lost and sent again).
          const opened = link.success.opened;
          if (opened !== null) {
            span.own("onto_ms", opened.onto);
            span.own("dialled_ms", opened.dialled);
            span.own("credential_ms", opened.credential);
          }
          span.own("paths", link.success.paths());
        } else {
          const frozenOrWoken = (timeout !== null && timeout.frozen) || self.#wakeGen !== openingWakeGen;
          if (timeout !== null && !timeout.connected && !frozenOrWoken) self.#stuck = true;
          failedIn(span, link.failure);
          span.own("relay", relayStatus(endpoint));
          // What a dial that failed was given and had beside it: the addresses it was told the station is reached straight
          // at, and the ways of this device's other links to the same station (in another workspace), open on the same
          // endpoint. 2026-10-29: a Mac's dials to its station failed for half an hour, both workspaces' at once, the
          // spans saying nothing of either.
          const straight = self.#straightAt(addr);
          if (straight.length > 0) span.own("ips", straight.join(", "));
          if (unanswered && !frozenOrWoken && straight.length > 0 && self.#mainOn(addr)) {
            self.#unansweredAt.set(addr, straight.join(" "));
          }
          const beside = self.#besideOf(addr);
          if (beside !== "") span.own("beside", beside);
        }
        span.end();
        opening.controls = link._tag === "Success" && winnerControl !== null ? [winnerControl] : [];
        opening.result = link._tag === "Success" ? { ok: link.success } : { err: link.failure, unanswered };
        if (link._tag === "Success") {
          if (link.success.pinned === null) {
            self.#unansweredAt.delete(addr);
            self.#handshakeRescueCooldown.delete(addr);
          }
          self.#adopt(addr, link.success);
          commitDial(winnerControl ?? undefined);
        }
        self.#scheduleSyncRelays();
        Deferred.doneUnsafe(opening.done, link._tag === "Success" ? Effect.succeed(link.success) : Effect.fail(link.failure));
      });
      this.#env.runner.fork(run);
      return yield* Deferred.await(opening.done);
    });
  }

  /// Closes the link to a station at `addr`, if one is open or opening: taken for gone. Its links at other addresses
  /// (in other workspaces) stay.
  dropLink(addr: string): void {
    const opening = this.#links.get(addr);
    if (opening?.controls) for (const c of opening.controls) cancelDial(c);
    cancelDial(this.#hedges.get(addr)?.control);
    this.#links.delete(addr);
    this.#rescued.delete(addr);
    this.#wakeSteer(addr);
    this.#notify();
    if (opening?.result && "ok" in opening.result) {
      opening.result.ok.conn.close(0, "woke");
      this.#count(addr, opening.result.ok);
    }
    for (const w of this.#ways.get(addr) ?? []) w.link.conn.close(0, "woke");
    this.#ways.delete(addr);
    this.#tellHealth(addr);
    this.#relaxStation(endpointId(addr));
    this.#env.runner.fork(this.#letGo());
  }

  /// Addresses with an open or opening link or live ways on this mesh.
  linkAddresses(): string[] {
    return [...new Set([...this.#links.keys(), ...this.#ways.keys()])];
  }

  /// Takes one way to the peer at `addr` for gone: `link` (what a stream that went silent came on), or the link
  /// requests go on where none is named. Only that way is closed while another open way answers its pings: the requests
  /// move to the best of those (one that answered its last ping first) at once. Where none does, every way is closed
  /// (`dropLink`) and the peer dialled anew by the next request. 2026-11-16: a stream silent on a slow relay closed every
  /// way, a quicker one answering every ping among them, again and again.
  dropWay(addr: string, link?: Link): void {
    const cur = this.current(addr);
    const target = link ?? cur;
    if (target === null) {
      this.dropLink(addr);
      return;
    }
    const others = this.#live(addr).filter((w) => w.link !== target && w.missed < DEAD_PINGS && !this.#wayOff(addr, w.link));
    const keep = target !== cur && cur !== null && cur.usable();
    const fresh = others.filter((w) => w.missed === 0);
    const best = keep ? null : this.#best(addr, this.#takeable(addr, fresh.length > 0 ? fresh : others));
    if (!keep && best === null) {
      this.dropLink(addr);
      return;
    }
    if (best !== null) this.#promote(addr, best, "lost");
    this.#ways.set(
      addr,
      (this.#ways.get(addr) ?? []).filter((w) => w.link !== target),
    );
    target.conn.close(0, "lost");
    this.#count(addr, target);
    this.#tellHealth(addr);
    this.#relaxStation(endpointId(addr));
    // (its relay's endpoint, none going on it now, let go)
    this.#env.runner.fork(this.#letGo());
  }

  /// Takes over the device key a page kept before the core existed (32 bytes): stored, the endpoint bound anew with
  /// it, open links closed. The same key again changes nothing.
  migrate(secret: Uint8Array): Effect.Effect<void, CoreError> {
    return Effect.gen({ self: this }, function* () {
      if (secret.length !== 32) return yield* Effect.fail(CoreError.invalid(t("core-logic.mesh.bad_device_key")));
      const stored = yield* Effect.mapError(this.#env.host.storageGet(DEVICE_KEY), asCoreError);
      if (stored !== null && hex(stored) === hex(secret)) return;
      const routes = entryRoutes(this.relays, this.entries, this.entryTargets);
      const allowlist = this.#mainAllowlist(this.relays, routes);
      const endpoint = yield* Mesh.#bindMain(this.#env, secret, this.relays, routes, allowlist);
      this.#env.runner.fork(this.#accepting(endpoint));
      yield* Effect.mapError(this.#env.host.storageSet(DEVICE_KEY, secret), asCoreError);
      this.#secret = secret;
      const old = this.#endpoint;
      this.#endpoint = endpoint;
      this.#endpointRemoved.clear();
      this.#appliedDisabled.clear();
      this.#hot.clear();
      this.#relaxedAt.clear();
      this.#syncDirty = false;
      for (const [, p] of [...this.#pinned]) {
        const e = yield* Deferred.await(p);
        if (e) this.#env.runner.fork(e.close());
      }
      this.#pinned.clear();
      const links = [...this.#links];
      this.#links.clear();
      for (const ways of this.#ways.values()) for (const w of ways) w.link.conn.close(0, "device key replaced");
      this.#ways.clear();
      this.#notify();
      for (const [id, o] of links) {
        if (o.result && "ok" in o.result) {
          o.result.ok.conn.close(0, "device key replaced");
          this.#count(id, o.result.ok);
        }
      }
      this.#env.runner.fork(old.close());
    });
  }

  /// The ways open to a station that are still up.
  #live(addr: string): Way[] {
    const all = this.#ways.get(addr);
    if (all === undefined) return [];
    const live = all.filter((w) => w.link.usable());
    for (const w of all) if (!live.includes(w)) w.link.close();
    if (live.length > 0) this.#ways.set(addr, live);
    else this.#ways.delete(addr);
    return live;
  }

  /// A way as compared with another (`clearlyBetter`).
  #score(addr: string, way: Way): Score {
    const via = way.link.via();
    return { score: cost(way.srtt, via !== null ? this.speed(addr, via) : null) + 2 * way.dev, dev: way.dev };
  }

  /// Best available RTT estimate for `way` in ms, falling back to 200 when no signal exists.
  #wayRtt(way: Way): number {
    if (way.samples > 0) return way.srtt;
    if (way.answeredMs !== null && Number.isFinite(way.answeredMs) && way.answeredMs > 0) return way.answeredMs;
    const netRtt = way.link.net().rttMs;
    if (netRtt !== null && Number.isFinite(netRtt) && netRtt > 0) return netRtt;
    return 200;
  }

  /// Expected ms to transfer BULK_BYTES on `way` (lower is better).
  #bulkScore(addr: string, way: Way): number {
    if (way.link.pinned === LAN) return way.samples > 0 ? way.srtt : 0;
    const rtt = this.#wayRtt(way);
    const sk = way.link.speedKey();
    const bps = sk !== null ? this.speed(addr, sk) : null;
    const baseProbe = way.key() === DIRECT ? BULK_PROBE_BPS : BULK_RELAY_PROBE_BPS;
    const probeBps = Math.min(baseProbe, Math.round(baseProbe * (200 / Math.max(200, rtt))));
    return rtt + (BULK_BYTES / (bps !== null && bps > 0 ? bps : probeBps)) * 1000;
  }

  /// Of `ways`, the one scoring best (pinged at least once; none pinged yet: the first).
  #best(addr: string, ways: Way[]): Way | null {
    let best: Way | null = null;
    for (const w of ways) {
      if (best === null) best = w;
      else if (w.samples > 0 && (best.samples === 0 || this.#score(addr, w).score < this.#score(addr, best).score)) best = w;
    }
    return best;
  }

  /// Dials the station every way at once: on the main endpoint (through any relay, or direct), and on each relay's own
  /// endpoint through that relay alone. The first through is the link; the others, as they come through, are ways to it
  /// as well (`#adopt`). Fails once all have, as the main endpoint's dial failed. A phone whose own relay could not
  /// reach the station (2026-10-08) waited out CONNECT_TIMEOUT_MS on it time after time.
  #dialAll(addr: string, endpoint: IrohEndpoint, credentials: CredentialSource, fresh: boolean, ctx: SpanContext | undefined, control?: DialControl): Effect.Effect<Link, CoreError> {
    return Effect.suspend(() => {
      if (control?.cancelled) return Effect.fail(unreached({ message: "dial cancelled" }));
      this.#exploredAt.set(addr, this.now());
      const round = { at: this.now(), attempts: [] as DialAttempt[] };
      this.#diags.set(addr, round);
      const onDone = (attempt: DialAttempt) => {
        if (round.attempts.length < 12) round.attempts.push(attempt);
      };
      const relays = this.relaysFor(addr);
      // On the main endpoint, one connection: a path through every relay the station is on (the endpoint is home on
      // all of them), to the addresses it said it is reached straight at, and those iroh punches through; iroh moves
      // its packets between them, and nothing on it ends as they change. The other endpoints only while its workspace
      // turned the main endpoint's ways off (`#mainOn`).
      type AttemptEntry = {
        effect: Effect.Effect<Link, CoreError>;
        kind: "main" | "pinned" | "at";
        relay?: string;
        onRelay: boolean;
        done: boolean;
      };
      const entries: AttemptEntry[] = [];
      const liveOrder: string[] = [];
      let mainCount = 0;
      let isUnanswered = false;
      const pushPinned = (r: string) => {
        const entry: AttemptEntry = {
          effect: undefined as unknown as Effect.Effect<Link, CoreError>,
          kind: "pinned",
          relay: r,
          onRelay: false,
          done: false,
        };
        entry.effect = this.#dialPinned(addr, r, credentials, fresh, ctx, onDone, () => {
          entry.onRelay = true;
          if (!liveOrder.includes(r)) liveOrder.push(r);
        });
        entries.push(entry);
      };
      if (this.#mainOn(addr)) {
        const straight = this.#straightAt(addr);
        const dial = this.#dialMain(addr, endpoint, relays, credentials, fresh, ctx, straight, onDone);
        // Given those addresses, its last dial went unanswered: each relay's own endpoint (on that relay alone, at no
        // address) dialled beside it. An address can reach the station one way only, and iroh's handshake goes on the
        // way the station heard first: a station in WSL with mirrored networking says the Windows machine's own
        // addresses, its answers to the Windows app there going back into WSL; that app's dials waited out
        // CONNECT_TIMEOUT_MS on them for hours while the phone came through a relay (2026-11-03).
        const unanswered = straight.length > 0 && this.#unansweredAt.get(addr) === straight.join(" ");
        isUnanswered = unanswered;
        // Its one connection let go for its pings going unanswered: dialled again on each other relay's own endpoint
        // as well, the requests going on whichever answers. Its path went through a relay that lost half of what went
        // and took 2–6 s a round trip from where the device is, and iroh dialled it there again: devices in China let
        // their links to stations in Tokyo go every 15–40 s for an evening, while Shenzhen's relay reached them in
        // 0.4 s (2026-11-09).
        const lost = this.#lostMain.delete(addr);
        if (!unanswered && !lost) {
          const withCancelMain = (effect: Effect.Effect<Link, CoreError>): Effect.Effect<Link, CoreError> =>
            control === undefined
              ? effect
              : Effect.raceFirst(
                  effect,
                  Effect.andThen(Deferred.await(control.cancelSignal), Effect.fail(unreached({ message: "dial cancelled" }))),
                );
          const self = this;
          const dialStarted = this.now();
          const dialNetGen = this.#netGen;
          const roundDeadline = dialStarted + ONTO_MAX_MS + CONNECT_TIMEOUT_MS;
          const mainHasIp =
            this.#env.relayOnly !== true &&
            (straight.length > 0 ||
              (this.#env.lookup === true && this.relays.length > 0) ||
              this.#known.some((a) => a.id === endpointId(addr) && (a.ips?.length ?? 0) > 0));
          return Effect.gen(function* () {
            const first = yield* Effect.result(withCancelMain(dial));
            if (first._tag === "Success") return first.success;
            const err = first.failure;
            const rescueKey = `${addr}\0${dialNetGen}`;
            const remainingMs = roundDeadline - self.now();
            if (
              !(err instanceof HandshakeConflict) ||
              !mainHasIp ||
              self.#closed ||
              control?.cancelled ||
              self.#netGen !== dialNetGen ||
              !self.#mainOn(addr) ||
              remainingMs <= 0 ||
              self.#handshakeRescuing.has(rescueKey) ||
              (self.#handshakeRescueCooldown.get(addr) ?? -Infinity) > self.now()
            ) {
              return yield* Effect.fail(err);
            }
            const rescueRelay = self.#pickHandshakeRescueRelay(addr);
            if (rescueRelay === null) return yield* Effect.fail(err);
            self.#handshakeRescuing.add(rescueKey);
            const rescueResult = yield* Effect.ensuring(
              Effect.result(
                withCancelMain(
                  Effect.raceFirst(
                    self.#dialPinned(addr, rescueRelay, credentials, fresh, ctx, onDone),
                    Effect.andThen(Effect.sleep(remainingMs), Effect.fail(new OpeningTimeout(false))), // timer: caps single-relay handshake rescue to the opening deadline
                  ),
                ),
              ),
              Effect.sync(() => {
                self.#handshakeRescuing.delete(rescueKey);
              }),
            );
            if (rescueResult._tag === "Success") {
              if (control?.cancelled || self.#closed || self.#wayOff(addr, rescueResult.success)) {
                rescueResult.success.close();
                if (self.#dialing === 0) self.#env.runner.fork(self.#letGo());
                return yield* Effect.fail(control?.cancelled ? unreached({ message: "dial cancelled" }) : err);
              }
              self.#rescued.add(addr);
              self.#mainDialledAt.set(addr, self.now());
              return rescueResult.success;
            }
            if (!control?.cancelled && !self.#closed && self.#netGen === dialNetGen) {
              self.#handshakeRescueCooldown.set(addr, self.now() + HANDSHAKE_RESCUE_COOLDOWN_MS);
            }
            if (self.#dialing === 0) self.#env.runner.fork(self.#letGo());
            return yield* Effect.fail(err);
          });
        }
        this.#rescued.add(addr);
        this.#mainDialledAt.set(addr, this.now());
        entries.push({ effect: dial, kind: "main", onRelay: true, done: false });
        mainCount = 1;
        const candidates = unanswered ? this.#waysFor(addr) : this.#pinnable(addr);
        for (const r of this.#filterDeadRelays(candidates, true)) pushPinned(r);
      } else {
        // Where the station said (in a run before, perhaps) it is reached straight: dialled beside the relays, not
        // after one of them brought its answer again.
        const at = AT_ADDRESSES.flatMap((kind) => this.#dialAt(addr, kind, credentials, fresh, onDone) ?? []);
        for (const r of this.#filterDeadRelays(this.#pinnable(addr), at.length > 0)) pushPinned(r);
        for (const eff of at) entries.push({ effect: eff, kind: "at", onRelay: true, done: false });
      }
      if (entries.length === 0) return Effect.fail(meshError(t("core-logic.mesh.all_off")));
      const self = this;
      const won = Deferred.makeUnsafe<Link, CoreError>();
      const extraAbort = Deferred.makeUnsafe<void>();
      const dialStarted = this.now();
      const dialNetGen = this.#netGen;
      const roundDeadline = dialStarted + ONTO_MAX_MS + CONNECT_TIMEOUT_MS;
      let wonSettled = false;
      let wonFailed = false;
      let initialLeft = entries.length;
      let mainFailure: CoreError | null = null;
      let extraRetries = 0;
      const maxExtraRetries = 2;
      const onlyUnconnectedSingleRelaysLeft = () =>
        entries.every(
          (e) =>
            e.done ||
            (e.kind === "pinned" &&
              e.relay !== undefined &&
              e.relay !== LAN &&
              e.relay !== TAILNET &&
              !isFenced(e.relay) &&
              !e.onRelay),
        );
      const capExtra = (effect: Effect.Effect<Link, CoreError>): Effect.Effect<Link, CoreError> => {
        const capMs = Math.max(0, roundDeadline - self.now());
        const limit = Effect.andThen(
          Effect.raceFirst(Deferred.await(extraAbort), Effect.sleep(capMs)),
          Effect.fail(new OpeningTimeout(false)),
        );
        return Effect.raceFirst(effect, limit);
      };
      const withCancel = (effect: Effect.Effect<Link, CoreError>): Effect.Effect<Link, CoreError> => {
        if (control === undefined) return effect;
        return Effect.raceFirst(
          effect,
          Effect.andThen(Deferred.await(control.cancelSignal), Effect.fail(unreached({ message: "dial cancelled" }))),
        );
      };
      const launch = (entry: AttemptEntry, isInitial: boolean, isPrimaryMain: boolean) => {
        self.#env.runner.fork(
          Effect.gen(function* () {
            if (control?.cancelled) {
              entry.done = true;
              if (isInitial) {
                initialLeft--;
                if (initialLeft === 0) {
                  if (Deferred.doneUnsafe(won, Effect.fail(mainFailure ?? unreached({ message: "dial cancelled" })))) {
                    wonSettled = true;
                    wonFailed = true;
                  }
                  Deferred.doneUnsafe(extraAbort, Effect.void);
                }
              }
              return;
            }
            const r = yield* Effect.result(withCancel(isInitial ? entry.effect : capExtra(entry.effect)));
            entry.done = true;
            if (r._tag === "Success") {
              if (control?.cancelled) {
                r.success.close();
                if (self.#dialing === 0) self.#env.runner.fork(self.#letGo());
                return;
              }
              if (Deferred.doneUnsafe(won, Effect.succeed(r.success))) {
                wonSettled = true;
              } else if (!wonFailed) {
                const shouldAdopt = control === undefined ? true : yield* Deferred.await(control.adopt);
                if (shouldAdopt && !control?.cancelled && !self.#closed) {
                  self.#adopt(addr, r.success);
                } else {
                  r.success.close();
                  if (self.#dialing === 0) self.#env.runner.fork(self.#letGo());
                }
              } else {
                r.success.close();
                if (self.#dialing === 0) self.#env.runner.fork(self.#letGo());
              }
              return;
            }
            if (isPrimaryMain) mainFailure = r.failure;
            if (isInitial) initialLeft--;
            if (initialLeft === 0) {
              if (Deferred.doneUnsafe(won, Effect.fail(mainFailure ?? r.failure))) {
                wonSettled = true;
                wonFailed = true;
              }
              Deferred.doneUnsafe(extraAbort, Effect.void);
              if (control?.cancelled && self.#dialing === 0) self.#env.runner.fork(self.#letGo());
              return;
            }
            if (control?.cancelled) {
              if (self.#dialing === 0) self.#env.runner.fork(self.#letGo());
              return;
            }
            const liveTimeout =
              r.failure instanceof OpeningTimeout &&
              !r.failure.frozen &&
              (entry.kind === "main" || (entry.kind === "pinned" && entry.onRelay));
            // When live paths time out while slow/unreachable pinned relays are still waiting in `onARelay`, keep
            // `won` open for slow relays that may still connect AND race a bounded live retry beside them so dead
            // relays never stall recovery for 40 s and extra retries never extend the round's failure deadline.
            if (
              !wonSettled &&
              !control?.cancelled &&
              !self.#closed &&
              self.#netGen === dialNetGen &&
              liveTimeout &&
              extraRetries < maxExtraRetries &&
              self.now() - dialStarted < ONTO_MAX_MS &&
              onlyUnconnectedSingleRelaysLeft()
            ) {
              extraRetries++;
              if (self.#mainOn(addr)) {
                const retry: AttemptEntry = {
                  effect: self.#dialMain(addr, self.#endpoint, self.relaysFor(addr), credentials, fresh, ctx, self.#straightAt(addr), onDone),
                  kind: "main",
                  onRelay: true,
                  done: false,
                };
                entries.push(retry);
                launch(retry, false, false);
                if (isUnanswered) {
                  const allowedWays = new Set(self.#waysFor(addr));
                  const fastest = liveOrder.find((r) => allowedWays.has(r));
                  if (fastest !== undefined) {
                    const pinnedRetry: AttemptEntry = {
                      effect: undefined as unknown as Effect.Effect<Link, CoreError>,
                      kind: "pinned",
                      relay: fastest,
                      onRelay: false,
                      done: false,
                    };
                    pinnedRetry.effect = self.#dialPinned(addr, fastest, credentials, fresh, ctx, onDone, () => {
                      pinnedRetry.onRelay = true;
                    }, false);
                    entries.push(pinnedRetry);
                    launch(pinnedRetry, false, false);
                  }
                }
              } else {
                const allowed = new Set(self.#pinnable(addr));
                const liveRelays = new Set(
                  entries
                    .filter((e) => e.done && e.kind === "pinned" && e.onRelay && e.relay !== undefined && allowed.has(e.relay))
                    .map((e) => e.relay!),
                );
                for (const relay of liveRelays) {
                  const retry: AttemptEntry = {
                    effect: undefined as unknown as Effect.Effect<Link, CoreError>,
                    kind: "pinned",
                    relay,
                    onRelay: false,
                    done: false,
                  };
                  retry.effect = self.#dialPinned(addr, relay, credentials, fresh, ctx, onDone, () => {
                    retry.onRelay = true;
                  }, false);
                  entries.push(retry);
                  launch(retry, false, false);
                }
              }
            }
          }),
        );
      };
      entries.forEach((entry, i) => launch(entry, true, i === 0 && mainCount > 0));
      return Deferred.await(won);
    });
  }

  /// This device's open links to the station at `addr` under its other addresses (another workspace's), as a span says
  /// them: each one's workspace and ways (`Link.paths`); "" with none.
  #besideOf(addr: string): string {
    const id = endpointId(addr);
    const out: string[] = [];
    for (const [a, o] of this.#links) if (a !== addr && endpointId(a) === id && o.result && "ok" in o.result && o.result.ok.closed() === null) out.push(`${a.slice(0, a.length - id.length - 1)}: ${o.result.ok.paths()}`);
    return out.join(" | ");
  }

  /// Where the station last said a device dials it straight (its LAN, its tailnet), but the kinds its workspace turned off.
  #straightAt(addr: string): string[] {
    return AT_ADDRESSES.flatMap((kind) => (this.#isOff(addr, kind) ? [] : (this.#said[addr]?.[kind] ?? [])));
  }

  /// The ways a station is dialled on each on an endpoint of its own: every relay and entry but still.fail's own relay
  /// (the first, on Cloudflare), which the main endpoint reaches already. It holds few connections, each a cost: one
  /// more a device filled it (2026-10-08: 429 to bft's keeper and to devices). None while there is one way or none.
  /// Off the main endpoint (`#mainOn`), every relay left is, still.fail's own too, and the fence of them (`#fence`).
  #pinnable(addr: string): string[] {
    const ways = this.#waysFor(addr);
    if (!this.#mainOn(addr)) {
      const fence = this.#fence(addr);
      return fence === null ? ways : [...ways, fence];
    }
    if (ways.length < 2) return [];
    const own = this.relays[0];
    return ways.filter((r) => own === undefined || !sameRelay(own, r));
  }

  /// Picks at most one allowed, non-dead relay for a single-relay rescue after a main handshake conflict: prefers
  /// non-primary relays over the primary relay to spare official relay quota, and within each tier prefers
  /// a relay already reported connected.
  #pickHandshakeRescueRelay(addr: string): string | null {
    const candidates = this.#filterDeadRelays(this.#waysFor(addr), true);
    if (candidates.length === 0) return null;
    const connected = new Set<string>();
    for (const s of this.#endpoint.relayStatus()) {
      if (s.connected) {
        connected.add(relayKey(s.url));
        if (s.access) connected.add(relayKey(s.access));
      }
    }
    const own = this.relays[0];
    const rank = (r: string) => {
      const isOwn = own !== undefined && sameRelay(own, r) ? 1 : 0;
      const isUp = connected.has(relayKey(r)) ? 0 : 1;
      return isOwn * 2 + isUp;
    };
    let best = candidates[0]!;
    let bestRank = rank(best);
    for (let i = 1; i < candidates.length; i++) {
      const r = candidates[i]!;
      const k = rank(r);
      if (k < bestRank) {
        best = r;
        bestRank = k;
      }
    }
    return best;
  }

  #isDeadRelay(relay: string): boolean {
    const key = relayKey(relay);
    const until = this.#deadRelays.get(key);
    if (until === undefined) return false;
    if (this.now() >= until) {
      this.#deadRelays.delete(key);
      return false;
    }
    return true;
  }

  #filterDeadRelays(relays: string[], hasOtherWays: boolean): string[] {
    const live = relays.filter((r) => r === LAN || r === TAILNET || isFenced(r) || !this.#isDeadRelay(r));
    return live.length > 0 || hasOtherWays ? live : relays;
  }

  #isDialingPinned(addr: string, relay: string): boolean {
    return (this.#inFlightPinned.get(`${addr}\0${pinnedIdentity(relay)}\0${this.#netGen}`) ?? 0) > 0;
  }

  /// A link through `relay` alone, on that relay's own endpoint (`#pinnedEndpoint`); through a fence's relays, or a path
  /// punched through them, on the fence's.
  #dialPinned(addr: string, relay: string, credentials: CredentialSource, fresh: boolean, ctx: SpanContext | undefined, onDone?: (attempt: DialAttempt) => void, onRelayReady?: () => void, countOnlineFail = true): Effect.Effect<Link, CoreError> {
    return Effect.suspend(() => {
      const singleRelay = relay !== LAN && relay !== TAILNET && !isFenced(relay);
      const startNetGen = this.#netGen;
      const inFlightKey = `${addr}\0${pinnedIdentity(relay)}\0${startNetGen}`;
      this.#dialing++;
      this.#inFlightPinned.set(inFlightKey, (this.#inFlightPinned.get(inFlightKey) ?? 0) + 1);
      return Effect.flatMap(this.#pinnedEndpoint(relay), (endpoint) => {
        if (endpoint === null) return Effect.fail(unreached({ message: `no endpoint for ${relayHost(relay)}` }));
        return open(this.#env, endpoint, this.#fences.get(relay) ?? [relay], endpointId(addr), credentials, fresh, relay, ctx, [], addr, onDone, onRelayReady).pipe(
          Effect.tap(() =>
            Effect.sync(() => {
              if (!singleRelay) return;
              const k = relayKey(relay);
              this.#deadRelays.delete(k);
              this.#deadRelayFails.delete(k);
            }),
          ),
          Effect.tapError((e) =>
            Effect.sync(() => {
              if (!singleRelay || !(e instanceof OpeningTimeout) || e.connected || e.frozen || this.#netGen !== startNetGen) return;
              const k = relayKey(relay);
              if (!endpointOnARelay(endpoint)) {
                this.#deadRelays.set(k, this.now() + DEAD_RELAY_MS);
                this.#deadRelayFails.delete(k);
                return;
              }
              if (!countOnlineFail) return;
              const fails = (this.#deadRelayFails.get(k) ?? 0) + 1;
              if (fails >= 2) {
                this.#deadRelays.set(k, this.now() + DEAD_RELAY_MS);
                this.#deadRelayFails.delete(k);
              } else {
                this.#deadRelayFails.set(k, fails);
              }
            }),
          ),
        );
      }).pipe(
        Effect.ensuring(
          Effect.sync(() => {
            this.#dialing--;
            const left = (this.#inFlightPinned.get(inFlightKey) ?? 1) - 1;
            if (left <= 0) this.#inFlightPinned.delete(inFlightKey);
            else this.#inFlightPinned.set(inFlightKey, left);
          }),
        ),
      );
    });
  }

  /// The station said where a device dials it straight (`link.lan`, `link.tailnet`, its answer to a link's
  /// credential): kept, and dialled there if new.
  #heard(addr: string, link: Link): void {
    // (refused, it said nothing of where it is: what was kept stays)
    if (link.refused !== null) return;
    const said: Said = { lan: link.lan, tailnet: link.tailnet };
    const was = this.#said[addr];
    const same = (kind: AtAddresses) => (was?.[kind] ?? []).join(" ") === said[kind].join(" ");
    if (!AT_ADDRESSES.every(same)) {
      for (const kind of AT_ADDRESSES) if (!same(kind)) this.#tried.delete(atKey(kind, addr));
      if (said.lan.length > 0 || said.tailnet.length > 0) this.#said[addr] = said;
      else delete this.#said[addr];
      this.#env.runner.fork(Effect.ignore(this.#env.host.storageSet(this.#env.addressesKey ?? ADDRESSES_KEY, toJsonBytes(this.#said)), { log: "Unhandled", message: "said kept" }));
    }
    // On the main endpoint the addresses are iroh's to try on the connection open (paths of it), not dialled apart.
    if (this.#mainOn(addr)) {
      const ips = this.#straightAt(addr);
      if (ips.length > 0) this.#endpoint.addAddr({ id: endpointId(addr), relays: this.relaysFor(addr), ips });
      return;
    }
    for (const kind of AT_ADDRESSES) this.#dialAtIf(addr, kind, link.credentials);
  }

  /// Dials the station at its addresses of `kind` on that kind's endpoint, unless a way to it is on that endpoint
  /// already: once for each set of addresses it says (a device off its LAN, its tailnet, tries them once, then not
  /// again until they change or the network does). Again on the LAN every REDIAL_MAIN_MS while it was reached direct
  /// within DIRECT_RECALL_MS; on the tailnet every EXPLORE_MS once it answered there since the network changed, as the
  /// relays are (a way let go as no better than the others may be better later).
  #dialAtIf(addr: string, kind: AtAddresses, credentials: CredentialSource): void {
    const at = this.#said[addr]?.[kind] ?? [];
    if (this.#closed || !this.#links.has(addr) || at.length === 0) return;
    const now = this.now();
    if (this.#tried.get(atKey(kind, addr)) === at.join(" ")) {
      const last = this.#atDialledAt.get(atKey(kind, addr)) ?? -Infinity;
      const again = kind === LAN ? now - (this.#directAt.get(addr) ?? -Infinity) < DIRECT_RECALL_MS && now - last >= REDIAL_MAIN_MS : this.#tailnetAnswered.has(addr) && now - last >= EXPLORE_MS;
      if (!again) return;
    }
    const dial = this.#dialAt(addr, kind, credentials, false);
    if (dial !== null) this.#env.runner.fork(Effect.ignore(Effect.map(dial, (link) => this.#adopt(addr, link)), { log: "Unhandled", message: "link dialled" }));
  }

  /// A dial of the station at its addresses of `kind`, on that kind's endpoint (`pinned` LAN or TAILNET): null when it
  /// said none, its workspace turned that kind off, one is under way or a way to it is on that endpoint already. Counted
  /// as under way from now: the caller runs it at once (`#dialAtIf` adopts what comes through; `#dialAll` races it).
  #dialAt(addr: string, kind: AtAddresses, credentials: CredentialSource, fresh: boolean, onDone?: (attempt: DialAttempt) => void): Effect.Effect<Link, CoreError> | null {
    const at = this.#said[addr]?.[kind] ?? [];
    const key = atKey(kind, addr);
    if (at.length === 0 || this.#isOff(addr, kind) || this.#atDialling.has(key) || this.#live(addr).some((w) => w.link.pinned === kind)) return null;
    this.#tried.set(key, at.join(" "));
    this.#atDialledAt.set(key, this.now());
    this.#atDialling.add(key);
    this.#dialing++;
    return Effect.flatMap(this.#pinnedEndpoint(kind), (endpoint) =>
      endpoint === null ? Effect.fail(unreached({ message: `no ${kind} endpoint` })) : open(this.#env, endpoint, [], endpointId(addr), credentials, fresh, kind, undefined, at, addr, onDone),
    ).pipe(
      Effect.ensuring(
        Effect.sync(() => {
          this.#dialing--;
          this.#atDialling.delete(key);
        }),
      ),
    );
  }

  /// `link` is a way to the station as well, if it is still wanted; pinged from now on.
  #adopt(addr: string, link: Link): void {
    // (one dialled before its workspace turned that way off)
    if (this.#closed || !this.#links.has(addr) || !link.usable() || this.#wayOff(addr, link)) {
      link.close();
      this.#env.runner.fork(this.#letGo());
      return;
    }
    if (link.pinned === null) this.#handshakeRescueCooldown.delete(addr);
    const ways = this.#live(addr);
    if (ways.some((w) => w.link === link)) return;
    const cur = this.current(addr);
    const id = pinnedIdentity(link.pinned);
    const same = ways.filter((w) => pinnedIdentity(w.link.pinned) === id);
    if (same.length > 0) {
      if (link === cur) {
        for (const w of same) this.#retire(addr, w);
      } else if (same.some((w) => w.missed === 0)) {
        link.close();
        this.#env.runner.fork(this.#letGo());
        return;
      } else {
        for (const w of same) if (w.link !== cur) this.#retire(addr, w);
      }
    }
    const nextWays = this.#live(addr);
    this.#ways.set(addr, [...nextWays, new Way(link)]);
    if (this.#env.linked && link.endpoint && (link.pinned === null || isFenced(link.pinned))) {
      const follow=Effect.andThen(link.admitted(),()=>this.#env.linked!(addr,link,link.endpoint!));
      this.#env.runner.fork(Effect.ignore(Effect.raceFirst(follow,Effect.asVoid(link.conn.closed())),{log:"Unhandled",message:"link transport admission"}));
    }
    if (this.#hasHotMode()) {
      if (link.pinned !== null && this.#hot.has(endpointId(addr))) this.#relaxStation(endpointId(addr));
      this.#env.runner.fork(
        Effect.andThen(
          link.conn.closed(),
          Effect.sync(() => {
            if (!this.#closed && !this.#retiring.has(link) && (this.#isCurrent(addr, link) || (this.#ways.get(addr) ?? []).some((w) => w.link === link))) {
              this.#relaxStation(endpointId(addr));
            }
          }),
        ),
      );
    }
    // A way just opened answers: not taken for unanswered as the ways before it were.
    this.#tellHealth(addr);
    if (link.pinned !== LAN && link.pinned !== TAILNET) this.#env.runner.fork(Effect.andThen(Deferred.await(link.answered), Effect.sync(() => this.#heard(addr, link))));
    this.#steerIf(addr);
  }

  /// Steers the station's ways (`#steer`) unless they are steered already: its one way too (no relays or one, and none
  /// at an address it said), nothing to choose between but its pings to answer, which are how a station gone from under
  /// it is found (`#suspect`): with one relay and no address said, a view of a station killed and started again stood
  /// still 24 s, unpinged (2026-11-11).
  #steerIf(addr: string): void {
    if (this.#steering.has(addr) || this.#live(addr).length === 0) return;
    this.#steering.add(addr);
    this.#env.runner.fork(this.#steer(addr));
  }

  /// Requests to the station go on `way` from now on; the link they went on stays open as another way.
  #promote(addr: string, way: Way, why: string): void {
    const before = this.current(addr);
    if (before === way.link) return;
    const span = this.#env.tracer.span("mesh.route", Kind.Internal);
    span.own("station", endpointId(addr));
    span.own("why", why);
    const was = before !== null ? this.#live(addr).find((w) => w.link === before) : undefined;
    if (was !== undefined) {
      span.own("from", was.key());
      span.own("from.score", Math.round(this.#score(addr, was).score));
      span.own("from.missed", was.missed);
      span.own("from.paths", was.link.paths());
    }
    span.own("to", way.key());
    span.own("to.score", Math.round(this.#score(addr, way).score));
    span.own("to.paths", way.link.paths());
    if (why === "lost" && this.#movedDirect.get(addr) === true) {
      const held = this.#lostDirect(addr, this.now() - (this.#movedAt.get(addr) ?? -Infinity));
      if (held !== null) span.own("direct_held_ms", held);
    }
    span.end();
    this.#movedDirect.set(addr, this.#isDirect(way));
    const prev = this.#links.get(addr);
    const done = Deferred.makeUnsafe<Link, CoreError>();
    Deferred.doneUnsafe(done, Effect.succeed(way.link));
    this.#links.set(addr, { done, result: { ok: way.link }, controls: prev?.controls });
    if (before !== null) this.#count(addr, before);
    const via = way.link.via();
    this.#moved.set(addr, via !== null ? relayHost(via) : "direct");
    this.#moves.set(addr, this.moves(addr) + 1);
    this.#movedAt.set(addr, this.now());
    for (const w of this.#live(addr)) w.better = 0;
    this.#notify();
  }

  /// How many times requests to the station moved from one way to another.
  moves(addr: string): number {
    return this.#moves.get(addr) ?? 0;
  }

  /// The ways open to the station, the link requests go on among them.
  ways(addr: string): Way[] {
    return this.#live(addr);
  }

  /// Whether a way to the station is up: one open that answered its last ping (one not pinged yet: its handshake did).
  standing(addr: string): boolean {
    return this.#links.has(addr) && this.#live(addr).some((w) => w.missed === 0);
  }

  /// Whether a way to the station answers its pings: one open that has not missed DEAD_PINGS in a row (none open: no).
  healthy(addr: string): boolean {
    return this.#links.has(addr) && this.#live(addr).some((w) => w.missed < DEAD_PINGS);
  }

  /// How many fibers are currently awaiting a ping health transition for `addr`.
  healthWaiters(addr: string): number {
    return this.#healthWaiting.get(addr)?.length ?? 0;
  }

  /// Succeeds with whether a way to the station answers its pings once that is no longer `was`, as the ticks find it.
  healthChange(addr: string, was: boolean): Effect.Effect<boolean> {
    return Effect.suspend(() => {
      const now = this.#health.get(addr) ?? this.healthy(addr);
      if (now !== was) return Effect.succeed(now);
      const d = Deferred.makeUnsafe<boolean>();
      this.#healthWaiting.set(addr, [...(this.#healthWaiting.get(addr) ?? []), d]);
      return Deferred.await(d).pipe(
        Effect.onInterrupt(() =>
          Effect.sync(() => {
            const waiting = this.#healthWaiting.get(addr);
            if (!waiting) return;
            const left = waiting.filter((x) => x !== d);
            if (left.length === 0) this.#healthWaiting.delete(addr);
            else this.#healthWaiting.set(addr, left);
          }),
        ),
      );
    });
  }

  /// After a tick: how its pings went, told to those waiting where it changed.
  #tellHealth(addr: string): void {
    const now = this.healthy(addr);
    if (this.#health.get(addr) === now) return;
    this.#health.set(addr, now);
    const waiting = this.#healthWaiting.get(addr) ?? [];
    this.#healthWaiting.delete(addr);
    for (const d of waiting) Deferred.doneUnsafe(d, Effect.succeed(now));
  }

  /// Pings a way: its credential presented again on it, answered by the station. Not answered within PING_TIMEOUT_MS,
  /// it counts as that long, and as missed; one still not answered is not sent again over it meanwhile. One answered
  /// later still is an answer: the way is not missing (only slow), and what it took is noted. A way whose round trip
  /// passes PING_TIMEOUT_MS missed every ping else, and its one connection was let go as dead at the third and dialled
  /// anew, again and again, each dial not done in CONNECT_TIMEOUT_MS (2026-10-29: a station 2–3 s away through every
  /// relay, unreached).
  #ping(way: Way): Effect.Effect<void> {
    return Effect.suspend(() => {
      if (way.pinging) {
        if (!way.brought()) way.missed++;
        way.note(PING_TIMEOUT_MS);
        return Effect.void;
      }
      way.pinging = true;
      way.brought();
      const link = way.link;
      const answered = Deferred.makeUnsafe<number | null>();
      let late = false;
      this.#env.runner.fork(
        Effect.gen(function* () {
          const started = yield* Clock.currentTimeMillis;
          const r = yield* Effect.result(link.controlled((c) => c.exchange(link.credential)));
          const took = (yield* Clock.currentTimeMillis) - started;
          way.pinging = false;
          if (late && r._tag === "Success") {
            way.missed = 0;
            way.note(took);
            way.answeredMs = took;
          }
          Deferred.doneUnsafe(answered, Effect.succeed(r._tag === "Success" ? took : null));
        }),
      );
      return Effect.map(Effect.raceFirst(Deferred.await(answered), Effect.as(Effect.sleep(PING_TIMEOUT_MS), null)), (ms) => {
        if (ms === null) {
          late = true;
          if (!way.brought()) way.missed++;
          way.note(PING_TIMEOUT_MS);
        } else {
          way.missed = 0;
          way.answeredMs = ms;
          if (way.warm) way.note(ms);
          way.warm = true;
        }
      });
    });
  }

  /// Every way to the station pinged at once.
  #sample(addr: string, ways: Way[] = this.#live(addr)): Effect.Effect<void> {
    return Effect.asVoid(Effect.all(ways.map((w) => this.#ping(w)), { concurrency: "unbounded" }));
  }

  /// Moves the station's requests to the best way if it is clearly better than theirs (`clearlyBetter`) BETTER_TICKS
  /// times in a row, or at once (`now`, why: "asked" as a person asks, "slow" as theirs was found to bring replies
  /// slowly); to the best way left at once if theirs is gone or missed DEAD_PINGS pings.
  #choose(addr: string, now: "asked" | "slow" | null): void {
    const cur = this.current(addr);
    if (cur === null && this.#links.get(addr)?.result === null) return;
    const ways = this.#live(addr);
    const up = ways.filter((w) => w.missed < DEAD_PINGS);
    const mine = ways.find((w) => w.link === cur);
    if (cur === null || !cur.usable() || mine === undefined || mine.missed >= DEAD_PINGS) {
      const best = this.#best(addr, this.#takeable(addr, up.filter((w) => w.link !== cur)));
      if (best !== null) this.#promote(addr, best, "lost");
      else if (cur !== null && mine !== undefined && mine.missed >= DEAD_PINGS && this.#mainOn(addr)) {
        // Its one connection: the station has not answered on it DEAD_PINGS times: let go, and the station dialled
        // anew. iroh keeps the connection up across its paths, but not off one that only loses most of what goes: the
        // dial goes on each other relay's own endpoint too (`#dialAll`).
        const credentials = cur.credentials;
        this.dropLink(addr);
        this.#lostMain.add(addr);
        this.#env.runner.fork(Effect.ignore(this.link(addr, credentials, undefined, undefined, "again"), { log: "Unhandled", message: "link opened" }));
      }
      return;
    }
    const held = this.#directHeld(addr);
    // A way gone direct and answering clearly quicker is taken at once: the station is on the LAN (or a hole was punched
    // to it), where a relay only adds its round trip. A phone that came back to the app on its station's LAN went on
    // through a relay as that link came through first, and stayed there for minutes (BETTER_TICKS, MIN_STAY_MS) while
    // the direct way waited its turn (2026-10-17).
    if (!held && mine.samples > 0 && mine.link.pinned !== LAN) {
      // One on the LAN endpoint is taken over the main endpoint's punched path as well: that one stopped answering seconds
      // after it opened.
      const lan = up.find((w) => w.link !== cur && w.link.pinned === LAN && w.samples > 0 && w.missed === 0);
      if (lan !== undefined && (mine.key() === "direct" || clearlyBetter(this.#score(addr, mine), this.#score(addr, lan)))) {
        this.#promote(addr, lan, "lan");
        return;
      }
      const direct = mine.key() === "direct" ? null : this.#best(addr, up.filter((w) => w.link !== cur && w.samples > 0 && w.missed === 0 && w.key() === "direct" && !this.#avoided(addr, w)));
      if (direct !== null && clearlyBetter(this.#score(addr, mine), this.#score(addr, direct))) {
        this.#promote(addr, direct, "direct");
        return;
      }
    }
    // Back to the main endpoint once it is healthy again and no worse than a pinned rescue relay.
    if (this.#mainOn(addr) && mine.link.pinned !== null && mine.link.pinned !== LAN && mine.link.pinned !== TAILNET) {
      const mainWay = up.find((w) => w.link.pinned === null && w.samples >= MIN_SAMPLES && w.missed === 0 && !this.#avoided(addr, w));
      if (
        mainWay !== undefined &&
        !clearlyBetter(this.#score(addr, mainWay), this.#score(addr, mine)) &&
        (mainWay.key() === mine.key() || now !== null || this.now() - (this.#movedAt.get(addr) ?? -Infinity) >= MIN_STAY_MS)
      ) {
        this.#promote(addr, mainWay, "main");
        return;
      }
    }
    if (mine.samples < MIN_SAMPLES) return;
    if (now === null && this.now() - (this.#movedAt.get(addr) ?? -Infinity) < MIN_STAY_MS) return;
    const best = this.#best(addr, up.filter((w) => w.link !== cur && w.samples >= MIN_SAMPLES && !this.#avoided(addr, w)));
    for (const w of ways) if (w !== best) w.better = 0;
    if (best === null) return;
    if (!clearlyBetter(this.#score(addr, mine), this.#score(addr, best))) {
      best.better = 0;
      return;
    }
    best.better++;
    if (now !== null || best.better >= BETTER_TICKS) this.#promote(addr, best, now ?? "better");
  }

  /// Whether `way` goes direct: on the LAN endpoint, or on a path iroh punched.
  #isDirect(way: Way): boolean {
    return way.link.pinned === LAN || way.key() === "direct";
  }

  /// Whether no way direct is moved to now (FLAKY_LOSSES).
  #directHeld(addr: string): boolean {
    return this.now() < (this.#directHeldUntil.get(addr) ?? -Infinity);
  }

  /// Whether the requests keep off `way` while another is up: a way direct while those are held off (FLAKY_LOSSES), the
  /// main endpoint's while the station was reached on the LAN endpoint lately (LAN_RECALL_MS).
  #avoided(addr: string, way: Way): boolean {
    if (this.#directHeld(addr) && this.#isDirect(way)) return true;
    return way.link.pinned === null && this.now() - (this.#lanAt.get(addr) ?? -Infinity) < LAN_RECALL_MS;
  }

  /// Of `ways`, those requests may move to: those not avoided (`#avoided`; all, if every one is).
  #takeable(addr: string, ways: Way[]): Way[] {
    const others = ways.filter((w) => !this.#avoided(addr, w));
    return others.length > 0 ? others : ways;
  }

  /// The way direct the requests went on was lost, `stayed` after they moved to it: one lost soon after, FLAKY_LOSSES
  /// times in a row, holds ways direct off a while (how long, or null); one that stayed MIN_STAY_MS starts the count anew.
  #lostDirect(addr: string, stayed: number): number | null {
    if (stayed >= MIN_STAY_MS) {
      this.#directLosses.delete(addr);
      return null;
    }
    const n = (this.#directLosses.get(addr) ?? 0) + 1;
    this.#directLosses.set(addr, n);
    if (n < FLAKY_LOSSES) return null;
    const hold = Math.min(DIRECT_HOLD_MS * 2 ** (n - FLAKY_LOSSES), DIRECT_HOLD_MAX_MS);
    this.#directHeldUntil.set(addr, this.now() + hold);
    return hold;
  }

  /// No more requests go on `way`; it is closed RETIRE_MS later, unless they went back to it meanwhile (replies under way
  /// on it come meanwhile: a large one, a read that just moved off it).
  #retire(addr: string, way: Way): void {
    this.#ways.set(
      addr,
      (this.#ways.get(addr) ?? []).filter((w) => w !== way),
    );
    this.#retiring.add(way.link);
    this.#env.runner.fork(
      Effect.andThen(
        Effect.sleep(RETIRE_MS),
        Effect.sync(() => {
          this.#retiring.delete(way.link);
          if (this.#isCurrent(addr, way.link)) return;
          way.link.close();
          this.#count(addr, way.link);
          this.#env.runner.fork(this.#letGo());
        }),
      ),
    );
  }

  /// Lets go of the ways not worth keeping: one that missed DEAD_PINGS pings, one of two going the same way, and past
  /// KEEP_WAYS the worst of those pinged MIN_SAMPLES times (never the one requests go on).
  #prune(addr: string): void {
    const cur = this.current(addr);
    for (const w of this.#live(addr)) if (w.link !== cur && w.missed >= DEAD_PINGS) this.#retire(addr, w);
    const byKey = new Map<string, Way>();
    for (const w of this.#live(addr)) {
      // Not before it was pinged MIN_SAMPLES times: a link on the main endpoint goes through a relay at first, and direct
      // once a hole is punched; let go as the twin of that relay's own, it never went direct (2026-10-17).
      if (w.link !== cur && w.samples < MIN_SAMPLES) continue;
      const k = w.key();
      const other = byKey.get(k);
      if (other === undefined) {
        byKey.set(k, w);
        continue;
      }
      const keep = other.link === cur ? other : w.link === cur ? w : this.#score(addr, w).score < this.#score(addr, other).score ? w : other;
      this.#retire(addr, keep === w ? other : w);
      byKey.set(k, keep);
    }
    // Once the main endpoint is current and healthy again after a rescue fan-out (and no bulk transfer recently
    // explored pinned relays), retire leftover rescue pinned relay ways so unused pinned endpoints can close.
    const mine = this.#live(addr).find((w) => w.link === cur);
    const bulkActive = this.now() - Math.max(this.#bulkExploredAt.get(addr) ?? -Infinity, this.#bulkUsedAt.get(addr) ?? -Infinity) < BULK_EXPLORE_MS;
    if (this.#rescued.has(addr) && this.#mainOn(addr) && cur !== null && cur.pinned === null && mine !== undefined && mine.samples >= MIN_SAMPLES && mine.missed === 0 && !bulkActive) {
      this.#rescued.delete(addr);
      for (const w of this.#live(addr)) {
        if (w.link !== cur && w.link.pinned !== null && w.link.pinned !== LAN && w.link.pinned !== TAILNET) {
          this.#retire(addr, w);
        }
      }
    }
    // Keep up to KEEP_WAYS - 1 backups besides current: the best interactive backup first, then best bulk backups.
    const others = this.#live(addr).filter((w) => w.link !== cur && w.samples >= MIN_SAMPLES);
    const budget = Math.max(0, KEEP_WAYS - 1);
    if (others.length > budget) {
      const kept = new Set<Way>();
      const byInteractive = [...others].sort((a, b) => Number(this.#avoided(addr, a)) - Number(this.#avoided(addr, b)) || this.#score(addr, a).score - this.#score(addr, b).score);
      if (budget > 0 && byInteractive[0] !== undefined) kept.add(byInteractive[0]);
      if (kept.size < budget) {
        const byBulk = others
          .filter((w) => !kept.has(w))
          .sort((a, b) => Number(this.#avoided(addr, a)) - Number(this.#avoided(addr, b)) || this.#bulkScore(addr, a) - this.#bulkScore(addr, b));
        for (const w of byBulk) {
          if (kept.size >= budget) break;
          kept.add(w);
        }
      }
      for (const w of others) if (!kept.has(w)) this.#retire(addr, w);
    }
  }

  /// Dials the station on the ways not open to it (the main endpoint, each relay's own; `mainOnly`: the main endpoint
  /// alone), each come through a way.
  #explore(addr: string, credentials: CredentialSource, mainOnly = false): Effect.Effect<void> {
    return Effect.gen({ self: this }, function* () {
      if (this.#exploring.has(addr)) return;
      this.#exploring.add(addr);
      this.#mainDialledAt.set(addr, this.now());
      if (!mainOnly) this.#exploredAt.set(addr, this.now());
      const have = new Set(this.#live(addr).map((w) => pinnedIdentity(w.link.pinned)));
      const relays = this.relaysFor(addr);
      const tries: Effect.Effect<Link, CoreError>[] = [];
      // Not while the LAN endpoint reaches it: the requests keep off the main endpoint then (LAN_RECALL_MS).
      const onLan = this.now() - (this.#lanAt.get(addr) ?? -Infinity) < LAN_RECALL_MS;
      if (!have.has("main") && !onLan && this.#mainOn(addr)) tries.push(this.#dialMain(addr, this.#endpoint, relays, credentials, false, undefined));
      if (!mainOnly) {
        const candidates = this.#pinnable(addr).filter((r) => !have.has(pinnedIdentity(r)) && !this.#isDialingPinned(addr, r));
        for (const r of this.#filterDeadRelays(candidates, tries.length > 0 || have.size > 0)) {
          tries.push(this.#dialPinned(addr, r, credentials, false, undefined));
        }
      }
      yield* Effect.all(
        tries.map((attempt) => Effect.map(Effect.result(attempt), (r) => (r._tag === "Success" ? this.#adopt(addr, r.success) : undefined))),
        { concurrency: "unbounded" },
      );
      this.#exploring.delete(addr);
    });
  }

  /// What went over each way to the station since the last tick, a line each tick while lines are kept (record.ts): the
  /// bytes in and out of each link, and of each of its paths the packets sent and lost since, its round trip.
  #recordWays(addr: string): void {
    const parts: string[] = [];
    for (const w of this.#live(addr)) {
      const stats = w.link.connStats();
      const was = this.#recorded.get(w.link) ?? { rx: 0, tx: 0, paths: new Map<string, [number, number]>() };
      const paths = w.link.connPaths().map((p) => {
        const [tx0, lost0] = was.paths.get(p.id) ?? [0, 0];
        was.paths.set(p.id, [p.txPackets, p.lostPackets]);
        return `${p.selected ? "*" : ""}${p.relay !== null ? relayHost(p.relay) : (p.ip ?? "direct")} ${p.rttMs === null ? "?" : `${Math.round(p.rttMs)}ms`} +${p.txPackets - tx0}/${p.lostPackets - lost0}`;
      });
      parts.push(`${w.link.pinned ?? "main"} in=+${stats.rxBytes - was.rx}B out=+${stats.txBytes - was.tx}B missed=${w.missed} [${paths.join("; ")}]`);
      was.rx = stats.rxBytes;
      was.tx = stats.txBytes;
      this.#recorded.set(w.link, was);
    }
    if (parts.length > 0) record(this.#env.host, "conn ways", () => `${stationTag(addr)} ${parts.join(" | ")}`);
  }

  /// Synchronous post-hot decisions for one `#steer` tick (run inside `#withSnap`).
  #afterHotOnTick(addr: string): void {
    this.#suspect(addr);
    this.#choose(addr, null);
    this.#prune(addr);
    // The way direct requests moved to stayed: one lost after this is not lost soon after.
    if (this.#movedDirect.get(addr) === true && this.now() - (this.#movedAt.get(addr) ?? Infinity) >= MIN_STAY_MS) this.#directLosses.delete(addr);
    const live = this.#live(addr);
    if (live.some((w) => this.#isDirect(w))) this.#directAt.set(addr, this.now());
    if (live.some((w) => w.link.pinned === LAN && w.missed === 0 && w.samples > 0)) this.#lanAt.set(addr, this.now());
    if (live.some((w) => w.link.pinned === TAILNET && w.missed === 0 && w.samples > 0)) this.#tailnetAnswered.add(addr);
    const credentials = (this.current(addr) ?? live[0]?.link)?.credentials;
    if (credentials === undefined) return;
    // One connection on the main endpoint: no other ways to dial, compare or move to (iroh moves its packets).
    // If a fallback left the station on pinned relays with no main link alive, periodically redial main to recover it.
    if (this.#mainOn(addr)) {
      if (
        !live.some((w) => w.link.pinned === null) &&
        // Not for the punched path while the LAN endpoint reaches it: the requests keep off that (LAN_RECALL_MS).
        this.now() - (this.#lanAt.get(addr) ?? -Infinity) >= LAN_RECALL_MS
      ) {
        const recentDirect = this.now() - (this.#directAt.get(addr) ?? -Infinity) < DIRECT_RECALL_MS;
        const interval = recentDirect ? REDIAL_MAIN_MS : MAIN_RECOVER_MS;
        if (this.now() - (this.#mainDialledAt.get(addr) ?? -Infinity) >= interval) {
          this.#env.runner.fork(this.#explore(addr, credentials, true));
        }
      }
      return;
    }
    for (const kind of AT_ADDRESSES) this.#dialAtIf(addr, kind, credentials);
    if (this.now() - (this.#exploredAt.get(addr) ?? 0) >= EXPLORE_MS) this.#env.runner.fork(this.#explore(addr, credentials));
  }

  #steerSleepMs(addr: string): number {
    if (!this.#isIdle(addr) || !this.#mainOn(addr)) return TICK_MS;
    if (this.#racing.has(addr) || this.#exploring.has(addr)) return TICK_MS;
    const cur = this.current(addr);
    const live = this.#live(addr);
    if (cur === null || !cur.usable() || cur.pinned !== null) return TICK_MS;
    if (live.length !== 1 || live[0]!.link !== cur || live[0]!.samples < MIN_SAMPLES || live[0]!.missed !== 0) return TICK_MS;
    const id = endpointId(addr);
    const budget = this.#hotBudgetFor(id);
    if (
      budget > 0 &&
      !this.#hot.has(id) &&
      this.now() - cur.openedAt < HOT_SETTLE_MS + TICK_MS &&
      this.now() - (this.#relaxedAt.get(id) ?? -Infinity) < HOT_SETTLE_MS + TICK_MS
    ) {
      return TICK_MS;
    }
    return IDLE_TICK_MS;
  }

  /// While the station has a way open: every TICK_MS (or IDLE_TICK_MS while settled and idle) each pinged, the requests
  /// moved to the best (`#choose`), the ways not worth keeping let go (`#prune`), and every EXPLORE_MS the others
  /// dialled again (`#explore`); the main endpoint's link, gone from a station on pinned relays, retried to recover it.
  #steer(addr: string): Effect.Effect<void> {
    return Effect.gen({ self: this }, function* () {
      for (;;) {
        const waitMs = this.#steerSleepMs(addr);
        const curBefore = this.current(addr);
        if (waitMs > TICK_MS && curBefore !== null) {
          const wake = Deferred.makeUnsafe<void>();
          this.#steerWakes.set(addr, wake);
          yield* Effect.raceFirst(
            laterSleep(waitMs),
            Effect.raceFirst(Deferred.await(wake), Effect.asVoid(curBefore.conn.closed())),
          );
          if (this.#steerWakes.get(addr) === wake) this.#steerWakes.delete(addr);
        } else {
          yield* laterSleep(TICK_MS);
        }
        if (this.#closed || !this.#links.has(addr)) break;
        const cur = this.current(addr);
        const before = this.#live(addr);
        if (before.length === 0 && (cur === null || !cur.usable())) break;
        yield* this.#sample(addr, before);
        const relax = this.#withSnap(addr, () => {
          this.#tellHealth(addr);
          for (const w of this.#live(addr)) this.#watchPaths(addr, w);
          if (recording(this.#env.host)) this.#recordWays(addr);
          recordDht(this.#env.host, this.#endpoint, TICK_MS);
          const eff = this.#updateHotOnTick(addr);
          if (eff !== Effect.void) return eff;
          this.#afterHotOnTick(addr);
          return null;
        });
        if (relax !== null) {
          yield* relax;
          if (this.#closed || !this.#links.has(addr)) break;
          this.#withSnap(addr, () => this.#afterHotOnTick(addr));
        }
      }
      this.#steering.delete(addr);
    });
  }

  /// 2026-10-17: a phone's punched paths went quiet seconds after they opened, which no Mac on the LAN did again
  ///. Each tick, a `mesh.path` span says a way's paths changed (one opened, one went, another chosen)
  /// (or first seen, direct) or that it missed its first ping in a row: its paths now and as the tick before saw them,
  /// round trips and counts.
  #watchPaths(addr: string, w: Way): void {
    const shape = w.link.pathShape();
    const paths = w.link.paths();
    // First seen, a way is told if it is direct already (iroh punches within a second, well before a tick).
    const changed = w.shape === null ? w.link.path() === "direct" : shape !== w.shape;
    const missed = w.missed === 1;
    if (changed || missed) {
      const span = this.#env.tracer.span("mesh.path", Kind.Internal);
      span.own("station", endpointId(addr));
      span.own("way", w.key());
      span.own("why", changed && missed ? "paths missed" : changed ? "paths" : "missed");
      span.own("current", w.link === this.current(addr));
      span.own("paths", paths);
      if (w.saw !== null) span.own("before.paths", w.saw);
      span.end();
    }
    w.shape = shape;
    w.saw = paths;
  }

  /// The way a read slow on `link` is asked on as well: the best other way open, going another way than `link` (not the
  /// main endpoint through the same relay), whose last ping was answered (one not pinged yet: its handshake was).
  standby(addr: string, link: Link): Link | null {
    const ways = this.#live(addr);
    const key = ways.find((w) => w.link === link)?.key() ?? null;
    return this.#best(addr, ways.filter((w) => w.link !== link && w.missed === 0 && w.key() !== key))?.link ?? null;
  }

  /// Open ways suitable for bulk transfers, deduplicated by way key and ordered by `#bulkScore` ascending.
  bulkLinks(addr: string): Link[] {
    const alive = this.#live(addr).filter((w) => w.missed < DEAD_PINGS && !this.#wayOff(addr, w.link));
    const pool = this.#takeable(addr, alive);
    const byKey = new Map<string, Way>();
    for (const w of pool) {
      const k = w.key();
      const prev = byKey.get(k);
      if (prev === undefined || this.#bulkScore(addr, w) < this.#bulkScore(addr, prev)) byKey.set(k, w);
    }
    return [...byKey.values()].sort((a, b) => this.#bulkScore(addr, a) - this.#bulkScore(addr, b)).map((w) => w.link);
  }

  /// Fast open bulk ways suitable for concurrent striped transfers: only includes proven fast ways (LAN, measured
  /// >= BULK_SLOW_BPS, or unmeasured low-RTT direct). Unmeasured relays are never mixed into multi-way striping; when
  /// no proven fast way exists, falls back to the single best low-RTT (or best overall) unmeasured way.
  fastBulkLinks(addr: string): Link[] {
    const ways = this.#live(addr);
    const candidates = this.bulkLinks(addr).flatMap((l) => {
      const w = ways.find((x) => x.link === l);
      return w !== undefined && w.missed === 0 ? [w] : [];
    });
    const proven: Link[] = [];
    let bestLowRttUnmeasured: Link | null = null;
    let bestUnmeasured: Link | null = null;
    for (const w of candidates) {
      const l = w.link;
      if (l.pinned === LAN) {
        proven.push(l);
        continue;
      }
      const sk = l.speedKey();
      const bps = sk !== null ? this.speed(addr, sk) : null;
      if (bps !== null) {
        if (bps >= BULK_SLOW_BPS) proven.push(l);
      } else {
        const rtt = this.#wayRtt(w);
        if (w.key() === DIRECT && rtt <= 600) {
          proven.push(l);
        } else {
          if (bestUnmeasured === null) bestUnmeasured = l;
          if (bestLowRttUnmeasured === null && rtt <= 600) bestLowRttUnmeasured = l;
        }
      }
    }
    if (proven.length > 0) return proven;
    const fallback = bestLowRttUnmeasured ?? bestUnmeasured;
    return fallback !== null ? [fallback] : [];
  }

  /// Standby link for hedging or failing over a slow bulk transfer: never hedges a healthy/unmeasured way onto one
  /// known to be below BULK_SLOW_BPS; when `link` itself is below BULK_SLOW_BPS, allows faster alternatives ordered by
  /// `#bulkScore`.
  bulkStandby(addr: string, link: Link): Link | null {
    const ways = this.#live(addr);
    const curSk = link.speedKey();
    const curBps = curSk !== null ? this.speed(addr, curSk) : null;
    const floor = curBps !== null && curBps < BULK_SLOW_BPS ? curBps : BULK_SLOW_BPS;
    for (const l of this.bulkLinks(addr)) {
      if (l === link) continue;
      const w = ways.find((x) => x.link === l);
      if (w === undefined || w.missed !== 0) continue;
      const sk = l.speedKey();
      const bps = sk !== null ? this.speed(addr, sk) : null;
      if (bps !== null && bps < floor) continue;
      return l;
    }
    return null;
  }

  /// A live standby bulk way that is at least 2x better than `link` (half the expected `#bulkScore` transfer time),
  /// or null when no clearly better alternative exists.
  betterBulkStandby(addr: string, link: Link): Link | null {
    const candidate = this.bulkStandby(addr, link);
    if (candidate === null) return null;
    const ways = this.#live(addr);
    const curWay = ways.find((w) => w.link === link);
    const candWay = ways.find((w) => w.link === candidate);
    if (candWay === undefined) return null;
    if (curWay === undefined) return candidate;
    return this.#bulkScore(addr, candWay) < 0.5 * this.#bulkScore(addr, curWay) ? candidate : null;
  }

  /// Relays that may be dialled pinned for bulk transfers (allows the single relay when main is on direct).
  #bulkRelays(addr: string): string[] {
    const pinnable = this.#pinnable(addr);
    if (pinnable.length > 0) return pinnable;
    const ways = this.#waysFor(addr);
    if (this.#mainOn(addr) && ways.length === 1 && this.current(addr)?.path() === "direct") return ways;
    return [];
  }

  /// On-demand pinned relay exploration when the best bulk way is known to be below BULK_SLOW_BPS.
  #maybeExploreBulk(addr: string, credentials?: CredentialSource): void {
    if (this.#closed || this.#exploring.has(addr)) return;
    const cur = this.current(addr);
    if (cur?.pinned === LAN) return;
    const now = this.now();
    if (now - (this.#bulkExploredAt.get(addr) ?? -Infinity) < BULK_EXPLORE_MS) return;
    const best = this.bulkLinks(addr)[0] ?? cur;
    if (best === null) return;
    const sk = best.speedKey();
    const bps = sk !== null ? this.speed(addr, sk) : null;
    if (bps === null || bps >= BULK_SLOW_BPS) return;
    const live = this.#live(addr);
    const missing = this.#bulkRelays(addr).filter((r) => !live.some((w) => (w.link.pinned !== null && sameRelay(w.link.pinned, r)) || w.key() === relayKey(r)));
    if (missing.length === 0) return;
    const creds = credentials ?? cur?.credentials;
    if (creds === undefined) return;
    this.#bulkExploredAt.set(addr, now);
    this.#env.runner.fork(this.#exploreBulk(addr, creds, missing));
  }

  #exploreBulk(addr: string, credentials: CredentialSource, relays: string[]): Effect.Effect<void> {
    return Effect.gen({ self: this }, function* () {
      if (this.#exploring.has(addr)) return;
      const have = new Set(this.#live(addr).map((w) => pinnedIdentity(w.link.pinned)));
      const targets = this.#filterDeadRelays(
        relays.filter((r) => !have.has(pinnedIdentity(r)) && !this.#isDialingPinned(addr, r)),
        true,
      );
      if (targets.length === 0) return;
      this.#exploring.add(addr);
      yield* Effect.all(
        targets.map((r) => Effect.map(Effect.result(this.#dialPinned(addr, r, credentials, false, undefined)), (res) => (res._tag === "Success" ? this.#adopt(addr, res.success) : undefined))),
        { concurrency: "unbounded" },
      ).pipe(Effect.ensuring(Effect.sync(() => this.#exploring.delete(addr))));
    });
  }

  /// Best link for a bulk transfer, opening the primary link first and exploring pinned relays on demand if slow.
  bulkLink(addr: string, credentials: CredentialSource, theirs?: readonly string[], off?: readonly string[], asker?: string): Effect.Effect<Link, CoreError> {
    return Effect.map(this.link(addr, credentials, theirs, off, asker), (cur) => {
      this.#bulkUsedAt.set(addr, this.now());
      this.#maybeExploreBulk(addr, credentials);
      return this.bulkLinks(addr)[0] ?? cur;
    });
  }

  /// Bulk link for a striped lane, spreading concurrent parts across fast bulk ways (or alternate bulk ways on retry).
  bulkLinkAt(addr: string, lane: number, credentials: CredentialSource, theirs?: readonly string[], off?: readonly string[], asker?: string): Effect.Effect<Link, CoreError> {
    return Effect.map(this.link(addr, credentials, theirs, off, asker), (cur) => {
      this.#bulkUsedAt.set(addr, this.now());
      this.#maybeExploreBulk(addr, credentials);
      const fast = this.fastBulkLinks(addr);
      if (fast.length >= 2 || (lane === 0 && fast.length > 0)) return fast[Math.abs(lane) % fast.length]!;
      const all = this.bulkLinks(addr);
      if (all.length > 0) return all[Math.abs(lane) % all.length]!;
      return cur;
    });
  }

  /// How long a read on `link` waits for its answer head before it is asked on another way as well: RTT plus four
  /// deviations, clamped to [HEDGE_FLOOR_MS, HEDGE_MAX_MS].
  hedgeAfter(addr: string, link: Link): number {
    const w = this.#live(addr).find((x) => x.link === link);
    if (w === undefined || w.samples === 0) return HEDGE_FLOOR_MS;
    return Math.min(HEDGE_MAX_MS, Math.max(HEDGE_FLOOR_MS, w.srtt + 4 * w.dev));
  }

  /// A read asked on `slow` and then on another way as well was answered on the other first, `ms` after it was asked on
  /// `slow`: that long counts as a ping of `slow` (the requests move as the pings decide, not on one read).
  outran(addr: string, slow: Link, ms: number): void {
    this.#live(addr).find((x) => x.link === slow)?.note(ms);
  }

  /// Every way to the station as pinged: the round trip of each way open (its relay's host, "tailnet" or "direct"), then each
  /// relay with no way open on it now (not reached, or let go: no figure).
  measured(addr: string): Measured | null {
    const ways = this.#live(addr).filter((w) => w.samples > 0);
    const measuring = this.#exploring.has(addr);
    if (ways.length === 0 && !measuring) return null;
    const relays: [string, number | null][] = [];
    const seen = new Set<string>();
    for (const w of [...ways].sort((a, b) => a.srtt - b.srtt)) {
      const key = w.key() === LAN ? "direct" : w.key();
      if (seen.has(key)) continue;
      seen.add(key);
      const via = w.link.via();
      relays.push([via !== null ? relayHost(via) : key === TAILNET ? TAILNET : "direct", Math.round(w.srtt)]);
    }
    for (const r of this.#waysFor(addr)) if (!seen.has(relayKey(r))) relays.push([relayHost(r), null]);
    return { measuring, relays, moved: this.#moved.get(addr) ?? null };
  }

  /// The ways to a station dialled and pinged now, as a person asks; the requests moved to the best if it is clearly
  /// better.
  remeasure(addr: string): Effect.Effect<void, CoreError> {
    return Effect.gen({ self: this }, function* () {
      const link = this.current(addr);
      if (link === null || !link.usable()) return yield* Effect.fail(meshError(t("core-logic.mesh.not_connected")));
      this.#deadRelays.clear();
    this.#deadRelayFails.clear();
      this.#handshakeRescueCooldown.clear();
      yield* this.#explore(addr, link.credentials);
      for (let i = 0; i <= MIN_SAMPLES; i++) yield* this.#sample(addr);
      this.#choose(addr, "asked");
      this.#prune(addr);
    });
  }

  /// The endpoint on `relay` alone: relay-only, no lookups, no IP transports. With lookups it found where a station was
  /// at home and went onto that relay too, and with an entry that was the same relay under two URLs, one key on it twice
  /// (2026-10-08); with IP transports, a way said to go through a relay went direct.
  #pinnedEndpoint(relay: string): Effect.Effect<IrohEndpoint | null> {
    return Effect.gen({ self: this }, function* () {
      if (this.#closed) return null;
      const existing = this.#pinned.get(relay);
      if (existing) return yield* Deferred.await(existing);
      const d = Deferred.makeUnsafe<IrohEndpoint | null>();
      this.#pinned.set(relay, d);
      // The LAN endpoint, the Tailscale one: on no relay, so each looks nothing up and punches no hole; it dials
      // addresses alone.
      // A fence's: at home on its relays alone, with IP transports (paths punched through them), looking nothing up.
      const fence = this.#fences.get(relay);
      const self = this;
      let settled = false;
      this.#env.runner.fork(
        Effect.ensuring(
          Effect.gen(function* () {
            const bound = yield* Effect.result(
              relay === LAN || relay === TAILNET
                ? Mesh.#bind(self.#env.iroh, pinnedKey(self.#secret, relay), [], false, false, [], [], [], false)
                : fence !== undefined
                  ? Mesh.#bind(self.#env.iroh, pinnedKey(self.#secret, relay), fence, false, false, [], [], fence, false)
                  : Mesh.#bind(self.#env.iroh, pinnedKey(self.#secret, relay), [relay], true, false, [], [], [relay], false),
            );
            const endpoint = bound._tag === "Success" ? bound.success : null;
            if (endpoint === null) {
              if (self.#pinned.get(relay) === d) self.#pinned.delete(relay);
              settled = true;
              Deferred.doneUnsafe(d, Effect.succeed(null));
              return;
            }
            if (self.#closed || self.#pinned.get(relay) !== d) {
              self.#env.runner.fork(endpoint.close());
              settled = true;
              Deferred.doneUnsafe(d, Effect.succeed(null));
              return;
            }
            settled = true;
            Deferred.doneUnsafe(d, Effect.succeed(endpoint));
          }),
          Effect.sync(() => {
            if (!settled) {
              if (self.#pinned.get(relay) === d) self.#pinned.delete(relay);
              Deferred.doneUnsafe(d, Effect.succeed(null));
            }
          }),
        ),
      );
      return yield* Deferred.await(d);
    });
  }

  /// Closes the pinned endpoints no way is on, unless something is being dialled meanwhile.
  #letGo(): Effect.Effect<void> {
    return Effect.gen({ self: this }, function* () {
      if (this.#dialing > 0) return;
      const used = new Set<string>();
      for (const ways of this.#ways.values()) for (const w of ways) if (w.link.pinned !== null && w.link.usable()) used.add(w.link.pinned);
      for (const [, l] of this.#openLinks()) if (l.pinned !== null) used.add(l.pinned);
      for (const l of this.#retiring) if (l.pinned !== null && l.usable()) used.add(l.pinned);
      for (const [relay, d] of [...this.#pinned]) {
        if (used.has(relay)) continue;
        this.#pinned.delete(relay);
        const e = yield* Deferred.await(d);
        if (e) this.#env.runner.fork(e.close());
      }
    });
  }

  /// As the UI comes back or the network changes: iroh is told, each open link races a new one, each link still
  /// opening has another tried beside it.
  #watch(): Effect.Effect<void> {
    return Effect.gen({ self: this }, function* () {
      for (;;) {
        const wake = yield* this.#env.wakes.next;
        if (wake.checksConnections() || wake.suspectsConnections()) this.#wakeGen++;
        if (wake.checksConnections()) for (const [addr, link] of this.#openLinks()) this.#env.runner.fork(this.#checkWoken(addr, link));
        if (!wake.suspectsConnections()) continue;
        this.#relaxAll();
        for (const addr of [...this.#steerWakes.keys()]) this.#wakeSteer(addr);
        this.#env.runner.fork(this.#endpoint.networkChange());
        recordDht(this.#env.host, this.#endpoint);
        record(this.#env.host, "conn network-change", () => `told the main endpoint (${wake.network ? "the network changed" : wake.retry ? "retry" : `the UI back after ${Math.round(wake.away / 1000)}s`}), ${this.#openLinks().length} link(s) open, ${this.#pinned.size} relay endpoint(s) not told`);
        // On another network, the speeds seen on the last say nothing of how fast each way is from here (a laptop taken
        // from home would keep the relay it was fast through there, however slowly it brings replies now): found anew.
        if (wake.network) this.#forgetSpeeds();
        if (wake.network || wake.retry) {
          this.#netGen++;
          this.#deadRelays.clear();
          this.#deadRelayFails.clear();
          this.#unansweredAt.clear();
          this.#handshakeRescueCooldown.clear();
        }
        // On another network now, perhaps the station's: its LAN addresses are worth a try again.
        this.#tried.clear();
        // (and its tailnet: dialled again on it only once it answered there again)
        this.#tailnetAnswered.clear();
        for (const [addr, link] of this.#openLinks()) {
          if (this.#racing.has(addr)) continue;
          this.#racing.add(addr);
          this.#env.runner.fork(this.#race(addr, link));
        }
        for (const [addr, h] of this.#hedges) {
          if (h.tx === null) continue;
          const tx = h.tx;
          h.tx = null;
          this.#env.runner.fork(this.#hedge(addr, h.credentials, tx, h.control));
        }
      }
    });
  }

  #tally(): Effect.Effect<void> {
    return Effect.forever(
      Effect.andThen(
        laterSleep(TALLY_EVERY_MS),
        Effect.sync(() => {
          for (const [addr, o] of this.#links) if (o.result && "ok" in o.result) this.#count(addr, o.result.ok);
          this.#keepDays();
        }),
      ),
    );
  }

  /// A link tried beside an opening still under way: on an endpoint bound anew if nothing is open on this one.
  #hedge(addr: string, credentials: CredentialSource, tx: Deferred.Deferred<Link, CoreError>, control: DialControl): Effect.Effect<void> {
    return Effect.gen({ self: this }, function* () {
      if (control.cancelled) {
        Deferred.doneUnsafe(tx, Effect.fail(unreached({ message: "dial cancelled" })));
        return;
      }
      const endpoint = this.#anyOpen() ? this.#endpoint : yield* this.#rebind();
      if (control.cancelled) {
        Deferred.doneUnsafe(tx, Effect.fail(unreached({ message: "dial cancelled" })));
        return;
      }
      const span = this.#env.tracer.span("mesh.hedge", Kind.Internal);
      span.own("station", endpointId(addr));
      span.own("relay", relayStatus(endpoint));
      const opened = yield* Effect.result(this.#dialAll(addr, endpoint, credentials, false, span.context, control));
      if (opened._tag === "Failure") span.fail();
      span.end();
      const taken = Deferred.doneUnsafe(tx, opened._tag === "Success" ? Effect.succeed(opened.success) : Effect.fail(opened.failure));
      if (!taken) {
        cancelDial(control);
        if (opened._tag === "Success") {
          opened.success.close();
          if (this.#dialing === 0) this.#env.runner.fork(this.#letGo());
        }
      }
    });
  }

  /// The UI is back from a short while away, its keepalives frozen meanwhile: the link is asked now, not at its next
  /// ping, and one that does not answer soon has a new link raced beside it. One that answers costs a round trip.
  #checkWoken(addr: string, link: Link): Effect.Effect<void> {
    return Effect.gen({ self: this }, function* () {
      if (this.#racing.has(addr) || this.#checking.has(addr)) return;
      this.#checking.add(addr);
      const last = this.#live(addr).find((w) => w.link === link)?.answeredMs ?? null;
      const wait = last === null ? WOKEN_ANSWER_MAX_MS : Math.min(WOKEN_ANSWER_MAX_MS, Math.max(WOKEN_ANSWER_MIN_MS, 2 * last));
      const answered = yield* Effect.ensuring(
        Effect.raceFirst(link.answers(this.#env.runner), Effect.as(Effect.sleep(wait), false)), // timer: a deadline on the answer
        Effect.sync(() => this.#checking.delete(addr)),
      );
      if (answered || this.#closed || !this.#isCurrent(addr, link) || this.#racing.has(addr)) return;
      this.#racing.add(addr);
      // (not `heard`: it has had its time to answer, so whichever comes first is taken, with no grace for the old one)
      this.#env.runner.fork(this.#race(addr, link));
    });
  }

  /// The way the requests go on missed its ping, its last one answered quickly, and no other is up: a new link is raced
  /// beside it at once (`#race`), not after DEAD_PINGS. A station whose process was killed and started again on another
  /// port leaves its old connection open and silent until QUIC's idle timeout: a view of its screen stood still 14 s,
  /// all of it the misses counted (2026-11-11). A way whose pings take near PING_TIMEOUT_MS misses them for its slowness
  /// alone, and is not dialled again for each.
  #suspect(addr: string): void {
    const cur = this.current(addr);
    if (cur === null || this.#racing.has(addr)) return;
    const ways = this.#live(addr);
    const mine = ways.find((w) => w.link === cur);
    if (mine === undefined || mine.missed !== 1 || mine.answeredMs === null || mine.answeredMs >= PING_TIMEOUT_MS / 2) return;
    if (ways.some((w) => w !== mine && w.missed === 0)) return;
    this.#racing.add(addr);
    this.#env.runner.fork(this.#race(addr, cur, true));
  }

  /// A link suspect against a new one opened beside it at once: whichever answers first. On a missed ping (`heard`), if
  /// the new link opens while the old one is still open and probing, hold switching for at most RACE_GRACE_MS so path
  /// rescue on the old connection can finish its control-stream round trip without dropping open streams.
  /// No new link opened, the old one is kept if it answered on its control stream since the race began (`answered`),
  /// whatever began the race: its probe's time run out, it answered as the new dial was still waiting (the side run,
  /// seed 2067651005: a relay back between PROBE_MS and CONNECT_TIMEOUT_MS after a network change, a ping waiting on
  /// it answered, and the read then on it was cut as the old link was let go for the dial's failure).
  #race(addr: string, old: Link, heard = false): Effect.Effect<void> {
    return Effect.gen({ self: this }, function* () {
      const before = old.controlAnswers();
      const answered = () => old.usable() && old.controlAnswers() > before;
      const recovered = () => heard && answered();
      const span = this.#env.tracer.span("mesh.race", Kind.Internal);
      span.own("station", endpointId(addr));
      const raceControl = makeDialControl(false);
      const fresh = Effect.result(this.#dialAll(addr, this.#endpoint, old.credentials, false, span.context, raceControl));
      // (the core's, not this race's: a link it opens after the race is over is still had, to be let go)
      const freshFiber = this.#env.runner.fork(fresh);
      const probeFiber = yield* Effect.forkChild(old.answers(this.#env.runner));
      const first = yield* Effect.raceFirst(
        Effect.map(Fiber.join(probeFiber), (ok) => ({ probe: ok }) as const),
        Effect.map(Fiber.join(freshFiber), (opened) => ({ fresh: opened }) as const),
      );
      let won: "old" | "neither" | "cancelled" | Link;
      if ("probe" in first) {
        if (first.probe) won = "old";
        else {
          const opened = yield* Fiber.join(freshFiber);
          if (opened._tag === "Success" ? recovered() : answered()) {
            if (opened._tag === "Success") opened.success.close();
            won = "old";
          } else won = opened._tag === "Success" ? opened.success : "neither";
        }
      } else if (first.fresh._tag === "Success") {
        const candidate = first.fresh.success;
        if (!this.#isCurrent(addr, old) || this.#closed) {
          candidate.close();
          won = "cancelled";
        } else if (recovered()) {
          candidate.close();
          won = "old";
        } else if (!heard || !old.usable()) {
          won = candidate;
        } else {
          const settled = yield* Effect.raceFirst(
            Effect.map(Fiber.join(probeFiber), (ok) => (ok || recovered() ? ("old" as const) : ("switch" as const))),
            Effect.raceFirst(
              Effect.as(old.nextControlAnswer(before), "old" as const),
              Effect.raceFirst(
                Effect.as(old.conn.closed(), "switch" as const),
                Effect.raceFirst(
                  Effect.as(this.replaced(addr, old), "cancelled" as const),
                  Effect.raceFirst(
                    Effect.as(candidate.conn.closed(), "candidate_closed" as const),
                    Effect.as(Effect.sleep(RACE_GRACE_MS), "switch" as const),
                  ),
                ),
              ),
            ),
          );
          if (settled === "cancelled" || !this.#isCurrent(addr, old) || this.#closed) {
            candidate.close();
            won = "cancelled";
          } else if (settled === "old" && old.usable()) {
            candidate.close();
            won = "old";
          } else if (settled === "candidate_closed" || !candidate.usable()) {
            candidate.close();
            const ok = yield* Fiber.join(probeFiber);
            won = ok || answered() ? "old" : "neither";
          } else {
            won = candidate;
          }
        }
      } else {
        const ok = yield* Fiber.join(probeFiber);
        won = ok || answered() ? "old" : "neither";
      }
      // The new one, opened or still opening, is let go (by a fiber of the core's: one of this race's would be ended with
      // it, and a link opened already left open).
      if (won === "old" || won === "cancelled" || won === "neither") {
        cancelDial(raceControl);
      }
      if (won === "old" || won === "cancelled") {
        this.#env.runner.fork(Effect.map(Fiber.join(freshFiber), (r) => (r._tag === "Success" ? r.success.close() : undefined)));
      }
      this.#racing.delete(addr);
      span.own("race", won === "old" || won === "cancelled" ? "old" : won === "neither" ? "neither" : "new");
      span.end();
      if (won === "neither") this.#dropIf(addr, old);
      else if (won !== "old" && won !== "cancelled") this.#switch(addr, old, won, raceControl);
    });
  }

  close(): Effect.Effect<void> {
    return Effect.gen({ self: this }, function* () {
      this.#closed = true;
      for (const o of this.#links.values()) if (o.controls) for (const c of o.controls) cancelDial(c);
      for (const h of this.#hedges.values()) cancelDial(h.control);
      for (const addr of [...this.#steerWakes.keys()]) this.#wakeSteer(addr);
      for (const [, o] of this.#links) if (o.result && "ok" in o.result) o.result.ok.close();
      this.#links.clear();
      this.#notify();
      for (const ways of this.#ways.values()) for (const w of ways) w.link.close();
      this.#ways.clear();
      for (const l of this.#retiring) l.close();
      this.#retiring.clear();
      for (const [, d] of [...this.#pinned]) {
        const e = yield* Deferred.await(d);
        if (e) yield* e.close();
      }
      this.#pinned.clear();
      const retired = [...this.#retired];
      this.#retired.clear();
      for (const e of retired) yield* e.close();
      yield* this.#endpoint.close();
    });
  }
}

/// What was kept of where stations said they are reached straight (`MeshEnv.addressesKey`), each kind's addresses as strings.
function saidOf(kept: J): Record<string, Said> {
  if (kept === null || typeof kept !== "object" || Array.isArray(kept)) return {};
  const strings = (v: J) => (Array.isArray(v) ? v.filter((a): a is string => typeof a === "string") : []);
  return Object.fromEntries(Object.entries(kept as Record<string, J>).map(([addr, v]) => [addr, { lan: strings(v?.lan), tailnet: strings(v?.tailnet) }]));
}

function relayStatus(endpoint: IrohEndpoint): string {
  const status = endpoint.relayStatus();
  if (status.length === 0) return "none";
  return status.map((s) => `${s.url} ${s.connected ? "up" : "down"}`).join(", ");
}

/// Once the endpoint is on one of its relays (at once with none, or where the dial was given no relay): what a dial's
/// CONNECT_TIMEOUT_MS counts from. Getting onto a relay takes several round trips to it (TCP, TLS, the relay's own), a
/// dozen seconds on a phone 2–4 s from every relay, back from the background (nomofu, 2026-10-30): counted in the dial's
/// time, every dial ended as it was about to be answered, and the next bound the endpoint anew (`#stuck`), to get onto
/// the relays from the start again. Not on one in ONTO_MAX_MS: counted from then.
/// Only a dial given no relay (`noRelays`: the LAN's and the tailnet's endpoints, a dial at addresses alone) counts at
/// once. One given relays waits for one even when it carries addresses a peer said before: those are dialled from the
/// start beside the relays, and where they answer the dial is done long before (the device on that LAN), but a device
/// gone off that network, or a web page that dials no address, carries them all the same: counted at once, every dial
/// ran out before the endpoint was on a relay, and bound it anew, again and again (2026-11-18: the web and Android with
/// all twelve relays down for up to 25 minutes, each dial `rebound`).
type SharedRelayWaiter = {
  readonly connected: Deferred.Deferred<void>;
  readonly waiters: Set<symbol>;
  hasLeader: boolean;
  leaderDone: Deferred.Deferred<void>;
  nextDelay: number;
  settled: boolean;
};

const sharedRelayWaiters = new WeakMap<Pick<IrohEndpoint, "relayStatus">, SharedRelayWaiter>();

function endpointOnARelay(endpoint: Pick<IrohEndpoint, "relayStatus">): boolean {
  const status = endpoint.relayStatus();
  return status.length === 0 || status.some((s) => s.connected);
}

export function onARelay(endpoint: Pick<IrohEndpoint, "relayStatus">, noRelays: boolean): Effect.Effect<void> {
  if (noRelays) return Effect.void;
  return Effect.gen(function* () {
    let shared = sharedRelayWaiters.get(endpoint);
    if (shared === undefined) {
      if (endpointOnARelay(endpoint)) return;
      shared = {
        connected: Deferred.makeUnsafe<void>(),
        waiters: new Set(),
        hasLeader: false,
        leaderDone: Deferred.makeUnsafe<void>(),
        nextDelay: ONTO_FIRST_RECHECK_MS,
        settled: false,
      };
      sharedRelayWaiters.set(endpoint, shared);
    }
    const token = Symbol();
    shared.waiters.add(token);
    const started = yield* Clock.currentTimeMillis;
    const deadline = started + ONTO_MAX_MS;
    const s = shared;
    return yield* Effect.ensuring(
      Effect.gen(function* () {
        for (;;) {
          if (s.settled) return;
          const now = yield* Clock.currentTimeMillis;
          const remaining = deadline - now;
          if (remaining <= 0) return;

          if (!s.hasLeader) {
            s.hasLeader = true;
            const myTurn = s.leaderDone;
            yield* Effect.ensuring(
              Effect.gen(function* () {
                for (;;) {
                  if (s.settled) return;
                  const tNow = yield* Clock.currentTimeMillis;
                  const rem = deadline - tNow;
                  if (rem <= 0) return;
                  const delay = s.nextDelay;
                  if (delay > rem) {
                    yield* Effect.sleep(rem);
                    return;
                  }
                  s.nextDelay = Math.min(delay * 2, ONTO_RECHECK_MS);
                  yield* Effect.sleep(delay);
                  if (s.settled) return;
                  if (endpointOnARelay(endpoint)) {
                    s.settled = true;
                    if (sharedRelayWaiters.get(endpoint) === s) sharedRelayWaiters.delete(endpoint);
                    Deferred.doneUnsafe(s.connected, Effect.void);
                    return;
                  }
                }
              }),
              Effect.sync(() => {
                s.hasLeader = false;
                s.leaderDone = Deferred.makeUnsafe<void>();
                Deferred.doneUnsafe(myTurn, Effect.void);
              }),
            );
            return;
          }

          const turn = s.leaderDone;
          yield* Effect.raceFirst(
            Effect.raceFirst(Deferred.await(s.connected), Deferred.await(turn)),
            Effect.sleep(remaining),
          );
        }
      }),
      Effect.sync(() => {
        s.waiters.delete(token);
        if (s.waiters.size === 0 && sharedRelayWaiters.get(endpoint) === s) {
          sharedRelayWaiters.delete(endpoint);
        }
      }),
    );
  });
}

/// Connects, presents the first credential, and starts renewing it. The credential is asked for while the
/// connection is being made; the link is handed out as soon as the credential is sent (the station reads it before any
/// request stream). A refusal closes the connection; the requests on it fail, and the next `link` starts over.
function open(
  env: MeshEnv,
  endpoint: IrohEndpoint,
  relays: string[],
  stationId: string,
  credentials: CredentialSource,
  fresh: boolean,
  pinned: string | null,
  ctx: SpanContext | undefined,
  ips: string[] = [],
  address: string = stationId,
  onDone?: (attempt: DialAttempt) => void,
  onRelayReady?: () => void,
): Effect.Effect<Link, CoreError> {
  // (the record's: each dial a line as it ends, where lines are kept: record.ts)
  const n = ++dials;
  const stages = { onto: -1, credential: -1, dialled: -1, openBi: -1, sent: -1 };
  let credFailed = false;
  const rec = recording(env.host);
  const leafTrace: PrepareTrace | undefined = rec && env.prepare ? { now: () => 0, stage: "enter", doneMs: -1 } : undefined;
  const startedAt = env.host.nowMs();
  const dial = Effect.suspend(() => {
    const began = env.host.nowMs();
    const monoBegan = env.host.monotonicMs();
    if (leafTrace) leafTrace.now = () => Math.max(0, Math.round(env.host.monotonicMs() - monoBegan));
    const opened = { onto: 0, dialled: 0, credential: 0 };
    const since = () => Math.round(env.host.nowMs() - began);
    let abandoned = false;
    // Its handshake given up with the opening (iroh.ts `connect`): left going, it retransmitted to every way to the
    // station until the connection's idle timeout, ten minutes, beside every dial after it.
    const givenUp = Deferred.makeUnsafe<void>();
    let connection: IrohConnection | null = null;
    const establish = Effect.gen(function* () {
      if (!/^[0-9a-f]{64}$/.test(stationId)) return yield* Effect.fail(CoreError.invalid(t("core-logic.mesh.bad_station_id", { id: stationId })));
      const device = endpoint.id();
      const meshScope = env.prepare ? yield* env.prepare(address, endpoint, leafTrace) : undefined;
      if (leafTrace && leafTrace.doneMs < 0 && !leafTrace.stage.startsWith("skip:")) leafTrace.doneMs = leafTrace.now();
      // A host may finish its native handshake after its caller is interrupted. Keep taking that answer, and close
      // it if this opening has ended. Until the Link is handed out, this opening owns the connection.
      const dialled = Deferred.makeUnsafe<IrohConnection, CoreError>();
      env.runner.fork(
        Effect.gen(function* () {
          const r = yield* Effect.result(endpoint.connect({ id:stationId,relays,...(ips.length > 0 ? {ips} : {}),...(meshScope ? {meshScope} : {})}, env.alpn, [], Deferred.await(givenUp)));
          opened.dialled = since();
          stages.dialled = opened.dialled;
          if (r._tag === "Success") {
            if (abandoned) {
              r.success.close(0, "opening ended");
              return;
            }
            connection = r.success;
          }
          Deferred.doneUnsafe(
            dialled,
            r._tag === "Success"
              ? Effect.succeed(r.success)
              : Effect.fail(isHandshakeConflictMessage(r.failure.message) ? new HandshakeConflict(r.failure.message) : unreached(r.failure)),
          );
        }),
      );
      const had = Effect.ensuring(
        Effect.tapError(credentials(device, fresh), () =>
          Effect.sync(() => {
            credFailed = true;
          }),
        ),
        Effect.sync(() => {
          opened.credential = since();
          stages.credential = opened.credential;
        }),
      );
      const [credential, conn] = yield* Effect.all([had, Deferred.await(dialled)], { concurrency: "unbounded" });
      const stream = yield* Effect.mapError(conn.openBi(), unreached);
      stages.openBi = since();
      const control = new Control(stream, env);
      yield* control.send(credential.credential, credential.also, ctx?.traceparent());
      stages.sent = since();
      const link = new Link(conn, control, credential.credential, credentials, pinned, endpoint);
      link.opened = opened;
      link.openedAt = began;
      // The station's answer to the first credential, while requests already go: a refusal closes the link.
      env.runner.fork(
        Effect.gen(function* () {
          const answer = yield* Effect.result(link.controlled((c) => c.answer()));
          if (answer._tag === "Failure") {
            link.renewalFailed = true;
            link.refused = answer.failure;
            conn.close(0, "credential refused");
          } else {
            link.answer = answer.success;
            const addrs = (said: J) => (Array.isArray(said) ? said.filter((a): a is string => typeof a === "string" && /^\d{1,3}(\.\d{1,3}){3}:\d{1,5}$/.test(a)).slice(0, 8) : []);
            link.lan = addrs((answer.success as J)?.lan);
            link.tailnet = addrs((answer.success as J)?.tailnet);
          }
          Deferred.doneUnsafe(link.answered, Effect.void);
        }),
      );
      env.runner.fork(renew(link, credentials, device));
      return link;
    });
    // The same budget as a dial had, still counted after getting onto a relay. It covers the whole opening, even
    // when the handshake succeeds but the old credential request or the first stream/write never answers.
    const deadline = Effect.gen(function* () {
      yield* onARelay(endpoint, relays.length === 0);
      if (endpointOnARelay(endpoint)) onRelayReady?.();
      opened.onto = since();
      stages.onto = opened.onto;
      const sleepStarted = env.host.nowMs();
      const monoSleepStarted = env.host.monotonicMs();
      yield* Effect.sleep(CONNECT_TIMEOUT_MS);
      const frozen =
        opened.onto > ONTO_MAX_MS + 3_000 ||
        env.host.nowMs() - sleepStarted > CONNECT_TIMEOUT_MS + 3_000 ||
        env.host.monotonicMs() - monoSleepStarted > CONNECT_TIMEOUT_MS + 3_000;
      return yield* Effect.fail(new OpeningTimeout(connection !== null, frozen));
    });
    return Effect.raceFirst(establish, deadline).pipe(Effect.onExit((exit) => Effect.sync(() => {
      if (exit._tag === "Failure") {
        abandoned = true;
        Deferred.doneUnsafe(givenUp, Effect.void);
        connection?.close(0, "opening ended");
      }
    })));
  });
  if (!rec && onDone === undefined) return dial;
  // the DHT's lines kept from the dial's start: a lookup it asks, a socket failing as it does (the record turned on, or
  // a first dial, after none was kept)
  const dialFrom = rec ? Effect.andThen(Effect.sync(() => recordDht(env.host, endpoint)), dial) : dial;
  const via = pinned === null ? (ips.length > 0 ? "main+addresses" : "main") : pinned === LAN ? "lan" : pinned === TAILNET ? "tailnet" : isFenced(pinned) ? "fenced" : `relay:${relayHost(pinned)}`;
  return Effect.onExit(dialFrom, (exit) =>
    Effect.sync(() => {
      const totalMs = Math.max(0, Math.round(env.host.nowMs() - startedAt));
      if (onDone !== undefined) {
        const stage: DialAttempt["stage"] = Exit.isSuccess(exit)
          ? "done"
          : stages.sent >= 0
            ? "hello"
            : stages.openBi >= 0
              ? "send"
              : stages.dialled >= 0
                ? "open_bi"
                : credFailed
                  ? "credential"
                  : stages.onto < 0 && relays.length > 0
                    ? "onto"
                    : "dial";
        if (Exit.isSuccess(exit)) onDone({ via, outcome: "ok", stage, totalMs });
        else if (Exit.hasInterrupts(exit)) onDone({ via, outcome: "interrupted", stage, totalMs });
        else {
          const e = Cause.squash(exit.cause) as { code?: unknown; cause?: unknown; message?: unknown };
          const code = typeof e?.code === "string" ? e.code : "";
          const msg = typeof e?.message === "string" ? e.message : String(e);
          const isTimeout = e instanceof OpeningTimeout || msg === noAnswer();
          const isRefused = code === "credential_refused" || code === "lock_unconfirmed" || code === "lock_station" || code === "client_upgrade_required";
          const rawErr = typeof e?.cause === "string" && e.cause !== "" ? e.cause : msg;
          onDone({
            via,
            outcome: isTimeout ? "no_answer" : isRefused ? "refused" : "error",
            stage,
            totalMs,
            ...(rawErr ? { error: said(rawErr) } : {}),
          });
        }
      }
      if (!rec) return;
      // what the DHT went through as it dialled (a lookup of this station's address among them, if one was asked)
      recordDht(env.host, endpoint);
      record(env.host, "conn dial", () =>
        dialLine({
          n,
          station: stationId,
          via,
          ...stages,
          leaf: formatPrepareTrace(leafTrace),
          total: totalMs,
          outcome: Exit.isSuccess(exit) ? "ok" : Exit.hasInterrupts(exit) ? "interrupted" : (() => {
            const e = Cause.squash(exit.cause) as { message?: string };
            const m = String(e?.message ?? e);
            return m === noAnswer() ? "no-answer" : `error: ${said(m)}`;
          })(),
        }),
      );
    }),
  );
}

/// The dials made so far (the record's numbers for them).
let dials = 0;

/// Presents a fresh credential every RENEW_MS until the link closes; one not had or refused leaves the link to run
/// out, and the next `link` opens another.
function renew(link: Link, credentials: CredentialSource, device: string): Effect.Effect<void> {
  return Effect.gen(function* () {
    for (;;) {
      const closed = yield* Effect.raceFirst(Effect.as(laterSleep(RENEW_MS), false), Effect.as(link.conn.closed(), true));
      if (closed) return;
      const renewed = yield* Effect.result(
        Effect.flatMap(credentials(device, false), (c) =>
          Effect.map(
            link.controlled((control) => control.exchange(c.credential)),
            () => {
              link.credential = c.credential;
            },
          ),
        ),
      );
      if (renewed._tag === "Failure") {
        link.renewalFailed = true;
        return;
      }
    }
  });
}
