// index.ts's pages (a profile or a skill shared, this station hosting), a profile moved or lent to another station,
// one handed over to this one, and the overview.

///|
fn Sharing::profile_at(self : Sharing, f : (Json) -> Bool) -> Json? {
  match self.profiles().search_by(f) {
    Some(i) => Some(self.profiles()[i])
    None => None
  }
}

///|
fn id_is(p : Json, id : String) -> Bool {
  get(Some(p), "id") is Some(String(x)) && x == id
}

///|
/// The profiles of a config as it is edited (`raw.profiles ?? []`, each looked at in turn).
fn profiles_of(r : Map[String, Json]) -> Array[Json] {
  match r.get("profiles") {
    Some(Array(a)) => a
    _ => []
  }
}

///|
/// `share_<20 hex>`, a share's new id (index.ts `newId`).
async fn Sharing::new_id(self : Sharing) -> String {
  "sh-" + (self.deps.random_hex)(10)
}

///|
/// The allow list said in the log: every station, or each one's first 8 characters.
fn who_of(allow : Json) -> Json {
  match allow {
    Array(a) => jstr(a.map(s => js_slice(js_string(Some(s)), 8)).join(","))
    _ => jstr("every station")
  }
}

///|
/// A profile shared (with who may use it: null, every station), its stations changed, or no longer shared. `among`:
/// the stations a person chose from (index.ts says why the others keep what they had). `by`: who asked.
pub async fn Sharing::share_profile(
  self : Sharing,
  profile_id : String,
  on : Bool,
  allow : Json,
  among? : Array[String]? = None,
  by? : String? = None,
) -> Unit {
  guard self.profile_at(x => id_is(x, profile_id)) is Some(p) else { raise Failed("unknown profile \{profile_id}") }
  if is_obj(get(Some(p), "share")) && gets(Some(p), ["share", "borrowed"]) is Some(True) {
    raise Failed("this profile is another station's")
  }
  if on && share_refusal(p) is Some(refused) {
    raise Failed(refused)
  }
  let had = if is_obj(get(Some(p), "share")) {
    str_of(gets(Some(p), ["share", "id"]))
  } else {
    None
  }
  // (the stations it reaches are said by the cloud: a station just started waits for them, as a login wanted does)
  if on && among is Some(_) {
    self.roster_said()
  }
  let fresh = match had {
    Some(h) => h
    None => self.new_id()
  }
  let stored : Ref[Json] = Ref(jnull())
  ignore(
    (self.deps.config.update_soon)(raw => {
      guard raw is Object(r) else { return }
      for x in profiles_of(r) {
        guard x is Object(xm) && id_is(x, profile_id) else { continue }
        if !on {
          xm.remove("share")
          continue
        }
        stored.val = match among {
          None => allow
          Some(a) => self.allow_among(x, allow, a)
        }
        xm["share"] = jobj([("id", jstr(fresh)), ("allow", stored.val)])
      }
    }),
  )
  self.deps.log.info("share", "who may use a shared profile changed", jobj([
    ("profile", jstr(profile_id)),
    ("shared", jbool(on)),
    ("allow", if on { who_of(stored.val) } else { jnull() }),
    ("by", match by { Some(b) => jstr(b); None => jnull() }),
  ]))
  ignore(self.sync_hosted())
  (self.deps.changed)()
  self.reconcile_soon()
}

///|
/// Who may use profile `p` once a person chose among stations `among` (index.ts `allowAmong`).
fn Sharing::allow_among(self : Sharing, p : Json, allow : Json, among : Array[String]) -> Json raise {
  let me = self.me()
  let shown = among
  let yes = match allow {
    Array(a) => str_list(a)
    _ => among
  }
  let before = if is_obj(get(Some(p), "share")) {
    match gets(Some(p), ["share", "allow"]) {
      Some(Array(a)) => Some(str_list(a))
      _ => None
    }
  } else {
    None
  }
  let rosters = self.rosters()
  let reached = match rosters {
    None => None
    Some(r) => Some(r.keys().collect().filter(peer => self.reach("profile", Some(p), peer, rosters) is Some(_)))
  }
  if before is None && among.iter().all(s => Some(s) == me || yes.contains(s)) {
    return jnull()
  }
  if before is None && reached is None {
    raise Said(tr((self.deps.lang)(), "station.share.stationsUnknown"))
  }
  let next : Array[String] = []
  let add = (s : String) => if !next.contains(s) { next.push(s) }
  for s in before.or_else(() => reached.unwrap()) {
    if !shown.contains(s) {
      add(s)
    }
  }
  if me is Some(m) {
    add(m)
  }
  for s in among {
    if yes.contains(s) {
      add(s)
    }
  }
  if reached is Some(r) && r.iter().all(s => next.contains(s)) {
    return jnull()
  }
  jstrs(next)
}

