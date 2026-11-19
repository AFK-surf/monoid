// The connects (slack/module.ts `SlackLive`, connects/part.ts `connectsPart`, connects/workspace.ts
// `WorkspaceConnectsLive`): config.json's Slack connects connected while the station is in their workspace and its
// sessions are taken up, disconnected as it leaves; their chats posted to and their events handed to the hub
// (`hub_ask("hub.receive")`) through the workspace's connects, which route a thread whose chat runs on another station
// of the workspace there over the mesh (`connect.*`); the names its people and chats go by, kept in its names book; the
// overview's Slack workspaces and apps; slack_api for the agents where no agents' part offers it; a connect moved to
// another station (the route, and what a move asks of it on `coord_ask`).

///|
/// The connects' files on this machine (connects_hub's `Fs`), through the shell's calls.
fn connects_fs(host : @host.Host) -> @connects_hub.Fs {
  let s = sep()
  let fail = (e : Error) => BusError("\{e}")
  {
    sep: s,
    read_text: async fn(p) {
      match read_text(p) {
        Some(t) => t
        None => raise @session_chats.Thrown("ENOENT", "ENOENT: no such file or directory, open '\{p}'")
      }
    },
    read_bytes: async fn(p) {
      match (host.read_bytes(p) catch { e => raise fail(e) }) {
        Some(b) => b
        None => raise @session_chats.Thrown("ENOENT", "ENOENT: no such file or directory, open '\{p}'")
      }
    },
    read_part: async fn(p, at, n) { (@drive.read_part(p, at, n) catch { e => raise fail(e) }).0 },
    size: async fn(p) { (@drive.stat(p) catch { e => raise fail(e) }).size },
    write_text: async fn(p, t) {
      ignore(attempt(() => @drive.mkdir(@nodepath.dirname(s, p), true)))
      ignore(@drive.write_part(p, { create: true, offset: 0.0, data: @utf8.encode(t), at_least: None, truncate: Some(0.0), sync: false }) catch { e => raise fail(e) })
    },
    write_bytes: async fn(p, b) {
      ignore(attempt(() => @drive.mkdir(@nodepath.dirname(s, p), true)))
      ignore(@drive.write_part(p, { create: true, offset: 0.0, data: b, at_least: None, truncate: Some(0.0), sync: false }) catch { e => raise fail(e) })
    },
    append_text: async fn(p, t) {
      let at = match (try { Ok(@drive.stat(p)) } catch { e => Err(e) }) {
        Ok(st) => st.size
        Err(_) => 0.0
      }
      ignore(@drive.write_part(p, { create: true, offset: at, data: @utf8.encode(t), at_least: None, truncate: None, sync: false }) catch { e => raise fail(e) })
    },
    rename: async fn(a, b) { @drive.rename(a, b) catch { e => raise fail(e) } },
    rm: async fn(p) { @drive.rm_force(p) },
    mkdir: async fn(p) { @drive.mkdir(p, true) catch { e => raise fail(e) } },
    readdir: async fn(p) { @drive.names(p) catch { e => raise fail(e) } },
    write_private: async fn(p, t) {
      host.write_private(p, @utf8.encode(t), sep=s) catch { e => raise fail(e) }
    },
  }
}

///|
fn connects_log() -> @connects_hub.Log {
  { write: (level, part, words, fields) => slice_log(level, part, words, of_jv(fields)) }
}

///|
/// A Slack connect of config.json as connects_hub hands it back (SlackConnect::to_j's): its fields.
fn slack_connect_of(j : @jsjson.JValue) -> @slack.SlackConnect {
  let c = of_jv(j)
  let team = jfield(c, "team")
  {
    id: jtext_or_empty(c, "id"),
    enabled: !(jfield(c, "enabled") is False),
    app_token: jtext_or_empty(c, "appToken"),
    bot_token: jtext_or_empty(c, "botToken"),
    app_id: jtext(c, "appId"),
    team: match jtext(team, "id") {
      Some(id) => Some((id, jtext_or_empty(team, "name")))
      None => None
    },
    bot_name: jtext(c, "botName"),
    bot_image: jtext(c, "botImage"),
    owner: jtext(c, "owner"),
    workspace: jtext(c, "workspace"),
  }
}

///|
/// A thread as the hub names it (`{channel, threadTs}`).
fn thread_of_j(v : @jsjson.JValue?) -> (String, String) {
  match v {
    Some(t) => {
      let c = of_jv(t)
      (jtext_or_empty(c, "channel"), jtext_or_empty(c, "threadTs"))
    }
    None => ("", "")
  }
}

///|
/// The calls a Slack surface answers (sessions/chat.ts `ChatSurface`'s, as slack/surface.ts has them).
let slack_calls : Array[String] = [
  "botUserId", "botName", "identity", "platform", "workspace", "cards", "loginCards", "mention", "post",
  "cardEnded", "download", "history", "places", "openPlaces", "join", "joins", "peopleIn", "begin", "edit", "userName",
  "userEmail", "userOf", "knownPerson", "knownChannel", "channelName", "working", "standsAt", "api", "threadOf",
  "permalink", "refreshIdentity",
]

