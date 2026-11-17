// Regional entries carry TCP only: the URL, HTTP Host, SNI and certificate identity stay the cloud's.
// The dial owns every candidate until one verified TLS socket is handed to HTTP or WebSocket. It never retries bytes.
import { connect, type TLSSocket } from "node:tls";
import type { Duplex } from "node:stream";
import type { Clock } from "effect";
import { Agent, buildConnector, fetch as undiciFetch } from "undici";
import type WebSocket from "ws";
import { Fibers } from "../ops/fibers.ts";

export type CloudEntry = { origin: string; host: string; port: number };
export const CLOUD_ORIGIN = "https://app.still.fail";
export type CloudFetch = (url: string, init?: RequestInit) => Promise<Response>;
type Socket = Pick<Duplex, "once" | "destroy" | "removeListener">;
export type DialIO = {
  after: (ms: number, f: () => void) => () => void;
  tls: (host: string, port: number, servername: string) => Socket;
};

export function cloudEntry(raw: any): CloudEntry | null {
  const e = raw?.cloudEntry;
  if (e === undefined) return null;
  if (e?.origin !== CLOUD_ORIGIN || typeof e.host !== "string" || !e.host || !Number.isInteger(e.port) || e.port < 1 || e.port > 65535) {
    throw new Error("cloudEntry needs origin https://app.still.fail, a host and a TCP port (1–65535); correct config.json");
  }
  return { origin: e.origin, host: e.host, port: e.port };
}

/// One direct attempt and at most one delayed entry, sharing one budget. The cancellation owns only pending sockets.
export function dialCloud(io: DialIO, origin: string, entry: CloudEntry | null, budget: number, done: (error: Error | null, socket?: Socket) => void): () => void {
  const target = new URL(origin);
  const sockets = new Set<Socket>();
  const failures: Error[] = [];
  let finished = false;
  let edgeStarted = false;
  let stopHedge = () => {};
  let stopDeadline = () => {};
  const finish = (error: Error | null, winner?: Socket) => {
    if (finished) { winner?.destroy(); return; }
    finished = true;
    stopHedge();
    stopDeadline();
    for (const s of sockets) if (s !== winner) s.destroy();
    sockets.clear();
    done(error, winner);
  };
  const start = (host: string, port: number) => {
    if (finished) return;
    let socket: Socket;
    const failed = (error: Error) => {
      if (finished) return;
      if (socket) { sockets.delete(socket); socket.destroy(); }
      failures.push(error);
      if (entry && !edgeStarted) startEdge();
      else if (sockets.size === 0) finish(new AggregateError(failures, "cloud TLS connections failed"));
    };
    try {
      socket = io.tls(host, port, target.hostname);
      sockets.add(socket);
      socket.once("error", failed);
      socket.once("secureConnect", () => {
        // Leave an error consumer until the protocol owner takes the socket; late errors must never escape.
        finish(null, socket);
      });
    } catch (e) { failed(e as Error); }
  };
  const startEdge = () => {
    if (finished || edgeStarted || !entry) return;
    edgeStarted = true;
    stopHedge();
    start(entry.host, entry.port);
  };
  // timer: the delayed connection hedge and deadline, both in the transport owner's scope and clock.
  stopDeadline = io.after(budget, () => finish(new Error("cloud TLS connection timed out; check the network or regional entry")));
  if (entry) stopHedge = io.after(1000, startEdge);
  start(target.hostname, Number(target.port || 443));
  return () => { if (!finished) finish(new Error("cloud connection cancelled")); };
}

export const cloudTLS = (host: string, port: number, servername: string): TLSSocket =>
  connect({ host, port, servername, rejectUnauthorized: true, ALPNProtocols: ["http/1.1"] });

export class CloudTransport {
  readonly #fibers: Fibers;
  readonly #entry: () => CloudEntry | null;
  readonly #pending = new Set<() => void>();
  readonly #agent: Agent;
  #closed = false;
  constructor(entry: () => CloudEntry | null, clock?: Clock.Clock, io?: DialIO) {
    this.#entry = entry;
    this.#fibers = new Fibers("cloud transport", clock);
    const dialIO: DialIO = io ?? {
      after: (ms, f) => this.#fibers.after(ms, f),
      tls: cloudTLS,
    };
    this.io = dialIO;
    const direct = buildConnector({ timeout: 10_000 });
    this.#agent = new Agent({ connect: (options, callback) => {
      if (this.#closed) { callback(new Error("cloud transport closed"), null); return; }
      if (options.protocol !== "https:" || new URL(`https://${options.host ?? options.hostname}`).origin !== CLOUD_ORIGIN) return direct(options, callback);
      this.dial(10_000, (error, socket) => error ? callback(error, null) : callback(null, socket! as TLSSocket));
    } });
  }
  private readonly io: DialIO;
  dial(budget: number, done: (error: Error | null, socket?: Socket) => void): () => void {
    if (this.#closed) { done(new Error("cloud transport closed")); return () => {}; }
    let cancel = () => {};
    const held = () => cancel();
    this.#pending.add(held);
    try {
      cancel = dialCloud(this.io, CLOUD_ORIGIN, this.#entry(), budget, (error, socket) => {
        this.#pending.delete(held);
        done(error, socket);
      });
    } catch (error) {
      this.#pending.delete(held);
      done(error as Error);
    }
    return held;
  }
  eligible(url: string, provider = "stillfail"): boolean {
    return provider === "stillfail" && new URL(url).origin === CLOUD_ORIGIN && this.#entry() !== null;
  }
  fetch: CloudFetch = async (url, init) => {
    if (this.#closed) throw new Error("cloud transport closed");
    if (!this.eligible(url)) return fetch(url, init);
    // The request's signal belongs to Undici, never to the shared connector.
    return await undiciFetch(url, { ...init, dispatcher: this.#agent } as Parameters<typeof undiciFetch>[1]) as unknown as Response;
  };
  /// Each WebSocket gets its own dial and an encompassing TLS + Upgrade deadline.
  websocket(url: string, headers: Record<string, string>, WebSocketType: typeof WebSocket): WebSocket {
    let cancelDial = () => {};
    const socket = new WebSocketType(url, { headers, createConnection: ((_options: unknown, callback: (error: Error | null, socket?: TLSSocket) => void) => {
      cancelDial = this.dial(20_000, (error, connected) => callback!(error, connected as TLSSocket));
      return undefined as unknown as TLSSocket;
    }) as unknown as WebSocket.ClientOptions["createConnection"] });
    // timer: a deadline for this exclusive TLS + HTTP Upgrade handshake.
    const stop = this.io.after(20_000, () => { cancelDial(); socket.terminate(); });
    socket.once("open", stop);
    socket.once("close", () => { stop(); cancelDial(); });
    socket.once("error", () => { stop(); cancelDial(); });
    const terminate = socket.terminate.bind(socket);
    socket.terminate = () => { cancelDial(); stop(); terminate(); };
    return socket;
  }
  async close(): Promise<void> {
    if (this.#closed) return;
    this.#closed = true;
    for (const cancel of [...this.#pending]) cancel();
    await this.#agent.destroy();
    await this.#fibers.close();
  }
}
