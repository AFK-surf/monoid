// A virtual microphone on a Linux desktop with PulseAudio or PipeWire's pulse server: a null sink the station plays
// into ("still.fail.Mic.Feed") and a source remapped from its monitor ("still.fail.Microphone") that any app can record,
// both made by `pactl load-module` when asked and unloaded, last first, when closed. Nothing is installed or needs an
// administrator; without `pactl` it says it is unavailable.
//
// Demand is read, never assumed: the recording streams (`pactl list source-outputs`) on that source or on the sink's
// monitor, not corked and not this process's own. The set of them changing (a consumer that stopped and another that
// started between two looks has a new index) or its being empty or not is a new epoch; an error is {active: false} with
// the error (virtual-mic spec §1.7's demand, as macOS and Windows give it). `pacat` plays the fed 48 kHz mono PCM16
// into the sink only while there is demand, at most 100 ms of it queued (the oldest dropped first).
import type { Writable } from "node:stream";
import { wall } from "../ops/fibers.ts";
import { endCommand, startCommand } from "../ops/processes.ts";
import type { MicDemand } from "../browser/mic.ts";

export type { MicDemand };

export const SINK_NAME = "stillfail_mic_sink";
export const SOURCE_NAME = "stillfail_mic";
export const MONITOR_NAME = `${SINK_NAME}.monitor`;
/// 100 ms of 48 kHz mono PCM16.
export const FEED_MOST_BYTES = 9600;

/// A command run to its end: its standard output, or a failure (`code: "ENOENT"` when the program is not there).
export type MicRunner = (program: string, args: string[]) => Promise<{ stdout: string }>;

/// The feeding process: written to, ended, heard ending.
export interface MicFeedProcess {
  /// False: the pipe is full; wait for `drain`.
  write(chunk: Uint8Array): boolean;
  onDrain(f: () => void): void;
  onExit(f: () => void): void;
  kill(): void;
}
export type MicFeedSpawner = (program: string, args: string[]) => MicFeedProcess;

/// How long a pactl command is given (the machine's time).
const COMMAND_MS = 5_000;

/// pactl and the like with their output, through ops/processes.ts (a group of their own, ended whole when late).
export const runCommand: MicRunner = (program, args) =>
  new Promise((resolve, reject) => {
    const child = startCommand(program, args, { stdio: ["ignore", "pipe", "pipe"], env: { ...process.env, LC_ALL: "C" } });
    let stdout = "", said = 0, failed: Error | null = null;
    const end = (why: Error) => {
      failed ??= why;
      endCommand(child, "SIGKILL");
    };
    const late = wall.after(COMMAND_MS, () => end(new Error(`${program} took more than ${COMMAND_MS} ms`)));
    // (heard before its streams: one not started (ENFILE, EMFILE) has none, and its error told to none ends the station)
    child.on("error", (e) => {
      late();
      reject(failed ?? e);
    });
    child.on("close", (code, signal) => {
      late();
      if (failed) reject(failed);
      else if (code === 0) resolve({ stdout });
      else reject(new Error(`${program} ${args[0] ?? ""} ended with ${code ?? signal}`));
    });
    child.stdout?.on("data", (chunk: Buffer) => {
      said += chunk.length;
      if (said > 4 * 1024 * 1024) end(new Error(`${program} said too much`));
      else stdout += chunk.toString("utf8");
    });
    child.stderr?.resume();
  });

export const spawnFeed: MicFeedSpawner = (program, args) => {
  const child = startCommand(program, args, { stdio: ["pipe", "ignore", "ignore"] });
  // Heard at once, whenever its end is asked for (`onExit`): one not started (ENFILE, EMFILE) has no stdin, and its
  // error told to none ends the station. Written to then: dropped, its end coming.
  child.on("error", () => {});
  const stdin = child.stdin as Writable | null | undefined;
  stdin?.on("error", () => {});
  return {
    write: (chunk) => stdin?.write(chunk) ?? true,
    onDrain: (f) => void stdin?.on("drain", f),
    onExit: (f) => {
      child.once("close", f);
      child.once("error", f);
    },
    kill: () => {
      stdin?.destroy();
      endCommand(child, "SIGTERM");
    },
  };
};

/// One recording stream as pactl says it.
export type SourceOutput = { index: number; source: string; corked: boolean; pid: number | null };

