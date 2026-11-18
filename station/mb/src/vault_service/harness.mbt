// The vault's service asked line by line (reader `--builder harness-vault-service`), for
// station/test/mb-vault-service.test.ts to hold it to the TypeScript it is the MoonBit of (station/src/vault/): the same
// database, the same clock, the same requests, the same fakes, and what each says and writes compared.
//
// On stdin: `{"setup": {db, data, home, env, previous}}` (answered `{"ready": true}`); `{"state": {...}}` the fake
// store's sessions, starters, people, thread, locks, peers and work directory as the test's fake has them now;
// `{"clock": ms}` the clock moved there, its timers due run (answered `{"clocked": ms}`); `{"fn": {id, name, args}}`
// one function of the package (answered `{"ans": id, "value" | "error": {kind, message}, "effects": [...]}`); and
// `{"ret": n, "value" | "throw": {message}}`, `{"chunk": n, "stream", "hex"}` the test's answers to what the program
// asked it (`{"call": n, "name", "args"}`: a post's browser, another station, the machine).
//
// The fake store is the test's (test/mb-vault-service.test.ts `FakeHub`), written again here: a session, its starter
// and people, one thread, the cards posted in it; what it is told (a card withdrawn or restated, a notice, an event) is
// the answer's `effects`, as the TypeScript's fake records them.

///|
priv struct HTimer {
  due : Double
  seq : Int
  f : () -> Unit
  mut alive : Bool
}

///|
priv struct Harness {
  host : @host.Host
  crypto : @vault_crypto.Crypto
  waiting : Map[Int, @effect.Deferred[Json]]
  chunks : Map[Int, (Bytes, Bool) -> Unit]
  mut next : Int
  mut state : Json
  effects : Array[Json]
  cards : Array[(String, Json)]
  mut hidden : Bool
  mut now_ms : Double
  timers : Array[HTimer]
  mut seq : Int
  /// The callbacks the machine's servers are given, by the serve's number.
  proxies : Map[Int, (async (ConnectAsk) -> ConnectDecision, async (ForwardAsk) -> ForwardDecision)]
  unix : Map[Int, async (Int, Bytes) -> (Bytes, Bool)]
  mut serves : Int
}


///|
fn Harness::say(self : Harness, v : Json) -> Unit {
  self.host.say(stringify(v))
}

///|
fn Harness::effect(self : Harness, kind : String, v : Json) -> Unit {
  self.effects.push(obj([(kind, v)]))
}

///|
/// A call of the test's: its answer, or what it threw.
async fn Harness::call(self : Harness, name : String, args : Array[Json]) -> Json {
  self.next += 1
  let n = self.next
  let done = @effect.Deferred::new()
  self.waiting[n] = done
  self.say(obj([("call", ji(n)), ("name", js(name)), ("args", jarr(args))]))
  done.wait()
}

///|
fn Harness::after(self : Harness, ms : Double, f : () -> Unit) -> () -> Unit {
  self.seq += 1
  let t = { due: self.now_ms + ms, seq: self.seq, f, alive: true }
  self.timers.push(t)
  () => t.alive = false
}

///|
fn Harness::advance(self : Harness, ms : Double) -> Unit {
  self.now_ms = ms
  while true {
    let mut next : HTimer? = None
    for t in self.timers {
      if t.alive && t.due <= ms {
        match next {
          Some(x) if x.due < t.due || (x.due == t.due && x.seq < t.seq) => ()
          _ => next = Some(t)
        }
      }
    }
    match next {
      Some(t) => {
        t.alive = false
        (t.f)()
      }
      None => break
    }
  }
  let alive = self.timers.filter(t => t.alive)
  self.timers.clear()
  self.timers.push_iter(alive.iter())
}

///|
fn Harness::st(self : Harness, k : String) -> Json? {
  get(Some(self.state), k)
}

///|
fn Harness::thread(self : Harness) -> Thread? {
  match self.st("thread") {
    Some(t) => Thread::of_json(t)
    None => None
  }
}