///|
/// A Slack surface as the connects and the hub take it (connects_hub's `Connection`, its `Surface` called by name).
fn slack_connection(s : @slack.SlackSurface) -> @connects_hub.Connection {
  let txt = (a : Array[@jsjson.JValue], i : Int) => match a.get(i) { Some(Str(u)) => @jsjson.text(u); _ => "" }
  let opt = (v : String?) => match v { Some(t) => to_jv(Json::string(t)); None => @jsjson.JValue::Null }
  let get = fn(name : String, a : Array[@jsjson.JValue]) -> @jsjson.JValue {
    match name {
      "botUserId" => to_jv(Json::string(s.bot_user_id()))
      "botName" => to_jv(Json::string(s.bot_name()))
      "identity" => match s.identity() { Some(i) => i.to_j(); None => Null }
      "platform" => to_jv(Json::string(s.platform()))
      "workspace" => opt(s.workspace())
      "cards" | "loginCards" | "joins" => Bool(name != "joins" || s.joins())
      "mention" => to_jv(Json::string("<@\{txt(a, 0)}>"))
      "knownPerson" => s.known_person(txt(a, 0)).unwrap_or(Null)
      "knownChannel" => opt(s.known_channel(txt(a, 0)))
      "threadOf" =>
        match s.thread_of(txt(a, 0)) {
          Some((ch, ts)) => to_jv({ "channel": Json::string(ch), "threadTs": Json::string(ts) })
          None => Null
        }
      "permalink" => {
        let (ch, ts) = thread_of_j(a.get(0))
        opt(s.permalink(ch, ts))
      }
      "working" => {
        let (ch, ts) = thread_of_j(a.get(0))
        s.working(ch, ts, match a.get(1) { Some(Str(u)) => Some(@jsjson.text(u)); _ => None }, txt(a, 2), page?=match a.get(3) { Some(Str(u)) => Some(Some(@jsjson.text(u))); _ => None })
        Null
      }
      "standsAt" => {
        let (ch, ts) = thread_of_j(a.get(0))
        s.stands_at(ch, ts, @slack.Stands::of_j(a.get(1)))
        Null
      }
      _ => Null
    }
  }
  let surface : @connects_hub.Surface = {
    has: name => slack_calls.contains(name),
    get,
    call: async fn(name, a) {
      match name {
        "post" => {
          let (ch, ts) = thread_of_j(a.get(0))
          let files = match a.get(2) { Some(Arr(xs)) => xs; _ => [] }
          let card = match a.get(3) { Some(Null) | None => None; c => c }
          to_jv(Json::string(s.post(ch, ts, txt(a, 1), files, card~)))
        }
        "cardEnded" => {
          let (ch, ts) = thread_of_j(a.get(0))
          s.card_ended(ch, ts, txt(a, 1), txt(a, 2), a.get(3), a.get(4))
          Null
        }
        "download" => to_jv(Json::string(@drive.hex(s.download(a.get(0).unwrap_or(Null)))))
        "history" => {
          let (ch, ts) = thread_of_j(a.get(0))
          Arr(s.history(ch, ts, txt(a, 1), match a.get(2) { Some(Num(n)) => n.to_int(); _ => 50 }))
        }
        "places" => Arr(s.places())
        "openPlaces" => Arr(s.open_places())
        "join" => {
          s.join(txt(a, 0))
          Null
        }
        "peopleIn" => Arr(s.people_in(txt(a, 0)))
        "begin" => {
          let ch = txt(a, 0)
          let ts = s.begin(ch, txt(a, 1))
          to_jv({ "thread": { "channel": Json::string(ch), "threadTs": Json::string(ts) }, "ts": Json::string(ts) })
        }
        "edit" => {
          let (ch, ts) = thread_of_j(a.get(0))
          Bool(s.edit(ch, ts, txt(a, 1), txt(a, 2)))
        }
        "userName" => opt(s.user_name(txt(a, 0)))
        "userEmail" => opt(s.user_email(txt(a, 0)))
        "userOf" => opt(s.user_of(txt(a, 0)))
        "channelName" => opt(s.channel_name(txt(a, 0)))
        "api" => s.api(txt(a, 0), a.get(1).unwrap_or(Null))
        "refreshIdentity" => {
          s.refresh_identity()
          Null
        }
        _ => get(name, a)
      }
    },
    remote: false,
  }
  let listeners : Array[(Int, () -> Unit)] = []
  let next = Ref(0)
  s.on_change(() => for l in listeners.copy() { (l.1)() })
  {
    surface,
    start: async fn(handler) { s.start(handler) },
    stop: async fn() { s.stop() },
    socket: () => {
      let (connected, last) = s.socket()
      to_jv({ "connected": Json::boolean(connected), "lastError": jopt(last) })
    },
    identity: () => match s.identity() { Some(i) => i.to_j(); None => Null },
    on_change: f => {
      next.val += 1
      let id = next.val
      listeners.push((id, f))
      () => match listeners.search_by(x => x.0 == id) {
        Some(i) => ignore(listeners.remove(i))
        None => ()
      }
    },
    refresh_identity: async fn() { s.refresh_identity() },
  }
}

