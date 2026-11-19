// The accounts (station/src/accounts/index.ts, `@accounts_pool.Accounts`), as a part of the station: the profiles of
// config.json (Claude, Codex, Antigravity, Cursor, Kimi's device sign-in, keyed providers), their checks, quotas and
// tokens renewed, their sign-ins, the automatic decisions' settings; config.json's every change checked
// (`bus.config_check`, accounts/check.ts `checkConfig`), a profile gone told to the hub (`profileGone`); the model
// catalog the cloud keeps (models/module.ts, `@accounts_oauth.models_live`). What the accounts ask of the rest of the
// station (`Backend`: its files, its store, config.json, the network, the words, the hub and the drivers, the
// sign-ins, the shared profiles) is answered here, each by its part: the files and the network by the shell, the store
// by `bus.store`, config.json by the bus, the hub, the drivers and the agents by `bus.hub_ask` (P5-2's), the profiles'
// sign-ins and the machine's logins by this slice's own (login.ts's LoginManager, machine.ts's MachineLogins:
// live_p5_3_accounts_io.mbt), the shared profiles by this slice's Sharing.

///|
/// What the accounts said, as JSON (undefined as null).
fn p53_json(v : @accounts_pool.JV) -> Json {
  if @accounts_pool.is_undef(v) {
    return Json::null()
  }
  match v {
    Null => Json::null()
    Bool(b) => Json::boolean(b)
    Num(n) => Json::number(n)
    Str(s) => Json::string(s)
    Arr(xs) => Json::array(xs.map(p53_json))
    Obj(kvs) => {
      let m : Map[String, Json] = Map([])
      for kv in kvs {
        if !@accounts_pool.is_undef(kv.1) {
          m[kv.0] = p53_json(kv.1)
        }
      }
      Json::object(m)
    }
  }
}

///|
priv struct P53Accounts {
  bus : LiveBus
  backend : @accounts_pool.Backend
  ctx : @accounts_pool.Ctx
  mut accounts : @accounts_pool.Accounts?
  /// Sharing, once it is made (the shared profiles the accounts ask of).
  mut sharing : @share_sync.Sharing?
  /// The accounts as the hub asks them of each session (accounts.ts `forHub`): made with the accounts.
  mut sessions : @accounts_pool.SessionAccounts?
  oauth_io : @accounts_oauth.Io
  /// Claude's logins renewed (oauth.ts `claudeOAuthToken`): one renewal a login at a time.
  claude_auth : @accounts_oauth.ClaudeAuth
  /// The profiles' sign-ins (accounts/index.ts `logins`: login.ts's LoginManager), not the station's logins to
  /// command-line tools (P5-4's, `/machine-logins`).
  logins : @accounts_oauth.LoginManager
  /// The machine's own logins (accounts/index.ts `machine`: machine.ts), on a whole station.
  machine : @accounts_oauth.MachineLogins?
  /// What the model catalog last said, as the accounts read it (catalog.ts `learn`'s table, one for the station):
  /// the models' makers and prices, kept by P53Models.
  pool_catalog : @accounts_pool.Catalog
}

///|
fn P53Accounts::new(bus : LiveBus) -> P53Accounts {
  let me : Ref[P53Accounts?] = Ref(None)
  let backend = @accounts_pool.Backend::new(async fn(name, args) {
    match me.val {
      Some(a) => a.answer(name, args)
      None => raise @accounts_pool.plain_error("the accounts are not made yet")
    }
  })
  let (zh, en) = catalogs_json()
  let ctx : @accounts_pool.Ctx = {
    io: @accounts_pool.Io::new(backend),
    words: @accounts_pool.Words::new(@jsjson.JV::of_json(jfield(zh, "station")).or_obj(@jsjson.JV::of_json(zh)), @jsjson.JV::of_json(jfield(en, "station")).or_obj(@jsjson.JV::of_json(en))),
    // profiles.ts `URLS`: with only the console here every Claude allowance was read at "/api/oauth/usage" (0.1.9984).
    urls: @jsjson.JV::of_json(
      jobj_of([
        ("opencode", jstr(@agent_runtimes.opencode)),
        // ($STILLFAIL_ANTHROPIC_API: a test's stand-in, as profiles.ts reads it)
        (
          "anthropic",
          jstr(
            match env_get("STILLFAIL_ANTHROPIC_API") {
              Some(u) if u != "" => u
              _ => "https://api.anthropic.com"
            },
          ),
        ),
        ("chatgpt", jstr("https://chatgpt.com")),
        ("claudeToken", jstr("https://platform.claude.com/v1/oauth/token")),
        ("console", jstr(@accounts_oauth.console_url)),
      ]),
    ),
    station_lang: (bus.lang.val)(),
    tz_offset_ms: _ => 0.0,
  }
  let oauth_io = p5_oauth_io(bus.host)
  let claude_auth = @accounts_oauth.ClaudeAuth::new(oauth_io, p53_claude_store(bus.host), {
    tr: (lang, key, args) => ctx.words.tr(lang, key, args~),
  })
  let words : @accounts_oauth.Words = { tr: (lang, key, args) => ctx.words.tr(lang, key, args~) }
  let logins = p53_login_manager(bus, words, oauth_io, ctx.io)
  let machine = if bus.as_rig() { None } else { Some(p53_machine_logins(bus, words, oauth_io, ctx)) }
  let a : P53Accounts = {
    bus,
    backend,
    ctx,
    accounts: None,
    sharing: None,
    sessions: None,
    oauth_io,
    claude_auth,
    logins,
    machine,
    pool_catalog: @accounts_pool.Catalog::new(),
  }
  me.val = Some(a)
  a
}

