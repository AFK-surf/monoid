// The vault's indexes as the station reads them (station/src/vault/member-index.ts, pending-index.ts,
// use-index.ts, rebox-index.ts, signin-save-index.ts): each installed as the vault is made, its readiness read, and the
// statements that read by it. Their bounded backfills are station/vaultuses's and station/signin's (the programs the
// station's readers run), which this asks in turn (use_index.mbt, signin.mbt).

///|

///|
/// The first column of the first row, None where there is no row.
fn first(db : @vault_crypto.Db, sql : String, params : Array[Json]) -> Json? raise {
  match db.get(sql, params) {
    Some(row) => Some(row.get(0).unwrap_or(Json::null()))
    None => None
  }
}

///|
/// Whether the row's `done` is 1.
fn done_is_1(db : @vault_crypto.Db, sql : String, params : Array[Json]) -> Bool raise {
  match first(db, sql, params) {
    Some(Number(n, ..)) => n == 1.0
    _ => false
  }
}

// ── the members of each vault (member-index.ts) ──

///|
pub fn initialize_vault_members(db : @vault_crypto.Db) -> Unit raise {
  @vault_crypto.install_schema(db, "vault_member_schema", member_schema)
}

///|
pub fn vault_members_complete(db : @vault_crypto.Db, ws : String) -> Bool raise {
  match
    db.get(
      "SELECT b.done, a.done AS audited, t.done AS type_audited, n.done AS nul_audited FROM vault_member_backfill b\n    LEFT JOIN vault_member_audit_v2 a ON a.ws = b.ws LEFT JOIN vault_member_type_audit_v3 t ON t.ws = b.ws\n    LEFT JOIN vault_member_nul_audit_v4 n ON n.ws = b.ws\n    WHERE b.ws = ?",
      [js(ws)],
    ) {
    Some(row) => row.all(v => v is Json::Number(1.0, ..))
    None => false
  }
}

///|
pub fn vault_members_started(db : @vault_crypto.Db, ws : String) -> Bool raise {
  db.get("SELECT 1 FROM vault_member_backfill WHERE ws = ?", [js(ws)]) is Some(_)
}

///|
let vault_members_invalid : String =
  #|SELECT 1 FROM vault_member_invalid i CROSS JOIN vaults v ON v.ws = i.ws AND v.id = i.vault WHERE i.ws = ?
  #|  UNION ALL SELECT 1 FROM vault_member_duplicates_v2 d CROSS JOIN vaults v ON v.ws = d.ws AND v.id = d.vault
  #|    WHERE d.ws = ?
  #|  UNION ALL SELECT 1 FROM vault_member_nul_v4 n CROSS JOIN vaults v ON v.ws = n.ws AND v.id = n.vault
  #|    WHERE n.ws = ? LIMIT 1

///|
pub fn has_invalid_vault_members(db : @vault_crypto.Db, ws : String) -> Bool raise {
  db.get(vault_members_invalid, [js(ws), js(ws), js(ws)]) is Some(_)
}

///|
let member_vaults : String =
  #|SELECT v.body FROM vault_member_lookup m
  #|  CROSS JOIN vaults v ON v.ws = m.ws AND v.id = m.vault
  #|  WHERE m.ws = ? AND m.sub = ? ORDER BY m.vault

// ── the requests still waiting (pending-index.ts) ──

///|
pub fn initialize_pending_index(db : @vault_crypto.Db) -> Unit raise {
  @vault_crypto.install_schema(db, "vault_pending_schema", pending_schema)
}

///|
pub fn pending_index_complete(db : @vault_crypto.Db, ws : String) -> Bool raise {
  done_is_1(db, "SELECT done FROM vault_pending_backfill WHERE ws = ?", [js(ws)])
}

///|
pub fn pending_index_started(db : @vault_crypto.Db, ws : String) -> Bool raise {
  db.get("SELECT 1 FROM vault_pending_backfill WHERE ws = ?", [js(ws)]) is Some(_)
}

///|
pub fn pending_audit_complete(db : @vault_crypto.Db, ws : String) -> Bool raise {
  done_is_1(db, "SELECT done FROM vault_pending_audit_v2 WHERE ws = ?", [js(ws)]) &&
  done_is_1(db, "SELECT done FROM vault_pending_nul_audit_v3 WHERE ws = ?", [js(ws)])
}

