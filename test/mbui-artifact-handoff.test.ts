import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { chmodSync, existsSync, mkdirSync, mkdtempSync, readdirSync, readFileSync, rmSync, statSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import { fileURLToPath } from "node:url";

const root = fileURLToPath(new URL("..", import.meta.url));
const script = join(root, "scripts/mbui-artifact-handoff.sh");
const commit = "a".repeat(40);

function makePreload(dir: string, storeDir: string, corruptGet = false) {
  const preload = join(dir, corruptGet ? "preload-corrupt.mjs" : "preload.mjs");
  writeFileSync(preload, `
    import { createHash, randomUUID } from "node:crypto";
    import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
    import { dirname, join } from "node:path";

    const store = ${JSON.stringify(storeDir)};
    const commit = ${JSON.stringify(commit)};
    const corruptGet = ${JSON.stringify(corruptGet)};
    globalThis.fetch = async (at, init = {}) => {
      const url = new URL(at);
      if (url.hostname === "oidc.example.test") {
        return Response.json({ value: "fake-oidc-jwt" });
      }
      if (url.hostname === "app.still.fail" && url.pathname === "/releases/ci-natives" && init.method === "PUT") {
        const receipt = "1700000000-" + commit + "/" + randomUUID();
        const dest = join(store, receipt);
        mkdirSync(dirname(dest), { recursive: true });
        writeFileSync(dest, Buffer.from(init.body));
        return Response.json({ receipt }, { status: 201 });
      }
      if (url.hostname === "app.still.fail" && url.pathname.startsWith("/releases/ci-natives/")) {
        const receipt = url.pathname.slice("/releases/ci-natives/".length);
        const bytes = Buffer.from(readFileSync(join(store, receipt)));
        if (corruptGet && bytes.length > 0) bytes[0] ^= 0xff;
        return new Response(bytes, { status: 200 });
      }
      throw new Error("unexpected fetch: " + (init.method ?? "GET") + " " + url.href);
    };
  `);
  return preload;
}

test("mbui-artifact-handoff stages pages_test via R2, shrinks upload dir to natives.r2.json, and restores files with permissions", { skip: process.platform === "win32" }, (t) => {
  const dir = mkdtempSync(join(tmpdir(), "mbui-handoff-test-"));
  t.after(() => rmSync(dir, { recursive: true, force: true }));
  const storeDir = join(dir, "r2-store");
  const artifactDir = join(dir, "pages-test");
  mkdirSync(join(artifactDir, "nested"), { recursive: true });
  writeFileSync(join(artifactDir, "sfapp_pages_test.blackbox_test.exe"), "binary-payload-1234567890");
  chmodSync(join(artifactDir, "sfapp_pages_test.blackbox_test.exe"), 0o755);
  writeFileSync(join(artifactDir, "__blackbox_test_info.json"), '{"tests":42}\n');
  writeFileSync(join(artifactDir, "nested", "extra.txt"), "nested-ok");

  const preload = makePreload(dir, storeDir);
  const env = {
    ...process.env,
    NODE_OPTIONS: `--import ${preload}`,
    RUNNER_TEMP: dir,
    STILLFAIL_DIRECT_DNS: "",
    STILLFAIL_NATIVE_DIRECT_R2: "",
    STILLFAIL_NATIVE_CACHE: "",
    ACTIONS_ID_TOKEN_REQUEST_URL: "https://oidc.example.test/token",
    ACTIONS_ID_TOKEN_REQUEST_TOKEN: "oidc-bearer",
  };

  const put = spawnSync("bash", [script, "put", "pages_test", artifactDir, commit], { cwd: root, encoding: "utf8", env });
  assert.equal(put.status, 0, `stdout:\n${put.stdout}\nstderr:\n${put.stderr}`);
  assert.deepEqual(readdirSync(artifactDir), ["natives.r2.json"]);
  const manifest = JSON.parse(readFileSync(join(artifactDir, "natives.r2.json"), "utf8"));
  assert.equal(manifest.length, 1);
  assert.equal(manifest[0].name, `mbui-pages-test-${commit.slice(0, 24)}.tar.gz`);

  // Tampered R2 payload must fail SHA-256 verification before unpacking.
  const corruptDir = join(dir, "corrupt-consumer");
  mkdirSync(corruptDir, { recursive: true });
  writeFileSync(join(corruptDir, "natives.r2.json"), readFileSync(join(artifactDir, "natives.r2.json")));
  const badGet = spawnSync("bash", [script, "get", corruptDir, commit], {
    cwd: root,
    encoding: "utf8",
    env: { ...env, NODE_OPTIONS: `--import ${makePreload(dir, storeDir, true)}` },
  });
  assert.notEqual(badGet.status, 0);
  assert.match(badGet.stderr, /failed SHA-256 verification/);
  assert.equal(existsSync(join(corruptDir, "sfapp_pages_test.blackbox_test.exe")), false);

  // Clean consumer restore unpacks all files, preserves executable bit, and removes manifest + tarball.
  const get = spawnSync("bash", [script, "get", artifactDir, commit], { cwd: root, encoding: "utf8", env });
  assert.equal(get.status, 0, `stdout:\n${get.stdout}\nstderr:\n${get.stderr}`);
  assert.equal(existsSync(join(artifactDir, "natives.r2.json")), false);
  assert.equal(existsSync(join(artifactDir, manifest[0].name)), false);
  assert.equal(readFileSync(join(artifactDir, "sfapp_pages_test.blackbox_test.exe"), "utf8"), "binary-payload-1234567890");
  assert.notEqual(statSync(join(artifactDir, "sfapp_pages_test.blackbox_test.exe")).mode & 0o111, 0);
  assert.equal(readFileSync(join(artifactDir, "__blackbox_test_info.json"), "utf8"), '{"tests":42}\n');
  assert.equal(readFileSync(join(artifactDir, "nested", "extra.txt"), "utf8"), "nested-ok");
});

test("mbui-artifact-handoff is a no-op for direct artifacts and empty or missing directories", { skip: process.platform === "win32" }, (t) => {
  const dir = mkdtempSync(join(tmpdir(), "mbui-handoff-noop-"));
  t.after(() => rmSync(dir, { recursive: true, force: true }));

  // Missing dir on put -> exit 0, creates nothing.
  const missingPut = spawnSync("bash", [script, "put", "pkgs", join(dir, "nope"), commit], { cwd: root, encoding: "utf8" });
  assert.equal(missingPut.status, 0, missingPut.stderr);
  assert.equal(existsSync(join(dir, "nope")), false);

  // Empty dir on put -> exit 0, writes no manifest.
  const emptyDir = join(dir, "empty");
  mkdirSync(emptyDir);
  const emptyPut = spawnSync("bash", [script, "put", "pkgs", emptyDir, commit], { cwd: root, encoding: "utf8" });
  assert.equal(emptyPut.status, 0, emptyPut.stderr);
  assert.deepEqual(readdirSync(emptyDir), []);

  // Direct artifact (ubuntu-24.04 / main) on get -> exit 0 without touching files or network.
  const directDir = join(dir, "direct");
  mkdirSync(directDir);
  writeFileSync(join(directDir, "flows.blackbox_test.exe"), "direct-binary");
  const directGet = spawnSync("bash", [script, "get", directDir, commit], { cwd: root, encoding: "utf8" });
  assert.equal(directGet.status, 0, directGet.stderr);
  assert.equal(readFileSync(join(directDir, "flows.blackbox_test.exe"), "utf8"), "direct-binary");
});