///|
/// The words a catalog keeps under its part's name, or the whole of it where it keeps none.
fn @accounts_pool.JV::or_obj(self : @accounts_pool.JV, whole : @accounts_pool.JV) -> @accounts_pool.JV {
  match self {
    Obj(_) => self
    _ => whole
  }
}

///|
/// What the accounts are given (accounts/index.ts's options as `Given` names them): what of the rest this station
/// answers here.
fn p53_given(machine~ : Bool) -> Json {
  jobj_of([
    ("hub", jb(true)),
    ("hubProfileGone", jb(true)),
    ("hubAllowanceReset", jb(true)),
    ("hubProfileLoginChanged", jb(true)),
    ("codex", jb(true)),
    ("codexLoginChanged", jb(true)),
    ("hermes", jb(true)),
    ("agy", jb(true)),
    ("agyCatalog", jb(true)),
    ("following", jb(true)),
    ("claudeVersion", jb(true)),
    ("check", jstr("default")),
    ("quota", jstr("default")),
    ("resetQuota", jstr("default")),
    ("discover", jstr("default")),
    ("machine", jb(machine)),
    ("checkOnStart", jb(true)),
    ("workspaces", jb(true)),
    ("reviewUndecided", jb(true)),
    ("shared", jb(true)),
    ("sharedLendCodex", jb(true)),
    ("sharedLendAgy", jb(true)),
    ("sharedQuotaReset", jb(true)),
    ("sharedLendClaude", jb(true)),
    ("sharedLoginUpdated", jb(true)),
    ("sharedHostName", jb(true)),
    ("configChecked", jb(true)),
  ])
}

///|
fn P53Accounts::attach(self : P53Accounts) -> Unit {
  let bus = self.bus
  // (config.json's every change checked first: what the accounts would refuse is not written)
  (bus.config_check.val)(raw => {
    match (try { Ok(@accounts_pool.check_config(Some(@jsjson.JV::of_json(raw)), bus.data)) } catch { e => Err(e) }) {
      Ok(_) => None
      Err(e) => Some(p53_words(e))
    }
  })
  ignore(
    bus.host.rt.fork_daemon("accounts", on_error=e => @host.note("accounts failed: \{e}"), async fn() {
      let rt = bus.host.rt
      let clock : @accounts_pool.Clock = {
        now: () => wall_ms().to_double(),
        after: (ms, f) => {
          let gone = Ref(false)
          ignore(
            rt.fork_daemon("accounts' timer", on_error=e => @host.note("accounts' timer failed: \{e}"), async fn() {
              @effect.sleep(ms.to_int()) // timer: the accounts' own (a token's renewal, a quota's poll: a provider's, which offers no push)
              if !gone.val {
                f()
              }
            }),
          )
          () => gone.val = true
        },
      }
      let raw = (bus.config_raw.val)()
      let made = @accounts_pool.Accounts::new(
        self.backend,
        self.ctx,
        @accounts_pool.Given::of_jv(@jsjson.JV::of_json(p53_given(machine=self.machine is Some(_))), bus.data),
        rt,
        clock,
        @jsjson.JV::of_json(raw),
        self.pool_catalog,
      ) catch {
        e => {
          slice_log("error", "accounts", "the accounts were not made", jobj_of([("error", jstr(p53_words(e)))]))
          return
        }
      }
      self.accounts = Some(made)
      let sa = @accounts_pool.SessionAccounts::new(
        self.backend,
        self.ctx.words,
        self.ctx.station_lang,
        async fn() { made.hub_config() },
        () => wall_ms().to_double(),
        rt,
      )
      self.sessions = Some(sa)
      made.set_hub_accounts(sa)
      ignore((bus.config_listen.val)(next => made.config_said(@jsjson.JV::of_json(next))))
      // (accounts/index.ts `start`: a sign-in's change, and the machine's logins read again, told the accounts)
      ignore(self.logins.changes(id => ignore(rt.fork_quiet(name="a sign-in changed", async fn() {
        made.login_changed(id) catch {
          e => slice_log("warn", "accounts", "a sign-in's change was not taken", jobj_of([("error", jstr(p53_words(e)))]))
        }
      }))))
      match self.machine {
        Some(m) =>
          ignore(m.changes(() => ignore(rt.fork_quiet(name="the machine's logins changed", async fn() {
            made.machine_changed() catch {
              e => slice_log("warn", "accounts", "the machine's logins were not taken", jobj_of([("error", jstr(p53_words(e)))]))
            }
          }))))
        None => ()
      }
      made.start()
    }),
  )
  let a = (r : Json) => (self.made(), r)
  let viewer_of = (r : Json) => @jsjson.JV::of_json(jfield(r, "viewer"))
  let lang_of = (r : Json) => jtext(r, "lang").unwrap_or((bus.lang.val)())
  let id_of = (r : Json) => p53_param(r, "id", 2)
  bus.parts.routes([
    { meth: "GET", path: "/profiles", answer: async fn(r) { p53_json(a(r).0.profiles_view(Some(viewer_of(r)))) } },
    { meth: "GET", path: "/profiles/pace", answer: async fn(r) { p53_json(a(r).0.pace_view(Some(viewer_of(r)))) } },
    { meth: "GET", path: "/accounts/state", answer: async fn(_r) { self.state() } },
    {
      meth: "POST",
      path: "/profiles",
      answer: async fn(r) { jstr(a(r).0.new_keyed_profile(@jsjson.JV::of_json(jfield(r, "body")), viewer_of(r), lang_of(r))) },
    },
    {
      meth: "PUT",
      path: "/profiles/:id",
      answer: async fn(r) {
        a(r).0.put_profile(id_of(r), @jsjson.JV::of_json(jfield(r, "body")), viewer_of(r), lang_of(r))
        jobj_of([("ok", jb(true))])
      },
    },
    {
      meth: "DELETE",
      path: "/profiles/:id",
      answer: async fn(r) {
        let id = id_of(r)
        a(r).0.delete_profile(id, viewer_of(r), lang_of(r))
        bus.hub_profile_gone(id) catch { _ => () }
        jobj_of([("ok", jb(true))])
      },
    },
    { meth: "POST", path: "/profiles/:id/check", answer: async fn(r) { p53_json(a(r).0.check(id_of(r), lang_of(r))) } },
    {
      meth: "POST",
      path: "/profiles/:id/quota",
      answer: async fn(r) {
        match a(r).0.asked_quota(id_of(r)) {
          Some(q) => p53_json(q)
          None => Json::null()
        }
      },
    },
    { meth: "POST", path: "/profiles/:id/login", answer: async fn(r) { jobj_of([("job", p53_json(a(r).0.start_login(id_of(r), viewer_of(r), lang_of(r))))]) } },
    { meth: "POST", path: "/logins", answer: async fn(r) { p53_json(a(r).0.new_login(@jsjson.JV::of_json(jfield(r, "body")), viewer_of(r), lang_of(r))) } },
  ])
}

