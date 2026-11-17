// What the station keeps of the vaults it holds (station/src/vault/store.ts): each vault's and each item's latest
// version, as signed, and the box certificates the workspace's app devices published. Ciphertext and signatures only;
// who may write what is checked before (station/vault_crypto). Its tables beside the store's, in the same database.

///|
let deleted_write : String = "vault was deleted during the write"

///|
/// A concurrent deletion blocked a write after its caller had already checked the vault.
pub fn is_deleted_vault_write(e : Error) -> Bool {
  message_of(e) == deleted_write
}

///|
/// The store of the vaults of a database.
pub struct VaultStore {
  db : @vault_crypto.Db
}

///|
/// The vault store of `db`: its tables and the members' lookup made where they are not.
pub fn VaultStore::new(db : @vault_crypto.Db) -> VaultStore raise {
  db.exec(store_schema)
  initialize_vault_members(db)
  { db, }
}

///|
fn bodies(rows : Array[Array[Json]]) -> Array[Json] {
  rows.map(r => match r.get(0) {
    Some(String(b)) => parse_or_null(b)
    _ => Json::null()
  })
}

///|
fn opt_body(row : Array[Json]?) -> (Json, String)? {
  match row {
    Some([String(b), ..]) => Some((parse_or_null(b), b))
    _ => None
  }
}

///|
/// Every vault of a workspace held here, latest versions.
pub fn VaultStore::vaults(self : VaultStore, ws : String) -> Array[Json] raise {
  bodies(self.db.all("SELECT body FROM vaults WHERE ws = ? ORDER BY id", [js(ws)]))
}

///|
/// Candidate vaults in the same order as the full list; callers still check membership on the held body.
pub fn VaultStore::member_vaults(self : VaultStore, ws : String, sub : String) -> Array[Json] raise {
  if !well_formed(sub) {
    return self.vaults(ws)
  }
  if self.db.get("SELECT 1 FROM vaults WHERE ws = ? LIMIT 1 OFFSET 32", [js(ws)]) is None {
    return self.vaults(ws)
  }
  self.db.exec("SAVEPOINT vault_member_read")
  let got = (fn() -> Array[Json] raise {
    if !vault_members_complete(self.db, ws) || has_invalid_vault_members(self.db, ws) {
      return self.vaults(ws)
    }
    bodies(self.db.all(member_vaults, [js(ws), js(sub)]))
  })() catch {
    e => {
      self.db.exec("RELEASE vault_member_read")
      raise e
    }
  }
  self.db.exec("RELEASE vault_member_read")
  got
}

///|
/// A short ordered prefix and its database keys.
pub fn VaultStore::first_vaults(self : VaultStore, ws : String, limit : Int) -> Array[(String, Json)] raise {
  self.db
  .all("SELECT id, body FROM vaults WHERE ws = ? ORDER BY id LIMIT ?", [js(ws), ji(limit)])
  .map(r => (js_text(r.get(0)), match r.get(1) { Some(String(b)) => parse_or_null(b); _ => Json::null() }))
}

///|
pub fn VaultStore::vaults_after(self : VaultStore, ws : String, id : String) -> Array[Json] raise {
  bodies(self.db.all("SELECT body FROM vaults WHERE ws = ? AND id > ? ORDER BY id", [js(ws), js(id)]))
}

///|
pub fn VaultStore::vault(self : VaultStore, ws : String, id : String) -> Json? raise {
  self.vault_snapshot(ws, id).map(x => x.0)
}

///|
/// The vault with its exact body, for a later decision to check it has not changed.
pub fn VaultStore::vault_snapshot(self : VaultStore, ws : String, id : String) -> (Json, String)? raise {
  opt_body(self.db.get("SELECT body FROM vaults WHERE ws = ? AND id = ?", [js(ws), js(id)]))
}

///|
fn deleted(v : Json) -> Bool {
  truthy(get(Some(v), "deleted"))
}

///|
fn num_or_null(v : Json?) -> Json {
  v.unwrap_or(Json::null())
}

