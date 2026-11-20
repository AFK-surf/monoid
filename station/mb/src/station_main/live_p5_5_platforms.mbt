// The other platforms' connects beside Slack's (feishu/module.ts `FeishuLive`, comma/module.ts `CommaLive`,
// group/module.ts `GroupLive`), each its package's own made with this machine's IO and kept by connects_hub's
// `make_connects` as Slack's are: Feishu's (its long connection on the shell's socket, its OpenAPI over HTTP, the apps
// made by a scan, feishu_api), Comma's (its Router's socket, the workspace's statistics and Task index, the chats it
// reads and writes in, `comma.*` on the mesh), the group's (`im/2`: each connect its own iroh endpoint, bound through the
// shell by its own key).

// ── a platform's socket on the shell (the `ws` package's WebSocket, connects_hub's `Socket`) ──

///|
/// A socket to `url` on the shell (`ws.open`, `ws.next`, `ws.send`, `ws.close`), what it says told as it comes. A
/// platform whose socket speaks in binary frames (Feishu's long connection, protobuf) asks for them (`binary`): what it
/// sends goes as binary frames too.
fn p55_shell_socket(host : @host.Host, binary? : Bool = false) -> (String, Array[(String, String)]) -> @connects_hub.Socket {
  (url, headers) => {
    let events : @effect.Queue[@connects_hub.SocketEvent] = @effect.Queue::unbounded()
    let id : Ref[Json?] = Ref(None)
    let closed = Ref(false)
    let close = () => if !closed.val {
      closed.val = true
      match id.val {
        Some(i) =>
          host.rt.fork(async fn() { ignore(host.shell("ws.close", { "id": i })) catch { _ => () } }) |> ignore
        None => ()
      }
    }
    host.rt.fork(async fn() {
      let opened = host.shell("ws.open", {
        "url": Json::string(url),
        "headers": Json::array(headers.map(h => Json::array([Json::string(h.0), Json::string(h.1)]))),
        "binary": Json::boolean(binary),
      }) catch {
        e => {
          let words = "\{e}"
          match words.find("websocket refused (") {
            Some(at) => {
              let digits = words.unsafe_substring(start=at + 19, end=words.length()).iter().take_while(c => c >= '0' && c <= '9').collect()
              let n = attempt(() => @string.parse_int(String::from_array(digits))).unwrap_or(0)
              ignore(events.try_offer(Refused(n, "")))
            }
            None => ignore(events.try_offer(Failed(words)))
          }
          return
        }
      }
      guard opened.0 is { "id": i, .. } else {
        ignore(events.try_offer(Failed("the shell gave no socket")))
        return
      }
      id.val = Some(i)
      if closed.val {
        ignore(host.shell("ws.close", { "id": i })) catch { _ => () }
        return
      }
      ignore(events.try_offer(Opened))
      while !closed.val {
        let (frame, bytes) = host.shell("ws.next", { "id": i }) catch {
          e => {
            ignore(events.try_offer(Failed("\{e}")))
            return
          }
        }
        match frame {
          { "text": String(t), .. } => ignore(events.try_offer(Said(@utf8.encode(t), false)))
          { "binary": True, .. } => ignore(events.try_offer(Said(bytes.unwrap_or(b""), true)))
          _ => {
            ignore(events.try_offer(Closed))
            return
          }
        }
      }
    })
    |> ignore
    {
      events,
      send: b => match id.val {
        Some(i) if !closed.val =>
          host.rt.fork(async fn() {
            if binary {
              ignore(host.shell("ws.send", { "id": i }, bytes=b)) catch { _ => () }
            } else {
              ignore(host.shell("ws.send", { "id": i, "text": Json::string(@utf8.decode_lossy(b)) })) catch { _ => () }
            }
          })
          |> ignore
        _ => ()
      },
      // (the shell answers the platform's pings itself, and pings nothing of its own)
      ping: () => (),
      terminate: close,
    }
  }
}

///|
fn surface_options(host : @host.Host, connect : String, book : @connects_hub.NameBook?, binary? : Bool = false) -> @connects_hub.SurfaceOptions {
  {
    connect: Some(connect),
    book,
    ping_ms: 5000.0,
    stale_ms: 20000.0,
    backoff_ms: 1000.0,
    clock: p5_connects_clock(),
    on_heard: () => (),
    log: connects_log(),
    open_socket: Some(p55_shell_socket(host, binary~)),
  }
}

///|
/// What `ConnectedSurface::base_get` and `base_call` answer for every platform.
let base_names : Array[String] = [
  "botUserId", "botName", "identity", "platform", "workspace", "cards", "working", "userName", "userEmail", "userOf",
  "refreshIdentity",
]

///|
/// A connected surface as the connects and the hub take it (connects_hub's `Connection`), its own calls first.
fn connection_of(
  base : @connects_hub.ConnectedSurface,
  calls : Array[String],
  get : (String, Array[@jsjson.JValue]) -> @jsjson.JValue?,
  call : async (String, Array[@jsjson.JValue]) -> @jsjson.JValue?,
  stop : async () -> Unit,
) -> @connects_hub.Connection {
  let geta = fn(name : String, a : Array[@jsjson.JValue]) -> @jsjson.JValue {
    match get(name, a) {
      Some(v) => v
      None => base.base_get(name, a).unwrap_or(Null)
    }
  }
  {
    surface: {
      // (what every connected surface answers, named: asking `base_get` would do it, `working` too)
      has: name => calls.contains(name) || base_names.contains(name),
      get: geta,
      call: async fn(name, a) {
        match call(name, a) {
          Some(v) => v
          None =>
            match base.base_call(name, a) {
              Some(v) => v
              None => geta(name, a)
            }
        }
      },
      remote: false,
    },
    start: async fn(handler) { base.start(handler) },
    stop: async fn() {
      stop()
      base.stop()
    },
    socket: () => base.socket(),
    identity: () => base.identity(),
    on_change: f => base.on_change(f),
    refresh_identity: async fn() { base.refresh_identity() },
  }
}

