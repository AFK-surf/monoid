import assert from "node:assert/strict";
import test from "node:test";
import { harness } from "./harness.ts";

test("console creates, lists, and revokes admin API keys; plaintext is returned once and never listed", async () => {
  const h = await harness();
  try {
    const aliceTokens = await h.login("alice");
    const aliceAdmin = h.as(aliceTokens, "admin");

    assert.deepEqual(await (await aliceAdmin("GET", "/v1/admin/keys")).json(), { keys: [] });

    // Validation errors
    assert.equal((await aliceAdmin("POST", "/v1/admin/keys", { name: "   " })).status, 400);
    assert.equal((await aliceAdmin("POST", "/v1/admin/keys", { name: "x".repeat(81) })).status, 400);
    assert.equal((await aliceAdmin("POST", "/v1/admin/keys", { name: "bad-days", days: 0 })).status, 400);
    assert.equal((await aliceAdmin("POST", "/v1/admin/keys", { name: "bad-days", days: 3651 })).status, 400);
    assert.equal((await aliceAdmin("POST", "/v1/admin/keys", { name: "bad-days", days: 1.5 })).status, 400);
    assert.equal((await aliceAdmin("POST", "/v1/admin/keys/ak_missing/revoke")).status, 404);

    // Create with expiry
    const res1 = await aliceAdmin("POST", "/v1/admin/keys", { name: "  Ops   CLI ", days: 30 });
    assert.equal(res1.status, 201);
    const made1 = (await res1.json()) as any;
    assert.match(made1.id, /^ak_/);
    assert.equal(made1.name, "Ops CLI");
    assert.match(made1.key, /^sfa_[A-Za-z0-9_-]{43}$/);
    assert.equal(made1.prefix, made1.key.slice(0, 12));
    assert.equal(made1.created_by, aliceTokens.subject);
    assert.equal(made1.created_by_email, "alice@example.test");
    assert.equal(made1.expires_at - made1.created_at, 30 * 86_400);
    assert.equal(made1.last_used_at, null);
    assert.equal(made1.revoked_at, null);
    assert.equal(made1.origin, h.origin);
    assert.equal(made1.host, new URL(h.origin).hostname);

    // Create without expiry (never expires)
    const res2 = await aliceAdmin("POST", "/v1/admin/keys", { name: "CI Script" });
    assert.equal(res2.status, 201);
    const made2 = (await res2.json()) as any;
    assert.equal(made2.expires_at, null);

    // Listing omits key and key_hash
    const listed = (await (await aliceAdmin("GET", "/v1/admin/keys")).json()) as { keys: Record<string, unknown>[] };
    assert.equal(listed.keys.length, 2);
    for (const k of listed.keys) {
      assert.equal("key" in k, false);
      assert.equal("key_hash" in k, false);
    }

    // Revoke + idempotent revoke
    const rev1 = await aliceAdmin("POST", `/v1/admin/keys/${made1.id}/revoke`);
    assert.equal(rev1.status, 200);
    assert.deepEqual(await rev1.json(), { ok: true });
    const rev2 = await aliceAdmin("POST", `/v1/admin/keys/${made1.id}/revoke`);
    assert.equal(rev2.status, 200);

    // Audit entries recorded
    const audit = (await (await aliceAdmin("GET", "/v1/admin/audit")).json()) as { audit: { actor: string; action: string; target: string; detail: string }[] };
    assert.ok(audit.audit.some((e) => e.action === "key.create" && e.target === "Ops CLI" && e.detail === `${made1.prefix} · days=30`));
    assert.ok(audit.audit.some((e) => e.action === "key.create" && e.target === "CI Script" && e.detail === `${made2.prefix} · never`));
    assert.ok(audit.audit.some((e) => e.action === "key.revoke" && e.target === "Ops CLI" && e.detail === made1.prefix));
  } finally {
    await h.close();
  }
});

