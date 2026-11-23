// index.ts's answers to the other stations (`share.*`) and the lending of a subscription's login.

///|
/// A request of another station of one of the station's workspaces (the transport checked it is one), made in
/// `workspace` (None: the home one).
pub async fn Sharing::handle(self : Sharing, peer : String, request : Json, workspace? : String? = None) -> Json {
  let rq = Some(request)
  let asked = match get(rq, "method") {
    None | Some(Null) => ""
    m => js_string(m)
  }
  let id = match get(rq, "id") {
    None | Some(Null) => ""
    i => js_string(i)
  }
  if asked == "share.changed" {
    // (one this station is handing over as it is told: heard once the hand-over is done here)
    if self.move_done.get(id) is Some(moving) {
      moving.wait()
    }
    return self.heard(peer, id, request, match workspace {
      Some(_) => workspace
      None => self.home_ws()
    })
  }
  if asked == "share.take" {
    return self.take(peer, request)
  }
  if asked == "share.borrow" {
    return self.borrow(peer, id, request)
  }
  if entry_of(self.moved(), id) is Some(moved) && asked == "share.version" {
    return jobj([("moved", moved.get("to").unwrap_or(jnull()))])
  }
  guard self.shares().get(id) is Some(own) else { raise Failed(not_shared) }
  // Who may use it is this station's own word, said as such (a copy is taken away on it, `not_ours`); where a station
  // is, the cloud's list (not known, or leaving it out a while): refused apart, a copy kept on that.
  if refusal_of(own.allow, peer, self.rosters(), r => self.reach(own.kind, own.profile, peer, Some(r))) is Some(no) {
    raise Failed(no)
  }
  let hosted_all = self.hosted()
  let version_now = () => match entry_of(hosted_all, id) {
    Some(h) =>
      match h.get("version") {
        None | Some(Null) => jnum(0.0)
        Some(v) => v
      }
    None => jnum(0.0)
  }
  if asked == "share.version" {
    // A copy of a skill not shown there, as one of that station's own has its name (or shown again).
    let version = version_now()
    if entry_of(hosted_all, id) is Some(hosted) && get(rq, "hidden") is Some(True | False as h) {
      let hidden = h is True
      let was = match get(hosted.get("missing"), peer) {
        None => jnull()
        Some(v) => v
      }
      let want = if hidden { jstr("same-name") } else { jnull() }
      if !strict_eq(Some(was), Some(want)) {
        miss(hosted, peer, if hidden { Some("same-name") } else { None })
        self.write_state()
        (self.deps.changed)()
      }
    }
    return jobj([("version", version)])
  }
  if own.kind == "profile" {
    let p = own.profile.unwrap_or(jnull())
    if asked == "share.get" {
      // (its account read first: the rest as it is when this answers)
      let email = if gets(Some(p), ["access", "kind"]) is Some(String("subscription")) {
        self.email_of(p)
      } else {
        None
      }
      guard self.shares().get(id) is Some(now) && now.kind == "profile" else { raise Failed(not_shared) }
      let at = version_now()
      // It has a copy now: it is told when this one changes.
      self.told(id, peer, at)
      let profile = now.profile.unwrap_or(jnull())
      return jobj([
        ("version", at),
        ("profile", portable(profile)),
        ("email", match email { Some(e) => jstr(e); None => jnull() }),
        ("allow", now.allow),
        ("workspaces", jstrs(self.shared_in(profile))),
        (
          "quotaRevision",
          match entry_of(hosted_all, id) {
            Some(h) =>
              match h.get("quotaRevision") {
                None | Some(Null) => jnum(0.0)
                Some(v) => v
              }
            None => jnum(0.0)
          },
        ),
      ])
    }
    if asked == "share.lend" {
      if self.moving.contains(id) {
        raise Failed("the login is being moved to another station")
      }
      return self.lend(p, match get(rq, "rejected") {
        Some(String(r)) => Some(r)
        _ => None
      })
    }
    if asked == "share.status" {
      return (self.deps.status)(js_string(get(Some(p), "id")), get(rq, "recheck") is Some(True))
    }
    if asked == "share.quotaReset" {
      let key = match get(rq, "key") {
        Some(String(k)) => k
        _ => ""
      }
      if key == "" ||
        !(get(Some(p), "runtime") is Some(String("codex"))) ||
        !(gets(Some(p), ["access", "kind"]) is Some(String("subscription"))) {
        raise Failed("invalid allowance reset")
      }
      let keys = match entry_of(hosted_all, id) {
        Some(h) =>
          match h.get("resetKeys") {
            Some(Array(a)) => a
            _ => []
          }
        None => []
      }
      if !keys.contains(jstr(key)) && self.deps.quota_reset is Some(f) {
        f(js_string(get(Some(p), "id")))
      }
      self.quota_reset(js_string(get(Some(p), "id")), key)
      return jobj([("heard", jbool(true))])
    }
  } else {
    let skill = own.skill.unwrap_or("")
    let dir = self.files.join([self.skills_dir(), skill])
    if asked == "share.get" {
      // (its version as it is when its files are read: not between a change read and its version raised)
      return self.hosted_turn.run(async fn() {
        let read = self.read_skill(dir, bytes=true)
        let now = version_now()
        self.told(id, peer, now)
        jobj([("version", now), ("hash", jstr(read.hash)), ("files", read.files.unwrap_or(jnull())), ("allow", own.allow)])
      })
    }
    if asked == "share.put" {
      return self.take_edit(peer, id, skill, dir, request)
    }
  }
  raise Failed("unknown share request \{asked}")
}