// ── Feishu ──

///|
/// A Feishu connect as the connects hand it back (`FeishuConnect::to_jv`'s fields, flat).
fn feishu_connect_of(j : @jsjson.JValue) -> @feishu.FeishuConnect? {
  let c = of_jv(j)
  if jtext_or_empty(c, "id") == "" {
    return None
  }
  let tenant = jfield(c, "tenant")
  Some({
    id: jtext_or_empty(c, "id"),
    enabled: !(jfield(c, "enabled") is False),
    app_id: jtext_or_empty(c, "appId"),
    app_secret: jtext_or_empty(c, "appSecret"),
    domain: if jtext_or_empty(c, "domain") == "lark" { "lark" } else { "feishu" },
    threads: jfield(c, "threads") is True,
    direct_threads: jfield(c, "directThreads") is True,
    bot_name: jtext(c, "botName"),
    bot_image: jtext(c, "botImage"),
    bot_open_id: jtext(c, "botOpenId"),
    tenant: match jtext(tenant, "key") {
      Some(k) => Some((k, jtext_or_empty(tenant, "name")))
      None => None
    },
    workspace: jtext(c, "workspace"),
  })
}

///|
fn feishu_thread(v : @jsjson.JValue?) -> @feishu.ThreadRef {
  let (channel, thread_ts) = thread_of_j(v)
  { channel, thread_ts }
}

///|
fn feishu_card_end(v : @jsjson.JValue?) -> @feishu.CardEnd {
  let e = match v {
    Some(x) => of_jv(x)
    None => Json::null()
  }
  match jtext_or_empty(e, "kind") {
    "message" | "byMessage" => ByMessage(jtext_or_empty(e, "user"), jtext_or_empty(e, "text"))
    "replaced" => Replaced
    "withdrawn" => Withdrawn
    _ => Closed
  }
}

///|
/// The Feishu calls a surface answers (feishu/surface.ts).
let feishu_calls : Array[String] = [
  "mention", "sessionLink", "post", "cardEnded", "download", "history", "quoted", "places", "peopleIn", "begin", "edit",
  "knownPerson", "knownChannel", "channelName", "api", "permalink", "threadOf",
]

