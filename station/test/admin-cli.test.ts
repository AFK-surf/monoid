import assert from "node:assert/strict";
import { mkdtempSync, rmSync } from "node:fs";
import { createServer as httpServer, type IncomingMessage, type ServerResponse } from "node:http";
import { createServer as httpsServer } from "node:https";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import { runAdminCli } from "../../bin/admin-cli.ts";
import type { Held } from "../src/vault/keeper.ts";
import { Proxy } from "../src/vault/proxy.ts";
import { runWith } from "../src/vault/run.ts";
import { makeCa, makeLeaf, pem } from "../src/vault/x509.ts";

function readBody(req: IncomingMessage): Promise<any> {
  return new Promise((resolve, reject) => {
    const chunks: Buffer[] = [];
    req.on("data", (c: Buffer) => chunks.push(c));
    req.on("end", () => {
      const raw = Buffer.concat(chunks).toString("utf8");
      resolve(raw ? JSON.parse(raw) : {});
    });
    req.on("error", reject);
  });
}

async function startMockCloud() {
  const calls: { method: string; url: string; auth: string | undefined; body: any }[] = [];
  const server = httpServer(async (req: IncomingMessage, res: ServerResponse) => {
    const body = await readBody(req);
    calls.push({ method: req.method ?? "", url: req.url ?? "", auth: req.headers.authorization, body });
    const send = (status: number, data: unknown) => {
      res.writeHead(status, { "content-type": "application/json" });
      res.end(JSON.stringify(data));
    };
    if (req.headers.authorization !== "Bearer sfa_test_secret_key") return send(401, { error: "unauthorized" });
    if (req.url === "/v1/admin/me" && req.method === "GET") {
      return send(200, { email: "alice@example.test", key: { id: "ak_1", name: "Ops", prefix: "sfa_test_sec" } });
    }
    if (req.url === "/v1/admin/users" && req.method === "GET") {
      const nowSec = Math.floor(Date.now() / 1000);
      return send(200, {
        users: [
          { sub: "sub_bob", email: "bob@example.test", name: "Bob", plan: "free", beta: false, blocked: false, admission: "free", created_at: nowSec - 2 * 86_400, last_seen: nowSec - 3600 },
          { sub: "sub_old", email: "old@example.test", name: "Old", plan: "standard", beta: true, blocked: false, admission: "code", created_at: nowSec - 90 * 86_400, last_seen: nowSec - 45 * 86_400 },
        ],
        pending: [
          { email: "newhire@example.test", beta: true, may_create: false, added_at: nowSec - 86_400 },
        ],
      });
    }
    if (req.url === "/v1/admin/invite-codes" && req.method === "GET") {
      const nowSec = Math.floor(Date.now() / 1000);
      return send(200, {
        codes: [
          { code: "OPEN-1111-AAAA", note: "active", beta: false, created_at: nowSec - 86_400, expires_at: nowSec + 7 * 86_400, revoked_at: null, used_at: null, used_by: null },
          { code: "EXPD-2222-BBBB", note: "old", beta: false, created_at: nowSec - 20 * 86_400, expires_at: nowSec - 86_400, revoked_at: null, used_at: null, used_by: null },
          { code: "USED-3333-CCCC", note: "used", beta: false, created_at: nowSec - 10 * 86_400, expires_at: nowSec + 86_400, revoked_at: null, used_at: nowSec - 3600, used_by: { sub: "sub_bob" } },
        ],
      });
    }
    if (req.url === "/v1/admin/users/sub_bob/beta" && req.method === "POST") {
      return send(200, { sub: "sub_bob", beta: body.on });
    }
    if (req.url === "/v1/admin/relays/list" && req.method === "POST") {
      return send(200, {
        relays: [
          { url: "https://hk.relay.example", name: "香港", target: null },
          { url: "https://bj.relay.example:8443", name: "北京入口", target: "https://hk.relay.example" },
        ],
        tokens: [],
      });
    }
    if (req.url === "/v1/admin/relays/put" && req.method === "POST") {
      return send(200, { url: body.url, name: body.name, target: body.target ?? null });
    }
    if (req.url === "/v1/admin/workspaces/ws_1/delete" && req.method === "POST") {
      return send(200, { ok: true });
    }
    if (req.url === "/v1/admin/feedback/FB-42" && req.method === "GET") {
      return send(200, { item: { id: "01JD3FB0000000000000000042", number: 42, status: "new", title: "Bug", body: "details" } });
    }
    if (req.url === "/v1/admin/feedback/01JD3FB0000000000000000042/status" && req.method === "POST") {
      return send(200, { ok: true });
    }
    return send(404, { error: "not_found" });
  });
  await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
  const port = (server.address() as { port: number }).port;
  return { server, origin: `http://127.0.0.1:${port}`, calls };
}

