// The relays stations and devices use. The first is this cloud's own (RELAY_URL, or PUBLIC_ORIGIN's /relay:
// relay-worker.ts), handed out alone as `relay_url` to what came before there were several. The others are the cloud's
// list (relay-registry.ts, kept by the Directory), its operator's to keep: no deploy's config lists them (the user,
// 2026-11-17: 「env 不保留，外部要用让他们自己配」), and a relay is put on it only by the operator or by one holding a
// token the operator made for it. Each endpoint has all of them in its map: a station homes on the nearest, and a
// device dials it on every one (client/core-ts mesh.ts). A listed relay's name is what people see a connection go
// through (经中继北京).
import { originList } from "./compat";
import type { WayView } from "./types";

/** One relay of the cloud's list: a relay, or (`target`) a way into the relay at `target` for devices alone, through a
 * machine their line reaches well and whose line to that relay is good (Beijing's to Hong Kong's: a phone in the
 * mainland reaches Beijing well, a station in Tokyo Hong Kong; 2026-10-08, bft). `name` "" is none. */
export type Listed = { url: string; name: string; target: string | null };
/** The relays as the cloud has them: its own and its list. */
export type Relays = { own: string; listed: Listed[] };

/** This cloud's own relay. */
export const ownRelay = (env: { PUBLIC_ORIGIN: string; RELAY_URL?: string }): string => env.RELAY_URL || env.PUBLIC_ORIGIN;

/** The relays a station and a device home on: the cloud's own first, then its list's, each once. */
export const relayUrls = (r: Relays): string[] => {
  const out = [r.own];
  for (const l of r.listed) if (l.target === null && !out.some((u) => sameUrl(u) === sameUrl(l.url))) out.push(l.url);
  return out;
};

/** What a station or a device is told about the relays: the one, as before, all of them, and the names of those named.
 * A device (`device`) is told of the ways into them as well, as `relay_entries`, and `relay_entry_targets` which relay
 * is on the other side of each. An entry is not another relay: putting both among `relay_urls` registers the same key
 * twice and the connections displace each other. New clients choose an entrance within the relay connection; older
 * ones dial each entry on an endpoint of its own. A station is not told the entries. */
export function relays(r: Relays, device = false): { relay_url: string; relay_urls: string[]; relay_names: Record<string, string>; relay_entries?: string[]; relay_entry_targets?: Record<string, string> } {
  const own = relayUrls(r);
  const isOwn = (url: string) => own.some((u) => sameUrl(u) === sameUrl(url));
  const entries: string[] = [];
  const targets: Record<string, string> = {};
  if (device) {
    for (const l of r.listed) {
      if (l.target === null || isOwn(l.url) || entries.some((u) => sameUrl(u) === sameUrl(l.url))) continue;
      entries.push(l.url);
      const relay = own.find((u) => sameUrl(u) === sameUrl(l.target!));
      if (relay !== undefined) targets[l.url] = relay;
    }
  }
  const named = (url: string) => r.listed.find((l) => sameUrl(l.url) === sameUrl(url) && l.name !== "")?.name;
  const names = Object.fromEntries([...own, ...entries].flatMap((url) => (named(url) ? [[url, named(url)!]] : [])));
  return { relay_url: own[0]!, relay_urls: own, relay_names: names, ...(device ? { relay_entries: entries, relay_entry_targets: targets } : {}) };
}

/** What a relay is called: its name on the list, else its host. */
export const relayName = (r: Relays, url: string): string => r.listed.find((l) => sameUrl(l.url) === sameUrl(url) && l.name !== "")?.name ?? new URL(url).host;

/** The list as a deploy's config said it before the cloud kept one (RELAY_URLS, RELAY_ENTRIES, RELAY_ENTRY_TARGETS,
 * RELAY_NAMES): what the Directory takes as its list once, the first time it opens without one (relay-registry.ts). A
 * name of the cloud's own relay is kept too, as a row of its own. */
