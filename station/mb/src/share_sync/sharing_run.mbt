// index.ts's running: what is configured and what the hosts say brought in line (`reconcile`), copies placed and taken
// away, the copied skills linked, and edits followed.

///|
/// `a === b` of two JSON values as JavaScript compares them (an object or an array only to itself).
fn strict_eq(a : Json?, b : Json?) -> Bool {
  match (a, b) {
    (None, None) => true
    (Some(Null), Some(Null)) => true
    (Some(True), Some(True)) | (Some(False), Some(False)) => true
    (Some(Number(x, ..)), Some(Number(y, ..))) => x == y
    (Some(String(x)), Some(String(y))) => x == y
    (Some(Array(x)), Some(Array(y))) => physical_equal(x, y)
    (Some(Object(x)), Some(Object(y))) => physical_equal(x, y)
    _ => false
  }
}

///|
/// `v` truthy as JavaScript has it.
fn truthy(v : Json?) -> Bool {
  @jsjson.json_truthy(v)
}

///|
/// A field of an entry kept as an object (`hosted.told`), made where it is none.
fn obj_field(m : Map[String, Json], k : String) -> Map[String, Json] {
  match m.get(k) {
    Some(Object(o)) => o
    _ => {
      let o : Map[String, Json] = Map([])
      m[k] = Json::object(o)
      o
    }
  }
}

///|
fn Sharing::itself(self : Sharing, station : String) -> Bool {
  match self.deps.itself {
    Some(f) => f(station)
    None => false
  }
}

// ── running ──

///|
/// Followed from now on: the cloud's word and the config, each change bringing the shares in line.
pub fn Sharing::start(self : Sharing) -> Unit {
  self.stops.push((self.deps.cloud.listen)(() => self.reconcile_soon()))
  self.stops.push((self.deps.config.listen)(() => self.reconcile_soon()))
  self.reconcile_soon()
}

///|
/// Closed: nothing is followed from then on.
pub async fn Sharing::close(self : Sharing) -> Unit {
  self.closed = true
  for stop in self.stops {
    stop()
  }
  self.stops.clear()
  self.stop_watches()
  match self.retry {
    Some(off) => off()
    None => ()
  }
  self.retry = None
  for _, off in self.settle {
    off()
  }
  self.settle.clear()
  self.program.close()
  // (the links' turn, files alone, done; a pass still asking other stations is not waited for, its watches refused)
  self.link_turn.settled()
  self.stop_watches()
  self.state_written()
}

///|
fn Sharing::stop_watches(self : Sharing) -> Unit {
  for _, w in self.watchers {
    (w.close)()
  }
  self.watchers.clear()
  self.login_dirs.clear()
}

///|
/// Brings what is here in line, without waiting for it: one at a time, again if asked meanwhile.
pub fn Sharing::reconcile_soon(self : Sharing) -> Unit {
  if self.reconciling is Some(_) {
    self.again = true
    return
  }
  let done : @effect.Deferred[Unit] = @effect.Deferred::new()
  self.reconciling = Some(done)
  self.tasks.spawn(async fn() {
    defer {
      self.reconciling = None
      ignore(done.succeed(()))
    }
    while true {
      self.again = false
      self.reconcile_once() catch {
        e => self.deps.log.warn("share", "bringing shares in line failed", jobj([("error", jstr(error_words(e)))]))
      }
      if !self.again {
        break
      }
    }
  })
}

///|
/// Brings what is here in line with what is configured and what the hosts say: one at a time, again if asked meanwhile.
pub async fn Sharing::reconcile(self : Sharing) -> Unit {
  self.reconcile_soon()
  match self.reconciling {
    Some(d) => d.wait()
    None => ()
  }
}