///|
/// Notes that a station has a share at a version (it has fetched it).
fn Sharing::told(self : Sharing, id : String, peer : String, version : Json) -> Unit {
  guard entry_of(self.hosted(), id) is Some(hosted) else { return }
  obj_field(hosted, "told")[peer] = version
  self.write_state()
}

///|
/// What a host says of one of its shares, in workspace `ws`: there, changed, no longer for this station, or moved to
/// another station.
async fn Sharing::heard(self : Sharing, peer : String, id : String, request : Json, ws : String?) -> Json {
  if !share_id_ok(id) {
    raise Failed("bad share id")
  }
  let rq = Some(request)
  let borrowed_all = self.borrowed()
  let had = entry_of(borrowed_all, id)
  let gone = get(rq, "gone") is Some(True)
  let new_host = match get(rq, "host") {
    Some(String(h)) => Some(h)
    _ => None
  }
  let host_is = (h : Map[String, Json], s : String) => h.get("host") is Some(String(x)) && x == s
  // From another station than the one it was had from: that one handed it over (its word on where may come later).
  if had is Some(h) && !host_is(h, peer) && !gone && new_host is None {
    h["host"] = jstr(peer)
    h["stale"] = jbool(true)
  }
  // The new host's announcement may arrive before the old host's handover notice: a notice naming the host already
  // taken is a harmless retry.
  if had is Some(h) && !host_is(h, peer) && new_host is Some(nh) && host_is(h, nh) {
    return jobj([("heard", jbool(true))])
  }
  if had is Some(h) && !host_is(h, peer) {
    raise Failed("only the station that has it says so")
  }
  // (the state changed at once, then the files: what reads the state meanwhile finds it as it is now)
  let mut dropped : (async () -> Unit)? = None
  if gone {
    if had is Some(h) {
      borrowed_all.remove(id)
      dropped = Some(async fn() { self.drop(id, h) })
    }
  } else if new_host is Some(nh) {
    if had is Some(h) {
      h["host"] = jstr(nh)
      h["stale"] = jbool(true)
    }
  } else if had is None || !strict_eq(had.unwrap().get("version"), get(rq, "version")) {
    let kind = if get(rq, "kind") is Some(String("skill")) { "skill" } else { "profile" }
    let name = match get(rq, "name") {
      None | Some(Null) => id
      n => js_string(n)
    }
    if kind == "skill" && !@memory.portable_name(name) {
      raise Failed("bad skill name")
    }
    // Renamed on its host: no longer linked under the name it had.
    if had is Some(h) && h.get("kind") is Some(String("skill")) && !(h.get("name") is Some(String(x)) && x == name) {
      let copy : Map[String, Json] = Map([])
      for k, v in h {
        copy[k] = v
      }
      // (the link is let go in the links' turn, now: as `this.unlinkSkill` is begun at once)
      let unlinking = @effect.Deferred::new()
      self.tasks.spawn(async fn() {
        defer ignore(unlinking.succeed(()))
        self.unlink_skill(id, copy)
      })
      dropped = Some(async fn() { unlinking.wait() })
    }
    let made : Map[String, Json] = Map([])
    match had {
      Some(h) =>
        for k in js_keys(h) {
          made[k] = h[k]
        }
      None => {
        made["version"] = jnum(-1.0)
        made["hash"] = jstr("")
      }
    }
    // A skill of a joined workspace's station: linked into that workspace's skills.
    if kind == "skill" && had is None && ws is Some(w) && Some(w) != self.home_ws() {
      made["workspace"] = jstr(w)
    }
    made["kind"] = jstr(kind)
    made["name"] = jstr(name)
    made["host"] = jstr(peer)
    made["allow"] = allow_of(get(rq, "allow"))
    made["stale"] = jbool(true)
    borrowed_all[id] = Json::object(made)
  }
  self.write_state()
  if dropped is Some(f) {
    f()
  }
  self.reconcile_soon()
  // Not to be shown here, as something of this station's has its name (its own skill wins): said to its host.
  if entry_of(self.borrowed(), id) is Some(now) &&
    now.get("kind") is Some(String("skill")) &&
    !self.skill_linked(id, now) &&
    self.name_taken(now) {
    return jobj([("heard", jbool(true)), ("hidden", jbool(true))])
  }
  jobj([("heard", jbool(true))])
}

