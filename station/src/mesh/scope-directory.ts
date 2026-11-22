// One serialized owner of the native scopes. Its roster is supplied by the
// station's admission layer; signed announcements never grant membership.
import { Announcements, announcementOf, type Announcement } from "./announcements.ts";
import type { Endpoint, MeshDescriptor, MeshScopeView, MeshGlobalRelay } from "./endpoint.ts";
import { globalRelaysOf } from "./global-relays.ts";
export type ScopeRoster = { scope: string; nodes: ReadonlySet<string>; generations?: ReadonlyMap<string, number>; relayUrls: string[]; transit: boolean; globalRelays?: MeshGlobalRelay[] };

const MAX_UNDERLAY_ADDRS = 8;

function parseIpv4(host: string): [number, number, number, number] | null {
  const parts = host.split(".");
  if (parts.length !== 4) return null;
  const out: number[] = [];
  for (const part of parts) {
    if (!/^(?:0|[1-9][0-9]{0,2})$/.test(part)) return null;
    const n = Number(part);
    if (n > 255) return null;
    out.push(n);
  }
  return [out[0]!, out[1]!, out[2]!, out[3]!];
}

function parseIpv6(raw: string): number[] | null {
  const host = raw.includes("%") ? raw.slice(0, raw.indexOf("%")) : raw;
  const doubleColon = host.indexOf("::");
  if (doubleColon !== -1 && host.indexOf("::", doubleColon + 2) !== -1) return null;
  const parseSide = (side: string, allowIpv4Tail: boolean): number[] | null => {
    if (!side) return [];
    const parts = side.split(":");
    const groups: number[] = [];
    for (let i = 0; i < parts.length; i++) {
      const part = parts[i]!;
      if (allowIpv4Tail && i === parts.length - 1 && part.includes(".")) {
        const v4 = parseIpv4(part);
        if (!v4) return null;
        groups.push((v4[0] << 8) | v4[1], (v4[2] << 8) | v4[3]);
      } else {
        if (!/^[0-9a-fA-F]{1,4}$/.test(part)) return null;
        groups.push(parseInt(part, 16));
      }
    }
    return groups;
  };
  if (doubleColon === -1) {
    const groups = parseSide(host, true);
    return groups && groups.length === 8 ? groups : null;
  }
  const left = parseSide(host.slice(0, doubleColon), false);
  const right = parseSide(host.slice(doubleColon + 2), true);
  if (!left || !right || left.length + right.length >= 8) return null;
  return [...left, ...Array<number>(8 - left.length - right.length).fill(0), ...right];
}

function ipTier(raw: string): number {
  let host = raw;
  if (host.startsWith("[")) {
    const end = host.indexOf("]");
    if (end !== -1) host = host.slice(1, end);
  } else {
    const first = host.indexOf(":");
    const last = host.lastIndexOf(":");
    if (first !== -1 && first === last) host = host.slice(0, first);
  }
  const v4 = parseIpv4(host);
  if (v4) {
    const [a, b, c, d] = v4;
    if ((a === 169 && b === 254) || a === 127 || (a === 0 && b === 0 && c === 0 && d === 0)) return 5;
    if (a === 10 || (a === 172 && (b & 0xf0) === 16) || (a === 192 && b === 168) || (a === 100 && (b & 0xc0) === 64)) return 3;
    if ((a & 0xf0) === 224 || (a === 255 && b === 255 && c === 255 && d === 255)
        || (a === 192 && b === 0 && c === 2) || (a === 198 && b === 51 && c === 100) || (a === 203 && b === 0 && c === 113)
        || a === 0) return 4;
    return 1;
  }
  const v6 = parseIpv6(host);
  if (v6) {
    const s0 = v6[0]!;
    const allZero = v6.every((g) => g === 0);
    const isLoopback = v6.slice(0, 7).every((g) => g === 0) && v6[7] === 1;
    if ((s0 & 0xffc0) === 0xfe80 || isLoopback || allZero) return 5;
    if ((s0 & 0xfe00) === 0xfc00 || (s0 & 0xff00) === 0xff00) return 4;
    return 2;
  }
  return 4;
}