///|
/// The accounts, made (a request before they are is refused).
fn P53Accounts::made(self : P53Accounts) -> @accounts_pool.Accounts raise P53Error {
  match self.accounts {
    Some(a) => a
    None => raise P53Error("the accounts are not ready yet; ask again in a moment")
  }
}

///|
/// A route's parameter: as the router gave it, else the path's segment at `at`.
fn p53_param(r : Json, name : String, at : Int) -> String {
  match jtext(jfield(r, "params"), name) {
    Some(v) => v
    None => {
      let parts = jtext_or_empty(r, "path").split("/").filter(p => p != "").map(p => p.to_string()).to_array()
      let v = if at - 1 < parts.length() && at >= 1 { parts[at - 1] } else { "" }
      @share_sync.decode_uri_component(v) catch {
        _ => v
      }
    }
  }
}

///|
fn P53Accounts::state(self : P53Accounts) -> Json {
  match self.accounts {
    Some(a) => p53_json(a.state())
    None => Json::null()
  }
}

///|
async fn P53Accounts::profiles_view(self : P53Accounts) -> Json {
  p53_json(self.made().profiles_view(None))
}

///|
fn P53Accounts::new_models(self : P53Accounts, keys : Array[String]) -> Unit {
  match self.accounts {
    Some(a) => a.new_models(keys)
    None => ()
  }
}

///|
async fn P53Accounts::close(self : P53Accounts) -> Unit {
  match self.accounts {
    Some(a) => a.close()
    None => ()
  }
}

///|
fn p53_arg(args : Array[@accounts_pool.JV], i : Int) -> Json {
  if i < args.length() {
    p53_json(args[i])
  } else {
    Json::null()
  }
}

///|
fn p53_arg_s(args : Array[@accounts_pool.JV], i : Int) -> String {
  match p53_arg(args, i) {
    String(s) => s
    _ => ""
  }
}