///|
/// What the slice keeps of the connects: the Slack connects, and the workspace's connects across its stations.
priv struct ConnectsLive {
  slack : @connects_hub.Connects
  /// Every platform's connects by kind (slack, feishu, comma, group: those made).
  kinds : Map[String, @connects_hub.Connects]
  workspace : @connects_hub.WorkspaceConnects
}

///|
/// A connect's connection, whichever platform's it is.
fn ConnectsLive::chat(self : ConnectsLive, id : String) -> @connects_hub.Surface? {
  for _, c in self.kinds {
    match c.chats(id) {
      Some(s) => return Some(s)
      None => ()
    }
  }
  None
}

///|
let connects_live : Ref[ConnectsLive?] = Ref(None)

///|
async fn P55::coord_connects(self : P55, name : String, args : Array[Json]) -> Json {
  ignore(self)
  guard connects_live.val is Some(live) else { return Json::null() }
  let wc = live.workspace
  let s = (i : Int) => match args.get(i) { Some(String(x)) => x; _ => "" }
  let ownc = (cs : Array[@jsjson.JValue]) => Json::array(cs.map(of_jv))
  match name {
    "connects.kindOf" =>
      match wc.kind_mode(s(0)) {
        Some(k) => of_jv(k)
        None => Json::null()
      }
    "connects.ownKinds" => ownc(wc.own_kinds(s(0)))
    // (agents.ts `heldBy`: the station of the workspace a connect with these tokens runs on already, by its name)
    "connects.heldBy" => {
      let ws = match args.get(0) {
        Some(String(w)) => Some(w)
        _ => None
      }
      let own = match args.get(2) {
        Some(o) => Some(to_jv(o))
        None => None
      }
      jopt(wc.held_by(ws, s(1), own))
    }
    "connects.movedAway" => ownc(wc.moved_away(s(0)))
    "connects.runsOn" => jopt(wc.runs_on(s(0)))
    "connects.move" => {
      wc.move_to(s(0), s(1), None, awaiting=core_strs(args.get(2).unwrap_or(Json::null())))
      Json::null()
    }
    "connects.arrived" => {
      wc.arrived(core_strs(args.get(0).unwrap_or(Json::null())))
      Json::null()
    }
    "connects.route" => {
      wc.route(s(0), s(1), s(2), s(3))
      Json::null()
    }
    "connects.describedFor" =>
      match wc.described_for(s(0)) {
        Some((station, described)) => { "station": Json::string(station), "described": of_jv(described) }
        None => Json::null()
      }
    "connects.learnOf" => {
      let k = args.get(0).unwrap_or(Json::null())
      wc.learn_of({ id: jtext_or_empty(k, "id"), origin: jtext_or_empty(k, "origin") }, s(1), to_jv(args.get(2).unwrap_or(Json::null())))
      Json::null()
    }
    "retire.of" => Json::array(wc.own_in(s(0)).map(Json::string(_)))
    "retire.named" => ownc(wc.named_in(s(0)))
    "retire.move" => {
      wc.move_all(s(0), s(1))
      Json::null()
    }
    "retire.takeHeld" => {
      wc.take_held(s(0))
      Json::null()
    }
    _ => Json::null()
  }
}