///|
async fn Sharing::reconcile_once(self : Sharing) -> Unit {
  let me = self.me()
  if me is None || (self.deps.cloud.removed)() {
    return
  }
  let rosters = self.rosters()
  self.follow_skills()
  let pending = Ref(false)
  let silent : Array[String] = self.silent_hosts.keys().collect()
  // Its answer; a refusal kept on what it was of (`hosted`: shown where it is shared, till it is taken).
  let tell = async fn(peer : String, ws : String?, request : Json, hosted : Map[String, Json]?) -> Json? {
    try {
      let answer = match self.ask(peer, ws, request) {
        Null => Json::object(Map([]))
        a => a
      }
      if hosted is Some(h) {
        miss(h, peer, if get(Some(answer), "hidden") is Some(True) { Some("same-name") } else { None })
      }
      Some(answer)
    } catch {
      e => {
        pending.val = true
        self.deps.log.info("share", "a station could not be told of a share", jobj([
          ("id", get(Some(request), "id").unwrap_or(jnull())),
          ("peer", jstr(peer)),
          ("by", jstr(who_said(e))),
          ("error", jstr(error_words(e))),
        ]))
        // One that did not answer is asked again; what it was before stands meanwhile.
        if hosted is Some(h) && e is Refused(m) {
          miss(h, peer, Some(if m.contains("bad skill name") { "name" } else { "refused" }))
        }
        None
      }
    }
  }
  let hosted_all = self.hosted()

  // What this station shares: its version raised when what it is changed, each station that may use it told (again,
  // one that did not answer), in a workspace it is for, one that no longer may told so.
  let own = self.sync_hosted()
  for id, now in own {
    if self.unannounced.contains(id) || now.hash is None || rosters is None {
      continue
    }
    guard entry_of(hosted_all, id) is Some(hosted) else { continue }
    let ros = rosters.unwrap()
    let peers : Array[async () -> Unit] = []
    for peer in ros.keys() {
      // (a station retired into this one: its copies came here with it)
      if self.itself(peer) {
        continue
      }
      let ws = self.reach(now.kind, now.profile, peer, rosters)
      if ws is Some(_) && may_use(now.allow, peer) {
        let version = hosted.get("version")
        if strict_eq(obj_field(hosted, "told").get(peer), version) {
          continue
        }
        let request = jobj([
          ("method", jstr("share.changed")),
          ("id", jstr(id)),
          ("kind", jstr(now.kind)),
          ("name", jstr(now.name)),
          ("version", version.unwrap_or(jnull())),
          ("allow", now.allow),
        ])
        peers.push(async fn() {
          if tell(peer, ws, request, Some(hosted)) is Some(_) {
            obj_field(hosted, "told")[peer] = version.unwrap_or(jnull())
          }
        })
      } else {
        miss(hosted, peer, None)
        if obj_field(hosted, "told").contains(peer) {
          let request = jobj([("method", jstr("share.changed")), ("id", jstr(id)), ("gone", jbool(true))])
          peers.push(async fn() {
            if tell(peer, None, request, None) is Some(_) {
              obj_field(hosted, "told").remove(peer)
            }
          })
        }
      }
    }
    if !peers.is_empty() {
      ignore(@effect.all(peers))
    }
    // Stations in none of this station's workspaces now: forgotten.
    let told = obj_field(hosted, "told")
    for peer in js_keys(told) {
      if !ros.contains(peer) {
        told.remove(peer)
      }
    }
    if hosted.get("missing") is Some(Object(missing)) {
      for peer in js_keys(missing) {
        if !ros.contains(peer) {
          miss(hosted, peer, None)
        }
      }
    }
  }
  // No longer shared: each station told is told so, then it is forgotten. Shared now, after awaiting peer
  // notifications, so a share turned on while peers were told is kept.
  let current_own = self.shares()
  for id in js_keys(hosted_all) {
    if current_own.contains(id) {
      continue
    }
    guard entry_of(hosted_all, id) is Some(hosted) else { continue }
    let told = obj_field(hosted, "told")
    let peers : Array[async () -> Unit] = []
    for peer in js_keys(told) {
      if self.itself(peer) || (rosters is Some(r) && !r.contains(peer)) {
        told.remove(peer)
      } else {
        let request = jobj([("method", jstr("share.changed")), ("id", jstr(id)), ("gone", jbool(true))])
        peers.push(async fn() {
          if tell(peer, None, request, None) is Some(_) {
            told.remove(peer)
          }
        })
      }
    }
    if !peers.is_empty() {
      ignore(@effect.all(peers))
    }
    if !self.shares().contains(id) && told.is_empty() {
      hosted_all.remove(id)
    }
  }
  // Handed to another station: the stations told of it hear where it went.
  let moved_all = self.moved()
  for id in js_keys(moved_all) {
    guard entry_of(moved_all, id) is Some(moved) else { continue }
    let left : Array[Json] = []
    let peers : Array[async () -> Unit] = []
    let to = moved.get("to")
    for peer_json in moved.get("tell").map(v => if v is Array(a) { a } else { [] }).unwrap_or([]) {
      let peer = js_string(Some(peer_json))
      if strict_eq(Some(peer_json), to) || self.itself(peer) || (rosters is Some(r) && !r.contains(peer)) {
        continue
      }
      let request = jobj([("method", jstr("share.changed")), ("id", jstr(id)), ("host", to.unwrap_or(jnull()))])
      peers.push(async fn() {
        if tell(peer, None, request, None) is None {
          left.push(peer_json)
        }
      })
    }
    if !peers.is_empty() {
      ignore(@effect.all(peers))
    }
    if left.is_empty() {
      moved_all.remove(id)
    } else {
      moved["tell"] = jarr(left)
    }
  }

  // What this station uses of others': fetched when its host said it changed, asked once a run, and taken away when
  // its host is gone from the workspace it was had in (any of this station's, for a profile).
  let borrowed_all = self.borrowed()
  for id in js_keys(borrowed_all) {
    guard entry_of(borrowed_all, id) is Some(had) else { continue }
    if rosters is Some(r) && !self.host_there(had, r) {
      self.deps.log.info("share", "the station a share was from left the workspace; its copy is taken away", jobj([
        ("id", jstr(id)),
        ("host", had.get("host").unwrap_or(jnull())),
      ]))
      borrowed_all.remove(id)
      self.drop(id, had)
      continue
    }
    let reset_pending = (h : Map[String, Json]) => match h.get("resetPending") {
      Some(Array(a)) => a
      _ => []
    }
    if !truthy(had.get("stale")) &&
      !truthy(had.get("pending")) &&
      !truthy(had.get("profileUpdate")) &&
      reset_pending(had).is_empty() &&
      self.checked.contains(id) {
      continue
    }
    // (its host retired into this station: nobody to ask, it comes here as its accounts do, `share.take`)
    if self.itself(js_string(had.get("host"))) {
      continue
    }
    try {
      for key in reset_pending(had).copy() {
        let host = js_string(had.get("host"))
        try {
          ignore(self.ask(host, self.ask_in(had), jobj([("method", jstr("share.quotaReset")), ("id", jstr(id)), ("key", key)])))
          if had.get("resetPending") is Some(Array(a)) {
            had["resetPending"] = jarr(a.filter(p => !strict_eq(Some(p), Some(key))))
          }
          self.write_state()
        } catch {
          e => {
            // An older host may not know this request yet. Retry it, without holding up other profile updates.
            pending.val = true
            self.deps.log.info("share", "an allowance reset could not be sent to its host", jobj([
              ("id", jstr(id)),
              ("host", had.get("host").unwrap_or(jnull())),
              ("by", jstr(who_said(e))),
              ("error", jstr(error_words(e))),
            ]))
            break
          }
        }
      }
      if truthy(had.get("pending")) && had.get("kind") is Some(String("skill")) {
        self.send_skill_edit(id, had)
      }
      if !truthy(had.get("stale")) && !truthy(had.get("profileUpdate")) {
        let request = jobj([("method", jstr("share.version")), ("id", jstr(id))])
        if had.get("kind") is Some(String("skill")) {
          let hidden = !self.skill_linked(id, had)
          if request is Object(rq) {
            rq["hidden"] = jbool(hidden)
          }
        }
        let host = js_string(had.get("host"))
        let now = self.ask(host, self.ask_in(had), request)
        self.silent_hosts.remove(host)
        match get(Some(now), "moved") {
          Some(String(to)) => {
            had["host"] = jstr(to)
            had["stale"] = jbool(true)
          }
          _ =>
            if strict_eq(get(Some(now), "version"), had.get("version")) {
              self.checked.add(id)
              continue
            }
        }
      }
      if truthy(had.get("stale")) || !truthy(had.get("profileUpdate")) {
        let host = js_string(had.get("host"))
        let got = self.ask(host, self.ask_in(had), jobj([("method", jstr("share.get")), ("id", jstr(id))]))
        self.silent_hosts.remove(js_string(had.get("host")))
        // (heard of again while it was asked for: taken away, or changed, `heard` putting a copy marked stale in its
        // place, which the pass `heard` asks for fetches; what came here is not placed, nor its allowance's reset
        // counted, twice)
        guard entry_of(borrowed_all, id) is Some(same) && physical_equal(same, had) else { continue }
        if had.get("kind") is Some(String("profile")) {
          self.placed_home(self.place_profile(id, had, got))
          // (lent meanwhile, or heard of again, while it was placed: that one's copy in its place, as above)
          guard entry_of(borrowed_all, id) is Some(same) && physical_equal(same, had) else { continue }
          let revision = num_or0(get(Some(got), "quotaRevision"))
          if js_num(had.get("version")) >= 0.0 {
            let before = match had.get("quotaRevision") {
              None | Some(Null) => 0.0
              v => js_num(v)
            }
            let reset = revision > before || gets(had.get("profileUpdate"), ["reset"]) is Some(True)
            had["profileUpdate"] = jobj([("reset", jbool(reset))])
          }
          had["quotaRevision"] = jnum_js(revision)
        } else {
          self.place_skill(id, had, got)
          guard entry_of(borrowed_all, id) is Some(same) && physical_equal(same, had) else { continue }
        }
        had["version"] = jnum_js(num_or0(get(Some(got), "version")))
        had["allow"] = allow_of(get(Some(got), "allow"))
        had["stale"] = jbool(false)
        self.write_state()
      }
      if truthy(had.get("profileUpdate")) {
        let profile = self.profiles().search_by(p => gets(Some(p), ["share", "id"]) is Some(String(x)) &&
          x == id &&
          gets(Some(p), ["share", "borrowed"]) is Some(True))
        if profile is Some(at) && self.deps.profile_changed is Some(changed) {
          changed(js_string(get(Some(self.profiles()[at]), "id")), gets(had.get("profileUpdate"), ["reset"]) |> truthy)
        }
        had.remove("profileUpdate")
        self.write_state()
      }
      self.checked.add(id)
    } catch {
      e => {
        // Its host says who may use it leaves this station out (`not_ours`) and the word of it never got here: taken
        // away as that word would have taken it; any other refusal (the host's list of stations not known, or leaving
        // this one out) is taken as the host not answering.
        if not_ours(e) {
          self.deps.log.info("share", "its host says a share is not this station's; its copy is taken away", jobj([
            ("id", jstr(id)),
            ("host", had.get("host").unwrap_or(jnull())),
          ]))
          self.silent_hosts.remove(js_string(had.get("host")))
          borrowed_all.remove(id)
          self.drop(id, had)
          self.write_state()
          continue
        }
        pending.val = true
        self.silent_hosts[js_string(had.get("host"))] = (self.deps.clock.now)()
        self.deps.log.info("share", "a share could not be had from its host", jobj([
          ("id", jstr(id)),
          ("host", had.get("host").unwrap_or(jnull())),
          ("by", jstr(who_said(e))),
          ("error", jstr(error_words(e))),
        ]))
      }
    }
  }
  // Hosts of borrowed subscriptions that did not answer: asked whether they do now.
  for host in self.silent_hosts.keys().collect() {
    if self.itself(host) {
      self.silent_hosts.remove(host)
      continue
    }
    let found = self.profiles().search_by(p => self.borrowed_subscription(p) &&
      gets(Some(p), ["share", "host"]) is Some(String(h)) &&
      h == host)
    guard found is Some(at) else {
      self.silent_hosts.remove(host)
      continue
    }
    let b = self.profiles()[at]
    try {
      ignore(self.ask(host, None, jobj([("method", jstr("share.status")), ("id", gets(Some(b), ["share", "id"]).unwrap_or(jnull()))])))
      self.silent_hosts.remove(host)
    } catch {
      _ => pending.val = true
    }
  }
  if silent.iter().any(h => !self.silent_hosts.contains(h)) {
    match self.deps.recheck {
      Some(f) => f()
      None => ()
    }
  }
  self.forget_taken()
  self.write_state()
  self.link_borrowed_skills()
  // What did not get through is tried again, less often the longer it does not.
  if !pending.val {
    self.retry_wait = retry_ms
  } else {
    self.schedule_retry()
  }
  (self.deps.changed)()
}

