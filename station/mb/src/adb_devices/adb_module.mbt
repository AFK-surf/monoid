// adb/module.ts: phones lent to the station over members' links as a part of the station: the offers and asks that come
// on a member's link, the chats' grants of them, each grant's adb server and display, the agents' tools, and the phones
// among the workspace's devices (devices/module.ts `phones`).

///|
pub struct Adb {
  w : World
  grants : PhoneGrants
  servers : GrantServers
  displays : PhoneDisplays
  shares : Shares
}

///|
/// The phones' part. `admit`: whether who uses a grant's adb server is found among the machine's processes (none on
/// Windows); `record`: where its servers are written down; `display_file`: scrcpy's server.
pub async fn Adb::new(
  w : World,
  db : @sql.Db,
  display_file : String,
  record? : String,
  admit~ : Bool = true,
  outcomes~ : Bool = false,
) -> Adb {
  let grants_ref : Ref[PhoneGrants?] = { val: None, }
  let shares_ref : Ref[Shares?] = { val: None, }
  let displays_ref : Ref[PhoneDisplays?] = { val: None, }
  let servers_ref : Ref[GrantServers?] = { val: None, }
  let session_of = fn(grant : String) -> String? raise {
    match grants_ref.val {
      Some(g) => g.get(grant).map(r => r.session())
      None => None
    }
  }
  let gate_admit : Admit? = if admit {
    Some(async fn(grant, holders) {
      let deps : GateDeps = {
        session: async fn(id) {
          match session_of(id) {
            None => Null
            Some(key) =>
              jo([
                (
                  "workspace",
                  get(w.store("getSession", [js(key)]), "workspace"),
                ),
              ])
          }
        },
        table: async fn() { w.ask("platform.processTable", []) },
        runners: async fn(id) {
          match session_of(id) {
            None => []
            Some(key) =>
              list_of(Some(w.ask("agents.runners", [js(key)]))).map(x => {
                num_of(Some(x)).unwrap_or(-1.0).to_int()
              })
          }
        },
        jobs: async fn() {
          list_of(Some(w.ask("jobs.watched", []))).map(j => {
            let session = get(j, "session")
            (
              num_of(at(Some(j), "pgid")).unwrap_or(-1.0).to_int(),
              fn(id : String) -> Bool raise {
                jeq(session, jopt(session_of(id)))
              },
            )
          })
        },
        cwds: async fn(pids) {
          cwds_of(w.ask("platform.cwds", [ja(pids.map(ji))]))
        },
        self_pid: num_of(Some(w.ask("process.pid", [])))
        .unwrap_or(-1.0)
        .to_int(),
        elsewhere: None,
      }
      gate(deps, w, grant, holders)
    })
  } else {
    None
  }
  let servers = GrantServers::new(w, record?, admit?=gate_admit)
  servers_ref.val = Some(servers)
  (w.spawn)(async fn() {
    ignore(
      servers.reap(previous_gone=async fn() {
        ignore(w.ask("previous.gone", []))
      }),
    ) catch {
      _ => ()
    }
  })
  let displays = PhoneDisplays::new(
    w,
    display_file,
    fn(id) {
      match grants_ref.val {
        Some(g) =>
          match g.get(id) {
            Some(r) if r.status() == "granted" =>
              r.get("lastUsedAt").unwrap_or(jn(0.0))
            _ => Null
          }
        None => Null
      }
    },
    fn(owner) {
      match (shares_ref.val, displays_ref.val) {
        (Some(s), Some(d)) => s.screens(owner, d.titles(owner))
        _ => ()
      }
    },
  )
  displays_ref.val = Some(displays)
  let grants = PhoneGrants::new(
    w,
    db,
    async fn(r) { grant_chat_title(w, r.v) },
    async fn(r, workspace, change) {
      if !(workspace is Null) {
        ignore(
          w.ask("events.tell", [
            js("adb-grant"),
            r,
            js("adb-grant\u{0}\{text_of(at(Some(r), "id"))}"),
            jo([("workspace", workspace), ("email", get(r, "owner"))]),
          ]),
        )
      }
      if change == "grant" {
        ignore(w.ask("sources.changed", [workspace]))
      }
      if change != "grant" {
        return
      }
      let id = text_of(at(Some(r), "id"))
      let owner = text_of(at(Some(r), "owner"))
      let status = text_of(at(Some(r), "status"))
      if status == "denied" || status == "ended" {
        // (its display's apps closed through the grant's adb server first)
        (w.spawn)(async fn() {
          displays.close(id)
          servers.stop(id)
        })
      }
      match shares_ref.val {
        Some(s) => s.regrant(owner)
        None => ()
      }
      // (granted while the phone is offered here already: its card says at once how it is held)
      if status == "granted" {
        match shares_ref.val {
          Some(s) =>
            match
              s.by_key.values().find_first(sh => sh.email().to_lower() == owner) {
              Some(held) => grants_ref.val.unwrap().linked(owner, held.state)
              None => ()
            }
          None => ()
        }
      }
    },
    outcomes~,
    told_revoke=async fn(signed, owner, request, workspace) {
      ignore(
        w.ask("events.tell", [
          js("adb-revoke"),
          signed,
          js("adb-revoke\u{0}\{owner}\u{0}\{request}"),
          jo([("workspace", js(workspace)), ("email", js(owner))]),
        ]),
      )
    },
  )
  grants_ref.val = Some(grants)
  let shares = Shares::new(
    w,
    cloud=true,
    servers~,
    granted=async fn(email) { grants.granted_of_owner(email).map(r => r.id()) },
    stated=async fn(email, state) {
      grants.linked(email, state)
      // (the members' list of devices says the phones lent here)
      ignore(w.ask("sources.changed", [Null]))
    },
    used=async fn(id, force) { grants.used(id, force) },
  )
  shares_ref.val = Some(shares)
  { w, grants, servers, displays, shares, }
}