///|
/// A Feishu surface and the connects' socket loop under it (connects/surface.ts `ConnectedSurface`).
fn feishu_connection(host : @host.Host, s : @feishu.FeishuSurface, id : String, book : @connects_hub.NameBook) -> @connects_hub.Connection {
  let base = @connects_hub.ConnectedSurface::new("feishu", surface_options(host, id, Some(book), binary=true), usable=i => {
    let c = of_jv(i)
    s.usable({
      team: jtext_or_empty(c, "team"),
      team_id: jtext_or_empty(c, "teamId"),
      url: jtext_or_empty(c, "url"),
      bot_user_id: jtext_or_empty(c, "botUserId"),
      bot_name: jtext_or_empty(c, "botName"),
      bot_image: jtext(c, "botImage"),
      bot_id: jtext_or_empty(c, "botId"),
    })
  })
  base.hooked(identify=async fn() { s.identify().to_jv() }, address=async fn() { s.address() }, run_socket=async fn(url, handler) {
    let hooks = s.socket_hooks(url, async fn(e) { handler(e) })
    let wrap = (sock : @connects_hub.Socket) => ({ send: sock.send, is_open: () => true } : @feishu.Socket)
    base.socket_to(url, {
      opened: sock => (hooks.opened)(wrap(sock)),
      message: (sock, data, _binary, at, end) => (hooks.message)(wrap(sock), data, at.to_int64()) catch {
        @feishu.FeishuError(m) => end(Some(m))
      },
      ping: sock => (hooks.ping)(wrap(sock)) catch { _ => () },
    })
  }, look_up=async fn(user) {
    match s.look_up(user) {
      Some(p) => Some(p.to_jv())
      None => None
    }
  }, look_up_email=async fn(user) { s.look_up_email(user) })
  let txt = (a : Array[@jsjson.JValue], i : Int) => match a.get(i) { Some(Str(u)) => @jsjson.sanitize_str(u); _ => "" }
  let opt = (v : String?) => match v { Some(t) => to_jv(Json::string(t)); None => @jsjson.JValue::Null }
  let get = fn(name : String, a : Array[@jsjson.JValue]) -> @jsjson.JValue? {
    match name {
      "mention" => Some(to_jv(Json::string(s.mention(txt(a, 0)))))
      "sessionLink" => Some(opt(s.session_link()))
      "knownPerson" =>
        Some(match s.known_person(txt(a, 0)) {
          Some(p) => p.to_jv()
          None => Null
        })
      "knownChannel" => Some(opt(s.known_channel(txt(a, 0))))
      "permalink" => Some(opt((try { Ok(s.permalink(feishu_thread(a.get(0)))) } catch { e => Err(e) }).to_option()))
      "platform" => Some(to_jv(Json::string(s.platform())))
      "working" => {
        s.working(feishu_thread(a.get(0)), match a.get(1) { Some(Str(u)) => Some(@jsjson.sanitize_str(u)); _ => None }, txt(a, 2), page?=match a.get(3) { Some(Str(u)) => Some(Some(@jsjson.sanitize_str(u))); _ => None })
        Some(Null)
      }
      _ => None
    }
  }
  let call = async fn(name : String, a : Array[@jsjson.JValue]) -> @jsjson.JValue? {
    match name {
      "post" => {
        let files = match a.get(2) {
          Some(Arr(xs)) => xs.map(f => ({ path: jv_text(f, "path").unwrap_or(""), name: jv_text(f, "name").unwrap_or("") } : @feishu.Attachment))
          _ => []
        }
        let card = match a.get(3) { Some(Null) | None => None; Some(c) => Some(c) }
        Some(to_jv(Json::string(s.post(feishu_thread(a.get(0)), txt(a, 1), files, card~))))
      }
      "cardEnded" => {
        s.card_ended(feishu_thread(a.get(0)), txt(a, 1), txt(a, 2), a.get(3), feishu_card_end(a.get(4)))
        Some(Null)
      }
      "download" => {
        let f = of_jv(a.get(0).unwrap_or(Null))
        let file : @feishu.InboundFile = { id: jtext_or_empty(f, "id"), name: jtext_or_empty(f, "name"), size: match jfield(f, "size") { Number(n, ..) => n.to_int(); _ => 0 }, url: jtext(f, "url") }
        Some(to_jv(Json::string(@drive.hex(s.download(file)))))
      }
      "history" =>
        Some(Arr(s.history(feishu_thread(a.get(0)), txt(a, 1), match a.get(2) { Some(Num(n)) => n.to_int(); _ => 50 }).map(m => m.to_jv())))
      "quoted" =>
        Some(match s.quoted(feishu_thread(a.get(0)), txt(a, 1)) {
          Some(m) => m.to_jv()
          None => Null
        })
      "places" => Some(Arr(s.places().map(p => to_jv({ "id": Json::string(p.id), "name": Json::string(p.name), "kind": Json::string(p.kind) }))))
      "peopleIn" => Some(Arr(s.people_in(txt(a, 0)).map(m => to_jv({ "id": Json::string(m.id), "name": Json::string(m.name) }))))
      "begin" => {
        let (t, ts) = s.begin(txt(a, 0), txt(a, 1))
        Some(to_jv({ "thread": { "channel": Json::string(t.channel), "threadTs": Json::string(t.thread_ts) }, "ts": Json::string(ts) }))
      }
      "edit" => Some(Bool(s.edit(feishu_thread(a.get(0)), txt(a, 1), txt(a, 2))))
      "channelName" => Some(opt(s.channel_name(txt(a, 0))))
      "userName" => Some(opt(s.user_name(txt(a, 0))))
      "userEmail" => Some(opt(s.user_email(txt(a, 0))))
      "userOf" => Some(opt(s.user_of(txt(a, 0))))
      "api" =>
        Some(match s.api(txt(a, 0), a.get(1).unwrap_or(Null)) {
          Data(v) => v
          File(bytes, name, kind) => to_jv({ "file": Json::string(@drive.hex(bytes)), "name": Json::string(name), "type": Json::string(kind) })
        })
      _ => None
    }
  }
  connection_of(base, feishu_calls, get, call, async fn() { s.stop() })
}

///|
/// Feishu's words as its package says them (its catalog's, in a language).
fn feishu_words(bus : LiveBus) -> @feishu.Words {
  {
    tr: (lang, key, args) => tr(lang, key, args=args.to_array().map(kv => (kv.0, match kv.1 { String(s) => s; other => other.stringify() }))),
    station_lang: () => (bus.lang.val)(),
  }
}

///|
/// The connects' names book as Feishu's surface keeps names in it.
fn feishu_book(book : @connects_hub.NameBook) -> @feishu.NameBook {
  {
    person: (key, fetch, stale) => match book.person(key, async fn() {
        match fetch() {
          Some(p) => Some(p.to_jv())
          None => None
        }
      }, stale=(known, at) => stale({ name: jv_text(known, "name").unwrap_or(""), email: jv_text(known, "email").unwrap_or("") }, at)) {
      Some(p) => Some({ name: jv_text(p, "name").unwrap_or(""), email: jv_text(p, "email").unwrap_or("") })
      None => None
    },
    channel: (key, fetch) => match of_jv(book.channel(key, async fn() { to_jv(jopt(fetch())) })) {
      String(n) => Some(n)
      _ => None
    },
  }
}

