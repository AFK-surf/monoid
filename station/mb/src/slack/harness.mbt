// The tests' way in (station/test/mb-slack.test.ts, through stillfail-reader `--builder harness-slack`), held to the
// TypeScript of station/src/slack on the same cases. A JSON line a case on stdin, `{seq, op, …}`; its answer a line
// `{re: seq, ok}` or `{re: seq, error, kind, …}`. `op` is "words" (the station's words), "lang", "wall" (the wall's time, `now`), "fn" (a function of
// no connection, by its TypeScript name, `args`), "new" (a client, an app API, a surface or an upgrade of the
// connects' apps, kept by `id`) and "call" (one of those asked, `id`, `name`, `args`). What they ask of the station
// meanwhile (a surface's handler, `onWorking`, the configuration tokens saved) is said `{ask: n, name, of, args}` and
// answered `{answer: n, result}` or `{answer: n, threw}`; what is only told (a name learned) `{tell, of, args}`. Its
// HTTP and Socket Mode are the shell's, to the test's stand-in for Slack.

///|
priv struct Harness {
  host : @host.Host
  words : Ref[Words]
  lang : Ref[String]
  asks : Map[Int, @effect.Deferred[J]]
  mut next_ask : Int
  clients : Map[String, SlackClient]
  apps : Map[String, SlackApps]
  tokens : Map[String, Array[J]]
  surfaces : Map[String, SlackSurface]
  books : Map[String, NameBook]
  upgrades : Map[String, Upgrades]
  configs : Map[String, Ref[J]]
  wall : Wall
}

///|
fn Harness::say(self : Harness, v : J) -> Unit {
  self.host.say(stringify(v))
}

///|
/// The test asked something and waits for its answer: what it returns, or what it threw (raised here as it said it).
async fn Harness::ask(self : Harness, name : String, of : String, args : Array[J]) -> J {
  self.next_ask += 1
  let n = self.next_ask
  let d : @effect.Deferred[J] = @effect.Deferred::new()
  self.asks[n] = d
  self.say(jo([("ask", ji(n)), ("name", js(name)), ("of", js(of)), ("args", ja(args))]))
  d.wait()
}

///|
fn Harness::tell(self : Harness, name : String, of : String, args : Array[J]) -> Unit {
  self.say(jo([("tell", js(name)), ("of", js(of)), ("args", ja(args))]))
}

///|
fn arg(args : Array[J], i : Int) -> J? {
  if i < args.length() {
    match args[i] {
      Null => Some(Null)
      v => Some(v)
    }
  } else {
    None
  }
}

///|
fn sarg(args : Array[J], i : Int) -> String {
  text(arg(args, i))
}

///|
fn oarg(args : Array[J], i : Int) -> String? {
  str_of(arg(args, i))
}

///|
fn params_arg(v : J?) -> Params {
  arr(v).map(p => (text(at_i(Some(p), 0)), text(at_i(Some(p), 1))))
}

///|
fn bytes_arg(v : J?) -> Bytes {
  @base64.decode(text(v)) catch {
    _ => b""
  }
}

///|
fn words_arg(v : J?) -> CardWords {
  match at(v, "markdown") {
    Some(Str(u)) => Markdown(@jsjson.sanitize_str(u))
    _ => Blocks(arr(at(v, "blocks")))
  }
}

///|
fn models_arg(v : J?) -> Array[ModelChoice] {
  arr(v).filter_map(m => ModelChoice::of_j(Some(m)))
}

///|
fn opt_j(v : J?) -> J {
  match v {
    Some(x) => x
    None => Null
  }
}

///|
/// An error as the test compares it: its message, its kind, and of Slack's app API its code and details.
fn error_j(e : Error) -> Array[(String, J)] {
  let kind = match e {
    SlackApiError(_, _, _) => "SlackApiError"
    SlackWords(_, _) => "SlackWords"
    Thrown(k, _) => k
    _ => ""
  }
  let fs = [("error", js(message_of(e))), ("kind", js(kind))]
  match e {
    SlackApiError(m, c, d) => {
      fs.push(("method", js(m)))
      fs.push(("code", js(c)))
      fs.push(("details", opt_j(d)))
    }
    SlackWords(k, _) => fs.push(("key", js(k)))
    _ => ()
  }
  fs
}

