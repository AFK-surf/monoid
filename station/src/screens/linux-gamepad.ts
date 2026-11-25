// A Linux desktop view's game controllers: virtual Xbox 360 controllers through /dev/uinput (linux-gamepad.py, started
// as the view's first controller state comes), which every app on the machine reads as a real one; where the station
// may not write /dev/uinput (no `uinput` module, not in its group) they drive the desktop instead (gamepad-desktop.ts),
// through the view's own pointer and keys. Never an error the view ends on.
import { spawn, type ChildProcessWithoutNullStreams } from "node:child_process";
import { fileURLToPath } from "node:url";
import { log } from "../ops/log.ts";
import { PadDesktop } from "./gamepad-desktop.ts";
import { type Gamepad, type ScreenInput, gamepadReleased } from "./source.ts";

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
  /// "starting" until the helper said whether /dev/uinput opened; "desktop" for good once it did not.
  #mode: "none" | "starting" | "uinput" | "desktop" = "none";
  /// States that came while it started: the latest of each slot.
  readonly #early = new Map<number, Gamepad>();
  readonly #slots = new Set<number>();
  #ended = false;

  constructor(post: (e: ScreenInput) => Promise<void>, env: NodeJS.ProcessEnv, python = "python3", helper = helperPath()) {
    this.#post = post;
    this.#env = env;
    this.#python = python;
    this.#helper = helper;
  }

  async input(pad: Gamepad): Promise<void> {
    if (this.#ended) return;
    if (pad.connected) this.#slots.add(pad.index);
    else this.#slots.delete(pad.index);
    if (this.#mode === "none") this.#start();
    if (this.#mode === "starting") {
      this.#early.set(pad.index, pad);
      return;
    }
    if (this.#mode === "uinput") return this.#write(pad);
    for (const e of this.#desktop.ops(pad)) await this.#post(e);
  }

  #start() {
    this.#mode = "starting";
    let said = "";
    const child = spawn(this.#python, ["-u", this.#helper], { env: this.#env, stdio: ["pipe", "pipe", "pipe"] });
    this.#child = child;
    // (heard before its streams: one not started (ENFILE, EMFILE) has none, and its error told to none ends the station)
    child.on("error", () => this.#settle("desktop"));
    child.on("close", () => {
      if (this.#child === child) this.#child = null;
      this.#settle("desktop");
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
          log.info("screens", "no virtual controller: the desktop driven with it", { error: told.error.slice(0, 200) });
          this.#settle("desktop");
        }
      }
    });
  }

  /// The helper said whether its controllers are made: the states held meanwhile go that way.
  #settle(mode: "uinput" | "desktop") {
    if (this.#mode === "desktop" || (this.#mode === "uinput" && mode === "uinput")) return;
    this.#mode = mode;
    const early = [...this.#early.values()];
    this.#early.clear();
    for (const pad of early) void this.input(pad).catch(() => {});
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
    for (const index of [...this.#slots]) void this.input(gamepadReleased(index)).catch(() => {});
    if (this.#mode === "desktop") for (const e of this.#desktop.release()) void this.#post(e).catch(() => {});
    this.#ended = true;
    this.#child?.stdin?.end();
  }
}
