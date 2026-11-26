// What a device is reached at from the machine it is attached to (设备, 2026-11-10): a connection whose bytes go to it
// as they are, carried to a chat's station over the mesh (mesh/peer-http.ts, a tunnel's `device`). An address and
// port its network reaches (`tcp`); this machine's adb server, which has the phone or board on its USB (`adb`: the
// chat names it with `-s <serial>`); a serial port, set raw at its speed (`serial`).
import { spawn } from "node:child_process";
import { close as closeFd, constants, createReadStream, createWriteStream, open } from "node:fs";
import { type Socket, connect } from "node:net";
import { Duplex } from "node:stream";
import type { AndroidTvProtocol, Device } from "../../../client/core-ts/src/rig-form.ts";
import { wall } from "../ops/fibers.ts";
import { platform } from "../platform/index.ts";
import type { AirPlayControlServer } from "./airplay/server.ts";
import type { AndroidTvControlServer, AndroidTvDeviceRef } from "./android-tv/server.ts";

/// How long a device's address has to take a connection.
const REACH_MS = 10_000;
/// The adb server a machine's own adb starts, where its USB phones are.
export const ADB_PORT = 5037;
/// A serial port's speed when none was given.
export const BAUD_DEFAULT = 115200;

/// A connection to `host:port`: paused, half-open (as peer-forward.ts's `reachLocal` gives one).
export function reachTcp(host: string, port: number): Promise<Socket> {
  return new Promise((resolve, reject) => {
    const socket = connect({ host, port, allowHalfOpen: true });
    const stop = wall.after(REACH_MS, () => {
      socket.destroy();
      reject(new Error(`${host}:${port} took no connection within ${REACH_MS / 1000} s`));
    });
    socket.once("error", (error) => {
      stop();
      reject(error);
    });
    socket.once("connect", () => {
      stop();
      socket.removeAllListeners("error");
      socket.on("error", () => {});
      socket.pause();
      resolve(socket);
    });
  });
}

/// `host:port` (a bracketed IPv6 address too) split.
export function hostPort(target: string): { host: string; port: number } {
  const at = target.lastIndexOf(":");
  const host = target.slice(0, at).replace(/^\[(.*)\]$/, "$1");
  return { host, port: Number(target.slice(at + 1)) };
}

/// The serial port at `path` set raw at `baud` (stty: its flag for the device is -F on Linux, -f on a Mac).
function setRaw(path: string, baud: number): Promise<void> {
  const flag = platform.os === "macos" ? "-f" : "-F";
  return new Promise((resolve, reject) => {
    const child = spawn("stty", [flag, path, "raw", "-echo", String(baud)], { stdio: ["ignore", "ignore", "pipe"] });
    let said = "";
    // (heard before its stderr: one not started (ENFILE, EMFILE) has none, and its error told to none ends the station)
    child.once("error", reject);
    child.once("close", (code) => (code === 0 ? resolve() : reject(new Error(`stty ${path}: ${said.trim() || `exit ${code}`}`))));
    child.stderr?.on("data", (chunk: Buffer) => (said += chunk.toString()));
  });
}

/// The serial port at `path`, both ways, as one stream: paused, as a socket from `reachTcp` is.
async function reachSerial(path: string, baud: number): Promise<Duplex> {
  if (platform.os === "windows") throw new Error("serial ports are not reached on Windows stations yet");
  await setRaw(path, baud);
  const fd = await new Promise<number>((resolve, reject) => open(path, constants.O_RDWR | constants.O_NOCTTY, (error, fd) => (error ? reject(error) : resolve(fd))));
  const readable = createReadStream("", { fd, autoClose: false });
  const writable = createWriteStream("", { fd, autoClose: false });
  const both = Duplex.from({ readable, writable });
  let closed = false;
  const close = () => {
    if (closed) return;
    closed = true;
    readable.destroy();
    writable.destroy();
    closeFd(fd, () => {});
  };
  both.once("close", close);
  both.on("error", () => {});
  both.pause();
  return both;
}

const ADB_FRAME_HEAD = /^[0-9a-f]{4}$/;

