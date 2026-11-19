// A token grants a relay identity only. This protocol exposes no station data or
// application routes. The transport's authenticated key becomes the relay key.
import { createHash } from "node:crypto";
import { wall } from "../ops/fibers.ts";
import type { Connection, Stream } from "./endpoint.ts";
import { signRelayRecord, type SignedRelayRecord } from "./relay-records.ts";
import { RelayEnrollment, type RelayRegistration } from "./enrollment.ts";
import { Reader, writeLine } from "./wire.ts";

export const ENROLLMENT_ALPN = Buffer.from("stillfail/mesh-enrollment/1");
// app.monoid.build answers still.fail's workspaces as its guest (cloud/deploy.py `guests`): one cloud, so one scope,
// named by still.fail's origin as the scopes kept before it.
export function workspaceScope(origin: string, workspace: string): string {
  const trimmed = origin.replace(/\/+$/, "");
  const cloud = trimmed === "https://app.monoid.build" ? "https://app.still.fail" : trimmed;
  return createHash("sha256").update("mesh-workspace/v1\0").update(cloud).update("\0").update(workspace).digest("hex");
}
export class EnrollmentDoor {
  #active = 0;
  readonly registry: RelayEnrollment;
  readonly allowed: (scope: string) => boolean;
  readonly sign: (text: string) => string;
  readonly watch?: (scope: string, node: string, first: unknown, stream: Stream, conn: Connection, reader: Reader) => Promise<void>;
  readonly registered: (signed: SignedRelayRecord) => Promise<void>;
  readonly read: (scope: string, node: string) => Promise<RelayRegistration | null>;
  constructor(registry: RelayEnrollment, allowed: (scope: string) => boolean, sign: (text: string) => string, read: (scope: string, node: string) => Promise<RelayRegistration | null>, registered: (signed: SignedRelayRecord) => Promise<void> = async () => {}, watch?: EnrollmentDoor["watch"]) {
    this.watch = watch;
    this.registered = registered;
    this.read = read;
    this.registry = registry;
    this.allowed = allowed;
    this.sign = sign;
  }
  async answer(request: any, authenticatedNode: string): Promise<unknown> {
    if (!(request?.op === "enroll" || request?.op === "resume") || typeof request.scope !== "string" || (request.op === "enroll" && typeof request.token !== "string") || !this.allowed(request.scope)) {
      throw Object.assign(new Error("relay enrollment is not available for this scope"), { code: "relay_scope_unavailable" });
    }
    const record = request.op === "resume" ? await this.read(request.scope, authenticatedNode) : this.registry.redeem(request.scope, request.token, authenticatedNode);
    if (!record || record.revoked !== 0 || record.node !== authenticatedNode || record.scope !== request.scope || record.issuer !== this.registry.issuer) throw Object.assign(new Error("relay identity is not registered in this scope"), { code: "relay_not_registered" });
    if (!this.allowed(request.scope)) throw Object.assign(new Error("relay enrollment is not available for this scope"), { code: "relay_scope_unavailable" });
    const signed = signRelayRecord(record, this.sign);
    await this.registered(signed);
    return { record: JSON.parse(signed.body), ...signed };
  }
  async serve(conn: Connection): Promise<void> {
    if (this.#active >= 32) { conn.close(1, "relay enrollment busy"); return; }
    this.#active++;
    let stream: Stream | null = null;
    try {
      stream = await wall.within(10_000, conn.acceptBi(), "relay handshake deadline");
      if (!stream) return;
      const reader = new Reader(stream, 64 * 1024);
      const request = await wall.within(10_000, reader.line(), "relay request deadline");
      if (request?.op === "watch") {
        if (!this.watch) throw new Error("relay directory is not available");
        await this.answer({ op: "resume", scope: request.scope }, conn.remoteId());
        await this.watch(request.scope, conn.remoteId(), request.announcement, stream, conn, reader);
        return;
      }
      await writeLine(stream, { ok: await this.answer(request, conn.remoteId()) });
      await stream.finish();
      await wall.within(10_000, conn.closed(), "relay reply deadline");
    } catch (error) {
      if (stream && !conn.isClosed()) {
        try {
          await wall.within(1000, writeLine(stream, { error: (error as Error).message, code: (error as any).code }), "relay error reply deadline");
          await stream.finish();
          // The client must receive FIN before the connection is closed. It
          // acknowledges the reply by closing; the timeout bounds absent clients.
          await wall.within(1000, conn.closed(), "relay error delivery deadline");
        } catch {}
      }
      throw error;
    } finally { this.#active--; conn.close(0, "relay enrollment ended"); }
  }
}