test("admin API key works on PUBLIC_ORIGIN across all admin endpoints, enforces boundaries, and audits with key name", async () => {
  const h = await harness();
  try {
    const aliceTokens = await h.login("alice");
    const bobTokens = await h.login("bob");
    const aliceAdmin = h.as(aliceTokens, "admin");

    const made = (await (await aliceAdmin("POST", "/v1/admin/keys", { name: "Automation", days: 7 })).json()) as { id: string; key: string; prefix: string };
    const call = (method: string, path: string, body?: unknown) =>
      h.fetch(path, {
        method,
        headers: {
          authorization: `Bearer ${made.key}`,
          ...(body !== undefined ? { "content-type": "application/json" } : {}),
        },
        ...(body !== undefined ? { body: JSON.stringify(body) } : {}),
      });

    // whoami
    const meRes = await call("GET", "/v1/admin/me");
    assert.equal(meRes.status, 200);
    assert.deepEqual(await meRes.json(), {
      email: "alice@example.test",
      key: { id: made.id, name: "Automation", prefix: made.prefix },
    });

    // Key management endpoints are forbidden (403) for API keys
    assert.equal((await call("GET", "/v1/admin/keys")).status, 403);
    assert.equal((await call("POST", "/v1/admin/keys", { name: "escalate" })).status, 403);
    assert.equal((await call("POST", `/v1/admin/keys/${made.id}/revoke`)).status, 403);

    // Cannot block creator / ADMIN_EMAIL (403)
    assert.equal((await call("POST", `/v1/admin/users/${aliceTokens.subject}/block`, { on: true })).status, 403);

    // Users & pending
    assert.equal((await call("GET", "/v1/admin/users")).status, 200);
    assert.equal((await call("POST", `/v1/admin/users/${bobTokens.subject}/beta`, { on: true })).status, 200);
    assert.equal((await call("POST", `/v1/admin/users/${bobTokens.subject}/may-create`, { on: true })).status, 200);
    assert.equal((await call("POST", `/v1/admin/users/${bobTokens.subject}/block`, { on: true })).status, 200);
    assert.equal((await call("POST", `/v1/admin/users/${bobTokens.subject}/block`, { on: false })).status, 200);
    assert.equal((await call("POST", "/v1/admin/pending", { email: "newbie@example.test", beta: true })).status, 200);
    assert.equal((await call("POST", "/v1/admin/pending/remove", { email: "newbie@example.test" })).status, 200);

    // Workspaces
    const wsRes = await call("POST", "/v1/admin/workspaces", { name: "Enterprise Co", owners: ["owner@co.test"], members: 30, stations: 64 });
    assert.equal(wsRes.status, 200);
    const ws = (await wsRes.json()) as { id: string };
    assert.equal((await call("GET", "/v1/admin/workspaces")).status, 200);
    assert.equal((await call("POST", `/v1/admin/workspaces/${ws.id}/limits`, { members: 50, stations: 64 })).status, 200);
    assert.equal((await call("POST", `/v1/admin/workspaces/${ws.id}/owners`, { emails: ["cto@co.test"] })).status, 200);
    assert.equal((await call("POST", `/v1/admin/workspaces/${ws.id}/added/remove`, { email: "cto@co.test" })).status, 200);
    assert.equal((await call("POST", `/v1/admin/workspaces/${ws.id}/enrollments`, { name: "box-1" })).status, 200);
    assert.equal((await call("POST", `/v1/admin/workspaces/${ws.id}/delete`)).status, 200);

    // Invite codes
    const codeRes = await call("POST", "/v1/admin/invite-codes", { note: "cli test", days: 7 });
    assert.equal(codeRes.status, 200);
    const code = (await codeRes.json()) as { code: string };
    assert.equal((await call("GET", "/v1/admin/invite-codes")).status, 200);
    assert.equal((await call("POST", `/v1/admin/invite-codes/${code.code}/revoke`)).status, 200);

    // Feedback (blocking bob signed out his prior session, so sign him in again)
    const bob = h.as(await h.login("bob"));
    const fbRes = await bob("POST", "/v1/feedback", { key: "k-1", title: "Test bug", body: "details", area: "web" });
    assert.equal(fbRes.status, 201);
    const fb = (await fbRes.json()) as { id: string; number: number };
    assert.equal((await call("GET", "/v1/admin/feedback")).status, 200);
    assert.equal((await call("GET", `/v1/admin/feedback/FB-${fb.number}`)).status, 200);
    assert.equal((await call("POST", `/v1/admin/feedback/${fb.id}/status`, { status: "triaged" })).status, 200);

    // Relays
    assert.equal((await call("GET", "/v1/admin/relays")).status, 200);
    assert.equal((await call("POST", "/v1/admin/relays/list")).status, 200);
    assert.equal((await call("POST", "/v1/admin/relays/put", { url: "https://sg.relay.example", name: "Singapore" })).status, 200);
    assert.equal((await call("POST", "/v1/admin/relays/remove", { url: "https://sg.relay.example" })).status, 200);

    // Audit records actor as `<email> (key:<name>)`
    const auditRes = await call("GET", "/v1/admin/audit");
    assert.equal(auditRes.status, 200);
    const audit = (await auditRes.json()) as { audit: { actor: string; action: string }[] };
    assert.ok(audit.audit.some((e) => e.actor === "alice@example.test (key:Automation)" && e.action === "user.beta"));
    assert.ok(audit.audit.some((e) => e.actor === "alice@example.test (key:Automation)" && e.action === "relay.put"));

    // Revoking immediately rejects key with 401
    assert.equal((await aliceAdmin("POST", `/v1/admin/keys/${made.id}/revoke`)).status, 200);
    assert.equal((await call("GET", "/v1/admin/me")).status, 401);

    // Forged sfa_ key returns 401
    assert.equal((await h.fetch("/v1/admin/me", { headers: { authorization: `Bearer sfa_${"a".repeat(43)}` } })).status, 401);

    // Expired key returns 401
    const shortKey = (await (await aliceAdmin("POST", "/v1/admin/keys", { name: "Short", days: 1 })).json()) as { id: string; key: string };
    assert.equal((await h.fetch("/v1/admin/me", { headers: { authorization: `Bearer ${shortKey.key}` } })).status, 200);
    const directories: any = await h.mf.getDurableObjectNamespace("DIRECTORY", "api");
    await directories.get(directories.idFromName("primary")).expireAdminKey(shortKey.id);
    assert.equal((await h.fetch("/v1/admin/me", { headers: { authorization: `Bearer ${shortKey.key}` } })).status, 401);
  } finally {
    await h.close();
  }
});