///|
fn next_retry_wait(current : Double) -> Double {
  if current * 2.0 < retry_max_ms {
    current * 2.0
  } else {
    retry_max_ms
  }
}

///|
fn Sharing::schedule_retry(self : Sharing) -> Unit {
  if self.closed || self.retry is Some(_) {
    return
  }
  let wait = self.retry_wait
  self.retry_wait = next_retry_wait(self.retry_wait)
  self.retry = Some(
    (self.deps.clock.after)(wait, () => {
      self.retry = None
      self.reconcile_soon()
    }),
  )
}

// ── copies of others' shares ──

///|
/// The copy's profile made or changed in config.json, taken at once: its home, for `placed_home` to make.
async fn Sharing::place_profile(self : Sharing, id : String, had : Map[String, Json], got : Json) -> String? {
  guard get(Some(got), "profile") is Some(Object(_) as given) else { raise Failed("the host sent no profile") }
  ignore(
    (self.deps.config.update_soon)(raw => {
      guard raw is Object(r) else { return }
      let list = match r.get("profiles") {
        Some(Array(a)) => a
        _ => []
      }
      let at = list.search_by(p => get(Some(p), "share") is Some(Object(sh)) &&
        sh.get("id") is Some(String(x)) &&
        x == id)
      // One kept from before (a station that handed it over keeps its id and home: its chats go on with it).
      let local_id = match at {
        Some(i) => js_string(get(Some(list[i]), "id"))
        None => id
      }
      let home = match at {
        Some(i) =>
          match get(Some(list[i]), "home") {
            Some(String(h)) => h
            _ => "homes/\{id}"
          }
        None => "homes/\{id}"
      }
      let made = match portable(given) {
        Object(m) => m
        _ => Map([])
      }
      made["id"] = jstr(local_id)
      made["home"] = jstr(home)
      let share : Map[String, Json] = Map([])
      share["id"] = jstr(id)
      share["borrowed"] = jbool(true)
      share["host"] = had.get("host").unwrap_or(jnull())
      made["share"] = Json::object(share)
      // Disabled by its host (kept apart from a pause here); paused on this station: still, as the host changes it.
      if get(Some(given), "enabled") is Some(False) {
        share["hostOff"] = jbool(true)
      }
      if at is Some(i) && gets(Some(list[i]), ["share", "paused"]) is Some(True) && is_obj(get(Some(list[i]), "share")) {
        share["paused"] = jbool(true)
        made["enabled"] = jbool(false)
      }
      if get(Some(got), "email") is Some(String(e)) {
        share["email"] = jstr(e)
      }
      // The workspaces it may serve here (none said: a host of before, as before).
      if get(Some(got), "workspaces") is Some(Array(ws)) {
        share["workspaces"] = jarr(ws.filter(w => w is String(_)))
      }
      if !(made.get("env") is Some(Object(_))) {
        made["env"] = Json::object(Map([]))
      }
      match at {
        Some(i) => list[i] = Json::object(made)
        None => list.push(Json::object(made))
      }
      r["profiles"] = jarr(list)
    }),
  )
  match self.profiles().search_by(p => gets(Some(p), ["share", "id"]) is Some(String(x)) && x == id && is_obj(get(Some(p), "share"))) {
    Some(i) => Some(self.home(self.profiles()[i]))
    None => None
  }
}

