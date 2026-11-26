// Zero-port in-process HTTP control server for Android TV devices.
// Uses shared MemorySocket (zero listening TCP ports) and supports:
// - GET /status
// - POST /action
// - POST /screenshot (returns raw image/png + x-image-width / x-image-height headers)
import { createWriteStream } from "node:fs";
import { mkdir, unlink } from "node:fs/promises";
import { createServer, request as httpRequest, type IncomingMessage, type ServerResponse } from "node:http";
import { dirname } from "node:path";
import type { Duplex } from "node:stream";
import type { DeviceCredentialStore } from "../credentials.ts";
import { createSocketPair, type MemorySocket, readJsonBody, sendJson } from "../memory-socket.ts";
import {
  ANDROID_TV_CONTROL_ACTIONS,
  AndroidTvError,
  type AndroidTvAdapter,
  type AndroidTvControlAction,
  type AndroidTvCredentials,
  type AndroidTvProtocol,
} from "./types.ts";

const MAX_JSON_BYTES = 1024 * 1024;
const MAX_SCREENSHOT_BYTES = 32 * 1024 * 1024;

export type AndroidTvDeviceRef = {
  id: string;
  ws: string;
  target: string;
  name: string;
  protocols?: readonly AndroidTvProtocol[];
};

function statusForError(err: unknown): number {
  if (err instanceof AndroidTvError) {
    switch (err.code) {
      case "invalid_params":
      case "unknown_action":
        return 400;
      case "auth_failed":
      case "adb_unauthorized":
        return 401;
      case "device_not_found":
        return 404;
      case "payload_too_large":
        return 413;
      case "not_supported":
        return 422;
      case "adb_missing":
        return 503;
      default:
        return 502;
    }
  }
  return 500;
}

export class AndroidTvControlServer {
  readonly #adapter: AndroidTvAdapter;
  readonly #credentials: DeviceCredentialStore<Record<string, unknown>>;
  readonly #sockets = new Set<MemorySocket>();

  constructor(adapter: AndroidTvAdapter, credentials: DeviceCredentialStore<Record<string, unknown>>) {
    this.#adapter = adapter;
    this.#credentials = credentials;
  }

  get adapter(): AndroidTvAdapter {
    return this.#adapter;
  }

