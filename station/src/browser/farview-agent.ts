// What the station itself asks of a chat's Farview tab on its agent port (127.0.0.1), as agent.exe does: a script's
// value, the cookies and the passkeys read, set or cleared, a step (a field typed, a click, a key) and what the page
// says after it.
// Farview's wire (its src/proto): a message is a 4-byte big-endian length and a body, the body a kind and its fields,
// each integer a zigzag varint, each string its UTF-8 length and bytes. Used for the sign-ins put into the tab and for
// filling its sign-in form, so nothing of them (a cookie, a passkey's key, a password) is ever on a command line.
import { connect } from "node:net";
import { wall } from "../ops/fibers.ts";

/// What the station asks.
export type AgentAsk =
  | { kind: "eval"; script: string }
  | { kind: "cookies"; verb: "get" | "set" | "clear"; arg: string }
  | { kind: "passkeys"; verb: "get" | "set" | "clear"; arg: string }
  | { kind: "act"; verb: "click" | "type" | "key" | "enter"; selector: string; text: string }
  | { kind: "look" };

/// What the tab answers: a value (a script's, as JSON; the cookies'), what the page says after a step, or that a person
/// took the tab back.
export type AgentAnswer = { kind: "value"; value: string } | { kind: "seen"; url: string; title: string; outline: string } | { kind: "taken" };

const KIND = { look: 19, seen: 20, taken: 21, act: 18, eval: 32, value: 33, cookies: 35, passkeys: 42 } as const;

function varint(out: number[], v: number) {
  let u = ((v << 1) ^ (v >> 31)) >>> 0;
  while (u >= 0x80) {
    out.push((u & 0x7f) | 0x80);
    u >>>= 7;
  }
  out.push(u);
}

function str(out: number[], s: string) {
  const b = Buffer.from(s, "utf8");
  varint(out, b.length);
  for (const x of b) out.push(x);
}

/// A message as the wire carries it, its length first.
export function encodeAsk(a: AgentAsk): Buffer {
  const body: number[] = [];
  switch (a.kind) {
    case "look":
      varint(body, KIND.look);
      break;
    case "eval":
      varint(body, KIND.eval);
      str(body, a.script);
      break;
    case "cookies":
    case "passkeys":
      varint(body, KIND[a.kind]);
      str(body, a.verb);
      str(body, a.arg);
      break;
    case "act":
      varint(body, KIND.act);
      str(body, a.verb);
      str(body, a.selector);
      str(body, a.text);
      break;
  }
  const head = Buffer.alloc(4);
  head.writeUInt32BE(body.length);
  return Buffer.concat([head, Buffer.from(body)]);
}

class Reader {
  i = 0;
  readonly b: Buffer;
  constructor(b: Buffer) {
    this.b = b;
  }
  int(): number {
    let shift = 0;
    let u = 0;
    for (;;) {
      if (this.i >= this.b.length) throw new RangeError("truncated varint");
      if (shift >= 35) throw new RangeError("varint overflow");
      const c = this.b[this.i++]!;
      if (shift === 28 && ((c & 0x80) !== 0 || (c & 0xf0) !== 0)) throw new RangeError("varint overflow");
      u |= (c & 0x7f) << shift;
      shift += 7;
      if (c < 0x80) break;
    }
    u >>>= 0;
    return (u >>> 1) ^ -(u & 1);
  }
  string(): string {
    const n = this.int();
    if (n < 0 || this.i + n > this.b.length) throw new RangeError("invalid string length");
    const s = this.b.subarray(this.i, this.i + n).toString("utf8");
    this.i += n;
    return s;
  }
}

/// A body read: an answer to the station, or null for what else the host sends (a frame, a notice).
export function decodeAnswer(body: Buffer): AgentAnswer | null {
  const r = new Reader(body);
  switch (r.int()) {
    case KIND.value:
      return { kind: "value", value: r.string() };
    case KIND.seen: {
      const url = r.string();
      const title = r.string();
      return { kind: "seen", url, title, outline: r.string() };
    }
    case KIND.taken:
      return { kind: "taken" };
    default:
      return null;
  }
}

/// How long an answer is waited for: the host waits on a script's promise up to 30 s of the page's time.
const ANSWER_MS = 45_000;
/// Maximum single frame size accepted from a Farview agent socket (32 MiB).
export const MAX_AGENT_FRAME = 32 * 1024 * 1024;
const MAX_AGENT_BUFFER = MAX_AGENT_FRAME + 4;

/// `ask` of the tab whose agent port is `port`, on a connection of its own: its first answer.
export function askTab(port: number, ask: AgentAsk): Promise<AgentAnswer> {
  return new Promise((resolve, reject) => {
    const s = connect({ host: "127.0.0.1", port });
    let buf: Buffer = Buffer.alloc(0);
    let done = false;
    let unwait = () => {};
    const end = (f: () => void) => {
      if (done) return;
      done = true;
      unwait();
      s.destroy();
      f();
    };
    // timer: a deadline for a process that may never answer.
    unwait = wall.after(ANSWER_MS, () => end(() => reject(new Error("Farview's tab did not answer"))));
    s.once("connect", () => s.write(encodeAsk(ask)));
    s.on("data", (chunk: Buffer) => {
      if (done) return;
      if (buf.length + chunk.length > MAX_AGENT_BUFFER) {
        return end(() => reject(new RangeError("Farview agent buffer limit exceeded")));
      }
      buf = buf.length === 0 ? chunk : Buffer.concat([buf, chunk]);
      while (buf.length >= 4) {
        const n = buf.readUInt32BE(0);
        if (n > MAX_AGENT_FRAME) {
          return end(() => reject(new RangeError(`Farview agent frame too large (${n} bytes)`)));
        }
        if (buf.length < 4 + n) break;
        let answer: AgentAnswer | null;
        try {
          answer = decodeAnswer(buf.subarray(4, 4 + n));
        } catch (e) {
          return end(() => reject(e));
        }
        buf = buf.subarray(4 + n);
        if (answer !== null) return end(() => resolve(answer));
      }
    });
    s.once("error", (e) => end(() => reject(e)));
    s.once("close", () => end(() => reject(new Error("Farview's tab closed the connection"))));
  });
}

/// A script's value in the tab (its JSON parsed; undefined where it is none).
export async function evalIn(port: number, script: string): Promise<any> {
  const a = await askTab(port, { kind: "eval", script });
  if (a.kind !== "value") throw new Error(a.kind === "taken" ? "the person took the tab back" : "no value");
  try {
    return JSON.parse(a.value);
  } catch {
    return undefined;
  }
}
