// Isolated ADB client for Android TV / Android TV boxes:
// - Dedicated vendor key dir: <data>/devices/adb-keys/ (never touches ~/.android/adbkey)
// - Dedicated ADB server socket: <data>/run/android-tv-adb.sock (Unix) or free 127.0.0.1 port (Windows)
//   (never touches host 5037)
// - Provides openRawAdbConnection() for single-port 4-byte transparent demux in devices/connect.ts
import { type ChildProcess, spawn } from "node:child_process";
import { chmod, mkdir, rm } from "node:fs/promises";
import net from "node:net";
import { join } from "node:path";
import { adbPath } from "../../adb/link.ts";
import { wall } from "../../ops/fibers.ts";
import { platform } from "../../platform/index.ts";
import { resolveAndroidKeyCode } from "./proto.ts";
import {
  AndroidTvError,
  type AndroidTvAdbCredentials,
  type AndroidTvControlAction,
} from "./types.ts";

const PNG_MAGIC = Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]);
const DEFAULT_ADB_TIMEOUT_MS = 20_000;

export type AdbExecResult = {
  code: number;
  stdout: Buffer;
  stderr: Buffer;
};

export type AdbExecFn = (
  args: string[],
  opts?: { timeoutMs?: number },
) => Promise<AdbExecResult>;

/// Parse PNG width & height from the IHDR chunk, validating magic bytes.
export function parsePngDimensions(png: Buffer): { width: number; height: number } {
  if (png.length < 24 || !png.subarray(0, 8).equals(PNG_MAGIC)) {
    throw new AndroidTvError("invalid_screenshot", "screencap did not return a valid PNG image");
  }
  const chunkType = png.subarray(12, 16).toString("ascii");
  if (chunkType !== "IHDR") {
    throw new AndroidTvError("invalid_screenshot", "PNG missing IHDR header");
  }
  const width = png.readUInt32BE(16);
  const height = png.readUInt32BE(20);
  if (width === 0 || height === 0 || width > 16384 || height > 16384) {
    throw new AndroidTvError("invalid_screenshot", `invalid PNG dimensions: ${width}x${height}`);
  }
  return { width, height };
}

/// Safely single-quote an argument for Android `/system/bin/sh -c` (`adb shell` concatenates args with spaces).
/// Rejects ASCII control characters (including NUL, CR, LF) so shell commands cannot be split or injected.
export function quoteAndroidShellArg(s: string): string {
  if (/[\x00-\x1f\x7f]/.test(s)) {
    throw new AndroidTvError("invalid_params", "shell argument contains unsupported control characters");
  }
  return `'${s.replace(/'/g, "'\\''")}'`;
}

