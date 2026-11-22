// Optional real-network fault experiment. Never imported by deterministic tests.
import assert from "node:assert/strict";
import { writeFile } from "node:fs/promises";
import { join } from "node:path";

type Relay = { url: string; entry?: string; stop(): void };
type RequestResult = { address: string; milliseconds: number; status?: number; error?: string; sameConnection?: boolean; closed?: unknown };
const pause = (ms: number) => new Promise<void>(resolve => setTimeout(resolve, ms));

export async function dualRelayFailure(rpc: (method: string, args?: unknown) => Promise<any>, relays: Relay[],
  eventStreams: Iterable<{ write(bytes: Buffer): Promise<unknown> }>, serverCounts: { eventOpens: number }, output: string) {
  const preCut = await rpc("snapshot");
  const logical = (path: any) => relays.find(relay => [relay.url, relay.entry].some(url => url && new URL(url).host === new URL(path.relay).host));
  const ordered = [...preCut.links[0].paths].filter((p: any) => p.relay !== null)
    .sort((a: any, b: any) => Number(b.selected) - Number(a.selected) || (a.rttMs ?? Infinity) - (b.rttMs ?? Infinity));
  const candidates = [...new Set(ordered.map(logical).filter((r): r is Relay => r !== undefined))];
  // A later hot-set branch can require two, without changing this fault injection.
  const expected = process.env.RELAY_LOAD_EXPECT_RELAY_PATHS;
  if (expected !== undefined) {
    assert.ok(Number.isInteger(Number(expected)) && Number(expected) >= 2);
    assert.equal(candidates.length, Number(expected), "target relay path count before the cut");
  }
  assert.ok(candidates.length >= 2, "the target has at least two distinct logical relay paths");
  const cuts = candidates.slice(0, 2);
  const opensBefore = serverCounts.eventOpens;
  const cutAt = performance.now();
  for (const cut of cuts) cut.stop();
  const cutIssuedMs = performance.now() - cutAt;
  await writeFile(join(output, "cut.json"), JSON.stringify({ preCut, cutRelays: cuts.map(r => r.url), cutIssuedMs }, null, 2));
  const timeline: any[] = [];
  let sampling = true;
  // timer: local side-test sampling of path changes during failure recovery.
  const sampler = (async () => {
    while (sampling) {
      const s = await rpc("snapshot");
      timeline.push({ ms: Math.round(performance.now() - cutAt), links: s.links, counts: s.counts, eventsByAddress: s.eventsByAddress });
      await pause(250);
    }
  })();
  try {
    // One read per station through production MeshWire. Only the product retries or hedges it.
    const requests: RequestResult[] = await Promise.all(preCut.links.map(async (link: any) => {
      try { return { address: link.address, ...(await rpc("wire-request", { address: link.address })), milliseconds: Math.round(performance.now() - cutAt) }; }
      catch (error) { return { address: link.address, error: String(error), milliseconds: Math.round(performance.now() - cutAt) }; }
    }));
    const postRequest = await rpc("snapshot");
    const writes = await Promise.allSettled([...eventStreams].map(stream => stream.write(Buffer.from("after-dual-cut\n"))));
    let allStreamsDelivered = false;
    const streamDeadline = performance.now() + 10_000;
    // timer: side-test observation deadline for post-fault event delivery.
    do {
      const s = await rpc("snapshot");
      allStreamsDelivered = preCut.links.every((link: any) => (s.eventsByAddress[link.address]?.chunks ?? 0) > (postRequest.eventsByAddress[link.address]?.chunks ?? 0));
      if (allStreamsDelivered) break;
      await pause(25);
    } while (performance.now() < streamDeadline);
    const recoverySnapshot = await rpc("snapshot");
    const recoveryObservedMs = Math.round(performance.now() - cutAt);
    // timer: separate post-recovery observation window, excluded from app recovery time.
    await pause(35_000);
    const final = await rpc("snapshot");
    return { preCut, postRequest, recoverySnapshot, final, timeline,
      recovery: { cutRelays: cuts.map(r => r.url), cutIssuedMs, requests, recoveryObservedMs, allStreamsDelivered,
        streamWrites: writes.map(w => w.status === "fulfilled" ? { status: w.status } : { status: w.status, error: String(w.reason) }),
        eventStreamsReopened: serverCounts.eventOpens - opensBefore,
        allOriginalConnectionsOpen: final.links.every((link: any) => link.originalClosed === null && link.sameConnection) } };
  } finally {
    sampling = false;
    await sampler;
    await writeFile(join(output, "failure-timeline.json"), JSON.stringify(timeline, null, 2));
  }
}