///|
/// An error as a case's argument says it, for `slackError`: `{api: [method, code, details]}`, `{words: key}`, or
/// `{message}`.
fn Harness::error_arg(self : Harness, v : J?) -> Error {
  match at(v, "api") {
    Some(Arr(xs)) =>
      SlackApiError(text(at_i(Some(Arr(xs)), 0)), text(at_i(Some(Arr(xs)), 1)), match at_i(Some(Arr(xs)), 2) {
        None | Some(Null) => None
        d => d
      })
    _ =>
      match str_of(at(v, "words")) {
        Some(k) => slack_words(self.words.val, self.lang.val, k)
        None => fail_(text(at(v, "message")))
      }
  }
}

///|
/// A function of no connection, by its TypeScript name.
fn Harness::pure(self : Harness, name : String, args : Array[J]) -> J raise {
  let words = self.words.val
  let lang = self.lang.val
  match name {
    // zip.ts
    "connectBlocked" => jb(connect_blocked(sarg(args, 0)))
    "zipOne" => js(@base64.encode(zip_one(sarg(args, 0), bytes_arg(arg(args, 1)))))
    // cards.ts
    "markdown" => markdown(sarg(args, 0))
    "questionBlocks" => ja(question_blocks(words, sarg(args, 0), arg(args, 1), lang))
    "loginBlocks" =>
      ja(
        login_blocks(words, sarg(args, 0), lang, page=arg(args, 1), shown=match arg(args, 2) {
          Some(Bool(b)) => b
          _ => true
        }),
      )
    "loginEnteredBlocks" => ja(login_entered_blocks(words, words_arg(arg(args, 0)), sarg(args, 1), lang))
    "loginCodeOf" => jopt(login_code_of(arg(args, 0)))
    "answeredBlocks" => ja(answered_blocks(words, words_arg(arg(args, 0)), sarg(args, 1), sarg(args, 2), lang))
    "endedBlocks" => ja(ended_blocks(sarg(args, 0), sarg(args, 1)))
    "standsBlock" =>
      match Stands::of_j(arg(args, 0)) {
        Some(s) => stands_block(words, s, lang)
        None => Null
      }
    "standsText" =>
      match Stands::of_j(arg(args, 0)) {
        Some(s) => js(stands_text(words, s, lang))
        None => Null
      }
    "answerOf" =>
      match answer_of(arg(args, 0)) {
        Some((said, field)) => jo([("said", js(said)), ("field", jb(field))])
        None => Null
      }
    // new-chat.ts
    "modelLabel" =>
      match ModelChoice::of_j(arg(args, 0)) {
        Some(m) => js(model_label(words, m, lang))
        None => Null
      }
    "modelValue" =>
      match ModelChoice::of_j(arg(args, 0)) {
        Some(m) => js(model_value(m))
        None => Null
      }
    "modelOf" =>
      match model_of(arg(args, 0)) {
        Some(m) => m.to_j()
        None => Null
      }
    "modelOptions" => ja(model_options(words, models_arg(arg(args, 0)), sarg(args, 1), lang))
    "newChatView" => new_chat_view(words, models_arg(arg(args, 0)), sarg(args, 1), sarg(args, 2), lang)
    "submittedChat" =>
      match submitted_chat(arg(args, 0)) {
        Some(s) => s.to_j()
        None => Null
      }
    "newChatBlocks" =>
      match ModelChoice::of_j(arg(args, 1)) {
        Some(m) => {
          let (t, bs) = new_chat_blocks(words, sarg(args, 0), m, sarg(args, 2), lang)
          jo([("text", js(t)), ("blocks", ja(bs))])
        }
        None => Null
      }
    // apps.ts
    "SLACK_GROUPS" => ja(slack_groups.map(g => g.to_j()))
    "settingsOf" => settings_of(arg(args, 0))
    "applySettings" => apply_settings(arg(args, 0), arg(args, 1))
    "withStopEvent" => opt_j(with_stop_event(arg(args, 0)))
    "withCommand" => with_command(opt_j(arg(args, 0)))
    "upgraded" => opt_j(upgraded(opt_j(arg(args, 0))))
    "withSocketMode" => with_socket_mode(arg(args, 0), is_true(arg(args, 1)))
    "botScopes" => jsa(bot_scopes())
    "slackManifest" => slack_manifest(sarg(args, 0), description=oarg(args, 1), redirect_url=oarg(args, 2))
    "createAppUrl" => js(create_app_url(sarg(args, 0)))
    "slackError" => js(slack_error(words, self.error_arg(arg(args, 0)), lang))
    "slackAppLinks" => slack_app_links(sarg(args, 0), oarg(args, 1))
    "upsertToken" => ja(upsert_token(arr(arg(args, 0)), opt_j(arg(args, 1))))
    "shapeOf" => shape_of(opt_j(arg(args, 0)))
    // index.ts
    "slackShown" => slack_shown(arg(args, 0))
    "slackConnects" => ja(slack_connects(arg(args, 0)).map(c => c.to_j()))
    "configTokens" => ja(config_tokens(arg(args, 0)))
    "madeApps" => ja(made_apps(arg(args, 0)))
    "slackOverview" => slack_overview(arg(args, 0), sarg(args, 1))
    "maskValue" => js(mask_value(sarg(args, 0)))
    "connectName" =>
      match slack_connects(Some(jo([("connects", ja([opt_j(arg(args, 0))]))]))) {
        [c] => js(connect_name(c))
        _ => Null
      }
    "credentials" =>
      match slack_connects(Some(jo([("connects", ja([opt_j(arg(args, 0))]))]))) {
        [c] => jopt(slack_credentials(c))
        _ => Null
      }
    "seen" =>
      match slack_connects(Some(jo([("connects", ja([opt_j(arg(args, 0))]))]))) {
        [c] =>
          match slack_seen(c, identity_arg(arg(args, 1))) {
            Some(write) => write(opt_j(arg(args, 0)))
            None => Null
          }
        _ => Null
      }
    // surface.ts
    "messageText" => js(message_text(arg(args, 0)))
    "messageFiles" => ja(message_files(arg(args, 0)))
    "filesToLookUp" => ja(files_to_look_up(arg(args, 0)).map(js))
    "answerFiles" => ja(answer_files(arg(args, 0)))
    "toEvent" => opt_j(to_event(arg(args, 0), sarg(args, 1), sarg(args, 2)))
    "personOf" => person_of(arg(args, 0))
    // connects/card-ends.ts
    "endedWords" => js(ended_words(words, arg(args, 0), arg(args, 1), oarg(args, 2), lang))
    // web.ts
    "field" => js(field(opt_j(arg(args, 0))))
    "formEncoded" => js(form_encoded(params_arg(arg(args, 0))))
    "httpDate" =>
      match http_date(sarg(args, 0)) {
        Some(d) => jn(d)
        None => Null
      }
    "apiBase" => js(api_base(oarg(args, 0)))
    _ => raise fail_("no such function: \{name}")
  }
}

