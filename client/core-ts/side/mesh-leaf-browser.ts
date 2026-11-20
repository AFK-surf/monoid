// Real Chromium/WASM + native ingress/forwarder/target. The browser can reach
// only ingress over iroh relay WebSocket; its inner QUIC takes three mesh hops.
import assert from "node:assert/strict";
import { test } from "node:test";
import { spawn } from "node:child_process";
import { randomBytes } from "node:crypto";
import { createServer } from "node:http";
import { mkdtemp, readFile, writeFile, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { createRequire } from "node:module";
import { build } from "esbuild";
import type { IrohMeshDescriptor } from "../src/iroh.ts";
import { loadAddon } from "../src/hosts/node-iroh.ts";
import { Cloud, writeState } from "../../../station/src/cloud/state.ts";
import { GrantKey } from "../../../station/test/fake-control-plane.ts";
import { serve } from "../../../station/src/mesh/serve.ts";
import { LeafAttachments } from "../../../station/src/mesh/leaf.ts";
import { workspaceScope } from "../../../station/src/mesh/enrollment-door.ts";

const requireRoot=createRequire(new URL("../../../package.json",import.meta.url));
const {chromium}=requireRoot("playwright-core");
const origin="https://mesh.invalid", workspace="01HZZZZZZZZZZZZZZZZZZZZZZZ";
const scope=workspaceScope(origin,workspace);
const alpn=Buffer.from("mesh-browser-side/1");
const pause=(ms:number)=>new Promise(r=>setTimeout(r,ms));
const root=resolve(import.meta.dirname,"../../..");
const pkg=process.env.MESH_WASM_PKG || join(root,"web/src/core/iroh-pkg");
const adjacent=(d:any,yes:boolean)=>{
  const ip=d.address.addrs.find((a:any)=>a.Ip&&!a.Ip.startsWith("["))?.Ip;
  assert.ok(ip,"native scope IPv4 address");
  return {...d,address:{id:d.address.id,addrs:yes?[{Ip:`127.0.0.1:${ip.split(":").at(-1)}`}]:[]}};
};

test("browser core authenticates target across ingress and forwarder and loses detached route",{timeout:90_000},async t=>{
  const cleanups:(()=>unknown|Promise<unknown>)[]=[];
  const after=(f:()=>unknown|Promise<unknown>)=>{cleanups.push(f);};
  t.after(async()=>{for(const cleanup of cleanups.reverse())await cleanup();});
  const addon=loadAddon();assert.ok(addon,"build mesh addon for this side test");
  const temp=await mkdtemp(join(tmpdir(),"mesh-browser-"));
  after(()=>rm(temp,{recursive:true,force:true}));
  const externalRelay=process.env.MESH_BROWSER_RELAY_URL;
  let relay:string;
  if(externalRelay){
    const url=new URL(externalRelay);
    // This side run uses the existing workspace-approved relay; it never deploys one.
    assert.equal(url.href,"https://34.146.162.106/","use the approved HTTPS relay exactly");
    relay=url.href;
  }else{
    assert.ok(process.env.STILLFAIL_RELAY_BIN,"build iroh-relay for this side test");
    const reserve=createServer();await new Promise<void>(r=>reserve.listen(0,"127.0.0.1",r));
    const port=(reserve.address() as {port:number}).port;await new Promise<void>(r=>reserve.close(()=>r()));
    relay=`http://127.0.0.1:${port}/`;
    await writeFile(join(temp,"relay.toml"),`enable_relay = true\nhttp_bind_addr = "127.0.0.1:${port}"\nenable_metrics = false\nenable_quic_addr_discovery = false\n`);
    const child=spawn(process.env.STILLFAIL_RELAY_BIN!,["--dev","--config-path",join(temp,"relay.toml")],{stdio:"inherit"});
    after(()=>child.kill("SIGKILL"));
    const deadline=Date.now()+10_000;
    while(!await fetch(relay).then(()=>true,()=>false)){assert.ok(Date.now()<deadline,"local relay starts");await pause(25);}
  }
  const nodes:any[]=[];
  after(async()=>{await Promise.all(nodes.map(n=>n.close()));});
  for(let i=0;i<3;i++)nodes.push(await addon.bind({secretKey:randomBytes(32),alpns:[alpn],relayUrls:i===0?[relay]:[],lookup:false,discovery:false}));
  const descriptors:(IrohMeshDescriptor & {address:{id:string;addrs:unknown[]}})[]=[];
  for(const n of nodes)descriptors.push(await n.meshConfigure({scope,transit:true,peers:[],relayUrls:[relay]}));
  for(let i=0;i<nodes.length;i++)await nodes[i].meshConfigure({scope,transit:true,relayUrls:[relay],peers:descriptors.flatMap((d,j)=>i===j?[]:[adjacent(d,Math.abs(i-j)===1)])});
  const ingress=descriptors[0];
  const grant=new GrantKey("mesh-browser");
  let targetRequests=0;
  let heldReady!:()=>void;const heldArrived=new Promise<void>(resolve=>{heldReady=resolve;});
  for(const i of [0,2]) {
    const data=join(temp,`station-${i}`);
    writeState(data,{origin,station:nodes[i].id(),workspace,workspace_name:"Mesh",name:`station-${i}`,relay_url:relay,relay_urls:[relay],grant_keys:{keys:[grant.jwk]},peers:nodes.filter((_,j)=>j!==i).map(n=>({id:n.id(),name:"peer"})),revocations:[]} as any);
    const cloud=new Cloud(data);after(()=>cloud.close());
    const directory={directory:{policy:()=>({nodes:nodes.map(n=>n.id()),relayUrls:[relay],globalRelays:[]}),records:()=>descriptors.map(descriptor=>({body:JSON.stringify({descriptor})}))},listen:()=>()=>{}};
    const leaves=new LeafAttachments(nodes[i],directory as any,cloud);
    if(i===2){const view=leaves.view.bind(leaves);leaves.view=(w:string)=>{targetRequests++;return view(w);};}
    void (async()=>{for(;;){const conn=await nodes[i].accept();if(!conn)return;void serve({cloud,leaves,admin:undefined as any,up:()=>true,streams:(head:any)=>{if(i===2&&head.headers?.["leaf-held"]==="1")heldReady();return undefined;}},conn).catch(e=>console.log("member ended:",String(e)));}})();
  }
  const peers=descriptors.map((d,i)=>({...d,address:{id:d.address.id,addrs:i===0?[{Relay:relay}]:[]}}));
  const bundled=await build({stdin:{contents:`
    import {Effect} from "effect";
    import {wrapIroh} from "./src/iroh-bindings.ts";
    const wasm=await import("/wasm/stillfail_iroh_wasm.js");await wasm.default();
    const run=Effect.runPromise;const iroh=wrapIroh(wasm.bind,b=>b);
    const line=async stream=>{let value="";for(;;){const bytes=await run(stream.read());if(bytes===null)throw Error("stream ended before line");value+=new TextDecoder().decode(bytes);const at=value.indexOf("\\n");if(at>=0)return JSON.parse(value.slice(0,at));}};
    const hello=async(conn,credential)=>{const control=await run(conn.openBi());await run(control.write(new TextEncoder().encode(JSON.stringify({credential,protocol:2})+"\\n")));return line(control);};
    const request=async(conn,method,body)=>{const stream=await run(conn.openBi());await run(stream.write(new TextEncoder().encode(JSON.stringify({method,path:"/admin/api/mesh/leaf",headers:{"stillfail-build":"0.1.0"}})+"\\n"+(body?JSON.stringify(body):""))));await run(stream.finish());let text="";for(;;){const bytes=await run(stream.read());if(bytes===null)break;text+=new TextDecoder().decode(bytes);}const at=text.indexOf("\\n");return {head:JSON.parse(text.slice(0,at)),body:JSON.parse(text.slice(at+1))};};
    globalThis.meshTest={run,iroh,hello,request};`,resolveDir:resolve(root,"client/core-ts")},bundle:true,format:"esm",platform:"browser",write:false,external:["/wasm/*"]});
  const server=createServer(async(req,res)=>{
    try {
      if(req.url==="/entry.js"){res.setHeader("Content-Type","text/javascript");res.end(bundled.outputFiles[0].contents);}
      else if(req.url?.startsWith("/wasm/")){
        const name=req.url.slice(6);if(!/^[a-zA-Z0-9_.]+$/.test(name))throw Error("bad path");
        res.setHeader("Content-Type",name.endsWith(".wasm")?"application/wasm":"text/javascript");res.end(await readFile(join(pkg,name)));
      }else{res.setHeader("Content-Type","text/html");res.end('<script type="module" src="/entry.js"></script>');}
    }catch(e){res.statusCode=500;res.end(String(e));}
  });
  await new Promise<void>(r=>server.listen(0,"127.0.0.1",r));after(()=>new Promise<void>(r=>server.close(()=>r())));
  const browser=await chromium.launch({headless:true,...(process.env.CHROME_BIN?{executablePath:process.env.CHROME_BIN}:{channel:"chrome"})});after(()=>browser.close());
  const sockets:{url:string;sent:number;received:number}[]=[];
  const page=await browser.newPage();
  page.on("websocket",(socket:{url():string;on(event:"framesent"|"framereceived",f:()=>void):void})=>{
    const url=new URL(socket.url());
    const record={url:url.origin+url.pathname,sent:0,received:0};sockets.push(record);
    socket.on("framesent",()=>record.sent++);socket.on("framereceived",()=>record.received++);
  });page.on("console",(m:any)=>console.log("browser:",m.text()));page.on("pageerror",(e:any)=>console.error(e));
  await page.goto(`http://127.0.0.1:${(server.address() as {port:number}).port}/`);await page.waitForFunction(()=>!!(globalThis as any).meshTest);
  const leaf=await page.evaluate(async({relay,scope,peers}:any)=>{
    const s=(globalThis as any).meshTest;
    s.endpoint=await s.run(s.iroh.bind({secretKey:crypto.getRandomValues(new Uint8Array(32)),relayUrls:[relay]}));
    const descriptor=await s.run(s.endpoint.meshConfigure({scope,transit:false,relayUrls:[relay],peers}));
    return {id:s.endpoint.id(),descriptor};
  },{relay,scope,peers});
  const now=Math.floor(Date.now()/1000);
  const credential=grant.credential({typ:"stillfail-member+jwt"},{iss:"stillfail-cloud",sub:"usr_mesh",email:"mesh@example.invalid",name:"Mesh",ws:workspace,role:"owner",device:leaf.id,sid:"mesh",iat:now,exp:now+3600});
  const targetId=nodes[2].id();
  const attachment=await page.evaluate(async({relay,scope,descriptor,ingressId,targetId,alpn,credential}:any)=>{
    const s=(globalThis as any).meshTest;
    s.connection=await s.run(s.endpoint.connect({id:ingressId,relays:[relay]},new Uint8Array(alpn),[]));
    const hello=await s.hello(s.connection,credential);if(!hello.ok||!hello.meshLeaf)throw Error(JSON.stringify(hello));
    const response=await s.request(s.connection,"POST",{target:targetId,descriptor});if(response.head.status!==200)throw Error(JSON.stringify(response));
    await s.run(s.endpoint.meshUseLeaf({scope,attachment:response.body.attachment}));return response.body.attachment;
  },{relay,scope,descriptor:leaf.descriptor,ingressId:nodes[0].id(),targetId,alpn:[...alpn],credential});
  const result=await page.evaluate(async({scope,targetId,alpn,credential}:any)=>{
    const s=(globalThis as any).meshTest;
    const refused=await s.run(s.endpoint.connect({id:targetId,meshScope:scope},new Uint8Array(alpn),[]));
    const denied=await s.hello(refused,"invalid credential");refused.close(0,"checked refusal");
    s.target=await s.run(s.endpoint.connect({id:targetId,meshScope:scope},new Uint8Array(alpn),[]));
    const admitted=await s.hello(s.target,credential);
    const reply=await s.request(s.target,"GET");
    return {root:s.target.remoteId(),denied:!!denied.error,admitted:admitted.ok,status:reply.head.status,scope:reply.body.scope};
  },{scope,targetId,alpn:[...alpn],credential});
  assert.deepEqual(result,{root:targetId,denied:true,admitted:true,status:200,scope});
  await page.evaluate(async()=>{const s=(globalThis as any).meshTest;s.held=await s.run(s.target.openBi());await s.run(s.held.write(new TextEncoder().encode(JSON.stringify({method:"GET",path:"/admin/api/mesh/leaf",headers:{"stillfail-build":"0.1.0","leaf-held":"1"}})+"\n")));});
  await heldArrived;
  const beforeDetach=targetRequests;
  await nodes[0].meshDetachLeaf({scope,attachmentId:attachment.id});
  await page.evaluate(()=>{const s=(globalThis as any).meshTest;void s.run(s.held.finish()).catch(()=>{});});
  await pause(750);
  assert.equal(targetRequests,beforeDetach,"detached ingress blocks completion of the already open application stream");
  await page.evaluate(async({scope}:any)=>{const s=(globalThis as any).meshTest;await s.run(s.endpoint.meshRemove(scope));await s.run(s.endpoint.close());},{scope});
  if(externalRelay){
    for(const socket of sockets){
      const url=new URL(socket.url);assert.equal(url.protocol,"wss:");assert.equal(url.host,new URL(relay).host);
    }
    assert.ok(sockets.some(s=>s.sent>0&&s.received>0),"actual WSS frames crossed the approved relay");
  }
  console.log(JSON.stringify({webSockets:sockets,browserLeaf:leaf.id,ingress:ingress.binding.endpoint,target:targetId,hops:3,e2e:true,memberCredential:true,invalidCredentialRefused:true}));
});