///|
fn cwds_of(v : J) -> Map[Int, String] {
  let out = Map::new()
  match v {
    Obj(fs) =>
      for f in fs {
        match @session_chats.js_number(js(@jsjson.text(f.0))) {
          Some(n) => out[n.to_int()] = js_text(f.1)
          None => ()
        }
      }
    Arr(pairs) =>
      for p in pairs {
        match (at_i(Some(p), 0), at_i(Some(p), 1)) {
          (Some(Num(n)), Some(Str(_) as s)) => out[n.to_int()] = js_text(s)
          _ => ()
        }
      }
    _ => ()
  }
  out
}

///|
/// Lending a phone is a change a read-only member does not make (credential.ts `readOnly`).
pub fn read_only(viewer : J) -> Bool {
  text_of(at(Some(viewer), "role")) == "viewer"
}

///|
/// An offer or an ask on a member's link (its send side came finished, what it hears goes down the stream).
pub async fn Adb::stream(
  self : Adb,
  conn : J,
  viewer : J,
  head : J,
  stream : J,
) -> Unit {
  let w = self.w
  if read_only(viewer) {
    write_line(
      w,
      stream,
      jo([
        ("status", ji(403)),
        ("headers", jo([("content-type", js("application/json"))])),
      ]),
    )
    stream_write(
      w,
      stream,
      @utf8.encode(
        stringify(
          jo([("error", js("read-only members cannot lend or use phones"))]),
        ),
      ),
    )
    ignore(w.ask("stream.finish", [stream]))
    return
  }
  // A grant decided, taken back, or the owner's grants listed (from their app).
  let ask = match at(Some(head), "adb") {
    Some(Null) | None => jo([])
    Some(a) => a
  }
  let op = match at(Some(ask), "op") {
    Some(Str(_) as o) => js_text(o)
    _ => ""
  }
  if ["decide", "revoke", "grants", "lasts", "sign"].contains(op) {
    let reply = async fn(status : Int, body : J) {
      write_line(
        w,
        stream,
        jo([
          ("status", ji(status)),
          ("headers", jo([("content-type", js("application/json"))])),
        ]),
      )
      stream_write(w, stream, @utf8.encode(stringify(body)))
      ignore(w.ask("stream.finish", [stream]))
    }
    let email = text_of(at(Some(viewer), "email")).to_lower()
    let ws = text_of(at(Some(viewer), "workspace"))
    // (`lasts`, and the `lasts` op answered with it: for cores from before, whose 默认最长授权 capped a card's lengths;
    // nothing caps them now. Goes 7 days after this ships.)
    if op == "grants" {
      return reply(
        200,
        jo([
          ("grants", ja(self.grants.of_owner(email, workspace=ws))),
          // (`revokes`: what their devices signed to take grants back, each phone checking it, whichever station's grant)
          ("revokes", ja(self.grants.revokes_of_owner(email))),
          ("lasts", js("chat")),
          ("signs", jb(true)),
        ]),
      )
    }
    if op == "lasts" {
      return reply(200, jo([("lasts", js("chat"))]))
    }
    // A taking back of a grant another station holds, brought here by the owner's device to be told to their phones
    // (the grant's own station may never say it ended).
    if op == "revoke" && at(Some(ask), "relay") is Some(Bool(true)) {
      return match self.grants.keep_revoke(email, at(Some(ask), "signed"), ws) {
        None => reply(200, jo([("ok", jb(true))]))
        Some(why) => reply(422, jo([("message", js(why))]))
      }
    }
    let id = match at(Some(ask), "request") {
      Some(Str(_) as r) => js_text(r)
      _ => ""
    }
    let scope = if is_scope(at(Some(ask), "scope")) {
      str_of(at(Some(ask), "scope"))
    } else {
      None
    }
    let why = match op {
      "sign" => self.grants.sign(email, id, at(Some(ask), "signed"), ws)
      "decide" =>
        self.grants.decide(
          email,
          id,
          scope,
          ws,
          signed?=at(Some(ask), "signed"),
        )
      _ => self.grants.revoke(email, id, ws, signed?=at(Some(ask), "signed"))
    }
    let request = self.grants.get(id)
    return match why {
      None =>
        reply(
          200,
          jo([
            (
              "request",
              match request {
                Some(r) => self.grants.shown(r)
                None => Null
              },
            ),
          ]),
        )
      Some(why) => reply(422, jo([("message", js(why))]))
    }
  }
  answer_adb(self.shares, conn, viewer, head, stream)
}