///|
/// The fake store (FakeHub's), as the test has it now.
fn Harness::store(self : Harness) -> Store {
  {
    get_session: k => match get(self.st("sessions"), k) {
      Some(Object(_) as row) =>
        Some({
          ws: gs(Some(row), "ws"),
          archived: get(Some(row), "archivedAt") is Some(Number(_, ..)),
        })
      _ => None
    },
    starter: k => gs(self.st("starters"), k),
    participants: k => strings_of(get(self.st("people"), k)),
    latest_thread: _ => self.thread(),
    latest_thread_if_ready: None,
    session_thread_by_id: (_, _) => self.thread(),
    pending_card_header: _ => if self.hidden || self.cards.is_empty() {
      None
    } else {
      Some(self.cards.length().to_string())
    },
    pending_card_header_if_ready: None,
    insert_message: (m, before) => {
      match before {
        Some(b) => b()
        None => ()
      }
      self.cards.push((gtext(Some(m), "text"), get(Some(m), "card").unwrap_or(Json::null())))
      self.hidden = false
      self.effect(
        "inserted",
        obj([("text", get(Some(m), "text").unwrap_or(Json::null())), ("card", get(Some(m), "card").unwrap_or(Json::null()))]),
      )
      self.cards.length()
    },
    withdraw_card: (session, thread, ts) => {
      self.effect("withdrawn", jarr([js(session), ji(thread), js(ts)]))
      true
    },
    restate_card: (session, thread, ts, f) => {
      let card = match digits_int(ts) {
        Some(i) if i >= 1 && i <= self.cards.length() => Some(self.cards[i - 1].1)
        _ => None
      }
      self.effect("restated", jarr([js(session), ji(thread), js(ts), f(card)]))
      true
    },
  }
}

///|
fn key_ref_of(v : Json) -> KeyRef {
  {
    handle: gtext(Some(v), "handle"),
    kind: gtext(Some(v), "kind"),
    public: strings_of(get(Some(v), "public")).map(@vault_crypto.unhex),
  }
}

///|
fn key_ref_json(k : KeyRef) -> Json {
  obj([("handle", js(k.handle)), ("kind", js(k.kind)), ("public", jarr(k.public.map(b => js(@vault_crypto.hex(b)))))])
}

///|
fn headers_json(hs : Array[(String, Array[String])]) -> Json {
  jarr(hs.map(h => jarr([js(h.0), jstrs(h.1)])))
}

///|
fn headers_of(v : Json?) -> Array[(String, Array[String])] {
  match v {
    Some(Array(a)) =>
      a.map(h => match h {
        Array([String(k), vs, ..]) => (k, strings_of(Some(vs)))
        _ => ("", [])
      })
    _ => []
  }
}

