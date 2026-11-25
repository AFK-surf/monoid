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

test("ensure --publish fans out cached parts to worker children and aborts a permanently stalled gh release upload with SIGKILL before retrying with --clobber", { skip: process.platform === "win32" }, (t) => {
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
  // - Logs ONE=$STILLFAIL_NATIVE_ONE and PPID=$PPID for every call (proving cached parts fanned out to distinct child
  //   workers without any timing barrier or polling).
  // - On try 1 of launcher (no --clobber), ignores SIGTERM and blocks indefinitely in `tail -f /dev/null` so ONLY
  //   spawnSync's timeout + SIGKILL can terminate it; try 2 receives --clobber and exits 0 immediately.
  const fakeGh = join(binDir, "gh");
  const logFile = join(stateDir, "gh.log");
  writeFileSync(fakeGh, `#!/usr/bin/env bash
set -euo pipefail
printf 'ONE=%s PPID=%s %s\\n' "\${STILLFAIL_NATIVE_ONE:-}" "$PPID" "$*" >> ${JSON.stringify(logFile)}
if [ "$1" = "api" ]; then
  printf '[]\\n'
  exit 0
fi
if [ "$1" = "release" ] && [ "$2" = "upload" ]; then
  file="$4"
  base="$(basename "$file")"
  case "$base" in
    launcher-*)
      if [[ " $* " != *" --clobber "* ]]; then
        trap '' TERM
        echo "partial upload stall" >&2
        exec tail -f /dev/null
      fi
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
      timeout: 30_000,
      env: {
        ...process.env,
        NODE_OPTIONS: `--import ${preload}`,
        PATH: `${binDir}:${process.env.PATH}`,
        STILLFAIL_NATIVE: "",
        STILLFAIL_NATIVE_ONE: "",
        STILLFAIL_NATIVE_INBOX: "",
        STILLFAIL_NATIVE_READERS: "",
        STILLFAIL_NATIVE_CACHE: cacheDir,
        STILLFAIL_NATIVE_CACHE_MAX_BYTES: "0",
        STILLFAIL_NATIVE_UPLOAD_TIMEOUT_MS: "500",
        STILLFAIL_NATIVE_UPLOAD_RETRY_MS: "0",
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
  assert.match(run.stderr, /launcher-linux-x64-[a-f0-9]{24}\.tar\.gz: not uploaded \(try 1\), trying again:.*ETIMEDOUT.*partial upload stall/);
  assert.match(run.stdout, /launcher linux-x64 [a-f0-9]{24}: cached .* → published/);
  assert.match(run.stdout, /runner linux-x64 [a-f0-9]{24}: cached .* → published/);

  const calls = readFileSync(logFile, "utf8").split("\n").filter(Boolean);
  const uploadCalls = calls.filter((c) => c.includes(" release upload "));
  const launcherFirst = uploadCalls.find((c) => c.includes("launcher-") && !c.includes("--clobber"));
  const launcherRetry = uploadCalls.find((c) => c.includes("launcher-") && c.includes("--clobber"));
  const runnerUpload = uploadCalls.find((c) => c.includes("runner-"));
  assert.ok(launcherFirst?.startsWith("ONE=1 "), calls.join("\n"));
  assert.ok(launcherRetry?.startsWith("ONE=1 "), calls.join("\n"));
  assert.ok(runnerUpload?.startsWith("ONE=1 "), calls.join("\n"));

  const ppidOf = (line: string) => line.match(/\bPPID=(\d+)\b/)?.[1];
  assert.notEqual(ppidOf(launcherRetry!), ppidOf(runnerUpload!), `expected separate worker processes:\n${calls.join("\n")}`);
});