/// Escape text safely for `adb shell input text <escaped>`.
/// Rejects NUL and non-whitespace control characters, flattens CR/LF/TAB to spaces so `adb shell` can never
/// execute a second line, and escapes all POSIX shell metacharacters.
export function escapeAdbInputText(text: string): string {
  if (/[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]/.test(text)) {
    throw new AndroidTvError("invalid_params", "keyboard text contains unsupported control characters");
  }
  const singleLine = text.replace(/\r\n|[\r\n\t]/g, " ");
  // Replace spaces with %s (Android input text convention) and backslash-escape shell metacharacters.
  return singleLine
    .replace(/\\/g, "\\\\")
    .replace(/ /g, "%s")
    .replace(/(["'`$&|;<>()\[\]{}*?!#~^])/g, "\\$1");
}

function freeLoopbackPort(): Promise<number> {
  return new Promise((resolve, reject) => {
    const s = net.createServer();
    s.once("error", reject);
    s.listen({ host: "127.0.0.1", port: 0 }, () => {
      const port = (s.address() as net.AddressInfo).port;
      s.close(() => resolve(port));
    });
  });
}

export class AndroidTvAdbClient {
  readonly #dataDir: string;
  readonly #adbBin: () => string | null;
  readonly #customExec: AdbExecFn | null;
  readonly #customRawOpen: (() => Promise<net.Socket>) | null;
  #serverChild: ChildProcess | null = null;
  #serverStarting: Promise<void> | null = null;
  #sockPath: string | null = null;
  #winPort: number | null = null;

  constructor(opts: {
    dataDir: string;
    adb?: () => string | null;
    exec?: AdbExecFn;
    openRaw?: () => Promise<net.Socket>;
  }) {
    this.#dataDir = opts.dataDir;
    this.#adbBin = opts.adb ?? adbPath;
    this.#customExec = opts.exec ?? null;
    this.#customRawOpen = opts.openRaw ?? null;
  }

  get keyDir(): string {
    return join(this.#dataDir, "devices", "adb-keys");
  }

  get socketPath(): string {
    return join(this.#dataDir, "run", "android-tv-adb.sock");
  }

  isAvailable(): boolean {
    if (this.#customExec !== null) return true;
    return this.#adbBin() !== null;
  }

  async #ensureKeyDir(): Promise<void> {
    await mkdir(this.keyDir, { recursive: true, mode: 0o700 });
    if (platform.os !== "windows") await chmod(this.keyDir, 0o700).catch(() => {});
  }

  async #ensureServer(): Promise<void> {
    if (this.#customExec !== null) return;
    if (this.#serverChild !== null && this.#serverChild.exitCode === null) return;
    if (this.#serverStarting !== null) return this.#serverStarting;
    this.#serverStarting = this.#startServer().finally(() => {
      this.#serverStarting = null;
    });
    return this.#serverStarting;
  }

  async #startServer(): Promise<void> {
    const bin = this.#adbBin();
    if (!bin) {
      throw new AndroidTvError("adb_missing", "adb is not installed on this station");
    }
    await this.#ensureKeyDir();
    const runDir = join(this.#dataDir, "run");
    await mkdir(runDir, { recursive: true, mode: 0o700 });

    const isWin = platform.os === "windows";
    const sockPath = isWin ? null : this.socketPath;
    if (sockPath !== null) {
      await rm(sockPath, { force: true }).catch(() => {});
    }
    const winPort = isWin ? (this.#winPort ?? (await freeLoopbackPort())) : null;
    this.#sockPath = sockPath;
    this.#winPort = winPort;

    const env: NodeJS.ProcessEnv = {
      ...process.env,
      ADB_VENDOR_KEYS: this.keyDir,
      ...(sockPath !== null ? { ADB_SERVER_SOCKET: `localfilesystem:${sockPath}` } : {}),
    };
    const args = sockPath !== null ? ["server", "nodaemon"] : ["-P", String(winPort!), "server", "nodaemon"];
    const r = await platform.runnableSoon(bin, args, env);
    const child = spawn(r.file, r.args, {
      env,
      stdio: "ignore",
      windowsHide: true,
      windowsVerbatimArguments: r.windowsVerbatimArguments,
    });

    const up = await new Promise<boolean>((resolve) => {
      child.once("exit", () => resolve(false));
      child.once("error", () => resolve(false));
      let tries = 0;
      const poke = () => {
        const c = net.connect(sockPath !== null ? { path: sockPath } : { host: "127.0.0.1", port: winPort! }, () => {
          c.destroy();
          resolve(true);
        });
        c.once("error", () => {
          c.destroy();
          if (++tries < 50) wall.after(100, poke);
          else resolve(false);
        });
      };
      poke();
    });

    if (!up) {
      child.kill("SIGKILL");
      throw new AndroidTvError("adb_failed", "failed to start isolated Android TV adb server");
    }
    this.#serverChild = child;
    child.once("exit", () => {
      if (this.#serverChild === child) this.#serverChild = null;
    });
  }

  /// Open a raw paused half-open socket directly to the isolated Android TV ADB server (for 4-byte demux).
  async openRawConnection(): Promise<net.Socket> {
    if (this.#customRawOpen !== null) return this.#customRawOpen();
    await this.#ensureServer();
    return new Promise((resolve, reject) => {
      const target = this.#sockPath !== null
        ? { path: this.#sockPath, allowHalfOpen: true }
        : { host: "127.0.0.1", port: this.#winPort!, allowHalfOpen: true };
      const socket = net.connect(target);
      const stop = wall.after(5_000, () => {
        socket.destroy();
        reject(new AndroidTvError("adb_failed", "timed out connecting to isolated Android TV adb server"));
      });
      socket.once("error", (err) => {
        stop();
        reject(err);
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

  async exec(args: string[], opts?: { timeoutMs?: number }): Promise<AdbExecResult> {
    if (this.#customExec !== null) return this.#customExec(args, opts);
    await this.#ensureServer();
    const bin = this.#adbBin();
    if (!bin) throw new AndroidTvError("adb_missing", "adb is not installed on this station");
    const env: NodeJS.ProcessEnv = {
      ...process.env,
      ADB_VENDOR_KEYS: this.keyDir,
      ...(this.#sockPath !== null ? { ADB_SERVER_SOCKET: `localfilesystem:${this.#sockPath}` } : {}),
    };
    const fullArgs = this.#winPort !== null ? ["-P", String(this.#winPort), ...args] : args;
    const r = await platform.runnableSoon(bin, fullArgs, env);
    const timeoutMs = opts?.timeoutMs ?? DEFAULT_ADB_TIMEOUT_MS;
    return new Promise((resolve, reject) => {
      const child = spawn(r.file, r.args, {
        env,
        stdio: ["ignore", "pipe", "pipe"],
        windowsHide: true,
        windowsVerbatimArguments: r.windowsVerbatimArguments,
      });
      const stdout: Buffer[] = [];
      const stderr: Buffer[] = [];
      let timedOut = false;
      const stop = wall.after(timeoutMs, () => {
        timedOut = true;
        child.kill("SIGKILL");
        reject(new AndroidTvError("timeout", `adb ${args[0] ?? ""} timed out`));
      });
      child.once("error", (err) => {
        stop();
        reject(new AndroidTvError("adb_failed", err.message));
      });
      child.stdout?.on("data", (c: Buffer) => stdout.push(c));
      child.stderr?.on("data", (c: Buffer) => stderr.push(c));
      child.once("close", (code) => {
        stop();
        if (timedOut) return;
        resolve({ code: code ?? 1, stdout: Buffer.concat(stdout), stderr: Buffer.concat(stderr) });
      });
    });
  }

  /// Pair Android 11+ Wireless Debugging (`adb pair host:pairPort pin`) and verify connection.
  async pairWireless(params: {
    host: string;
    pairPort: number;
    pin: string;
    connectPort?: number;
  }): Promise<{ credentials: AndroidTvAdbCredentials; model?: string }> {
    const pin = params.pin.trim();
    if (!/^[0-9]{6}$/.test(pin)) {
      throw new AndroidTvError("invalid_pin", "Android wireless debugging pairing code must be 6 digits");
    }
    const pairTarget = `${params.host}:${params.pairPort}`;
    const pairRes = await this.exec(["pair", pairTarget, pin]);
    const pairOut = `${pairRes.stdout.toString("utf8")}\n${pairRes.stderr.toString("utf8")}`.trim();
    if (pairRes.code !== 0 || /failed|error/i.test(pairOut)) {
      throw new AndroidTvError("pair_failed", `adb pair failed: ${pairOut || `exit ${pairRes.code}`}`);
    }
    const connectPort = params.connectPort ?? 5555;
    return this.connectAndVerify(params.host, connectPort, "tls_wireless");
  }

  /// Connect legacy network ADB (`adb connect host:port`, default 5555) and check authorization state.
  async connectLegacy(host: string, port = 5555): Promise<{ credentials: AndroidTvAdbCredentials; model?: string }> {
    return this.connectAndVerify(host, port, "legacy_tcp");
  }

  async connectAndVerify(
    host: string,
    port: number,
    mode: "legacy_tcp" | "tls_wireless",
  ): Promise<{ credentials: AndroidTvAdbCredentials; model?: string }> {
    const serial = `${host}:${port}`;
    const connRes = await this.exec(["connect", serial]);
    const connOut = `${connRes.stdout.toString("utf8")}\n${connRes.stderr.toString("utf8")}`.trim();
    if (connRes.code !== 0 || /unable to connect|failed to connect|refused|cannot connect/i.test(connOut)) {
      throw new AndroidTvError("connect_failed", `adb connect ${serial} failed: ${connOut || `exit ${connRes.code}`}`);
    }

    const stateRes = await this.exec(["-s", serial, "get-state"]);
    const stateOut = `${stateRes.stdout.toString("utf8")}\n${stateRes.stderr.toString("utf8")}`.trim();
    if (stateOut.includes("unauthorized")) {
      throw new AndroidTvError(
        "adb_unauthorized",
        "TV has not authorized USB/network debugging yet; click 'Always allow' on the TV screen and retry",
      );
    }
    if (stateRes.code !== 0 || !stateOut.includes("device")) {
      throw new AndroidTvError("connect_failed", `adb device not ready (${stateOut || `exit ${stateRes.code}`})`);
    }

    const modelRes = await this.exec(["-s", serial, "shell", "getprop", "ro.product.model"]).catch(() => null);
    const model = modelRes && modelRes.code === 0 ? modelRes.stdout.toString("utf8").trim() : undefined;
    return {
      credentials: { host, port, mode, serial },
      ...(model ? { model } : {}),
    };
  }

  /// Ensure a target `host:port` is connected in our isolated ADB server before issuing commands or demuxing raw ADB.
  async ensureConnected(host: string, port: number): Promise<string> {
    const serial = `${host}:${port}`;
    const stateRes = await this.exec(["-s", serial, "get-state"]).catch(() => null);
    if (stateRes && stateRes.code === 0 && stateRes.stdout.toString("utf8").trim() === "device") {
      return serial;
    }
    const connRes = await this.exec(["connect", serial]);
    const connOut = `${connRes.stdout.toString("utf8")}\n${connRes.stderr.toString("utf8")}`.trim();
    if (connRes.code !== 0 || /unable to connect|failed to connect|refused|cannot connect/i.test(connOut)) {
      throw new AndroidTvError("connect_failed", `adb connect ${serial} failed: ${connOut || `exit ${connRes.code}`}`);
    }
    const after = await this.exec(["-s", serial, "get-state"]);
    const afterOut = `${after.stdout.toString("utf8")}\n${after.stderr.toString("utf8")}`.trim();
    if (afterOut.includes("unauthorized")) {
      throw new AndroidTvError("adb_unauthorized", "TV ADB debugging is unauthorized; approve the prompt on the TV screen");
    }
    if (after.code !== 0 || !afterOut.includes("device")) {
      throw new AndroidTvError("connect_failed", `adb device ${serial} is not ready: ${afterOut}`);
    }
    return serial;
  }

  async #shell(serial: string, cmdArgs: string[]): Promise<string> {
    const res = await this.exec(["-s", serial, "shell", ...cmdArgs]);
    if (res.code !== 0) {
      const msg = res.stderr.toString("utf8").trim() || res.stdout.toString("utf8").trim() || `exit ${res.code}`;
      throw new AndroidTvError("adb_failed", `adb shell ${cmdArgs[0] ?? ""} failed: ${msg}`);
    }
    return res.stdout.toString("utf8").trim();
  }

  async screenshot(serial: string): Promise<{ png: Buffer; width: number; height: number }> {
    const res = await this.exec(["-s", serial, "exec-out", "screencap", "-p"], { timeoutMs: 25_000 });
    if (res.code !== 0) {
      const msg = res.stderr.toString("utf8").trim() || `exit ${res.code}`;
      throw new AndroidTvError("adb_failed", `screencap failed: ${msg}`);
    }
    const { width, height } = parsePngDimensions(res.stdout);
    return { png: res.stdout, width, height };
  }

  async control(serial: string, action: AndroidTvControlAction, args: Record<string, unknown> = {}): Promise<unknown> {
    switch (action) {
      case "status": {
        const [model, manufacturer, release, powerDump, focusDump, volDump] = await Promise.all([
          this.#shell(serial, ["getprop", "ro.product.model"]).catch(() => ""),
          this.#shell(serial, ["getprop", "ro.product.manufacturer"]).catch(() => ""),
          this.#shell(serial, ["getprop", "ro.build.version.release"]).catch(() => ""),
          this.#shell(serial, ["dumpsys", "power"]).catch(() => ""),
          this.#shell(serial, ["dumpsys", "window", "displays"]).catch(() => ""),
          this.#shell(serial, ["cmd", "media_session", "volume", "--stream", "3", "--get"]).catch(() => ""),
        ]);
        const wakeMatch = /mWakefulness=(\w+)/.exec(powerDump);
        const screenOn = wakeMatch ? wakeMatch[1] === "Awake" : /Display Power: state=ON/.test(powerDump);
        const focusMatch = /mCurrentFocus=Window\{[^\s]+ [^\s]+ ([A-Za-z0-9._]+)\//.exec(focusDump);
        const volMatch = /volume is (\d+) in range \[(\d+)\.\.(\d+)\]/.exec(volDump);
        return {
          online: true,
          protocol: "adb",
          serial,
          ...(model ? { model } : {}),
          ...(manufacturer ? { manufacturer } : {}),
          ...(release ? { androidVersion: release } : {}),
          power: screenOn ? "on" : "off",
          ...(focusMatch ? { foregroundApp: focusMatch[1] } : {}),
          ...(volMatch
            ? { volume: Number(volMatch[1]), volumeMin: Number(volMatch[2]), volumeMax: Number(volMatch[3]) }
            : {}),
        };
      }

      case "power": {
        const desired = typeof args.state === "string" ? args.state.trim().toLowerCase() : "toggle";
        if (desired === "get") {
          const dump = await this.#shell(serial, ["dumpsys", "power"]);
          const awake = /mWakefulness=Awake/.test(dump) || /Display Power: state=ON/.test(dump);
          return { power: awake ? "on" : "off" };
        }
        const keyCode = desired === "on" ? 224 : desired === "off" ? 223 : 26;
        await this.#shell(serial, ["input", "keyevent", String(keyCode)]);
        return { ok: true, action: "power", state: desired };
      }

      case "remote": {
        const key = typeof args.key === "string" ? args.key.trim() : "";
        const code = resolveAndroidKeyCode(key);
        if (code === null) throw new AndroidTvError("invalid_params", `unsupported remote key: ${key}`);
        const press = typeof args.press === "string" ? args.press.trim().toLowerCase() : "single";
        const repeatRaw = typeof args.repeat === "number" ? args.repeat : 1;
        const repeat = Math.max(1, Math.min(20, Math.floor(repeatRaw)));
        for (let i = 0; i < repeat; i++) {
          if (press === "hold") {
            await this.#shell(serial, ["input", "keyevent", "--longpress", String(code)]);
          } else if (press === "double") {
            await this.#shell(serial, ["input", "keyevent", String(code)]);
            await this.#shell(serial, ["input", "keyevent", String(code)]);
          } else {
            await this.#shell(serial, ["input", "keyevent", String(code)]);
          }
        }
        return { ok: true, key, keyCode: code, press, repeat };
      }

      case "apps": {
        const raw = await this.#shell(serial, ["pm", "list", "packages", "-3"]);
        const apps = raw
          .split(/\r?\n/)
          .map((line) => line.replace(/^package:/, "").trim())
          .filter(Boolean)
          .map((id) => ({ id, name: id }));
        return { apps };
      }

      case "launch": {
        const app = typeof args.app === "string" ? args.app.trim() : typeof args.url === "string" ? args.url.trim() : "";
        if (!app) throw new AndroidTvError("invalid_params", "launch requires args.app (package name or URL)");
        if (/^[a-zA-Z][a-zA-Z0-9+.-]*:\/\//.test(app)) {
          await this.#shell(serial, ["am", "start", "-a", "android.intent.action.VIEW", "-d", quoteAndroidShellArg(app)]);
          return { ok: true, launched: app, via: "view_intent" };
        }
        if (!/^[A-Za-z0-9._]+$/.test(app)) {
          throw new AndroidTvError("invalid_params", `invalid Android package name: ${app}`);
        }
        try {
          await this.#shell(serial, ["monkey", "-p", app, "-c", "android.intent.category.LEANBACK_LAUNCHER", "1"]);
          return { ok: true, launched: app, via: "leanback_launcher" };
        } catch {
          await this.#shell(serial, ["monkey", "-p", app, "-c", "android.intent.category.LAUNCHER", "1"]);
          return { ok: true, launched: app, via: "launcher" };
        }
      }

      case "playing": {
        const dump = await this.#shell(serial, ["dumpsys", "media_session"]).catch(() => "");
        const stateMatch = /state=PlaybackState \{state=(\d+)/.exec(dump);
        const metaMatch = /description=([^\n]+)/.exec(dump);
        return {
          ...(stateMatch ? { playbackState: Number(stateMatch[1]) } : {}),
          ...(metaMatch ? { description: metaMatch[1]!.trim() } : {}),
        };
      }

      case "volume": {
        if (args.mute === true || args.action === "mute") {
          await this.#shell(serial, ["input", "keyevent", "164"]);
          return { ok: true, muted: true };
        }
        if (args.action === "up") {
          await this.#shell(serial, ["input", "keyevent", "24"]);
          return { ok: true, direction: "up" };
        }
        if (args.action === "down") {
          await this.#shell(serial, ["input", "keyevent", "25"]);
          return { ok: true, direction: "down" };
        }
        if (typeof args.level === "number") {
          const level = Math.max(0, Math.min(100, Math.round(args.level)));
          // Query max volume on STREAM_MUSIC (3) to map 0..100 accurately
          const volDump = await this.#shell(serial, ["cmd", "media_session", "volume", "--stream", "3", "--get"]).catch(() => "");
          const volMatch = /in range \[(\d+)\.\.(\d+)\]/.exec(volDump);
          const maxVol = volMatch ? Number(volMatch[2]) : 15;
          const idx = Math.round((level / 100) * maxVol);
          await this.#shell(serial, ["cmd", "media_session", "volume", "--stream", "3", "--set", String(idx)]);
          return { ok: true, level, index: idx, max: maxVol };
        }
        const volDump = await this.#shell(serial, ["cmd", "media_session", "volume", "--stream", "3", "--get"]).catch(() => "");
        const volMatch = /volume is (\d+) in range \[(\d+)\.\.(\d+)\]/.exec(volDump);
        return volMatch
          ? { volume: Number(volMatch[1]), volumeMin: Number(volMatch[2]), volumeMax: Number(volMatch[3]) }
          : { volume: null };
      }

      case "keyboard": {
        const text = typeof args.text === "string" ? args.text : "";
        if (text === "") return { ok: true, text: "" };
        await this.#shell(serial, ["input", "text", escapeAdbInputText(text)]);
        return { ok: true, text };
      }

      case "play_url": {
        const url = typeof args.url === "string" ? args.url.trim() : "";
        if (!url) throw new AndroidTvError("invalid_params", "play_url requires args.url");
        await this.#shell(serial, ["am", "start", "-a", "android.intent.action.VIEW", "-d", quoteAndroidShellArg(url)]);
        return { ok: true, url };
      }

      case "screenshot":
        throw new AndroidTvError("invalid_params", "screenshot must be called via POST /screenshot");
    }
  }

  async close(): Promise<void> {
    const child = this.#serverChild;
    this.#serverChild = null;
    if (child && child.exitCode === null) {
      child.kill("SIGTERM");
    }
    if (this.#sockPath !== null) {
      await rm(this.#sockPath, { force: true }).catch(() => {});
    }
  }
}
