// What station/test/mb-live-p5-5.test.ts asks of P5-5's live parts made in this process (`--builder
// harness-station-main`'s "p5_5"), as the admin API (P5-1's, not made here) would: on a data directory and a release of
// the test's, its own key, store and bus, the parts made as `run` makes them; then what the overview says, a route's
// answer, the tools offered and one called, and an op of `coord_ask`.
// - {step: "start", data, app}: the parts made (the agents' door taken as open);
// - {step: "overview", viewer, lang}; {step: "route", method, path, body, viewer, lang};
// - {step: "tools"}; {step: "call", name, args, context}; {step: "coord", name, arg}; {step: "config", config};
// - {step: "peers"}: the mesh's methods answered; {step: "peer", from, workspace, method, params}: one asked;
// - {step: "platform", name, args}: what the updates ask of this machine (updates_platform.mbt), as they ask it;
// - {step: "stop"}.

///|
let p5_5_harnessed : Ref[LiveBus?] = Ref(None)

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
  match p55_jtext(ask, "step") {
    "start" => {
      let data = p55_jtext(ask, "data")
      let app = p55_jtext(ask, "app")
      ignore(attempt(() => @drive.mkdir(path([data, "run"]), true)))
      let key = @cloud_lock.load_key(host, data)
      let db_path = path([data, "stillfail.db"])
      let db = @sql.Db::create(host, db_path, wait=5000)
      @store_schema.open(db, host, db_path, wall_ms())
      let st = @store_sessions.Store::open(db, () => wall_ms(), 0L)
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
        "overview" => Json::object(bus.parts.overview_of(p55_jfield(ask, "viewer"), lang_in(ask)))
        "route" =>
          match answer_route(bus.parts.all_routes(Json::null()), ask) {
            Some(a) => a
            None => refused(404, "no route")
          }
        "tools" => Json::array(bus.parts.all_tools().map(t => Json::string(t.name)))
        "call" =>
          match bus.parts.all_tools().search_by(t => t.name == p55_jtext(ask, "name")) {
            Some(i) => (bus.parts.all_tools()[i].call)(p55_jfield(ask, "args"), p55_jfield(ask, "context"))
            None => raise BusError("no such tool offered: \{p55_jtext(ask, "name")}")
          }
        "coord" => (bus.coord_ask.val)(p55_jtext(ask, "name"), p55_jfield(ask, "arg"))
        "peers" =>
          {
            "methods": Json::array(bus.peer_handlers.keys().map(Json::string(_)).collect()),
            "prefixes": Json::array(bus.peer_prefixes.map(p => Json::string(p.0))),
          }
        "peer" => {
          let (v, _) = bus.dispatch_peer(p55_jtext(ask, "from"), p55_jstr(ask, "workspace"), p55_jtext(ask, "method"), p55_jfield(ask, "params"), None)
          v
        }
        "platform" => {
          let args = match p55_jfield(ask, "args") {
            Array(xs) => xs
            _ => []
          }
          updates_platform(bus.host, bus.data, p55_jtext(ask, "name"), args).unwrap_or(Json::null())
        }
        "config" => {
          let next = p55_jfield(ask, "config")
          (bus.config_update.val)(_ => next)
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
