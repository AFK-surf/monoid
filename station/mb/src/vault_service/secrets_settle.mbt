// A request decided and what follows (station/src/vault/secrets.ts `#settle`, `grant`, `grantPlain`, `denyPlain`,
// `deny`), a sign-in's grant put into the chat's browser and its newer cookies kept (`#signIn`, `signInAgain`,
// `browserUsed`, `passkeysAgain`, `renewed`), and the commands run with a grant here or on another station (`run`,
// `#elsewhere`, `#runOn`, `#captureOn`, `heard`).

///|
/// A request decided otherwise than granted, or granted (the grant checked by `prepare` first); `into`: the vault a
/// secret to keep went into. Whether it was this decision that settled it.
fn Secrets::settle(
  self : Secrets,
  r : Json,
  status : String,
  scope? : String,
  into? : String,
  prepare? : (Json) -> Unit raise,
) -> Bool raise {
  let ws = gtext(Some(r), "ws")
  let rid = gtext(Some(r), "id")
  let session = gtext(Some(r), "session")
  let requested = stringify(r)
  let mut settled : (KeptRequest, Json, Bool)? = None
  for _ in 0..<3 {
    let k = match self.kept(ws, rid) {
      Some(k) => k
      None => return false
    }
    if gs(Some(k.request), "status") != Some("pending") || stringify(k.request) != requested {
      return false
    }
    let expected = k
    let of = [("status", js(status))]
    if status == "granted" && scope is Some(s) && s != "" {
      of.push(("scope", js(s)))
    }
    let outcome = obj(of)
    let save = fn() raise {
      // The writer is held here: a decision or reissued card committed after the first read is seen.
      match
        self.db.get(
          "SELECT thread,card_ts FROM vault_requests WHERE ws=? AND id=? AND status='pending' AND body=?",
          [js(ws), js(rid), js(expected.raw.unwrap_or(""))],
        ) {
        None => raise DecisionChanged
        Some(row) => {
          let thread = match row.get(0) {
            Some(Number(n, ..)) => Some(n.to_int())
            _ => None
          }
          let card_ts = match row.get(1) {
            Some(String(s)) => Some(s)
            _ => None
          }
          if thread != expected.thread || card_ts != expected.card_ts {
            raise DecisionCardMoved
          }
        }
      }
      match prepare {
        Some(p) => p(k.request)
        None => ()
      }
      set(k.request, "status", js(status))
      if into is Some(v) {
        set(k.request, "vault", js(v))
      }
      if status == "granted" {
        match self.keeper.usable(session, rid) {
          Ok(h) =>
            if truthy(get(Some(h.grant), "timeout")) {
              set(outcome, "timeout", get(Some(h.grant), "timeout").unwrap())
            }
          Err(_) => ()
        }
      }
      self.write(k)
    }
    let queue = match (k.thread, k.card_ts) {
      (Some(_), Some(_)) => self.w.card_outcomes
      _ => None
    }
    let attempt = (fn() -> Bool raise {
      self.keeper.rollback_on_error(rid, fn() raise {
        match queue {
          Some(q) =>
            (q.save)(
              obj([
                ("thread", ji(expected.thread.unwrap())),
                ("ts", js(expected.card_ts.unwrap())),
                ("agent", js(session)),
                ("field", js("vault")),
                ("close", jb(true)),
                ("outcome", outcome),
              ]),
              save,
            )
          None => {
            let nested = self.db.in_transaction()
            self.db.exec(if nested { "SAVEPOINT vault_settle" } else { "BEGIN IMMEDIATE" })
            (fn() raise {
              save()
              self.db.exec(if nested { "RELEASE vault_settle" } else { "COMMIT" })
            })() catch {
              e => {
                self.db.exec(
                  if nested {
                    "ROLLBACK TO vault_settle; RELEASE vault_settle"
                  } else {
                    "ROLLBACK"
                  },
                ) catch {
                  _ => ()
                }
                raise e
              }
            }
          }
        }
      })
      true
    })() catch {
      DecisionChanged => return false
      DecisionCardMoved => false
      e => raise e
    }
    if !attempt {
      continue
    }
    settled = Some((k, outcome, queue is Some(_)))
    break
  }
  guard settled is Some((k, outcome, queued)) else { return false }
  self.track_saved(k)
  if !queued {
    match (k.thread, k.card_ts) {
      (Some(t), Some(ts)) => {
        ignore((self.w.hub.store.withdraw_card)(session, t, ts))
        ignore(
          (self.w.hub.store.restate_card)(session, t, ts, card => spread(card, [
            ("vault", spread(get(card, "vault"), [("outcome", outcome)])),
          ])),
        )
      }
      _ => ()
    }
  }
  self.forget_save(rid, settled_ws=ws)
  if status != "granted" {
    self.keeper.drop(rid)
  }
  self.audit_(k.request, status, "")
  self.told(k.request)
  if status == "granted" &&
    gs(Some(k.request), "mode") == Some("browser") &&
    !truthy(get(Some(k.request), "describe")) &&
    !truthy(get(Some(k.request), "remove")) {
    self.renewal_granted(k.request)
    self.sign_in(k.request)
  }
  // The agent is told in its session: no tool call waits for it (one it withdrew itself knows already).
  if status != "expired" && status != "withdrawn" {
    let l = self.listing_of(r)
    let said = if truthy(get(Some(k.request), "save")) {
      self.said_save(k.request)
    } else if truthy(get(Some(k.request), "describe")) {
      self.said_describe(k.request)
    } else if truthy(get(Some(k.request), "remove")) {
      self.said_remove(k.request)
    } else {
      match l {
        Some(l) => self.said(k.request, l)
        None => "The request \{rid} was \{status}."
      }
    }
    // (the session gone: nobody to tell)
    (self.w.hub.notify)(session, said) catch {
      _ => ()
    }
  }
  true
}

