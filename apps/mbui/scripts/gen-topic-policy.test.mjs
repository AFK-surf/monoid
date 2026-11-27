import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { mkdtempSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { describe, it } from "node:test";
import { fileURLToPath } from "node:url";
import { generateTopicPolicyMbt } from "./gen-topic-policy.mjs";

describe("gen-topic-policy fail-fast validation", () => {
  const baseTopics = {
    a: { scope: ["string", "req"] },
    b: { scope: ["string", "req"], query: ["string", "def"] },
  };
  const basePolicy = {
    a: { retention: "live" },
    b: { retention: "live" },
  };

  it("rejects byParam until per-param codegen is implemented", () => {
    assert.throws(
      () =>
        generateTopicPolicyMbt(baseTopics, {
          ...basePolicy,
          a: { retention: "swr", keep: 8, showKept: true, byParam: { key: "part", values: {} } },
        }),
      /byParam is not yet supported/,
    );
  });

  it("rejects live topics with keep / lasting / showKept / keepBeforeViews", () => {
    assert.throws(
      () => generateTopicPolicyMbt(baseTopics, { ...basePolicy, a: { retention: "live", keep: 4 } }),
      /live topic cannot set/,
    );
    assert.throws(
      () => generateTopicPolicyMbt(baseTopics, { ...basePolicy, a: { retention: "live", lasting: true } }),
      /live topic cannot set/,
    );
  });

  it("rejects lasting combined with showKept or keep or query param", () => {
    assert.throws(
      () =>
        generateTopicPolicyMbt(baseTopics, {
          ...basePolicy,
          a: { retention: "swr", lasting: true, showKept: true, keep: 8 },
        }),
      /lasting and showKept cannot both be true/,
    );
    assert.throws(
      () =>
        generateTopicPolicyMbt(baseTopics, {
          ...basePolicy,
          a: { retention: "swr", lasting: true, keep: 8 },
        }),
      /cannot set keep\/keepBeforeViews/,
    );
    assert.throws(
      () =>
        generateTopicPolicyMbt(baseTopics, {
          ...basePolicy,
          b: { retention: "swr", lasting: true },
        }),
      /must not declare a 'query' param/,
    );
  });

  it("rejects showKept with keepBeforeViews, non-positive keep, or query param", () => {
    assert.throws(
      () =>
        generateTopicPolicyMbt(baseTopics, {
          ...basePolicy,
          a: { retention: "swr", showKept: true, keep: 8, keepBeforeViews: 4 },
        }),
      /showKept topic cannot set keepBeforeViews/,
    );
    assert.throws(
      () =>
        generateTopicPolicyMbt(baseTopics, {
          ...basePolicy,
          a: { retention: "swr", showKept: true, keep: 0 },
        }),
      /requires positive integer keep/,
    );
    assert.throws(
      () =>
        generateTopicPolicyMbt(baseTopics, {
          ...basePolicy,
          b: { retention: "swr", showKept: true, keep: 8 },
        }),
      /must not declare a 'query' param/,
    );
  });

  it("rejects swr with neither lasting nor showKept, and delta without positive keep", () => {
    assert.throws(
      () => generateTopicPolicyMbt(baseTopics, { ...basePolicy, a: { retention: "swr" } }),
      /must set either lasting: true or showKept: true/,
    );
    assert.throws(
      () => generateTopicPolicyMbt(baseTopics, { ...basePolicy, a: { retention: "delta" } }),
      /delta topic requires positive integer keep/,
    );
  });

  it("exits non-zero on drift when invoked via a symlink path", () => {
    const tmp = mkdtempSync(join(tmpdir(), "gen-topic-policy-symlink-"));
    try {
      const scriptPath = fileURLToPath(new URL("./gen-topic-policy.mjs", import.meta.url));
      const linkPath = join(tmp, "gen-topic-policy-link.mjs");
      const driftedOut = join(tmp, "drifted.mbt");
      symlinkSync(scriptPath, linkPath);
      writeFileSync(driftedOut, "// intentionally drifted\n");

      const res = spawnSync(process.execPath, [linkPath, "--check", "--out", driftedOut], {
        encoding: "utf8",
      });
      assert.notEqual(res.status, 0, "symlinked --check must fail on drifted output");
      assert.match(res.stderr, /not what client\/core-ts\/src\/topic-policy\.ts makes/);
    } finally {
      rmSync(tmp, { recursive: true, force: true });
    }
  });
});
