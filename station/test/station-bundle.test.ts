import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { cpSync, existsSync, mkdirSync, mkdtempSync, readdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { test } from "node:test";
import { fileURLToPath } from "node:url";

test("a station release includes every worker built, including workers in new directories", { skip: process.platform === "win32" }, () => {
  const root = mkdtempSync(join(tmpdir(), "station-bundle-"));
  const file = (path: string, content = "fixture") => {
    const absolute = join(root, path);
    mkdirSync(dirname(absolute), { recursive: true });
    writeFileSync(absolute, content);
  };
  try {
    mkdirSync(join(root, "scripts"), { recursive: true });
    cpSync(fileURLToPath(new URL("../../scripts/station-bundle.sh", import.meta.url)), join(root, "scripts/station-bundle.sh"));
    for (const path of ["bin/stillfail", "bin/stillfail.cmd", "bin/stillfail.ps1", ".node-version", "natives/stillfail-station",
      "natives/stillfail-station-w.exe", "natives/mesh.node", "natives/stillfail-runner", "natives/stillfail-screen.exe",
      "natives/stillfail-screen-linux", "natives/agent-desktop.exe", "natives/stillfail-reader", "natives/stillfail-reader.exe", "natives/still.fail Helper.app/Contents/MacOS/helper"]) file(path);
    // the lock's and vault's rules in Pion (shared/rules-runtime.ts PION_RULES_AT), copied whole beside main.js
    for (const path of ["pion/rules/js/rules-wasm.mjs", "pion/rules/js/pion_wasm_rt.mjs", "pion/rules/js/rules.wasm"]) file(path, path);
    // A release may run after a different build in the same checkout; its files must not leak into this one.
    file("station/dist/stale/old-worker.js");
    file("mock-bin/node", `#!/bin/sh
set -eu
case "$1" in
  */posthog-key.ts) mkdir -p "$BUNDLE_TEST_ROOT/dist/admin"; printf '{}' > "$BUNDLE_TEST_ROOT/dist/admin/posthog.json" ;;
  */native.ts) case "$3" in
    launcher) name=stillfail-station ;; mesh) name=mesh.node ;; runner) name=stillfail-runner ;;
    helper) name='still.fail Helper.app' ;; reader) name=stillfail-reader; [ "$4" = win32-x64 ] && name=stillfail-reader.exe ;; screen) name=stillfail-screen.exe ;; screen-linux) name=stillfail-screen-linux ;; agent-desktop) name=agent-desktop.exe ;;
    *) exit 1 ;;
  esac; printf '%s/natives/%s\\n' "$BUNDLE_TEST_ROOT" "$name" ;;
  */installers.ts) : ;;
  *) exit 1 ;;
esac
`);
    file("mock-bin/pnpm", `#!/bin/sh
set -eu
for name in main.js future/another-worker.js \\
  skills/example.md dsh-bridge.mjs cursor-bridge.mjs sandbox-bridge.mjs colab-sandbox.mjs scrcpy-server linux-portal.py linux-x11.py linux-gamepad.py; do
  mkdir -p "dist/$(dirname "$name")"
  printf '%s' "$name" > "dist/$name"
done
`);
    file("mock-bin/git", `#!/bin/sh\nprintf '123\\n'\n`);
    for (const executable of ["node", "pnpm", "git"]) execFileSync("chmod", ["+x", join(root, "mock-bin", executable)]);
    const env: NodeJS.ProcessEnv = { ...process.env, BUNDLE_TEST_ROOT: root, PATH: `${join(root, "mock-bin")}:${process.env.PATH ?? ""}` };
    delete env.STILLFAIL_SIGN_STATION;
    for (const platform of ["darwin-arm64", "linux-x64", "linux-arm64", "win32-x64"]) {
      execFileSync("/bin/sh", [join(root, "scripts/station-bundle.sh"), join(root, "out"), platform], { env });
      const station = join(root, "out/stillfail/station");
      for (const worker of ["future/another-worker.js", "colab-sandbox.mjs"]) {
        assert.equal(readFileSync(join(station, worker), "utf8"), worker, `${platform}: ${worker}`);
      }
      assert.equal(existsSync(join(station, "stale/old-worker.js")), false, `${platform}: nothing left from an earlier build`);
      for (const name of ["rules-wasm.mjs", "pion_wasm_rt.mjs", "rules.wasm"]) {
        assert.equal(readFileSync(join(station, "pion-rules", name), "utf8"), `pion/rules/js/${name}`, `${platform}: pion-rules/${name}`);
      }
      assert.equal(existsSync(join(station, "linux-portal.py")), platform.startsWith("linux-"));
      assert.equal(existsSync(join(station, "linux-gamepad.py")), platform.startsWith("linux-"));
      assert.equal(existsSync(join(station, "stillfail-screen-linux")), platform.startsWith("linux-"), `${platform}: native Linux screen helper`);
      // the reader in MoonBit (scripts/native.ts `reader`), every platform's
      assert.ok(existsSync(join(station, platform === "win32-x64" ? "stillfail-reader.exe" : "stillfail-reader")), `${platform}: the MoonBit reader`);
    }
  } finally { rmSync(root, { recursive: true, force: true }); }
});

// scripts/release.sh builds the station once and bundles the platforms side by side (STILLFAIL_STATION_BUILT=1): a
// bundle then neither writes dist/admin again nor builds station/dist, taking both as they are.
test("a bundle told the station is built takes dist/admin and station/dist as they are", { skip: process.platform === "win32" }, () => {
  const root = mkdtempSync(join(tmpdir(), "station-bundle-built-"));
  const file = (path: string, content = "fixture") => {
    const absolute = join(root, path);
    mkdirSync(dirname(absolute), { recursive: true });
    writeFileSync(absolute, content);
  };
  try {
    mkdirSync(join(root, "scripts"), { recursive: true });
    cpSync(fileURLToPath(new URL("../../scripts/station-bundle.sh", import.meta.url)), join(root, "scripts/station-bundle.sh"));
    for (const path of ["bin/stillfail", ".node-version", "natives/stillfail-station", "natives/mesh.node", "natives/stillfail-runner",
      "natives/stillfail-reader", "natives/stillfail-screen-linux", "pion/rules/js/rules-wasm.mjs", "pion/rules/js/pion_wasm_rt.mjs",
      "pion/rules/js/rules.wasm"]) file(path);
    file("dist/admin/posthog.json", "built before");
    file("station/dist/main.js", "built before");
    file("mock-bin/node", `#!/bin/sh
set -eu
case "$1" in
  */posthog-key.ts) echo "posthog-key.ts run again" >&2; exit 9 ;;
  */native.ts) case "$3" in
    launcher) name=stillfail-station ;; mesh) name=mesh.node ;; runner) name=stillfail-runner ;; reader) name=stillfail-reader ;;
    screen-linux) name=stillfail-screen-linux ;; *) exit 1 ;;
  esac; printf '%s/natives/%s\\n' "$BUNDLE_TEST_ROOT" "$name" ;;
  */installers.ts) : ;;
  *) exit 1 ;;
esac
`);
    file("mock-bin/pnpm", `#!/bin/sh\necho "station built again" >&2\nexit 9\n`);
    file("mock-bin/git", `#!/bin/sh\nprintf '123\\n'\n`);
    for (const executable of ["node", "pnpm", "git"]) execFileSync("chmod", ["+x", join(root, "mock-bin", executable)]);
    const env: NodeJS.ProcessEnv = { ...process.env, BUNDLE_TEST_ROOT: root, STILLFAIL_STATION_BUILT: "1", PATH: `${join(root, "mock-bin")}:${process.env.PATH ?? ""}` };
    delete env.STILLFAIL_SIGN_STATION;
    execFileSync("/bin/sh", [join(root, "scripts/station-bundle.sh"), join(root, "out"), "linux-x64"], { env });
    assert.equal(readFileSync(join(root, "out/stillfail/station/main.js"), "utf8"), "built before");
    assert.equal(readFileSync(join(root, "out/stillfail/dist/admin/posthog.json"), "utf8"), "built before");
    assert.equal(readFileSync(join(root, "station/dist/main.js"), "utf8"), "built before", "station/dist left as it was");
  } finally { rmSync(root, { recursive: true, force: true }); }
});

test("files a module finds beside itself are named as they lie beside main.js in a release, where every module is bundled", () => {
  // The release copies them flat beside main.js (package.json build), so a path into another directory of src only
  // works from the source (2026-11-04: the chat's own phone screen looked for ../screens/scrcpy-server and found none).
  const src = fileURLToPath(new URL("../src/", import.meta.url));
  const wrong: string[] = [];
  for (const name of readdirSync(src, { recursive: true, encoding: "utf8" })) {
    if (!name.endsWith(".ts")) continue;
    readFileSync(join(src, name), "utf8").split("\n").forEach((line, i) => {
      // Built from the source only: mesh's library from a local cargo build, and skills found by where the module runs.
      if (line.includes("native/mesh/target/") || line.includes('import.meta.url.endsWith(".ts")')) return;
      for (const m of line.matchAll(/new URL\("([^"]*)", import\.meta\.url\)/g)) {
        if (!/^\.\/[^/]+\/?$/.test(m[1])) wrong.push(`${name}:${i + 1} ${m[1]}`);
      }
    });
  }
  assert.deepEqual(wrong, []);
});
