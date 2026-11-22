import assert from "node:assert/strict";
import { execFileSync, spawn } from "node:child_process";
import { createHash } from "node:crypto";
import { chmodSync, existsSync, mkdirSync, mkdtempSync, readdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import { fileURLToPath } from "node:url";

// scripts/release.sh gets each platform's Node side by side into one cache: neither run reads the other's half-written
// download, checksum list or unpacked directory, and the package made of bin/node is made once and copied after.
test("node-dist.sh run for several platforms at once into one cache, then again from the cache", { skip: process.platform === "win32" }, async (t) => {
  const root = fileURLToPath(new URL("..", import.meta.url));
  const tmp = mkdtempSync(join(tmpdir(), "node-dist-test-"));
  t.after(() => rmSync(tmp, { recursive: true, force: true }));
  const version = readFileSync(join(root, ".node-version"), "utf8").trim();
  const site = join(tmp, "site"), bin = join(tmp, "bin"), cache = join(tmp, "cache");
  mkdirSync(site);
  mkdirSync(bin);
  const platforms = ["darwin-arm64", "linux-x64", "linux-arm64"];
  let sums = "";
  for (const p of platforms) {
    const dist = `node-v${version}-${p}`;
    const tree = join(tmp, "tree", dist);
    mkdirSync(join(tree, "bin"), { recursive: true });
    mkdirSync(join(tree, "include"), { recursive: true });
    writeFileSync(join(tree, "bin/node"), `node for ${p}`);
    chmodSync(join(tree, "bin/node"), 0o755);
    writeFileSync(join(tree, "LICENSE"), "license");
    writeFileSync(join(tree, "include/node.h"), "a header, not packed");
    execFileSync("tar", ["-czf", join(site, `${dist}.tar.gz`), "-C", join(tmp, "tree"), dist]);
    sums += `${createHash("sha256").update(readFileSync(join(site, `${dist}.tar.gz`))).digest("hex")}  ${dist}.tar.gz\n`;
  }
  writeFileSync(join(site, "SHASUMS256.txt"), sums);
  // nodejs.org as a directory, each download logged
  writeFileSync(join(bin, "curl"), `#!/bin/sh
out= url=
while [ "$#" -gt 0 ]; do case "$1" in -o) shift; out=$1 ;; https://*) url=$1 ;; esac; shift; done
echo "\${url##*/}" >> "$FAKE_LOG"
cp "$FAKE_SITE/\${url##*/}" "$out"
`);
  chmodSync(join(bin, "curl"), 0o755);
  const log = join(tmp, "downloads");
  const env = { ...process.env, PATH: `${bin}:${process.env.PATH}`, STATION_TS_TARGET_DIR: cache, FAKE_SITE: site, FAKE_LOG: log };
  const run = (p: string, out: string) => new Promise<string>((resolve, reject) => {
    const child = spawn("sh", [join(root, "scripts/node-dist.sh"), out, p], { env, stdio: ["ignore", "pipe", "inherit"] });
    let said = "";
    child.stdout.on("data", (b) => { said += b; });
    child.on("close", (code) => code === 0 ? resolve(said.trim()) : reject(new Error(`${p}: node-dist.sh ended ${code}`)));
  });
  const check = (p: string, file: string) => {
    assert.equal(file, join(tmp, `out-${p}`, `node/node-v${version}-${p}.tar.gz`));
    assert.equal(readFileSync(`${file}.sha256`, "utf8").trim(), createHash("sha256").update(readFileSync(file)).digest("hex"));
    const listed = execFileSync("tar", ["-tzf", file], { encoding: "utf8" }).trim().split("\n").sort();
    assert.deepEqual(listed, ["LICENSE", "bin/node"]);
    assert.equal(execFileSync("tar", ["-xzOf", file, "bin/node"], { encoding: "utf8" }), `node for ${p}`);
  };
  const first = await Promise.all(platforms.map((p) => run(p, join(tmp, `out-${p}`))));
  platforms.forEach((p, i) => check(p, first[i]!));
  const node = join(cache, "node");
  // (nothing half-written left behind, and of the tarball bin/node and its LICENSE alone unpacked)
  assert.deepEqual(readdirSync(node).filter((n) => /\.(part|tmp)\.|SHASUMS/.test(n)), []);
  for (const p of platforms) {
    assert.equal(existsSync(join(node, `node-v${version}-${p}/include`)), false);
    assert.ok(existsSync(join(node, `packed-node-v${version}-${p}.tar.gz`)));
  }
  const downloads = readFileSync(log, "utf8");
  for (const p of platforms) rmSync(join(tmp, `out-${p}`), { recursive: true });
  const again = await Promise.all(platforms.map((p) => run(p, join(tmp, `out-${p}`))));
  platforms.forEach((p, i) => check(p, again[i]!));
  assert.equal(readFileSync(log, "utf8"), downloads, "nothing downloaded again");
  // (the package copied as made the first time, not gzipped again)
  for (const p of platforms) assert.deepEqual(readFileSync(again[platforms.indexOf(p)]!), readFileSync(join(node, `packed-node-v${version}-${p}.tar.gz`)));
});
