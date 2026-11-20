// The browser's virtual microphone (src/browser/mic.ts): its real page hook run in a VM page with a fake Web Audio and
// MediaDevices, driven through a deterministic CDP, as browser-passkey.test.ts drives the passkey hook.
import assert from "node:assert/strict";
import { test } from "node:test";
import { createContext, runInContext } from "node:vm";
import { attachBrowserMic, MIC_DEVICE_ID, MIC_LABEL, MIC_RING_FRAMES } from "../src/browser/mic.ts";
import type { Cdp, CdpEvent } from "../src/browser/cdp.ts";

function page() {
  const context = createContext({ atob, btoa, Promise, JSON, Float32Array, Set, Array, Object, Reflect });
  const run = (s: string): any => runInContext(s, context);
  run(`globalThis.window = globalThis;
    window.listeners = {};
    window.addEventListener = (type, f) => { (listeners[type] ??= []).push(f); };
    window.fire = (type) => { for (const f of listeners[type] ?? []) f(); };
    window.nativeAsked = [];
    class MediaStreamTrack {
      constructor(kind) { this.kind = kind; this.readyState = "live"; this.ended = []; }
      stop() { this.readyState = "ended"; }
      addEventListener(type, f) { if (type === "ended") this.ended.push(f); }
    }
    window.MediaStreamTrack = MediaStreamTrack;
    class MediaStream {
      constructor(tracks) { this.tracks = tracks; }
      getAudioTracks() { return this.tracks.filter(t => t.kind === "audio"); }
      getVideoTracks() { return this.tracks.filter(t => t.kind === "video"); }
      getTracks() { return this.tracks; }
      addTrack(t) { this.tracks.push(t); }
    }
    window.MediaStream = MediaStream;
    window.MediaDeviceInfo = class MediaDeviceInfo {};
    window.contexts = [];
    window.AudioContext = class {
      constructor(o) { this.sampleRate = o.sampleRate; this.state = "running"; contexts.push(this); }
      createScriptProcessor(size, i, o) {
        const node = { size, connected: [], connect(d) { this.connected.push(d); }, disconnect() { this.connected = []; } };
        this.node = node;
        return node;
      }
      createMediaStreamDestination() { return { stream: new MediaStream([new MediaStreamTrack("audio")]) }; }
      resume() { return Promise.resolve(); }
      close() { this.state = "closed"; return Promise.resolve(); }
    };
    window.navigator = { mediaDevices: {
      enumerateDevices: async () => [{ deviceId: "built-in", kind: "audioinput", label: "MacBook Microphone", groupId: "g" }],
      getUserMedia: async (c) => { nativeAsked.push(JSON.stringify(c)); return new MediaStream(c.video ? [new MediaStreamTrack("video")] : [new MediaStreamTrack("audio")]); },
    } };
    window.process = (n) => {
      const out = new Float32Array(n);
      contexts[0].node.onaudioprocess({ outputBuffer: { getChannelData: () => out } });
      return Array.from(out);
    };
  `);
  const pending = new Set<Promise<unknown>>();
  const listeners = new Set<(e: CdpEvent) => void>();
  const scripts = new Map<string, string>();
  const sent: string[] = [];
  const session = "s1";
  let next = 0;
  const cdp: Cdp = {
    send(method, params: any = {}, sid) {
      sent.push(method);
      const promise = Promise.resolve().then(() => {
        assert.equal(sid, session);
        if (method === "Runtime.enable") return {};
        if (method === "Runtime.addBinding") {
          context[params.name] = (payload: string) => {
            for (const f of [...listeners]) f({ sessionId: session, method: "Runtime.bindingCalled", params: { name: params.name, payload } });
          };
          return {};
        }
        if (method === "Runtime.removeBinding") {
          delete context[params.name];
          return {};
        }
        if (method === "Runtime.evaluate") return { result: { value: run(params.expression) } };
        if (method === "Page.addScriptToEvaluateOnNewDocument") {
          const identifier = String(++next);
          scripts.set(identifier, params.source);
          return { identifier };
        }
        if (method === "Page.removeScriptToEvaluateOnNewDocument") {
          scripts.delete(params.identifier);
          return {};
        }
        assert.fail(method);
      });
      pending.add(promise);
      void promise.finally(() => pending.delete(promise));
      return promise;
    },
    on(f) {
      listeners.add(f);
      return () => listeners.delete(f);
    },
    closed: new Promise(() => {}),
    close() {},
  };
  const settle = async () => {
    while (pending.size) await Promise.all([...pending]);
    await new Promise<void>((resolve) => setImmediate(resolve));
  };
  const emit = (e: CdpEvent) => {
    for (const f of [...listeners]) f(e);
  };
  return { run, cdp, session, settle, scripts, sent, emit };
}