///|
/// A skill shared, its stations changed, or no longer shared.
pub async fn Sharing::share_skill(self : Sharing, name : String, on : Bool, allow : Json) -> Unit {
  let had = match self.shared_skill(name) {
    Some((id, _)) => Some(id)
    None => None
  }
  if on {
    let dir = self.files.join([self.skills_dir(), name])
    match self.files.lstat(dir) {
      None => raise Failed("ENOENT: no such file or directory, lstat '\{dir}'")
      Some(st) => if st.kind == "link" { raise Failed("this skill is another station's") }
    }
    if !self.read_skill(dir).has_skill_md {
      raise Failed("no SKILL.md in that skill")
    }
  }
  let fresh = match had {
    Some(h) => h
    None => self.new_id()
  }
  ignore(
    (self.deps.config.update_soon)(raw => {
      guard raw is Object(r) else { return }
      let skills = match r.get("sharedSkills") {
        Some(Object(m)) => m
        _ => Map([])
      }
      if on {
        skills[name] = jobj([("id", jstr(fresh)), ("allow", allow)])
      } else {
        skills.remove(name)
      }
      r["sharedSkills"] = Json::object(skills)
    }),
  )
  if !on {
    self.stop_watch("hosted:\{name}")
  }
  ignore(self.sync_hosted())
  (self.deps.changed)()
  self.reconcile_soon()
}

///|
/// The login files of a profile read for its move: name → base64 (one that is a link, or does not read, left out).
async fn Sharing::credentials_of(self : Sharing, p : Json, home : String) -> Map[String, Json] {
  let credentials : Map[String, Json] = Map([])
  for name in sign_in_files(p, self.files.sep) {
    let path = self.files.join([home, name])
    guard self.files.lstat(path) is Some(st) && st.kind != "link" else { continue }
    guard st.kind == "file" && self.files.read_bytes(path) is Some(b) else { continue }
    credentials[name] = jstr(base64_of(b))
  }
  credentials
}

