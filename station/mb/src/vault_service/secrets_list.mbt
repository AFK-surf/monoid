// What may be asked for and what waits (station/src/vault/secrets.ts `listings`, `#findListing`, `tells`, `inVault`,
// `preparePending`, `pending`, `uses`): the items a session may ask for, who decides a request and is told of it, the
// requests a person may decide, and the uses of a vault's secrets.

///|
/// The items a session may ask for: those with a listing of whoever started its chat (or `person`), in their vaults
/// (security mode on) or their plain library (off).
pub fn Secrets::listings(self : Secrets, session : String, person? : String) -> Array[Listed] raise {
  let (ws, lock) = self.place_of(session)
  guard self.person_for(session, person) is Some(email) else { return [] }
  self.listings_at(ws, lock, email)
}

///|
fn plain_listings(items : Array[Json]) -> Array[Listed] {
  let out = []
  for i in items {
    if !truthy(get(Some(i), "deleted")) && truthy(get(Some(i), "listing")) {
      out.push({
        vault: @vault_crypto.plain_id,
        vault_name: None,
        scope: None,
        item: gtext(Some(i), "id"),
        owner: gs(Some(i), "owner"),
        listing: get(Some(i), "listing").unwrap(),
      })
    }
  }
  out
}

///|
fn vault_listings(lock : Lock, vault : Json, items : Array[Json]) -> Array[Listed] {
  let out = []
  let scope = Some(if gs(Some(vault), "scope") == Some("workspace") { "workspace" } else { "personal" })
  let vault_name = gs(Some(vault), "name")
  for item in items {
    if !truthy(get(Some(item), "deleted")) &&
      has(Some(item), "listing") &&
      get(Some(item), "epoch") == get(Some(vault), "epoch") {
      out.push({
        vault: gtext(Some(vault), "id"),
        vault_name,
        scope,
        item: gtext(Some(item), "id"),
        owner: lock.email_of(gtext(Some(vault), "owner")),
        listing: get(Some(item), "listing").unwrap(),
      })
    }
  }
  out
}

///|
fn members_of(vault : Json) -> Array[String] {
  strings_of(get(Some(vault), "members"))
}

///|
fn Secrets::listings_at(self : Secrets, ws : String, lock : Lock?, email : String) -> Array[Listed] raise {
  guard lock is Some(lock) else { return plain_listings(self.plain.items(ws, email)) }
  guard lock.member_with_email(email) is Some(sub) else { return [] }
  let out = []
  for vault in self.vaults.vaults(lock.ws) {
    if members_of(vault).contains(sub) {
      for l in vault_listings(lock, vault, self.vaults.items(lock.ws, gtext(Some(vault), "id"))) {
        out.push(l)
      }
    }
  }
  out
}

///|
fn listed_matches(l : Listed, wanted : String) -> Bool {
  lower(l.item) == wanted || lower(gtext(Some(l.listing), "name")) == wanted
}

///|
fn first_match(ls : Array[Listed], wanted : String) -> Listed? {
  for l in ls {
    if listed_matches(l, wanted) {
      return Some(l)
    }
  }
  None
}

///|
/// A use needs only the first matching listing; names can equal another item's id, so the list's order is kept.
fn Secrets::find_listing(self : Secrets, session : String, wanted : String, person : String?) -> Listed? raise {
  let (ws, lock) = self.place_of(session)
  guard self.person_for(session, person) is Some(email) else { return None }
  // The prefix and any remaining reads in one snapshot.
  self.db.exec("SAVEPOINT vault_find_listing")
  let found = (fn() -> Listed? raise {
    guard lock is Some(lock) else {
      let prefix = self.plain.first_items(ws, email, listing_prefix)
      let found = first_match(plain_listings(prefix.map(e => e.1)), wanted)
      if found is Some(_) || prefix.length() < listing_prefix {
        return found
      }
      return first_match(plain_listings(self.plain.items_after(ws, email, prefix[prefix.length() - 1].0)), wanted)
    }
    guard lock.member_with_email(email) is Some(sub) else { return None }
    let in_vault = fn(vault : Json, short : Bool) -> Listed? raise {
      if !members_of(vault).contains(sub) {
        return None
      }
      let vid = gtext(Some(vault), "id")
      if !short {
        return first_match(vault_listings(lock, vault, self.vaults.items(lock.ws, vid)), wanted)
      }
      let prefix = self.vaults.first_items(lock.ws, vid, listing_prefix)
      let found = first_match(vault_listings(lock, vault, prefix.map(e => e.1)), wanted)
      if found is Some(_) || prefix.length() < listing_prefix {
        return found
      }
      first_match(
        vault_listings(lock, vault, self.vaults.items_after(lock.ws, vid, prefix[prefix.length() - 1].0)),
        wanted,
      )
    }
    let prefix = self.vaults.first_vaults(lock.ws, listing_prefix)
    for entry in prefix {
      if in_vault(entry.1, true) is Some(f) {
        return Some(f)
      }
    }
    if prefix.length() < listing_prefix {
      return None
    }
    for vault in self.vaults.vaults_after(lock.ws, prefix[prefix.length() - 1].0) {
      if in_vault(vault, false) is Some(f) {
        return Some(f)
      }
    }
    None
  })() catch {
    e => {
      self.db.exec("RELEASE vault_find_listing")
      raise e
    }
  }
  self.db.exec("RELEASE vault_find_listing")
  found
}