const pcm = (...samples: number[]) => {
  const b = new Uint8Array(samples.length * 2);
  const v = new DataView(b.buffer);
  samples.forEach((s, i) => v.setInt16(i * 2, s, true));
  return b;
};

async function attached() {
  const p = page();
  const said: { active: boolean; epoch: number }[] = [];
  const mic = attachBrowserMic(p.cdp, p.session, { onDemand: (s) => said.push(s) });
  await p.settle();
  return { p, mic, said };
}

test("the page lists the virtual microphone first, its own devices after", async () => {
  const { p } = await attached();
  await p.run(`navigator.mediaDevices.enumerateDevices().then(l => window.listed = l)`);
  await p.settle();
  const listed = p.run("listed");
  assert.equal(listed.length, 2);
  assert.equal(listed[0].deviceId, MIC_DEVICE_ID);
  assert.equal(listed[0].kind, "audioinput");
  assert.equal(listed[0].label, MIC_LABEL);
  assert.equal(listed[0].groupId, "stillfail-audio");
  assert.ok(p.run("listed[0] instanceof MediaDeviceInfo"));
  assert.deepEqual(JSON.parse(p.run("JSON.stringify(listed[0])")), { deviceId: MIC_DEVICE_ID, kind: "audioinput", label: MIC_LABEL, groupId: "stillfail-audio" });
  assert.equal(listed[1].deviceId, "built-in");
});

test("getUserMedia({audio}) is demand; stopping its track ends it; each lifetime a new epoch", async () => {
  const { p, mic, said } = await attached();
  assert.deepEqual(mic.demand, { active: false, epoch: 0 });
  await p.run(`navigator.mediaDevices.getUserMedia({ audio: true }).then(s => window.s1 = s)`);
  await p.settle();
  assert.deepEqual(said, [{ active: true, epoch: 1 }]);
  assert.equal(mic.demand.active, true);
  assert.equal(mic.demand.device, MIC_DEVICE_ID);
  assert.equal(p.run("nativeAsked.length"), 0, "the browser's own was not asked");
  assert.equal(p.run("contexts[0].sampleRate"), 48000);

  // A second consumer of the same page is the same demand.
  await p.run(`navigator.mediaDevices.getUserMedia({ audio: { deviceId: { exact: "${MIC_DEVICE_ID}" } } }).then(s => window.s2 = s)`);
  await p.settle();
  assert.equal(said.length, 1);
  p.run("s1.getAudioTracks()[0].stop()");
  await p.settle();
  assert.equal(said.length, 1, "one consumer still records");
  p.run("s2.getAudioTracks()[0].stop()");
  await p.settle();
  assert.deepEqual(said.at(-1), { active: false, epoch: 2 });
  assert.equal(p.run("s2.getAudioTracks()[0].readyState"), "ended", "the browser's stop still ran");

  await p.run(`navigator.mediaDevices.getUserMedia({ audio: true }).then(s => window.s3 = s)`);
  await p.settle();
  assert.deepEqual(said.at(-1), { active: true, epoch: 3 });
  // An 'ended' event (the track ended by the browser) ends it as stop does.
  p.run("for (const f of s3.getAudioTracks()[0].ended) f()");
  await p.settle();
  assert.deepEqual(said.at(-1), { active: false, epoch: 4 });
  const epochs = said.map((s) => s.epoch);
  assert.deepEqual(epochs, [...epochs].sort((a, b) => a - b));
});

test("video alone, or another device asked by id, is the browser's own and no demand", async () => {
  const { p, said } = await attached();
  await p.run(`navigator.mediaDevices.getUserMedia({ video: true })`);
  await p.run(`navigator.mediaDevices.getUserMedia({ audio: { deviceId: { exact: "built-in" } } })`);
  await p.run(`navigator.mediaDevices.getUserMedia({ audio: { deviceId: ["built-in"] } })`);
  await p.settle();
  assert.equal(said.length, 0);
  assert.equal(p.run("nativeAsked.length"), 3);
  // Audio and video: the video the browser's, the audio ours.
  await p.run(`navigator.mediaDevices.getUserMedia({ audio: true, video: true }).then(s => window.av = s)`);
  await p.settle();
  assert.equal(p.run("nativeAsked.at(-1)"), JSON.stringify({ video: true }));
  assert.equal(p.run("av.getTracks().length"), 2);
  assert.deepEqual(said, [{ active: true, epoch: 1 }]);
});

