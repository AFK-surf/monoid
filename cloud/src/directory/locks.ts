import { nowSeconds } from "../auth";
import { apply, asEntry, entryHash, genesis, keepLockAt, LockAppendRefused, shortCode, type Entry, type LockEntry, type LockState } from "../lock";
import { relays } from "../relays";
import type { DeviceView, LockHead, LockRequestView, Role } from "../types";
import type { DirectoryDb, DirectoryHost } from "./db";
import { LOCK_REQUEST_TTL_SEC, MANAGERS, fail } from "./types";

// ── the workspace lock (lock.ts): kept and carried, not trusted ─────────────────────────

export class DirectoryLocks {
  #db: DirectoryDb;
  #host: DirectoryHost;
  #lockSeen: Set<string>;

  constructor(db: DirectoryDb, host: DirectoryHost, lockSeen: Set<string>) {
    this.#db = db;
    this.#host = host;
    this.#lockSeen = lockSeen;
  }

  /** The kept chain checked once a workspace while this object lives (#lockState): what it reads after is what checks out. */
  #lockChecked(workspace: string): void {
    if (this.#lockSeen.has(workspace)) return;
    this.#lockSeen.add(workspace);
    this.#lockState(workspace);
  }

  /**
   * The kept chain's state as a station takes it (null: none), what does not check out cut off with everything after
   * it: entries kept before the cloud checked them (until 2026-10-29), which every station refused, and every entry
   * after them with them (a workspace's new devices turned away for days). Its stations and members are told.
   */
  #lockState(workspace: string): LockState | null {
    let state: LockState | null = null;
    for (const r of this.#db.rows("SELECT seq, entry FROM lock_entries WHERE workspace = ? ORDER BY seq", workspace)) {
      try {
        const e = JSON.parse(r.entry as string) as Entry;
        state = state === null ? genesis(e) : apply(state, e, null);
      } catch (error) {
        this.#db.run("DELETE FROM lock_entries WHERE workspace = ? AND seq >= ?", workspace, r.seq);
        console.warn(`lock: ${workspace}'s kept lock cut back before entry ${String(r.seq)}, which no station takes: ${(error as Error).message}`);
        // Not from inside what is being told (a state frame reads the head).
        queueMicrotask(() => this.#host.changed(workspace, false));
        break;
      }
    }
    return state;
  }

  lockHead(workspace: string): LockHead | null {
    this.#lockChecked(workspace);
    const last = this.#db.one("SELECT seq, hash FROM lock_entries WHERE workspace = ? ORDER BY seq DESC LIMIT 1", workspace);
    if (!last) return null;
    const first = this.#db.one("SELECT hash FROM lock_entries WHERE workspace = ? AND seq = 0", workspace);
    return { seq: last.seq as number, hash: last.hash as string, genesis: (first?.hash as string) ?? "" };
  }

  /** How many devices wait to be confirmed, of those the caller sees (all for owners and admins, their own for others). */
  lockRequestCount(workspace: string, sub: string, role: Role): number {
    return this.#lockRequestRows(workspace, sub, role).length;
  }

