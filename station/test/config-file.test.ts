// config.json as settings.rs keeps it: an edit checked, written privately, told; one that does not check out changes
// nothing; fields not known kept; an edit made elsewhere read again. The station's (watched) reads and writes it off the
// main thread (`updateSoon`), an edit made elsewhere read as the system says it changed.
import assert from "node:assert/strict";
import { mkdirSync, mkdtempSync, readFileSync, rmSync, statSync, writeFileSync } from "node:fs";
import { readFile, stat } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import { ConfigFile } from "../src/ops/config.ts";
import { writePrivateSoon } from "../src/ops/files.ts";
import { setStationLang } from "../src/ops/i18n.ts";
import { syncCalls } from "./main-thread-sync.ts";

test("an unreadable initial config is reported without treating it as an empty config", () => {
  setStationLang("en");
  const dir = mkdtempSync(join(tmpdir(), "config-invalid-"));
  const file = join(dir, "config.json");
  const contents = "%TSD-Header-###%secret";
  writeFileSync(file, contents);
  assert.throws(() => new ConfigFile(dir), (error: Error) =>
    error.message.includes(file) && /encrypt/i.test(error.message) && !error.message.includes("secret"));
  assert.equal(readFileSync(file, "utf8"), contents);
});

test("an unreadable external edit keeps the last settings and cannot be overwritten", () => {
  setStationLang("en");
  const dir = mkdtempSync(join(tmpdir(), "config-invalid-edit-"));
  const file = join(dir, "config.json");
  writeFileSync(file, JSON.stringify({ language: "en", profiles: [] }));
  const config = new ConfigFile(dir);
  const contents = "%TSD-Header-###%ciphertext";
  writeFileSync(file, contents);
  assert.equal(config.raw().language, "en");
  assert.throws(() => config.update((raw) => (raw.language = "zh")), /encrypt/i);
  assert.equal(readFileSync(file, "utf8"), contents);
  writeFileSync(file, JSON.stringify({ language: "zh" }));
  assert.equal(config.raw().language, "zh");
});

test("an edit is checked, written privately and told; unknown fields are kept", () => {
  const dir = mkdtempSync(join(tmpdir(), "config-"));
  writeFileSync(join(dir, "config.json"), JSON.stringify({ someday: { x: 1 } }));
  const config = new ConfigFile(dir);
  config.check = (raw) => {
    for (const p of raw.profiles ?? []) if (!/^[a-z0-9-]+$/.test(p.id)) throw new Error(`profile id ${JSON.stringify(p.id)}: use lowercase letters, digits and dashes`);
  };
  const told: any[] = [];
  config.listen((raw) => told.push(raw));
  config.update((raw) => (raw.profiles = [{ id: "cc", home: "homes/cc" }]));
  assert.equal(told.length, 1);
  // Private on Windows by the data directory's ACL (the user's profile's), which keeps no Unix modes.
  if (process.platform !== "win32") assert.equal(statSync(join(dir, "config.json")).mode & 0o777, 0o600);
  const stored = JSON.parse(readFileSync(join(dir, "config.json"), "utf8"));
  assert.deepEqual(stored, { someday: { x: 1 }, profiles: [{ id: "cc", home: "homes/cc" }] });
  assert.throws(() => config.update((raw) => (raw.profiles[0].id = "Bad")), /lowercase/);
  assert.equal(config.raw().profiles[0].id, "cc");
  assert.equal(JSON.parse(readFileSync(join(dir, "config.json"), "utf8")).profiles[0].id, "cc");
  // Written by something else: read again, and told.
  writeFileSync(join(dir, "config.json"), JSON.stringify({ language: "en", profiles: [] }) + "\n   ");
  assert.equal(config.raw().language, "en");
  assert.equal(told.length, 2);
});

/// A config of a directory of its own, watched as the station's is (services.ts StationConfig).
function watched(contents: unknown, check?: (raw: any) => void): { dir: string; file: string; config: ConfigFile } {
  const dir = mkdtempSync(join(tmpdir(), "config-watched-"));
  const file = join(dir, "config.json");
  writeFileSync(file, JSON.stringify(contents));
  const config = new ConfigFile(dir);
  if (check) config.check = check;
  config.watch();
  return { dir, file, config };
}

/// Once the config heard is one `f` holds of.
const heard = (config: ConfigFile, f: (raw: any) => boolean) =>
  new Promise<any>((resolve) => {
    const stop = config.listen((raw) => {
      if (!f(raw)) return;
      stop();
      resolve(raw);
    });
  });

