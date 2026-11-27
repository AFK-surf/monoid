// What the station keeps of the vaults it holds: each vault's and each item's latest version, as signed,
// and the box certificates the workspace's app devices published. Ciphertext and signatures only; who may write what is
// checked before (crypto.ts). Its tables beside the store's, in the same database (`CREATE TABLE IF NOT EXISTS`: a
// station from before has none, and one from before opens this one's database as it was).
import type { DatabaseSync } from "node:sqlite";
import type { BoxCert, Item, JoinAsk, JoinDismiss, KeyAsk, Vault } from "./crypto.ts";
import { hasInvalidVaultMembers, initializeVaultMembers, vaultMembersComplete } from "./member-index.ts";

const DELETED_WRITE = "vault was deleted during the write";

/// A concurrent deletion blocked a write after its caller had already checked the vault.
export function isDeletedVaultWrite(error: unknown): boolean {
  return error instanceof Error && error.message === DELETED_WRITE;
}

const SCHEMA = `
CREATE TABLE IF NOT EXISTS vaults (
  ws TEXT NOT NULL,
  id TEXT NOT NULL,
  seq INTEGER NOT NULL,
  body TEXT NOT NULL,
  PRIMARY KEY (ws, id)
);
CREATE TABLE IF NOT EXISTS vault_items (
  ws TEXT NOT NULL,
  vault TEXT NOT NULL,
  id TEXT NOT NULL,
  version INTEGER NOT NULL,
  body TEXT NOT NULL,
  PRIMARY KEY (ws, vault, id)
);
CREATE TABLE IF NOT EXISTS vault_boxes (
  ws TEXT NOT NULL,
  device TEXT NOT NULL,
  body TEXT NOT NULL,
  PRIMARY KEY (ws, device)
);
CREATE TABLE IF NOT EXISTS vault_asks (
  ws TEXT NOT NULL,
  vault TEXT NOT NULL,
  device TEXT NOT NULL,
  box TEXT NOT NULL,
  at INTEGER NOT NULL,
  body TEXT NOT NULL,
  PRIMARY KEY (ws, vault, device)
) WITHOUT ROWID;
CREATE INDEX IF NOT EXISTS vault_asks_vault_at ON vault_asks (ws, vault, at DESC, device);
CREATE TABLE IF NOT EXISTS vault_joins (
  ws TEXT NOT NULL,
  vault TEXT NOT NULL,
  sub TEXT NOT NULL,
  at INTEGER NOT NULL,
  state TEXT NOT NULL,
  body TEXT,
  dismiss_up_to INTEGER NOT NULL DEFAULT -1,
  dismiss_body TEXT,
  PRIMARY KEY (ws, vault, sub)
) WITHOUT ROWID;
CREATE INDEX IF NOT EXISTS vault_joins_vault_at ON vault_joins (ws, vault, state, at DESC, sub);
-- A previous station can have validated a write before this station commits a deletion. These checks also apply to
-- its already-prepared UPSERT statements when it resumes, without scanning old rows during installation.
CREATE TRIGGER IF NOT EXISTS vault_item_deleted_insert BEFORE INSERT ON vault_items
  WHEN EXISTS (SELECT 1 FROM vaults v WHERE v.ws = NEW.ws AND v.id = NEW.vault
    AND CASE WHEN json_valid(v.body) THEN json_type(v.body, '$.deleted') = 'true' ELSE 0 END)
  BEGIN SELECT RAISE(ABORT, '${DELETED_WRITE}'); END;
CREATE TRIGGER IF NOT EXISTS vault_item_deleted_update BEFORE UPDATE ON vault_items
  WHEN EXISTS (SELECT 1 FROM vaults v WHERE v.ws = NEW.ws AND v.id = NEW.vault
    AND CASE WHEN json_valid(v.body) THEN json_type(v.body, '$.deleted') = 'true' ELSE 0 END)
  BEGIN SELECT RAISE(ABORT, '${DELETED_WRITE}'); END;
CREATE TRIGGER IF NOT EXISTS vault_deleted_stays_deleted_insert BEFORE INSERT ON vaults
  WHEN EXISTS (SELECT 1 FROM vaults v WHERE v.ws = NEW.ws AND v.id = NEW.id
    AND CASE WHEN json_valid(v.body) THEN json_type(v.body, '$.deleted') = 'true' ELSE 0 END)
    AND (CASE WHEN json_valid(NEW.body) THEN json_type(NEW.body, '$.deleted') IS NOT 'true' ELSE 1 END)
  BEGIN SELECT RAISE(ABORT, '${DELETED_WRITE}'); END;
CREATE TRIGGER IF NOT EXISTS vault_deleted_stays_deleted BEFORE UPDATE OF body ON vaults
  WHEN (CASE WHEN json_valid(OLD.body) THEN json_type(OLD.body, '$.deleted') = 'true' ELSE 0 END)
    AND (CASE WHEN json_valid(NEW.body) THEN json_type(NEW.body, '$.deleted') IS NOT 'true' ELSE 1 END)
  BEGIN SELECT RAISE(ABORT, '${DELETED_WRITE}'); END;
-- Older stations save the deleted version and remove its items in separate statements. Do the removal inside their
-- first statement as well, so a crash or error between those statements does not leave the items behind.
CREATE TRIGGER IF NOT EXISTS vault_deleted_items_insert AFTER INSERT ON vaults
  WHEN CASE WHEN json_valid(NEW.body) THEN json_type(NEW.body, '$.deleted') = 'true' ELSE 0 END
  BEGIN DELETE FROM vault_items WHERE ws = NEW.ws AND vault = NEW.id; END;
CREATE TRIGGER IF NOT EXISTS vault_deleted_items_update AFTER UPDATE OF body ON vaults
  WHEN CASE WHEN json_valid(NEW.body) THEN json_type(NEW.body, '$.deleted') = 'true' ELSE 0 END
  BEGIN DELETE FROM vault_items WHERE ws = NEW.ws AND vault = NEW.id; END;
CREATE TRIGGER IF NOT EXISTS vault_deleted_asks_insert AFTER INSERT ON vaults
  WHEN CASE WHEN json_valid(NEW.body) THEN json_type(NEW.body, '$.deleted') = 'true' ELSE 0 END
  BEGIN DELETE FROM vault_asks WHERE ws = NEW.ws AND vault = NEW.id; END;
CREATE TRIGGER IF NOT EXISTS vault_deleted_asks_update AFTER UPDATE OF body ON vaults
  WHEN CASE WHEN json_valid(NEW.body) THEN json_type(NEW.body, '$.deleted') = 'true' ELSE 0 END
  BEGIN DELETE FROM vault_asks WHERE ws = NEW.ws AND vault = NEW.id; END;
CREATE TRIGGER IF NOT EXISTS vault_deleted_joins_insert AFTER INSERT ON vaults
  WHEN CASE WHEN json_valid(NEW.body) THEN json_type(NEW.body, '$.deleted') = 'true' ELSE 0 END
  BEGIN DELETE FROM vault_joins WHERE ws = NEW.ws AND vault = NEW.id; END;
CREATE TRIGGER IF NOT EXISTS vault_deleted_joins_update AFTER UPDATE OF body ON vaults
  WHEN CASE WHEN json_valid(NEW.body) THEN json_type(NEW.body, '$.deleted') = 'true' ELSE 0 END
  BEGIN DELETE FROM vault_joins WHERE ws = NEW.ws AND vault = NEW.id; END;
`;

