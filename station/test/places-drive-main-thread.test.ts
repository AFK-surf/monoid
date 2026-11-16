// What the station's main thread waits on as it looks at the places people and agents name (src/ops/places.ts: a
// directory to start in, a file to attach, its links followed up to a folder macOS protects), shows the drive's pinned
// roots (src/drive/drive.ts, the overview's `drive` of every GET /overview) and asks still.fail Helper for a disk's
// grant (src/helper/grants.ts): nothing of node:fs's synchronous calls (station/AGENTS.md, the main thread waits on
// nothing). Each was a stat, an lstat or an opendir on it, which a disk gone or a network file system that does not
// answer holds for as long as it does not.
import assert from "node:assert/strict";
import { lstatSync, mkdirSync, mkdtempSync, readFileSync, realpathSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { randomUUID } from "node:crypto";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { after, test } from "node:test";
import { overview } from "../src/api/overview.ts";
import { Drive, rootViewThrough } from "../src/drive/drive.ts";
import { type Protected, protectedPlaceSoon } from "../src/drive/fs.ts";
import type { HelperApp } from "../src/helper/app.ts";
import { GrantRefused, HelperGrants } from "../src/helper/grants.ts";
import { PlaceRefused, Places, type PlaceHelper, follow, nodeProbe, realOutside, walk } from "../src/ops/places.ts";
import { WINDOWS, platform } from "../src/platform/index.ts";
import { Store } from "../src/store/store.ts";
import { syncCalls } from "./main-thread-sync.ts";

const dirs: string[] = [];
after(() => {
  for (const d of dirs) rmSync(d, { recursive: true, force: true });
});
const temp = (name: string) => {
  const dir = realpathSync(mkdtempSync(join(tmpdir(), name)));
  dirs.push(dir);
  return dir;
};

/// A home with a protected folder (Desktop, by its name) and a folder of the station's that links into it.
function home() {
  const h = temp("places-main-thread-");
  mkdirSync(join(h, "Desktop", "proj"), { recursive: true });
  writeFileSync(join(h, "Desktop", "proj", "a.txt"), "on the desktop");
  mkdirSync(join(h, "work", "app"), { recursive: true });
  writeFileSync(join(h, "work", "notes.txt"), "notes");
  symlinkSync(join(h, "Desktop", "proj"), join(h, "work", "linked"));
  symlinkSync("../work/app", join(h, "work", "rel"));
  symlinkSync(join(h, "Desktop", "proj", "a.txt"), join(h, "work", "desk.txt"));
  return h;
}

/// still.fail Helper as Places sees it: a folder in a protected folder is one.
const helper: PlaceHelper = {
  request: async () => ({ dir: true, file: false, link: false, size: 0, mtime: 0 }),
  ask: async () => "up",
  fs: () => {
    throw new Error("no file copied by the helper in this test");
  },
};

test("a place looked at, walked, its links followed and a file staged wait on no file", { skip: WINDOWS }, async () => {
  const h = home();
  const into = join(h, "uploads");
  const places = new Places({ mac: true, home: h, helper, probe: nodeProbe });
  const plain = new Places({ mac: false, home: h });
  const desk = (p: string) => protectedPlaceSoon(p, h);
  const nowhere = `/Volumes/stillfail-none-${randomUUID()}`;
  let staged = "";
  const calls = await syncCalls(async () => {
    assert.deepEqual(await walk(join(h, "work", "linked", "src"), desk), { state: "protected", path: join(h, "Desktop", "proj", "src"), top: join(h, "Desktop"), helper: true });
    assert.deepEqual(await walk(join(h, "work", "rel"), desk), { state: "ok", real: join(h, "work", "app") });
    assert.deepEqual(await walk(join(h, "work", "notes.txt"), desk), { state: "not_a_directory" });
    assert.deepEqual(await walk(join(h, "work", "nope"), desk), { state: "gone" });
    assert.equal((await follow(join(h, "work", "linked"), desk)).state, "protected");
    assert.equal(await realOutside(join(h, "work", "rel"), h), join(h, "work", "app"));
    assert.equal(await realOutside(join(h, "work", "linked", "x"), h), platform.hasFolderPermissions ? join(h, "Desktop", "proj", "x") : null);
    // A directory: outside the protected folders by the station, in one by the helper; off macOS directly.
    assert.equal(await places.directory(join(h, "work", "rel"), { lang: "en" }), join(h, "work", "app"));
    assert.equal(await places.directory(join(h, "work", "linked"), { lang: "en" }), join(h, "Desktop", "proj"));
    assert.equal(await plain.directory(join(h, "work", "app"), { lang: "en" }), join(h, "work", "app"));
    await assert.rejects(plain.directory(join(h, "work", "nope"), { lang: "en" }), (e: unknown) => e instanceof PlaceRefused && e.code === "gone");
    await assert.rejects(plain.directory(join(h, "work", "notes.txt"), { lang: "en" }), (e: unknown) => e instanceof PlaceRefused && e.code === "not_a_directory");
    // A disk in /Volumes that is not there: looked at off the thread, nothing there.
    assert.equal(places.protects(join(nowhere, "x")), true, "by its name, not known yet: a disk");
    await assert.rejects(places.directory(join(nowhere, "x"), { lang: "en" }), (e: unknown) => e instanceof PlaceRefused && e.code === "gone");
    // A file: outside them, itself; through a link into one, copied off the thread into the uploads.
    assert.equal(await places.file(join(h, "work", "notes.txt"), into, { lang: "en" }, 1024), join(h, "work", "notes.txt"));
    staged = await places.file(join(h, "work", "desk.txt"), into, { lang: "en", self: true }, 1024);
  });
  assert.deepEqual(calls, []);
  assert.equal(readFileSync(staged, "utf8"), "on the desktop");
});

test("the drive's pinned roots, as GET /drive and every GET /overview show them, wait on no file", { skip: WINDOWS }, async () => {
  const h = home();
  const file = join(h, "work", "notes.txt");
  const desktop = join(h, "Desktop", "proj");
  const roots = [join(h, "work", "app"), join(h, "work"), join(h, "gone"), file, desktop];
  const config = { drive: { roots } };
  // still.fail Helper: Desktop granted, as last known.
  const files: Protected = {
    fs: () => {
      throw new Error("nothing listed in this test");
    },
    known: (top) => (top === join(h, "Desktop") ? { grant: "desktop", state: "granted" } : undefined),
    check: () => {},
    ask: async () => "none",
  };
  const drive = new Drive({ config: () => config, protect: () => [], home: h, files });
  const store = Store.open(":memory:");
  const hub: any = { processes: () => [], config: () => ({ dataDir: "/" }) };
  const cloud: any = { state: null };
  const viewer = { sub: "s", email: "person@example.test", name: "P", role: "member", workspace: "w", device: "d" } as const;
  const states = ["ok", "ok", "missing", "not_a_directory", "ok"];
  try {
    const calls = await syncCalls(async () => {
      assert.deepEqual((await drive.roots()).map((r) => r.state), states);
      assert.deepEqual(await rootViewThrough(desktop, files, h), { path: desktop, name: "proj", state: "ok" });
      const seen = (await overview({ store, hub, cloud, config: () => config, rootView: (p) => rootViewThrough(p, files, h) }, viewer, "en")) as any;
      assert.deepEqual(seen.drive.roots.map((r: { state: string }) => r.state), states);
    });
    assert.deepEqual(calls, []);
  } finally {
    store.close();
  }
});

test("a disk's grant asked for, its mounts looked at, waits on no file", { skip: WINDOWS }, async () => {
  const base = temp("grants-main-thread-");
  const volumes = join(base, "Volumes");
  mkdirSync(join(volumes, "Backup"), { recursive: true });
  // The system's own disk is a link to / there: never asked about.
  symlinkSync("/", join(volumes, "Macintosh HD"));
  let up: string[] | null = null;
  const asked: any[] = [];
  const app = {
    listen: () => {},
    onBack: () => {},
    request: async (op: any) => {
      asked.push(op);
      if (op.op === "status") return { capture: true, control: true, files: { removable: "unknown", network: "unknown" }, asking: up !== null, asked: up ?? [] };
      if (op.op === "permissions.show") return void (up = op.grants);
      if (op.op === "files.access") return { access: op.paths.map((p: string) => ({ path: p, top: p, grant: p.endsWith("Backup") ? "removable" : null, state: "unknown" })) };
      throw new Error(`unknown op ${op.op}`);
    },
  } as unknown as HelperApp;
  const grants = new HelperGrants({ helper: app, volumes, mounts: () => [], reach: async () => null, open: () => {} });
  const calls = await syncCalls(async () => {
    assert.equal((await grants.request("removable", {})).window, "up");
    await assert.rejects(grants.request("network", {}), (e: unknown) => e instanceof GrantRefused && e.key === "station.permissions.noNetworkDisk");
  });
  assert.deepEqual(calls, []);
  assert.deepEqual(asked.filter((a) => a.op === "files.access").map((a) => a.paths), [[join(volumes, "Backup")], [join(volumes, "Backup")]]);
  assert.deepEqual(asked.find((a) => a.op === "permissions.show").paths, { removable: join(volumes, "Backup") });
});

test("a place in /Volumes not looked at before goes as what is there: the system's own link and nothing there directly, never through the helper", { skip: WINDOWS }, async () => {
  const h = home();
  let helped = 0;
  const files: Protected = {
    fs: () => {
      helped++;
      throw new Error("not through the helper");
    },
    known: () => undefined,
    check: () => {},
    ask: async () => "none",
  };
  const drive = new Drive({ config: () => ({ drive: { roots: [] } }), protect: () => [], home: h, files });
  // Nothing there, never looked at: no disk, so the station looks itself.
  const nowhere = `/Volumes/stillfail-none-${randomUUID()}`;
  assert.equal((await drive.place(nowhere, "", true)).fs.helper, false);
  // The system's own disk (a link to / there), on a Mac that has it, never looked at in this process.
  const system = "/Volumes/Macintosh HD";
  if (lstatSync(system, { throwIfNoEntry: false })?.isSymbolicLink()) {
    const place = await drive.place(join(system, "private", "tmp"), "", true);
    assert.equal(place.fs.helper, false);
  }
  assert.equal(helped, 0);
});
