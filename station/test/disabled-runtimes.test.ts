import assert from "node:assert/strict";
import { describe, test } from "node:test";
import { Clock, Effect } from "effect";
import { hubConfig } from "../src/sessions/config.ts";
import { Accounts } from "../src/sessions/accounts.ts";
import { Store } from "../src/store/store.ts";
import { overview } from "../src/api/overview.ts";

const owner = { sub: "u1", email: "owner@example.com", name: "Owner", role: "owner" as const, workspace: "W1", device: "d1", home: true };

describe("disabledRuntimes", () => {
  test("hubConfig filters disabled runtimes from profile.runtimes while keeping profile.runtime", () => {
    const cfg = hubConfig(
      {
        disabledRuntimes: ["dsh", "codex", "unknown", "dsh"],
        profiles: [
          { id: "cx", name: "Codex", runtime: "codex", access: { kind: "subscription" }, home: "homes/cx", models: ["gpt-6-sol"] },
          { id: "groq", name: "Groq", access: { kind: "api-provider", provider: "groq", key: "gsk-1" }, home: "homes/groq", models: ["deepseek-v4-pro"] },
          { id: "cc", name: "Claude", runtime: "claude", access: { kind: "subscription" }, home: "homes/cc", models: ["claude-sonnet-5.5"] },
        ],
      },
      "/tmp/data",
    );
    assert.deepEqual(cfg.disabledRuntimes, ["dsh", "codex"]);
    const cx = cfg.profiles.find((p) => p.id === "cx")!;
    assert.deepEqual(cx.runtimes, []);
    assert.equal(cx.runtime, "codex");
    const groq = cfg.profiles.find((p) => p.id === "groq")!;
    assert.deepEqual(groq.runtimes, ["pi"]);
    const cc = cfg.profiles.find((p) => p.id === "cc")!;
    assert.deepEqual(cc.runtimes, ["claude"]);
  });

  test("AccountPool runOn, repick, and change reject disabled runtimes with clear guidance", () => {
    const store = Store.open(":memory:", null);
    store.insertSession({ key: "s-codex", connect: "internal", runtime: "codex", profile: "cx", workspace: "/tmp/w1", token: "t1", createdAt: 1, lastActiveAt: 1 });
    store.insertSession({ key: "s-claude", connect: "internal", runtime: "claude", profile: "cc", workspace: "/tmp/w2", token: "t2", createdAt: 1, lastActiveAt: 1 });
    const raw = {
      disabledRuntimes: ["codex"],
      profiles: [
        { id: "cx", name: "Codex", runtime: "codex", access: { kind: "subscription" }, home: "homes/cx", models: ["gpt-6-sol"] },
        { id: "cc", name: "Claude", runtime: "claude", access: { kind: "subscription" }, home: "homes/cc", models: ["claude-sonnet-5.5"] },
      ],
    };
    const pool = new Accounts({
      store,
      config: () => hubConfig(raw, "/tmp/data"),
      clock: Effect.runSync(Clock.clockWith(Effect.succeed)),
      running: () => [],
    });
    assert.throws(() => pool.runOn("s-codex"), /Codex/);
    assert.throws(() => pool.repick("s-codex"), /Codex/);
    assert.throws(() => pool.change("s-claude", { runtime: "codex" }, "en"), /Codex is turned off on this station/);
    assert.throws(() => pool.change("s-claude", { runtime: "codex" }, "zh"), /这台 Station 已停用 Codex/);
    // Re-enabling codex allows switching and running again
    raw.disabledRuntimes = [];
    const changed = pool.change("s-claude", { runtime: "codex" }, "en");
    assert.equal(changed.runtime, "codex");
    assert.equal(changed.profile, "cx");
    store.close();
  });

  test("overview exposes disabledRuntimes in canonical RUNTIME_KINDS order", async () => {
    const store = Store.open(":memory:", null);
    const raw: any = { profiles: [], connects: [], disabledRuntimes: ["pi", "dsh", "invalid", "pi"] };
    const ov: any = await overview(
      {
        store,
        hub: {
          config: () => hubConfig(raw, "/tmp/data"),
          processes: () => new Map(),
          waitForSessionCounts: async () => true,
        } as any,
        cloud: { state: null, reached: false, membership: () => null } as any,
        config: () => raw,
      },
      owner,
      "en",
    );
    assert.deepEqual(ov.disabledRuntimes, ["dsh", "pi"]);
    delete raw.disabledRuntimes;
    const ov2: any = await overview(
      {
        store,
        hub: {
          config: () => hubConfig(raw, "/tmp/data"),
          processes: () => new Map(),
          waitForSessionCounts: async () => true,
        } as any,
        cloud: { state: null, reached: false, membership: () => null } as any,
        config: () => raw,
      },
      owner,
      "en",
    );
    assert.deepEqual(ov2.disabledRuntimes, []);
    store.close();
  });
});