///|
fn Secrets::decision_changed(self : Secrets, r : Json) -> String raise {
  match self.kept(gtext(Some(r), "ws"), gtext(Some(r), "id")) {
    None => "no such request"
    Some(c) =>
      if gs(Some(c.request), "status") == Some("pending") {
        "the request changed; try again"
      } else {
        "the request is \{gtext(Some(c.request), "status")}"
      }
  }
}

///|
fn Secrets::check_vault_snapshot(
  self : Secrets,
  ws : String,
  vault : String,
  item : String,
  vault_body : String,
  item_body : String,
) -> Unit raise {
  let v = self.db.get("SELECT 1 FROM vaults WHERE ws=? AND id=? AND body=?", [js(ws), js(vault), js(vault_body)])
  let i = self.db.get("SELECT 1 FROM vault_items WHERE ws=? AND vault=? AND id=? AND body=?", [
    js(ws),
    js(vault),
    js(item),
    js(item_body),
  ])
  if v is None || i is None {
    raise Refused("the request's vault or item changed; try again")
  }
}

///|
/// A sign-in granted: put into the chat's browser while the grant lasts.
fn Secrets::sign_in(self : Secrets, r : Json) -> Unit raise {
  let session = gtext(Some(r), "session")
  let rid = gtext(Some(r), "id")
  guard self.keeper.usable(session, rid) is Ok(held) else { return }
  guard @vault_crypto.value_of(held.secret) is Some(cookies) else { return }
  guard self.w.browsers is Some(browsers) else { return }
  if is_plain(held.request) && gs(Some(held.grant), "scope") == Some("once") && !self.previous_exited {
    // An older process may still use its in-memory copy without the conditional claim: its real exit waited for.
    ignore(
      @effect.runtime().fork(name="vault sign-in", async fn() {
        (async fn() -> Unit raise {
          match self.w.previous.gone {
            Some(gone) => gone()
            None => ()
          }
          self.sign_in(r)
        })() catch {
          e =>
            self.w.warn("vault", "a sign-in could not wait for the previous station", obj([
              ("request", js(rid)),
              ("error", js(message_of(e))),
            ]))
        }
      }),
    )
    return
  }
  if !self.keeper.spend(rid) {
    self.w.warn("vault", "a one-use sign-in grant was already used or changed", obj([("request", js(rid))]))
    return
  }
  self.audit_(r, "use", "browser \{join(strings_of(get(Some(held.grant), "hosts")), " ")}")
  let d = obj([
    ("request", js(rid)),
    ("workspace", get(Some(r), "ws").unwrap_or(Json::null())),
    ("sites", get(Some(held.grant), "hosts").unwrap_or(jarr([]))),
    ("cookies", js(cookies)),
    ("until", get(Some(held.grant), "exp").unwrap_or(Json::null())),
  ])
  ignore(
    @effect.runtime().fork(name="vault sign-in", async fn() {
      (browsers.sign_in)(session, d) catch {
        e =>
          self.w.warn("vault", "a sign-in could not be put into its chat's browser", obj([
            ("request", js(rid)),
            ("error", js(message_of(e))),
          ]))
      }
    }),
  )
}

