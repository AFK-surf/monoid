// The agents' hand on the relays of their chat's workspace (mesh/ways.ts): listed, added, taken away. Nobody approves
// a relay (the user, 2026-11-11: 「要手动加太不 ai native 了」); one is added only once this station reached it as a relay.
import { wall } from "../ops/fibers.ts";
import { MAX_OWN_RELAYS, type Ways, WaysRefusal, addRelay, relayUrl, removeRelay, stillFails } from "../mesh/ways.ts";
import type { Tool } from "./mcp.ts";

/// What reaching a relay found: it answered as one (its round trip, the second ask's), or why it is none.
export type Probed = { ok: true; ms: number } | { ok: false; why: string };

/// Whether `url` is a relay this station reaches: its https (a valid certificate) answers `/ping` (twice, the second
/// timed on the connection made) and refuses `/relay` asked without the relay's handshake, as iroh's relay does.
export async function probeRelay(url: string): Promise<Probed> {
  const base = url.replace(/\/+$/, "");
  try {
    const first = await fetch(`${base}/ping`, { signal: AbortSignal.timeout(10_000) });
    await first.arrayBuffer();
    if (!first.ok) return { ok: false, why: `${base}/ping answered ${first.status}: not a relay` };
    const start = wall.now();
    const again = await fetch(`${base}/ping`, { signal: AbortSignal.timeout(10_000) });
    await again.arrayBuffer();
    const ms = wall.now() - start;
    const relay = await fetch(`${base}/relay`, { signal: AbortSignal.timeout(10_000) });
    await relay.arrayBuffer();
    if (relay.status !== 400 && relay.status !== 426) return { ok: false, why: `${base}/relay answered ${relay.status}, not a relay's refusal of a plain request` };
    return { ok: true, ms };
  } catch (e) {
    const cause = (e as { cause?: { code?: string; message?: string } }).cause;
    return { ok: false, why: `${base} not reached from this station: ${cause?.code ?? cause?.message ?? (e as Error).message}` };
  }
}

export type RelayToolsDeps = {
  /// The ways this station keeps; null before it is in a workspace.
  ways: () => Ways | null;
  /// The workspace a session is in (its chat's).
  workspaceOf: (session: string) => string | null;
  /// Who a session's change is said to be by: its chat's name.
  by: (session: string) => string;
  meshList?: (workspace: string) => unknown[];
  revoke?: (workspace: string, node: string) => Promise<unknown>;
  enroll?: (workspace: string, name: string, by: string) => unknown;
  probe?: (url: string) => Promise<Probed>;
};

export function relayTools(deps: RelayToolsDeps): Tool[] {
  const probe = deps.probe ?? probeRelay;
  return [{
    name: "relays",
    description: `Manage this workspace's relays. list shows relay URLs, disabled routes and registered mesh nodes. add probes an https iroh relay URL before sharing it with workspace stations and devices; no approval needed. remove removes a URL; at most ${MAX_OWN_RELAYS} own URLs. enroll (name) issues a private one-use token valid for 24 hours, granting forwarding only. revoke (node) removes a mesh relay through its issuing station, which must be reachable.`,
    inputSchema: {
      type: "object",
      properties: {
        action: { type: "string", enum: ["list", "add", "remove", "enroll", "revoke"] },
        node: { type: "string", description: "Mesh relay public key from list (revoke)." },
        name: { type: "string", description: "Name for a new mesh relay (enroll)." },
        url: { type: "string", description: "The relay's URL (add, remove)." },
      },
      required: ["action"],
      additionalProperties: false,
    },
    run: async (session, args) => {
      const ways = deps.ways();
      const ws = deps.workspaceOf(session);
      if (ways === null || !ws) throw new Error("this station is in no workspace");
      const action = args.action;
      const list = () => {
        const v = ways.view(ws);
        return { workspace: ws, own: v.relays, still_fail: stillFails(ways.cloud), off: v.off };
      };
      if (action === "list") return JSON.stringify({ ...list(), ...(deps.meshList ? { mesh: deps.meshList(ws) } : {}) });
      if (action === "revoke") {
        if (!deps.revoke) throw new Error("mesh relay revocation is not available on this station");
        if (typeof args.node !== "string" || !/^[0-9a-f]{64}$/.test(args.node)) throw new Error("node must be a mesh relay public key from list");
        return JSON.stringify(await deps.revoke(ws, args.node));
      }
      if (action === "enroll") {
        if (!deps.enroll) throw new Error("mesh relay enrollment is not available on this station");
        if (typeof args.name !== "string") throw new Error("name is required for mesh relay enrollment");
        return JSON.stringify(deps.enroll(ws, args.name, deps.by(session)));
      }
      const raw = typeof args.url === "string" ? args.url : "";
      if (action === "add") {
        const url = relayUrl(raw, (ways.cloud.state?.origin ?? "").startsWith("http:"));
        if (url === null) throw new Error("url: https://host[:port][/path], with no account, query or fragment");
        const reached = await probe(url);
        if (!reached.ok) throw new Error(`not added: ${reached.why}`);
        try {
          addRelay(ways, ws, url, deps.by(session));
        } catch (e) {
          if (e instanceof WaysRefusal) throw new Error(`not added: ${e.message}`);
          throw e;
        }
        return JSON.stringify({ added: url, round_trip_ms: reached.ms, ...list() });
      }
      if (action === "remove") {
        try {
          removeRelay(ways, ws, raw);
        } catch (e) {
          if (e instanceof WaysRefusal) throw new Error(`not removed: ${e.message}`);
          throw e;
        }
        return JSON.stringify({ removed: relayUrl(raw, true) ?? raw, ...list() });
      }
      throw new Error("action: list, add, remove, enroll or revoke");
    },
  }];
}