  /**
   * The devices waiting to be confirmed that the caller sees, oldest first: not past their time, and of one person's
   * devices with the same kind and name (the same browser on the same computer, its storage cleared; an app installed
   * again) only the latest.
   */
  #lockRequestRows(workspace: string, sub: string, role: Role): Record<string, unknown>[] {
    const rows = this.#db.rows(
      `SELECT r.base, r.sub, COALESCE(u.email, '') AS email, r.request, r.created_at FROM lock_requests r LEFT JOIN users u ON u.sub = r.sub
        WHERE r.workspace = ? AND (? OR r.sub = ?) AND r.created_at > ? ORDER BY r.created_at DESC, r.rowid DESC`,
      workspace, MANAGERS.includes(role) ? 1 : 0, sub, nowSeconds() - LOCK_REQUEST_TTL_SEC,
    );
    const seen = new Set<string>();
    return rows.filter((r) => {
      const { kind, label } = JSON.parse(r.request as string) as { kind: string; label: string };
      if (!label) return true;
      const same = JSON.stringify([r.sub, kind, label]);
      if (seen.has(same)) return false;
      seen.add(same);
      return true;
    }).reverse();
  }

  /** Whether a workspace is locked: it has a chain, not turned off. */
  locked(workspace: string): boolean {
    this.#lockChecked(workspace);
    const last = this.#db.one("SELECT entry FROM lock_entries WHERE workspace = ? ORDER BY seq DESC LIMIT 1", workspace);
    return last !== undefined && (JSON.parse(last.entry as string) as LockEntry).kind !== "disable";
  }

  /** Whether a workspace's chain moved to its people's logs (`moved {root}`, its last entry for good): whether it is on
   * is said there, never here, and `#locked` stays true. */
  moved(workspace: string): boolean {
    this.#lockChecked(workspace);
    const last = this.#db.one("SELECT entry FROM lock_entries WHERE workspace = ? ORDER BY seq DESC LIMIT 1", workspace);
    return last !== undefined && (JSON.parse(last.entry as string) as LockEntry).kind === "moved";
  }

  /** The entries after `after` of a chain of the workspace's turned off (its genesis' hash), none if none is kept. */
  lockTurnedOff(workspace: string, genesis: string, after: number): unknown[] {
    return this.#db.rows("SELECT entry FROM lock_turned_off WHERE workspace = ? AND genesis = ? AND seq > ? ORDER BY seq", workspace, genesis, after).map((r) => JSON.parse(r.entry as string));
  }

  lockAfter(workspace: string, after: number): unknown[] {
    this.#lockChecked(workspace);
    return this.#db.rows("SELECT entry FROM lock_entries WHERE workspace = ? AND seq > ? ORDER BY seq", workspace, after).map((r) => JSON.parse(r.entry as string));
  }

  /** The lock's head and its entries after `after`, for any member. */
  lock(sub: string, workspace: string, after: number): { head: LockHead | null; entries: unknown[] } {
    this.#db.role(sub, workspace);
    return { head: this.lockHead(workspace), entries: this.lockAfter(workspace, after) };
  }

  /**
   * Entries that follow the kept chain (those it has are skipped; one that disagrees is refused, with the rest). A
   * genesis starts a chain where there is none, or where the last one was turned off. Stations and members' devices
   * bring them; each is checked as a station checks it (signed by whom it may be), and one a station would refuse is
   * refused here, with the rest: kept, it would leave every entry after it refused at the stations. `fork`: what
   * another keeper took (a station of the lock, a device saying `keep`), kept by the rules' fork choice among all kept
   * (lock.ts `keepLockAt`): the chain gone by (`lock_entries`, what every reader reads) is their active chain, the rest
   * kept beside it (`lock_aside`, none in a record from before).
   */
  async appendLockInternal(workspace: string, raw: unknown, fork = false): Promise<LockHead | null> {
    const entries = (Array.isArray(raw) ? raw : []).map(asEntry);
    if (entries.length === 0 || entries.length > 256 || entries.some((e) => e === null || e.ws !== workspace)) fail(400, "invalid_lock_entries");
    // Nothing else runs on this object between the reads and the writes below (no await between them), so they are
    // one step. What is refused throws before anything is written.
    this.#lockChecked(workspace);
    const parse = (r: Record<string, unknown>) => JSON.parse(r.entry as string) as LockEntry;
    const kept = {
      entries: this.#db.rows("SELECT entry FROM lock_entries WHERE workspace = ? ORDER BY seq", workspace).map(parse),
      aside: this.#db.rows("SELECT entry FROM lock_aside WHERE workspace = ? ORDER BY rowid", workspace).map(parse),
    };
    let plan: ReturnType<typeof keepLockAt>;
    try {
      plan = keepLockAt(kept, entries as LockEntry[], nowSeconds(), fork);
    } catch (e) {
      if (e instanceof LockAppendRefused) fail(e.status, e.code);
      throw e;
    }
    const { restart, changed, moved, kept: now } = plan!;
    if (changed) {
      this.#db.ctx.storage.transactionSync(() => {
        if (restart) {
          // A chain turned off, kept for the stations that missed its end (lockTurnedOff).
          const genesisHash = this.#db.one("SELECT hash FROM lock_entries WHERE workspace = ? AND seq = 0", workspace)?.hash;
          if (typeof genesisHash === "string") this.#db.run("INSERT OR IGNORE INTO lock_turned_off (workspace, genesis, seq, entry) SELECT workspace, ?, seq, entry FROM lock_entries WHERE workspace = ?", genesisHash, workspace);
        }
        // (from where the chain now parts from the one kept: a branch that won replaces it from there)
        const hashes = kept.entries.map(entryHash);
        let from = 0;
        while (!restart && from < now.entries.length && from < hashes.length && entryHash(now.entries[from]!) === hashes[from]) from++;
        this.#db.run("DELETE FROM lock_entries WHERE workspace = ? AND seq >= ?", workspace, from);
        for (const e of now.entries.slice(from)) this.#db.run("INSERT INTO lock_entries (workspace, seq, hash, entry) VALUES (?, ?, ?, ?)", workspace, e.seq, entryHash(e), JSON.stringify(e));
        const aside = new Set(now.aside.map(entryHash));
        const had = new Set(kept.aside.map(entryHash));
        for (const h of had) if (!aside.has(h)) this.#db.run("DELETE FROM lock_aside WHERE workspace = ? AND hash = ?", workspace, h);
        for (const e of now.aside) if (!had.has(entryHash(e))) this.#db.run("INSERT INTO lock_aside (workspace, hash, entry) VALUES (?, ?, ?)", workspace, entryHash(e), JSON.stringify(e));
      });
      // (its lock alone moved on: said in the event, so the members' devices need not ask for the workspace again)
      if (moved) this.#host.changed(workspace, false, [], "lock");
    }
    return this.lockHead(workspace);
  }

  /** A member's device brings entries (its own signer's, or what a station had more: `keep`, what a station took). */
  async appendLock(sub: string, workspace: string, entries: unknown, keep = false): Promise<{ head: LockHead | null }> {
    this.#db.role(sub, workspace);
    return { head: await this.appendLockInternal(workspace, entries, keep) };
  }

  /** The owner lets the kept lock go (its signers lost: each station is reset on its own machine). */
  clearLock(sub: string, workspace: string): void {
    this.#db.role(sub, workspace, ["owner"]);
    this.#db.run("DELETE FROM lock_entries WHERE workspace = ?", workspace);
    this.#db.run("DELETE FROM lock_aside WHERE workspace = ?", workspace);
    this.#host.changed(workspace, false);
  }

  /** A device asked for a credential: kept for the owner to check when the lock is turned on. The relays it is told
   * with the credential. */
  recordDevice(sub: string, workspace: string, device: string, said: { base?: string; kind?: string; label?: string }): ReturnType<typeof relays> {
    const now = nowSeconds();
    this.#db.run(
      `INSERT INTO devices (workspace, sub, device, base, kind, label, first_seen, last_seen) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT (workspace, sub, device) DO UPDATE SET base = COALESCE(excluded.base, base), kind = COALESCE(excluded.kind, kind), label = COALESCE(excluded.label, label), last_seen = excluded.last_seen`,
      workspace, sub, device, said.base ?? null, said.kind ?? null, said.label ?? null, now, now,
    );
    return relays(this.#db.relays(this.#host.meshRelays()), true);
  }

  /** The devices that asked for credentials in the workspace in the last 31 days: its owners and admins see everyone's
   * (what turning the lock on lists, when each was last used), a member their own. */
  devices(sub: string, workspace: string): { devices: DeviceView[] } {
    const manages = MANAGERS.includes(this.#db.role(sub, workspace));
    const devices = this.#db.rows(
      `SELECT d.sub, COALESCE(u.email, '') AS email, d.device, d.base, d.kind, d.label, d.first_seen, d.last_seen FROM devices d LEFT JOIN users u ON u.sub = d.sub
        WHERE d.workspace = ? AND d.last_seen >= ? AND d.sub IN (SELECT sub FROM members WHERE workspace = ?) AND (? OR d.sub = ?) ORDER BY d.sub, d.last_seen DESC`,
      workspace, nowSeconds() - 31 * 86400, workspace, manages ? 1 : 0, sub,
    ) as unknown as DeviceView[];
    return { devices };
  }

  /** A member's new device asks to be confirmed into the lock: its owners and admins, and the member's other devices, are told. */
  async requestLock(sub: string, workspace: string, input: Record<string, unknown>): Promise<LockRequestView> {
    this.#db.role(sub, workspace);
    const base = typeof input.base === "string" && /^[0-9a-f]{64}$/.test(input.base) ? input.base : fail(400, "invalid_device");
    const kind = input.kind === "app" || input.kind === "web" ? input.kind : fail(400, "invalid_kind");
    const label = typeof input.label === "string" ? input.label.slice(0, 120) : "";
    const sign_key = typeof input.sign_key === "string" && input.sign_key.length <= 200 ? input.sign_key : null;
    const endpoints = Array.isArray(input.endpoints) ? input.endpoints.filter((e): e is string => typeof e === "string" && /^[0-9a-f]{64}$/.test(e)).slice(0, 16) : [];
    const code = await shortCode(base);
    const request = { kind, label, sign_key, endpoints };
    // Asked again, it waits anew; those past their time, and the person's others it now stands for (the same kind and
    // name: see #lockRequestRows), go.
    this.#db.run("DELETE FROM lock_requests WHERE workspace = ? AND created_at <= ?", workspace, nowSeconds() - LOCK_REQUEST_TTL_SEC);
    if (label) {
      this.#db.run("DELETE FROM lock_requests WHERE workspace = ? AND sub = ? AND base != ? AND json_extract(request, '$.kind') = ? AND json_extract(request, '$.label') = ?", workspace, sub, base, kind, label);
    }
    this.#db.run(
      "INSERT INTO lock_requests (workspace, base, sub, request, created_at) VALUES (?, ?, ?, ?, ?) ON CONFLICT (workspace, base) DO UPDATE SET sub = excluded.sub, request = excluded.request, created_at = excluded.created_at",
      workspace, base, sub, JSON.stringify(request), nowSeconds(),
    );
    // (its requests alone changed: said in the event, so a device of today, which shows none, asks for nothing)
    this.#host.changed(workspace, false, [], "requests");
    return { base, sub, email: (this.#db.one("SELECT email FROM users WHERE sub = ?", sub)?.email as string) ?? "", ...request, code, created_at: nowSeconds() };
  }

  /** Devices waiting to be confirmed: all of them for owners and admins, a member's own for a member. */
  async lockRequests(sub: string, workspace: string): Promise<{ requests: LockRequestView[] }> {
    const rows = this.#lockRequestRows(workspace, sub, this.#db.role(sub, workspace));
    const requests = await Promise.all(rows.map(async (r) => ({ base: r.base as string, sub: r.sub as string, email: r.email as string, ...(JSON.parse(r.request as string) as { kind: string; label: string; sign_key: string | null; endpoints: string[] }), code: await shortCode(r.base as string), created_at: r.created_at as number })));
    return { requests };
  }

  /** A request answered (confirmed or turned down): gone from the list. Its member's own, or an owner's or admin's. */
  dropLockRequest(sub: string, workspace: string, base: string): void {
    const role = this.#db.role(sub, workspace);
    const row = this.#db.one("SELECT sub FROM lock_requests WHERE workspace = ? AND base = ?", workspace, base);
    if (!row) return;
    if (row.sub !== sub && !MANAGERS.includes(role)) fail(403, "forbidden");
    this.#db.run("DELETE FROM lock_requests WHERE workspace = ? AND base = ?", workspace, base);
    // (its requests alone changed: said in the event, so a device of today, which shows none, asks for nothing)
    this.#host.changed(workspace, false, [], "requests");
  }
}