///|
fn identity_arg(v : J?) -> BotIdentity {
  {
    team: text(at(v, "team")),
    team_id: text(at(v, "teamId")),
    url: text(at(v, "url")),
    bot_user_id: text(at(v, "botUserId")),
    bot_name: text(at(v, "botName")),
    bot_image: str_of(at(v, "botImage")),
    bot_id: text(at(v, "botId")),
  }
}

///|
fn Harness::client(self : Harness, id : String) -> SlackClient raise {
  match self.clients.get(id) {
    Some(c) => c
    None => raise fail_("no client \{id}")
  }
}

///|
fn Harness::log(_self : Harness) -> Log {
  (level, part, words, fields) => @host.note("\{level} \{part}: \{words} \{stringify(fields)}")
}

///|
/// Something made, kept by its id.
async fn Harness::make(self : Harness, c : J) -> J {
  let id = text(at(Some(c), "id"))
  match text(at(Some(c), "kind")) {
    "client" => {
      let timeout = match at(Some(c), "timeoutMs") {
        Some(Num(d)) => d.to_int()
        _ => 30000
      }
      self.clients[id] = SlackClient::new(host_net(self.host, self.wall), base=text(at(Some(c), "base")), timeout_ms=timeout)
    }
    "apps" => {
      self.tokens[id] = arr(at(Some(c), "tokens"))
      let apps = SlackApps::new(
        self.client(text(at(Some(c), "client"))),
        () => self.tokens.get(id).unwrap_or([]),
        async fn(token) {
          self.tokens[id] = upsert_token(self.tokens.get(id).unwrap_or([]), token)
          ignore(self.ask("save", id, [token]))
        },
        self.words.val,
        self.lang,
        self.log(),
      )
      self.apps[id] = apps
    }
    "surface" => {
      let clock = host_clock(self.host)
      let book = if is_true(at(Some(c), "book")) {
        let b = NameBook::new(clock)
        b.on_learn(() => self.tell("learned", id, []))
        self.books[id] = b
        Some(b)
      } else {
        None
      }
      let models = models_arg(at(Some(c), "models"))
      let first = match at(Some(c), "first") {
        Some(Arr(_) as f) => Some(models_arg(Some(f)))
        _ => None
      }
      let o = SurfaceOptions::new(
        text(at(Some(c), "appToken")),
        text(at(Some(c), "botToken")),
        self.client(text(at(Some(c), "client"))),
        clock,
        host_ws(self.host),
        self.words.val,
        self.lang,
        self.log(),
        host_read_file(self.host),
        connect=str_of(at(Some(c), "connect")),
        book~,
        ping_ms=match at(Some(c), "pingMs") {
          Some(Num(d)) => d.to_int()
          _ => 5000
        },
        stale_ms=match at(Some(c), "staleMs") {
          Some(Num(d)) => d.to_int()
          _ => 20000
        },
        backoff_ms=match at(Some(c), "backoffMs") {
          Some(Num(d)) => d.to_int()
          _ => 1000
        },
        on_working=async fn() { is_true(Some(self.ask("onWorking", id, []))) },
        models=() => models,
        models_first=match first {
          Some(f) => Some(_ => f)
          None => None
        },
      )
      let surface = SlackSurface::new(o)
      surface.on_change(() => self.tell("changed", id, []))
      self.surfaces[id] = surface
    }
    "upgrades" => {
      // config.json as the test keeps it, connects all connected that may be (connects/connections.ts `state`)
      let config = Ref(opt_j(at(Some(c), "raw")))
      self.configs[id] = config
      let identity = at(Some(c), "identity")
      let view : ConnectsView = {
        connects: () => slack_connects(Some(config.val)),
        state: cid => match slack_connects(Some(config.val)).search_by(x => x.id == cid) {
          Some(i) => {
            let x = slack_connects(Some(config.val))[i]
            if !x.enabled {
              Some("disabled")
            } else if slack_credentials(x) is None {
              Some("no_tokens")
            } else {
              Some("connected")
            }
          }
          None => None
        },
        chat: cid => match slack_connects(Some(config.val)).search_by(x => x.id == cid) {
          Some(_) => Some((str_of(at(identity, "teamId")), text(at(identity, "botUserId"))))
          None => None
        },
        bound: () => !is_true(at(Some(config.val), "$unbound")),
        in_workspace: _ => true,
        raw: () => config.val,
      }
      let apps = SlackApps::new(
        self.client(text(at(Some(c), "client"))),
        () => config_tokens(Some(config.val)),
        async fn(token) {
          config.val = kept_config_token(config.val, token)
          ignore(self.ask("save", id, [token]))
        },
        self.words.val,
        self.lang,
        self.log(),
      )
      self.upgrades[id] = Upgrades::new(view, apps, self.log(), f => host_clock(self.host).run(f))
    }
    k => raise fail_("nothing of kind \{k}")
  }
  Null
}

