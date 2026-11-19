// The vault as a part of the station (station/src/vault/module.ts `VaultLive`) on the station's database: its store,
// the agents' requests for its secrets and the grants they hold, sign-ins from a card (vault_service's `Vault`), its
// tools, its events (`vault-request`, `vault-plain`), its requests of the other stations (`vault.`), and what it holds
// only in memory carried over to the next process at a handover (`carry("vault")`). Its routes are api_routes's
// (vault.mbt), which ask what is answered here by name (`p54_vault_ask`, through the bus's `ui_ask`).
//
// What the vault asks of the agents' side (a post in a chat, a notice, the identity a session speaks with) is the
// hub's: asked through the bus (`hub_ask`, P5-2's). The chats' thread entries (a card kept, withdrawn, restated) are
// the store's, written here on the station's database (store_threads), each change told to the store's listeners.

///|
/// What the control plane says of the workspaces (P5-1's `cloud_call`): the locks pinned and the memberships, kept
/// here as last told, for what asks them at once (the vault's `lock`, its `peer`).
priv struct P54Cloud {
  locks : Map[String, Json]
  mut memberships : Array[Json]
  /// Each workspace not in security mode: the lock its vault goes by, its members' own locks as one
  /// (cloud/vault-lock.ts), as made last (`p54_personal_lock`).
  personal : Map[String, Json]
  /// Who asked the vault of each workspace here (vault/module.ts `lock`'s `viewer`), by sub: their email.
  viewers : Map[String, Map[String, String]]
  /// The vault's records of a workspace (its vaults, its box certificates) and its check of a box certificate against
  /// a lock: the vault's part's, once it is made.
  held : Ref[((String) -> (Array[Json], Array[Json]))?]
  cert_ok : Ref[((Json, Json) -> Bool)?]
}

///|
fn P54Cloud::new() -> P54Cloud {
  { locks: Map([]), memberships: [], personal: Map([]), viewers: Map([]), held: Ref(None), cert_ok: Ref(None) }
}

///|
/// Whether `ws` is the home workspace or one this station is in.
fn P54Cloud::has(self : P54Cloud, bus : LiveBus, ws : String) -> Bool {
  bus_home(bus) == Some(ws) || self.memberships.iter().any(m => jtext(m, "workspace") == Some(ws))
}

///|
/// The members of `ws` whose devices came to this station (mesh/seen-devices.json, the gate's), by sub: their email,
/// as they said it last.
fn p54_seen_members(bus : LiveBus, ws : String) -> Map[String, String] {
  let out : Map[String, (String, Double)] = Map([])
  let rows = match read_text(path([bus.data, "mesh", "seen-devices.json"])).bind(@cloud_lock.parse) {
    Some(Array(a)) => a
    _ => []
  }
  for r in rows {
    guard jtext(r, "workspace") == Some(ws) else { continue }
    guard jtext(r, "sub") is Some(sub) && jtext(r, "email") is Some(email) && email != "" else { continue }
    let at = match r {
      { "last_seen": Number(n, ..), .. } => n
      _ => 0.0
    }
    match out.get(sub) {
      Some((_, had)) if had > at => ()
      _ => out[sub] = (email, at)
    }
  }
  let said : Map[String, String] = Map([])
  for sub, v in out {
    said[sub] = v.0
  }
  said
}

///|
/// The lock `ws`'s vault goes by where it is not in security mode (Cloud `vaultLock`), made again of the person logs
/// the control plane keeps, the members known and the vault's records; None where it is in security mode or this
/// station is not in it.
async fn p54_personal_lock(bus : LiveBus, c : P54Cloud, ws : String) -> Json? {
  if c.locks.contains(ws) || !c.has(bus, ws) {
    c.personal.remove(ws)
    return None
  }
  let chains : Array[(String, Array[Json])] = match (try { Ok((bus.cloud_call.val)("personChains", Json::null())) } catch { e => Err(e) }) {
    Ok(Array(a)) =>
      a.filter_map(p => match p {
        Array([String(g), Array(ch)]) => Some((g, ch))
        _ => None
      })
    _ => []
  }
  let emails = p54_seen_members(bus, ws)
  for sub, e in c.viewers.get(ws).unwrap_or(Map([])) {
    emails[sub] = e
  }
  let (vaults, boxes) = match c.held.val {
    Some(f) => f(ws)
    None => ([], [])
  }
  let cert_ok = c.cert_ok.val.unwrap_or((_, _) => false)
  let lock = @cloud_lock.personal_vault_lock(@cloud_lock.Crypto::of_host(bus.host), ws, chains, emails, vaults, boxes, cert_ok)
  c.personal[ws] = lock
  Some(lock)
}

///|
fn P54Cloud::lock(self : P54Cloud, ws : String) -> Json? {
  match self.locks.get(ws) {
    Some(Object(_) as l) => Some(l)
    _ => None
  }
}

///|
/// The locks and memberships asked again of the control plane (at the start and as its state changes).
async fn p54_cloud_refresh(bus : LiveBus, c : P54Cloud) -> Unit {
  let home = bus_home(bus)
  let ms = match (try { Ok((bus.cloud_call.val)("memberships", Json::null())) } catch { e => Err(e) }) {
    Ok(Array(a)) => a
    _ => []
  }
  c.memberships = ms
  let wss : Array[String] = []
  if home is Some(h) { wss.push(h) }
  for m in ms {
    match jtext(m, "workspace") {
      Some(w) if !wss.contains(w) => wss.push(w)
      _ => ()
    }
  }
  for w in wss {
    let ask = if Some(w) == home { Json::null() } else { Json::string(w) }
    match (try { Ok((bus.cloud_call.val)("locked", { "workspace": ask })) } catch { e => Err(e) }) {
      // (the lock's state in force, as vault/module.ts `lock` takes `cloud.locked(ws)?.state`)
      Ok({ "state": Object(_) as st, .. }) => c.locks[w] = st
      _ => c.locks.remove(w)
    }
    ignore(p54_personal_lock(bus, c, w))
  }
}

///|
/// A station's name among the workspaces' (peer-http.ts `nameOf`): its id where none is said.
fn P54Cloud::station_name(self : P54Cloud, id : String) -> String {
  for m in self.memberships {
    match opt_field(Some(m), "peers") {
      Some(Array(ps)) =>
        for p in ps {
          if jtext(p, "id") == Some(id) {
            match jtext(p, "name") {
              Some(n) if n != "" => return n
              _ => ()
            }
          }
        }
      _ => ()
    }
  }
  id
}

