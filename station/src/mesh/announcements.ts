// Signed, scoped address announcements can pass through other workspace stations.
// A third party cannot replace a newer address or change a forwarding capability.
import { createPublicKey, verify } from "node:crypto";
import type { DatabaseSync } from "node:sqlite";
import type { MeshDescriptor } from "./endpoint.ts";
const KEY = /^[0-9a-f]{64}$/;
const DOMAIN = "mesh-announcement/v1\0";
const LIMIT = 16 * 1024;
export type Announcement = { body: string; signature: string };
export type Announced = { scope: string; node: string; revision: number; descriptor: MeshDescriptor };
import { ANNOUNCEMENT_TABLE } from "../store/mesh-schema.ts";
export { ANNOUNCEMENT_TABLE } from "../store/mesh-schema.ts";
const bytes = (raw: unknown, length: number): raw is number[] => Array.isArray(raw) && raw.length === length && raw.every((b) => Number.isInteger(b) && b >= 0 && b <= 255);
function validSignature(node: string, body: Buffer, signature: Buffer): boolean {
  try {
    const key = createPublicKey({ key: Buffer.concat([Buffer.from("302a300506032b6570032100", "hex"), Buffer.from(node, "hex")]), format: "der", type: "spki" });
    return verify(null, body, key, signature);
  } catch { return false; }
}
export function descriptorOf(raw: any, scope: string, node: string, minimumGeneration = 0): MeshDescriptor {
  const b = raw?.binding;
  if (!KEY.test(scope) || !KEY.test(node) || !b || !bytes(b.scope, 32) || !bytes(b.policy, 32) || !bytes(b.endpoint, 32) || !bytes(b.neighbor, 32) || !bytes(b.signature, 64)
      || !Number.isSafeInteger(b.generation) || b.generation < minimumGeneration || b.generation < 1 || typeof b.transit !== "boolean"
      || Buffer.from(b.scope).toString("hex") !== scope || Buffer.from(b.endpoint).toString("hex") !== node
      || Buffer.from(b.neighbor).equals(Buffer.from(b.endpoint))) throw new Error("invalid scoped mesh binding");
  const generation = Buffer.alloc(8); generation.writeBigUInt64BE(BigInt(b.generation));
  const message = Buffer.concat([Buffer.from("mesh-neighbor-binding/v2\0"), Buffer.from(b.scope), Buffer.from(b.policy), Buffer.from(b.endpoint), Buffer.from(b.neighbor), generation, Buffer.from([b.transit ? 1 : 0])]);
  if (!validSignature(node, message, Buffer.from(b.signature))) throw new Error("invalid mesh binding signature");
  if (!raw.address || raw.address.id !== Buffer.from(b.neighbor).toString("hex") || !Array.isArray(raw.address.addrs) || raw.address.addrs.length > 8
      || Buffer.byteLength(JSON.stringify(raw)) > LIMIT) throw new Error("invalid mesh neighbor address");
  for (const addr of raw.address.addrs) {
    if (!addr || typeof addr !== "object" || Object.keys(addr).length !== 1
        || !(typeof addr.Ip === "string" && addr.Ip.length <= 128 || typeof addr.Relay === "string" && addr.Relay.length <= 2048)) {
      throw new Error("invalid mesh underlay address");
    }
  }
  return structuredClone(raw);
}
export function announcementOf(raw: any, scope: string, allowed: ReadonlySet<string>, minimumGeneration = 0): Announced {
  if (allowed.size > 256) throw new Error("too many mesh identities");
  if (typeof raw?.body !== "string" || Buffer.byteLength(raw.body) > LIMIT || typeof raw.signature !== "string" || !/^[0-9a-f]{128}$/i.test(raw.signature)) throw new Error("invalid mesh announcement");
  const value = JSON.parse(raw.body);
  if (value?.scope !== scope || !KEY.test(value.node) || !allowed.has(value.node) || !Number.isSafeInteger(value.revision) || value.revision < 1) throw new Error("mesh announcement is outside the admitted directory");
  if (!validSignature(value.node, Buffer.from(DOMAIN + raw.body), Buffer.from(raw.signature, "hex"))) throw new Error("invalid mesh announcement signature");
  return { scope, node: value.node, revision: value.revision, descriptor: descriptorOf(value.descriptor, scope, value.node, minimumGeneration) };
}
export class Announcements {
  readonly db: DatabaseSync;
  readonly #cache = new Map<string, Map<string, Announcement>>();
  #rosterVersion = 0;
  readonly #read: (scope: string, nodes: string[]) => Promise<Announcement[]>;
  constructor(db: DatabaseSync, read: (scope: string, nodes: string[]) => Promise<Announcement[]> = async () => []) {
    this.db = db; this.#read = read; db.exec(ANNOUNCEMENT_TABLE);
  }
  async load(scope: string, allowed: ReadonlySet<string>): Promise<void> {
    if (allowed.size > 256) throw new Error("too many mesh identities");
    const rosterVersion = this.#rosterVersion;
    const records = await this.#read(scope, [...allowed]);
    if (rosterVersion !== this.#rosterVersion) return;
    if (!Array.isArray(records) || records.length > 256) throw new Error("invalid stored mesh directory");
    for (const record of records) announcementOf(record, scope, allowed);
    for (const record of records) this.#remember(scope, record);
  }
  retain(scopes: ReadonlyMap<string, ReadonlySet<string>>): void {
    this.#rosterVersion++;
    for (const [scope, nodes] of this.#cache) {
      const allowed = scopes.get(scope);
      if (!allowed) { this.#cache.delete(scope); continue; }
      for (const node of nodes.keys()) if (!allowed.has(node)) nodes.delete(node);
    }
  }
  #remember(scope: string, signed: Announcement): void {
    const value = JSON.parse(signed.body);
    let nodes = this.#cache.get(scope);
    if (!nodes) {
      if (this.#cache.size >= 32) throw new Error("too many cached mesh scopes");
      this.#cache.set(scope, nodes = new Map());
    }
    const old = nodes.get(value.node);
    if (old && JSON.parse(old.body).revision >= value.revision) return;
    if (!old && nodes.size >= 256) throw new Error("too many cached mesh identities");
    nodes.set(value.node, { ...signed });
  }
  publish(scope: string, descriptor: MeshDescriptor, signer: { id: string; sign(text: string): string }): Announcement {
    descriptorOf(descriptor, scope, signer.id);
    this.db.exec("BEGIN IMMEDIATE");
    let committed = false;
    try {
      const old = this.db.prepare("SELECT revision, body, signature FROM mesh_announcements WHERE scope = ? AND node = ?").get(scope, signer.id);
      if (old && JSON.stringify(JSON.parse(String(old.body)).descriptor) === JSON.stringify(descriptor)) {
        this.db.exec("COMMIT"); committed = true;
        const signed = { body: String(old.body), signature: String(old.signature) };
        this.#remember(scope, signed);
        return signed;
      }
      const revision = Number(old?.revision ?? 0) + 1;
      if (!Number.isSafeInteger(revision)) throw new Error("mesh announcement revision exhausted");
      const body = JSON.stringify({ scope, node: signer.id, revision, descriptor });
      if (Buffer.byteLength(body) > LIMIT) throw new Error("mesh announcement too large");
      const signed = { body, signature: signer.sign(DOMAIN + body) };
      announcementOf(signed, scope, new Set([signer.id]));
      this.#keep(scope, signer.id, revision, signed);
      this.db.exec("COMMIT"); committed = true;
      this.#remember(scope, signed);
      return signed;
    } catch (error) { if (!committed) this.db.exec("ROLLBACK"); throw error; }
  }
  take(raw: Announcement, scope: string, allowed: ReadonlySet<string>): boolean {
    const value = announcementOf(raw, scope, allowed);
    const changed = this.#keep(scope, value.node, value.revision, raw);
    if (changed) this.#remember(scope, raw);
    return changed;
  }
  #keep(scope: string, node: string, revision: number, signed: Announcement) {
    const result = this.db.prepare(`INSERT INTO mesh_announcements(scope, node, revision, body, signature) VALUES (?, ?, ?, ?, ?)
      ON CONFLICT(scope, node) DO UPDATE SET revision = excluded.revision, body = excluded.body, signature = excluded.signature
      WHERE excluded.revision > mesh_announcements.revision`)
      .run(scope, node, revision, signed.body, signed.signature);
    return Number(result.changes) === 1;
  }
  list(scope: string, allowed: ReadonlySet<string>): Announcement[] {
    if (allowed.size > 256) throw new Error("too many mesh identities");
    const nodes = this.#cache.get(scope);
    const result: Announcement[] = [];
    for (const node of allowed) {
      const record = nodes?.get(node);
      if (record) result.push({ ...record });
    }
    return result;
  }
}
