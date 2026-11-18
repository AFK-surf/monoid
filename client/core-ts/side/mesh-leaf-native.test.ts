// The real core host drives the NAPI scope transport. C has no advertised root
// address: after admission at B, A authenticates C through A -> B -> C.
import assert from "node:assert/strict";
import { randomBytes } from "node:crypto";
import { test } from "node:test";
import { loadAddon, nodeIroh } from "../src/hosts/node-iroh.ts";
import type { IrohMeshDescriptor, IrohEndpoint } from "../src/iroh.ts";
import { run } from "../test/run.ts";

const utf8 = (s: string) => new TextEncoder().encode(s);
const scope = "27".repeat(32);
const alpn = utf8("mesh-leaf-native/1");
function reachable(d: IrohMeshDescriptor, yes: boolean): IrohMeshDescriptor {
  const address = d.address as { id: string; addrs: { Ip?: string }[] };
  const port = address.addrs.find(a => a.Ip && !a.Ip.startsWith("["))?.Ip?.split(":").at(-1);
  assert.ok(port, "scope has an IPv4 neighbor socket");
  return { ...d, address: { id: address.id, addrs: yes ? [{ Ip: `127.0.0.1:${port}` }] : [] } };
}

test("core NAPI leaf reaches the root identity across two hops and removes its scope", { timeout: 30_000 }, async () => {
  const addon = loadAddon();
  assert.ok(addon, "build the real mesh addon before this side test");
  const raw:any[]=[];
  const iroh = nodeIroh({bind:async options=>{const endpoint=await addon.bind(options);raw.push(endpoint);return endpoint;}})!;
  const endpoints: IrohEndpoint[] = [];
  try {
    for (let i = 0; i < 3; i++) endpoints.push(await run(iroh.bind({ secretKey: randomBytes(32), relayUrls: [], lookup: false, relayOnly: false, alpns: [alpn] })));
    const descriptors = [];
    for (let i = 0; i < 3; i++) {
      assert.ok(endpoints[i].meshConfigure, "host exposes real mesh configuration");
      descriptors.push(await run(endpoints[i].meshConfigure!({ scope, peers: [], transit: i !== 0, relayUrls: [] })));
    }
    assert.equal(descriptors[0].binding.transit, false);
    assert.equal(descriptors[2].binding.transit, true);
    for (let i = 0; i < 3; i++) await run(endpoints[i].meshConfigure!({ scope, transit: i !== 0, relayUrls: [], peers: descriptors.flatMap((d, j) => i === j || j===0 ? [] : [reachable(d, Math.abs(i - j) === 1)]) }));
    // The ingress authenticates the actual root QUIC connection before admitting
    // A; no other station has A in its directory.
    const admission=raw[1].accept();
    const rootPort=raw[1].sockets().find((a:string)=>!a.startsWith("["))?.split(":").at(-1);
    assert.ok(rootPort);
    const ingress=await run(endpoints[0].connect({id:endpoints[1].id(),ips:[`127.0.0.1:${rootPort}`]},alpn,[]));
    const authenticated=await admission;
    assert.equal(authenticated.remoteId(),endpoints[0].id());
    const attachment=await raw[1].meshAttachLeaf(authenticated,{scope,descriptor:reachable(descriptors[0],true),target:endpoints[2].id(),expiresUnixMs:Date.now()+60_000});
    await run(endpoints[0].meshUseLeaf!({scope,attachment}));
    const accepted = run(endpoints[2].accept!());
    const connection = await run(endpoints[0].connect({ id: endpoints[2].id(), meshScope: scope }, alpn, []));
    assert.equal(connection.remoteId(), endpoints[2].id(), "inner QUIC authenticates the destination root");
    const incoming = await accepted;
    assert.ok(incoming);
    assert.equal(incoming.connection.remoteId(), endpoints[0].id(), "destination sees the leaf root, not the forwarder");
    const sent = await run(connection.openBi());
    await run(sent.write(utf8("root-to-root ciphertext")));
    await run(sent.finish());
    const received = await run(incoming.connection.acceptBi());
    assert.ok(received);
    const chunks: Uint8Array[] = [];
    for (;;) { const chunk = await run(received.read()); if (chunk === null) break; chunks.push(chunk); }
    assert.equal(Buffer.concat(chunks).toString(), "root-to-root ciphertext");
    await run(endpoints[0].meshRemove!(scope));
    await assert.rejects(run(endpoints[0].connect({ id: endpoints[2].id(), meshScope: scope }, alpn, [])), /scope is not configured/);
    connection.close(0, "done");
    ingress.close(0,"done");
  } finally {
    await Promise.all(endpoints.map(e => run(e.close())));
  }
});