///|
/// A profile of this station's moved to another whole station of a workspace it serves (index.ts `moveProfile` says
/// the whole of it). Its id there, and the share it moved as.
pub async fn Sharing::move_profile(
  self : Sharing,
  profile_id : String,
  to : String,
  lang? : String? = None,
  share_first? : (async (String) -> Unit)? = None,
) -> (String, String?) {
  let lang = match lang {
    Some(l) => l
    None => (self.deps.lang)()
  }
  let t = (key : String) => tr(lang, key)
  guard self.profile_at(x => id_is(x, profile_id)) is Some(p) else { raise Said(t("station.share.moveUnknown")) }
  if get(Some(p), "machine") is Some(True) {
    raise Said(t("station.share.moveMachine"))
  }
  if is_obj(get(Some(p), "share")) && gets(Some(p), ["share", "borrowed"]) is Some(True) {
    raise Said(t("station.share.moveBorrowed"))
  }
  if Some(to) == self.me() {
    return (profile_id, None)
  }
  guard self.reach("profile", Some(p), to, self.rosters()) is Some(ws) else { raise Said(t("station.share.moveWhere")) }
  let home = self.home(p)
  let credentials = self.credentials_of(p, home)
  // (its account read while its login is here: the copy kept here is named by it after the login goes)
  let email = self.email_of(p)
  let me = self.me()
  let shared = is_obj(get(Some(p), "share"))
  let sharing = !shared && share_first is Some(_) && share_refusal(p) is None && me is Some(_)
  if !shared && !sharing {
    return (self.move_own(p, to, ws, credentials, lang), None)
  }
  let id = if sharing { self.new_id() } else { js_string(gets(Some(p), ["share", "id"])) }
  if self.moving.contains(id) {
    raise Said(t("station.share.moving"))
  }
  let allow = if sharing {
    jstrs([me.unwrap(), to])
  } else {
    allow_of(gets(Some(p), ["share", "allow"]))
  }
  let was = if sharing { None } else { entry_of(self.hosted(), id) }
  let done : @effect.Deferred[Unit] = @effect.Deferred::new()
  self.moving.add(id)
  if sharing {
    self.unannounced.add(id)
  }
  self.move_done[id] = done
  let mut there = profile_id
  let mut made = false
  let mut taken = false
  let mut keeps = true
  let was_version = match was {
    Some(w) => num_or0(w.get("version"))
    None => 0.0
  }
  let was_revision = match was {
    Some(w) =>
      match w.get("quotaRevision") {
        None | Some(Null) => jnum(0.0)
        Some(v) => v
      }
    None => jnum(0.0)
  }
  let failure = try {
    if sharing {
      (share_first.unwrap())(id)
      ignore(
        (self.deps.config.update_soon)(raw => {
          guard raw is Object(r) else { return }
          for x in profiles_of(r) {
            if x is Object(xm) && id_is(x, profile_id) {
              xm["share"] = jobj([("id", jstr(id)), ("allow", allow)])
            }
          }
        }),
      )
      made = true
      self.deps.log.info("share", "a profile shared as it moves, with this station and the one it goes to only", jobj([
        ("profile", jstr(profile_id)),
        ("to", jstr(to)),
      ]))
    }
    let profile = match portable(p) {
      Object(m) => m
      _ => Map([])
    }
    if get(Some(p), "access") is Some(a) {
      profile["access"] = a
    }
    let answer = self.ask(
      to,
      Some(ws),
      jobj([
        ("method", jstr("share.take")),
        ("id", jstr(id)),
        ("profileId", jstr(profile_id)),
        ("profile", Json::object(profile)),
        ("served", jstrs(self.shared_in(p))),
        ("lang", jstr(lang)),
        ("email", match email { Some(e) => jstr(e); None => jnull() }),
        ("credentials", Json::object(credentials)),
        ("allow", allow),
        ("version", jnum_js(was_version + 1.0)),
        ("quotaRevision", was_revision),
        (
          "resetKeys",
          match was {
            Some(w) =>
              match w.get("resetKeys") {
                None | Some(Null) => jarr([])
                Some(v) => v
              }
            None => jarr([])
          },
        ),
      ]),
    )
    taken = true
    if get(Some(answer), "id") is Some(String(x)) {
      there = x
    }
    // Ours no more: the login forgotten (the new host renews it now), the profile kept as a copy under the same id.
    for name in credentials.keys() {
      self.files.remove(self.files.join([home, name]))
    }
    // (a station its stations do not include keeps no copy: it may not borrow it)
    keeps = match allow {
      Array(a) => me is Some(m) && a.contains(jstr(m))
      _ => true
    }
    let keeps_now = keeps
    ignore(
      (self.deps.config.update_soon)(raw => {
        guard raw is Object(r) else { return }
        if !keeps_now {
          r["profiles"] = jarr(profiles_of(r).filter(x => !id_is(x, profile_id)))
        } else {
          for x in profiles_of(r) {
            if x is Object(xm) && id_is(x, profile_id) {
              let share = jobj([("id", jstr(id)), ("borrowed", jbool(true)), ("host", jstr(to))])
              if email is Some(e) && e != "" && share is Object(sm) {
                sm["email"] = jstr(e)
              }
              xm["share"] = share
            }
          }
        }
      }),
    )
    self.hosted().remove(id)
    // Fetched from the new host at once: the workspaces it shares it in are its to say now.
    if keeps {
      self.borrowed()[id] = jobj([
        ("version", jnum_js(was_version + 1.0)),
        ("hash", jstr("")),
        ("kind", jstr("profile")),
        (
          "name",
          jstr(
            match get(Some(p), "name") {
              None | Some(Null) => js_string(get(Some(p), "id"))
              n => js_string(n)
            },
          ),
        ),
        ("host", jstr(to)),
        ("allow", allow),
        ("stale", jbool(true)),
        ("quotaRevision", was_revision),
      ])
    }
    let tell = match was {
      Some(w) =>
        match w.get("told") {
          Some(Object(told)) => js_keys(told)
          _ => []
        }
      None => []
    }
    self.moved()[id] = jobj([("to", jstr(to)), ("tell", jstrs(tell))])
    self.write_state()
    None
  } catch {
    e => {
      // (the share this move made, undone while the login is still here alone: as it was)
      if made && !taken {
        ignore(
          (self.deps.config.update_soon)(raw => {
            guard raw is Object(r) else { return }
            for x in profiles_of(r) {
              if x is Object(xm) && id_is(x, profile_id) && gets(Some(x), ["share", "id"]) is Some(String(sid)) && sid == id &&
                is_obj(xm.get("share")) {
                xm.remove("share")
              }
            }
          }),
        )
        self.deps.log.info("share", "a share made to move a profile undone: the move failed", jobj([
          ("profile", jstr(profile_id)),
          ("to", jstr(to)),
          ("error", jstr(error_words(e))),
        ]))
      }
      Some(e)
    }
  }
  self.moving.remove(id)
  self.unannounced.remove(id)
  self.move_done.remove(id)
  ignore(done.succeed(()))
  if failure is Some(e) {
    raise e
  }
  let fields = jobj([("profile", jstr(profile_id)), ("to", jstr(to))])
  if !keeps && fields is Object(f) {
    f["copy"] = jstr("none: this station may not use it")
  }
  self.deps.log.info("share", "a shared profile moved to another station", fields)
  if !keeps {
    if self.deps.profile_gone is Some(gone) {
      gone(profile_id) catch {
        error =>
          self.deps.log.warn("share", "moving sessions off a profile moved away failed", jobj([
            ("profile", jstr(profile_id)),
            ("error", jstr(error_words(error))),
          ]))
      }
    }
    (self.deps.changed)()
  }
  self.reconcile()
  (there, Some(id))
}