///|
/// What the accounts ask of the rest of the station (`<part>.<method>`, accounts_pool's backend.mbt).
async fn P53Accounts::answer(self : P53Accounts, name : String, args : Array[@accounts_pool.JV]) -> @accounts_pool.JV {
  let bus = self.bus
  let host = bus.host
  let store = bus.store
  let s = (i : Int) => p53_arg_s(args, i)
  let j = (i : Int) => p53_arg(args, i)
  let done = @accounts_pool.jundef
  // (a renewal refused and words for people keep their kind, as console.ts's classes: quota.mbt `failed` and the Claude
  // driver tell a sign-in to make again by it)
  let thrown = (e : Error) => match e {
    @accounts_pool.Thrown(_, _) => e
    @accounts_oauth.RenewRefused(status, message) =>
      @accounts_pool.Thrown(
        "RenewRefused",
        @accounts_pool.jobj([
          ("message", @accounts_pool.js(message)),
          (
            "status",
            match status {
              Some(n) => Num(n.to_double())
              None => Null
            },
          ),
        ]),
      )
    @accounts_oauth.Said(message) => @accounts_pool.Thrown("Said", @accounts_pool.jobj([("message", @accounts_pool.js(message))]))
    _ => @accounts_pool.plain_error(p53_words(e))
  }
  try {
    match self.machine_answer(name, args) {
      Some(v) => return v
      None => ()
    }
    match name {
      // ── the files ──
      "fs.readFile" =>
        match shell_read_text(host, s(0)) {
          Some(t) => Str(t)
          None => raise @accounts_pool.Thrown("Error", @accounts_pool.jobj([("message", @accounts_pool.js("ENOENT: no such file, open '\{s(0)}'")), ("code", @accounts_pool.js("ENOENT"))]))
        }
      "fs.writePrivate" => {
        p53_write_private(host, s(0), @utf8.encode(s(1)))
        done
      }
      "fs.mkdir" => {
        ignore(host.shell("fs.mkdir", { "path": jstr(s(0)), "recursive": jb(true) }))
        done
      }
      "fs.rm" => {
        ignore(host.shell("fs.remove", { "path": jstr(s(0)), "recursive": jb(true) }))
        done
      }
      "fs.rename" => {
        ignore(host.shell("fs.rename", { "from": jstr(s(0)), "to": jstr(s(1)) }))
        done
      }
      "fs.readdir" =>
        match host.shell("fs.readdir", { "path": jstr(s(0)) }) {
          (Array(xs), _) => @jsjson.JV::of_json(Json::array(xs))
          _ => Arr([])
        }
      "fs.exists" => Bool(p53_exists(host, s(0)))
      "fs.stamp" =>
        match (try { Ok(host.shell("fs.meta", { "path": jstr(s(0)) })) } catch { e => Err(e) }) {
          Ok((m, _)) => Str("\{jnum_of(m, "size").unwrap_or(0.0)}:\{jnum_of(m, "mtimeMs").unwrap_or(0.0)}")
          Err(_) => Str("")
        }
      // ── the machine ──
      "crypto.randomHex" => Str(@drive.hex(@drive.random_bytes(as_num(j(0)).unwrap_or(16.0).to_int())))
      "crypto.randomUUID" => Str(p53_uuid())
      "os.info" =>
        @jsjson.JV::of_json(jobj_of([("platform", jstr(platform())), ("arch", jstr(arch())), ("hostname", jstr(hostname())), ("homedir", jstr(homedir()))]))
      "platform.hasKeychain" => Bool(platform() == "darwin")
      "wall.now" => Num(wall_ms().to_double())
      "paths.join" => Str(@nodepath.join(sep(), args.map(a => p53_json(a)).filter_map(x => if x is String(t) { Some(t) } else { None })))
      "station.env" => @jsjson.JV::of_json(Json::object(Map::from_array(env_all().map(kv => (kv.0, jstr(kv.1))))))
      "log.info" | "log.warn" | "log.error" => {
        slice_log(name[4:].to_owned(), s(0), s(1), j(2))
        done
      }
      "fetch" => {
        let r = j(0)
        let headers = match jfield(r, "headers") {
          Object(m) => m.to_array().filter_map(kv => if kv.1 is String(v) { Some((kv.0, v)) } else { None })
          Array(xs) => xs.filter_map(x => match x { Array([String(k), String(v)]) => Some((k, v)); _ => None })
          _ => []
        }
        let answer = (self.oauth_io.fetch)({
          url: jtext_or_empty(r, "url"),
          method_: jtext(r, "method").unwrap_or("GET"),
          headers,
          body: jtext(r, "body"),
          timeout_ms: jnum_of(r, "timeoutMs").unwrap_or(30000.0).to_int(),
          manual: false,
        })
        @jsjson.JV::of_json(jobj_of([("status", ji(answer.status)), ("text", jstr(answer.body))]))
      }
      // ── config.json ──
      "config.raw" => @jsjson.JV::of_json((bus.config_raw.val)())
      "config.put" => {
        let next = j(0)
        @jsjson.JV::of_json((bus.config_update.val)(_ => next))
      }
      // ── the store ──
      "store.now" => Num(store.now().to_double())
      "store.getSession" => @jsjson.JV::of_json(store.get_session(s(0)))
      "store.setSessionProfile" => {
        store.set_session_profile(s(0), j(1), j(2) is True, if args.length() > 3 { Some(j(3)) } else { None })
        done
      }
      "store.setSessionRuntime" => {
        store.set_session_runtime(s(0), j(1), j(2), j(3) is True, j(4), j(5), if args.length() > 6 { Some(j(6)) } else { None }, j(7), if args.length() > 8 { Some(j(8)) } else { None })
        done
      }
      "store.setSessionContextBefore" => {
        store.set_session_context_before(s(0), j(1))
        done
      }
      "store.ranIn" => {
        store.ran_in(s(0), j(1), j(2))
        done
      }
      "store.profileStatus" => @jsjson.JV::of_json(store.profile_status())
      "store.setProfileCheck" => {
        store.set_profile_check(j(0), j(1))
        done
      }
      "store.setProfileQuota" => {
        store.set_profile_quota(j(0), j(1))
        done
      }
      "store.profileHours" => @jsjson.JV::of_json(store.profile_hours(as_num(j(0)).unwrap_or(0.0)))
      "store.forgetProfileHours" => {
        store.forget_profile_hours(j(0))
        done
      }
      "store.lastTurn" => @jsjson.JV::of_json(store.last_turn(j(0)))
      "store.lastContexts" => @jsjson.JV::of_json(Json::array(store.last_contexts(s(0), as_num(j(1)).unwrap_or(1.0).to_int())))
      "store.recentlyCompacted" => Bool(store.recently_compacted(s(0)))
      "store.compactionPoints" => @jsjson.JV::of_json(store.compaction_points(j(0)))
      "store.compactionsReady" => Bool(store.compactions_ready())
      // ── the shared profiles (this slice's Sharing) ──
      "shared.lendCodex" => Num(self.sharing().lend_codex(j(0), rejected=j(1) is True))
      "shared.lendAgy" => Num(self.sharing().lend_agy(j(0), rejected=j(1) is True))
      "shared.lendClaude" => {
        let (token, until) = self.sharing().lend_claude(j(0), rejected=as_text(j(1)))
        @jsjson.JV::of_json(jobj_of([("token", jstr(token)), ("expiresAt", jn(until))]))
      }
      "shared.loginUpdated" => {
        self.sharing().login_updated(profile_id=as_text(j(0)))
        done
      }
      "shared.quotaReset" => {
        self.sharing().quota_reset(s(0), s(1))
        done
      }
      "shared.status" => @jsjson.JV::of_json(self.sharing().status(j(0)))
      "shared.view" =>
        match self.sharing().profile_view(j(0), workspace=if j(1) is String(w) { Some(w) } else { None }) {
          Some(v) => @jsjson.JV::of_json(v)
          None => Null
        }
      "shared.hostName" => {
        let host_id = s(0)
        let peers = match jfield(p53_cloud(bus), "peers") {
          Array(xs) => xs
          _ => []
        }
        match peers.search_by(p => jtext(p, "id") == Some(host_id)) {
          Some(i) => Str(jtext_or_empty(peers[i], "name"))
          None => Str(host_id)
        }
      }
      "share.shareRefusal" =>
        match @share_sync.share_refusal(j(0)) {
          Some(w) => Str(w)
          None => Null
        }
      // ── the sign-ins and the machine's logins (accounts/index.ts `logins`, console.ts, `machine`) ──
      _ if name.has_prefix("logins.") || name.has_prefix("console.") || name.has_prefix("machine.") =>
        match self.sign_in_answer(name, args.map(p53_json)) {
          Some(v) => @jsjson.JV::of_json(v)
          None => raise P53Error("no sign-ins' ask \{name}")
        }
      // ── the hub, the drivers, the agents and the rest of the store (P5-2's) ──
      _ =>
        @jsjson.JV::of_json((bus.hub_ask.val)(name, Json::array(args.map(p53_json))))
    }
  } catch {
    e => raise thrown(e)
  }
}