///|
/// Whether the members' lookup is there (a vault store made on this database).
pub fn has_vault_members(db : @vault_crypto.Db) -> Bool raise {
  db.get("SELECT 1 FROM sqlite_schema WHERE type = 'table' AND name = 'vault_member_backfill'", []) is Some(_)
}

///|
let pending_bodies : String =
  #|SELECT r.body FROM vault_pending_lookup p
  #|  JOIN vault_requests r ON r.ws = p.ws AND r.id = p.id WHERE p.ws = ? ORDER BY p.id

///|
let pending_own : String =
  #|SELECT r.id, r.body FROM vault_pending_lookup p INDEXED BY vault_pending_decider
  #|  JOIN vault_requests r ON r.ws = p.ws AND r.id = p.id
  #|  WHERE p.ws = ? AND p.owner_decides = 1 AND p.decider = ?

///|
let pending_cross_own : String =
  #|SELECT r.id, r.body FROM vault_pending_owner_v4 p INDEXED BY vault_pending_owner_v4_owner
  #|  JOIN vault_requests r ON r.ws = p.ws AND r.id = p.id
  #|  WHERE p.ws = ? AND p.owner = ?

///|
let cross_uses_sql : String =
  #|SELECT r.body FROM vault_cross_use_lookup u INDEXED BY vault_cross_use_owner
  #|  JOIN vault_requests r ON r.ws = u.ws AND r.id = u.id
  #|  WHERE u.ws = ?1 AND u.owner = ?2 ORDER BY u.at DESC, u.id DESC LIMIT ?3

///|
let pending_member : String =
  #|SELECT r.id, r.body FROM vault_member_lookup m
  #|  CROSS JOIN vault_pending_lookup p INDEXED BY vault_pending_decider
  #|  JOIN vault_requests r ON r.ws = p.ws AND r.id = p.id
  #|  WHERE m.ws = ? AND m.sub = ? AND p.ws = m.ws AND p.owner_decides = 0 AND p.decider = m.vault

///|
let pending_due : String =
  #|SELECT r.id, r.body FROM vault_pending_lookup p INDEXED BY vault_pending_at
  #|  JOIN vault_requests r ON r.ws = p.ws AND r.id = p.id WHERE p.ws = ? AND p.at <= ?

///|
let pending_no_time : String =
  #|SELECT r.id, r.body FROM vault_pending_lookup p INDEXED BY vault_pending_at
  #|  JOIN vault_requests r ON r.ws = p.ws AND r.id = p.id WHERE p.ws = ? AND p.at IS NULL

///|
let pending_other_time : String =
  #|SELECT r.id, r.body FROM vault_pending_lookup p INDEXED BY vault_pending_at
  #|  JOIN vault_requests r ON r.ws = p.ws AND r.id = p.id WHERE p.ws = ? AND p.at >= ''

///|
let pending_duplicates : String =
  #|SELECT r.id, r.body FROM vault_pending_duplicates_v2 d
  #|  CROSS JOIN vault_requests r ON r.ws = d.ws AND r.id = d.id WHERE d.ws = ? AND r.status = 'pending'

///|
let pending_nul_fields : String =
  #|SELECT r.id, r.body FROM vault_pending_nul_v3 n
  #|  CROSS JOIN vault_requests r ON r.ws = n.ws AND r.id = n.id WHERE n.ws = ? AND r.status = 'pending'

///|
let pending_seed_first : String =
  #|SELECT r.id, r.body FROM vault_pending_lookup p
  #|  JOIN vault_requests r ON r.ws = p.ws AND r.id = p.id WHERE p.ws = ? ORDER BY p.id LIMIT ?

///|
let pending_seed : String =
  #|SELECT r.id, r.body FROM vault_pending_lookup p
  #|  JOIN vault_requests r ON r.ws = p.ws AND r.id = p.id WHERE p.ws = ? AND p.id > ? ORDER BY p.id LIMIT ?

///|
/// Whether a workspace's pending lookup is ready to be read (`pendingPreparationComplete`).
pub fn pending_preparation_complete(db : @vault_crypto.Db, ws : String, members : Bool, audit : Bool) -> Bool raise {
  pending_index_complete(db, ws) &&
  (!audit || pending_audit_complete(db, ws)) &&
  (!members || !has_vault_members(db) || vault_members_complete(db, ws))
}

// ── the requests whose boxes might need recovery (rebox-index.ts) ──