///|
/// The connect platform of Feishu's, and its part's own (its threads, the apps made by a scan, feishu_api).
async fn P55::start_feishu(self : P55, options : @connects_hub.ConnectsOptions) -> @connects_hub.Connects {
  let bus = self.bus
  let host = bus.host
  let net = { ..@feishu.host_net(host, stand_in=env_get("STILLFAIL_FEISHU_API")), now: () => p5_epoch_ms() }
  let words = feishu_words(bus)
  let disk = @feishu.host_disk(host, sep=sep())
  let feishu = @feishu.make_feishu(host.rt, bus.data, sep(), net, words, @feishu.host_log(), disk, @feishu.host_random_hex(host), bus.argv0)
  feishu.registrations.ready()
  let connects = @connects_hub.make_connects(options, {
    kind: "feishu",
    names: "feishu-names.json",
    connects: raw => @feishu.feishu_connects(raw).map(c => c.to_jv()),
    credentials: c => match feishu_connect_of(c) {
      Some(fc) => @feishu.credentials(fc)
      None => None
    },
    create: async fn(c, book) {
      guard feishu_connect_of(c) is Some(fc) else { raise BusError("not a Feishu connect") }
      let surface = feishu.create(fc, Some(feishu_book(book)))
      feishu_connection(host, surface, fc.id, book)
    },
    seen: (c, i) => {
      guard feishu_connect_of(c) is Some(fc) else { return None }
      let id = of_jv(i)
      let identity : @feishu.BotIdentity = {
        team: jtext_or_empty(id, "team"),
        team_id: jtext_or_empty(id, "teamId"),
        url: jtext_or_empty(id, "url"),
        bot_user_id: jtext_or_empty(id, "botUserId"),
        bot_name: jtext_or_empty(id, "botName"),
        bot_image: jtext(id, "botImage"),
        bot_id: jtext_or_empty(id, "botId"),
      }
      match @feishu.seen_patch(fc, identity) {
        Some(patch) => Some(entry => { patch(entry); entry })
        None => None
      }
    },
  })
  self.closing(async fn() {
    connects.close()
    feishu.close()
  })
  // (the apps being made by a scan before a restart, known before the overview lists them)
  bus.parts.overview("feishuRegistrations", async fn(viewer, _lang) {
    of_jv(feishu.overview(jtext_or_empty(viewer, "email"), jtext(viewer, "workspace")))
  })
  ignore(feishu.registrations.on_change(() => (bus.overview_changed.val)()))
  // feishu_api for the agents (feishu/tool.ts), where the agents' part offers it not; `feishu.api` for its.
  let is_feishu = (id : String) => connects.connects().iter().any(c => jv_text(c, "id").unwrap_or("") == id)
  let world = () => Some(self.feishu_tool_world(connects))
  let (declared, run) = feishu.tool(world, is_feishu)
  bus.parts.tools(
    [
      {
        name: "feishu_api",
        declared: of_jv(declared),
        call: async fn(args, context) {
          tool_said(async fn() {
            let session = self.session_of(context)
            Json::string(run(session, to_jv(args)))
          })
        },
      },
    ],
  )
  self.op("feishu.api", async fn(arg) {
    match arg {
      Array([String(session), args, ..]) => Json::string(run(session, to_jv(args)))
      _ => raise BusError("feishu.api: [session, args]")
    }
  })
  // What the admin API's Feishu routes ask (api_routes kinds2.mbt): an app's credentials verified, its domain, the
  // apps made by a scan begun, completed, called off.
  self.op("feishu/surface.verifyFeishuApp", async fn(arg) {
    let a = jitems(arg)
    let s = (i : Int) => match a.get(i) { Some(String(x)) => x; _ => "" }
    let (identity, errors) = @feishu.verify_feishu_app(net, words, s(0), s(1), s(2), lang=s(3))
    Json::array([
      match identity {
        Some(i) => of_jv(i.to_jv())
        None => Json::null()
      },
      Json::array(errors.map(Json::string(_))),
    ])
  })
  self.op("feishu/web.domainOf", async fn(arg) {
    Json::string(@feishu.domain_of(match jitems(arg).get(0) { Some(Null) | None => None; Some(v) => Some(@feishu.JV::of_json(v)) }))
  })
  self.op("feishu.registrations.start", async fn(arg) {
    let save = jitems(arg).get(0).unwrap_or(Json::null())
    feishu.registrations.start(async fn(reg) { self.called_text(save, [of_jv(reg.jv())]) })
    Json::null()
  })
  self.op("feishu.registrations.begin", async fn(arg) {
    let a = jitems(arg)
    let s = (i : Int) => match a.get(i) { Some(String(x)) => Some(x); _ => None }
    let reg = feishu.registrations.begin(
      s(0).unwrap_or(""),
      s(1).unwrap_or(""),
      s(2),
      context=@feishu.JV::of_json(a.get(3).unwrap_or(Json::null())),
      workspace=s(4),
    )
    of_jv(reg.jv())
  })
  self.op("feishu.registrations.complete", async fn(arg) {
    let a = jitems(arg)
    let s = (i : Int) => match a.get(i) { Some(String(x)) => x; _ => "" }
    let save = a.get(3).unwrap_or(Json::null())
    jopt(feishu.registrations.complete(s(0), s(1), s(2), async fn(reg) { self.called_text(save, [of_jv(reg.jv())]) }))
  })
  self.op("feishu.registrations.cancel", async fn(arg) {
    let a = jitems(arg)
    let s = (i : Int) => match a.get(i) { Some(String(x)) => x; _ => "" }
    Json::boolean(feishu.registrations.cancel(s(0), s(1), workspace=s(2)))
  })
  connects
}

