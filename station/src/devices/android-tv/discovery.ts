// LAN mDNS DNS-SD discovery and manual TCP port probe for Android TV / Google TV / Android TV boxes.
// Uses an ephemeral UDP4 socket bound to port 0 (never binds 5353, closes immediately after timeoutMs).
import dgram from "node:dgram";
import net from "node:net";
import { wall } from "../../ops/fibers.ts";
import type { AndroidTvCandidate, AndroidTvCandidateProtocol } from "./types.ts";

const MDNS_ADDR = "224.0.0.251";
const MDNS_PORT = 5353;

export const MDNS_SERVICES = [
  "_androidtvremote2._tcp.local",
  "_adb-tls-connect._tcp.local",
  "_adb-tls-pairing._tcp.local",
] as const;

const TYPE_A = 1;
const TYPE_PTR = 12;
const TYPE_TXT = 16;
const TYPE_SRV = 33;

function encodeDnsName(name: string): Buffer {
  const parts = name.replace(/\.$/, "").split(".").filter(Boolean);
  const chunks: Buffer[] = [];
  for (const part of parts) {
    const b = Buffer.from(part, "utf8");
    chunks.push(Buffer.from([b.length]), b);
  }
  chunks.push(Buffer.from([0]));
  return Buffer.concat(chunks);
}

/// Build a standard mDNS PTR query packet with QU bit (0x8001) set so responders unicast back to our ephemeral port.
export function buildMdnsQuery(services: readonly string[]): Buffer {
  const header = Buffer.alloc(12);
  header.writeUInt16BE(0, 0); // ID
  header.writeUInt16BE(0, 2); // Flags: standard query
  header.writeUInt16BE(services.length, 4); // QDCOUNT
  const questions: Buffer[] = [];
  for (const svc of services) {
    const qname = encodeDnsName(svc);
    const tail = Buffer.alloc(4);
    tail.writeUInt16BE(TYPE_PTR, 0);
    tail.writeUInt16BE(0x8001, 2); // Class IN + QU bit
    questions.push(qname, tail);
  }
  return Buffer.concat([header, ...questions]);
}

function readDnsName(buf: Buffer, offset: number, depth = 0): { name: string; next: number } | null {
  if (depth > 16 || offset < 0 || offset >= buf.length) return null;
  const labels: string[] = [];
  let pos = offset;
  let jumped = false;
  let endPos = offset;
  while (pos < buf.length) {
    const len = buf[pos]!;
    if (len === 0) {
      if (!jumped) endPos = pos + 1;
      break;
    }
    if ((len & 0xc0) === 0xc0) {
      if (pos + 1 >= buf.length) return null;
      const ptr = ((len & 0x3f) << 8) | buf[pos + 1]!;
      if (!jumped) {
        endPos = pos + 2;
        jumped = true;
      }
      const sub = readDnsName(buf, ptr, depth + 1);
      if (!sub) return null;
      if (sub.name) labels.push(sub.name);
      break;
    }
    pos++;
    if (pos + len > buf.length) return null;
    labels.push(buf.subarray(pos, pos + len).toString("utf8"));
    pos += len;
    if (!jumped) endPos = pos;
  }
  return { name: labels.join("."), next: endPos };
}

export type ParsedDnsRecords = {
  ptrs: { service: string; instance: string }[];
  srvs: { instance: string; host: string; port: number }[];
  txts: { instance: string; kv: Record<string, string> }[];
  as: { host: string; ip: string }[];
};

/// Parse PTR, SRV, TXT, and A records from a raw DNS/mDNS UDP packet.
export function parseMdnsPacket(buf: Buffer): ParsedDnsRecords {
  const out: ParsedDnsRecords = { ptrs: [], srvs: [], txts: [], as: [] };
  if (buf.length < 12) return out;
  const qdCount = buf.readUInt16BE(4);
  const anCount = buf.readUInt16BE(6);
  const nsCount = buf.readUInt16BE(8);
  const arCount = buf.readUInt16BE(10);
  let pos = 12;

  for (let i = 0; i < qdCount; i++) {
    const qn = readDnsName(buf, pos);
    if (!qn || qn.next + 4 > buf.length) return out;
    pos = qn.next + 4;
  }

  const totalRr = anCount + nsCount + arCount;
  for (let i = 0; i < totalRr; i++) {
    const rn = readDnsName(buf, pos);
    if (!rn || rn.next + 10 > buf.length) break;
    pos = rn.next;
    const type = buf.readUInt16BE(pos);
    const rdLen = buf.readUInt16BE(pos + 8);
    pos += 10;
    if (pos + rdLen > buf.length) break;
    const rdataEnd = pos + rdLen;
    if (type === TYPE_PTR) {
      const target = readDnsName(buf, pos);
      if (target) out.ptrs.push({ service: rn.name.toLowerCase(), instance: target.name });
    } else if (type === TYPE_SRV && rdLen >= 6) {
      const port = buf.readUInt16BE(pos + 4);
      const target = readDnsName(buf, pos + 6);
      if (target) out.srvs.push({ instance: rn.name, host: target.name.toLowerCase(), port });
    } else if (type === TYPE_TXT) {
      const kv: Record<string, string> = {};
      let p = pos;
      while (p < rdataEnd) {
        const l = buf[p++]!;
        if (p + l > rdataEnd) break;
        const entry = buf.subarray(p, p + l).toString("utf8");
        p += l;
        const eq = entry.indexOf("=");
        if (eq > 0) kv[entry.slice(0, eq).toLowerCase()] = entry.slice(eq + 1);
      }
      out.txts.push({ instance: rn.name, kv });
    } else if (type === TYPE_A && rdLen === 4) {
      const ip = `${buf[pos]}.${buf[pos + 1]}.${buf[pos + 2]}.${buf[pos + 3]}`;
      out.as.push({ host: rn.name.toLowerCase(), ip });
    }
    pos = rdataEnd;
  }
  return out;
}

