// A virtual microphone in a tab of the station's browser, there only while the page records it: the page's own
// `navigator.mediaDevices` lists one more audio input ("still.fail Microphone") and gives a page asking for audio a live
// track of what the station feeds it (48 kHz mono PCM16, 20 ms at a time, the system audio's packets' beat:
// native/helper SystemAudio.swift, native/screen audio_packets.rs), read from a ring in the page that plays silence on
// an underrun and never an old sample again.
//
// Demand is the page's to say, pulled, never pushed: the hook counts the virtual tracks not yet ended, and says
// {active: true} as the count goes from 0 to 1 and {active: false} as it comes back to 0 (a track stopped, ended, the
// page hidden or unloaded), each with an epoch that only grows; so a consumer that stops and starts again between two
// looks is a new epoch, and an old lifetime is retired (virtual-mic spec §1.7's epoch, as the receiver keeps it).
// Anything unknown, a new document, the hook gone, is {active: false}.
//
// Like the passkey and login hooks (view.ts), a binding of the controller's own name and a script on every new document;
// the hook keeps the browser's originals as it found them, so a page replacing `getUserMedia` or `MediaStreamTrack`'s
// `stop` after it ran changes nothing of what it counts. A page asking for a given device that is not this one
// (a `deviceId` other than "default" or "stillfail-mic"), or for video alone, gets the browser's own.
import { randomUUID } from "node:crypto";
import type { Cdp } from "./cdp.ts";

export type MicDemand = { active: boolean; epoch: number; device?: string; error?: string };

export interface BrowserMicController {
  /// The latest demand the page said (inactive until it says otherwise).
  readonly demand: MicDemand;
  /// 48 kHz mono little-endian PCM16 for the page's ring; dropped at once while nothing records it (no CDP call).
  feedPcm16(pcm16le: Uint8Array): void;
  /// Removes the binding and the hook, ends the page's virtual tracks; said inactive if it was active.
  close(): void;
}

export const MIC_DEVICE_ID = "stillfail-mic";
export const MIC_LABEL = "still.fail Microphone";
export const MIC_GROUP_ID = "stillfail-audio";
/// The ring's frames in the page (341 ms at 48 kHz): what is fed past it drops the oldest.
export const MIC_RING_FRAMES = 16384;
/// Feeds sent and not answered yet: past this many, a feed is dropped rather than queued behind a slow page.
const FEEDS_IN_FLIGHT = 8;

const binding = (owner: string) => `__stillfailMic_${owner}`;
const global = (owner: string) => `__stillfailMicHook_${owner}`;

