// A Linux desktop view's game controllers: virtual Xbox 360 controllers through /dev/uinput (linux-gamepad.py, started
// as the view's first controller state comes), which every app on the machine reads as a real one; when the user
// explicitly enables mouse/keyboard emulation (`allowMouse` / `setMouse(true)`), controllers drive the desktop instead
// (gamepad-desktop.ts). When mouse emulation is off (default) and /dev/uinput is unavailable, controller input is
// dropped rather than silently hijacking the mouse. Never an error the view ends on.
import { spawn, type ChildProcessWithoutNullStreams } from "node:child_process";
import { access, constants } from "node:fs/promises";
import { fileURLToPath } from "node:url";
import { log } from "../ops/log.ts";
import { PadDesktop } from "./gamepad-desktop.ts";
import { type Gamepad, type ScreenGamepad, type ScreenInput, gamepadReleased } from "./source.ts";

/// Beside the source in development, beside the station's main.js in its release.
function helperPath(): string {
  return fileURLToPath(import.meta.url.endsWith(".ts") ? new URL("../../assets/screens/linux-gamepad.py", import.meta.url) : new URL("./linux-gamepad.py", import.meta.url));
}

export class LinuxGamepads {
  readonly #python: string;
  readonly #helper: string;
  readonly #env: NodeJS.ProcessEnv;
  /// How the view posts what a controller drives on the desktop instead.
  readonly #post: (e: ScreenInput) => Promise<void>;
  readonly #desktop = new PadDesktop();
  #child: ChildProcessWithoutNullStreams | null = null;
  /// "starting" until the helper said whether /dev/uinput opened; "unavailable" once it did not.
  #mode: "none" | "starting" | "uinput" | "unavailable" = "none";
  /// Explicit opt-in for desktop mouse/keyboard emulation.
  #allowMouse: boolean;
  /// Known native uinput availability (null until probed or helper reports).
  #native: boolean | null = null;
  #heard: ((pad: ScreenGamepad) => void) | null = null;
  /// States that came while it started: the latest of each slot.
  readonly #early = new Map<number, Gamepad>();
  readonly #slots = new Set<number>();
  #ended = false;

  constructor(post: (e: ScreenInput) => Promise<void>, env: NodeJS.ProcessEnv, allowMouse = false, python = "python3", helper = helperPath()) {
    this.#post = post;
    this.#env = env;
    this.#allowMouse = allowMouse;
    this.#python = python;
    this.#helper = helper;
  }

  #status(): ScreenGamepad {
    const native = this.#native === true;
    return { native, driver: native ? "uinput" : "missing", mouse: this.#allowMouse };
  }

  #emit() {
    if (!this.#ended && this.#native !== null) this.#heard?.(this.#status());
  }

  watch(heard: (pad: ScreenGamepad) => void): () => void {
    this.#heard = heard;
    if (this.#native !== null) {
      heard(this.#status());
    } else {
      void access("/dev/uinput", constants.W_OK).then(
        () => {
          if (this.#native === null) this.#native = true;
          this.#emit();
        },
        () => {
          if (this.#native === null) this.#native = false;
          this.#emit();
        },
      );
    }
    return () => {
      if (this.#heard === heard) this.#heard = null;
    };
  }

  async setMouse(on: boolean): Promise<void> {
    if (this.#ended) return;
    if (this.#allowMouse !== on) {
      if (this.#allowMouse) {
        for (const e of this.#desktop.release()) await this.#post(e);
      } else if (this.#mode === "uinput") {
        for (const index of [...this.#slots]) this.#write(gamepadReleased(index));
        this.#slots.clear();
      }
      this.#allowMouse = on;
    }
    if (this.#native === null) {
      this.#native = await access("/dev/uinput", constants.W_OK).then(() => true, () => false);
    }
    this.#emit();
  }

  async input(pad: Gamepad): Promise<void> {
    if (this.#ended) return;
    if (pad.connected) this.#slots.add(pad.index);
    else this.#slots.delete(pad.index);
    if (this.#allowMouse) {
      for (const e of this.#desktop.ops(pad)) await this.#post(e);
      return;
    }
    if (this.#mode === "none") this.#start();
    if (this.#mode === "starting") {
      this.#early.set(pad.index, pad);
      return;
    }
    if (this.#mode === "uinput") return this.#write(pad);
  }

  #start() {
    this.#mode = "starting";
    let said = "";
    const child = spawn(this.#python, ["-u", this.#helper], { env: this.#env, stdio: ["pipe", "pipe", "pipe"] });
    this.#child = child;
    // (heard before its streams: one not started (ENFILE, EMFILE) has none, and its error told to none ends the station)
    child.on("error", () => this.#settle("unavailable"));
    child.on("close", () => {
      if (this.#child === child) this.#child = null;
      this.#settle("unavailable");
    });
    child.stdin?.on("error", () => {});
    child.stderr?.on("data", () => {});
    child.stdout?.on("data", (data: Buffer) => {
      said += data.toString();
      for (let at = said.indexOf("\n"); at >= 0; at = said.indexOf("\n")) {
        const line = said.slice(0, at);
        said = said.slice(at + 1);
        let told: any = null;
        try {
          told = JSON.parse(line);
        } catch {}
        if (told?.ready === true && this.#mode === "starting") this.#settle("uinput");
        else if (typeof told?.error === "string") {
          log.info("screens", "no virtual controller (/dev/uinput unavailable)", { error: told.error.slice(0, 200) });
          this.#settle("unavailable");
        }
      }
    });
  }

  /// The helper said whether its controllers are made: the states held meanwhile go that way.
  #settle(mode: "uinput" | "unavailable") {
    if (this.#mode === "unavailable" || (this.#mode === "uinput" && mode === "uinput")) return;
    this.#mode = mode;
    this.#native = mode === "uinput";
    this.#emit();
    const early = [...this.#early.values()];
    this.#early.clear();
    if (mode === "uinput") for (const pad of early) void this.input(pad).catch(() => {});
  }

  #write(pad: Gamepad) {
    const child = this.#child;
    if (child === null || !child.stdin || child.stdin.destroyed) return;
    const { t: _, ...state } = pad;
    child.stdin.write(`${JSON.stringify(state)}\n`);
  }

  /// The view ends: every controller let go of (the helper destroys its devices as its stdin ends).
  close(): void {
    if (this.#ended) return;
    if (this.#mode === "uinput") for (const index of [...this.#slots]) this.#write(gamepadReleased(index));
    if (this.#allowMouse) for (const e of this.#desktop.release()) void this.#post(e).catch(() => {});
    this.#ended = true;
    this.#heard = null;
    this.#child?.stdin?.end();
  }
}
