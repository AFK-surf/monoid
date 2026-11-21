import assert from "node:assert/strict";
import { describe, test } from "node:test";
import { checkConfig } from "../src/accounts/check.ts";
import { checkProfile } from "../src/accounts/profiles.ts";
import { checkQuota } from "../src/accounts/quota.ts";
import { defaultServiceShareRefusal, type ServiceProfileAdapter, type ServiceRegistry } from "../src/accounts/services.ts";
import { hubConfig } from "../src/sessions/config.ts";
import { shareRefusal, signInFiles } from "../src/share/index.ts";
import { RUNTIME_KINDS } from "../src/agents/runtime.ts";
import { PROFILE_SERVICES_HEADER, RUNTIMES_HEADER, runtimeCompatible } from "../src/api/runtime-compat.ts";
import { json, type Request } from "../src/api/request.ts";

function fakeServices(overrides: Partial<ServiceProfileAdapter> = {}): ServiceRegistry {
  const adapter: ServiceProfileAdapter = {
    id: "fake-gpu",
    name: "Fake GPU",
    capabilities: () => ["gpu-lease"],
    signInFiles: () => ["service-token.json"],
    shareRefusal: () => defaultServiceShareRefusal("fake-gpu"),
    identity: async () => "gpu-user@example.com",
    check: async ({ home }) => ({ state: "ok", detail: `checked ${home}`, models: null, checkedAt: 0 }),
    quota: async () => ({ state: "ok", windows: [{ label: "GPU", usedPercent: 25, resetsAt: null, minutes: null }], detail: null, checkedAt: 0 }),
    ...overrides,
  };
  return new Map([[adapter.id, adapter]]);
}

