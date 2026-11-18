// The relays each other station is not reached through, held by the endpoint itself (src/mesh/peer-relays.ts): one set a
// station, whoever dials it and whichever workspace it is asked in, held before it is dialed and as the ways and rosters
// change, on what its connections have too (iroh's `set_disabled_relays`); an endpoint from before has its callers close
// a connection through a relay turned off instead.
import assert from "node:assert/strict";
import { test } from "node:test";
import { PEER_BYTES_ALPN, peerCall } from "../src/mesh/peer.ts";
import { PEER_HTTP_ALPN, PeerHttp } from "../src/mesh/peer-http.ts";
import { closePeerRelays, peerRelaysOf } from "../src/mesh/peer-relays.ts";
import { setWay, waysOf } from "../src/mesh/ways.ts";
import { BOTH, OURS, OWN, P1, P2, W1, W2, type Way, dialing, rosterW2, twoWorkspaces } from "./relay-fakes.ts";

const ours = [...OURS].sort().join(",");

test("each station held to its disabled relays before it is dialed; the dial says none itself", async () => {
  const cloud = twoWorkspaces();
  const { endpoint, told, dialed } = dialing(PEER_BYTES_ALPN, { result: { ok: true } }, () => ({ ip: "192.168.1.9:4433" }), true);
  const call = peerCall(endpoint, cloud);
  try {
    await call(P1, W1, { method: "describe" });
    await call(P2, W2, { method: "describe" });
    // W1 turned still.fail's off for its own (and so iroh's public ones too); W2 turned nothing off.
    assert.deepEqual(told, [`disabled b ${ours} true`, "dial b -", "disabled c none false", "dial c -"]);
    assert.deepEqual(dialed.map((a) => a.relays), [[OWN], OURS], "dialed by the relays of the workspace asked in");
  } finally {
    call.close?.();
    closePeerRelays(endpoint);
  }
});

test("one set a station of two workspaces, whoever dials it and whichever workspace asks, at once or one after another", async () => {
  const cloud = twoWorkspaces();
  // One endpoint a station: the station transport's connections and the web requests' alike.
  const a = dialing(null, (alpn: Buffer) => (alpn.equals(PEER_HTTP_ALPN) ? { status: 200 } : { result: { ok: true } }), () => ({ ip: "192.168.1.9:4433" }), true);
  const call = peerCall(a.endpoint, cloud);
  const web = new PeerHttp(a.endpoint, cloud);
  try {
    await Promise.all([call(BOTH, W1, { method: "describe" }), call(BOTH, W2, { method: "describe" }), web.tunnel(BOTH, 8080, true)]);
    await call(BOTH, W2, { method: "describe" });
    await web.tunnel(BOTH, 8080, true);
    // What both workspaces turn off: W1 still.fail's, W2 none, so none; W2 keeps still.fail's on, so iroh's public ones are not off either.
    assert.deepEqual(a.told.filter((t) => t.startsWith("disabled d")), ["disabled d none false"], `none told for one with none off: ${a.told.join(" | ")}`);
    assert.equal(a.policies.has(BOTH), false);
    // W2 turns one of still.fail's off too: what both turn off, held once for every caller.
    setWay(waysOf(cloud), W2, OURS[0]!, false);
    await peerRelaysOf(a.endpoint, cloud)!.again();
    await Promise.all([call(BOTH, W1, { method: "describe" }), call(BOTH, W2, { method: "describe" }), web.tunnel(BOTH, 8080, true)]);
    assert.deepEqual(a.policies.get(BOTH), { relays: [OURS[0]!], noPublic: false });
    assert.deepEqual(a.told.filter((t) => t.startsWith("disabled d")), ["disabled d none false", `disabled d ${OURS[0]} false`]);
  } finally {
    call.close?.();
    web.close();
    closePeerRelays(a.endpoint);
  }
});

test("as the ways change, every station held anew on what its connection has (kept, not closed); one gone from the rosters let go", async () => {
  const cloud = twoWorkspaces();
  const ways = new Map<string, Way>([[P2, { relay: `${OURS[0]}/` }]]);
  const { endpoint, told, policies, made } = dialing(PEER_BYTES_ALPN, { result: { ok: true } }, (peer) => ways.get(peer) ?? { ip: "192.168.1.9:4433" }, true);
  const call = peerCall(endpoint, cloud);
  try {
    await call(P2, W2, { method: "describe" });
    assert.equal(policies.has(P2), false, "W2 turns nothing off");
    setWay(waysOf(cloud), W2, OURS[0]!, false);
    await peerRelaysOf(endpoint, cloud)!.again();
    assert.deepEqual(policies.get(P2), { relays: [OURS[0]!], noPublic: false });
    assert.equal(made[0]!.isClosed(), false, "its connection (through that relay now) kept: iroh gives up the path itself");
    // The next request goes on the connection kept.
    await call(P2, W2, { method: "describe" });
    assert.equal(made.length, 1);
    // Gone from W2's roster: let go.
    rosterW2(cloud, [BOTH]);
    await peerRelaysOf(endpoint, cloud)!.again();
    assert.equal(policies.has(P2), false);
    assert.equal(told.at(-1), "disabled c none false");
    // A station that came to this one is held as one dialed is.
    call.arrived({ remoteId: () => P1 } as never);
    await peerRelaysOf(endpoint, cloud)!.again();
    assert.deepEqual(policies.get(P1), { relays: [...OURS].sort(), noPublic: true });
  } finally {
    call.close?.();
    closePeerRelays(endpoint);
  }
});

