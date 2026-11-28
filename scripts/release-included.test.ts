import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { generateKeyPairSync } from "node:crypto";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";
import { keyId, verifyFeed } from "../shared/release-signed.ts";
import { buildReleaseIncluded, writeReleaseIncluded } from "./release-included.ts";
import { doomedOf } from "./release-prune.ts";

function cleanEnv(extra: Record<string, string> = {}): NodeJS.ProcessEnv {
  const env: NodeJS.ProcessEnv = { ...process.env };
  for (const k of Object.keys(env)) {
    if (k.startsWith("GIT_")) delete env[k];
  }
  return { ...env, ...extra };
}

function git(cwd: string, ...args: string[]): string {
  return execFileSync("git", args, {
    cwd,
    encoding: "utf8",
    env: cleanEnv({
      GIT_AUTHOR_NAME: "Test",
      GIT_AUTHOR_EMAIL: "test@example.com",
      GIT_COMMITTER_NAME: "Test",
      GIT_COMMITTER_EMAIL: "test@example.com",
    }),
  }).trim();
}

test("release-included: linear main commits, release branch cherry-pick -x, PR subjects, Fixes trailers, channel-free path", () => {
  const dir = mkdtempSync(join(tmpdir(), "release-included-test-"));
  const repo = join(dir, "repo");
  const outDir = join(dir, "out");
  mkdirSync(repo, { recursive: true });
  try {
    git(repo, "init", "-b", "main");
    writeFileSync(join(repo, "a.txt"), "1\n");
    git(repo, "add", ".");
    git(repo, "commit", "-m", "feat(station): base commit (#8200)\n\nFixes: FB-101");
    const c1 = git(repo, "rev-parse", "HEAD");

    writeFileSync(join(repo, "a.txt"), "2\n");
    git(repo, "add", ".");
    git(repo, "commit", "-m", "fix(station): second main commit (#8270)\n\nFixes: FB-123, FB-456");
    const c2 = git(repo, "rev-parse", "HEAD");

    // Branch a release branch from c1 and cherry-pick c2 with -x.
    git(repo, "checkout", "-b", "release/0.1", c1);
    git(repo, "cherry-pick", "-x", c2);
    const cpHash = git(repo, "rev-parse", "HEAD");

    const written = writeReleaseIncluded(repo, outDir, { rev: "HEAD", build: 11125 });
    assert.match(written.file, /^station\/included\/11125-[0-9a-f]{16}\.json$/);
    assert.equal(written.file.includes("beta"), false);
    assert.equal(written.file.includes("stable"), false);
    assert.ok(existsSync(written.absPath));
    assert.equal(written.size, readFileSync(written.absPath).byteLength);

    const m = written.manifest;
    assert.equal(m.build, 11125);
    assert.equal(m.commit, cpHash);
    assert.equal(m.baseCommit, c1);
    assert.equal(m.baseBuild, 1);
    assert.deepEqual(m.prs, [8200, 8270]);
    assert.deepEqual(m.fixes, [101, 123, 456]);
    assert.ok(m.commits.includes(c1.slice(0, 12)));
    assert.ok(m.commits.includes(c2.slice(0, 12)), "includes cherry-picked original commit");
    assert.ok(m.commits.includes(cpHash.slice(0, 12)), "includes cherry-pick commit itself");

    // Also test direct buildReleaseIncluded on main.
    const mainManifest = buildReleaseIncluded(repo, { rev: "main", build: 2 });
    assert.equal(mainManifest.baseCommit, c2);
    assert.equal(mainManifest.baseBuild, 2);
    assert.deepEqual(mainManifest.prs, [8200, 8270]);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test("release-sign + verifyFeed: signs and verifies included manifest, and stays compatible without included", () => {
  const dir = mkdtempSync(join(tmpdir(), "release-sign-inc-test-"));
  try {
    const repo = join(dir, "repo");
    mkdirSync(repo, { recursive: true });
    git(repo, "init", "-b", "main");
    writeFileSync(join(repo, "f.txt"), "hello\n");
    git(repo, "add", ".");
    git(repo, "commit", "-m", "fix(station): test fix (#9001)\n\nFixes: FB-77");
    const commit = git(repo, "rev-parse", "HEAD");

    // Create a minimal .tar.gz archive.
    const pkgRoot = join(dir, "pkg");
    mkdirSync(join(pkgRoot, "stillfail"), { recursive: true });
    writeFileSync(join(pkgRoot, "stillfail", "BUILD"), "9001\n");
    const archive = join(dir, "station.tar.gz");
    execFileSync("tar", ["-czf", archive, "-C", pkgRoot, "stillfail"]);

    const { privateKey, publicKey } = generateKeyPairSync("ed25519");
    const pem = privateKey.export({ format: "pem", type: "pkcs8" }).toString();
    const rawPub = Buffer.from(publicKey.export({ format: "jwk" }).x as string, "base64url").toString("base64");
    const trusted = new Map([[keyId(rawPub), rawPub]]);
    // Unset CI so release-sign.ts allows the test's ephemeral key (not in production RELEASE_KEYS).
    const signEnv = cleanEnv({ RELEASE_SIGNING_KEY: pem });
    delete signEnv.CI;

    const incDir = join(dir, "inc");
    const feedWith = join(dir, "station-with.json");
    execFileSync(
      process.execPath,
      [
        join(import.meta.dirname, "release-sign.ts"),
        "station",
        feedWith,
        "--build",
        "9001",
        "--commit",
        commit,
        "--included-dir",
        incDir,
        "--repo",
        repo,
        `linux-x64=${archive}`,
      ],
      { env: signEnv, stdio: "pipe" },
    );

    const parsedWith = JSON.parse(readFileSync(feedWith, "utf8"));
    const verifiedWith = verifyFeed(parsedWith, trusted);
    assert.ok(verifiedWith.included);
    assert.match(verifiedWith.included.file, /^station\/included\/9001-[0-9a-f]{16}\.json$/);
    assert.ok(existsSync(join(incDir, verifiedWith.included.file)));

    // Without --included-dir: still verifies cleanly.
    const feedWithout = join(dir, "station-without.json");
    execFileSync(
      process.execPath,
      [
        join(import.meta.dirname, "release-sign.ts"),
        "station",
        feedWithout,
        "--build",
        "9001",
        "--commit",
        commit,
        `linux-x64=${archive}`,
      ],
      { env: signEnv, stdio: "pipe" },
    );
    const verifiedWithout = verifyFeed(JSON.parse(readFileSync(feedWithout, "utf8")), trusted);
    assert.equal(verifiedWithout.included, undefined);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test("release-prune: keeps referenced and newer station/included manifests, prunes older unreferenced ones", () => {
  const makeFeed = (build: number, incFile: string, earlier: { build: number; incFile: string }[] = []) => {
    const words = (b: number, f: string) =>
      Buffer.from(JSON.stringify({ kind: "stillfail-station-release", version: `0.1.${b}`, build: b, builds: {}, included: { file: f, sha256: "a".repeat(64), size: 10 } })).toString("base64");
    return JSON.stringify({
      version: `0.1.${build}`,
      release: words(build, incFile),
      earlier: earlier.map((e) => ({ version: `0.1.${e.build}`, release: words(e.build, e.incFile) })),
    });
  };
  const feeds = {
    "station.json": makeFeed(100, "station/included/100-aaaaaaaaaaaaaaaa.json", [
      { build: 99, incFile: "station/included/99-bbbbbbbbbbbbbbbb.json" },
    ]),
    "station-beta.json": makeFeed(105, "station/included/105-cccccccccccccccc.json"),
  };
  const keys = [
    "station/included/98-1111111111111111.json", // old, unreferenced -> doom
    "station/included/99-bbbbbbbbbbbbbbbb.json", // referenced in stable earlier -> keep
    "station/included/100-aaaaaaaaaaaaaaaa.json", // referenced in stable -> keep
    "station/included/102-2222222222222222.json", // older than beta (105), unreferenced -> doom
    "station/included/105-cccccccccccccccc.json", // referenced in beta -> keep
    "station/included/106-3333333333333333.json", // newer than max(100,105) -> keep (in-flight release)
  ];
  const doomed = doomedOf(keys, feeds, null, 1_700_000_000);
  assert.deepEqual(doomed, [
    "station/included/98-1111111111111111.json",
    "station/included/102-2222222222222222.json",
  ]);
});
