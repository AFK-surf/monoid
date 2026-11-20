// The Linux virtual microphone (src/screens/linux-mic.ts) against a fake pactl and pacat: the commands it runs, both of
// pactl's output formats, demand and its epoch, the feed's backpressure. With STILLFAIL_MIC_LIVE=1 on a machine with a
// pulse server, also the real thing (parecord as the consumer).
import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { test } from "node:test";
import {
  consumers,
  FEED_MOST_BYTES,
  LinuxVirtualMic,
  type MicFeedProcess,
  MONITOR_NAME,
  ourModules,
  parseShortSources,
  parseSourceOutputsJson,
  parseSourceOutputsText,
  SINK_NAME,
  SOURCE_NAME,
  type MicDemand,
} from "../src/screens/linux-mic.ts";

const SELF = 4242;

/// A pulse server as pactl shows it: its modules, sources and the streams recording them.
function pulse(o: { json?: boolean; missing?: boolean } = {}) {
  const calls: string[] = [];
  let nextModule = 30;
  const modules = new Map<number, string>([[7, `module-null-sink\tsink_name=${SINK_NAME} rate=48000`]]);
  const outputs: { index: number; source: number; corked: boolean; pid: number }[] = [];
  let fail: string | null = null;
  const sources = () => {
    const rows = [[1, "alsa_input.pci-0000_00_1f.3.analog-stereo"]];
    for (const [, line] of modules) {
      if (line.startsWith("module-null-sink")) rows.push([2, MONITOR_NAME]);
      if (line.startsWith("module-remap-source")) rows.push([3, SOURCE_NAME]);
    }
    return rows.map(([i, n]) => `${i}\t${n}\tmodule-x.c\ts16le 1ch 48000Hz\tIDLE`).join("\n") + "\n";
  };
  const run = async (program: string, args: string[]) => {
    calls.push([program, ...args].join(" "));
    if (o.missing) throw Object.assign(new Error("spawn pactl ENOENT"), { code: "ENOENT" });
    if (fail !== null) throw new Error(fail);
    assert.equal(program, "pactl");
    const a = args.join(" ");
    if (a === "list short modules") return { stdout: [...modules].map(([id, l]) => `${id}\t${l}`).join("\n") };
    if (args[0] === "unload-module") {
      modules.delete(Number(args[1]));
      return { stdout: "" };
    }
    if (args[0] === "load-module") {
      const id = nextModule++;
      modules.set(id, `${args[1]}\t${args.slice(2).join(" ")}`);
      return { stdout: `${id}\n` };
    }
    if (a === "list short sources") return { stdout: sources() };
    if (a === "-f json list source-outputs") {
      if (!o.json) throw new Error("pactl ended with 1");
      return {
        stdout: JSON.stringify(
          outputs.map((s) => ({ index: s.index, source: s.source, corked: s.corked, properties: { "application.process.id": String(s.pid), "application.name": "app" } })),
        ),
      };
    }
    if (a === "list source-outputs") {
      return {
        stdout: outputs
          .map((s) => `Source Output #${s.index}\n\tDriver: protocol-native.c\n\tSource: ${s.source}\n\tCorked: ${s.corked ? "yes" : "no"}\n\tProperties:\n\t\tapplication.name = "app"\n\t\tapplication.process.id = "${s.pid}"\n`)
          .join("\n"),
      };
    }
    assert.fail(a);
  };
  return { run, calls, modules, outputs, failWith: (why: string | null) => (fail = why) };
}

/// pacat as a fake: what it was written, its pipe full when told.
function feeds() {
  const started: { args: string[]; written: Uint8Array[]; killed: boolean; full: boolean; drain: () => void; exit: () => void }[] = [];
  const spawnFeed = (program: string, args: string[]): MicFeedProcess => {
    assert.equal(program, "pacat");
    const f = { args, written: [] as Uint8Array[], killed: false, full: false, drain: () => {}, exit: () => {} };
    started.push(f);
    return {
      write: (c) => (f.written.push(c), !f.full),
      onDrain: (cb) => void (f.drain = cb),
      onExit: (cb) => void (f.exit = cb),
      kill: () => void (f.killed = true),
    };
  };
  return { started, spawnFeed };
}

