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
fn feishu_jv(j : @jsjson.JValue) -> @feishu.JV {
  @jsjson.JV::of_js(j)
}

///|
fn of_feishu(v : @feishu.JV) -> @jsjson.JValue {
  @jsjson.JV::to_js(v)
}

///|
/// A Feishu connect as the connects hand it back (`FeishuConnect::to_jv`'s fields, flat).
fn feishu_connect_of(j : @jsjson.JValue) -> @feishu.FeishuConnect? {
  let c = to_core(j)
  if p55_jtext(c, "id") == "" {
    return None
  }
  let tenant = p55_jfield(c, "tenant")
  Some({
    id: p55_jtext(c, "id"),
    enabled: !(p55_jfield(c, "enabled") is False),
    app_id: p55_jtext(c, "appId"),
    app_secret: p55_jtext(c, "appSecret"),
    domain: if p55_jtext(c, "domain") == "lark" { "lark" } else { "feishu" },
    threads: p55_jfield(c, "threads") is True,
    direct_threads: p55_jfield(c, "directThreads") is True,
    bot_name: p55_jstr(c, "botName"),
    bot_image: p55_jstr(c, "botImage"),
    bot_open_id: p55_jstr(c, "botOpenId"),
    tenant: match p55_jstr(tenant, "key") {
      Some(k) => Some((k, p55_jtext(tenant, "name")))
      None => None
    },
    workspace: p55_jstr(c, "workspace"),
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
    Some(x) => to_core(x)
    None => Json::null()
  }
  match p55_jtext(e, "kind") {
    "message" | "byMessage" => ByMessage(p55_jtext(e, "user"), p55_jtext(e, "text"))
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
    let c = to_core(i)
    s.usable({
      team: p55_jtext(c, "team"),
      team_id: p55_jtext(c, "teamId"),
      url: p55_jtext(c, "url"),
      bot_user_id: p55_jtext(c, "botUserId"),
      bot_name: p55_jtext(c, "botName"),
      bot_image: p55_jstr(c, "botImage"),
      bot_id: p55_jtext(c, "botId"),
    })
  })
  base.hooked(identify=async fn() { of_feishu(s.identify().to_jv()) }, address=async fn() { s.address() }, run_socket=async fn(url, handler) {
    let hooks = s.socket_hooks(url, async fn(e) { handler(of_feishu(e)) })
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
      Some(p) => Some(of_feishu(p.to_jv()))
      None => None
    }
  }, look_up_email=async fn(user) { s.look_up_email(user) })
  let txt = (a : Array[@jsjson.JValue], i : Int) => match a.get(i) { Some(Str(u)) => @jsjson.text(u); _ => "" }
  let opt = (v : String?) => match v { Some(t) => of_core(Json::string(t)); None => @jsjson.JValue::Null }
  let get = fn(name : String, a : Array[@jsjson.JValue]) -> @jsjson.JValue? {
    match name {
      "mention" => Some(of_core(Json::string(s.mention(txt(a, 0)))))
      "sessionLink" => Some(opt(s.session_link()))
      "knownPerson" =>
        Some(match s.known_person(txt(a, 0)) {
          Some(p) => of_feishu(p.to_jv())
          None => Null
        })
      "knownChannel" => Some(opt(s.known_channel(txt(a, 0))))
      "permalink" => Some(opt((try { Ok(s.permalink(feishu_thread(a.get(0)))) } catch { e => Err(e) }).to_option()))
      "platform" => Some(of_core(Json::string(s.platform())))
      "working" => {
        s.working(feishu_thread(a.get(0)), match a.get(1) { Some(Str(u)) => Some(@jsjson.text(u)); _ => None }, txt(a, 2), page?=match a.get(3) { Some(Str(u)) => Some(Some(@jsjson.text(u))); _ => None })
        Some(Null)
      }
      _ => None
    }
  }
  let call = async fn(name : String, a : Array[@jsjson.JValue]) -> @jsjson.JValue? {
    match name {
      "post" => {
        let files = match a.get(2) {
          Some(Arr(xs)) => xs.map(f => ({ path: p55_jtext(to_core(f), "path"), name: p55_jtext(to_core(f), "name") } : @feishu.Attachment))
          _ => []
        }
        let card = match a.get(3) { Some(Null) | None => None; Some(c) => Some(feishu_jv(c)) }
        Some(of_core(Json::string(s.post(feishu_thread(a.get(0)), txt(a, 1), files, card~))))
      }
      "cardEnded" => {
        s.card_ended(feishu_thread(a.get(0)), txt(a, 1), txt(a, 2), a.get(3).map(feishu_jv), feishu_card_end(a.get(4)))
        Some(Null)
      }
      "download" => {
        let f = to_core(a.get(0).unwrap_or(Null))
        let file : @feishu.InboundFile = { id: p55_jtext(f, "id"), name: p55_jtext(f, "name"), size: match p55_jfield(f, "size") { Number(n, ..) => n.to_int(); _ => 0 }, url: p55_jstr(f, "url") }
        Some(of_core(Json::string(@drive.hex(s.download(file)))))
      }
      "history" =>
        Some(Arr(s.history(feishu_thread(a.get(0)), txt(a, 1), match a.get(2) { Some(Num(n)) => n.to_int(); _ => 50 }).map(m => of_feishu(m.to_jv()))))
      "quoted" =>
        Some(match s.quoted(feishu_thread(a.get(0)), txt(a, 1)) {
          Some(m) => of_feishu(m.to_jv())
          None => Null
        })
      "places" => Some(Arr(s.places().map(p => of_core({ "id": Json::string(p.id), "name": Json::string(p.name), "kind": Json::string(p.kind) }))))
      "peopleIn" => Some(Arr(s.people_in(txt(a, 0)).map(m => of_core({ "id": Json::string(m.id), "name": Json::string(m.name) }))))
      "begin" => {
        let (t, ts) = s.begin(txt(a, 0), txt(a, 1))
        Some(of_core({ "thread": { "channel": Json::string(t.channel), "threadTs": Json::string(t.thread_ts) }, "ts": Json::string(ts) }))
      }
      "edit" => Some(Bool(s.edit(feishu_thread(a.get(0)), txt(a, 1), txt(a, 2))))
      "channelName" => Some(opt(s.channel_name(txt(a, 0))))
      "userName" => Some(opt(s.user_name(txt(a, 0))))
      "userEmail" => Some(opt(s.user_email(txt(a, 0))))
      "userOf" => Some(opt(s.user_of(txt(a, 0))))
      "api" =>
        Some(match s.api(txt(a, 0), feishu_jv(a.get(1).unwrap_or(Null))) {
          Data(v) => of_feishu(v)
          File(bytes, name, kind) => of_core({ "file": Json::string(@drive.hex(bytes)), "name": Json::string(name), "type": Json::string(kind) })
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
          Some(p) => Some(of_feishu(p.to_jv()))
          None => None
        }
      }, stale=(known, at) => stale({ name: p55_jtext(to_core(known), "name"), email: p55_jtext(to_core(known), "email") }, at)) {
      Some(p) => Some({ name: p55_jtext(to_core(p), "name"), email: p55_jtext(to_core(p), "email") })
      None => None
    },
    channel: (key, fetch) => match to_core(book.channel(key, async fn() { of_core(p55_jopt(fetch())) })) {
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
    connects: raw => @feishu.feishu_connects(feishu_jv(raw)).map(c => of_feishu(c.to_jv())),
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
      let id = to_core(i)
      let identity : @feishu.BotIdentity = {
        team: p55_jtext(id, "team"),
        team_id: p55_jtext(id, "teamId"),
        url: p55_jtext(id, "url"),
        bot_user_id: p55_jtext(id, "botUserId"),
        bot_name: p55_jtext(id, "botName"),
        bot_image: p55_jstr(id, "botImage"),
        bot_id: p55_jtext(id, "botId"),
      }
      match @feishu.seen_patch(fc, identity) {
        Some(patch) =>
          Some(entry => {
            let e = feishu_jv(entry)
            patch(e)
            of_feishu(e)
          })
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
    to_core(of_feishu(feishu.overview(p55_jtext(viewer, "email"), p55_jstr(viewer, "workspace"))))
  })
  ignore(feishu.registrations.on_change(() => (bus.overview_changed.val)()))
  // feishu_api for the agents (feishu/tool.ts), where the agents' part offers it not; `feishu.api` for its.
  let is_feishu = (id : String) => connects.connects().iter().any(c => p55_jtext(to_core(c), "id") == id)
  let world = () => Some(self.feishu_tool_world(connects))
  let (declared, run) = feishu.tool(world, is_feishu)
  bus.parts.tools(
    [
      {
        name: "feishu_api",
        declared: to_core(of_feishu(declared)),
        call: async fn(args, context) {
          tool_said(async fn() {
            let session = self.session_of(context)
            Json::string(run(session, feishu_jv(of_core(args))))
          })
        },
      },
    ],
  )
  self.op("feishu.api", async fn(arg) {
    match arg {
      Array([String(session), args, ..]) => Json::string(run(session, feishu_jv(of_core(args))))
      _ => raise BusError("feishu.api: [session, args]")
    }
  })
  // What the admin API's Feishu routes ask (api_routes kinds2.mbt): an app's credentials verified, its domain, the
  // apps made by a scan begun, completed, called off.
  self.op("feishu/surface.verifyFeishuApp", async fn(arg) {
    let a = core_items(arg)
    let s = (i : Int) => match a.get(i) { Some(String(x)) => x; _ => "" }
    let (identity, errors) = @feishu.verify_feishu_app(net, words, s(0), s(1), s(2), lang=s(3))
    Json::array([
      match identity {
        Some(i) => to_core(of_feishu(i.to_jv()))
        None => Json::null()
      },
      Json::array(errors.map(Json::string(_))),
    ])
  })
  self.op("feishu/web.domainOf", async fn(arg) {
    Json::string(@feishu.domain_of(match core_items(arg).get(0) { Some(Null) | None => None; Some(v) => Some(@feishu.JV::of_json(v)) }))
  })
  self.op("feishu.registrations.start", async fn(arg) {
    let save = core_items(arg).get(0).unwrap_or(Json::null())
    feishu.registrations.start(async fn(reg) { self.called_text(save, [to_core(of_feishu(reg.jv()))]) })
    Json::null()
  })
  self.op("feishu.registrations.begin", async fn(arg) {
    let a = core_items(arg)
    let s = (i : Int) => match a.get(i) { Some(String(x)) => Some(x); _ => None }
    let reg = feishu.registrations.begin(
      s(0).unwrap_or(""),
      s(1).unwrap_or(""),
      s(2),
      context=@feishu.JV::of_json(a.get(3).unwrap_or(Json::null())),
      workspace=s(4),
    )
    to_core(of_feishu(reg.jv()))
  })
  self.op("feishu.registrations.complete", async fn(arg) {
    let a = core_items(arg)
    let s = (i : Int) => match a.get(i) { Some(String(x)) => x; _ => "" }
    let save = a.get(3).unwrap_or(Json::null())
    p55_jopt(feishu.registrations.complete(s(0), s(1), s(2), async fn(reg) { self.called_text(save, [to_core(of_feishu(reg.jv()))]) }))
  })
  self.op("feishu.registrations.cancel", async fn(arg) {
    let a = core_items(arg)
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
      Ok(Object(_) as row) => Some((p55_jstr(row, "connect"), p55_jtext(row, "workspace")))
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
        raise BusError("to must look like CHANNEL/THREAD_TS, got \{to_core(of_feishu(to)).stringify()}")
      }
      let rows = bus.db.all(
        "SELECT ts.connect FROM thread_sessions ts JOIN threads t ON t.id = ts.thread WHERE ts.session = ? AND t.channel = ? AND t.thread_ts = ?",
        [Json::string(key), Json::string(t.unsafe_substring(start=0, end=cut)), Json::string(t.unsafe_substring(start=cut + 1, end=t.length()))],
      )
      match rows {
        [r, ..] => p55_jtext(Json::object(r), "connect")
        [] => raise BusError("\{t} is not a conversation of this session")
      }
    },
    chat_api: id => match connects.chats(id) {
      Some(chat) =>
        Some(async fn(meth, params) {
          let v = to_core((chat.call)("api", [of_core(Json::string(meth)), of_feishu(params)]))
          match p55_jstr(v, "file") {
            Some(h) => File(hex_bytes(h), p55_jtext(v, "name"), p55_jtext(v, "type"))
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
  match p55_jfield(f, "$fn") {
    Number(_, ..) as id => {
      let (v, _) = self.bus.call_peer("self", None, "$admin.called", { "id": id, "args": Json::array(args) })
      v
    }
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
    ignore(handler)
    let next = Ref(0)
    let wrap = (sock : @connects_hub.Socket) => {
      next.val += 1
      ({ id: next.val, send: t => (sock.send)(@utf8.encode(t)), on_close: _f => () => () } : @comma.Socket)
    }
    let current : Ref[@comma.Socket?] = Ref(None)
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
  }, look_up=async fn(user) { Some(s.look_up(user)) }, look_up_email=async fn(user) { s.look_up_email(user) })
  let txt = (a : Array[@jsjson.JValue], i : Int) => match a.get(i) { Some(Str(u)) => @jsjson.text(u); _ => "" }
  let get = fn(name : String, a : Array[@jsjson.JValue]) -> @jsjson.JValue? {
    match name {
      "sessionLink" => Some(of_core(p55_jopt(s.session_link())))
      "standsAt" => {
        let (ch, ts) = thread_of_j(a.get(0))
        let st = to_core(a.get(1).unwrap_or(Null))
        s.stands_at(ch, ts, p55_jtext(st, "kind"), p55_jstr(st, "words"))
        Some(Null)
      }
      _ => None
    }
  }
  let call = async fn(name : String, a : Array[@jsjson.JValue]) -> @jsjson.JValue? {
    match name {
      "mention" => Some(of_core(Json::string(s.mention(txt(a, 0)))))
      "knownPerson" => Some(s.known_person(txt(a, 0)))
      "post" => {
        let (ch, ts) = thread_of_j(a.get(0))
        let files = match a.get(2) {
          Some(Arr(xs)) => xs.map(@comma.Attachment::of_j)
          _ => []
        }
        let card = match a.get(3) { Some(Null) | None => None; c => c }
        Some(of_core(Json::string(s.post(ch, ts, txt(a, 1), files, card~))))
      }
      "download" => {
        let f = to_core(a.get(0).unwrap_or(Null))
        Some(of_core(Json::string(@drive.hex(s.download(p55_jtext(f, "id"), p55_jtext(f, "name"), match p55_jfield(f, "size") { Number(n, ..) => n; _ => 0.0 })))))
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
    ..@comma.host_io(host, words=@comma.Words::new(of_core(zh), of_core(en)), lang=() => (bus.lang.val)(), platform=platform(), arch=arch(), hostname=hostname(), version=bus.version),
    now: () => p5_epoch_ms().to_double(),
  }
  let cloud_listeners = (f : () -> Unit) => (bus.cloud_listen.val)(_ => f())
  let rows = (sql : String, args : Array[@jsjson.JValue]) => db.all(sql, args.map(to_core)).map(r => of_core(Json::object(r)))
  let live = @comma.CommaLive::new(
    {
      data: bus.data,
      home: () => self.home(),
      memberships: () => self.memberships().map(m => m.0),
      membership: ws => match self.memberships().search_by(m => m.0 == ws) {
        Some(i) => {
          let m = self.memberships()[i]
          of_core({ "workspace": Json::string(m.0), "workspace_name": Json::string(m.1), "name": Json::string(hostname()), "peers": Json::array(m.3) })
        }
        None => Null
      },
      station: () => bus.key.id,
      cloud_listen: cloud_listeners,
      pages: () => Null,
      read: async fn(op, args, lang, _background) {
        match (bus.reader_ask.val)(op, to_core(args), lang) {
          String(t) => t
          other => other.stringify()
        }
      },
      ask: async fn(station, request) {
        let r = to_core(request)
        let (v, _) = bus.call_peer(station, p55_jstr(r, "workspace"), p55_jtext(r, "method"), r)
        of_core(v)
      },
      ask_text: async fn(station, request) {
        let r = to_core(request)
        match bus.call_peer(station, p55_jstr(r, "workspace"), p55_jtext(r, "method"), r).0 {
          String(t) => t
          other => other.stringify()
        }
      },
      member: (peer, ws) => {
        guard self.roster(ws) is Some(r) && r.iter().any(m => m.0 == peer) else {
          raise BusError("not a station of this workspace")
        }
      },
      subscribe: f => bus.subscribe_store(change => f(p55_jtext(change, "type"))),
      hub: {
        get: async fn(sql, args) {
          match rows(sql, args) {
            [r, ..] => r
            [] => Null
          }
        },
        all: async fn(sql, args) { rows(sql, args) },
        run: async fn(sql, args) { ignore(db.all(sql, args.map(to_core))) },
        thread_sessions: async fn(thread) { core_items(self.hub("store.threadSessions", [Json::number(thread)])).map(of_core) },
        get_session: async fn(key) {
          match (try { Ok(bus.store.get_session(key)) } catch { e => Err(e) }) {
            Ok(r) => of_core(r)
            Err(_) => Null
          }
        },
        ws_of: async fn(s) {
          match self.hub("hub.wsOf", [to_core(s)]) {
            String(w) => Some(w)
            _ => None
          }
        },
        deliver: async fn(thread, n, sessions, text, ws) {
          ignore(self.hub("hub.deliver", [Json::number(thread), Json::number(n), Json::array(sessions.map(Json::string(_))), Json::string(text), p55_jopt(ws)]))
        },
        complete_router_write: async fn(id) { self.hub("store.completeRouterWrite", [Json::string(id)]) is True },
        say: async fn(thread, author, text, _hooks) {
          match self.hub("hub.say", [Json::number(thread), Json::string(author), Json::string(text)]) {
            Number(n, ..) => n
            _ => 0.0
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
    let a = peer_read(from, of_core(params), ws)
    (a.check)()
    (to_core(a.head), Some(a.bytes))
  })
  bus.on_peer_prefix("comma.", async fn(from, ws, meth, params, _bytes) {
    if meth == "comma.say" {
      (to_core(live.say_handler(from, of_core(params), ws)), None)
    } else if meth == "comma.changed" {
      (to_core(live.changed_handler(from, ws)), None)
    } else {
      let a = peer_read(from, of_core(params), ws)
      (a.check)()
      (to_core(a.head), Some(a.bytes))
    }
  })
  let parts_ref : Ref[@comma.CommaParts?] = Ref(None)
  let connects_ref : Ref[@connects_hub.Connects?] = Ref(None)
  let parts = live.make_comma(
    bus.data,
    () => of_core((bus.config_raw.val)()),
    f => (bus.config_listen.val)(raw => f(of_core(raw))),
    options.in_workspace,
    {
      get_session: async fn(key) {
        match (try { Ok(bus.store.get_session(key)) } catch { e => Err(e) }) {
          Ok(r) => of_core(r)
          Err(_) => Null
        }
      },
      pending_count: async fn(key) {
        match self.hub("store.pendingCount", [Json::string(key)]) {
          Number(n, ..) => n
          _ => 0.0
        }
      },
      thread_at: async fn(surface, ch, ts) { (self.connect_threads_store().thread_at)(surface, ch, ts) },
      leave_thread: async fn(thread, key) { ignore(self.hub("store.leaveThread", [Json::number(thread), Json::string(key)])) },
      handler: async fn(event) {
        ignore(self.hub("hub.receive", [Json::string(p55_jtext(to_core(event), "connect")), to_core(event)]))
      },
      book_person: None,
      book_known: None,
    },
    _connect => [],
    async fn() {
      match connects_ref.val {
        Some(c) => c.reconcile()
        None => ()
      }
    },
    async fn() {
      match connects_ref.val {
        Some(c) => c.stop_all()
        None => ()
      }
    },
  )
  parts_ref.val = Some(parts)
  let scoped = (j : @jsjson.JValue) => {
    let id = p55_jtext(to_core(j), "id")
    parts.connects(of_core((bus.config_raw.val)())).search_by(sc => sc.connect.id == id).map(i => parts.connects(of_core((bus.config_raw.val)()))[i])
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
    match @comma.comma_line(match core_items(arg).get(0) { Some(String(l)) => l; _ => "" }) {
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
      let o = to_core(options)
      let key = hex_bytes(p55_jtext(o, "secretKey"))
      let alpns = core_strs(p55_jfield(o, "alpns")).map(a => Json::string(@drive.hex(@utf8.encode(a))))
      let (bound, _) = host.shell(
        "iroh.bind",
        { "relayUrls": p55_jfield(o, "relayUrls"), "alpns": Json::array(alpns), "discovery": Json::boolean(jtrue(o, "discovery")) },
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
          let a = to_core(addr)
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
    speech: { words: @replica_coord.station_words(of_core(zh), of_core(en)), lang: Ref((bus.lang.val)()) },
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
  match p55_jstr(given, "server") {
    Some(server) if server.trim().to_lower() != p55_jtext(Json::object(g), "server") => {
      g["server"] = Json::string(server.trim().to_lower().to_owned())
      for k in ["memberId", "name", "bound"] {
        g.remove(k)
      }
    }
    _ => ()
  }
  match p55_jfield(given, "relays") {
    Array(xs) => g["relays"] = Json::array(xs.filter(x => x is String(_)))
    _ => ()
  }
  match p55_jstr(given, "code") {
    Some(code) if code.trim() != "" => {
      let kept = code.trim().to_upper().to_owned().replace_all(old="-", new="").replace_all(old=" ", new="")
      if kept.length() != 16 {
        raise BusError("the code is not one")
      }
      g["code"] = Json::string(kept)
    }
    _ => ()
  }
  match p55_jfield(given, "botName") {
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