const parse = <T>(rows: unknown[]): T[] => rows.map((r) => JSON.parse((r as { body: string }).body) as T);

export const MEMBER_VAULTS = `SELECT v.body FROM vault_member_lookup m
  CROSS JOIN vaults v ON v.ws = m.ws AND v.id = m.vault
  WHERE m.ws = ? AND m.sub = ? ORDER BY m.vault`;
export const MEMBER_VAULTS_MANY = `SELECT DISTINCT v.body FROM vault_member_lookup m
  CROSS JOIN vaults v ON v.ws = m.ws AND v.id = m.vault
  WHERE m.ws = ? AND m.sub IN (SELECT value FROM json_each(?)) ORDER BY m.vault LIMIT ?`;

export class VaultStore {
  readonly #db: DatabaseSync;
  /// Moves on with each vault or box certificate written here (`version`).
  #version = 0;

  constructor(db: DatabaseSync) {
    this.#db = db;
    db.exec(SCHEMA);
    initializeVaultMembers(db);
  }

  /// Moves on as a vault or a box certificate is written here: what is made of them (the vault's lock where the
  /// workspace is not in security mode, cloud/vault-lock.ts) is made again only then.
  version(): number {
    return this.#version;
  }

  /// Every vault of a workspace held here, latest versions.
  vaults(ws: string): Vault[] {
    return parse(this.#db.prepare("SELECT body FROM vaults WHERE ws = ? ORDER BY id").all(ws));
  }

  /// Candidate vaults in the same order as the full list. Callers still check membership on the held body.
  memberVaults(ws: string, sub: string): Vault[] {
    // SQLite and JavaScript encode isolated surrogate code units differently; keep JavaScript's comparison for them.
    if (!sub.isWellFormed()) return this.vaults(ws);
    // A small workspace is cheaper to read directly; this probe visits at most 33 index entries, not vault bodies.
    if (this.#db.prepare("SELECT 1 FROM vaults WHERE ws = ? LIMIT 1 OFFSET 32").get(ws) === undefined) return this.vaults(ws);
    // The index state, its anomaly markers and the rows must all be read from the same snapshot.
    this.#db.exec("SAVEPOINT vault_member_read");
    try {
      if (!vaultMembersComplete(this.#db, ws) || hasInvalidVaultMembers(this.#db, ws)) return this.vaults(ws);
      return parse(this.#db.prepare(MEMBER_VAULTS).all(ws, sub));
    } finally {
      this.#db.exec("RELEASE vault_member_read");
    }
  }

  /// Candidate vaults belonging to any of `subs` (e.g. workspace owners/admins for zero-schema workspace vault
  /// discovery), using a single SAVEPOINT and at most one fallback scan when the workspace is small or the index is
  /// still backfilling.
  memberVaultsMany(ws: string, subs: readonly string[], limit = 64): Vault[] {
    if (subs.length === 0 || limit <= 0) return [];
    if (subs.some((s) => !s.isWellFormed())) return this.vaults(ws);
    if (this.#db.prepare("SELECT 1 FROM vaults WHERE ws = ? LIMIT 1 OFFSET 32").get(ws) === undefined) return this.vaults(ws);
    this.#db.exec("SAVEPOINT vault_member_many_read"); // deferred: read-only snapshot
    try {
      if (!vaultMembersComplete(this.#db, ws) || hasInvalidVaultMembers(this.#db, ws)) return this.vaults(ws);
      return parse(this.#db.prepare(MEMBER_VAULTS_MANY).all(ws, JSON.stringify(subs), limit));
    } finally {
      this.#db.exec("RELEASE vault_member_many_read");
    }
  }

  /// A short ordered prefix and its database keys, followed by the rest only when a search needs it.
  firstVaults(ws: string, limit: number): { id: string; value: Vault }[] {
    const rows = this.#db.prepare("SELECT id, body FROM vaults WHERE ws = ? ORDER BY id LIMIT ?").all(ws, limit) as { id: string; body: string }[];
    return rows.map((row) => ({ id: row.id, value: JSON.parse(row.body) as Vault }));
  }

  vaultsAfter(ws: string, id: string): Vault[] {
    return parse(this.#db.prepare("SELECT body FROM vaults WHERE ws = ? AND id > ? ORDER BY id").all(ws, id));
  }

  vault(ws: string, id: string): Vault | null {
    return this.vaultSnapshot(ws, id)?.value ?? null;
  }

  /// Exact bodies let a later decision check the vault and item it validated have not changed.
  vaultSnapshot(ws: string, id: string): { value: Vault; body: string } | null {
    const row = this.#db.prepare("SELECT body FROM vaults WHERE ws = ? AND id = ?").get(ws, id) as { body: string } | undefined;
    return row ? { value: JSON.parse(row.body) as Vault, body: row.body } : null;
  }

  /// A vault's new version, in place of the one before (checked to follow it). Deleted, its items go with it: sealed
  /// under a key no one holds any more.
  putVault(v: Vault): void {
    this.#version++;
    const save = this.#db.prepare("INSERT INTO vaults (ws, id, seq, body) VALUES (?, ?, ?, ?) ON CONFLICT (ws, id) DO UPDATE SET seq = excluded.seq, body = excluded.body");
    if (!v.deleted) {
      save.run(v.ws, v.id, v.seq, JSON.stringify(v));
      return;
    }
    // A failure or interruption while deleting the items must not leave the deleted version beside its old items.
    // A savepoint also works when the caller is already in a transaction.
    this.#db.exec("SAVEPOINT vault_delete");
    try {
      save.run(v.ws, v.id, v.seq, JSON.stringify(v));
      this.#db.prepare("DELETE FROM vault_items WHERE ws = ? AND vault = ?").run(v.ws, v.id);
      this.#db.prepare("DELETE FROM vault_asks WHERE ws = ? AND vault = ?").run(v.ws, v.id);
      this.#db.prepare("DELETE FROM vault_joins WHERE ws = ? AND vault = ?").run(v.ws, v.id);
      this.#db.exec("RELEASE vault_delete");
    } catch (error) {
      try { this.#db.exec("ROLLBACK TO vault_delete; RELEASE vault_delete"); } catch { /* SQLite may already have rolled back. */ }
      throw error;
    }
  }

  /// Save only if the version checked by the caller is still the one held. `null` means there was no vault.
  putVaultIf(v: Vault, previous: string | null): boolean {
    return this.putVaultChecked(v, previous) === "saved";
  }

  /// Atomic vault CAS write with optional join-request approval precondition (`approveJoin`) and newly-added member
  /// `vault_joins` floor update (`dismiss_up_to = MAX(dismiss_up_to, vault_joins.at)` using the applicant's own ask
  /// clock so a later removal cannot resurrect the pre-join request).
  putVaultChecked(
    v: Vault,
    previous: string | null,
    opts?: { addedSubs?: readonly string[]; approveJoin?: { sub: string; at: number } },
  ): "saved" | "conflict" | "join_cancelled" {
    const body = JSON.stringify(v);
    const save = () => previous === null
      ? this.#db.prepare(`INSERT INTO vaults (ws, id, seq, body)
          SELECT ?, ?, ?, ? WHERE NOT EXISTS (SELECT 1 FROM vaults WHERE ws = ? AND id = ?)`)
        .run(v.ws, v.id, v.seq, body, v.ws, v.id).changes > 0
      : this.#db.prepare("UPDATE vaults SET seq = ?, body = ? WHERE ws = ? AND id = ? AND body = ?")
        .run(v.seq, body, v.ws, v.id, previous).changes > 0;
    const needsTx = Boolean(v.deleted) || opts?.approveJoin !== undefined || (opts?.addedSubs !== undefined && opts.addedSubs.length > 0);
    if (!needsTx) {
      this.#version++;
      return save() ? "saved" : "conflict";
    }
    this.#db.exec("BEGIN IMMEDIATE");
    try {
      if (opts?.approveJoin !== undefined) {
        const ok = this.#db.prepare(
          "SELECT 1 FROM vault_joins WHERE ws = ? AND vault = ? AND sub = ? AND state = 'pending' AND at = ? AND at > dismiss_up_to",
        ).get(v.ws, v.id, opts.approveJoin.sub, opts.approveJoin.at);
        if (ok === undefined) {
          this.#db.exec("ROLLBACK");
          return "join_cancelled";
        }
      }
      this.#version++;
      const saved = save();
      if (!saved) {
        this.#db.exec("ROLLBACK");
        return "conflict";
      }
      if (v.deleted) {
        this.#db.prepare("DELETE FROM vault_items WHERE ws = ? AND vault = ?").run(v.ws, v.id);
        this.#db.prepare("DELETE FROM vault_asks WHERE ws = ? AND vault = ?").run(v.ws, v.id);
        this.#db.prepare("DELETE FROM vault_joins WHERE ws = ? AND vault = ?").run(v.ws, v.id);
      } else if (opts?.addedSubs && opts.addedSubs.length > 0) {
        const bump = this.#db.prepare(
          "UPDATE vault_joins SET dismiss_up_to = CASE WHEN at > dismiss_up_to THEN at ELSE dismiss_up_to END WHERE ws = ? AND vault = ? AND sub = ?",
        );
        for (const sub of opts.addedSubs) bump.run(v.ws, v.id, sub);
      }
      this.#db.exec("COMMIT");
      return "saved";
    } catch (error) {
      try { this.#db.exec("ROLLBACK"); } catch { /* SQLite may already have rolled back. */ }
      throw error;
    }
  }

  /// A vault's items, latest versions (deleted ones too: a version saying so).
  items(ws: string, vault: string): Item[] {
    return parse(this.#db.prepare("SELECT body FROM vault_items WHERE ws = ? AND vault = ? ORDER BY id").all(ws, vault));
  }

  firstItems(ws: string, vault: string, limit: number): { id: string; value: Item }[] {
    const rows = this.#db.prepare("SELECT id, body FROM vault_items WHERE ws = ? AND vault = ? ORDER BY id LIMIT ?").all(ws, vault, limit) as { id: string; body: string }[];
    return rows.map((row) => ({ id: row.id, value: JSON.parse(row.body) as Item }));
  }

  itemsAfter(ws: string, vault: string, id: string): Item[] {
    return parse(this.#db.prepare("SELECT body FROM vault_items WHERE ws = ? AND vault = ? AND id > ? ORDER BY id").all(ws, vault, id));
  }

  item(ws: string, vault: string, id: string): Item | null {
    return this.itemSnapshot(ws, vault, id)?.value ?? null;
  }

  itemSnapshot(ws: string, vault: string, id: string): { value: Item; body: string } | null {
    const row = this.#db.prepare("SELECT body FROM vault_items WHERE ws = ? AND vault = ? AND id = ?").get(ws, vault, id) as { body: string } | undefined;
    return row ? { value: JSON.parse(row.body) as Item, body: row.body } : null;
  }

  /// What a move put here, taken back (move/vault.ts): an item, a vault with its items, no version kept.
  forgetItem(ws: string, vault: string, id: string): void {
    this.#db.prepare("DELETE FROM vault_items WHERE ws = ? AND vault = ? AND id = ?").run(ws, vault, id);
  }
  forgetVault(ws: string, id: string): void {
    this.#version++;
    this.#db.prepare("DELETE FROM vault_items WHERE ws = ? AND vault = ?").run(ws, id);
    this.#db.prepare("DELETE FROM vault_asks WHERE ws = ? AND vault = ?").run(ws, id);
    this.#db.prepare("DELETE FROM vault_joins WHERE ws = ? AND vault = ?").run(ws, id);
    this.#db.prepare("DELETE FROM vaults WHERE ws = ? AND id = ?").run(ws, id);
  }

  putItem(i: Item): void {
    this.#db.prepare("INSERT INTO vault_items (ws, vault, id, version, body) VALUES (?, ?, ?, ?, ?) ON CONFLICT (ws, vault, id) DO UPDATE SET version = excluded.version, body = excluded.body").run(i.ws, i.vault, i.id, i.version, JSON.stringify(i));
  }

  /// The parent vault and the previous item must both still be the bodies the caller checked.
  putItemIf(i: Item, vaultBody: string, previous: string | null): boolean {
    const body = JSON.stringify(i);
    if (previous === null) {
      return this.#db.prepare(`INSERT INTO vault_items (ws, vault, id, version, body)
        SELECT ?, ?, ?, ?, ? WHERE EXISTS (SELECT 1 FROM vaults WHERE ws = ? AND id = ? AND body = ?)
          AND NOT EXISTS (SELECT 1 FROM vault_items WHERE ws = ? AND vault = ? AND id = ?)`)
        .run(i.ws, i.vault, i.id, i.version, body, i.ws, i.vault, vaultBody, i.ws, i.vault, i.id).changes > 0;
    }
    return this.#db.prepare(`UPDATE vault_items SET version = ?, body = ?
      WHERE ws = ? AND vault = ? AND id = ? AND body = ?
        AND EXISTS (SELECT 1 FROM vaults WHERE ws = ? AND id = ? AND body = ?)`)
      .run(i.version, body, i.ws, i.vault, i.id, previous, i.ws, i.vault, vaultBody).changes > 0;
  }

  /// The box certificates published in a workspace, one per device (its latest).
  boxes(ws: string): BoxCert[] {
    return parse(this.#db.prepare("SELECT body FROM vault_boxes WHERE ws = ? ORDER BY device").all(ws));
  }

  /// The certificates held for these device ids, in the same order as the workspace's full list.
  boxesFor(ws: string, devices: readonly string[]): BoxCert[] {
    if (devices.length === 0) return [];
    return parse(this.#db.prepare("SELECT body FROM vault_boxes WHERE ws = ? AND device IN (SELECT value FROM json_each(?)) ORDER BY device")
      .all(ws, JSON.stringify(devices)));
  }

  box(ws: string, device: string): BoxCert | null {
    return this.boxSnapshot(ws, device)?.value ?? null;
  }

  boxSnapshot(ws: string, device: string): { value: BoxCert; body: string } | null {
    const row = this.#db.prepare("SELECT body FROM vault_boxes WHERE ws = ? AND device = ?").get(ws, device) as { body: string } | undefined;
    return row ? { value: JSON.parse(row.body) as BoxCert, body: row.body } : null;
  }

  putBox(cert: BoxCert): void {
    this.#version++;
    this.#db.prepare("INSERT INTO vault_boxes (ws, device, body) VALUES (?, ?, ?) ON CONFLICT (ws, device) DO UPDATE SET body = excluded.body").run(cert.ws, cert.device, JSON.stringify(cert));
  }

  /// Do not replace a certificate written after the caller checked the one held.
  putBoxIf(cert: BoxCert, previous: string | null): boolean {
    this.#version++;
    const body = JSON.stringify(cert);
    if (previous === null) return this.#db.prepare(`INSERT INTO vault_boxes (ws, device, body)
      SELECT ?, ?, ? WHERE NOT EXISTS (SELECT 1 FROM vault_boxes WHERE ws = ? AND device = ?)`)
      .run(cert.ws, cert.device, body, cert.ws, cert.device).changes > 0;
    return this.#db.prepare("UPDATE vault_boxes SET body = ? WHERE ws = ? AND device = ? AND body = ?")
      .run(body, cert.ws, cert.device, previous).changes > 0;
  }

  /// Explicit per-vault key asks for these vaults, newest first per vault via `vault_asks_vault_at`, using a bounded
  /// mixed-direction keyset cursor scan (`perVaultScan` per vault and `maxScan` total) so stale/rotated rows in one
  /// vault neither starve valid asks in that vault nor starve subsequent vaults.
  asksForVaults(
    ws: string,
    vaultIds: readonly string[],
    limit: number,
    opts?: { devices?: readonly string[]; perVault?: number; perVaultScan?: number; maxScan?: number; accept?: (a: KeyAsk) => boolean },
  ): KeyAsk[] {
    if (vaultIds.length === 0 || limit <= 0) return [];
    const devices = opts?.devices;
    if (devices !== undefined && devices.length === 0) return [];
    const perVault = Math.min(opts?.perVault ?? 64, limit);
    const perVaultScan = Math.max(perVault, opts?.perVaultScan ?? 128);
    const maxScan = Math.max(perVaultScan, opts?.maxScan ?? 512);
    const accept = opts?.accept;
    const out: KeyAsk[] = [];
    const devicesJson = devices !== undefined ? JSON.stringify(devices) : null;
    const firstStmt = devicesJson !== null
      ? this.#db.prepare(
        "SELECT at, device, body FROM vault_asks WHERE ws = ? AND vault = ? AND device IN (SELECT value FROM json_each(?)) ORDER BY at DESC, device ASC LIMIT ?",
      )
      : this.#db.prepare(
        "SELECT at, device, body FROM vault_asks WHERE ws = ? AND vault = ? ORDER BY at DESC, device ASC LIMIT ?",
      );
    const nextStmt = devicesJson !== null
      ? this.#db.prepare(
        "SELECT at, device, body FROM vault_asks WHERE ws = ? AND vault = ? AND device IN (SELECT value FROM json_each(?)) AND (at < ? OR (at = ? AND device > ?)) ORDER BY at DESC, device ASC LIMIT ?",
      )
      : this.#db.prepare(
        "SELECT at, device, body FROM vault_asks WHERE ws = ? AND vault = ? AND (at < ? OR (at = ? AND device > ?)) ORDER BY at DESC, device ASC LIMIT ?",
      );
    let totalScanned = 0;
    for (const vault of vaultIds) {
      if (out.length >= limit || totalScanned >= maxScan) break;
      const want = Math.min(perVault, limit - out.length);
      let taken = 0;
      let vaultScanned = 0;
      let cursorAt: number | null = null;
      let cursorDev = "";
      while (taken < want && vaultScanned < perVaultScan && totalScanned < maxScan) {
        const batch = Math.min(want - taken, perVaultScan - vaultScanned, maxScan - totalScanned);
        if (batch <= 0) break;
        const rows = (cursorAt === null
          ? (devicesJson !== null ? firstStmt.all(ws, vault, devicesJson, batch) : firstStmt.all(ws, vault, batch))
          : (devicesJson !== null
            ? nextStmt.all(ws, vault, devicesJson, cursorAt, cursorAt, cursorDev, batch)
            : nextStmt.all(ws, vault, cursorAt, cursorAt, cursorDev, batch))) as { at: number; device: string; body: string }[];
        if (rows.length === 0) break;
        vaultScanned += rows.length;
        totalScanned += rows.length;
        const last = rows[rows.length - 1]!;
        cursorAt = last.at;
        cursorDev = last.device;
        for (const r of rows) {
          const a = JSON.parse(r.body) as KeyAsk;
          if (accept !== undefined && !accept(a)) continue;
          out.push(a);
          taken++;
          if (taken >= want || out.length >= limit) break;
        }
        if (rows.length < batch) break;
      }
    }
    return out;
  }

  /// Snapshot of a member's join-request row (including dismiss-only tombstones where `body` is NULL and `state` is `'none'`).
  joinSnapshot(ws: string, vault: string, sub: string): {
    value: JoinAsk | null;
    body: string | null;
    dismissUpTo: number;
    dismiss: JoinDismiss | null;
    dismissBody: string | null;
  } | null {
    const row = this.#db.prepare(
      "SELECT body, dismiss_up_to, dismiss_body FROM vault_joins WHERE ws = ? AND vault = ? AND sub = ?",
    ).get(ws, vault, sub) as { body: string | null; dismiss_up_to: number; dismiss_body: string | null } | undefined;
    if (!row) return null;
    const value = row.body !== null && row.body !== "" ? (JSON.parse(row.body) as JoinAsk) : null;
    const dismiss = row.dismiss_body !== null && row.dismiss_body !== "" ? (JSON.parse(row.dismiss_body) as JoinDismiss) : null;
    return { value, body: row.body, dismissUpTo: row.dismiss_up_to, dismiss, dismissBody: row.dismiss_body };
  }

  /// Save a signed `JoinAsk` (`pending` or `cancelled`) only if the parent vault and previous `body` still match,
  /// preserving any existing `dismiss_up_to` and `dismiss_body`.
  putJoinIf(join: JoinAsk, vaultBody: string, previousBody: string | null, rowExists: boolean): boolean {
    const body = JSON.stringify(join);
    if (!rowExists) {
      return this.#db.prepare(`INSERT INTO vault_joins (ws, vault, sub, at, state, body)
        SELECT ?, ?, ?, ?, ?, ? WHERE EXISTS (SELECT 1 FROM vaults WHERE ws = ? AND id = ? AND body = ?)
          AND NOT EXISTS (SELECT 1 FROM vault_joins WHERE ws = ? AND vault = ? AND sub = ?)`)
        .run(join.ws, join.vault, join.sub, join.at, join.state, body, join.ws, join.vault, vaultBody, join.ws, join.vault, join.sub).changes > 0;
    }
    if (previousBody === null) {
      return this.#db.prepare(`UPDATE vault_joins SET at = ?, state = ?, body = ?
        WHERE ws = ? AND vault = ? AND sub = ? AND body IS NULL
          AND EXISTS (SELECT 1 FROM vaults WHERE ws = ? AND id = ? AND body = ?)`)
        .run(join.at, join.state, body, join.ws, join.vault, join.sub, join.ws, join.vault, vaultBody).changes > 0;
    }
    return this.#db.prepare(`UPDATE vault_joins SET at = ?, state = ?, body = ?
      WHERE ws = ? AND vault = ? AND sub = ? AND body = ?
        AND EXISTS (SELECT 1 FROM vaults WHERE ws = ? AND id = ? AND body = ?)`)
      .run(join.at, join.state, body, join.ws, join.vault, join.sub, previousBody, join.ws, join.vault, vaultBody).changes > 0;
  }

  /// Record a signed admin `JoinDismiss` watermark monotonically (never regressing `dismiss_up_to`), inserting a
  /// dismiss-only tombstone (`state = 'none'`, `body = NULL`) if the station has not seen the ask yet.
  putJoinDismissIf(dismiss: JoinDismiss, vaultBody: string, previousDismissUpTo: number | null): boolean {
    const body = JSON.stringify(dismiss);
    if (previousDismissUpTo === null) {
      return this.#db.prepare(`INSERT INTO vault_joins (ws, vault, sub, at, state, body, dismiss_up_to, dismiss_body)
        SELECT ?, ?, ?, 0, 'none', NULL, ?, ? WHERE EXISTS (SELECT 1 FROM vaults WHERE ws = ? AND id = ? AND body = ?)
          AND NOT EXISTS (SELECT 1 FROM vault_joins WHERE ws = ? AND vault = ? AND sub = ?)`)
        .run(dismiss.ws, dismiss.vault, dismiss.sub, dismiss.upTo, body, dismiss.ws, dismiss.vault, vaultBody, dismiss.ws, dismiss.vault, dismiss.sub).changes > 0;
    }
    return this.#db.prepare(`UPDATE vault_joins SET dismiss_up_to = ?, dismiss_body = ?
      WHERE ws = ? AND vault = ? AND sub = ? AND dismiss_up_to = ?
        AND (? > dismiss_up_to OR dismiss_body IS NULL)
        AND EXISTS (SELECT 1 FROM vaults WHERE ws = ? AND id = ? AND body = ?)`)
      .run(dismiss.upTo, body, dismiss.ws, dismiss.vault, dismiss.sub, previousDismissUpTo, dismiss.upTo, dismiss.ws, dismiss.vault, vaultBody).changes > 0;
  }

  /// Pending workspace-vault join asks for managing admins, newest first via `vault_joins_vault_at`, with bounded
  /// per-vault and total keyset scans.
  joinsForVaults(
    ws: string,
    vaultIds: readonly string[],
    limit: number,
    opts?: { perVault?: number; perVaultScan?: number; maxScan?: number; accept?: (a: JoinAsk, dismissUpTo: number) => boolean },
  ): JoinAsk[] {
    if (vaultIds.length === 0 || limit <= 0) return [];
    const perVault = Math.min(opts?.perVault ?? 64, limit);
    const perVaultScan = Math.max(perVault, opts?.perVaultScan ?? 128);
    const maxScan = Math.max(perVaultScan, opts?.maxScan ?? 512);
    const accept = opts?.accept;
    const out: JoinAsk[] = [];
    const firstStmt = this.#db.prepare(
      "SELECT at, sub, body, dismiss_up_to FROM vault_joins WHERE ws = ? AND vault = ? AND state = 'pending' ORDER BY at DESC, sub ASC LIMIT ?",
    );
    const nextStmt = this.#db.prepare(
      "SELECT at, sub, body, dismiss_up_to FROM vault_joins WHERE ws = ? AND vault = ? AND state = 'pending' AND (at < ? OR (at = ? AND sub > ?)) ORDER BY at DESC, sub ASC LIMIT ?",
    );
    let totalScanned = 0;
    for (const vault of vaultIds) {
      if (out.length >= limit || totalScanned >= maxScan) break;
      const want = Math.min(perVault, limit - out.length);
      let taken = 0;
      let vaultScanned = 0;
      let cursorAt: number | null = null;
      let cursorSub = "";
      while (taken < want && vaultScanned < perVaultScan && totalScanned < maxScan) {
        const batch = Math.min(want - taken, perVaultScan - vaultScanned, maxScan - totalScanned);
        if (batch <= 0) break;
        const rows = (cursorAt === null
          ? firstStmt.all(ws, vault, batch)
          : nextStmt.all(ws, vault, cursorAt, cursorAt, cursorSub, batch)) as { at: number; sub: string; body: string | null; dismiss_up_to: number }[];
        if (rows.length === 0) break;
        vaultScanned += rows.length;
        totalScanned += rows.length;
        const last = rows[rows.length - 1]!;
        cursorAt = last.at;
        cursorSub = last.sub;
        for (const r of rows) {
          if (r.body === null || r.body === "" || r.at <= r.dismiss_up_to) continue;
          const a = JSON.parse(r.body) as JoinAsk;
          if (accept !== undefined && !accept(a, r.dismiss_up_to)) continue;
          out.push(a);
          taken++;
          if (taken >= want || out.length >= limit) break;
        }
        if (rows.length < batch) break;
      }
    }
    return out;
  }

  /// Signed admin join-dismiss records for these workspace vaults, bounded per vault for cross-station convergence.
  joinDismissesForVaults(ws: string, vaultIds: readonly string[], limit: number, accept?: (d: JoinDismiss) => boolean): JoinDismiss[] {
    if (vaultIds.length === 0 || limit <= 0) return [];
    const out: JoinDismiss[] = [];
    const stmt = this.#db.prepare(
      "SELECT dismiss_body FROM vault_joins WHERE ws = ? AND vault = ? AND dismiss_body IS NOT NULL ORDER BY sub ASC LIMIT ?",
    );
    for (const vault of vaultIds) {
      const remain = limit - out.length;
      if (remain <= 0) break;
      const rows = stmt.all(ws, vault, remain) as { dismiss_body: string }[];
      for (const r of rows) {
        if (!r.dismiss_body) continue;
        const d = JSON.parse(r.dismiss_body) as JoinDismiss;
        if (accept !== undefined && !accept(d)) continue;
        out.push(d);
        if (out.length >= limit) break;
      }
    }
    return out;
  }

  /// Direct O(1) PK lookup of `sub`'s own join state on each discoverable workspace vault.
  ownJoinsForVaults(ws: string, vaultIds: readonly string[], sub: string): { joins: JoinAsk[]; dismisses: JoinDismiss[]; floors: Record<string, number> } {
    const joins: JoinAsk[] = [];
    const dismisses: JoinDismiss[] = [];
    const floors: Record<string, number> = {};
    const stmt = this.#db.prepare(
      "SELECT body, dismiss_up_to, dismiss_body FROM vault_joins WHERE ws = ? AND vault = ? AND sub = ?",
    );
    for (const vault of vaultIds) {
      const row = stmt.get(ws, vault, sub) as { body: string | null; dismiss_up_to: number; dismiss_body: string | null } | undefined;
      if (!row) continue;
      if (row.body !== null && row.body !== "") joins.push(JSON.parse(row.body) as JoinAsk);
      if (row.dismiss_body !== null && row.dismiss_body !== "") dismisses.push(JSON.parse(row.dismiss_body) as JoinDismiss);
      if (row.dismiss_up_to >= 0) floors[vault] = row.dismiss_up_to;
    }
    return { joins, dismisses, floors };
  }

  askSnapshot(ws: string, vault: string, device: string): { value: KeyAsk; body: string } | null {
    const row = this.#db.prepare("SELECT body FROM vault_asks WHERE ws = ? AND vault = ? AND device = ?").get(ws, vault, device) as { body: string } | undefined;
    return row ? { value: JSON.parse(row.body) as KeyAsk, body: row.body } : null;
  }

  putAsk(ask: KeyAsk): void {
    this.#db.prepare(
      "INSERT INTO vault_asks (ws, vault, device, box, at, body) VALUES (?, ?, ?, ?, ?, ?) ON CONFLICT (ws, vault, device) DO UPDATE SET box = excluded.box, at = excluded.at, body = excluded.body",
    ).run(ask.ws, ask.vault, ask.device, ask.box, ask.at, JSON.stringify(ask));
  }

  /// Save a key ask only if the parent vault and the previous ask are still the exact bodies the caller checked.
  putAskIf(ask: KeyAsk, vaultBody: string, previous: string | null): boolean {
    const body = JSON.stringify(ask);
    if (previous === null) {
      return this.#db.prepare(`INSERT INTO vault_asks (ws, vault, device, box, at, body)
        SELECT ?, ?, ?, ?, ?, ? WHERE EXISTS (SELECT 1 FROM vaults WHERE ws = ? AND id = ? AND body = ?)
          AND NOT EXISTS (SELECT 1 FROM vault_asks WHERE ws = ? AND vault = ? AND device = ?)`)
        .run(ask.ws, ask.vault, ask.device, ask.box, ask.at, body, ask.ws, ask.vault, vaultBody, ask.ws, ask.vault, ask.device).changes > 0;
    }
    return this.#db.prepare(`UPDATE vault_asks SET box = ?, at = ?, body = ?
      WHERE ws = ? AND vault = ? AND device = ? AND body = ?
        AND EXISTS (SELECT 1 FROM vaults WHERE ws = ? AND id = ? AND body = ?)`)
      .run(ask.box, ask.at, body, ask.ws, ask.vault, ask.device, previous, ask.ws, ask.vault, vaultBody).changes > 0;
  }

  /// Remove stored asks that are now satisfied by `keys` (matching `device` and `box`) or belong to removed devices.
  pruneAsks(ws: string, vault: string, keys: readonly { cert: { device: string; box: string } }[], removedDevices: readonly string[] = []): void {
    if (keys.length > 0) {
      const del = this.#db.prepare("DELETE FROM vault_asks WHERE ws = ? AND vault = ? AND device = ? AND box = ?");
      for (const k of keys) del.run(ws, vault, k.cert.device, k.cert.box);
    }
    if (removedDevices.length > 0) {
      const delDev = this.#db.prepare("DELETE FROM vault_asks WHERE ws = ? AND vault = ? AND device = ?");
      for (const d of removedDevices) delDev.run(ws, vault, d);
    }
  }
}

const made = new WeakMap<DatabaseSync, VaultStore>();

/// The vault store of a database: one per database, whoever asks (the vault's routes, the keeper's).
export function vaultStore(db: DatabaseSync): VaultStore {
  let s = made.get(db);
  if (!s) made.set(db, (s = new VaultStore(db)));
  return s;
}
