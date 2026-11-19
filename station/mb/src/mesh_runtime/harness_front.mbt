// The front's client in the harness (station/test/mb-mesh-runtime.test.ts runs a front of its own on a Unix socket, as
// it does for the TypeScript's `withFront`): endpoints bound through the shell's sockets, their connections and streams
// kept by name and asked as the test says (`front` `{name, verb, args}`), each answered once it is done.

///|
priv struct FrontHarness {
  host : @host.Host
  endpoints : Map[String, FrontEndpoint]
  conns : Map[String, @door.Connection]
  streams : Map[String, @door.Stream]
  logs : Array[Json]
  /// The waits between tries to link again, each held till the test lets it end (`wake`), and what waits for one.
  sleeping : Array[(Int, @effect.Deferred[Unit])]
  mut sleeper : @effect.Deferred[Unit]?
  /// The shell's sockets the client holds (connected or accepted, not yet let go), and what waits for one let go.
  mut live : Int
  mut let_go : @effect.Deferred[Unit]?
}

///|
fn FrontHarness::new(host : @host.Host) -> FrontHarness {
  { host, endpoints: Map([]), conns: Map([]), streams: Map([]), logs: [], sleeping: [], sleeper: None, live: 0, let_go: None }
}

///|
/// The shell's sockets, each counted from when the client has it until it lets it go (`destroy`): the shell keeps one
/// until then, ended both ways or not.
fn FrontHarness::counted(self : FrontHarness, sockets : Sockets) -> Sockets {
  let held = (k : Sock) => {
    self.live += 1
    let gone = Ref(false)
    let s : Sock = {
      ..k,
      destroy: () => {
        if !gone.val {
          gone.val = true
          self.live -= 1
          if self.let_go is Some(w) {
            self.let_go = None
            ignore(w.succeed(()))
          }
        }
        (k.destroy)()
      },
    }
    s
  }
  {
    connect: async fn(path) { held((sockets.connect)(path)) },
    listen: async fn(path) {
      let l = (sockets.listen)(path)
      {
        accept: async fn() -> Sock? {
          match (l.accept)() {
            Some(k) => Some(held(k))
            None => None
          }
        },
        close: l.close,
      }
    },
    remove: sockets.remove,
  }
}

///|
fn bytes_arg(v : Json?) -> Array[Bytes] {
  arr(v).map(x => hex_arg(Some(x)))
}