///|
/// The machine as the test answers it.
fn Harness::machine(self : Harness) -> Machine {
  {
    temp_dir: async fn(prefix) { js_text(Some(self.call("machine.tempDir", [js(prefix)]))) },
    remove: async fn(p) { ignore(self.call("machine.remove", [js(p)])) },
    chmod: async fn(p, mode) { ignore(self.call("machine.chmod", [js(p), ji(mode)])) },
    write_file: async fn(p, b, mode) {
      ignore(self.call("machine.writeFile", [js(p), js(@vault_crypto.hex(b)), ji(mode)]))
    },
    read_file: async fn(p) {
      match self.call("machine.readFile", [js(p)]) {
        String(h) => Some(@vault_crypto.unhex(h))
        _ => None
      }
    },
    mkdir: async fn(p, mode) { ignore(self.call("machine.mkdir", [js(p), ji(mode)])) },
    shell_for: async fn(env) {
      js_text(Some(self.call("machine.shellFor", [jarr(env.map(e => jarr([js(e.0), js(e.1)])))])))
    },
    spawn: async fn(s) {
      self.next += 1
      let n = self.next
      let done = @effect.Deferred::new()
      self.waiting[n] = done
      self.chunks[n] = (b, err) => if err { (s.on_err)(b) } else { (s.on_out)(b) }
      self.say(
        obj([
          ("call", ji(n)),
          ("name", js("machine.spawn")),
          (
            "args",
            jarr([
              js(s.shell),
              jstrs(s.args),
              js(s.cwd),
              jarr(s.env.map(e => jarr([js(e.0), js(e.1)]))),
              jn(s.timeout_ms),
            ]),
          ),
        ]),
      )
      let ended = done.wait()
      self.chunks.remove(n)
      {
        code: gn(Some(ended), "code").map(c => c.to_int()),
        signal: gs(Some(ended), "signal"),
        timed_out: get(Some(ended), "timedOut") == Some(Json::boolean(true)),
        error: gs(Some(ended), "error"),
      }
    },
    p256_new: async fn() { key_ref_of(self.call("machine.p256New", [])) },
    key_of_pem: async fn(pem) {
      match self.call("machine.keyOfPem", [js(pem)]) {
        Null => None
        v => Some(key_ref_of(v))
      }
    },
    ed25519_of_seed: async fn(seed) {
      key_ref_of(self.call("machine.ed25519OfSeed", [js(@vault_crypto.hex(seed))]))
    },
    rsa_of_jwk: async fn(jwk) { key_ref_of(self.call("machine.rsaOfJwk", [jwk])) },
    key_pem: async fn(k) { js_text(Some(self.call("machine.keyPem", [key_ref_json(k)]))) },
    sign: async fn(k, hash, data) {
      @vault_crypto.unhex(
        js_text(Some(self.call("machine.sign", [key_ref_json(k), js(hash), js(@vault_crypto.hex(data))]))),
      )
    },
    sha1: async fn(b) {
      @vault_crypto.unhex(js_text(Some(self.call("machine.sha1", [js(@vault_crypto.hex(b))]))))
    },
    roots: async fn() { strings_of(Some(self.call("machine.roots", []))) },
    tls_context: async fn(key, chain) { js_text(Some(self.call("machine.tlsContext", [js(key), js(chain)]))) },
    proxy_listen: async fn(connect, forward) {
      self.serves += 1
      let n = self.serves
      self.proxies[n] = (connect, forward)
      gn(Some(self.call("machine.proxyListen", [ji(n)])), "port").unwrap_or(0.0).to_int()
    },
    proxy_close: () => (),
    unix_serve: async fn(path, answer) {
      self.serves += 1
      let n = self.serves
      self.unix[n] = answer
      ignore(self.call("machine.unixServe", [ji(n), js(path)]))
      () => {
        self.unix.remove(n)
        ignore(
          @effect.runtime().fork(name="unix close", async fn() {
            ignore(self.call("machine.unixClose", [ji(n)])) catch {
              _ => ()
            }
          }),
        )
      }
    },
    random: n => self.crypto.random(n) catch { _ => Bytes::make(n, b'\x00') },
  }
}

///|
fn opt_str_arg(v : Json?) -> String? {
  match v {
    Some(String(s)) => Some(s)
    _ => None
  }
}

///|
fn Harness::world(self : Harness, setup : Json) -> World {
  let db_path = gtext(Some(setup), "db")
  let host = self.host
  {
    hub: {
      store: self.store(),
      prepare_latest_threads: None,
      prepare_card_posts: None,
      post: async fn(_, _, _, _) { (self.cards.length() + 1).to_string() },
      shared: (_, _, _, _) => (),
      notify: (k, text) => self.effect("notified", jarr([js(k), js(text)])),
      identity: async fn(_) { None },
    },
    card_outcomes: None,
    home: () => gs(Some(self.state), "home"),
    title: None,
    title_if_ready: None,
    data: gtext(Some(setup), "data"),
    lock: ws => {
      let key = match ws {
        Some(w) if Some(w) != gs(Some(self.state), "home") => w
        _ => ""
      }
      match get(self.st("locks"), key) {
        Some(Object(_) as l) => Some(Lock::of_json(l))
        _ => None
      }
    },
    now: () => self.now_ms,
    after: (ms, f) => self.after(ms, f),
    sleep: async fn(ms) {
      let d : @effect.Deferred[Unit] = @effect.Deferred::new()
      ignore(self.after(ms, () => ignore(d.succeed(()))))
      d.wait() catch {
        _ => ()
      }
    },
    peer: Some(given => match get(self.st("peers"), given) {
      Some(Object(_) as p) => Some({ id: gtext(Some(p), "id"), name: gtext(Some(p), "name") })
      Some(String(why)) => raise Failure(why)
      _ => None
    }),
    ask: Some(async fn(station, request) { self.call("ask", [js(station), request]) }),
    work_of: Some((ws, peer, session) => "\{gtext(self.st("work"), "dir")}/\{ws}/\{peer}/\{session}"),
    coming: None,
    previous: { gone: None },
    browsers: Some({
      cookies: async fn(session, sites, station) {
        js_text(Some(self.call("browser.cookies", [js(session), jstrs(sites), jb(station)])))
      },
      passkeys_in: Some(async fn(session, d) { ignore(self.call("browser.passkeysIn", [js(session), d])) }),
      sign_in: async fn(session, d) { ignore(self.call("browser.signIn", [js(session), d])) },
      extend_sign_in: Some((session, request, until) => self.effect("extended", jarr([js(session), js(request), jn(until)]))),
    }),
    machine: self.machine(),
    hold: () => () => (),
    log: (_, _, _, _) => (),
    random: n => self.crypto.random(n) catch { _ => Bytes::make(n, b'\x00') },
    env: () => match get(Some(setup), "env") {
      Some(Array(a)) =>
        a.map(e => match e {
          Array([String(k), String(v), ..]) => (k, v)
          _ => ("", "")
        })
      _ => []
    },
    index_db: Some(() => @sql.Db::attach(host, db_path, wait=5000)),
    backfill_take: () => true,
    backfill_give: () => (),
    foreground: _ => (),
  }
}