function underlayEntry(addr: unknown): { tier: number; key: string; dedup: string } | null {
  if (!addr || typeof addr !== "object" || Array.isArray(addr)) return null;
  const keys = Object.keys(addr);
  if (keys.length !== 1) return null;
  const rec = addr as Record<string, unknown>;
  if (typeof rec.Relay === "string" && rec.Relay.length <= 2048) {
    return { tier: 0, key: rec.Relay, dedup: `R:${rec.Relay}` };
  }
  if (typeof rec.Ip === "string" && rec.Ip.length <= 128) {
    return { tier: ipTier(rec.Ip), key: rec.Ip, dedup: `I:${rec.Ip}` };
  }
  return null;
}

function boundedDescriptor(descriptor: MeshDescriptor): MeshDescriptor {
  const address = descriptor?.address as { id?: unknown; addrs?: unknown } | null | undefined;
  if (!address || typeof address !== "object" || !Array.isArray(address.addrs) || address.addrs.length <= MAX_UNDERLAY_ADDRS) {
    return descriptor;
  }
  const ranked: { tier: number; key: string; addr: unknown }[] = [];
  const seen = new Set<string>();
  for (const addr of address.addrs) {
    const entry = underlayEntry(addr);
    if (!entry) return descriptor;
    if (seen.has(entry.dedup)) continue;
    seen.add(entry.dedup);
    ranked.push({ tier: entry.tier, key: entry.key, addr });
  }
  ranked.sort((a, b) => a.tier - b.tier || (a.key < b.key ? -1 : a.key > b.key ? 1 : 0));
  return { ...descriptor, address: { ...address, addrs: ranked.slice(0, MAX_UNDERLAY_ADDRS).map((r) => r.addr) } };
}
export class ScopeDirectory {
  readonly endpoint: Endpoint;
  readonly kept: Announcements;
  readonly signer: { id: string; sign(text: string): string };
  #wanted = new Map<string, ScopeRoster>();
  #applied = new Map<string, string>();
  #known = new Set<string>();
  #serial: Promise<void> = Promise.resolve();
  #closed = false;
  #authoritative = false;
  #off: () => void;
  readonly changed: (scope: string) => void;
  readonly failed: (error: unknown) => void;
  constructor(endpoint: Endpoint, kept: Announcements, signer: { id: string; sign(text: string): string }, changed: (scope: string) => void, failed: (error: unknown) => void) {
    this.endpoint = endpoint; this.kept = kept; this.signer = signer; this.changed = changed; this.failed = failed;
    this.#off = endpoint.meshListen?.((scopes) => {
      try { this.#addresses(scopes); }
      catch (error) { this.failed(error); }
      if (this.#authoritative && scopes.some(({ scope }) => !this.#wanted.has(scope))) void this.reconcile().catch(this.failed);
    }) ?? (() => {});
  }
  #addresses(scopes: MeshScopeView[]) {
    if (this.#closed) return;
    for (const { scope, descriptor } of scopes) {
      this.#known.add(scope);
      if (!this.#wanted.has(scope)) continue;
      const before = this.kept.list(scope, new Set([this.signer.id]))[0];
      const after = this.kept.publish(scope, boundedDescriptor(descriptor), this.signer);
      if (before?.body !== after.body) this.changed(scope);
    }
  }
  set(rosters: ScopeRoster[]): Promise<void> {
    if (rosters.length > 32 || new Set(rosters.map((r) => r.scope)).size !== rosters.length) throw new Error("too many or duplicate mesh scopes");
    const next = new Map<string, ScopeRoster>();
    for (const r of rosters) {
      if (!/^[0-9a-f]{64}$/.test(r.scope) || r.nodes.size > 256 || !r.nodes.has(this.signer.id)
          || [...r.nodes].some((n) => !/^[0-9a-f]{64}$/.test(n))) throw new Error("invalid mesh roster");
      const globalRelays = globalRelaysOf(r.globalRelays);
      if (globalRelays.some(g => r.nodes.has(g.node)) || r.nodes.size + globalRelays.length > 256) throw new Error("conflicting or excessive mesh identities");
      next.set(r.scope, { ...r, nodes: new Set(r.nodes), generations: new Map(r.generations), relayUrls: [...r.relayUrls], globalRelays });
    }
    this.kept.retain(new Map([...next].map(([scope, r]) => [scope, r.nodes])));
    this.#wanted = next;
    this.#authoritative = true;
    return this.reconcile();
  }
  policy(scope: string): { nodes: string[]; generations: Record<string, number>; relayUrls: string[]; globalRelays: MeshGlobalRelay[] } {
    const r = this.#wanted.get(scope);
    if (!r || this.#closed) throw new Error("mesh scope removed");
    return { nodes: [...r.nodes], generations: Object.fromEntries(r.generations ?? []), relayUrls: [...r.relayUrls], globalRelays: structuredClone(r.globalRelays ?? []) };
  }
  ready(scope: string, node: string): boolean {
    return !this.#closed && this.#applied.has(scope) && this.#wanted.get(scope)?.nodes.has(node) === true;
  }
  // Whether `node` is on the scope's roster here: an exchange asks a peer for only these (scope-exchange.ts).
  admits(scope: string, node: string): boolean {
    return this.#wanted.get(scope)?.nodes.has(node) === true;
  }
  records(scope: string): Announcement[] {
    const r = this.#wanted.get(scope);
    return r ? this.kept.list(scope, r.nodes).filter((record) => {
      const value = JSON.parse(record.body);
      return value.descriptor.binding.generation >= (r.generations?.get(value.node) ?? 0);
    }) : [];
  }
  take(scope: string, records: Announcement[]): Promise<void> {
    const r = this.#wanted.get(scope);
    if (!r || !Array.isArray(records) || records.length > 256) throw new Error("invalid mesh directory exchange");
    // Validate the complete batch before keeping any part of it.
    for (const record of records) {
      const value = announcementOf(record, scope, r.nodes);
      if (value.descriptor.binding.generation < (r.generations?.get(value.node) ?? 0)) throw new Error("stale mesh binding generation");
    }
    let changed = false;
    for (const record of records) changed = this.kept.take(record, scope, r.nodes) || changed;
    if (changed) this.changed(scope);
    return this.reconcile();
  }
  async exchange(scope: string, request: { give?: Announcement[]; want?: string[] }): Promise<{ versions: Record<string, number>; records: Announcement[] }> {
    const r = this.#wanted.get(scope);
    if (!r || !Array.isArray(request.give ?? []) || (request.give?.length ?? 0) > 16
        || !Array.isArray(request.want ?? []) || (request.want?.length ?? 0) > 16
        || request.want?.some((node) => typeof node !== "string" || !r.nodes.has(node))) throw new Error("invalid mesh directory exchange");
    await this.take(scope, request.give ?? []);
    // Membership can change while native configuration is awaited. Do not give
    // the previous roster's records after that change.
    const current = this.#wanted.get(scope);
    if (!current) throw new Error("mesh scope removed");
    const versions: Record<string, number> = {};
    const records: Announcement[] = [];
    const want = new Set(request.want ?? []);
    for (const record of this.records(scope)) {
      const value = announcementOf(record, scope, current.nodes);
      versions[value.node] = value.revision;
      if (want.has(value.node)) records.push(record);
    }
    return { versions, records };
  }
  reconcile(): Promise<void> {
    const run = this.#serial.catch(() => {}).then(async () => {
      if (this.#closed || !this.endpoint.meshConfigure || !this.endpoint.meshRemove) return;
      for (const scope of this.#known) if (!this.#wanted.has(scope)) {
        await this.endpoint.meshRemove(scope);
        this.#known.delete(scope); this.#applied.delete(scope);
      }
      // Each await can admit a new roster. Its queued reconciliation owns the next
      // configuration; do not continue applying entries from a superseded roster.
      const wanted = this.#wanted;
      for (const [scope, r] of wanted) {
        if (this.#closed || this.#wanted !== wanted) break;
        await this.kept.load(scope, r.nodes);
        if (this.#closed || this.#wanted !== wanted) break;
        const peers = this.records(scope).map((a) => announcementOf(a, scope, r.nodes)).filter((a) => a.node !== this.signer.id).map((a) => a.descriptor);
        const config = { scope, peers, transit: r.transit, relayUrls: r.relayUrls, globalRelays: r.globalRelays ?? [] };
        const word = JSON.stringify(config);
        if (this.#applied.get(scope) === word) continue;
        // Remember even an unacknowledged configure: a later removal must send a
        // tombstone, since the front may already have accepted this configuration.
        this.#known.add(scope);
        const descriptor = await this.endpoint.meshConfigure(config);
        this.#applied.set(scope, word);
        if (!this.#closed && this.#wanted === wanted) this.#addresses([{ scope, descriptor }]);
      }
    });
    this.#serial = run;
    return run;
  }
  close(): void {
    this.#closed = true; this.#off();
    // Native forwarding survives a Node handover. The successor reconciles the
    // scopes against its authoritative roster instead of destroying all routes.
  }
}