test("an endpoint from before (no such operation): a connection whose chosen path goes through a relay turned off is closed instead", async () => {
  const cloud = twoWorkspaces();
  const ways = new Map<string, Way>([[P2, { relay: `${OURS[0]}/` }]]);
  const { endpoint, dialed, made } = dialing(PEER_BYTES_ALPN, { result: { ok: true } }, (peer) => ways.get(peer)!, "from before");
  const call = peerCall(endpoint, cloud);
  try {
    await call(P2, W2, { method: "describe" });
    setWay(waysOf(cloud), W2, OURS[0]!, false);
    await peerRelaysOf(endpoint, cloud)!.again();
    assert.equal(made[0]!.isClosed(), true);
    ways.set(P2, { relay: `${OURS[1]}/` });
    await call(P2, W2, { method: "describe" });
    assert.deepEqual((dialed[1] as { disabledRelays?: string[] }).disabledRelays, [OURS[0]], "dialed again saying the relay off itself");
  } finally {
    call.close?.();
    closePeerRelays(endpoint);
  }
});


test("a failed policy prevents a dial and is retried by the next request", async () => {
  const cloud = twoWorkspaces();
  const a = dialing(PEER_BYTES_ALPN, { result: { ok: true } }, () => ({ ip: "192.168.1.9:4433" }), true);
  const apply = a.endpoint.disabledRelays!.bind(a.endpoint);
  a.endpoint.disabledRelays = async () => { throw new Error("policy unavailable"); };
  const call = peerCall(a.endpoint, cloud);
  try {
    await assert.rejects(call(P1, W1, { method: "describe" }), /policy unavailable/);
    assert.equal(a.dialed.length, 0);
    a.endpoint.disabledRelays = apply;
    await call(P1, W1, { method: "describe" });
    assert.equal(a.dialed.length, 1);
    assert.deepEqual(a.policies.get(P1), { relays: [...OURS].sort(), noPublic: true });
  } finally {
    call.close?.();
    closePeerRelays(a.endpoint);
  }
});

test("a ways change during the first policy is applied before its waiting dial", async () => {
  const cloud = twoWorkspaces();
  const a = dialing(PEER_BYTES_ALPN, { result: { ok: true } }, () => ({ ip: "192.168.1.9:4433" }), true);
  const apply = a.endpoint.disabledRelays!.bind(a.endpoint);
  const entered = Promise.withResolvers<void>();
  const release = Promise.withResolvers<void>();
  let first = true;
  a.endpoint.disabledRelays = async (...args) => {
    if (first) {
      first = false;
      entered.resolve();
      await release.promise;
    }
    await apply(...args);
  };
  const call = peerCall(a.endpoint, cloud);
  try {
    const request = call(P2, W2, { method: "describe" });
    await entered.promise;
    setWay(waysOf(cloud), W2, OURS[0]!, false);
    assert.equal(a.dialed.length, 0);
    release.resolve();
    await request;
    assert.deepEqual(a.told, ["disabled c none false", `disabled c ${OURS[0]} false`, "dial c -"]);
    assert.deepEqual(a.policies.get(P2), { relays: [OURS[0]!], noPublic: false });
  } finally {
    release.resolve();
    call.close?.();
    closePeerRelays(a.endpoint);
  }
});

test("mesh candidates preserve shared disabled-relay enforcement for RPC and HTTP", async () => {
  const cloud = twoWorkspaces();
  const a = dialing(null, (alpn: Buffer) => alpn.equals(PEER_HTTP_ALPN) ? { status: 200 } : { result: { ok: true } }, () => ({ ip: "192.168.1.9:4433" }), true);
  const scope = "ef".repeat(32);
  const resolve = (target: string, workspace: string | null) => target === P1 && workspace === W1 ? scope : undefined;
  const call = peerCall(a.endpoint, cloud, undefined, undefined, undefined, {}, resolve);
  const web = new PeerHttp(a.endpoint, cloud, undefined, undefined, resolve);
  try {
    await call(P1, W1, { method: "describe" });
    await web.tunnel(P1, 8080, true);
    assert.equal(a.dialed.length, 2);
    for (const addr of a.dialed) {
      assert.equal(addr.meshScope, scope);
      assert.deepEqual(addr.relays, [OWN]);
      assert.equal(addr.disabledRelays, undefined, "the live policy owns disabled relays");
    }
    assert.deepEqual(a.policies.get(P1), { relays: [...OURS].sort(), noPublic: true });
  } finally { call.close?.(); web.close(); closePeerRelays(a.endpoint); }
});
