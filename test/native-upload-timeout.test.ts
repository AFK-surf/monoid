import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { chmodSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import { fileURLToPath } from "node:url";
import { key } from "../scripts/native.ts";

const root = fileURLToPath(new URL("..", import.meta.url));
const nativeScript = join(root, "scripts/native.ts");

function seedCache(cacheDir: string, part: string, target: "linux-x64", file: string) {
  const k = key(part, target);
  const dir = join(cacheDir, part, `${target}-${k}`);
  mkdirSync(dir, { recursive: true });
  writeFileSync(join(dir, file), `fake-${part}`);
  writeFileSync(join(dir, "manifest.json"), JSON.stringify({ part, target, key: k, from: "built" }) + "\n");
  return k;
}

test("ensure --publish aborts a stalled gh release upload after timeout, retries with --clobber, and publishes cached parts in parallel", { skip: process.platform === "win32" }, (t) => {
  const dir = mkdtempSync(join(tmpdir(), "native-upload-timeout-"));
  t.after(() => rmSync(dir, { recursive: true, force: true }));
  const cacheDir = join(dir, "cache");
  const binDir = join(dir, "bin");
  const stateDir = join(dir, "state");
  mkdirSync(binDir, { recursive: true });
  mkdirSync(stateDir, { recursive: true });

  seedCache(cacheDir, "launcher", "linux-x64", "stillfail-station");
  seedCache(cacheDir, "runner", "linux-x64", "stillfail-runner");

  const preload = join(dir, "preload.mjs");
  writeFileSync(preload, `
    globalThis.fetch = async (at) => {
      const url = new URL(at);
      if (url.hostname === "api.github.com") return Response.json({ assets: [] });
      return new Response("", { status: 404 });
    };
  `);

  // Fake gh:
  // - `release upload` for launcher hangs on try 1 (killed by STILLFAIL_NATIVE_UPLOAD_TIMEOUT_MS) and succeeds with --clobber on try 2.
  // - Both cached parts (`launcher` and `runner`) synchronize through a barrier file in stateDir to prove parallel upload.
  const fakeGh = join(binDir, "gh");
  const logFile = join(stateDir, "gh.log");
  writeFileSync(fakeGh, `#!/usr/bin/env bash
set -euo pipefail
printf '%s\\n' "$*" >> ${JSON.stringify(logFile)}
if [ "$1" = "api" ]; then
  printf '[]\\n'
  exit 0
fi
if [ "$1" = "release" ] && [ "$2" = "upload" ]; then
  file="$4"
  base="$(basename "$file")"
  case "$base" in
    launcher-*)
      touch ${JSON.stringify(join(stateDir, "launcher.started"))}
      if [[ " $* " != *" --clobber "* ]]; then
        sleep 5
        exit 0
      fi
      # Wait briefly for sibling cached upload (runner) to confirm parallel execution.
      for _ in $(seq 1 40); do
        [ -f ${JSON.stringify(join(stateDir, "runner.started"))} ] && break
        sleep 0.05
      done
      [ -f ${JSON.stringify(join(stateDir, "runner.started"))} ] || { echo "runner did not run concurrently" >&2; exit 1; }
      exit 0
      ;;
    runner-*)
      touch ${JSON.stringify(join(stateDir, "runner.started"))}
      for _ in $(seq 1 40); do
        [ -f ${JSON.stringify(join(stateDir, "launcher.started"))} ] && break
        sleep 0.05
      done
      [ -f ${JSON.stringify(join(stateDir, "launcher.started"))} ] || { echo "launcher did not run concurrently" >&2; exit 1; }
      exit 0
      ;;
  esac
fi
exit 0
`);
  chmodSync(fakeGh, 0o755);

  const run = spawnSync(
    process.execPath,
    [nativeScript, "ensure", "--publish", "launcher:linux-x64", "runner:linux-x64"],
    {
      cwd: root,
      encoding: "utf8",
      timeout: 15_000,
      env: {
        ...process.env,
        NODE_OPTIONS: `--import ${preload}`,
        PATH: `${binDir}:${process.env.PATH}`,
        STILLFAIL_NATIVE_CACHE: cacheDir,
        STILLFAIL_NATIVE_UPLOAD_TIMEOUT_MS: "350",
        STILLFAIL_NATIVE_UPLOAD_RETRY_MS: "20",
        STILLFAIL_NATIVE_RETRY_MS: "0",
        STILLFAIL_DIRECT_DNS: "",
        STILLFAIL_NATIVE_STORE: "https://app.still.fail/releases/natives",
        STILLFAIL_NATIVE_REPO: "AFK-surf/monoid",
        STILLFAIL_NATIVE_RELEASE: "native-artifacts",
        STILLFAIL_NATIVE_GITHUB_API: "https://api.github.com",
        GH_TOKEN: "native-test-token",
        GITHUB_TOKEN: "",
      },
    },
  );
  assert.equal(run.status, 0, `stdout:\n${run.stdout}\nstderr:\n${run.stderr}`);
  assert.match(run.stderr, /launcher-linux-x64-[a-f0-9]{24}\.tar\.gz: not uploaded \(try 1\), trying again/);
  assert.match(run.stdout, /launcher linux-x64 [a-f0-9]{24}: cached .* → published/);
  assert.match(run.stdout, /runner linux-x64 [a-f0-9]{24}: cached .* → published/);
  const calls = readFileSync(logFile, "utf8").split("\n").filter(Boolean);
  assert.ok(calls.some((c) => c.startsWith("release upload ") && c.includes("launcher-") && c.includes("--clobber")), calls.join("\n"));
});