///|
/// What another part asks of the accounts by name (`accounts.<method>`: the admin API's routes, their arguments in
/// order; the hub and the agents' side, positional or by name), as accounts/index.ts and its `forHub` answer it. A
/// refusal is thrown as the routes take it (`Refused`, its status); the hub's `pick` is answered `{error}` instead.
async fn P53Accounts::ask(self : P53Accounts, m : String, arg : Json) -> Json {
  let positional = arg is Array(_)
  let at = (i : Int, key : String) => match arg {
    Array(xs) => if i < xs.length() { xs[i] } else { Json::null() }
    String(_) | Number(_, ..) | True | False if i == 0 => arg
    _ => jfield(arg, key)
  }
  let str = (i : Int, key : String) => match at(i, key) {
    String(t) => Some(t)
    _ => None
  }
  let text = (i : Int, key : String) => str(i, key).unwrap_or("")
  let given = (i : Int, key : String) => match at(i, key) {
    Null => @jsjson.JV::of_json(Json::object({}))
    v => @jsjson.JV::of_json(v)
  }
  let lang = (i : Int) => str(i, "lang").unwrap_or((self.bus.lang.val)())
  let viewer = (i : Int) => match at(i, "viewer") {
    Null => None
    v => Some(@jsjson.JV::of_json(v))
  }
  let done = Json::null()
  // (the accounts' own refusal as the routes take one: api/request.ts Refused, which accounts/index.ts throws as Refusal)
  fn refused(e : Error) -> Error {
    match e {
      @accounts_pool.Thrown(kind, said) =>
        @api_routes.Thrown(if kind == "Refusal" { "Refused" } else { kind }, @jsjson.JV::of_json(p53_json(said)))
      @api_routes.Thrown(_, _) => e
      _ => @api_routes.Thrown("Error", @jsjson.JV::of_json(jobj_of([("message", jstr(p53_words(e)))])))
    }
  }
  try {
    // ── the sign-ins (accounts.ts `logins`: the routes' code, page, its state and cancel) ──
    if m.has_prefix("logins.") {
      let args = match arg {
        Array(xs) => xs
        Null => []
        v => [v]
      }
      match self.sign_in_answer(m, args) {
        Some(v) => return v
        None => raise P53Error("no sign-ins' ask \{m}")
      }
    }
    let sessions = () => match self.sessions {
      Some(sa) => sa
      None => raise P53Error("the accounts are not ready yet; ask again in a moment")
    }
    match m {
      // ── forHub: what the hub, the actors and the drivers ask of each session's accounts ──
      "pick" => {
        let sa = sessions()
        let cfg = self.made().hub_config()
        let ids = match at(0, "candidates") {
          Array(xs) => xs.filter_map(x => if x is String(t) { Some(t) } else { None })
          _ => []
        }
        let candidates = cfg.profiles.filter(p => ids.contains(p.id))
        match (try { Ok(sa.pick(cfg, candidates, str(1, "model"), at(2, "strict") is True, except?=str(3, "except"))) } catch { e => Err(e) }) {
          Ok(p) => p53_json(p.raw)
          Err(e) => jobj_of([("error", jstr(p53_words(e)))])
        }
      }
      "runOn" =>
        p53_json(
          sessions().run_on(
            text(0, "key"),
            holding=at(1, "holding") is True,
            quiet=(if positional { at(3, "") } else { jfield(arg, "quiet") }) is True,
            across=(if positional { at(2, "") } else { jfield(arg, "across") }) is True,
          ).raw,
        )
      "goesOnWith" =>
        jb(sessions().goes_on_with(@accounts_pool.Row::of_jv(given(0, "row")), text(1, "profile")))
      "resetAllowance" => {
        sessions().reset_allowance(text(0, "profile"))
        done
      }
      "change" => p53_json(sessions().change(text(0, "key"), given(1, "change"), lang(2)))
      "repick" => {
        sessions().repick(text(0, "key"))
        done
      }
      "modelEfforts" => {
        let pinned : @accounts_pool.Pinned = match at(2, "pinned") {
          String(one) => One(one)
          Array(xs) => Some_(xs.filter_map(x => if x is String(t) { Some(t) } else { None }))
          _ => None_
        }
        let allowed = match at(3, "allowed") {
          Array(xs) => Some(xs.filter_map(x => if x is String(t) { Some(t) } else { None }))
          _ => None
        }
        Json::array(
          sessions().model_efforts(text(0, "runtime"), str(1, "model"), pinned, allowed=p => match allowed {
            Some(ids) => ids.contains(p.id)
            None => true
          }).map(jstr),
        )
      }
      "limitAfter" =>
        match sessions().limit_after(text(0, "profile"), str(1, "model")) {
          OwnLimit(words) => jstr(words)
          AccountLimit => Json::null()
          NotKnown => jobj_of([("$undef", ji(1))])
        }
      "recheck" => {
        sessions().recheck(text(0, "profile"))
        done
      }
      // (agents.ts: someone follows the events again, after nobody did: the allowances read again)
      "followed" => {
        self.made().followed()
        done
      }
      "spend" =>
        match sessions().spend(text(0, "key"), str(1, "ranOn"), model?=str(2, "model")) {
          Some((left, taken)) => Json::array([jstr(left), jstr(taken)])
          None => Json::null()
        }
      "refillsAt" => jn(sessions().refills_at(text(0, "key")))
      "profile" =>
        match sessions().profile(text(0, "id")) {
          Some(p) => p53_json(p.raw)
          None => Json::null()
        }
      "allows" =>
        match sessions().profile(match at(1, "profile") { String(id) => id; v => jtext_or_empty(v, "id") }) {
          Some(p) => jb(sessions().allows(text(0, "key"), p))
          None => jb(false)
        }
      "healthOf" => p53_json(sessions().health_of(self.made().hub_config(), text(0, "id")).to_jv())
      "sameAccount" => jb(sessions().same_account(text(0, "a"), text(1, "b")))
      // ── the accounts themselves (accounts/index.ts): the routes' and the agents' tools' ──
      "state" => self.state()
      "profiles" => Json::array(self.made().profiles().map(p => p53_json(p.raw)))
      "claudeToken" => p53_json(self.made().claude_token(given(0, "profile"), str(1, "rejected"), at(2, "lent") is True))
      "machineToken" => {
        // (accounts/index.ts `machineToken(env, rejected, lent)`: the token the driver saw refused, renewed, never given again)
        let rejected = match str(0, "rejected") {
          Some(r) => Some(r)
          None => str(0, "runtime")
        }
        p53_json(self.made().machine_token(rejected, at(1, "lent") is True))
      }
      "putProfile" => {
        self.made().put_profile(text(0, "id"), given(1, "body"), given(2, "viewer"), lang(3))
        done
      }
      "deleteProfile" => {
        let id = text(0, "id")
        self.made().delete_profile(id, given(1, "viewer"), lang(2))
        self.bus.hub_profile_gone(id) catch { _ => () }
        done
      }
      "newKeyedProfile" => jstr(self.made().new_keyed_profile(given(0, "body"), given(1, "viewer"), lang(2)))
      "newMachineProfile" => jstr(self.made().new_machine_profile(given(0, "body"), given(1, "viewer"), lang(2)))
      "startLogin" => p53_json(self.made().start_login(text(0, "id"), given(1, "viewer"), lang(2)))
      "newLogin" => p53_json(self.made().new_login(given(0, "body"), given(1, "viewer"), lang(2)))
      "hasPending" => jb(self.made().has_pending(text(0, "id")))
      "dropLogin" => {
        self.made().drop_login(text(0, "id"))
        done
      }
      "check" => p53_json(self.made().check(text(0, "id"), lang(1)))
      "askedQuota" =>
        match self.made().asked_quota(text(0, "id")) {
          Some(q) => p53_json(q)
          None => Json::null()
        }
      "refreshQuota" =>
        match self.made().refresh_quota(text(0, "id")) {
          Some(q) => p53_json(q)
          None => Json::null()
        }
      "resetQuota" => p53_json(self.made().reset_quota(text(0, "id"), text(1, "key"), lang(2), str(3, "kind")))
      "decisionModels" => p53_json(self.made().decision_models())
      "putAutomaticDecisions" => {
        self.made().put_automatic_decisions(given(0, "body"), given(1, "viewer"), lang(2))
        done
      }
      "putArchiving" => {
        self.made().put_archiving(given(0, "body"), given(1, "viewer"), lang(2))
        done
      }
      "putArchivePolicy" => {
        self.made().put_archive_policy(given(0, "body"), given(1, "viewer"), lang(2))
        done
      }
      "reviewUndecided" => jn(self.made().review_undecided(given(0, "viewer"), lang(1)))
      "refreshDecisionModels" => {
        self.made().refresh_decision_models(given(0, "viewer"), lang(1))
        done
      }
      "automaticDecisionsView" => {
        // (only the chats the viewer's workspace has, each by its chat's name: overview.ts `mine`, `title`)
        let store = self.bus.store
        let seen = @events.Viewer::of(to_jv(at(0, "viewer")))
        p53_json(
          self.made().automatic_decisions_view(
            given(0, "viewer"),
            include_policy=!(at(1, "includePolicy") is False),
            visible=async fn(session) { @events.sees(seen, to_jv(store.session_ws(session) catch { _ => Json::null() })) },
            title=async fn(session) { jtext_or_empty(store.get_session(session) catch { _ => Json::null() }, "title") },
            // (the decisions' models the overview asked already, not made again: `decisionModels`)
            models?=match at(2, "models") {
              Array(_) as m => Some(@jsjson.JV::of_json(m))
              _ => None
            },
          ),
        )
      }
      "profilesView" => p53_json(self.made().profiles_view(viewer(0)))
      "paceView" => p53_json(self.made().pace_view(viewer(0)))
      "fusionView" => p53_json(self.made().fusion_view(text(0, "id")))
      "loginsView" => p53_json(self.made().logins_view())
      "machineLogins" => p53_json(self.made().machine_logins())
      // (agents.ts `accounts.machine?.refresh()`: a runtime installed or updated, the machine's logins read again)
      "machineRefresh" => {
        match self.machine {
          Some(m) => m.refresh()
          None => ()
        }
        done
      }
      "apiProviders" => p53_json(@accounts_pool.api_providers())
      "homesReadSoon" => {
        self.made().homes_read_soon()
        done
      }
      "refreshQuotas" => {
        self.made().refresh_quotas(at(0, "force") is True)
        done
      }
      "recheckBorrowed" => {
        self.made().recheck_borrowed()
        done
      }
      "newModels" => {
        self.new_models(match at(0, "keys") { Array(xs) => xs.filter_map(x => if x is String(t) { Some(t) } else { None }); _ => [] })
        done
      }
      "accountEmail" =>
        match self.made().account_email(text(0, "runtime"), text(1, "home")) {
          Some(e) => jstr(e)
          None => Json::null()
        }
      _ => raise P53Error("no accounts' ask \{m}")
    }
  } catch {
    e => raise refused(e)
  }
}