async function execCli(argv: string[], env: Record<string, string | undefined>) {
  let stdout = "";
  let stderr = "";
  const code = await runAdminCli(argv, {
    stdout: (s) => { stdout += s; },
    stderr: (s) => { stderr += s; },
    env,
    argv0: "stillfail",
  });
  return { code, stdout, stderr };
}

test("admin CLI handles whoami, email-to-sub resolution, relays rename target preservation, workspaces delete --yes guard, and FB-n resolution", async () => {
  const mock = await startMockCloud();
  try {
    const env = { STILLFAIL_ADMIN_ORIGIN: mock.origin, STILLFAIL_ADMIN_KEY: "sfa_test_secret_key" };

    // whoami + --json
    const who = await execCli(["--json", "whoami"], env);
    assert.equal(who.code, 0, who.stderr);
    assert.deepEqual(JSON.parse(who.stdout), { email: "alice@example.test", key: { id: "ak_1", name: "Ops", prefix: "sfa_test_sec" } });

    // users beta resolves email -> sub_bob
    const beta = await execCli(["users", "beta", "bob@example.test", "on"], env);
    assert.equal(beta.code, 0, beta.stderr);
    assert.ok(mock.calls.some((c) => c.url === "/v1/admin/users/sub_bob/beta" && c.body.on === true));

    // relays rename preserves existing entry target when --target is omitted
    const ren = await execCli(["--json", "relays", "rename", "https://bj.relay.example:8443", "北京入口2"], env);
    assert.equal(ren.code, 0, ren.stderr);
    assert.deepEqual(JSON.parse(ren.stdout), {
      url: "https://bj.relay.example:8443",
      name: "北京入口2",
      target: "https://hk.relay.example",
    });

    // workspaces delete refuses without --yes
    const noYes = await execCli(["workspaces", "delete", "ws_1"], env);
    assert.equal(noYes.code, 2);
    assert.match(noYes.stderr, /--yes/);

    // workspaces delete succeeds with --yes
    const withYes = await execCli(["workspaces", "delete", "ws_1", "--yes"], env);
    assert.equal(withYes.code, 0, withYes.stderr);

    // feedback status resolves FB-42 to ULID
    const fb = await execCli(["feedback", "status", "FB-42", "triaged"], env);
    assert.equal(fb.code, 0, fb.stderr);
    assert.ok(mock.calls.some((c) => c.url === "/v1/admin/feedback/01JD3FB0000000000000000042/status" && c.body.status === "triaged"));

    // users list filters: active, new, dormant, pending
    const uActive = await execCli(["--json", "users", "list", "--filter", "active"], env);
    assert.equal(uActive.code, 0, uActive.stderr);
    assert.deepEqual(JSON.parse(uActive.stdout).users.map((u: any) => u.sub), ["sub_bob"]);

    const uNew = await execCli(["--json", "users", "list", "--filter", "new"], env);
    assert.equal(uNew.code, 0, uNew.stderr);
    assert.deepEqual(JSON.parse(uNew.stdout).users.map((u: any) => u.sub), ["sub_bob"]);

    const uDormant = await execCli(["--json", "users", "list", "--filter", "dormant"], env);
    assert.equal(uDormant.code, 0, uDormant.stderr);
    assert.deepEqual(JSON.parse(uDormant.stdout).users.map((u: any) => u.sub), ["sub_old"]);

    const uPending = await execCli(["users", "list", "--filter", "pending"], env);
    assert.equal(uPending.code, 0, uPending.stderr);
    assert.match(uPending.stdout, /newhire@example\.test/);

    // codes list filters: open excludes expired; expired matches only expired; text prints expired
    const cOpen = await execCli(["--json", "codes", "list", "--filter", "open"], env);
    assert.equal(cOpen.code, 0, cOpen.stderr);
    assert.deepEqual(JSON.parse(cOpen.stdout).codes.map((c: any) => c.code), ["OPEN-1111-AAAA"]);

    const cExp = await execCli(["codes", "list", "--filter", "expired"], env);
    assert.equal(cExp.code, 0, cExp.stderr);
    assert.match(cExp.stdout, /EXPD-2222-BBBB\texpired/);
    assert.doesNotMatch(cExp.stdout, /OPEN-1111-AAAA/);

    // unauthorized key fails with exit code 1 and never leaks key in stderr
    const bad = await execCli(["whoami"], { STILLFAIL_ADMIN_ORIGIN: mock.origin, STILLFAIL_ADMIN_KEY: "sfa_wrong_secret_xyz" });
    assert.equal(bad.code, 1);
    assert.doesNotMatch(bad.stderr, /sfa_wrong_secret_xyz/);
  } finally {
    mock.server.close();
  }
});