///|
/// The account a profile is signed in to, as its files say.
async fn Sharing::email_of(self : Sharing, p : Json) -> String? {
  let pj = Some(p)
  if gets(pj, ["share", "email"]) is Some(String(e)) {
    return Some(e)
  }
  if get(pj, "machine") is Some(True) {
    return match self.deps.machine_email {
      Some(f) => f(js_string(get(pj, "runtime")))
      None => None
    }
  }
  let home = self.home(p)
  let runtime = get(pj, "runtime")
  // (read again only once its file changed: accounts/index.ts emailKept)
  if runtime is Some(String("grok" | "cursor" as r)) {
    return (self.deps.account_email)(r, home)
  }
  if runtime is Some(String("codex")) {
    guard self.files.read_text(self.files.join([home, "auth.json"])) is Some(text) else { return None }
    let auth = js_parse(text) catch { _ => return None }
    let token = match gets(Some(auth), ["tokens", "id_token"]) {
      None | Some(Null) => ""
      t => js_string(t)
    }
    guard jwt_claims(token) is Some(claims) else { return None }
    let email = match get(Some(claims), "email") {
      None | Some(Null) => gets(Some(claims), ["https://api.openai.com/profile", "email"])
      e => e
    }
    return str_of(email)
  }
  if runtime is Some(String("claude")) {
    for file in [self.files.join([home, ".claude.json"]), self.files.join([home, "claude.json"])] {
      guard self.files.read_text(file) is Some(text) else { continue }
      let parsed = js_parse(text) catch { _ => continue }
      if gets(Some(parsed), ["oauthAccount", "emailAddress"]) is Some(String(e)) {
        return Some(e)
      }
    }
  }
  None
}

///|
/// An edit from a station that copies a skill: taken when made on the current version; else kept beside it.
async fn Sharing::take_edit(self : Sharing, peer : String, id : String, name : String, dir : String, request : Json) -> Json {
  self.hosted_turn.run(async fn() { self.take_edit_now(peer, id, name, dir, request) })
}

///|
async fn Sharing::take_edit_now(self : Sharing, peer : String, id : String, name : String, dir : String, request : Json) -> Json {
  let hosted = entry_of(self.hosted(), id)
  let version = match hosted {
    Some(h) =>
      match h.get("version") {
        None | Some(Null) => jnum(0.0)
        Some(v) => v
      }
    None => jnum(0.0)
  }
  let files = match get(Some(request), "files") {
    Some(Object(_) as f) => f
    _ => Json::object(Map([]))
  }
  let conflict = !strict_eq(get(Some(request), "base"), Some(version))
  // Its every file checked by the program before anything is written, one made on an older copy too.
  let args = [("dir", jstr(dir)), ("files", files), ("most", jnum(max_skill_bytes))]
  if conflict {
    args.push(("check", jbool(true)))
  }
  ignore(self.program.ask("skillWrite", args))
  if conflict && get(Some(files), "SKILL.md") is Some(String(skill)) {
    ignore(self.program.ask("skillConflict", [("dir", jstr(dir)), ("peer", jstr(peer)), ("content", jstr(skill))]))
  }
  let next = jnum_js(js_num(Some(version)) + 1.0)
  if hosted is Some(h) {
    h["version"] = next
    h["hash"] = jstr(self.read_skill(dir).hash)
    // The station that sent it has it (unless it conflicted); the others are told.
    if !conflict {
      obj_field(h, "told")[peer] = next
    }
  }
  self.write_state()
  self.deps.log.info(
    "share",
    if conflict {
      "a skill edit on an older copy kept beside it"
    } else {
      "a skill edit taken"
    },
    jobj([("name", jstr(name)), ("from", jstr(peer))]),
  )
  self.reconcile_soon()
  jobj([("version", next), ("conflict", jbool(conflict))])
}

///|
/// A short-lived access token of a shared subscription, renewed here when needed. Its login over here, it is checked
/// again (its borrowers, older ones too, read that in `share.status`) and the borrower told so (LOGIN_OVER).
async fn Sharing::lend(self : Sharing, p : Json, rejected : String?) -> Json {
  self.lend_of(p, rejected) catch {
    e if over_here(e) => {
      let id = js_string(get(Some(p), "id"))
      self.tasks.spawn(async fn() { ignore((self.deps.status)(id, true)) catch { _ => () } })
      raise Failed(login_over + error_words(e))
    }
    e => raise e
  }
}