///|
/// A member's name by their email, where the workspaces' rosters say one.
fn P54Cloud::person_name(self : P54Cloud, email : String) -> String? {
  let lower = email.to_lower()
  for m in self.memberships {
    match opt_field(Some(m), "members") {
      Some(Array(ms)) =>
        for p in ms {
          if jtext(p, "email").map(e => e.to_lower()) == Some(lower) {
            match jtext(p, "name") {
              Some(n) if n != "" => return Some(n)
              _ => ()
            }
          }
        }
      _ => ()
    }
  }
  None
}

///|
/// A station of the workspaces by id or name (peer-http.ts `peerNamed`): None for this station.
fn P54Cloud::peer(self : P54Cloud, bus : LiveBus, given : String) -> @vault_service.Peer? raise {
  let own = bus_station_id_opt(bus)
  let lower = given.to_lower()
  if Some(given) == own || self.memberships.iter().any(m => jtext(m, "name").map(n => n.to_lower()) == Some(lower)) {
    return None
  }
  let found : Array[(String, String)] = []
  for m in self.memberships {
    match opt_field(Some(m), "peers") {
      Some(Array(ps)) =>
        for p in ps {
          let id = jtext(p, "id").unwrap_or("")
          let name = jtext(p, "name").unwrap_or("")
          if id != "" && (id == given || name.to_lower() == lower) && !found.iter().any(f => f.0 == id) {
            found.push((id, if name == "" { id } else { name }))
          }
        }
      _ => ()
    }
  }
  match found {
    [] => raise Failure("no station \{given} in this station's workspaces")
    [one] => Some({ id: one.0, name: one.1 })
    _ => raise Failure("\{given} names \{found.length()} stations: give the id of the one meant")
  }
}

///|
/// The vault's store as it reads and writes the chats (secrets.ts `hub.store`).
fn p54_vault_store(bus : LiveBus, threads : @store_threads.Store) -> @vault_service.Store {
  let thread_of = (v : Json) => match v {
    Object(_) => @vault_service.Thread::of_json(v)
    _ => None
  }
  {
    get_session: k => match bus_session_row_opt(bus, k) {
      Some(row) =>
        Some({
          ws: bus_session_ws(bus, k),
          archived: opt_num(opt_field(Some(row), "archivedAt")) is Some(_),
        })
      None => None
    },
    starter: k => opt_str(Some(threads.starter(Json::string(k)) catch { _ => Json::null() })),
    participants: k => opt_strs(Some(threads.participants(Json::string(k)) catch { _ => Json::null() })),
    latest_thread: k => {
      let t = thread_of(threads.latest_thread(Json::string(k)) catch { _ => Json::null() })
      bus.drain_thread_requests(threads)
      t
    },
    latest_thread_if_ready: Some(k => {
      let v = threads.latest_thread_if_ready(Json::string(k)) catch { _ => Json::null() }
      bus.drain_thread_requests(threads)
      match v {
        Object(m) if m.get("ready") is Some(False) => None
        v => Some(thread_of(v))
      }
    }),
    session_thread_by_id: (k, id) => thread_of(
      threads.session_thread_by_id(Json::string(k), Json::number(id.to_double())) catch {
        _ => Json::null()
      },
    ),
    pending_card_header: id => opt_str(Some(threads.pending_card_header(Json::number(id.to_double())) catch { _ => Json::null() })),
    pending_card_header_if_ready: None,
    insert_message: (m, before) => {
      let got = threads.insert_message(to_jv(m), before~)
      told_threads(bus, threads)
      match got {
        Array([Number(n, ..), ..]) => n.to_int()
        Number(n, ..) => n.to_int()
        _ => 0
      }
    },
    withdraw_card: (session, thread, ts) => {
      let done = threads.withdraw_card(Json::string(session), Json::number(thread.to_double()), Json::string(ts)) catch {
        _ => Json::boolean(false)
      }
      told_threads(bus, threads)
      done is True
    },
    restate_card: (session, thread, ts, f) => {
      let done = threads.restate_card(Json::string(session), Json::number(thread.to_double()), Json::string(ts), card => to_jv(
        f(card.map(of_jv)),
      )) catch {
        _ => Json::boolean(false)
      }
      told_threads(bus, threads)
      done is True
    },
  }
}