  async ensureAdbConnected(d: AndroidTvDeviceRef): Promise<{ serial: string }> {
    const creds = ((await this.#credentials.get(d.ws, d.id)) ?? undefined) as AndroidTvCredentials | undefined;
    return this.#adapter.ensureAdbConnected({ target: d.target, credentials: creds });
  }

  openRawAdbConnection(): Promise<import("node:net").Socket> {
    return this.#adapter.openRawAdbConnection();
  }

  /// Returns a paused, half-open Duplex stream speaking HTTP/1.1 to an in-process
  /// Android TV control server bound exclusively to device `d` (zero listening ports).
  open(d: AndroidTvDeviceRef): Duplex {
    const server = createServer((req, res) => {
      void this.#handle(d, req, res).catch((err: unknown) => {
        const code = err instanceof AndroidTvError ? err.code : "internal_error";
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

  async #handle(d: AndroidTvDeviceRef, req: IncomingMessage, res: ServerResponse): Promise<void> {
    const method = req.method ?? "GET";
    const path = (req.url ?? "/").split("?")[0]!;

    if (method === "GET" && path === "/status") {
      const credentials = ((await this.#credentials.get(d.ws, d.id)) ?? undefined) as AndroidTvCredentials | undefined;
      const result = await this.#adapter.control({
        target: d.target,
        ...(credentials ? { credentials } : {}),
        ...(d.protocols ? { protocols: d.protocols } : {}),
        action: "status",
      });
      sendJson(res, 200, { ok: true, result });
      return;
    }

    if (method === "POST" && path === "/action") {
      const body = await readJsonBody(req, {
        maxBytes: MAX_JSON_BYTES,
        onTooLarge: () => new AndroidTvError("payload_too_large", "request body exceeds 1 MB"),
        onInvalid: (msg) => new AndroidTvError("invalid_params", msg),
      });
      const action = typeof body.action === "string" ? body.action.trim() : "";
      if (action === "screenshot") {
        throw new AndroidTvError("invalid_params", "screenshot is not allowed on /action; call POST /screenshot");
      }
      if (!ANDROID_TV_CONTROL_ACTIONS.includes(action as AndroidTvControlAction)) {
        throw new AndroidTvError("unknown_action", `unsupported action: ${action}`);
      }
      const args = body.args !== undefined && body.args !== null && typeof body.args === "object" && !Array.isArray(body.args)
        ? (body.args as Record<string, unknown>)
        : undefined;
      const credentials = ((await this.#credentials.get(d.ws, d.id)) ?? undefined) as AndroidTvCredentials | undefined;
      const result = await this.#adapter.control({
        target: d.target,
        ...(credentials ? { credentials } : {}),
        ...(d.protocols ? { protocols: d.protocols } : {}),
        action: action as AndroidTvControlAction,
        ...(args ? { args } : {}),
      });
      sendJson(res, 200, { ok: true, result });
      return;
    }

    if (method === "POST" && path === "/screenshot") {
      const credentials = ((await this.#credentials.get(d.ws, d.id)) ?? undefined) as AndroidTvCredentials | undefined;
      const shot = await this.#adapter.screenshot({
        target: d.target,
        ...(credentials ? { credentials } : {}),
        ...(d.protocols ? { protocols: d.protocols } : {}),
      });
      res.writeHead(200, {
        "content-type": "image/png",
        "content-length": shot.png.length,
        "x-image-width": String(shot.width),
        "x-image-height": String(shot.height),
        connection: "close",
      });
      res.end(shot.png);
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
  const message = parsed?.error?.message ?? (raw.trim() || `Android TV request failed (HTTP ${status})`);
  throw new AndroidTvError(code, message);
}

/// Send a JSON action to a forwarded Android TV tunnel on 127.0.0.1:<port>.
export function sendAndroidTvAction(
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

/// Stream a PNG screenshot from a forwarded Android TV tunnel on 127.0.0.1:<port> directly to `destPath`.
export async function fetchAndroidTvScreenshot(
  port: number,
  destPath: string,
  signal?: AbortSignal,
): Promise<{ ok: true; path: string; bytes: number; width: number; height: number }> {
  await mkdir(dirname(destPath), { recursive: true });
  return new Promise((resolve, reject) => {
    const req = httpRequest(
      {
        host: "127.0.0.1",
        port,
        method: "POST",
        path: "/screenshot",
        headers: { "content-length": 0 },
        signal,
      },
      (res) => {
        const status = res.statusCode ?? 500;
        const ctype = String(res.headers["content-type"] ?? "");
        if (status < 200 || status >= 300 || !ctype.startsWith("image/png")) {
          const chunks: Buffer[] = [];
          res.on("data", (c: Buffer) => chunks.push(c));
          res.on("error", reject);
          res.on("end", () => {
            try {
              parseTunnelReply(status, Buffer.concat(chunks).toString("utf8"));
              reject(new AndroidTvError("invalid_screenshot", `unexpected response (HTTP ${status})`));
            } catch (err) {
              reject(err);
            }
          });
          return;
        }
        const width = Number(res.headers["x-image-width"] ?? 0);
        const height = Number(res.headers["x-image-height"] ?? 0);
        const out = createWriteStream(destPath, { mode: 0o600 });
        let bytes = 0;
        let failed = false;
        const fail = (err: Error) => {
          if (failed) return;
          failed = true;
          out.destroy();
          void unlink(destPath).catch(() => {});
          reject(err);
        };
        res.on("data", (chunk: Buffer) => {
          bytes += chunk.length;
          if (bytes > MAX_SCREENSHOT_BYTES) {
            fail(new AndroidTvError("payload_too_large", "screenshot exceeds 32 MB limit"));
            res.destroy();
            return;
          }
          if (!out.write(chunk)) {
            res.pause();
            out.once("drain", () => { if (!failed) res.resume(); });
          }
        });
        res.on("error", fail);
        out.on("error", fail);
        res.on("end", () => {
          if (!failed) out.end();
        });
        out.on("finish", () => {
          if (!failed) resolve({ ok: true, path: destPath, bytes, width, height });
        });
      },
    );
    req.on("error", reject);
    req.end();
  });
}
