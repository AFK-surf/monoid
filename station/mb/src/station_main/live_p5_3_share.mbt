// What a station shares with the others of its workspaces (station/src/share/index.ts `Sharing`: a subscription's
// profile lent and borrowed, a skill shared on its own), the agents' memory brought level between them
// (share/memory.ts `MemorySync`: MEMORY.md and the team's skills, two versions made apart merged by the memory's
// program, station/mb src/memory, as `--builder memory` does) and chats shared with other workspaces (xshare/:
// `ChatShares`, its index built by `ChatShareIndexBuilder`), as parts of the station: `@share_sync`'s, given the
// station's config, its cloud's word on its workspaces, the files, the peers' bus (`bus.on_peer_prefix`,
// `bus.call_peer`) and the accounts. `bus.outside_reaches` says which stations of other workspaces this one may ask.

///|
/// How often a followed tree is looked at for what changed in it (the machine's own files, which tell nothing by
/// themselves here: the shell keeps no watch).
let p53_follow_ms : Int = 2000

///|
priv struct P53Share {
  bus : LiveBus
  accounts : P53Accounts
  files : @share_sync.Files
  log : @share_sync.Log
  clock : @share_sync.Clock
  mut sharing : @share_sync.Sharing?
  mut memory : @share_sync.MemorySync?
  mut shares : @share_sync.ChatShares?
  mut index : @share_sync.ChatShareIndexBuilder?
}

///|
fn P53Share::new(bus : LiveBus, accounts : P53Accounts) -> P53Share {
  {
    bus,
    accounts,
    files: { host: bus.host, sep: sep() },
    log: { say: (level, part, message, fields) => slice_log(level, part, message, fields) },
    clock: { ..@share_sync.Clock::live(bus.host.rt), now: () => p5_epoch_ms().to_double() },
    sharing: None,
    memory: None,
    shares: None,
    index: None,
  }
}

///|
/// A membership as cloud.json says it (cloud/state.ts `homeMembership`, `joinedMembership`).
fn p53_membership(m : Json) -> @share_sync.Membership {
  {
    workspace: jtext_or_empty(m, "workspace"),
    workspace_name: jtext_or_empty(m, "workspace_name"),
    peers: match jfield(m, "peers") {
      Array(xs) => xs
      _ => []
    },
  }
}

///|
/// The cloud's word on this station and its workspaces (cloud/state.ts `Cloud`), from what the bus keeps of it.
fn P53Share::cloud(self : P53Share) -> @share_sync.Cloud {
  let bus = self.bus
  let state = () => (bus.cloud_state.val)()
  let removed = () => match state() {
    Some(s) => jnum_of(s, "removed_at") is Some(_)
    None => false
  }
  let memberships = () => match state() {
    Some(s) if jtext_or_empty(s, "workspace") != "" && !removed() => {
      let out = [p53_membership(s)]
      match jfield(s, "joined") {
        Array(js) => for j in js { out.push(p53_membership(j)) }
        _ => ()
      }
      out
    }
    _ => []
  }
  {
    has_state: () => state() is Some(_),
    station: () => match state() { Some(s) => jtext(s, "station"); None => None },
    name: () => match state() { Some(s) => jtext(s, "name"); None => None },
    rig: () => match state() { Some(s) => !(jfield(s, "rig") is Null); None => false },
    peers_current: () => state() is Some(_) && !removed() && (bus.cloud_reached.val)(),
    memberships,
    membership: ws => memberships().iter().find_first(m => m.workspace == ws),
    home: () => if removed() { None } else { p53_home(bus) },
    removed,
    listen: f => (bus.cloud_listen.val)(_ => f()),
  }
}

///|
/// config.json as the shares read and change it (ops/config.ts `ConfigFile`).
fn P53Share::config(self : P53Share) -> @share_sync.Config {
  let bus = self.bus
  {
    raw: () => (bus.config_raw.val)(),
    update_soon: async fn(edit) {
      (bus.config_update.val)(raw => {
        // (made on a copy, which is then the config)
        let copy = attempt(() => @json.parse(raw.stringify())).unwrap_or(raw)
        match (try { Ok(edit(copy)) } catch { e => Err(e) }) {
          Ok(_) => copy
          Err(_) => raw
        }
      })
    },
    listen: f => (bus.config_listen.val)(_ => f()),
  }
}

