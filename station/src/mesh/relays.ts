// Keeps the station on still.fail's relays (the Rust station's main.rs `keep_relays`): the ones browsers reach (they
// know no others), iroh homing on the nearest and the station kept on the rest too (keepers), so a device that reaches
// only some of them still reaches it. Those the cloud adds or takes away are put in or taken out as it pushes them.
// iroh's public relays come in only while none of ours answers (so the station can still be reached; the DHT says
// where), and go once one does again (else iroh may home on a public relay, where browsers can't follow). The relay
// iroh homes on is asked first, and once it answers asked again on the same connection, timed: the ping other stations
// are told of (jobs/load.ts). The workspaces' own relays (mesh/ways.ts, kept by their stations) are kept the same way,
// after still.fail's, as they are added or taken away. A relay every workspace of the station's turned off (one of
// still.fail's, all of them as `ours`, one of its own) is not kept: the station is on those its workspaces go by
// (ways.ts `workspaceRelays`), and on iroh's public relays never where every workspace turned still.fail's off. One it
// was bound with (home on it) goes only by binding the endpoint again (`rebindRelays`): iroh's removeRelay leaves a
// home relay's connection up (each one bound has a relay map of its own, Transports::bind).
import { Effect, Schedule, Stream } from "effect";
import type { Net } from "../jobs/load.ts";
import { wall } from "../ops/fibers.ts";
import { log } from "../ops/log.ts";
import { ControlPlane } from "../services.ts";
import type { Cloud } from "../cloud/state.ts";
import type { Endpoint } from "./native.ts";
import { allOursOff, sameUrl, waysOf, wantedRelays } from "./ways.ts";

export { allOursOff, wantedRelays };

/// Asking our relays whether they answer is asking an outside system: the one timer here.
const RELAY_CHECK = "30 seconds";

const has = (urls: string[], url: string) => urls.some((u) => sameUrl(u) === sameUrl(url));
const same = (a: string[], b: string[]) => a.length === b.length && a.every((u, i) => sameUrl(u) === sameUrl(b[i]!));

/// Runs for good (until interrupted).
export const keepRelays = (endpoint: Endpoint, net?: Net) =>
  Effect.gen(function* () {
    const cloud = yield* ControlPlane;
    const ways = waysOf(cloud.state);
    const wanted = () => wantedRelays(cloud.state);
    let ours = wanted();
    // What it was bound with, home on each, and what is on it besides: as a front that kept it across a handover says
    // (`boundRelays`), else as this process bound it (mesh.ts: still.fail's, the workspaces' own put in below).
    const bound = endpoint.boundRelays?.();
    let homes = bound?.homes ?? [...ours];
    const on = bound?.relays ?? cloud.state.relays();
    // Whether iroh's public relays are on: not known at first, since an endpoint kept across a handover (the front's)
    // may have them on from the process before; the first check that finds ours answering takes them off.
    let added: boolean | null = null;
    /// Bound again with `urls` alone where one it is home on goes (iroh's removeRelay leaves that one's connection up);
    /// whether it was (a front or an addon from before cannot: the relays are taken out one by one then).
    const rebound = async (urls: string[]): Promise<boolean> => {
      if (endpoint.rebindRelays === undefined || homes.every((h) => has(urls, h))) return false;
      try {
        await endpoint.rebindRelays(urls);
      } catch (e) {
        log.warn("mesh", "the endpoint was not bound again on the relays kept; taking them out one by one", { error: (e as Error).message });
        return false;
      }
      log.info("mesh", "the endpoint bound again on the relays kept", { relays: urls, was: homes });
      homes = [...urls];
      // (bound anew: none of iroh's public relays on it)
      added = null;
      return true;
    };
    // The workspaces' own put in before it is kept on them, where the endpoint was bound with still.fail's alone; those
    // its workspaces turned off taken out.
    if (!(yield* Effect.promise(() => rebound(ours)))) {
      for (const url of ours.filter((u) => !has(on, u))) {
        yield* Effect.promise(() => endpoint.insertRelay(url).catch((e) => log.warn("mesh", "a workspace's relay was not added", { relay: url, error: (e as Error).message })));
      }
      for (const url of [...on, ...homes].filter((u, i, all) => !has(ours, u) && all.findIndex((x) => sameUrl(x) === sameUrl(u)) === i)) {
        yield* Effect.promise(() => endpoint.removeRelay(url).catch((e) => log.warn("mesh", "a relay turned off was not taken out", { relay: url, error: (e as Error).message })));
      }
    }
    endpoint.keep(ours);

    // As the cloud pushes still.fail's, and as a workspace's own are added, taken away or turned off. One change at a time.
    let changing: Promise<void> = Promise.resolve();
    const changed = () => (changing = changing.then(async () => {
      const now = wanted();
      if (now.length === 0 || same(now, ours)) return;
      log.info("mesh", "the relays kept changed", { relays: now });
      const was = ours;
      ours = now;
      if (!(await rebound(now))) {
        for (const url of now.filter((u) => !has(was, u))) await endpoint.insertRelay(url);
        for (const url of was.filter((u) => !has(now, u))) await endpoint.removeRelay(url);
      }
      endpoint.keep(now);
    }).catch((e) => log.warn("mesh", "the relays kept were not changed", { error: (e as Error).message })));
    const follow = cloud.changes.pipe(Stream.runForEach(() => Effect.promise(changed)));
    const stopWays = ways.listen(() => void changed());

    const check = Effect.promise(async () => {
      let up = false;
      const bare = (url: string) => url.replace(/\/+$/, "");
      const home = endpoint.home();
      const order = home === null ? ours : [...ours.filter((u) => bare(u) === bare(home)), ...ours.filter((u) => bare(u) !== bare(home))];
      // Two tries each: one lost request is not the relay down.
      relays: for (const relay of order) {
        for (let i = 0; i < 2; i++) {
          try {
            const r = await fetch(`${bare(relay)}/ping`, { signal: AbortSignal.timeout(10_000) });
            if (r.ok) {
              up = true;
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
      if (!up && allOursOff(cloud.state)) {
        // Every workspace turned still.fail's off: iroh's are not taken in their place, whatever answers.
        if (added !== false) {
          log.warn("mesh", "none of the relays kept answers; iroh's public relays stay off, as every workspace turned still.fail's off", { relays: ours });
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
    });

    yield* Effect.all([follow, Effect.repeat(check, Schedule.spaced(RELAY_CHECK))], { concurrency: "unbounded", discard: true }).pipe(Effect.ensuring(Effect.sync(stopWays))); // timer: a ping that measures the relays, which tell nothing by themselves
  });
