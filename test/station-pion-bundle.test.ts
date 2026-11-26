import assert from "node:assert/strict";
import { execFileSync, spawnSync } from "node:child_process";
import { chmodSync, cpSync, existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { test } from "node:test";
import { fileURLToPath } from "node:url";
import { key } from "../scripts/native.ts";

const repoRoot = fileURLToPath(new URL("..", import.meta.url));

function makeBundleSandbox(t: { after: (fn: () => void) => void }) {
  const root = mkdtempSync(join(tmpdir(), "station-pion-bundle-"));
  t.after(() => rmSync(root, { recursive: true, force: true }));
  const file = (rel: string, content = "fixture") => {
    const abs = join(root, rel);
    mkdirSync(dirname(abs), { recursive: true });
    writeFileSync(abs, content);
    return abs;
  };
  mkdirSync(join(root, "scripts"), { recursive: true });
  cpSync(join(repoRoot, "scripts/station-bundle.sh"), join(root, "scripts/station-bundle.sh"));
  for (const rel of [
    "bin/stillfail",
    "bin/stillfail.cmd",
    "bin/stillfail.ps1",
    ".node-version",
    "natives/stillfail-station",
    "natives/stillfail-station-w.exe",
    "natives/mesh.node",
    "natives/stillfail-runner",
    "natives/stillfail-screen.exe",
    "natives/stillfail-screen-linux",
    "natives/agent-desktop.exe",
    "natives/stillfail-reader",
    "natives/stillfail-reader.exe",
    "natives/stillfail-pion",
    "natives/stillfail-pion.exe",
    "natives/still.fail Helper.app/Contents/MacOS/helper",
    "pion/rules/js/rules-wasm.mjs",
    "pion/rules/js/pion_wasm_rt.mjs",
    "pion/rules/js/rules.wasm",
    "dist/admin/posthog.json",
    "station/dist/main.js",
  ]) {
    file(rel);
  }
  const fakeStationPionUnix = file("natives/stillfail-station-pion", "orig-station-pion-unix");
  const fakeStationPionWin = file("natives/stillfail-station-pion.exe", "orig-station-pion-win32");

  // Mock `node` honoring STILLFAIL_STATION_PION for `native.ts file station-pion <target>`.
  file(
    "mock-bin/node",
    `#!/bin/sh
set -eu
case "$1" in
  */native.ts)
    case "$3" in
      launcher) name=stillfail-station ;;
      mesh) name=mesh.node ;;
      runner) name=stillfail-runner ;;
      helper) name='still.fail Helper.app' ;;
      reader) name=stillfail-reader; [ "$4" = win32-x64 ] && name=stillfail-reader.exe ;;
      pion-reader) name=stillfail-pion; [ "$4" = win32-x64 ] && name=stillfail-pion.exe ;;
      station-pion)
        if [ -n "\${STILLFAIL_STATION_PION:-}" ]; then
          printf '%s\\n' "$STILLFAIL_STATION_PION"
          exit 0
        fi
        name=stillfail-station-pion
        [ "$4" = win32-x64 ] && name=stillfail-station-pion.exe
        ;;
      screen) name=stillfail-screen.exe ;;
      screen-linux) name=stillfail-screen-linux ;;
      agent-desktop) name=agent-desktop.exe ;;
      *) exit 1 ;;
    esac
    printf '%s/natives/%s\\n' "$BUNDLE_TEST_ROOT" "$name"
    ;;
  */installers.ts) : ;;
  *) exit 1 ;;
esac
`,
  );
  file("mock-bin/git", `#!/bin/sh\nprintf '123\\n'\n`);
  chmodSync(join(root, "mock-bin/node"), 0o755);
  chmodSync(join(root, "mock-bin/git"), 0o755);
  return { root, file, fakeStationPionUnix, fakeStationPionWin };
}

test("station-bundle.sh bundles stillfail-station-pion for all four platforms including win32-x64 .exe", { skip: process.platform === "win32" }, (t) => {
  const { root, fakeStationPionUnix, fakeStationPionWin } = makeBundleSandbox(t);
  for (const platform of ["darwin-arm64", "linux-x64", "linux-arm64", "win32-x64"] as const) {
    const out = join(root, `out-${platform}`);
    const isWin = platform === "win32-x64";
    const env: NodeJS.ProcessEnv = {
      ...process.env,
      BUNDLE_TEST_ROOT: root,
      STILLFAIL_STATION_BUILT: "1",
      STILLFAIL_STATION_PION: isWin ? fakeStationPionWin : fakeStationPionUnix,
      PATH: `${join(root, "mock-bin")}:${process.env.PATH ?? ""}`,
    };
    delete env.STILLFAIL_SIGN_STATION;
    execFileSync("/bin/sh", [join(root, "scripts/station-bundle.sh"), out, platform], { env });
    const bundled = join(out, "stillfail/station", isWin ? "stillfail-station-pion.exe" : "stillfail-station-pion");
    assert.ok(existsSync(bundled), `${platform}: expected ${bundled}`);
    assert.equal(readFileSync(bundled, "utf8"), isWin ? "orig-station-pion-win32" : "orig-station-pion-unix", `${platform}: bytes`);
  }
});

test("station-bundle.sh signs stillfail-station-pion with fail.still.station-pion on darwin-arm64 and restores ad-hoc binary on signing failure", { skip: process.platform === "win32" }, (t) => {
  const { root, file, fakeStationPionUnix } = makeBundleSandbox(t);
  const signLog = join(root, "sign-args.txt");

  // 1. Successful signing: verify exact file + identifier pair passed to .github/sign-station.sh.
  file(
    ".github/sign-station.sh",
    `#!/bin/sh
set -eu
: > "${signLog}"
while [ $# -ge 2 ]; do
  printf '%s|%s\\n' "$1" "$2" >> "${signLog}"
  shift 2
done
`,
  );
  const outOk = join(root, "out-signed");
  const baseEnv: NodeJS.ProcessEnv = {
    ...process.env,
    BUNDLE_TEST_ROOT: root,
    STILLFAIL_STATION_BUILT: "1",
    STILLFAIL_STATION_PION: fakeStationPionUnix,
    STILLFAIL_SIGN_STATION: "1",
    PATH: `${join(root, "mock-bin")}:${process.env.PATH ?? ""}`,
  };
  execFileSync("/bin/sh", [join(root, "scripts/station-bundle.sh"), outOk, "darwin-arm64"], { env: baseEnv });
  const pairs = readFileSync(signLog, "utf8").trim().split("\n");
  const expectedTarget = `${join(outOk, "stillfail/station/stillfail-station-pion")}|fail.still.station-pion`;
  assert.ok(pairs.includes(expectedTarget), `expected ${expectedTarget} in sign-station.sh args:\n${pairs.join("\n")}`);

  // 2. Failed signing after mutating the target binary: fallback branch must re-copy the original ad-hoc binary.
  file(
    ".github/sign-station.sh",
    `#!/bin/sh
set -eu
while [ $# -ge 2 ]; do
  if [ "$2" = "fail.still.station-pion" ]; then
    printf 'corrupted-partial-signature' > "$1"
  fi
  shift 2
done
exit 1
`,
  );
  const outFail = join(root, "out-fallback");
  execFileSync("/bin/sh", [join(root, "scripts/station-bundle.sh"), outFail, "darwin-arm64"], { env: baseEnv });
  assert.equal(
    readFileSync(join(outFail, "stillfail/station/stillfail-station-pion"), "utf8"),
    "orig-station-pion-unix",
    "signing failure fallback must restore original station-pion binary",
  );
});

test("pion-reader and shell-apple cache keys remain byte-for-byte identical to origin/main", (t) => {
  const show = spawnSync("git", ["show", "origin/main:scripts/native.ts"], { cwd: repoRoot, encoding: "utf8" });
  if (show.status !== 0) {
    t.skip("origin/main ref unavailable in checkout");
    return;
  }
  const tmp = mkdtempSync(join(tmpdir(), "native-main-keys-"));
  t.after(() => rmSync(tmp, { recursive: true, force: true }));
  const mainScript = join(tmp, "native-main.ts");
  const patched = show.stdout.replace(
    'const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), "..");',
    `const ROOT = ${JSON.stringify(repoRoot)};`,
  );
  assert.notEqual(patched, show.stdout, "expected ROOT declaration in origin/main:scripts/native.ts");
  writeFileSync(mainScript, patched);

  const checks: [string, string][] = [
    ["pion-reader", "darwin-arm64"],
    ["pion-reader", "linux-x64"],
    ["pion-reader", "linux-arm64"],
    ["pion-reader", "win32-x64"],
    ["shell-apple", "darwin-arm64"],
    ["shell-apple", "ios-arm64"],
    ["shell-apple", "ios-sim-arm64"],
  ];
  for (const [part, target] of checks) {
    const mainKey = execFileSync(process.execPath, [mainScript, "key", part, target], { cwd: repoRoot, encoding: "utf8" }).trim();
    const headKey = key(part, target as never);
    assert.equal(headKey, mainKey, `${part}:${target} cache key changed from origin/main`);
  }
});