///|
/// What the phone's notification names a chat by: its title, else what its agent asked the phone for.
pub async fn Adb::name_of(self : Adb, grant : String) -> String {
  guard self.grants.get(grant) is Some(r) else { return "" }
  let title = text_of(at(Some(self.grants.shown(r)), "chatTitle"))
  if title != "" {
    title
  } else {
    first_units(r.text("reason"), 40)
  }
}

///|
/// `s.slice(0, n)`.
fn first_units(s : String, n : Int) -> String {
  js_slice(s, 0, b=n)
}

///|
/// How a granted phone is reached now (phone_use, device_use).
pub async fn Adb::reach(self : Adb, owner : String, grant : String) -> String {
  let phones = self.shares
    .list()
    .filter(p => text_of(at(Some(get(p, "owner")), "email")).to_lower() == owner)
  let server = if phones.length() > 0 {
    self.servers.ensure(grant)
  } else {
    None
  }
  // Its own screen, made once the phone is in the grant's server (the first phone: one person lends one).
  let phone = phones
    .search_by(p => text_of(at(Some(p), "adb")) == "connected")
    .map(i => phones[i])
  let display = match (server, phone) {
    (Some(s), Some(p)) =>
      self.displays.open(
        grant,
        owner,
        self.name_of(grant),
        s.port,
        text_of(at(Some(p), "serial")),
      ) catch {
        e => jo([("failed", js(message_of(e)))])
      }
    _ => Null
  }
  reached(
    phones,
    server.map(s => s.port),
    gone=self.shares.gone.get(owner).unwrap_or(Null),
    display~,
  )
}

///|
/// phone_use.
pub async fn Adb::phone_use(self : Adb, session : String, args : J) -> String {
  phone_use(
    self.grants,
    async fn(owner, grant) { self.reach(owner, grant) },
    session,
    args,
  )
}

///|
/// A phone's id among the devices: of its owner and its serial.
pub fn phone_id(email : String, serial : String) -> String {
  js_slice(
    @memory.sha256_hex(@utf8.encode("\{email.to_lower()}\u{0}\{serial}")),
    0,
    b=16,
  )
}

///|
fn phone_name(p : J, email : String) -> String {
  let owner = get(p, "owner")
  let name = if truthy(at(Some(owner), "name")) {
    js_text(get(owner, "name"))
  } else {
    email
  }
  let device = if truthy(at(Some(p), "device")) {
    js_text(get(p, "device"))
  } else {
    "手机"
  }
  "\{name} 的 \{device}"
}