///|
/// feishu_api's world: a session's own connect and workspace, its recent threads' connects, a connect's OpenAPI.
fn P55::feishu_tool_world(self : P55, connects : @connects_hub.Connects) -> @feishu.ToolWorld {
  let bus = self.bus
  {
    session: key => match (try { Ok(bus.store.get_session(key)) } catch { e => Err(e) }) {
      Ok(Object(_) as row) => Some((jtext(row, "connect"), jtext_or_empty(row, "workspace")))
      _ => None
    },
    recent_connects: key => {
      let rows = (try {
        Ok(bus.db.all("SELECT connect FROM thread_sessions WHERE session = ? ORDER BY joined_at DESC LIMIT 50", [Json::string(key)]))
      } catch {
        e => Err(e)
      }).unwrap_or([])
      rows.filter_map(r => match r.get("connect") { Some(String(c)) => Some(c); _ => None })
    },
    // (sessions/conversations.ts `target`: `to` one of the session's threads, CHANNEL/THREAD_TS; its connect there)
    target: (key, to) => {
      let t = match to {
        Str(s) => s.trim().to_owned()
        _ => ""
      }
      guard t.rev_find("/") is Some(cut) && cut > 0 && cut < t.length() - 1 else {
        raise BusError("to must look like CHANNEL/THREAD_TS, got \{of_jv(to).stringify()}")
      }
      let rows = bus.db.all(
        "SELECT ts.connect FROM thread_sessions ts JOIN threads t ON t.id = ts.thread WHERE ts.session = ? AND t.channel = ? AND t.thread_ts = ?",
        [Json::string(key), Json::string(t.unsafe_substring(start=0, end=cut)), Json::string(t.unsafe_substring(start=cut + 1, end=t.length()))],
      )
      match rows {
        [r, ..] => jtext_or_empty(Json::object(r), "connect")
        [] => raise BusError("\{t} is not a conversation of this session")
      }
    },
    chat_api: id => match connects.chats(id) {
      Some(chat) =>
        Some(async fn(meth, params) {
          let v = of_jv((chat.call)("api", [to_jv(Json::string(meth)), params]))
          match jtext(v, "file") {
            Some(h) => File(unhex_lenient(h), jtext_or_empty(v, "name"), jtext_or_empty(v, "type"))
            None => Data(@feishu.JV::of_json(v))
          }
        })
      None => None
    },
    now: () => wall_ms(),
    uuid: () => @drive.random_uuid(),
    disk: @feishu.host_disk(bus.host, sep=sep()),
    sep: sep(),
  }
}

///|
/// A callback the admin API handed as `{"$fn": id}` (P5-1's `$admin.called` on the bus): called with `args`, its
/// answer.
async fn P55::called(self : P55, f : Json, args : Array[Json]) -> Json {
  match jfield(f, "$fn") {
    Number(_, ..) as id => self.bus.admin_called(id, args)
    _ => raise BusError("not a callback: \{f.stringify()}")
  }
}

///|
async fn P55::called_text(self : P55, f : Json, args : Array[Json]) -> String {
  match self.called(f, args) {
    String(s) => s
    other => other.stringify()
  }
}

// ── Comma ──

///|
/// The Comma calls a surface answers (comma/surface.ts).
let comma_calls : Array[String] = ["mention", "sessionLink", "post", "download", "knownPerson", "standsAt"]

///|
/// A Comma surface and the connects' socket loop under it.
fn comma_connection(host : @host.Host, s : @comma.CommaSurface, id : String, book : @connects_hub.NameBook) -> @connects_hub.Connection {
  let base = @connects_hub.ConnectedSurface::new("comma", surface_options(host, id, Some(book)))
  // (Comma shows no status line: comma/surface.ts `Quiet`, each said taken as shown)
  base.set_status_line(_ => @connects_hub.StatusLine::new(f => base.run(f), base.clock, 1000.0, async fn(_, _, _) { true }))
  base.hooked(identify=async fn() { s.identify() }, address=async fn() { s.address() }, run_socket=async fn(url, handler) {
    s.set_handler(handler)
    let next = Ref(0)
    let close_cbs : Array[(Int, () -> Unit)] = []
    let next_cb = Ref(0)
    let fire_close = () => {
      let cbs = close_cbs.copy()
      close_cbs.clear()
      for pair in cbs {
        (pair.1)()
      }
      s.closed()
    }
    let wrap = (sock : @connects_hub.Socket) => {
      next.val += 1
      ({
        id: next.val,
        send: t => (sock.send)(@utf8.encode(t)),
        on_close: f => {
          next_cb.val += 1
          let cid = next_cb.val
          close_cbs.push((cid, f))
          () => {
            match close_cbs.search_by(p => p.0 == cid) {
              Some(i) => ignore(close_cbs.remove(i))
              None => ()
            }
          }
        },
      } : @comma.Socket)
    }
    let current : Ref[@comma.Socket?] = Ref(None)
    try {
      base.socket_to(url, {
        opened: sock => current.val = Some(wrap(sock)),
        message: (sock, data, _binary, _at, end) => {
          let cs = match current.val {
            Some(c) => c
            None => wrap(sock)
          }
          s.message(cs, @utf8.decode_lossy(data), () => end(None))
        },
        ping: _ => (),
      }, headers=s.headers())
    } catch {
      e => {
        fire_close()
        raise e
      }
    }
    fire_close()
  }, look_up=async fn(user) { Some(s.look_up(user)) }, look_up_email=async fn(user) { s.look_up_email(user) })
  let txt = (a : Array[@jsjson.JValue], i : Int) => match a.get(i) { Some(Str(u)) => @jsjson.sanitize_str(u); _ => "" }
  let get = fn(name : String, a : Array[@jsjson.JValue]) -> @jsjson.JValue? {
    match name {
      "sessionLink" => Some(to_jv(jopt(s.session_link())))
      "standsAt" => {
        let (ch, ts) = thread_of_j(a.get(0))
        let st = of_jv(a.get(1).unwrap_or(Null))
        s.stands_at(ch, ts, jtext_or_empty(st, "kind"), jtext(st, "words"))
        Some(Null)
      }
      _ => None
    }
  }
  let call = async fn(name : String, a : Array[@jsjson.JValue]) -> @jsjson.JValue? {
    match name {
      "mention" => Some(to_jv(Json::string(s.mention(txt(a, 0)))))
      "knownPerson" => Some(s.known_person(txt(a, 0)))
      "post" => {
        let (ch, ts) = thread_of_j(a.get(0))
        let files = match a.get(2) {
          Some(Arr(xs)) => xs.map(@comma.Attachment::of_j)
          _ => []
        }
        let card = match a.get(3) { Some(Null) | None => None; c => c }
        Some(to_jv(Json::string(s.post(ch, ts, txt(a, 1), files, card~))))
      }
      "download" => {
        let f = of_jv(a.get(0).unwrap_or(Null))
        Some(to_jv(Json::string(@drive.hex(s.download(jtext_or_empty(f, "id"), jtext_or_empty(f, "name"), match jfield(f, "size") { Number(n, ..) => n; _ => 0.0 })))))
      }
      _ => None
    }
  }
  connection_of(base, comma_calls, get, call, async fn() { s.closed() })
}