///|
/// `session`'s chat has a new context in the browser (Chrome started again): its sign-ins still granted put in again.
pub fn Secrets::sign_in_again(self : Secrets, session : String) -> Unit raise {
  for h in self.keeper.held(session) {
    let cookies = if gs(Some(h.grant), "mode") == Some("browser") { @vault_crypto.value_of(h.secret) } else { None }
    guard cookies is Some(cookies) && self.w.browsers is Some(browsers) else { continue }
    if is_plain(h.request) && gs(Some(h.grant), "scope") == Some("once") {
      self.sign_in(h.request)
      continue
    }
    let rid = gtext(Some(h.request), "id")
    let d = obj([
      ("request", js(rid)),
      ("workspace", get(Some(h.request), "ws").unwrap_or(Json::null())),
      ("sites", get(Some(h.grant), "hosts").unwrap_or(jarr([]))),
      ("cookies", js(cookies)),
      ("until", match h.until { Some(u) => jn(u); None => get(Some(h.grant), "exp").unwrap_or(Json::null()) }),
    ])
    ignore(
      @effect.runtime().fork(name="vault sign-in again", async fn() {
        (browsers.sign_in)(session, d) catch {
          e =>
            self.w.warn("vault", "a sign-in could not be put into its chat's browser again", obj([
              ("request", js(rid)),
              ("error", js(message_of(e))),
            ]))
        }
      }),
    )
  }
}

///|
/// A deliberate browser action on a granted site extends that sign-in's idle time.
pub fn Secrets::browser_used(self : Secrets, session : String, host : String) -> Unit {
  for h in self.keeper.held(session) {
    if gs(Some(h.grant), "mode") != Some("browser") ||
      gs(get(Some(h.grant), "timeout"), "kind") != Some("idle") ||
      !strings_of(get(Some(h.grant), "hosts")).any(site => host == site || ends(host, ".\{site}")) {
      continue
    }
    let rid = gtext(Some(h.request), "id")
    self.keeper.renew(session, rid)
    match (h.until, self.w.browsers) {
      (Some(u), Some(b)) =>
        match b.extend_sign_in {
          Some(f) => f(session, rid, u)
          None => ()
        }
      _ => ()
    }
  }
}

///|
/// `session`'s chat's context taken up from the station process before: the passkeys of its sign-ins put in again.
pub fn Secrets::passkeys_again(self : Secrets, session : String) -> Unit raise {
  for h in self.keeper.held(session) {
    let cookies = if gs(Some(h.grant), "mode") == Some("browser") { @vault_crypto.value_of(h.secret) } else { None }
    guard cookies is Some(cookies) && self.w.browsers is Some(browsers) && browsers.passkeys_in is Some(passkeys_in) else {
      continue
    }
    if is_plain(h.request) && gs(Some(h.grant), "scope") == Some("once") {
      self.sign_in(h.request)
      continue
    }
    let rid = gtext(Some(h.request), "id")
    let d = obj([("sites", get(Some(h.grant), "hosts").unwrap_or(jarr([]))), ("cookies", js(cookies))])
    ignore(
      @effect.runtime().fork(name="vault passkeys", async fn() {
        passkeys_in(session, d) catch {
          e =>
            self.w.warn("vault", "a sign-in's passkeys could not be put into its chat's browser again", obj([
              ("request", js(rid)),
              ("error", js(message_of(e))),
            ]))
        }
      }),
    )
  }
}

///|
/// What a sign-in's cookies are known by where they are not kept.
fn Secrets::digest_of(self : Secrets, cookies : String) -> String raise {
  @vault_crypto.hex(self.crypto.sha256(utf8_of(cookies)))
}

///|
/// A sign-in taken out of its chat's browser as its grant ended, with its cookies as they were then: kept as the
/// item's new version where the station keeps it (the plain library). A vault's item is written only by its members'
/// apps (`renew_sealed`).
pub fn Secrets::renewed(self : Secrets, session : String, request : String, cookies : String, workspace? : String) -> Unit raise {
  // Contexts made before the workspace was kept still need their original lookup: the session may have moved.
  let r = match workspace {
    None =>
      match self.db.get("SELECT ws FROM vault_requests WHERE id = ? AND session = ?", [js(request), js(session)]) {
        Some(row) => self.kept(js_text(row.get(0)), request).map(k => k.request)
        None => None
      }
    Some(w) =>
      match
        self.db.get("SELECT body FROM vault_requests WHERE ws = ? AND id = ? AND session = ?", [
          js(w),
          js(request),
          js(session),
        ]) {
        Some(row) => Some(parse(js_text(row.get(0))))
        None => None
      }
  }
  guard r is Some(r) else { return }
  if !is_plain(r) {
    return self.renew_sealed(r, cookies)
  }
  let ws = gtext(Some(r), "ws")
  guard self.plain.item(ws, gtext(Some(r), "item")) is Some(item) else { return }
  if truthy(get(Some(item), "deleted")) ||
    gs(Some(item), "kind") != Some("browser") ||
    gs(get(Some(item), "fields"), "cookies") == Some(cookies) {
    return
  }
  let next = spread(Some(item), [
    ("version", jn(gn(Some(item), "version").unwrap_or(@double.not_a_number) + 1.0)),
    ("fields", spread(get(Some(item), "fields"), [("cookies", js(cookies))])),
    ("at", jn(self.secs())),
  ])
  match @vault_crypto.plain_ok(Some(item), next, gtext(Some(item), "owner")) {
    Some(why) =>
      return self.w.warn("vault", "a sign-in's new cookies not kept", obj([("request", js(request)), ("why", js(why))]))
    None => ()
  }
  self.plain.put(next)
  self.audit_(r, "renewed", "")
  (self.plain_written)(next)
}