///|
async fn P55::start_connects(self : P55) -> Unit {
  let bus = self.bus
  let host = bus.host
  let data = bus.data
  let fs = connects_fs(host)
  let log = connects_log()
  let clock = p5_connects_clock()
  let (zh, en) = catalogs_json()
  let words = @replica_coord.station_words(to_jv(zh), to_jv(en))
  let lang = Ref((bus.lang.val)())
  let config : @connects_hub.Config = {
    raw: () => to_jv((bus.config_raw.val)()),
    update_soon: async fn(f) { ignore((bus.config_update.val)(raw => of_jv(f(to_jv(raw))))) },
    listen: f => (bus.config_listen.val)(_raw => f()),
    written: async fn() { () },
  }
  // (connected once the sessions are taken up, while the station is in a workspace)
  let bound = () => bus.door_ready.is_done() && self.memberships().length() > 0
  let in_workspace = (ws : String?) => match ws {
    None => true
    Some(w) => self.memberships().iter().any(m => m.0 == w)
  }
  let workspace_ref : Ref[@connects_hub.WorkspaceConnects?] = Ref(None)
  let receive = async fn(connect : String, event : @jsjson.JValue) -> Unit {
    match workspace_ref.val {
      Some(wc) => wc.receive(connect, event)
      None => ignore(self.hub("hub.receive", [Json::string(connect), of_jv(event)]))
    }
  }
  let options : @connects_hub.ConnectsOptions = {
    data,
    store: {
      live_sessions: () => attempt(() => bus.store.running_sessions()).unwrap_or([]).filter_map(r => jtext(r, "key")),
      notify: key => bus.notify_store({ "type": Json::string("session"), "key": Json::string(key) }),
    },
    config,
    receive,
    bound,
    in_workspace: Some(in_workspace),
    fs,
    clock,
    log,
  }
  // Slack: a connect's surface on Slack's Web API and Socket Mode ($STILLFAIL_SLACK_API: a stand-in's), each socket's
  // events taken as the hub's.
  let client = @slack.SlackClient::new(@slack.host_net(host, @slack.Wall::new(wall_ms().to_double())), base=@slack.api_base(env_get("STILLFAIL_SLACK_API")))
  let slack_log = (level : String, part : String, said : String, fields : @jsjson.JValue) => slice_log(level, part, said, of_jv(fields))
  let slack = @connects_hub.make_connects(options, {
    kind: "slack",
    names: "slack-names.json",
    connects: raw => @slack.slack_connects(Some(raw)).map(c => c.to_j()),
    credentials: c => @slack.slack_credentials(slack_connect_of(c)),
    create: async fn(c, book) {
      let sc = slack_connect_of(c)
      // (its names kept in the connects' book, the one its pages read: connects/names.ts)
      let names : @slack.Names = {
        person: (key, fetch, stale) => book.person(key, fetch, stale~),
        channel: (key, fetch) => match of_jv(book.channel(key, async fn() { to_jv(jopt(fetch())) })) {
          String(n) => Some(n)
          _ => None
        },
      }
      let surface = @slack.SlackSurface::new(
        @slack.SurfaceOptions::new(
          sc.app_token,
          sc.bot_token,
          client,
          @slack.host_clock(host, now=() => p5_epoch_ms().to_double()),
          @slack.host_ws(host),
          words,
          lang,
          slack_log,
          @slack.host_read_file(host),
          connect=Some(sc.id),
          names=Some(names),
        ),
      )
      slack_connection(surface)
    },
    seen: (c, i) => {
      let id = of_jv(i)
      @slack.slack_seen(slack_connect_of(c), {
        team: jtext_or_empty(id, "team"),
        team_id: jtext_or_empty(id, "teamId"),
        url: jtext_or_empty(id, "url"),
        bot_user_id: jtext_or_empty(id, "botUserId"),
        bot_name: jtext_or_empty(id, "botName"),
        bot_image: jtext(id, "botImage"),
        bot_id: jtext_or_empty(id, "botId"),
      })
    },
  })
  self.closing(async fn() { slack.close() })
  // The other platforms' (live_p5_5_platforms.mbt), each on its own: one that is not made is said, the rest are.
  let kinds : Map[String, @connects_hub.Connects] = { "slack": slack }
  let more : Array[(String, async () -> @connects_hub.Connects)] = [
    ("feishu", async fn() { self.start_feishu(options) }),
    ("comma", async fn() { self.start_comma(options) }),
    ("group", async fn() { self.start_group(options) }),
  ]
  for m in more {
    match (try { Ok((m.1)()) } catch { e => Err(e) }) {
      Ok(c) => kinds[m.0] = c
      Err(e) => self.warn(m.0, "its connects are not made", e)
    }
  }
  // The workspace's connects: a thread's chat on another station of the workspace reached there.
  let peer_bus : @connects_hub.Bus = {
    ask: async fn(station, request, body) {
      let r = of_jv(request)
      let bytes = match body {
        NoBody => None
        DataBody(b) => Some(b)
        FileBody(p, from, len) => Some((@drive.read_part(p, from, len) catch { _ => (b"", 0.0, 0.0) }).0)
      }
      let (value, back) = bus.call_peer(station, jtext(r, "workspace"), jtext_or_empty(r, "method"), r, bytes?)
      { json: to_jv(value), bytes: back }
    },
    on: (meth, handler) => bus.on_peer(meth, async fn(from, ws, params, bytes) {
      let a = handler(from, to_jv(with_method(params, meth)), ws, bytes)
      (of_jv(a.json), a.bytes)
    }),
    // (peer.ts `heard`: a station heard from again, a connect's move it may hold settled)
    heard: Some(f => bus.on_peer_heard(f)),
  }
  let wc = @connects_hub.WorkspaceConnects::new({
    data,
    hub: {
      chat_of: async fn(id) {
        for _, c in kinds {
          match c.chats(id) {
            Some(s) => return Some(s)
            None => ()
          }
        }
        None
      },
      config_connects: async fn() { core_items(jfield((bus.config_raw.val)(), "connects")).map(to_jv) },
      receive: async fn(connect, event) { ignore(self.hub("hub.receive", [Json::string(connect), of_jv(event)])) },
      moved_to: async fn(connect, channel, ts) {
        match self.hub("hub.movedTo", [Json::string(connect), Json::string(channel), Json::string(ts)]) {
          String(s) => Some(s)
          _ => None
        }
      },
      quiet_in: async fn(ws) { self.hub("hub.quietIn", [Json::string(ws)]) is True },
      surface: async fn(id) {
        match self.hub("hub.surface", [Json::string(id)]) {
          String(s) if s != "" => s
          _ => id
        }
      },
      told_bots: async fn(peer, bots) { ignore(self.hub("hub.toldBots", [Json::string(peer), Json::array(bots.map(Json::string(_)))])) },
    },
    store: self.connect_threads_store(),
    config,
    here: () => bus.key.id,
    home: () => self.home(),
    stations: ws => match self.memberships().search_by(m => m.0 == ws) {
      Some(i) => self.memberships()[i].3.map(to_jv)
      None => []
    },
    bus: peer_bus,
    names: kind => kinds.get(kind).map(c => c.names),
    fs,
    log,
    speech: { words, lang },
    uuid: () => @drive.random_uuid(),
  })
  workspace_ref.val = Some(wc)
  let live : ConnectsLive = { slack, kinds, workspace: wc }
  connects_live.val = Some(live)
  // (the agents' side keeps each connect's surface as the hub reads it at once, sessions/chat.ts `ChatSurface`: told
  // each time a connect starts, changes or stops)
  let tell_surfaces = () => {
    let all : Map[String, Json] = {}
    for _, c in kinds {
      for conf in c.connects() {
        guard of_jv(conf) is Object(m) && m.get("id") is Some(String(id)) else { continue }
        match c.chats(id) {
          Some(s) => all[id] = p55_surface_json(s)
          None => ()
        }
      }
    }
    ignore(
      bus.host.rt.fork_quiet(name="connects' surfaces told", async fn() {
        ignore((bus.hub_ask.val)("surfaces", Json::object(all))) catch {
          _ => ()
        }
      }),
    )
  }
  for _, c in kinds {
    ignore(c.on_change(tell_surfaces))
  }
  tell_surfaces()
  // (in line with the config once the sessions are taken up; again as the workspaces change)
  let reconcile_all = async fn() {
    for kind, c in kinds {
      c.reconcile() catch {
        e => self.warn(kind, "connects not brought in line with the config", e)
      }
    }
  }
  bus.host.rt.fork(name="connects", async fn() {
    ignore(bus.door_ready.wait())
    reconcile_all()
    if kinds.values().all(c => c.connects().length() == 0) {
      err_write("station: no connect is connected; add or enable one in the workspace's settings\n")
    }
  })
  |> ignore
  ignore((bus.cloud_listen.val)(_state => bus.host.rt.fork(async fn() { reconcile_all() }) |> ignore))
  // (connects/part.ts `agents.along`: in line with the config as the sessions are taken up, the station comes into its
  // workspace or one of those it joined is left or back; every connection ended as it leaves it)
  self.op("agents.along", async fn(arg) {
    let which = match arg {
      String(w) => w
      _ => jtext_or_empty(arg, "which")
    }
    match which {
      "left" =>
        for kind, c in kinds {
          c.stop_all() catch {
            e => self.warn(kind, "connects not stopped", e)
          }
        }
      _ => reconcile_all()
    }
    Json::null()
  })
  for _, c in kinds {
    ignore(c.on_change(() => (bus.overview_changed.val)()))
  }
  // The Slack workspaces a viewer can make apps in, and the apps they made that wait for a connect.
  bus.parts.overview("slackTeams", async fn(viewer, _lang) {
    jfield(of_jv(@slack.slack_overview(Some(to_jv((bus.config_raw.val)())), jtext_or_empty(viewer, "email"))), "slackTeams")
  })
  bus.parts.overview("slackApps", async fn(viewer, _lang) {
    jfield(of_jv(@slack.slack_overview(Some(to_jv((bus.config_raw.val)())), jtext_or_empty(viewer, "email"))), "slackApps")
  })
  // (what the overview shows of each connect config.json names, as its kind says it (connectKind `shown`: slack/index.ts
  // `slackShown`, the Feishu, Comma and group parts' `shown`), where its connection stands, and every kind a part is
  // made for: one ask for the overview)
  self.op("connects.overview", async fn(_arg) {
    let out = []
    for c in core_items(jfield((bus.config_raw.val)(), "connects")) {
      let id = jtext_or_empty(c, "id")
      let kind = match jfield(c, "kind") {
        String(k) if k != "" => k
        _ => "slack"
      }
      guard kinds.get(kind) is Some(k) else { continue }
      let shown = match kind {
        "slack" => of_jv(@slack.slack_shown(Some(to_jv(c))))
        "feishu" => {
          let live = match k.chat(id) {
            Some(conn) => p55_bot_identity(of_jv((conn.identity)()))
            None => None
          }
          @feishu.shown(@feishu.JV::of_json(c), live).to_json()
        }
        "comma" => of_jv(@comma.shown(to_jv(c)))
        "group" =>
          match p55_group_parts.val {
            Some(g) => of_jv(g.shown(to_jv(c)))
            None => Json::object({})
          }
        _ => Json::object({})
      }
      let st = match k.state(to_jv(Json::string(id))) {
        Some(s) => of_jv(s)
        None => Json::null()
      }
      out.push(({ "id": Json::string(id), "kind": Json::string(kind), "connection": st, "shown": shown } : Json))
    }
    let made = []
    for kind, _ in kinds {
      made.push(Json::string(kind))
    }
    { "kinds": Json::array(made), "connects": Json::array(out) }
  })
  // (each connect and where its connection stands: what the agents' overview shows of them, connectKind's)
  self.op("connects.states", async fn(_arg) {
    let out = []
    for kind, k in kinds {
      for c in k.connects() {
        let id = jv_text(c, "id").unwrap_or("")
        let st = match k.state(to_jv(Json::string(id))) {
          Some(s) => of_jv(s)
          None => Json::null()
        }
        out.push(({ "id": Json::string(id), "kind": Json::string(kind), "connection": st } : Json))
      }
    }
    Json::array(out)
  })
  self.connect_kind_ops(live)
  // A connect moved to another station from the pages (connects/workspace.ts' route).
  bus.parts.routes([
    p55_route("POST", "^/connects/([^/]+)/move$", async fn(r) {
      let lang = lang_in(r)
      let to = jtext_or_empty(jfield(r, "body"), "station")
      if to == "" {
        return refused(400, tr(lang, "station.connect.moveWhere"))
      }
      let viewer = jfield(r, "viewer")
      match (try { Ok(wc.move_to(path_seg(r, 2), to, jtext(viewer, "workspace"), lang=Some(lang))) } catch { e => Err(e) }) {
        Ok(_) => answered(200, self.hub("agents.overview", [viewer, Json::string(lang)]))
        Err(e) => refused(500, "\{e}")
      }
    }),
  ])
  // slack_api where the agents' part offers it not (its MCP door, P5-2's, lists its own).
  bus.parts.tools(
    [
      {
        name: "slack_api",
        declared: tool_declared(slack_api_declared),
        call: async fn(args, context) {
          tool_said(async fn() {
            let session = self.session_of(context)
            Json::string(self.slack_api(slack, session, args))
          })
        },
      },
    ],
    // (the agents' side lists its own, tools/chat.ts's, where it runs: this one only where it does not)
    offered=() => bus.mcp_handle.val is None,
  )
  self.op("slack.api", async fn(arg) {
    match arg {
      Array([String(session), args, ..]) => Json::string(self.slack_api(slack, session, args))
      _ => raise BusError("slack.api: [session, args]")
    }
  })
  for op in ["connects.kindOf", "connects.ownKinds", "connects.heldBy", "connects.movedAway", "connects.runsOn", "connects.move", "connects.arrived", "connects.route", "connects.describedFor", "connects.learnOf", "retire.of", "retire.named", "retire.move", "retire.takeHeld"] {
    self.op(op, async fn(arg) { self.coord_connects(op, core_items(arg)) })
  }
  // A connect's chat surface by its call's name (sessions/chat.ts `ChatSurface`), as the agents' side and its storage ask
  // it: `[connect, ...args]`, `{connect, args}`, or `{connect, thread, text, files, user, …}` by the call's fields.
  self.prefix_op("chat.", async fn(name, arg) {
    let meth = name[5:].to_owned()
    guard connects_live.val is Some(live) else { raise BusError("no connects here") }
    let field = (k : String) => jfield(arg, k)
    let (connect, args) : (String, Array[Json]) = match arg {
      Array([String(c), .. rest]) => (c, rest.to_array())
      Object(m) if m.get("args") is Some(Array(a)) => (jtext_or_empty(arg, "connect"), a)
      Object(_) =>
        (
          jtext_or_empty(arg, "connect"),
          match meth {
            "post" => [field("thread"), field("text"), field("files"), field("card")]
            "working" => [field("thread"), field("ts"), field("status"), field("page")]
            "standsAt" => [field("thread"), field("stands")]
            "userName" | "userEmail" | "mention" | "knownPerson" => [field("user")]
            "userOf" => [field("email")]
            "channelName" | "knownChannel" => [field("channel")]
            "sessionLink" => [match field("link") { Null => field("url"); l => l }, field("label")]
            "quoted" => [field("thread"), field("ts")]
            "history" => [field("thread"), field("before"), field("limit")]
            "download" => [field("file")]
            "api" => [field("method"), field("params")]
            _ => []
          },
        )
      _ => raise BusError("chat.\{meth}: [connect, ...args] or {connect, ...}")
    }
    guard live.chat(connect) is Some(s) else { raise BusError("no such connect connected here: \{connect}") }
    match meth {
      "has" =>
        Json::boolean(
          match args.get(0) {
            Some(String(m)) => (s.has)(m)
            _ => false
          },
        )
      "bot" => {
        let name = if (s.has)("botName") { of_jv((s.get)("botName", [])) } else { Json::null() }
        { "name": name, "user": of_jv((s.get)("botUserId", [])) }
      }
      // (what answers at once is the surface's `get`: connects_hub chat.mbt `Surface`)
      "botUserId" | "workspace" => of_jv((s.get)(meth, args.map(to_jv)))
      "post" => of_jv((s.call)(meth, args.map(to_jv)))
      "botName" | "identity" | "platform" | "mention" | "cards" | "loginCards" | "sessionLink" | "answerFiles" | "knownPerson"
      | "knownChannel" | "working" | "standsAt" =>
        if (s.has)(meth) {
          of_jv((s.get)(meth, args.map(to_jv)))
        } else {
          of_jv(@connects_hub.undefined())
        }
      _ =>
        if (s.has)(meth) {
          of_jv((s.call)(meth, args.map(to_jv)))
        } else {
          of_jv(@connects_hub.undefined())
        }
    }
  })
  self.op("connects.chat", async fn(arg) {
    // (a connect's surface called by name: the hub's posting, P5-2's)
    let id = jtext_or_empty(arg, "connect")
    match live.chat(id) {
      Some(s) => of_jv((s.call)(jtext_or_empty(arg, "call"), core_items(jfield(arg, "args")).map(to_jv)))
      None => raise BusError("no such connect connected here: \{id}")
    }
  })
}

