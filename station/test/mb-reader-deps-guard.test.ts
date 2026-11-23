// Drift guard for the slimmed `stillfail-reader` dependency graph and 3-layer native cache keys:
// 1. Parses `station/mb/src/reader/moon.pkg` transitively across all `station/*` packages (ignoring comments
//    and test-only import blocks).
// 2. Asserts frozen whole-station packages (`station_main`, `drive`, `cloud_lock`, `api_routes`, `session_hub`, ...)
//    are never transitively reachable from `reader`.
// 3. Asserts all non-`station/*`, non-`moonbitlang/*` workspace imports stay strictly within the allowed
//    whitelist (`base/*`, `ui/effect`, `ui/halt`), with negative assertions for `ui/signals` and `stillfail/rules/lock`.
// 4. Asserts every transitive `station/*` package of `reader` matches both `scripts/native.ts` (`READER_PKGS`)
//    and `station/mb/build.sh` (`READER_SRC_PKGS`), and that `libs/ui/tools/mbc` + `libs/ui/scripts/mbc` are
//    covered in both `READER_INPUTS` and `HARNESS_INPUTS`.
// 5. Asserts every `.c` file and every `native-stub` entry across `reader`'s transitive packages is covered
//    by `station/mb/build.sh` (`READER_C_STUBS`), with no frozen C stubs leaked into `reader`.
import assert from "node:assert/strict";
import { existsSync, readdirSync, readFileSync, statSync } from "node:fs";
import { join, posix } from "node:path";
import { fileURLToPath } from "node:url";
import { test } from "node:test";

const root = fileURLToPath(new URL("../..", import.meta.url));
const mbSrc = join(root, "station", "mb", "src");

function stripLineComments(text: string): string {
  return text.replace(/\/\/[^\n]*/g, "");
}

/// Extracts non-test `import { ... }` entries from a `moon.pkg` file (ignoring comments and `import (...) for "test"`).
function parseProdImports(moonPkgText: string): string[] {
  const clean = stripLineComments(moonPkgText);
  const out: string[] = [];
  const re = /\bimport\s*\{([\s\S]*?)\}(?:\s*for\s*"([^"]+)")?/g;
  for (const m of clean.matchAll(re)) {
    const scope = m[2];
    if (scope === "test" || scope === "wbtest") continue;
    for (const q of m[1]!.matchAll(/"([^"]+)"/g)) {
      out.push(q[1]!);
    }
  }
  return out;
}

/// Extracts `"native-stub": [ ... ]` entries from a `moon.pkg` file.
function parseNativeStubs(moonPkgText: string): string[] {
  const clean = stripLineComments(moonPkgText);
  const out: string[] = [];
  const re = /"native-stub"\s*:\s*\[([\s\S]*?)\]/g;
  for (const m of clean.matchAll(re)) {
    for (const q of m[1]!.matchAll(/"([^"]+)"/g)) {
      out.push(q[1]!);
    }
  }
  return out;
}

function collectTransitiveGraph(): { stationPkgs: Set<string>; externalImports: Set<string>; nativeStubs: Set<string> } {
  const stationPkgs = new Set<string>(["reader"]);
  const externalImports = new Set<string>();
  const nativeStubs = new Set<string>();
  const queue = ["reader"];
  while (queue.length > 0) {
    const pkg = queue.shift()!;
    const pkgFile = join(mbSrc, pkg, "moon.pkg");
    assert.ok(existsSync(pkgFile), `missing moon.pkg for station/${pkg}`);
    const text = readFileSync(pkgFile, "utf8");
    for (const dep of parseProdImports(text)) {
      if (dep.startsWith("station/")) {
        const sub = dep.slice("station/".length);
        if (!stationPkgs.has(sub)) {
          stationPkgs.add(sub);
          queue.push(sub);
        }
      } else if (!dep.startsWith("moonbitlang/")) {
        externalImports.add(dep);
      }
    }
    for (const stub of parseNativeStubs(text)) {
      nativeStubs.add(posix.normalize(posix.join(pkg, stub)));
    }
  }
  return { stationPkgs, externalImports, nativeStubs };
}

function disallowedExternalImports(imports: Iterable<string>): string[] {
  const bad: string[] = [];
  for (const dep of imports) {
    if (dep.startsWith("base/") || dep === "ui/effect" || dep === "ui/halt") continue;
    bad.push(dep);
  }
  return bad.sort();
}

function parseNativeArray(name: string): string[] {
  const text = readFileSync(join(root, "scripts", "native.ts"), "utf8");
  const m = new RegExp(`const ${name} = \\[([\\s\\S]*?)\\];`).exec(text);
  assert.ok(m, `scripts/native.ts must define \`const ${name} = [...]\``);
  return [...m[1]!.matchAll(/"([^"]+)"/g)].map((x) => x[1]!);
}

