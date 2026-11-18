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
  const own={body:JSON.stringify({descriptor:{binding:issuer,address:{id:station,addrs:[]}}})};
  const other={body:JSON.stringify({descriptor:{binding:{...issuer,endpoint:[...Buffer.from(target,"hex")]},address:{id:target,addrs:[]}}})};
  const scopeState={ready:true,records:[own,other]};
  const directory={directory:{policy:()=>policy,records:()=>scopeState.records,ready:(s:string,node:string)=>scopeState.ready&&s===scope&&node===station},listen:()=>()=>{}} as unknown as ScopeSync;
  let closed=false;
  const connection={remoteId:()=>leaf,isClosed:()=>closed} as unknown as Connection;
  const service=new LeafAttachments(endpoint,directory,cloud);
  service.authenticated(connection,workspace,9);
  return {service,connection,descriptor,finish:()=>finish(attachment),membership,policy,detached,close:()=>{closed=true;},scopeState,own,other};
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

for(const renewal of ["the same credential","a renewed one"] as const) test(`a ping with ${renewal} while native attachment is awaited keeps the grant`,async()=>{
  const f=fixture();
  const response=f.service.attach(f.connection,workspace,f.descriptor,target);
  f.service.authenticated(f.connection,workspace,renewal==="the same credential"?9:309);
  f.finish();
  const {attachment}=await response;
  assert.deepEqual(attachment.id,Array(32).fill(4));
  assert.deepEqual(f.detached,[]);
});
for(const change of ["another workspace","a shorter credential"] as const) test(`a member connection given ${change} while native attachment is awaited withdraws the grant`,async()=>{
  const f=fixture();
  const response=f.service.attach(f.connection,workspace,f.descriptor,target);
  if(change==="another workspace")f.service.authenticated(f.connection,"other",9);
  else f.service.authenticated(f.connection,workspace,8);
  f.finish();
  await assert.rejects(response,/leaf admission changed/);
  assert.deepEqual(f.detached,[{scope,attachmentId:Array(32).fill(4)}]);
});
test("a ping with the same credential writes no view again; a renewal does",async()=>{
  const f=fixture();
  const lines:string[]=[];
  let written=()=>{};
  let stop!:()=>void;
  const stopped=new Promise<void>(resolve=>{stop=resolve;});
  const stream={write:async(b:Buffer)=>{lines.push(b.toString());written();},stopped:()=>stopped,finish:async()=>{}} as never;
  const line=()=>new Promise<void>(resolve=>{written=resolve;});
  let next=line();
  const following=f.service.follow(f.connection,workspace,stream);
  await next;
  for(let i=0;i<3;i++)f.service.authenticated(f.connection,workspace,9);
  // Every turn of the microtasks run: a ping that woke the stream has its line written by now.
  await new Promise(setImmediate);
  assert.equal(lines.length,1);
  next=line();
  f.service.authenticated(f.connection,workspace,309);
  await next;
  stop();
  await following;
  assert.deepEqual(lines.map(l=>JSON.parse(l).credentialExpiresUnixMs),[9000,309000]);
});
for(const state of ["not configured","without its own descriptor"] as const) test(`a scope ${state} on this station gives a device no peers`,()=>{
  const f=fixture();
  assert.equal(f.service.view(workspace).peers.length,2);
  if(state==="not configured")f.scopeState.ready=false;
  else f.scopeState.records=[f.other];
  assert.deepEqual(f.service.view(workspace).peers,[]);
});
