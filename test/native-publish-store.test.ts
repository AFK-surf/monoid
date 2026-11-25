import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { once } from "node:events";
import { chmodSync, existsSync, mkdirSync, mkdtempSync, readdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { createServer } from "node:http";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test, type TestContext } from "node:test";
import { fileURLToPath } from "node:url";
import { key } from "../scripts/native.ts";

// `ensure --publish-store` (main's natives-mac jobs on the Shanghai Macs): what the store lacks is put there by
// release-put.sh --files, and GitHub is never asked, neither gh nor the release's HTTP endpoints.
const root = fileURLToPath(new URL("..", import.meta.url));
const nativeScript = join(root, "scripts/native.ts");
const ACCOUNT = "0123456789abcdef0123456789abcdef";

const asset = (part: string) => `${part}-linux-x64-${key(part, "linux-x64")}.tar.gz`;

function seedCache(cacheDir: string, part: string, file: string) {
  const k = key(part, "linux-x64");
  const dir = join(cacheDir, part, `linux-x64-${k}`);
  mkdirSync(dir, { recursive: true });
  writeFileSync(join(dir, file), `fake-${part}`);
  writeFileSync(join(dir, "manifest.json"), JSON.stringify({ part, target: "linux-x64", key: k, from: "built" }) + "\n");
}

