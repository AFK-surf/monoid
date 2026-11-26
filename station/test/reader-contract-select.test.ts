import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { test } from "node:test";
import { fileURLToPath } from "node:url";
import {
  type DefaultPolicyTable,
  PION_DEFAULT_TARGETS_BY_CHANNEL,
  isReaderMode,
  READER_MODES,
  type ReaderMode,
  defaultEngineFor,
  readerModeEnvKey,
  resolveReaderEngine,
} from "../src/read/reader-select.ts";

const MAIN_MBT_PATH = fileURLToPath(new URL("../mb/src/reader/main.mbt", import.meta.url));
const FRONT_RS_PATH = fileURLToPath(new URL("../native/launcher/src/front.rs", import.meta.url));

/** Extract every `--builder <name>` plus top-level `--data`/`--serve`/`--sessions` mode from `main.mbt`. */
function modesInMainMbt(): string[] {
  const src = readFileSync(MAIN_MBT_PATH, "utf8");
  const mainStart = src.indexOf("\nfn main {");
  assert.ok(mainStart >= 0, "fn main { found in station/mb/src/reader/main.mbt");
  const mainBody = src.slice(mainStart);
  const modes = new Set<string>(["data", "serve", "sessions"]);
  for (const match of mainBody.matchAll(/\(\s*Some\("([a-z0-9-]+)"\)\s*,/g)) {
    modes.add(match[1]!);
  }
  return [...modes].sort();
}

test("READER_MODES strictly matches all modes in station/mb/src/reader/main.mbt and allows shadow ONLY for footprint", () => {
  const registered = Object.keys(READER_MODES).sort();
  const fromMainMbt = modesInMainMbt();
  assert.deepEqual(
    registered,
    fromMainMbt,
    "READER_MODES must match every --builder and top-level mode in station/mb/src/reader/main.mbt",
  );

  const shadowAllowed = (Object.entries(READER_MODES) as [ReaderMode, (typeof READER_MODES)[ReaderMode]][])
    .filter(([, meta]) => meta.allowShadow)
    .map(([mode]) => mode)
    .sort();
  assert.deepEqual(
    shadowAllowed,
    ["footprint"],
    "only footprint is currently certified pure read-only and permitted to run in shadow mode",
  );

  const pionImplemented = (Object.entries(READER_MODES) as [ReaderMode, (typeof READER_MODES)[ReaderMode]][])
    .filter(([, meta]) => meta.pionImplemented)
    .map(([mode]) => mode)
    .sort();
  assert.deepEqual(
    pionImplemented,
    [
      "archive-last",
      "archive-marks",
      "card-posts",
      "cc-index",
      "closed-cards",
      "data",
      "footprint",
      "legacy-edits",
      "legacy-said",
      "live-locator",
      "memory",
      "mesh",
      "outflow-chats",
      "packed",
      "page-letters",
      "people-since",
      "post-blocks",
      "recent-chat",
      "replica-carry",
      "replica-chat",
      "replica-export",
      "replica-restore",
      "said",
      "search",
      "search-scope",
      "serve",
      "session-backfill",
      "session-bindings",
      "session-counts",
      "session-list",
      "session-up-jobs",
      "sessions",
      "signin-save",
      "turn-counts",
      "usage-check",
      "usage-counter",
      "usage-retire",
      "vault-uses",
      "widget-sources",
      "workspace-up-jobs",
    ],
    "only the implemented baseline + builders_core + builders_index + builders_stateful + builders_legacy + builders_recent + builders_vault + builders_requested + locate modes are currently enabled in Pion",
  );

  assert.equal(readerModeEnvKey("footprint"), "STILLFAIL_READER_FOOTPRINT");
  assert.equal(readerModeEnvKey("replica-export"), "STILLFAIL_READER_REPLICA_EXPORT");
  assert.equal(readerModeEnvKey("live-locator"), "STILLFAIL_READER_LIVE_LOCATOR");
  for (const [mode, meta] of Object.entries(READER_MODES) as [ReaderMode, (typeof READER_MODES)[ReaderMode]][]) {
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

test("config.readers selects mb, pion, and shadow (for footprint)", () => {
  assert.deepEqual(
    resolveReaderEngine("footprint", { config: { readers: { footprint: "mb" } }, env: {}, hasPionBinary: true }),
    { mode: "footprint", engine: "mb", requested: "mb", rawRequested: "mb", source: "config", fallback: false },
  );
  assert.deepEqual(
    resolveReaderEngine("footprint", { config: { readers: { footprint: "pion" } }, env: {}, hasPionBinary: true }),
    { mode: "footprint", engine: "pion", requested: "pion", rawRequested: "pion", source: "config", fallback: false },
  );
  assert.deepEqual(
    resolveReaderEngine("footprint", { config: { readers: { footprint: "shadow" } }, env: {}, hasPionBinary: true }),
    { mode: "footprint", engine: "shadow", requested: "shadow", rawRequested: "shadow", source: "config", fallback: false },
  );

  // Implemented non-footprint modes can select pion directly when binary is available.
  assert.deepEqual(
    resolveReaderEngine("packed", { config: { readers: { packed: "pion" } }, env: {}, hasPionBinary: true }),
    { mode: "packed", engine: "pion", requested: "pion", rawRequested: "pion", source: "config", fallback: false },
  );
  assert.deepEqual(
    resolveReaderEngine("memory", { config: { readers: { memory: "pion" } }, env: {}, hasPionBinary: true }),
    { mode: "memory", engine: "pion", requested: "pion", rawRequested: "pion", source: "config", fallback: false },
  );

  // Unimplemented modes safely fall back to mb with reason "pion-mode-unimplemented".
  const unimpl = resolveReaderEngine("forward", { config: { readers: { forward: "pion" } }, env: {}, hasPionBinary: true });
  assert.equal(unimpl.engine, "mb");
  assert.equal(unimpl.requested, "pion");
  assert.equal(unimpl.source, "config");
  assert.equal(unimpl.fallback, true);
  assert.equal(unimpl.reason, "pion-mode-unimplemented");

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

  const upgrade = resolveReaderEngine("packed", {
    config: { readers: { packed: "mb" } },
    env: { STILLFAIL_READER_PACKED: "pion" },
    hasPionBinary: true,
  });
  assert.deepEqual(upgrade, {
    mode: "packed",
    engine: "pion",
    requested: "pion",
    rawRequested: "pion",
    source: "env",
    fallback: false,
  });

  const unimplEnv = resolveReaderEngine("forward", {
    config: { readers: { forward: "mb" } },
    env: { STILLFAIL_READER_FORWARD: "pion" },
    hasPionBinary: true,
  });
  assert.equal(unimplEnv.engine, "mb");
  assert.equal(unimplEnv.requested, "pion");
  assert.equal(unimplEnv.source, "env");
  assert.equal(unimplEnv.fallback, true);
  assert.equal(unimplEnv.reason, "pion-mode-unimplemented");

  const blankEnv = resolveReaderEngine("footprint", {
    config: { readers: { footprint: "shadow" } },
    env: { STILLFAIL_READER_FOOTPRINT: "  \t  " },
    hasPionBinary: true,
  });
  assert.equal(blankEnv.engine, "shadow");
  assert.equal(blankEnv.source, "config");
});

test("case-insensitivity and whitespace trimming", () => {
  const fromEnv = resolveReaderEngine("footprint", {
    env: { STILLFAIL_READER_FOOTPRINT: "  ShAdOw \n" },
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

test("invalid values (including untrusted objects with null toString or circular refs) fall back safely without throwing", () => {
  const circular: Record<string, unknown> = {};
  circular.self = circular;
  const nullProto = Object.create(null) as Record<string, unknown>;
  nullProto.engine = "pion";

  for (const bad of [
    "rust",
    "moonbit",
    "dual",
    42,
    true,
    { engine: "pion" },
    { toString: null },
    nullProto,
    circular,
  ]) {
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
    assert.equal(typeof sel.rawRequested, "string");
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

test("every non-footprint mode strictly forbids shadow and falls back to mb", () => {
  const nonFootprint = (Object.keys(READER_MODES) as ReaderMode[]).filter((m) => m !== "footprint");
  assert.ok(nonFootprint.length >= 30);

  for (const mode of nonFootprint) {
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

  const shadowReq = resolveReaderEngine("footprint", {
    env: { STILLFAIL_READER_FOOTPRINT: "shadow" },
    hasPionBinary: false,
  });
  assert.equal(shadowReq.engine, "mb");
  assert.equal(shadowReq.requested, "shadow");
  assert.equal(shadowReq.source, "env");
  assert.equal(shadowReq.fallback, true);
  assert.equal(shadowReq.reason, "pion-binary-missing");

  const mbReq = resolveReaderEngine("footprint", {
    config: { readers: { footprint: "mb" } },
    env: {},
    hasPionBinary: false,
  });
  assert.equal(mbReq.engine, "mb");
  assert.equal(mbReq.fallback, false);
  assert.equal(mbReq.reason, undefined);
});

test("STILLFAIL_READER_ENGINE acts as global env fallback below config.readers and above default mb", () => {
  const globalPion = resolveReaderEngine("footprint", {
    config: undefined,
    env: { STILLFAIL_READER_ENGINE: "pion" },
    hasPionBinary: true,
  });
  assert.equal(globalPion.engine, "pion");
  assert.equal(globalPion.source, "env");
  assert.equal(globalPion.fallback, false);

  // Per-mode config pins override global STILLFAIL_READER_ENGINE.
  const configWinsOverGlobal = resolveReaderEngine("footprint", {
    config: { readers: { footprint: "mb" } },
    env: { STILLFAIL_READER_ENGINE: "pion" },
    hasPionBinary: true,
  });
  assert.equal(configWinsOverGlobal.engine, "mb");
  assert.equal(configWinsOverGlobal.source, "config");
  assert.equal(configWinsOverGlobal.fallback, false);

  // Per-mode env STILLFAIL_READER_<MODE> still overrides both config and global env.
  const perModeWins = resolveReaderEngine("footprint", {
    config: { readers: { footprint: "pion" } },
    env: { STILLFAIL_READER_ENGINE: "pion", STILLFAIL_READER_FOOTPRINT: "mb" },
    hasPionBinary: true,
  });
  assert.equal(perModeWins.engine, "mb");
  assert.equal(perModeWins.source, "env");
  assert.equal(perModeWins.fallback, false);

  // Global shadow is still blocked on non-footprint modes.
  const blockedShadow = resolveReaderEngine("data", {
    env: { STILLFAIL_READER_ENGINE: "shadow" },
    hasPionBinary: true,
  });
  assert.equal(blockedShadow.engine, "mb");
  assert.equal(blockedShadow.fallback, true);
  assert.equal(blockedShadow.reason, "shadow-forbidden");
});

test("every mode with pionImplemented: true is explicitly wired to resolveReaderSelection (exact allowlist guard)", () => {
  // Modes whose spawn sites are wired through resolveReaderSelection AND backed by Pion implementations.
  // Adding a mode here requires wiring its actual spawn site and updating the capability gate.
  const WIRED_PION_MODES = new Set<ReaderMode>([
    "archive-last",
    "archive-marks",
    "card-posts",
    "cc-index",
    "closed-cards",
    "data",
    "footprint",
    "legacy-edits",
    "legacy-said",
    "live-locator",
    "memory",
    "mesh",
    "outflow-chats",
    "packed",
    "page-letters",
    "people-since",
    "post-blocks",
    "recent-chat",
    "replica-carry",
    "replica-chat",
    "replica-export",
    "replica-restore",
    "said",
    "search",
    "search-scope",
    "serve",
    "session-backfill",
    "session-bindings",
    "session-counts",
    "session-list",
    "session-up-jobs",
    "sessions",
    "signin-save",
    "turn-counts",
    "usage-check",
    "usage-counter",
    "usage-retire",
    "vault-uses",
    "widget-sources",
    "workspace-up-jobs",
  ]);
  const enabled = (Object.entries(READER_MODES) as [ReaderMode, (typeof READER_MODES)[ReaderMode]][])
    .filter(([, meta]) => meta.pionImplemented)
    .map(([mode]) => mode)
    .sort();
  for (const mode of enabled) {
    assert.ok(
      WIRED_PION_MODES.has(mode),
      `mode "${mode}" has pionImplemented: true in READER_MODES but is not in WIRED_PION_MODES`,
    );
  }
  assert.deepEqual(enabled, [...WIRED_PION_MODES].sort());
});

/** Parse `PION_DEFAULT_TARGETS_BY_CHANNEL` directly from `station/native/launcher/src/front.rs`. */
function parseRustDefaultPolicyTable(): Record<string, string[]> {
  const src = readFileSync(FRONT_RS_PATH, "utf8");
  const match = /const PION_DEFAULT_TARGETS_BY_CHANNEL:\s*&\[\(&str,\s*&\[&str\]\)\]\s*=\s*&\[([\s\S]*?)\];/.exec(src);
  assert.ok(match, "PION_DEFAULT_TARGETS_BY_CHANNEL must exist in station/native/launcher/src/front.rs");
  const body = match[1]!;
  const result: Record<string, string[]> = {};
  for (const entry of body.matchAll(/\(\s*"([a-z]+)"\s*,\s*&\[([^\]]*)\]\s*\)/g)) {
    const ch = entry[1]!;
    const rawTargets = entry[2]!.trim();
    const targets = rawTargets === ""
      ? []
      : [...rawTargets.matchAll(/"([^"]+)"/g)].map((m) => m[1]!);
    result[ch] = targets;
  }
  return result;
}

test("cross-language contract: TS and Rust front.rs PION_DEFAULT_TARGETS_BY_CHANNEL match 1:1 and Stage 9A keeps Zero Default Flip", () => {
  const rustTable = parseRustDefaultPolicyTable();
  assert.deepEqual(
    rustTable,
    {
      beta: [...PION_DEFAULT_TARGETS_BY_CHANNEL.beta],
      stable: [...PION_DEFAULT_TARGETS_BY_CHANNEL.stable],
    },
    "TS and Rust front.rs PION_DEFAULT_TARGETS_BY_CHANNEL must stay identical",
  );
  // Stage 9A Zero Default Flip invariant: both channels remain empty.
  assert.deepEqual(PION_DEFAULT_TARGETS_BY_CHANNEL, { beta: [], stable: [] });
});

test("default policy matrix across all 4 targets x (stable, beta, missing, unknown CHANNEL) with injected 9B table", () => {
  const targets = ["darwin-arm64", "linux-x64", "linux-arm64", "win32-x64"] as const;
  const stage9bTable: DefaultPolicyTable = {
    beta: ["darwin-arm64", "linux-x64", "linux-arm64", "win32-x64"],
    stable: ["linux-x64", "darwin-arm64"],
  };

  for (const target of targets) {
    // Production Stage 9A table always resolves to mb.
    for (const ch of ["beta", "stable", "nightly", null, undefined] as const) {
      assert.equal(defaultEngineFor(ch, target), "mb");
    }

    // Injected 9B table: beta enables all 4 targets; missing/unknown channel stays mb.
    assert.equal(defaultEngineFor("beta", target, stage9bTable), "pion");
    assert.equal(defaultEngineFor(null, target, stage9bTable), "mb");
    assert.equal(defaultEngineFor(undefined, target, stage9bTable), "mb");
    assert.equal(defaultEngineFor("dev", target, stage9bTable), "mb");

    const betaSel = resolveReaderEngine("data", {
      config: { channel: "beta" },
      env: {},
      hasPionBinary: true,
      target,
      defaultTargetsByChannel: stage9bTable,
    });
    assert.deepEqual(betaSel, {
      mode: "data",
      engine: "pion",
      requested: "pion",
      rawRequested: null,
      source: "default",
      fallback: false,
    });

    // Unimplemented mode (`forward`) under default=pion stays silent (`fallback: false`).
    const forwardSel = resolveReaderEngine("forward", {
      config: { channel: "beta" },
      env: {},
      hasPionBinary: true,
      target,
      defaultTargetsByChannel: stage9bTable,
    });
    assert.deepEqual(forwardSel, {
      mode: "forward",
      engine: "mb",
      requested: null,
      rawRequested: null,
      source: "default",
      fallback: false,
    });

    // Missing Pion binary under default=pion records requested="pion" and fallback=true.
    const missingSel = resolveReaderEngine("data", {
      config: { channel: "beta" },
      env: {},
      hasPionBinary: false,
      target,
      defaultTargetsByChannel: stage9bTable,
    });
    assert.equal(missingSel.engine, "mb");
    assert.equal(missingSel.requested, "pion");
    assert.equal(missingSel.source, "default");
    assert.equal(missingSel.fallback, true);
    assert.equal(missingSel.reason, "pion-binary-missing");
  }

  // Stable channel only enables listed targets.
  assert.equal(defaultEngineFor("stable", "linux-x64", stage9bTable), "pion");
  assert.equal(defaultEngineFor("stable", "darwin-arm64", stage9bTable), "pion");
  assert.equal(defaultEngineFor("stable", "linux-arm64", stage9bTable), "mb");
  assert.equal(defaultEngineFor("stable", "win32-x64", stage9bTable), "mb");
});

test("config.readers['*'] wildcard sits below config.readers[mode] and above STILLFAIL_READER_ENGINE and default", () => {
  const stage9bTable: DefaultPolicyTable = { beta: ["linux-x64"], stable: [] };

  // Emergency rollback config.readers["*"] = "mb" overrides STILLFAIL_READER_ENGINE=pion and default=pion.
  const rollback = resolveReaderEngine("data", {
    config: { readers: { "*": "mb" }, channel: "beta" },
    env: { STILLFAIL_READER_ENGINE: "pion" },
    hasPionBinary: true,
    target: "linux-x64",
    defaultTargetsByChannel: stage9bTable,
  });
  assert.equal(rollback.engine, "mb");
  assert.equal(rollback.source, "config");
  assert.equal(rollback.fallback, false);

  // Per-mode config overrides wildcard.
  const perModeWins = resolveReaderEngine("data", {
    config: { readers: { "*": "mb", data: "pion" } },
    env: {},
    hasPionBinary: true,
  });
  assert.equal(perModeWins.engine, "pion");
  assert.equal(perModeWins.source, "config");

  // Blank per-mode config falls through to wildcard.
  const blankFallsToWildcard = resolveReaderEngine("data", {
    config: { readers: { "*": "pion", data: "   " } },
    env: { STILLFAIL_READER_ENGINE: "mb" },
    hasPionBinary: true,
  });
  assert.equal(blankFallsToWildcard.engine, "pion");
  assert.equal(blankFallsToWildcard.source, "config");

  // Per-mode env STILLFAIL_READER_<MODE> overrides wildcard.
  const envWins = resolveReaderEngine("data", {
    config: { readers: { "*": "mb" } },
    env: { STILLFAIL_READER_DATA: "pion" },
    hasPionBinary: true,
  });
  assert.equal(envWins.engine, "pion");
  assert.equal(envWins.source, "env");

  // Invalid / forbidden shadow wildcard fails closed to mb as invalid-value without falling through to global env.
  const badWildcard = resolveReaderEngine("data", {
    config: { readers: { "*": "shadow" }, channel: "beta" },
    env: { STILLFAIL_READER_ENGINE: "pion" },
    hasPionBinary: true,
    target: "linux-x64",
    defaultTargetsByChannel: stage9bTable,
  });
  assert.equal(badWildcard.engine, "mb");
  assert.equal(badWildcard.source, "config");
  assert.equal(badWildcard.fallback, true);
  assert.equal(badWildcard.reason, "invalid-value");
});