function parseBuildShArray(name: string): string[] {
  const text = readFileSync(join(root, "station", "mb", "build.sh"), "utf8");
  const m = new RegExp(`${name}=\\(([\\s\\S]*?)\\)`).exec(text);
  assert.ok(m, `station/mb/build.sh must define ${name}=(...)`);
  return m[1]!.trim().split(/\s+/).filter(Boolean);
}

test("reader transitive dependencies never include station_main or frozen whole-station packages", () => {
  const { stationPkgs } = collectTransitiveGraph();
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
  const found = forbidden.filter((pkg) => stationPkgs.has(pkg));
  assert.deepEqual(found, [], `stillfail-reader must not transitively depend on frozen packages: ${found.join(", ")}`);
  assert.ok(stationPkgs.has("reader") && stationPkgs.has("host") && stationPkgs.has("sql") && stationPkgs.has("readops") && stationPkgs.has("shim_plan"));
});

test("reader external workspace imports stay within whitelist (base/*, ui/effect, ui/halt) and negative cases fail", () => {
  const { externalImports } = collectTransitiveGraph();
  assert.deepEqual(disallowedExternalImports(externalImports), []);
  // Negative assertions: adding ui/signals or stillfail/rules/lock must be rejected.
  assert.deepEqual(disallowedExternalImports([...externalImports, "ui/signals"]), ["ui/signals"]);
  assert.deepEqual(disallowedExternalImports([...externalImports, "stillfail/rules/lock"]), ["stillfail/rules/lock"]);
  // Commented-out and test-only imports are ignored by parser.
  const sample = `
    // "stillfail/rules/lock"
    import {
      "base/url",
    }
    import {
      "ui/signals",
    } for "test"
  `;
  assert.deepEqual(parseProdImports(sample), ["base/url"]);
});

test("scripts/native.ts READER_PKGS/READER_COMMON_INPUTS and station/mb/build.sh READER_SRC_PKGS match reader's transitive graph", () => {
  const { stationPkgs } = collectTransitiveGraph();
  const actual = [...stationPkgs].sort();
  const nativePkgs = [...new Set(parseNativeArray("READER_PKGS"))].sort();
  const buildShPkgs = [...new Set(parseBuildShArray("READER_SRC_PKGS"))].sort();

  assert.deepEqual(
    {
      missingInNative: actual.filter((p) => !nativePkgs.includes(p)),
      extraInNative: nativePkgs.filter((p) => !actual.includes(p)),
    },
    { missingInNative: [], extraInNative: [] },
    "scripts/native.ts READER_PKGS drifted from station/mb/src/reader/moon.pkg transitive deps",
  );

  assert.deepEqual(
    {
      missingInBuildSh: actual.filter((p) => !buildShPkgs.includes(p)),
      extraInBuildSh: buildShPkgs.filter((p) => !actual.includes(p)),
    },
    { missingInBuildSh: [], extraInBuildSh: [] },
    "station/mb/build.sh READER_SRC_PKGS drifted from station/mb/src/reader/moon.pkg transitive deps",
  );

  const common = parseNativeArray("READER_COMMON_INPUTS");
  assert.ok(common.includes("libs/ui/tools/mbc"), "READER_COMMON_INPUTS must include libs/ui/tools/mbc");
  assert.ok(common.includes("libs/ui/scripts/mbc"), "READER_COMMON_INPUTS must include libs/ui/scripts/mbc");
  const buildSh = readFileSync(join(root, "station", "mb", "build.sh"), "utf8");
  assert.match(buildSh, /libs\/ui\/tools\/mbc/, "build.sh gen_inputs must include libs/ui/tools/mbc");
  assert.match(buildSh, /libs\/ui\/scripts\/mbc/, "build.sh gen_inputs must include libs/ui/scripts/mbc");
});

test("station/mb/build.sh READER_C_STUBS covers all C files and moon.pkg native-stub entries in reader's closure", () => {
  const { stationPkgs, nativeStubs } = collectTransitiveGraph();
  const expectedC = new Set<string>(nativeStubs);
  const walkC = (dir: string, relBase: string) => {
    for (const entry of readdirSync(dir).sort()) {
      const full = join(dir, entry);
      const rel = posix.join(relBase, entry);
      if (statSync(full).isDirectory()) walkC(full, rel);
      else if (entry.endsWith(".c")) expectedC.add(rel);
    }
  };
  for (const pkg of [...stationPkgs].sort()) {
    const dir = join(mbSrc, pkg);
    if (existsSync(dir) && statSync(dir).isDirectory()) walkC(dir, pkg);
  }
  const buildStubs = [...new Set(parseBuildShArray("READER_C_STUBS"))].sort();
  assert.deepEqual(
    buildStubs,
    [...expectedC].sort(),
    "station/mb/build.sh READER_C_STUBS must match all C files and native-stub entries in reader's closure",
  );
  for (const stub of buildStubs) {
    assert.ok(!stub.startsWith("station_main/"), `frozen stub leaked into reader: ${stub}`);
    assert.ok(stub !== "drive/drive.c", `frozen stub leaked into reader: ${stub}`);
  }
});