type Accumulator = {
  ptrs: Map<string, string>; // instance -> service
  srvs: Map<string, { host: string; port: number }>; // instance -> srv
  txts: Map<string, Record<string, string>>; // instance -> txt kv
  as: Map<string, string>; // host -> ipv4
};

function instanceDisplayName(instance: string): string {
  const dot = instance.indexOf("._");
  return dot > 0 ? instance.slice(0, dot) : instance;
}

/// Merge accumulated mDNS DNS-SD records across services into unified per-IP AndroidTvCandidate entries.
export function mergeMdnsRecords(packets: readonly ParsedDnsRecords[]): AndroidTvCandidate[] {
  const acc: Accumulator = {
    ptrs: new Map(),
    srvs: new Map(),
    txts: new Map(),
    as: new Map(),
  };
  for (const pkt of packets) {
    for (const p of pkt.ptrs) acc.ptrs.set(p.instance, p.service);
    for (const s of pkt.srvs) acc.srvs.set(s.instance, { host: s.host, port: s.port });
    for (const t of pkt.txts) {
      const prev = acc.txts.get(t.instance) ?? {};
      acc.txts.set(t.instance, { ...prev, ...t.kv });
    }
    for (const a of pkt.as) acc.as.set(a.host, a.ip);
  }

  type Merged = {
    ip: string;
    name?: string;
    model?: string;
    remotePort?: number;
    adbPort?: number;
    adbPairPort?: number;
  };
  const byIp = new Map<string, Merged>();

  for (const [instance, srv] of acc.srvs) {
    const ip = acc.as.get(srv.host);
    if (!ip) continue;
    const service = acc.ptrs.get(instance) ?? inferService(instance);
    if (!service) continue;
    let entry = byIp.get(ip);
    if (!entry) {
      entry = { ip };
      byIp.set(ip, entry);
    }
    const txt = acc.txts.get(instance) ?? {};
    const label = txt.name || txt.fn || instanceDisplayName(instance);
    if (service === "_androidtvremote2._tcp.local") {
      entry.remotePort = srv.port;
      if (label) entry.name = label;
      if (txt.bt || txt.md || txt.model) entry.model = txt.md || txt.model || entry.model;
    } else if (service === "_adb-tls-connect._tcp.local") {
      entry.adbPort = srv.port;
      if (!entry.name && label) entry.name = label;
      if (txt.name && !entry.model) entry.model = txt.name;
    } else if (service === "_adb-tls-pairing._tcp.local") {
      entry.adbPairPort = srv.port;
      if (!entry.name && label) entry.name = label;
    }
  }

  const candidates: AndroidTvCandidate[] = [];
  for (const m of byIp.values()) {
    const protocols: AndroidTvCandidateProtocol[] = [];
    if (m.remotePort !== undefined) {
      protocols.push({ protocol: "atv_remote", pairing: "mandatory", port: m.remotePort, pairPort: 6467 });
    }
    if (m.adbPort !== undefined || m.adbPairPort !== undefined) {
      protocols.push({
        protocol: "adb",
        pairing: m.adbPairPort !== undefined ? "mandatory" : "optional",
        ...(m.adbPort !== undefined ? { port: m.adbPort } : {}),
        ...(m.adbPairPort !== undefined ? { pairPort: m.adbPairPort } : {}),
        adbMode: "tls_wireless",
      });
    }
    if (protocols.length === 0) continue;
    candidates.push({
      identifier: m.ip,
      name: m.name || `Android TV (${m.ip})`,
      address: m.ip,
      model: m.model || "Android TV",
      ...(m.remotePort !== undefined ? { remotePort: m.remotePort } : {}),
      ...(m.adbPort !== undefined ? { adbPort: m.adbPort } : {}),
      ...(m.adbPairPort !== undefined ? { adbPairPort: m.adbPairPort } : {}),
      protocols,
    });
  }
  return candidates;
}

