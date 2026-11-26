// What station/test/mb-live-p5-5.test.ts asks of P5-5's live parts made in this process (`--builder
// harness-station-main`'s "p5_5"), as the admin API (P5-1's, not made here) would: on a data directory and a release of
// the test's, its own key, store and bus, the parts made as `run` makes them; then what the overview says, a route's
// answer, the tools offered and one called, and an op of `coord_ask`.
// - {step: "start", data, app}: the parts made (the agents' door taken as open);
// - {step: "overview", viewer, lang}; {step: "route", method, path, body, viewer, lang};
// - {step: "tools"}; {step: "call", name, args, context}; {step: "coord", name, arg}; {step: "config", config};
// - {step: "peers"}: the mesh's methods answered; {step: "peer", from, workspace, method, params}: one asked;
// - {step: "platform", name, args}: what the updates ask of this machine (updates_platform.mbt), as they ask it;
// - {step: "standIn", hub, peers}: the agents' side (`hub_ask`, by name) and the other stations (by method) answered
//   with what the test gives, what was asked kept; {step: "asked"}: what was asked of them since; {step: "heard",
//   hub}: answered once the agents' side was asked that (what a choice set going comes to);
// - {step: "card", key, call: "may"|"chosen", viewer, card, option, at}: a part's card choice, as the admin API asks it;
// - {step: "stop"}.
// Asked with no parts made (live_p5_5_platforms.mbt as the connects use it):
// - {step: "keepalive"}: how Feishu's and Comma's sockets are pinged and taken for dead ({feishu, comma}: {pingMs,
//   staleMs});
// - {step: "socket", url}: a platform's socket on the shell (`p55_shell_socket`) to the test's WebSocket server:
//   whether it is open before it opened, once opened, and once the server closed it after its ping
//   ({before, opened, said, after}), and a second socket cut off once opened ({cutOpened, cut});
// - {step: "pageBase", state, channel}: where the session pages are as Comma's part is given them (`page_base_of`).
// - {step: "fetchVia", via, url, manual}: a GET as the part `via` names asks the shell for it (Slack's `host_net`,
//   Feishu's, the updates' `fetch_on`, Farview's release download `host_fetch_bytes`, the accounts' `host_io` with its
//   `manual`), its answer ({status, redirected?, body}; Farview's: {body} or null).

///|
let p5_5_harnessed : Ref[LiveBus?] = Ref(None)

///|
let p5_5_stood_asked : Array[Json] = []

///|
let p5_5_stood_waits : Array[(String, @effect.Deferred[Unit])] = []

///|
async fn p5_5_harness(host : @host.Host, ask : Json) -> Result[Json, String] {
  let r = try {
    Ok(p5_5_step(host, ask))
  } catch {
    e => Err("\{e}")
  }
  r
}

///|
async fn p5_5_step(host : @host.Host, ask : Json) -> Json {
  match jtext_or_empty(ask, "step") {
    "keepalive" => {
      let said = (o : @connects_hub.SurfaceOptions) => ({ "pingMs": Json::number(o.ping_ms), "staleMs": Json::number(o.stale_ms) } : Json)
      { "feishu": said(feishu_surface_options(host, "f1", None)), "comma": said(comma_surface_options(host, "c1", None)) }
    }
    "socket" => p5_5_socket_probe(host, jtext_or_empty(ask, "url"))
    "fetchVia" => p5_5_fetch_via(host, jtext_or_empty(ask, "via"), jtext_or_empty(ask, "url"), jfield(ask, "manual") is True)
    "pageBase" =>
      page_base_of(
        match jfield(ask, "state") {
          Null => None
          st => Some(st)
        },
        jtext_or_empty(ask, "channel"),
      )
    "start" => {
      let data = jtext_or_empty(ask, "data")
      let app = jtext_or_empty(ask, "app")
      ignore(attempt(() => @drive.mkdir(path([data, "run"]), true)))
      let key = @cloud_lock.load_key(host, data)
      let db_path = path([data, "stillfail.db"])
      let db = @sql.Db::create(host, db_path, wait=5000)
      @store_schema.open(db, host, db_path, wall_ms())
      let st = @store_sessions.Store::open(db, () => wall_ms(), @agent_runtimes.latest().to_int64())
      let parts = StationParts::new()
      let stopped : @effect.Deferred[String] = @effect.Deferred::new()
      let bus = LiveBus::new(host, "", [], data, app, "0.1.0", key, db, st, parts, stopped, false, "", None, _ => (), why => ignore(stopped.succeed(why)))
      p5_5_harnessed.val = Some(bus)
      start_live_p5_5(bus)
      ignore(bus.door_ready.succeed("http://127.0.0.1:0/mcp"))
      { "station": Json::string(key.id) }
    }
    step => {
      guard p5_5_harnessed.val is Some(bus) else { raise BusError("start first") }
      match step {
        "overview" => Json::object(bus.parts.overview_of(jfield(ask, "viewer"), lang_in(ask)))
        "route" =>
          match answer_route(bus.parts.all_routes(Json::null()), ask) {
            Some(a) => a
            None => refused(404, "no route")
          }
        "tools" => Json::array(bus.parts.all_tools().map(t => Json::string(t.name)))
        "call" =>
          match bus.parts.all_tools().search_by(t => t.name == jtext_or_empty(ask, "name")) {
            Some(i) => (bus.parts.all_tools()[i].call)(jfield(ask, "args"), jfield(ask, "context"))
            None => raise BusError("no such tool offered: \{jtext_or_empty(ask, "name")}")
          }
        "coord" => (bus.coord_ask.val)(jtext_or_empty(ask, "name"), jfield(ask, "arg"))
        "peers" =>
          {
            "methods": Json::array(bus.peer_handlers.keys().map(x => Json::string(x)).collect()),
            "prefixes": Json::array(bus.peer_prefixes.map(p => Json::string(p.0))),
          }
        "peer" => {
          let (v, _) = bus.dispatch_peer(jtext_or_empty(ask, "from"), jtext(ask, "workspace"), jtext_or_empty(ask, "method"), jfield(ask, "params"), None)
          v
        }
        "platform" => {
          let args = match jfield(ask, "args") {
            Array(xs) => xs
            _ => []
          }
          updates_platform(bus.host, bus.data, jtext_or_empty(ask, "name"), args).unwrap_or(Json::null())
        }
        "config" => {
          let next = jfield(ask, "config")
          (bus.config_update.val)(_ => next)
        }
        "standIn" => {
          let hub = jfield(ask, "hub")
          let peers = jfield(ask, "peers")
          bus.hub_ask.val = fn(name, arg) {
            p5_5_stood_asked.push({ "hub": Json::string(name), "args": arg })
            for w in p5_5_stood_waits {
              if w.0 == name {
                ignore(w.1.succeed(()))
              }
            }
            jfield(hub, name)
          }
          bus.peer_call.val = fn(target, ws, meth, params, _bytes) raise {
            p5_5_stood_asked.push({ "peer": Json::string(target), "workspace": jopt(ws), "method": Json::string(meth), "params": params })
            match peers {
              Object(m) if m.contains(meth) => (jfield(peers, meth), None)
              _ => raise BusError("\{meth}: not answered by the test's stations")
            }
          }
          Json::null()
        }
        "asked" => Json::array(p5_5_stood_asked.copy())
        "heard" => {
          let name = jtext_or_empty(ask, "hub")
          if !p5_5_stood_asked.iter().any(x => jtext(x, "hub") == Some(name)) {
            let heard : @effect.Deferred[Unit] = @effect.Deferred::new()
            p5_5_stood_waits.push((name, heard))
            heard.wait()
          }
          Json::null()
        }
        "card" => {
          guard bus.parts.card_choice_named(jtext_or_empty(ask, "key")) is Some(choice) else { raise BusError("no card choice") }
          match jtext_or_empty(ask, "call") {
            "may" => jopt((choice.may)(jfield(ask, "viewer"), jfield(ask, "card"), jfield(ask, "at")))
            _ => {
              (choice.chosen)(jfield(ask, "viewer"), jfield(ask, "card"), jtext_or_empty(ask, "option"), jfield(ask, "at"))
              Json::null()
            }
          }
        }
        "stop" => {
          ignore(bus.stopped.succeed("the test stops"))
          Json::null()
        }
        _ => raise BusError("no such step: \{step}")
      }
    }
  }
}

