// Workspace station directory changes travel on the existing authenticated peer
// connection. Healthy peers are contacted only when a roster or record changes.
import type { DatabaseSync } from "node:sqlite";
import type { Cloud } from "../cloud/state.ts";
import { RelayEnrollment } from "./enrollment.ts";
import { Fibers, wall } from "../ops/fibers.ts";
import { log } from "../ops/log.ts";
import type { PeerCall } from "./bus.ts";
import type { Endpoint } from "./endpoint.ts";
import { RelayRecords, relayRecordOf, signRelayRecord, type SignedRelayRecord } from "./relay-records.ts";
import { Announcements, announcementOf, type Announcement } from "./announcements.ts";
import { ScopeDirectory, type ScopeRoster } from "./scope-directory.ts";
import { exchangeScope, exchangeSignedRecords } from "./scope-exchange.ts";
import { workspaceScope } from "./enrollment-door.ts";
import { waysOf, workspaceRelays } from "./ways.ts";
import { globalRelaysOf } from "./global-relays.ts";
/// What a front from before its mesh operations (one saying `streams` under 5, launcher front.rs `STREAMS`) answers them.
const OLD_FRONT = /no operation mesh(?:Configure|Remove)/i;
/// What a station from before the directory exchange answers it: a method it does not know, or (one from before
/// `meshDirectory` in peer.ts `servePeer`) the exchange taken as a task's request (as replica/copies.ts `#reason`).
const OLD_PEER = /unknown.*method|no such method|unsupported peer method|session and task key (?:is|are) required/i;
/// How long a station waits before it tries a peer again that it could not reach or exchange with, at first; each
/// failure after doubles it, up to PEER_RETRY_MOST_MS (as ways.ts's and lock-sync.ts's): a peer that is off is the
/// workspace's ordinary state, not this station's failure.
const PEER_RETRY_MS = 5_000;
const PEER_RETRY_MOST_MS = 10 * 60_000;
export class ScopeSync {
  readonly directory: ScopeDirectory;
  readonly #cloud: Cloud;
  readonly #call: PeerCall;
  readonly #read: (args: unknown) => Promise<string>;
  readonly #relayStore: RelayRecords;
  readonly #relayRecords = new Map<string, SignedRelayRecord[]>();
  readonly #fibers: Pick<Fibers, "after" | "close">;
  #rosterEpoch = 0;
  #rosterWait = 0;
  #rosterRetry?: () => void;
  readonly #restartFront: (() => void) | undefined;
  #oldFront = false;
  readonly #off: (() => void)[] = [];
  readonly #workspaces = new Map<string, string>();
  readonly #jobs = new Map<string, { scope: string; workspace: string; peer: string; done: string; running: boolean; wait: number; cancel?: () => void }>();
  readonly #listeners = new Set<(scope: string) => void>();
  #closed = false;
  #active = 0;
  constructor(endpoint: Endpoint, db: DatabaseSync, cloud: Cloud, signer: { id: string; sign(text: string): string }, call: PeerCall, read: (args: unknown) => Promise<string>, fibers: Pick<Fibers, "after" | "close"> = new Fibers("mesh-directory"), restartFront?: () => void) {
    this.#fibers = fibers; this.#restartFront = restartFront;
    this.#cloud = cloud; this.#call = call; this.#read = read; this.#relayStore = new RelayRecords(db);
    this.directory = new ScopeDirectory(endpoint, new Announcements(db, async (scope, nodes) => JSON.parse(await read({ kind: "announcements", scope, nodes }))), signer, (scope) => this.#changed(scope), (error) => this.#failed(error));
    this.#off.push(cloud.listen(() => this.#roster()), waysOf(cloud).listen(() => this.#roster()));
    this.#roster();
  }
  #failed(error: unknown) {
    if (OLD_FRONT.test(String(error))) return this.#frontTooOld();
    log.warn("mesh", "mesh directory update failed", { error: String(error) });
  }
  // The launcher's front is from before the mesh operations: no retry makes it take them. Its launcher (one that
  // keeps it) is asked once to start the release's, the Node then handed over to one linked to it; with none, it is
  // said once, and the directory is tried again only as the roster changes.
  #frontTooOld() {
    if (this.#oldFront) return;
    this.#oldFront = true;
    if (this.#restartFront) {
      log.warn("mesh", "the front is from before meshConfigure: asking the launcher to start the release's");
      this.#restartFront();
    } else log.warn("mesh", "the front is from before meshConfigure: the mesh directory waits for a front that takes it");
  }
  async #roster() {
    if (this.#closed || !this.#cloud.peersCurrent || !this.#cloud.state) return;
    const epoch = ++this.#rosterEpoch;
    this.#rosterRetry?.(); this.#rosterRetry = undefined;
    const rosters: ScopeRoster[] = [];
    const jobs = new Map<string, { scope: string; workspace: string; peer: string }>();
    const workspaces = new Map<string, string>();
    try {
    for (const m of this.#cloud.fullMemberships()) {
      const scope = workspaceScope(this.#cloud.state.origin, m.workspace);
      const nodes = new Set<string>([this.directory.signer.id, ...m.peers.map((p) => p.id).filter((id): id is string => typeof id === "string")]);
      const ways = waysOf(this.#cloud);
      const off = new Set(ways.view(m.workspace).off);
      const globals = globalRelaysOf(this.#cloud.state.mesh_relays);
      rosters.push({ scope, nodes, relayUrls: workspaceRelays(ways, m.workspace), transit: true,
        globalRelays: off.has("ours") ? [] : globals.filter(g => !off.has(`mesh:${g.node}`)) });
      workspaces.set(m.workspace, scope);
      for (const peer of nodes) if (peer !== this.directory.signer.id) {
        jobs.set(`${scope}:${peer}`, { scope, workspace: m.workspace, peer });
      }
    }
      const records = new Map<string, SignedRelayRecord[]>();
      for (const roster of rosters) {
        const saved: SignedRelayRecord[] = JSON.parse(await this.#read({ kind: "relayRecords", scope: roster.scope }));
        if (!Array.isArray(saved) || saved.length > 256) throw new Error("invalid stored relay directory");
        const admitted: SignedRelayRecord[] = [];
        const nodes = new Set(roster.nodes);
        const generations = new Map<string, number>();
        for (const signed of saved) {
          // An issuer removed from the station roster can no longer grant transit.
          const issuer = JSON.parse(signed.body).issuer;
          if (!roster.nodes.has(issuer)) continue;
          const record = relayRecordOf(signed, roster.scope, roster.nodes);
          admitted.push(signed);
          if (record.revoked === 0) { nodes.add(record.node); generations.set(record.node, record.generation); }
        }
        records.set(roster.scope, admitted); roster.nodes = nodes; roster.generations = generations;
      }
      if (epoch !== this.#rosterEpoch || this.#closed) return;
      const applied = this.directory.set(rosters);
      const changedScopes = new Set([...this.#relayRecords.keys(), ...records.keys()]);
      this.#relayRecords.clear();
      for (const [scope, rows] of records) this.#relayRecords.set(scope, rows);
      this.#workspaces.clear();
      for (const [workspace, scope] of workspaces) this.#workspaces.set(workspace, scope);
      for (const [key, job] of this.#jobs) if (!jobs.has(key)) { job.cancel?.(); this.#jobs.delete(key); }
      for (const [key, job] of jobs) if (!this.#jobs.has(key)) this.#jobs.set(key, { ...job, done: "", running: false, wait: 0 });
      await applied;
      if (epoch === this.#rosterEpoch) this.#rosterWait = 0;
      for (const scope of changedScopes) this.#changed(scope);
    } catch (error) { this.#retryRoster(epoch, error); }
  }
  #retryRoster(epoch: number, error: unknown) {
    if (this.#closed || epoch !== this.#rosterEpoch) return;
    this.#failed(error);
    if (OLD_FRONT.test(String(error))) return;
    this.#rosterWait = Math.min(this.#rosterWait ? this.#rosterWait * 2 : 1000, 60_000);
    this.#rosterRetry = this.#fibers.after(this.#rosterWait, () => this.#roster()); // timer: retry failed native directory application with backoff
  }
  #word(scope: string) {
    return JSON.stringify([this.directory.records(scope).map((r) => { const a = JSON.parse(r.body); return [a.node, a.revision]; }).sort(),
      (this.#relayRecords.get(scope) ?? []).map((r) => { const a = JSON.parse(r.body); return [a.node, a.generation]; }).sort()]);
  }
  #pump() {
    if (this.#closed) return;
    for (const [key, job] of this.#jobs) {
      if (this.#active >= 4) break;
      const word = this.#word(job.scope);
      if (job.running || job.cancel || job.done === word) continue;
      job.running = true; this.#active++;
      // Whether the peer's call failed, not this station's own directory (its front, its store).
      let peerFailed = false;
      const send = (method: string) => async (request: unknown) => {
        if (this.#closed || this.#jobs.get(key) !== job) throw new Error("mesh membership changed");
        try { return await this.#call(job.peer, job.workspace, { method, ...request as object }); }
        catch (error) { peerFailed = true; throw error; }
      };
      void (async () => {
        // Membership grants/revocations arrive before any relay address records.
        await exchangeSignedRecords(() => this.#relayRecords.get(job.scope) ?? [],
          (records) => this.#takeRegistrations(job.scope, records), send("meshRelays.exchange"), "generation");
        await exchangeScope(this.directory, job.scope, send("meshScopes.exchange"));
      })().then(() => { job.done = word; job.wait = 0; }, (error) => {
        if (this.#closed || this.#jobs.get(key) !== job) return;
        // A station from before the exchange: level with it until this station's word changes.
        if (peerFailed && OLD_PEER.test(String(error))) { job.done = word; job.wait = 0; return; }
        // (a front from before: tried again with the next word, or by the Node a new front is handed)
        if (!peerFailed && OLD_FRONT.test(String(error))) { this.#frontTooOld(); job.done = word; return; }
        if (peerFailed) {
          log.info("mesh", "a station's mesh directory was not brought level", { peer: job.peer.slice(0, 12), workspace: job.workspace, error: String(error) });
          job.wait = Math.min(job.wait ? job.wait * 2 : PEER_RETRY_MS, PEER_RETRY_MOST_MS);
        } else {
          this.#failed(error);
          job.wait = Math.min(job.wait ? job.wait * 2 : 1000, 60_000);
        }
        job.cancel = this.#fibers.after(job.wait, () => { // timer: retry after failed directory exchange, with backoff
          job.cancel = undefined; this.#pump();
        });
      }).finally(() => { job.running = false; this.#active--; this.#pump(); });
    }
  }
  #changed(scope: string) {
    this.#pump();
    for (const listener of this.#listeners) { try { listener(scope); } catch (error) { this.#failed(error); } }
  }
  listen(listener: (scope: string) => void): () => void {
    this.#listeners.add(listener); return () => { this.#listeners.delete(listener); };
  }
  relayView(scope: string, node: string) {
    const registered = (this.#relayRecords.get(scope) ?? []).map((r) => JSON.parse(r.body)).find((r) => r.node === node && r.revoked === 0);
    if (!registered || this.#closed) throw new Error("relay registration removed");
    return { scope, generation: registered.generation, ...this.directory.policy(scope), records: this.directory.records(scope) };
  }
  async relayAnnouncement(scope: string, node: string, signed: Announcement): Promise<void> {
    const view = this.relayView(scope, node);
    const record = announcementOf(signed, scope, new Set([node]), view.generation);
    if (!record.descriptor.binding.transit) throw new Error("a relay must advertise forwarding capability");
    await this.directory.take(scope, [signed]);
  }
  async registration(signed: SignedRelayRecord): Promise<void> {
    await this.#takeRegistrations(JSON.parse(signed.body).scope, [signed]);
  }
  async #takeRegistrations(scope: string, records: SignedRelayRecord[]): Promise<void> {
    const membership = this.#cloud.fullMemberships().find((m) => workspaceScope(this.#cloud.state!.origin, m.workspace) === scope);
    if (!membership || this.#closed) throw new Error("relay workspace removed");
    const issuers = new Set([this.directory.signer.id, ...membership.peers.map((p) => p.id)]);
    for (const signed of records) relayRecordOf(signed, scope, issuers);
    let changed = false;
    for (const signed of records) changed = this.#relayStore.take(signed, scope, issuers) || changed;
    // Local enrollment may already have persisted the record before this call.
    if (changed || records.length > 0) await this.#roster();
  }
  relays(workspace: string): unknown[] {
    const scope = this.#workspaces.get(workspace);
    if (!scope || !this.#cloud.membership(workspace)) throw new Error("mesh workspace is not ready");
    return (this.#relayRecords.get(scope) ?? []).map((signed) => JSON.parse(signed.body));
  }
  async revoke(workspace: string, node: string, localOnly = false): Promise<SignedRelayRecord> {
    const scope = this.#workspaces.get(workspace);
    if (!scope || this.#closed || !this.#cloud.membership(workspace) || !/^[0-9a-f]{64}$/.test(node)) throw new Error("invalid relay workspace or identity");
    const signed = (this.#relayRecords.get(scope) ?? []).find((s) => JSON.parse(s.body).node === node);
    if (!signed) throw new Error("relay is not registered in this workspace");
    const record = JSON.parse(signed.body);
    if (record.issuer !== this.directory.signer.id) {
      if (localOnly) throw new Error("only the issuing station can revoke this relay");
      const reply = await this.#call(record.issuer, workspace, { method: "meshRelays.revoke", node }) as unknown as SignedRelayRecord;
      const revoked = relayRecordOf(reply, scope, new Set([record.issuer]));
      if (revoked.node !== node || revoked.revoked !== 1 || revoked.generation < record.generation) throw new Error("invalid relay revocation reply");
      await this.registration(reply);
      return reply;
    }
    const revoked = new RelayEnrollment(this.#relayStore.db, this.directory.signer.id, wall.now).revoke(scope, node);
    const reply = signRelayRecord(revoked, (body) => this.directory.signer.sign(body));
    await this.registration(reply);
    return reply;
  }
  scopeFor(peer: string, workspace: string | null): string | undefined {
    const candidates = workspace ? [this.#workspaces.get(workspace)] : [...this.#workspaces.values()];
    return candidates.find((scope) => scope !== undefined && this.directory.ready(scope, peer));
  }
  async answer(peer: string, workspace: string, request: any): Promise<unknown> {
    const admitted = () => !this.#closed && this.#cloud.membership(workspace)?.peers.some((p) => p.id === peer) === true;
    const scope = this.#workspaces.get(workspace);
    if (!scope || !admitted() || !(request?.method === "meshScopes.exchange" || request?.method === "meshRelays.exchange" || request?.method === "meshRelays.revoke")) throw new Error("mesh workspace membership required");
    let result: unknown;
    if (request.method === "meshRelays.revoke") result = await this.revoke(workspace, request.node, true);
    else if (request.method === "meshRelays.exchange") {
      const give = request.give ?? [], want = request.want ?? [];
      if (!Array.isArray(give) || give.length > 16 || !Array.isArray(want) || want.length > 16
          || want.some((id) => typeof id !== "string" || !/^[0-9a-f]{64}$/.test(id))) throw new Error("invalid relay record exchange");
      await this.#takeRegistrations(scope, give);
      const versions: Record<string, number> = {};
      const records: SignedRelayRecord[] = [];
      for (const signed of this.#relayRecords.get(scope) ?? []) {
        const record = JSON.parse(signed.body); versions[record.node] = record.generation;
        if (want.includes(record.node)) records.push(signed);
      }
      result = { versions, records };
    } else result = await this.directory.exchange(scope, request);
    if (!admitted()) throw new Error("mesh workspace membership removed");
    return result;
  }
  async close(): Promise<void> {
    this.#closed = true; this.#rosterRetry?.();
    for (const off of this.#off) off();
    for (const job of this.#jobs.values()) job.cancel?.();
    this.#jobs.clear(); this.#listeners.clear(); this.directory.close();
    await this.#fibers.close();
  }
}
