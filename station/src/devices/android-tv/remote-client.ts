// Pure TypeScript Google Android TV Remote Protocol v2 TLS client:
// - Pairing on :6467 (mTLS with self-signed RSA-2048 client cert, 6-char hex PIN verification)
// - Control on :6466 (mTLS with persisted client cert & pinned server cert SHA-256)
import { randomBytes, X509Certificate } from "node:crypto";
import tls, { type TLSSocket } from "node:tls";
import { wall } from "../../ops/fibers.ts";
import { certSha256Hex, computePairingSecretHash, generateClientCert } from "./cert.ts";
import {
  decodePairingMessage,
  decodeRemoteMessage,
  encodePairingConfiguration,
  encodePairingOption,
  encodePairingRequest,
  encodePairingSecret,
  encodeRemoteAppLinkLaunch,
  encodeRemoteConfigure,
  encodeRemoteImeBatchEdit,
  encodeRemoteKeyInject,
  encodeRemotePingResponse,
  encodeRemoteSetActive,
  frameMessage,
  FrameReader,
  PAIRING_STATUS_OK,
  REMOTE_DIRECTION_END_LONG,
  REMOTE_DIRECTION_SHORT,
  REMOTE_DIRECTION_START_LONG,
  resolveAndroidKeyCode,
  type DecodedPairingMessage,
  type DecodedRemoteMessage,
} from "./proto.ts";
import {
  AndroidTvError,
  type AndroidTvControlAction,
  type AndroidTvRemoteCredentials,
} from "./types.ts";

const CONNECT_TIMEOUT_MS = 10_000;
const FRAME_TIMEOUT_MS = 10_000;

/// Buffered frame stream over a TLS socket so request/response steps never race or drop packets.
class FramedTlsChannel {
  readonly socket: TLSSocket;
  readonly #reader = new FrameReader();
  readonly #queue: Buffer[] = [];
  readonly #waiters: { resolve: (b: Buffer) => void; reject: (e: Error) => void }[] = [];
  #ended: Error | null = null;