///|
fn P53Accounts::sharing(self : P53Accounts) -> @share_sync.Sharing raise P53Error {
  match self.sharing {
    Some(s) => s
    None => raise P53Error("the shared profiles are not ready yet")
  }
}

///|
/// Whether there is something at `path`.
async fn p53_exists(host : @host.Host, path : String) -> Bool {
  match (try { Ok(host.shell("fs.stat", { "path": Json::string(path) })) } catch { e => Err(e) }) {
    Ok((String(_), _)) => true
    _ => false
  }
}

///|
/// A random UUID (v4), as crypto.randomUUID makes one.
fn p53_uuid() -> String {
  let b = @drive.random_bytes(16)
  let h = @drive.hex(b).to_array()
  // (its version and variant)
  h[12] = '4'
  h[16] = match h[16] {
    '0' | '4' | '8' | 'c' => '8'
    '1' | '5' | '9' | 'd' => '9'
    '2' | '6' | 'a' | 'e' => 'a'
    _ => 'b'
  }
  let s = String::from_array(h)
  "\{s[0:8]}-\{s[8:12]}-\{s[12:16]}-\{s[16:20]}-\{s[20:32]}"
}

// ── the model catalog (models/module.ts) ──

///|
priv struct P53Models {
  bus : LiveBus
  accounts : P53Accounts
  /// What the catalog says (catalog.ts's table), told on to the accounts' (`P53Accounts::pool_catalog`).
  told : @accounts_oauth.Catalog
  mut catalog : @accounts_oauth.ModelCatalog?
  /// The last catalog version applied to the main process (`@readops.learn_catalog` and `P53Accounts::pool_catalog`).
  mut learned_version : Double
  /// The cloud said the catalog changed before what was kept was read (Some: to that ETag, if it named one): asked for
  /// once it is.
  mut pending : String??
}

