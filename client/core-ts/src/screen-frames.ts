// A screen view's frames on its stream (Wire): a kind byte, the payload's length (4 bytes,
// big-endian), the payload. The station sends `config`, `video` and `state` (and `cursor`, the pointer in a few bytes,
// to a view that asked `binaryCursor`; `cursorImage`, the picture of a pointer of an app's own, before the first that
// names it "custom:<id>", to one that asked `customCursor`); the client `input`, `ack`, `keyframe` and
// `look` (the part of the screen it shows, zoomed in); the screen's clipboard goes both ways (`clipboard`) while the
// view drives it, a copy an app marked private (a password manager's) as `privateClipboard`, its mark first, to a view
// that asked `privateClip`.
// Read as the stream's pieces come, however they are cut: each frame's bytes are copied once, into an array of its own
// (what goes to the UI, transferred on the web).
import { fromBase64, fromUtf8, isObject, utf8 } from "./util.ts";

export const CONFIG = 1;
export const VIDEO = 2;
export const STATE = 3;
export const CLIPBOARD = 4;
export const AUDIO_CONFIG = 5;
export const AUDIO = 6;
export const CURSOR = 7;
export const CURSOR_IMAGE = 8;
export const PRIVATE_CLIPBOARD = 9;
export const INPUT = 16;
export const ACK = 17;
export const KEYFRAME = 18;
export const SET_CLIPBOARD = 19;
export const LOOK = 20;
export const SOUND = 21;
/// A packet of sound: 20 ms of PCM16 (3840 bytes), or one Opus packet (at most 1275).
const AUDIO_MAX = 3840;
/// A `cursor` frame: x and y (16 bits each, of 65535), then the pointer's shape (UTF-8, at most this many bytes).
const CURSOR_SHAPE_MAX = 64;
/// A `cursorImage` frame: width and height (points, 1..128), the hot spot (0..width, 0..height), 1 byte each; the id's 16
/// lowercase hex digits; then a PNG of at most this many bytes.
const CURSOR_PNG_MAX = 65536;
const PNG_SIGNATURE = [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a];

/// A clip's type on the wire.
export type ClipType = "text" | "png";
const CLIP_BYTE: Record<ClipType, number> = { text: 1, png: 2 };
const CLIP_OF_BYTE: Record<number, ClipType> = { 1: "text", 2: "png" };
/// What the app that copied a clip marked it (station/src/screens/source.ts `ClipPrivacy`), and its code on the wire.
export type ClipPrivacy = "concealed" | "transient" | "auto";
const PRIVACY_CODE: Record<ClipPrivacy, number> = { concealed: 1, transient: 2, auto: 3 };
const PRIVACY_OF_CODE: Record<number, ClipPrivacy> = { 1: "concealed", 2: "transient", 3: "auto" };
export function privacyOf(v: unknown): ClipPrivacy | null {
  return v === "concealed" || v === "transient" || v === "auto" ? v : null;
}
/// The most a clipboard carries each way (station/src/screens/source.ts): text's UTF-8 bytes, a picture's.
export const CLIP_TEXT_MAX = 1024 * 1024;
export const CLIP_PNG_MAX = 8 * 1024 * 1024;

/// A frame longer than this is no frame: the stream is out of step (or not a view's).
export const MAX_FRAME = 64 * 1024 * 1024;

// deno-lint-ignore no-explicit-any
type J = any;

/// A part of the screen, 0..1 of its width and height.
export type Region = { x: number; y: number; w: number; h: number };

/// `region`: the part of the screen the frames after it show (null: the whole).
export type FrameConfig = { codec: string; width: number; height: number; description: Uint8Array | null; region: Region | null };

/// What the station sends, read.
export type StationFrame =
  | { config: FrameConfig }
  | { video: { key: boolean; ts: number; data: Uint8Array } }
  | { state: J }
  | { audioConfig: { codec: "pcm_s16le" | "opus"; sampleRate: 48000; channels: 2 } }
  | { audio: { ts: number; data: Uint8Array } }
  /// The screen's clipboard, changed: its type and its bytes (text in UTF-8).
  | { clipboard: { type: ClipType; data: Uint8Array; privacy?: ClipPrivacy } }
  /// The pointer moved (0..1 of the screen, to a ten-thousandth, and its shape where said), or none shown (null).
  | { cursor: { x: number; y: number; shape?: string } | null }
  /// The picture of a pointer of an app's own, by the shape that names it ("custom:<id>"): its size and hot spot in
  /// points, and its PNG.
  | { cursorImage: { shape: string; w: number; h: number; hx: number; hy: number; data: Uint8Array } }
  /// A kind this client does not know (a later station's): passed over.
  | { other: number };

