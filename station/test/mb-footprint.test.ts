// A directory's size on disk by the MoonBit program (`--builder footprint`, station/mb src/footprint; the station's
// sessions/footprint.ts) held to the main thread's walk it replaced (test/footprint-reference.ts) on the same trees:
// the same bytes, the same rebuildable directories and sizes in the same order, cut short at the same place and for
// the same reason, stopped past a limit at the same count, failing on the same errors.
import assert from "node:assert/strict";
import { chmodSync, linkSync, mkdirSync, mkdtempSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { after, test } from "node:test";
import { MbProcess, mbReaderBinary } from "../src/read/mb-reader.ts";
import { platform } from "../src/platform/index.ts";
import { measureRoom, measured, measuredUpTo } from "../src/sessions/footprint.ts";
import { measureRoomReference, measuredReference, measuredUpToReference } from "./footprint-reference.ts";

const binary = mbReaderBinary();
const skip = binary === null ? "the MoonBit program (stillfail-reader) is not built here" : false;

const dirs: string[] = [];
after(() => {
  for (const dir of dirs) {
    try { chmodSync(dir, 0o755); } catch {}
    rmSync(dir, { recursive: true, force: true });
  }
});
const fresh = () => {
  const dir = mkdtempSync(join(tmpdir(), "footprint-"));
  dirs.push(dir);
  return dir;
};
const write = (path: string, bytes: number) => {
  mkdirSync(join(path, ".."), { recursive: true });
  writeFileSync(path, Buffer.alloc(bytes, 7));
};

/// A workspace with something of everything a measure tells apart.
function workspace(): string {
  const root = fresh();
  write(join(root, "src/main.ts"), 5_000);
  write(join(root, "src/deep/a/b/c.txt"), 9_000);
  // A file with three names, one of them in what is made again.
  write(join(root, "data/big"), 64_000);
  linkSync(join(root, "data/big"), join(root, "data/big2"));
  mkdirSync(join(root, "app"), { recursive: true });
  // What is made again, each kind, and what only looks it.
  write(join(root, "app/node_modules/pkg/index.js"), 20_000);
  write(join(root, "app/node_modules/pkg/node_modules/inner/x.js"), 3_000);
  linkSync(join(root, "data/big"), join(root, "app/node_modules/pkg/big"));
  write(join(root, "web/.next/cache/x"), 12_000);
  write(join(root, "web/.turbo/log"), 1_000);
  write(join(root, "py/__pycache__/m.pyc"), 2_000);
  write(join(root, "rs/Cargo.toml"), 100);
  write(join(root, "rs/target/debug/bin"), 30_000);
  write(join(root, "notrs/target/out"), 4_000);
  write(join(root, "android/settings.gradle"), 100);
  write(join(root, "android/.gradle/caches/x"), 6_000);
  write(join(root, "kt/build.gradle.kts"), 100);
  write(join(root, "kt/build/classes/A.class"), 7_000);
  write(join(root, "site/build/index.html"), 2_500);
  // Known by what is near or in them (the room a checkout: its .git below): Elixir's build and dependencies, MoonBit's
  // build beside its manifest and below one within the checkout, its packages; Xcode's derived data and a Cargo target
  // of any name by what is in them; and what only looks it.
  write(join(root, "ex/mix.exs"), 100);
  write(join(root, "ex/_build/dev/lib/a.beam"), 3_000);
  write(join(root, "ex/deps/jason/mix.exs"), 800);
  write(join(root, "mb/moon.mod.json"), 100);
  write(join(root, "mb/src/moon.pkg.json"), 100);
  write(join(root, "mb/_build/native/debug/a.o"), 5_000);
  write(join(root, "mb/src/lib/_build/x.o"), 1_200);
  write(join(root, "mb/.mooncakes/core/x.mbt"), 2_200);
  write(join(root, "mb-new/moon.mod"), 100);
  write(join(root, "mb-new/src/moon.pkg"), 100);
  write(join(root, "mb-new/_build/native/debug/a.o"), 5_000);
  write(join(root, "mb-new/src/lib/_build/x.o"), 1_200);
  write(join(root, "mb-new/.mooncakes/core/x.mbt"), 2_200);
  write(join(root, "notmb/_build/out"), 1_100);
  write(join(root, "notex/deps/x"), 900);
  write(join(root, "ios-dd/Build/Products/Debug/App"), 8_000);
  write(join(root, "ios-dd/Build/Intermediates.noindex/x.o"), 3_300);
  write(join(root, "notios/Build/Products/App"), 700);
  write(join(root, "rs-out/debug/deps/libx.rlib"), 9_500);
  writeFileSync(join(root, "rs-out/CACHEDIR.TAG"), "Signature: 8a477f597d28d172789f06886806bc55\r\n# This file is a cache directory tag created by cargo.\n# For information about cache directory tags see https://bford.info/cachedir/\n");
  write(join(root, "rs-info/.rustc_info.json"), 300);
  writeFileSync(join(root, "rs-info/CACHEDIR.TAG"), "Signature: 8a477f597d28d172789f06886806bc55\n# This file is a cache directory tag created by cargo.");
  write(join(root, "notrs-tag/debug/deps/x"), 600);
  writeFileSync(join(root, "notrs-tag/CACHEDIR.TAG"), "Signature: 8a477f597d28d172789f06886806bc55\n# made by something else\n");
  // Never found in a repository's metadata or the attachments, but counted.
  write(join(root, ".git/objects/pack/p"), 40_000);
  write(join(root, ".git/node_modules/meta"), 1_000);
  write(join(root, "uploads/node_modules/evidence.js"), 1_500);
  // Links: one back up (a loop if followed), one out of the tree, one dangling.
  const outside = fresh();
  write(join(outside, "node_modules/huge"), 200_000);
  symlinkSync(root, join(root, "src/up"));
  symlinkSync(outside, join(root, "out"));
  symlinkSync(join(root, "nowhere"), join(root, "dangling"));
  return root;
}

const roomOfBoth = async (root: string, budget?: { maxEntries?: number }) => {
  const [program, reference] = [await measureRoom(root, budget), await measureRoomReference(root, budget)];
  return { program, reference };
};

test("a room's size and what is made again in it are the walk's, each kind of it, hard links once, links not followed", { skip }, async () => {
  const root = workspace();
  const { program, reference } = await roomOfBoth(root);
  assert.deepEqual(program, reference);
  assert.deepEqual(program.rebuild.map(([p]) => p.slice(root.length + 1)).sort(),
    ["android/.gradle", "app/node_modules", "ex/_build", "ex/deps", "ios-dd", "kt/build", "mb-new/.mooncakes", "mb-new/_build", "mb-new/src/lib/_build", "mb/.mooncakes", "mb/_build", "mb/src/lib/_build", "py/__pycache__",
      "rs-info", "rs-out", "rs/target", "web/.next", "web/.turbo"]);
  assert.equal(await measured(root), await measuredReference(root));
  assert.deepEqual(await measuredUpTo(root, Number.MAX_SAFE_INTEGER), await measuredUpToReference(root, Number.MAX_SAFE_INTEGER));
  // (the file of three names counted once: a measure of where it is alone is as much)
  assert.ok(await measured(join(root, "data")) >= 64_000);
  // A room that is not there is nothing.
  assert.deepEqual(await measureRoom(join(root, "none")), { bytes: 0, rebuild: [], complete: true });
});

test("cut short at every count of entries as the walk is, what is made again included", { skip }, async () => {
  const root = workspace();
  for (let most = 0; most <= 120; most++) {
    const { program, reference } = await roomOfBoth(root, { maxEntries: most });
    assert.deepEqual(program, reference, `maxEntries ${most}`);
    const [p, r] = [await measuredUpTo(root, Number.MAX_SAFE_INTEGER, undefined, { maxEntries: most }), await measuredUpToReference(root, Number.MAX_SAFE_INTEGER, undefined, { maxEntries: most })];
    assert.deepEqual(p, { bytes: r.bytes, complete: r.complete, ...(r.truncated ? { truncated: true } : {}) }, `maxEntries ${most}`);
  }
});

test("stopped as it counts past its limit at the same count, not truncated", { skip }, async () => {
  const root = workspace();
  const whole = await measured(root);
  for (const limit of [0, 1, 4096, 10_000, 50_000, 100_000, 200_000, whole - 1, whole]) {
    const [p, r] = [await measuredUpTo(root, limit), await measuredUpToReference(root, limit)];
    assert.deepEqual(p, r, `limit ${limit}`);
    assert.equal(p.truncated, undefined);
  }
});

test("no deeper than 32 below a root, each found directory's walk its own", { skip }, async () => {
  const root = fresh();
  let deep = root;
  for (let i = 0; i < 40; i++) deep = join(deep, `d${i}`);
  write(join(deep, "bottom"), 10_000);
  let found = join(root, "x");
  for (let i = 0; i < 20; i++) found = join(found, `e${i}`);
  write(join(found, "node_modules", ...Array.from({ length: 35 }, (_, i) => `n${i}`), "f"), 10_000);
  const up = await measuredUpTo(root, Number.MAX_SAFE_INTEGER);
  const ref = await measuredUpToReference(root, Number.MAX_SAFE_INTEGER);
  assert.deepEqual(up, { bytes: ref.bytes, complete: false, truncated: true });
  assert.equal(ref.reason, "depth");
  const { program, reference } = await roomOfBoth(root);
  assert.deepEqual(program, reference);
  assert.equal(program.rebuild.length, 1);
});

const unreadable = platform.os === "windows" || process.getuid?.() === 0 ? "a directory this user cannot read (not on Windows, nor as root)" : false;

test("strict, an error of the disk fails it as the walk's did; else what cannot be read is passed over", { skip: skip || unreadable }, async () => {
  const root = workspace();
  const locked = join(root, "locked");
  write(join(locked, "secret"), 10_000);
  chmodSync(locked, 0);
  try {
    const failed = (p: Promise<unknown>) => p.then(() => null, (e: NodeJS.ErrnoException) => ({ code: e.code, message: e.message }));
    const [p, r] = [await failed(measuredUpTo(root, Number.MAX_SAFE_INTEGER)), await failed(measuredUpToReference(root, Number.MAX_SAFE_INTEGER))];
    assert.deepEqual(p, r);
    assert.equal(p?.code, "EACCES");
    assert.equal(await measured(root), await measuredReference(root));
    const { program, reference } = await roomOfBoth(root);
    assert.deepEqual(program, reference);
    // A path gone is nothing, strict or not.
    assert.deepEqual(await measuredUpTo(join(root, "gone"), 1), { bytes: 0, complete: true });
  } finally {
    chmodSync(locked, 0o755);
  }
});

test("an abort ends the program at once and fails the measure with its reason", { skip }, async () => {
  const root = fresh();
  for (let d = 0; d < 20; d++) for (let f = 0; f < 200; f++) write(join(root, `d${d}`, `f${f}`), 10);
  const before = new AbortController();
  before.abort(new Error("called off"));
  await assert.rejects(measuredUpTo(root, Number.MAX_SAFE_INTEGER, before.signal), /called off/);
  const during = new AbortController();
  const programs = () => MbProcess.live().filter((p) => p.args.includes("footprint"));
  const was = programs().length;
  const measuring = measuredUpTo(root, Number.MAX_SAFE_INTEGER, during.signal);
  const running = programs();
  assert.equal(running.length, was + 1);
  assert.equal(running.at(-1)!.background, true, "the system's background work");
  during.abort();
  await assert.rejects(measuring, { name: "AbortError" });
});
