// The events of a group space (`im/2`), byte for byte as the IM's own code makes them (AFK-surf/group
// core/src/im/canon.mbt and event.mbt): an event is said by one device and signed by its Ed25519 key (the connect's key,
// its iroh endpoint's), over the canonical JSON of its envelope; its id is the SHA-256 of that same text. The anchor
// stamps what it takes (`aseq`, its place in its space; `n` where it is a message; `at`, its time), none of it signed.
//
// Canonical JSON as canon.mbt writes it: no space; whole numbers as integers; a string's `"` `\` and newline, return
// and tab escaped as `\"` `\\` `\n` `\r` `\t`, every other character under 0x20 as `\u00xx` (lowercase hex), the rest
// as it is; an object's keys in MoonBit's order of strings, which is by length first (UTF-16 code units), then code
// unit by code unit (not JavaScript's sort: `"v"` comes before `"body"`, `"enc"` before `"author"`).
import { createHash, createPrivateKey, createPublicKey, sign, verify, type KeyObject } from "node:crypto";

type Json = any;

export const PROTOCOL_VERSION = 2;
export const LOBBY = "lobby";

/// The envelope of an event, signed (`sig`: its device's signature, 128 hex).
export type GroupEvent = {
  v: 2;
  space: string;
  author: string;
  device: string;
  dseq: number;
  hlc: [number, number];
  prev: string;
  topic: string;
  kind: string;
  enc: 0;
  body: Json;
  sig: string;
};

/// An event as the anchor took it.
export type Stamped = { id: string; event: GroupEvent; aseq: number; n: number; at: number };

/// MoonBit's order of strings (core's `String::compare`): the shorter first, then by UTF-16 code unit.
export function moonOrder(a: string, b: string): number {
  if (a.length !== b.length) return a.length - b.length;
  return a < b ? -1 : a > b ? 1 : 0;
}

const HEX = "0123456789abcdef";

function writeString(s: string): string {
  let out = '"';
  for (const c of s) {
    const v = c.codePointAt(0)!;
    if (c === '"') out += '\\"';
    else if (c === "\\") out += "\\\\";
    else if (c === "\n") out += "\\n";
    else if (c === "\r") out += "\\r";
    else if (c === "\t") out += "\\t";
    else if (v < 0x20) out += `\\u00${HEX[v >> 4]}${HEX[v & 15]}`;
    else out += c;
  }
  return `${out}"`;
}

/// `j` as canonical JSON (canon.mbt `canonical`).
export function canonicalJson(j: Json): string {
  if (j === null || j === undefined) return "null";
  if (j === true) return "true";
  if (j === false) return "false";
  if (typeof j === "number") {
    // (only whole numbers are in what is signed: sequences, times, sizes)
    if (Number.isInteger(j)) return Object.is(j, -0) ? "0" : String(j);
    return String(j);
  }
  if (typeof j === "string") return writeString(j);
  if (Array.isArray(j)) return `[${j.map(canonicalJson).join(",")}]`;
  if (typeof j === "object") {
    const keys = Object.keys(j).filter((k) => j[k] !== undefined).sort(moonOrder);
    return `{${keys.map((k) => `${writeString(k)}:${canonicalJson(j[k])}`).join(",")}}`;
  }
  return "null";
}

/// What is signed of an event, and what its id is the hash of (event.mbt `Event::unsigned`).
export function unsignedOf(e: Omit<GroupEvent, "sig"> | GroupEvent): Json {
  return { v: PROTOCOL_VERSION, space: e.space, author: e.author, device: e.device, dseq: e.dseq, hlc: [e.hlc[0], e.hlc[1]], prev: e.prev, topic: e.topic, kind: e.kind, enc: 0, body: e.body };
}

export const signedText = (e: Omit<GroupEvent, "sig"> | GroupEvent) => canonicalJson(unsignedOf(e));

export const sha256Hex = (text: string | Buffer) => createHash("sha256").update(text).digest("hex");

/// The event's id: SHA-256 of what is signed, hex.
export const eventId = (e: Omit<GroupEvent, "sig"> | GroupEvent) => sha256Hex(signedText(e));

const isHex = (s: unknown, n: number): s is string => typeof s === "string" && s.length === n && /^[0-9a-f]*$/.test(s);