///|
/// Whether `viewer` (`sub`, `email`) decides request `r`: the plain library's item's owner, a member of the vault.
fn Secrets::decides(self : Secrets, r : Json, sub : String, email : String, lock : Lock?) -> Bool raise {
  if is_plain(r) || truthy(get(Some(r), "save")) {
    return gs(Some(r), "owner") == Some(lower(email))
  }
  match lock {
    None => false
    Some(lock) =>
      match self.vaults.vault(lock.ws, gtext(Some(r), "vault")) {
        Some(v) => members_of(v).contains(sub)
        None => false
      }
  }
}

///|
/// Whom request `r`'s changes are told to: in its workspace, its owner for the plain library or a secret to keep (none
/// without one), else the members of its vault as each is told (`inVault`).
pub fn Secrets::tells(_self : Secrets, r : Json) -> Json? {
  if !is_plain(r) && !truthy(get(Some(r), "save")) {
    return Some(
      obj([("workspace", get(Some(r), "ws").unwrap_or(Json::null())), ("vault", get(Some(r), "vault").unwrap_or(Json::null()))]),
    )
  }
  match get(Some(r), "owner") {
    None => None
    Some(o) => Some(obj([("workspace", get(Some(r), "ws").unwrap_or(Json::null())), ("email", o)]))
  }
}

///|
/// Whether `viewer` is a member of that vault of their workspace now.
pub fn Secrets::in_vault(self : Secrets, sub : String, workspace : String, vault : String) -> Bool raise {
  match self.vaults.vault(workspace, vault) {
    Some(v) => members_of(v).contains(sub)
    None => false
  }
}

///|
/// This workspace's old pending lookup filled before its request list is read.
pub async fn Secrets::prepare_pending(self : Secrets, ws : String, members? : Bool) -> Unit {
  let members = match members {
    Some(m) => m
    None => (self.w.lock)(Some(ws)) is Some(_)
  }
  // A request does not wait for an earlier process still running: the original query remains available.
  if !self.previous_exited {
    return
  }
  if pending_index_started(self.db, ws) && !pending_audit_complete(self.db, ws) && !self.pending_audits.contains(ws) {
    self.pending_audits[ws] = ()
    ignore(
      @effect.runtime().fork(name="vault pending audit", async fn() {
        self.uses_index.prepare_pending(ws, false, audit=true) catch {
          e =>
            if !self.restore_closed {
              self.w.warn("vault", "the pending index audit could not finish", obj([("error", js(message_of(e)))]))
            }
        }
        self.pending_audits.remove(ws)
      }),
    )
  }
  if members &&
    has_vault_members(self.db) &&
    vault_members_started(self.db, ws) &&
    !vault_members_complete(self.db, ws) {
    if !self.member_audits.contains(ws) {
      self.member_audits[ws] = ()
      ignore(
        @effect.runtime().fork(name="vault member audit", async fn() {
          self.uses_index.prepare_pending(ws, true) catch {
            e =>
              if !self.restore_closed {
                self.w.warn("vault", "the member index audit could not finish", obj([("error", js(message_of(e)))]))
              }
          }
          self.member_audits.remove(ws)
        }),
      )
    }
    self.uses_index.prepare_pending(ws, false)
  } else {
    self.uses_index.prepare_pending(ws, members)
  }
  if self.lost_saves.get(ws) is Some(s) && s.ready {
    return
  }
  match self.preparing_pending.get(ws) {
    Some(d) => return d.wait()
    None => ()
  }
  let d : @effect.Deferred[Unit] = @effect.Deferred::new()
  self.preparing_pending[ws] = d
  // Once the earlier process has exited, writes to requests are made here and update this set in `save`.
  let state : LostSaves = { ids: Map([]), ready: false }
  self.lost_saves[ws] = state
  let prepared = (async fn() -> Unit raise {
    let mut after : String? = None
    while true {
      let rows = match after {
        None => self.db.all(pending_seed_first, [js(ws), ji(32)])
        Some(a) => self.db.all(pending_seed, [js(ws), js(a), ji(32)])
      }
      for row in rows {
        let request = parse(js_text(row.get(1)))
        self.track_pending(ws, js_text(row.get(0)), request, true)
      }
      if rows.length() < 32 {
        break
      }
      after = Some(js_text(rows[rows.length() - 1].get(0)))
      @effect.pause()
    }
    state.ready = true
  })() catch {
    e => {
      if self.lost_saves.get(ws) is Some(s) && physical_equal(s, state) {
        let ids = []
        for id, _ in state.ids {
          ids.push(id)
        }
        for id in ids {
          self.mark_lost(ws, id, false)
        }
        self.lost_saves.remove(ws)
      }
      if self.preparing_pending.get(ws) is Some(x) && physical_equal(x, d) {
        self.preparing_pending.remove(ws)
      }
      ignore(d.fail(e))
      raise e
    }
  }
  ignore(prepared)
  if self.preparing_pending.get(ws) is Some(x) && physical_equal(x, d) {
    self.preparing_pending.remove(ws)
  }
  ignore(d.succeed(()))
}

