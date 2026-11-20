// Native Linux desktop source backed by `stillfail-screen-linux` (`station/native/screen-linux`).
// Reuses `HelperView` + `LastingView` over the 5-byte binary pipe protocol, while preserving
// `LinuxGamepads` and `LinuxMicPart` for controllers and virtual microphone.
import { type ChildProcess, spawn } from "node:child_process";
import { existsSync } from "node:fs";
import { hostname } from "node:os";
import { fileURLToPath } from "node:url";
import { wall } from "../ops/fibers.ts";
import { log } from "../ops/log.ts";
import { HelperView } from "./desktop.ts";
import { ScreenRefused } from "./hub.ts";
import { LinuxGamepads } from "./linux-gamepad.ts";
import { LinuxInput } from "./linux-input.ts";
import { LinuxMicPart } from "./linux-mic.ts";
import {
  type Codec, type Frame, type Region, type ScreenAccess, type ScreenCursor, type ScreenInput,
  type ScreenMic, type ScreenSource, type ScreenVideo, type ScreenView, type ViewOptions, codecFor,
} from "./source.ts";
import { LastingView, childPipe } from "./win-desktop.ts";

export const LINUX_SCREEN_BINARY = "stillfail-screen-linux";

const foundCache = new Map<string, string>();

/// Locate `stillfail-screen-linux`: STILLFAIL_SCREEN_LINUX, beside station code, or built in checkout.
export function linuxScreenBinary(env: NodeJS.ProcessEnv = process.env): string | null {
  const key = env.STILLFAIL_SCREEN_LINUX ?? "";
  const kept = foundCache.get(key);
  if (kept !== undefined) return kept;
  const candidates = [
    env.STILLFAIL_SCREEN_LINUX,
    fileURLToPath(new URL(`./${LINUX_SCREEN_BINARY}`, import.meta.url)),
    fileURLToPath(new URL(`../../native/screen-linux/target/release/${LINUX_SCREEN_BINARY}`, import.meta.url)),
  ];
  const found = candidates.find((p) => p && existsSync(p)) ?? null; // sync: read once, before the station serves (services.ts, as it makes the desktop's screen)
  if (found !== null) foundCache.set(key, found);
  return found;
}

export type LinuxNativeStart = (binary: string, args: string[], env: NodeJS.ProcessEnv) => ChildProcess;
const defaultStart: LinuxNativeStart = (binary, args, env) =>
  spawn(binary, args, { env, stdio: ["pipe", "pipe", "ignore"] });

export type LinuxNativeStatus = {
  available: boolean;
  backend: "x11" | "wayland" | null;
  display: { width: number; height: number };
};

export type LinuxNativeOptions = {
  binary: string | null;
  changed: () => void;
  title?: () => string;
  env?: NodeJS.ProcessEnv;
  start?: LinuxNativeStart;
};

const FRESH_MS = 2_000;
const STATUS_TIMEOUT_MS = 3_000;

export class LinuxNativeDesktop implements ScreenSource {
  readonly id = "desktop";
  readonly kind = "desktop" as const;
  readonly #o: LinuxNativeOptions;
  readonly #views = new Set<LinuxNativeView>();
  #status: LinuxNativeStatus = { available: false, backend: null, display: { width: 0, height: 0 } };
  #looked = 0;
  #looking: Promise<void> | null = null;

  constructor(options: LinuxNativeOptions) {
    this.#o = options;
  }

  title(): string {
    return this.#o.title?.() ?? hostname();
  }