///|
async fn Sharing::placed_home(self : Sharing, home : String?) -> Unit {
  if home is Some(h) {
    self.files.mkdir(h)
  }
}

///|
fn Sharing::mirror(self : Sharing, id : String) -> String {
  self.files.join([self.root(), id, "skill"])
}

///|
async fn Sharing::place_skill(self : Sharing, id : String, had : Map[String, Json], got : Json) -> Unit {
  guard get(Some(got), "files") is Some(Object(_) as files) else { raise Failed("the host sent no files") }
  self.stop_watch("borrowed:\{id}")
  ignore(self.program.ask("skillWrite", [("dir", jstr(self.mirror(id))), ("files", files)]))
  had["hash"] = jstr(
    match get(Some(got), "hash") {
      None | Some(Null) => ""
      h => js_string(h)
    },
  )
}

///|
/// A copy taken away (already gone from the state): its profile, or its skill's link and files.
async fn Sharing::drop(self : Sharing, id : String, had : Map[String, Json]) -> Unit {
  if had.get("kind") is Some(String("profile")) {
    ignore(
      (self.deps.config.update_soon)(raw => {
        guard raw is Object(r) else { return }
        let list = match r.get("profiles") {
          Some(Array(a)) => a
          _ => []
        }
        r["profiles"] = jarr(
          list.filter(p => !(get(Some(p), "share") is Some(Object(sh)) &&
            sh.get("id") is Some(String(x)) &&
            x == id &&
            sh.get("borrowed") is Some(True))),
        )
      }),
    )
    return
  }
  self.stop_watch("borrowed:\{id}")
  self.link_turn.run(async fn() {
    // (again in its turn: a watch made before it came, by a pass that saw the copy still there, stops too)
    self.stop_watch("borrowed:\{id}")
    self.unlink_skill_now(id, had)
    self.files.remove(self.files.join([self.root(), id]), recursive=true)
  })
}