///|
/// A vault's sign-in's newer cookies, sealed to its members' devices and kept until a grant of it carries them.
fn Secrets::renew_sealed(self : Secrets, r : Json, cookies : String) -> Unit raise {
  let ws = gtext(Some(r), "ws")
  guard (self.w.lock)(Some(ws)) is Some(lock) else { return }
  guard self.vaults.vault(lock.ws, gtext(Some(r), "vault")) is Some(vault) else { return }
  let certs = []
  for sub in members_of(vault) {
    for c in self.certs_of(lock, sub) {
      certs.push(c)
    }
  }
  if certs.is_empty() {
    return
  }
  let id = "n_" + ulid(self.now(), (self.w.random)(16))
  let body = obj([
    ("id", js(id)),
    ("sealed", jarr(certs.map(c => self.seal_to(c, ws, id, obj([("cookies", js(cookies))]))))),
    ("digest", js(self.digest_of(cookies))),
  ])
  ignore(
    self.db.run(
      "INSERT INTO vault_renewals (ws, item, body) VALUES (?, ?, ?) ON CONFLICT (ws, item) DO UPDATE SET body = excluded.body",
      [js(ws), get(Some(r), "item").unwrap_or(Json::null()), js(stringify(body))],
    ),
  )
  self.audit_(r, "renewal", "")
}

///|
/// The newer cookies kept for sign-in `item`, for a request of it to carry.
fn Secrets::renewal_of(self : Secrets, ws : String, item : String) -> Json? raise {
  match self.db.get("SELECT body FROM vault_renewals WHERE ws = ? AND item = ?", [js(ws), js(item)]) {
    None => None
    Some(row) => {
      let kept = parse(js_text(row.get(0)))
      Some(
        obj([
          ("id", get(Some(kept), "id").unwrap_or(Json::null())),
          ("sealed", get(Some(kept), "sealed").unwrap_or(Json::null())),
        ]),
      )
    }
  }
}

///|
/// A sign-in granted with the newer cookies its request carried: they are written now, kept no longer.
fn Secrets::renewal_granted(self : Secrets, r : Json) -> Unit raise {
  guard get(Some(r), "renewal") is Some(renewal) else { return }
  let cookies = match self.keeper.usable(gtext(Some(r), "session"), gtext(Some(r), "id")) {
    Ok(h) => @vault_crypto.value_of(h.secret)
    Err(_) => None
  }
  let ws = gtext(Some(r), "ws")
  let item = gtext(Some(r), "item")
  let kept = match self.db.get("SELECT body FROM vault_renewals WHERE ws = ? AND item = ?", [js(ws), js(item)]) {
    Some(row) => Some(parse(js_text(row.get(0))))
    None => None
  }
  guard kept is Some(kept) &&
    get(Some(kept), "id") == get(Some(renewal), "id") &&
    cookies is Some(cookies) &&
    Some(self.digest_of(cookies)) == gs(Some(kept), "digest") else {
    return
  }
  ignore(self.db.run("DELETE FROM vault_renewals WHERE ws = ? AND item = ?", [js(ws), js(item)]))
}

///|
/// POST vault/grants: `grant`, sent by `sub`'s app; why it is refused, or None.
pub fn Secrets::grant(self : Secrets, lock : Lock, sub : String, grant : Json) -> String? raise {
  let k = match gs(Some(grant), "request") {
    Some(id) => self.kept(lock.ws, id)
    None => None
  }
  guard k is Some(k) else { return Some("no such request") }
  let r = k.request
  if truthy(get(Some(r), "save")) {
    return Some("a secret to keep is approved by POST vault/saves")
  }
  if truthy(get(Some(r), "describe")) {
    return Some("a request to rename an item grants nothing: it is approved by POST vault/described")
  }
  if truthy(get(Some(r), "remove")) {
    return Some("a request to delete an item grants nothing: it is approved by POST vault/removed")
  }
  let status = gtext(Some(r), "status")
  if status != "pending" {
    return Some("the request is \{status}")
  }
  let vid = gtext(Some(r), "vault")
  let vault_snapshot = self.vaults.vault_snapshot(lock.ws, vid)
  let item_snapshot = self.vaults.item_snapshot(lock.ws, vid, gtext(Some(r), "item"))
  guard vault_snapshot is Some((vault, vault_body)) && item_snapshot is Some((item, item_body)) else {
    return Some("the request's vault or item is gone")
  }
  if !members_of(vault).contains(sub) {
    return Some("only the vault's members decide its requests")
  }
  let take = match self.keeper.prepare_accept(lock.view, vault, item, r, grant) {
    Refusal(why) => return Some(why)
    Ready(t) => t
  }
  let settled = self.settle(r, "granted", scope=gtext(Some(grant), "scope"), prepare=_ => {
    self.check_vault_snapshot(lock.ws, gtext(Some(vault), "id"), gtext(Some(item), "id"), vault_body, item_body)
    match take() {
      Some(why) => raise Refused(why)
      None => ()
    }
  }) catch {
    Refused(m) => return Some(m)
    e => raise e
  }
  if !settled {
    return Some(self.decision_changed(r))
  }
  None
}

