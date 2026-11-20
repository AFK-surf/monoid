// Keeps the station on still.fail's relays (the Rust station's main.rs `keep_relays`): the ones browsers reach (they
// know no others), iroh homing on the nearest and the station kept on the rest too (keepers), so a device that reaches
// only some of them still reaches it. Those the cloud adds or takes away are put in or taken out as it pushes them.
// iroh's public relays come in only while none of ours answers (so the station can still be reached; the DHT says
// where), and go once one does again (else iroh may home on a public relay, where browsers can't follow). The relay
// iroh homes on is asked first, and once it answers asked again on the same connection, timed: the ping other stations
// are told of (jobs/load.ts). The workspaces' own relays (mesh/ways.ts, kept by their stations) are kept the same way,
// after still.fail's, as they are added or taken away; and a relay every workspace of the station's turns off (`off`:
// one's URL, `ours` for still.fail's) is not kept, nor dialed to another station (`stationAddr`).
import { Clock, Effect, Option, Schedule, Stream } from "effect";
import type { Net } from "../jobs/load.ts";
import { wall } from "../ops/fibers.ts";
import { log } from "../ops/log.ts";
import { ControlPlane } from "../services.ts";
import type { Cloud } from "../cloud/state.ts";
import type { Addr, Connection, Endpoint } from "./native.ts";
import { offRelays, sameUrl, waysOf, workspaceRelays } from "./ways.ts";
import type { Ways } from "./ways.ts";

/// Asking our relays whether they answer is asking an outside system: the one timer here.
const RELAY_CHECK = "30 seconds";

/// The relays the station is kept on: each of its workspaces' (`workspaceRelays`: still.fail's, then its own, but those
/// its ways turn off), the home one's first; still.fail's where it is in none. What its endpoint is bound with (mesh.ts,
/// rig/main.ts), so a front's endpoint taken over in a handover is reconciled with all of them (mesh.mbt `bind`).
export function wantedRelays(state: Cloud): string[] {
  const ways = waysOf(state);
  const out: string[] = [];
  for (const m of state.memberships()) for (const u of workspaceRelays(ways, m.workspace)) if (!out.some((o) => sameUrl(o) === sameUrl(u))) out.push(u);
  return out.length > 0 ? out : state.relays();
}

/// Where station `id` is dialed (peer.ts, peer-http.ts): through the relays of the workspace it is asked in, or, where
/// none is said (or it is another workspace's, sharing chats), of every workspace of this station's it is in too; and
/// not through those all of them turn off (`disabledRelays`: iroh drops them where Address Lookup names them, the
/// other station kept on them for a workspace of its own that keeps them on). One of none of them: as this station is
/// kept (`wantedRelays`).
export function stationAddr(cloud: Cloud, id: string, workspace: string | null = null): Addr & { disabledRelays: string[] } {
  const ways = waysOf(cloud);
  const shared = workspace !== null && cloud.membership(workspace) !== null
    ? [workspace]
    : cloud.memberships().filter((m) => m.peers.some((p) => p?.id === id) || cloud.rigs(m.workspace).some((r) => r.id === id)).map((m) => m.workspace);
  if (shared.length === 0) return { id, relays: wantedRelays(cloud), disabledRelays: [] };
  const relays: string[] = [];
  for (const ws of shared) for (const u of workspaceRelays(ways, ws)) if (!relays.some((r) => sameUrl(r) === sameUrl(u))) relays.push(u);
  const offs = shared.map((ws) => offRelays(ways, ws));
  const disabledRelays = offs[0]!.filter((u) => offs.every((o) => o.some((x) => sameUrl(x) === sameUrl(u))) && !relays.some((r) => sameUrl(r) === sameUrl(u)));
  return { id, relays, disabledRelays };
}

const among = (urls: string[], url: string) => urls.some((u) => sameUrl(u) === sameUrl(url));

/// Whether every workspace of the station's turned still.fail's relays off for relays of its own: then iroh's public
/// relays, a third party's too, are not added while none of those answers (a workspace that keeps its packets off
/// still.fail's keeps them off n0's).
export function oursOff(state: Cloud, ways: Ways = waysOf(state)): boolean {
  const ms = state.memberships();
  return ms.length > 0 && ms.every((m) => ways.view(m.workspace).off.includes("ours") && offRelays(ways, m.workspace).length > 0);
}