  size(): { width: number; height: number } {
    return { ...this.#status.display };
  }

  available(): boolean {
    return this.#o.binary !== null && this.#status.available;
  }

  backend(): "x11" | "wayland" | null {
    return this.#status.backend;
  }

  access(): ScreenAccess {
    if (this.#o.binary === null) return { capture: false, control: false, unsupported: "helper" };
    if (!this.#status.available) return { capture: false, control: false, reason: "linuxUnavailable" };
    return { capture: true, control: true };
  }

  refresh(force = false): Promise<void> {
    if (this.#o.binary === null) {
      this.#status = { available: false, backend: null, display: { width: 0, height: 0 } };
      return Promise.resolve();
    }
    if (!force && wall.now() - this.#looked < FRESH_MS) return Promise.resolve();
    this.#looking ??= this.#askStatus()
      .then(
        (told) => {
          const ok = told?.ok === true && told?.capture === true;
          const backend = told?.backend === "wayland" ? "wayland" : told?.backend === "x11" ? "x11" : null;
          const width = ok ? Number(told?.display?.width) || 0 : 0;
          const height = ok ? Number(told?.display?.height) || 0 : 0;
          const next: LinuxNativeStatus = { available: ok && width >= 2 && height >= 2, backend, display: { width, height } };
          const prev = this.#status;
          this.#status = next;
          if (
            prev.available !== next.available ||
            prev.backend !== next.backend ||
            prev.display.width !== next.display.width ||
            prev.display.height !== next.display.height
          ) {
            this.#o.changed();
          }
        },
        (e) => {
          const prev = this.#status;
          this.#status = { available: false, backend: null, display: { width: 0, height: 0 } };
          if (prev.available) this.#o.changed();
          log.warn("screens", "stillfail-screen-linux status failed", { error: (e as Error).message });
        },
      )
      .finally(() => {
        this.#looked = wall.now();
        this.#looking = null;
      });
    return this.#looking;
  }

  #askStatus(): Promise<any> {
    const binary = this.#o.binary;
    if (binary === null) return Promise.reject(new Error("stillfail-screen-linux is not there"));
    const env = this.#o.env ?? process.env;
    return new Promise((resolve, reject) => {
      const child = (this.#o.start ?? defaultStart)(binary, ["status"], env);
      let said = "";
      const unarm = wall.after(STATUS_TIMEOUT_MS, () => child.kill());
      child.stdout!.setEncoding("utf8").on("data", (chunk: string) => (said += chunk));
      let finished = false;
      const done = (error?: Error) => {
        if (finished) return;
        finished = true;
        unarm();
        try {
          if (error) throw error;
          resolve(JSON.parse(said));
        } catch (e) {
          reject(e as Error);
        }
      };
      child.on("error", done);
      child.on("close", () => done());
      child.stdin?.end();
    });
  }

  async open(options: ViewOptions): Promise<ScreenView> {
    const binary = this.#o.binary;
    if (binary === null) throw new ScreenRefused(501, "station.screen.noHelper", {}, this.access());
    const codec = codecFor(options, ["h264", "jpeg"]);
    if (codec === undefined) throw new ScreenRefused(415, "station.screen.codec", { codec: "H.264, JPEG" });
    await this.refresh();
    if (!this.#status.available) throw new ScreenRefused(503, "station.screen.linuxUnavailable", {}, this.access());
    const input = new LinuxInput();
    const ask = {
      codec,
      maxWidth: options.maxWidth,
      maxHeight: options.maxHeight,
      ...(options.bitrate ? { bitrate: Math.round(options.bitrate) } : {}),
      ...(options.fps ? { fps: options.fps } : {}),
    };
    let first: HelperView;
    try {
      first = await this.#start(binary, ask, input);
    } catch (error) {
      throw new ScreenRefused(503, "station.screen.failed", { said: (error as Error).message });
    }
    const env = this.#o.env ?? process.env;
    let view: LinuxNativeView | null = null;
    const lasting = new LastingView(first, () => this.#start(binary, ask, input), () => view?.close());
    view = new LinuxNativeView(lasting, env, () => this.#views.delete(view!));
    this.#views.add(view);
    return view;
  }

  async #start(
    binary: string,
    ask: { codec: Codec; maxWidth: number; maxHeight: number; bitrate?: number; fps?: number },
    input: LinuxInput,
  ): Promise<HelperView> {
    const env = this.#o.env ?? process.env;
    const child = (this.#o.start ?? defaultStart)(binary, ["view"], env);
    child.stdin!.write(`${JSON.stringify(ask)}\n`);
    const capture = this.#status.backend === "wayland" ? "Wayland (wlr-screencopy)" : "X11 (MIT-SHM+XDamage)";
    const view = new HelperView(ask.codec, childPipe(child), () => {}, input, capture, false, false);
    try {
      await view.ready;
      return view;
    } catch (error) {
      view.close();
      throw error;
    }
  }

  close(): Promise<void> {
    for (const view of [...this.#views]) view.close();
    return Promise.resolve();
  }
}

/// Wraps `LastingView` with Linux-specific gamepad (`LinuxGamepads`) and virtual mic (`LinuxMicPart`).
class LinuxNativeView implements ScreenView {
  readonly #inner: LastingView;
  readonly #pads: LinuxGamepads;
  readonly #mic = new LinuxMicPart();
  readonly #gone: () => void;
  #ended = false;

  constructor(inner: LastingView, env: NodeJS.ProcessEnv, gone: () => void) {
    this.#inner = inner;
    this.#pads = new LinuxGamepads((e) => this.input(e), env);
    this.#gone = gone;
  }

  next(): Promise<Frame | null> { return this.#inner.next(); }
  keyframe() { this.#inner.keyframe(); }
  video(): ScreenVideo { return this.#inner.video(); }
  rate(bitsPerSecond: number) { this.#inner.rate(bitsPerSecond); }
  bounds(maxWidth: number, maxHeight: number, region?: Region | null) { this.#inner.bounds(maxWidth, maxHeight, region); }
  regions(): boolean { return this.#inner.regions(); }
  watchCursor(heard: (cursor: ScreenCursor) => void): () => void { return this.#inner.watchCursor(heard); }
  cursorImage(shape: string): Uint8Array | undefined { return this.#inner.cursorImage(shape); }
  watchMic(heard: (mic: ScreenMic) => void): () => void { return this.#ended ? () => {} : this.#mic.watch(heard); }
  feedMic(pcm16le: Uint8Array, epoch: number) { this.#mic.feed(pcm16le, epoch); }
  input(event: ScreenInput): Promise<void> {
    if (event.t === "gamepad") return this.#pads.input(event);
    return this.#inner.input(event);
  }
  close() {
    if (this.#ended) return;
    this.#ended = true;
    this.#pads.close();
    this.#mic.stop();
    this.#inner.close();
    this.#gone();
  }
}