///|
async fn Sharing::lend_of(self : Sharing, p : Json, rejected : String?) -> Json {
  let pj = Some(p)
  if !(gets(pj, ["access", "kind"]) is Some(String("subscription"))) {
    raise Failed("only a subscription is lent")
  }
  if get(pj, "runtime") is Some(String("claude")) {
    let (token, expires_at) = (self.deps.claude_token)(p, rejected)
    return jobj([("runtime", jstr("claude")), ("token", jstr(token)), ("expiresAt", jnum_js(expires_at))])
  }
  if get(pj, "runtime") is Some(String("agy")) {
    return self.lend_agy_here(p)
  }
  let file = self.codex_file(p)
  let mut auth = js_parse(self.files.need_text(file))
  let mut expires_at = jwt_expiry(gets(Some(auth), ["tokens", "access_token"])).unwrap_or(0.0)
  let now = () => (self.deps.clock.now)()
  let mut over : Error? = None
  if expires_at - now() < codex_lend_ms {
    // By the Codex running on it, asked to, or here where none runs.
    let auth_then = auth
    let renewed = self.renew_once(p, "Codex", expires_at, async fn() {
      if !(self.deps.codex_renew_running)(js_string(get(pj, "id"))) {
        ignore(self.renew_codex(file, auth_then))
      }
    })
    // One that still lasts CODEX_MIN_MS waits for its renewal LEND_BOUND_MS at most, then is lent as it is.
    over = if expires_at - now() >= codex_min_ms {
      self.within_bound(p, "Codex", expires_at, renewed)
    } else {
      renewed.wait()
    }
    // Read again either way: Codex may have renewed it and then failed a step after.
    auth = js_parse(self.files.need_text(file))
    expires_at = jwt_expiry(gets(Some(auth), ["tokens", "access_token"])).unwrap_or(0.0)
  }
  // (its renewal refused for good: the login here is over, LOGIN_OVER; failed for now: refused as before)
  if expires_at - now() < codex_min_ms {
    if over is Some(err) {
      raise err
    }
    raise Failed("the Codex login here runs out soon and cannot be renewed now")
  }
  let tokens = match get(Some(auth), "tokens") {
    None | Some(Null) => Json::object(Map([]))
    t => t.unwrap()
  }
  let lent : Map[String, Json] = Map([])
  for k in ["id_token", "access_token", "account_id"] {
    if get(Some(tokens), k) is Some(v) {
      lent[k] = v
    }
  }
  jobj([("runtime", jstr("codex")), ("tokens", Json::object(lent)), ("expiresAt", jnum_js(expires_at))])
}

///|
/// Where an Antigravity CLI home keeps its sign-in (agents/agy.ts `agyToken`).
fn Sharing::agy_token(self : Sharing, home : String) -> String {
  self.files.join([self.files.join([self.files.join([home, "agy"]), ".gemini"]), "antigravity-cli", "antigravity-oauth-token"])
}

///|
/// When an Antigravity CLI sign-in runs out (agents/agy.ts `agyExpiryIn`): 0 where it does not say.
pub fn agy_expiry_in(text : String) -> Double {
  let parsed = js_parse(text) catch { _ => return 0.0 }
  let expiry = gets(Some(parsed), ["token", "expiry"])
  let at = match expiry {
    None => @double.not_a_number
    Some(String(s)) => date_parse(s)
    Some(Number(d, ..)) => d
    Some(Null) => @double.not_a_number
    other => date_parse(js_string(other))
  }
  if at == at && at != @double.infinity && at != @double.neg_infinity {
    at
  } else {
    0.0
  }
}

///|
/// An object without one of its keys (`const { k: _, ...rest } = v`).
fn without(v : Json?, key : String) -> Json {
  let out : Map[String, Json] = Map([])
  match v {
    Some(Object(m)) =>
      for k in js_keys(m) {
        if k != key {
          out[k] = m[k]
        }
      }
    Some(String(s)) =>
      // (a string spread: its characters by index)
      for i, c in s.to_array() {
        out[i.to_string()] = jstr(c.to_string())
      }
    Some(Array(a)) =>
      for i, x in a {
        out[i.to_string()] = x
      }
    _ => ()
  }
  Json::object(out)
}

///|
/// An Antigravity CLI sign-in's access token, renewed first when it has less than AGY_LEND_MS left. Its refresh
/// token stays here.
async fn Sharing::lend_agy_here(self : Sharing, p : Json) -> Json {
  let file = self.agy_token(self.home(p))
  let mut text = self.files.need_text(file)
  let mut expires_at = agy_expiry_in(text)
  let now = () => (self.deps.clock.now)()
  let mut over : Error? = None
  if expires_at - now() < agy_lend_ms {
    let renewed = self.renew_once(p, "Antigravity CLI", expires_at, async fn() {
      match self.deps.agy_renew {
        Some(f) => f(self.home(p))
        None => raise Failed("this station renews no Antigravity CLI sign-in")
      }
    })
    over = if expires_at - now() >= agy_min_ms {
      self.within_bound(p, "Antigravity CLI", expires_at, renewed)
    } else {
      renewed.wait()
    }
    text = self.files.need_text(file)
    expires_at = agy_expiry_in(text)
  }
  if expires_at - now() < agy_min_ms {
    if over is Some(err) {
      raise err
    }
    raise Failed("the Antigravity CLI sign-in here runs out soon and cannot be renewed now")
  }
  let had = js_parse(text)
  let token = without(
    match get(Some(had), "token") {
      None | Some(Null) => Some(Json::object(Map([])))
      t => t
    },
    "refresh_token",
  )
  // `stored`: the rest of its file (a company's project, region and tier) for the borrower's.
  let rest = without(Some(had), "token")
  jobj([
    ("runtime", jstr("agy")),
    ("token", token),
    ("email", match get(Some(had), "id_token_email") { Some(String(e)) => jstr(e); _ => jnull() }),
    ("auth_method", match get(Some(had), "auth_method") { Some(String(e)) => jstr(e); _ => jnull() }),
    ("stored", rest),
    ("expiresAt", jnum_js(expires_at)),
  ])
}

