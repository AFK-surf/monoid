// Zero-port in-process HTTP control server for AirPlay devices.
// Each `open(d)` returns a paused, half-open in-memory Duplex socket paired directly
// with an un-bound `http.Server` (`server.emit("connection", serverEnd)`), so it
// occupies zero TCP ports and works transparently over `Forwards` and `mesh/peer-http.ts`.
import { randomBytes } from "node:crypto";
import { createReadStream, createWriteStream } from "node:fs";
import { stat, unlink } from "node:fs/promises";
import { createServer, request as httpRequest, type IncomingMessage, type ServerResponse } from "node:http";
import { tmpdir } from "node:os";
import { basename, extname, join } from "node:path";
import { Duplex } from "node:stream";
import { createSocketPair, type MemorySocket, readJsonBody, sendJson } from "../memory-socket.ts";
import type { AirPlayCredentialStore } from "./credentials.ts";
import {
  AIRPLAY_CONTROL_ACTIONS,
  AirPlayError,
  type AirPlayAdapter,
  type AirPlayControlAction,
} from "./types.ts";

const MAX_JSON_BYTES = 1024 * 1024;
const MAX_AUDIO_BYTES = 100 * 1024 * 1024;
const SAFE_EXT = /^\.[a-z0-9]{1,8}$/;

export type AirPlayDeviceRef = {
  id: string;
  ws: string;
  target: string;
  name: string;
};

function statusForError(err: unknown): number {
  if (err instanceof AirPlayError) {
    switch (err.code) {
      case "invalid_params":
      case "unknown_action":
        return 400;
      case "auth_failed":
        return 401;
      case "device_not_found":
        return 404;
      case "payload_too_large":
        return 413;
      case "not_supported":
        return 422;
      default:
        return 502;
    }
  }
  return 500;
}

export class AirPlayControlServer {
  readonly #adapter: AirPlayAdapter;
  readonly #credentials: AirPlayCredentialStore;
  readonly #sockets = new Set<MemorySocket>();

  constructor(adapter: AirPlayAdapter, credentials: AirPlayCredentialStore) {
    this.#adapter = adapter;
    this.#credentials = credentials;
  }

