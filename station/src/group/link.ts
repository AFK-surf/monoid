// A group connect's link to its IM anchor (AFK-surf/group, protocol `im/2`): an iroh endpoint of the connect's own key,
// dialled to the server's endpoint through its relays, let in by its hello, then a request a stream. The framing is the
// mesh's (mesh/wire.ts, the door's: mesh/door.ts): the first stream is the control stream, one JSON line each way at a
// time (the hello `{credential, name}` and its answer, then a ping and its answer), every other stream one request, a
// JSON head line `{method, path, headers}` then its body, answered a head line `{status, headers}` then the body.
//
// The device is the connect's key, which the connection proves; its hello says a code only where the device joins by
// one (an invitation, a device code). What answers it is the server's (its `LetIn`, or `{error, code, why}`).
//
// The same endpoint takes the connections other members' devices dial it by to hand it a secret (`im-secret/1`: one
// stream, one JSON line each way), which the surface serves (`accepted`).
import type { Addr, Connection, Endpoint, Endpoints, Stream } from "../mesh/endpoint.ts";
import { Reader, writeLine } from "../mesh/wire.ts";

/// The IM's protocol (its anchor.mbt `alpn`).
export const ALPN = "im/2";
/// What a device dials another member's device by to hand it a secret, end to end.
export const SECRET_ALPN = "im-secret/1";

/// Who the server let this device in as (its protocol.ts `LetIn`).
export type LetIn = { member: string; name: string; owner: boolean; joined: boolean };

/// The server said no to the hello: a code it does not take, a device removed, one that is nobody's and said no code
/// (`why`: the server's word for it). Stands until the connect's code changes: never asked again by itself.
export class GroupRefused extends Error {
  readonly why: string;
  constructor(message: string, why: string) {
    super(message);
    this.why = why;
  }
}

/// The server was not reached, or the link went (asked again on the connect's backoff): unanswered.ts takes its code
/// as no answer at all.
export class GroupUnreached extends Error {
  readonly code = "EHOSTUNREACH";
}

export type Answered = { status: number; headers: Record<string, string>; body: Buffer };
/// An answer read as it comes (the event stream): its head, its body's pieces, and what lets go of it.
export type Streamed = { status: number; headers: Record<string, string>; chunks: AsyncIterable<Buffer>; cancel(): void };

export type LinkOptions = {
  endpoints: Endpoints;
  secretKey: Buffer;
  server: string;
  relays: string[];
  /// Where the server is besides its relays (a test's endpoint on 127.0.0.1); none in config.json.
  ips?: string[];
};

const headersOf = (v: unknown): Record<string, string> => {
  const out: Record<string, string> = {};
  if (v !== null && typeof v === "object") for (const [k, x] of Object.entries(v)) if (typeof x === "string") out[k.toLowerCase()] = x;
  return out;
};

export class GroupLink {
  readonly #o: LinkOptions;
  #endpoint: Promise<Endpoint> | null = null;
  #conn: Connection | null = null;
  #control: { stream: Stream; reader: Reader } | null = null;
  /// One line at a time on the control stream: a ping waits for the one before it.
  #turn: Promise<unknown> = Promise.resolve();
  #closed = false;

  constructor(options: LinkOptions) {
    this.#o = options;
  }

  /// This device's endpoint id (its key's public half).
  async device(): Promise<string> {
    return (await this.#bound()).id();
  }

  #bound(): Promise<Endpoint> {
    const bound = this.#endpoint ?? this.#o.endpoints.bind({ secretKey: this.#o.secretKey, alpns: [Buffer.from(SECRET_ALPN)], relayUrls: this.#o.relays, discovery: false });
    this.#endpoint = bound;
    return bound;
  }