///|
/// `renewed` waited for LEND_BOUND_MS at most: past it, what is lent is the login as it is, which is said. What came of
/// it in time: its login found over (`renew_once`), else none.
async fn Sharing::within_bound(
  self : Sharing,
  p : Json,
  what : String,
  expires_at : Double,
  renewed : @effect.Deferred[Error?],
) -> Error? {
  let began = (self.deps.clock.now)()
  let first : @effect.Deferred[Bool] = @effect.Deferred::new()
  let stop = (self.deps.clock.after)(lend_bound_ms, () => ignore(first.succeed(false)))
  if renewed.is_done() {
    ignore(first.succeed(true))
  } else {
    self.tasks.spawn(async fn() {
      ignore(renewed.wait()) catch {
        _ => ()
      }
      ignore(first.succeed(true))
    })
  }
  let in_time = first.wait()
  stop()
  if in_time {
    return renewed.wait()
  } else {
    let now = (self.deps.clock.now)()
    self.deps.log.warn(
      "share",
      "a shared \{what} login's renewal outlasted the lend's bound; the login it has was lent, the renewal goes on",
      jobj([
        ("profile", get(Some(p), "id").unwrap_or(jnull())),
        ("ms", jnum(now - began)),
        ("lastsMin", jnum(((expires_at - now) / 60000.0).round())),
      ]),
    )
    None
  }
}

///|
/// One renewal of a profile's login at a time, what is lent meanwhile waiting on it; a failure is said. What came of it:
/// the failure where it says the login is over (`over_here`), else none.
fn Sharing::renew_once(
  self : Sharing,
  p : Json,
  what : String,
  expires_at : Double,
  renew : async () -> Unit,
) -> @effect.Deferred[Error?] {
  let id = js_string(get(Some(p), "id"))
  if self.renewing.get(id) is Some(going) {
    return going
  }
  let began = (self.deps.clock.now)()
  let done : @effect.Deferred[Error?] = @effect.Deferred::new()
  self.renewing[id] = done
  self.tasks.spawn(async fn() {
    let over : Ref[Error?] = Ref(None)
    defer {
      self.renewing.remove(id)
      ignore(done.succeed(over.val))
    }
    renew() catch {
      e => {
        if over_here(e) {
          over.val = Some(e)
        }
        let now = (self.deps.clock.now)()
        self.deps.log.warn("share", "renewing a shared \{what} login failed", jobj([
          ("profile", get(Some(p), "id").unwrap_or(jnull())),
          ("ms", jnum(now - began)),
          ("lastsMin", jnum(((expires_at - now) / 60000.0).round())),
          ("error", jstr(error_words(e))),
        ]))
      }
    }
  })
  done
}

///|
/// Once a renewal of profile `id` going on, if any, is over (tests).
pub async fn Sharing::renewed_behind(self : Sharing, id : String) -> Unit {
  if self.renewing.get(id) is Some(d) {
    ignore(d.wait())
  }
}

///|
/// Codex's own renewal of its ChatGPT login, done here while no Codex runs on it.
async fn Sharing::renew_codex(self : Sharing, file : String, auth : Json) -> Json {
  let refresh = gets(Some(auth), ["tokens", "refresh_token"])
  guard refresh is Some(String(r)) && r != "" else { raise Over("no refresh token") }
  let body = js_stringify(jobj([
    ("client_id", jstr(codex_client_id)),
    ("grant_type", jstr("refresh_token")),
    ("refresh_token", jstr(r)),
    ("scope", jstr("openid profile email")),
  ]))
  let (status, text) = (self.deps.fetch)(self.deps.codex_token_url, body)
  // (refused: the login is over; any other answer is the provider's trouble, for now)
  if status == 400 || status == 401 || status == 403 {
    raise Over("the token endpoint answered \{status}")
  }
  if status < 200 || status > 299 {
    raise Failed("the token endpoint answered \{status}")
  }
  let got = js_parse(text)
  let next = clone(auth)
  guard next is Object(n) else { raise Failed("the login here is no object") }
  let tokens : Map[String, Json] = Map([])
  if n.get("tokens") is Some(Object(t)) {
    for k in js_keys(t) {
      tokens[k] = t[k]
    }
  }
  n["tokens"] = Json::object(tokens)
  for k in ["id_token", "access_token", "refresh_token"] {
    if get(Some(got), k) is Some(String(v)) {
      tokens[k] = jstr(v)
    }
  }
  n["last_refresh"] = jstr(iso_string((self.deps.clock.now)()))
  self.files.write_private_text(file, js_stringify2(next))
  next
}

// ── borrowing (the agents' drivers) ──