///|
/// A vault's new version, in place of the one before. Deleted, its items go with it.
pub fn VaultStore::put_vault(self : VaultStore, v : Json) -> Unit raise {
  let save = () => ignore(
    self.db.run(
      "INSERT INTO vaults (ws, id, seq, body) VALUES (?, ?, ?, ?) ON CONFLICT (ws, id) DO UPDATE SET seq = excluded.seq, body = excluded.body",
      [num_or_null(get(Some(v), "ws")), num_or_null(get(Some(v), "id")), num_or_null(get(Some(v), "seq")), js(stringify(v))],
    ),
  )
  if !deleted(v) {
    save()
    return
  }
  self.db.exec("SAVEPOINT vault_delete")
  (fn() raise {
    save()
    ignore(
      self.db.run("DELETE FROM vault_items WHERE ws = ? AND vault = ?", [
        num_or_null(get(Some(v), "ws")),
        num_or_null(get(Some(v), "id")),
      ]),
    )
    self.db.exec("RELEASE vault_delete")
  })() catch {
    e => {
      self.db.exec("ROLLBACK TO vault_delete; RELEASE vault_delete") catch {
        _ => ()
      }
      raise e
    }
  }
}

///|
/// Saved only if the version the caller checked is still the one held (None: there was no vault).
pub fn VaultStore::put_vault_if(self : VaultStore, v : Json, previous : String?) -> Bool raise {
  let body = stringify(v)
  let ws = num_or_null(get(Some(v), "ws"))
  let id = num_or_null(get(Some(v), "id"))
  let seq = num_or_null(get(Some(v), "seq"))
  let save = () => match previous {
    None =>
      self.db.run(
        "INSERT INTO vaults (ws, id, seq, body)\n          SELECT ?, ?, ?, ? WHERE NOT EXISTS (SELECT 1 FROM vaults WHERE ws = ? AND id = ?)",
        [ws, id, seq, js(body), ws, id],
      ) >
      0
    Some(p) =>
      self.db.run("UPDATE vaults SET seq = ?, body = ? WHERE ws = ? AND id = ? AND body = ?", [
        seq,
        js(body),
        ws,
        id,
        js(p),
      ]) >
      0
  }
  if !deleted(v) {
    return save()
  }
  self.db.exec("SAVEPOINT vault_delete_if")
  (fn() -> Bool raise {
    let saved = save()
    if saved {
      ignore(self.db.run("DELETE FROM vault_items WHERE ws = ? AND vault = ?", [ws, id]))
    }
    self.db.exec("RELEASE vault_delete_if")
    saved
  })() catch {
    e => {
      self.db.exec("ROLLBACK TO vault_delete_if; RELEASE vault_delete_if") catch {
        _ => ()
      }
      raise e
    }
  }
}

///|
/// A vault's items, latest versions (deleted ones too).
pub fn VaultStore::items(self : VaultStore, ws : String, vault : String) -> Array[Json] raise {
  bodies(self.db.all("SELECT body FROM vault_items WHERE ws = ? AND vault = ? ORDER BY id", [js(ws), js(vault)]))
}

///|
pub fn VaultStore::first_items(self : VaultStore, ws : String, vault : String, limit : Int) -> Array[(String, Json)] raise {
  self.db
  .all("SELECT id, body FROM vault_items WHERE ws = ? AND vault = ? ORDER BY id LIMIT ?", [js(ws), js(vault), ji(limit)])
  .map(r => (js_text(r.get(0)), match r.get(1) { Some(String(b)) => parse_or_null(b); _ => Json::null() }))
}

///|
pub fn VaultStore::items_after(self : VaultStore, ws : String, vault : String, id : String) -> Array[Json] raise {
  bodies(
    self.db.all("SELECT body FROM vault_items WHERE ws = ? AND vault = ? AND id > ? ORDER BY id", [
      js(ws),
      js(vault),
      js(id),
    ]),
  )
}

///|
pub fn VaultStore::item(self : VaultStore, ws : String, vault : String, id : String) -> Json? raise {
  self.item_snapshot(ws, vault, id).map(x => x.0)
}

///|
pub fn VaultStore::item_snapshot(self : VaultStore, ws : String, vault : String, id : String) -> (Json, String)? raise {
  opt_body(
    self.db.get("SELECT body FROM vault_items WHERE ws = ? AND vault = ? AND id = ?", [js(ws), js(vault), js(id)]),
  )
}

///|
/// What a move put here, taken back: an item, no version kept.
pub fn VaultStore::forget_item(self : VaultStore, ws : String, vault : String, id : String) -> Unit raise {
  ignore(self.db.run("DELETE FROM vault_items WHERE ws = ? AND vault = ? AND id = ?", [js(ws), js(vault), js(id)]))
}

///|
/// What a move put here, taken back: a vault with its items.
pub fn VaultStore::forget_vault(self : VaultStore, ws : String, id : String) -> Unit raise {
  ignore(self.db.run("DELETE FROM vault_items WHERE ws = ? AND vault = ?", [js(ws), js(id)]))
  ignore(self.db.run("DELETE FROM vaults WHERE ws = ? AND id = ?", [js(ws), js(id)]))
}

