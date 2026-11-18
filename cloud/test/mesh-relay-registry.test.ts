import { watchMessage } from "../src/mesh-relay-events.ts";
import assert from "node:assert/strict";
import test from "node:test";
import { harness } from "./harness.ts";
import { meshRegistration, meshRelayMessage } from "../src/mesh-relay-registry.ts";

test("global mesh enrollment is atomic, addresses are signed, and revocation prevents replay", async () => {
  const h = await harness();
  try {
    const admin = (path: string, input: unknown) => h.fetch(`/v1/admin/relays/${path}`, { method:"POST", headers:{authorization:`Bearer ${h.adminToken}`,"content-type":"application/json"},body:JSON.stringify(input) });
    const token = async () => {
      const response = await admin("mesh-token",{name:"mesh test"});
      assert.equal(response.status,200);
      const result = await response.json() as any;
      assert.equal(result.invitation.origin,h.origin);
      assert.ok(result.invitation.relays.length > 0);
      assert.equal(result.command,"mesh-relay --global DATA_DIRECTORY INVITATION_JSON_FILE");
      return result.invitation.token as string;
    };
    const key = await crypto.subtle.generateKey({name:"Ed25519"},true,["sign","verify"]) as CryptoKeyPair;
    const node = Buffer.from(await crypto.subtle.exportKey("raw",key.publicKey) as ArrayBuffer).toString("hex");
    const address = {id:node,addrs:[{Ip:"127.0.0.1:4567"}]};
    const signed = async (value: unknown) => {
      const body = JSON.stringify(value);
      const signature = Buffer.from(await crypto.subtle.sign("Ed25519",key.privateKey,new TextEncoder().encode(meshRelayMessage(h.origin,body)))).toString("hex");
      return {body,signature};
    };
    const post = (path: string,input: unknown) => h.fetch(`/v1/relays/mesh/${path}`,{method:"POST",headers:{"content-type":"application/json"},body:JSON.stringify(input)});
    const list = async () => (await (await h.fetch("/v1/relays/mesh")).json() as any).relays;
    const invite = await token();
    const request = await signed({node,token:invite,revision:1,address});
    assert.equal((await post("enroll",{...request,signature:"00".repeat(64)})).status,401);
    const concurrent = await Promise.all([post("enroll",request),post("enroll",request)]);
    assert.deepEqual(concurrent.map(r=>r.status).sort(),[200,403]);
    assert.deepEqual(await list(),[{node,name:"mesh test",generation:1,revision:1,address}]);
    const watchBody = JSON.stringify({node,generation:1,at:Date.now()});
    const watchSignature = Buffer.from(await crypto.subtle.sign("Ed25519",key.privateKey,new TextEncoder().encode(watchMessage(h.origin,watchBody)))).toString("hex");
    const watchReply = await post("events",{body:watchBody,signature:watchSignature});
    assert.equal(watchReply.status,200);
    const reader = watchReply.body!.getReader();
    let buffered = "";
    const decoder = new TextDecoder();
    const next = async () => {
      while (!buffered.includes("\n")) {
        const chunk = await reader.read();
        assert.equal(chunk.done,false,"subscription ended before its next snapshot");
        buffered += decoder.decode(chunk.value,{stream:true});
      }
      const end = buffered.indexOf("\n");
      const value = JSON.parse(buffered.slice(0,end)); buffered = buffered.slice(end+1);
      return value;
    };
    assert.equal((await next()).relays[0].revision,1);
    assert.equal((await post("events",{body:watchBody,signature:watchSignature})).status,429,"a captured watch proof cannot open another stream");
    const update = await signed({node,generation:1,revision:2,address:{...address,addrs:[{Ip:"127.0.0.1:4568"}]}});
    assert.equal((await post("address",update)).status,200);
    assert.equal((await next()).relays[0].revision,2);
    assert.equal((await post("address",update)).status,409);
    const wrongCloud = {...update, signature:Buffer.from(await crypto.subtle.sign("Ed25519",key.privateKey,new TextEncoder().encode(meshRelayMessage("https://other.example",update.body)))).toString("hex")};
    assert.equal((await post("address",wrongCloud)).status,401);
    const removed = await admin("mesh-remove",{node});
    assert.equal(removed.status,200,await removed.text());
    const operator = h.as(await h.login("alice"), "admin");
    const auditResponse = await operator("GET", "/v1/admin/audit");
    assert.equal(auditResponse.status, 200);
    const audit = (await auditResponse.json() as any).audit;
    assert.ok(audit.some((entry: any) => entry.action === "relay.token" && entry.target === "mesh test"));
    assert.ok(audit.some((entry: any) => entry.action === "relay.remove" && entry.target === node));
    assert.equal(JSON.stringify(audit).includes(invite), false, "audit must not contain enrollment tokens");
    assert.deepEqual(await list(),[]);
    assert.deepEqual((await next()).relays,[]);
    assert.equal((await reader.read()).done,true);
    assert.equal((await post("address",await signed({node,generation:1,revision:3,address}))).status,403);
    assert.equal((await post("enroll",await signed({node,token:await token(),revision:1,address}))).status,200);
    assert.equal((await list())[0].generation,2);
    assert.equal((await post("address",await signed({node,generation:1,revision:100,address}))).status,403);
    assert.equal((await post("address",await signed({node,generation:2,revision:2,address}))).status,200);
    const listing = await (await admin("list",{})).json() as any;
    assert.equal(listing.mesh[0].node,node);
    assert.equal(listing.tokens.length,0,"consumed tokens are not retained");
  } finally { await h.close(); }
});

test("bootstrap addresses cannot contain custom routes, DNS sockets, or excessive data", () => {
  const node = "ab".repeat(32);
  const value = {node,revision:1,token:"x".repeat(32),address:{id:node,addrs:[{Ip:"[::1]:1234"}]}};
  assert.ok(meshRegistration(JSON.stringify(value),true,false));
  for (const addr of [{Custom:{id:1}},{Ip:"host.example:1234"},{Ip:"127.0.0.1:0"},{Ip:"127.0.0.1:65536"},{Relay:"http://relay.example"}]) {
    assert.equal(meshRegistration(JSON.stringify({...value,address:{id:node,addrs:[addr]}}),true,false),null);
  }
  assert.equal(meshRegistration(JSON.stringify({...value,address:{id:node,addrs:Array(9).fill({Ip:"127.0.0.1:1"})}}),true,false),null);
  assert.equal(meshRegistration("x".repeat(8193),true,false),null);
});