/// The watch of the endpoint itself (`keepRelays`' `watch`), on the relays' check: a relay answering its ping says
/// nothing of whether the endpoint is still reached through it (FB-38: an endpoint stuck, every relay answering, the
/// station out of reach for hours), so the endpoint is probed end to end through one that answers (endpoint.ts
/// `probeRelay`): every `everyHealthy` checks while all looks well, every check while its relays say it is not on any,
/// held off one for another endpoint of its key (`conflict`), or a probe failed. After `failuresToRecover` probes in a
/// row that found the endpoint at fault (`endpoint_failed`, or no answer), it is told unhealthy (`onUnhealthy`: the
/// front restarted, or the endpoint closed and bound anew), never in the first `startupGraceMs`, and again only after a
/// cooldown, `cooldownMs` first and doubled each time it comes back (to `cooldownMaxMs`: two stations on one key would
/// otherwise take turns restarting), back to `cooldownMs` once a probe finds it well after the cooldown. A probe that
/// finds the relay out of this machine's reach (`probe_offline`), or no relay answering at all, is the network's, not
/// the endpoint's: it counts for nothing. A front or an addon from before that has no probe is not probed again.
/// One relay can fail the probe while the endpoint is well (a relay half down that still answers its ping, or one over
/// its quota that lets no one on), so a check probes through up to `MAX_PROBES_PER_TICK` relays that answer, the
/// first that did, then the next of the rest whose ping answers: one through which it is reached clears the failures;
/// a failure counts only once a second relay also fails, or when no other relay answering was left to ask.
export const PROBE = {
  startupGraceMs: 120_000,
  everyHealthy: 4,
  failuresToRecover: 3,
  cooldownMs: 600_000,
  cooldownMaxMs: 3_600_000,
};
export type ProbeParams = typeof PROBE;
/// The longest a probe is waited for (the addon's own takes some 25 s at most): a deadline.
const PROBE_DEADLINE = "60 seconds";
/// The most relays one check probes through (`PROBE`).
const MAX_PROBES_PER_TICK = 4;

const bare = (url: string) => url.replace(/\/+$/, "");

/// One ping of a relay, within 10 s: whether it answered ok.
async function pingOnce(url: string): Promise<boolean> {
  try {
    const r = await fetch(`${bare(url)}/ping`, { signal: AbortSignal.timeout(10_000) });
    await r.body?.cancel().catch(() => {});
    return r.ok;
  } catch {
    return false;
  }
}

/// What one probe through a relay found: no probe at all, the endpoint reached, the relay out of this machine's reach,
/// or the endpoint not reached (`detail`: its stage, or the error).
type ProbeOutcome =
  | { kind: "unsupported"; error: string }
  | { kind: "ok" }
  | { kind: "offline" }
  | { kind: "failed"; detail: Record<string, unknown> };

/// What watches the endpoint (`PROBE`): told when it is found at fault, `params` for a test's.
export type RelayWatch = { onUnhealthy: () => void; params?: Partial<ProbeParams> };