/// The page's hook, installed once per document and owner (again it is a no-op).
export function micHook(owner: string): string {
  return `(() => {
  const BINDING = ${JSON.stringify(binding(owner))};
  const GLOBAL = ${JSON.stringify(global(owner))};
  if (Object.prototype.hasOwnProperty.call(window, GLOBAL)) return;
  const md = navigator.mediaDevices;
  if (!md || typeof md.getUserMedia !== "function") return;
  const say = typeof window[BINDING] === "function" ? window[BINDING] : null;
  const origEnumerate = typeof md.enumerateDevices === "function" ? md.enumerateDevices : null;
  const origGum = md.getUserMedia;
  const Track = window.MediaStreamTrack;
  const origStop = Track && Track.prototype && Track.prototype.stop;
  const apply = (f, self, args) => Reflect.apply(f, self, args);
  const C = ${MIC_RING_FRAMES};
  const ring = new Float32Array(C);
  let written = 0, read = 0;
  const live = new Set();
  let epoch = 0, ctx = null, node = null, closed = false;
  const tell = () => {
    if (say === null) return;
    try { apply(say, window, [JSON.stringify({ owner: ${JSON.stringify(owner)}, active: live.size > 0, epoch })]); } catch {}
  };
  const pull = (out) => {
    for (let i = 0; i < out.length; i++) {
      if (read < written) { out[i] = ring[read % C]; read++; } else out[i] = 0;
    }
  };
  const ended = (track) => {
    if (!live.delete(track)) return;
    if (live.size === 0) { epoch++; tell(); read = written; }
  };
  const ensure = () => {
    if (ctx !== null) return;
    const AC = window.AudioContext || window.webkitAudioContext;
    ctx = new AC({ sampleRate: 48000 });
    node = ctx.createScriptProcessor(1024, 1, 1);
    node.onaudioprocess = (e) => pull(e.outputBuffer.getChannelData(0));
  };
  const wanted = (audio) => {
    if (!audio) return false;
    if (audio === true || typeof audio !== "object") return true;
    const d = audio.deviceId;
    if (d === undefined || d === null) return true;
    const ids = [];
    const add = (v) => { if (typeof v === "string") ids.push(v); else if (Array.isArray(v)) for (const x of v) if (typeof x === "string") ids.push(x); };
    if (typeof d === "object" && !Array.isArray(d)) { add(d.exact); add(d.ideal); } else add(d);
    return ids.every((id) => id === "default" || id === ${JSON.stringify(MIC_DEVICE_ID)} || id === "");
  };
  const virtualTrack = () => {
    ensure();
    const dest = ctx.createMediaStreamDestination();
    node.connect(dest);
    if (typeof ctx.resume === "function") { try { const p = ctx.resume(); if (p && typeof p.catch === "function") p.catch(() => {}); } catch {} }
    const stream = dest.stream;
    const track = stream.getAudioTracks()[0];
    const first = live.size === 0;
    if (first) read = written;
    live.add(track);
    if (typeof track.addEventListener === "function") track.addEventListener("ended", () => ended(track));
    if (first) { epoch++; tell(); }
    return { stream, track };
  };
  const gum = function getUserMedia(constraints) {
    if (closed || !constraints || !wanted(constraints.audio)) return apply(origGum, md, [constraints]);
    if (constraints.video) {
      return apply(origGum, md, [{ video: constraints.video }]).then((video) => {
        const { stream } = virtualTrack();
        for (const t of video.getVideoTracks()) stream.addTrack(t);
        return stream;
      });
    }
    try { return Promise.resolve(virtualTrack().stream); } catch (e) { return Promise.reject(e); }
  };
  const info = () => {
    const proto = window.MediaDeviceInfo && window.MediaDeviceInfo.prototype;
    const o = proto ? Object.create(proto) : {};
    const v = { deviceId: ${JSON.stringify(MIC_DEVICE_ID)}, kind: "audioinput", label: ${JSON.stringify(MIC_LABEL)}, groupId: ${JSON.stringify(MIC_GROUP_ID)} };
    for (const k of Object.keys(v)) Object.defineProperty(o, k, { value: v[k], enumerable: true });
    Object.defineProperty(o, "toJSON", { value: () => ({ ...v }) });
    return Object.freeze(o);
  };
  const enumerate = function enumerateDevices() {
    const own = closed ? [] : [info()];
    if (origEnumerate === null) return Promise.resolve(own);
    return apply(origEnumerate, md, []).then((list) => own.concat(Array.from(list).filter((d) => d.deviceId !== ${JSON.stringify(MIC_DEVICE_ID)})));
  };
  const stop = function stop() {
    const r = apply(origStop, this, []);
    ended(this);
    return r;
  };
  const endAll = () => { for (const t of [...live]) { try { apply(origStop, t, []); } catch {} ended(t); } };
  const hook = {
    feed(b64) {
      if (closed || live.size === 0 || typeof b64 !== "string") return 0;
      const bin = atob(b64);
      const n = bin.length >> 1;
      for (let i = 0; i < n; i++) {
        let s = bin.charCodeAt(2 * i) | (bin.charCodeAt(2 * i + 1) << 8);
        if (s >= 0x8000) s -= 0x10000;
        ring[written % C] = s / 32768;
        written++;
      }
      if (written - read > C) read = written - C;
      return n;
    },
    pull,
    state: () => ({ active: live.size > 0, epoch, queued: written - read }),
    close() {
      if (closed) return;
      endAll();
      closed = true;
      if (md.getUserMedia === gum) md.getUserMedia = origGum;
      if (origEnumerate !== null && md.enumerateDevices === enumerate) md.enumerateDevices = origEnumerate;
      if (Track && Track.prototype.stop === stop) Track.prototype.stop = origStop;
      if (node !== null) { try { node.disconnect(); } catch {} node.onaudioprocess = null; }
      if (ctx !== null && typeof ctx.close === "function") { try { const p = ctx.close(); if (p && typeof p.catch === "function") p.catch(() => {}); } catch {} }
      ctx = null; node = null;
    },
  };
  Object.defineProperty(window, GLOBAL, { value: Object.freeze(hook), enumerable: false, configurable: false, writable: false });
  md.getUserMedia = gum;
  if (origEnumerate !== null) md.enumerateDevices = enumerate;
  if (Track && typeof origStop === "function") Track.prototype.stop = stop;
  window.addEventListener("pagehide", endAll);
  window.addEventListener("beforeunload", endAll);
})()`;
}

