// Compact wire-format Protobuf codec, varint framing, and Google Android TV Remote Protocol v2 messages.
// Supports both Pairing (:6467) and Remote (:6466) protocols with zero external dependencies.

// ── Wire-format Protobuf primitives ──

export const WIRE_VARINT = 0;
export const WIRE_LEN = 2;

export function encodeVarint(value: number): Buffer {
  if (!Number.isSafeInteger(value) || value < 0) {
    throw new RangeError(`invalid varint value: ${value}`);
  }
  const out: number[] = [];
  let v = value;
  while (v >= 0x80) {
    out.push((v & 0x7f) | 0x80);
    v = Math.floor(v / 128);
  }
  out.push(v);
  return Buffer.from(out);
}

export function decodeVarint(buf: Buffer, offset = 0): { value: number; next: number } | null {
  let value = 0;
  let mult = 1;
  let i = offset;
  while (i < buf.length) {
    const b = buf[i]!;
    value += (b & 0x7f) * mult;
    i++;
    if ((b & 0x80) === 0) return { value, next: i };
    mult *= 128;
    if (i - offset > 8) throw new Error("varint too long");
  }
  return null;
}

export function pbVarint(field: number, value: number): Buffer {
  return Buffer.concat([encodeVarint((field << 3) | WIRE_VARINT), encodeVarint(value)]);
}

export function pbBytes(field: number, data: Buffer): Buffer {
  return Buffer.concat([encodeVarint((field << 3) | WIRE_LEN), encodeVarint(data.length), data]);
}

export function pbString(field: number, value: string): Buffer {
  return pbBytes(field, Buffer.from(value, "utf8"));
}

export function pbMessage(field: number, parts: readonly Buffer[]): Buffer {
  return pbBytes(field, Buffer.concat(parts));
}

export type PbField =
  | { field: number; wire: 0; value: number }
  | { field: number; wire: 2; value: Buffer };

export function decodeFields(buf: Buffer): PbField[] {
  const out: PbField[] = [];
  let offset = 0;
  while (offset < buf.length) {
    const tag = decodeVarint(buf, offset);
    if (tag === null) throw new Error("truncated protobuf tag");
    offset = tag.next;
    const field = tag.value >>> 3;
    const wire = tag.value & 7;
    if (wire === WIRE_VARINT) {
      const v = decodeVarint(buf, offset);
      if (v === null) throw new Error("truncated protobuf varint");
      offset = v.next;
      out.push({ field, wire: 0, value: v.value });
    } else if (wire === WIRE_LEN) {
      const len = decodeVarint(buf, offset);
      if (len === null || offset + len.value > buf.length) throw new Error("truncated protobuf length-delimited field");
      offset = len.next;
      out.push({ field, wire: 2, value: buf.subarray(offset, offset + len.value) });
      offset += len.value;
    } else if (wire === 1) {
      if (offset + 8 > buf.length) throw new Error("truncated protobuf fixed64");
      offset += 8;
    } else if (wire === 5) {
      if (offset + 4 > buf.length) throw new Error("truncated protobuf fixed32");
      offset += 4;
    } else {
      throw new Error(`unsupported protobuf wire type: ${wire}`);
    }
  }
  return out;
}

function firstVarint(fields: readonly PbField[], num: number): number | undefined {
  const f = fields.find((x) => x.field === num && x.wire === 0);
  return f && f.wire === 0 ? f.value : undefined;
}

function firstBytes(fields: readonly PbField[], num: number): Buffer | undefined {
  const f = fields.find((x) => x.field === num && x.wire === 2);
  return f && f.wire === 2 ? f.value : undefined;
}

function firstString(fields: readonly PbField[], num: number): string | undefined {
  const b = firstBytes(fields, num);
  return b ? b.toString("utf8") : undefined;
}

// ── Varint-prefixed message framing ──

export function frameMessage(payload: Buffer): Buffer {
  return Buffer.concat([encodeVarint(payload.length), payload]);
}

/// Incremental varint-framed message reader.
export class FrameReader {
  #buf: Buffer = Buffer.alloc(0);