///|
/// A copied skill's link under its name, if it is this copy's (`had`: as it was, its name the one it was linked by).
async fn Sharing::unlink_skill(self : Sharing, id : String, had : Map[String, Json]) -> Unit {
  self.link_turn.run(async fn() { self.unlink_skill_now(id, had) })
}

///|
async fn Sharing::unlink_skill_now(self : Sharing, id : String, had : Map[String, Json]) -> Unit {
  let at = self.files.join([self.skills_dir(ws=self.ask_in(had)), js_string(had.get("name"))])
  if entry_at(self.files, at) is Link(l) && l == self.mirror(id) {
    self.files.remove(at) catch {
      _ => ()
    }
  }
}

///|
/// Each copied skill linked under its name into the agents' skills of the workspace it was had in, unless one of that
/// workspace's own has it; edits to the copy followed.
async fn Sharing::link_borrowed_skills(self : Sharing) -> Unit {
  self.link_turn.run(async fn() {
    let borrowed_all = self.borrowed()
    for id in js_keys(borrowed_all) {
      guard entry_of(borrowed_all, id) is Some(had) && had.get("kind") is Some(String("skill")) else { continue }
      let target = self.mirror(id)
      if !self.files.exists(target) {
        continue
      }
      try {
        let skills = self.skills_dir(ws=self.ask_in(had))
        let name = js_string(had.get("name"))
        let at = self.files.join([skills, name])
        let there = entry_at(self.files, at)
        // (taken away or renamed while its copy was looked at: `drop` or `heard` has it now)
        guard entry_of(self.borrowed(), id) is Some(same) &&
          physical_equal(same, had) &&
          had.get("kind") is Some(String("skill")) &&
          self.files.join([skills, js_string(had.get("name"))]) == at else {
          continue
        }
        match there {
          Nothing => {
            self.files.mkdir(skills)
            // Where links are refused, a junction will do: its target is the copy's own directory.
            self.files.symlink(target, at)
            // Its host hears it is shown here (it may have been told otherwise).
            if self.checked.contains(id) {
              self.checked.remove(id)
              self.again = true
            }
          }
          Other => continue
          Link(l) => if l != target { continue }
        }
      } catch {
        e => {
          // This copy's alone: the others are linked all the same.
          self.deps.log.warn("share", "a shared skill could not be linked", jobj([
            ("id", jstr(id)),
            ("name", had.get("name").unwrap_or(jnull())),
            ("error", jstr(error_words(e))),
          ]))
          continue
        }
      }
      self.watch_borrowed(id, target)
    }
  })
}