function inferService(instance: string): string | null {
  const lower = instance.toLowerCase();
  for (const svc of MDNS_SERVICES) {
    if (lower.endsWith(`.${svc}`)) return svc;
  }
  return null;
}

/// Probe whether a TCP port on `host` accepts a connection within `timeoutMs`.
export function probeTcpPort(host: string, port: number, timeoutMs = 1500): Promise<boolean> {
  return new Promise((resolve) => {
    const socket = net.connect({ host, port });
    let settled = false;
    const done = (ok: boolean) => {
      if (settled) return;
      settled = true;
      stop();
      socket.destroy();
      resolve(ok);
    };
    const stop = wall.after(timeoutMs, () => done(false));
    socket.once("connect", () => done(true));
    socket.once("error", () => done(false));
  });
}

/// Parse a user-supplied host or `host:port` (including bracketed IPv6).
export function parseHostSpec(spec: string): { host: string; explicitPort?: number } {
  const trimmed = spec.trim();
  const bracketMatch = /^\[([^\]]+)\](?::([0-9]{1,5}))?$/.exec(trimmed);
  if (bracketMatch) {
    const port = bracketMatch[2] ? Number(bracketMatch[2]) : undefined;
    return { host: bracketMatch[1]!, ...(port && port >= 1 && port <= 65535 ? { explicitPort: port } : {}) };
  }
  const colonIdx = trimmed.lastIndexOf(":");
  if (colonIdx > 0 && trimmed.indexOf(":") === colonIdx) {
    const port = Number(trimmed.slice(colonIdx + 1));
    if (Number.isSafeInteger(port) && port >= 1 && port <= 65535) {
      return { host: trimmed.slice(0, colonIdx), explicitPort: port };
    }
  }
  return { host: trimmed };
}

/// Actively probe a specific host/IP (e.g. `192.168.1.52` or `192.168.1.52:5555`) for Remote v2 (:6467) and ADB (:5555 or explicit port).
export async function probeAndroidTvHost(
  hostSpec: string,
  opts?: { timeoutMs?: number; remotePairPort?: number; remotePort?: number; defaultAdbPort?: number },
): Promise<AndroidTvCandidate[]> {
  const { host, explicitPort } = parseHostSpec(hostSpec);
  if (!host) return [];
  const timeoutMs = opts?.timeoutMs ?? 1500;
  const remotePairPort = opts?.remotePairPort ?? 6467;
  const remotePort = opts?.remotePort ?? 6466;
  const adbPort = explicitPort ?? opts?.defaultAdbPort ?? 5555;

  const [hasRemote, hasAdb] = await Promise.all([
    probeTcpPort(host, remotePairPort, timeoutMs),
    probeTcpPort(host, adbPort, timeoutMs),
  ]);

  const protocols: AndroidTvCandidateProtocol[] = [];
  if (hasRemote) {
    protocols.push({ protocol: "atv_remote", pairing: "mandatory", port: remotePort, pairPort: remotePairPort });
  }
  if (hasAdb) {
    protocols.push({
      protocol: "adb",
      pairing: "optional",
      port: adbPort,
      adbMode: adbPort === 5555 ? "legacy_tcp" : "tls_wireless",
    });
  }
  if (protocols.length === 0) return [];
  return [
    {
      identifier: explicitPort ? `${host}:${explicitPort}` : host,
      name: `Android TV (${host})`,
      address: host,
      model: "Android TV",
      ...(hasRemote ? { remotePort } : {}),
      ...(hasAdb ? { adbPort } : {}),
      protocols,
    },
  ];
}

/// Scan the local LAN for Android TV / Google TV / ADB wireless devices via mDNS, or probe a specific `host` if provided.
export async function scanAndroidTv(opts?: { timeoutMs?: number; host?: string }): Promise<AndroidTvCandidate[]> {
  if (opts?.host && opts.host.trim() !== "") {
    return probeAndroidTvHost(opts.host, { timeoutMs: Math.min(opts.timeoutMs ?? 2000, 5000) });
  }
  const timeoutMs = Math.max(300, Math.min(opts?.timeoutMs ?? 2500, 10_000));
  const packets: ParsedDnsRecords[] = [];

  await new Promise<void>((resolve) => {
    const sock = dgram.createSocket({ type: "udp4" });
    let closed = false;
    const finish = () => {
      if (closed) return;
      closed = true;
      stop();
      try { sock.close(); } catch {}
      resolve();
    };
    const stop = wall.after(timeoutMs, finish);
    sock.on("error", () => finish());
    sock.on("message", (msg) => {
      try {
        packets.push(parseMdnsPacket(msg));
      } catch {
        // ignore malformed packets
      }
    });
    sock.bind(0, () => {
      const query = buildMdnsQuery(MDNS_SERVICES);
      sock.send(query, MDNS_PORT, MDNS_ADDR, () => {});
    });
  });

  return mergeMdnsRecords(packets);
}
