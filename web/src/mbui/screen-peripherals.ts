// What a screen's view takes of this browser's own devices while the app drives it (apps/mbui sfpages' screen.mbt): the
// person's microphone into the screen's virtual one (`screen.mic`), game controllers (`screen.input` `gamepad`), the
// pointer held by an app there (Pointer Lock: `screen.input` moves with `relative`) and, in full screen, the keys the
// browser would take for itself (Keyboard Lock). The app's mbui draws on a canvas and has no reach to these: this page
// reads what the app and its core say to each other (core.ts `send`, `toApp`) to know which views drive what, and
// tells the core itself, under ids of its own.
//
// The microphone is open only while a view drives its screen, the person shared it (`screen.micOn`) and something on
// the screen records its virtual microphone now (the state's `mic.active`): as soon as any of those stops it is let go
// of at once, in the same turn, so the browser's and the system's recording marks go out with it.

/// The ids of this page's own calls to the core for the views (past the app's, HANDOVER's and the reports'): their
/// answers are not the app's (core.ts toApp lets go of every id from REPORT_FIRST on).
export const PERIPHERAL_FIRST = 2 ** 31 + 2 ** 30;

/// 48 kHz mono, 20 ms a packet: 960 samples, 1920 bytes of s16le.
export const MIC_RATE = 48_000;
export const MIC_SAMPLES = 960;

/// How far a stick moves before it counts (a controller at rest drifts this far).
export const DEAD_ZONE = 0.06;

/// The most a controller's state is sent a second while it does not change (a stick held over).
export const PAD_MS = 1000 / 60;

/// A view of a screen as the app and its core said it.
export type ViewSaid = {
  view: string;
  phase: string;
  control: boolean;
  /// the screen's virtual microphone (none while only looking, or from a station before it)
  mic: { available: boolean; active: boolean; epoch: number } | null;
  /// an app there holds the pointer
  pointerLock: boolean;
  /// the person shares their microphone into it (`screen.micOn`), as the app last said
  micOn: boolean;
  /// where the app last said the pointer is on it (0..1)
  at: { x: number; y: number };
};

const isObject = (v: unknown): v is Record<string, unknown> => typeof v === "object" && v !== null;

/// Whether `v` drives its screen now: live, and driven by this viewer.
export const driving = (v: ViewSaid): boolean => v.phase === "live" && v.control;

/// The views open, by the app's call that opened each (`screen.view`), as the messages between the app and the core
/// say them. Nothing here touches a device: what the page does follows from it (ScreenPeripherals).
export class ScreenViews {
  readonly byCall = new Map<number, ViewSaid>();
  /// the view the app last sent input to (a controller's go there)
  last: string | null = null;

  /// A message of the app's to the core. Whether it changed what the views say.
  fromApp(m: unknown): boolean {
    if (!isObject(m) || typeof m.id !== "number") return false;
    if (m.cancel === true) return this.byCall.delete(m.id);
    const p = m.params;
    if (!isObject(p) || typeof p.view !== "string") return false;
    if (m.call === "screen.view") {
      this.byCall.set(m.id, { view: p.view, phase: "connecting", control: false, mic: null, pointerLock: false, micOn: false, at: { x: 0.5, y: 0.5 } });
      return true;
    }
    const v = this.of(p.view);
    if (!v) return false;
    if (m.call === "screen.micOn" && typeof p.on === "boolean") {
      v.micOn = p.on;
      return true;
    }
    if (m.call === "screen.input" && isObject(p.input) && p.input.t === "pointer") {
      this.last = v.view;
      const { x, y } = p.input;
      if (typeof x === "number" && typeof y === "number") v.at = { x, y };
    }
    return false;
  }