  /// The connections dialled to this device (`im-secret/1`), as they come; null once its endpoint is closed.
  async accepted(): Promise<Connection | null> {
    if (this.#closed) return null;
    return (await this.#bound()).accept();
  }

  /// Whether a connection let in is up.
  open(): boolean {
    return this.#conn !== null && this.#control !== null && !this.#conn.isClosed();
  }

  /// A new connection to the server, let in by `hello` (the one before it closed first): who it let this device in as.
  async connect(hello: { credential: string; name?: string }): Promise<LetIn> {
    if (this.#closed) throw new GroupUnreached("the link is closed");
    this.drop("dialled again");
    const endpoint = await this.#bound();
    const addr: Addr = { id: this.#o.server, relays: this.#o.relays, ...(this.#o.ips && this.#o.ips.length > 0 ? { ips: this.#o.ips } : {}) };
    let conn: Connection;
    try {
      conn = await endpoint.connect(addr, Buffer.from(ALPN));
    } catch (e) {
      throw new GroupUnreached(`the server was not reached: ${(e as Error).message}`);
    }
    let answer: any;
    let stream: Stream;
    let reader: Reader;
    try {
      stream = await conn.openBi();
      reader = new Reader(stream);
      await writeLine(stream, hello);
      answer = await reader.line();
    } catch (e) {
      conn.close(0, "no hello");
      throw new GroupUnreached(`the server did not answer the hello: ${(e as Error).message}`);
    }
    if (answer === null || answer?.ok !== true) {
      conn.close(0, "refused");
      if (answer === null) throw new GroupUnreached("the server did not answer the hello");
      const why = typeof answer?.why === "string" ? answer.why : typeof answer?.code === "string" ? answer.code : "refused";
      throw new GroupRefused(typeof answer?.error === "string" ? answer.error : why, why);
    }
    if (this.#closed) {
      conn.close(0, "closed");
      throw new GroupUnreached("the link is closed");
    }
    this.#conn = conn;
    this.#control = { stream, reader };
    this.#turn = Promise.resolve();
    return { member: String(answer.member ?? ""), name: String(answer.name ?? ""), owner: answer.owner === true, joined: answer.joined === true };
  }

  /// The control stream said a line again and was answered (the server asks again who the device is): the link is
  /// alive. Fails where it is not, or the device is no member's any more.
  ping(): Promise<void> {
    const control = this.#control;
    if (control === null) return Promise.reject(new GroupUnreached("not connected"));
    const turn = this.#turn.then(async () => {
      await writeLine(control.stream, { credential: "" });
      const line = await control.reader.line();
      if (line === null) throw new GroupUnreached("the link went");
      if (line?.ok !== true && typeof line?.error === "string") throw new GroupRefused(line.error, typeof line?.why === "string" ? line.why : "refused");
    });
    this.#turn = turn.catch(() => {});
    return turn;
  }

  async #opened(method: string, path: string, body: Buffer | null, headers: Record<string, string>): Promise<{ stream: Stream; reader: Reader; head: any }> {
    const conn = this.#conn;
    if (conn === null || conn.isClosed()) throw new GroupUnreached("not connected");
    let stream: Stream;
    try {
      stream = await conn.openBi();
      await writeLine(stream, { method, path, headers });
      if (body !== null && body.length > 0) await stream.write(body);
      await stream.finish();
    } catch (e) {
      throw new GroupUnreached(`the request did not go: ${(e as Error).message}`);
    }
    const reader = new Reader(stream);
    const head = await reader.line().catch((e) => {
      throw new GroupUnreached(`the request was not answered: ${(e as Error).message}`);
    });
    if (head === null || typeof head?.status !== "number") throw new GroupUnreached("the request was not answered");
    return { stream, reader, head };
  }

  /// One request, its answer read whole. `body`: JSON (an object) or bytes as they are.
  async ask(method: string, path: string, body?: unknown): Promise<Answered> {
    const bytes = body === undefined ? null : Buffer.isBuffer(body) ? body : Buffer.from(JSON.stringify(body));
    const { reader, head } = await this.#opened(method, path, bytes, Buffer.isBuffer(body) ? { "content-type": "application/octet-stream" } : body === undefined ? {} : { "content-type": "application/json" });
    const rest = await reader.rest().catch((e) => {
      throw new GroupUnreached(`the answer was cut: ${(e as Error).message}`);
    });
    return { status: head.status, headers: headersOf(head.headers), body: rest };
  }

  /// One request whose answer is read as it comes (GET /events).
  async stream(method: string, path: string): Promise<Streamed> {
    const { stream, reader, head } = await this.#opened(method, path, null, {});
    let cancelled = false;
    return {
      status: head.status,
      headers: headersOf(head.headers),
      chunks: (async function* () {
        try {
          for await (const chunk of reader.chunks()) {
            if (cancelled) return;
            yield chunk;
          }
        } catch {
          // (cut: the link went, or it was let go)
        }
      })(),
      cancel: () => {
        if (cancelled) return;
        cancelled = true;
        void stream.reset(0).catch(() => {});
      },
    };
  }

  /// The connection let go (the endpoint kept for the next).
  drop(reason: string) {
    const conn = this.#conn;
    this.#conn = null;
    this.#control = null;
    if (conn !== null && !conn.isClosed()) conn.close(0, reason);
  }

  async close() {
    this.#closed = true;
    this.drop("connect stopped");
    const endpoint = this.#endpoint;
    this.#endpoint = null;
    if (endpoint !== null) await (await endpoint.catch(() => null))?.close().catch(() => {});
  }
}

/// The events of a stream's text (text/event-stream, as monoid's event log writes them): each `[event, data, id]`, an
/// id alone as `["", "", id]`.
export class SseLines {
  #carry = "";
  readonly #decoder = new TextDecoder();

  feed(chunk: Buffer): [string, string, string | null][] {
    this.#carry += this.#decoder.decode(chunk, { stream: true });
    const out: [string, string, string | null][] = [];
    for (;;) {
      const end = this.#carry.indexOf("\n\n");
      if (end < 0) break;
      const block = this.#carry.slice(0, end);
      this.#carry = this.#carry.slice(end + 2);
      let event = "";
      const data: string[] = [];
      let id: string | null = null;
      for (const line of block.split("\n")) {
        if (line.startsWith(":")) continue;
        const at = line.indexOf(":");
        const [field, value] = at < 0 ? [line, ""] : [line.slice(0, at), line.slice(at + 1).replace(/^ /, "")];
        if (field === "event") event = value;
        else if (field === "data") data.push(value);
        else if (field === "id") id = value;
      }
      if (event === "" && data.length > 0) event = "message";
      if (event !== "" || id !== null) out.push([event, data.join("\n"), id]);
    }
    return out;
  }
}
