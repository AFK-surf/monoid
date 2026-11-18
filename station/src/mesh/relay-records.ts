// A relay's self-signature proves its identity, not its workspace membership.
// Only a currently admitted issuing station can grant or revoke that identity.
import { createPublicKey, verify } from "node:crypto";
import type { DatabaseSync } from "node:sqlite";
import type { RelayRegistration } from "./enrollment.ts";
import { RELAY_RECORD_TABLE } from "../store/mesh-schema.ts";
export type SignedRelayRecord = { body: string; signature: string };
const KEY = /^[0-9a-f]{64}$/;
const DOMAIN = "mesh-relay-registration/v1\0";
export function relayRecordOf(signed: SignedRelayRecord, scope: string, issuers: ReadonlySet<string>): RelayRegistration {
  if (issuers.size > 256 || typeof signed?.body !== "string" || Buffer.byteLength(signed.body) > 16 * 1024
      || typeof signed.signature !== "string" || !/^[0-9a-f]{128}$/i.test(signed.signature)) throw new Error("invalid relay record");
  const record = JSON.parse(signed.body);
  if (record?.scope !== scope || !KEY.test(scope) || !KEY.test(record.node) || !KEY.test(record.issuer) || !issuers.has(record.issuer)
      || !Number.isSafeInteger(record.generation) || record.generation < 1 || !(record.revoked === 0 || record.revoked === 1)
      || typeof record.name !== "string" || record.name.length < 1 || record.name.length > 80
      || typeof record.made_by !== "string" || record.made_by.length > 200) throw new Error("relay record is outside the admitted workspace");
  const key = createPublicKey({ key: Buffer.concat([Buffer.from("302a300506032b6570032100", "hex"), Buffer.from(record.issuer, "hex")]), format: "der", type: "spki" });
  if (!verify(null, Buffer.from(DOMAIN + signed.body), key, Buffer.from(signed.signature, "hex"))) throw new Error("invalid relay issuer signature");
  return record;
}
export function signRelayRecord(record: RelayRegistration, sign: (body: string) => string): SignedRelayRecord {
  const body = JSON.stringify({ scope: record.scope, node: record.node, issuer: record.issuer, generation: record.generation,
    name: record.name, made_by: record.made_by, revoked: record.revoked });
  return { body, signature: sign(DOMAIN + body) };
}
export class RelayRecords {
  readonly db: DatabaseSync;
  constructor(db: DatabaseSync) { this.db = db; db.exec(RELAY_RECORD_TABLE); }
  take(signed: SignedRelayRecord, scope: string, issuers: ReadonlySet<string>): boolean {
    const record = relayRecordOf(signed, scope, issuers);
    // Admission and its bounded capacity decision are one writer transaction.
    this.db.exec("BEGIN IMMEDIATE");
    try {
      const old = this.db.prepare("SELECT issuer,generation FROM mesh_relay_records WHERE scope=? AND node=?").get(scope, record.node);
      if (old && old.issuer !== record.issuer) throw new Error("relay identity already has another issuer");
      if (!old) {
        const count = this.db.prepare("SELECT COUNT(*) AS n FROM mesh_relay_records WHERE scope=?").get(scope)!;
        if (Number(count.n) >= 256) throw new Error("too many relay identities in this scope");
      }
      const result = this.db.prepare(`INSERT INTO mesh_relay_records(scope,node,issuer,generation,body,signature) VALUES(?,?,?,?,?,?)
        ON CONFLICT(scope,node) DO UPDATE SET generation=excluded.generation,body=excluded.body,signature=excluded.signature
        WHERE mesh_relay_records.issuer=excluded.issuer AND mesh_relay_records.generation<excluded.generation`)
        .run(scope, record.node, record.issuer, record.generation, signed.body, signed.signature);
      this.db.exec("COMMIT");
      return Number(result.changes) === 1;
    } catch (error) { this.db.exec("ROLLBACK"); throw error; }
  }
}
