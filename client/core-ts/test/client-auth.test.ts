// Tests for `ClientAuthTracker`: `{ id: 0, auth }` boundary tracking, `CallAuth` scope derivation,
// and end-to-end compatibility with `Core.connect({ authHandshake: true, requireCallAuth: true })`
// and `hosts/node.ts` `start()`.
import assert from "node:assert/strict";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { describe, it } from "node:test";
import { ClientAuthTracker } from "../src/client-auth.ts";
import { Core } from "../src/core.ts";
import { start as startNode } from "../src/hosts/node.ts";
import { FakeHost } from "../src/testing.ts";
import { account, nowS } from "./helpers.ts";

describe("ClientAuthTracker", () => {
  it("waits for full handshake snapshot, enforces monotonicity within a conn, and resets on reconnect", async () => {
    const tracker = new ClientAuthTracker();
    assert.equal(tracker.ready, false);
    assert.equal(tracker.callAuth("chat.create", { station: "ws1/st1" }), undefined);

    let readyResolved = false;
    const readyPromise = tracker.whenReady().then(() => {
      readyResolved = true;
    });

    // Incremental boundary before full snapshot must not unlock handshake.
    assert.equal(tracker.takeMessage({ id: 0, auth: { conn: 1, global: 2, workspace: "ws1", authGen: 2 } }), true);
    await Promise.resolve();
    assert.equal(tracker.ready, false);
    assert.equal(readyResolved, false);

    // Non-auth messages on id=0 (e.g. a call reply with id=0) are ignored.
    assert.equal(tracker.takeMessage({ id: 0, ok: { ok: true } }), false);
    assert.equal(tracker.ready, false);

    // Full snapshot unlocks handshake.
    assert.equal(
      tracker.takeMessage({
        id: 0,
        auth: { conn: 2, global: 1, vaultGlobal: 1, scopes: { ws1: 3 }, vaults: { "ws1/v1": 4, ws1: 4 } },
      }),
      true,
    );
    await readyPromise;
    assert.equal(readyResolved, true);
    assert.equal(tracker.conn, 2);

    // Same-conn stale snapshot must not regress generations.
    tracker.take({ conn: 2, global: 1, vaultGlobal: 1, scopes: { ws1: 1 }, vaults: { "ws1/v1": 2, ws1: 2 } });
    assert.deepEqual(tracker.callAuth("vault.putItem", { workspace: "ws1", vault: "v1" }), {
      conn: 2,
      workspace: "ws1",
      authGen: 3,
      vault: "v1",
      vaultGen: 4,
    });

    // Older conn is ignored.
    tracker.take({ conn: 1, global: 99, vaultGlobal: 99, scopes: {}, vaults: {} });
    assert.equal(tracker.conn, 2);

    // Incremental workspace, dependentVaultGens, single-vault, and vaultAll updates.
    tracker.take({ conn: 2, global: 1, workspace: "ws1", authGen: 5, dependentVaultGens: { ws2: 6 } });
    assert.deepEqual(tracker.callAuth("chat.create", { station: "ws1/st1" }), {
      conn: 2,
      workspace: "ws1",
      authGen: 5,
    });
    assert.deepEqual(tracker.callAuth("vault.open", { workspace: "ws2", item: "i1" }), {
      conn: 2,
      workspace: "ws2",
      authGen: 1,
      vaultGen: 6,
    });

    tracker.take({ conn: 2, global: 1, workspace: "ws1", vault: "v2", vaultGen: 7, dependentWorkspaces: ["ws3"] });
    assert.deepEqual(tracker.callAuth("vault.putItem", { workspace: "ws1", vault: "v2" }), {
      conn: 2,
      workspace: "ws1",
      authGen: 5,
      vault: "v2",
      vaultGen: 7,
    });
    assert.deepEqual(tracker.callAuth("vault.open", { workspace: "ws1", item: "i1" }), {
      conn: 2,
      workspace: "ws1",
      authGen: 5,
      vaultGen: 7,
    });
    assert.deepEqual(tracker.callAuth("vault.open", { workspace: "ws3", item: "i1" }), {
      conn: 2,
      workspace: "ws3",
      authGen: 1,
      vaultGen: 7,
    });
    // Unaffected vault v1 keeps its own vaultGen (4).
    assert.deepEqual(tracker.callAuth("vault.putItem", { workspace: "ws1", vault: "v1" }), {
      conn: 2,
      workspace: "ws1",
      authGen: 5,
      vault: "v1",
      vaultGen: 4,
    });

    // Explicit vault.lock (`vaultAll`) raises vaultGlobal for all vaults without raising authGen.
    tracker.take({ conn: 2, global: 1, vaultAll: true, vaultGen: 8 });
    assert.deepEqual(tracker.callAuth("vault.putItem", { workspace: "ws1", vault: "v1" }), {
      conn: 2,
      workspace: "ws1",
      authGen: 5,
      vault: "v1",
      vaultGen: 8,
    });

    // Global boundary advances globalGen across workspaces with lower scope gen.
    tracker.take({ conn: 2, global: 6 });
    assert.deepEqual(tracker.callAuth("chat.send", { station: "ws1/st1", session: "s1", text: "hi" }), {
      conn: 2,
      workspace: "ws1",
      authGen: 6,
    });

    // Higher conn resets scope/vault maps from the new connection's snapshot.
    tracker.take({ conn: 3, global: 2, vaultGlobal: 2, scopes: {}, vaults: {} });
    assert.deepEqual(tracker.callAuth("chat.create", { station: "ws1/st1" }), {
      conn: 3,
      workspace: "ws1",
      authGen: 2,
    });
  });

  it("derives CallAuth targets matching core.ts callAuthTarget across call families", () => {
    const tracker = new ClientAuthTracker();
    tracker.take({ conn: 5, global: 2, vaultGlobal: 3, scopes: { wsA: 4, wsB: 5 }, vaults: { wsA: 6, "wsA/v1": 7 } });

    // Exempt calls never require auth.
    for (const exempt of ["migrate", "client.device", "prefs.set", "changelog.read", "auth.begin", "auth.complete", "auth.password"]) {
      assert.equal(tracker.needsAuth(exempt), false, `${exempt} should be exempt`);
      assert.equal(tracker.callAuth(exempt, { workspace: "wsA" }), undefined);
    }

    // station.join prefers params.workspace over params.station's workspace.
    assert.deepEqual(tracker.callAuth("station.join", { workspace: "wsB", station: "wsA/st1" }), {
      conn: 5,
      workspace: "wsB",
      authGen: 5,
    });

    // shareIn uses params.scope.
    assert.deepEqual(tracker.callAuth("shareIn.open", { scope: "wsA" }), {
      conn: 5,
      workspace: "wsA",
      authGen: 4,
    });

    // composer.* extracts workspace from params.key (preferring key over station); non-composer calls do not misparse params.key.
    assert.deepEqual(tracker.callAuth("composer.text", { key: "new:wsA", text: "hi" }), {
      conn: 5,
      workspace: "wsA",
      authGen: 4,
    });
    assert.deepEqual(tracker.callAuth("composer.add", { key: "wsB/st1/s1", station: "wsA/st2" }), {
      conn: 5,
      workspace: "wsB",
      authGen: 5,
    });
    assert.deepEqual(tracker.callAuth("auth.signOut", { account: "sub-1", key: "ignored/key" }), {
      conn: 5,
      account: "sub-1",
      authGen: 2,
    });

    // workspace.* op carries both account and workspace.
    assert.deepEqual(tracker.callAuth("workspace.addMembers", { account: "sub-1", workspace: "wsA", emails: ["b@x.test"] }), {
      conn: 5,
      workspace: "wsA",
      account: "sub-1",
      authGen: 4,
    });

    // vault.lock / vault.state / vault.prompts omit vaultGen; vault.create / vault.putItem include it.
    assert.deepEqual(tracker.callAuth("vault.lock", { workspace: "wsA" }), {
      conn: 5,
      workspace: "wsA",
      authGen: 4,
    });
    assert.deepEqual(tracker.callAuth("vault.state", { workspace: "wsA" }), {
      conn: 5,
      workspace: "wsA",
      authGen: 4,
    });
    assert.deepEqual(tracker.callAuth("vault.create", { workspace: "wsA", station: "st-id-no-slash" }), {
      conn: 5,
      workspace: "wsA",
      authGen: 4,
      vaultGen: 6,
    });
    assert.deepEqual(tracker.callAuth("vault.putItem", { workspace: "wsA", vault: "v1" }), {
      conn: 5,
      workspace: "wsA",
      authGen: 4,
      vault: "v1",
      vaultGen: 7,
    });
  });

  it("passes Core requireCallAuth verification across account, workspace, and vault.lock boundaries", async () => {
    const host = new FakeHost();
    const core = await Core.create(host, { iroh: null });
    const tracker = new ClientAuthTracker();
    const drain = () => {
      const emitted = host.takeEmitted();
      for (const [, msg] of emitted) tracker.takeMessage(msg);
      return emitted;
    };

    const client = core.connect({ authHandshake: true, requireCallAuth: true });
    await host.time.pass(10, 1);
    drain();
    assert.equal(tracker.ready, true);

    // Without auth, protected write is rejected as auth_stale.
    core.receiveRaw(client, { id: 1, call: "draft.put", params: { station: "ws-1/st-1", chat: "new", text: "nope", quotes: [], files: [] } });
    await host.time.pass(10, 1);
    const bare = drain().find(([, m]) => (m as { id?: number }).id === 1)?.[1] as { error?: { code?: string } } | undefined;
    assert.equal(bare?.error?.code, "auth_stale");

    // With ClientAuthTracker, protected write succeeds before and after account + workspace + vault.lock bumps.
    core.receiveRaw(client, { id: 2, call: "migrate", params: { accounts: [account("alice", "alice@x.test", "Alice", "tok", "ref", nowS(host) + 3600)] } });
    await host.time.pass(10, 1);
    drain();

    const putAuth = tracker.callAuth("draft.put", { station: "ws-1/st-1", chat: "new" });
    core.receiveRaw(client, {
      id: 3,
      call: "draft.put",
      params: { station: "ws-1/st-1", chat: "new", text: "hello", quotes: [], files: [] },
      auth: putAuth,
    });
    await host.time.pass(10, 1);
    const okPut = drain().find(([, m]) => (m as { id?: number }).id === 3)?.[1] as { ok?: unknown; error?: unknown } | undefined;
    assert.equal(okPut?.error, undefined, `expected draft.put ok, got ${JSON.stringify(okPut)}`);

    // Workspace-scoped authGen bump: stale pre-bump CallAuth is rejected, updated tracker CallAuth succeeds.
    const staleAuth = tracker.callAuth("draft.put", { station: "ws-1/st-1", chat: "new" });
    core.inner.store.authGen.bumpWorkspace("ws-1");
    await host.time.pass(10, 1);
    drain();
    core.receiveRaw(client, {
      id: 31,
      call: "draft.put",
      params: { station: "ws-1/st-1", chat: "new", text: "stale", quotes: [], files: [] },
      auth: staleAuth,
    });
    core.receiveRaw(client, {
      id: 32,
      call: "draft.put",
      params: { station: "ws-1/st-1", chat: "new", text: "fresh", quotes: [], files: [] },
      auth: tracker.callAuth("draft.put", { station: "ws-1/st-1", chat: "new" }),
    });
    await host.time.pass(10, 1);
    const afterBump = drain();
    const staleRes = afterBump.find(([, m]) => (m as { id?: number }).id === 31)?.[1] as { error?: { code?: string } } | undefined;
    const freshRes = afterBump.find(([, m]) => (m as { id?: number }).id === 32)?.[1] as { error?: unknown } | undefined;
    assert.equal(staleRes?.error?.code, "auth_stale", "pre-bump CallAuth must be rejected");
    assert.equal(freshRes?.error, undefined, `post-bump CallAuth must succeed, got ${JSON.stringify(freshRes)}`);

    core.receiveRaw(client, {
      id: 4,
      call: "vault.lock",
      params: { workspace: "ws-1" },
      auth: tracker.callAuth("vault.lock", { workspace: "ws-1" }),
    });
    await host.time.pass(10, 1);
    const okLock = drain().find(([, m]) => (m as { id?: number }).id === 4)?.[1] as { ok?: unknown; error?: unknown } | undefined;
    assert.equal(okLock?.error, undefined, `expected vault.lock ok, got ${JSON.stringify(okLock)}`);

    // Follow-up vault write uses bumped vaultGen from the vault.lock boundary (not auth_stale).
    core.receiveRaw(client, {
      id: 5,
      call: "vault.open",
      params: { workspace: "ws-1", item: "missing" },
      auth: tracker.callAuth("vault.open", { workspace: "ws-1", item: "missing" }),
    });
    await host.time.pass(10, 1);
    const openAns = drain().find(([, m]) => (m as { id?: number }).id === 5)?.[1] as { error?: { code?: string } } | undefined;
    assert.notEqual(openAns?.error?.code, "auth_stale", "vault.open after vault.lock must carry updated vaultGen");

    await core.close();
  });

  it("works end-to-end with hosts/node.ts start() where requireCallAuth is enabled by default", async () => {
    const dir = mkdtempSync(join(tmpdir(), "core-node-auth-"));
    const tracker = new ClientAuthTracker();
    const pending = new Map<number, (m: Record<string, unknown>) => void>();
    const core = startNode(
      dir,
      "http://127.0.0.1:1",
      (_client, json) => {
        const m = JSON.parse(json) as Record<string, unknown>;
        if (tracker.takeMessage(m)) return;
        const id = m.id as number;
        const resolve = pending.get(id);
        if (resolve) {
          pending.delete(id);
          resolve(m);
        }
      },
      undefined,
      { hostWire: true },
    );
    try {
      const client = core.connect();
      await tracker.whenReady();
      assert.ok(tracker.conn > 0);

      const ask = (id: number, call: string, params: Record<string, unknown>, attachAuth: boolean) =>
        new Promise<Record<string, unknown>>((resolve) => {
          pending.set(id, resolve);
          const msg: Record<string, unknown> = { id, call, params };
          if (attachAuth) msg.auth = tracker.callAuth(call, params);
          core.receive(client, JSON.stringify(msg));
        });

      const unauth = await ask(1, "draft.put", { station: "ws-node/st-1", chat: "new", text: "no-auth", quotes: [], files: [] }, false);
      assert.equal((unauth.error as { code?: string } | undefined)?.code, "auth_stale");

      const authed = await ask(2, "draft.put", { station: "ws-node/st-1", chat: "new", text: "with-auth", quotes: [], files: [] }, true);
      assert.equal(authed.error, undefined, `expected authenticated draft.put ok, got ${JSON.stringify(authed)}`);
    } finally {
      await core.close();
      rmSync(dir, { recursive: true, force: true });
    }
  });
});
