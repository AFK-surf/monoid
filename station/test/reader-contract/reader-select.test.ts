import assert from "node:assert/strict";
import { test } from "node:test";
import {
  isReaderMode,
  READER_MODES,
  type ReaderMode,
  readerModeEnvKey,
  resolveReaderEngine,
} from "../../src/read/reader-select.ts";

const READ_ONLY_MODES: readonly ReaderMode[] = [
  "footprint",
  "data",
  "search",
  "live-locator",
  "usage-check",
];

const SIDE_EFFECT_MODES: readonly ReaderMode[] = [
  "serve",
  "sessions",
  "memory",
  "packed",
  "replica-export",
  "replica-restore",
  "replica-carry",
  "vault-uses",
  "usage-counter",
  "usage-retire",
  "session-backfill",
  "session-counts",
  "session-list",
  "forward",
  "mesh",
];

test("READER_MODES metadata invariants: envKey formula and allowShadow iff read-only", () => {
  const entries = Object.entries(READER_MODES) as [ReaderMode, (typeof READER_MODES)[ReaderMode]][];
  assert.ok(entries.length >= 20, "all reader/builder modes are registered");
  assert.equal(readerModeEnvKey("footprint"), "STILLFAIL_READER_FOOTPRINT");
  assert.equal(readerModeEnvKey("replica-export"), "STILLFAIL_READER_REPLICA_EXPORT");
  assert.equal(readerModeEnvKey("live-locator"), "STILLFAIL_READER_LIVE_LOCATOR");
  for (const [mode, meta] of entries) {
    assert.equal(isReaderMode(mode), true);
    assert.match(readerModeEnvKey(mode), /^STILLFAIL_READER_[A-Z0-9_]+$/);
    assert.equal(
      meta.allowShadow,
      meta.sideEffect === "read-only",
      `allowShadow must match read-only sideEffect for ${mode}`,
    );
  }
  assert.equal(isReaderMode("unknown-mode"), false);
  assert.equal(isReaderMode("toString"), false);
});

test("defaults to mb for every mode regardless of hasPionBinary", () => {
  for (const mode of Object.keys(READER_MODES) as ReaderMode[]) {
    for (const hasPionBinary of [true, false]) {
      const sel = resolveReaderEngine(mode, { config: undefined, env: {}, hasPionBinary });
      assert.deepEqual(sel, {
        mode,
        engine: "mb",
        requested: null,
        rawRequested: null,
        source: "default",
        fallback: false,
      });
    }
  }
});

test("config.readers selects mb, pion, and shadow (for read-only modes)", () => {
  for (const mode of READ_ONLY_MODES) {
    assert.deepEqual(
      resolveReaderEngine(mode, { config: { readers: { [mode]: "mb" } }, env: {}, hasPionBinary: true }),
      { mode, engine: "mb", requested: "mb", rawRequested: "mb", source: "config", fallback: false },
    );
    assert.deepEqual(
      resolveReaderEngine(mode, { config: { readers: { [mode]: "pion" } }, env: {}, hasPionBinary: true }),
      { mode, engine: "pion", requested: "pion", rawRequested: "pion", source: "config", fallback: false },
    );
    assert.deepEqual(
      resolveReaderEngine(mode, { config: { readers: { [mode]: "shadow" } }, env: {}, hasPionBinary: true }),
      { mode, engine: "shadow", requested: "shadow", rawRequested: "shadow", source: "config", fallback: false },
    );
  }

  // Empty or null config values fall back to default cleanly.
  assert.equal(
    resolveReaderEngine("footprint", { config: { readers: { footprint: "   " } }, env: {}, hasPionBinary: true }).source,
    "default",
  );
  assert.equal(
    resolveReaderEngine("footprint", { config: { readers: { footprint: null } }, env: {}, hasPionBinary: true }).source,
    "default",
  );
});

test("environment variable STILLFAIL_READER_<UPPER_SNAKE_MODE> overrides config", () => {
  // Rollback via env when config asks for pion
  const rollback = resolveReaderEngine("footprint", {
    config: { readers: { footprint: "pion" } },
    env: { STILLFAIL_READER_FOOTPRINT: "mb" },
    hasPionBinary: true,
  });
  assert.deepEqual(rollback, {
    mode: "footprint",
    engine: "mb",
    requested: "mb",
    rawRequested: "mb",
    source: "env",
    fallback: false,
  });

  // Upgrade via env when config asks for mb (hyphenated mode -> UPPER_SNAKE)
  const upgrade = resolveReaderEngine("replica-export", {
    config: { readers: { "replica-export": "mb" } },
    env: { STILLFAIL_READER_REPLICA_EXPORT: "pion" },
    hasPionBinary: true,
  });
  assert.deepEqual(upgrade, {
    mode: "replica-export",
    engine: "pion",
    requested: "pion",
    rawRequested: "pion",
    source: "env",
    fallback: false,
  });

  // Whitespace-only env is ignored and config takes effect
  const blankEnv = resolveReaderEngine("footprint", {
    config: { readers: { footprint: "shadow" } },
    env: { STILLFAIL_READER_FOOTPRINT: "  \t  " },
    hasPionBinary: true,
  });
  assert.equal(blankEnv.engine, "shadow");
  assert.equal(blankEnv.source, "config");
});

