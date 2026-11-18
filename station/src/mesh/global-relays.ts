import { isIP } from "node:net";
import type { MeshGlobalRelay } from "./endpoint.ts";

/** Global bootstrap metadata only. Reject the whole malformed snapshot. */
export function globalRelaysOf(raw: unknown): MeshGlobalRelay[] {
  if (raw === undefined) return [];
  if (!Array.isArray(raw) || raw.length > 32) throw new Error("invalid global mesh registry");
  const seen = new Set<string>();
  return raw.map((r) => {
    if (!r || !/^[0-9a-f]{64}$/.test(r.node) || seen.has(r.node) || typeof r.name !== "string" || [...r.name].length > 40
      || !Number.isSafeInteger(r.generation) || r.generation < 1 || !Number.isSafeInteger(r.revision) || r.revision < 1
      || r.address?.id !== r.node || !Array.isArray(r.address.addrs) || r.address.addrs.length > 8) throw new Error("invalid global mesh relay");
    seen.add(r.node);
    const addrs = r.address.addrs.map((a: any) => {
      if (!a || Object.keys(a).length !== 1) throw new Error("invalid global mesh address");
      if (typeof a.Ip === "string") {
        const match = /^(?:\[([^\]]+)\]|([^:]+)):(\d+)$/.exec(a.Ip);
        if (!match || !isIP(match[1] ?? match[2]!) || Number(match[3]) < 1 || Number(match[3]) > 65535) throw new Error("invalid global mesh IP");
        return { Ip: a.Ip };
      }
      if (typeof a.Relay === "string" && a.Relay.length <= 2048) {
        const url = new URL(a.Relay);
        if (!["https:", "http:"].includes(url.protocol) || url.username || url.password || url.search || url.hash) throw new Error("invalid global mesh relay URL");
        return { Relay: url.href };
      }
      throw new Error("recursive global mesh address");
    });
    return { node: r.node, name: r.name, generation: r.generation, revision: r.revision, address: { id: r.node, addrs } };
  });
}