///|
/// The machine as the vault asks it (vault_service machine.mbt): files, a command run with its output as it comes, a
/// shell for a command, random bytes. The keys, TLS and the proxy's listening are the shell's primitives the station's
/// shell does not have yet: refused, saying so, where a secret's use needs them.
fn p54_vault_machine(bus : LiveBus) -> @vault_service.Machine {
  let host = bus.host
  let crypto = @vault_crypto.Crypto::of_host(host)
  let keys = p54_key_ops(host)
  let proxy_stop : Ref[() -> Unit] = Ref(() => ())
  let lacking = (what : String) => Failure(
    "this station cannot \{what} yet: the program's shell has no such primitive (a secret used by the proxy or as an SSH key needs it)",
  )
  {
    temp_dir: async fn(prefix) {
      let dir = path([tmpdir(), prefix + @drive.hex(@drive.random_bytes(6))])
      @drive.mkdir(dir, true, mode=0o700)
      dir
    },
    remove: async fn(p) { @drive.rm_force(p) },
    chmod: async fn(p, mode) {
      ignore(host.shell("fs.chmod", { "path": Json::string(p), "mode": Json::number(mode.to_double()) })) catch {
        _ => ()
      }
    },
    write_file: async fn(p, b, mode) {
      host.write_atomic(p, b, mode~, sync=true, mkdir=true, sep=sep())
      if mode != 0o600 {
        ignore(host.shell("fs.chmod", { "path": Json::string(p), "mode": Json::number(mode.to_double()) })) catch {
          _ => ()
        }
      }
    },
    read_file: async fn(p) { host.read_bytes(p) catch { _ => None } },
    mkdir: async fn(p, mode) { @drive.mkdir(p, true, mode~) },
    shell_for: async fn(_env) {
      if is_windows() {
        "powershell.exe"
      } else {
        match env_get("SHELL") {
          Some(s) if s != "" => s
          _ => "/bin/sh"
        }
      }
    },
    spawn: async fn(s) {
      let ended : @effect.Deferred[(Int?, String?)] = @effect.Deferred::new()
      let child = p54_spawn(
        host,
        s.shell,
        s.args,
        env=s.env,
        cwd=s.cwd,
        stdin_piped=false,
        group=true,
        out=s.on_out,
        err=s.on_err,
        close=(code, signal) => ignore(ended.succeed((code, signal))),
      ) catch {
        e => return { code: None, signal: None, timed_out: false, error: Some(p54_message(e)) }
      }
      let ms = if s.timeout_ms > 0.0 && s.timeout_ms < 2147483647.0 { s.timeout_ms.to_int() } else { 2147483647 }
      match @effect.timeout(ms, async fn() { ended.wait() }) {
        Some((code, signal)) => { code, signal, timed_out: false, error: None }
        None => {
          ignore(kill(child.proc.pid, "SIGKILL", group=true))
          let (code, signal) = ended.wait()
          { code, signal, timed_out: true, error: None }
        }
      }
    },
    p256_new: keys.0,
    key_of_pem: keys.1,
    ed25519_of_seed: keys.2,
    rsa_of_jwk: keys.3,
    key_pem: keys.4,
    sign: keys.5,
    sha1: keys.6,
    roots: async fn() { p54_roots(host) },
    tls_context: async fn(key, chain) { p54_tls_context(host, key, chain) },
    proxy_listen: async fn(connect, forward) { p54_proxy_listen(host, proxy_stop, connect, forward) },
    proxy_close: () => {
      (proxy_stop.val)()
      proxy_stop.val = () => ()
    },
    unix_serve: async fn(path, answer) { p54_unix_serve(host, path, answer) },
    random: n => crypto.random(n) catch { _ => @drive.random_bytes(n) },
  }
}

///|
/// What the vault's part is in this process: the vault, its store's own connection, the cloud's locks as last told.
priv struct P54Vault {
  vault : @vault_service.Vault
  world : @vault_service.World
  crypto : @vault_crypto.Crypto
  db : @vault_crypto.Db
  cloud : P54Cloud
  bus : LiveBus
}

///|
/// The vault made and its part said (module.ts `VaultLive`).
async fn p54_vault_start(bus : LiveBus, cloud : P54Cloud, threads : @store_threads.Store) -> P54Vault {
  let host = bus.host
  let crypto = @vault_crypto.Crypto::of_host(host)
  let db_path = path([bus.data, "stillfail.db"])
  let db = @vault_crypto.Db::attach(crypto, db_path, wait=5000)
  let world = p54_vault_world(bus, cloud, threads, crypto, Some(db))
  p54_vault_live(bus, cloud, world, crypto, db)
}

///|
/// What the vault asks of the station (vault/module.ts's deps): its chats' store, the hub, the machine, the mesh. With
/// the vault's own connection (`db`), a decided card's outcome is queued for the agents' side's worker; a rig, which
/// keeps no cards, has none.
fn p54_vault_world(
  bus : LiveBus,
  cloud : P54Cloud,
  threads : @store_threads.Store,
  crypto : @vault_crypto.Crypto,
  db : @vault_crypto.Db?,
) -> @vault_service.World {
  let host = bus.host
  let db_path = path([bus.data, "stillfail.db"])
  let previous_gone = match bus.previous_pid {
    Some(_) => Some(bus.previous_gone)
    None => None
  }
  let hub_ask = async fn(op : String, args : Json) -> Json { (bus.hub_ask.val)(op, args) }
  let fork = (name : String, f : async () -> Unit) => ignore(host.rt.fork_quiet(name~, async fn() { f() catch { _ => () } }))
  ({
    hub: {
      store: p54_vault_store(bus, threads),
      prepare_latest_threads: Some(async fn(keys) { ignore(hub_ask("store.prepareLatestThreads", [Json::array(keys.map(Json::string))])) }),
      prepare_card_posts: Some(async fn(threads) {
        ignore(hub_ask("hub.prepareCardPosts", [Json::array(threads.map(t => Json::number(t.to_double())))]))
      }),
      post: async fn(connect, channel, thread_ts, text) {
        match hub_ask("hub.post", [Json::string(connect), Json::string(channel), Json::string(thread_ts), Json::string(text)]) {
          String(ts) => ts
          Object(_) as got => jtext(got, "ts").unwrap_or("")
          _ => raise Failure("the chat's post was not said (the agents' side is not up)")
        }
      },
      shared: (thread, n, session, text) => fork("vault shared", async fn() {
        ignore(
          hub_ask("hub.shared", [
            Json::number(thread.to_double()),
            Json::number(n.to_double()),
            Json::string(session),
            Json::string(text),
          ]),
        )
      }),
      notify: (session, text) => {
        if bus_session_row_opt(bus, session) is None {
          raise Failure("no session \{session}")
        }
        fork("vault notify", async fn() { ignore(hub_ask("hub.notify", [Json::string(session), Json::string(text)])) })
      },
      // (card-place.ts `postCard`'s `hub.actors.get(session)?.messageIdentity()`: none where the actor is not up)
      identity: async fn(session) {
        let got = hub_ask("hub.identity", [Json::string(session)]) catch { _ => Json::null() }
        match got {
          Null => None
          // (JavaScript's undefined as the bus carries it: session_chats `is_undefined`)
          Object(m) if m.size() == 1 && m.contains("$u") => None
          other => Some(other)
        }
      },
    },
    card_outcomes: db.map(db => p54_vault_outcomes(bus, threads, db)),
    home: () => bus_home(bus),
    title: Some(session => opt_text(bus_session_row_opt(bus, session), "title")),
    title_if_ready: None,
    data: bus.data,
    lock: ws => {
      let w = match ws {
        Some(w) => Some(w)
        None => bus_home(bus)
      }
      match w {
        // (its lock in force in security mode, else its members' own as made last)
        Some(x) =>
          match cloud.lock(x) {
            Some(l) => Some(@vault_service.Lock::of_json(l))
            None => cloud.personal.get(x).map(@vault_service.Lock::of_json)
          }
        None => None
      }
    },
    now: () => wall_ms().to_double(),
    after: (ms, f) => bus_after(host, ms, f),
    sleep: async fn(ms) { @effect.sleep(if ms < 0.0 { 0 } else { ms.to_int() }) },
    peer: Some(given => cloud.peer(bus, given)),
    ask: Some(async fn(station, request) {
      let meth = jtext(request, "method").unwrap_or("")
      let (answer, _) = bus.call_peer(station, None, meth, request)
      answer
    }),
    work_of: Some((ws, peer, session) => path([bus.data, "remote", ws, peer, session])),
    coming: None,
    previous: { gone: previous_gone },
    browsers: Some({
      cookies: async fn(session, sites, station) {
        opt_str(Some((bus.ui_ask.val)("browser.cookies", [Json::string(session), Json::array(sites.map(Json::string)), Json::boolean(station)]))).unwrap_or(
          "",
        )
      },
      passkeys_in: Some(async fn(session, d) { ignore((bus.ui_ask.val)("browser.passkeysIn", [Json::string(session), d])) }),
      sign_in: async fn(session, d) { ignore((bus.ui_ask.val)("browser.signIn", [Json::string(session), d])) },
      extend_sign_in: Some((session, request, until) => fork("vault extend", async fn() {
        ignore((bus.ui_ask.val)("browser.extendSignIn", [Json::string(session), Json::string(request), Json::number(until)]))
      })),
    }),
    machine: p54_vault_machine(bus),
    hold: () => () => (),
    log: (level, part, said, about) => slice_log(level, part, said, about),
    random: n => crypto.random(n) catch { _ => @drive.random_bytes(n) },
    env: () => env_all(),
    index_db: Some(() => @sql.Db::attach(host, db_path, wait=5000)),
    backfill_take: () => true,
    backfill_give: () => (),
    foreground: _ => (),
  } : @vault_service.World)
}