///|
/// The next thing a socket says, named; a bound only on what must come (one that never comes fails the test, saying so).
async fn p5_5_socket_said(sock : @connects_hub.Socket) -> String {
  guard @effect.timeout(10000, () => sock.events.take()) is Some(ev) else {
    raise BusError("the socket said nothing within 10s")
  }
  match ev {
    Opened => "opened"
    Said(_, _) => "said"
    Pong => "pong"
    Pinged => "pinged"
    Closed => "closed"
    Failed(e) => "failed: \{e}"
    Refused(n, _) => "refused \{n}"
  }
}

///|
async fn p5_5_socket_probe(host : @host.Host, url : String) -> Json {
  let open = p55_shell_socket(host)
  let sock = open(url, [])
  let before = (sock.is_open)()
  let first = p5_5_socket_said(sock)
  guard first == "opened" else { raise BusError("the socket did not open: \{first}") }
  let opened = (sock.is_open)()
  (sock.ping)()
  let said = []
  while true {
    let next = p5_5_socket_said(sock)
    said.push(Json::string(next))
    if next == "closed" || next.has_prefix("failed") {
      break
    }
  }
  let after = (sock.is_open)()
  let other = open(url, [])
  let o = p5_5_socket_said(other)
  guard o == "opened" else { raise BusError("the second socket did not open: \{o}") }
  let cut_opened = (other.is_open)()
  (other.terminate)()
  {
    "before": Json::boolean(before),
    "opened": Json::boolean(opened),
    "said": Json::array(said),
    "after": Json::boolean(after),
    "cutOpened": Json::boolean(cut_opened),
    "cut": Json::boolean((other.is_open)()),
  }
}

///|
/// The step "fetchVia": `url` asked as the part `via` asks the shell for it.
async fn p5_5_fetch_via(host : @host.Host, via : String, url : String, manual : Bool) -> Json {
  let text = (b : Bytes) => Json::string(@utf8.decode_lossy(b))
  match via {
    "slack" => {
      let r = (@slack.host_net(host, @slack.Wall::new(0.0)).fetch)("GET", url, [], None, 10_000)
      { "status": Json::number(r.status.to_double()), "redirected": Json::boolean(r.redirected), "body": text(r.body) }
    }
    "feishu" => {
      let r = (@feishu.host_net(host).fetch)({ url, verb: "GET", headers: [], body: None, timeout_ms: 10_000 })
      { "status": Json::number(r.status.to_double()), "body": text(r.body) }
    }
    "updates" => {
      let r = @updates.fetch_on(host, url)
      { "status": Json::number(r.status.to_double()), "body": text(r.bytes()) }
    }
    "farview" =>
      match (@browser.host_fetch_bytes(host, tmpdir()))(url) {
        Some(b) => { "body": text(b) }
        None => Json::null()
      }
    "oauth" => {
      let r = (@accounts_oauth.host_io(host).fetch)({ url, method_: "GET", headers: [], body: None, timeout_ms: 10_000, manual })
      { "status": Json::number(r.status.to_double()), "body": Json::string(r.body) }
    }
    other => raise LiveError("no part \{other} fetches")
  }
}
