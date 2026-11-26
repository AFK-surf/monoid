// A leaf scope is learned from a station that admitted this device. Its stream
// pushes policy changes; only targets actually dialled get an attachment.
import { Deferred, Effect, Schedule, Semaphore } from "effect";
import { CoreError } from "../error.ts";
import type { IrohEndpoint, IrohLeafAttachment, IrohMeshDescriptor, IrohMeshScope } from "../iroh.ts";
import type { Link, MeshEnv, Reply } from "../mesh.ts";
import type { PrepareTrace } from "../record.ts";
import { fromUtf8, hex, utf8 } from "../util.ts";
import { BUILD_HEADER, ownBuild } from "./oldest.ts";

const LIMIT=1024*1024;
type LeafConfig=IrohMeshScope & { credentialExpiresUnixMs?:number;stations?:string[] };
const sameBytes=(a:readonly number[],b:readonly number[])=>a.length===b.length && a.every((v,i)=>v===b[i]);
const error=(e:unknown)=>new CoreError("mesh",e instanceof Error?e.message:String(e));
const native=<A>(e:Effect.Effect<A,unknown>)=>Effect.mapError(e,error);
const head=(method:string,path:string)=>({method,path:`/admin/api/mesh/leaf${path}`,headers:[[BUILD_HEADER,ownBuild()||"0.1.0"]] as [string,string][]});
function json(reply:Reply):Effect.Effect<unknown,CoreError> {
  return Effect.gen(function*(){
    const chunks:Uint8Array[]=[];let length=0;
    for (;;) {const part=yield* native(reply.body.take);if(part===null)break;length+=part.length;if(length>LIMIT)return yield* Effect.fail(error("leaf response exceeds bound"));chunks.push(part);}
    if(reply.status!==200)return yield* Effect.fail(error(`leaf admission refused (${reply.status})`));
    const bytes=new Uint8Array(length);let at=0;for(const part of chunks){bytes.set(part,at);at+=part.length;}
    return yield* Effect.try({try:()=>JSON.parse(fromUtf8(bytes)) as unknown,catch:error});
  }).pipe(Effect.ensuring(Effect.sync(()=>reply.cancel())));
}
type State={link:Link;endpoint:IrohEndpoint;config:LeafConfig|null;descriptor:IrohMeshDescriptor|null;attachments:Map<string,IrohLeafAttachment>;lock:ReturnType<typeof Semaphore.makeUnsafe>;lockHolder:string|null;done:Deferred.Deferred<void>};
export class LeafLinks {
  readonly #held=new WeakMap<IrohEndpoint,Map<string,State>>();
  readonly prepare:NonNullable<MeshEnv["prepare"]>=(address,endpoint,trace)=>Effect.gen({self:this},function*(){
    const at=address.indexOf("/");
    if(at<1){if(trace)trace.stage="skip:addr";return undefined;}
    const state=this.#held.get(endpoint)?.get(address.slice(0,at));
    if(!state){if(trace)trace.stage="skip:no-state";return undefined;}
    if(trace)trace.ingress=state.link.conn.remoteId().slice(0,8);
    if(!state.config){if(trace)trace.stage="skip:no-config";return undefined;}
    if(state.link.closed()!==null){if(trace)trace.stage="skip:closed";return undefined;}
    const target=address.slice(at+1);
    if(target===state.link.conn.remoteId()){if(trace)trace.stage="skip:self";return undefined;}
    // A target without a descriptor here is dialled as before, not through this
    // station: an older station, one enrolled but not yet in the lock, one not
    // protected, or one this station has not yet heard of from the cloud. This
    // station grants no access and may not refuse a device's dial to another
    // (the lock guards against stations): the TLS endpoint key and the core's
    // own lock rules authenticate the target. A descriptor-bearing peer always
    // attaches, and a signing or policy failure there is never downgraded.
    if(!state.config.peers.some(p=>hex(new Uint8Array(p.binding.endpoint))===target)){if(trace)trace.stage="skip:no-peer";return undefined;}
    const lockAt=trace?.now();
    if(trace){trace.stage="lock";if(state.lockHolder)trace.heldBy=state.lockHolder;}
    return yield* state.lock.withPermits(1)(Effect.gen({self:this},function*(){
      if(trace&&lockAt!==undefined)trace.lockMs=Math.max(0,trace.now()-lockAt);
      state.lockHolder=`prepare:${target.slice(0,8)}`;
      if(!state.config || state.link.closed()!==null){if(trace)trace.stage="skip:closed-after-lock";return undefined;}
      // Binding opens relay sockets. Keep an unused workspace's policy alone
      // until a descriptor-bearing peer needs its authenticated inner route.
      if(!state.descriptor){
        const cfgAt=trace?.now();
        if(trace)trace.stage="configure";
        state.descriptor=yield* native(state.endpoint.meshConfigure!({...state.config,transit:false}));
        if(trace&&cfgAt!==undefined)trace.configureMs=Math.max(0,trace.now()-cfgAt);
      }
      return yield* this.#attach(state,target,trace);
    }).pipe(Effect.ensuring(Effect.sync(()=>{state.lockHolder=null;}))));
  });
  #attach(state:State,target:string,trace?:PrepareTrace):Effect.Effect<string|undefined,CoreError>{
    return Effect.gen(function*(){
      if(!state.config || !state.descriptor || state.link.closed()!==null){if(trace)trace.stage="skip:closed-attach";return undefined;}
      if(state.attachments.has(target)){if(trace){trace.stage="cached";trace.doneMs=trace.now();}return state.config.scope;}
      const headAt=trace?.now();
      if(trace)trace.stage="post-head";
      const reply=yield* state.link.request(head("POST",""),utf8(JSON.stringify({target,descriptor:state.descriptor})));
      if(trace&&headAt!==undefined)trace.postHeadMs=Math.max(0,trace.now()-headAt);
      const bodyAt=trace?.now();
      if(trace)trace.stage="post-body";
      const value=yield* json(reply) as Effect.Effect<{attachment:IrohLeafAttachment},CoreError>;
      if(trace&&bodyAt!==undefined)trace.postBodyMs=Math.max(0,trace.now()-bodyAt);
      if(!value?.attachment || hex(new Uint8Array(value.attachment.target))!==target)return yield* Effect.fail(error("leaf attachment has another target"));
      const useAt=trace?.now();
      if(trace)trace.stage="use";
      yield* native(state.endpoint.meshUseLeaf!({scope:state.config.scope,attachment:value.attachment}));
      if(trace&&useAt!==undefined)trace.useMs=Math.max(0,trace.now()-useAt);
      state.attachments.set(target,value.attachment);
      if(trace){trace.stage="done";trace.doneMs=trace.now();}
      return state.config.scope;
    });
  }
  readonly linked:NonNullable<MeshEnv["linked"]>=(address,link,endpoint)=>Effect.gen({self:this},function*(){
    if(!endpoint.meshConfigure || !endpoint.meshRemove || !endpoint.meshUseLeaf || !endpoint.meshDetachLeaf || !(link.answer as {meshLeaf?:boolean}|null)?.meshLeaf)return;
    const at=address.indexOf("/");if(at<1)return;
    const workspace=address.slice(0,at);
    let held=this.#held.get(endpoint);if(!held){held=new Map();this.#held.set(endpoint,held);}
    for(;;){const old=held.get(workspace);if(!old)break;yield* Deferred.await(old.done);}
    const state:State={link,endpoint,config:null,descriptor:null,attachments:new Map(),lock:Semaphore.makeUnsafe(1),lockHolder:null,done:Deferred.makeUnsafe()};
    held.set(workspace,state);
    yield* this.#follow(state).pipe(Effect.ensuring(Effect.gen(function*(){
      if(held!.get(workspace)===state)held!.delete(workspace);
      yield* state.lock.withPermits(1)(Effect.gen(function*(){
        state.lockHolder="close:remove";
        if(state.config && state.descriptor)yield* Effect.ignore(endpoint.meshRemove!(state.config.scope));
        state.config=null;state.descriptor=null;
      }).pipe(Effect.ensuring(Effect.sync(()=>{state.lockHolder=null;}))));
      Deferred.doneUnsafe(state.done,Effect.void);
    })));
    // A failed stream releases ingress ownership so an authenticated alternate can take over.
  }).pipe(Effect.retry({ schedule:Schedule.spaced("2 seconds"), while:()=>link.closed()===null })); // timer: retry the failed stream while its connection remains open.
  #follow(state:State):Effect.Effect<void,CoreError>{
    return Effect.gen({self:this},function*(){
      const reply=yield* state.link.request(head("GET","/events"),new Uint8Array());
      if(reply.status!==200){reply.cancel();return yield* Effect.fail(error("leaf policy stream refused"));}
      let carry=new Uint8Array();
      yield* Effect.gen({self:this},function*(){
        for(;;){
          const chunk=yield* native(reply.body.take);if(chunk===null)return yield* Effect.fail(error("leaf policy stream ended"));
          if(carry.length+chunk.length>LIMIT)return yield* Effect.fail(error("leaf policy exceeds bound"));
          const joined=new Uint8Array(carry.length+chunk.length);joined.set(carry);joined.set(chunk,carry.length);carry=joined;
          for(;;){const end=carry.indexOf(10);if(end<0)break;const bytes=carry.slice(0,end);carry=carry.slice(end+1);
            const config=yield* Effect.try({try:()=>JSON.parse(fromUtf8(bytes)) as LeafConfig,catch:error});
            // Inspect peer keys before prepare reads them. The native binding
            // still verifies signatures and policy before creating a route.
            if(!config || typeof config.scope!=="string" || !/^[0-9a-f]{64}$/i.test(config.scope)
              || !Array.isArray(config.peers) || config.peers.length>=256
              || config.peers.some(p=>!Array.isArray(p?.binding?.endpoint) || p.binding.endpoint.length!==32
                || p.binding.endpoint.some(b=>!Number.isInteger(b) || b<0 || b>255))
              || !Array.isArray(config.relayUrls) || config.relayUrls.length>32 || config.relayUrls.some(url=>typeof url!=="string"))return yield* Effect.fail(error("invalid leaf config"));
            if(config.stations!==undefined && (!Array.isArray(config.stations) || config.stations.length>256 || config.stations.some(n=>typeof n!=="string" || !/^[0-9a-f]{64}$/.test(n))))return yield* Effect.fail(error("invalid leaf station roster"));
            yield* state.lock.withPermits(1)(Effect.gen({self:this},function*(){
              state.lockHolder="follow:configure";
              const previous=state.config;
              const configured=state.descriptor!==null;
              if(previous && previous.scope!==config.scope && configured){
                yield* native(state.endpoint.meshRemove!(previous.scope));
                state.descriptor=null;
              }
              const descriptor=configured?yield* native(state.endpoint.meshConfigure!({...config,transit:false})):null;
              state.config=config;state.descriptor=descriptor;
              if(!descriptor)return;
              for(const [target,attachment] of [...state.attachments]){
                const issuer=config.peers.find(p=>sameBytes(p.binding.endpoint,attachment.issuer.endpoint))?.binding;
                const targetPresent=config.peers.some(p=>hex(new Uint8Array(p.binding.endpoint))===target);
                const valid=previous?.scope===config.scope && sameBytes(attachment.policy,descriptor.binding.policy)
                  && issuer?.generation===attachment.issuer.generation && sameBytes(issuer.neighbor,attachment.issuer.neighbor)
                  && issuer.transit && targetPresent
                  && (config.credentialExpiresUnixMs===undefined || config.credentialExpiresUnixMs===attachment.expires_unix_ms);
                if(valid)continue;
                state.lockHolder=`follow:detach:${target.slice(0,8)}`;
                if(previous)yield* native(state.endpoint.meshDetachLeaf!({scope:previous.scope,attachmentId:attachment.id}));
                state.attachments.delete(target);
                if(targetPresent && issuer){
                  state.lockHolder=`follow:attach:${target.slice(0,8)}`;
                  yield* this.#attach(state,target);
                }
              }
            }).pipe(Effect.ensuring(Effect.sync(()=>{state.lockHolder=null;}))));
          }
        }
      }).pipe(Effect.ensuring(Effect.sync(()=>reply.cancel())));
    });
  }
}