///|
/// Whether something else is under a copied skill's name here (one of this station's own, or another's copy).
async fn Sharing::name_taken(self : Sharing, had : Map[String, Json]) -> Bool {
  let at = (try Some(self.files.join([self.skills_dir(ws=self.ask_in(had)), js_string(had.get("name"))])) catch {
    _ => None
  })
  match at {
    Some(p) => !(entry_at(self.files, p) is Nothing)
    None => false
  }
}

///|
/// Whether a copied skill shows under its name here (one of this station's own of that name wins).
async fn Sharing::skill_linked(self : Sharing, id : String, had : Map[String, Json]) -> Bool {
  let at = (try Some(self.files.join([self.skills_dir(ws=self.ask_in(had)), js_string(had.get("name"))])) catch {
    _ => None
  })
  match at {
    Some(p) => entry_at(self.files, p) is Link(l) && l == self.mirror(id)
    None => false
  }
}

// ── edits followed ──

///|
fn Sharing::stop_watch(self : Sharing, key : String) -> Unit {
  if self.watchers.get(key) is Some(w) {
    (w.close)()
  }
  self.watchers.remove(key)
}

///|
/// The debounce of a burst of changes under `key`: `then` once they have settled SETTLE_MS.
fn Sharing::settled_then(self : Sharing, key : String, then : () -> Unit) -> Unit {
  if self.settle.get(key) is Some(off) {
    off()
  }
  // timer: a debounce of a burst
  self.settle[key] = (self.deps.clock.after)(settle_ms, () => {
    self.settle.remove(key)
    then()
  })
}