/// A key (32 bytes, hex: the Ed25519 seed) to sign with.
export function signingKey(seedHex: string): KeyObject {
  return createPrivateKey({ key: Buffer.concat([Buffer.from("302e020100300506032b657004220420", "hex"), Buffer.from(seedHex, "hex")]), format: "der", type: "pkcs8" });
}

const publicOf = (device: string): KeyObject => createPublicKey({ key: Buffer.concat([Buffer.from("302a300506032b6570032100", "hex"), Buffer.from(device, "hex")]), format: "der", type: "spki" });

/// The device id (public key, 64 hex) of a signing key.
export const deviceOfKey = (key: KeyObject): string => createPublicKey(key).export({ format: "der", type: "spki" }).subarray(-32).toString("hex");

/// The event said by the key's device, signed (event.mbt `sign_event`).
export function signEvent(key: KeyObject, e: Omit<GroupEvent, "sig" | "v" | "enc">): GroupEvent {
  const unsigned = { ...e, v: 2 as const, enc: 0 as const };
  const sig = sign(null, Buffer.from(signedText(unsigned), "utf8"), key).toString("hex");
  return { ...unsigned, sig };
}

/// Whether the event is signed by the device it names.
export function verified(e: GroupEvent): boolean {
  if (!isHex(e.device, 64) || !isHex(e.sig, 128)) return false;
  try {
    return verify(null, Buffer.from(signedText(e), "utf8"), publicOf(e.device), Buffer.from(e.sig, "hex"));
  } catch {
    return false;
  }
}

/// An event read off the wire (event.mbt `Event::of_json`); null where it is none.
export function eventOf(j: Json): GroupEvent | null {
  if (j === null || typeof j !== "object" || Array.isArray(j)) return null;
  if (j.v !== PROTOCOL_VERSION || j.enc !== 0) return null;
  if (!Array.isArray(j.hlc) || j.hlc.length !== 2 || typeof j.hlc[0] !== "number" || typeof j.hlc[1] !== "number") return null;
  if (typeof j.dseq !== "number" || !Number.isInteger(j.dseq) || j.dseq < 1) return null;
  if (!("body" in j)) return null;
  for (const k of ["space", "author", "device", "prev", "topic", "kind", "sig"]) if (typeof j[k] !== "string") return null;
  return { v: 2, space: j.space, author: j.author, device: j.device, dseq: j.dseq, hlc: [j.hlc[0], j.hlc[1]], prev: j.prev, topic: j.topic, kind: j.kind, enc: 0, body: j.body, sig: j.sig };
}

/// A stamped event read off the wire: its id worked out again, never taken as said (null where it differs), and its
/// signature checked (null where it is not its device's).
export function stampedOf(j: Json): Stamped | null {
  const event = eventOf(j?.event);
  if (event === null) return null;
  const id = eventId(event);
  if (j?.id !== id || !verified(event)) return null;
  const int = (v: unknown) => (typeof v === "number" && Number.isFinite(v) ? Math.trunc(v) : 0);
  return { id, event, aseq: int(j.aseq), n: int(j.n), at: int(j.at) };
}

/// The id of the direct space of two members (event.mbt `direct_id`).
export function directId(a: string, b: string): string {
  const pair = moonOrder(a, b) < 0 ? `${a}|${b}` : `${b}|${a}`;
  return `d_${sha256Hex(`im/2 direct ${pair}`).slice(0, 24)}`;
}

export const isSpaceId = (id: string) => /^[ds]_[0-9a-f]{24}$/.test(id);
export const isTopicId = (id: string) => id === LOBBY || /^t_[0-9a-f]{16}$/.test(id);

/// A hybrid logical clock (event.mbt `Clock`): never behind the wall, never behind what was seen, after its last.
export class Hlc {
  ms = 0;
  n = 0;
  next(wall: number): [number, number] {
    if (wall > this.ms) {
      this.ms = wall;
      this.n = 0;
    } else this.n += 1;
    return [this.ms, this.n];
  }
  saw(ms: number, n: number) {
    if (ms > this.ms || (ms === this.ms && n > this.n)) {
      this.ms = ms;
      this.n = n;
    }
  }
}