///|
/// Whether a profile is a copy of another station's subscription (its login borrowed for each process).
pub fn Sharing::borrowed_subscription(_self : Sharing, profile : Json) -> Bool {
  let pj = Some(profile)
  is_obj(get(pj, "share")) &&
  gets(pj, ["share", "borrowed"]) is Some(True) &&
  gets(pj, ["access", "kind"]) is Some(String("subscription"))
}

///|
fn host_of(profile : Json) -> String raise {
  match gets(Some(profile), ["share", "host"]) {
    Some(String(h)) => h
    _ => raise Failed("this profile is not borrowed from another station")
  }
}

///|
/// Once the cloud has said the workspace's stations, or ROSTER_WAIT_MS on.
async fn Sharing::roster_said(self : Sharing) -> Unit {
  let cloud = self.deps.cloud
  if (cloud.peers_current)() || !(cloud.has_state)() {
    return
  }
  let said : @effect.Deferred[Unit] = @effect.Deferred::new()
  let stop : Ref[() -> Unit] = Ref(() => ())
  let give_up : Ref[() -> Unit] = Ref(() => ())
  let done = () => {
    (stop.val)()
    (give_up.val)()
    ignore(said.succeed(()))
  }
  stop.val = (cloud.listen)(() => if (cloud.peers_current)() { done() })
  give_up.val = (self.deps.clock.after)(roster_wait_ms, done)
  said.wait()
}

///|
fn Sharing::not_lent(self : Sharing) -> ShareError {
  Said(tr((self.deps.lang)(), "station.share.notLent"))
}

///|
/// A copy asked of its host again (reconcile's share.version), as at the start of a run (index.ts `askAgain`).
fn Sharing::ask_again(self : Sharing, profile : Json) -> Unit {
  self.checked.remove(js_string(gets(Some(profile), ["share", "id"])))
  self.reconcile_soon()
}

///|
/// A borrowed Claude subscription's token, from its host; `rejected`, the one a process here was refused with.
pub async fn Sharing::lend_claude(self : Sharing, profile : Json, rejected? : String? = None) -> (String, Double) {
  let host = host_of(profile)
  let pid = js_string(get(Some(profile), "id"))
  let now = () => (self.deps.clock.now)()
  match self.lent_claude.get(pid) {
    None => self.roster_said()
    Some((token, at)) =>
      if Some(token) == rejected || at - now() < keep_lent_ms {
        self.roster_said()
      }
  }
  try {
    let request = jobj([("method", jstr("share.lend")), ("id", gets(Some(profile), ["share", "id"]).unwrap_or(jnull()))])
    if rejected is Some(r) && request is Object(m) {
      m["rejected"] = jstr(r)
    }
    let got = self.ask(host, None, request)
    self.silent_hosts.remove(host)
    guard get(Some(got), "token") is Some(String(token)) else { raise Failed("the host lent no token") }
    let lent = (token, num_or0(get(Some(got), "expiresAt")))
    self.lent_claude[pid] = lent
    lent
  } catch {
    e if is_login_over(e) => {
      self.lent_claude.remove(pid)
      raise self.over_there(profile, e)
    }
    e => {
      // Left out by who may use it (`not_ours`): nothing lent before is used, and the copy is asked of again, which
      // takes it away. Any other refusal is the host not answering, as before.
      let ours = !not_ours(e)
      if ours {
        self.silent_hosts[host] = now()
        self.schedule_retry()
      } else {
        self.lent_claude.remove(pid)
        self.ask_again(profile)
      }
      (self.deps.changed)()
      if ours &&
        self.lent_claude.get(pid) is Some((token, at)) &&
        Some(token) != rejected &&
        at - now() >= keep_lent_ms {
        self.deps.log.warn("share", "the host did not lend a new token; the one lent before is used", jobj([
          ("profile", jstr(pid)),
          ("error", jstr(error_words(e))),
        ]))
        return (token, at)
      }
      self.deps.log.warn("share", "the host did not lend it", jobj([("profile", jstr(pid)), ("error", jstr(error_words(e)))]))
      raise self.not_lent()
    }
  }
}

///|
/// When the Codex login lent before, kept in a borrowed profile's home, runs out (0 when there is none).
async fn Sharing::kept_codex_expiry(self : Sharing, file : String) -> Double {
  guard self.files.read_text(file) is Some(text) else { return 0.0 }
  let parsed = js_parse(text) catch { _ => return 0.0 }
  jwt_expiry(gets(Some(parsed), ["tokens", "access_token"])).unwrap_or(0.0)
}

