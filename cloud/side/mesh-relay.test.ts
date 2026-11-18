// Real Rust process and HTTP sockets against the actual Worker: the side run's.
import assert from "node:assert/strict";
import { spawn, type ChildProcess } from "node:child_process";
import { once } from "node:events";
import { mkdirSync, mkdtempSync, readFileSync, rmSync, watch, writeFileSync } from "node:fs";
import { createServer } from "node:http";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";
import { harness } from "../test/harness.ts";

function signal() {
  let resolve!: () => void;
  const promise = new Promise<void>(done => { resolve = done; });
  return {promise,resolve};
}

function stateWhen(dir: string, predicate: (state: any) => boolean): Promise<any> {
  return new Promise((resolve, reject) => {
    const timeout = setTimeout(() => finish(new Error("relay did not persist expected global state")), 15000);
    const watcher = watch(dir, check);
    function finish(error?: Error, state?: unknown) {
      clearTimeout(timeout); watcher.close();
      if (error) reject(error); else resolve(state);
    }
    function check() {
      try {
        const state = JSON.parse(readFileSync(join(dir, "global.json"), "utf8"));
        if (predicate(state)) finish(undefined, state);
      } catch (error) {
        if ((error as NodeJS.ErrnoException).code !== "ENOENT") finish(error as Error);
      }
    }
    check();
  });
}

for (const revokeDuringPublish of [true, false]) test(`global relay restarts and clears revocation ${revokeDuringPublish ? "during publication" : "from its live subscription"}`, { timeout: 60000 }, async () => {
  const binary = process.env.STILLFAIL_MESH_RELAY_BIN;
  assert.ok(binary, "build mesh-relay and set STILLFAIL_MESH_RELAY_BIN for this side test");
  const root = mkdtempSync(join(tmpdir(), "mesh-global-side-"));
  const data = join(root, "data"); mkdirSync(data, { mode: 0o700 });
  let h: Awaited<ReturnType<typeof harness>> | undefined;
  let child: ChildProcess | undefined;
  let exited: Promise<unknown[]> | undefined;
  let output = "";
  let revokeBeforeAddress: string | undefined;
  let ready = signal();
  const admin = async (action: string, body: unknown) => {
    assert.ok(h);
    return h.fetch(`/v1/admin/relays/${action}`, { method: "POST", headers: {
      authorization: `Bearer ${h.adminToken}`, "content-type": "application/json",
    }, body: JSON.stringify(body) });
  };
  const server = createServer(async (req, res) => {
    try {
      assert.ok(h);
      const chunks: Buffer[] = [];
      for await (const chunk of req) chunks.push(Buffer.from(chunk));
      // Revoke after the registry read but before publication, exercising the race.
      if (req.url === "/v1/relays/mesh/address" && revokeBeforeAddress) {
        const node = revokeBeforeAddress; revokeBeforeAddress = undefined;
        assert.equal((await admin("mesh-remove", { node })).status, 200);
      }
      const answer = await h.fetch(req.url!, { method: req.method, headers: { "content-type": "application/json" },
        ...(chunks.length ? { body: Buffer.concat(chunks).toString() } : {}) });
      res.writeHead(answer.status, Object.fromEntries(answer.headers));
      if (req.url === "/v1/relays/mesh/events" && answer.status === 200) {
        const signal = ready.resolve;
        const reader = answer.body!.getReader();
        let closed = false;
        res.on("close", () => { closed = true; void reader.cancel().catch(() => {}); });
        res.flushHeaders();
        try {
          while (!closed) {
            const part = await reader.read(); if (part.done) break;
            const flowing = res.write(Buffer.from(part.value)); signal();
            if (!flowing && !closed) await Promise.race([once(res,"drain"),once(res,"close")]);
          }
        } finally { await reader.cancel().catch(() => {}); }
        if (!closed) res.end();
      } else res.end(Buffer.from(await answer.arrayBuffer()));
    } catch (error) { output += String(error); res.writeHead(500).end(); }
  });
  server.listen(0, "127.0.0.1"); await once(server, "listening");
  const origin = `http://127.0.0.1:${(server.address() as { port: number }).port}`;
  const start = (invite?: string) => {
    ready = signal();
    child = spawn(binary, ["--global", data, ...(invite ? [invite] : [])], { stdio: ["ignore", "pipe", "pipe"] });
    child.stdout!.on("data", b => { output += b; }); child.stderr!.on("data", b => { output += b; });
    exited = once(child, "exit");
  };
  const stop = async () => { if (child && child.exitCode === null && child.signalCode === null) { child.kill("SIGKILL"); await exited; } };
  try {
    h = await harness({ origin });
    const tokenResponse = await admin("token", { name: "global side relay" });
    assert.equal(tokenResponse.status, 200);
    const { token } = await tokenResponse.json() as { token: string };
    const invite = join(root, "invite.json");
    writeFileSync(invite, JSON.stringify({ origin, token, relays: [] }), { mode: 0o600 });
    const registered = stateWhen(data, s => !!s.registration && s.invitation.token === "");
    start(invite);
    const first = await registered;
    const identity = readFileSync(join(data, "identity"));
    await stop(); rmSync(invite);
    const resumed = stateWhen(data, s => !!s.registration && s.registration.revision > first.registration.revision);
    start();
    const second = await resumed;
    assert.equal(second.registration.node, first.registration.node);
    assert.equal(second.registration.generation, first.registration.generation);
    assert.deepEqual(readFileSync(join(data, "identity")), identity);
    if (revokeDuringPublish) { await stop(); revokeBeforeAddress = first.registration.node; }
    else await ready.promise;
    const cleared = stateWhen(data, s => s.registration === null && s.registry.every((r: any) => r.node !== first.registration.node));
    if (revokeDuringPublish) start();
    else assert.equal((await admin("mesh-remove", {node:first.registration.node})).status,200);
    await cleared;
    const [code] = await exited!;
    assert.notEqual(code, 0);
    assert.match(output, revokeDuringPublish ? /mesh_relay_not_registered/ : /global registration was removed/);
    const listing = await (await admin("list", {})).json() as any;
    assert.equal(listing.tokens.length, 0);
    assert.equal((await (await h.fetch("/v1/relays/mesh")).json() as any).relays.length, 0);
  } catch (error) { throw new Error(`${String(error)}\n${output}`, { cause: error }); }
  finally {
    await stop(); server.closeAllConnections();
    await new Promise<void>(resolve => server.close(() => resolve()));
    await h?.close(); rmSync(root, { recursive: true, force: true });
  }
});