///|
fn thread_arg(v : J?) -> (String, String) {
  (text(at(v, "channel")), text(at(v, "threadTs")))
}

///|
/// One of what was made, asked.
async fn Harness::call(self : Harness, id : String, name : String, args : Array[J]) -> J {
  match self.clients.get(id) {
    Some(cl) => return self.call_client(cl, name, args)
    None => ()
  }
  match self.apps.get(id) {
    Some(a) => return self.call_apps(id, a, name, args)
    None => ()
  }
  match self.surfaces.get(id) {
    Some(s) => return self.call_surface(id, s, name, args)
    None => ()
  }
  match self.upgrades.get(id) {
    Some(u) =>
      return match name {
        "set" => {
          match self.configs.get(id) {
            Some(r) => r.val = opt_j(arg(args, 0))
            None => ()
          }
          Null
        }
        "raw" =>
          match self.configs.get(id) {
            Some(r) => r.val
            None => Null
          }
        "upgradeApps" => {
          u.upgrade_apps()
          Null
        }
        "onWorking" => jb(u.on_working(sarg(args, 0)))
        "settled" => {
          // (what is under way waited for, and what it set going after)
          while u.upgrading.length() > 0 {
            for d in u.upgrading.values().collect() {
              d.wait() catch {
                _ => ()
              }
            }
          }
          Null
        }
        "close" => {
          u.close()
          Null
        }
        _ => raise fail_("no such call: \{name}")
      }
    None => ()
  }
  raise fail_("nothing made as \{id}")
}