///|
/// The store's record of which station a connect's thread's chat runs on (store.ts `connectThreadStation` and its
/// kin), on the station's database.
fn P55::connect_threads_store(self : P55) -> @connects_hub.WsStore {
  let db = self.bus.db
  let all = (sql : String, args : Array[Json]) => (try { Ok(db.all(sql, args)) } catch { e => Err(e) }).unwrap_or([])
  let run = (sql : String, args : Array[Json]) => ignore(try { Ok(db.all(sql, args)) } catch { e => Err(e) })
  let txt = (r : Map[String, Json], k : String) => match r.get(k) { Some(String(s)) => s; _ => "" }
  {
    drop_connect_thread_station: async fn(c, ch, ts) {
      run("DELETE FROM connect_threads WHERE connect = ? AND channel = ? AND thread_ts = ?", [Json::string(c), Json::string(ch), Json::string(ts)])
    },
    set_connect_thread_station: async fn(c, ch, ts, station) {
      run(
        "INSERT INTO connect_threads (connect, channel, thread_ts, station) VALUES (?1, ?2, ?3, ?4) ON CONFLICT (connect, channel, thread_ts) DO UPDATE SET station = ?4",
        [Json::string(c), Json::string(ch), Json::string(ts), Json::string(station)],
      )
    },
    connect_thread_station: async fn(c, ch, ts) {
      match all("SELECT station FROM connect_threads WHERE connect = ? AND channel = ? AND thread_ts = ?", [Json::string(c), Json::string(ch), Json::string(ts)]) {
        [r, ..] => Some(txt(r, "station"))
        [] => None
      }
    },
    drop_connect_threads: async fn(c) { run("DELETE FROM connect_threads WHERE connect = ?", [Json::string(c)]) },
    connect_threads: async fn(c) {
      all("SELECT channel, thread_ts, station FROM connect_threads WHERE connect = ?", [Json::string(c)]).map(r => to_jv({
        "channel": Json::string(txt(r, "channel")),
        "threadTs": Json::string(txt(r, "thread_ts")),
        "station": Json::string(txt(r, "station")),
      }))
    },
    connect_local_threads: async fn(c) {
      all("SELECT DISTINCT t.channel, t.thread_ts FROM thread_sessions s JOIN threads t ON t.id = s.thread WHERE s.connect = ?", [Json::string(c)]).map(r => to_jv({
        "channel": Json::string(txt(r, "channel")),
        "threadTs": Json::string(txt(r, "thread_ts")),
      }))
    },
    thread_at: async fn(surface, ch, ts) {
      match all("SELECT id, surface, channel, thread_ts FROM threads WHERE surface = ? AND channel = ? AND thread_ts = ?", [Json::string(surface), Json::string(ch), Json::string(ts)]) {
        [r, ..] =>
          to_jv({
            "id": r.get("id").unwrap_or(Json::null()),
            "surface": Json::string(txt(r, "surface")),
            "channel": Json::string(txt(r, "channel")),
            "threadTs": Json::string(txt(r, "thread_ts")),
          })
        [] => Null
      }
    },
  }
}