///|
/// The vault made on its world and its part said (module.ts `VaultLive`).
async fn p54_vault_live(
  bus : LiveBus,
  cloud : P54Cloud,
  world : @vault_service.World,
  crypto : @vault_crypto.Crypto,
  db : @vault_crypto.Db,
) -> P54Vault {
  let host = bus.host
  let fork = (name : String, f : async () -> Unit) => ignore(host.rt.fork_quiet(name~, async fn() { f() catch { _ => () } }))
  let vault = @vault_service.Vault::new(world, db, crypto, {
    tell: (ev, data, key, to) => (bus.events_tell.val)(ev, data, key, to),
    tabs: session => p54_browser_tabs(session),
    look: async fn(session, tab) { (bus.ui_ask.val)("browser.look", [Json::string(session), Json::string(tab)]) },
    drive: async fn(session, tab, site, values, used) {
      (bus.ui_ask.val)("browser.drive", [
        Json::string(session),
        Json::string(tab),
        Json::string(site),
        values,
        Json::array(used.keys().map(Json::string).collect()),
      ])
    },
    screen_link: tab => match (bus_home(bus), bus_station_id_opt(bus), (bus.cloud_state.val)()) {
      (Some(ws), Some(station), Some(s)) =>
        match jtext(s, "origin") {
          Some(origin) => Some("\{origin}/w/\{ws}/s/\{station}/screen/\{@drive.encode_uri("browser:" + tab)}")
          None => None
        }
      _ => None
    },
    session_ws: session => bus_session_ws(bus, session),
    session_dir: session => bus_session_dir(bus, session),
    join_path: (a, b) => path([a, b]),
    signin_id: None,
    passkeys_again_all: () => fork("vault passkeys", async fn() { ignore((bus.ui_ask.val)("browser.passkeysAgain", [])) }),
  })
  // The grants, the boxes of requests waiting and the secrets to keep, only in memory: over to the next process at a
  // handover (an update), so no agent asks again.
  bus.parts.carry("vault", async fn() { vault.carried() }, what => vault.carry(what))
  // (vault/module.ts `readers.onTrim`: the use index's reader let go short of memory)
  bus.on_trim(() => vault.secrets.trim_idle())
  // Another station's requests (`vault.`): a command run here with a secret, a secret read here.
  bus.on_peer_prefix("vault.", async fn(peer, ws, meth, params, _bytes) {
    let request = match params {
      Object(m) => {
        let c = m.copy()
        if !c.contains("method") {
          c["method"] = Json::string(meth)
        }
        Json::object(c)
      }
      _ => { "method": Json::string(meth) }
    }
    (vault.heard(world, peer, ws, request), None)
  })
  // A session's chat changed or gone: what waits for it let go.
  ignore(bus.subscribe_store(change => match jtext(change, "session") {
    Some(k) => vault.session_changed(k)
    None => ()
  }))
  bus.parts.tools(
    vault.tools.map(t => {
      let declared : Json = {
        "name": Json::string(t.name),
        "description": Json::string(t.description),
        "inputSchema": t.input_schema,
      }
      ({
        name: t.name,
        declared,
        call: async fn(args, context) {
          let session = p54_session(context)
          match (try { Ok((t.run)(session, args, None)) } catch { e => Err(e) }) {
            Ok(text) => tool_answer(text)
            Err(e) => tool_answer(@vault_service.message_of(e), error=true)
          }
        },
      } : PartTool)
    }),
  )
  // (vault/module.ts: whether a viewer may follow a vault's events, their workspace's or their own)
  match live_events.val {
    Some(events) =>
      events.follow(in_vault=(viewer, id) => vault.secrets.in_vault(viewer.sub, viewer.workspace, id) catch { _ => false })
    None => ()
  }
  // (the lock of a workspace not in security mode is made of the vault's records too: p54_personal_lock)
  cloud.held.val = Some(ws => {
    let vs = vault.vaults.vaults(ws) catch { _ => [] }
    let bs = vault.vaults.boxes(ws) catch { _ => [] }
    (vs, bs)
  })
  cloud.cert_ok.val = Some((lock, cert) => @vault_crypto.cert_ok(crypto, @vault_crypto.lock_view(lock), Some(cert)) is None)
  { vault, world, crypto, db, cloud, bus }
}

///|
/// The browser's tabs of a chat, as the browsers' part last listed them (set as it is made).
let p54_browser_tabs_ref : Ref[(String) -> Array[(String, String)]] = Ref(_ => [])