///|
pub fn initialize_rebox_index(db : @vault_crypto.Db) -> Unit raise {
  @vault_crypto.install_schema(db, "vault_rebox_schema", rebox_schema, rows=[
    "SELECT 1 FROM vault_rebox_backfill WHERE id = 1",
  ])
}

///|
pub fn rebox_index_complete(db : @vault_crypto.Db) -> Bool raise {
  done_is_1(db, "SELECT done FROM vault_rebox_backfill WHERE id = 1", [])
}

///|
let rebox_ready : String =
  #|SELECT r.ws, r.id FROM vault_rebox_lookup p
  #|  CROSS JOIN vault_requests r ON r.ws = p.ws AND r.id = p.id
  #|  WHERE r.status = 'pending' ORDER BY r.rowid

///|
let rebox_legacy : String = "SELECT ws, id FROM vault_requests WHERE status = 'pending'"

// ── the decided uses (use-index.ts) ──

///|
pub fn initialize_use_index(db : @vault_crypto.Db) -> Unit raise {
  @vault_crypto.install_schema(db, "vault_use_schema", use_schema, rows=[
    "SELECT 1 FROM vault_use_backfill_all WHERE id = 1",
  ])
}

// ── a sign-in's saves (signin-save-index.ts) ──

///|
pub fn install_signin_save_index(db : @vault_crypto.Db) -> Unit raise {
  db.exec(signin_save_schema)
}

///|
let signin_save : String =
  #|SELECT a.body FROM signin_save_lookup l INDEXED BY signin_save_by_request
  #|  JOIN signin_asks a ON a.id = l.ask WHERE l.session = ? AND l.save = ? ORDER BY a.status, a.rowid LIMIT 1

///|
pub fn signin_for_save(db : @vault_crypto.Db, session : String, save : String) -> String? raise {
  match first(db, signin_save, [js(session), js(save)]) {
    Some(String(b)) => Some(b)
    _ => None
  }
}

///|
/// A sign-in's save waiting to be told: its session, its request and its status.
pub(all) struct PendingSigninSave {
  session : String
  save : String
  status : String
}

///|
fn pending_of(row : Array[Json]?) -> PendingSigninSave? {
  match row {
    Some([String(session), String(save), String(status), ..]) => Some({ session, save, status })
    _ => None
  }
}

///|
pub fn pending_signin_save(db : @vault_crypto.Db, session? : String) -> PendingSigninSave? raise {
  match session {
    None =>
      pending_of(db.get("SELECT session, save, status FROM signin_save_pending ORDER BY session, save LIMIT 1", []))
    Some(s) =>
      pending_of(
        db.get("SELECT session, save, status FROM signin_save_pending WHERE session = ? ORDER BY save LIMIT 1", [
          js(s),
        ]),
      )
  }
}

///|
/// Round-robin the waiting sessions without walking the other sessions' requests.
pub fn next_pending_signin_save(db : @vault_crypto.Db, after : String?) -> PendingSigninSave? raise {
  let next = match after {
    None => None
    Some(a) =>
      pending_of(
        db.get("SELECT session, save, status FROM signin_save_pending WHERE session > ? ORDER BY session, save LIMIT 1", [
          js(a),
        ]),
      )
  }
  match next {
    Some(n) => Some(n)
    None => pending_signin_save(db)
  }
}

///|
pub fn forget_signin_save(db : @vault_crypto.Db, session : String, save : String, status? : String) -> Unit raise {
  match status {
    None =>
      ignore(db.run("DELETE FROM signin_save_pending WHERE session = ? AND save = ?", [js(session), js(save)]))
    Some(s) =>
      ignore(
        db.run("DELETE FROM signin_save_pending WHERE session = ? AND save = ? AND status = ?", [
          js(session),
          js(save),
          js(s),
        ]),
      )
  }
}

///|
pub fn queue_signin_save(db : @vault_crypto.Db, session : String, save : String, status : String) -> Unit raise {
  ignore(
    db.run(
      "INSERT INTO signin_save_pending (session, save, status) VALUES (?, ?, ?)\n    ON CONFLICT (session, save) DO UPDATE SET status = excluded.status WHERE status IS NOT excluded.status",
      [js(session), js(save), js(status)],
    ),
  )
}

///|
pub fn signin_save_complete(db : @vault_crypto.Db, session : String) -> Bool raise {
  done_is_1(db, "SELECT done FROM signin_save_progress WHERE session = ?", [js(session)])
}
