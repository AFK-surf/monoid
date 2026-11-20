// Optional relay API experiment. It shares the load fixture and its original links.
import assert from "node:assert/strict";
import { writeFile } from "node:fs/promises";
import { join } from "node:path";
import type { RelayCapture } from "./relay-load-cdp.ts";

export async function relayControls(rpc: (method: string, args?: unknown) => Promise<any>, capture: RelayCapture,
  device: string, urls: string[], entries: string[], targets: Record<string, string>, output: string) {
  const first = await rpc("snapshot");
  const address = first.links[0].address;
  const id = address.slice(address.lastIndexOf("/") + 1);
  const relay = urls[0];
  const hosts = new Set([relay, ...entries.filter(entry => targets[entry] === relay)].map(url => new URL(url).host));
  const endpoint = (method: string, ...values: unknown[]) => rpc("endpoint", { method, values });
  const snapshot = async () => {
    const value = await rpc("snapshot");
    assert.ok(value.links.every((link: any) => link.originalClosed === null && link.sameConnection), "relay controls keep every original station connection");
    assert.equal(value.counts.eventOpens, first.counts.eventOpens, "relay controls do not reopen event streams");
    return value;
  };
  const pathOn = (value: any) => value.links[0].paths.some((path: any) => path.relay && hosts.has(new URL(path.relay).host));
  const socketCount = () => [...capture.sockets.values()].filter(socket => socket.opened !== null && socket.closed === null
    && hosts.has(socket.host) && socket.identityCandidates.includes(device)).length;
  const observe = async (condition: (value: any) => boolean, timeout = 30_000) => {
    const start = performance.now();
    do {
      if (condition(await snapshot())) return Math.round(performance.now() - start);
      await new Promise(resolve => setTimeout(resolve, 25));
    } while (performance.now() - start < timeout);
    return null;
  };
  const request = async () => {
    const value = await rpc("request", { address });
    assert.equal(value.status, 200);assert.equal(value.sameConnection, true);
    await snapshot();
  };
  assert.notEqual(await observe(pathOn, 10_000), null, "the tested relay has a path before removal");
  const methods = ["clear-disabled", "remove-insert", "disabled-remove-insert-clear"];
  const only = process.env.RELAY_CONTROL_METHOD;
  assert.ok(only === undefined || methods.includes(only), "known relay recovery method");
  const cases: { method: string; milliseconds: number | null; observationLimitMs: number }[] = [];
  const disabled: { milliseconds: number; mainSockets: number }[] = [];
  let removeClosedMs: number | null = null, insertOpenedMs: number | null = null;
  for (const method of only === undefined ? methods : [only]) {
    assert.notEqual(await observe(pathOn, 10_000), null, "each case starts with the tested relay path");
    const usesDisabled = method !== "remove-insert";
    if (usesDisabled) {
      await endpoint("setDisabledRelays", id, [relay]);
      const gone = await observe(value => !pathOn(value), 10_000);
      assert.notEqual(gone, null, "disabling removes the relay path");
      assert.ok(socketCount() > 0, "disabling one peer keeps its relay WebSocket");
      disabled.push({ milliseconds: gone!, mainSockets: socketCount() });
      await request();
    }
    let start = performance.now();
    if (method !== "clear-disabled") {
      const removedAt = performance.now();
      await endpoint("removeRelay", relay);
      assert.notEqual(await observe(() => socketCount() === 0, 10_000), null, "removeRelay closes the main endpoint's socket");
      assert.notEqual(await observe(value => !pathOn(value), 10_000), null, "removeRelay removes the peer path");
      removeClosedMs = Math.round(performance.now() - removedAt);
      await request();
      // Even while absent, an entrance update must survive the next insertion.
      await endpoint("setRelayEntries", entries.map(entry => ({ entry, relay: targets[entry] })));
      const insertedAt = performance.now();
      start = insertedAt;
      await endpoint("insertRelay", relay);
      assert.notEqual(await observe(() => socketCount() > 0, 10_000), null, "insertRelay reconnects its main socket");
      insertOpenedMs = Math.round(performance.now() - insertedAt);
      if (usesDisabled) assert.equal(pathOn(await snapshot()), false, "insertRelay cannot bypass a peer's disabled set");
    }
    if (usesDisabled) {
      start = performance.now();
      await endpoint("setDisabledRelays", id, []);
    }
    const restored = await observe(pathOn);
    cases.push({ method, milliseconds: restored === null ? null : Math.round(performance.now() - start), observationLimitMs: 30_000 });
    await request();
  }
  const result = { relay, cases, disabled, removeClosedMs, insertOpenedMs, allOriginalConnectionsOpen: true, eventStreamsReopened: 0 };
  await writeFile(join(output, "relay-controls.json"), JSON.stringify(result, null, 2) + "\n");
  console.log(JSON.stringify({ phase: "relay-controls", ...result }));
  assert.ok(cases.every(value => value.milliseconds !== null), "every tested method must restore the relay path without addAddr");
  return result;
}
