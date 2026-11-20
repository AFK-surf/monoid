// Devices enter transport scopes only on their existing authenticated member
// connection. The native front owns each attachment across Node handovers.
import type { Cloud } from "../cloud/state.ts";
import type { Connection, Endpoint, MeshDescriptor, MeshLeafAttachment, MeshScope, Stream } from "./endpoint.ts";
import type { ScopeSync } from "./scope-sync.ts";
import { descriptorOf } from "./announcements.ts";
import { workspaceScope } from "./enrollment-door.ts";

export class LeafAttachments {
  readonly #endpoint: Endpoint;
  readonly #directory: ScopeSync;
  readonly #cloud: Cloud;
  readonly #streams = new Set<{connection: Connection; wake(): void}>();
  readonly #members = new WeakMap<Connection, { workspace: string; expires: number }>();
  constructor(endpoint: Endpoint, directory: ScopeSync, cloud: Cloud) {
    this.#endpoint=endpoint; this.#directory=directory; this.#cloud=cloud;
  }
  // The device's control stream sends its credential again on every ping (5 s): the same one changes nothing, so its
  // view is not written again; a renewal or another workspace is.
  authenticated(connection: Connection, workspace: string, expires: number): void {
    const current=this.#members.get(connection);
    if (current && current.workspace===workspace && current.expires===expires) return;
    this.#members.set(connection,{workspace,expires});
    for (const stream of this.#streams) if (stream.connection===connection) stream.wake();
  }
  view(workspace: string): MeshScope & {stations:string[]} {
    if (!this.#cloud.state || !this.#cloud.membership(workspace)) throw new Error("leaf workspace removed");
    const scope=workspaceScope(this.#cloud.state.origin,workspace);
    const policy=this.#directory.directory.policy(scope);
    // No peers until this station's own scope is configured and its own descriptor is among them: a device given
    // the others would ask this station to issue attachments it cannot yet, and be refused. Its publishing changes
    // the scope, so `follow` writes the peers then.
    const directory=this.#directory.directory;
    const ready=typeof directory.ready==="function" ? directory.ready(scope,this.#endpoint.id()) : true;
    const records=ready ? directory.records(scope).map(a=>JSON.parse(a.body).descriptor as MeshDescriptor) : [];
    const peers=records.some(p=>Buffer.from(p.binding.endpoint).toString("hex")===this.#endpoint.id()) ? records : [];
    return { scope, transit:false, peers, relayUrls:policy.relayUrls, globalRelays:policy.globalRelays, stations:policy.nodes };
  }
  async follow(connection: Connection, workspace: string, stream: Stream): Promise<void> {
    let wake=()=>{};
    let changed=true;
    let ended=false;
    const subscriber={connection,wake:()=>{changed=true;wake();}};
    this.#streams.add(subscriber);
    const scope=this.view(workspace).scope;
    const off=this.#directory.listen(changed=>{if(changed===scope)subscriber.wake();});
    void stream.stopped().then(()=>{ended=true;wake();},()=>{ended=true;wake();});
    try {
      while (!ended && !connection.isClosed()) {
        if (!changed) await new Promise<void>(resolve=>{wake=resolve;});
        if (ended || connection.isClosed()) break;
        changed=false;
        await stream.write(Buffer.from(JSON.stringify({...this.view(workspace),credentialExpiresUnixMs:(this.#members.get(connection)?.expires ?? 0)*1000})+"\n"));
      }
    } finally {off();this.#streams.delete(subscriber);await stream.finish();}
  }
  async attach(connection: Connection, workspace: string, raw: unknown, target: string): Promise<{ attachment: MeshLeafAttachment; config: MeshScope }> {
    const member=this.#members.get(connection);
    const membership=this.#cloud.membership(workspace);
    if (!member || member.workspace!==workspace || !membership || connection.isClosed()) throw new Error("leaf member connection ended");
    if (target!==this.#endpoint.id() && !membership.peers.some(p=>p.id===target)) throw new Error("leaf target is not a workspace station");
    const config=this.view(workspace);
    const descriptor=descriptorOf(raw,config.scope,connection.remoteId());
    if (descriptor.binding.transit) throw new Error("a device cannot provide transit");
    if (!this.#endpoint.meshAttachLeaf) throw new Error("native leaf transport is unavailable");
    const attachment=await this.#endpoint.meshAttachLeaf(connection,{scope:config.scope,descriptor,target,expiresUnixMs:member.expires*1000});
    // Admission can be revoked while native configuration is awaited. Its
    // connection-close watcher removes the lease too; do not hand it out here.
    try {
    const latest=this.#cloud.membership(workspace);
    const current=this.view(workspace);
    const issuer=current.peers.find(p=>Buffer.from(p.binding.endpoint).toString("hex")===this.#endpoint.id())?.binding;
    const sameIssuer=issuer && issuer.generation===attachment.issuer.generation && JSON.stringify([issuer.policy,issuer.neighbor])===JSON.stringify([attachment.issuer.policy,attachment.issuer.neighbor]);
    const samePolicy=JSON.stringify([current.scope,current.relayUrls,current.globalRelays])===JSON.stringify([config.scope,config.relayUrls,config.globalRelays]);
    // A ping with the same credential, or its renewal, meanwhile is no change; another workspace or a shorter one is.
    const latestMember=this.#members.get(connection);
    const sameMember=latestMember!==undefined && latestMember.workspace===workspace && latestMember.expires>=member.expires;
    if (connection.isClosed() || !sameMember || !latest ||
        (target!==this.#endpoint.id() && !latest.peers.some(p=>p.id===target)) || !samePolicy || !sameIssuer) {
      throw new Error("leaf admission changed");
    }
    return {attachment,config};
    } catch (error) {
      await this.#endpoint.meshDetachLeaf?.({scope:config.scope,attachmentId:attachment.id});
      throw error;
    }
  }
}
