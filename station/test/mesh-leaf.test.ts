import assert from "node:assert/strict";
import { createPrivateKey, createPublicKey, sign } from "node:crypto";
import { test } from "node:test";
import { LeafAttachments } from "../src/mesh/leaf.ts";
import { workspaceScope } from "../src/mesh/enrollment-door.ts";
import type { Cloud } from "../src/cloud/state.ts";
import type { ScopeSync } from "../src/mesh/scope-sync.ts";
import type { Connection, Endpoint, MeshDescriptor, MeshLeafAttachment } from "../src/mesh/endpoint.ts";

const origin="https://example.invalid";
const workspace="leaf-tests";
const scope=workspaceScope(origin,workspace);
const station="41".repeat(32), target="42".repeat(32);
function fixture() {
  const key=createPrivateKey({key:Buffer.concat([Buffer.from("302e020100300506032b657004220420","hex"),Buffer.alloc(32,73)]),format:"der",type:"pkcs8"});
  const leaf=createPublicKey(key).export({format:"der",type:"spki"}).subarray(-32).toString("hex");
  const binding:MeshDescriptor["binding"]={scope:[...Buffer.from(scope,"hex")],policy:Array(32).fill(0),endpoint:[...Buffer.from(leaf,"hex")],neighbor:Array(32).fill(74),generation:1,transit:false,signature:[]};
  const generation=Buffer.alloc(8);generation.writeBigUInt64BE(1n);
  binding.signature=[...sign(null,Buffer.concat([Buffer.from("mesh-neighbor-binding/v2\0"),Buffer.from(binding.scope),Buffer.from(binding.policy),Buffer.from(binding.endpoint),Buffer.from(binding.neighbor),generation,Buffer.from([0])]),key)];
  const descriptor={binding,address:{id:Buffer.from(binding.neighbor).toString("hex"),addrs:[]}};
  const issuer={...binding,endpoint:[...Buffer.from(station,"hex")],transit:true};
  const attachment={scope:binding.scope,policy:binding.policy,issuer,leaf:binding,target:[...Buffer.from(target,"hex")],id:Array(32).fill(4),expires_unix_ms:9000,signature:[]} satisfies MeshLeafAttachment;
  let finish!:(a:MeshLeafAttachment)=>void;
  const pending=new Promise<MeshLeafAttachment>(resolve=>{finish=resolve;});
  const detached:unknown[]=[];
  const endpoint={id:()=>station,meshAttachLeaf:()=>pending,meshDetachLeaf:async(v:unknown)=>{detached.push(v);}} as unknown as Endpoint;
  const membership={peers:[{id:target}]};
  const cloud={state:{origin},membership:()=>membership} as unknown as Cloud;
  const policy={relayUrls:[] as string[],globalRelays:[]};
  const directory={directory:{policy:()=>policy,records:()=>[{body:JSON.stringify({descriptor:{binding:issuer,address:{id:station,addrs:[]}}})}]}} as unknown as ScopeSync;
  let closed=false;
  const connection={remoteId:()=>leaf,isClosed:()=>closed} as unknown as Connection;
  const service=new LeafAttachments(endpoint,directory,cloud);
  service.authenticated(connection,workspace,9);
  return {service,connection,descriptor,finish:()=>finish(attachment),membership,policy,detached,close:()=>{closed=true;}};
}
for(const change of ["target","policy","connection"] as const) test(`leaf admission rechecks ${change} after native attachment and withdraws stale grant`,async()=>{
  const f=fixture();
  const response=f.service.attach(f.connection,workspace,f.descriptor,target);
  if(change==="target")f.membership.peers=[];
  else if(change==="policy")f.policy.relayUrls=["https://changed.invalid/"];
  else f.close();
  f.finish();
  await assert.rejects(response,/leaf admission changed/);
  assert.deepEqual(f.detached,[{scope,attachmentId:Array(32).fill(4)}]);
});