///|
/// POST vault/plain/grants: the plain library's request granted by `email` (its item's owner) for `scope`; why it is
/// refused, or None.
pub fn Secrets::grant_plain(self : Secrets, ws : String, lock : Lock?, email : String, d : Json) -> String? raise {
  let k = match gs(Some(d), "request") {
    Some(id) => self.kept(ws, id)
    None => None
  }
  guard k is Some(k) && is_plain(k.request) else { return Some("no such request of the plain library") }
  let r = k.request
  if truthy(get(Some(r), "save")) {
    return Some("a secret to keep is approved by POST vault/plain/saves")
  }
  if truthy(get(Some(r), "describe")) {
    return Some("a request to rename an item grants nothing: it is approved by POST vault/plain/described")
  }
  if truthy(get(Some(r), "remove")) {
    return Some("a request to delete an item grants nothing: it is approved by POST vault/plain/removed")
  }
  let status = gtext(Some(r), "status")
  if status != "pending" {
    return Some("the request is \{status}")
  }
  if gs(Some(r), "owner") != Some(lower(email)) {
    return Some("only the item's owner decides its requests")
  }
  if lock is Some(_) {
    return Some("security mode is on: the plain library's secrets are moved into the vault, not given out")
  }
  let item_snapshot = self.plain.item_snapshot(ws, gtext(Some(r), "item"))
  guard item_snapshot is Some((item, item_body)) &&
    !truthy(get(Some(item), "deleted")) &&
    has(Some(item), "listing") else {
    return Some("the item is gone, or not one agents may ask for")
  }
  let listing = get(Some(item), "listing").unwrap()
  let hosts = if hosted(gtext(Some(r), "mode")) {
    match get(Some(r), "hosts") {
      Some(h) => h
      None => get(Some(listing), "hosts").unwrap_or(Json::null())
    }
  } else {
    jarr([])
  }
  let timeout = get(Some(d), "timeout")
  let settled = self.settle(r, "granted", scope=gtext(Some(d), "scope"), prepare=current => {
    if self.db.get("SELECT 1 FROM vault_plain WHERE ws=? AND id=? AND body=?", [
        js(ws),
        get(Some(item), "id").unwrap_or(Json::null()),
        js(item_body),
      ]) is None {
      raise Refused("the item changed; try again")
    }
    let hd = [
      ("scope", get(Some(d), "scope").unwrap_or(Json::null())),
      ("hosts", hosts),
      ("listing", listing),
      ("lasts", self.lasts_of(current, listing).unwrap_or(Json::null())),
    ]
    if timeout is Some(t) {
      hd.push(("timeout", t))
    }
    match
      self.keeper.hold(
        current,
        obj(hd),
        obj([
          ("kind", get(Some(item), "kind").unwrap_or(Json::null())),
          ("name", get(Some(item), "name").unwrap_or(Json::null())),
          ("fields", get(Some(item), "fields").unwrap_or(Json::null())),
        ]),
      ) {
      Some(why) => raise Refused(why)
      None => ()
    }
  }) catch {
    Refused(m) => return Some(m)
    e => raise e
  }
  if !settled {
    return Some(self.decision_changed(r))
  }
  None
}

///|
/// POST vault/plain/denials: the plain library's request turned down by its item's owner.
pub fn Secrets::deny_plain(self : Secrets, ws : String, email : String, d : Json) -> String? raise {
  let k = match gs(Some(d), "request") {
    Some(id) => self.kept(ws, id)
    None => None
  }
  guard k is Some(k) && is_plain(k.request) else { return Some("no such request of the plain library") }
  if gs(Some(k.request), "owner") != Some(lower(email)) {
    return Some("only the item's owner decides its requests")
  }
  let status = gtext(Some(k.request), "status")
  if status != "pending" {
    return Some("the request is \{status}")
  }
  if !self.settle(k.request, "denied") {
    return Some(self.decision_changed(k.request))
  }
  None
}