/// Base64 of `pcm` without Node's Buffer copy when it is one already.
function base64(pcm: Uint8Array): string {
  return Buffer.from(pcm.buffer, pcm.byteOffset, pcm.byteLength & ~1).toString("base64");
}

export function attachBrowserMic(cdp: Cdp, session: string, options?: { onDemand?: (state: { active: boolean; epoch: number }) => void }): BrowserMicController {
  const owner = randomUUID().replaceAll("-", "");
  const name = binding(owner);
  const hook = micHook(owner);
  const call = (method: string) => `window[${JSON.stringify(global(owner))}] && window[${JSON.stringify(global(owner))}].${method}`;
  let on = true;
  let script: string | null = null;
  let demand: MicDemand = { active: false, epoch: 0 };
  // What the page said last (its own epoch restarts with each document): a change of either is a new epoch here.
  let heard: { active: boolean; epoch: number } | null = null;
  let inFlight = 0;
  const set = (active: boolean) => {
    demand = { active, epoch: demand.epoch + 1, ...(active ? { device: MIC_DEVICE_ID } : {}) };
    options?.onDemand?.({ active, epoch: demand.epoch });
  };
  const unlisten = cdp.on((e) => {
    if (!on || e.sessionId !== session) return;
    if (e.method === "Runtime.executionContextsCleared" || (e.method === "Page.frameNavigated" && e.params?.frame && !e.params.frame.parentId)) {
      // A new document: nothing of the old one records any more.
      heard = null;
      if (demand.active) set(false);
      return;
    }
    if (e.method !== "Runtime.bindingCalled" || e.params?.name !== name) return;
    let said: any = null;
    try {
      said = JSON.parse(String(e.params.payload));
    } catch {}
    if (said?.owner !== owner || typeof said.active !== "boolean" || !Number.isSafeInteger(said.epoch)) return;
    if (heard !== null && heard.active === said.active && heard.epoch === said.epoch) return;
    // (an older say of this document come late: its epoch is behind the one heard)
    if (heard !== null && said.epoch < heard.epoch) return;
    heard = { active: said.active, epoch: said.epoch };
    if (!said.active) {
      if (demand.active) set(false);
      return;
    }
    // (active again with no inactive heard between: the old lifetime is retired first)
    if (demand.active) set(false);
    set(true);
  });
  const undo = () => {
    void cdp.send("Runtime.evaluate", { expression: `${call("close")}()` }, session).catch(() => {});
    void cdp.send("Runtime.removeBinding", { name }, session).catch(() => {});
    if (script !== null) void cdp.send("Page.removeScriptToEvaluateOnNewDocument", { identifier: script }, session).catch(() => {});
  };
  void (async () => {
    try {
      await cdp.send("Runtime.addBinding", { name }, session);
      await cdp.send("Runtime.enable", {}, session);
      script = (await cdp.send("Page.addScriptToEvaluateOnNewDocument", { source: hook }, session))?.identifier ?? null;
      await cdp.send("Runtime.evaluate", { expression: hook }, session);
      if (!on) undo();
    } catch {}
  })();
  return {
    get demand() {
      return demand;
    },
    feedPcm16(pcm16le) {
      if (!on || !demand.active || pcm16le.byteLength < 2 || inFlight >= FEEDS_IN_FLIGHT) return;
      inFlight++;
      void cdp
        .send("Runtime.evaluate", { expression: `${call("feed")}(${JSON.stringify(base64(pcm16le))})` }, session)
        .catch(() => {})
        .finally(() => inFlight--);
    },
    close() {
      if (!on) return;
      on = false;
      unlisten();
      undo();
      if (demand.active) set(false);
    },
  };
}