///|
/// The agents' home (sessions/agents.ts `settings().agentHome`): config.json's, else `<data>/agent`.
fn P53Share::agent_home(self : P53Share) -> String {
  match jtext((self.bus.config_raw.val)(), "agentHome") {
    Some(h) if h != "" => h
    _ => @nodepath.join(sep(), [self.bus.data, "agent"])
  }
}

///|
/// How the machine's directories are followed: a tree looked at every P53_FOLLOW_MS for what changed in it (each
/// file's size and time), what changed told by its path.
fn P53Share::watching(self : P53Share) -> @share_sync.Watching {
  let host = self.bus.host
  let stopped = self.bus.stopped
  {
    tree: (root, into, most, changed, _failed) => {
      let gone = Ref(false)
      let marks : Ref[Map[String, String]?] = Ref(None)
      let look = async fn() -> String? {
        let now : Map[String, String] = Map([])
        let queue = [(root, 0)]
        let mut seen = 0
        while queue.pop() is Some((dir, depth)) {
          for e in p53_readdir_types(host, dir) {
            let (name, kind) = e
            let full = @nodepath.join(sep(), [dir, name])
            seen += 1
            if seen > 20000 {
              break
            }
            if kind == "dir" {
              if depth < most && into(full) {
                queue.push((full, depth + 1))
              }
              continue
            }
            match (try { Ok(host.shell("fs.meta", { "path": jstr(full) })) } catch { e => Err(e) }) {
              Ok((m, _)) => now[full] = "\{jnum_of(m, "size").unwrap_or(0.0)}:\{jnum_of(m, "mtimeMs").unwrap_or(0.0)}"
              Err(_) => ()
            }
          }
        }
        match marks.val {
          Some(before) => {
            for k, v in now {
              if before.get(k) != Some(v) {
                changed(k)
              }
            }
            for k, _ in before {
              if !now.contains(k) {
                changed(k)
              }
            }
          }
          None => ()
        }
        marks.val = Some(now)
        None
      }
      ignore(
        host.rt.fork_daemon("a followed tree", on_error=e => @host.note("a followed tree failed: \{e}"), async fn() {
          ignore(look())
          while !gone.val && !stopped.is_done() {
            @effect.sleep(p53_follow_ms) // timer: a sample of this machine (its own files: the shell keeps no watch)
            ignore(look())
          }
        }),
      )
      { close: () => gone.val = true, scan: look }
    },
    dir: (_dir, _changed, _failed) => None,
  }
}

///|
/// A request to station `peer` of workspace `ws` (None: the first both are in), as the peers' bus carries it.
async fn P53Share::ask(self : P53Share, peer : String, ws : String?, request : Json) -> Json {
  let meth = jtext_or_empty(request, "method")
  let (answer, _) = self.bus.call_peer(peer, ws, meth, request)
  answer
}