test("parses pactl's JSON and text alike, counting only running streams of others on our source or monitor", () => {
  const names = parseShortSources(`1\talsa_input\tm.c\ts16le\tIDLE\n2\t${MONITOR_NAME}\tm.c\ts16le\tIDLE\n3\t${SOURCE_NAME}\tm.c\ts16le\tRUNNING\n`);
  const json = parseSourceOutputsJson(
    JSON.stringify([
      { index: 10, source: 3, corked: false, properties: { "application.process.id": "100" } },
      { index: 11, source: 3, corked: true, properties: { "application.process.id": "101" } },
      { index: 12, source: 1, corked: false, properties: { "application.process.id": "102" } },
      { index: 13, source: 2, corked: false, properties: { "application.process.id": "103" } },
      { index: 14, source: 3, corked: false, properties: { "application.process.id": String(SELF) } },
      { index: 15, source: 3, corked: false, properties: {} },
    ]),
    names,
  );
  const text = parseSourceOutputsText(
    [
      `Source Output #10\n\tSource: 3\n\tCorked: no\n\tProperties:\n\t\tapplication.process.id = "100"`,
      `Source Output #11\n\tSource: 3\n\tCorked: yes\n\tProperties:\n\t\tapplication.process.id = "101"`,
      `Source Output #12\n\tSource: 1\n\tCorked: no\n\tProperties:\n\t\tapplication.process.id = "102"`,
      `Source Output #13\n\tSource: 2\n\tCorked: no\n\tProperties:\n\t\tapplication.process.id = "103"`,
      `Source Output #14\n\tSource: 3\n\tCorked: no\n\tProperties:\n\t\tapplication.process.id = "${SELF}"`,
      `Source Output #15\n\tSource: 3\n\tCorked: no\n\tProperties:\n\t\tmedia.name = "x"`,
    ].join("\n\n"),
    names,
  );
  assert.deepEqual(json, text);
  assert.deepEqual(consumers(json, SELF), [10, 13, 15]);
  assert.deepEqual(ourModules(`7\tmodule-null-sink\tsink_name=${SINK_NAME} rate=48000\n8\tmodule-remap-source\tmaster=x source_name=${SOURCE_NAME}\n9\tmodule-null-sink\tsink_name=other\n`), [7, 8]);
});

test("open unloads what of ours was left, loads the sink then the source; close unloads them last first", async () => {
  const p = pulse();
  const mic = new LinuxVirtualMic({ run: p.run, spawnFeed: feeds().spawnFeed, pid: SELF });
  assert.deepEqual(await mic.open(), { ok: true });
  assert.deepEqual(p.calls, [
    "pactl list short modules",
    "pactl unload-module 7",
    `pactl load-module module-null-sink sink_name=${SINK_NAME} sink_properties=device.description=still.fail.Mic.Feed rate=48000 channels=1`,
    `pactl load-module module-remap-source master=${MONITOR_NAME} source_name=${SOURCE_NAME} source_properties=device.description=still.fail.Microphone`,
  ]);
  assert.deepEqual(mic.modules, [30, 31]);
  p.calls.length = 0;
  await mic.close();
  assert.deepEqual(p.calls, ["pactl unload-module 31", "pactl unload-module 30"]);
  assert.equal(p.modules.size, 0);
});

test("without pactl it is unavailable, and demand is inactive with the error, never thrown", async () => {
  const p = pulse({ missing: true });
  const mic = new LinuxVirtualMic({ run: p.run, spawnFeed: feeds().spawnFeed, pid: SELF });
  assert.deepEqual(await mic.open(), { ok: false, error: "unavailable: pactl is not installed" });
  const d = await mic.sample();
  assert.equal(d.active, false);
  assert.match(d.error!, /not open/);
});

test("a source failing to load leaves nothing loaded", async () => {
  const p = pulse();
  const run = async (program: string, args: string[]) => {
    if (args[1] === "module-remap-source") throw new Error("pactl load-module ended with 1");
    return p.run(program, args);
  };
  const mic = new LinuxVirtualMic({ run, spawnFeed: feeds().spawnFeed, pid: SELF });
  const r = await mic.open();
  assert.equal(r.ok, false);
  assert.equal(p.modules.size, 0);
});

for (const json of [true, false]) {
  test(`demand and its epoch follow who records (${json ? "JSON" : "text"}); a stop and start between looks is a new lifetime`, async () => {
    const p = pulse({ json });
    const f = feeds();
    const said: MicDemand[] = [];
    const mic = new LinuxVirtualMic({ run: p.run, spawnFeed: f.spawnFeed, pid: SELF, onDemand: (d) => said.push(d) });
    await mic.open();
    assert.deepEqual(await mic.sample(), { active: false, epoch: 0 });
    // Our own stream (the station's) and a corked one are not demand.
    p.outputs.push({ index: 1, source: 3, corked: false, pid: SELF }, { index: 2, source: 3, corked: true, pid: 9 });
    assert.deepEqual(await mic.sample(), { active: false, epoch: 0 });
    p.outputs.push({ index: 3, source: 3, corked: false, pid: 9 });
    assert.deepEqual(await mic.sample(), { active: true, epoch: 1, device: SOURCE_NAME });
    assert.equal(f.started.length, 1);
    assert.deepEqual(f.started[0]!.args, ["--playback", `--device=${SINK_NAME}`, "--format=s16le", "--rate=48000", "--channels=1", "--latency-msec=20"]);
    assert.deepEqual(await mic.sample(), { active: true, epoch: 1, device: SOURCE_NAME }, "unchanged: same epoch");
    // Stopped and started again between two looks: active both times, a new index, so a new epoch (through inactive).
    p.outputs.splice(2, 1, { index: 4, source: 3, corked: false, pid: 9 });
    assert.deepEqual(await mic.sample(), { active: true, epoch: 3, device: SOURCE_NAME });
    assert.deepEqual(said.map((d) => [d.active, d.epoch]), [[true, 1], [false, 2], [true, 3]]);
    assert.equal(f.started.length, 2, "the feed of the old lifetime ended, a new one started");
    assert.equal(f.started[0]!.killed, true);
    // Recording the sink's monitor directly is demand too.
    p.outputs.splice(2, 1, { index: 5, source: 2, corked: false, pid: 9 });
    assert.equal((await mic.sample()).epoch, 5);
    p.outputs.splice(2, 1);
    assert.deepEqual(await mic.sample(), { active: false, epoch: 6 });
    assert.equal(mic.feeding, false);
    assert.equal(f.started[1]!.killed, true);
    await mic.close();
  });
}