///|
/// The connect platform of Comma's, and its part's own (the workspace's statistics and Task index, the Router's chats,
/// what another station asks of them).
async fn P55::start_comma(self : P55, options : @connects_hub.ConnectsOptions) -> @connects_hub.Connects {
  let bus = self.bus
  let host = bus.host
  let db = bus.db
  let (zh, en) = catalogs_json()
  let io = {
    ..@comma.host_io(host, words=@comma.Words::new(to_jv(zh), to_jv(en)), lang=() => (bus.lang.val)(), platform=platform(), arch=arch(), hostname=hostname(), version=bus.version),
    now: () => p5_epoch_ms().to_double(),
  }
  let cloud_listeners = (f : () -> Unit) => (bus.cloud_listen.val)(_ => f())
  let rows = (sql : String, args : Array[@jsjson.JValue]) => db.all(sql, args.map(of_jv)).map(r => to_jv(Json::object(r)))
  let live = @comma.CommaLive::new(
    {
      data: bus.data,
      home: () => self.home(),
      memberships: () => self.memberships().map(m => m.0),
      membership: ws => match self.memberships().search_by(m => m.0 == ws) {
        Some(i) => {
          let m = self.memberships()[i]
          to_jv({ "workspace": Json::string(m.0), "workspace_name": Json::string(m.1), "name": Json::string(hostname()), "peers": Json::array(m.3) })
        }
        None => Null
      },
      station: () => bus.key.id,
      cloud_listen: cloud_listeners,
      pages: () => Null,
      read: async fn(op, args, lang, _background) {
        match (bus.reader_ask.val)(op, of_jv(args), lang) {
          String(t) => t
          other => other.stringify()
        }
      },
      ask: async fn(station, request) {
        let r = of_jv(request)
        let (v, _) = bus.call_peer(station, jtext(r, "workspace"), jtext_or_empty(r, "method"), r)
        to_jv(v)
      },
      ask_text: async fn(station, request) {
        let r = of_jv(request)
        match bus.call_peer(station, jtext(r, "workspace"), jtext_or_empty(r, "method"), r).0 {
          String(t) => t
          other => other.stringify()
        }
      },
      member: (peer, ws) => {
        guard self.roster(ws) is Some(r) && r.iter().any(m => m.0 == peer) else {
          raise BusError("not a station of this workspace")
        }
      },
      subscribe: f => bus.subscribe_store(change => f(jtext_or_empty(change, "type"))),
      hub: {
        get: async fn(sql, args) {
          match rows(sql, args) {
            [r, ..] => r
            [] => Null
          }
        },
        all: async fn(sql, args) { rows(sql, args) },
        run: async fn(sql, args) { ignore(db.all(sql, args.map(of_jv))) },
        thread_sessions: async fn(thread) { jitems(self.hub("store.threadSessions", [Json::number(thread)])).map(to_jv) },
        get_session: async fn(key) {
          match (try { Ok(bus.store.get_session(key)) } catch { e => Err(e) }) {
            Ok(r) => to_jv(r)
            Err(_) => Null
          }
        },
        ws_of: async fn(s) {
          as_text(self.hub("hub.wsOf", [of_jv(s)]))
        },
        deliver: async fn(thread, n, sessions, text, ws) {
          ignore(self.hub("hub.deliver", [Json::number(thread), Json::number(n), Json::array(sessions.map(Json::string(_))), Json::string(text), jopt(ws)]))
        },
        complete_router_write: async fn(id) {
          ignore(db.all("UPDATE comma_router_once SET pending = 0 WHERE id = ? AND pending = 1", [Json::string(id)]))
          ignore(db.all("DELETE FROM comma_router_once_targets WHERE id = ?", [Json::string(id)]))
          db.all("SELECT 1 FROM comma_router_once WHERE id = ? AND pending = 0", [Json::string(id)]).length() > 0
        },
        say: async fn(thread, author, text, hooks) {
          match hooks {
            Some(h) => {
              (h.before)()
              let n = as_num(self.hub("hub.say", [Json::number(thread), Json::string(author), Json::string(text)])).unwrap_or(0.0)
              (h.inserted)(n)
              n
            }
            None =>
              as_num(self.hub("hub.say", [Json::number(thread), Json::string(author), Json::string(text)])).unwrap_or(0.0)
          }
        },
      },
      previous_exited: async fn() { (bus.previous_gone)() },
    },
    io,
    host.rt,
  )
  self.closing(async fn() { live.close() })
  // Another station's read of this one's statistics and its write in one of its chats (comma/peer.ts).
  let peer_read = live.peer_read()
  bus.on_peer_prefix("outflow.", async fn(from, ws, _meth, params, _bytes) {
    let a = peer_read(from, to_jv(params), ws)
    (a.check)()
    (of_jv(a.head), Some(a.bytes))
  })
  bus.on_peer_prefix("comma.", async fn(from, ws, meth, params, _bytes) {
    if meth == "comma.say" {
      (of_jv(live.say_handler(from, to_jv(params), ws)), None)
    } else if meth == "comma.changed" {
      (of_jv(live.changed_handler(from, ws)), None)
    } else {
      let a = peer_read(from, to_jv(params), ws)
      (a.check)()
      (of_jv(a.head), Some(a.bytes))
    }
  })
  let parts_ref : Ref[@comma.CommaParts?] = Ref(None)
  let connects_ref : Ref[@connects_hub.Connects?] = Ref(None)
  let parts = live.make_comma(
    bus.data,
    () => to_jv((bus.config_raw.val)()),
    f => (bus.config_listen.val)(raw => f(to_jv(raw))),
    options.in_workspace,
    {
      get_session: async fn(key) {
        match (try { Ok(bus.store.get_session(key)) } catch { e => Err(e) }) {
          Ok(r) => to_jv(r)
          Err(_) => Null
        }
      },
      pending_count: async fn(key) {
        as_num(self.hub("store.pendingCount", [Json::string(key)])).unwrap_or(0.0)
      },
      thread_at: async fn(surface, ch, ts) { (self.connect_threads_store().thread_at)(surface, ch, ts) },
      leave_thread: async fn(thread, key) { ignore(self.hub("store.leaveThread", [Json::number(thread), Json::string(key)])) },
      handler: async fn(event) {
        ignore(self.hub("hub.receive", [Json::string(jv_text(event, "connect").unwrap_or("")), of_jv(event)]))
      },
      book_person: None,
      book_known: None,
    },
    connect => (bus.hub_models_for.val)(connect).map(to_jv),
    async fn() {
      if connects_ref.val is Some(c) { c.reconcile() }
    },
    async fn() {
      if connects_ref.val is Some(c) { c.stop_all() }
    },
  )
  parts_ref.val = Some(parts)
  let scoped = (j : @jsjson.JValue) => {
    let id = jv_text(j, "id").unwrap_or("")
    parts.connects(to_jv((bus.config_raw.val)())).search_by(sc => sc.connect.id == id).map(i => parts.connects(to_jv((bus.config_raw.val)()))[i])
  }
  let connects = @connects_hub.make_connects(options, {
    kind: "comma",
    names: "comma-names.json",
    connects: raw => parts.connects(raw).map(sc => sc.connect.to_j()),
    credentials: c => match scoped(c) {
      Some(sc) => @comma.credentials(sc)
      None => None
    },
    create: async fn(c, book) {
      guard scoped(c) is Some(sc) else { raise BusError("not a Comma connect") }
      comma_connection(host, parts.create(sc), sc.connect.id, book)
    },
    seen: (_c, _i) => None,
  })
  connects_ref.val = Some(connects)
  self.closing(async fn() {
    connects.close()
    parts.close()
  })
  // (what offers Comma as a platform in the connect wizard)
  bus.parts.overview("comma", async fn(_viewer, _lang) { Json::boolean(true) })
  self.op("comma/index.commaLine", async fn(arg) {
    match @comma.comma_line(match jitems(arg).get(0) { Some(String(l)) => l; _ => "" }) {
      Some((server, token)) => { "server": Json::string(server), "token": Json::string(token) }
      None => Json::null()
    }
  })
  connects
}