/// `pactl -f json list source-outputs`: its `source` is the source's index, named through `names`.
export function parseSourceOutputsJson(text: string, names: Map<string, string>): SourceOutput[] {
  const list = JSON.parse(text);
  if (!Array.isArray(list)) throw new Error("pactl's source outputs are not a list");
  return list.map((o: any) => {
    const index = Number(o?.index);
    if (!Number.isSafeInteger(index)) throw new Error("a source output without an index");
    const source = names.get(String(o.source)) ?? String(o.source);
    const pid = Number.parseInt(String(o?.properties?.["application.process.id"] ?? ""), 10);
    return { index, source, corked: o.corked === true || o.corked === "yes", pid: Number.isSafeInteger(pid) ? pid : null };
  });
}

/// `pactl list source-outputs` in the C locale.
export function parseSourceOutputsText(text: string, names: Map<string, string>): SourceOutput[] {
  const out: SourceOutput[] = [];
  let cur: { index: number; source: string; corked: boolean; pid: number | null } | null = null;
  for (const line of text.split("\n")) {
    const head = /^Source Output #(\d+)\s*$/.exec(line);
    if (head) {
      if (cur) out.push(cur);
      cur = { index: Number(head[1]), source: "", corked: false, pid: null };
      continue;
    }
    if (!cur) continue;
    const t = line.trim();
    let m: RegExpExecArray | null;
    if ((m = /^Source:\s*(.+)$/.exec(t))) cur.source = names.get(m[1]!) ?? m[1]!;
    else if ((m = /^Corked:\s*(\S+)/.exec(t))) cur.corked = m[1] === "yes";
    else if ((m = /^application\.process\.id\s*=\s*"(\d+)"/.exec(t))) cur.pid = Number(m[1]);
  }
  if (cur) out.push(cur);
  return out;
}

/// `pactl list short sources`: index → name.
export function parseShortSources(text: string): Map<string, string> {
  const names = new Map<string, string>();
  for (const line of text.split("\n")) {
    const [index, name] = line.split("\t");
    if (index && name && /^\d+$/.test(index)) names.set(index, name);
  }
  return names;
}

/// `pactl list short modules`: the ids of modules of ours left loaded (a station that ended without unloading).
export function ourModules(text: string): number[] {
  const ids: number[] = [];
  for (const line of text.split("\n")) {
    const [id, , args = ""] = line.split("\t");
    if (id && /^\d+$/.test(id) && (args.includes(`sink_name=${SINK_NAME}`) || args.includes(`source_name=${SOURCE_NAME}`))) ids.push(Number(id));
  }
  return ids;
}

/// The recording streams that are demand: on our source or the sink's monitor, running, not `self`'s.
export function consumers(outputs: SourceOutput[], self: number): number[] {
  return outputs
    .filter((o) => (o.source === SOURCE_NAME || o.source === MONITOR_NAME) && !o.corked && o.pid !== self)
    .map((o) => o.index)
    .sort((a, b) => a - b);
}

const unavailable = (e: any) => (e?.code === "ENOENT" ? "unavailable: pactl is not installed" : String(e?.message ?? e));

export class LinuxVirtualMic {
  readonly #run: MicRunner;
  readonly #spawn: MicFeedSpawner;
  readonly #pid: number;
  readonly #onDemand?: (demand: MicDemand) => void;
  #modules: number[] = [];
  #demand: MicDemand = { active: false, epoch: 0 };
  #seen = "";
  #feed: MicFeedProcess | null = null;
  #queue: Uint8Array[] = [];
  #queued = 0;
  #blocked = false;
  #closed = false;
  /// Sent to the feed and dropped from the queue (counted for tests and stats).
  dropped = 0;

  constructor(o: { run?: MicRunner; spawnFeed?: MicFeedSpawner; pid?: number; onDemand?: (demand: MicDemand) => void } = {}) {
    this.#run = o.run ?? runCommand;
    this.#spawn = o.spawnFeed ?? spawnFeed;
    this.#pid = o.pid ?? process.pid;
    this.#onDemand = o.onDemand;
  }

  get demand(): MicDemand {
    return this.#demand;
  }
  get modules(): readonly number[] {
    return this.#modules;
  }
  get feeding(): boolean {
    return this.#feed !== null;
  }