export function listedFromConfig(env: { PUBLIC_ORIGIN: string; RELAY_URL?: string; RELAY_URLS?: string; RELAY_ENTRIES?: string; RELAY_ENTRY_TARGETS?: Record<string, string>; RELAY_NAMES?: Record<string, string> }): Listed[] {
  const own = ownRelay(env);
  const nameOf = (url: string) => Object.entries(env.RELAY_NAMES ?? {}).find(([u]) => sameUrl(u) === sameUrl(url))?.[1] ?? "";
  const out: Listed[] = [];
  const add = (url: string, target: string | null) => {
    if (out.some((l) => sameUrl(l.url) === sameUrl(url))) return;
    out.push({ url, name: nameOf(url), target });
  };
  if (nameOf(own) !== "") add(own, null);
  for (const url of originList("", env.RELAY_URLS)) if (sameUrl(url) !== sameUrl(own)) add(url, null);
  const relaysNow = [own, ...out.map((l) => l.url)];
  for (const url of originList("", env.RELAY_ENTRIES)) {
    if (relaysNow.some((u) => sameUrl(u) === sameUrl(url))) continue;
    const target = Object.entries(env.RELAY_ENTRY_TARGETS ?? {}).find(([u]) => sameUrl(u) === sameUrl(url))?.[1];
    const relay = target === undefined ? undefined : relaysNow.find((u) => sameUrl(u) === sameUrl(target));
    // (an entry into no relay of the list is no way into anything)
    if (relay !== undefined) add(url, relay);
  }
  return out;
}

/** At most this many relays of a workspace's own (directory.ts setRelays). */
export const MAX_RELAYS = 4;

/** A relay's URL as compared: its normal form without a trailing slash. */
export const sameUrl = (url: string): string => (URL.canParse(url) ? new URL(url).href : url).replace(/\/+$/, "");

/** A relay's URL as one is kept: https (http too where `insecure`, a local setup), no account, query or fragment, no
 * trailing slash; null when it is none. */
export function relayUrl(raw: unknown, insecure = false): string | null {
  if (typeof raw !== "string" || !URL.canParse(raw.trim())) return null;
  const url = new URL(raw.trim());
  if (!(url.protocol === "https:" || (insecure && url.protocol === "http:")) || url.username || url.password || url.search || url.hash) return null;
  return url.href.replace(/\/+$/, "");
}

/** A workspace's own relays as kept (a JSON array, or null for none). */
export function parseRelays(kept: unknown): string[] {
  if (typeof kept !== "string") return [];
  try {
    const list: unknown = JSON.parse(kept);
    return Array.isArray(list) ? list.filter((u): u is string => typeof u === "string") : [];
  } catch {
    return [];
  }
}

/** The ways to a station that are no relay, which a workspace may turn off as it may a relay: straight on its LAN, over
 * Tailscale, and a path iroh punches through (连接方式). */
export const WAY_KINDS = ["lan", "tailnet", "direct"] as const;

/** Every way a workspace's devices may reach its stations: the cloud's relays, its own, then the kinds that are no
 * relay; each on unless among `off` (`ours` turns off all of the cloud's relays). */
export function waysOf(r: Relays, own: string[], off: string[]): WayView[] {
  const isOff = (id: string) => off.some((o) => sameUrl(o) === sameUrl(id));
  const oursOff = off.includes("ours");
  return [
    ...relayUrls(r).map((url): WayView => {
      const name = r.listed.find((l) => sameUrl(l.url) === sameUrl(url) && l.name !== "")?.name;
      return { id: url, kind: "relay", ...(name ? { name } : {}), on: !oursOff && !isOff(url) };
    }),
    ...own.map((url): WayView => ({ id: url, kind: "relay", own: true, on: !isOff(url) })),
    ...WAY_KINDS.map((kind): WayView => ({ id: kind, kind, on: !off.includes(kind) })),
  ];
}
