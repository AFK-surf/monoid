import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { mkdtempSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { describe, it } from "node:test";
import { fileURLToPath } from "node:url";
import { generateTopicPolicyMbt } from "./gen-topic-policy.mjs";

describe("gen-topic-policy fail-fast validation and byParam codegen", () => {
  const baseTopics = {
    a: { scope: ["string", "req"], part: ["string", "req"] },
    b: { scope: ["string", "req"], query: ["string", "def"] },
  };
  const basePolicy = {
    a: { retention: "live" },
    b: { retention: "live" },
  };

  it("generates byParam branches and rejects invalid byParam definitions", () => {
    const out = generateTopicPolicyMbt(baseTopics, {
      ...basePolicy,
      a: {
        retention: "live",
        byParam: {
          key: "part",
          values: {
            logins: { retention: "sensitive" },
            profiles: { retention: "swr", keep: 24, showKept: true },
          },
        },
      },
    });
    assert.match(out, /topic_policy_param_str\(params, "part"\)/);
    assert.match(out, /Some\("logins"\) => true/);
    assert.match(out, /Some\("profiles"\) => if views && !topic_policy_typed\(params\) \{ 24 \} else \{ 0 \}/);

    assert.throws(
      () =>
        generateTopicPolicyMbt(baseTopics, {
          ...basePolicy,
          a: { retention: "live", byParam: { key: "missingKey", values: { x: { retention: "sensitive" } } } },
        }),
      /is not declared in TOPICS/,
    );
    assert.throws(
      () =>
        generateTopicPolicyMbt(baseTopics, {
          ...basePolicy,
          a: { retention: "live", byParam: { key: "part", values: {} } },
        }),
      /byParam\.values must not be empty/,
    );
  });

  it("rejects sensitive and live topics with keep / lasting / showKept / topicPolicy / keepBeforeViews", () => {
    assert.throws(
      () => generateTopicPolicyMbt(baseTopics, { ...basePolicy, a: { retention: "sensitive", keep: 4 } }),
      /sensitive topic cannot set/,
    );
    assert.throws(
      () => generateTopicPolicyMbt(baseTopics, { ...basePolicy, a: { retention: "sensitive", lasting: true } }),
      /sensitive topic cannot set/,
    );
    assert.throws(
      () => generateTopicPolicyMbt(baseTopics, { ...basePolicy, a: { retention: "sensitive", topicPolicy: true } }),
      /sensitive topic cannot set/,
    );
    assert.throws(
      () => generateTopicPolicyMbt(baseTopics, { ...basePolicy, a: { retention: "live", keep: 4 } }),
      /live topic cannot set/,
    );
    assert.throws(
      () => generateTopicPolicyMbt(baseTopics, { ...basePolicy, a: { retention: "live", lasting: true } }),
      /live topic cannot set/,
    );
    assert.throws(
      () => generateTopicPolicyMbt(baseTopics, { ...basePolicy, a: { retention: "live", topicPolicy: true } }),
      /live topic cannot set/,
    );
  });

  it("generates policy-gated byParam branches when topicPolicy is true", () => {
    const out = generateTopicPolicyMbt(baseTopics, {
      ...basePolicy,
      a: {
        retention: "live",
        byParam: {
          key: "part",
          values: {
            logins: { retention: "sensitive" },
            gated: { retention: "swr", keep: 8, showKept: true, topicPolicy: true },
          },
        },
      },
    });
    assert.match(out, /Some\("gated"\) => if views && policy && !topic_policy_typed\(params\) \{ 8 \} else \{ 0 \}/);
    assert.match(out, /Some\("gated"\) => policy/);
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