test("a page replacing stop or getUserMedia after the hook does not hide what it counts", async () => {
  const { p, said } = await attached();
  await p.run(`navigator.mediaDevices.getUserMedia({ audio: true }).then(s => window.s = s)`);
  await p.settle();
  // A page wraps stop after the hook: its wrapper still reaches the hook's.
  p.run(`const inner = MediaStreamTrack.prototype.stop; MediaStreamTrack.prototype.stop = function () { window.wrapped = true; return inner.call(this); }`);
  p.run("s.getAudioTracks()[0].stop()");
  await p.settle();
  assert.equal(p.run("wrapped"), true);
  assert.deepEqual(said.at(-1), { active: false, epoch: 2 });
  // The hook object itself cannot be replaced.
  const name = p.run(`Object.getOwnPropertyNames(window).find(n => n.startsWith("__stillfailMicHook_"))`);
  p.run(`try { window["${name}"] = null; } catch {}`);
  assert.notEqual(p.run(`window["${name}"]`), null);
  // Installed again (a second evaluate of the same hook): a no-op, nothing counted twice.
  for (const source of p.scripts.values()) p.run(source);
  await p.run(`navigator.mediaDevices.getUserMedia({ audio: true }).then(s => window.t = s)`);
  await p.settle();
  assert.deepEqual(said.at(-1), { active: true, epoch: 3 });
});

test("fed PCM16 plays in order; an underrun is silence and never an old sample again", async () => {
  const { p, mic } = await attached();
  const before = p.sent.length;
  mic.feedPcm16(pcm(16384, -16384));
  assert.equal(p.sent.length, before, "nothing records: dropped with no CDP call");
  await p.run(`navigator.mediaDevices.getUserMedia({ audio: true }).then(s => window.s = s)`);
  await p.settle();
  mic.feedPcm16(pcm(16384, -16384, 32767, -32768));
  await p.settle();
  assert.deepEqual(p.run("process(6)"), [0.5, -0.5, 32767 / 32768, -1, 0, 0]);
  assert.deepEqual(p.run("process(4)"), [0, 0, 0, 0], "nothing read twice");
  mic.feedPcm16(pcm(1000));
  await p.settle();
  assert.deepEqual(p.run("process(2)"), [1000 / 32768, 0]);
});

test("the ring keeps the newest 16384 frames; a new lifetime starts from what is fed then", async () => {
  const { p, mic } = await attached();
  await p.run(`navigator.mediaDevices.getUserMedia({ audio: true }).then(s => window.s = s)`);
  await p.settle();
  const n = MIC_RING_FRAMES + 960;
  mic.feedPcm16(pcm(...Array.from({ length: n }, (_, i) => i % 30000)));
  await p.settle();
  const out: number[] = p.run(`process(${MIC_RING_FRAMES + 2})`);
  assert.equal(Math.round(out[0]! * 32768), 960 % 30000, "the oldest 960 dropped");
  assert.equal(Math.round(out[MIC_RING_FRAMES - 1]! * 32768), (n - 1) % 30000);
  assert.deepEqual(out.slice(MIC_RING_FRAMES), [0, 0]);
  // Fed, then stopped and opened again: the next consumer hears none of it.
  mic.feedPcm16(pcm(5, 6, 7));
  await p.settle();
  p.run("s.getAudioTracks()[0].stop()");
  await p.settle();
  await p.run(`navigator.mediaDevices.getUserMedia({ audio: true }).then(s => window.s = s)`);
  await p.settle();
  assert.deepEqual(p.run("process(3)"), [0, 0, 0]);
});

test("a new document, the page hidden, or the controller closed ends the demand", async () => {
  const { p, mic, said } = await attached();
  await p.run(`navigator.mediaDevices.getUserMedia({ audio: true }).then(s => window.old = s)`);
  await p.settle();
  p.emit({ sessionId: p.session, method: "Runtime.executionContextsCleared", params: {} });
  assert.deepEqual(said.at(-1), { active: false, epoch: 2 });
  // The old document's late say that it ended is no new lifetime; a consumer after it is.
  p.run("old.getAudioTracks()[0].stop()");
  await p.settle();
  assert.equal(said.length, 2);
  await p.run(`navigator.mediaDevices.getUserMedia({ audio: true })`);
  await p.settle();
  assert.deepEqual(said.at(-1), { active: true, epoch: 3 });
  p.run(`fire("pagehide")`);
  await p.settle();
  assert.deepEqual(said.at(-1), { active: false, epoch: 4 });
  await p.run(`navigator.mediaDevices.getUserMedia({ audio: true }).then(s => window.s = s)`);
  await p.settle();
  assert.equal(mic.demand.active, true);
  mic.close();
  await p.settle();
  assert.deepEqual(said.at(-1), { active: false, epoch: 6 });
  assert.equal(p.scripts.size, 0, "the new-document hook removed");
  assert.equal(p.run("s.getAudioTracks()[0].readyState"), "ended");
  assert.equal(p.run(`contexts[0].state`), "closed");
  await p.run(`navigator.mediaDevices.getUserMedia({ audio: true })`);
  await p.settle();
  assert.equal(p.run("nativeAsked.length"), 1, "the browser's own getUserMedia is back");
  const sent = p.sent.length;
  mic.feedPcm16(pcm(1, 2));
  assert.equal(p.sent.length, sent);
});
