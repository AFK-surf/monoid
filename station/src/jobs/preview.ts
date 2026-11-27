// A web service on this machine, reached through the admin API: GET
// /admin/api/preview/<port>/<path> is <path> of http://localhost:<port>, passed through as it is. It is how a client
// shows a page an agent serves here (a dev server, a report): its requests come over the mesh like any other admin
// call, so they need no port open to anyone. The HTTP wiring is the admin API's: this takes the request's parts and
// gives the answer's. A preview's WebSocket goes over a mesh `socket` stream, its messages framed (a kind byte, the
// payload's length in 4 bytes big-endian, the payload); the mesh layer opens the service's socket here and pumps.
import { request as httpRequest } from "node:http";
import { Readable } from "node:stream";
import WebSocket from "ws";
import { type Lang, tr } from "../ops/i18n.ts";
import { wall } from "../ops/fibers.ts";

/// The header a core names its person's language in.
const LANG_HEADER = "stillfail-lang";
/// Headers that belong to the hop to here (and the admin call's own), not to the service.
const HOP = ["connection", "keep-alive", "proxy-connection", "transfer-encoding", "upgrade", "te", "trailer", "host", "authorization", "traceparent", "tracestate", LANG_HEADER];
/// Answers the service gives that would stop its page from being shown framed on another origin.
const FRAMING = ["x-frame-options", "content-security-policy", "content-security-policy-report-only"];
/// An HTTP method as a token (what an HTTP client takes).
const TOKEN = /^[!#$%&'*+\-.^_`|~0-9A-Za-z]+$/;

/// What goes back to the client: the service's status, its headers (by lowercase name, repeats kept), and its body as
/// it comes.
export type PreviewAnswer = { status: number; headers: [string, string][]; body: Readable };

/// The port and path a /preview/<port>/<path> request is for.
export function previewTarget(path: string): [number, string] | null {
  if (!path.startsWith("/preview/")) return null;
  const rest = path.slice("/preview/".length);
  const at = rest.indexOf("/");
  const [port, target] = at >= 0 ? [rest.slice(0, at), rest.slice(at)] : [rest, "/"];
  if (port === "" || port.length > 5 || !/^[0-9]+$/.test(port)) return null;
  const n = Number(port);
  return n >= 1 && n <= 65535 ? [n, target] : null;
}

function plain(status: number, text: string): PreviewAnswer {
  return { status, headers: [["content-type", "text/plain; charset=utf-8"]], body: Readable.from([Buffer.from(text)]) };
}

/// Who a request comes from: a preview's page (through the admin API: its authorization is the admin call's, its answer
/// shown framed and read plain), or a program on another station of the workspace (mesh/peer-http.ts: its own
/// authorization and encodings go to the service, its answer comes back whole).
export type Asker = "preview" | "peer";

/// Passes a request to localhost:`port` and its answer back. `headers` are the request's, by lowercase name; `lang` is
/// what its refusals are said in. Redirects are not followed (they go back as they are), and no proxy is used.
export function proxyPreview(method: string, headers: [string, string][], body: Buffer | string | Readable | null, port: number, path: string, lang: Lang, asker: Asker = "preview"): Promise<PreviewAnswer> {
  if (!TOKEN.test(method)) return Promise.resolve(plain(400, tr(lang, "station.preview.badMethod", { method })));
  const peer = asker === "peer";
  const sent: Record<string, string | string[]> = {};
  for (const [name, value] of headers) {
    if (peer ? HOP.includes(name) && name !== "authorization" : HOP.includes(name) || name === "accept-encoding") continue;
    if (name.startsWith("x-stillfail-")) continue;
    const was = sent[name];
    sent[name] = was === undefined ? value : [...(Array.isArray(was) ? was : [was]), value];
  }
  sent.host = `localhost:${port}`;
  // The body goes back as it is: a client that cannot undo an encoding (a service worker's Response does not) gets it
  // plain. A peer's program asked for what it can undo.
  if (!peer) sent["accept-encoding"] = "identity";
  // A body that comes as it is sent, of no length said, goes in chunks (Node sends a GET's unframed otherwise).
  else if (body instanceof Readable && sent["content-length"] === undefined) sent["transfer-encoding"] = "chunked";
  const service = ["http", "https"].flatMap((s) => [`${s}://localhost:${port}`, `${s}://127.0.0.1:${port}`, `${s}://[::1]:${port}`]);
  return new Promise((resolve) => {
    let request;
    try {
      request = httpRequest({ host: "localhost", port, method, path, headers: sent, agent: false });
    } catch (error) {
      resolve(plain(502, tr(lang, "station.preview.noAnswerSaying", { port, error: (error as Error).message })));
      return;
    }
    request.on("error", (error) => resolve(plain(502, tr(lang, "station.preview.noAnswerSaying", { port, error: error.message }))));
    request.on("response", (answer) => {
      const out: [string, string][] = [];
      const raw = answer.rawHeaders;
      for (let i = 0; i + 1 < raw.length; i += 2) {
        const name = raw[i].toLowerCase();
        let value = raw[i + 1];
        if (HOP.includes(name) || (!peer && FRAMING.includes(name))) continue;
        // A redirect to the service itself stays on the preview's path.
        if (name === "location") {
          const origin = service.find((o) => value.startsWith(o) && /^(?:[/?#]|$)/.test(value.slice(o.length)));
          if (origin) {
            value = value.slice(origin.length);
            if (!value.startsWith("/")) value = `/${value}`;
          }
        }
        out.push([name, value]);
      }
      resolve({ status: answer.statusCode ?? 502, headers: out, body: answer });
    });
    if (body === null) request.end();
    else if (typeof body === "string" || Buffer.isBuffer(body)) request.end(body);
    else {
      // A body that fails on the way (its sender gone) ends the request, not leaves the service waiting for the rest.
      body.on("error", (error) => request.destroy(error));
      body.pipe(request);
    }
  });
}

// ── a service's WebSocket ────────────────────────────────────────────────────

/// A WebSocket message on a preview's socket stream, as the client core frames it (client/core-ts/src/station/sync.ts): a kind
/// byte, the payload's length (4 bytes, big-endian), then the payload.
export const FRAME_TEXT = 1;
export const FRAME_BINARY = 2;
/// Its payload: the close code (2 bytes, big-endian) and the reason, when there is one.
export const FRAME_CLOSE = 8;
/// A frame longer than this is not a client talking.
const MAX_FRAME = 16 * 1024 * 1024;
/// How long a service has to take a socket.
const OPEN_WITHIN_MS = 20_000;
/// How long the service has to answer a close the client sent.
const CLOSE_ANSWER_MS = 5000;

/// Request headers passed on to the service's socket: what a page's own WebSocket would send that the service may look
/// at (its sub-protocols, cookies, the browser it is).
const SOCKET_HEADERS = ["sec-websocket-protocol", "cookie", "user-agent"];

/// One frame.
export function frame(kind: number, payload: Uint8Array): Buffer {
  const out = Buffer.alloc(5 + payload.length);
  out[0] = kind;
  out.writeUInt32BE(payload.length, 1);
  out.set(payload, 5);
  return out;
}

/// The client's side of a socket stream, as the mesh gives it: chunks until null (its end).
export type ByteSource = { read(): Promise<Buffer | null> };
/// Where frames to the client go.
export type ByteSink = { write(bytes: Buffer): Promise<void>; finish(): Promise<void> };

/// Frames from a byte stream. `carry`: bytes already read past the stream's head.
export class FrameReader {
  private readonly source: ByteSource;
  private readonly header = Buffer.alloc(5);
  private headerBytes = 0;
  private bodyLen = 0;
  private bodyLeft = 0;
  private readonly bodyParts: Buffer[] = [];
  private tail: Buffer;
  private tailAt = 0;

  constructor(source: ByteSource, carry: Buffer = Buffer.alloc(0)) {
    this.source = source;
    this.tail = carry;
  }

  /// The next frame; null when the stream ended between frames (an end inside one is an error).
  async next(): Promise<[number, Buffer] | null> {
    for (;;) {
      if (this.tailAt < this.tail.length) {
        if (this.headerBytes < this.header.length) {
          const got = this.tail.copy(this.header, this.headerBytes, this.tailAt);
          this.headerBytes += got;
          this.tailAt += got;
          if (this.headerBytes < this.header.length) {
            this.tail = Buffer.alloc(0);
            this.tailAt = 0;
            continue;
          }
          this.bodyLen = this.header.readUInt32BE(1);
          if (this.bodyLen > MAX_FRAME) throw new Error("frame too long");
          this.bodyLeft = this.bodyLen;
        }
        let payload: Buffer | null = null;
        if (this.bodyLeft === 0) {
          payload = this.bodyParts.length > 0 ? Buffer.concat(this.bodyParts, this.bodyLen) : Buffer.alloc(0);
        } else {
          // Join multi-chunk frames once when the final piece arrives.
          const part = this.tail.subarray(this.tailAt, this.tailAt + this.bodyLeft);
          this.tailAt += part.length;
          this.bodyLeft -= part.length;
          if (this.bodyLeft === 0) {
            if (this.bodyParts.length > 0) {
              this.bodyParts.push(part);
              payload = Buffer.concat(this.bodyParts, this.bodyLen);
            } else {
              payload = part.length === this.tail.length ? part : Buffer.from(part);
            }
          } else if (part.length > 0) {
            this.bodyParts.push(part);
          }
        }
        if (this.tailAt >= this.tail.length) {
          this.tail = Buffer.alloc(0);
          this.tailAt = 0;
        }
        if (payload !== null) {
          this.bodyParts.length = 0;
          this.headerBytes = 0;
          return [this.header[0]!, payload];
        }
      }
      if (this.headerBytes === this.header.length && this.bodyLeft === 0) {
        this.bodyParts.length = 0;
        this.headerBytes = 0;
        return [this.header[0]!, Buffer.alloc(0)];
      }
      const more = await this.source.read();
      if (more === null) {
        if (this.headerBytes === 0) return null;
        throw new Error("the stream ended inside a frame");
      }
      if (more.length === 0) continue;
      this.tail = more;
      this.tailAt = 0;
    }
  }
}

type Message = { kind: "text" | "binary"; data: Buffer } | { kind: "close"; code: number; reason: Buffer };

/// A service's socket, open: what it says kept from the moment it opened (nothing is lost before the pump starts).
export class ServiceSocket {
  readonly ws: WebSocket;
  /// The sub-protocol the service chose.
  readonly protocol: string | null;
  private queue: Message[] = [];
  private waiting: ((m: Message) => void) | null = null;

  constructor(ws: WebSocket) {
    this.ws = ws;
    this.protocol = ws.protocol === "" ? null : ws.protocol;
    ws.on("message", (data: WebSocket.RawData, isBinary: boolean) => {
      const bytes = Array.isArray(data) ? Buffer.concat(data) : Buffer.from(data as ArrayBuffer);
      this.push({ kind: isBinary ? "binary" : "text", data: bytes });
    });
    ws.on("close", (code: number, reason: Buffer) => this.push({ kind: "close", code, reason }));
    ws.on("error", () => {});
  }

  private push(m: Message) {
    const waiting = this.waiting;
    if (waiting) {
      this.waiting = null;
      waiting(m);
    } else this.queue.push(m);
  }

  /// What it says next; its close last (1005 when it gave no code, 1006 when it went without a close).
  next(): Promise<Message> {
    const m = this.queue.shift();
    if (m) return Promise.resolve(m);
    return new Promise((resolve) => (this.waiting = resolve));
  }
}

/// Why a socket was not opened: the status to answer, and the words.
export class SocketRefused extends Error {
  readonly status: number;
  constructor(status: number, message: string) {
    super(message);
    this.status = status;
  }
}

/// Opens `path` of ws://localhost:`port` for a preview's page, with its headers (by lowercase name). Gives the socket
/// (with the sub-protocol the service chose), or throws a SocketRefused: the service's own refusal, 502 when it does
/// not answer.
export function openSocket(headers: [string, string][], port: number, path: string, lang: Lang, asker: Asker = "preview"): Promise<ServiceSocket> {
  return new Promise((resolve, reject) => {
    const passed: Record<string, string> = {};
    let protocols: string[] = [];
    for (const [name, value] of headers) {
      // A peer's program's own authorization goes too (a preview's is the admin call's).
      if (!SOCKET_HEADERS.includes(name) && !(asker === "peer" && name === "authorization")) continue;
      if (name === "sec-websocket-protocol") protocols = value.split(",").map((p) => p.trim()).filter((p) => p !== "");
      else passed[name] = value;
    }
    let ws: WebSocket;
    try {
      // As a page of the service itself would: a dev server turns away sockets from other origins.
      ws = new WebSocket(`ws://localhost:${port}${path}`, protocols, {
        headers: passed, origin: `http://localhost:${port}`, perMessageDeflate: false, followRedirects: false,
      });
    } catch (error) {
      reject(new SocketRefused(400, tr(lang, "station.preview.badAddress", { error: (error as Error).message })));
      return;
    }
    let settled = false;
    const fail = (refusal: SocketRefused) => {
      if (settled) return;
      settled = true;
      timer();
      ws.removeAllListeners();
      ws.on("error", () => {});
      ws.terminate();
      reject(refusal);
    };
    const timer = wall.after(OPEN_WITHIN_MS, () => fail(new SocketRefused(502, tr(lang, "station.preview.noAnswer", { port }))));
    ws.on("unexpected-response", (_req, answer) => {
      const status = answer.statusCode ?? 502;
      answer.resume();
      fail(new SocketRefused(status < 400 ? 502 : status, tr(lang, "station.preview.socketRefused", { port, status })));
    });
    ws.on("error", (error) => fail(new SocketRefused(502, tr(lang, "station.preview.noAnswerSaying", { port, error: error.message }))));
    ws.on("open", () => {
      if (settled) return;
      settled = true;
      timer();
      ws.removeAllListeners();
      resolve(new ServiceSocket(ws));
    });
  });
}

/// Passes messages between the service's socket and the client's stream until either closes; a close on one is passed
/// on to the other. The service's side ending ends both (the caller then resets the client's stream: a read it still
/// waits on is left). The client's ending (its close sent on, or its page gone) leaves the service a moment to answer
/// its close, which goes back as it would.
export async function pumpSocket(socket: ServiceSocket, fromClient: FrameReader, toClient: ByteSink): Promise<void> {
  const ws = socket.ws;
  let over = false;
  const sendClose = (code: number, reason: string) => {
    try {
      ws.close(code, reason);
    } catch {
      // A code a WebSocket may not send (1005, 1006): closed without one.
      try {
        ws.close();
      } catch {}
    }
  };
  const up = (async () => {
    for (;;) {
      let got: [number, Buffer] | null;
      try {
        got = await fromClient.next();
      } catch {
        got = null;
      }
      if (over) return;
      // The client went (its page, its tab): the service's socket goes too.
      if (got === null) return sendClose(1001, "");
      const [kind, payload] = got;
      if (kind === FRAME_CLOSE) {
        const code = payload.length >= 2 ? payload.readUInt16BE(0) : 1000;
        return sendClose(code, payload.length > 2 ? payload.subarray(2).toString("utf8") : "");
      }
      if (kind !== FRAME_TEXT && kind !== FRAME_BINARY) continue;
      if (ws.readyState !== WebSocket.OPEN) return;
      const sent = await new Promise<boolean>((resolve) => {
        if (kind === FRAME_TEXT) ws.send(payload.toString("utf8"), (e) => resolve(!e));
        else ws.send(payload, { binary: true }, (e) => resolve(!e));
      });
      if (!sent) return;
    }
  })();
  const down = (async () => {
    for (;;) {
      const m = await socket.next();
      let bytes: Buffer;
      if (m.kind !== "close") bytes = frame(m.kind === "text" ? FRAME_TEXT : FRAME_BINARY, m.data);
      else {
        const payload = Buffer.alloc(2 + m.reason.length);
        payload.writeUInt16BE(m.code, 0);
        m.reason.copy(payload, 2);
        try {
          await toClient.write(frame(FRAME_CLOSE, payload));
        } catch {}
        break;
      }
      try {
        await toClient.write(bytes);
      } catch {
        return;
      }
    }
    try {
      await toClient.finish();
    } catch {}
  })();
  const first = await Promise.race([up.then(() => "up" as const), down.then(() => "down" as const)]);
  if (first === "up") {
    await Promise.race([down, wall.sleep(CLOSE_ANSWER_MS)]);
  }
  over = true;
  if (ws.readyState !== WebSocket.CLOSED) ws.terminate();
}