///|
fn error_json(e : Error) -> Json {
  let kind = match e {
    Refused(_) => "Refused"
    Aborted => "AbortError"
    _ => "Error"
  }
  obj([("kind", js(kind)), ("message", js(message_of(e)))])
}

///|
fn opt_json(v : String?) -> Json {
  match v {
    Some(s) => js(s)
    None => Json::null()
  }
}

///|
fn held_json(h : @vault_crypto.Held) -> Json {
  h.to_json()
}

///|
fn result_json(r : Result[Json, String]) -> Json {
  match r {
    Ok(v) => v
    Err(e) => js(e)
  }
}

///|
fn listed_json(l : Listed) -> Json {
  obj([
    ("vault", js(l.vault)),
    ("item", js(l.item)),
    ("owner", opt_json(l.owner)),
    ("listing", l.listing),
  ])
}


///|
/// One function of the package, as the test asks it.
async fn Harness::run_fn(self : Harness, v : Vault, w : World, name : String, a : Array[Json]) -> Json {
  let arg = (i : Int) => a.get(i).unwrap_or(Json::null())
  let s = (i : Int) => js_text(Some(arg(i)))
  let os = (i : Int) => opt_str_arg(Some(arg(i)))
  let secrets = v.secrets
  let lock_of = (ws : String) => (w.lock)(Some(ws))
  match name {
    "listings" => jarr(secrets.listings(s(0), person?=os(1)).map(listed_json))
    "ask" => {
      let x = arg(1)
      js(
        secrets.ask(s(0), {
          item: gtext(Some(x), "item"),
          mode: gs(Some(x), "mode"),
          reason: gtext(Some(x), "reason"),
          command: gs(Some(x), "command"),
          hosts: match get(Some(x), "hosts") { Some(Array(_) as h) => Some(strings_of(Some(h))); _ => None },
          station: gs(Some(x), "station"),
          timeout: get(Some(x), "timeout"),
          person: gs(Some(x), "person"),
        }),
      )
    }
    "reask" => js(secrets.reask(s(0), s(1)))
    "describe" => {
      let x = arg(1)
      js(
        secrets.describe(
          s(0),
          gtext(Some(x), "item"),
          name?=gs(Some(x), "name"),
          about?=gs(Some(x), "about"),
          gtext(Some(x), "reason"),
          person?=gs(Some(x), "person"),
        ),
      )
    }
    "described" => opt_json(secrets.described(lock_of(s(0)).unwrap(), s(1), arg(2)))
    "describedPlain" => result_json(secrets.described_plain(s(0), lock_of(s(0)), s(1), arg(2)))
    "remove" => {
      let x = arg(1)
      js(secrets.remove(s(0), gtext(Some(x), "item"), gtext(Some(x), "reason"), person?=gs(Some(x), "person")))
    }
    "removed" => opt_json(secrets.removed(lock_of(s(0)).unwrap(), s(1), arg(2)))
    "removedPlain" => result_json(secrets.removed_plain(s(0), s(1), arg(2)))
    "cancel" => js(secrets.cancel(s(0), s(1)))
    "status" => js(secrets.status(s(0), person?=os(1)))
    "save" => {
      let x = arg(1)
      js(
        secrets.save_secret(s(0), {
          name: gtext(Some(x), "name"),
          kind: gtext(Some(x), "kind"),
          reason: gtext(Some(x), "reason"),
          value: gs(Some(x), "value"),
          command: gs(Some(x), "command"),
          path: gs(Some(x), "path"),
          username: gs(Some(x), "username"),
          public_key: gs(Some(x), "public_key"),
          filename: gs(Some(x), "filename"),
          modes: match get(Some(x), "modes") { Some(Array(_) as m) => Some(strings_of(Some(m))); _ => None },
          hosts: match get(Some(x), "hosts") { Some(Array(_) as h) => Some(strings_of(Some(h))); _ => None },
          env: gs(Some(x), "env"),
          cwd: gtext(Some(x), "cwd"),
          station: gs(Some(x), "station"),
          browser: gs(Some(x), "browser"),
          person: gs(Some(x), "person"),
          oauth: gs(Some(x), "oauth"),
          about: gs(Some(x), "about"),
          quiet: None,
        }),
      )
    }
    "boxed" => jb(secrets.boxed(lock_of(s(0)).unwrap(), arg(1)))
    "saved" => opt_json(secrets.saved(lock_of(s(0)).unwrap(), s(1), arg(2)))
    "savedPlain" => result_json(secrets.saved_plain(s(0), lock_of(s(0)), s(1), arg(2)))
    "grant" => opt_json(secrets.grant(lock_of(s(0)).unwrap(), s(1), arg(2)))
    "grantPlain" => opt_json(secrets.grant_plain(s(0), lock_of(s(0)), s(1), arg(2)))
    "denyPlain" => opt_json(secrets.deny_plain(s(0), s(1), arg(2)))
    "deny" => opt_json(secrets.deny(lock_of(s(0)).unwrap(), s(1), arg(2)))
    "run" => {
      let x = arg(1)
      js(
        secrets.run(s(0), {
          grant: gtext(Some(x), "grant"),
          command: gtext(Some(x), "command"),
          env: gs(Some(x), "env"),
          cwd: gtext(Some(x), "cwd"),
          under: gs(Some(x), "under"),
          timeout_ms: gn(Some(x), "timeoutMs"),
          station: gs(Some(x), "station"),
        }),
      )
    }
    "heard" => secrets.heard(s(0), s(1), arg(2))
    "held" => jarr(secrets.held(s(0)).map(held_json))
    "pending" => jarr(secrets.pending(s(0), lock_of(s(0)), s(1), s(2)))
    "preparePending" => {
      secrets.prepare_pending(s(0))
      Json::null()
    }
    "uses" => jarr(secrets.uses(s(0), lock_of(s(0)), s(1), s(2), s(3)))
    "audit" => jarr(secrets.audit(s(0), s(1)))
    "carried" => secrets.carried()
    "carry" => {
      v.carry(arg(0))
      Json::null()
    }
    "reboxed" => {
      secrets.reboxed()
      Json::null()
    }
    "renewed" => {
      secrets.renewed(s(0), s(1), s(2), workspace?=os(3))
      Json::null()
    }
    "signInAgain" => {
      secrets.sign_in_again(s(0))
      Json::null()
    }
    "browserUsed" => {
      secrets.browser_used(s(0), s(1))
      Json::null()
    }
    "passkeysAgain" => {
      secrets.passkeys_again(s(0))
      Json::null()
    }
    "tells" =>
      match secrets.tells(arg(0)) {
        Some(t) => t
        None => Json::null()
      }
    "inVault" => jb(secrets.in_vault(s(0), s(1), s(2)))
    "sessionChanged" => {
      v.session_changed(s(0))
      Json::null()
    }
    "signin.ask" => {
      let x = arg(1)
      js(
        v.sign_ins.ask(s(0), {
          site: gtext(Some(x), "site"),
          reason: gs(Some(x), "reason"),
          tab: gs(Some(x), "tab"),
          again: get(Some(x), "again") == Some(Json::boolean(true)),
          reask: get(Some(x), "reask") == Some(Json::boolean(true)),
          done: get(Some(x), "done") == Some(Json::boolean(true)),
          stuck: gs(Some(x), "stuck"),
          name: gs(Some(x), "name"),
          about: gs(Some(x), "about"),
        }),
      )
    }
    "signin.fill" => opt_json(v.sign_ins.fill(s(0), s(1), s(2), arg(3)))
    "signin.self" => opt_json(v.sign_ins.self_(s(0), s(1), s(2), arg(3) == Json::boolean(true)))
    "signin.deny" => opt_json(v.sign_ins.deny(s(0), s(1), s(2)))
    "signin.get" =>
      match v.sign_ins.get(s(0)) {
        Some(x) => x
        None => Json::null()
      }
    "tools" =>
      jarr(
        v.tools.map(t => obj([("name", js(t.name)), ("description", js(t.description)), ("inputSchema", t.input_schema)])),
      )
    "tool" => {
      guard v.tools.search_by(t => t.name == s(0)) is Some(i) else { raise Failure("no tool \{s(0)}") }
      js((v.tools[i].run)(s(1), arg(2), None))
    }
    "formsOf" => jarr(forms_of(s(0)).map(b => js(@vault_crypto.hex(b))))
    "scrub" => js(scrub(s(0), strings_of(Some(arg(1)))))
    "scrubChunks" => {
      let sc = Scrubber::new(strings_of(Some(arg(0))))
      let out = []
      for c in strings_of(Some(arg(1))) {
        out.push(js(@vault_crypto.hex(sc.push(@vault_crypto.unhex(c)))))
      }
      out.push(js(@vault_crypto.hex(sc.end())))
      jarr(out)
    }
    "swap" => js(swap(s(0), s(1), s(2)))
    "siteOf" => js(site_of(s(0)))
    "placeholder" => js(placeholder(s(0)))
    "ulid" => js(ulid(gn(Some(arg(0)), "ms").unwrap_or(0.0), @vault_crypto.unhex(gtext(Some(arg(0)), "random"))))
    "baseEnv" => jarr(base_env(w).map(e => jarr([js(e.0), js(e.1)])))
    "capture" => secrets_capture(w, s(0), s(1), gn(Some(arg(2)), "ms").unwrap_or(capture_ms))
    "sshKey" => {
      let k = parse_ssh_key(w.machine, s(0))
      obj([("kind", js(k.kind)), ("comment", js(k.comment)), ("blob", js(@vault_crypto.hex(k.blob)))])
    }
    "sshAnswer" => {
      let k = parse_ssh_key(w.machine, s(0))
      let allowed = arg(2) != Json::boolean(false)
      js(@vault_crypto.hex(agent_answer(w.machine, k, @vault_crypto.unhex(s(1)), () => allowed)))
    }
    "makeCa" => {
      let made = make_ca(w.machine, gn(Some(arg(0)), "now").unwrap_or(0.0), s(1))
      obj([("cert", js(@vault_crypto.hex(made.0))), ("key", key_ref_json(made.1))])
    }
    "makeLeaf" => {
      let ca = (@vault_crypto.unhex(s(0)), key_ref_of(arg(1)))
      let made = make_leaf(w.machine, ca, s(2), s(3), gn(Some(arg(4)), "now").unwrap_or(0.0))
      obj([("cert", js(@vault_crypto.hex(made.0))), ("key", key_ref_json(made.1))])
    }
    "pem" => js(pem(@vault_crypto.unhex(s(0))))
    "proxyAdmit" => {
      let x = arg(0)
      let used = []
      let admitted = secrets.proxy.admit({
        hosts: strings_of(get(Some(x), "hosts")),
        placeholder: gtext(Some(x), "placeholder"),
        value: gtext(Some(x), "value"),
        used: h => used.push(h),
        allowed: () => true,
      })
      js(admitted.0)
    }
    "proxyStart" => ji(secrets.proxy.start())
    "proxyConnect" => {
      let (connect, _) = self.proxies.get(gn(Some(arg(0)), "n").unwrap_or(0.0).to_int()).unwrap()
      match connect({ url: s(1), authorization: os(2) }) {
        Refuse(line) => obj([("refuse", js(line))])
        Tunnel(h, p) => obj([("tunnel", jarr([js(h), ji(p)]))])
        Open(h, p, ctx, run) => obj([("open", jarr([js(h), ji(p), js(ctx), ji(run)]))])
      }
    }
    "proxyForward" => {
      let (_, forward) = self.proxies.get(gn(Some(arg(0)), "n").unwrap_or(0.0).to_int()).unwrap()
      let x = arg(1)
      match
        forward({
          run: gn(Some(x), "run").unwrap_or(0.0).to_int(),
          host: gtext(Some(x), "host"),
          port: gn(Some(x), "port").unwrap_or(0.0).to_int(),
          verb: gtext(Some(x), "method"),
          path: gtext(Some(x), "path"),
          headers: headers_of(get(Some(x), "headers")),
        }) {
        Forbid(code, text) => obj([("forbid", jarr([ji(code), js(text)]))])
        Forward(hs) => obj([("forward", headers_json(hs))])
      }
    }
    "unixChunk" => {
      let answer = self.unix.get(gn(Some(arg(0)), "n").unwrap_or(0.0).to_int()).unwrap()
      let (out, destroy) = answer(gn(Some(arg(1)), "n").unwrap_or(0.0).to_int(), @vault_crypto.unhex(s(2)))
      obj([("out", js(@vault_crypto.hex(out))), ("destroy", jb(destroy))])
    }
    "close" => {
      v.close()
      Json::null()
    }
    "drain" => {
      secrets.uses_index.drain()
      Json::null()
    }
    "hideCard" => {
      self.hidden = true
      Json::null()
    }
    _ => raise Failure("no function \{name}")
  }
}