///|
/// Profile `profileId` lent to station `to` for a move's sake, this station staying its host. What it changed
/// (`share`, `made`, `widened`), for `unlend` to undo.
pub async fn Sharing::lend_to(self : Sharing, profile_id : String, to : String) -> (String, Bool, Bool) {
  guard self.profile_at(x => id_is(x, profile_id)) is Some(p) else { raise Failed("unknown profile \{profile_id}") }
  if is_obj(get(Some(p), "share")) && gets(Some(p), ["share", "borrowed"]) is Some(True) {
    raise Failed("this profile is another station's")
  }
  guard self.me() is Some(me) else { raise Failed("this station is in no workspace") }
  let mut made = false
  let mut widened = false
  if !is_obj(get(Some(p), "share")) {
    self.share_profile(profile_id, true, jstrs([me, to]), by=Some("a move"))
    made = true
  } else if gets(Some(p), ["share", "allow"]) is Some(Array(a)) && !a.contains(jstr(to)) {
    let wider = a.copy()
    wider.push(jstr(to))
    self.share_profile(profile_id, true, jarr(wider), by=Some("a move"))
    widened = true
  }
  guard self.profile_at(x => id_is(x, profile_id)) is Some(now) else { raise Failed("unknown profile \{profile_id}") }
  let share = js_string(gets(Some(now), ["share", "id"]))
  // (its account read first: its version and allowance's revision then of one moment)
  let email = if gets(Some(now), ["access", "kind"]) is Some(String("subscription")) {
    self.email_of(now)
  } else {
    None
  }
  let hosted = entry_of(self.hosted(), share)
  let version = match hosted {
    Some(h) =>
      match h.get("version") {
        None | Some(Null) => jnum(1.0)
        Some(v) => v
      }
    None => jnum(1.0)
  }
  try {
    ignore(
      self.ask(
        to,
        None,
        jobj([
          ("method", jstr("share.borrow")),
          ("id", jstr(share)),
          ("version", version),
          ("profile", portable(now)),
          ("email", match email { Some(e) => jstr(e); None => jnull() }),
          ("allow", allow_of(gets(Some(now), ["share", "allow"]))),
          ("workspaces", jstrs(self.shared_in(now))),
          (
            "quotaRevision",
            match hosted {
              Some(h) =>
                match h.get("quotaRevision") {
                  None | Some(Null) => jnum(0.0)
                  Some(v) => v
                }
              None => jnum(0.0)
            },
          ),
        ]),
      ),
    )
    self.told(share, to, version)
  } catch {
    e => {
      self.unlend(share, to, made, widened) catch {
        _ => ()
      }
      raise e
    }
  }
  (share, made, widened)
}

///|
/// What `lend_to` changed undone, this station its host.
pub async fn Sharing::unlend(self : Sharing, share : String, to : String, made : Bool, widened : Bool) -> Unit {
  guard self.profile_at(x => is_obj(get(Some(x), "share")) &&
      gets(Some(x), ["share", "id"]) is Some(String(s)) &&
      s == share &&
      !(gets(Some(x), ["share", "borrowed"]) is Some(True))) is Some(p) else {
    return
  }
  let pid = js_string(get(Some(p), "id"))
  if made {
    self.share_profile(pid, false, jnull(), by=Some("a move done with it"))
  } else if widened && gets(Some(p), ["share", "allow"]) is Some(Array(a)) {
    self.share_profile(pid, true, jarr(a.filter(x => !(x is String(s) && s == to))), by=Some("a move done with it"))
  }
}

///|
/// A share lent to this station by its host for a move (`lend_to`): its copy placed here before this answers.
async fn Sharing::borrow(self : Sharing, peer : String, id : String, request : Json) -> Json {
  if !share_id_ok(id) {
    raise Failed("bad share id")
  }
  if self.shares().contains(id) {
    return jobj([("borrowed", jbool(true))])
  }
  let me = self.me()
  let allow = allow_of(get(Some(request), "allow"))
  if allow is Array(a) && (me is None || !a.contains(jstr(me.unwrap()))) {
    raise Failed("this station is not among those it is shared with")
  }
  let borrowed_all = self.borrowed()
  // (a copy put in the place of what was had, never that one changed where it is: a pass of `reconcile` waiting on its
  // host holds it, and finds by that it was taken over, as `heard` does)
  let had = match entry_of(borrowed_all, id) {
    Some(h) => {
      let c : Map[String, Json] = Map([])
      for k, v in h {
        c[k] = v
      }
      c
    }
    None => {
      let h : Map[String, Json] = Map([])
      h["version"] = jnum(-1.0)
      h["hash"] = jstr("")
      h["kind"] = jstr("profile")
      h["name"] = jstr(
        match gets(Some(request), ["profile", "name"]) {
          None | Some(Null) => id
          n => js_string(n)
        },
      )
      h["host"] = jstr(peer)
      h["allow"] = allow
      h["stale"] = jbool(true)
      h
    }
  }
  had["host"] = jstr(peer)
  had["allow"] = allow
  let home = self.place_profile(id, had, request)
  had["version"] = jnum_js(num_or0(get(Some(request), "version")))
  had["quotaRevision"] = jnum_js(num_or0(get(Some(request), "quotaRevision")))
  had["stale"] = jbool(false)
  borrowed_all[id] = Json::object(had)
  self.write_state()
  self.checked.add(id)
  self.placed_home(home)
  self.reconcile_soon()
  jobj([("borrowed", jbool(true))])
}