async function world(t: TestContext, stored: Set<string>) {
  const dir = mkdtempSync(join(tmpdir(), "native-publish-store-"));
  t.after(() => rmSync(dir, { recursive: true, force: true }));
  const cacheDir = join(dir, "cache"), binDir = join(dir, "bin"), tmp = join(dir, "tmp");
  mkdirSync(binDir, { recursive: true });
  mkdirSync(tmp, { recursive: true });
  seedCache(cacheDir, "launcher", "stillfail-station");
  seedCache(cacheDir, "runner", "stillfail-runner");
  // Any gh call fails the run, and is logged.
  const ghLog = join(dir, "gh.log");
  writeFileSync(join(binDir, "gh"), `#!/bin/sh\necho "gh $*" >> ${JSON.stringify(ghLog)}\necho "gh must not be called" >&2\nexit 1\n`);
  // Cloudflare's API: each PUT logged with the size of what it sent, answered with an etag.
  const curlLog = join(dir, "curl.log");
  writeFileSync(join(binDir, "curl"), `#!/bin/sh
file=""; url=""
while [ $# -gt 0 ]; do
  case $1 in -T) file=$2; shift ;; https://*) url=$1 ;; esac
  shift
done
echo "$url $(wc -c < "$file" | tr -d ' ')" >> ${JSON.stringify(curlLog)}
printf '{"success":true,"result":{"etag":"00000000000000000000000000000000"}}'
`);
  chmodSync(join(binDir, "gh"), 0o755);
  chmodSync(join(binDir, "curl"), 0o755);
  // The store answers what it has (Range: its first byte); anything under /github is GitHub, asked of nobody.
  const github: string[] = [];
  const asked: string[] = [];
  const server = createServer((req, res) => {
    const url = req.url ?? "";
    if (url.startsWith("/github")) { github.push(url); res.writeHead(500).end(); return; }
    const name = url.replace(/^\/store\//, "");
    asked.push(name);
    if (stored.has(name)) res.writeHead(206).end("a");
    else res.writeHead(404).end();
  });
  server.listen(0, "127.0.0.1");
  await once(server, "listening");
  t.after(() => server.close());
  const base = `http://127.0.0.1:${(server.address() as { port: number }).port}`;
  const ensure = async (...args: string[]) => {
    const child = spawn(process.execPath, [nativeScript, "ensure", ...args], {
      cwd: root,
      env: {
        ...process.env,
        PATH: `${binDir}:${process.env.PATH}`,
        TMPDIR: tmp,
        STILLFAIL_NATIVE: "",
        STILLFAIL_NATIVE_ONE: "",
        STILLFAIL_NATIVE_INBOX: "",
        STILLFAIL_NATIVE_READERS: "",
        STILLFAIL_NATIVE_CACHE: cacheDir,
        STILLFAIL_NATIVE_CACHE_MAX_BYTES: "0",
        STILLFAIL_NATIVE_RETRY_MS: "0",
        STILLFAIL_DIRECT_DNS: "",
        STILLFAIL_NATIVE_STORE: `${base}/store`,
        STILLFAIL_NATIVE_GITHUB: `${base}/github`,
        STILLFAIL_NATIVE_GITHUB_API: `${base}/github/api`,
        STILLFAIL_NATIVE_REPO: "AFK-surf/monoid",
        STILLFAIL_NATIVE_RELEASE: "native-artifacts",
        STILLFAIL_PUT_RECEIPTS: "",
        CLOUDFLARE_API_TOKEN: "test-token",
        CLOUDFLARE_ACCOUNT_ID: ACCOUNT,
        GH_TOKEN: "test-gh-token",
        GITHUB_TOKEN: "",
      },
    });
    let stdout = "", stderr = "";
    child.stdout.on("data", (c) => { stdout += c; });
    child.stderr.on("data", (c) => { stderr += c; });
    const [status] = await once(child, "exit");
    return { status: status as number, stdout, stderr };
  };
  const puts = () => (existsSync(curlLog) ? readFileSync(curlLog, "utf8").split("\n").filter(Boolean) : []);
  const ghCalls = () => (existsSync(ghLog) ? readFileSync(ghLog, "utf8").split("\n").filter(Boolean) : []);
  return { ensure, puts, ghCalls, github, asked, tmp };
}

const objectUrl = (name: string) => `https://api.cloudflare.com/client/v4/accounts/${ACCOUNT}/r2/buckets/stillfail-releases/objects/natives/${name}`;

test("ensure --publish-store puts what the store lacks there and never asks GitHub", { skip: process.platform === "win32" }, async (t) => {
  const w = await world(t, new Set());
  const run = await w.ensure("--publish-store", "launcher:linux-x64");
  assert.equal(run.status, 0, `stdout:\n${run.stdout}\nstderr:\n${run.stderr}`);
  assert.match(run.stdout, /launcher linux-x64 [0-9a-f]{24}: cached \(\d+ s\) → store/);
  const puts = w.puts();
  assert.equal(puts.length, 1, puts.join("\n"));
  const [url, size] = puts[0]!.split(" ");
  assert.equal(url, objectUrl(asset("launcher")));
  assert.ok(Number(size) > 0);
  assert.deepEqual(w.ghCalls(), []);
  assert.deepEqual(w.github, []);
  assert.deepEqual(w.asked, [asset("launcher")]);
  // (its work directory gone with the archive)
  assert.deepEqual(readdirSync(w.tmp).filter((f) => f.startsWith("stillfail-native-")), []);
});

test("ensure --publish-store fans several parts the store lacks out to workers, each put once, GitHub never asked", { skip: process.platform === "win32" }, async (t) => {
  const w = await world(t, new Set());
  const run = await w.ensure("--publish-store", "launcher:linux-x64", "runner:linux-x64");
  assert.equal(run.status, 0, `stdout:\n${run.stdout}\nstderr:\n${run.stderr}`);
  assert.match(run.stdout, /launcher linux-x64 [0-9a-f]{24}: cached \(\d+ s\) → store/);
  assert.match(run.stdout, /runner linux-x64 [0-9a-f]{24}: cached \(\d+ s\) → store/);
  assert.deepEqual(w.puts().map((l) => l.split(" ")[0]).sort(), [objectUrl(asset("launcher")), objectUrl(asset("runner"))].sort());
  assert.deepEqual(w.ghCalls(), []);
  assert.deepEqual(w.github, []);
  assert.deepEqual(readdirSync(w.tmp).filter((f) => f.startsWith("stillfail-native-")), []);
});

test("ensure --publish-store leaves what the store has", { skip: process.platform === "win32" }, async (t) => {
  const w = await world(t, new Set([asset("launcher")]));
  const run = await w.ensure("--publish-store", "launcher:linux-x64");
  assert.equal(run.status, 0, `stdout:\n${run.stdout}\nstderr:\n${run.stderr}`);
  assert.match(run.stdout, /launcher linux-x64 [0-9a-f]{24}: cached \(\d+ s\), published already/);
  assert.deepEqual(w.puts(), []);
  assert.deepEqual(w.ghCalls(), []);
  assert.deepEqual(w.github, []);
});

test("ensure refuses --publish with --publish-store", { skip: process.platform === "win32" }, async (t) => {
  const w = await world(t, new Set());
  const run = await w.ensure("--publish", "--publish-store", "launcher:linux-x64");
  assert.notEqual(run.status, 0);
  assert.match(run.stderr, /cannot combine --publish and --publish-store/);
  assert.deepEqual(w.puts(), []);
  assert.deepEqual(w.ghCalls(), []);
  assert.deepEqual(w.github, []);
  assert.deepEqual(w.asked, []);
});