  /// Makes the sink and the source (after unloading any of ours left loaded); an error when pactl is missing or fails,
  /// with nothing of ours left loaded.
  async open(): Promise<{ ok: true } | { ok: false; error: string }> {
    if (this.#modules.length) return { ok: true };
    try {
      const left = ourModules((await this.#run("pactl", ["list", "short", "modules"])).stdout);
      for (const id of left.reverse()) await this.#run("pactl", ["unload-module", String(id)]).catch(() => {});
      const sink = await this.#load(["module-null-sink", `sink_name=${SINK_NAME}`, "sink_properties=device.description=still.fail.Mic.Feed", "rate=48000", "channels=1"]);
      this.#modules.push(sink);
      const source = await this.#load(["module-remap-source", `master=${MONITOR_NAME}`, `source_name=${SOURCE_NAME}`, "source_properties=device.description=still.fail.Microphone"]);
      this.#modules.push(source);
      return { ok: true };
    } catch (e) {
      await this.#unload();
      return { ok: false, error: unavailable(e) };
    }
  }

  async #load(args: string[]): Promise<number> {
    const { stdout } = await this.#run("pactl", ["load-module", ...args]);
    const id = Number.parseInt(stdout.trim(), 10);
    if (!Number.isSafeInteger(id)) throw new Error(`pactl load-module ${args[0]} said no module id`);
    return id;
  }

  async #unload(): Promise<void> {
    const ids = this.#modules.splice(0).reverse();
    for (const id of ids) await this.#run("pactl", ["unload-module", String(id)]).catch(() => {});
  }

  /// Looks at who records, once: the demand now, with its epoch moved on when it changed. The feed follows it.
  async sample(): Promise<MicDemand> {
    let next: { active: boolean; seen: string; error?: string };
    if (this.#closed || this.#modules.length === 0) next = { active: false, seen: "", error: "the virtual microphone is not open" };
    else {
      try {
        const names = parseShortSources((await this.#run("pactl", ["list", "short", "sources"])).stdout);
        let outputs: SourceOutput[];
        try {
          outputs = parseSourceOutputsJson((await this.#run("pactl", ["-f", "json", "list", "source-outputs"])).stdout, names);
        } catch (e: any) {
          if (e?.code === "ENOENT") throw e;
          // (a pactl before 16 has no JSON)
          outputs = parseSourceOutputsText((await this.#run("pactl", ["list", "source-outputs"])).stdout, names);
        }
        if (![...names.values()].includes(SOURCE_NAME)) throw new Error("the virtual microphone's source is gone");
        const ids = consumers(outputs, this.#pid);
        next = { active: ids.length > 0, seen: ids.join(",") };
      } catch (e) {
        next = { active: false, seen: "", error: unavailable(e) };
      }
    }
    const changed = next.active !== this.#demand.active || next.seen !== this.#seen;
    this.#seen = next.seen;
    if (changed) {
      // A different set while active is another lifetime: inactive first, then active again.
      if (next.active && this.#demand.active) this.#set({ active: false, epoch: this.#demand.epoch + 1 });
      this.#set({ active: next.active, epoch: this.#demand.epoch + 1, ...(next.active ? { device: SOURCE_NAME } : {}) });
    }
    if (next.error !== undefined) this.#demand = { active: false, epoch: this.#demand.epoch, error: next.error };
    else if (!next.active) this.#demand = { active: false, epoch: this.#demand.epoch };
    return this.#demand;
  }

  #set(d: MicDemand) {
    this.#demand = d;
    if (d.active) this.#startFeed();
    else this.#stopFeed();
    this.#onDemand?.(d);
  }

  #startFeed() {
    if (this.#feed || this.#closed) return;
    const feed = this.#spawn("pacat", ["--playback", `--device=${SINK_NAME}`, "--format=s16le", "--rate=48000", "--channels=1", "--latency-msec=20"]);
    this.#feed = feed;
    this.#blocked = false;
    feed.onDrain(() => {
      if (this.#feed !== feed) return;
      this.#blocked = false;
      this.#pump();
    });
    feed.onExit(() => {
      if (this.#feed !== feed) return;
      this.#feed = null;
      this.#clear();
    });
  }

  #stopFeed() {
    const feed = this.#feed;
    this.#feed = null;
    this.#clear();
    feed?.kill();
  }

  #clear() {
    this.#queue = [];
    this.#queued = 0;
    this.#blocked = false;
  }

  /// 48 kHz mono PCM16 for the sink; dropped at once with no demand.
  feedPcm16(pcm16le: Uint8Array): void {
    if (!this.#demand.active || this.#feed === null || pcm16le.byteLength === 0) return;
    this.#queue.push(pcm16le);
    this.#queued += pcm16le.byteLength;
    while (this.#queued > FEED_MOST_BYTES && this.#queue.length > 1) {
      const old = this.#queue.shift()!;
      this.#queued -= old.byteLength;
      this.dropped += old.byteLength;
    }
    this.#pump();
  }

  /// Bytes waiting to be written to the feed.
  get queuedBytes(): number {
    return this.#queued;
  }

  #pump() {
    const feed = this.#feed;
    while (feed && !this.#blocked && this.#queue.length) {
      const chunk = this.#queue.shift()!;
      this.#queued -= chunk.byteLength;
      if (!feed.write(chunk)) this.#blocked = true;
    }
  }

  /// Stops the feed and unloads the modules, the source first.
  async close(): Promise<void> {
    if (this.#closed) return;
    this.#closed = true;
    const was = this.#demand.active;
    this.#stopFeed();
    await this.#unload();
    if (was) {
      this.#demand = { active: false, epoch: this.#demand.epoch + 1 };
      this.#onDemand?.(this.#demand);
    }
  }
}

/// How often a driven Linux view looks at who records its virtual microphone.
export const MIC_SAMPLE_MS = 250;

/// A Linux desktop view's `watchMic`/`feedMic` (x11-desktop.ts, linux-portal.ts): the virtual microphone opened as the
/// driver watches it, said unavailable where it cannot be (no pactl, it failed), else said at once and again as who
/// records it changes, looked at every `MIC_SAMPLE_MS`; `stop` ends the looking and unloads it.
export function watchLinuxMic(
  heard: (mic: { available: boolean; active: boolean; epoch: number }) => void,
  o: { make?: () => LinuxVirtualMic; every?: (ms: number, f: () => void) => () => void } = {},
): { stop(): void; feed(pcm16le: Uint8Array, epoch: number): void } {
  const mic = o.make?.() ?? new LinuxVirtualMic();
  const every = o.every ?? wall.every;
  let stopped = false;
  let unsample = () => {};
  let told: string | null = null;
  const tell = (d: MicDemand) => {
    const next = { available: d.error === undefined, active: d.active && d.error === undefined, epoch: d.epoch >>> 0 };
    const key = `${next.available}/${next.active}/${next.epoch}`;
    if (key === told) return;
    told = key;
    heard(next);
  };
  void mic.open().then((opened) => {
    if (stopped) return void mic.close();
    if (!opened.ok) {
      told = "false/false/0";
      return heard({ available: false, active: false, epoch: 0 });
    }
    tell(mic.demand);
    let looking = false;
    // timer: local machine sampling (PulseAudio source-outputs recording the virtual mic)
    unsample = every(MIC_SAMPLE_MS, () => { // timer: local machine sampling (PulseAudio source-outputs recording the virtual mic)
      if (looking || stopped) return;
      looking = true;
      void mic.sample().then(
        (d) => {
          looking = false;
          if (!stopped) tell(d);
        },
        () => (looking = false),
      );
    });
  });
  return {
    stop() {
      if (stopped) return;
      stopped = true;
      unsample();
      void mic.close();
    },
    feed(pcm16le, epoch) {
      const d = mic.demand;
      if (!stopped && d.active && d.epoch >>> 0 === epoch) mic.feedPcm16(pcm16le);
    },
  };
}

/// What a Linux desktop view holds of its virtual microphone: one watch at a time, stopped as the view ends.
export class LinuxMicPart {
  #w: ReturnType<typeof watchLinuxMic> | null = null;
  readonly #make?: () => LinuxVirtualMic;
  constructor(make?: () => LinuxVirtualMic) {
    this.#make = make;
  }
  watch(heard: (mic: { available: boolean; active: boolean; epoch: number }) => void): () => void {
    this.stop();
    const w = watchLinuxMic(heard, this.#make ? { make: this.#make } : {});
    this.#w = w;
    return () => {
      if (this.#w === w) this.stop();
    };
  }
  feed(pcm16le: Uint8Array, epoch: number): void {
    this.#w?.feed(pcm16le, epoch);
  }
  stop(): void {
    const w = this.#w;
    this.#w = null;
    w?.stop();
  }
}
