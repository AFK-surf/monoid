// Real Node enrollment/watch handlers and the Rust relay executable on QUIC.
// Directory application is observed through a test endpoint; this test does not
// claim to verify the native front's forwarding or browser entry.
import assert from "node:assert/strict";
import { test } from "node:test";
import { spawn } from "node:child_process";
import { createPrivateKey, createPublicKey, sign } from "node:crypto";
import { watch } from "node:fs";
import { mkdtemp, mkdir, writeFile, readFile, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { DatabaseSync } from "node:sqlite";
import { loadMesh } from "../src/mesh/native.ts";
import type { Endpoint, MeshDescriptor } from "../src/mesh/endpoint.ts";
import { EnrollmentDoor, ENROLLMENT_ALPN, workspaceScope } from "../src/mesh/enrollment-door.ts";
import { RelayEnrollment } from "../src/mesh/enrollment.ts";
import { RelayRecords } from "../src/mesh/relay-records.ts";
import { ScopeSync } from "../src/mesh/scope-sync.ts";
import { watchRelay } from "../src/mesh/relay-watch.ts";
import { wall } from "../src/ops/fibers.ts";

function key(seed: number) {
  const privateKey = createPrivateKey({ key: Buffer.concat([Buffer.from("302e020100300506032b657004220420", "hex"), Buffer.alloc(32,seed)]), format: "der", type: "pkcs8" });
  return { id: createPublicKey(privateKey).export({ format:"der",type:"spki" }).subarray(-32).toString("hex"),
    sign: (body: string) => sign(null,Buffer.from(body),privateKey).toString("hex"), privateKey };
}
test("Rust relay enrolls through Node, receives its directory and obeys revocation", { timeout: 45_000 }, async (t) => {
  const binary = process.env.STILLFAIL_MESH_RELAY_BIN;
  assert.ok(binary, "build mesh-relay and set STILLFAIL_MESH_RELAY_BIN");
  const data = await mkdtemp(join(tmpdir(),"mesh-node-relay-"));
  const db = new DatabaseSync(":memory:");
  const issuer = key(70), neighbor = key(72);
  const endpoint = await loadMesh().bind({ secretKey: Buffer.alloc(32,70), alpns:[ENROLLMENT_ALPN], relayUrls:[], discovery:false, bindAddr:"127.0.0.1:0" });
  assert.equal(endpoint.id(),issuer.id);
  const workspace = "ws", origin = "https://example.test", scope = workspaceScope(origin,workspace);
  const membership = { workspace, peers:[] };
  const cloud = { data, peersCurrent:true, state:{ origin, station:issuer.id }, relays:()=>[], waysSaid:()=>null,
    memberships:()=>[membership], fullMemberships:()=>[membership], membership:(ws:string)=>ws===workspace?membership:null, listen:()=>()=>{},
  } as unknown as import("../src/cloud/state.ts").Cloud;
  const generation = Buffer.alloc(8); generation.writeBigUInt64BE(1n);
  const binding = { policy:[...Buffer.alloc(32)], scope:[...Buffer.from(scope,"hex")], endpoint:[...Buffer.from(issuer.id,"hex")], neighbor:[...Buffer.from(neighbor.id,"hex")], generation:1, transit:true, signature:[] as number[] };
  binding.signature = [...sign(null,Buffer.concat([Buffer.from("mesh-neighbor-binding/v2\0"),Buffer.from(binding.scope),Buffer.from(binding.policy),Buffer.from(binding.endpoint),Buffer.from(binding.neighbor),generation,Buffer.from([1])]),issuer.privateKey)];
  const descriptor: MeshDescriptor = { binding, address:{ id:neighbor.id, addrs:[] } };
  let joined!: (node: string) => void;
  const ready = new Promise<string>((resolve)=>{ joined=resolve; });
  const configuration = { meshConfigure:async (value:any)=> {
    const relay = value.peers.find((peer: MeshDescriptor) => Buffer.from(peer.binding.endpoint).toString("hex")!==issuer.id);
    if(relay) joined(Buffer.from(relay.binding.endpoint).toString("hex"));
    return descriptor;
  },meshRemove:async()=>{} } as unknown as Endpoint;
  const read = async (args:any) => JSON.stringify(args.kind==="relayRecords"
    ? db.prepare("SELECT body,signature FROM mesh_relay_records WHERE scope=?").all(args.scope)
    : db.prepare("SELECT body,signature FROM mesh_announcements WHERE scope=?").all(args.scope).filter((row:any)=>args.nodes.includes(JSON.parse(row.body).node)));
  const sync = new ScopeSync(configuration,db,cloud,issuer,async()=>{ throw new Error("unknown method"); },read);
  const registry = new RelayEnrollment(db,issuer.id,wall.now);
  const records = new RelayRecords(db);
  const door = new EnrollmentDoor(registry,(s)=>s===scope,issuer.sign,
    async(s,node)=>db.prepare("SELECT revoked,made_by,name,generation,issuer,node,scope FROM mesh_relay_registrations WHERE scope=? AND node=? AND revoked=0").get(s,node) as any ?? null,
    async(signed)=>{ records.take(signed,scope,new Set([issuer.id])); await sync.registration(signed); },
    (s,node,first,stream,conn,reader)=>watchRelay(sync,s,node,first,stream,conn,reader));
  const serving = new Set<Promise<void>>();
  const accept = (async()=>{
    for (;;) {
      const conn = await endpoint.accept(); if(!conn) break;
      const task = door.serve(conn).catch((error)=>{ console.error("enrollment handler:",String(error)); }); serving.add(task); void task.finally(()=>serving.delete(task));
    }
  })();
  const invite = registry.issue(scope,"actual relay","side test");
  const path = join(data,"invite.json");
  await writeFile(path,JSON.stringify({ ...invite, endpoint:{ id:issuer.id,relays:[],ips:endpoint.sockets() } }),{mode:0o600});
  await mkdir(join(data,"relay"),{mode:0o700});
  let savedSnapshot!: (value:any)=>void;
  const snapshotSaved = new Promise<any>((resolve)=>{savedSnapshot=resolve;});
  const stateWatch = watch(join(data,"relay"),(_event,name)=>{
    if(String(name)!=="state.json")return;
    void readFile(join(data,"relay","state.json"),"utf8").then((text)=>{
      const saved=JSON.parse(text); if(saved.snapshot)savedSnapshot(saved.snapshot);
    }).catch(()=>{});
  });
  const child = spawn(binary,[join(data,"relay"),path],{stdio:["ignore","ignore","pipe"]});
  let stderr=""; child.stderr.on("data",(bytes)=>{stderr+=String(bytes); if(stderr.length>64*1024)stderr=stderr.slice(-64*1024);});
  const ended = new Promise<number|null>((resolve,reject)=>{child.once("exit",resolve);child.once("error",reject);});
  t.after(async()=>{stateWatch.close();if(child.exitCode===null)child.kill("SIGKILL");await ended.catch(()=>{});await endpoint.close();await accept;await Promise.allSettled([...serving]);await sync.close();db.close();await rm(data,{recursive:true,force:true});});
  const node = await wall.within(25_000,Promise.race([ready,ended.then((code)=>{throw new Error(`relay ended ${code}: ${stderr}`);})]),"relay never joined native directory").catch((error)=>{throw new Error(`${String(error)}; relay stderr: ${stderr}`);});
  assert.equal((sync.relays(workspace)[0] as any).node,node);
  const before = JSON.parse(await readFile(join(data,"relay","state.json"),"utf8"));
  assert.equal(before.invitation.token,"");
  const snapshot = await wall.within(10_000,snapshotSaved,"Rust relay did not accept and persist the Node directory");
  assert.ok(snapshot.policy.nodes.includes(node));
  assert.ok(snapshot.records.some((record:any)=>JSON.parse(record.body).node===node));
  assert.equal(snapshot.policy.generations[node],1);
  await sync.revoke(workspace,node);
  assert.equal(await wall.within(15_000,ended,"revoked relay did not exit"),1,stderr);
  const after = JSON.parse(await readFile(join(data,"relay","state.json"),"utf8"));
  assert.equal(after.registration,null);assert.equal(after.snapshot,null);
  assert.equal(sync.directory.ready(scope,node),false);
});
