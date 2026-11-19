import { digest, nowSeconds, pastedSecret, randomSecret } from "../auth";
import { verifyKeySignature } from "../grants";
import type { MeshRelayEvents } from "../mesh-relay-events";
import { meshRegistration, meshRelayMessage, type MeshRelay } from "../mesh-relay-registry";
import { RELAY_TOKEN_TTL_SEC, relayPut, relayTokenOf, type RelayListed, type RelayTokenInput } from "../relay-registry";
import { ownRelay, relayUrl, sameUrl, type Listed, type Relays } from "../relays";
import type { DirectoryDb, DirectoryHost } from "./db";
import { fail, type Attachment } from "./types";

// ── the cloud's relays (relays.ts, relay-registry.ts) ───────────────────

export class DirectoryRelays {
  #db: DirectoryDb;
  #host: DirectoryHost;
  #meshEvents: MeshRelayEvents;

  constructor(db: DirectoryDb, host: DirectoryHost, meshEvents: MeshRelayEvents) {
    this.#db = db;
    this.#host = host;
    this.#meshEvents = meshEvents;
  }

  meshRelays(): MeshRelay[] {
    return this.#db.meshRelays();
  }

  async meshRelayRegister(body: unknown, signature: unknown, enroll: boolean): Promise<MeshRelay> {
    const input = meshRegistration(body, enroll, this.#db.env.PUBLIC_ORIGIN.startsWith("http:")) ?? fail(400, "invalid_request");
    if (typeof signature !== "string" || !await verifyKeySignature(input.node, signature, meshRelayMessage(this.#db.env.PUBLIC_ORIGIN, body as string))) fail(401, "invalid_signature");
    const hash = enroll ? await digest(input.token!) : null;
    // All awaits precede the token/row read. Consumption and the generation
    // change are one transaction, including concurrent attempts with one token.
    const result = this.#db.ctx.storage.transactionSync(() => {
      const old = this.#db.one("SELECT * FROM mesh_relays WHERE node = ?", input.node);
      if (enroll) {
        const token = this.#db.one("SELECT * FROM relay_tokens WHERE token_hash = ? AND expires_at > ?", hash!, nowSeconds()) ?? fail(403, "invalid_token");
        if (token.url !== null || token.target !== null) fail(403, "wrong_relay_kind");
        if ((!old || old.revoked) && this.#host.meshRelays().length >= 32) fail(409, "too_many_mesh_relays");
        if (!old && (this.#db.one("SELECT COUNT(*) AS n FROM mesh_relays")?.n as number) >= 256) fail(409, "mesh_registry_capacity");
        const generation = old ? Number(old.generation) + 1 : 1;
        if (!Number.isSafeInteger(generation)) fail(409, "mesh_generation_exhausted");
        this.#db.run("DELETE FROM relay_tokens WHERE token_hash = ?", hash!);
        this.#db.run(`INSERT INTO mesh_relays (node,name,generation,revision,address,revoked,added_at,added_by) VALUES (?,?,?,?,?,0,?,?)
          ON CONFLICT(node) DO UPDATE SET name=excluded.name,generation=excluded.generation,revision=excluded.revision,address=excluded.address,revoked=0,added_at=excluded.added_at,added_by=excluded.added_by`,
          input.node, token.name as string, generation, input.revision, JSON.stringify(input.address), nowSeconds(), token.made_by as string);
        return { node: input.node, name: token.name as string, generation, revision: input.revision, address: input.address };
      }
      if (!old || old.revoked || old.generation !== input.generation) fail(403, "mesh_relay_not_registered");
      if (input.revision <= Number(old!.revision)) fail(409, "stale_mesh_address");
      this.#db.run("UPDATE mesh_relays SET revision = ?, address = ? WHERE node = ?", input.revision, JSON.stringify(input.address), input.node);
      return { node: input.node, name: old!.name as string, generation: Number(old!.generation), revision: input.revision, address: input.address };
    });
    this.#relaysChanged();
    return result;
  }

  meshRelayRemove(node: unknown): void {
    if (typeof node !== "string" || !/^[0-9a-f]{64}$/.test(node)) fail(400, "invalid_node");
    if (!this.#db.one("SELECT node FROM mesh_relays WHERE node = ?", node as string)) fail(404, "mesh_relay_not_found");
    this.#db.run("UPDATE mesh_relays SET revoked = 1 WHERE node = ?", node as string);
    this.#relaysChanged();
  }

  /** The same, for what reads it outside this object (status.ts, relay-load.ts, the probes). */
  relaysNow(): Relays {
    return this.#db.relays(this.#host.meshRelays());
  }

  /** The list as the console shows it, and the tokens made for relays not used yet. */
  relayList(): { own: string; relays: RelayListed[]; tokens: { name: string; url: string | null; target: string | null; expires_at: number }[] } {
    const now = nowSeconds();
    this.#db.run("DELETE FROM relay_tokens WHERE expires_at <= ?", now);
    return {
      own: ownRelay(this.#db.env),
      relays: this.#db.rows("SELECT url, name, target, secret_hash, added_at, added_by FROM relays ORDER BY added_at, rowid").map((r) => ({
        url: r.url as string, name: r.name as string, target: (r.target as string | null) ?? null, added_at: r.added_at as number, added_by: r.added_by as string, enrolled: r.secret_hash !== null,
      })),
      // (`id`: the first 16 characters of its digest, to take it back by; never the token nor its whole digest)
      tokens: this.#db.rows("SELECT token_hash, name, url, target, expires_at FROM relay_tokens ORDER BY expires_at").map((r) => ({ id: (r.token_hash as string).slice(0, 16), name: r.name as string, url: (r.url as string | null) ?? null, target: (r.target as string | null) ?? null, expires_at: r.expires_at as number })),
    };
  }

  /** The operator takes back a token made for a relay not used yet (made by mistake), by its `id` (relayList). */
  relayTokenRevoke(id: unknown): { revoked: true } {
    if (typeof id !== "string" || !/^[A-Za-z0-9_-]{16}$/.test(id)) fail(400, "invalid_request");
    const gone = this.#db.ctx.storage.sql.exec("DELETE FROM relay_tokens WHERE substr(token_hash, 1, 16) = ?", id).rowsWritten;
    if (gone > 0) this.#relaysChanged();
    return { revoked: true };
  }

  /** The operator puts a relay on the list (or names it anew, or changes what an entry is a way into). */
  relayPut(by: string, input: RelayTokenInput): Listed {
    const put = relayPut(input, this.#db.relays(this.#host.meshRelays()), this.#db.env.PUBLIC_ORIGIN.startsWith("http:"));
    if (typeof put === "string") fail(400, put);
    const { url, name, target } = put as Listed;
    this.#db.run(`INSERT INTO relays (url, name, target, added_at, added_by) VALUES (?, ?, ?, ?, ?)
      ON CONFLICT (url) DO UPDATE SET name = excluded.name, target = excluded.target`, url, name, target, nowSeconds(), by);
    this.#relaysChanged();
    return put as Listed;
  }

  /** The operator takes a relay off the list, and the ways into it with it; its tokens made for it go too. */
  relayRemove(url: unknown): void {
    if (typeof url !== "string") fail(400, "invalid_relay");
    const found = this.#db.rows("SELECT url FROM relays").map((r) => r.url as string).find((u) => sameUrl(u) === sameUrl(url as string)) ?? fail(404, "relay_not_found");
    this.#db.ctx.storage.transactionSync(() => {
      this.#db.run("DELETE FROM relays WHERE url = ? OR target = ?", found, found);
      this.#db.run("DELETE FROM relay_tokens WHERE url = ? OR target = ?", found, found);
    });
    this.#relaysChanged();
  }

  /** A token for a relay to put itself on the list with (relay-enroll.sh): good for RELAY_TOKEN_TTL_SEC, once. */
  async relayToken(by: string, input: RelayTokenInput): Promise<{ token: string; name: string; url: string | null; expires_at: number }> {
    const made = relayTokenOf(input, this.#db.relays(this.#host.meshRelays()), this.#db.env.PUBLIC_ORIGIN.startsWith("http:"));
    if (typeof made === "string") fail(400, made);
    const { name, url, target } = made as Exclude<typeof made, string>;
    const token = pastedSecret();
    const expires = nowSeconds() + RELAY_TOKEN_TTL_SEC;
    this.#db.run("DELETE FROM relay_tokens WHERE expires_at <= ?", nowSeconds());
    this.#db.run("INSERT INTO relay_tokens (token_hash, name, url, target, made_by, expires_at) VALUES (?, ?, ?, ?, ?, ?)", await digest(token), name, url, target, by, expires);
    return { token, name, url, expires_at: expires };
  }

  /**
   * A relay puts itself on the list with a token the operator made (POST /v1/relays/enroll): at the URL the token names,
   * or the one it says where the token names none. Given a secret of its own, which its counters come with
   * (relay-load.ts); one on the list already is given a new one (and the token's name). Nothing awaits between the
   * token read and its use, so it is used once.
   */
  async relayEnrolled(token: unknown, said: unknown): Promise<{ url: string; name: string; secret: string }> {
    if (typeof token !== "string" || token === "") fail(400, "invalid_request");
    const hash = await digest(token as string);
    const secret = randomSecret();
    const secretHash = await digest(secret);
    const row = this.#db.one("SELECT name, url, target, made_by FROM relay_tokens WHERE token_hash = ? AND expires_at > ?", hash, nowSeconds()) ?? fail(403, "invalid_token");
    const insecure = this.#db.env.PUBLIC_ORIGIN.startsWith("http:");
    const url = (row!.url as string | null) ?? relayUrl(said, insecure) ?? fail(400, "invalid_relay");
    if (said !== undefined && said !== null && said !== "" && sameUrl(String(said)) !== sameUrl(url as string)) fail(403, "wrong_relay");
    const put = relayPut({ url, name: row!.name, target: row!.target }, this.#db.relays(this.#host.meshRelays()), insecure);
    if (typeof put === "string") fail(400, put);
    const { name, target } = put as Listed;
    this.#db.ctx.storage.transactionSync(() => {
      this.#db.run("DELETE FROM relay_tokens WHERE token_hash = ?", hash);
      this.#db.run(`INSERT INTO relays (url, name, target, secret_hash, added_at, added_by) VALUES (?, ?, ?, ?, ?, ?)
        ON CONFLICT (url) DO UPDATE SET name = excluded.name, target = excluded.target, secret_hash = excluded.secret_hash`, (put as Listed).url, name, target, secretHash, nowSeconds(), `token:${row!.made_by as string}`);
    });
    this.#relaysChanged();
    return { url: (put as Listed).url, name, secret };
  }

  /**
   * Which relay of the list sent its counters (relay-load.ts): the one whose secret it came with; else, one listed
   * with no secret of its own (as the deploy's config listed them) named by `named`, believed by the address it came
   * from (`from`, which Cloudflare saw) being its URL's.
   */
  relayHeard(secretHash: string | null, named: string, from: string | null): string {
    if (secretHash !== null) return (this.#db.one("SELECT url FROM relays WHERE secret_hash = ?", secretHash)?.url as string | undefined) ?? fail(403, "invalid_secret");
    const row = this.#db.rows("SELECT url, secret_hash FROM relays WHERE target IS NULL").find((r) => sameUrl(r.url as string) === sameUrl(named)) ?? fail(400, "unknown_relay");
    if (row!.secret_hash !== null) fail(403, "not_from_relay");
    if (!from || new URL(row!.url as string).hostname.replace(/^\[|\]$/g, "") !== from) fail(403, "not_from_relay");
    return row!.url as string;
  }

  /** The list changed: every station connected is sent its state again (its relays in it), every device told to read
   * its `/v1/me` again. */
  #relaysChanged(): void {
    this.#meshEvents.changed(this.#host.meshRelays());
    const stations = new Set(this.#db.rows("SELECT key FROM live WHERE kind = 'station'").map((r) => r.key as string));
    for (const ws of this.#db.ctx.getWebSockets()) {
      const attachment = ws.deserializeAttachment() as Attachment;
      if ("station" in attachment && !attachment.dropped) stations.add(attachment.station);
    }
    for (const station of stations) this.#host.sendState(station);
    this.#host.tellAll({ type: "workspaces" }, null);
    // (the operator's console shows the list: its 中继 page read again, as the minute's sample has it)
    this.#host.tell(this.#host.adminSubs(), { type: "relays" });
  }
}