  push(chunk: Buffer): Buffer[] {
    this.#buf = this.#buf.length === 0 ? Buffer.from(chunk) : Buffer.concat([this.#buf, chunk]);
    const frames: Buffer[] = [];
    while (this.#buf.length > 0) {
      const len = decodeVarint(this.#buf, 0);
      if (len === null) break;
      if (len.value > 4 * 1024 * 1024) throw new Error("frame exceeds 4 MB limit");
      if (this.#buf.length < len.next + len.value) break;
      frames.push(Buffer.from(this.#buf.subarray(len.next, len.next + len.value)));
      this.#buf = this.#buf.subarray(len.next + len.value);
    }
    return frames;
  }
}

// ── Pairing Protocol v2 (:6467) ──

export const PAIRING_PROTOCOL_VERSION = 2;
export const PAIRING_STATUS_OK = 200;
export const PAIRING_STATUS_ERROR = 400;
export const PAIRING_STATUS_BAD_CONFIGURATION = 401;
export const PAIRING_STATUS_BAD_SECRET = 402;

export const ENCODING_TYPE_HEXADECIMAL = 3;
export const ROLE_TYPE_INPUT = 1;
export const ROLE_TYPE_OUTPUT = 2;

export function encodePairingRequest(serviceName: string, clientName: string): Buffer {
  return Buffer.concat([
    pbVarint(1, PAIRING_PROTOCOL_VERSION),
    pbVarint(2, PAIRING_STATUS_OK),
    pbMessage(10, [pbString(1, serviceName), pbString(2, clientName)]),
  ]);
}

export function encodePairingOption(symbolLength = 6): Buffer {
  const encoding = Buffer.concat([pbVarint(1, ENCODING_TYPE_HEXADECIMAL), pbVarint(2, symbolLength)]);
  return Buffer.concat([
    pbVarint(1, PAIRING_PROTOCOL_VERSION),
    pbVarint(2, PAIRING_STATUS_OK),
    pbMessage(20, [pbBytes(1, encoding), pbVarint(3, ROLE_TYPE_INPUT)]),
  ]);
}

export function encodePairingConfiguration(symbolLength = 6): Buffer {
  const encoding = Buffer.concat([pbVarint(1, ENCODING_TYPE_HEXADECIMAL), pbVarint(2, symbolLength)]);
  return Buffer.concat([
    pbVarint(1, PAIRING_PROTOCOL_VERSION),
    pbVarint(2, PAIRING_STATUS_OK),
    pbMessage(30, [pbBytes(1, encoding), pbVarint(2, ROLE_TYPE_INPUT)]),
  ]);
}

export function encodePairingSecret(secretHash: Buffer): Buffer {
  return Buffer.concat([
    pbVarint(1, PAIRING_PROTOCOL_VERSION),
    pbVarint(2, PAIRING_STATUS_OK),
    pbMessage(40, [pbBytes(1, secretHash)]),
  ]);
}

export type DecodedPairingMessage = {
  protocolVersion: number;
  status: number;
  kind:
    | "pairing_request"
    | "pairing_request_ack"
    | "pairing_option"
    | "pairing_configuration"
    | "pairing_configuration_ack"
    | "pairing_secret"
    | "pairing_secret_ack"
    | "unknown";
  serverName?: string;
  serviceName?: string;
  clientName?: string;
  secret?: Buffer;
};

export function decodePairingMessage(buf: Buffer): DecodedPairingMessage {
  const fields = decodeFields(buf);
  const protocolVersion = firstVarint(fields, 1) ?? 0;
  const status = firstVarint(fields, 2) ?? 0;
  const req = firstBytes(fields, 10);
  if (req !== undefined) {
    const f = decodeFields(req);
    return { protocolVersion, status, kind: "pairing_request", serviceName: firstString(f, 1), clientName: firstString(f, 2) };
  }
  const reqAck = firstBytes(fields, 11);
  if (reqAck !== undefined) {
    const f = decodeFields(reqAck);
    return { protocolVersion, status, kind: "pairing_request_ack", serverName: firstString(f, 1) };
  }
  if (firstBytes(fields, 20) !== undefined) return { protocolVersion, status, kind: "pairing_option" };
  if (firstBytes(fields, 30) !== undefined) return { protocolVersion, status, kind: "pairing_configuration" };
  if (firstBytes(fields, 31) !== undefined) return { protocolVersion, status, kind: "pairing_configuration_ack" };
  const sec = firstBytes(fields, 40);
  if (sec !== undefined) {
    const f = decodeFields(sec);
    return { protocolVersion, status, kind: "pairing_secret", secret: firstBytes(f, 1) };
  }
  const secAck = firstBytes(fields, 41);
  if (secAck !== undefined) {
    const f = decodeFields(secAck);
    return { protocolVersion, status, kind: "pairing_secret_ack", secret: firstBytes(f, 1) };
  }
  return { protocolVersion, status, kind: "unknown" };
}

// ── Remote Protocol v2 (:6466) ──

export const REMOTE_DIRECTION_START_LONG = 1;
export const REMOTE_DIRECTION_END_LONG = 2;
export const REMOTE_DIRECTION_SHORT = 3;

/// Standard Android KeyEvent keycodes supported by both Remote v2 and ADB `input keyevent`.
export const ANDROID_KEY_CODES: Record<string, number> = {
  up: 19,
  down: 20,
  left: 21,
  right: 22,
  select: 23,
  center: 23,
  enter: 66,
  back: 4,
  home: 3,
  menu: 82,
  play: 126,
  pause: 127,
  play_pause: 85,
  stop: 86,
  next: 87,
  previous: 88,
  volume_up: 24,
  volume_down: 25,
  mute: 164,
  power: 26,
  power_on: 224,
  power_off: 223,
  channel_up: 166,
  channel_down: 167,
  search: 84,
  settings: 176,
  "0": 7,
  "1": 8,
  "2": 9,
  "3": 10,
  "4": 11,
  "5": 12,
  "6": 13,
  "7": 14,
  "8": 15,
  "9": 16,
};

export function resolveAndroidKeyCode(key: string): number | null {
  const normalized = key.trim().toLowerCase();
  if (normalized in ANDROID_KEY_CODES) return ANDROID_KEY_CODES[normalized]!;
  if (/^[0-9]+$/.test(normalized)) {
    const code = Number(normalized);
    if (Number.isSafeInteger(code) && code >= 0 && code <= 1024) return code;
  }
  return null;
}

export function encodeRemoteConfigure(opts?: {
  code1?: number;
  model?: string;
  vendor?: string;
  packageName?: string;
  appVersion?: string;
}): Buffer {
  const code1 = opts?.code1 ?? 622;
  const deviceInfo = Buffer.concat([
    pbString(1, opts?.model ?? "still.fail"),
    pbString(2, opts?.vendor ?? "still.fail"),
    pbVarint(3, 1),
    pbString(4, "1"),
    pbString(5, opts?.packageName ?? "fail.still.remote"),
    pbString(6, opts?.appVersion ?? "1.0.0"),
  ]);
  return pbMessage(1, [pbVarint(1, code1), pbBytes(2, deviceInfo)]);
}

export function encodeRemoteSetActive(active = 622): Buffer {
  return pbMessage(2, [pbVarint(1, active)]);
}

export function encodeRemotePingResponse(val1: number): Buffer {
  return pbMessage(9, [pbVarint(1, val1)]);
}

export function encodeRemoteKeyInject(keyCode: number, direction = REMOTE_DIRECTION_SHORT): Buffer {
  return pbMessage(10, [pbVarint(1, keyCode), pbVarint(2, direction)]);
}

export function encodeRemoteAppLinkLaunch(appLink: string): Buffer {
  return pbMessage(90, [pbString(1, appLink)]);
}

export function encodeRemoteImeBatchEdit(text: string, imeCounter = 0, fieldCounter = 0): Buffer {
  const textFieldStatus = Buffer.concat([
    pbVarint(1, fieldCounter),
    pbString(2, text),
    pbVarint(3, text.length),
    pbVarint(4, text.length),
  ]);
  const editInfo = Buffer.concat([
    pbVarint(1, 2),
    pbBytes(2, textFieldStatus),
  ]);
  return pbMessage(21, [
    pbVarint(1, imeCounter),
    pbVarint(2, fieldCounter),
    pbBytes(3, editInfo),
  ]);
}

export type DecodedRemoteMessage =
  | { kind: "remote_configure"; code1?: number; model?: string; vendor?: string }
  | { kind: "remote_set_active"; active?: number }
  | { kind: "remote_ping_request"; val1: number }
  | { kind: "remote_ping_response"; val1: number }
  | { kind: "remote_key_inject"; keyCode: number; direction: number }
  | { kind: "remote_ime_batch_edit"; imeCounter: number; fieldCounter: number; text?: string }
  | { kind: "remote_ime_show_request"; fieldCounter: number; value?: string }
  | { kind: "remote_start"; started: boolean }
  | { kind: "remote_set_volume_level"; volumeLevel: number; volumeMax: number; volumeMuted: boolean; playerModel?: string }
  | { kind: "remote_app_link_launch_request"; appLink: string }
  | { kind: "remote_error"; value: boolean }
  | { kind: "unknown" };

export function decodeRemoteMessage(buf: Buffer): DecodedRemoteMessage {
  const fields = decodeFields(buf);
  const cfg = firstBytes(fields, 1);
  if (cfg !== undefined) {
    const f = decodeFields(cfg);
    const info = firstBytes(f, 2);
    const infoFields = info ? decodeFields(info) : [];
    return {
      kind: "remote_configure",
      code1: firstVarint(f, 1),
      model: firstString(infoFields, 1),
      vendor: firstString(infoFields, 2),
    };
  }
  const active = firstBytes(fields, 2);
  if (active !== undefined) {
    return { kind: "remote_set_active", active: firstVarint(decodeFields(active), 1) };
  }
  const err = firstBytes(fields, 3);
  if (err !== undefined) {
    return { kind: "remote_error", value: (firstVarint(decodeFields(err), 1) ?? 0) !== 0 };
  }
  const pingReq = firstBytes(fields, 8);
  if (pingReq !== undefined) {
    return { kind: "remote_ping_request", val1: firstVarint(decodeFields(pingReq), 1) ?? 0 };
  }
  const pingRes = firstBytes(fields, 9);
  if (pingRes !== undefined) {
    return { kind: "remote_ping_response", val1: firstVarint(decodeFields(pingRes), 1) ?? 0 };
  }
  const key = firstBytes(fields, 10);
  if (key !== undefined) {
    const f = decodeFields(key);
    return {
      kind: "remote_key_inject",
      keyCode: firstVarint(f, 1) ?? 0,
      direction: firstVarint(f, 2) ?? REMOTE_DIRECTION_SHORT,
    };
  }
  const batch = firstBytes(fields, 21);
  if (batch !== undefined) {
    const f = decodeFields(batch);
    const editInfo = firstBytes(f, 3);
    const editFields = editInfo ? decodeFields(editInfo) : [];
    const status = firstBytes(editFields, 2);
    const statusFields = status ? decodeFields(status) : [];
    return {
      kind: "remote_ime_batch_edit",
      imeCounter: firstVarint(f, 1) ?? 0,
      fieldCounter: firstVarint(f, 2) ?? 0,
      text: firstString(statusFields, 2),
    };
  }
  const imeShow = firstBytes(fields, 22);
  if (imeShow !== undefined) {
    const f = decodeFields(imeShow);
    const status = firstBytes(f, 2);
    const statusFields = status ? decodeFields(status) : [];
    return {
      kind: "remote_ime_show_request",
      fieldCounter: firstVarint(statusFields, 1) ?? 0,
      value: firstString(statusFields, 2),
    };
  }
  const start = firstBytes(fields, 40);
  if (start !== undefined) {
    return { kind: "remote_start", started: (firstVarint(decodeFields(start), 1) ?? 0) !== 0 };
  }
  const vol = firstBytes(fields, 50);
  if (vol !== undefined) {
    const f = decodeFields(vol);
    return {
      kind: "remote_set_volume_level",
      playerModel: firstString(f, 3),
      volumeMax: firstVarint(f, 6) ?? 0,
      volumeLevel: firstVarint(f, 7) ?? 0,
      volumeMuted: (firstVarint(f, 8) ?? 0) !== 0,
    };
  }
  const launch = firstBytes(fields, 90);
  if (launch !== undefined) {
    return { kind: "remote_app_link_launch_request", appLink: firstString(decodeFields(launch), 1) ?? "" };
  }
  return { kind: "unknown" };
}
