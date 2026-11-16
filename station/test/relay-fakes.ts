// What the tests of the relays a station dials its peers by share (peer.test.ts, peer-http.test.ts): a station in two
// workspaces as the control plane tells it, one that turned still.fail's relays off for one of its own, the other on
// still.fail's; and an endpoint that dials nothing, each connection it makes going the way the test says, answering
// each request at once with `answer`.
import { mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { applyState } from "../src/cloud/presence.ts";
import { Cloud, writeState } from "../src/cloud/state.ts";
import type { Addr, Connection, Endpoint } from "../src/mesh/native.ts";

export const OURS = ["https://relay.still.example", "https://relay2.still.example"];
export const OWN = "https://relay.own.example";
export const W1 = "01HZZZZZZZZZZZZZZZZZZZZZZZ";
export const W2 = "01HYYYYYYYYYYYYYYYYYYYYYYY";
export const ME = "a".repeat(64);
/// A station of W1 alone, one of W2 alone, one of both.
export const P1 = "b".repeat(64);
export const P2 = "c".repeat(64);
export const BOTH = "d".repeat(64);

/// This station: home in W1 (`off: ["ours"]`, its own relay OWN), joined to W2 (still.fail's relays).
export function twoWorkspaces(): Cloud {
  const data = mkdtempSync(join(tmpdir(), "relay-fakes-"));
  writeState(data, { origin: "https://app.still.fail", station: ME, workspace: W1, workspace_name: "One", name: "me", relay_url: OURS[0]!, relay_urls: OURS, grant_keys: { keys: [] }, peers: [], revocations: [] });
  const cloud = new Cloud(data, false);
  applyState(cloud, JSON.stringify({
    type: "state", workspace: W1, workspace_name: "One", name: "me", origin: "https://app.still.fail", relay_url: OURS[0], relay_urls: [...OURS, OWN], stillfail_relays: OURS,
    peers: [{ id: ME, name: "me" }, { id: P1, name: "p1" }, { id: BOTH, name: "both" }], revocations: [], ways: { relays: [OWN], off: ["ours"] },
    workspaces: [{ workspace: W2, workspace_name: "Two", name: "me", peers: [{ id: ME, name: "me" }, { id: P2, name: "p2" }, { id: BOTH, name: "both" }], revocations: [], ways: { relays: [], off: [] } }],
  }));
  return cloud;
}

/// The way a connection goes now: through a relay (its URL as iroh says it, a trailing slash), or direct.
export type Way = { relay: string } | { ip: string };

/// An endpoint whose connections are made at once: each the protocol `alpn`, going the way `way` says of its peer as
/// it is asked, every stream answered `answer` (a head line) and ended.
export function dialing(alpn: Buffer, answer: unknown, way: (peer: string) => Way) {
  const dialed: Addr[] = [];
  const made: Connection[] = [];
  const endpoint = {
    connect: async (addr: Addr) => {
      dialed.push(addr);
      let closed = false;
      const conn = {
        remoteId: () => addr.id,
        alpn: () => alpn,
        via: () => ("relay" in way(addr.id) ? "relay" : "direct"),
        paths: () => {
          const w = way(addr.id);
          return [{ selected: true, ...("relay" in w ? { relay: w.relay, ip: null } : { relay: null, ip: w.ip }), txPackets: 0, lostPackets: 0 }];
        },
        isClosed: () => closed,
        close: () => void (closed = true),
        closed: () => new Promise<string>(() => {}),
        answers: async () => true,
        acceptBi: async () => null,
        openBi: async () => {
          let given = false;
          return {
            write: async () => {},
            finish: async () => {},
            read: async () => (given ? null : ((given = true), Buffer.from(JSON.stringify(answer) + "\n"))),
            reset: async () => {},
            stopped: async () => null,
          };
        },
      } as unknown as Connection;
      made.push(conn);
      return conn;
    },
  } as unknown as Endpoint;
  return { endpoint, dialed, made };
}
