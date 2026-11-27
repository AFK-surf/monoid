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
-- Active workspace vault discovery index: vaults holds one row per vault (typically tens of rows per workspace, not an
-- append-only log), so creating this partial index is sub-millisecond and guarantees 0 temp B-trees on discovery.
CREATE INDEX IF NOT EXISTS vaults_workspace_active ON vaults (ws, id DESC)
  WHERE json_valid(body) AND json_extract(body, '$.scope') = 'workspace' AND json_type(body, '$.deleted') IS NOT 'true';
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
  joined_up_to INTEGER NOT NULL DEFAULT -1,
  dismiss_up_to INTEGER NOT NULL DEFAULT -1,
  dismiss_body TEXT,
  PRIMARY KEY (ws, vault, sub)
) WITHOUT ROWID;
CREATE INDEX IF NOT EXISTS vault_joins_vault_at ON vault_joins (ws, vault, state, at DESC, sub);
CREATE INDEX IF NOT EXISTS vault_joins_vault_dismiss ON vault_joins (ws, vault, sub) WHERE dismiss_body IS NOT NULL;
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
export const ACTIVE_WORKSPACE_VAULTS = `SELECT id, body FROM vaults
  WHERE ws = ? AND json_valid(body) AND json_extract(body, '$.scope') = 'workspace' AND json_type(body, '$.deleted') IS NOT 'true'
  ORDER BY id DESC LIMIT ?`;
