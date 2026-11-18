// Workspace relay enrollment belongs to its issuing station. Tokens are never
// replicated; their single use and the resulting record commit together. The
// caller checks workspace membership before issuing or revoking a registration,
// and authenticates the relay's endpoint before redeeming a token.
import { createHash, randomBytes } from "node:crypto";
import type { DatabaseSync } from "node:sqlite";

import { ENROLLMENT_TABLES } from "../store/mesh-schema.ts";
export { ENROLLMENT_TABLES } from "../store/mesh-schema.ts";
const KEY = /^[0-9a-f]{64}$/;
const TTL_MS = 24 * 60 * 60 * 1000;
const TOKEN_LIMIT = 32;
const ACTIVE_LIMIT = 32;
const RECORD_LIMIT = 256;
export type RelayRegistration = {
  scope: string; node: string; issuer: string; generation: number;
  name: string; made_by: string; revoked: number;
};

function key(value: string): string {
  if (!KEY.test(value)) throw new Error("invalid mesh identity or scope");
  return value;
}
function hash(token: string): string {
  if (!/^[A-Za-z0-9_-]{43}$/.test(token)) throw new Error("invalid relay enrollment token");
  return createHash("sha256").update(token).digest("hex");
}

export class RelayEnrollment {
  readonly db: DatabaseSync;
  readonly issuer: string;
  readonly now: () => number;
  readonly secret: () => string;
  constructor(db: DatabaseSync, issuer: string, now: () => number, secret: () => string = () => randomBytes(32).toString("base64url")) {
    this.db = db;
    this.issuer = key(issuer);
    this.now = now;
    this.secret = secret;
    db.exec(ENROLLMENT_TABLES);
  }

  #transaction<T>(work: () => T): T {
    this.db.exec("BEGIN IMMEDIATE");
    try {
      const result = work();
      this.db.exec("COMMIT");
      return result;
    } catch (error) {
      this.db.exec("ROLLBACK");
      throw error;
    }
  }

  issue(scope: string, name: string, by: string): { token: string; expires: number; issuer: string; scope: string } {
    key(scope);
    name = name.trim();
    if (!name || name.length > 80 || !by || by.length > 200) throw new Error("invalid relay enrollment name or issuer attribution");
    const now = this.now();
    const token = this.secret();
    const digest = hash(token);
    return this.#transaction(() => {
      this.db.prepare("DELETE FROM mesh_relay_tokens WHERE scope = ? AND expires <= ?").run(scope, now);
      const count = this.db.prepare("SELECT COUNT(*) AS n FROM mesh_relay_tokens WHERE scope = ?").get(scope)!;
      if (Number(count.n) >= TOKEN_LIMIT) throw new Error("too many pending relay enrollment tokens");
      const expires = now + TTL_MS;
      this.db.prepare("INSERT INTO mesh_relay_tokens(hash, scope, name, made_by, expires) VALUES (?, ?, ?, ?, ?)")
        .run(digest, scope, name, by, expires);
      return { token, expires, issuer: this.issuer, scope };
    });
  }

  // `node` comes from the authenticated transport, never a claimed request field.
  // A new token can explicitly re-enroll a revoked identity at a higher generation.
  redeem(scope: string, token: string, node: string): RelayRegistration {
    key(scope); key(node);
    const digest = hash(token);
    const now = this.now();
    return this.#transaction(() => {
      const pending = this.db.prepare("SELECT name, made_by FROM mesh_relay_tokens WHERE hash = ? AND scope = ? AND expires > ?")
        .get(digest, scope, now);
      if (!pending) throw new Error("relay enrollment token is invalid, expired, or already used");
      const old = this.db.prepare("SELECT * FROM mesh_relay_registrations WHERE scope = ? AND node = ?").get(scope, node);
      if (old && old.issuer !== this.issuer) throw new Error("relay registration belongs to another issuer");
      const counts = this.db.prepare("SELECT COUNT(*) AS total, SUM(CASE WHEN revoked = 0 THEN 1 ELSE 0 END) AS active FROM mesh_relay_registrations WHERE scope = ?").get(scope)!;
      if ((!old && Number(counts.total) >= RECORD_LIMIT) || ((!old || old.revoked) && Number(counts.active) >= ACTIVE_LIMIT)) {
        throw new Error("workspace relay registration limit reached");
      }
      const generation = Number(old?.generation ?? 0) + 1;
      if (!Number.isSafeInteger(generation)) throw new Error("relay generation exhausted");
      this.db.prepare(`INSERT INTO mesh_relay_registrations(scope, node, issuer, generation, name, made_by, revoked) VALUES (?, ?, ?, ?, ?, ?, 0)
        ON CONFLICT(scope, node) DO UPDATE SET generation = excluded.generation, name = excluded.name, made_by = excluded.made_by, revoked = 0`)
        .run(scope, node, this.issuer, generation, String(pending.name), String(pending.made_by));
      this.db.prepare("DELETE FROM mesh_relay_tokens WHERE hash = ?").run(digest);
      return { scope, node, issuer: this.issuer, generation, name: String(pending.name), made_by: String(pending.made_by), revoked: 0 };
    });
  }

  revoke(scope: string, node: string): RelayRegistration {
    key(scope); key(node);
    return this.#transaction(() => {
      const old = this.db.prepare("SELECT * FROM mesh_relay_registrations WHERE scope = ? AND node = ? AND issuer = ?").get(scope, node, this.issuer);
      if (!old) throw new Error("relay registration is not held by this issuer");
      const generation = Number(old.generation) + (old.revoked ? 0 : 1);
      if (!Number.isSafeInteger(generation)) throw new Error("relay generation exhausted");
      this.db.prepare("UPDATE mesh_relay_registrations SET revoked = 1, generation = ? WHERE scope = ? AND node = ?")
        .run(generation, scope, node);
      return { scope, node, issuer: this.issuer, generation, name: String(old.name), made_by: String(old.made_by), revoked: 1 };
    });
  }
}