///|
/// POST vault/denials: `deny`, sent by `sub`'s app; why it is refused, or None.
pub fn Secrets::deny(self : Secrets, lock : Lock, sub : String, deny : Json, email? : String) -> String? raise {
  let k = match gs(Some(deny), "request") {
    Some(id) => self.kept(lock.ws, id)
    None => None
  }
  guard k is Some(k) else { return Some("no such request") }
  if gn(Some(deny), "v") != Some(1.0) || gs(Some(deny), "ws") != Some(lock.ws) {
    return Some("a refusal is {v: 1, ws, request, at, sig} of this workspace")
  }
  let by = match gs(get(Some(deny), "sig"), "key") {
    Some(key) => @vault_crypto.signer_of(lock.view, key)
    None => None
  }
  if truthy(get(Some(k.request), "save")) && lock.open_roster() && lock.devices_for(sub).length() == 0 {
    // Security mode off and no own lock of theirs heard here: whoever it is kept for turns it down from their app
    // before they turned their vault on (their credential says who).
    if email.map(lower) != gs(Some(k.request), "owner") || email is None {
      return Some("only the person it is kept for decides it")
    }
  } else if truthy(get(Some(k.request), "save")) {
    // A secret to keep: its owner's to turn down, from one of their devices.
    if lock.email_of(sub).map(lower) != gs(Some(k.request), "owner") || lock.email_of(sub) is None {
      return Some("only the person it is kept for decides it")
    }
    match by {
      Some((s, _)) if s == sub => ()
      _ => return Some("a refusal is signed by one of their devices in the lock")
    }
  } else {
    guard self.vaults.vault(lock.ws, gtext(Some(k.request), "vault")) is Some(vault) && members_of(vault).contains(sub) else {
      return Some("only the vault's members decide its requests")
    }
    match by {
      Some((s, _)) if members_of(vault).contains(s) => ()
      _ => return Some("a refusal is signed by a vault member's device in the lock")
    }
  }
  if !@vault_crypto.signed_ok(self.crypto, deny, @vault_crypto.tag_deny) {
    return Some("the refusal's signature is invalid")
  }
  let status = gtext(Some(k.request), "status")
  if status != "pending" {
    return Some("the request is \{status}")
  }
  if !self.settle(k.request, "denied") {
    return Some(self.decision_changed(k.request))
  }
  None
}

///|
/// What secret_run asks (secrets.ts `run`'s `a`).
pub(all) struct RunArgs {
  grant : String
  command : String
  env : String?
  cwd : String
  under : String?
  timeout_ms : Double?
  station : String?
}

///|
fn ran_said(r : Ran) -> String {
  let end = if r.timed_out {
    "stopped: it ran too long"
  } else {
    match r.code {
      Some(c) => "exit code \{c}"
      None => "ended by \{r.signal.unwrap_or("null")}"
    }
  }
  "\{end}\{if r.cut { " (output cut in the middle)" } else { "" }}\n\{r.output}"
}

///|
/// secret_run: `command` with grant `grant`, in the session's workspace (or `cwd` under it).
pub async fn Secrets::run(self : Secrets, session : String, a : RunArgs) -> String {
  let mut held = match self.keeper.usable(session, a.grant) {
    Err(why) => raise Refused(why)
    Ok(h) => h
  }
  if is_plain(held.request) && gs(Some(held.grant), "scope") == Some("once") && !self.previous_exited {
    // The previous binary may still spend an in-memory copy without a conditional database claim.
    match self.w.previous.gone {
      Some(gone) => gone()
      None => ()
    }
    held = match self.keeper.usable(session, a.grant) {
      Err(why) => raise Refused(why)
      Ok(h) => h
    }
  }
  if gs(Some(held.grant), "mode") == Some("browser") {
    raise Refused("A sign-in is not run with: it is in this chat's browser (the `browser` tool) while its grant lasts.")
  }
  if a.env is Some(e) && !var_name(e) {
    raise Refused("env must be a variable name")
  }
  // Where it was granted for, and nowhere else.
  let on = match get(Some(held.request), "runOn") {
    Some(Object(_) as o) => Some(Peer::{ id: gtext(Some(o), "id"), name: gtext(Some(o), "name") })
    _ => None
  }
  match a.station {
    Some(st) if trim(st) != "" => {
      let asked = self.peer(st)
      if asked.map(p => p.id) != on.map(p => p.id) {
        match on {
          Some(o) =>
            raise Refused(
              "This grant is for commands on \{o.name}: run them there (station \"\{o.name}\", or none), or ask again.",
            )
          None => {
            let n = asked.unwrap().name
            raise Refused(
              "This grant is for commands on this station: to run them on \{n}, ask again with secret_use {station: \"\{n}\"}.",
            )
          }
        }
      }
    }
    _ => ()
  }
  let listing = self.listing_of(held.request)
  let rid = gtext(Some(held.request), "id")
  if !self.keeper.spend(rid) {
    raise Refused("this grant was already used or changed: ask again")
  }
  let env = match a.env {
    Some(e) if e != "" => Some(e)
    _ => gs(listing, "env")
  }
  let timeout_ms = a.timeout_ms.unwrap_or(run_ms).min(3600000.0)
  match on {
    Some(o) => {
      let ran = self.run_on(o, session, held, a.command, a.under.unwrap_or(""), timeout_ms, env)
      self.audit_(held.request, "run", slice("\{o.name}: \{a.command}", 0, b=500))
      return ran_said(ran)
    }
    None => ()
  }
  // The station does not update itself meanwhile: the proxy or ssh-agent the command uses is this process's.
  let let_go = (self.w.hold)()
  let h = held
  let ran = run_with(
    self.w,
    h,
    { command: a.command, cwd: a.cwd, env, timeout_ms },
    self.proxy,
    base_env(self.w),
    detail => {
      self.keeper.renew(session, rid)
      self.audit_(h.request, "use", detail) catch {
        _ => ()
      }
    },
    allowed=() => self.keeper.active(session, rid),
  ) catch {
    e => {
      let_go()
      raise e
    }
  }
  let_go()
  self.audit_(held.request, "run", slice(a.command, 0, b=500))
  ran_said(ran)
}