///|
/// A share a move made undone once its login is home again, where it is allowed to none but `stations`. True: undone.
pub async fn Sharing::unshare_moved(self : Sharing, share : String, stations : Array[String]) -> Bool {
  guard self.profile_at(x => is_obj(get(Some(x), "share")) &&
      gets(Some(x), ["share", "id"]) is Some(String(s)) &&
      s == share &&
      !(gets(Some(x), ["share", "borrowed"]) is Some(True))) is Some(p) else {
    self.deps.log.info("share", "a share a move made is not undone: this station does not host it", jobj([("share", jstr(share))]))
    return false
  }
  let allow = allow_of(gets(Some(p), ["share", "allow"]))
  let others = match allow {
    Array(a) => a.iter().any(s => !(s is String(x) && stations.contains(x)))
    _ => true
  }
  if others {
    self.deps.log.info("share", "a share a move made stays shared: a person allowed other stations since", jobj([
      ("profile", get(Some(p), "id").unwrap_or(jnull())),
      ("share", jstr(share)),
      ("allow", who_of(allow)),
    ]))
    return false
  }
  self.share_profile(js_string(get(Some(p), "id")), false, jnull(), by=Some("a move back"))
  true
}

///|
/// A profile not shared moved to `to`: the other station takes it as its own, then it is gone from here.
async fn Sharing::move_own(
  self : Sharing,
  p : Json,
  to : String,
  ws : String,
  credentials : Map[String, Json],
  lang : String,
) -> String {
  let pid = js_string(get(Some(p), "id"))
  let key = "own:\{pid}"
  if self.moving.contains(key) {
    raise Said(tr(lang, "station.share.moving"))
  }
  self.moving.add(key)
  let result = try {
    let profile = match portable(p) {
      Object(m) => m
      _ => Map([])
    }
    if get(Some(p), "access") is Some(a) {
      profile["access"] = a
    }
    let email = self.email_of(p)
    let answer = self.ask(
      to,
      Some(ws),
      jobj([
        ("method", jstr("share.take")),
        ("own", jbool(true)),
        ("profileId", get(Some(p), "id").unwrap_or(jnull())),
        ("profile", Json::object(profile)),
        ("served", jstrs(self.shared_in(p))),
        ("lang", jstr(lang)),
        ("email", match email { Some(e) => jstr(e); None => jnull() }),
        ("credentials", Json::object(credentials)),
      ]),
    )
    guard get(Some(answer), "taken") is Some(True) && get(Some(answer), "id") is Some(String(there)) else {
      raise Said(tr(lang, "station.share.moveNotTaken"))
    }
    // (the other has it now: the login here goes, so that one station alone renews it)
    let home = self.home(p)
    for name in credentials.keys() {
      self.files.remove(self.files.join([home, name]))
    }
    ignore(
      (self.deps.config.update_soon)(raw => {
        guard raw is Object(r) else { return }
        r["profiles"] = jarr(profiles_of(r).filter(x => !strict_eq(get(Some(x), "id"), get(Some(p), "id"))))
      }),
    )
    Ok(there)
  } catch {
    e => Err(e)
  }
  self.moving.remove(key)
  let there = match result {
    Ok(t) => t
    Err(e) => raise e
  }
  self.deps.log.info("share", "a profile moved to another station", jobj([("profile", jstr(pid)), ("to", jstr(to)), ("there", jstr(there))]))
  if self.deps.profile_gone is Some(gone) {
    gone(pid) catch {
      error =>
        self.deps.log.warn("share", "moving sessions off a profile moved away failed", jobj([
          ("profile", jstr(pid)),
          ("error", jstr(error_words(error))),
        ]))
    }
  }
  (self.deps.changed)()
  there
}

///|
/// A profile's id here for one handed over as `wanted` there: that id where it is free, else the next free one of it.
fn Sharing::id_for(self : Sharing, wanted : Json?, fallback : String) -> String {
  let taken : Set[String] = Set::new()
  for x in self.profiles() {
    taken.add(js_string(get(Some(x), "id")))
  }
  let base = match wanted {
    Some(String(w)) if profile_id_ok(w) => w
    _ => fallback
  }
  let mut id = base
  let mut n = 2
  while taken.contains(id) {
    id = "\{base}-\{n}"
    n += 1
  }
  id
}