// ── the group connect (im/2) ──

///|
/// Endpoints as the group connects bind them (mesh/endpoint.ts `Endpoints`): each connect's own, by its own key,
/// through the shell's iroh (`iroh.*`, `conn.*`, `istream.*`).
fn shell_endpoints(host : @host.Host) -> @connects_hub.Endpoints {
  fn stream(id : Json) -> @connects_hub.MeshStream {
    {
      read: async fn() {
        let (said, bytes) = host.shell("istream.read", { "id": id })
        match said {
          { "end": True, .. } => None
          _ => Some(bytes.unwrap_or(b""))
        }
      },
      write: async fn(b) { ignore(host.shell("istream.write", { "id": id }, bytes=b)) },
      finish: async fn() { ignore(host.shell("istream.finish", { "id": id })) },
      reset: async fn(code) { ignore(host.shell("istream.reset", { "id": id, "code": Json::number(code.to_double()) })) },
      stopped: async fn() { ignore(host.shell("istream.stopped", { "id": id })) },
    }
  }
  fn conn(id : Json) -> @connects_hub.MeshConn {
    let closed = Ref(false)
    let remote = Ref("")
    host.rt.fork(async fn() {
      match (try { Ok(host.shell("conn.remoteId", { "id": id }).0) } catch { e => Err(e) }) {
        Ok(String(r)) => remote.val = r
        Ok({ "id": String(r), .. }) => remote.val = r
        _ => ()
      }
    })
    |> ignore
    {
      open_bi: async fn() {
        match host.shell("conn.openBi", { "id": id }).0 {
          { "id": s, .. } => stream(s)
          _ => raise BusError("the shell opened no stream")
        }
      },
      close: (code, reason) => {
        closed.val = true
        host.rt.fork(async fn() {
          ignore(host.shell("conn.close", { "id": id, "code": Json::number(code.to_double()), "reason": Json::string(reason), "forget": true })) catch {
            _ => ()
          }
        })
        |> ignore
      },
      is_closed: () => closed.val,
      accept_bi: async fn() {
        match host.shell("conn.acceptBi", { "id": id }).0 {
          { "end": True, .. } => None
          { "id": s, .. } => Some(stream(s))
          _ => None
        }
      },
      remote_id: () => remote.val,
    }
  }
  {
    bind: async fn(options) {
      let o = of_jv(options)
      let key = unhex_lenient(jtext_or_empty(o, "secretKey"))
      let alpns = core_strs(jfield(o, "alpns")).map(a => Json::string(@drive.hex(@utf8.encode(a))))
      let test_ips = match env_get("STILLFAIL_GROUP_IPS") {
        Some(v) if v != "" =>
          v.split(",").map(s => s.trim().to_string()).filter(s => s != "").to_array()
        _ => []
      }
      let relay_urls = if test_ips.length() > 0 { Json::array([]) } else { jfield(o, "relayUrls") }
      let (bound, _) = host.shell(
        "iroh.bind",
        { "relayUrls": relay_urls, "alpns": Json::array(alpns), "discovery": Json::boolean(jtrue(o, "discovery")) },
        bytes=key,
      )
      guard bound is { "id": endpoint, .. } else { raise BusError("the shell bound no endpoint") }
      let id = match (try { Ok(host.shell_sync("iroh.endpointId", { "id": endpoint })) } catch { e => Err(e) }) {
        Ok(String(s)) => s
        _ => ""
      }
      {
        id: () => id,
        connect: async fn(addr, alpn) {
          let a = match of_jv(addr) {
            Object(m) if test_ips.length() > 0 => {
              let next : Map[String, Json] = Map::new()
              for k, v in m {
                next[k] = v
              }
              next["relays"] = Json::array([])
              next["ips"] = Json::array(test_ips.map(Json::string(_)))
              Json::object(next)
            }
            other => other
          }
          match host.shell("iroh.connect", { "id": endpoint, "addr": a }, bytes=@utf8.encode(alpn)).0 {
            { "id": c, .. } => conn(c)
            _ => raise BusError("the shell made no connection")
          }
        },
        accept: async fn() {
          match host.shell("iroh.accept", { "id": endpoint }).0 {
            { "id": c, .. } => Some(conn(c))
            _ => None
          }
        },
        close: async fn() { ignore(host.shell("iroh.close", { "id": endpoint, "forget": true })) catch { _ => () } },
      }
    },
  }
}