///|
/// `still`: whether it is still to be followed once its directory was looked at (it may have stopped meanwhile).
async fn Sharing::watch_dir(self : Sharing, key : String, dir : String, then : () -> Unit, still : () -> Bool) -> Unit {
  if self.closed || self.watchers.contains(key) || !self.files.exists(dir) {
    return
  }
  // (closed, no longer to be followed, or one begun meanwhile for the same key follows it already)
  if self.closed || !still() || self.watchers.contains(key) {
    return
  }
  let tree : Ref[Watcher?] = Ref(None)
  let made = (self.deps.watching.tree)(
    dir,
    rel => rel.split("/").all(n => !skipped.contains(n.to_string())),
    skill_dirs_most,
    _ => self.settled_then(key, () => {
      if tree.val is Some(t) {
        self.tasks.spawn(async fn() { ignore((t.scan)()) })
      }
      then()
    }),
    e => {
      self.deps.log.warn("share", "a shared skill's directory no longer followed", jobj([("dir", jstr(dir)), ("error", jstr(e))]))
      if tree.val is Some(t) && self.watchers.get(key) is Some(w) && physical_equal(w, t) {
        self.stop_watch(key)
      }
    },
  )
  tree.val = Some(made)
  self.watchers[key] = made
  self.tasks.spawn(async fn() {
    guard (made.scan)() is Some(failed) else { return }
    self.deps.log.warn("share", "a shared skill's directory cannot be followed", jobj([("dir", jstr(dir)), ("error", jstr(failed))]))
    if self.watchers.get(key) is Some(w) && physical_equal(w, made) {
      self.stop_watch(key)
    }
  })
}