///|
/// `Array.prototype.join(sep)` of JSON values (null and undefined as "").
fn js_join(a : Array[Json], sep : String) -> String {
  a.map(x => if x is Null { "" } else { js_string(Some(x)) }).join(sep)
}

///|
/// The joined workspaces of this station's a profile handed over is withheld from (index.ts `withheldFor`); None where
/// the other station did not say. Refused, in words, where it did not serve this station's home workspace.
fn Sharing::withheld_for(self : Sharing, served : Json?, lang : Json?) -> Array[String]? raise {
  guard served is Some(Array(list)) else { return None }
  let home = self.home_ws()
  if home is Some(h) && !list.contains(jstr(h)) {
    let l = match lang {
      Some(String("zh" | "en" as x)) => x
      _ => (self.deps.lang)()
    }
    raise Refused(tr(l, "station.share.moveHome", args=[("workspaces", js_join(list, ", "))]))
  }
  Some(
    (self.deps.cloud.memberships)()
    .map(m => m.workspace)
    .filter(w => Some(w) != home && !list.contains(jstr(w))),
  )
}

///|
/// The login files handed over with a profile, written in its home here (only those its runtime signs in with).
async fn Sharing::write_sign_ins(self : Sharing, home : String, given : Json, credentials : Json?) -> Unit {
  let allowed = sign_in_files(given, self.files.sep)
  guard credentials is Some(Object(c)) else { return }
  for name in js_keys(c) {
    guard allowed.contains(name) && c[name] is String(data) else { continue }
    let path = self.files.join([home, name])
    if self.files.lstat(path) is Some(st) && st.kind == "link" {
      self.files.remove(path) catch {
        _ => ()
      }
    }
    self.files.write_private(path, base64_loose(data))
  }
}

///|
/// What `taken` keeps goes once the profile it names is gone.
fn Sharing::forget_taken(self : Sharing) -> Unit {
  guard self.st().get("taken") is Some(Object(taken)) else { return }
  let ids = self.profiles().map(x => get(Some(x), "id"))
  for asked in js_keys(taken) {
    let id = taken[asked]
    if !ids.iter().any(i => strict_eq(i, Some(id))) {
      taken.remove(asked)
    }
  }
}

///|
/// A profile not shared handed over by another station of a workspace both are in: this station's own from now on.
async fn Sharing::take_own(self : Sharing, peer : String, request : Json) -> Json {
  let rq = Some(request)
  guard get(rq, "profile") is Some(Object(_) as given) else { raise Failed("nothing handed over") }
  match get(Some(given), "runtime") {
    None | Some(String(_)) => ()
    _ => raise Failed("nothing handed over")
  }
  let asked = "\{peer}/\{match get(rq, "profileId") { None | Some(Null) => ""; v => js_string(v) }}"
  let before = get(self.st().get("taken"), asked)
  if before is Some(b) && self.profiles().iter().any(x => strict_eq(get(Some(x), "id"), Some(b))) {
    return jobj([("taken", jbool(true)), ("id", b)])
  }
  let email = match get(rq, "email") {
    Some(String(e)) if e != "" => Some(e)
    _ => None
  }
  if email is Some(_) {
    for x in self.profiles() {
      let xj = Some(x)
      if !(get(xj, "machine") is Some(True)) &&
        !(is_obj(get(xj, "share")) && gets(xj, ["share", "borrowed"]) is Some(True)) &&
        strict_eq(get(xj, "runtime"), get(Some(given), "runtime")) &&
        strict_eq(gets(xj, ["access", "kind"]), gets(Some(given), ["access", "kind"])) &&
        strict_eq(gets(xj, ["access", "service"]), gets(Some(given), ["access", "service"])) &&
        self.email_of(x) == email {
        return jobj([("taken", jbool(true)), ("id", get(xj, "id").unwrap_or(jnull())), ("had", jbool(true))])
      }
    }
  }
  let withheld = self.withheld_for(get(rq, "served"), get(rq, "lang"))
  let fallback = "moved-" + (self.deps.random_hex)(4)
  let local_id = self.id_for(get(rq, "profileId"), fallback)
  let home = self.files.join([self.deps.data, "homes", local_id])
  // The login written first, then the profile and what it was taken as.
  self.files.mkdir(home)
  self.write_sign_ins(home, given, get(rq, "credentials"))
  ignore(
    (self.deps.config.update_soon)(raw => {
      guard raw is Object(r) else { return }
      let list = profiles_of(r)
      let made = match portable(given) {
        Object(m) => m
        _ => Map([])
      }
      if get(Some(given), "access") is Some(a) {
        made["access"] = a
      }
      made["id"] = jstr(local_id)
      made["home"] = jstr("homes/\{local_id}")
      if withheld is Some(w) && !w.is_empty() {
        made["withheld"] = jstrs(w)
      }
      if !(made.get("env") is Some(Object(_))) {
        made["env"] = Json::object(Map([]))
      }
      list.push(Json::object(made))
      r["profiles"] = jarr(list)
    }),
  )
  section(self.st(), "taken")[asked] = jstr(local_id)
  self.forget_taken()
  self.write_state()
  self.deps.log.info("share", "a profile handed over to this station", jobj([("id", jstr(local_id)), ("from", jstr(peer))]))
  (self.deps.changed)()
  jobj([("taken", jbool(true)), ("id", jstr(local_id))])
}

