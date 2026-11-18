// Global mesh registration is bootstrap metadata only. No workspace scope,
// member directory, live links, routes, or link quality are stored here.
import { validKeyHex } from "./grants";
import { relayUrl } from "./relays";
export const MESH_RELAY_TABLES = `CREATE TABLE IF NOT EXISTS mesh_relays (
  node TEXT PRIMARY KEY, name TEXT NOT NULL, generation INTEGER NOT NULL,
  revision INTEGER NOT NULL, address TEXT NOT NULL, revoked INTEGER NOT NULL DEFAULT 0,
  added_at INTEGER NOT NULL, added_by TEXT NOT NULL
);`;
export type MeshAddress = { id: string; addrs: ({ Ip: string } | { Relay: string })[] };
export type MeshRelay = { node: string; name: string; generation: number; revision: number; address: MeshAddress };
export type MeshRegistration = { node: string; revision: number; address: MeshAddress; token?: string; generation?: number };
export const meshRelayMessage = (origin: string, body: string) => `mesh-global-registration/v1\0${origin.replace(/\/+$/, "")}\0${body}`;
export function meshRegistration(body: unknown, enroll: boolean, insecure: boolean): MeshRegistration | null {
  if (typeof body !== "string" || new TextEncoder().encode(body).length > 8192) return null;
  let value: any;
  try { value = JSON.parse(body); } catch { return null; }
  if (!value || !validKeyHex(value.node) || !Number.isSafeInteger(value.revision) || value.revision < 1) return null;
  if (enroll ? typeof value.token !== "string" || value.token.length < 16 || value.token.length > 256
    : !Number.isSafeInteger(value.generation) || value.generation < 1) return null;
  const address = value.address;
  if (!address || address.id !== value.node || !Array.isArray(address.addrs) || address.addrs.length > 8) return null;
  const addrs: MeshAddress["addrs"] = [];
  for (const addr of address.addrs) {
    if (!addr || typeof addr !== "object" || Object.keys(addr).length !== 1) return null;
    if (typeof addr.Relay === "string") {
      const relay = relayUrl(addr.Relay, insecure);
      if (!relay) return null;
      addrs.push({ Relay: relay });
    } else if (typeof addr.Ip === "string" && addr.Ip.length <= 128) {
      // Numeric socket addresses only; no DNS name or recursive custom transport.
      if (!/^(?:\d{1,3}(?:\.\d{1,3}){3}|\[[0-9a-fA-F:]+\]):\d{1,5}$/.test(addr.Ip)) return null;
      try {
        const url = new URL(`http://${addr.Ip}`);
        const port = Number(addr.Ip.slice(addr.Ip.lastIndexOf(":") + 1));
        if (port < 1 || port > 65535 || !url.hostname) return null;
      } catch { return null; }
      addrs.push({ Ip: addr.Ip });
    } else return null;
  }
  return { node: value.node, revision: value.revision, address: { id: value.node, addrs },
    ...(enroll ? { token: value.token } : { generation: value.generation }) };
}
