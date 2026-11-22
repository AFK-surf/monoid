import assert from "node:assert/strict";
import { test } from "node:test";
import { Effect, Fiber, Queue } from "effect";
import { LeafLinks } from "../src/station/mesh-leaf.ts";
import type { IrohEndpoint, IrohLeafAttachment, IrohMeshDescriptor, IrohMeshScope } from "../src/iroh.ts";
import type { Link, Reply } from "../src/mesh.ts";
import { run } from "./run.ts";

const scope="13".repeat(32), ingress="14".repeat(32), target="15".repeat(32);
const bytes=(n:number)=>Array(32).fill(n);
const binding=(n:number,transit:boolean)=>({scope:bytes(19),policy:bytes(0),endpoint:bytes(n),neighbor:bytes(n+1),generation:1,transit,signature:Array(64).fill(0)});
const issuer={binding:binding(20,true),address:{id:ingress,addrs:[]}};
const destination={binding:binding(21,true),address:{id:target,addrs:[]}};
const refusing={binding:binding(25,true),address:{id:"19".repeat(32),addrs:[]}};
const leaf={binding:binding(22,false),address:{id:"16".repeat(32),addrs:[]}} satisfies IrohMeshDescriptor;

async function lifecycle() {
  const events=await run(Queue.unbounded<Uint8Array|null>()),reading=await run(Queue.unbounded<void>());
  const configured:IrohMeshScope[]=[],removed:string[]=[],attached:IrohLeafAttachment[]=[];
  let closed:string|null=null;
  const endpoint={
    meshConfigure:(config:IrohMeshScope)=>Effect.sync(()=>{configured.push(config);return leaf;}),
    meshRemove:(scope:string)=>Effect.sync(()=>{removed.push(scope);}),
    meshUseLeaf:({attachment}:{attachment:IrohLeafAttachment})=>Effect.sync(()=>{attached.push(attachment);}),
    meshDetachLeaf:()=>Effect.void,
  } as unknown as IrohEndpoint;
  const link={answer:{meshLeaf:true},closed:()=>closed,conn:{remoteId:()=>ingress},request:(head:{method:string})=>Effect.gen(function*(){
    if(head.method==="GET")return {status:200,body:{take:Effect.suspend(()=>{Queue.offerUnsafe(reading,undefined);return Queue.take(events);})},cancel:()=>{}} as unknown as Reply;
    const attachment={scope:bytes(19),policy:bytes(0),issuer:issuer.binding,leaf:leaf.binding,target:bytes(21),id:bytes(attached.length+1),expires_unix_ms:9000,signature:[]} satisfies IrohLeafAttachment;
    const response=yield* Queue.unbounded<Uint8Array|null>();
    Queue.offerUnsafe(response,new TextEncoder().encode(JSON.stringify({attachment})));Queue.offerUnsafe(response,null);
    return {status:200,body:{take:Queue.take(response)},cancel:()=>{}} as unknown as Reply;
  })} as unknown as Link;
  const manager=new LeafLinks();
  const following=Effect.runFork(manager.linked(`workspace/${ingress}`,link,endpoint));
  await run(Queue.take(reading));
  return {configured,removed,attached,
    update:async(config:IrohMeshScope)=>{Queue.offerUnsafe(events,new TextEncoder().encode(JSON.stringify(config)+"\n"));await run(Queue.take(reading));},
    prepare:()=>run(manager.prepare(`workspace/${target}`,endpoint)),
    close:async()=>{closed="closed";Queue.offerUnsafe(events,null);await run(Fiber.await(following));},
    interrupt:()=>run(Fiber.interrupt(following)),
  };
}

test("an unused leaf scope never binds or removes an endpoint, including updates and scope changes",async()=>{
  const f=await lifecycle();
  try {
    await f.update({scope,transit:true,relayUrls:[],peers:[issuer]});
    assert.equal(f.configured.length,0,"one connected station needs no inner endpoint");
    await f.update({scope,transit:true,relayUrls:["https://relay.invalid/"],peers:[issuer]});
    await f.update({scope:"23".repeat(32),transit:true,relayUrls:[],peers:[issuer]});
    await f.close();
    assert.deepEqual(f.configured,[]);
    assert.deepEqual(f.removed,[]);
  } finally {await f.interrupt();}
});