///|
fn p54_browser_tabs(session : String) -> Array[(String, String)] {
  (p54_browser_tabs_ref.val)(session)
}

///|
fn p54_viewer_sub(v : Json?) -> String {
  opt_text(v, "sub").unwrap_or("")
}

///|
fn p54_viewer_email(v : Json?) -> String {
  opt_text(v, "email").unwrap_or("")
}

///|
fn p54_lock_arg(v : Json?) -> @vault_service.Lock? {
  match v {
    Some(Object(_) as l) => Some(@vault_service.Lock::of_json(l))
    _ => None
  }
}

///|
fn p54_result(r : Result[Json, String]) -> Json {
  match r {
    Ok(v) => v
    Err(why) => Json::string(why)
  }
}


///|
fn p54_opt_json(v : Json?) -> Json {
  v.unwrap_or(Json::null())
}

///|
/// What the admin API's vault routes ask of the vault (api_routes vault.mbt's `vaults.`, `vault/crypto.`, `secrets.`,
/// `secrets.plain.`, `vault.`, `signIns.`), by name and its arguments; None where `op` is not the vault's.
async fn p54_vault_ask(v : P54Vault, op : String, a : Json) -> Json? {
  let vaults = v.vault.vaults
  let secrets = v.vault.secrets
  let plain = secrets.plain
  let s = (i : Int) => call_arg_text(a, i)
  let j = (i : Int) => call_arg(a, i).unwrap_or(Json::null())
  let lv = (i : Int) => @vault_crypto.lock_view(j(i))
  let some = (x : Json) => match x {
    Null => None
    Object(m) if m.contains("$undef") => None
    v => Some(v)
  }
  let answer : Json = match op {
    // the lock pinned in a workspace (null: none), the write gate, a certificate's boxes
    "vault.lock" => {
      let ws = opt_str(some(j(0)))
      // (who asks is known by its members' own locks from then on: vault/module.ts `lock`'s `viewer`)
      match (ws, some(j(1))) {
        (Some(w), Some(viewer)) =>
          match (jtext(viewer, "sub"), jtext(viewer, "email")) {
            (Some(sub), Some(email)) if sub != "" && email != "" => {
              let of = match v.cloud.viewers.get(w) {
                Some(m) => m
                None => {
                  let m = Map([])
                  v.cloud.viewers[w] = m
                  m
                }
              }
              of[sub] = email.to_lower()
            }
            _ => ()
          }
        _ => ()
      }
      let w = match ws {
        Some(x) => Some(x)
        None => bus_home(v.bus)
      }
      match w {
        Some(x) if !v.cloud.locks.contains(x) => ignore(p54_personal_lock(v.bus, v.cloud, x))
        _ => ()
      }
      match (v.world.lock)(ws) {
        Some(l) => l.json
        None => Json::null()
      }
    }
    "vault.beforeWrite" =>
      match v.vault.writes.wait() {
        None => Json::boolean(true)
        Some(None) => Json::boolean(false)
        Some(Some(d)) => Json::boolean(d.wait())
      }
    "vault.boxed" => Json::boolean(secrets.boxed(@vault_service.Lock::of_json(j(0)), j(1)))
    "vault/store.isDeletedVaultWrite" => Json::boolean(opt_text(Some(j(0)), "message").map(m => m.contains("deleted")).unwrap_or(false))
    "vault/plain.plainOk" => jopt(@vault_crypto.plain_ok(some(j(0)), j(1), s(2)))
    "vault/plain.shown" => @vault_crypto.shown(j(0))
    // the vaults, items and boxes kept here (store.ts)
    "vaults.vault" => p54_opt_json(vaults.vault(s(0), s(1)))
    "vaults.vaultSnapshot" => @vault_crypto.snapshot_json(vaults.vault_snapshot(s(0), s(1)))
    "vaults.memberVaults" => Json::array(vaults.member_vaults(s(0), s(1)))
    "vaults.items" => Json::array(vaults.items(s(0), s(1)))
    "vaults.itemSnapshot" => @vault_crypto.snapshot_json(vaults.item_snapshot(s(0), s(1), s(2)))
    "vaults.boxes" => Json::array(vaults.boxes(s(0)))
    "vaults.boxesFor" => Json::array(vaults.boxes_for(s(0), opt_strs(Some(j(1)))))
    "vaults.boxSnapshot" => @vault_crypto.snapshot_json(vaults.box_snapshot(s(0), s(1)))
    "vaults.putVaultIf" => Json::boolean(vaults.put_vault_if(j(0), opt_str(some(j(1)))))
    "vaults.putItemIf" => Json::boolean(vaults.put_item_if(j(0), s(1), opt_str(some(j(2)))))
    "vaults.putBoxIf" => Json::boolean(vaults.put_box_if(j(0), opt_str(some(j(1)))))
    // the checks of what a member's device signed (vault/crypto.ts)
    "vault/crypto.signedOk" => Json::boolean(@vault_crypto.signed_ok(v.crypto, j(0), s(1)))
    "vault/crypto.signerOf" =>
      match @vault_crypto.signer_of(lv(0), s(1)) {
        Some((sub, device)) => { "sub": Json::string(sub), "device": Json::string(device) }
        None => Json::null()
      }
    "vault/crypto.vaultSupersedes" => Json::boolean(@vault_crypto.vault_supersedes(j(0), j(1)))
    "vault/crypto.itemSupersedes" => Json::boolean(@vault_crypto.item_supersedes(j(0), j(1)))
    "vault/crypto.vaultOk" => jopt(@vault_crypto.vault_ok(v.crypto, lv(0), some(j(1)), j(2), copy=opt_true(call_arg(a, 3))))
    "vault/crypto.itemOk" => jopt(@vault_crypto.item_ok(v.crypto, lv(0), j(1), some(j(2)), j(3), copy=opt_true(call_arg(a, 4))))
    "vault/crypto.certOk" => jopt(@vault_crypto.cert_ok(v.crypto, lv(0), some(j(1))))
    // the agents' requests and what members decide of them (vault-requests.ts)
    "secrets.preparePending" => {
      secrets.prepare_pending(s(0), members=opt_true(call_arg(a, 1)))
      Json::null()
    }
    "secrets.pending" =>
      Json::array(secrets.pending(s(0), p54_lock_arg(some(j(1))), p54_viewer_sub(some(j(2))), p54_viewer_email(some(j(2)))))
    "secrets.uses" =>
      Json::array(secrets.uses(s(0), p54_lock_arg(some(j(1))), s(2), p54_viewer_sub(some(j(3))), p54_viewer_email(some(j(3)))))
    "secrets.grantPlain" => jopt(secrets.grant_plain(s(0), p54_lock_arg(some(j(1))), s(2), j(3)))
    "secrets.denyPlain" => jopt(secrets.deny_plain(s(0), s(1), j(2)))
    "secrets.describedPlain" => p54_result(secrets.described_plain(s(0), p54_lock_arg(some(j(1))), s(2), j(3)))
    "secrets.removedPlain" => p54_result(secrets.removed_plain(s(0), s(1), j(2)))
    "secrets.savedPlain" => p54_result(secrets.saved_plain(s(0), p54_lock_arg(some(j(1))), s(2), j(3)))
    "secrets.grant" => jopt(secrets.grant(@vault_service.Lock::of_json(j(0)), s(1), j(2)))
    "secrets.deny" => jopt(secrets.deny(@vault_service.Lock::of_json(j(0)), s(1), j(2), email?=opt_str(some(j(3)))))
    "secrets.saved" => jopt(secrets.saved(@vault_service.Lock::of_json(j(0)), s(1), j(2)))
    "secrets.described" => jopt(secrets.described(@vault_service.Lock::of_json(j(0)), s(1), j(2)))
    "secrets.removed" => jopt(secrets.removed(@vault_service.Lock::of_json(j(0)), s(1), j(2)))
    "secrets.inVault" => Json::boolean(secrets.in_vault(s(0), s(1), s(2)))
    "secrets.status" => Json::string(secrets.status(s(0)))
    "secrets.plain.items" => Json::array(plain.items(s(0), s(1)))
    "secrets.plain.item" => p54_opt_json(plain.item(s(0), s(1)))
    "secrets.plain.lasts" =>
      match plain.lasts(s(0), s(1)) {
        Some((lasts, at)) => { "lasts": lasts, "at": at }
        None => Json::null()
      }
    "secrets.plain.setLasts" => jopt(plain.set_lasts(s(0), s(1), some(j(2)), some(j(3))))
    "secrets.plain.put" => {
      plain.put(j(0))
      Json::null()
    }
    "secrets.plain.forget" => {
      plain.forget(s(0), s(1))
      Json::null()
    }
    // the moves' vault module (move/live.ts `vault`): an owner's rows sent as they are, taken out on a move back
    "vaults.vaults" => Json::array(vaults.vaults(s(0)))
    "vaults.item" => p54_opt_json(vaults.item(s(0), s(1), s(2)))
    "vaults.putVault" => {
      vaults.put_vault(j(0))
      Json::null()
    }
    "vaults.putItem" => {
      vaults.put_item(j(0))
      Json::null()
    }
    "vaults.forgetItem" => {
      vaults.forget_item(s(0), s(1), s(2))
      Json::null()
    }
    "vaults.forgetVault" => {
      vaults.forget_vault(s(0), s(1))
      Json::null()
    }
    // (move/live.ts `vault.owners`: whose plain items and vaults a workspace keeps here)
    "vault.moveOwners" => {
      let out : Array[String] = []
      for r in v.db.all("SELECT DISTINCT owner FROM vault_plain WHERE ws = ? LIMIT 500", [Json::string(s(0))]) {
        if r.get(0) is Some(String(o)) && !out.contains(o) {
          out.push(o)
        }
      }
      for x in vaults.vaults(s(0)) {
        if x is { "owner": String(o), .. } && !out.contains(o) {
          out.push(o)
        }
      }
      Json::array(out.map(Json::string(_)))
    }
    // (move/live.ts `vault.grantOwners`: each session's owners, of the grants it holds: one read for a page of chats)
    "vault.moveGrantOwners" => {
      let keys = opt_strs(Some(j(0)))
      let out : Map[String, Json] = {}
      let rows = v.db.all(
        "SELECT session, body FROM vault_grants WHERE session IN (SELECT value FROM json_each(?)) ORDER BY session, rowid LIMIT ?",
        [Json::string(Json::array(keys.map(Json::string(_))).stringify()), Json::number((keys.length() * 50).to_double())],
      )
      for r in rows {
        guard r.get(0) is Some(String(session)) && r.get(1) is Some(String(body)) else { continue }
        let owner = match (try Some(@json.parse(body)) catch { _ => None }) {
          Some({ "request": { "owner": String(o), .. }, .. }) => Some(o)
          _ => None
        }
        guard owner is Some(o) else { continue }
        let list = match out.get(session) {
          Some(Array(l)) => l
          _ => []
        }
        if !list.contains(Json::string(o)) {
          list.push(Json::string(o))
        }
        out[session] = Json::array(list)
      }
      Json::object(out)
    }
    // a sign-in from a card (signin.ts), by the member who has it: [email, workspace, id, …]
    "signIns.fill" => jopt(v.vault.sign_ins.fill(s(0), s(1), s(2), j(3)))
    "signIns.self" => jopt(v.vault.sign_ins.self_(s(0), s(1), s(2), opt_true(call_arg(a, 3))))
    "signIns.deny" => jopt(v.vault.sign_ins.deny(s(0), s(1), s(2)))
    "signIns.get" => p54_opt_json(v.vault.sign_ins.get(s(0)))
    // the members' event streams: whether a viewer is a vault's member (events.follow `inVault`)
    "vault.carried" => v.vault.carried()
    // (a test's, through its door alone: the SSH agent and the proxy as a command with a secret has them)
    "test.sshAgent" if p54_testing() => {
      let key = @vault_service.parse_ssh_key(v.world.machine, s(0))
      ignore(@vault_service.serve_agent(v.world.machine, s(1), key, () => true))
      { "blob": Json::string(@drive.hex(key.blob)), "kind": Json::string(key.kind) }
    }
    "test.proxy" if p54_testing() => {
      let proxy = secrets.proxy
      ignore(proxy.start())
      let (url, _) = proxy.admit({
        hosts: opt_strs(call_arg(a, 0)),
        placeholder: s(1),
        value: s(2),
        used: _ => (),
        allowed: () => true,
      })
      { "url": Json::string(url), "bundle": Json::string(proxy.bundle()) }
    }
    _ => return None
  }
  // (a vault or a box certificate written where no workspace lock is pinned: the lock its vaults go by, made of its
  // members' own locks and named by its vaults' owners and members, made again: vault/module.ts `held.version`)
  let written = match op {
    "vaults.putVault" | "vaults.forgetVault" => true
    "vaults.putVaultIf" | "vaults.putBoxIf" => answer is True
    _ => false
  }
  if written {
    let w = if op == "vaults.forgetVault" { Some(s(0)) } else { opt_text(Some(j(0)), "ws") }
    match w {
      Some(x) if x != "" && !v.cloud.locks.contains(x) => ignore(p54_personal_lock(v.bus, v.cloud, x))
      _ => ()
    }
  }
  Some(answer)
}