///|
async fn secrets_capture(w : World, command : String, cwd : String, ms : Double) -> Json {
  capture(w, command, cwd, base_env(w), ms).to_json()
}

///|
/// The harness's loop: setup, then each line as it comes.
pub async fn harness(host : @host.Host) -> Unit {
  let h : Harness = {
    host,
    crypto: @vault_crypto.Crypto::of_host(host),
    waiting: Map([]),
    chunks: Map([]),
    next: 0,
    state: obj([]),
    effects: [],
    cards: [],
    hidden: false,
    now_ms: 0.0,
    timers: [],
    seq: 0,
    proxies: Map([]),
    unix: Map([]),
    serves: 0,
  }
  let made : @effect.Deferred[(Vault, World)] = @effect.Deferred::new()
  // One function at a time, in the order asked: what the TypeScript's are given one after another.
  let queue : @effect.Queue[(Json, String, Array[Json])] = @effect.Queue::unbounded()
  ignore(
    host.rt.fork(name="vault service harness", async fn() {
      while true {
        let (id, name, args) = queue.take()
        let (v, w) = made.wait()
        let value = h.run_fn(v, w, name, args) catch {
          e => {
            let effects = h.effects.copy()
            h.effects.clear()
            h.say(obj([("ans", id), ("error", error_json(e)), ("effects", jarr(effects))]))
            continue
          }
        }
        let effects = h.effects.copy()
        h.effects.clear()
        h.say(obj([("ans", id), ("value", value), ("effects", jarr(effects))]))
      }
    }),
  )
  // What the test's own servers ask (a proxy's CONNECT, an agent's chunk) is answered beside the queue: the function
  // that set them going waits on what they serve.
  let side = [
    "proxyConnect", "proxyForward", "unixChunk", "heard",
  ]
  while host.line() is Some(line) {
    let said = parse_or_null(line)
    guard said is Object(_) else { continue }
    match get(Some(said), "ret") {
      Some(Number(n, ..)) => {
        match h.waiting.get(n.to_int()) {
          Some(done) => {
            h.waiting.remove(n.to_int())
            match get(Some(said), "throw") {
              Some(t) => ignore(done.fail(Failure(gtext(Some(t), "message"))))
              None => ignore(done.succeed(get(Some(said), "value").unwrap_or(Json::null())))
            }
          }
          None => ()
        }
        continue
      }
      _ => ()
    }
    match get(Some(said), "chunk") {
      Some(Number(n, ..)) => {
        match h.chunks.get(n.to_int()) {
          Some(f) => f(@vault_crypto.unhex(gtext(Some(said), "hex")), gs(Some(said), "stream") == Some("err"))
          None => ()
        }
        continue
      }
      _ => ()
    }
    match get(Some(said), "state") {
      Some(st) => {
        h.state = st
        h.say(obj([("stated", jb(true))]))
        continue
      }
      None => ()
    }
    match get(Some(said), "clock") {
      Some(Number(ms, ..)) => {
        h.advance(ms)
        // (what the timers set going settles before the test looks)
        for _ in 0..<64 {
          @effect.pause()
        }
        h.say(obj([("clocked", jn(ms))]))
        continue
      }
      _ => ()
    }
    match get(Some(said), "setup") {
      Some(setup) => {
        let w = h.world(setup)
        let crypto = h.crypto
        ignore(
          host.rt.fork(name="vault service setup", async fn() {
            let db = @vault_crypto.Db::attach(crypto, gtext(Some(setup), "db")) catch {
              e => {
                h.say(obj([("ready", jb(false)), ("error", js(message_of(e)))]))
                return
              }
            }
            let vault = Vault::new(
              w,
              db,
              crypto,
              {
                tell: (kind, what, key, to) => h.effect(
                  "told",
                  jarr([js(kind), what, js(key), to]),
                ),
                tabs: session => match get(h.st("tabs"), session) {
                  Some(Array(ts)) => ts.map(t => (gtext(Some(t), "id"), gtext(Some(t), "url")))
                  _ => []
                },
                look: async fn(session, tab) { h.call("browser.look", [js(session), js(tab)]) },
                drive: async fn(session, tab, site, values, used) {
                  let had = []
                  for k, _ in used {
                    had.push(k)
                  }
                  let answer = h.call("browser.drive", [js(session), js(tab), js(site), values, jstrs(had)])
                  used.clear()
                  for k in strings_of(get(Some(answer), "used")) {
                    used[k] = ()
                  }
                  get(Some(answer), "driven").unwrap_or(Json::null())
                },
                screen_link: tab => match h.st("pages") {
                  Some(Object(_) as p) =>
                    Some("\{gtext(Some(p), "origin")}/w/\{gtext(Some(p), "workspace")}/s/\{gtext(Some(p), "station")}/screen/\{gtext(Some(p), "tab_prefix")}\{tab}")
                  _ => None
                },
                session_ws: session => match get(h.st("sessions"), session) {
                  Some(row) => gs(Some(row), "ws")
                  None => None
                },
                session_dir: session => match get(h.st("sessions"), session) {
                  Some(row) => gs(Some(row), "workspace")
                  None => None
                },
                join_path: (a, b) => if starts(b, "/") { b } else { "\{a}/\{b}" },
                signin_id: Some(() => "g_" + @vault_crypto.js_number(h.now_ms)),
                passkeys_again_all: () => h.effect("passkeysAgainAll", Json::null()),
              },
            ) catch {
              e => {
                h.say(obj([("ready", jb(false)), ("error", js(message_of(e)))]))
                return
              }
            }
            ignore(made.succeed((vault, w)))
            let effects = h.effects.copy()
            h.effects.clear()
            h.say(obj([("ready", jb(true)), ("effects", jarr(effects))]))
          }),
        )
        continue
      }
      None => ()
    }
    match get(Some(said), "fn") {
      Some(q) => {
        let id = get(Some(q), "id").unwrap_or(Json::null())
        let name = gtext(Some(q), "name")
        let args = ga(Some(q), "args").unwrap_or([])
        if side.contains(name) {
          ignore(
            host.rt.fork(name="vault service side", async fn() {
              let (v, w) = made.wait()
              let value = h.run_fn(v, w, name, args) catch {
                e => {
                  h.say(obj([("ans", id), ("error", error_json(e)), ("effects", jarr([]))]))
                  return
                }
              }
              h.say(obj([("ans", id), ("value", value), ("effects", jarr([]))]))
            }),
          )
        } else {
          ignore(queue.try_offer((id, name, args)))
        }
        continue
      }
      None => ()
    }
  }
  // (stdin closed: the test is done with it)
  @host.exit(0)
}