///|
/// slack_api (tools/slack.ts, sessions/conversations.ts `slackApi`): a Slack Web API method as the session's bot (its
/// connect, or the station's one bot named by `bot`); not the methods that manage the app itself. A write in a thread is
/// told the hub, whose the thread's sessions are (`hub.slackWrote`).
async fn P55::slack_api(self : P55, slack : @connects_hub.Connects, session : String, args : Json) -> String {
  let meth = jtext_or_empty(args, "method").trim().to_owned()
  let valid = meth != "" && meth.iter().all(c => (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '.' || c == '_')
  if !valid || !meth.contains(".") {
    raise BusError("not a Slack method: \{Json::string(meth).stringify()}")
  }
  if meth.has_prefix("admin.") || meth.has_prefix("apps.") || meth.has_prefix("oauth.") || meth == "auth.revoke" {
    raise BusError("\{meth} is not for agents: it manages the Slack app itself")
  }
  let params = match jfield(args, "params") {
    Object(_) as p => p
    _ => Json::object({})
  }
  let ids = slack.connects().map(c => jv_text(c, "id").unwrap_or(""))
  let own = match (try { Ok(self.bus.store.get_session(session)) } catch { e => Err(e) }) {
    Ok(row) => jtext(row, "connect")
    Err(_) => None
  }
  let connect = match (jtext(args, "bot"), own) {
    (Some(b), _) if b.trim() != "" =>
      match slack.connects().search_by(c => jv_text(c, "id").unwrap_or("") == b || jv_text(c, "botName") == Some(b)) {
        Some(i) => jv_text(slack.connects()[i], "id").unwrap_or("")
        None => raise BusError("no Slack bot \{b} on this station: \{ids}")
      }
    (_, Some(c)) if ids.contains(c) => c
    _ =>
      match ids {
        [one] => one
        [] => raise BusError("this station has no Slack connect")
        _ => raise BusError("this chat has no Slack bot of its own and the station has several: name one with bot (\{ids})")
      }
  }
  guard slack.chats(connect) is Some(chat) else { raise BusError("the Slack connect \{connect} is not connected") }
  let result = of_jv((chat.call)("api", [to_jv(Json::string(meth)), to_jv(params)]))
  let write = meth == "chat.postMessage" || meth == "chat.update" || meth == "chat.delete" || meth.has_prefix("reactions.") || meth == "files.completeUploadExternal" || meth == "chat.postEphemeral"
  if write && (jtext(params, "channel") is Some(_) || jtext(params, "channel_id") is Some(_)) {
    ignore(self.hub("hub.slackWrote", [Json::string(session), Json::string(connect), Json::string(meth), params, result])) catch {
      _ => ()
    }
  }
  let text = result.stringify()
  let chars = text.iter().collect()
  if chars.length() > 60000 {
    String::from_array(chars[:60000].to_array()) + "… (cut at 60000 characters; ask for less, e.g. a smaller limit)"
  } else {
    text
  }
}

///|
/// slack_api (tools/slack.ts `SLACK_API`), as it is declared to the agents.
let slack_api_declared : String =
  #|{
  #|  "name": "slack_api",
  #|  "description": "Call any Slack Web API method as your Slack bot, e.g. conversations.history, users.info, reactions.add, chat.update, chat.postMessage in a channel, conversations.open then chat.postMessage for a direct message. A chat that did not start in Slack calls as the station's Slack bot. Writes in a thread another session takes part in are refused; posting in a thread nobody else is in, or a new message, makes that thread one of your conversations. Prefer chat_post to answer the thread you are working in. To see a file in another thread (a screenshot), read it with save_files: its url_private does not open for you.",
  #|  "inputSchema": {
  #|    "type": "object",
  #|    "properties": {
  #|      "method": {
  #|        "type": "string",
  #|        "description": "The Web API method, e.g. \"conversations.replies\"."
  #|      },
  #|      "params": {
  #|        "type": "object",
  #|        "description": "Its arguments as Slack documents them (blocks and other structures as JSON values).",
  #|        "additionalProperties": true
  #|      },
  #|      "to": {
  #|        "type": "string",
  #|        "description": "CHANNEL/THREAD_TS of one of your Slack conversations: whose bot to call as. Default: this session's own connect."
  #|      },
  #|      "save_files": {
  #|        "type": "boolean",
  #|        "description": "Also save the files in the answer (conversations.replies, conversations.history, files.info) into your workspace's uploads. The answer starts with saved_files, their local paths, and not_saved, why any could not be."
  #|      },
  #|      "bot": {
  #|        "type": "string",
  #|        "description": "Which of the station's Slack bots to call as, by its id or name, when the chat has none of its own and the station has several (the error names them). Default: the one bound to your runtime."
  #|      }
  #|    },
  #|    "required": [
  #|      "method"
  #|    ],
  #|    "additionalProperties": false
  #|  }
  #|}

///|
/// The optional calls of a chat surface (sessions/chat.ts `ChatSurface`): those a surface has, the hub asks.
let p55_surface_calls : Array[String] = [
  "answerFiles", "api", "begin", "botName", "cardEnded", "cards", "channelName", "download", "edit", "history",
  "identity", "join", "joins", "knownChannel", "knownPerson", "loginCards", "mention", "openPlaces", "peopleIn",
  "permalink", "places", "platform", "quoted", "sessionLink", "standsAt", "start", "stop", "threadOf", "userEmail",
  "userName", "userOf", "working",
]

///|
/// A connect's surface as the agents' side keeps it: its bot, its platform's workspace, the calls it has.
fn p55_surface_json(s : @connects_hub.Surface) -> Json {
  let got = (name : String) => match of_jv((s.get)(name, [])) {
    Object(m) if m.contains("$u") => Json::null()
    v => v
  }
  let out : Map[String, Json] = {
    "botUserId": got("botUserId"),
    "workspace": got("workspace"),
    "has": Json::array(p55_surface_calls.filter(c => (s.has)(c)).map(Json::string(_))),
    "remote": Json::boolean(s.remote),
  }
  // (what answers at once besides, where it has it: the hub's `chatProp`)
  for name in ["botName", "platform", "identity", "cards", "loginCards"] {
    if (s.has)(name) {
      out[name] = got(name)
    }
  }
  Json::object(out)
}

///|
/// A Feishu connection's identity as its surface says it (`BotIdentity::to_jv`), None where it has none yet.
fn p55_bot_identity(j : Json) -> @feishu.BotIdentity? {
  guard j is Object(m) && m.get("botUserId") is Some(String(_)) else { return None }
  let t = (k : String) => match m.get(k) {
    Some(String(s)) => s
    _ => ""
  }
  Some({
    team: t("team"),
    team_id: t("teamId"),
    url: t("url"),
    bot_user_id: t("botUserId"),
    bot_name: t("botName"),
    bot_image: match m.get("botImage") {
      Some(String(s)) => Some(s)
      _ => None
    },
    bot_id: t("botId"),
  })
}

///|
/// The group's part, made by `start_group`, for what the overview shows of a group connect.
let p55_group_parts : Ref[@connects_hub.GroupParts?] = Ref(None)

///|
/// The connects' clock (`@connects_hub.Clock::live`) with its time since the epoch: what it keeps (a name's `at`) is
/// read again by the next process.
fn p5_connects_clock() -> @connects_hub.Clock {
  { ..@connects_hub.Clock::live(), now: () => p5_epoch_ms().to_double() }
}