  constructor(socket: TLSSocket) {
    this.socket = socket;
    socket.on("data", (chunk: Buffer) => {
      let frames: Buffer[];
      try {
        frames = this.#reader.push(chunk);
      } catch (err) {
        this.#fail(err instanceof Error ? err : new Error(String(err)));
        socket.destroy();
        return;
      }
      for (const f of frames) {
        const w = this.#waiters.shift();
        if (w) w.resolve(f);
        else this.#queue.push(f);
      }
    });
    socket.once("error", (err) => this.#fail(err));
    socket.once("close", () => this.#fail(new AndroidTvError("connection_closed", "TV closed the Remote v2 connection")));
  }

  #fail(err: Error): void {
    if (this.#ended !== null) return;
    this.#ended = err;
    while (this.#waiters.length > 0) {
      this.#waiters.shift()!.reject(err);
    }
  }

  send(payload: Buffer): void {
    if (this.socket.destroyed) throw new AndroidTvError("connection_closed", "TV connection is closed");
    this.socket.write(frameMessage(payload));
  }

  /// Gracefully flush all buffered TLS writes and send TLS close_notify before closing.
  end(timeoutMs = 1000): Promise<void> {
    if (this.socket.destroyed || this.socket.writableEnded) return Promise.resolve();
    return new Promise((resolve) => {
      let done = false;
      const finish = () => {
        if (done) return;
        done = true;
        stop();
        resolve();
      };
      const stop = wall.after(timeoutMs, () => {
        this.socket.destroy();
        finish();
      });
      this.socket.once("close", finish);
      this.socket.once("finish", () => {
        // Allow TLS close_notify record to flush to the peer.
        this.socket.end();
        finish();
      });
      this.socket.end();
    });
  }

  nextFrame(timeoutMs = FRAME_TIMEOUT_MS): Promise<Buffer> {
    if (this.#queue.length > 0) return Promise.resolve(this.#queue.shift()!);
    if (this.#ended !== null) return Promise.reject(this.#ended);
    return new Promise((resolve, reject) => {
      let settled = false;
      const waiter = {
        resolve: (b: Buffer) => {
          if (settled) return;
          settled = true;
          stop();
          resolve(b);
        },
        reject: (e: Error) => {
          if (settled) return;
          settled = true;
          stop();
          reject(e);
        },
      };
      const stop = wall.after(timeoutMs, () => {
        const idx = this.#waiters.indexOf(waiter);
        if (idx >= 0) this.#waiters.splice(idx, 1);
        waiter.reject(new AndroidTvError("timeout", "timed out waiting for TV response"));
      });
      this.#waiters.push(waiter);
    });
  }

  close(): void {
    this.socket.destroy();
  }
}

function connectTls(opts: {
  host: string;
  port: number;
  certPem: string;
  keyPem: string;
  timeoutMs?: number;
}): Promise<{ channel: FramedTlsChannel; peerCert: X509Certificate }> {
  return new Promise((resolve, reject) => {
    const socket = tls.connect({
      host: opts.host,
      port: opts.port,
      cert: opts.certPem,
      key: opts.keyPem,
      rejectUnauthorized: false,
    });
    let settled = false;
    const stop = wall.after(opts.timeoutMs ?? CONNECT_TIMEOUT_MS, () => {
      if (settled) return;
      settled = true;
      socket.destroy();
      reject(new AndroidTvError("timeout", `timed out connecting to ${opts.host}:${opts.port}`));
    });
    socket.once("error", (err) => {
      if (settled) return;
      settled = true;
      stop();
      reject(new AndroidTvError("connect_failed", `failed to connect to ${opts.host}:${opts.port}: ${err.message}`));
    });
    socket.once("secureConnect", () => {
      if (settled) return;
      settled = true;
      stop();
      const rawPeer = socket.getPeerCertificate(false);
      if (!rawPeer || !Buffer.isBuffer(rawPeer.raw) || rawPeer.raw.length === 0) {
        socket.destroy();
        reject(new AndroidTvError("auth_failed", "TV did not present a TLS certificate"));
        return;
      }
      const peerCert = new X509Certificate(rawPeer.raw);
      resolve({ channel: new FramedTlsChannel(socket), peerCert });
    });
  });
}

type ActivePair = {
  channel: FramedTlsChannel;
  certPem: string;
  keyPem: string;
  peerCert: X509Certificate;
  serverCertSha256: string;
  serverName?: string;
  host: string;
  pairPort: number;
  remotePort: number;
};

export class AndroidTvRemoteClient {
  readonly #activePairs = new Map<string, ActivePair>();

  async pairStart(params: {
    host: string;
    pairPort?: number;
    remotePort?: number;
  }): Promise<{ pairToken: string; serverName?: string }> {
    const pairPort = params.pairPort ?? 6467;
    const remotePort = params.remotePort ?? 6466;
    const { certPem, keyPem } = await generateClientCert();
    const { channel, peerCert } = await connectTls({
      host: params.host,
      port: pairPort,
      certPem,
      keyPem,
    });
    const serverCertSha256 = certSha256Hex(peerCert);

    try {
      // Step 1: pairing_request -> pairing_request_ack
      channel.send(encodePairingRequest("still.fail", "still.fail"));
      const ack1 = decodePairingMessage(await channel.nextFrame());
      this.#assertPairingOk(ack1, "pairing_request_ack");

      // Step 2: pairing_option -> server pairing_option
      channel.send(encodePairingOption(6));
      const opt = decodePairingMessage(await channel.nextFrame());
      this.#assertPairingOk(opt, "pairing_option");

      // Step 3: pairing_configuration -> pairing_configuration_ack (TV now shows 6-char hex PIN)
      channel.send(encodePairingConfiguration(6));
      const cfgAck = decodePairingMessage(await channel.nextFrame());
      this.#assertPairingOk(cfgAck, "pairing_configuration_ack");

      const pairToken = `atv_rem_${randomBytes(10).toString("hex")}`;
      this.#activePairs.set(pairToken, {
        channel,
        certPem,
        keyPem,
        peerCert,
        serverCertSha256,
        ...(ack1.serverName ? { serverName: ack1.serverName } : {}),
        host: params.host,
        pairPort,
        remotePort,
      });
      return { pairToken, ...(ack1.serverName ? { serverName: ack1.serverName } : {}) };
    } catch (err) {
      channel.close();
      throw err;
    }
  }

  async pairFinish(params: {
    pairToken: string;
    pin: string;
  }): Promise<{ credentials: AndroidTvRemoteCredentials; model?: string }> {
    const active = this.#activePairs.get(params.pairToken);
    if (!active) {
      throw new AndroidTvError("invalid_pair_token", "Remote v2 pairing session not found or expired");
    }
    const cleanPin = params.pin.trim().toUpperCase();
    if (!/^[0-9A-F]{6}$/.test(cleanPin)) {
      throw new AndroidTvError("invalid_pin", "pairing code must be 6 hexadecimal characters (e.g. A3F19C)");
    }
    const pinBytes = Buffer.from(cleanPin, "hex");
    const hash = computePairingSecretHash({
      clientCert: active.certPem,
      serverCert: active.peerCert,
      pinSuffix: pinBytes.subarray(1, 3),
    });
    if (hash[0] !== pinBytes[0]) {
      // Keep the pairing session alive so the user can correct a typo without re-triggering TV PIN dialog.
      throw new AndroidTvError("invalid_pin", "pairing code does not match; check the 6-character code on the TV");
    }

    this.#activePairs.delete(params.pairToken);
    try {
      active.channel.send(encodePairingSecret(hash));
      const ack = decodePairingMessage(await active.channel.nextFrame());
      this.#assertPairingOk(ack, "pairing_secret_ack");
      return {
        credentials: {
          certPem: active.certPem,
          keyPem: active.keyPem,
          serverCertSha256: active.serverCertSha256,
          host: active.host,
          remotePort: active.remotePort,
          pairPort: active.pairPort,
        },
        ...(active.serverName ? { model: active.serverName } : {}),
      };
    } finally {
      active.channel.close();
    }
  }

  async pairCancel(pairToken: string): Promise<void> {
    const active = this.#activePairs.get(pairToken);
    if (!active) return;
    this.#activePairs.delete(pairToken);
    active.channel.close();
  }

  async control(params: {
    host: string;
    remotePort?: number;
    credentials: AndroidTvRemoteCredentials;
    action: AndroidTvControlAction;
    args?: Record<string, unknown>;
  }): Promise<unknown> {
    const host = params.host || params.credentials.host;
    const port = params.remotePort ?? params.credentials.remotePort ?? 6466;
    const { channel, peerCert } = await connectTls({
      host,
      port,
      certPem: params.credentials.certPem,
      keyPem: params.credentials.keyPem,
    });

    try {
      if (params.credentials.serverCertSha256) {
        const actual = certSha256Hex(peerCert);
        if (actual !== params.credentials.serverCertSha256.toLowerCase()) {
          throw new AndroidTvError("auth_failed", "TV TLS certificate fingerprint does not match paired credential");
        }
      }

      // Remote v2 handshake: exchange remote_configure and remote_set_active, capturing initial state pushed by TV.
      const state: {
        model?: string;
        vendor?: string;
        powered?: boolean;
        volumeLevel?: number;
        volumeMax?: number;
        volumeMuted?: boolean;
        imeFieldCounter?: number;
      } = {};

      const handleServerMsg = (msg: DecodedRemoteMessage) => {
        if (msg.kind === "remote_ping_request") {
          channel.send(encodeRemotePingResponse(msg.val1));
        } else if (msg.kind === "remote_configure") {
          if (msg.model) state.model = msg.model;
          if (msg.vendor) state.vendor = msg.vendor;
        } else if (msg.kind === "remote_start") {
          state.powered = msg.started;
        } else if (msg.kind === "remote_set_volume_level") {
          state.volumeLevel = msg.volumeLevel;
          state.volumeMax = msg.volumeMax;
          state.volumeMuted = msg.volumeMuted;
          if (msg.playerModel && !state.model) state.model = msg.playerModel;
        } else if (msg.kind === "remote_ime_show_request") {
          state.imeFieldCounter = msg.fieldCounter;
        }
      };

      // Server typically sends remote_configure first; wait briefly or send ours and read responses.
      const first = decodeRemoteMessage(await channel.nextFrame(3000));
      handleServerMsg(first);
      channel.send(encodeRemoteConfigure());

      // Wait for server remote_set_active (handling any pings/status messages along the way).
      for (let i = 0; i < 6; i++) {
        const msg = decodeRemoteMessage(await channel.nextFrame(3000));
        handleServerMsg(msg);
        if (msg.kind === "remote_set_active") {
          channel.send(encodeRemoteSetActive(msg.active ?? 622));
          break;
        }
        if (msg.kind === "remote_start") {
          channel.send(encodeRemoteSetActive(622));
          break;
        }
      }

      // Drain any immediate status push (remote_start / volume) briefly without blocking.
      if (params.action === "status" || params.action === "volume") {
        for (let i = 0; i < 3; i++) {
          try {
            const extra = decodeRemoteMessage(await channel.nextFrame(150));
            handleServerMsg(extra);
          } catch {
            break;
          }
        }
      }

      const args = params.args ?? {};
      let result: unknown;
      switch (params.action) {
        case "status":
          result = {
            online: true,
            protocol: "atv_remote",
            ...(state.model ? { model: state.model } : {}),
            ...(state.vendor ? { vendor: state.vendor } : {}),
            ...(state.powered !== undefined ? { power: state.powered ? "on" : "off" } : {}),
            ...(state.volumeLevel !== undefined
              ? { volume: state.volumeLevel, volumeMax: state.volumeMax, muted: state.volumeMuted ?? false }
              : {}),
          };
          break;

        case "power": {
          const desired = typeof args.state === "string" ? args.state.trim().toLowerCase() : "toggle";
          if (desired === "get") {
            result = { power: state.powered === undefined ? "unknown" : state.powered ? "on" : "off" };
            break;
          }
          const keyName = desired === "on" ? "power_on" : desired === "off" ? "power_off" : "power";
          const code = resolveAndroidKeyCode(keyName)!;
          channel.send(encodeRemoteKeyInject(code, REMOTE_DIRECTION_SHORT));
          result = { ok: true, action: "power", state: desired };
          break;
        }

        case "remote": {
          const key = typeof args.key === "string" ? args.key.trim() : "";
          const code = resolveAndroidKeyCode(key);
          if (code === null) {
            throw new AndroidTvError("invalid_params", `unsupported remote key: ${key}`);
          }
          const press = typeof args.press === "string" ? args.press.trim().toLowerCase() : "single";
          const repeatRaw = typeof args.repeat === "number" ? args.repeat : 1;
          const repeat = Math.max(1, Math.min(20, Math.floor(repeatRaw)));
          for (let i = 0; i < repeat; i++) {
            if (press === "hold") {
              channel.send(encodeRemoteKeyInject(code, REMOTE_DIRECTION_START_LONG));
              await new Promise<void>((r) => wall.after(300, r));
              channel.send(encodeRemoteKeyInject(code, REMOTE_DIRECTION_END_LONG));
            } else if (press === "double") {
              channel.send(encodeRemoteKeyInject(code, REMOTE_DIRECTION_SHORT));
              channel.send(encodeRemoteKeyInject(code, REMOTE_DIRECTION_SHORT));
            } else {
              channel.send(encodeRemoteKeyInject(code, REMOTE_DIRECTION_SHORT));
            }
          }
          result = { ok: true, key, keyCode: code, press, repeat };
          break;
        }

        case "launch": {
          const app = typeof args.app === "string" ? args.app.trim() : typeof args.url === "string" ? args.url.trim() : "";
          if (!app) throw new AndroidTvError("invalid_params", "launch requires args.app (URL or deep link)");
          channel.send(encodeRemoteAppLinkLaunch(app));
          result = { ok: true, launched: app };
          break;
        }

        case "play_url": {
          const url = typeof args.url === "string" ? args.url.trim() : "";
          if (!url) throw new AndroidTvError("invalid_params", "play_url requires args.url");
          channel.send(encodeRemoteAppLinkLaunch(url));
          result = { ok: true, url };
          break;
        }

        case "volume": {
          if (args.mute === true || args.action === "mute") {
            channel.send(encodeRemoteKeyInject(resolveAndroidKeyCode("mute")!, REMOTE_DIRECTION_SHORT));
            result = { ok: true, muted: true };
            break;
          }
          if (args.action === "up") {
            channel.send(encodeRemoteKeyInject(resolveAndroidKeyCode("volume_up")!, REMOTE_DIRECTION_SHORT));
            result = { ok: true, direction: "up" };
            break;
          }
          if (args.action === "down") {
            channel.send(encodeRemoteKeyInject(resolveAndroidKeyCode("volume_down")!, REMOTE_DIRECTION_SHORT));
            result = { ok: true, direction: "down" };
            break;
          }
          if (typeof args.level === "number") {
            const target = Math.max(0, Math.min(100, Math.round(args.level)));
            if (state.volumeLevel !== undefined && state.volumeMax && state.volumeMax > 0) {
              const targetSteps = Math.round((target / 100) * state.volumeMax);
              const diff = targetSteps - state.volumeLevel;
              const code = resolveAndroidKeyCode(diff >= 0 ? "volume_up" : "volume_down")!;
              const steps = Math.min(30, Math.abs(diff));
              for (let i = 0; i < steps; i++) {
                channel.send(encodeRemoteKeyInject(code, REMOTE_DIRECTION_SHORT));
              }
              result = { ok: true, level: target, stepsSent: steps };
              break;
            }
            throw new AndroidTvError("not_supported", "setting exact volume level requires ADB protocol or TV volume state; use args.action='up'|'down'|'mute'");
          }
          result = {
            ...(state.volumeLevel !== undefined ? { volume: state.volumeLevel, volumeMax: state.volumeMax, muted: state.volumeMuted ?? false } : { volume: null }),
          };
          break;
        }

        case "keyboard": {
          const text = typeof args.text === "string" ? args.text : "";
          channel.send(encodeRemoteImeBatchEdit(text, 0, state.imeFieldCounter ?? 0));
          result = { ok: true, text };
          break;
        }

        default:
          throw new AndroidTvError("not_supported", `action '${params.action}' requires ADB protocol on Android TV`);
      }
      await channel.end();
      return result;
    } finally {
      channel.close();
    }
  }

  #assertPairingOk(msg: DecodedPairingMessage, expected: DecodedPairingMessage["kind"]): void {
    if (msg.status !== PAIRING_STATUS_OK) {
      throw new AndroidTvError(
        msg.status === 402 ? "invalid_pin" : "pair_failed",
        `TV rejected pairing step (${expected}) with status ${msg.status}`,
      );
    }
    if (msg.kind !== expected) {
      throw new AndroidTvError("pair_failed", `unexpected pairing message: expected ${expected}, got ${msg.kind}`);
    }
  }

  async close(): Promise<void> {
    for (const active of this.#activePairs.values()) {
      active.channel.close();
    }
    this.#activePairs.clear();
  }
}