test("watched, an edit, a read and an edit made elsewhere wait on no file, and the one elsewhere is told", async () => {
  const { file, config } = watched({ kept: true });
  const told: any[] = [];
  config.listen((raw) => told.push(raw));
  try {
    const calls = await syncCalls(async () => {
      const edited = await config.updateSoon((raw) => (raw.a = 1));
      assert.deepEqual(edited, { kept: true, a: 1 });
      assert.deepEqual(config.raw(), { kept: true, a: 1 });
      // On disk once it resolves: what reads the file next (the MoonBit readers, another process) reads it.
      assert.deepEqual(JSON.parse(await readFile(file, "utf8")), { kept: true, a: 1 });
      // Written beside and renamed into place, as `stillfail channel`, the installer and editors write it.
      const there = heard(config, (raw) => raw.b === 2);
      await writePrivateSoon(file, JSON.stringify({ kept: true, a: 1, b: 2 }));
      await there;
      assert.deepEqual(config.raw(), { kept: true, a: 1, b: 2 });
      // Written back elsewhere to the very text this process wrote: someone's edit too, taken and told.
      const back = heard(config, (raw) => raw.b === undefined);
      await writePrivateSoon(file, `${JSON.stringify({ kept: true, a: 1 }, null, 2)}\n`);
      await back;
      assert.deepEqual(config.raw(), { kept: true, a: 1 });
    });
    assert.deepEqual(calls, []);
    // Its own write read back is not told again.
    assert.deepEqual(told, [{ kept: true, a: 1 }, { kept: true, a: 1, b: 2 }, { kept: true, a: 1 }]);
    if (process.platform !== "win32") assert.equal((await stat(file)).mode & 0o777, 0o600);
  } finally {
    config.unwatch();
    await config.written();
  }
});

test("edits taken together are written in their order, and one that does not check out changes nothing", async () => {
  const { file, config } = watched({ n: [] }, (raw) => {
    if (raw.bad === true) throw new Error("bad is refused");
  });
  try {
    const all = await Promise.all([1, 2, 3].map((k) => config.updateSoon((raw) => raw.n.push(k))));
    assert.deepEqual(all.map((raw) => raw.n), [[1], [1, 2], [1, 2, 3]]);
    assert.deepEqual(JSON.parse(await readFile(file, "utf8")), { n: [1, 2, 3] });
    const before = await readFile(file, "utf8");
    await assert.rejects(config.updateSoon((raw) => (raw.bad = true)), /bad is refused/);
    assert.deepEqual(config.raw(), { n: [1, 2, 3] });
    assert.equal(await readFile(file, "utf8"), before);
  } finally {
    config.unwatch();
    await config.written();
  }
});

test("a write that fails is its edit's caller's to hear, and the edits after it are written", async () => {
  const { file, config } = watched({ n: 0 });
  try {
    // Nothing can be renamed onto a directory that holds something, whoever runs the test.
    rmSync(file);
    mkdirSync(join(file, "in-the-way"), { recursive: true });
    await assert.rejects(config.updateSoon((raw) => (raw.n = 1)));
    await assert.rejects(config.updateSoon((raw) => (raw.n = 2)));
    rmSync(file, { recursive: true });
    await config.updateSoon((raw) => (raw.n = 3));
    assert.deepEqual(JSON.parse(await readFile(file, "utf8")), { n: 3 });
  } finally {
    config.unwatch();
    await config.written();
  }
});

test("unwatched, an edit takes what was edited elsewhere, and refuses a file that cannot be read until it can", async () => {
  setStationLang("en");
  const dir = mkdtempSync(join(tmpdir(), "config-unwatched-"));
  const file = join(dir, "config.json");
  writeFileSync(file, JSON.stringify({ language: "en" }));
  const config = new ConfigFile(dir);
  writeFileSync(file, JSON.stringify({ language: "en", elsewhere: true }));
  await config.updateSoon((raw) => (raw.here = true));
  assert.deepEqual(JSON.parse(await readFile(file, "utf8")), { language: "en", elsewhere: true, here: true });
  writeFileSync(file, "%TSD-Header-###%ciphertext");
  await assert.rejects(config.updateSoon((raw) => (raw.language = "zh")), /encrypt/i);
  assert.equal(await readFile(file, "utf8"), "%TSD-Header-###%ciphertext");
  // What was good before the file went bad stays for readers meanwhile.
  assert.deepEqual(config.raw(), { language: "en", elsewhere: true, here: true });
  writeFileSync(file, JSON.stringify({ language: "zh" }));
  await config.updateSoon((raw) => (raw.again = true));
  assert.deepEqual(JSON.parse(await readFile(file, "utf8")), { language: "zh", again: true });
  assert.deepEqual(config.raw(), { language: "zh", again: true });
});