const TWO_32 = 2 ** 32;

/// The frames of a stream, read as its pieces come.
export class FrameReader {
  readonly #chunks: Uint8Array[] = [];
  /// Where the first piece's unread bytes start.
  #at = 0;
  #have = 0;

  push(chunk: Uint8Array): void {
    if (chunk.length === 0) return;
    this.#chunks.push(chunk);
    this.#have += chunk.length;
  }

  /// The next whole frame, or null until more has come. Throws when the stream is not a view's frames.
  next(): StationFrame | null {
    if (this.#have < 5) return null;
    const kind = this.#peek(0);
    const length = ((this.#peek(1) << 24) | (this.#peek(2) << 16) | (this.#peek(3) << 8) | this.#peek(4)) >>> 0;
    if (length > MAX_FRAME) throw new Error(`a frame of ${length} bytes`);
    if (this.#have < 5 + length) return null;
    this.#skip(5);
    switch (kind) {
      case VIDEO: {
        if (length < 9) {
          this.#skip(length);
          throw new Error("a video frame without its head");
        }
        const head = this.#take(9);
        const view = new DataView(head.buffer);
        const ts = view.getUint32(1) * TWO_32 + view.getUint32(5);
        return { video: { key: (head[0]! & 1) === 1, ts, data: this.#take(length - 9) } };
      }
      case CONFIG: {
        const c = json(this.#take(length));
        if (!isObject(c) || typeof c.codec !== "string") throw new Error("a config that says no codec");
        const description = typeof c.description === "string" && c.description !== "" ? fromBase64(c.description) : null;
        return { config: { codec: c.codec, width: whole(c.width), height: whole(c.height), description, region: regionOf(c.region) } };
      }
      case AUDIO_CONFIG: {
        const c = json(this.#take(length));
        if (!isObject(c) || (c.codec !== "pcm_s16le" && c.codec !== "opus") || c.sampleRate !== 48000 || c.channels !== 2) throw new Error("unsupported screen audio format");
        return { audioConfig: { codec: c.codec, sampleRate: 48000, channels: 2 } };
      }
      case AUDIO: {
        if (length <= 8 || length > 8 + AUDIO_MAX) { this.#skip(length); throw new Error("invalid screen audio packet"); }
        const head = this.#take(8);
        const view = new DataView(head.buffer);
        return { audio: { ts: view.getUint32(0) * TWO_32 + view.getUint32(4), data: this.#take(length - 8) } };
      }
      case STATE:
        return { state: json(this.#take(length)) };
      case CURSOR: {
        if (length === 0) return { cursor: null };
        // (a length no station sends: passed over, as a kind not known)
        if (length < 4 || length > 4 + CURSOR_SHAPE_MAX) {
          this.#skip(length);
          return { other: kind };
        }
        const b = this.#take(length);
        const at = (hi: number) => Math.round((((b[hi]! << 8) | b[hi + 1]!) / 65535) * 10000) / 10000;
        return { cursor: { x: at(0), y: at(2), ...(length > 4 ? { shape: fromUtf8(b.subarray(4)) } : {}) } };
      }
      case CURSOR_IMAGE: {
        // (one not well made: passed over, as a kind not known)
        if (length < 20 + PNG_SIGNATURE.length || length > 20 + CURSOR_PNG_MAX) {
          this.#skip(length);
          return { other: kind };
        }
        const b = this.#take(length);
        const [w, h, hx, hy] = [b[0]!, b[1]!, b[2]!, b[3]!];
        let id = "";
        for (let i = 4; i < 20; i++) id += String.fromCharCode(b[i]!);
        if (w < 1 || w > 128 || h < 1 || h > 128 || hx > w || hy > h || !/^[0-9a-f]{16}$/.test(id) || PNG_SIGNATURE.some((s, i) => b[20 + i] !== s)) return { other: kind };
        return { cursorImage: { shape: `custom:${id}`, w, h, hx, hy, data: b.subarray(20) } };
      }
      case CLIPBOARD: {
        const type = length > 0 ? CLIP_OF_BYTE[this.#peek(0)] : undefined;
        if (type === undefined) {
          this.#skip(length);
          return { other: kind };
        }
        this.#skip(1);
        return { clipboard: { type, data: this.#take(length - 1) } };
      }
      case PRIVATE_CLIPBOARD: {
        const privacy = length > 1 ? PRIVACY_OF_CODE[this.#peek(0)] : undefined;
        const type = length > 1 ? CLIP_OF_BYTE[this.#peek(1)] : undefined;
        if (privacy === undefined || type === undefined) {
          this.#skip(length);
          return { other: kind };
        }
        this.#skip(2);
        return { clipboard: { type, data: this.#take(length - 2), privacy } };
      }
      default:
        this.#skip(length);
        return { other: kind };
    }
  }

  #peek(i: number): number {
    let at = this.#at + i;
    for (const chunk of this.#chunks) {
      if (at < chunk.length) return chunk[at]!;
      at -= chunk.length;
    }
    return 0;
  }

  /// The next `n` bytes, in an array of their own.
  #take(n: number): Uint8Array {
    const out = new Uint8Array(n);
    let filled = 0;
    while (filled < n) {
      const chunk = this.#chunks[0]!;
      const count = Math.min(n - filled, chunk.length - this.#at);
      out.set(chunk.subarray(this.#at, this.#at + count), filled);
      filled += count;
      this.#advance(count);
    }
    return out;
  }

  #skip(n: number): void {
    let left = n;
    while (left > 0) {
      const chunk = this.#chunks[0]!;
      const count = Math.min(left, chunk.length - this.#at);
      left -= count;
      this.#advance(count);
    }
  }

  #advance(count: number): void {
    this.#at += count;
    this.#have -= count;
    if (this.#at === this.#chunks[0]!.length) {
      this.#chunks.shift();
      this.#at = 0;
    }
  }
}

function json(bytes: Uint8Array): J {
  return JSON.parse(fromUtf8(bytes));
}

/// A part of the screen as a station says it: within the screen, more than nothing each way; null when it is not one.
export function regionOf(v: unknown): Region | null {
  if (!isObject(v)) return null;
  const n = (k: string) => (typeof v[k] === "number" && Number.isFinite(v[k]) ? (v[k] as number) : NaN);
  const [x, y, w, h] = [n("x"), n("y"), n("w"), n("h")];
  if (!(x >= 0 && y >= 0 && w > 0 && h > 0 && x + w <= 1.0001 && y + h <= 1.0001)) return null;
  return { x, y, w, h };
}

function whole(v: unknown): number {
  return typeof v === "number" && Number.isFinite(v) && v > 0 ? Math.round(v) : 0;
}

function frame(kind: number, payload: Uint8Array): Uint8Array {
  const out = new Uint8Array(5 + payload.length);
  out[0] = kind;
  new DataView(out.buffer).setUint32(1, payload.length);
  out.set(payload, 5);
  return out;
}

/// A person's input (screen.ts checks it first).
export function inputFrame(input: J): Uint8Array {
  return frame(INPUT, utf8(JSON.stringify(input)));
}

/// The timestamp (µs) of the last frame the client decoded.
export function ackFrame(ts: number): Uint8Array {
  const payload = new Uint8Array(8);
  const view = new DataView(payload.buffer);
  const t = Math.max(0, Math.floor(ts));
  view.setUint32(0, Math.floor(t / TWO_32));
  view.setUint32(4, t % TWO_32);
  return frame(ACK, payload);
}

export function keyframeFrame(): Uint8Array {
  return frame(KEYFRAME, new Uint8Array(0));
}

/// The view's sound on (1) or off (0: muted here, the station sends none).
export function soundFrame(on: boolean): Uint8Array {
  return frame(SOUND, new Uint8Array([on ? 1 : 0]));
}

/// The part of the screen the client shows (null: the whole), and the bounds its pictures are to fit in (the device
/// pixels it is shown in).
export function lookFrame(region: Region | null, maxWidth: number, maxHeight: number): Uint8Array {
  return frame(LOOK, utf8(JSON.stringify(region ? { region, maxWidth, maxHeight } : { region: null })));
}

/// The screen's clipboard set (and pasted, with `paste`): flags (bit 0 paste, bits 1..2 its mark: a station from before
/// reads bit 0 alone), type, the bytes.
export function clipboardFrame(type: ClipType, data: Uint8Array, paste: boolean, privacy: ClipPrivacy | null = null): Uint8Array {
  const payload = new Uint8Array(2 + data.length);
  payload[0] = (paste ? 1 : 0) | (privacy ? PRIVACY_CODE[privacy] << 1 : 0);
  payload[1] = CLIP_BYTE[type];
  payload.set(data, 2);
  return frame(SET_CLIPBOARD, payload);
}

// ── what a station sends, for its tests and the test station ──

export function configFrame(config: { codec: string; width: number; height: number; description?: string; region?: Region }): Uint8Array {
  return frame(CONFIG, utf8(JSON.stringify(config)));
}

export function videoFrame(key: boolean, ts: number, data: Uint8Array): Uint8Array {
  const payload = new Uint8Array(9 + data.length);
  const view = new DataView(payload.buffer);
  payload[0] = key ? 1 : 0;
  view.setUint32(1, Math.floor(ts / TWO_32));
  view.setUint32(5, ts % TWO_32);
  payload.set(data, 9);
  return frame(VIDEO, payload);
}

export function stateFrame(state: J): Uint8Array {
  return frame(STATE, utf8(JSON.stringify(state)));
}

/// The pointer as a station's `cursor` frame says it (null: none shown); a shape of more than CURSOR_SHAPE_MAX bytes
/// goes without it.
export function cursorFrame(cursor: { x: number; y: number; shape?: string } | null): Uint8Array {
  if (cursor === null) return frame(CURSOR, new Uint8Array(0));
  const shape = typeof cursor.shape === "string" ? utf8(cursor.shape) : new Uint8Array(0);
  const payload = new Uint8Array(4 + (shape.length <= CURSOR_SHAPE_MAX ? shape.length : 0));
  const view = new DataView(payload.buffer);
  const q = (v: number) => Math.round(Math.min(1, Math.max(0, Number.isFinite(v) ? v : 0)) * 65535);
  view.setUint16(0, q(cursor.x));
  view.setUint16(2, q(cursor.y));
  if (payload.length > 4) payload.set(shape, 4);
  return frame(CURSOR, payload);
}

/// A `cursorImage` frame (the station's): its size and hot spot, the id, the PNG.
export function cursorImageFrame(image: { w: number; h: number; hx: number; hy: number; id: string; png: Uint8Array }): Uint8Array {
  const payload = new Uint8Array(20 + image.png.length);
  payload.set([image.w, image.h, image.hx, image.hy]);
  payload.set(utf8(image.id).subarray(0, 16), 4);
  payload.set(image.png, 20);
  return frame(CURSOR_IMAGE, payload);
}

export function copiedFrame(type: ClipType, data: Uint8Array, privacy: ClipPrivacy | null = null): Uint8Array {
  const head = privacy ? [PRIVACY_CODE[privacy], CLIP_BYTE[type]] : [CLIP_BYTE[type]];
  const payload = new Uint8Array(head.length + data.length);
  payload.set(head);
  payload.set(data, head.length);
  return frame(privacy ? PRIVATE_CLIPBOARD : CLIPBOARD, payload);
}

/// What the client sends, read (the test station's side).
export type ClientFrame = { input: J } | { ack: number } | { keyframe: true } | { sound: boolean } | { look: J } | { clipboard: { type: ClipType | null; paste: boolean; data: Uint8Array; privacy?: ClipPrivacy } } | { other: number };

export function readClientFrames(buf: Uint8Array): [ClientFrame[], Uint8Array] {
  const frames: ClientFrame[] = [];
  let at = 0;
  const view = new DataView(buf.buffer, buf.byteOffset, buf.byteLength);
  while (buf.length - at >= 5) {
    const len = view.getUint32(at + 1);
    if (buf.length - at - 5 < len) break;
    const payload = buf.subarray(at + 5, at + 5 + len);
    switch (buf[at]) {
      case INPUT:
        frames.push({ input: json(payload) });
        break;
      case ACK: {
        const p = new DataView(payload.buffer, payload.byteOffset, payload.byteLength);
        frames.push({ ack: p.getUint32(0) * TWO_32 + p.getUint32(4) });
        break;
      }
      case KEYFRAME:
        frames.push({ keyframe: true });
        break;
      case SOUND:
        frames.push({ sound: payload[0] !== 0 });
        break;
      case LOOK:
        frames.push({ look: json(payload) });
        break;
      case SET_CLIPBOARD:
        frames.push({ clipboard: { type: CLIP_OF_BYTE[payload[1] ?? 0] ?? null, paste: ((payload[0] ?? 0) & 1) === 1, data: payload.slice(2), ...(PRIVACY_OF_CODE[((payload[0] ?? 0) >> 1) & 3] ? { privacy: PRIVACY_OF_CODE[((payload[0] ?? 0) >> 1) & 3]! } : {}) } });
        break;
      default:
        frames.push({ other: buf[at]! });
    }
    at += 5 + len;
  }
  return [frames, buf.slice(at)];
}