///|
async fn Harness::call_client(self : Harness, cl : SlackClient, name : String, args : Array[J]) -> J {
  let words = self.words.val
  match name {
    "api" => cl.api(sarg(args, 0), params_arg(arg(args, 1)), sarg(args, 2))
    "app" => {
      let file = match arg(args, 3) {
        Some(Obj(_) as f) =>
          Some({ bytes: bytes_arg(at(Some(f), "bytes")), name: text(at(Some(f), "name")), mime: text(at(Some(f), "mime")) })
        _ => None
      }
      match file {
        Some(f) => cl.app(sarg(args, 0), oarg(args, 1), params_arg(arg(args, 2)), file=f)
        None => cl.app(sarg(args, 0), oarg(args, 1), params_arg(arg(args, 2)))
      }
    }
    "download" => {
      let b = cl.download(sarg(args, 0), sarg(args, 1), sarg(args, 2))
      js(@base64.encode(b))
    }
    "upload" => {
      cl.upload(sarg(args, 0), bytes_arg(arg(args, 1)), sarg(args, 2))
      Null
    }
    "localTimeUpper" =>
      match cl.local_time_upper(sarg(args, 0)) {
        Some(t) => jn(t)
        None => Null
      }
    "hasScope" => jb(cl.has_scope(sarg(args, 0), sarg(args, 1)))
    "base" => js(cl.base)
    "identityOf" => identity_of(cl, sarg(args, 0)).to_j()
    "verifySlackTokens" => {
      let (i, errors) = verify_slack_tokens(words, cl, sarg(args, 0), sarg(args, 1), self.lang.val)
      ja([opt_j(i), jsa(errors)])
    }
    "exchangeInstallCode" => {
      let (token, team) = exchange_install_code(cl, sarg(args, 0), sarg(args, 1), sarg(args, 2), sarg(args, 3))
      ja([js(token), jopt(team)])
    }
    "rotateConfigToken" => rotate_config_token(cl, sarg(args, 0))
    "appIdOf" => js(app_id_of(cl, sarg(args, 0)))
    "ownerOfConfigToken" => opt_j(owner_of_config_token(cl, sarg(args, 0)))
    _ => raise fail_("no such call: \{name}")
  }
}

