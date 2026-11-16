// The relays each other station is not to be reached through, held by the endpoint itself (the addon's or the front's
// `disabledRelays`: iroh's `Endpoint::set_disabled_relays`): nothing is sent it through one of them, and what a
// connection to it has through one (a backup path kept beside a direct one, a path it opened) is given up, its direct
// paths kept. One set a station, whoever calls it (the station transport, the web requests) and whichever workspace a
// request is asked in: those every workspace both stations are in turns off (relays.ts `stationAddr` with no workspace),
// and iroh's public relays too where each of those turned still.fail's off for relays of its own (`public`). A dial
// says none of them itself (iroh's `with_disabled_relays` would set them over), so what the set is is decided here only:
// held before the station is dialed, in force once that resolves (the call is answered once iroh went by it), and held
// anew as the ways or the rosters change. A station that came to this one (`arrived`) is held too.
//
// A station of no workspace of this one's any more is let go (its set emptied): what is held is bounded by the rosters.
// Where the endpoint holds none (an addon or a front from before: no such operation), `supported` turns false and its
// callers close a connection whose chosen path goes through a relay turned off instead (relays.ts `goesThrough`).
import type { Cloud } from "../cloud/state.ts";
import { log } from "../ops/log.ts";
import type { Endpoint } from "./native.ts";
import { stationAddr } from "./relays.ts";
import { offRelays, sameUrl, waysOf } from "./ways.ts";

/// What one station is held to: the relays it is not reached through, and whether iroh's public relays are among them.
export type PeerDisabled = { relays: string[]; public: boolean };

/// What `peer` is held to now; null where it is a station of no workspace of this one's (nothing to hold it to).
export function peerDisabled(cloud: Cloud, peer: string): PeerDisabled | null {
  const shared = cloud.memberships().filter((m) => m.peers.some((p) => p?.id === peer) || cloud.rigs(m.workspace).some((r) => r.id === peer)).map((m) => m.workspace);
  if (shared.length === 0) return null;
  const ways = waysOf(cloud);
  const relays = stationAddr(cloud, peer, null).disabledRelays;
  const noPublic = shared.every((ws) => ways.view(ws).off.includes("ours") && offRelays(ways, ws).length > 0);
  return { relays, public: noPublic };
}

const keyOf = (d: PeerDisabled | null) => (d === null ? "" : JSON.stringify([[...d.relays].map((u) => sameUrl(u)).sort(), d.public]));

type Holding = Endpoint & { disabledRelays(id: string, relays: string[], noPublic: boolean): Promise<void> };

export class PeerRelays {
  readonly #endpoint: Holding;
  readonly #cloud: Cloud;
  /// Each station held: the key of what the endpoint was told last.
  readonly #held = new Map<string, string>();
  /// Each station's changes, one after another (a dial's and the ways' alike).
  readonly #going = new Map<string, Promise<void>>();
  readonly #stops: (() => void)[];
  /// Whether the endpoint holds them (false once it answered it has no such operation).
  supported = true;

  constructor(endpoint: Holding, cloud: Cloud) {
    this.#endpoint = endpoint;
    this.#cloud = cloud;
    const again = () => void this.again().catch((error) => log.warn("mesh", "disabled relays could not be updated", { error: (error as Error).message }));
    this.#stops = [waysOf(cloud).listen(again), cloud.listen(again)];
  }

  /// `peer` held to what it is to be held to now, in force once this resolves (before it is dialed).
  hold(peer: string): Promise<void> {
    return this.#then(peer, () => this.#give(peer));
  }

  /// Every station held, held anew as the ways and rosters are now; one of no workspace of this one's let go.
  /// Resolves once each is in force.
  again(): Promise<void> {
    return Promise.all([...new Set([...this.#held.keys(), ...this.#going.keys()])].map((peer) => this.#then(peer, () => this.#give(peer)))).then(() => {});
  }

  async #give(peer: string): Promise<void> {
    if (!this.supported) return;
    const now = peerDisabled(this.#cloud, peer);
    const key = keyOf(now);
    const was = this.#held.get(peer);
    if (key === was || (now === null && was === undefined)) return;
    try {
      await this.#endpoint.disabledRelays(peer, now?.relays ?? [], now?.public ?? false);
    } catch (e) {
      if (/no operation|not a function/.test((e as Error).message)) this.supported = false;
      else throw e;
      return;
    }
    if (now === null) this.#held.delete(peer);
    else this.#held.set(peer, key);
    // A roster or ways event may have arrived while the endpoint applied the previous set.
    if (keyOf(peerDisabled(this.#cloud, peer)) !== key) await this.#give(peer);
  }

  #then(peer: string, f: () => Promise<void>): Promise<void> {
    const next = (this.#going.get(peer) ?? Promise.resolve()).then(f, f);
    const clean = () => {
      if (this.#going.get(peer) === settled) this.#going.delete(peer);
    };
    const settled = next.then(clean, clean);
    this.#going.set(peer, settled);
    return next;
  }

  /// What `peer` is held to (its key; tests).
  heldOf(peer: string): string | null {
    return this.#held.get(peer) ?? null;
  }

  close() {
    for (const stop of this.#stops.splice(0)) stop();
  }
}

const kept = new WeakMap<Endpoint, PeerRelays>();
/// The sets an endpoint holds its peers to, one for every caller of it; null where the endpoint offers none.
export function peerRelaysOf(endpoint: Endpoint, cloud: Cloud): PeerRelays | null {
  if (typeof endpoint.disabledRelays !== "function") return null;
  let held = kept.get(endpoint);
  if (held === undefined) kept.set(endpoint, (held = new PeerRelays(endpoint as Holding, cloud)));
  return held;
}

/// The sets of `endpoint` let go of (the mesh stops): no more following the ways.
export function closePeerRelays(endpoint: Endpoint): void {
  kept.get(endpoint)?.close();
  kept.delete(endpoint);
}
