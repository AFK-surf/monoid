import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { chmodSync, existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { test } from "node:test";

// store-sync with the network simulated (fetch replaced) and release-put.sh's `sh` replaced by one that lists what it
// was given: the store has every part but two, which the release has.
const LACKING = ["screen-win32-x64-", "station-load-darwin-arm64-"];

for (const scenario of ["breaks-once", "breaks-always", "token"] as const) test(`native store-sync: ${scenario}`, (t) => {
  const root = fileURLToPath(new URL("..", import.meta.url));
  const dir = mkdtempSync(join(tmpdir(), "native-store-sync-"));
  t.after(() => rmSync(dir, { recursive: true, force: true }));
  const bin = join(dir, "bin"), put = join(dir, "put"), requests = join(dir, "requests");
  mkdirSync(bin); mkdirSync(put);
  writeFileSync(join(bin, "git"), "#!/bin/sh\nexit 0\n");
  writeFileSync(join(bin, "gh"), "#!/bin/sh\nexit 1\n");
  // (release-put.sh --files <work>: each file it was handed copied aside, nothing put)
  writeFileSync(join(bin, "sh"), `#!/bin/sh\necho "$*" > "${put}/args"\ncp "$3"/natives/* "${put}/"\n`);
  for (const f of ["git", "gh", "sh"]) chmodSync(join(bin, f), 0o755);
  const preload = join(dir, "preload.mjs");
  writeFileSync(preload, `
    import { appendFileSync } from 'node:fs';
    const scenario = ${JSON.stringify(scenario)};
    const lacking = ${JSON.stringify(LACKING)};
    const missing = new Set();
    const tries = new Map();
    globalThis.fetch = async (at, init = {}) => {
      const url = new URL(at);
      const name = url.pathname.split('/').at(-1);
      appendFileSync(${JSON.stringify(requests)}, (init.method ?? 'GET') + ' ' + url.hostname + ' ' + name + '\\n');
      if (url.hostname === 'app.still.fail') {
        if (!lacking.some((l) => name.startsWith(l))) return new Response('a', { status: 206 });
        missing.add(name);
        return new Response('', { status: 404 });
      }
      if (url.hostname === 'api.github.com' && url.pathname.endsWith('/releases/tags/native-artifacts')) {
        if (new Headers(init.headers).get('authorization') !== 'Bearer native-test-token') throw new Error('wrong authorization');
        return Response.json({ assets: [...missing].map((name) => ({ name })) });
      }
      if (url.hostname === 'github.com' && (init.method ?? 'GET') === 'GET') {
        const n = (tries.get(name) ?? 0) + 1;
        tries.set(name, n);
        const broken = name.startsWith(lacking[0]) && (scenario === 'breaks-always' || (scenario === 'breaks-once' && n === 1));
        if (broken) throw new TypeError('fetch failed');
        return new Response('bytes of ' + name);
      }
      throw new Error('unexpected request ' + (init.method ?? 'GET') + ' ' + at);
    };
  `);
  const run = spawnSync(process.execPath, ["--import", preload, join(root, "scripts/native.ts"), "store-sync"], {
    cwd: root, encoding: "utf8", env: { ...process.env, PATH: `${bin}:${process.env.PATH}`,
      STILLFAIL_NATIVE_RETRY_MS: "0", STILLFAIL_DIRECT_DNS: "",
      STILLFAIL_NATIVE_STORE: "https://app.still.fail/releases/natives", STILLFAIL_NATIVE_REPO: "AFK-surf/monoid",
      STILLFAIL_NATIVE_RELEASE: "native-artifacts", STILLFAIL_NATIVE_GITHUB: "https://github.com",
      STILLFAIL_NATIVE_GITHUB_API: "https://api.github.com", GH_TOKEN: "native-test-token", GITHUB_TOKEN: "" },
  });
  assert.equal(run.status, 0, run.stderr + run.stdout);
  const asked = readFileSync(requests, "utf8").trim().split("\n");
  const names = [...new Set(asked.filter((l) => l.startsWith("GET app.still.fail ")).map((l) => l.split(" ")[2]!))];
  const [first, second] = LACKING.map((l) => names.find((n) => n.startsWith(l))!);
  assert.ok(first && second, "both lacking parts asked of the store");
  // The release asked once, by its API, for all the store lacks: never a HEAD a part.
  assert.equal(asked.filter((l) => l.startsWith("GET api.github.com ")).length, 1);
  assert.equal(asked.filter((l) => l.startsWith("HEAD ")).length, 0);
  const downloads = (name: string) => asked.filter((l) => l === `GET github.com ${name}`).length;
  assert.equal(readFileSync(join(put, second), "utf8"), `bytes of ${second}`);
  assert.equal(readFileSync(join(put, "args"), "utf8").split(" ")[1], "--files");
  if (scenario === "breaks-always") {
    // Given up after three tries, said, and the others put all the same.
    assert.equal(downloads(first), 3);
    assert.equal(existsSync(join(put, first)), false);
    assert.match(run.stdout, new RegExp(`${first}: the release failed \\(fetch failed\\); the next run copies it`));
  } else {
    assert.equal(downloads(first), scenario === "breaks-once" ? 2 : 1);
    assert.equal(readFileSync(join(put, first), "utf8"), `bytes of ${first}`);
  }
  // The log in the parts' own order, whatever order the store answered in.
  const said = run.stdout.split("\n").filter((l) => /: (in the store|from the release)/.test(l)).map((l) => l.split(":")[0]);
  assert.deepEqual(said.filter((n) => n !== first || scenario !== "breaks-always"), names.filter((n) => n !== first || scenario !== "breaks-always"));
});