test("case-insensitivity and whitespace trimming", () => {
  const fromEnv = resolveReaderEngine("data", {
    env: { STILLFAIL_READER_DATA: "  ShAdOw \n" },
    hasPionBinary: true,
  });
  assert.equal(fromEnv.engine, "shadow");
  assert.equal(fromEnv.requested, "shadow");
  assert.equal(fromEnv.fallback, false);

  const fromConfig = resolveReaderEngine("footprint", {
    config: { readers: { footprint: " PION " } },
    env: {},
    hasPionBinary: true,
  });
  assert.equal(fromConfig.engine, "pion");
  assert.equal(fromConfig.requested, "pion");
  assert.equal(fromConfig.fallback, false);
});

test("invalid values in config or env fall back safely to mb with structured reason", () => {
  for (const bad of ["rust", "moonbit", "dual", 42, true, { engine: "pion" }]) {
    const sel = resolveReaderEngine("footprint", {
      config: { readers: { footprint: bad } },
      env: {},
      hasPionBinary: true,
    });
    assert.equal(sel.engine, "mb");
    assert.equal(sel.requested, null);
    assert.equal(sel.source, "config");
    assert.equal(sel.fallback, true);
    assert.equal(sel.reason, "invalid-value");
    assert.ok(sel.detail && sel.detail.includes("footprint"));
  }

  // Invalid env must NOT silently fall through to config=pion; it must fail safe to mb.
  const badEnv = resolveReaderEngine("footprint", {
    config: { readers: { footprint: "pion" } },
    env: { STILLFAIL_READER_FOOTPRINT: "typo" },
    hasPionBinary: true,
  });
  assert.equal(badEnv.engine, "mb");
  assert.equal(badEnv.source, "env");
  assert.equal(badEnv.fallback, true);
  assert.equal(badEnv.reason, "invalid-value");
  assert.equal(badEnv.rawRequested, "typo");
});

test("all stateful / write modes strictly forbid shadow and fall back to mb", () => {
  for (const mode of SIDE_EFFECT_MODES) {
    assert.equal(READER_MODES[mode].allowShadow, false, `${mode} must forbid shadow`);
    for (const hasPionBinary of [true, false]) {
      const viaConfig = resolveReaderEngine(mode, {
        config: { readers: { [mode]: "shadow" } },
        env: {},
        hasPionBinary,
      });
      assert.equal(viaConfig.engine, "mb");
      assert.equal(viaConfig.requested, "shadow");
      assert.equal(viaConfig.source, "config");
      assert.equal(viaConfig.fallback, true);
      assert.equal(viaConfig.reason, "shadow-forbidden");
      assert.ok(viaConfig.detail && viaConfig.detail.includes(mode));

      const viaEnv = resolveReaderEngine(mode, {
        config: { readers: { [mode]: "pion" } },
        env: { [readerModeEnvKey(mode)]: "SHADOW" },
        hasPionBinary,
      });
      assert.equal(viaEnv.engine, "mb");
      assert.equal(viaEnv.requested, "shadow");
      assert.equal(viaEnv.source, "env");
      assert.equal(viaEnv.fallback, true);
      assert.equal(viaEnv.reason, "shadow-forbidden");
    }
  }
});

test("missing Pion binary safely falls back to mb for pion and allowed shadow requests", () => {
  const pionReq = resolveReaderEngine("footprint", {
    config: { readers: { footprint: "pion" } },
    env: {},
    hasPionBinary: false,
  });
  assert.equal(pionReq.engine, "mb");
  assert.equal(pionReq.requested, "pion");
  assert.equal(pionReq.source, "config");
  assert.equal(pionReq.fallback, true);
  assert.equal(pionReq.reason, "pion-binary-missing");
  assert.ok(pionReq.detail && pionReq.detail.includes("Pion binary is unavailable"));

  const shadowReq = resolveReaderEngine("data", {
    env: { STILLFAIL_READER_DATA: "shadow" },
    hasPionBinary: false,
  });
  assert.equal(shadowReq.engine, "mb");
  assert.equal(shadowReq.requested, "shadow");
  assert.equal(shadowReq.source, "env");
  assert.equal(shadowReq.fallback, true);
  assert.equal(shadowReq.reason, "pion-binary-missing");

  // Explicit mb request with hasPionBinary: false is not a fallback.
  const mbReq = resolveReaderEngine("footprint", {
    config: { readers: { footprint: "mb" } },
    env: {},
    hasPionBinary: false,
  });
  assert.equal(mbReq.engine, "mb");
  assert.equal(mbReq.fallback, false);
  assert.equal(mbReq.reason, undefined);
});