///|
/// The requests `viewer` (`sub`, `email`) may decide in workspace `ws`, still waiting.
pub fn Secrets::pending(self : Secrets, ws : String, lock : Lock?, sub : String, email : String) -> Array[Json] raise {
  let now = self.secs()
  let lost = self.lost_saves.get(ws)
  let bodies : Array[String] = []
  // The readiness and anomaly checks describe the same snapshot as the indexed candidates.
  self.db.exec("SAVEPOINT vault_pending_read")
  (fn() raise {
    let ready = well_formed(email) &&
      (lock is None || well_formed(sub)) &&
      lost.map(l => l.ready) == Some(true) &&
      pending_index_complete(self.db, ws) &&
      pending_audit_complete(self.db, ws) &&
      (match lock {
        None => true
        Some(l) =>
          l.ws == ws &&
          has_vault_members(self.db) &&
          vault_members_complete(self.db, ws) &&
          !has_invalid_vault_members(self.db, ws)
      })
    if !ready {
      let sql = if pending_index_complete(self.db, ws) {
        pending_bodies
      } else {
        "SELECT body FROM vault_requests WHERE ws = ? AND status = 'pending'"
      }
      for row in self.db.all(sql, [js(ws)]) {
        bodies.push(js_text(row.get(0)))
      }
    } else {
      let selected : Map[String, String] = Map([])
      let add = fn(rows : Array[Array[Json]]) {
        for row in rows {
          selected[js_text(row.get(0))] = js_text(row.get(1))
        }
      }
      add(self.db.all(pending_own, [js(ws), js(lower(email))]))
      if lock is Some(_) {
        add(self.db.all(pending_member, [js(ws), js(sub)]))
      }
      add(self.db.all(pending_due, [js(ws), jn(now - pending_secs)]))
      add(self.db.all(pending_no_time, [js(ws)]))
      add(self.db.all(pending_other_time, [js(ws)]))
      add(self.db.all(pending_duplicates, [js(ws)]))
      add(self.db.all(pending_nul_fields, [js(ws)]))
      let coming = match self.w.coming {
        Some(c) => c()
        None => false
      }
      if !coming {
        let ids = []
        for id, _ in lost.unwrap().ids {
          ids.push(id)
        }
        for id in ids {
          match self.kept(ws, id) {
            Some(k) if gs(Some(k.request), "status") == Some("pending") => selected[id] = stringify(k.request)
            _ => self.mark_lost(ws, id, false)
          }
        }
      }
      let keys = []
      for k, _ in selected {
        keys.push(k)
      }
      for k in sorted(keys) {
        bodies.push(selected[k])
      }
    }
  })() catch {
    e => {
      self.db.exec("RELEASE vault_pending_read")
      raise e
    }
  }
  self.db.exec("RELEASE vault_pending_read")
  let live = []
  for body in bodies {
    let r = parse(body)
    // A secret to keep gone with a restart and sealed to no device can never be kept: let go.
    if self.request_live(r, now) {
      live.push(r)
      continue
    }
    if self.settle(r, "expired") {
      continue
    }
    // Another connection may have changed the request before its expiration could be recorded.
    match self.kept(gtext(Some(r), "ws"), gtext(Some(r), "id")) {
      Some(k) if gs(Some(k.request), "status") == Some("pending") && self.request_live(k.request, now) =>
        live.push(k.request)
      _ => ()
    }
  }
  let vault_decisions : Map[String, Bool] = Map([])
  let out = []
  for r in live {
    let keep = if is_plain(r) || truthy(get(Some(r), "save")) || lock is None {
      self.decides(r, sub, email, lock)
    } else {
      let v = gtext(Some(r), "vault")
      match vault_decisions.get(v) {
        Some(c) => c
        None => {
          let may = self.decides(r, sub, email, lock)
          vault_decisions[v] = may
          may
        }
      }
    }
    if keep {
      out.push(r)
    }
  }
  out
}