///|
async fn Harness::call_apps(self : Harness, id : String, a : SlackApps, name : String, args : Array[J]) -> J {
  match name {
    "configured" => jb(a.configured(sarg(args, 0)))
    "exportManifest" => a.export_manifest(sarg(args, 0), sarg(args, 1))
    "updateManifest" => jb(a.update_manifest(sarg(args, 0), sarg(args, 1), opt_j(arg(args, 2))))
    "editManifest" => {
      // `args[2]`: what the edit does, "upgraded" (apps.ts `upgraded`), "none" (leaves it), or a manifest to put
      let how = arg(args, 2)
      jb(
        a.edit_manifest(sarg(args, 0), sarg(args, 1), async fn(m) {
          match how {
            Some(Str(_)) if text(how) == "upgraded" => upgraded(m)
            Some(Str(_)) if text(how) == "none" => None
            Some(x) => Some(x)
            None => None
          }
        }),
      )
    }
    "createApp" => a.create_app(sarg(args, 0), sarg(args, 1), opt_j(arg(args, 2)))
    "setIcon" => {
      a.set_icon(sarg(args, 0), sarg(args, 1), bytes_arg(arg(args, 2)), sarg(args, 3))
      Null
    }
    "exchangeInstallCode" => {
      let (token, team) = a.exchange_install_code(sarg(args, 0), sarg(args, 1), sarg(args, 2), sarg(args, 3))
      ja([js(token), jopt(team)])
    }
    "verifyTokens" => {
      let (i, errors) = a.verify_tokens(sarg(args, 0), sarg(args, 1), sarg(args, 2))
      ja([opt_j(i), jsa(errors)])
    }
    "tokens" => ja(self.tokens.get(id).unwrap_or([]))
    "setTokens" => {
      self.tokens[id] = arr(arg(args, 0))
      Null
    }
    "all" => {
      // several asked at once (`args[0]`: a list of `[name, args]`), each one's outcome
      let calls = arr(arg(args, 0))
      let outs = @effect.all(
        calls.map(c => async fn() -> J {
          try {
            jo([("ok", self.call_apps(id, a, text(at_i(Some(c), 0)), arr(at_i(Some(c), 1))))])
          } catch {
            e => jo(error_j(e))
          }
        }),
      )
      ja(outs)
    }
    _ => raise fail_("no such call: \{name}")
  }
}

///|
async fn Harness::call_surface(self : Harness, id : String, s : SlackSurface, name : String, args : Array[J]) -> J {
  match name {
    "start" => {
      s.start(async fn(event) { ignore(self.ask("handler", id, [event])) })
      Null
    }
    "stop" => {
      s.stop()
      match self.books.get(id) {
        Some(b) => b.close()
        None => ()
      }
      Null
    }
    "identity" =>
      match s.identity() {
        Some(i) => i.to_j()
        None => Null
      }
    "socket" => {
      let (connected, last) = s.socket()
      jo([("connected", jb(connected)), ("lastError", jopt(last))])
    }
    "botUserId" => js(s.bot_user_id())
    "botName" => js(s.bot_name())
    "workspace" => jopt(s.workspace())
    "platform" => js(s.platform())
    "refreshIdentity" => {
      s.refresh_identity()
      Null
    }
    "post" => {
      let (channel, thread_ts) = thread_arg(arg(args, 0))
      js(s.post(channel, thread_ts, sarg(args, 1), arr(arg(args, 2)), card=arg(args, 3)))
    }
    "begin" => {
      let channel = sarg(args, 0)
      let root = s.begin(channel, sarg(args, 1))
      jo([("thread", jo([("channel", js(channel)), ("threadTs", js(root))])), ("ts", js(root))])
    }
    "edit" => {
      let (channel, thread_ts) = thread_arg(arg(args, 0))
      jb(s.edit(channel, thread_ts, sarg(args, 1), sarg(args, 2)))
    }
    "standsAt" => {
      let (channel, thread_ts) = thread_arg(arg(args, 0))
      s.stands_at(channel, thread_ts, Stands::of_j(arg(args, 1)))
      Null
    }
    "cardEnded" => {
      let (channel, thread_ts) = thread_arg(arg(args, 0))
      s.card_ended(channel, thread_ts, sarg(args, 1), sarg(args, 2), arg(args, 3), arg(args, 4))
      Null
    }
    "places" => ja(s.places())
    "openPlaces" => ja(s.open_places())
    "join" => {
      s.join(sarg(args, 0))
      Null
    }
    "joins" => jb(s.joins())
    "peopleIn" => ja(s.people_in(sarg(args, 0)))
    "permalink" => {
      let (channel, thread_ts) = thread_arg(arg(args, 0))
      jopt(s.permalink(channel, thread_ts))
    }
    "threadOf" =>
      match s.thread_of(sarg(args, 0)) {
        Some((c, t)) => jo([("channel", js(c)), ("threadTs", js(t))])
        None => Null
      }
    "sharedOut" => jb(s.shared_out(sarg(args, 0)))
    "channelName" => jopt(s.channel_name(sarg(args, 0)))
    "history" => {
      let (channel, thread_ts) = thread_arg(arg(args, 0))
      ja(s.history(channel, thread_ts, sarg(args, 1), js_num(arg(args, 2)).to_int()))
    }
    "download" => js(@base64.encode(s.download(opt_j(arg(args, 0)))))
    "answerFiles" => ja(answer_files(arg(args, 0)))
    "api" => s.api(sarg(args, 0), opt_j(arg(args, 1)))
    "working" => {
      let (channel, thread_ts) = thread_arg(arg(args, 0))
      s.working(channel, thread_ts, oarg(args, 1), sarg(args, 2), page=oarg(args, 3))
      Null
    }
    "userName" => jopt(s.user_name(sarg(args, 0)))
    "userEmail" => jopt(s.user_email(sarg(args, 0)))
    "userOf" => jopt(s.user_of(sarg(args, 0)))
    "knownPerson" => opt_j(s.known_person(sarg(args, 0)))
    "knownChannel" => jopt(s.known_channel(sarg(args, 0)))
    _ => raise fail_("no such call: \{name}")
  }
}