///|
pub fn VaultStore::put_item(self : VaultStore, i : Json) -> Unit raise {
  let f = (k : String) => num_or_null(get(Some(i), k))
  ignore(
    self.db.run(
      "INSERT INTO vault_items (ws, vault, id, version, body) VALUES (?, ?, ?, ?, ?) ON CONFLICT (ws, vault, id) DO UPDATE SET version = excluded.version, body = excluded.body",
      [f("ws"), f("vault"), f("id"), f("version"), js(stringify(i))],
    ),
  )
}

///|
/// The parent vault and the previous item must both still be the bodies the caller checked.
pub fn VaultStore::put_item_if(self : VaultStore, i : Json, vault_body : String, previous : String?) -> Bool raise {
  let body = stringify(i)
  let f = (k : String) => num_or_null(get(Some(i), k))
  match previous {
    None =>
      self.db.run(
        "INSERT INTO vault_items (ws, vault, id, version, body)\n        SELECT ?, ?, ?, ?, ? WHERE EXISTS (SELECT 1 FROM vaults WHERE ws = ? AND id = ? AND body = ?)\n          AND NOT EXISTS (SELECT 1 FROM vault_items WHERE ws = ? AND vault = ? AND id = ?)",
        [
          f("ws"),
          f("vault"),
          f("id"),
          f("version"),
          js(body),
          f("ws"),
          f("vault"),
          js(vault_body),
          f("ws"),
          f("vault"),
          f("id"),
        ],
      ) >
      0
    Some(p) =>
      self.db.run(
        "UPDATE vault_items SET version = ?, body = ?\n      WHERE ws = ? AND vault = ? AND id = ? AND body = ?\n        AND EXISTS (SELECT 1 FROM vaults WHERE ws = ? AND id = ? AND body = ?)",
        [
          f("version"),
          js(body),
          f("ws"),
          f("vault"),
          f("id"),
          js(p),
          f("ws"),
          f("vault"),
          js(vault_body),
        ],
      ) >
      0
  }
}

///|
/// The box certificates published in a workspace, one per device (its latest).
pub fn VaultStore::boxes(self : VaultStore, ws : String) -> Array[Json] raise {
  bodies(self.db.all("SELECT body FROM vault_boxes WHERE ws = ? ORDER BY device", [js(ws)]))
}

///|
/// The certificates held for these device ids, in the same order as the workspace's full list.
pub fn VaultStore::boxes_for(self : VaultStore, ws : String, devices : Array[String]) -> Array[Json] raise {
  if devices.is_empty() {
    return []
  }
  bodies(
    self.db.all(
      "SELECT body FROM vault_boxes WHERE ws = ? AND device IN (SELECT value FROM json_each(?)) ORDER BY device",
      [js(ws), js(stringify(jstrs(devices)))],
    ),
  )
}

///|
pub fn VaultStore::box_(self : VaultStore, ws : String, device : String) -> Json? raise {
  self.box_snapshot(ws, device).map(x => x.0)
}

///|
pub fn VaultStore::box_snapshot(self : VaultStore, ws : String, device : String) -> (Json, String)? raise {
  opt_body(self.db.get("SELECT body FROM vault_boxes WHERE ws = ? AND device = ?", [js(ws), js(device)]))
}

///|
pub fn VaultStore::put_box(self : VaultStore, cert : Json) -> Unit raise {
  ignore(
    self.db.run(
      "INSERT INTO vault_boxes (ws, device, body) VALUES (?, ?, ?) ON CONFLICT (ws, device) DO UPDATE SET body = excluded.body",
      [num_or_null(get(Some(cert), "ws")), num_or_null(get(Some(cert), "device")), js(stringify(cert))],
    ),
  )
}

///|
/// Do not replace a certificate written after the caller checked the one held.
pub fn VaultStore::put_box_if(self : VaultStore, cert : Json, previous : String?) -> Bool raise {
  let body = stringify(cert)
  let ws = num_or_null(get(Some(cert), "ws"))
  let device = num_or_null(get(Some(cert), "device"))
  match previous {
    None =>
      self.db.run(
        "INSERT INTO vault_boxes (ws, device, body)\n      SELECT ?, ?, ? WHERE NOT EXISTS (SELECT 1 FROM vault_boxes WHERE ws = ? AND device = ?)",
        [ws, device, js(body), ws, device],
      ) >
      0
    Some(p) =>
      self.db.run("UPDATE vault_boxes SET body = ? WHERE ws = ? AND device = ? AND body = ?", [
        js(body),
        ws,
        device,
        js(p),
      ]) >
      0
  }
}