export const ACTIVE_WORKSPACE_VAULTS_BEFORE = `SELECT id, body FROM vaults
  WHERE ws = ? AND json_valid(body) AND json_extract(body, '$.scope') = 'workspace' AND json_type(body, '$.deleted') IS NOT 'true'
    AND id < ?
  ORDER BY id DESC LIMIT ?`;

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

  /// Active workspace vaults in `ws`, newest ULID first, read directly via the `vaults_workspace_active` partial
  /// index with bounded keyset pagination (0 temp B-trees, never scanning personal or deleted vaults).
  activeWorkspaceVaults(
    ws: string,
    limit: number,
    opts?: { maxScan?: number; accept?: (v: Vault) => boolean },
  ): Vault[] {
    if (limit <= 0) return [];
    const maxScan = Math.max(limit, opts?.maxScan ?? 64);
    const accept = opts?.accept;
    const firstStmt = this.#db.prepare(ACTIVE_WORKSPACE_VAULTS);
    const nextStmt = this.#db.prepare(ACTIVE_WORKSPACE_VAULTS_BEFORE);
    const out: Vault[] = [];
    let scanned = 0;
    let cursorId: string | null = null;
    while (out.length < limit && scanned < maxScan) {
      const batch = Math.min(Math.max(limit - out.length, 8), maxScan - scanned);
      if (batch <= 0) break;
      const rows = (cursorId === null
        ? firstStmt.all(ws, batch)
        : nextStmt.all(ws, cursorId, batch)) as { id: string; body: string }[];
      if (rows.length === 0) break;
      scanned += rows.length;
      cursorId = rows[rows.length - 1]!.id;
      for (const r of rows) {
        const v = JSON.parse(r.body) as Vault;
        if (accept !== undefined && !accept(v)) continue;
        out.push(v);
        if (out.length >= limit) break;
      }
      if (rows.length < batch) break;
    }
    return out;
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

  /// Atomic vault CAS write with optional join-request approval precondition (`approveJoin`, requiring exact
  /// `(sub, at, device, box, sig)` match + wrapped key for the stored ask's `(device, box)`) and newly-added member
  /// `vault_joins` admission watermark update (`joined_up_to = MAX(joined_up_to, vault_joins.at)` using the applicant's
  /// own ask clock, kept separate from signed admin `dismiss_body`/`dismiss_up_to` so a later removal cannot resurrect
  /// the pre-join request even if the approving admin is later demoted).
  putVaultChecked(
    v: Vault,
    previous: string | null,
    opts?: {
      addedSubs?: readonly string[];
      approveJoin?: { sub: string; at: number; device: string; box: string; sig: string };
      isValidAsk?: (a: JoinAsk) => boolean;
      isActiveDismiss?: (d: JoinDismiss) => boolean;
    },
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
        const row = this.#db.prepare(
          "SELECT body, at, joined_up_to, dismiss_up_to, dismiss_body FROM vault_joins WHERE ws = ? AND vault = ? AND sub = ? AND state = 'pending' AND at = ? AND at > joined_up_to",
        ).get(v.ws, v.id, opts.approveJoin.sub, opts.approveJoin.at) as
          | { body: string | null; at: number; joined_up_to: number; dismiss_up_to: number; dismiss_body: string | null }
          | undefined;
        let askOkNow = false;
        if (row !== undefined && row.body !== null && row.body !== "") {
          const ask = JSON.parse(row.body) as JoinAsk;
          const matchesAsk = ask.device === opts.approveJoin.device
            && ask.box === opts.approveJoin.box
            && ask.sig?.sig === opts.approveJoin.sig;
          const hasWrappedKey = Array.isArray(v.keys) && v.keys.some((k) => k.cert.device === ask.device && k.cert.box === ask.box);
          const valid = opts.isValidAsk ? opts.isValidAsk(ask) : true;
          askOkNow = matchesAsk && hasWrappedKey && valid;
        }
        let dismissed = false;
        if (askOkNow && row !== undefined && row.dismiss_body !== null && row.dismiss_body !== "" && row.at <= row.dismiss_up_to) {
          const d = JSON.parse(row.dismiss_body) as JoinDismiss;
          dismissed = opts.isActiveDismiss ? opts.isActiveDismiss(d) : true;
        }
        if (!askOkNow || dismissed) {
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
          "UPDATE vault_joins SET joined_up_to = CASE WHEN at > joined_up_to THEN at ELSE joined_up_to END WHERE ws = ? AND vault = ? AND sub = ?",
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

  /// Explicit per-vault key asks for these vaults, newest first per vault.
  /// When active lock devices are supplied (any count), probes the PRIMARY KEY `(ws, vault, device)` in bounded
  /// batches of 256 so thousands of historical revoked-device asks are never scanned (O(activeDevices * log N),
  /// independent of revoked history). When `devices` is omitted, uses a split-range keyset cursor on `vault_asks_vault_at`.
  asksForVaults(
    ws: string,
    vaultIds: readonly string[],
    limit: number,
    opts?: { devices?: readonly string[]; perVault?: number; perVaultScan?: number; maxScan?: number; maxDevices?: number; accept?: (a: KeyAsk) => boolean },
  ): KeyAsk[] {
    if (vaultIds.length === 0 || limit <= 0) return [];
    const devices = opts?.devices;
    if (devices !== undefined && devices.length === 0) return [];
    const perVault = Math.min(opts?.perVault ?? 64, limit);
    const perVaultScan = Math.max(perVault, opts?.perVaultScan ?? 128);
    const maxScan = Math.max(perVaultScan, opts?.maxScan ?? 512);
    const accept = opts?.accept;
    const out: KeyAsk[] = [];
    if (devices !== undefined) {
      // Batched PK point-lookup per active device: O(activeDevices * log N), completely bypassing revoked-device rows
      // at any active-device count (no cliff at 257+ active devices).
      const pkStmt = this.#db.prepare(
        "SELECT at, device, body FROM vault_asks WHERE ws = ? AND vault = ? AND device IN (SELECT value FROM json_each(?))",
      );
      const maxDevices = Math.max(256, opts?.maxDevices ?? 2048);
      const cappedDevices = devices.length > maxDevices ? devices.slice(0, maxDevices) : devices;
      const chunks: string[] = [];
      for (let i = 0; i < cappedDevices.length; i += 256) {
        chunks.push(JSON.stringify(cappedDevices.slice(i, i + 256)));
      }
      let totalScanned = 0;
      for (const vault of vaultIds) {
        if (out.length >= limit || totalScanned >= maxScan) break;
        const want = Math.min(perVault, limit - out.length);
        const matched: { at: number; device: string; body: string }[] = [];
        let vaultScanned = 0;
        for (const chunkJson of chunks) {
          if (vaultScanned >= perVaultScan || totalScanned >= maxScan) break;
          const rows = pkStmt.all(ws, vault, chunkJson) as { at: number; device: string; body: string }[];
          if (rows.length === 0) continue;
          const takeRows = Math.min(rows.length, perVaultScan - vaultScanned, maxScan - totalScanned);
          for (let i = 0; i < takeRows; i++) matched.push(rows[i]!);
          vaultScanned += takeRows;
          totalScanned += takeRows;
        }
        if (matched.length === 0) continue;
        matched.sort((a, b) => (b.at - a.at) || (a.device < b.device ? -1 : a.device > b.device ? 1 : 0));
        let taken = 0;
        for (const r of matched) {
          const a = JSON.parse(r.body) as KeyAsk;
          if (accept !== undefined && !accept(a)) continue;
          out.push(a);
          taken++;
          if (taken >= want || out.length >= limit) break;
        }
      }
      return out;
    }
    const firstStmt = this.#db.prepare(
      "SELECT at, device, body FROM vault_asks WHERE ws = ? AND vault = ? ORDER BY at DESC, device ASC LIMIT ?",
    );
    const sameAtStmt = this.#db.prepare(
      "SELECT at, device, body FROM vault_asks INDEXED BY vault_asks_vault_at WHERE ws = ? AND vault = ? AND at = ? AND device > ? ORDER BY at DESC, device ASC LIMIT ?",
    );
    const olderStmt = this.#db.prepare(
      "SELECT at, device, body FROM vault_asks WHERE ws = ? AND vault = ? AND at < ? ORDER BY at DESC, device ASC LIMIT ?",
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
        let rows: { at: number; device: string; body: string }[];
        if (cursorAt === null) {
          rows = firstStmt.all(ws, vault, batch) as { at: number; device: string; body: string }[];
        } else {
          const sameRows = sameAtStmt.all(ws, vault, cursorAt, cursorDev, batch) as { at: number; device: string; body: string }[];
          if (sameRows.length < batch) {
            const rem = batch - sameRows.length;
            const olderRows = olderStmt.all(ws, vault, cursorAt, rem) as { at: number; device: string; body: string }[];
            rows = sameRows.length === 0 ? olderRows : [...sameRows, ...olderRows];
          } else {
            rows = sameRows;
          }
        }
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
    joinedUpTo: number;
    dismissUpTo: number;
    dismiss: JoinDismiss | null;
    dismissBody: string | null;
  } | null {
    const row = this.#db.prepare(
      "SELECT body, joined_up_to, dismiss_up_to, dismiss_body FROM vault_joins WHERE ws = ? AND vault = ? AND sub = ?",
    ).get(ws, vault, sub) as { body: string | null; joined_up_to: number; dismiss_up_to: number; dismiss_body: string | null } | undefined;
    if (!row) return null;
    const value = row.body !== null && row.body !== "" ? (JSON.parse(row.body) as JoinAsk) : null;
    const dismiss = row.dismiss_body !== null && row.dismiss_body !== "" ? (JSON.parse(row.dismiss_body) as JoinDismiss) : null;
    return { value, body: row.body, joinedUpTo: row.joined_up_to, dismissUpTo: row.dismiss_up_to, dismiss, dismissBody: row.dismiss_body };
  }

  /// Save a signed `JoinAsk` (`pending` or `cancelled`) only if the parent vault and previous `body` still match,
  /// preserving any existing `dismiss_up_to`, `dismiss_body`, and `joined_up_to` (unless `resetJoinedFloor` is set
  /// when replacing an ask from a revoked device).
  putJoinIf(join: JoinAsk, vaultBody: string, previousBody: string | null, rowExists: boolean, resetJoinedFloor = false): boolean {
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
    if (resetJoinedFloor) {
      return this.#db.prepare(`UPDATE vault_joins SET at = ?, state = ?, body = ?, joined_up_to = -1
        WHERE ws = ? AND vault = ? AND sub = ? AND body = ?
          AND EXISTS (SELECT 1 FROM vaults WHERE ws = ? AND id = ? AND body = ?)`)
        .run(join.at, join.state, body, join.ws, join.vault, join.sub, previousBody, join.ws, join.vault, vaultBody).changes > 0;
    }
    return this.#db.prepare(`UPDATE vault_joins SET at = ?, state = ?, body = ?
      WHERE ws = ? AND vault = ? AND sub = ? AND body = ?
        AND EXISTS (SELECT 1 FROM vaults WHERE ws = ? AND id = ? AND body = ?)`)
      .run(join.at, join.state, body, join.ws, join.vault, join.sub, previousBody, join.ws, join.vault, vaultBody).changes > 0;
  }

  /// Record a signed admin `JoinDismiss` watermark monotonically (never regressing `dismiss_up_to`), inserting a
  /// dismiss-only tombstone (`state = 'none'`, `body = NULL`) if the station has not seen the ask yet. When
  /// `allowReplaceInvalid` is true (e.g. a previously dismissing admin was demoted), allows replacing the exact
  /// `previousDismissBody` at the same `upTo`.
  putJoinDismissIf(
    dismiss: JoinDismiss,
    vaultBody: string,
    previousDismissUpTo: number | null,
    previousDismissBody: string | null = null,
    allowReplaceInvalid = false,
  ): boolean {
    const body = JSON.stringify(dismiss);
    if (previousDismissUpTo === null) {
      return this.#db.prepare(`INSERT INTO vault_joins (ws, vault, sub, at, state, body, dismiss_up_to, dismiss_body)
        SELECT ?, ?, ?, 0, 'none', NULL, ?, ? WHERE EXISTS (SELECT 1 FROM vaults WHERE ws = ? AND id = ? AND body = ?)
          AND NOT EXISTS (SELECT 1 FROM vault_joins WHERE ws = ? AND vault = ? AND sub = ?)`)
        .run(dismiss.ws, dismiss.vault, dismiss.sub, dismiss.upTo, body, dismiss.ws, dismiss.vault, vaultBody, dismiss.ws, dismiss.vault, dismiss.sub).changes > 0;
    }
    if (allowReplaceInvalid && previousDismissBody !== null) {
      return this.#db.prepare(`UPDATE vault_joins SET dismiss_up_to = ?, dismiss_body = ?
        WHERE ws = ? AND vault = ? AND sub = ? AND dismiss_up_to = ? AND dismiss_body = ?
          AND EXISTS (SELECT 1 FROM vaults WHERE ws = ? AND id = ? AND body = ?)`)
        .run(dismiss.upTo, body, dismiss.ws, dismiss.vault, dismiss.sub, previousDismissUpTo, previousDismissBody, dismiss.ws, dismiss.vault, vaultBody).changes > 0;
    }
    return this.#db.prepare(`UPDATE vault_joins SET dismiss_up_to = ?, dismiss_body = ?
      WHERE ws = ? AND vault = ? AND sub = ? AND dismiss_up_to = ?
        AND (? > dismiss_up_to OR dismiss_body IS NULL)
        AND EXISTS (SELECT 1 FROM vaults WHERE ws = ? AND id = ? AND body = ?)`)
      .run(dismiss.upTo, body, dismiss.ws, dismiss.vault, dismiss.sub, previousDismissUpTo, dismiss.upTo, dismiss.ws, dismiss.vault, vaultBody).changes > 0;
  }

  /// Signed workspace-vault join records (`pending` and `cancelled`) for managing admins, queried with completely
  /// independent per-state quotas AND scan budgets on `vault_joins_vault_at (ws, vault, state, at DESC, sub)` so
  /// filtered `pending` rows can never starve `cancelled` tombstones (nor vice versa), with resumable keyset cursor
  /// for `cancelled` tombstones.
  joinsForVaults(
    ws: string,
    vaultIds: readonly string[],
    limit: number,
    opts?: {
      perVault?: number;
      perVaultCancelled?: number;
      cancelledLimit?: number;
      perVaultScan?: number;
      maxScan?: number;
      cancelledMaxScan?: number;
      cancelledAfterVault?: string;
      cancelledAfterAt?: number;
      cancelledAfterSub?: string;
      accept?: (a: JoinAsk, joinedUpTo: number, dismiss: JoinDismiss | null) => boolean;
    },
  ): { joins: JoinAsk[]; nextCancelledCursor?: { vault: string; at: number; sub: string } } {
    if (vaultIds.length === 0 || limit <= 0) return { joins: [] };
    const perVault = Math.min(opts?.perVault ?? 64, limit);
    const cancelledLimit = opts?.cancelledLimit ?? 64;
    const perVaultCancelled = Math.min(opts?.perVaultCancelled ?? 64, cancelledLimit);
    const perVaultScan = Math.max(perVault, opts?.perVaultScan ?? 128);
    const maxScan = Math.max(perVaultScan, opts?.maxScan ?? 512);
    const cancelledMaxScan = Math.max(perVaultScan, opts?.cancelledMaxScan ?? maxScan);
    const accept = opts?.accept;
    const out: JoinAsk[] = [];
    const firstStmt = this.#db.prepare(
      "SELECT at, sub, body, joined_up_to, dismiss_body FROM vault_joins INDEXED BY vault_joins_vault_at WHERE ws = ? AND vault = ? AND state = ? ORDER BY at DESC, sub ASC LIMIT ?",
    );
    const sameAtStmt = this.#db.prepare(
      "SELECT at, sub, body, joined_up_to, dismiss_body FROM vault_joins INDEXED BY vault_joins_vault_at WHERE ws = ? AND vault = ? AND state = ? AND at = ? AND sub > ? ORDER BY at DESC, sub ASC LIMIT ?",
    );
    const olderStmt = this.#db.prepare(
      "SELECT at, sub, body, joined_up_to, dismiss_body FROM vault_joins INDEXED BY vault_joins_vault_at WHERE ws = ? AND vault = ? AND state = ? AND at < ? ORDER BY at DESC, sub ASC LIMIT ?",
    );
    const scanState = (
      state: "pending" | "cancelled",
      perVaultCap: number,
      stateLimit: number,
      stateMaxScan: number,
      after?: { vault: string; at: number; sub: string },
    ): { vault: string; at: number; sub: string } | undefined => {
      let stateEmitted = 0;
      let stateScanned = 0;
      let nextCursor: { vault: string; at: number; sub: string } | undefined;
      let lastVisited: { vault: string; at: number; sub: string } | null = null;
      let exhausted = false;
      const startIdx = after ? Math.max(0, vaultIds.indexOf(after.vault)) : 0;
      for (let vi = startIdx; vi < vaultIds.length; vi++) {
        const vault = vaultIds[vi]!;
        if (stateEmitted >= stateLimit) break;
        if (stateScanned >= stateMaxScan) {
          exhausted = true;
          break;
        }
        const want = Math.min(perVaultCap, stateLimit - stateEmitted);
        let taken = 0;
        let vaultScanned = 0;
        let cursorAt: number | null = vi === startIdx && after && after.vault === vault ? after.at : null;
        let cursorSub = vi === startIdx && after && after.vault === vault ? after.sub : "";
        while (taken < want && vaultScanned < perVaultScan && stateScanned < stateMaxScan) {
          const batch = Math.min(want - taken + 1, perVaultScan - vaultScanned, stateMaxScan - stateScanned);
          if (batch <= 0) {
            exhausted = true;
            break;
          }
          let rows: { at: number; sub: string; body: string | null; joined_up_to: number; dismiss_body: string | null }[];
          if (cursorAt === null) {
            rows = firstStmt.all(ws, vault, state, batch) as { at: number; sub: string; body: string | null; joined_up_to: number; dismiss_body: string | null }[];
          } else {
            const sameRows = sameAtStmt.all(ws, vault, state, cursorAt, cursorSub, batch) as { at: number; sub: string; body: string | null; joined_up_to: number; dismiss_body: string | null }[];
            if (sameRows.length < batch) {
              const olderRows = olderStmt.all(ws, vault, state, cursorAt, batch - sameRows.length) as { at: number; sub: string; body: string | null; joined_up_to: number; dismiss_body: string | null }[];
              rows = sameRows.length === 0 ? olderRows : [...sameRows, ...olderRows];
            } else {
              rows = sameRows;
            }
          }
          if (rows.length === 0) break;
          let hitVaultCap = false;
          for (let i = 0; i < rows.length; i++) {
            const r = rows[i]!;
            vaultScanned++;
            stateScanned++;
            cursorAt = r.at;
            cursorSub = r.sub;
            lastVisited = { vault, at: r.at, sub: r.sub };
            if (r.body === null || r.body === "") continue;
            const a = JSON.parse(r.body) as JoinAsk;
            const d = r.dismiss_body !== null && r.dismiss_body !== "" ? (JSON.parse(r.dismiss_body) as JoinDismiss) : null;
            if (accept !== undefined && !accept(a, r.joined_up_to, d)) continue;
            out.push(a);
            taken++;
            stateEmitted++;
            if (stateEmitted >= stateLimit) {
              if (i + 1 < rows.length || vi + 1 < vaultIds.length) {
                nextCursor = { vault, at: r.at, sub: r.sub };
              }
              break;
            }
            if (taken >= want) {
              hitVaultCap = true;
              break;
            }
          }
          if (nextCursor !== undefined || hitVaultCap) break;
          if (rows.length < batch) break;
        }
        if (nextCursor !== undefined) break;
        if (stateScanned >= stateMaxScan) {
          exhausted = true;
          break;
        }
      }
      if (nextCursor === undefined && exhausted && lastVisited !== null) {
        nextCursor = lastVisited;
      }
      return nextCursor;
    };
    scanState("pending", perVault, limit, maxScan);
    const cancelledAfter = opts?.cancelledAfterVault !== undefined && opts.cancelledAfterAt !== undefined && opts.cancelledAfterSub !== undefined
      ? { vault: opts.cancelledAfterVault, at: opts.cancelledAfterAt, sub: opts.cancelledAfterSub }
      : undefined;
    const nextCancelledCursor = scanState("cancelled", perVaultCancelled, cancelledLimit, cancelledMaxScan, cancelledAfter);
    return nextCancelledCursor !== undefined ? { joins: out, nextCancelledCursor } : { joins: out };
  }

  /// Signed admin join-dismiss records for these workspace vaults via partial index `vault_joins_vault_dismiss`,
  /// bounded with keyset cursor (`afterVault`, `afterSub`) that also advances cleanly when `maxScan` is exhausted.
  joinDismissesForVaults(
    ws: string,
    vaultIds: readonly string[],
    limit: number,
    opts?: {
      afterVault?: string;
      afterSub?: string;
      maxScan?: number;
      accept?: (d: JoinDismiss) => boolean;
    },
  ): { dismisses: JoinDismiss[]; nextCursor?: { vault: string; sub: string } } {
    if (vaultIds.length === 0 || limit <= 0) return { dismisses: [] };
    const maxScan = Math.max(limit, opts?.maxScan ?? 256);
    const accept = opts?.accept;
    const out: JoinDismiss[] = [];
    const firstStmt = this.#db.prepare(
      "SELECT sub, dismiss_body FROM vault_joins INDEXED BY vault_joins_vault_dismiss WHERE ws = ? AND vault = ? AND dismiss_body IS NOT NULL ORDER BY sub ASC LIMIT ?",
    );
    const afterStmt = this.#db.prepare(
      "SELECT sub, dismiss_body FROM vault_joins INDEXED BY vault_joins_vault_dismiss WHERE ws = ? AND vault = ? AND dismiss_body IS NOT NULL AND sub > ? ORDER BY sub ASC LIMIT ?",
    );
    const startIdx = opts?.afterVault ? Math.max(0, vaultIds.indexOf(opts.afterVault)) : 0;
    let totalScanned = 0;
    let nextCursor: { vault: string; sub: string } | undefined;
    let lastVisited: { vault: string; sub: string } | null = null;
    let exhaustedBudget = false;
    for (let vi = startIdx; vi < vaultIds.length; vi++) {
      const vault = vaultIds[vi]!;
      if (out.length >= limit) break;
      if (totalScanned >= maxScan) {
        exhaustedBudget = true;
        break;
      }
      let cursorSub: string | null = vi === startIdx && opts?.afterVault === vault && opts.afterSub !== undefined ? opts.afterSub : null;
      while (out.length < limit) {
        if (totalScanned >= maxScan) {
          exhaustedBudget = true;
          break;
        }
        const batch = Math.min(limit - out.length + 1, maxScan - totalScanned);
        if (batch <= 0) {
          exhaustedBudget = true;
          break;
        }
        const rows = (cursorSub === null
          ? firstStmt.all(ws, vault, batch)
          : afterStmt.all(ws, vault, cursorSub, batch)) as { sub: string; dismiss_body: string }[];
        if (rows.length === 0) break;
        let emittedInBatch = 0;
        let lastVisitedSub = cursorSub ?? "";
        for (let i = 0; i < rows.length; i++) {
          const r = rows[i]!;
          totalScanned++;
          lastVisitedSub = r.sub;
          lastVisited = { vault, sub: r.sub };
          if (!r.dismiss_body) continue;
          const d = JSON.parse(r.dismiss_body) as JoinDismiss;
          if (accept !== undefined && !accept(d)) continue;
          if (out.length >= limit) {
            nextCursor = { vault, sub: cursorSub ?? "" };
            break;
          }
          out.push(d);
          emittedInBatch++;
          cursorSub = r.sub;
          if (out.length >= limit) {
            if (i + 1 < rows.length || vi + 1 < vaultIds.length) {
              nextCursor = { vault, sub: r.sub };
            }
            break;
          }
        }
        if (nextCursor !== undefined) break;
        if (emittedInBatch === 0) cursorSub = lastVisitedSub;
        if (rows.length < batch) break;
      }
      if (nextCursor !== undefined || exhaustedBudget) break;
    }
    if (nextCursor === undefined && exhaustedBudget && lastVisited !== null) {
      nextCursor = lastVisited;
    }
    return nextCursor !== undefined ? { dismisses: out, nextCursor } : { dismisses: out };
  }

  /// Direct O(1) PK lookup of `sub`'s own active join state on each discoverable workspace vault (excluding pre-join
  /// asks already suppressed by `joined_up_to`).
  ownJoinsForVaults(ws: string, vaultIds: readonly string[], sub: string): { joins: JoinAsk[]; dismisses: JoinDismiss[] } {
    const joins: JoinAsk[] = [];
    const dismisses: JoinDismiss[] = [];
    const stmt = this.#db.prepare(
      "SELECT at, body, joined_up_to, dismiss_body FROM vault_joins WHERE ws = ? AND vault = ? AND sub = ?",
    );
    for (const vault of vaultIds) {
      const row = stmt.get(ws, vault, sub) as { at: number; body: string | null; joined_up_to: number; dismiss_body: string | null } | undefined;
      if (!row) continue;
      if (row.body !== null && row.body !== "" && row.at > row.joined_up_to) joins.push(JSON.parse(row.body) as JoinAsk);
      if (row.dismiss_body !== null && row.dismiss_body !== "") dismisses.push(JSON.parse(row.dismiss_body) as JoinDismiss);
    }
    return { joins, dismisses };
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