///|
/// The program's harness: cases a line each, answered as each ends, until stdin ends.
pub async fn harness(host : @host.Host) -> Unit {
  let h : Harness = {
    host,
    words: Ref(Words::empty()),
    lang: Ref("zh"),
    asks: {},
    next_ask: 0,
    clients: {},
    apps: {},
    tokens: {},
    surfaces: {},
    books: {},
    upgrades: {},
    configs: {},
    wall: Wall::new(0.0),
  }
  while true {
    guard host.line() is Some(line) else { break }
    let c = parse(line) catch {
      e => {
        h.say(jo(error_j(e)))
        continue
      }
    }
    // an answer to what was asked of the test
    match at(Some(c), "answer") {
      Some(Num(n)) => {
        match h.asks.get(n.to_int()) {
          Some(d) => {
            h.asks.remove(n.to_int())
            match at(Some(c), "threw") {
              Some(Str(u)) => ignore(d.fail(fail_(@jsjson.sanitize_str(u))))
              _ => ignore(d.succeed(opt_j(at(Some(c), "result"))))
            }
          }
          None => ()
        }
        continue
      }
      _ => ()
    }
    let seq = opt_j(at(Some(c), "seq"))
    // (each case on a fiber of its own: one may wait on what the test answers while another is asked)
    ignore(
      host.rt.fork(async fn() {
        let answer = try {
          let args = arr(at(Some(c), "args"))
          let v = match text(at(Some(c), "op")) {
            "words" => {
              h.words.val = Words::new(
                opt_j(at(Some(c), "zh")),
                opt_j(at(Some(c), "en")),
                product=str_of(at(Some(c), "product")).unwrap_or("still.fail"),
              )
              J::Null
            }
            "wall" => {
              h.wall.told(js_num(at(Some(c), "now")))
              J::Null
            }
            "lang" => {
              h.lang.val = text(at(Some(c), "lang"))
              J::Null
            }
            "fn" => h.pure(text(at(Some(c), "name")), args)
            "new" => h.make(c)
            "call" => h.call(text(at(Some(c), "id")), text(at(Some(c), "name")), args)
            op => raise fail_("no such op: \{op}")
          }
          jo([("re", seq), ("ok", v)])
        } catch {
          e => jo([("re", seq)] + error_j(e))
        }
        h.say(answer)
      }),
    )
  }
}
