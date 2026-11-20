// A leaf scope is learned from a station that admitted this device. Its stream
// pushes policy changes; only targets actually dialled get an attachment.
import { Deferred, Effect, Schedule, Semaphore } from "effect";
import { CoreError } from "../error.ts";
import type { IrohEndpoint, IrohLeafAttachment, IrohMeshDescriptor, IrohMeshScope } from "../iroh.ts";
import type { Link, MeshEnv, Reply } from "../mesh.ts";
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
type State={link:Link;endpoint:IrohEndpoint;config:LeafConfig|null;descriptor:IrohMeshDescriptor|null;attachments:Map<string,IrohLeafAttachment>;lock:ReturnType<typeof Semaphore.makeUnsafe>;done:Deferred.Deferred<void>};
export class LeafLinks {
  readonly #held=new WeakMap<IrohEndpoint,Map<string,State>>();
  readonly prepare:NonNullable<MeshEnv["prepare"]>=(address,endpoint)=>Effect.gen({self:this},function*(){
    const at=address.indexOf("/");if(at<1)return undefined;
    const state=this.#held.get(endpoint)?.get(address.slice(0,at));
    if(!state?.config || state.link.closed()!==null || address.slice(at+1)===state.link.conn.remoteId())return undefined;
    const target=address.slice(at+1);
    // A target without a descriptor here is dialled as before, not through this
    // station: an older station, one enrolled but not yet in the lock, one not
    // protected, or one this station has not yet heard of from the cloud. This
    // station grants no access and may not refuse a device's dial to another
    // (the lock guards against stations): the TLS endpoint key and the core's
    // own lock rules authenticate the target. A descriptor-bearing peer always
    // attaches, and a signing or policy failure there is never downgraded.
    if(!state.config.peers.some(p=>hex(new Uint8Array(p.binding.endpoint))===target))return undefined;
    return yield* state.lock.withPermits(1)(this.#attach(state,target));
  });
  #attach(state:State,target:string):Effect.Effect<string|undefined,CoreError>{
    return Effect.gen(function*(){
      if(!state.config || !state.descriptor || state.link.closed()!==null)return undefined;
      if(state.attachments.has(target))return state.config.scope;
      const reply=yield* state.link.request(head("POST",""),utf8(JSON.stringify({target,descriptor:state.descriptor})));
      const value=yield* json(reply) as Effect.Effect<{attachment:IrohLeafAttachment},CoreError>;
      if(!value?.attachment || hex(new Uint8Array(value.attachment.target))!==target)return yield* Effect.fail(error("leaf attachment has another target"));
      yield* native(state.endpoint.meshUseLeaf!({scope:state.config.scope,attachment:value.attachment}));
      state.attachments.set(target,value.attachment);
      return state.config.scope;
    });
  }
  readonly linked:NonNullable<MeshEnv["linked"]>=(address,link,endpoint)=>Effect.gen({self:this},function*(){
    if(!endpoint.meshConfigure || !endpoint.meshRemove || !endpoint.meshUseLeaf || !endpoint.meshDetachLeaf || !(link.answer as {meshLeaf?:boolean}|null)?.meshLeaf)return;
    const at=address.indexOf("/");if(at<1)return;
    const workspace=address.slice(0,at);
    let held=this.#held.get(endpoint);if(!held){held=new Map();this.#held.set(endpoint,held);}
    for(;;){const old=held.get(workspace);if(!old)break;yield* Deferred.await(old.done);}
    const state:State={link,endpoint,config:null,descriptor:null,attachments:new Map(),lock:Semaphore.makeUnsafe(1),done:Deferred.makeUnsafe()};
    held.set(workspace,state);
    yield* this.#follow(state).pipe(Effect.ensuring(Effect.gen(function*(){
      if(held!.get(workspace)===state)held!.delete(workspace);
      if(state.config)yield* Effect.ignore(endpoint.meshRemove!(state.config.scope));
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
            if(config.stations!==undefined && (!Array.isArray(config.stations) || config.stations.length>256 || config.stations.some(n=>typeof n!=="string" || !/^[0-9a-f]{64}$/.test(n))))return yield* Effect.fail(error("invalid leaf station roster"));
            yield* state.lock.withPermits(1)(Effect.gen({self:this},function*(){
              const previous=state.config;
              if(previous && previous.scope!==config.scope)yield* native(state.endpoint.meshRemove!(previous.scope));
              const descriptor=yield* native(state.endpoint.meshConfigure!({...config,transit:false}));
              state.config=config;state.descriptor=descriptor;
              for(const [target,attachment] of [...state.attachments]){
                const issuer=config.peers.find(p=>sameBytes(p.binding.endpoint,attachment.issuer.endpoint))?.binding;
                const targetPresent=config.peers.some(p=>hex(new Uint8Array(p.binding.endpoint))===target);
                const valid=previous?.scope===config.scope && sameBytes(attachment.policy,descriptor.binding.policy)
                  && issuer?.generation===attachment.issuer.generation && sameBytes(issuer.neighbor,attachment.issuer.neighbor)
                  && issuer.transit && targetPresent
                  && (config.credentialExpiresUnixMs===undefined || config.credentialExpiresUnixMs===attachment.expires_unix_ms);
                if(valid)continue;
                if(previous)yield* native(state.endpoint.meshDetachLeaf!({scope:previous.scope,attachmentId:attachment.id}));
                state.attachments.delete(target);
                if(targetPresent && issuer)yield* this.#attach(state,target);
              }
            }));
          }
        }
      }).pipe(Effect.ensuring(Effect.sync(()=>reply.cancel())));
    });
  }
}