///|
fn P53Models::new(bus : LiveBus, accounts : P53Accounts) -> P53Models {
  { bus, accounts, told: @accounts_oauth.Catalog::new(), catalog: None, learned_version: 0.0, pending: None }
}

///|
/// still.fail cloud's origin, where the station is in a workspace of its (models/module.ts `origin`: none where the
/// plane is Comma's, which serves no catalog).
fn p53_origin(bus : LiveBus) -> String? {
  let cloud = p53_cloud(bus)
  guard @cloud_net.provider_of(Some(jfield(cloud, "provider"))) is Stillfail else { return None }
  match jtext(cloud, "origin") {
    Some(o) if o != "" => Some(o)
    _ => None
  }
}

///|
/// What the catalog says now, given the accounts (their makers' profiles and prices read it) and the main process's
/// session-usage pricing (`@readops.model_catalog`), then repricing any session usage with unpriced calls.
fn P53Models::learned(self : P53Models) -> Unit {
  let snap = self.told.snapshot()
  let version = match snap {
    { "version": Number(v, ..), .. } => v
    _ => 0.0
  }
  if version == self.learned_version {
    return
  }
  self.learned_version = version
  let models : Map[String, @accounts_pool.JV] = Map::new()
  if snap is { "models": Object(m) as json, .. } {
    @readops.learn_catalog(json)
    for k, v in m {
      models[k] = @jsjson.JV::of_json(v)
    }
  } else {
    @readops.learn_catalog(Json::null())
  }
  self.accounts.pool_catalog.models = models
  if !self.bus.as_rig() {
    ignore(
      self.bus.host.rt.fork_quiet(name="reprice session usage", async fn() {
        ignore((self.bus.hub_ask.val)("usage.reprice", Json::array([]))) catch {
          _ => ()
        }
      }),
    )
  }
}