///|
/// Ed25519 as the shell does it (`ed25519.sign`, `crypto.verify`): a seed's public half, a signature, its check.
fn shell_signer(host : @host.Host) -> @connects_hub.Signer {
  let public_key = (seed : String) => match (try { Ok(host.shell_sync("ed25519.sign", { "seed": Json::string(seed), "message": "" })) } catch { e => Err(e) }) {
    Ok({ "publicKey": String(k), .. }) => Some(k)
    _ => None
  }
  {
    public_key,
    sign: (seed, message) => match (try { Ok(host.shell_sync("ed25519.sign", { "seed": Json::string(seed), "message": Json::string(@drive.hex(message)) })) } catch { e => Err(e) }) {
      Ok({ "signature": String(sig), .. }) => Some(sig)
      _ => None
    },
    verify: (device, message, sig) => (try {
      Ok(host.shell_sync("crypto.verify", { "alg": "Ed25519", "key": Json::string(device), "signature": Json::string(sig), "message": Json::string(@drive.hex(message)) }))
    } catch {
      e => Err(e)
    }) is Ok(True),
  }
}

///|
async fn P55::start_group(self : P55, options : @connects_hub.ConnectsOptions) -> @connects_hub.Connects {
  let bus = self.bus
  let host = bus.host
  let (zh, en) = catalogs_json()
  let signer = shell_signer(host)
  let group = @connects_hub.make_group({
    connects: options,
    endpoints: () => shell_endpoints(host),
    create: None,
    public_key: signer.public_key,
    speech: { words: @replica_coord.station_words(to_jv(zh), to_jv(en)), lang: Ref((bus.lang.val)()) },
    uuid: () => @drive.random_uuid(),
    signer,
  })
  self.closing(async fn() { group.close() })
  p55_group_parts.val = Some(group)
  // (the overview says a station has the group connect, which the pages offer only then)
  bus.parts.overview("group", async fn(_viewer, _lang) { Json::boolean(true) })
  group.connects
}

///|
/// group/index.ts `groupEntryIn`: a group connect's part of its config entry, from what the page gave and what it had.
fn group_entry(given : Json, had : Json) -> Json raise {
  if !(given is Object(_)) && had == Json::null() {
    return Json::null()
  }
  let g : Map[String, Json] = match had {
    Object(m) => m.copy()
    _ => Map([])
  }
  match jtext(given, "server") {
    Some(server) if server.trim().to_lower() != jtext_or_empty(Json::object(g), "server") => {
      g["server"] = Json::string(server.trim().to_lower().to_owned())
      for k in ["memberId", "name", "bound"] {
        g.remove(k)
      }
    }
    _ => ()
  }
  match jfield(given, "relays") {
    Array(xs) => g["relays"] = Json::array(xs.filter(x => x is String(_)))
    _ => ()
  }
  match jtext(given, "code") {
    Some(code) if code.trim() != "" => {
      let kept = code.trim().to_upper().to_owned().replace_all(old="-", new="").replace_all(old=" ", new="")
      if kept.length() != 16 {
        raise BusError("the code is not one")
      }
      g["code"] = Json::string(kept)
    }
    _ => ()
  }
  match jfield(given, "botName") {
    String(n) => if n.trim() == "" { g.remove("botName") } else { g["botName"] = Json::string(n.trim().to_owned()) }
    Null => if given is Object(m) && m.contains("botName") { g.remove("botName") }
    _ => ()
  }
  match g.get("key") {
    Some(String(k)) if k.length() == 64 => ()
    _ => g["key"] = Json::string(@drive.hex(@drive.random_bytes(32)))
  }
  Json::object(g)
}