///|
fn owner_text(p : J, k : String) -> String {
  match at(Some(get(p, "owner")), k) {
    None | Some(Null) => ""
    Some(v) => js_text(v)
  }
}

///|
/// The phones among the workspace's devices: those lent to this station now, any member's, each its person's to grant.
pub async fn Adb::phone_entries(self : Adb, session : String) -> Array[J] {
  let station = text_of(Some(self.w.ask("cloud.station", [])))
  let out = []
  for p in self.shares.list() {
    let email = owner_text(p, "email").to_lower()
    let held = self.grants.held(session)
    let mine = held.search_by(r => r.owner() == email).map(i => held[i])
    let shared = self.grants.granted_of_owner(email).length() == 0
    let theirs = self.grants.of_owner(email)
    let pending = theirs
      .search_by(r => {
        text_of(at(Some(r), "session")) == session &&
        text_of(at(Some(r), "status")) == "pending"
      })
      .map(i => theirs[i])
    let this_chat = match (mine, pending) {
      (Some(m), _) =>
        "granted to this chat (\{scope_said(m.get("scope"))}): device_use gives it"
      (None, Some(r)) =>
        "asked: waits for \{email} to approve request \{text_of(at(Some(r), "id"))} on the card in your chat"
      _ =>
        if shared {
          "shared with every agent of this station by its app: adb -s <target> on this machine's own adb"
        } else {
          "no grant: ask with device_use {device: \"<its name>\", reason}; its card goes to \{email}"
        }
    }
    let has_access = if shared {
      js("every agent of this station")
    } else {
      ja(
        self.grants
        .of_owner(email)
        .filter(r => text_of(at(Some(r), "status")) == "granted")
        .map(r => {
          if truthy(at(Some(r), "chatTitle")) {
            js("\"\{js_text(get(r, "chatTitle"))}\"")
          } else {
            get(r, "chat")
          }
        }),
      )
    }
    out.push(
      jo([
        ("id", js(phone_id(email, js_text(get(p, "serial"))))),
        ("name", js(phone_name(p, email))),
        ("kind", js("adb")),
        ("target", js(js_text(get(p, "serial")))),
        ("via", js("phone")),
        ("station", js(station)),
        ("stationName", js("")),
        ("owner", js(email)),
        ("ownerEmail", js(email)),
        ("ownerName", js(owner_text(p, "name"))),
        ("online", jb(text_of(at(Some(p), "adb")) == "connected")),
        ("thisChat", js(this_chat)),
        ("hasAccess", has_access),
      ]),
    )
  }
  out
}

///|
/// device_use of a phone (`e`, a phone's entry): asked of its owner, as phone_use asks.
pub async fn Adb::phone_device_use(
  self : Adb,
  session : String,
  e : J,
  reason : String,
) -> String {
  let owner = text_of(at(Some(e), "ownerEmail")).to_lower()
  let mut r = if owner == "" {
    self.grants.ask(session, reason)
  } else {
    self.grants.ask(session, reason, of=owner)
  }
  if r.status() == "pending" {
    let pending = self.grants.card_pending(r)
    r = self.grants.get(r.id()).unwrap_or(r)
    if r.status() == "pending" && pending == Some(false) {
      return "The phone request \{r.id()} is still pending, but its card is no longer pending. If it is still needed, call phone_use again with the same reason and reask: true."
    }
  }
  if r.status() == "granted" {
    return self.reach(r.owner(), r.id())
  }
  said(r)
}

///|
/// The chat's phone grants (or requests) handed back: their names.
pub async fn Adb::phone_done(
  self : Adb,
  session : String,
  e : J,
) -> Array[String] {
  let ended = match e {
    Null => self.grants.release(session)
    e => self.grants.release(session, owner=text_of(at(Some(e), "ownerEmail")))
  }
  ended.map(r => "\{r.owner()} 的手机")
}