///|
async fn Sharing::watch_hosted(self : Sharing, name : String, dir : String) -> Unit {
  self.watch_dir("hosted:\{name}", dir, () => self.reconcile_soon(), () => self.shared_skill(name) is Some(_))
}

///|
/// Follow the directory, not auth.json itself: Codex replaces the file when it signs in or renews.
fn Sharing::watch_login(self : Sharing, id : String, file : String) -> Unit {
  let key = "login:\{id}"
  if self.closed || (self.login_dirs.get(id) == Some(file) && self.watchers.contains(key)) {
    return
  }
  self.stop_watch(key)
  self.login_dirs.remove(id)
  let base = self.files.basename(file)
  let made : Ref[Watcher?] = Ref(None)
  let w = (self.deps.watching.dir)(
    self.files.dirname(file),
    name => {
      if name is Some(n) && n != base {
        return
      }
      self.settled_then(key, () => self.reconcile_soon())
    },
    () => if made.val is Some(m) && self.watchers.get(key) is Some(now) && physical_equal(now, m) {
      self.stop_watch(key)
    },
  )
  // (the profile's home may not exist until it is signed in)
  if w is Some(watcher) {
    made.val = Some(watcher)
    self.watchers[key] = watcher
    self.login_dirs[id] = file
  }
}

///|
async fn Sharing::watch_borrowed(self : Sharing, id : String, dir : String) -> Unit {
  let key = "borrowed:\{id}"
  self.watch_dir(
    key,
    dir,
    () => {
      if !self.borrowed().contains(id) {
        return
      }
      // (read while no new copy is placed: placing one stops this watch first, and what it read then is not an edit)
      let watching = self.watchers.get(key)
      self.tasks.spawn(async fn() {
        let hash = self.read_skill(dir).hash catch { _ => return }
        guard entry_of(self.borrowed(), id) is Some(had) else { return }
        let same = match (self.watchers.get(key), watching) {
          (Some(a), Some(b)) => physical_equal(a, b)
          (None, None) => true
          _ => false
        }
        if !same || had.get("hash") == Some(jstr(hash)) {
          return
        }
        had["pending"] = jbool(true)
        self.write_state()
        self.reconcile_soon()
      })
    },
    () => self.borrowed().contains(id),
  )
}

///|
/// An edit made to a copied skill, sent to its host on the version it was made on.
async fn Sharing::send_skill_edit(self : Sharing, id : String, had : Map[String, Json]) -> Unit {
  let read = self.read_skill(self.mirror(id), bytes=true)
  let answer = self.ask(
    js_string(had.get("host")),
    self.ask_in(had),
    jobj([
      ("method", jstr("share.put")),
      ("id", jstr(id)),
      ("base", had.get("version").unwrap_or(jnull())),
      ("files", read.files.unwrap_or(jnull())),
    ]),
  )
  had["pending"] = jbool(false)
  had["hash"] = jstr(read.hash)
  if get(Some(answer), "version") is Some(Number(_) as v) {
    had["version"] = v
  }
  // On an older copy: the host's is fetched, the edit beside it.
  if get(Some(answer), "conflict") is Some(True) {
    had["stale"] = jbool(true)
  }
}