// ── commands on another station of the workspace ( 在另一台 station 上用) ──

///|
/// Station `given` (its name or id): another of the workspace, or None for this one.
fn Secrets::peer(self : Secrets, given : String) -> Peer? raise {
  guard self.w.peer is Some(peer) else { raise Refused("this station does not reach the workspace's other stations") }
  peer(trim(given)) catch {
    e => raise Refused(message_of(e))
  }
}

///|
/// `request` sent to station `on`, which answers at once that it started and says how it ended later (`vault.done`):
/// that, or a refusal when it would not start or said nothing within `ms` and a while.
async fn Secrets::elsewhere(self : Secrets, on : Peer, request : Json, ms : Double, used? : () -> Json) -> Json {
  guard self.w.ask is Some(ask) else { raise Refused("this station does not reach the workspace's other stations") }
  let id = "x_" + ulid(self.now(), (self.w.random)(16))
  let done : @effect.Deferred[Json] = @effect.Deferred::new()
  // How long its end is waited for: the machine's time, as the command's own is on that station.
  let stop = (self.w.after)(ms + 120000.0, () => if self.away.contains(id) {
    self.away.remove(id)
    ignore(done.fail(Refused("\{on.name} did not say how the command ended; it may still have run")))
  })
  self.away[id] = {
    station: on.id,
    done: result => {
      stop()
      ignore(done.succeed(result))
    },
    used,
    session: gs(Some(request), "session"),
    workspace: gs(Some(request), "workspace"),
  }
  ignore(
    @effect.runtime().fork(name="vault elsewhere", async fn() {
      let answer = ask(on.id, spread(Some(request), [("id", js(id))])) catch {
        e => {
          if !self.away.contains(id) {
            return
          }
          self.away.remove(id)
          stop()
          let why = message_of(e)
          // A station from before this answers what it does not know as one of its remote tasks.
          let old = if from_before(why) { " (a station from before this cannot: update it)" } else { "" }
          ignore(done.fail(Refused("\{on.name} did not start it: \{why}\{old}")))
          return
        }
      }
      if get(Some(answer), "started") == Some(Json::boolean(true)) || !self.away.contains(id) {
        return
      }
      self.away.remove(id)
      stop()
      ignore(done.fail(Refused("\{on.name} did not start it (a station from before this cannot: update it)")))
    }),
  )
  done.wait()
}