test("the first descriptor peer binds once and attaches; updates, scope changes and close release built scopes",async()=>{
  const f=await lifecycle();
  try {
    const config={scope,transit:true,relayUrls:[],peers:[issuer,destination]};
    await f.update(config);
    assert.equal(f.configured.length,0);
    assert.equal(await f.prepare(),scope);
    assert.equal(await f.prepare(),scope);
    assert.equal(f.configured.length,1);
    assert.equal(f.configured[0].transit,false,"a browser cannot become a transit peer");
    assert.equal(f.attached.length,1);
    await f.update({...config,relayUrls:["https://relay.invalid/"]});
    assert.equal(f.configured.length,2);
    assert.equal(f.attached.length,1,"an address update keeps the attachment");
    assert.deepEqual(f.removed,[]);
    const next="23".repeat(32);
    await f.update({...config,scope:next});
    assert.equal(f.configured.length,3);
    assert.equal(f.attached.length,2);
    assert.deepEqual(f.removed,[scope]);
    await f.close();
    assert.deepEqual(f.removed,[scope,next]);
  } finally {await f.interrupt();}
});

test("unrelated address updates preserve a live attachment; issuer generation change replaces it",async()=>{
  const events=await run(Queue.unbounded<Uint8Array|null>()), reading=await run(Queue.unbounded<void>());
  const legacy="17".repeat(32);
  let current:IrohMeshScope & {stations?:string[]}={scope,transit:false,relayUrls:[],peers:[issuer,destination,refusing],stations:[ingress,target,legacy]};
  let signed=0,detached=0,refused=0;
  const endpoint={
    meshConfigure:(config:IrohMeshScope)=>Effect.sync(()=>{current=config;return leaf;}),
    meshRemove:()=>Effect.void,
    meshUseLeaf:()=>Effect.void,
    meshDetachLeaf:()=>Effect.sync(()=>{detached++;}),
  } as unknown as IrohEndpoint;
  const link={answer:{meshLeaf:true},closed:()=>null,conn:{remoteId:()=>ingress},request:(head:{method:string},body?:Uint8Array)=>Effect.gen(function*(){
    if(head.method==="GET")return {status:200,body:{take:Effect.suspend(()=>{Queue.offerUnsafe(reading,undefined);return Queue.take(events);})},cancel:()=>{}} as unknown as Reply;
    if((JSON.parse(new TextDecoder().decode(body)) as {target:string}).target==="19".repeat(32)){
      refused++;const none=yield* Queue.unbounded<Uint8Array|null>();Queue.offerUnsafe(none,null);
      return {status:403,body:{take:Queue.take(none)},cancel:()=>{}} as unknown as Reply;
    }
    signed++;
    const attachment={scope:bytes(19),policy:bytes(0),issuer:current.peers[0].binding,leaf:leaf.binding,target:bytes(21),id:bytes(signed),expires_unix_ms:9000,signature:[]} satisfies IrohLeafAttachment;
    const response=yield* Queue.unbounded<Uint8Array|null>();
    Queue.offerUnsafe(response,new TextEncoder().encode(JSON.stringify({attachment})));Queue.offerUnsafe(response,null);
    return {status:200,body:{take:Queue.take(response)},cancel:()=>{}} as unknown as Reply;
  })} as unknown as Link;
  const manager=new LeafLinks();
  const following=Effect.runFork(manager.linked(`workspace/${ingress}`,link,endpoint));
  const update=async(config:IrohMeshScope)=>{
    Queue.offerUnsafe(events,new TextEncoder().encode(JSON.stringify(config)+"\n"));
    await run(Queue.take(reading));
    await run(manager.prepare(`workspace/${target}`,endpoint));
  };
  try {
    await run(Queue.take(reading));
    await update(current);assert.deepEqual([signed,detached],[1,0]);
    assert.equal(await run(manager.prepare(`workspace/${legacy}`,endpoint)),undefined,"admitted old station without descriptor retains legacy dial");
    assert.deepEqual([signed,detached],[1,0],"legacy compatibility asks for no attachment");
    assert.equal(await run(manager.prepare(`workspace/${"18".repeat(32)}`,endpoint)),undefined,"a station without a descriptor here (not yet in the lock, not protected, not yet synced) is dialled as before");
    assert.deepEqual([signed,detached,refused],[1,0,0],"dialling it as before asks this station for no attachment");
    await assert.rejects(run(manager.prepare(`workspace/${"19".repeat(32)}`,endpoint)),/leaf admission refused \(403\)/,"a refused descriptor-bearing peer is never downgraded");
    assert.deepEqual([signed,detached,refused],[1,0,1]);
    await update({...current,peers:[{...issuer,address:{id:ingress,addrs:[{Ip:"127.0.0.1:99"}]}},destination]});
    assert.deepEqual([signed,detached],[1,0],"ordinary address update neither revokes nor asks for a new attachment");
    await update({...current,peers:[{...issuer,binding:{...issuer.binding,generation:2}},destination]});
    assert.deepEqual([signed,detached],[2,1],"issuer generation change withdraws the old attachment");
  }finally{await run(Fiber.interrupt(following));}
});