///|
/// A borrowed Codex subscription: its home's auth.json written with the host's current tokens (no refresh token, so
/// Codex never renews it here); when they run out.
pub async fn Sharing::lend_codex(self : Sharing, profile : Json, rejected? : Bool = false) -> Double {
  let host = host_of(profile)
  let home = self.home(profile)
  let pid = js_string(get(Some(profile), "id"))
  let file = self.files.join([home, "auth.json"])
  let now = () => (self.deps.clock.now)()
  if self.kept_codex_expiry(file) - now() < keep_lent_ms {
    self.roster_said()
  }
  let got = try {
    let got = self.ask(host, None, jobj([("method", jstr("share.lend")), ("id", gets(Some(profile), ["share", "id"]).unwrap_or(jnull()))]))
    self.silent_hosts.remove(host)
    got
  } catch {
    e if is_login_over(e) => raise self.over_there(profile, e)
    e => {
      // Left out by who may use it (`not_ours`): as lend_claude.
      let ours = !not_ours(e)
      if ours {
        self.silent_hosts[host] = now()
        self.schedule_retry()
      } else {
        self.ask_again(profile)
      }
      (self.deps.changed)()
      let kept = if ours { self.kept_codex_expiry(file) } else { 0.0 }
      if ours && !rejected && kept - now() >= keep_lent_ms {
        self.deps.log.warn("share", "the host did not lend a new login; the one lent before is used", jobj([
          ("profile", jstr(pid)),
          ("error", jstr(error_words(e))),
        ]))
        return kept
      }
      self.deps.log.warn("share", "the host did not lend it", jobj([("profile", jstr(pid)), ("error", jstr(error_words(e)))]))
      raise self.not_lent()
    }
  }
  let tokens : Map[String, Json] = Map([])
  match get(Some(got), "tokens") {
    Some(t) =>
      match without(Some(t), "") {
        Object(m) =>
          for k in js_keys(m) {
            tokens[k] = m[k]
          }
        _ => ()
      }
    None => ()
  }
  tokens["refresh_token"] = jstr("lent-by-another-station")
  let auth = jobj([
    ("auth_mode", jstr("chatgpt")),
    ("OPENAI_API_KEY", jnull()),
    ("tokens", Json::object(tokens)),
    ("last_refresh", jstr(iso_string(now()))),
  ])
  self.files.write_private_text(file, js_stringify2(auth))
  num_or0(get(Some(got), "expiresAt"))
}

///|
/// The sign-in file lent, as a borrower writes it (agents/agy.ts `agyLentFile`).
pub fn agy_lent_file(lent : Json) -> String {
  let token = without(
    match get(Some(lent), "token") {
      None | Some(Null) => Some(Json::object(Map([])))
      t => t
    },
    "refresh_token",
  )
  let stored = match get(Some(lent), "stored") {
    Some(Object(_) as s) => s
    _ => Json::object(Map([]))
  }
  let out : Map[String, Json] = Map([])
  if stored is Object(s) {
    for k in js_keys(s) {
      out[k] = s[k]
    }
  }
  out["token"] = token
  out["auth_method"] = match get(Some(lent), "auth_method") {
    None | Some(Null) =>
      match get(Some(stored), "auth_method") {
        None | Some(Null) => jstr("consumer")
        Some(v) => v
      }
    Some(v) => v
  }
  if truthy(get(Some(lent), "email")) {
    out["id_token_email"] = get(Some(lent), "email").unwrap()
  }
  js_stringify(Json::object(out))
}

///|
/// A borrowed Antigravity CLI subscription: its home's sign-in file written with the host's current access token (no
/// refresh token); when it runs out.
pub async fn Sharing::lend_agy(self : Sharing, profile : Json, rejected? : Bool = false) -> Double {
  let host = host_of(profile)
  let file = self.agy_token(self.home(profile))
  let pid = js_string(get(Some(profile), "id"))
  let now = () => (self.deps.clock.now)()
  let kept = async fn() -> Double {
    match self.files.read_text(file) {
      Some(t) => agy_expiry_in(t)
      None => 0.0
    }
  }
  if kept() - now() < keep_agy_ms {
    self.roster_said()
  }
  let got = try {
    let got = self.ask(host, None, jobj([("method", jstr("share.lend")), ("id", gets(Some(profile), ["share", "id"]).unwrap_or(jnull()))]))
    self.silent_hosts.remove(host)
    got
  } catch {
    e if is_login_over(e) => raise self.over_there(profile, e)
    e => {
      // Left out by who may use it (`not_ours`): as lend_claude.
      let ours = !not_ours(e)
      if ours {
        self.silent_hosts[host] = now()
        self.schedule_retry()
      } else {
        self.ask_again(profile)
      }
      (self.deps.changed)()
      let until = if ours { kept() } else { 0.0 }
      if ours && !rejected && until - now() >= keep_agy_ms {
        self.deps.log.warn("share", "the host did not lend a new sign-in; the one lent before is used", jobj([
          ("profile", jstr(pid)),
          ("error", jstr(error_words(e))),
        ]))
        return until
      }
      self.deps.log.warn("share", "the host did not lend it", jobj([("profile", jstr(pid)), ("error", jstr(error_words(e)))]))
      raise self.not_lent()
    }
  }
  if !(get(Some(got), "runtime") is Some(String("agy"))) ||
    !(gets(Some(got), ["token", "access_token"]) is Some(String(_))) {
    raise self.not_lent()
  }
  self.files.write_private_text(file, agy_lent_file(got))
  if get(Some(got), "email") is Some(String(e)) && e != "" {
    let account = self.files.join([self.files.join([self.home(profile), "agy"]), "account.json"])
    self.files.write_private_text(account, js_stringify(jobj([("email", jstr(e))])) + "\n")
  }
  num_or0(get(Some(got), "expiresAt"))
}