  /// A message of the core's to the app: a view's state taken, or its call over. Whether it changed what they say.
  fromCore(m: unknown): boolean {
    if (!isObject(m) || typeof m.id !== "number") return false;
    const v = this.byCall.get(m.id);
    if (!v) return false;
    if ("ok" in m || "error" in m) return this.byCall.delete(m.id);
    const s = isObject(m.value) ? m.value.state : undefined;
    if (!isObject(s)) return false;
    v.phase = typeof s.phase === "string" ? s.phase : v.phase;
    v.control = s.control === true;
    const mic = s.mic;
    v.mic = isObject(mic) ? { available: mic.available === true, active: mic.available === true && mic.active === true, epoch: typeof mic.epoch === "number" ? mic.epoch : 0 } : null;
    v.pointerLock = s.pointerLock === true;
    return true;
  }

  of(view: string): ViewSaid | undefined {
    for (const v of this.byCall.values()) if (v.view === view) return v;
    return undefined;
  }

  /// The view whose screen this device's microphone goes to now, and the recording's epoch: driving, shared and
  /// recorded there (the first such, one at a time); none else.
  micFor(): { view: string; epoch: number } | null {
    for (const v of this.byCall.values()) {
      if (driving(v) && v.micOn && v.mic?.available === true && v.mic.active) return { view: v.view, epoch: v.mic.epoch };
    }
    return null;
  }

  /// The views driven now.
  driven(): ViewSaid[] {
    return [...this.byCall.values()].filter(driving);
  }

  /// The view a controller drives now: the one last given input of those driven, else the last opened of them.
  padView(): string | null {
    const driven = this.driven();
    if (driven.length === 0) return null;
    return driven.find((v) => v.view === this.last)?.view ?? driven[driven.length - 1]!.view;
  }

  /// The view whose app holds the pointer now, driven.
  lockView(): ViewSaid | null {
    return this.driven().find((v) => v.pointerLock) ?? null;
  }
}

/// A microphone's samples (-1..1, 48 kHz mono) cut into packets of MIC_SAMPLES as s16le, each handed to `out` as it is
/// whole.
export class PcmChunker {
  #buf = new Int16Array(MIC_SAMPLES);
  #n = 0;
  readonly #out: (pcm: Uint8Array) => void;
  constructor(out: (pcm: Uint8Array) => void) {
    this.#out = out;
  }

  push(samples: Float32Array): void {
    for (let i = 0; i < samples.length; i++) {
      const s = samples[i]!;
      const c = Number.isFinite(s) ? Math.max(-1, Math.min(1, s)) : 0;
      this.#buf[this.#n++] = c < 0 ? Math.round(c * 0x8000) : Math.round(c * 0x7fff);
      if (this.#n === MIC_SAMPLES) {
        const bytes = new Uint8Array(MIC_SAMPLES * 2);
        const d = new DataView(bytes.buffer);
        for (let k = 0; k < MIC_SAMPLES; k++) d.setInt16(k * 2, this.#buf[k]!, true);
        this.#n = 0;
        this.#out(bytes);
      }
    }
  }
}

/// The parts of a Gamepad read here (the W3C's).
export type PadRead = { index: number; connected: boolean; mapping: string; buttons: readonly { pressed: boolean; value: number }[]; axes: readonly number[] };

/// A controller's state as `screen.input` takes it: its slot, its buttons' bits (the Standard Gamepad's 17), its sticks
/// past the dead zone and its triggers.
export function padInput(p: PadRead): Record<string, number | string | boolean> {
  const axis = (i: number) => {
    const a = p.axes[i] ?? 0;
    return Number.isFinite(a) && Math.abs(a) > DEAD_ZONE ? Math.max(-1, Math.min(1, a)) : 0;
  };
  let buttons = 0;
  for (let i = 0; i < Math.min(17, p.buttons.length); i++) if (p.buttons[i]!.pressed) buttons |= 1 << i;
  const trigger = (i: number) => Math.max(0, Math.min(1, p.buttons[i]?.value ?? 0));
  return { t: "gamepad", index: p.index, connected: true, buttons, lx: axis(0), ly: axis(1), rx: axis(2), ry: axis(3), lt: trigger(6), rt: trigger(7) };
}

/// A controller let go of (`connected: false`): the screen's virtual one released.
export const padGone = (index: number) => ({ t: "gamepad", index, connected: false, buttons: 0, lx: 0, ly: 0, rx: 0, ry: 0, lt: 0, rt: 0 });

/// Whether a controller's state is to be sent now: changed since the last sent, or a stick or trigger held off rest
/// and PAD_MS since.
export function padDue(now: Record<string, unknown>, was: { input: string; at: number } | undefined, at: number): boolean {
  if (!was) return true;
  if (JSON.stringify(now) !== was.input) return true;
  const held = ["lx", "ly", "rx", "ry", "lt", "rt"].some((k) => now[k] !== 0);
  return held && at - was.at >= PAD_MS;
}

/// What the page reaches of the browser (given by core.ts; a test gives its own).
export type Reach = {
  post(message: unknown): void;
  canvas(): HTMLCanvasElement | null;
};

/// The views' peripherals in this page, following ScreenViews as it changes (sync).
export class ScreenPeripherals {
  readonly views = new ScreenViews();
  #next = PERIPHERAL_FIRST;
  /// the microphone open: its stream, its context, the view and epoch it goes to (read as each packet goes)
  #mic: MicOpen | null = null;
  #padsSent = new Map<number, { input: string; at: number }>();
  #padLoop = 0;
  #keysLocked = false;
  #locked: string | null = null;
  #heard = false;