///|
/// A Unix socket served at `path` (the SSH agent's): each connection's bytes given to `answer` as they come, what it
/// answers written back, the connection closed where it says so; what it gives stops it and removes the socket.
async fn p54_unix_serve(host : @host.Host, path : String, answer : async (Int, Bytes) -> (Bytes, Bool)) -> () -> Unit {
  @drive.rm_force(path)
  let id = host.unix_listen(path).id
  let stopped = Ref(false)
  let next = Ref(0)
  let conns : Map[Int, P54Conn] = Map([])
  fork_bg(host, "unix serve", async fn() {
    while @mesh_runtime.accept_through(closed=() => stopped.val, async fn() { host.accept(id) }) is Some(got) {
      next.val += 1
      let n = next.val
      let conn : P54Conn = { host, id: got.id, closed: false }
      conns[n] = conn
      fork_bg(host, "unix conn", async fn() {
        while conn.read() is Some(chunk) {
          let (reply, close) = answer(n, chunk) catch { _ => (b"", true) }
          if reply.length() > 0 {
            conn.write(reply) catch { _ => break }
          }
          if close { break }
        }
        conn.close()
        conns.remove(n)
      })
    }
  })
  () => {
    if stopped.val {
      return
    }
    stopped.val = true
    for _, c in conns {
      c.close()
    }
    fork_bg(host, "unix close", async fn() {
      host.listen_close(id)
      @drive.rm_force(path)
    })
  }
}

