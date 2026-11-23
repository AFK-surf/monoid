// Drift guard for the slimmed `stillfail-reader` dependency graph and 3-layer native cache keys:
// 1. Parses `station/mb/src/reader/moon.pkg` transitively across all `station/*` packages.
// 2. Asserts frozen whole-station packages (`station_main`, `drive`, `cloud_lock`, `api_routes`,
//    `session_hub`, etc.) are never transitively reachable from `reader`.
// 3. Asserts every transitive `station/*` package of `reader` is listed in both `scripts/native.ts`
//    (`READER_PKGS`) and `station/mb/build.sh` (`READER_SRC_PKGS`), with no drift in either direction.
// 4. Asserts every `.c` file inside `reader`'s transitive packages is listed in `station/mb/build.sh`
//    (`READER_C_STUBS`), and no frozen C stub (`station_main/*.c`, `drive/drive.c`) is compiled into `reader`.
import assert from "node:assert/strict";
import { existsSync, readdirSync, readFileSync, statSync } from "node:fs";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { test } from "node:test";

const root = fileURLToPath(new URL("../..", import.meta.url));
const mbSrc = join(root, "station", "mb", "src");

function transitiveReaderPackages(): Set<string> {
  const visited = new Set<string>(["reader"]);
  const queue = ["reader"];
  while (queue.length > 0) {
    const pkg = queue.shift()!;
    const pkgFile = join(mbSrc, pkg, "moon.pkg");
    assert.ok(existsSync(pkgFile), `missing moon.pkg for station/${pkg}`);
    const text = readFileSync(pkgFile, "utf8");
    for (const m of text.matchAll(/"station\/([^"]+)"/g)) {
      const dep = m[1]!;
      if (!visited.has(dep)) {
        visited.add(dep);
        queue.push(dep);
      }
    }
  }
  return visited;
}

function parseNativeReaderPkgs(): string[] {
  const text = readFileSync(join(root, "scripts", "native.ts"), "utf8");
  const m = /const READER_PKGS = \[([\s\S]*?)\];/.exec(text);
  assert.ok(m, "scripts/native.ts must define `const READER_PKGS = [...]`");
  return [...m[1]!.matchAll(/"([^"]+)"/g)].map((x) => x[1]!);
}

function parseBuildShArray(name: string): string[] {
  const text = readFileSync(join(root, "station", "mb", "build.sh"), "utf8");
  const m = new RegExp(`${name}=\\(([\\s\\S]*?)\\)`).exec(text);
  assert.ok(m, `station/mb/build.sh must define ${name}=(...)`);
  return m[1]!.trim().split(/\s+/).filter(Boolean);
}

test("reader transitive dependencies never include station_main or frozen whole-station packages", () => {
  const deps = transitiveReaderPackages();
  const forbidden = [
    "station_main",
    "drive",
    "cloud_lock",
    "api_routes",
    "session_hub",
    "session_chats",
    "mcp_tools",
    "accounts_pool",
    "accounts_oauth",
    "vault_service",
    "reader_harness",
  ];
  const found = forbidden.filter((pkg) => deps.has(pkg));
  assert.deepEqual(found, [], `stillfail-reader must not transitively depend on frozen packages: ${found.join(", ")}`);
  assert.ok(deps.has("reader") && deps.has("host") && deps.has("sql") && deps.has("readops"), "sanity check core reader deps");
});

test("scripts/native.ts READER_PKGS and station/mb/build.sh READER_SRC_PKGS match reader's exact transitive dependency graph", () => {
  const actual = [...transitiveReaderPackages()].sort();
  const nativePkgs = [...new Set(parseNativeReaderPkgs())].sort();
  const buildShPkgs = [...new Set(parseBuildShArray("READER_SRC_PKGS"))].sort();

  const missingInNative = actual.filter((p) => !nativePkgs.includes(p));
  const extraInNative = nativePkgs.filter((p) => !actual.includes(p));
  assert.deepEqual(
    { missingInNative, extraInNative },
    { missingInNative: [], extraInNative: [] },
    "scripts/native.ts READER_PKGS drifted from station/mb/src/reader/moon.pkg transitive deps",
  );

  const missingInBuildSh = actual.filter((p) => !buildShPkgs.includes(p));
  const extraInBuildSh = buildShPkgs.filter((p) => !actual.includes(p));
  assert.deepEqual(
    { missingInBuildSh, extraInBuildSh },
    { missingInBuildSh: [], extraInBuildSh: [] },
    "station/mb/build.sh READER_SRC_PKGS drifted from station/mb/src/reader/moon.pkg transitive deps",
  );
});

test("station/mb/build.sh READER_C_STUBS matches all C files in reader's transitive packages and excludes frozen C stubs", () => {
  const deps = transitiveReaderPackages();
  const expectedC: string[] = [];
  for (const pkg of [...deps].sort()) {
    const dir = join(mbSrc, pkg);
    if (!existsSync(dir) || !statSync(dir).isDirectory()) continue;
    for (const entry of readdirSync(dir).sort()) {
      if (entry.endsWith(".c")) expectedC.push(`${pkg}/${entry}`);
    }
  }
  const buildStubs = [...new Set(parseBuildShArray("READER_C_STUBS"))].sort();
  assert.deepEqual(
    buildStubs,
    expectedC.sort(),
    "station/mb/build.sh READER_C_STUBS must match C files in reader's transitive deps",
  );
  for (const stub of buildStubs) {
    assert.ok(!stub.startsWith("station_main/"), `frozen stub leaked into reader: ${stub}`);
    assert.ok(stub !== "drive/drive.c", `frozen stub leaked into reader: ${stub}`);
  }
});