test("a query failing is inactive with its error, a new epoch if it was active", async () => {
  const p = pulse({ json: true });
  const mic = new LinuxVirtualMic({ run: p.run, spawnFeed: feeds().spawnFeed, pid: SELF });
  await mic.open();
  p.outputs.push({ index: 3, source: 3, corked: false, pid: 9 });
  assert.equal((await mic.sample()).active, true);
  p.failWith("Connection failure: Connection refused");
  assert.deepEqual(await mic.sample(), { active: false, epoch: 2, error: "Connection failure: Connection refused" });
  assert.deepEqual(await mic.sample(), { active: false, epoch: 2, error: "Connection failure: Connection refused" });
  p.failWith(null);
  assert.deepEqual(await mic.sample(), { active: true, epoch: 3, device: SOURCE_NAME });
  // Our source unloaded behind our back: an error, not demand.
  p.modules.delete(31);
  const d = await mic.sample();
  assert.equal(d.active, false);
  assert.match(d.error!, /source is gone/);
});

test("the feed: dropped without demand, written in order, at most 100 ms queued behind a full pipe (oldest dropped)", async () => {
  const p = pulse({ json: true });
  const f = feeds();
  const mic = new LinuxVirtualMic({ run: p.run, spawnFeed: f.spawnFeed, pid: SELF });
  await mic.open();
  mic.feedPcm16(new Uint8Array(1920));
  assert.equal(f.started.length, 0, "no demand: no pacat");
  p.outputs.push({ index: 3, source: 3, corked: false, pid: 9 });
  await mic.sample();
  const feed = f.started[0]!;
  const chunk = (n: number) => new Uint8Array(1920).fill(n);
  mic.feedPcm16(chunk(1));
  mic.feedPcm16(chunk(2));
  assert.deepEqual(feed.written.map((c) => c[0]), [1, 2]);
  feed.full = true;
  mic.feedPcm16(chunk(3)); // written, and the pipe says full
  for (let i = 4; i < 14; i++) mic.feedPcm16(chunk(i));
  assert.equal(mic.queuedBytes, FEED_MOST_BYTES, "five 20 ms chunks queued, no more");
  assert.equal(mic.dropped, 5 * 1920);
  feed.full = false;
  feed.drain();
  assert.deepEqual(feed.written.map((c) => c[0]), [1, 2, 3, 9, 10, 11, 12, 13], "the newest kept");
  assert.equal(mic.queuedBytes, 0);
  // pacat ending by itself: nothing written to it again until demand starts another.
  feed.exit();
  assert.equal(mic.feeding, false);
  mic.feedPcm16(chunk(20));
  assert.equal(feed.written.length, 8);
  await mic.close();
});

const live = process.env.STILLFAIL_MIC_LIVE === "1";
test("live: a real recorder on the virtual microphone is demand", { skip: live ? false : "set STILLFAIL_MIC_LIVE=1 on a machine with a pulse server (pactl, parecord)" }, async () => {
  const mic = new LinuxVirtualMic();
  const opened = await mic.open();
  assert.deepEqual(opened, { ok: true });
  try {
    assert.equal((await mic.sample()).active, false);
    const rec = spawn("parecord", [`--device=${SOURCE_NAME}`, "--format=s16le", "--rate=48000", "--channels=1", "/dev/null"], { stdio: "ignore" });
    await new Promise((r) => rec.once("spawn", r).once("error", r));
    let d: MicDemand = mic.demand;
    for (let i = 0; i < 100 && !d.active; i++) d = await mic.sample();
    assert.equal(d.active, true, "parecord's stream seen");
    mic.feedPcm16(new Uint8Array(1920));
    assert.equal(mic.feeding, true);
    rec.kill("SIGTERM");
    await new Promise((r) => rec.once("close", r));
    for (let i = 0; i < 100 && d.active; i++) d = await mic.sample();
    assert.equal(d.active, false);
    assert.equal(mic.feeding, false);
  } finally {
    await mic.close();
  }
});