///|
/// A profile handed over by the station that has it, one at a time with what else changes `state.hosted`.
async fn Sharing::take(self : Sharing, peer : String, request : Json) -> Json {
  self.hosted_turn.run(async fn() {
    if get(Some(request), "own") is Some(True) {
      self.take_own(peer, request)
    } else {
      self.take_shared(peer, request)
    }
  })
}

///|
async fn Sharing::take_shared(self : Sharing, peer : String, request : Json) -> Json {
  let rq = Some(request)
  let id = match get(rq, "id") {
    None | Some(Null) => ""
    v => js_string(v)
  }
  if !share_id_ok(id) {
    raise Failed("bad share id")
  }
  if entry_of(self.borrowed(), id) is Some(had) && !(had.get("host") is Some(String(h)) && h == peer) {
    raise Failed("only the station that has it can hand it over")
  }
  let share_is = (x : Json) => is_obj(get(Some(x), "share")) && gets(Some(x), ["share", "id"]) is Some(String(s)) && s == id
  let mine = self.profile_at(x => share_is(x) && !(gets(Some(x), ["share", "borrowed"]) is Some(True)))
  if self.shares().contains(id) {
    return match mine {
      Some(m) => jobj([("taken", jbool(true)), ("id", get(Some(m), "id").unwrap_or(jnull()))])
      None => jobj([("taken", jbool(true))])
    }
  }
  guard get(rq, "profile") is Some(Object(_) as given) else { raise Failed("nothing handed over") }
  // (the workspaces it served there, and no more, as it is this station's to share now)
  let withheld = self.withheld_for(get(rq, "served"), get(rq, "lang"))
  // (the copy here keeps its id; else the id it had there, where that is free here)
  let local_id = match self.profile_at(share_is) {
    Some(existing) =>
      match get(Some(existing), "id") {
        None | Some(Null) =>
          match get(rq, "profileId") {
            Some(String(_)) as w => self.id_for(w, id)
            _ => id
          }
        v => js_string(v)
      }
    None =>
      match get(rq, "profileId") {
        Some(String(_)) as w => self.id_for(w, id)
        _ => id
      }
  }
  let home = self.files.join([self.deps.data, "homes", local_id])
  // The login written first, then the profile and the share in one step.
  self.files.mkdir(home)
  self.write_sign_ins(home, given, get(rq, "credentials"))
  let allow = allow_of(get(rq, "allow"))
  let made = match portable(given) {
    Object(m) => m
    _ => Map([])
  }
  if get(Some(given), "access") is Some(a) {
    made["access"] = a
  }
  made["id"] = jstr(local_id)
  made["home"] = jstr("homes/\{local_id}")
  made["share"] = jobj([("id", jstr(id)), ("allow", allow)])
  if withheld is Some(w) && !w.is_empty() {
    made["withheld"] = jstrs(w)
  }
  if !(made.get("env") is Some(Object(_))) {
    made["env"] = Json::object(Map([]))
  }
  let made_json = Json::object(made)
  // (hashed as it will be, its login written: the profile, the copy let go and the share then, in this share's turn)
  let hash = self.profile_hash(made_json)
  ignore(
    (self.deps.config.update_soon)(raw => {
      guard raw is Object(r) else { return }
      let list = profiles_of(r)
      match list.search_by(x => id_is(x, local_id)) {
        Some(at) => list[at] = clone(made_json)
        None => list.push(clone(made_json))
      }
      r["profiles"] = jarr(list)
    }),
  )
  self.borrowed().remove(id)
  // The station that handed it over keeps a copy, at this version.
  let version = match get(rq, "version") {
    None | Some(Null) => 1.0
    v => js_num(v)
  }
  let revision = match get(rq, "quotaRevision") {
    Some(Number(d, ..)) if d == d.floor() && d.abs() <= 9007199254740991.0 && d >= 0.0 => d
    _ => 0.0
  }
  let reset_keys = match get(rq, "resetKeys") {
    Some(Array(a)) => {
      let keys = a.filter(k => k is String(_))
      if keys.length() > 32 {
        keys[keys.length() - 32:].to_array()
      } else {
        keys
      }
    }
    _ => []
  }
  self.hosted()[id] = jobj([
    ("version", jnum_js(version)),
    ("hash", jstr(hash)),
    ("kind", jstr("profile")),
    (
      "name",
      jstr(
        match get(Some(given), "name") {
          None | Some(Null) => local_id
          n => js_string(n)
        },
      ),
    ),
    ("allow", allow),
    ("told", jobj([(peer, jnum_js(version))])),
    ("quotaRevision", jnum(revision)),
    ("resetKeys", jarr(reset_keys)),
  ])
  self.write_state()
  self.deps.log.info("share", "a shared profile handed over to this station", jobj([("id", jstr(id)), ("from", jstr(peer))]))
  self.reconcile_soon()
  if self.on_hosted is Some(f) {
    f(id, peer)
  }
  jobj([("taken", jbool(true)), ("id", jstr(local_id))])
}