///|
/// A command run with grant `held` on station `on`, in the session's directory there (`under` it).
async fn Secrets::run_on(
  self : Secrets,
  on : Peer,
  session : String,
  held : @vault_crypto.Held,
  command : String,
  under : String,
  timeout_ms : Double,
  env : String?,
) -> Ran {
  let (ws, _) = self.place_of(session)
  let timeout = get(Some(held.grant), "timeout")
  if truthy(timeout) {
    // Only a station that answers and does not know the question is too old; one not reached is not.
    let answer = match self.w.ask {
      None => None
      Some(ask) =>
        Some(
          ask(on.id, obj([("method", js("vault.capabilities")), ("workspace", js(ws))])) catch {
            e => {
              if from_before(message_of(e)) {
                Json::null()
              } else {
                raise Refused("\{on.name} could not be reached (\{message_of(e)}): try again once it is back online")
              }
            }
          },
        )
    }
    if get(answer, "timeouts") != Some(Json::boolean(true)) {
      raise Refused("\{on.name} needs an update before a timed grant can run there")
    }
  }
  let rid = gtext(Some(held.request), "id")
  let fs = [
    ("method", js("vault.run")),
    ("workspace", js(ws)),
    ("session", js(session)),
    ("grant", js(rid)),
    ("command", js(command)),
    ("under", js(under)),
    ("timeoutMs", jn(timeout_ms)),
  ]
  if env is Some(e) && e != "" {
    fs.push(("env", js(e)))
  }
  fs.push(("mode", get(Some(held.grant), "mode").unwrap_or(Json::null())))
  fs.push(("hosts", get(Some(held.grant), "hosts").unwrap_or(Json::null())))
  fs.push(("secret", held.secret))
  fs.push(("expires", match held.until { Some(u) => jn(u); None => get(Some(held.grant), "exp").unwrap_or(Json::null()) }))
  if truthy(timeout) {
    fs.push(("grantTimeout", timeout.unwrap()))
  }
  let result = self.elsewhere(on, obj(fs), timeout_ms, used=() => {
    if !self.keeper.active(session, rid) {
      return Json::null()
    }
    self.keeper.renew(session, rid)
    match held.until {
      Some(u) => jn(u)
      None => get(Some(held.grant), "exp").unwrap_or(Json::null())
    }
  })
  guard gs(Some(result), "output") is Some(output) else {
    raise Refused("\{on.name} said nothing of how the command ended")
  }
  {
    code: gn(Some(result), "code").map(n => n.to_int()),
    signal: gs(Some(result), "signal"),
    output,
    cut: get(Some(result), "cut") == Some(Json::boolean(true)),
    timed_out: get(Some(result), "timedOut") == Some(Json::boolean(true)),
    used: Some(get(Some(result), "used") == Some(Json::boolean(true))),
  }
}

///|
/// What a command printed on station `on`, run in the session's directory there, taken as a secret to keep.
async fn Secrets::capture_on(self : Secrets, on : Peer, session : String, ws : String, command : String) -> Captured {
  let got = self.elsewhere(
    on,
    obj([
      ("method", js("vault.capture")),
      ("workspace", js(ws)),
      ("session", js(session)),
      ("command", js(command)),
      ("under", js("")),
      ("timeoutMs", jn(capture_ms)),
    ]),
    capture_ms,
  )
  guard gs(Some(got), "out") is Some(out) && gs(Some(got), "err") is Some(err) else {
    raise Refused("\{on.name} said nothing of what the command printed")
  }
  {
    code: gn(Some(got), "code").map(n => n.to_int()),
    signal: gs(Some(got), "signal"),
    out,
    raw: gs(Some(got), "raw"),
    err,
    timed_out: get(Some(got), "timedOut") == Some(Json::boolean(true)),
    too_long: get(Some(got), "tooLong") == Some(Json::boolean(true)),
  }
}

///|
/// A request of another station of the workspace (`vault.`): a command to run here with a secret it holds a grant
/// for, or one whose output it takes as a secret to keep; or how one sent from here ended.
pub async fn Secrets::heard(self : Secrets, peer : String, ws : String, request : Json) -> Json {
  let method_ = gtext(Some(request), "method")
  let id = gtext(Some(request), "id")
  if method_ == "vault.used" {
    match self.away.get(id) {
      Some(away) if away.station == peer && away.used is Some(used) => return obj([("until", used())])
      _ => raise Failure("no such command sent to that station")
    }
  }
  if method_ == "vault.done" {
    match self.away.get(id) {
      Some(away) if away.station == peer => {
        self.away.remove(id)
        (away.done)(get(Some(request), "result").unwrap_or(Json::null()))
        return obj([("ok", jb(true))])
      }
      _ => raise Failure("no such command sent to that station")
    }
  }
  // A command another station sends to run here (a rig runs those too, with no vault of its own).
  self.runs.heard(peer, ws, request)
}

///|
/// The grants a session holds that may still be used.
pub fn Secrets::held(self : Secrets, session : String) -> Array[@vault_crypto.Held] {
  self.keeper.held(session)
}

///|
/// A session's chat changed (store.ts `subscribe`'s `session` and `sessionRemoved`): one ended takes back the
/// commands it sent elsewhere and lets go of its grants.
pub fn Secrets::session_changed(self : Secrets, key : String) -> Unit {
  if !self.ended(key) {
    return
  }
  for id, away in self.away {
    match (away.session, away.workspace, self.w.ask) {
      (Some(s), Some(workspace), Some(ask)) if s == key =>
        ignore(
          @effect.runtime().fork(name="vault revoke", async fn() {
            ignore(ask(away.station, obj([("method", js("vault.revoke")), ("workspace", js(workspace)), ("id", js(id))]))) catch {
              _ => ()
            }
          }),
        )
      _ => ()
    }
  }
  if self.keeper.holds(key) {
    self.keeper.end(key)
  }
}