///|
/// The machine's roots of trust as PEM, for the proxy's bundle (beside its own CA): the system's file where there is
/// one, else what macOS's keychain or Windows' store gives, else none.
async fn p54_roots(host : @host.Host) -> Array[String] {
  let given : Array[String] = match env_get("SSL_CERT_FILE") {
    Some(f) if f != "" => [f]
    _ => []
  }
  let files = given + ["/etc/ssl/cert.pem", "/etc/ssl/certs/ca-certificates.crt", "/etc/pki/tls/certs/ca-bundle.crt", "/etc/ssl/ca-bundle.pem"]
  for f in files {
    match read_text(f) {
      Some(t) if t.contains("-----BEGIN CERTIFICATE-----") => return [t.trim().to_owned()]
      _ => ()
    }
  }
  if platform() == "darwin" {
    let (code, out, _) = run_cmd(host, "/usr/bin/security", [
      "find-certificate", "-a", "-p", "/System/Library/Keychains/SystemRootCertificates.keychain",
    ]) catch {
      _ => return []
    }
    if code == Some(0) && out.contains("-----BEGIN CERTIFICATE-----") {
      return [out.trim().to_owned()]
    }
  }
  if is_windows() {
    // (certutil writes the ROOT store's certificates, each its own file, into a folder of this process's)
    let dir = path([tmpdir(), "sf-roots-" + @drive.hex(@drive.random_bytes(4))])
    @drive.mkdir(dir, true)
    let (code, _, _) = run_cmd(host, "certutil", ["-split", "-store", "-silent", "Root"], cwd=dir) catch { _ => return [] }
    let out = []
    if code == Some(0) {
      for name in @drive.names(dir) catch { _ => [] } {
        if name.has_suffix(".crt") || name.has_suffix(".cer") {
          guard (host.read_bytes(path([dir, name])) catch { _ => None }) is Some(der) else { continue }
          out.push(p54_pem("CERTIFICATE", der).trim().to_owned())
        }
      }
    }
    ignore(host.shell("fs.remove", { "path": Json::string(dir), "recursive": Json::boolean(true) })) catch {
      _ => ()
    }
    return out
  }
  []
}

///|
/// The vault's proxy on 127.0.0.1 (vault/proxy.ts' server): a CONNECT whose credentials name a run decided by
/// `connect` (refused, carried through to its host as it is, or opened here with a leaf of the proxy's), each request
/// in one it opened decided by `forward`; anything else refused. Its port; `stop` set to what ends it.
async fn p54_proxy_listen(
  host : @host.Host,
  stop : Ref[() -> Unit],
  connect : async (@vault_service.ConnectAsk) -> @vault_service.ConnectDecision,
  forward : async (@vault_service.ForwardAsk) -> @vault_service.ForwardDecision,
) -> Int {
  let listening = host.tcp_listen_local(0)
  let id = listening.id
  let port = listening.port
  let stopped = Ref(false)
  stop.val = () => {
    if stopped.val {
      return
    }
    stopped.val = true
    fork_bg(host, "proxy close", async fn() {
      host.listen_close(id)
    })
  }
  fork_bg(host, "vault proxy", async fn() {
    while @mesh_runtime.accept_through(closed=() => stopped.val, async fn() { host.accept(id) }) is Some(got) {
      let conn : P54Conn = { host, id: got.id, closed: false }
      ignore(
        host.rt.fork_quiet(name="proxy connection", async fn() {
          p54_proxy_connection(host, conn, connect, forward) catch {
            _ => ()
          }
          conn.close()
        }),
      )
    }
  })
  port
}

