// CDP observes the worker's sockets. Payload byte counts exclude WS/TCP/TLS headers.
import assert from "node:assert/strict";
import { createWriteStream } from "node:fs";

type Socket = {
  id: string; url: string; host: string; created: number; opened: number | null; closed: number | null;
  identityCandidates: string[];
};
type Frame = { at: number; id: string; direction: "sent" | "received"; bytes: number };
export class RelayCapture {
  readonly sockets = new Map<string, Socket>();
  readonly frames: Frame[] = [];
  readonly requests: { at: number; host: string; path: string; method: string }[] = [];
  readonly workers = new Set<string>();
  readonly errors: string[] = [];
  readonly #cdp: any;
  readonly #raw: ReturnType<typeof createWriteStream>;
  readonly #pending = new Map<number, { resolve(value: any): void; reject(error: Error): void }>();
  #serial = 0;
  #closed = false;
  constructor(cdp: any, path: string) { this.#cdp = cdp; this.#raw = createWriteStream(path); }
  async start(): Promise<void> {
    this.#cdp.on("Target.receivedMessageFromTarget", ({ sessionId, message }: any) => {
      const data = JSON.parse(message);
      if (data.id) {
        const pending = this.#pending.get(data.id);
        this.#pending.delete(data.id);
        if (data.error) pending?.reject(Error(JSON.stringify(data.error)));
        else pending?.resolve(data.result);
      } else this.#event(sessionId, data.method, data.params);
    });
    this.#cdp.on("Target.targetCreated", ({ targetInfo }: any) => {
      if (targetInfo.type !== "worker") return;
      void this.#attach(targetInfo).catch(e => { this.errors.push(String(e)); });
    });
    await this.#cdp.send("Target.setDiscoverTargets", { discover: true });
  }
  async #attach(info: any): Promise<void> {
    const { sessionId } = await this.#cdp.send("Target.attachToTarget", { targetId: info.targetId, flatten: false });
    await this.#send(sessionId, "Network.enable", {});
    this.workers.add(sessionId);
    this.#raw.write(JSON.stringify({ kind: "worker", at: performance.now(), sessionId, target: info }) + "\n");
  }
  #send(sessionId: string, method: string, params: unknown): Promise<any> {
    const id = ++this.#serial;
    return new Promise((resolve, reject) => {
      this.#pending.set(id, { resolve, reject });
      void this.#cdp.send("Target.sendMessageToTarget", { sessionId, message: JSON.stringify({ id, method, params }) })
        .catch((e: Error) => { this.#pending.delete(id); reject(e); });
    });
  }
  #event(session: string, method: string, params: any): void {
    if (this.#closed) return;
    if (method === "Network.requestWillBeSent") {
      const url = new URL(params.request.url);
      if (url.protocol === "http:" || url.protocol === "https:") {
        const request = { at: performance.now(), host: url.host, path: url.pathname, method: params.request.method };
        this.requests.push(request);
        this.#raw.write(JSON.stringify({ kind: "http", session, ...request }) + "\n");
      }
      return;
    }
    if (!method.startsWith("Network.webSocket")) return;
    const at = performance.now();
    const id = `${session}:${params.requestId}`;
    if (method === "Network.webSocketCreated") {
      const url = new URL(params.url);
      this.sockets.set(id, { id, url: params.url, host: url.host, created: at, opened: null, closed: null, identityCandidates: [] });
    }
    const socket = this.sockets.get(id);
    if (!socket) { this.errors.push(`${method} before Created: ${id}`); return; }
    const out: Record<string, unknown> = { at, protocolTimestamp: params.timestamp ?? null, method, id, url: socket.url };
    if (method === "Network.webSocketHandshakeResponseReceived") {
      out.status = params.response.status;
      if (params.response.status === 101) socket.opened = at;
    }
    if (method === "Network.webSocketClosed") socket.closed = at;
    if (method === "Network.webSocketFrameError") out.error = params.errorMessage;
    if (method === "Network.webSocketFrameSent" || method === "Network.webSocketFrameReceived") {
      const frame = params.response;
      const payload = frame.opcode === 2 ? Buffer.from(frame.payloadData, "base64") : Buffer.from(frame.payloadData, "utf8");
      const direction = method === "Network.webSocketFrameSent" ? "sent" : "received";
      this.frames.push({ at, id, direction, bytes: payload.length });
      out.bytes = payload.length; out.opcode = frame.opcode;
      // ClientAuth tag 1 is followed by a serialized public key. Match both fixed
      // bytes and postcard's length-prefixed bytes against fixture endpoint IDs.
      if (direction === "sent" && frame.opcode === 2 && payload[0] === 1 && payload.length >= 97 && payload.length <= 100) {
        socket.identityCandidates = [payload.subarray(1, 33).toString("hex"), payload.subarray(2, 34).toString("hex")];
      }
    }
    this.#raw.write(JSON.stringify(out) + "\n");
  }
  summarize(start: number, end: number, identities: { kind: string; id: string; scope?: string }[], relayUrls: string[]) {
    assert.ok(end > start);
    const sockets = [...this.sockets.values()];
    const known = new Map(identities.map(identity => [identity.id, identity]));
    const describe = (socket: Socket) => {
      const identity = socket.identityCandidates.map(id => known.get(id)).find(Boolean);
      const lifetimeMs = socket.closed === null ? null : Math.round(socket.closed - socket.created);
      return { ...socket, kind: identity?.kind ?? (socket.identityCandidates.length ? "temporary-probe" : "unclassified"),
        identity: identity?.id ?? null, scope: identity?.scope ?? null, lifetimeMs,
        short: lifetimeMs !== null && lifetimeMs < 10_000,
        ageAtEndMs: Math.round((socket.closed ?? end) - socket.created) };
    };
    const described = sockets.map(describe);
    const durationSeconds = (end - start) / 1000;
    const group = (host: string | null) => {
      const selected = described.filter(s => host === null || s.host === host);
      const ids = new Set(selected.map(s => s.id));
      const frames = this.frames.filter(f => f.at >= start && f.at < end && ids.has(f.id));
      const opens = selected.filter(s => s.created >= start && s.created < end);
      const samples = Array.from({ length: Math.ceil(durationSeconds) }, (_, i) => {
        const at = start + i * 1000;
        return selected.filter(s => s.opened !== null && s.opened <= at && (s.closed === null || s.closed > at)).length;
      }).sort((a, b) => a - b);
      let active = 0, peak = 0;
      // Exclude connections whose interval does not intersect this window.
      const intersecting = new Set(selected.filter(s => s.opened !== null && s.opened < end && (s.closed === null || s.closed > start)).map(s => s.id));
      const changes = selected.filter(s => intersecting.has(s.id)).flatMap(s => [
        { at: Math.max(start, s.opened!), delta: 1 }, { at: Math.min(end, s.closed ?? end), delta: -1 },
      ]).sort((a, b) => a.at - b.at || a.delta - b.delta);
      for (const change of changes) { active += change.delta; peak = Math.max(peak, active); }
      const rate = (direction: Frame["direction"]) => {
        const rows = frames.filter(f => f.direction === direction);
        return { framesPerSecond: rows.length / durationSeconds, payloadBytesPerSecond: rows.reduce((n, f) => n + f.bytes, 0) / durationSeconds };
      };
      return { concurrent: { minimum: samples[0] ?? 0, median: samples[Math.floor(samples.length / 2)] ?? 0,
        p95: samples[Math.floor(samples.length * 0.95)] ?? 0, peak },
        createdPerMinute: opens.length * 60 / durationSeconds,
        establishedPerMinute: selected.filter(s => s.opened !== null && s.opened >= start && s.opened < end).length * 60 / durationSeconds,
        shortCreatedPerMinute: opens.filter(s => s.short).length * 60 / durationSeconds,
        unclassifiedCreated: opens.filter(s => s.kind === "unclassified").length,
        sent: rate("sent"), received: rate("received"),
        perSecond: Array.from({ length: Math.ceil(durationSeconds) }, (_, second) => {
          const rows = frames.filter(f => f.at >= start + second * 1000 && f.at < start + (second + 1) * 1000);
          return { second, sent: rows.filter(f => f.direction === "sent").length, received: rows.filter(f => f.direction === "received").length,
            sentBytes: rows.filter(f => f.direction === "sent").reduce((n, f) => n + f.bytes, 0),
            receivedBytes: rows.filter(f => f.direction === "received").reduce((n, f) => n + f.bytes, 0) };
        }),
      };
    };
    const hosts = new Set(relayUrls.map(url => new URL(url).host));
    const requests = this.requests.filter(r => hosts.has(r.host) && r.at >= start && r.at < end);
    const http = Object.fromEntries([...hosts].map(host => [host, Object.fromEntries(
      [...new Set(requests.filter(r => r.host === host).map(r => `${r.method} ${r.path}`))].map(path => {
        const count = requests.filter(r => r.host === host && `${r.method} ${r.path}` === path).length;
        return [path, { count, perMinute: count * 60 / durationSeconds }];
      }),
    )]));
    return { window: { start, end, durationSeconds }, http, httpRequests: requests, total: group(null),
      byHost: Object.fromEntries([...new Set(sockets.map(s => s.host))].map(host => [host, group(host)])),
      sockets: described, errors: this.errors, workerSessions: [...this.workers] };
  }
  async close(): Promise<void> {
    this.#closed = true;
    await this.#cdp.detach();
    await new Promise<void>(resolve => this.#raw.end(resolve));
  }
}