///|
fn Secrets::vault_member(self : Secrets, ws : String, vault : String, sub : String) -> Bool raise {
  match self.vaults.vault(ws, vault) {
    Some(v) => members_of(v).contains(sub)
    None => false
  }
}

///|
/// The uses of a vault's (or the plain library's) secrets `viewer` may see, the latest first: the requests decided.
pub async fn Secrets::uses(
  self : Secrets,
  ws : String,
  lock : Lock?,
  vault : String,
  sub : String,
  email : String,
  limit? : Int = 500,
) -> Array[Json] {
  let plain = vault == @vault_crypto.plain_id
  if !plain && (lock is None || !self.vault_member(ws, vault, sub)) {
    return []
  }
  let bodies = self.uses_index.read(ws, vault, if plain { Some(lower(email)) } else { None }, limit)
  // A large old database may still have been filling its index: access can change while that read waits.
  if !plain && ((self.w.lock)(Some(ws)) is None || !self.vault_member(ws, vault, sub)) {
    return []
  }
  let low = lower(email)
  let requests = bodies
    .map(b => parse_or_null(b))
    .filter(r => gs(Some(r), "vault") == Some(vault) &&
      (!plain || gs(Some(r), "owner") == Some(low)) &&
      nullish(get(Some(r), "save")) &&
      nullish(get(Some(r), "describe")) &&
      nullish(get(Some(r), "remove")))
  let names : Map[String, String?] = Map([])
  let sessions = uniq(requests.map(r => gtext(Some(r), "session")))
  match (self.w.title_if_ready, self.w.hub.prepare_latest_threads) {
    (Some(title_if_ready), Some(prepare)) =>
      while true {
        // The vault may have changed while the order was prepared.
        if !plain && ((self.w.lock)(Some(ws)) is None || !self.vault_member(ws, vault, sub)) {
          return []
        }
        let missing = []
        names.clear()
        // Readiness and the name in one snapshot, let go before waiting.
        self.db.exec("SAVEPOINT vault_use_titles")
        for session in sessions {
          let got = title_if_ready(session) catch {
            _ => {
              names[session] = None
              continue
            }
          }
          match got {
            None => missing.push(session)
            Some(name) => names[session] = name
          }
        }
        self.db.exec("RELEASE vault_use_titles")
        if missing.is_empty() {
          break
        }
        prepare(missing)
      }
    _ =>
      for session in sessions {
        names[session] = self.title(session)
      }
  }
  requests.map(r => use_json(
    gtext(Some(r), "item"),
    get(Some(r), "at").unwrap_or(Json::null()),
    gtext(Some(r), "session"),
    names.get(gtext(Some(r), "session")).unwrap_or(None),
    get(Some(r), "mode").unwrap_or(Json::null()),
    get(Some(r), "command").unwrap_or(Json::null()),
    get(Some(r), "hosts").unwrap_or(jarr([])),
    gs(Some(r), "status") == Some("denied"),
  ))
}

///|
/// `v == null`: absent or null.
fn nullish(v : Json?) -> Bool {
  v is None || v is Some(Null)
}

///|
fn Secrets::title(self : Secrets, session : String) -> String? {
  match self.w.title {
    Some(t) =>
      t(session) catch {
        _ => None
      }
    None => None
  }
}

///|
/// The longest grant a request's item (listed as `l`) is given for: its own, else its vault's or its owner's; None:
/// any.
fn Secrets::lasts_of(self : Secrets, r : Json, l : Json) -> Json? raise {
  if truthy(get(Some(l), "lasts")) {
    return get(Some(l), "lasts")
  }
  let found = if is_plain(r) {
    match gs(Some(r), "owner") {
      Some(o) if o != "" =>
        match self.plain.lasts(gtext(Some(r), "ws"), o) {
          Some((lasts, _)) => Some(lasts)
          None => None
        }
      _ => None
    }
  } else {
    get(self.vaults.vault(gtext(Some(r), "ws"), gtext(Some(r), "vault")), "lasts")
  }
  match found {
    None | Some(Null) => None
    x => x
  }
}

///|
/// The listing of a request's item, where it still is.
fn Secrets::listing_of(self : Secrets, r : Json) -> Json? raise {
  let ws = gtext(Some(r), "ws")
  if is_plain(r) {
    get(self.plain.item(ws, gtext(Some(r), "item")), "listing")
  } else {
    get(self.vaults.item(ws, gtext(Some(r), "vault"), gtext(Some(r), "item")), "listing")
  }
}