describe("service profile decoupling", () => {
  test("checkConfig validates service profiles against registry and forbids runtime", () => {
    const services = fakeServices();
    const base = {
      profiles: [{ id: "gpu-1", home: "homes/gpu-1", access: { kind: "service", service: "fake-gpu" } }],
    };
    assert.doesNotThrow(() => checkConfig(base, "/data", services));
    // Unregistered service is rejected.
    assert.throws(() => checkConfig(base, "/data", new Map()), /unknown service fake-gpu/);
    // Invalid service id is rejected.
    assert.throws(
      () => checkConfig({ profiles: [{ id: "gpu-1", home: "homes/gpu-1", access: { kind: "service", service: "BAD_ID" } }] }, "/data", services),
      /valid service id/,
    );
    // Setting runtime on a service profile is rejected.
    assert.throws(
      () => checkConfig({ profiles: [{ id: "gpu-1", home: "homes/gpu-1", runtime: "claude", access: { kind: "service", service: "fake-gpu" } }] }, "/data", services),
      /cannot specify a runtime/,
    );
  });

  test("hubConfig preserves runtime: undefined for service and non-runtime (Jev) profiles without fabricating claude", () => {
    const cfg = hubConfig(
      {
        profiles: [
          { id: "gpu-1", home: "homes/gpu-1", access: { kind: "service", service: "fake-gpu" } },
          { id: "jev-1", home: "homes/jev-1", access: { kind: "api-provider", provider: "jev", key: "k" } },
        ],
      },
      "/data",
    );
    const gpu = cfg.profiles.find((p) => p.id === "gpu-1")!;
    assert.equal(gpu.runtime, undefined);
    assert.deepEqual(gpu.runtimes, []);
    assert.equal(gpu.service, "fake-gpu");
    assert.deepEqual(gpu.models, []);

    const jev = cfg.profiles.find((p) => p.id === "jev-1")!;
    assert.equal(jev.runtime, undefined);
    assert.deepEqual(jev.runtimes, []);
    assert.equal(jev.service, undefined);
  });

  test("checkProfile and checkQuota dispatch service profiles to adapter and never fall through to codex", async () => {
    const services = fakeServices();
    const cfg = hubConfig(
      {
        profiles: [
          { id: "gpu-1", home: "homes/gpu-1", access: { kind: "service", service: "fake-gpu" } },
        ],
      },
      "/data",
    );
    const gpu = cfg.profiles[0]!;
    const checked = await checkProfile({
      runtime: undefined,
      kind: "service",
      service: "fake-gpu",
      services,
      profile: gpu,
      home: gpu.home,
      key: "",
      via: {},
      machine: false,
      env: {},
    });
    assert.equal(checked.state, "ok");
    assert.equal(checked.detail, "checked /data/homes/gpu-1");

    let codexCalled = false;
    const codex = {
      rateLimits: async () => {
        codexCalled = true;
        throw new Error("should not be called");
      },
    } as never;
    const q = await checkQuota(gpu, {}, codex, undefined, "zh", undefined, services);
    assert.equal(q.state, "ok");
    assert.equal(q.windows.length, 1);
    assert.equal(codexCalled, false);

    // Unmatched subscription with runtime: undefined must return unsupported without calling codex.
    const orphan = { ...gpu, access: { kind: "subscription" as const }, service: undefined };
    const orphanQ = await checkQuota(orphan, {}, codex, undefined, "zh", undefined, services);
    assert.equal(orphanQ.state, "unsupported");
    assert.equal(codexCalled, false);
  });

  test("shareRefusal and signInFiles dispatch to service adapter without claude fallback", () => {
    const services = fakeServices();
    const gpu = hubConfig(
      { profiles: [{ id: "gpu-1", home: "homes/gpu-1", access: { kind: "service", service: "fake-gpu" } }] },
      "/data",
    ).profiles[0]!;
    assert.deepEqual(signInFiles(gpu, services), ["service-token.json"]);
    assert.deepEqual(signInFiles(gpu, new Map()), []);
    assert.equal(shareRefusal(gpu, services), defaultServiceShareRefusal("fake-gpu"));
    const custom = fakeServices({ shareRefusal: () => "custom refusal" });
    assert.equal(shareRefusal(gpu, custom), "custom refusal");
  });

  test("runtimeCompatible filters service profiles and backfills runtime for legacy clients without profile-services header", () => {
    const overview = {
      profiles: [
        { id: "cc", name: "Claude", runtime: "claude", runtimes: ["claude"], access: { kind: "subscription", key: "" } },
        { id: "jev", name: "Jev", runtime: null, runtimes: [], access: { kind: "env", key: "k", provider: "jev" } },
        {
          id: "og",
          name: "OpenCode Go",
          runtime: "claude",
          runtimes: ["claude", "codex"],
          access: { kind: "opencode-go", key: "k", login: true },
          login: { profile: "og", runtime: null, provider: "opencode", state: "needs_approval", startedAt: 1, expiresAt: 2 },
        },
        { id: "gpu-1", name: "GPU", runtime: null, service: "fake-gpu", runtimes: [], access: { kind: "service", key: "", service: "fake-gpu" } },
      ],
      logins: [
        { id: "l1", runtime: "claude", job: null, created: null, error: null },
        {
          id: "l-og",
          runtime: null,
          job: { profile: "l-og", runtime: null, provider: "opencode", state: "needs_approval", startedAt: 1, expiresAt: 2 },
          created: null,
          error: null,
        },
        {
          id: "l-svc",
          runtime: null,
          service: "fake-gpu",
          job: { profile: "l-svc", runtime: null, service: "fake-gpu", state: "needs_code", startedAt: 1, expiresAt: 2 },
          created: null,
          error: null,
        },
      ],
    };
    const viewer = { sub: "u", email: "u@x", name: "", role: "owner", workspace: "w", device: "d" };
    const req = (headers: Record<string, string>): Request => ({ path: "/overview", headers, method: "GET", query: [], body: Buffer.alloc(0), viewer, lang: "en" });
    const ans = () => json(200, JSON.stringify(overview));

    // Legacy client: knows all 9 runtimes, but no stillfail-profile-services header.
    const oldOut = JSON.parse(String(runtimeCompatible(req({ [RUNTIMES_HEADER]: RUNTIME_KINDS.join(",") }), ans()).body));
    assert.deepEqual(oldOut.profiles.map((p: { id: string }) => p.id), ["cc", "jev", "og"]);
    assert.equal(oldOut.profiles.find((p: { id: string }) => p.id === "jev").runtime, "claude");
    assert.equal(oldOut.profiles.find((p: { id: string }) => p.id === "og").login.runtime, "claude");
    assert.deepEqual(oldOut.logins.map((l: { id: string }) => l.id), ["l1", "l-og"]);
    const oldOgLogin = oldOut.logins.find((l: { id: string }) => l.id === "l-og");
    assert.equal(oldOgLogin.runtime, "claude");
    assert.equal(oldOgLogin.job.runtime, "claude");

    // New client: sends stillfail-profile-services: 1.
    const newOut = JSON.parse(
      String(runtimeCompatible(req({ [RUNTIMES_HEADER]: RUNTIME_KINDS.join(","), [PROFILE_SERVICES_HEADER]: "1" }), ans()).body),
    );
    assert.deepEqual(newOut.profiles.map((p: { id: string }) => p.id), ["cc", "jev", "og", "gpu-1"]);
    assert.equal(newOut.profiles.find((p: { id: string }) => p.id === "jev").runtime, null);
    assert.equal(newOut.profiles.find((p: { id: string }) => p.id === "og").login.runtime, null);
    assert.equal(newOut.profiles.find((p: { id: string }) => p.id === "gpu-1").runtime, null);
    assert.deepEqual(newOut.logins.map((l: { id: string }) => l.id), ["l1", "l-og", "l-svc"]);
    assert.equal(newOut.logins.find((l: { id: string }) => l.id === "l-og").runtime, null);
    assert.equal(newOut.logins.find((l: { id: string }) => l.id === "l-og").job.runtime, null);
  });
});