///|
/// Told as a shared profile is handed over to this station to host (a move's, move/accounts.ts).
pub fn Sharing::set_on_hosted(self : Sharing, f : ((String, String) -> Unit)?) -> Unit {
  self.on_hosted = f
}

// ── the overview ──

///|
/// What the overview says of a profile's sharing (None: not shared). `workspace`: the viewer's; the stations it names
/// (`users`, `allow`) are this one and those of that workspace only, so a member never sees a station of a workspace of
/// this station's they are not in, which they could only show by its id (None: all of them).
pub fn Sharing::profile_view(self : Sharing, p : Json, workspace? : String? = None) -> Json? {
  guard get(Some(p), "share") is Some(Object(sh)) && sh.get("id") is Some(String(id)) else { return None }
  let me = self.me()
  let rosters = match workspace {
    None => None
    Some(_) => self.rosters()
  }
  let seen = fn(station : String) -> Bool {
    match (rosters, workspace) {
      (Some(r), Some(ws)) =>
        Some(station) == me ||
        (match r.get(station) {
          Some(wss) => wss.contains(ws)
          None => false
        })
      _ => true
    }
  }
  let seen_of = fn(v : Json) -> Json {
    match (v, rosters) {
      (Array(xs), Some(_)) => Json::array(xs.filter(x => x is String(st) && seen(st)))
      (other, _) => other
    }
  }
  if sh.get("borrowed") is Some(True) {
    let host = match sh.get("host") {
      None | Some(Null) => ""
      h => js_string(h)
    }
    // The allowance is the host's, naming the stations of each of its workspaces: only this one's and the viewer's.
    let allow = match entry_of(self.borrowed(), id) {
      Some(had) =>
        match had.get("allow") {
          None | Some(Null) => jnull()
          Some(a) => seen_of(a)
        }
      None => jnull()
    }
    return Some(
      jobj([
        ("id", jstr(id)),
        ("role", jstr("user")),
        ("host", jstr(host)),
        ("allow", allow),
        ("reachable", jbool(!self.silent_hosts.contains(host))),
        ("pausable", jbool(true)),
      ]),
    )
  }
  let users = match entry_of(self.hosted(), id) {
    Some(h) =>
      match h.get("told") {
        Some(Object(told)) => js_keys(told).filter(k => js_num(told.get(k)) >= 0.0 && seen(k))
        _ => []
      }
    None => []
  }
  Some(
    jobj([
      ("id", jstr(id)),
      ("role", jstr("host")),
      ("host", jstr(me.unwrap_or(""))),
      ("allow", seen_of(allow_of(sh.get("allow")))),
      ("reachable", jnull()),
      ("users", jstrs(users)),
    ]),
  )
}

///|
/// What the memory page says of a skill's sharing (None: not shared): by its name in the agents' skills.
pub async fn Sharing::skill_view(self : Sharing, name : String) -> Json? {
  if self.shared_skill(name) is Some((id, allow)) {
    return Some(
      jobj([
        ("id", jstr(id)),
        ("role", jstr("host")),
        ("host", jstr(self.me().unwrap_or(""))),
        ("allow", allow),
        ("reachable", jnull()),
      ]),
    )
  }
  let borrowed_all = self.borrowed()
  for id in js_keys(borrowed_all) {
    guard entry_of(borrowed_all, id) is Some(had) else { continue }
    if !(had.get("kind") is Some(String("skill"))) ||
      !(had.get("name") is Some(String(n)) && n == name) ||
      !self.skill_linked(id, had) {
      continue
    }
    let host = js_string(had.get("host"))
    return Some(
      jobj([
        ("id", jstr(id)),
        ("role", jstr("user")),
        ("host", had.get("host").unwrap_or(jnull())),
        ("allow", match had.get("allow") { None | Some(Null) => jnull(); Some(a) => a }),
        ("reachable", jbool(!self.silent_hosts.contains(host))),
      ]),
    )
  }
  None
}