///|
/// What the members are shown: each phone lent here, whose, and the chats of this workspace that hold it.
pub async fn Adb::phones_shown(self : Adb, ws : String) -> Array[J] {
  let out = []
  for p in self.shares.list() {
    let email = owner_text(p, "email").to_lower()
    let held = self.grants
      .of_owner(email, workspace=ws)
      .filter(r => text_of(at(Some(r), "status")) == "granted")
    let open = self.grants.granted_of_owner(email).length() == 0
    let grants = []
    for r in held {
      let scope = text_of(at(Some(r), "scope"))
      let exp = match at(Some(r), "exp") {
        Some(Num(n)) => n
        _ => 0.0
      }
      let used = match at(Some(r), "lastUsedAt") {
        Some(Num(n)) => n
        _ => 0.0
      }
      let by = self.grants
        .starter(text_of(at(Some(r), "session")))
        .unwrap_or("")
      grants.push(
        jo([
          ("request", get(r, "id")),
          ("session", get(r, "session")),
          ("chat", get(r, "chat")),
          (
            "title",
            match at(Some(r), "chatTitle") {
              Some(Null) | None => js("")
              Some(t) => t
            },
          ),
          ("by", js(by)),
          (
            "timeoutKind",
            js(
              if scope == "idle" {
                "idle"
              } else if scope == "chat" {
                "chat"
              } else {
                "fixed"
              },
            ),
          ),
          (
            "timeoutSeconds",
            ji(
              if scope == "hour" {
                3600
              } else if scope == "eight" {
                28800
              } else if scope == "idle" {
                3600
              } else {
                0
              },
            ),
          ),
          ("exp", jn(exp)),
          (
            "until",
            jn(
              if scope == "idle" {
                @cmp.minimum(exp, (used / 1000.0).floor() + 3600.0)
              } else {
                exp
              },
            ),
          ),
        ]),
      )
    }
    out.push(
      jo([
        ("id", js(phone_id(email, js_text(get(p, "serial"))))),
        ("name", js(phone_name(p, email))),
        ("target", js(js_text(get(p, "serial")))),
        ("ownerEmail", js(email)),
        ("ownerName", js(owner_text(p, "name"))),
        ("online", jb(text_of(at(Some(p), "adb")) == "connected")),
        ("open", jb(open)),
        ("grants", ja(grants)),
      ]),
    )
  }
  out
}

///|
/// phone_send: a file of this machine put on the phone granted to this chat.
pub async fn Adb::phone_send(self : Adb, session : String, args : J) -> String {
  let w = self.w
  guard self.grants.held(session).get(0) is Some(grant) else {
    return "This chat holds no phone grant: ask for the phone with phone_use first."
  }
  guard self.shares.by_key
    .values()
    .find_first(s => s.email().to_lower() == grant.owner())
    is Some(share) else {
    return "Granted, but the phone is not lent to this station right now: call phone_use to see why."
  }
  let row = w.store("getSession", [js(session)])
  guard at(Some(row), "workspace") is Some(workspace) else {
    raise fail_("unknown session \{session}")
  }
  let (name, size) = staged(
    w,
    text_of(Some(workspace)),
    str_of(at(Some(args), "path")).unwrap_or(""),
  )
  self.grants.used(grant.id(), true)
  let r = fetch_on_phone(w, share.conn, session, name, size, heard=async fn(_) {
    self.grants.used(grant.id(), true)
  })
  if at(Some(r), "path") is Some(p) {
    let path = js_text(p)
    return "On the phone at \{path} (\{num_text(size)} bytes). pm cannot read that folder: to install an APK, adb … shell 'cp \{path} /data/local/tmp/a.apk && pm install -r /data/local/tmp/a.apk'."
  }
  if at(Some(r), "old") is Some(Bool(true)) {
    return "The still.fail app on the phone is too old to take files this way: use adb push, or ask its person to update the app."
  }
  "Not all there: the phone has \{js_text(get(r, "at"))} of \{num_text(size)} bytes (\{js_text(get(r, "error"))}). Call phone_send again to go on from there."
}

///|
/// adb_devices: phones lent with an app's switch (from before grants), any agent's.
pub async fn Adb::adb_devices(self : Adb) -> String {
  let out = []
  for p in self.shares.list() {
    if self.grants
      .granted_of_owner(js_text(get(get(p, "owner"), "email")))
      .length() ==
      0 {
      out.push(p)
    }
  }
  listed(out)
}

///|
/// The station stopping: the phones' links, displays and servers let go.
pub async fn Adb::close(self : Adb) -> Unit {
  self.shares.close()
  self.displays.close_all()
  self.servers.close()
}