  /// Returns a paused, half-open Duplex stream speaking HTTP/1.1 to an in-process
  /// control server bound exclusively to device `d` (zero listening ports).
  open(d: AirPlayDeviceRef): Duplex {
    const server = createServer((req, res) => {
      void this.#handle(d, req, res).catch((err: unknown) => {
        const code = err instanceof AirPlayError ? err.code : "internal_error";
        const message = err instanceof Error ? err.message : String(err);
        if (!res.headersSent) {
          sendJson(res, statusForError(err), { ok: false, error: { code, message } });
        } else {
          res.destroy();
        }
      });
    });

    const [client, serverEnd] = createSocketPair();
    this.#sockets.add(client);
    this.#sockets.add(serverEnd);
    client.once("close", () => {
      this.#sockets.delete(client);
      this.#sockets.delete(serverEnd);
      server.close();
    });
    client.on("error", () => {});
    serverEnd.on("error", () => {});
    client.pause();
    server.emit("connection", serverEnd);
    return client;
  }

  async #handle(d: AirPlayDeviceRef, req: IncomingMessage, res: ServerResponse): Promise<void> {
    const method = req.method ?? "GET";
    const path = (req.url ?? "/").split("?")[0]!;

    if (method === "GET" && path === "/status") {
      const credentials = (await this.#credentials.get(d.ws, d.id)) ?? undefined;
      const result = await this.#adapter.control({
        identifier: d.target,
        ...(credentials ? { credentials } : {}),
        action: "status",
      });
      sendJson(res, 200, { ok: true, result });
      return;
    }

    if (method === "POST" && path === "/action") {
      const body = await readJsonBody(req, {
        maxBytes: MAX_JSON_BYTES,
        onTooLarge: () => new AirPlayError("payload_too_large", "request body exceeds 1 MB"),
        onInvalid: (msg) => new AirPlayError("invalid_params", msg),
      });
      const action = typeof body.action === "string" ? body.action.trim() : "";
      if (action === "stream_audio") {
        throw new AirPlayError("invalid_params", "stream_audio is not allowed on /action; stream raw audio bytes to POST /stream-audio");
      }
      if (!AIRPLAY_CONTROL_ACTIONS.includes(action as AirPlayControlAction)) {
        throw new AirPlayError("unknown_action", `unsupported action: ${action}`);
      }
      const args = body.args !== undefined && body.args !== null && typeof body.args === "object" && !Array.isArray(body.args)
        ? (body.args as Record<string, unknown>)
        : undefined;
      const credentials = (await this.#credentials.get(d.ws, d.id)) ?? undefined;
      const result = await this.#adapter.control({
        identifier: d.target,
        ...(credentials ? { credentials } : {}),
        action: action as AirPlayControlAction,
        ...(args ? { args } : {}),
      });
      sendJson(res, 200, { ok: true, result });
      return;
    }

    if (method === "POST" && path === "/stream-audio") {
      const rawName = typeof req.headers["x-filename"] === "string" ? req.headers["x-filename"] : "";
      const ext = extname(rawName).toLowerCase();
      const safeExt = SAFE_EXT.test(ext) ? ext : ".audio";
      const tmpPath = join(tmpdir(), `stillfail-airplay-${randomBytes(8).toString("hex")}${safeExt}`);
      let result: unknown;
      try {
        await new Promise<void>((resolve, reject) => {
          const out = createWriteStream(tmpPath, { mode: 0o600 });
          let total = 0;
          let failed = false;
          const fail = (err: Error) => {
            if (failed) return;
            failed = true;
            out.destroy();
            reject(err);
          };
          req.on("data", (chunk: Buffer) => {
            total += chunk.length;
            if (total > MAX_AUDIO_BYTES) {
              fail(new AirPlayError("payload_too_large", "audio file exceeds 100 MB limit"));
              req.destroy();
              return;
            }
            if (!out.write(chunk)) {
              req.pause();
              out.once("drain", () => { if (!failed) req.resume(); });
            }
          });
          req.on("error", fail);
          out.on("error", fail);
          req.on("end", () => {
            if (!failed) out.end();
          });
          out.on("finish", () => {
            if (!failed) resolve();
          });
        });
        const credentials = (await this.#credentials.get(d.ws, d.id)) ?? undefined;
        result = await this.#adapter.control({
          identifier: d.target,
          ...(credentials ? { credentials } : {}),
          action: "stream_audio",
          args: { path: tmpPath },
        });
      } finally {
        await unlink(tmpPath).catch(() => {});
      }
      sendJson(res, 200, { ok: true, result });
      return;
    }

    sendJson(res, 404, { ok: false, error: { code: "not_found", message: `${method} ${path} not found` } });
  }

  close(): void {
    for (const s of [...this.#sockets]) s.destroy();
    this.#sockets.clear();
  }
}

function parseTunnelReply(status: number, raw: string): unknown {
  let parsed: { ok?: boolean; result?: unknown; error?: { code?: string; message?: string } } | null = null;
  try {
    parsed = JSON.parse(raw);
  } catch {
    // non-JSON reply
  }
  if (status >= 200 && status < 300 && parsed?.ok === true) {
    return parsed.result;
  }
  const code = parsed?.error?.code ?? `http_${status}`;
  const message = parsed?.error?.message ?? (raw.trim() || `AirPlay device request failed (HTTP ${status})`);
  throw new AirPlayError(code, message);
}

/// Send a JSON action to a forwarded AirPlay device tunnel on 127.0.0.1:<port>.
export function sendAirPlayAction(
  port: number,
  action: string,
  args?: Record<string, unknown>,
  signal?: AbortSignal,
): Promise<unknown> {
  const payload = JSON.stringify({ action, ...(args ? { args } : {}) });
  return new Promise((resolve, reject) => {
    const req = httpRequest(
      {
        host: "127.0.0.1",
        port,
        method: "POST",
        path: "/action",
        headers: {
          "content-type": "application/json",
          "content-length": Buffer.byteLength(payload),
        },
        signal,
      },
      (res) => {
        const chunks: Buffer[] = [];
        res.on("data", (c: Buffer) => chunks.push(c));
        res.on("error", reject);
        res.on("end", () => {
          try {
            resolve(parseTunnelReply(res.statusCode ?? 500, Buffer.concat(chunks).toString("utf8")));
          } catch (err) {
            reject(err);
          }
        });
      },
    );
    req.on("error", reject);
    req.end(payload);
  });
}

/// Stream a local audio file on this station to a forwarded AirPlay device tunnel on 127.0.0.1:<port>.
export async function sendAirPlayAudio(
  port: number,
  audioPath: string,
  signal?: AbortSignal,
): Promise<unknown> {
  const info = await stat(audioPath);
  if (!info.isFile()) throw new AirPlayError("invalid_params", `not a regular file: ${audioPath}`);
  if (info.size > MAX_AUDIO_BYTES) throw new AirPlayError("payload_too_large", "audio file exceeds 100 MB limit");
  return new Promise((resolve, reject) => {
    const req = httpRequest(
      {
        host: "127.0.0.1",
        port,
        method: "POST",
        path: "/stream-audio",
        headers: {
          "content-type": "application/octet-stream",
          "content-length": info.size,
          "x-filename": basename(audioPath),
        },
        signal,
      },
      (res) => {
        const chunks: Buffer[] = [];
        res.on("data", (c: Buffer) => chunks.push(c));
        res.on("error", reject);
        res.on("end", () => {
          try {
            resolve(parseTunnelReply(res.statusCode ?? 500, Buffer.concat(chunks).toString("utf8")));
          } catch (err) {
            reject(err);
          }
        });
      },
    );
    req.on("error", reject);
    const stream = createReadStream(audioPath);
    stream.on("error", (err) => {
      req.destroy(err);
      reject(err);
    });
    stream.pipe(req);
  });
}