///|
/// One connection to the proxy: its CONNECT read and decided.
async fn p54_proxy_connection(
  host : @host.Host,
  conn : P54Conn,
  connect : async (@vault_service.ConnectAsk) -> @vault_service.ConnectDecision,
  forward : async (@vault_service.ForwardAsk) -> @vault_service.ForwardDecision,
) -> Unit {
  let r : P54Reader = { read: async fn() { conn.read() }, buf: @buffer.new(), have: b"" }
  let mut head_end = -1
  while head_end < 0 {
    for i in 0..<(if r.have.length() >= 4 { r.have.length() - 3 } else { 0 }) {
      if r.have[i] == b'\r' && r.have[i + 1] == b'\n' && r.have[i + 2] == b'\r' && r.have[i + 3] == b'\n' {
        head_end = i
        break
      }
    }
    if head_end < 0 {
      guard (r.read)() is Some(more) else { return }
      r.have = p54_cat([r.have, more])
      if r.have.length() > 65536 {
        return
      }
    }
  }
  let head = @utf8.decode_lossy(p54_sub(r.have, 0, head_end))
  let rest = p54_sub(r.have, head_end + 4, r.have.length())
  let lines = head.split("\r\n").map(l => l.to_owned()).to_array()
  let first = lines[0].split(" ").map(x => x.to_owned()).to_array()
  if first.length() < 2 || first[0] != "CONNECT" {
    conn.write(@utf8.encode("HTTP/1.1 405 Method Not Allowed\r\nconnection: close\r\ncontent-length: 0\r\n\r\n"))
    return
  }
  let mut authorization : String? = None
  for l in lines[1:] {
    match l.find(":") {
      Some(i) if l[:i].to_owned().to_lower() == "proxy-authorization" => authorization = Some(l[i + 1:].to_owned().trim().to_owned())
      _ => ()
    }
  }
  match connect({ url: first[1], authorization }) {
    Refuse(raw) => conn.write(@utf8.encode(raw))
    Tunnel(to, port) => {
      let opened = try {
        if to == "127.0.0.1" || to == "localhost" {
          Ok(p54_wire_of_conn(p54_tcp_open(host, port)))
        } else {
          Ok(p54_wire_of_net(p54_net_tcp(host, to, port)))
        }
      } catch {
        e => Err(e)
      }
      guard opened is Ok(up) else {
        conn.write(@utf8.encode("HTTP/1.1 502 Bad Gateway\r\n\r\n"))
        return
      }
      conn.write(@utf8.encode("HTTP/1.1 200 Connection Established\r\n\r\n"))
      if rest.length() > 0 {
        (up.write)(rest)
      }
      let back = host.rt.fork(name="tunnel back", async fn() {
        while (up.read)() is Some(b) {
          conn.write(b) catch {
            _ => break
          }
        }
        host.tcp_end(conn.id) catch {
          _ => ()
        }
      })
      while conn.read() is Some(b) {
        (up.write)(b) catch {
          _ => break
        }
      }
      (up.end)()
      ignore(back.wait())
      (up.close)()
    }
    Open(to, port, context, run) => {
      conn.write(@utf8.encode("HTTP/1.1 200 Connection Established\r\n\r\n"))
      let carried : Ref[Bytes] = Ref(rest)
      p54_tls_serve(
        host,
        context,
        async fn() -> Bytes? {
          if carried.val.length() > 0 {
            let b = carried.val
            carried.val = b""
            return Some(b)
          }
          conn.read()
        },
        async fn(b) { conn.write(b) },
        async fn(read, write) { p54_http_inside(host, to, port, run, forward, read, write) },
      )
    }
  }
}

///|
/// Whether a test's door is open (`STILLFAIL_TEST_UI_ASK`): what only a test asks is answered then alone.
fn p54_testing() -> Bool {
  match env_get("STILLFAIL_TEST_UI_ASK") {
    Some(t) => t != ""
    None => false
  }
}

///|
/// secrets.ts and signin.ts `cardOutcomes`: a decided card's request written on the vault's own connection in its own
/// write, then its outcome queued on the chats' (the card closed there where asked, the close told), and the agents'
/// side's worker woken to restate it. Two connections, so two writes: one write would wait on the other's lock.
fn p54_vault_outcomes(bus : LiveBus, threads : @store_threads.Store, db : @vault_crypto.Db) -> @vault_service.CardOutcomes {
  {
    save: (item, tx) => {
      let nested = db.in_transaction()
      db.exec(if nested { "SAVEPOINT vault_outcome" } else { "BEGIN IMMEDIATE" })
      (fn() raise {
        tx()
        db.exec(if nested { "RELEASE vault_outcome" } else { "COMMIT" })
      })() catch {
        e => {
          db.exec(if nested { "ROLLBACK TO vault_outcome; RELEASE vault_outcome" } else { "ROLLBACK" }) catch {
            _ => ()
          }
          raise e
        }
      }
      // (the request is written: its card left as it is where its outcome is not queued, said, not undone)
      threads.set_now(wall_ms().to_double())
      ignore(threads.save_card_outcome(@store_threads.CardOutcome::from_json(to_jv(item)), () => ())) catch {
        e => slice_log("warn", "vault", "a card's outcome was not queued", { "error": Json::string(p54_message(e)) })
      }
      told_threads(bus, threads)
      ignore(
        bus.host.rt.fork_quiet(name="card outcome", async fn() {
          bus.hub_card_outcomes_wake() catch {
            _ => ()
          }
        }),
      )
    },
  }
}

///|
/// rig/main.ts `Incoming`: on a station that only runs tasks, a command another station sends to run here with a
/// secret one of its chats was granted (`vault.run`, `vault.capture`, `vault.revoke`, `vault.capabilities`), the
/// secret in no file; asked in the workspace the request says, else the station's home.
fn p54_rig_incoming(bus : LiveBus, cloud : P54Cloud, threads : @store_threads.Store) -> Unit {
  let crypto = @vault_crypto.Crypto::of_host(bus.host)
  let world = p54_vault_world(bus, cloud, threads, crypto, None)
  let runs = @vault_service.Incoming::new(
    world,
    @vault_service.Proxy::new(world.machine, path([bus.data, "vault"]), () => wall_ms().to_double()),
  )
  bus.on_peer_prefix("vault.", async fn(peer, ws, meth, params, _bytes) {
    let request = match params {
      Object(m) => {
        let c = m.copy()
        if !c.contains("method") {
          c["method"] = Json::string(meth)
        }
        Json::object(c)
      }
      _ => { "method": Json::string(meth) }
    }
    let workspace = match ws {
      Some(w) => w
      None => bus_home(bus).unwrap_or("")
    }
    (runs.heard(peer, workspace, request), None)
  })
}
