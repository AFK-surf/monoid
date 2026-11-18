// Real control sockets: lost acknowledgements must not restore a removed scope.
import assert from "node:assert/strict";
import { mkdtemp, rm } from "node:fs/promises";
import { createServer, type Socket } from "node:net";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import { withFront } from "../src/mesh/front.ts";
import type { Mesh } from "../src/mesh/native.ts";

for (const operation of ["meshConfigure", "meshRemove"] as const) {
  test(`a lost ${operation} reply preserves the desired scope on reconnect`, async () => {
    const dir = await mkdtemp(join(tmpdir(), "front-scope-"));
    const sock = join(dir, "front.sock");
    const links: Socket[] = [];
    const told: { link: number; op: string; args: unknown }[] = [];
    let lose = false;
    const server = createServer((s) => {
      const link = links.push(s);
      let pending = "";
      s.on("error", () => {});
      s.on("data", (chunk) => {
        pending += chunk;
        for (let at; (at = pending.indexOf("\n")) >= 0; pending = pending.slice(at + 1)) {
          const asked = JSON.parse(pending.slice(0, at));
          told.push({ link, op: asked.op, args: asked.args });
          if (lose && asked.op === operation) {
            lose = false;
            s.destroy();
            return;
          }
          s.write(JSON.stringify({ id: asked.id, ok: asked.op === "bind" ? { id: "station", sockets: [] } : asked.op === "relayStatus" ? [] : null }) + "\n");
        }
      });
    });
    await new Promise<void>((resolve) => server.listen(sock, resolve));
    const mesh = withFront({} as Mesh, sock);
    const endpoint = await mesh.bind({ secretKey: Buffer.alloc(32), alpns: [], relayUrls: [] });
    try {
      const scope = { scope: "03".repeat(32), peers: [], relayUrls: [] };
      if (operation === "meshRemove") await endpoint.meshConfigure!(scope);
      lose = true;
      await assert.rejects(operation === "meshConfigure" ? endpoint.meshConfigure!(scope) : endpoint.meshRemove!(scope.scope), /front is gone/);
      // Waiting for the observable reconnect, with no elapsed-time assertion.
      while (links.length < 2 || mesh.frontLink!() !== "ok") await new Promise((r) => setImmediate(r));
      assert.deepEqual(told.filter((x) => x.link === 2 && x.op.startsWith("mesh")), [{
        link: 2, op: operation, args: operation === "meshConfigure" ? scope : { scope: scope.scope },
      }]);
    } finally {
      await endpoint.close();
      for (const s of links) s.destroy();
      server.close();
      await rm(dir, { recursive: true, force: true });
    }
  });
}

test("the front pushes scope addresses without status requests", { timeout: 5000 }, async () => {
  const dir = await mkdtemp(join(tmpdir(), "front-mesh-push-"));
  const sock = join(dir, "front.sock");
  const links: Socket[] = [];
  const asked: string[] = [];
  const server = createServer((s) => {
    links.push(s);
    let pending = "";
    s.on("error", () => {});
    s.on("data", (chunk) => {
      pending += chunk;
      for (let at; (at = pending.indexOf("\n")) >= 0; pending = pending.slice(at + 1)) {
        const request = JSON.parse(pending.slice(0, at));
        asked.push(request.op);
        s.write(JSON.stringify({ id: request.id, ok: request.op === "bind" ? { id: "station", sockets: [] } : [] }) + "\n");
      }
    });
  });
  await new Promise<void>((resolve) => server.listen(sock, resolve));
  const endpoint = await withFront({} as Mesh, sock).bind({ secretKey: Buffer.alloc(32), alpns: [], relayUrls: [] });
  try {
    let delivered!: (scopes: unknown) => void;
    const update = new Promise((resolve) => { delivered = resolve; });
    const off = endpoint.meshListen!(delivered);
    const scopes = [{ scope: "01".repeat(32), descriptor: { binding: {}, address: { id: "neighbor" } } }];
    links[0]!.write(JSON.stringify({ event: "meshScopes", scopes }) + "\n");
    assert.deepEqual(await update, scopes);
    assert.deepEqual(asked, ["bind", "relayStatus"], "no request between the subscription and the pushed change");
    off();
  } finally {
    await endpoint.close();
    for (const s of links) s.destroy();
    server.close();
    await rm(dir, { recursive: true, force: true });
  }
});