/// Single-port 4-byte transparent demuxer for `android_tv` devices:
/// - If the first 4 bytes match an ADB client frame length (`^[0-9a-f]{4}$`, e.g. `000c`) and the device has
///   `adb` enabled, connects the TV to the isolated Android TV ADB server and pipes the stream straight to it.
/// - Otherwise (HTTP requests such as `GET ` / `POST`), pipes the stream to the in-process `AndroidTvControlServer`.
function reachAndroidTv(ref: AndroidTvDeviceRef, androidTv: AndroidTvControlServer): Duplex {
  const hasAdb = Boolean(ref.protocols?.includes("adb"));
  let headChunks: Buffer[] = [];
  let headLen = 0;
  let upstream: Duplex | null = null;
  let resolving = false;
  let pendingWrites: { chunk: Buffer; cb: (err?: Error | null) => void }[] = [];
  let pendingFinal: ((err?: Error | null) => void) | null = null;

  const attachUpstream = (u: Duplex, initial: Buffer, firstCb: (err?: Error | null) => void) => {
    upstream = u;
    u.on("data", (c: Buffer) => {
      if (!demux.push(c)) u.pause();
    });
    u.on("end", () => {
      demux.push(null);
    });
    u.on("error", (err) => {
      demux.destroy(err);
    });
    u.on("close", () => {
      if (!demux.destroyed) demux.destroy();
    });
    u.resume();

    if (initial.length > 0) {
      u.write(initial, firstCb);
    } else {
      firstCb();
    }
    const queued = pendingWrites;
    pendingWrites = [];
    for (const item of queued) {
      u.write(item.chunk, item.cb);
    }
    if (pendingFinal !== null) {
      const fcb = pendingFinal;
      pendingFinal = null;
      u.end(() => fcb());
    }
  };

  const resolveRoute = (initial: Buffer, firstCb: (err?: Error | null) => void) => {
    resolving = true;
    const isAdb = hasAdb && initial.length >= 4 && ADB_FRAME_HEAD.test(initial.subarray(0, 4).toString("ascii"));
    const openPromise: Promise<Duplex> = isAdb
      ? androidTv.ensureAdbConnected(ref).then(() => androidTv.openRawAdbConnection())
      : Promise.resolve(androidTv.open(ref));

    openPromise.then(
      (u) => {
        if (demux.destroyed) {
          u.destroy();
          firstCb(new Error("stream closed"));
          return;
        }
        attachUpstream(u, initial, firstCb);
      },
      (err) => {
        const error = err instanceof Error ? err : new Error(String(err));
        firstCb(error);
        const queued = pendingWrites;
        pendingWrites = [];
        for (const item of queued) item.cb(error);
        if (pendingFinal !== null) {
          const fcb = pendingFinal;
          pendingFinal = null;
          fcb(error);
        }
        demux.destroy(error);
      },
    );
  };

  const demux = new Duplex({
    allowHalfOpen: true,
    read() {
      upstream?.resume();
    },
    write(chunk: Buffer, _encoding: BufferEncoding, callback: (error?: Error | null) => void) {
      if (upstream !== null) {
        upstream.write(chunk, callback);
        return;
      }
      if (resolving) {
        pendingWrites.push({ chunk, cb: callback });
        return;
      }
      headChunks.push(chunk);
      headLen += chunk.length;
      if (headLen >= 4) {
        const initial = Buffer.concat(headChunks);
        headChunks = [];
        headLen = 0;
        resolveRoute(initial, callback);
      } else {
        callback();
      }
    },
    final(callback: (error?: Error | null) => void) {
      if (upstream !== null) {
        upstream.end(() => callback());
        return;
      }
      if (resolving) {
        pendingFinal = callback;
        return;
      }
      if (headLen > 0) {
        const initial = Buffer.concat(headChunks);
        headChunks = [];
        headLen = 0;
        pendingFinal = callback;
        resolveRoute(initial, () => {});
        return;
      }
      callback();
    },
    destroy(error: Error | null, callback: (error?: Error | null) => void) {
      upstream?.destroy();
      upstream = null;
      callback(error);
    },
  });
  demux.on("error", () => {});
  demux.pause();
  return demux;
}

/// A connection to device `d` from this machine.
export async function reachDevice(
  d: Device & { ws?: string },
  airplay?: AirPlayControlServer,
  androidTv?: AndroidTvControlServer,
): Promise<Duplex> {
  switch (d.kind) {
    case "tcp": {
      const { host, port } = hostPort(d.target);
      return reachTcp(host, port);
    }
    case "adb":
      return reachTcp("127.0.0.1", ADB_PORT);
    case "serial":
      return reachSerial(d.target, d.baud ?? BAUD_DEFAULT);
    case "airplay":
      if (airplay === undefined) throw new Error("airplay control server is not available on this station");
      return airplay.open({ id: d.id, ws: d.ws ?? "", target: d.target, name: d.name });
    case "android_tv": {
      if (androidTv === undefined) throw new Error("android_tv control server is not available on this station");
      const protocols = Array.isArray(d.protocols)
        ? d.protocols.filter((p): p is AndroidTvProtocol => p === "atv_remote" || p === "adb")
        : undefined;
      return reachAndroidTv(
        { id: d.id, ws: d.ws ?? "", target: d.target, name: d.name, ...(protocols ? { protocols } : {}) },
        androidTv,
      );
    }
  }
}