///|
fn P53Share::attach(self : P53Share) -> Unit {
  let bus = self.bus
  let cloud = self.cloud()
  let rt = bus.host.rt
  // ── Sharing ──
  let sharing = @share_sync.Sharing::new(
    {
      data: bus.data,
      config: self.config(),
      cloud,
      ask: async fn(peer, ws, request) { self.ask(peer, ws, request) },
      agent_home: () => self.agent_home(),
      codex_auth_file: () => {
        let home = env_get("CODEX_HOME").unwrap_or(@nodepath.join(sep(), [homedir(), ".codex"]))
        @nodepath.join(sep(), [home, "auth.json"])
      },
      machine_email: None,
      claude_token: async fn(profile, rejected) {
        let accounts = self.accounts.made()
        let got = p53_json(accounts.claude_token(@jsjson.JV::of_json(profile), rejected, true))
        (jtext_or_empty(got, "token"), jnum_of(got, "expiresAt").unwrap_or(0.0))
      },
      codex_renew_running: async fn(profile) {
        bus.hub_codex_renew_running(profile)
      },
      agy_renew: Some(async fn(profile) { bus.hub_agy_renew(profile) }),
      status: async fn(id) {
        let accounts = self.accounts.made()
        p53_json(accounts.health(id).to_jv())
      },
      changed: () => (bus.overview_changed.val)(),
      recheck: Some(() => match self.accounts.accounts { Some(a) => a.recheck_borrowed(); None => () }),
      profile_changed: Some(async fn(id, login) {
        match self.accounts.accounts {
          Some(a) => a.shared_changed(id, login)
          None => ()
        }
      }),
      quota_reset: Some(async fn(id) {
        match self.accounts.accounts {
          Some(a) => a.shared_quota_reset(id)
          None => ()
        }
      }),
      profile_gone: Some(async fn(id) { bus.hub_profile_gone(id) }),
      itself: Some(station => station == p53_station_id(bus)),
      codex_token_url: @share_sync.codex_token_url,
      fetch: async fn(url, body) {
        let answer = (self.accounts.oauth_io.fetch)({
          url,
          method_: "POST",
          headers: [("content-type", "application/json")],
          body: Some(body),
          timeout_ms: 30000,
          manual: false,
        })
        (answer.status, answer.body)
      },
      account_email: async fn(runtime, home) {
        match self.accounts.accounts {
          Some(a) => a.account_email(runtime, home)
          None => None
        }
      },
      lang: () => (bus.lang.val)(),
      random_hex: async fn(n) { @drive.hex(@drive.random_bytes(n)) },
      watching: self.watching(),
      clock: self.clock,
      log: self.log,
      files: self.files,
    },
    rt,
  )
  self.sharing = Some(sharing)
  // (agents.ts `readers.onTrim`: the shares' and the memory's programs let go short of memory)
  bus.on_trim(() => {
    let mut n = sharing.trim_idle()
    match self.memory {
      Some(m) => n += m.trim_idle()
      None => ()
    }
    n
  })
  // (a login home again, by any route: the share a trip made for it undone; move/live.ts `sharing.onHosted`)
  sharing.set_on_hosted(
    Some((share, from) => ignore(
      bus.host.rt.fork_quiet(name="share came home", async fn() {
        ignore((bus.coord_ask.val)("move.shareCameHome", Json::array([Json::string(share), Json::string(from)]))) catch {
          _ => ()
        }
      }),
    )),
  )
  self.accounts.sharing = Some(sharing)
  bus.on_peer_prefix("share.", async fn(_peer, ws, _meth, request, _bytes) { (sharing.handle(_peer, request, workspace=ws), None) })
  // ── the agents' memory ──
  let memory = @share_sync.MemorySync::new(
    {
      data: bus.data,
      cloud,
      ask: async fn(peer, ws, request) { self.ask(peer, Some(ws), request) },
      agent_home: () => self.agent_home(),
      workspace_agent_home: async fn(agent_home, ws, home) {
        let dir = @share_sync.workspace_agent_home_path(sep(), agent_home, ws, home)
        ignore(bus.host.shell("fs.mkdir", { "path": jstr(dir), "recursive": jb(true) }))
        dir
      },
      still: false,
      watching: self.watching(),
      clock: self.clock,
      log: self.log,
      files: self.files,
    },
    rt,
  )
  self.memory = Some(memory)
  bus.on_peer_prefix("memory.", async fn(peer, ws, _meth, request, _bytes) { (memory.handle(peer, request, ws), None) })
  // ── chats shared across workspaces ──
  let sql = @share_sync.SqlChatShares::new(bus.db, () => bus.store.now().to_double())
  let gone : @effect.Deferred[Bool] = @effect.Deferred::new()
  ignore(rt.fork_daemon("the station before gone", on_error=e => @host.note("the station before gone failed: \{e}"), async fn() {
    (bus.previous_gone)()
    ignore(gone.succeed(true))
  }))
  let index = @share_sync.ChatShareIndexBuilder::new(sql, () => Some(bus.db), gone, rt, self.log)
  self.index = Some(index)
  let shares = @share_sync.ChatShares::new(
    {
      data: bus.data,
      store: sql.store(),
      cloud,
      chat_ws: Some(session => match p53_session_row(bus, session) { Null => None; row => either(jtext(row, "ws"), p53_home(bus)) }),
      ask: async fn(station, request) { self.ask(station, None, request) },
      link: session => match p53_home(bus) {
        Some(ws) => match p53_origin(bus) {
          Some(o) => Some("\{o}/o/\{ws}/\{p53_station_id(bus)}/\{session}")
          None => None
        }
        None => None
      },
      title: session => jtext_or_empty(p53_session_row(bus, session), "title"),
      touches: entry => match jfield(entry, "session") { String(s) => [s]; _ => [] },
      inbox: async fn(station, request) { bus.hub_inbox(station, request) },
      prepare_index: Some(() => index.request()),
      clock: self.clock,
      log: self.log,
      files: self.files,
    },
    rt,
  )
  self.shares = Some(shares)
  bus.on_peer_prefix("xshare.", async fn(peer, ws, _meth, request, _bytes) { (shares.inside(peer, request, workspace=ws), None) })
  bus.outside_reaches.val = (target, ws) => match ws {
    Some(w) => shares.reaches(target, w)
    None => false
  }
  // (each loaded and set going once the station before is gone, as main.ts starts them)
  ignore(
    rt.fork_daemon("shares", on_error=e => @host.note("shares failed: \{e}"), async fn() {
      (bus.previous_gone)()
      sharing.load() catch {
        e => slice_log("warn", "share", "the shared profiles were not loaded", jobj_of([("error", jstr(p53_words(e)))]))
      }
      sharing.start()
      memory.start()
      shares.load() catch {
        e => slice_log("warn", "xshare", "the chats shared were not loaded", jobj_of([("error", jstr(p53_words(e)))]))
      }
      shares.start() catch {
        e => slice_log("warn", "xshare", "the chats shared were not set going", jobj_of([("error", jstr(p53_words(e)))]))
      }
    }),
  )
  bus.parts.routes([
    { meth: "GET", path: "/share", answer: async fn(_r) { self.state() } },
    {
      meth: "POST",
      path: "/profiles/:id/share",
      answer: async fn(r) {
        let body = jfield(r, "body")
        sharing.share_profile(p53_param(r, "id", 2), jtrue(body, "shared"), jfield(r, "viewer"))
        jobj_of([("ok", jb(true))])
      },
    },
    {
      meth: "POST",
      path: "/skills/:name/share",
      answer: async fn(r) {
        sharing.share_skill(p53_param(r, "name", 2), jtrue(jfield(r, "body"), "shared"), jfield(r, "viewer"))
        jobj_of([("ok", jb(true))])
      },
    },
    {
      meth: "GET",
      path: "/memory/kept",
      answer: async fn(r) { self.memory_kept(either(jtext(jfield(r, "query"), "workspace"), p53_home(bus)).unwrap_or("")) },
    },
  ])
}