///|
/// One thing asked of the front's client (`verb`), its answer.
async fn FrontHarness::ask(self : FrontHarness, name : String, verb : String, a : Json) -> Json {
  let ep = () => match self.endpoints.get(name) {
    Some(e) => e
    None => raise Failure("no endpoint \{name}")
  }
  let conn = () => match self.conns.get(name) {
    Some(c) => c
    None => raise Failure("no connection \{name}")
  }
  let stream = () => match self.streams.get(name) {
    Some(s) => s
    None => raise Failure("no stream \{name}")
  }
  let as_ = str_of(arg(a, "as")).unwrap_or("")
  match verb {
    "bind" => {
      let o = arg(a, "options").unwrap_or(Json::null())
      let bind = front_bind_options(
        hex_arg(field(o, "secretKey")),
        bytes_arg(field(o, "alpns")),
        strs(field(o, "relayUrls")),
        discovery=!(field(o, "discovery") is Some(False)),
        bind_addr=str_of(field(o, "bindAddr")),
        relay_only=field(o, "relayOnly") is Some(True),
        congestion=str_of(field(o, "congestion")),
        dscp=num_of(field(o, "dscp")),
      )
      let logs = self.logs
      let e = FrontEndpoint::bind(
        self.counted(shell_sockets(self.host)),
        str_of(arg(a, "socket")).unwrap_or(""),
        @host.pid(),
        bind,
        self.host.rt,
        async fn(ms) {
          let d : @effect.Deferred[Unit] = @effect.Deferred::new()
          self.sleeping.push((ms, d))
          if self.sleeper is Some(w) {
            self.sleeper = None
            ignore(w.succeed(()))
          }
          d.wait()
        },
        (level, part, words, with_) => logs.push(jobj([("level", jstr(level)), ("at", jstr(part)), ("words", jstr(words)), ("with", with_)])),
      )
      self.endpoints[name] = e
      jobj([("id", jstr(e.id())), ("sockets", Json::array(e.sockets().map(jstr)))])
    }
    "accept" =>
      match ep().accept() {
        Some(c) => {
          self.conns[as_] = c
          jobj([("remote", jstr((c.remote_id)())), ("alpn", jstr((c.alpn)())), ("handed", opt_json(c.handed.map(h => h.to_double())))])
        }
        None => Json::null()
      }
    "connect" => {
      let c = ep().connect(arg(a, "addr").unwrap_or(Json::null()), hex_arg(arg(a, "alpn")), additional=bytes_arg(arg(a, "additional")))
      self.conns[as_] = c
      jobj([("remote", jstr((c.remote_id)()))])
    }
    "linked" => Json::boolean(ep().linked())
    "id" => jobj([("id", jstr(ep().id())), ("sockets", Json::array(ep().sockets().map(jstr)))])
    "online" => {
      ep().online()
      Json::null()
    }
    "home" => opt_str(ep().home())
    "relayStatus" => ep().relay_status()
    "disabledRelays" => {
      ep().disabled_relays(str_of(arg(a, "peer")).unwrap_or(""), strs(arg(a, "relays")), arg(a, "public") is Some(True))
      Json::null()
    }
    "insertRelay" => {
      ep().insert_relay(str_of(arg(a, "url")).unwrap_or(""))
      Json::null()
    }
    "removeRelay" => {
      ep().remove_relay(str_of(arg(a, "url")).unwrap_or(""))
      Json::null()
    }
    "publicRelays" => {
      ep().public_relays(arg(a, "on") is Some(True))
      Json::null()
    }
    "keep" => {
      ep().keep(strs(arg(a, "urls")))
      Json::null()
    }
    "setCongestion" => {
      ep().set_congestion(str_of(arg(a, "congestion")).unwrap_or(""))
      Json::null()
    }
    "holdIncoming" => {
      ep().hold_incoming(num_of(arg(a, "n")).unwrap_or(0.0).to_int())
      Json::null()
    }
    "addAddr" => {
      ep().add_addr(arg(a, "addr").unwrap_or(Json::null()))
      Json::null()
    }
    "setRelayEntries" => {
      ep().set_relay_entries(arg(a, "entries").unwrap_or(Json::array([])))
      Json::null()
    }
    "networkChange" => {
      ep().network_change()
      Json::null()
    }
    "route" =>
      Json::boolean(ep().route(hex_arg(arg(a, "alpn")), strs(arg(a, "to")), strs(arg(a, "routes"))))
    "close" => {
      ep().close()
      Json::null()
    }
    // the shell's sockets the client holds; `fewerThan`: once they are fewer than that
    "live" => {
      let under = num_of(arg(a, "fewerThan")).map(n => n.to_int())
      while under is Some(n) && self.live >= n {
        let w : @effect.Deferred[Unit] = @effect.Deferred::new()
        self.let_go = Some(w)
        w.wait()
      }
      jnum(self.live.to_double())
    }
    "logs" => {
      let out = self.logs.copy()
      self.logs.clear()
      Json::array(out)
    }
    "wake" => {
      // (the next wait begun, let end: how long it was to be)
      if self.sleeping.length() == 0 {
        let w : @effect.Deferred[Unit] = @effect.Deferred::new()
        self.sleeper = Some(w)
        w.wait()
      }
      let (ms, d) = self.sleeping.remove(0)
      ignore(d.succeed(()))
      jnum(ms.to_double())
    }
    // a connection's
    "openBi" => {
      self.streams[as_] = (conn().open_bi)()
      Json::null()
    }
    "acceptBi" =>
      match (conn().accept_bi)() {
        Some(s) => {
          self.streams[as_] = s
          Json::boolean(true)
        }
        None => Json::null()
      }
    "connClose" => {
      (conn().close)(num_of(arg(a, "code")).unwrap_or(0.0).to_int(), str_of(arg(a, "reason")).unwrap_or(""))
      Json::null()
    }
    "closed" => jstr((conn().closed)())
    "isClosed" => Json::boolean((conn().is_closed)())
    "closeReason" =>
      match conn().close_reason.map(f => f()).unwrap_or(None) {
        Some((kind, reason)) => jobj([("kind", jstr(kind)), ("reason", jstr(reason))])
        None => Json::null()
      }
    "via" => opt_str((conn().via)())
    "answers" => Json::boolean(conn().answers.unwrap()(num_of(arg(a, "within")).unwrap_or(0.0).to_int()))
    // a stream's
    "write" => {
      (stream().write)(hex_arg(arg(a, "bytes")))
      Json::null()
    }
    "read" =>
      match (stream().read)() {
        Some(b) => hexj(b)
        None => Json::null()
      }
    "finish" => {
      (stream().finish)()
      Json::null()
    }
    "stopped" => opt_json((stream().stopped)().map(c => c.to_double()))
    "reset" => {
      (stream().reset)(num_of(arg(a, "code")).unwrap_or(0.0).to_int())
      Json::null()
    }
    _ => raise Failure("no verb \{verb}")
  }
}

///|
/// What `incoming` is given and taken, in a test's order (`{give: [id, index?]}`, `{skip}`, `{take}`, `{end}`): the ids
/// taken (None: none came), and those let go.
pub fn incoming_steps_json(steps : Array[Json]) -> Json {
  incoming_steps(steps)
}

///|
fn incoming_steps(steps : Array[Json]) -> Json {
  let i = Incoming::new()
  let rt = @effect.Runtime::new()
  let taken = []
  let destroyed = []
  for s in steps {
    match s {
      { "give": Array(g), .. } => {
        let id = num_of(g.get(0)).unwrap_or(0.0).to_int64()
        let sock : Sock = {
          read: async fn() -> Bytes? { None },
          write: async fn(_) {  },
          end: async fn() {  },
          destroy: () => destroyed.push(jnum(id.to_double())),
        }
        let index = match g.get(1) {
          Some(Number(n, ..)) => Some(n.to_int64())
          _ => None
        }
        i.give({ held: Held::new(sock), carry: b"", id }, index~)
      }
      { "skip": Number(n, ..), .. } => i.skip(n.to_int64())
      { "take": _, .. } =>
        ignore(
          rt.fork(() => taken.push(
            match i.take() {
              Some(c) => jnum(c.id.to_double())
              None => Json::null()
            },
          )),
        )
      { "end": _, .. } => i.end()
      _ => ()
    }
    ignore(rt.run_ready())
  }
  jobj([("taken", Json::array(taken)), ("destroyed", Json::array(destroyed))])
}