test("admin CLI works end-to-end through vault Proxy + runWith(mode: proxy) without leaking plaintext key", async () => {
  const dir = mkdtempSync(join(tmpdir(), "sf-admin-cli-proxy-"));
  const realKey = "sfa_real_vault_secret_token_9876543210abcdef";
  const now = Date.now();
  const upstreamCa = makeCa(now, "test-upstream-ca");
  const leaf = makeLeaf(upstreamCa, "test-upstream-ca", "localhost", now);

  let seenAuth = "";
  const bigLogs = "L".repeat(24 * 1024);
  const upstream = httpsServer(
    { key: leaf.key.export({ format: "pem", type: "pkcs8" }), cert: pem(leaf.cert) },
    (req, res) => {
      seenAuth = req.headers.authorization ?? "";
      if (req.url === "/v1/admin/feedback/FB-99") {
        // Chunked response (>16KB, no Content-Length) to verify standard https.request over proxy tunnel
        res.writeHead(200, { "content-type": "application/json", "transfer-encoding": "chunked" });
        const payload = JSON.stringify({ item: { id: "01JD3FB0000000000000000099", number: 99, status: "new", title: "Big", body: "b", logs: bigLogs } });
        for (let i = 0; i < payload.length; i += 4096) res.write(payload.slice(i, i + 4096));
        res.end();
        return;
      }
      res.writeHead(200, { "content-type": "application/json" });
      res.end(JSON.stringify({ email: "alice@example.test", key: { id: "ak_proxy", name: "Vault Key", prefix: realKey.slice(0, 12) } }));
    },
  );
  await new Promise<void>((resolve) => upstream.listen(0, "127.0.0.1", resolve));
  const port = (upstream.address() as { port: number }).port;

  const proxy = new Proxy(join(dir, "proxy"), () => now, [pem(upstreamCa.cert)]);
  const usedHosts: string[] = [];
  const held: Held = {
    request: { id: "r_admin_1", ws: "ws", vault: "v1", item: "i1", session: "s1", chat: "CHAT/1.0", mode: "proxy", reason: "admin cli", box: "", at: Math.floor(now / 1000), status: "granted" },
    grant: { v: 1, ws: "ws", request: "r_admin_1", vault: "v1", item: "i1", mode: "proxy", hosts: ["localhost"], scope: "once", exp: Math.floor(now / 1000) + 600, secret: "", at: Math.floor(now / 1000), sig: { key: "", alg: "Ed25519", sig: "" } },
    secret: { kind: "token", name: "Admin API Key", fields: { value: realKey } },
    uses: 0,
  };

  try {
    const cliEntry = join(import.meta.dirname, "..", "..", "bin", "admin-cli.ts");
    const ran = await runWith(
      held,
      {
        command: `${JSON.stringify(process.execPath)} ${JSON.stringify(cliEntry)} --origin https://localhost:${port} --json whoami`,
        cwd: dir,
        env: "STILLFAIL_ADMIN_KEY",
        timeoutMs: 15_000,
      },
      proxy,
      { PATH: process.env.PATH ?? "" },
      (host) => usedHosts.push(host),
    );
    assert.equal(ran.code, 0, ran.output);
    assert.equal(seenAuth, `Bearer ${realKey}`, "vault proxy must substitute placeholder with real sfa_ key");
    assert.deepEqual(usedHosts, ["localhost"]);
    assert.doesNotMatch(ran.output, new RegExp(realKey), "plaintext key must never appear in CLI output");
    const parsed = JSON.parse(ran.output);
    assert.equal(parsed.email, "alice@example.test");
    assert.equal(parsed.key.name, "Vault Key");

    // Large (>16KB) chunked JSON response over proxy tunnel
    const bigRan = await runWith(
      held,
      {
        command: `${JSON.stringify(process.execPath)} ${JSON.stringify(cliEntry)} --origin https://localhost:${port} --json feedback get FB-99`,
        cwd: dir,
        env: "STILLFAIL_ADMIN_KEY",
        timeoutMs: 15_000,
      },
      proxy,
      { PATH: process.env.PATH ?? "" },
      (host) => usedHosts.push(host),
    );
    assert.equal(bigRan.code, 0, bigRan.output);
    assert.doesNotMatch(bigRan.output, new RegExp(realKey));
    const bigParsed = JSON.parse(bigRan.output);
    assert.equal(bigParsed.item.logs.length, bigLogs.length);
  } finally {
    proxy.close();
    upstream.close();
    rmSync(dir, { recursive: true, force: true });
  }
});