///|
fn P53Share::state(self : P53Share) -> Json {
  jobj_of([
    ("sharing", match self.sharing { Some(s) => s.state_json(); None => Json::null() }),
    ("xshare", self.xshare_state()),
  ])
}

///|
async fn P53Share::status(self : P53Share, arg : Json) -> Json {
  match self.sharing {
    Some(s) => s.status(arg)
    None => Json::null()
  }
}

///|
fn P53Share::xshare_state(self : P53Share) -> Json {
  match self.shares {
    Some(s) => s.state_json()
    None => Json::null()
  }
}

///|
fn P53Share::memory_kept(self : P53Share, ws : String) -> Json {
  match self.memory {
    Some(m) => m.kept_json(ws).unwrap_or(Json::null())
    None => Json::null()
  }
}

///|
async fn P53Share::level_now(self : P53Share) -> Unit {
  match self.memory {
    Some(m) => m.level_now()
    None => ()
  }
}

///|
fn P53Share::reaches(self : P53Share, target : String, ws : String?) -> Bool {
  match (self.shares, ws) {
    (Some(s), Some(w)) => s.reaches(target, w)
    _ => false
  }
}

///|
async fn P53Share::close(self : P53Share) -> Unit {
  match self.memory {
    Some(m) => m.stop()
    None => ()
  }
  match self.sharing {
    Some(s) => s.close()
    None => ()
  }
  match self.shares {
    Some(s) => s.close()
    None => ()
  }
  match self.index {
    Some(i) => i.close()
    None => ()
  }
}

///|
/// A directory's entries with their kinds (`fs.readdir` with types), none where it is not read.
async fn p53_readdir_types(host : @host.Host, dir : String) -> Array[(String, String)] {
  let listed = try { Ok(host.shell("fs.readdir", { "path": Json::string(dir), "types": Json::boolean(true) })) } catch { e => Err(e) }
  match listed {
    Ok((Array(entries), _)) =>
      entries.filter_map(e => match e {
        Array([String(n), String(k), ..]) => Some((n, k))
        Object(_) => Some((jtext_or_empty(e, "name"), jtext_or_empty(e, "kind")))
        String(n) => Some((n, ""))
        _ => None
      })
    _ => []
  }
}
