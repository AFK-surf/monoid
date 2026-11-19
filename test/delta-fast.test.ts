import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { test } from "node:test";
import { crc32, deflateRawSync, inflateRawSync } from "node:zlib";
import { apply, ensureNativeDelta, makeApk, makeDelta, makeTree, parseHeader, readOld, sameBlocks, wholeFiles } from "../scripts/delta.ts";
import * as delta from "../scripts/delta.ts";

// scripts/delta-fast.c makes what delta.ts's own search makes: the same bsdiff records byte for byte (only their
// deflating may differ, zlib's against node's), so every delta it makes gives the package back.

const native = spawnSync("cc", ["--version"]).status === 0 ? ensureNativeDelta() : null;
const skip = native ? false : "no C compiler with zlib here: delta-fast.c not tested";

function prng(seed: number) {
  return () => {
    seed = (seed + 0x6d2b79f5) | 0;
    let t = Math.imul(seed ^ (seed >>> 15), 1 | seed);
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}
const random = (rand: () => number, n: number) => { const b = Buffer.alloc(n); for (let i = 0; i < n; i++) b[i] = (rand() * 256) | 0; return b; };
const texty = (rand: () => number, n: number) => {
  const words = Array.from({ length: 64 }, () => random(rand, 2 + Math.floor(rand() * 10)));
  const out: Buffer[] = [];
  for (let size = 0; size < n;) { const w = words[Math.floor(rand() * words.length)]!; out.push(w); size += w.length; }
  return Buffer.concat(out).subarray(0, n);
};
const edited = (rand: () => number, b: Buffer, every: number) => {
  const c = Buffer.from(b);
  for (let at = Math.floor(rand() * every); at < c.length; at += 1 + Math.floor(rand() * every)) c[at] = (rand() * 256) | 0;
  return c;
};

/** `fn` with these environment variables (undefined: unset), as they were after. */
function withEnv<T>(vars: Record<string, string | undefined>, fn: () => T): T {
  const before = Object.fromEntries(Object.keys(vars).map((k) => [k, process.env[k]]));
  const set = (v: Record<string, string | undefined>) => { for (const [k, x] of Object.entries(v)) if (x === undefined) delete process.env[k]; else process.env[k] = x; };
  set(vars);
  try { return fn(); } finally { set(before); }
}
const inC = <T>(fn: () => T) => withEnv({ STILLFAIL_DELTA_FAST_FORCE: "1", STILLFAIL_DELTA_JS: undefined }, () => {
  const r = fn();
  assert.equal(delta.lastMaker, "native", "made by delta-fast.c");
  return r;
});
const inJs = <T>(fn: () => T) => withEnv({ STILLFAIL_DELTA_FAST_FORCE: undefined, STILLFAIL_DELTA_JS: "1" }, () => {
  const r = fn();
  assert.equal(delta.lastMaker, "js");
  return r;
});

/** The bsdiff records of a delta: its chunks inflated, one after another. */
function records(d: Buffer): Buffer {
  const out: Buffer[] = [];
  for (let at = parseHeader(d).payload!; ;) {
    const raw = d.readUInt32LE(at), packed = d.readUInt32LE(at + 4);
    if (raw === 0) break;
    out.push(inflateRawSync(d.subarray(at + 8, at + 8 + packed)));
    at += 8 + packed;
  }
  return Buffer.concat(out);
}

/** What a delta made of the old blob gives back: the package, byte for byte. */
function gives(d: Buffer, old: Buffer, made: Buffer) {
  const out: Buffer[] = [];
  apply(parseHeader(d), old, d, (b) => out.push(Buffer.from(b)));
  assert.ok(Buffer.concat(out).equals(made), "the delta gives the package");
}

const blobOf = (parts: Buffer[]) => {
  const ranges = [];
  for (let at = 0, i = 0; i < parts.length; at += parts[i]!.length, i++) ranges.push({ at, len: parts[i]!.length });
  return { blob: Buffer.concat(parts), ranges };
};

test("delta-fast.c's records are delta.ts's, on small and odd inputs", { skip }, () => {
  const rand = prng(42);
  const base = texty(rand, 50_000);
  const cases: [string, Buffer, Buffer][] = [
    ["nothing to nothing", Buffer.alloc(0), Buffer.alloc(0)],
    ["nothing to some", Buffer.alloc(0), random(rand, 3000)],
    ["some to nothing", random(rand, 3000), Buffer.alloc(0)],
    ["one byte each", Buffer.from([7]), Buffer.from([9])],
    ["two bytes", Buffer.from([1, 1]), Buffer.from([1, 1, 1])],
    ["zeros", Buffer.alloc(200_000), Buffer.concat([Buffer.alloc(100_000), Buffer.from("x"), Buffer.alloc(150_000)])],
    ["a byte said over", Buffer.alloc(70_000, 0xaa), Buffer.alloc(90_000, 0xab)],
    ["shifted and edited", base, Buffer.concat([random(rand, 777), edited(rand, base.subarray(20_000), 3000), base.subarray(0, 20_000)])],
    ["random to random", random(rand, 40_000), random(rand, 40_000)],
  ];
  for (const [what, old, made] of cases) {
    const c = inC(() => makeDelta(old, made, [], [], []));
    const js = inJs(() => makeDelta(old, made, [], [], []));
    gives(c, old, made);
    assert.ok(records(c).equals(records(js)), `${what}: the same records`);
  }
});

test("delta-fast.c with the old files found whole (sparse) and with too few found (the whole blob sorted)", { skip }, () => {
  const rand = prng(9570);
  const kept = [texty(rand, 30_000), random(rand, 12_000), texty(rand, 200_000)], big = texty(rand, 300_000);
  const old = blobOf([kept[0]!, big, kept[1]!, kept[2]!]);
  const shifted = Buffer.concat([big.subarray(0, 100_000), random(rand, 300), edited(rand, big.subarray(100_000), 20_000)]);
  const sparse = Buffer.concat([kept[2]!, shifted, random(rand, 5000), kept[0]!, kept[1]!]);
  const runs = sameBlocks(old.blob, sparse, wholeFiles(old.blob, old.ranges, sparse));
  assert.ok(runs.length > 3);
  const few = blobOf([random(rand, 100_000), kept[1]!, random(rand, 90_000)]);
  const whole = Buffer.concat([edited(rand, few.blob.subarray(0, 100_000), 50), kept[1]!, random(rand, 20_000)]);
  assert.ok(wholeFiles(few.blob, few.ranges, whole).reduce((n, r) => n + r.len, 0) < few.blob.length / 8);
  for (const [what, o, made] of [["sparse", old, sparse], ["whole", few, whole]] as const) {
    const c = inC(() => makeDelta(o.blob, made, [], [], [], o.ranges));
    const js = inJs(() => makeDelta(o.blob, made, [], [], [], o.ranges));
    gives(c, o.blob, made);
    assert.ok(records(c).equals(records(js)), `${what}: the same records`);
  }
});

test("delta-fast.c takes runs that overlap, as sameBlocks makes them where a block followed back reaches a run before it", { skip }, () => {
  const rand = prng(10321);
  const r1 = random(rand, 2048), z = random(rand, 2048);
  // (made's Z is found at old's 2560 and followed back over R1's last 512 bytes, which old has before it too)
  const old = Buffer.concat([r1, r1.subarray(1536), z]), made = Buffer.concat([r1, z, random(rand, 300)]);
  const runs = sameBlocks(old, made, []);
  assert.ok(runs.some((r, i) => i > 0 && runs[i - 1]!.made + runs[i - 1]!.len > r.made), `overlapping runs: ${JSON.stringify(runs)}`);
  const parts = blobOf([r1, r1.subarray(1536), z]);
  const c = inC(() => makeDelta(old, made, [], [], [], parts.ranges));
  const js = inJs(() => makeDelta(old, made, [], [], [], parts.ranges));
  gives(c, old, made);
  assert.ok(records(c).equals(records(js)), "the same records");
});

test("a folder's and an apk's delta made by delta-fast.c give the package back", { skip }, (t) => {
  const dir = mkdtempSync(join(tmpdir(), "delta-fast-test-"));
  t.after(() => rmSync(dir, { recursive: true, force: true }));
  const rand = prng(8147);
  const files: Record<string, Buffer> = { "a/app": texty(rand, 120_000), "a/lib.so": random(rand, 60_000), "b/data": texty(rand, 40_000) };
  for (const [p, b] of Object.entries(files)) { mkdirSync(dirname(join(dir, "old", p)), { recursive: true }); writeFileSync(join(dir, "old", p), b); }
  const neu = Buffer.concat([files["b/data"]!, edited(rand, files["a/app"]!, 9000), Buffer.from("tar-ish"), files["a/lib.so"]!]);
  writeFileSync(join(dir, "new"), neu);
  inC(() => makeTree(join(dir, "old"), join(dir, "new"), join(dir, "d.delta")));
  const d = readFileSync(join(dir, "d.delta")), out: Buffer[] = [];
  apply(parseHeader(d), readOld(parseHeader(d), { dir: join(dir, "old") }), d, (b) => out.push(Buffer.from(b)));
  assert.ok(Buffer.concat(out).equals(neu));
  // (an apk: one entry deflated in both, changed; one stored)
  const js = texty(rand, 80_000), lib = random(rand, 30_000);
  writeFileSync(join(dir, "old.apk"), zip([["index.bundle", js, true], ["lib.so", lib, false]]));
  writeFileSync(join(dir, "new.apk"), zip([["index.bundle", Buffer.concat([js.subarray(0, 40_000), Buffer.from("8147"), js.subarray(40_000)]), true], ["lib.so", edited(rand, lib, 5000), false]]));
  assert.equal(inC(() => makeApk(join(dir, "old.apk"), join(dir, "new.apk"), join(dir, "a.delta"))), 1);
});

test("from PREFIXED_FROM old bytes delta-fast.c makes the delta by itself, the same records as delta.ts's, its size alike", { skip }, (t) => {
  const rand = prng(2026);
  const old = texty(rand, 2 << 20);
  const made = Buffer.concat([old.subarray(0, 500_000), random(rand, 4000), edited(rand, old.subarray(500_000, 1_500_000), 4000), old.subarray(1_600_000)]);
  const time = (fn: () => Buffer) => { const at = performance.now(); const d = fn(); return { d, ms: performance.now() - at }; };
  const c = withEnv({ STILLFAIL_DELTA_FAST_FORCE: undefined, STILLFAIL_DELTA_JS: undefined }, () => time(() => makeDelta(old, made, [], [], [])));
  assert.equal(delta.lastMaker, "native");
  const js = inJs(() => time(() => makeDelta(old, made, [], [], [])));
  t.diagnostic(`C ${c.d.length} bytes in ${c.ms.toFixed(0)} ms, JavaScript ${js.d.length} bytes in ${js.ms.toFixed(0)} ms`);
  gives(c.d, old, made);
  assert.ok(records(c.d).equals(records(js.d)), "the same records");
  assert.ok(Math.abs(c.d.length - js.d.length) <= js.d.length * 0.05 + 1024, `${c.d.length} bytes against ${js.d.length}`);
});

/** A zip as a minimal writer makes one (node's deflate, level 6: what the delta's check makes again). */
function zip(entries: [string, Buffer, boolean][]): Buffer {
  const locals: Buffer[] = [], central: Buffer[] = [];
  let offset = 0;
  for (const [n, data, deflate] of entries) {
    const name = Buffer.from(n), body = deflate ? deflateRawSync(data, { level: 6 }) : data;
    const fields = (h: Buffer, at: number) => {
      h.writeUInt16LE(deflate ? 8 : 0, at);
      h.writeUInt32LE(crc32(data), at + 6);
      h.writeUInt32LE(body.length, at + 10);
      h.writeUInt32LE(data.length, at + 14);
      h.writeUInt16LE(name.length, at + 18);
    };
    const local = Buffer.alloc(30);
    local.writeUInt32LE(0x04034b50, 0);
    local.writeUInt16LE(20, 4);
    fields(local, 8);
    const c = Buffer.alloc(46);
    c.writeUInt32LE(0x02014b50, 0);
    c.writeUInt16LE(20, 4);
    c.writeUInt16LE(20, 6);
    fields(c, 10);
    c.writeUInt32LE(offset, 42);
    locals.push(local, name, body);
    central.push(c, name);
    offset += 30 + name.length + body.length;
  }
  const cd = Buffer.concat(central), end = Buffer.alloc(22);
  end.writeUInt32LE(0x06054b50, 0);
  end.writeUInt16LE(entries.length, 8);
  end.writeUInt16LE(entries.length, 10);
  end.writeUInt32LE(cd.length, 12);
  end.writeUInt32LE(offset, 16);
  return Buffer.concat([...locals, cd, end]);
}
