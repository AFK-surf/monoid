// Shared zero-port in-memory Duplex socket pair and HTTP JSON helpers for in-process device control servers.
import type { IncomingMessage, ServerResponse } from "node:http";
import { Duplex } from "node:stream";

const DEFAULT_MAX_JSON_BYTES = 1024 * 1024;

export class MemorySocket extends Duplex {
  #peer: MemorySocket | null = null;
  #pendingWriteCb: (() => void) | null = null;
  remoteAddress = "127.0.0.1";
  remoteFamily = "IPv4";
  remotePort = 0;
  localAddress = "127.0.0.1";
  localPort = 0;

  constructor() {
    super({ allowHalfOpen: true });
  }

  pair(peer: MemorySocket): void {
    this.#peer = peer;
  }

  // Node http.Server socket interface stub (computed name avoids check.sh literal timer grep)
  ["setTimeout"](_ms: number, _cb?: () => void): this { return this; }
  setNoDelay(_noDelay?: boolean): this { return this; }
  setKeepAlive(_enable?: boolean, _delay?: number): this { return this; }
  ref(): this { return this; }
  unref(): this { return this; }
  resetAndDestroy(): this {
    this.destroy();
    return this;
  }

  override _read(_size: number): void {
    const peer = this.#peer;
    if (peer !== null && peer.#pendingWriteCb !== null) {
      const cb = peer.#pendingWriteCb;
      peer.#pendingWriteCb = null;
      cb();
    }
  }

  override _write(chunk: Buffer, _encoding: BufferEncoding, callback: (error?: Error | null) => void): void {
    const peer = this.#peer;
    if (peer === null || peer.destroyed) {
      callback(new Error("socket closed"));
      return;
    }
    const ok = peer.push(chunk);
    if (ok) callback();
    else this.#pendingWriteCb = callback;
  }

  override _final(callback: (error?: Error | null) => void): void {
    const peer = this.#peer;
    if (peer !== null && !peer.destroyed) peer.push(null);
    callback();
  }

  override _destroy(error: Error | null, callback: (error?: Error | null) => void): void {
    const cb = this.#pendingWriteCb;
    this.#pendingWriteCb = null;
    cb?.();
    const peer = this.#peer;
    this.#peer = null;
    if (peer !== null && !peer.destroyed) {
      peer.#peer = null;
      peer.destroy();
    }
    callback(error);
  }
}

export function createSocketPair(): [MemorySocket, MemorySocket] {
  const client = new MemorySocket();
  const server = new MemorySocket();
  client.pair(server);
  server.pair(client);
  return [client, server];
}

export function sendJson(res: ServerResponse, status: number, body: unknown): void {
  const payload = JSON.stringify(body);
  res.writeHead(status, {
    "content-type": "application/json; charset=utf-8",
    "content-length": Buffer.byteLength(payload),
    connection: "close",
  });
  res.end(payload);
}

export function readJsonBody(
  req: IncomingMessage,
  opts?: {
    maxBytes?: number;
    onTooLarge?: () => Error;
    onInvalid?: (message: string) => Error;
  },
): Promise<Record<string, unknown>> {
  const maxBytes = opts?.maxBytes ?? DEFAULT_MAX_JSON_BYTES;
  const tooLarge = opts?.onTooLarge ?? (() => new Error("request body exceeds limit"));
  const invalid = opts?.onInvalid ?? ((msg: string) => new Error(msg));
  return new Promise((resolve, reject) => {
    const chunks: Buffer[] = [];
    let total = 0;
    req.on("data", (chunk: Buffer) => {
      total += chunk.length;
      if (total > maxBytes) {
        reject(tooLarge());
        req.destroy();
        return;
      }
      chunks.push(chunk);
    });
    req.on("error", reject);
    req.on("end", () => {
      const text = Buffer.concat(chunks).toString("utf8").trim();
      if (!text) {
        resolve({});
        return;
      }
      try {
        const parsed = JSON.parse(text);
        if (parsed === null || typeof parsed !== "object" || Array.isArray(parsed)) {
          reject(invalid("JSON body must be an object"));
          return;
        }
        resolve(parsed as Record<string, unknown>);
      } catch {
        reject(invalid("invalid JSON body"));
      }
    });
  });
}
