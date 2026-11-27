// Tests for lockless 2-generation CoW git worktree creation (src/sessions/worktree-cow.ts).
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { chmodSync, existsSync, lstatSync, mkdirSync, mkdtempSync, readdirSync, readFileSync, rmSync, statSync, symlinkSync, utimesSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { after, describe, test } from "node:test";
import { fileURLToPath } from "node:url";
import { clonesAt } from "../src/ops/clone.ts";
import { DISK_LOW_BYTES } from "../src/ops/disk.ts";
import { platform } from "../src/platform/index.ts";
import { REPO_IDLE_MS, relieveRepos } from "../src/sessions/lifecycle.ts";
import { runWorktreeCow } from "../src/sessions/worktree-cow.ts";
import { Rig, testClock } from "./hub-fakes.ts";

const REPO_ROOT = resolve(fileURLToPath(new URL("../..", import.meta.url)));
const dirs: string[] = [];

function scratch(tag: string): string {
  const dir = mkdtempSync(join(tmpdir(), `wt-cow-${tag}-`));
  dirs.push(dir);
  return dir;
}

after(() => {
  for (const d of dirs) rmSync(d, { recursive: true, force: true });
});

function git(cwd: string, args: string[], extraEnv?: Record<string, string>): string {
  return execFileSync("git", args, {
    cwd,
    encoding: "utf8",
    env: {
      ...process.env,
      GIT_AUTHOR_NAME: "Test",
      GIT_AUTHOR_EMAIL: "test@example.com",
      GIT_COMMITTER_NAME: "Test",
      GIT_COMMITTER_EMAIL: "test@example.com",
      GIT_TERMINAL_PROMPT: "0",
      ...extraEnv,
    },
  }).trim();
}

function listTreeFiles(root: string): Map<string, Buffer> {
  const out = new Map<string, Buffer>();
  const walk = (dir: string, rel: string) => {
    for (const name of readdirSync(dir).sort()) {
      if (rel === "" && name === ".git") continue;
      const full = join(dir, name);
      const nextRel = rel === "" ? name : `${rel}/${name}`;
      const st = lstatSync(full);
      if (st.isDirectory()) walk(full, nextRel);
      else out.set(nextRel, readFileSync(full));
    }
  };
  walk(root, "");
  return out;
}

function assertWorktreesIdentical(a: string, b: string, label: string): void {
  const filesA = listTreeFiles(a);
  const filesB = listTreeFiles(b);
  assert.deepEqual([...filesA.keys()], [...filesB.keys()], `${label}: visible file set mismatch`);
  for (const [k, bufA] of filesA) {
    assert.deepEqual(bufA, filesB.get(k), `${label}: file bytes mismatch for ${k}`);
  }
  const getSparse = (d: string) => {
    try {
      return git(d, ["config", "--get", "core.sparseCheckout"]);
    } catch {
      return "";
    }
  };
  assert.equal(getSparse(a), getSparse(b), `${label}: core.sparseCheckout mismatch`);
  assert.equal(git(a, ["ls-files", "-t"]), git(b, ["ls-files", "-t"]), `${label}: git ls-files -t mismatch`);
}

function initSampleRepo(dir: string): { c1: string; c2: string; c3: string } {
  mkdirSync(dir, { recursive: true });
  git(dir, ["init", "-b", "main"]);
  mkdirSync(join(dir, "in"), { recursive: true });
  mkdirSync(join(dir, "out", "b"), { recursive: true });
  mkdirSync(join(dir, "other"), { recursive: true });
  writeFileSync(join(dir, "root.txt"), "root-v1\n");
  writeFileSync(join(dir, "in", "a.txt"), "in-a-v1\n");
  writeFileSync(join(dir, "in", "big.bin"), Buffer.alloc(96 * 1024, 0x55));
  writeFileSync(join(dir, "out", "a.txt"), "out-a-v1\n");
  writeFileSync(join(dir, "out", "b", "x.txt"), "out-b-x-v1\n");
  writeFileSync(join(dir, "other", "z.txt"), "other-z-v1\n");
  git(dir, ["add", "."]);
  git(dir, ["commit", "-m", "c1"]);
  const c1 = git(dir, ["rev-parse", "HEAD"]);

  writeFileSync(join(dir, "in", "a.txt"), "in-a-v2\n");
  writeFileSync(join(dir, "out", "a.txt"), "out-a-v2\n");
  git(dir, ["add", "."]);
  git(dir, ["commit", "-m", "c2"]);
  const c2 = git(dir, ["rev-parse", "HEAD"]);

  writeFileSync(join(dir, "root.txt"), "root-v3\n");
  git(dir, ["add", "."]);
  git(dir, ["commit", "-m", "c3"]);
  const c3 = git(dir, ["rev-parse", "HEAD"]);

  return { c1, c2, c3 };
}

describe("worktree-cow", () => {
  test("same-commit hit, cross-commit reuse, auto-promotion, >2 generation eviction, and concurrent creation", async (t) => {
    const base = scratch("basic");
    if (!(await clonesAt(base))) {
      t.skip("filesystem does not support CoW cloning");
      return;
    }
    const repo = join(base, "repo");
    const { c1, c2, c3 } = initSampleRepo(repo);
    const cowDir = join(repo, ".git", "cow");

    // 1. First creation on c1 -> cold miss, auto-promotes c1.
    const wt1 = join(base, "wt1");
    const r1 = await runWorktreeCow(["-C", repo, "worktree", "add", "--detach", wt1, c1], base);
    assert.equal(r1.code, 0);
    assert.equal(r1.usedCow, true);
    assert.equal(r1.hitGen, null);
    assert.equal(r1.promoted, true);
    const c1GenDir = readdirSync(cowDir).find((n) => n.startsWith(`${c1}-`) && /^[0-9a-f]{40}-[0-9a-f]{16}$/.test(n));
    assert.ok(c1GenDir && existsSync(join(cowDir, c1GenDir, "meta.json")));
    assert.equal(readFileSync(join(wt1, "in", "a.txt"), "utf8"), "in-a-v1\n");

    // 2. Second creation on c1 -> exact generation hit.
    const wt2 = join(base, "wt2");
    const r2 = await runWorktreeCow(["-C", repo, "worktree", "add", "--detach", wt2, c1], base);
    assert.equal(r2.code, 0);
    assert.equal(r2.usedCow, true);
    assert.equal(r2.hitGen, c1);
    assert.equal(r2.promoted, false);

    // 3. Cross-commit creation on c2 -> hits c1 generation, updates changed files cleanly.
    const wt3 = join(base, "wt3");
    const r3 = await runWorktreeCow(["-C", repo, "worktree", "add", "--detach", wt3, c2], base);
    assert.equal(r3.code, 0);
    assert.equal(r3.usedCow, true);
    assert.equal(r3.hitGen, c1);
    assert.equal(readFileSync(join(wt3, "in", "a.txt"), "utf8"), "in-a-v2\n");
    assert.equal(readFileSync(join(wt3, "in", "big.bin")).length, 96 * 1024);

    // 4. Promote c2 and c3 as HEAD -> >2 generations must evict oldest, leaving at most 2.
    git(repo, ["checkout", "-q", c2]);
    const wt4 = join(base, "wt4");
    const r4 = await runWorktreeCow(["-C", repo, "worktree", "add", "--detach", wt4, c2], base);
    assert.equal(r4.code, 0);
    assert.equal(r4.promoted, true);
    // Ensure distinct mtime for c3 promotion.
    const older = new Date(Date.now() - 60_000);
    utimesSync(join(cowDir, c1GenDir!, "meta.json"), older, older);

    git(repo, ["checkout", "-q", c3]);
    const wt5 = join(base, "wt5");
    const r5 = await runWorktreeCow(["-C", repo, "worktree", "add", "--detach", wt5, c3], base);
    assert.equal(r5.code, 0);
    assert.equal(r5.promoted, true);

    const gens = readdirSync(cowDir).filter((n) => /^[0-9a-f]{40}-[0-9a-f]{16}$/.test(n));
    assert.equal(gens.length, 2, `expected at most 2 generations kept, got ${gens.join(",")}`);
    assert.ok(gens.some((g) => g.startsWith(`${c3}-`)), "newest promoted generation must be kept");

    // 5. Concurrent creation + promotion leaves no .tmp-* directories.
    rmSync(cowDir, { recursive: true, force: true });
    const conc = await Promise.all(
      [0, 1, 2, 3].map((i) => runWorktreeCow(["-C", repo, "worktree", "add", "--detach", join(base, `conc-${i}`), c3], base)),
    );
    for (const r of conc) {
      assert.equal(r.code, 0);
      assert.equal(r.usedCow, true);
    }
    const leftovers = readdirSync(cowDir).filter((n) => n.startsWith(".tmp-"));
    assert.deepEqual(leftovers, [], "no leftover .tmp-* directories after concurrent promotion");
  });

  test("Sparse x Full 4 quadrants match native git worktree add byte-for-byte without mutating sparse source", async (t) => {
    const base = scratch("sparse-quad");
    if (!(await clonesAt(base))) {
      t.skip("filesystem does not support CoW cloning");
      return;
    }

    const setupRepo = (name: string, sparse: boolean) => {
      const repo = join(base, name);
      const commits = initSampleRepo(repo);
      if (sparse) {
        git(repo, ["sparse-checkout", "init", "--cone"]);
        git(repo, ["sparse-checkout", "set", "in", "out/b"]);
      }
      return { repo, ...commits };
    };

    // Quadrant 1: full <- full
    {
      const { repo, c1, c2 } = setupRepo("q-ff", false);
      const seed = join(base, "q-ff-seed");
      assert.equal((await runWorktreeCow(["-C", repo, "worktree", "add", "--detach", seed, c1], base)).code, 0);
      const cowWt = join(base, "q-ff-cow");
      const natWt = join(base, "q-ff-nat");
      const res = await runWorktreeCow(["-C", repo, "worktree", "add", "--detach", cowWt, c2], base);
      assert.equal(res.code, 0);
      assert.equal(res.hitGen, c1);
      git(repo, ["worktree", "add", "--detach", natWt, c2]);
      assertWorktreesIdentical(cowWt, natWt, "full<-full");
    }

    // Quadrant 2: sparse <- sparse (and verify promoted sparse source is untouched)
    {
      const { repo, c1, c2 } = setupRepo("q-ss", true);
      const seed = join(base, "q-ss-seed");
      const rSeed = await runWorktreeCow(["-C", repo, "worktree", "add", "--detach", seed, c1], base);
      assert.equal(rSeed.code, 0);
      assert.equal(rSeed.promoted, true);

      // Verify seed worktree itself still has sparse checkout intact (other/z.txt absent, ls-files has S).
      assert.equal(existsSync(join(seed, "other", "z.txt")), false, "promoted sparse source must not be materialized");
      assert.match(git(seed, ["ls-files", "-t"]), /^S other\/z\.txt$/m, "promoted sparse source index must retain S bit");

      const cowWt = join(base, "q-ss-cow");
      const natWt = join(base, "q-ss-nat");
      const res = await runWorktreeCow(["-C", repo, "worktree", "add", "--detach", cowWt, c2], base);
      assert.equal(res.code, 0);
      assert.equal(res.hitGen, c1);
      git(repo, ["worktree", "add", "--detach", natWt, c2]);
      assertWorktreesIdentical(cowWt, natWt, "sparse<-sparse");
    }

    // Quadrant 3: full <- sparse (gen promoted while sparse, then sparse disabled before full worktree)
    {
      const { repo, c1, c2 } = setupRepo("q-fs", true);
      const seed = join(base, "q-fs-seed");
      const rSeed = await runWorktreeCow(["-C", repo, "worktree", "add", "--detach", seed, c1], base);
      assert.equal(rSeed.code, 0);
      assert.equal(rSeed.promoted, true);

      // Disable sparse checkout on repo so subsequent worktrees are full.
      git(repo, ["sparse-checkout", "disable"]);

      const cowWt = join(base, "q-fs-cow");
      const natWt = join(base, "q-fs-nat");
      const res = await runWorktreeCow(["-C", repo, "worktree", "add", "--detach", cowWt, c2], base);
      assert.equal(res.code, 0);
      assert.equal(res.hitGen, c1);
      git(repo, ["worktree", "add", "--detach", natWt, c2]);
      assertWorktreesIdentical(cowWt, natWt, "full<-sparse");
    }

    // Quadrant 4: sparse <- full (gen promoted while full, then sparse enabled before sparse worktree)
    {
      const { repo, c1, c2 } = setupRepo("q-sf", false);
      const seed = join(base, "q-sf-seed");
      const rSeed = await runWorktreeCow(["-C", repo, "worktree", "add", "--detach", seed, c1], base);
      assert.equal(rSeed.code, 0);
      assert.equal(rSeed.promoted, true);

      git(repo, ["sparse-checkout", "init", "--cone"]);
      git(repo, ["sparse-checkout", "set", "in", "out/b"]);

      const cowWt = join(base, "q-sf-cow");
      const natWt = join(base, "q-sf-nat");
      const res = await runWorktreeCow(["-C", repo, "worktree", "add", "--detach", cowWt, c2], base);
      assert.equal(res.code, 0);
      assert.equal(res.hitGen, c1);
      git(repo, ["worktree", "add", "--detach", natWt, c2]);
      assertWorktreesIdentical(cowWt, natWt, "sparse<-full");
    }
  });

  test("regression gates: cross-commit .gitattributes, external XDG/info attributes, hooksPath, non-empty target, -b passthrough, env bypass", async (t) => {
    const base = scratch("gates");
    if (!(await clonesAt(base))) {
      t.skip("filesystem does not support CoW cloning");
      return;
    }

    // 1. Cross-commit .gitattributes change (eol=lf -> eol=crlf, file blob unchanged)
    {
      const repo = join(base, "attr-repo");
      mkdirSync(repo, { recursive: true });
      git(repo, ["init", "-b", "main"]);
      writeFileSync(join(repo, ".gitattributes"), "*.txt text eol=lf\n");
      writeFileSync(join(repo, "hello.txt"), "line1\nline2\n");
      git(repo, ["add", "."]);
      git(repo, ["commit", "-m", "lf"]);
      const cLf = git(repo, ["rev-parse", "HEAD"]);

      writeFileSync(join(repo, ".gitattributes"), "*.txt text eol=crlf\n");
      git(repo, ["add", ".gitattributes"]);
      git(repo, ["commit", "-m", "crlf"]);
      const cCrlf = git(repo, ["rev-parse", "HEAD"]);

      // Promote cLf
      const wt1 = join(base, "attr-wt1");
      assert.equal((await runWorktreeCow(["-C", repo, "worktree", "add", "--detach", wt1, cLf], base)).code, 0);
      assert.equal(readFileSync(join(wt1, "hello.txt"), "utf8"), "line1\nline2\n");

      // Checkout cCrlf: diff touches .gitattributes, so CoW gen must NOT be reused blindly -> CRLF bytes!
      const wt2 = join(base, "attr-wt2");
      const r2 = await runWorktreeCow(["-C", repo, "worktree", "add", "--detach", wt2, cCrlf], base);
      assert.equal(r2.code, 0);
      assert.equal(r2.hitGen, null, "gen must be bypassed when diff touches .gitattributes");
      assert.equal(readFileSync(join(wt2, "hello.txt"), "utf8"), "line1\r\nline2\r\n");
    }

    // 2. Same-commit external $GIT_DIR/info/attributes change invalidates fingerprint
    {
      const repo = join(base, "info-attr-repo");
      mkdirSync(repo, { recursive: true });
      git(repo, ["init", "-b", "main"]);
      writeFileSync(join(repo, "f.txt"), "a\nb\n");
      git(repo, ["add", "."]);
      git(repo, ["commit", "-m", "init"]);
      const c1 = git(repo, ["rev-parse", "HEAD"]);

      writeFileSync(join(repo, ".git", "info", "attributes"), "*.txt text eol=lf\n");
      const wt1 = join(base, "info-wt1");
      assert.equal((await runWorktreeCow(["-C", repo, "worktree", "add", "--detach", wt1, c1], base)).code, 0);
      assert.equal(readFileSync(join(wt1, "f.txt"), "utf8"), "a\nb\n");

      writeFileSync(join(repo, ".git", "info", "attributes"), "*.txt text eol=crlf\n");
      const wt2 = join(base, "info-wt2");
      const r2 = await runWorktreeCow(["-C", repo, "worktree", "add", "--detach", wt2, c1], base);
      assert.equal(r2.code, 0);
      assert.equal(r2.hitGen, null, "fingerprint mismatch must invalidate old gen");
      assert.equal(readFileSync(join(wt2, "f.txt"), "utf8"), "a\r\nb\r\n");
    }

    // 3. Relative sibling core.hooksPath=../hooks & in-repo .githooks/post-checkout bypass; .githooks without post-checkout uses CoW
    if (platform.os !== "windows") {
      // 3a. Sibling ../hooks/post-checkout -> bypasses CoW, hook executes exactly once
      const repo = join(base, "hook-sibling");
      mkdirSync(repo, { recursive: true });
      git(repo, ["init", "-b", "main"]);
      writeFileSync(join(repo, "a.txt"), "hi\n");
      git(repo, ["add", "."]);
      git(repo, ["commit", "-m", "init"]);
      const hooksDir = join(base, "hooks");
      const countFile = join(base, "sibling-hook-count.txt");
      mkdirSync(hooksDir, { recursive: true });
      const hookPath = join(hooksDir, "post-checkout");
      writeFileSync(hookPath, `#!/bin/sh\necho ran >> "${countFile}"\n`);
      chmodSync(hookPath, 0o755);
      git(repo, ["config", "core.hooksPath", "../hooks"]);

      const wt = join(base, "wt-sibling");
      const res = await runWorktreeCow(["-C", repo, "worktree", "add", "--detach", wt, "HEAD"], base);
      assert.equal(res.code, 0);
      assert.equal(res.usedCow, false, "relative sibling post-checkout must bypass CoW");
      assert.equal(readFileSync(countFile, "utf8").trim().split("\n").length, 1, "post-checkout hook must run exactly once");

      // 3b. In-repo .githooks/post-checkout -> bypasses CoW, hook executes exactly once
      const repoIn = join(base, "hook-inrepo");
      mkdirSync(join(repoIn, ".githooks"), { recursive: true });
      git(repoIn, ["init", "-b", "main"]);
      const countIn = join(base, "inrepo-hook-count.txt");
      const inHook = join(repoIn, ".githooks", "post-checkout");
      writeFileSync(inHook, `#!/bin/sh\necho ran >> "${countIn}"\n`);
      chmodSync(inHook, 0o755);
      git(repoIn, ["add", "."]);
      git(repoIn, ["commit", "-m", "init"]);
      git(repoIn, ["config", "core.hooksPath", ".githooks"]);

      const wtIn = join(base, "wt-inrepo");
      const resIn = await runWorktreeCow(["-C", repoIn, "worktree", "add", "--detach", wtIn, "HEAD"], base);
      assert.equal(resIn.code, 0);
      assert.equal(resIn.usedCow, false, "in-repo .githooks/post-checkout must bypass CoW");
      assert.equal(readFileSync(countIn, "utf8").trim().split("\n").length, 1, "in-repo post-checkout hook must run exactly once");

      // 3c. In-repo .githooks WITHOUT post-checkout (like monoid) -> uses CoW fast path!
      const repoNoHook = join(base, "hook-none");
      mkdirSync(join(repoNoHook, ".githooks"), { recursive: true });
      git(repoNoHook, ["init", "-b", "main"]);
      writeFileSync(join(repoNoHook, ".githooks", "pre-commit"), "#!/bin/sh\nexit 0\n");
      chmodSync(join(repoNoHook, ".githooks", "pre-commit"), 0o755);
      git(repoNoHook, ["add", "."]);
      git(repoNoHook, ["commit", "-m", "init"]);
      git(repoNoHook, ["config", "core.hooksPath", ".githooks"]);

      const wtNoHook = join(base, "wt-nohook");
      const resNoHook = await runWorktreeCow(["-C", repoNoHook, "worktree", "add", "--detach", wtNoHook, "HEAD"], base);
      assert.equal(resNoHook.code, 0);
      assert.equal(resNoHook.usedCow, true, "repo with .githooks but no post-checkout must use CoW fast path");
    }

    // 4. Non-empty target path rejected, -b branch passthrough, STILLFAIL_WORKTREE_COW=0 bypass
    {
      const repo = join(base, "misc-repo");
      initSampleRepo(repo);

      const nonEmpty = join(base, "non-empty");
      mkdirSync(nonEmpty, { recursive: true });
      writeFileSync(join(nonEmpty, "keep.txt"), "keep\n");
      const rNonEmpty = await runWorktreeCow(["-C", repo, "worktree", "add", "--detach", nonEmpty, "HEAD"], base);
      assert.notEqual(rNonEmpty.code, 0, "non-empty target must fail");
      assert.equal(readFileSync(join(nonEmpty, "keep.txt"), "utf8"), "keep\n", "existing file must not be clobbered");

      const branchWt = join(base, "branch-wt");
      const rBranch = await runWorktreeCow(["-C", repo, "worktree", "add", "-b", "feat/x", branchWt, "HEAD"], base);
      assert.equal(rBranch.code, 0);
      assert.equal(rBranch.usedCow, false, "-b must pass through to native git");
      assert.equal(git(branchWt, ["rev-parse", "--abbrev-ref", "HEAD"]), "feat/x");

      const prevEnv = process.env.STILLFAIL_WORKTREE_COW;
      process.env.STILLFAIL_WORKTREE_COW = "0";
      try {
        const envWt = join(base, "env-wt");
        const rEnv = await runWorktreeCow(["-C", repo, "worktree", "add", "--detach", envWt, "HEAD"], base);
        assert.equal(rEnv.code, 0);
        assert.equal(rEnv.usedCow, false, "STILLFAIL_WORKTREE_COW=0 must bypass CoW");
      } finally {
        if (prevEnv === undefined) delete process.env.STILLFAIL_WORKTREE_COW;
        else process.env.STILLFAIL_WORKTREE_COW = prevEnv;
      }
    }

    // 5. CLI wrapper bin/stillfail -C <repo> worktree add --detach
    if (platform.os !== "windows") {
      const repo = join(base, "cli-repo");
      initSampleRepo(repo);
      const cliWt = join(base, "cli-wt");
      execFileSync(join(REPO_ROOT, "bin", "stillfail"), ["-C", repo, "worktree", "add", "--detach", cliWt, "HEAD"], {
        cwd: base,
        encoding: "utf8",
      });
      assert.ok(existsSync(join(cliWt, "root.txt")));
      assert.ok(existsSync(join(repo, ".git", "cow")), "bin/stillfail worktree add must promote CoW gen");
    }

    // 6. Relative path with `-C <repo>` from outside caller_cwd resolves relative to `<repo>` identically with CoW on & off.
    {
      const repo = join(base, "rel-repo");
      initSampleRepo(repo);
      const outside = join(base, "outside-caller");
      mkdirSync(outside, { recursive: true });
      const rCow = await runWorktreeCow(["-C", repo, "worktree", "add", "--detach", "rel/wt-cow", "HEAD"], outside);
      assert.equal(rCow.code, 0);
      assert.equal(rCow.usedCow, true);
      assert.ok(existsSync(join(repo, "rel", "wt-cow", "root.txt")), "CoW relative path must land under <repo>/rel/wt-cow");
      assert.equal(existsSync(join(outside, "rel", "wt-cow")), false, "CoW relative path must not land under caller_cwd");

      const prevEnv = process.env.STILLFAIL_WORKTREE_COW;
      process.env.STILLFAIL_WORKTREE_COW = "0";
      try {
        const rNat = await runWorktreeCow(["-C", repo, "worktree", "add", "--detach", "rel/wt-nat", "HEAD"], outside);
        assert.equal(rNat.code, 0);
        assert.equal(rNat.usedCow, false);
        assert.ok(existsSync(join(repo, "rel", "wt-nat", "root.txt")), "native passthrough relative path lands under <repo>/rel/wt-nat");
      } finally {
        if (prevEnv === undefined) delete process.env.STILLFAIL_WORKTREE_COW;
        else process.env.STILLFAIL_WORKTREE_COW = prevEnv;
      }
    }

    // 7. `.gitattributes` with `filter=lfs`: uses CoW when `filter.lfs.*` is unconfigured, bypasses when configured.
    {
      const prevGlobal = process.env.GIT_CONFIG_GLOBAL;
      const prevNoSystem = process.env.GIT_CONFIG_NOSYSTEM;
      const emptyGlobalCfg = join(base, "empty-global.gitconfig");
      writeFileSync(emptyGlobalCfg, "");
      process.env.GIT_CONFIG_GLOBAL = emptyGlobalCfg;
      process.env.GIT_CONFIG_NOSYSTEM = "1";
      try {
        const repo = join(base, "lfs-filter-repo");
        mkdirSync(repo, { recursive: true });
        git(repo, ["init", "-b", "main"]);
        writeFileSync(join(repo, ".gitattributes"), "*.bin filter=lfs diff=lfs merge=lfs -text\n");
        writeFileSync(join(repo, "data.bin"), "binary-data\n");
        git(repo, ["add", "."]);
        git(repo, ["commit", "-m", "init lfs attr"]);

        const wtUnconf = join(base, "wt-lfs-unconf");
        const rUnconf = await runWorktreeCow(["-C", repo, "worktree", "add", "--detach", wtUnconf, "HEAD"], base);
        assert.equal(rUnconf.code, 0);
        assert.equal(rUnconf.usedCow, true, "unconfigured filter=lfs must still use CoW fast path");

        git(repo, ["config", "filter.lfs.smudge", "cat"]);
        const wtConf = join(base, "wt-lfs-conf");
        const rConf = await runWorktreeCow(["-C", repo, "worktree", "add", "--detach", wtConf, "HEAD"], base);
        assert.equal(rConf.code, 0);
        assert.equal(rConf.usedCow, false, "configured filter.lfs.smudge must bypass CoW to native git");
      } finally {
        if (prevGlobal === undefined) delete process.env.GIT_CONFIG_GLOBAL;
        else process.env.GIT_CONFIG_GLOBAL = prevGlobal;
        if (prevNoSystem === undefined) delete process.env.GIT_CONFIG_NOSYSTEM;
        else process.env.GIT_CONFIG_NOSYSTEM = prevNoSystem;
      }
    }

    // 8. Relative `core.hooksPath` traversing a tracked directory symlink (`hooks -> scripts`) bypasses CoW and runs `post-checkout` once.
    if (process.platform !== "win32") {
      const repo = join(base, "symlink-hook-repo");
      mkdirSync(join(repo, "scripts"), { recursive: true });
      git(repo, ["init", "-b", "main"]);
      const markerPath = join(base, "symlink-hook-ran.txt");
      const hookFile = join(repo, "scripts", "post-checkout");
      writeFileSync(hookFile, `#!/bin/sh\necho ran >> "${markerPath}"\n`);
      chmodSync(hookFile, 0o755);
      symlinkSync("scripts", join(repo, "hooks"));
      git(repo, ["add", "."]);
      git(repo, ["commit", "-m", "tracked symlink hooks -> scripts"]);
      git(repo, ["config", "core.hooksPath", "hooks"]);

      const wtSymHook = join(base, "wt-sym-hook");
      const rSym = await runWorktreeCow(["-C", repo, "worktree", "add", "--detach", wtSymHook, "HEAD"], base);
      assert.equal(rSym.code, 0);
      assert.equal(rSym.usedCow, false, "tracked symlink hooksPath must bypass CoW to native git");
      assert.equal(readFileSync(markerPath, "utf8").trim(), "ran", "native git executed post-checkout exactly once");
    }

    // 9. Corrupt `meta.json` occupying `cow/<oid>-<fp16>` is reclaimed after grace period and re-promoted cleanly.
    {
      const repo = join(base, "corrupt-meta-repo");
      initSampleRepo(repo);
      const wt1 = join(base, "wt-corrupt-1");
      const r1 = await runWorktreeCow(["-C", repo, "worktree", "add", "--detach", wt1, "HEAD"], base);
      assert.equal(r1.code, 0);
      assert.equal(r1.promoted, true);

      const cowDir = join(repo, ".git", "cow");
      const gens = readdirSync(cowDir);
      assert.equal(gens.length, 1);
      const genDir = join(cowDir, gens[0]!);
      writeFileSync(join(genDir, "meta.json"), "{corrupt-json");
      const oldSec = Math.floor((Date.now() - 7_200_000) / 1000);
      utimesSync(genDir, oldSec, oldSec);

      // Next run misses and its cleanupCowDir evicts the aged corrupt generation; run after re-promotes cleanly.
      const wt2 = join(base, "wt-corrupt-2");
      const r2 = await runWorktreeCow(["-C", repo, "worktree", "add", "--detach", wt2, "HEAD"], base);
      assert.equal(r2.code, 0);
      assert.equal(r2.usedCow, true);

      const wt3 = join(base, "wt-corrupt-3");
      const r3 = await runWorktreeCow(["-C", repo, "worktree", "add", "--detach", wt3, "HEAD"], base);
      assert.equal(r3.code, 0);
      assert.equal(r3.promoted, true, "reclaimed slot re-promoted cleanly");

      const wt4 = join(base, "wt-corrupt-4");
      const r4 = await runWorktreeCow(["-C", repo, "worktree", "add", "--detach", wt4, "HEAD"], base);
      assert.equal(r4.code, 0);
      assert.equal(r4.hitGen, gens[0]!.slice(0, 40));
    }
  });

  test("relieveRepos reclaims a shared clone containing .git/cow when no worktree registrations remain", async (t) => {
    const base = scratch("relieve");
    if (!(await clonesAt(base))) {
      t.skip("filesystem does not support CoW cloning");
      return;
    }
    const clock = testClock();
    await clock.adjust(Date.now() + REPO_IDLE_MS + 120_000);
    const rig = new Rig({ clock: clock.clock });
    try {
      const bare = join(base, "origin.git");
      mkdirSync(bare, { recursive: true });
      git(bare, ["init", "--bare"]);

      const repo = join(rig.dir, "repos", "cow-reclaimable");
      initSampleRepo(repo);
      git(repo, ["remote", "add", "origin", bare]);
      git(repo, ["push", "-u", "origin", "main"]);
      git(repo, ["remote", "set-url", "origin", "https://example.com/cow-reclaimable.git"]);

      // Create & remove a CoW worktree so .git/cow/<oid> exists with zero worktrees registered.
      const wt = join(base, "temp-wt");
      const res = await runWorktreeCow(["-C", repo, "worktree", "add", "--detach", wt, "HEAD"], base);
      assert.equal(res.code, 0);
      assert.ok(existsSync(join(repo, ".git", "cow")));
      git(repo, ["worktree", "remove", "--force", wt]);

      // Repo files have current wall-clock mtime while testClock is advanced past REPO_IDLE_MS.
      const removed = await relieveRepos(rig.hub, () => 0, DISK_LOW_BYTES, { full: true });
      assert.ok(removed.includes("cow-reclaimable"), `expected cow-reclaimable to be reclaimed, got ${JSON.stringify(removed)}`);
      assert.equal(existsSync(repo), false);
    } finally {
      await rig.close();
    }
  });
});