  readonly #reach: Reach;
  constructor(reach: Reach) {
    this.#reach = reach;
  }

  fromApp(m: unknown): void {
    const changed = this.views.fromApp(m);
    // a press on the picture of a view whose app holds the pointer: held for it (a user's press, so the browser lets it)
    if (isObject(m) && m.call === "screen.input" && isObject(m.params) && isObject(m.params.input)) {
      const input = m.params.input;
      const v = typeof m.params.view === "string" ? this.views.of(m.params.view) : undefined;
      if (input.t === "pointer" && input.kind === "down" && v && driving(v) && v.pointerLock) this.#lockPointer(v.view);
    }
    if (changed) this.sync();
  }

  fromCore(m: unknown): void {
    if (this.views.fromCore(m)) this.sync();
  }

  /// The core gone (stopped, the page hidden): every view with it, so the microphone, the pointer, the keys and the
  /// controllers let go of at once.
  stop(): void {
    this.views.byCall.clear();
    this.sync();
  }

  #call(call: string, params: unknown, bytes?: Uint8Array): void {
    const message = { id: this.#next++, call, params };
    this.#reach.post(bytes ? { withBytes: message, bytes } : message);
  }

  /// Everything as the views say it now: the microphone open or let go of, the controllers read or let go of, the
  /// pointer and the keys let go of where nothing holds them.
  sync(): void {
    this.#listen();
    const mic = this.views.micFor();
    if (!mic || (this.#mic && this.#mic.view !== mic.view)) this.#micOff();
    if (mic && !this.#mic) this.#micOn(mic.view);
    // the pointer: let go of where the view it was held for no longer holds it
    const lock = this.views.lockView();
    if (this.#locked !== null && lock?.view !== this.#locked) this.#unlockPointer();
    this.#keys();
    this.#pads();
  }

  // ---- microphone

  #micOn(view: string): void {
    const md = typeof navigator !== "undefined" ? navigator.mediaDevices : undefined;
    if (!md?.getUserMedia) return;
    const open: MicOpen = { stream: null, ctx: null, view, gone: false };
    this.#mic = open;
    const chunker = new PcmChunker((pcm) => {
      const now = this.views.micFor();
      if (open.gone || !now || now.view !== view) return;
      this.#call("screen.mic", { view, epoch: now.epoch }, pcm);
    });
    void md.getUserMedia({ audio: { sampleRate: MIC_RATE, channelCount: 1, echoCancellation: true, noiseSuppression: true, autoGainControl: true } }).then(async (stream) => {
      open.stream = stream;
      // (let go of meanwhile: closed as it came)
      if (open.gone) return stopAll(open);
      const ctx = new AudioContext({ sampleRate: MIC_RATE });
      open.ctx = ctx;
      const source = ctx.createMediaStreamSource(stream);
      const take = (samples: Float32Array) => chunker.push(ctx.sampleRate === MIC_RATE ? samples : resample(samples, ctx.sampleRate));
      try {
        if (!ctx.audioWorklet) throw new Error("no worklet");
        const url = URL.createObjectURL(new Blob([WORKLET], { type: "text/javascript" }));
        await ctx.audioWorklet.addModule(url);
        URL.revokeObjectURL(url);
        if (open.gone) return;
        const node = new AudioWorkletNode(ctx, "sf-mic", { numberOfInputs: 1, numberOfOutputs: 1, channelCount: 1 });
        node.port.onmessage = (e: MessageEvent) => take(e.data as Float32Array);
        source.connect(node).connect(ctx.destination);
      } catch {
        if (open.gone) return;
        // (a browser without AudioWorklet: the processor it had before)
        const node = ctx.createScriptProcessor(1024, 1, 1);
        node.onaudioprocess = (e) => take(e.inputBuffer.getChannelData(0).slice());
        source.connect(node).connect(ctx.destination);
      }
    }, () => {
      // refused (the person said no, or no microphone): nothing goes; asked again as it is shared again
      if (this.#mic === open) this.#mic = null;
    });
  }

  #micOff(): void {
    const open = this.#mic;
    this.#mic = null;
    if (open) stopAll(open);
  }

  /// Whether the microphone is open (or being opened) now, and for which view.
  get micView(): string | null {
    return this.#mic?.view ?? null;
  }

  // ---- pointer lock

  #lockPointer(view: string): void {
    const canvas = this.#reach.canvas();
    if (!canvas?.requestPointerLock || typeof document === "undefined") return;
    this.#locked = view;
    if (document.pointerLockElement !== canvas) {
      try {
        const p = canvas.requestPointerLock() as unknown;
        if (p instanceof Promise) p.catch(() => undefined);
      } catch {
        // not now (no press of the person's to go by)
      }
    }
  }

  #unlockPointer(): void {
    this.#locked = null;
    const canvas = this.#reach.canvas();
    if (typeof document !== "undefined" && canvas && document.pointerLockElement === canvas) document.exitPointerLock();
  }

  /// A pointer's event while the canvas holds the pointer for a view: that view's alone, as how far it moved (the app
  /// under it given none of it).
  #held = (e: PointerEvent): void => {
    const canvas = this.#reach.canvas();
    if (this.#locked === null || !canvas || document.pointerLockElement !== canvas) return;
    const v = this.views.of(this.#locked);
    if (!v || !driving(v)) return;
    e.stopImmediatePropagation();
    e.preventDefault();
    const kind = e.type === "pointerdown" ? "down" : e.type === "pointerup" ? "up" : "move";
    const input: Record<string, unknown> = { t: "pointer", kind, x: v.at.x, y: v.at.y, buttons: e.buttons & 7, relative: true };
    if (kind === "move") {
      // (a move of nothing: none sent)
      if (e.movementX === 0 && e.movementY === 0) return;
      input.dx = e.movementX;
      input.dy = e.movementY;
    }
    this.#call("screen.input", { view: v.view, input });
  };

  // ---- keyboard lock in full screen

  #keys(): void {
    if (typeof document === "undefined") return;
    const kb = (navigator as unknown as { keyboard?: { lock?(keys: string[]): Promise<void>; unlock?(): void } }).keyboard;
    const want = document.fullscreenElement != null && this.views.driven().length > 0;
    if (want && !this.#keysLocked) {
      this.#keysLocked = true;
      kb?.lock?.(["Escape", "Tab"])?.catch(() => undefined);
    } else if (!want && this.#keysLocked) {
      this.#keysLocked = false;
      kb?.unlock?.();
    }
  }

  // ---- controllers

  #pads(): void {
    const view = this.views.padView();
    if (view === null) {
      this.#padsLetGo();
      return;
    }
    if (this.#padLoop === 0 && typeof requestAnimationFrame === "function" && padsNow().length > 0) {
      const step = (t: number) => {
        this.#padLoop = 0;
        if (this.#padRead(t)) this.#padLoop = requestAnimationFrame(step);
      };
      this.#padLoop = requestAnimationFrame(step);
    }
  }

  /// The controllers read once, each one's state sent where it is due; whether to read them again next frame.
  #padRead(at: number): boolean {
    const view = this.views.padView();
    if (view === null) {
      this.#padsLetGo();
      return false;
    }
    const pads = padsNow();
    const there = new Set<number>();
    for (const p of pads) {
      if (p.index > 3) continue;
      there.add(p.index);
      const input = padInput(p);
      const was = this.#padsSent.get(p.index);
      if (padDue(input, was, at)) {
        this.#padsSent.set(p.index, { input: JSON.stringify(input), at });
        this.#call("screen.input", { view, input });
      }
    }
    for (const index of [...this.#padsSent.keys()]) {
      if (!there.has(index)) {
        this.#padsSent.delete(index);
        this.#call("screen.input", { view, input: padGone(index) });
      }
    }
    return pads.length > 0;
  }

  #padsLetGo(): void {
    if (this.#padLoop !== 0) cancelAnimationFrame(this.#padLoop);
    this.#padLoop = 0;
    // (to the view they drove, gone or not: the core lets a call to a view gone be)
    const view = this.views.last ?? null;
    for (const index of this.#padsSent.keys()) if (view !== null) this.#call("screen.input", { view, input: padGone(index) });
    this.#padsSent.clear();
  }

  /// The page's own listeners, once: controllers coming and going, the pointer held or let go of, full screen.
  #listen(): void {
    if (this.#heard || typeof addEventListener !== "function") return;
    this.#heard = true;
    addEventListener("gamepadconnected", () => this.sync());
    addEventListener("gamepaddisconnected", () => this.sync());
    document.addEventListener("fullscreenchange", () => this.sync());
    document.addEventListener("pointerlockchange", () => {
      // (let go of by the person, Escape: pressed on the picture again to hold it again)
      if (document.pointerLockElement !== this.#reach.canvas()) this.#locked = null;
    });
    for (const name of ["pointerdown", "pointermove", "pointerup"]) addEventListener(name, this.#held as EventListener, { capture: true });
  }
}

/// The microphone open (or on its way): its stream, its context, the view it goes to, and whether it was let go of.
type MicOpen = { stream: MediaStream | null; ctx: AudioContext | null; view: string; gone: boolean };

/// The controllers connected now.
function padsNow(): PadRead[] {
  if (typeof navigator === "undefined" || !navigator.getGamepads) return [];
  return navigator.getGamepads().filter((p): p is Gamepad => p !== null && p.connected);
}

/// The microphone let go of at once: its tracks stopped (the browser's mark and the system's out), its context closed.
function stopAll(open: MicOpen): void {
  open.gone = true;
  open.stream?.getTracks().forEach((t) => t.stop());
  void open.ctx?.close().catch(() => undefined);
}

/// Samples of `rate` as 48 kHz (where the browser opened the context at its own rate): the nearest two weighed.
export function resample(samples: Float32Array, rate: number): Float32Array {
  const n = Math.floor((samples.length * MIC_RATE) / rate);
  const out = new Float32Array(n);
  const step = rate / MIC_RATE;
  for (let i = 0; i < n; i++) {
    const at = i * step;
    const k = Math.floor(at);
    const f = at - k;
    out[i] = (samples[k] ?? 0) * (1 - f) + (samples[k + 1] ?? samples[k] ?? 0) * f;
  }
  return out;
}

/// The worklet that hands each block of the microphone's samples to the page.
const WORKLET = `class P extends AudioWorkletProcessor{process(i){const c=i[0]&&i[0][0];if(c)this.port.postMessage(c.slice(0));return true}}registerProcessor("sf-mic",P);`;