///|
/// A borrowed profile's login over on its host (LOGIN_OVER): the host answered, so it is not one that did not; its check
/// here says to sign in again, and a session that could not start on it goes on on another (`LoginOver`).
fn Sharing::over_there(self : Sharing, profile : Json, e : Error) -> ShareError raise {
  let pid = js_string(get(Some(profile), "id"))
  self.silent_hosts.remove(host_of(profile))
  if self.deps.login_expired is Some(f) {
    f(pid)
  }
  (self.deps.changed)()
  self.deps.log.warn("share", "the host's login of a borrowed profile is over", jobj([("profile", jstr(pid)), ("error", jstr(error_words(e)))]))
  LoginOver(pid, tr((self.deps.lang)(), "station.quota.signInExpired"))
}

///|
/// A borrowed profile's check and allowance, as its host has them; `recheck`: its login asked of its provider again
/// there first (a host from before asks nothing again: its answer is what it had).
pub async fn Sharing::status(self : Sharing, profile : Json, recheck? : Bool = false) -> Json {
  let host = host_of(profile)
  self.roster_said()
  try {
    let request = jobj([("method", jstr("share.status")), ("id", gets(Some(profile), ["share", "id"]).unwrap_or(jnull()))])
    if recheck && request is Object(m) {
      m["recheck"] = jbool(true)
    }
    let got = self.ask(host, None, request)
    self.silent_hosts.remove(host)
    let or_null = (v : Json?) => match v {
      None | Some(Null) => jnull()
      Some(x) => x
    }
    jobj([("check", or_null(get(Some(got), "check"))), ("quota", or_null(get(Some(got), "quota")))])
  } catch {
    e => {
      self.silent_hosts[host] = (self.deps.clock.now)()
      self.schedule_retry()
      raise e
    }
  }
}

///|
/// A sign-in changed on this station: a profile signed in anew, shared from here, has its copies told a new version.
pub fn Sharing::login_updated(self : Sharing, profile_id? : String? = None) -> Unit {
  let profile = match profile_id {
    Some(pid) =>
      match self.profiles().search_by(p => get(Some(p), "id") is Some(String(x)) && x == pid) {
        Some(i) => Some(self.profiles()[i])
        None => None
      }
    None => None
  }
  if profile is Some(p) &&
    gets(Some(p), ["share", "id"]) is Some(String(id)) &&
    !(get(Some(p), "runtime") is Some(String("codex"))) &&
    !(gets(Some(p), ["share", "borrowed"]) is Some(True)) {
    if entry_of(self.hosted(), id) is Some(hosted) {
      hosted["version"] = jnum_js(js_num(hosted.get("version")) + 1.0)
      self.write_state()
    }
  }
  self.reconcile_soon()
}

///|
/// A reset made here or by a borrower is sent to every copy, including those currently offline.
pub async fn Sharing::quota_reset(self : Sharing, profile_id : String, key : String) -> Unit {
  guard self.profiles().search_by(p => get(Some(p), "id") is Some(String(x)) && x == profile_id) is Some(at) else {
    return
  }
  let profile = self.profiles()[at]
  guard gets(Some(profile), ["share", "id"]) is Some(String(id)) else { return }
  if self.move_done.get(id) is Some(moving) {
    moving.wait()
    return self.quota_reset(profile_id, key)
  }
  if gets(Some(profile), ["share", "borrowed"]) is Some(True) {
    guard entry_of(self.borrowed(), id) is Some(had) else { return }
    let keys : Array[Json] = []
    let all = match had.get("resetPending") {
      Some(Array(a)) => a.copy()
      _ => []
    }
    all.push(jstr(key))
    // (`[...new Set(…)]`: each once, where it came first)
    for k in all {
      if !keys.iter().any(x => strict_eq(Some(x), Some(k))) {
        keys.push(k)
      }
    }
    had["resetPending"] = jarr(keys)
  } else {
    let mut hosted = entry_of(self.hosted(), id)
    if hosted is None {
      self.reconcile()
      hosted = entry_of(self.hosted(), id)
    }
    guard hosted is Some(h) else { return }
    let keys = match h.get("resetKeys") {
      Some(Array(a)) => a.copy()
      _ => []
    }
    if keys.contains(jstr(key)) {
      return
    }
    keys.push(jstr(key))
    h["resetKeys"] = jarr(if keys.length() > 32 { keys[keys.length() - 32:].to_array() } else { keys })
    h["quotaRevision"] = jnum_js(
      (match h.get("quotaRevision") {
        None | Some(Null) => 0.0
        v => js_num(v)
      }) +
      1.0,
    )
    h["version"] = jnum_js(js_num(h.get("version")) + 1.0)
  }
  self.write_state()
  self.reconcile_soon()
}