/// Runs for good (until interrupted). `bound`: the relays the endpoint was bound with (still.fail's where not said):
/// those wanted that it lacks are put in before it is kept on them, and those not wanted taken out. `watch`: the
/// endpoint probed end to end on the relays' check, and what is told when it is at fault (`PROBE`).
export const keepRelays = (endpoint: Endpoint, net?: Net, bound?: string[], watch?: RelayWatch) =>
  Effect.gen(function* () {
    const cloud = yield* ControlPlane;
    const ways = waysOf(cloud.state);
    const wanted = () => wantedRelays(cloud.state);
    let ours = wanted();
    const was = bound ?? cloud.state.relays();
    for (const url of ours.filter((u) => !among(was, u))) {
      yield* Effect.promise(() => endpoint.insertRelay(url).catch((e) => log.warn("mesh", "a workspace's relay was not added", { relay: url, error: (e as Error).message })));
    }
    for (const url of was.filter((u) => !among(ours, u))) {
      yield* Effect.promise(() => endpoint.removeRelay(url).catch((e) => log.warn("mesh", "a relay turned off was not removed", { relay: url, error: (e as Error).message })));
    }
    endpoint.keep(ours);
    // Whether iroh's public relays are on: not known at first, since an endpoint kept across a handover (the front's)
    // may have them on from the process before; the first check that finds ours answering takes them off.
    let added: boolean | null = null;

    // As the cloud pushes still.fail's, and as a workspace's own are added or taken away. One change at a time.
    let changing: Promise<void> = Promise.resolve();
    const changed = () => (changing = changing.then(async () => {
      const now = wanted();
      // (none: not in a workspace now, cloud.json gone; the relays stay as they are)
      if (now.length === 0 || (now.length === ours.length && now.every((u, i) => sameUrl(u) === sameUrl(ours[i]!)))) return;
      log.info("mesh", "the relays kept changed", { relays: now });
      const was = ours;
      ours = now;
      for (const url of now.filter((u) => !among(was, u))) await endpoint.insertRelay(url);
      for (const url of was.filter((u) => !among(now, u))) await endpoint.removeRelay(url);
      endpoint.keep(now);
    }).catch((e) => log.warn("mesh", "the relays kept were not changed", { error: (e as Error).message })));
    const follow = cloud.changes.pipe(Stream.runForEach(() => Effect.promise(changed)));
    const stopWays = ways.listen(() => void changed());

    // The endpoint's watch (`PROBE`).
    const p: ProbeParams = { ...PROBE, ...watch?.params };
    const startedAt = yield* Clock.currentTimeMillis;
    let failures = 0;
    let healthyTicks = 0;
    let unsupported = false;
    let lastRecoverAt: number | null = null;
    let cooldown = p.cooldownMs;
    const probeTick = (up: boolean, reachable: string | null, rest: string[]) =>
      Effect.gen(function* () {
        if (watch === undefined || endpoint.probeRelay === undefined || unsupported) return;
        // (none of the relays answers: this machine's network or the relays', not the endpoint's)
        if (!up) {
          failures = 0;
          return;
        }
        if (reachable === null) return;
        const status = endpoint.relayStatus?.() ?? [];
        const suspect = (status.length > 0 && status.every((s) => !s.connected)) || status.some((s) => s.conflict === true) || failures > 0;
        if (!suspect && ++healthyTicks < p.everyHealthy) return;
        healthyTicks = 0;
        const probe = endpoint.probeRelay.bind(endpoint);
        const runOne = (relay: string) =>
          Effect.map(
            Effect.timeoutOption(Effect.promise(() => probe(relay).then((found) => ({ found }), (error: unknown) => ({ error: error instanceof Error ? error.message : String(error) }))), PROBE_DEADLINE), // timer: a deadline on the probe
            (answer): ProbeOutcome => {
              const said = Option.isNone(answer) ? { error: `no answer in ${PROBE_DEADLINE}` } : answer.value;
              if ("error" in said) return /no operation|not a function/.test(said.error) ? { kind: "unsupported", error: said.error } : { kind: "failed", detail: { error: said.error } };
              if (said.found.ok) return { kind: "ok" };
              if (said.found.stage === "probe_offline") return { kind: "offline" };
              return { kind: "failed", detail: { stage: said.found.stage ?? "unknown" } };
            },
          );
        let probed = 0;
        let restIdx = 0;
        let exhausted = false;
        const tried = new Set<string>();
        const failedRelays: string[] = [];
        let firstDetail: Record<string, unknown> = {};
        const offlineRelays: string[] = [];
        while (probed < MAX_PROBES_PER_TICK) {
          // The first that answered its ping, then the next of the rest whose ping answers.
          let relay: string | null = probed === 0 ? reachable : null;
          while (relay === null && restIdx < rest.length) {
            const c = rest[restIdx++]!;
            if (tried.has(bare(c))) continue;
            if (yield* Effect.promise(() => pingOnce(c))) relay = c;
          }
          if (relay === null) {
            exhausted = true;
            break;
          }
          tried.add(bare(relay));
          const res = yield* runOne(relay);
          probed++;
          if (res.kind === "unsupported") {
            // (a front or an addon from before: never restarted for having no probe)
            failures = 0;
            unsupported = true;
            log.info("mesh", "the endpoint cannot be probed through a relay; not probed again", { relay, error: res.error });
            return;
          }
          if (res.kind === "ok") {
            if (failedRelays.length > 0) log.info("mesh", "the endpoint was not reached through one relay, but answered through another; not the endpoint's", { relay: failedRelays[0], okRelay: relay, ...firstDetail });
            failures = 0;
            const now = yield* Clock.currentTimeMillis;
            if (lastRecoverAt !== null && now - lastRecoverAt >= cooldown) {
              cooldown = p.cooldownMs;
              lastRecoverAt = null;
            }
            return;
          }
          if (res.kind === "offline") {
            offlineRelays.push(relay);
            continue;
          }
          if (failedRelays.length === 0) firstDetail = res.detail;
          failedRelays.push(relay);
          // (two relays found it out of reach: the endpoint's)
          if (failedRelays.length >= 2) break;
        }
        if (restIdx >= rest.length && failedRelays.length < 2) exhausted = true;
        if (failedRelays.length === 0) {
          log.info("mesh", "a probe through a relay that answers did not get on it; the network's, not the endpoint's", { relay: offlineRelays[0] ?? reachable, ...(offlineRelays.length > 1 ? { relays: offlineRelays } : {}) });
          return;
        }
        if (failedRelays.length === 1 && !exhausted) {
          log.info("mesh", "a probe failed through one relay while other relays could not be reached; not counting it against the endpoint", { relay: failedRelays[0], offline: offlineRelays, ...firstDetail });
          return;
        }
        const also = failedRelays.length > 1 ? { also: failedRelays[1] } : {};
        failures++;
        log.warn("mesh", "the endpoint was not reached through a relay that answers", { relay: failedRelays[0], ...also, ...firstDetail, failures });
        const now = yield* Clock.currentTimeMillis;
        if (failures < p.failuresToRecover || now - startedAt < p.startupGraceMs || (lastRecoverAt !== null && now - lastRecoverAt < cooldown)) return;
        cooldown = lastRecoverAt === null ? p.cooldownMs : Math.min(cooldown * 2, p.cooldownMaxMs);
        lastRecoverAt = now;
        log.error("mesh", "the endpoint failed its end-to-end probes through a relay that answers; recovering it", { relay: failedRelays[0], ...also, failures, cooldownMs: cooldown });
        failures = 0;
        watch.onUnhealthy();
      });

    const ping = Effect.promise(async () => {
      let up = false;
      let reachable: string | null = null;
      let rest: string[] = [];
      const home = endpoint.home();
      const order = home === null ? ours : [...ours.filter((u) => bare(u) === bare(home)), ...ours.filter((u) => bare(u) !== bare(home))];
      // Two tries each: one lost request is not the relay down.
      relays: for (const [idx, relay] of order.entries()) {
        for (let i = 0; i < 2; i++) {
          try {
            const r = await fetch(`${bare(relay)}/ping`, { signal: AbortSignal.timeout(10_000) });
            if (r.ok) {
              up = true;
              reachable = relay;
              // (the relays after it, not asked this check: probed through where it fails, `PROBE`)
              rest = order.slice(idx + 1);
              if (net !== undefined) {
                // Once more on the connection made (its body read, so it is free again): the time is the way there and
                // back, not the handshakes.
                try {
                  await r.arrayBuffer();
                  const start = wall.now();
                  const again = await fetch(`${bare(relay)}/ping`, { signal: AbortSignal.timeout(10_000) });
                  await again.arrayBuffer();
                  if (again.ok) net.pinged(bare(relay), wall.now() - start);
                } catch {}
              }
              break relays;
            }
          } catch {}
        }
      }
      if (!up && oursOff(cloud.state, ways)) {
        // (none answers, but iroh's public relays are off too: the workspaces turned still.fail's off)
        if (added !== false) {
          log.warn("mesh", "none of the workspaces' relays answers; iroh's public relays stay off, still.fail's being turned off", { relays: ours });
          await endpoint.publicRelays(false);
          added = false;
        }
      } else if (!up && added !== true) {
        log.warn("mesh", "none of still.fail's relays answers; adding iroh's public relays until one does", { relays: ours });
        await endpoint.publicRelays(true);
        added = true;
      } else if (up && added !== false) {
        if (added === true) log.info("mesh", "still.fail's relays answer again; back home to them", { relays: ours });
        await endpoint.publicRelays(false);
        added = false;
      }
      return { up, reachable, rest };
    });
    const check = Effect.gen(function* () {
      const { up, reachable, rest } = yield* ping;
      yield* probeTick(up, reachable, rest);
    });

    yield* Effect.all([follow, Effect.repeat(check, Schedule.spaced(RELAY_CHECK))], { concurrency: "unbounded", discard: true }).pipe(Effect.ensuring(Effect.sync(stopWays))); // timer: a ping that measures the relays, which tell nothing by themselves
  });

/// Calls `sweep` whenever a workspace's ways or the cloud's state change here; returns what stops it.
export function onRelaysChanged(cloud: Cloud, sweep: () => void): () => void {
  const stopWays = waysOf(cloud).listen(sweep);
  const stopCloud = cloud.listen(sweep);
  return () => {
    stopWays();
    stopCloud();
  };
}

/// Whether `conn` goes through one of `relays` now (its path chosen): a connection kept from before they were turned off,
/// let go so the next request dials anew, not through them (peer.ts, peer-http.ts).
export function goesThrough(conn: Connection, relays: string[] | undefined): boolean {
  if (relays === undefined || relays.length === 0) return false;
  const via = conn.paths?.().find((p) => p.selected)?.relay;
  return typeof via === "string" && relays.some((u) => sameUrl(u) === sameUrl(via));
}