test("admin API key works across guest-forwarded origin alongside ADMIN_TOKEN", async () => {
  const secret = "s".repeat(40);
  const guest = "https://app.still.fail";
  const h = await harness({
    origin: "https://app.monoid.build",
    guests: [{ origin: guest, beta: "https://app.youdid.wtf", google_client_id: "g-id", google_client_secret: "g-sec" }],
    forwardSecret: secret,
  });
  try {
    const aliceTokens = await h.login("alice");
    const aliceAdmin = h.as(aliceTokens, "admin");
    const made = (await (await aliceAdmin("POST", "/v1/admin/keys", { name: "Guest CLI" })).json()) as { key: string };

    const res = await h.fetch("/v1/admin/me", {
      headers: {
        authorization: `Bearer ${made.key}`,
        "x-stillfail-forwarded-origin": guest,
        "x-stillfail-forward-secret": secret,
        "x-stillfail-forwarded-for": "203.0.113.7",
      },
    });
    assert.equal(res.status, 200);
    const body = (await res.json()) as { email: string; key: { name: string } };
    assert.equal(body.email, "alice@example.test");
    assert.equal(body.key.name, "Guest CLI");

    // Legacy ADMIN_TOKEN still works
    assert.equal((await h.fetch("/v1/admin/workspaces/list", { method: "POST", headers: { authorization: `Bearer ${h.adminToken}` } })).status, 200);
  } finally {
    await h.close();
  }
});