///|
fn P53Models::attach(self : P53Models) -> Unit {
  let bus = self.bus
  let not_read = (e : Error) => slice_log(
    "info",
    "models",
    "the model catalog was not read",
    jobj_of([("error", jstr(p53_words(e)))]),
  )
  ignore(
    bus.host.rt.fork_daemon("model catalog", on_error=e => @host.note("model catalog failed: \{e}"), async fn() {
      let catalog = @accounts_oauth.ModelCatalog::open(
        self.accounts.oauth_io,
        self.told,
        @nodepath.join(sep(), [bus.data, "model-catalog.json"]),
        () => p53_origin(bus),
        added=keys => {
          self.learned()
          self.accounts.new_models(keys)
        },
        learned=() => self.learned(),
      ) catch {
        e => {
          not_read(e)
          return
        }
      }
      self.catalog = Some(catalog)
      self.learned()
      // (asked for in the background at the start, and as the cloud says it changed: its presence socket, `models`)
      self.refresh(None) catch {
        e => not_read(e)
      }
      // (what the cloud said meanwhile, while what was kept was read)
      if self.pending is Some(etag) {
        self.pending = None
        self.refresh(etag) catch {
          e => not_read(e)
        }
      }
    }),
  )
  // (the readers' prices are the catalog's as well: read/pool.ts `give`)
  bus.model_catalog.val = () => self.told.snapshot()
  bus.parts.routes([
    {
      meth: "GET",
      path: "/models",
      answer: async fn(_r) {
        let file = @nodepath.join(sep(), [bus.data, "model-catalog.json"])
        match shell_read_text(bus.host, file) {
          Some(t) => attempt(() => @json.parse(t)).unwrap_or(Json::null())
          None => Json::null()
        }
      },
    },
  ])
}

///|
/// The cloud said the catalog changed (to `etag`): asked for again, once what was kept is read if it is not yet.
async fn P53Models::refresh(self : P53Models, etag : String?) -> Unit {
  match self.catalog {
    Some(c) => {
      match etag {
        Some(e) => c.refresh(etag=e)
        None => c.refresh()
      }
      self.learned()
    }
    None => self.pending = Some(etag)
  }
}

///|
/// Once what it read of the cloud is written (the station stopping: models/module.ts's finalizer).
async fn P53Models::written(self : P53Models) -> Unit {
  if self.catalog is Some(c) {
    c.written()
  }
}

///|
/// The accounts' IO (`@accounts_oauth.host_io`) with the times it keeps (an expiry, when a lock was taken) since the
/// epoch.
fn p5_oauth_io(host : @host.Host) -> @accounts_oauth.Io {
  { ..@accounts_oauth.host_io(host), now: () => p5_epoch_ms(), wall: () => p5_epoch_ms() }
}
