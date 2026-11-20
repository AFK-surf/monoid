// The presence socket on the runtime's virtual clock and sockets of the test's own: its backoff (a second, doubling to
// a minute, a second again after one that held a minute), its heartbeat (a ping each 30 s, gone at the second with no
// pong), another station on its key (three replaced in a row: a minute's wait, said; a socket that holds ends it), the
// station not answering (closed, opened again once it does), and being removed (404 or 4004: nothing asked until it
// is enrolled again).

///|
priv struct FakeSock {
  url : String
  headers : Headers
  events : WsEvents
  sent : Array[String]
  mut closed : String?
}

///|
priv struct World {
  rt : @effect.Runtime
  cloud : StateCloud
  plane : PlaneCloud
  socks : Array[FakeSock]
  opens : Array[Int64]
  presence : Array[String]
  up : Up
  refuse : Ref[Bool]
  parts : PresenceParts
}

///|
let station_id : String = "aa".repeat(32)

///|
fn world(provider? : Provider = Stillfail) -> World {
  let rt = @effect.Runtime::new()
  let state : Json = {
    "origin": "https://app.still.fail",
    "station": Json::string(station_id),
    "workspace": "w1",
    "workspace_name": "W1",
    "name": "here",
    "relay_url": "https://relay.example",
    "relay_urls": ["https://relay.example"],
    "grant_keys": {},
    "peers": [],
    "revocations": [],
  }
  let cloud = StateCloud::new(Some(state))
  let plane = PlaneCloud::new(cloud, () => rt.now() / 1000L)
  let ways = Ways::new(cloud.view(), Kept::memory().0, () => rt.now())
  let socks : Array[FakeSock] = []
  let opens = []
  let said_presence = []
  let up = Up::new(true)
  let refuse = Ref(false)
  let ws = {
    open: (url, headers, _over, events) => {
      opens.push(rt.now())
      if refuse.val {
        raise NetError("connect ECONNREFUSED")
      }
      let sock = { url, headers, events, sent: [], closed: None }
      socks.push(sock)
      {
        send: t => sock.sent.push(t),
        close: () => sock.closed = Some("close"),
        terminate: () => {
          sock.closed = Some("terminate")
          (events.close)(1006, "")
        },
        is_open: () => sock.closed is None,
      }
    },
  }
  let timers = After::effect(rt)
  let every = (ms : Int, f : () -> Unit) => {
    let fiber = rt.fork(async fn() {
      while true {
        @effect.sleep(ms)
        f()
      }
    })
    fn() { fiber.interrupt() }
  }
  let transport = CloudTransport::new(() => None, {
    after: timers.after,
    tls: (_, _, _, _) => raise NetError("no TLS in this test"),
  })
  let parts = {
    plane,
    ways,
    spec: () => spec_of(provider),
    sign: m => "sig(\{m})",
    version: "0.1.test",
    up,
    ws,
    transport,
    said: _ => (),
    every,
    timers,
    write_presence: (online, error, conflict) => said_presence.push(
      "\{online} \{error.unwrap_or("-")} \{conflict}",
    ),
  }
  let w = {
    rt,
    cloud,
    plane,
    socks,
    opens,
    presence: said_presence,
    up,
    refuse,
    parts,
  }
  ignore(rt.fork(async fn() { presence(parts) }))
  w
}

///|
fn World::refusing(self : World, on : Bool) -> Unit {
  self.refuse.val = on
}

///|
fn World::last(self : World) -> FakeSock {
  self.socks[self.socks.length() - 1]
}

///|
test "a socket that cannot be had is tried again a second later, doubling to a minute" {
  let w = world()
  w.refusing(true)
  w.rt.advance(200_000)
  assert_eq(w.opens, [0L, 1000L, 3000L, 7000L, 15000L, 31000L, 63000L, 123000L, 183000L])
  assert_eq(
    w.presence[0],
    "false connect ECONNREFUSED false",
  )
}

///|
test "it is signed as enrolment is, and opens online; the plane's state is taken" {
  let w = world()
  w.rt.advance(10)
  let s = w.last()
  assert_eq(s.url, "wss://app.still.fail/v1/stations/connect")
  assert_eq(s.headers.get("x-stillfail-station"), Some(station_id))
  assert_eq(s.headers.get("x-stillfail-ts"), Some("0"))
  assert_eq(
    s.headers.get("x-stillfail-signature"),
    Some(
      "sig(stillfail-station-connect-v1:https://app.still.fail:\{station_id}:0)",
    ),
  )
  assert_eq(s.headers.get("x-stillfail-version"), Some("0.1.test"))
  (s.events.open)()
  assert_eq(w.presence, ["true - false"])
  (s.events.message)(
    "{\"type\":\"state\",\"workspace\":\"w1\",\"name\":\"renamed\",\"peers\":[{\"id\":\"\{"bb".repeat(32)}\"}]}",
  )
  assert_eq(w.cloud.state.unwrap().get("name"), Some(Json::string("renamed")))
  assert_true(w.cloud.peers_current)
  assert_true(w.plane.reached)
}

///|
test "a ping each thirty seconds; one with no pong since the last ends the socket" {
  let w = world()
  w.rt.advance(10)
  let s = w.last()
  (s.events.open)()
  w.rt.advance(30_000)
  assert_eq(s.sent, ["ping"])
  w.rt.advance(30_000)
  // (no pong: terminated, the next socket a second later)
  assert_eq(s.closed, Some("terminate"))
  assert_eq(
    w.presence[w.presence.length() - 1],
    "false still.fail cloud stopped answering false",
  )
  w.rt.advance(1000)
  assert_eq(w.socks.length(), 2)
}

///|
test "a socket that held a minute starts over a second after the plane closes it" {
  let w = world()
  w.rt.advance(10)
  let s = w.last()
  (s.events.open)()
  w.rt.advance(30_000)
  (s.events.message)("pong")
  w.rt.advance(40_000)
  (s.events.close)(1012, "restarting")
  w.rt.advance(0)
  assert_eq(
    w.presence[w.presence.length() - 1],
    "false still.fail cloud closed the presence socket (1012 restarting) false",
  )
  w.rt.advance(999)
  assert_eq(w.socks.length(), 1)
  w.rt.advance(1)
  assert_eq(w.socks.length(), 2)
  // (and one that did not hold a minute waits twice as long the next time)
  (w.last().events.close)(1012, "")
  w.rt.advance(1999)
  assert_eq(w.socks.length(), 2)
  w.rt.advance(1)
  assert_eq(w.socks.length(), 3)
}

///|
test "three replaced in a row before they held: another station on this key, said, a minute's wait; one that holds ends it" {
  let w = world()
  w.rt.advance(10)
  (w.last().events.open)()
  (w.last().events.close)(4000, "replaced")
  w.rt.advance(1000)
  (w.last().events.open)()
  (w.last().events.close)(4000, "replaced")
  w.rt.advance(2000)
  (w.last().events.open)()
  (w.last().events.close)(4000, "replaced")
  w.rt.advance(0)
  assert_eq(
    w.presence[w.presence.length() - 1],
    "false \{conflict_error} (still.fail cloud closed the presence socket (4000 replaced)) true",
  )
  assert_eq(w.socks.length(), 3)
  w.rt.advance(59_999)
  assert_eq(w.socks.length(), 3)
  w.rt.advance(1)
  assert_eq(w.socks.length(), 4)
  let s = w.last()
  (s.events.open)()
  // (open alone says the conflict still: the other replaces it a moment later)
  assert_eq(w.presence[w.presence.length() - 1], "true \{conflict_error} true")
  w.rt.advance(30_000)
  (s.events.message)("pong")
  assert_eq(w.presence[w.presence.length() - 1], "true - false")
}

///|
test "the station not answering closes the socket; answering again opens one at once" {
  let w = world()
  w.rt.advance(10)
  let s = w.last()
  (s.events.open)()
  w.up.set(false)
  w.rt.advance(10)
  assert_eq(s.closed, Some("close"))
  assert_eq(
    w.presence[w.presence.length() - 1],
    "false station not answering; went offline at still.fail cloud false",
  )
  w.rt.advance(120_000)
  assert_eq(w.socks.length(), 1)
  w.up.set(true)
  w.rt.advance(10)
  assert_eq(w.socks.length(), 2)
}

///|
test "removed (4004, or 404 at the Upgrade): nothing is asked until enrolled again" {
  let w = world()
  w.rt.advance(10)
  (w.last().events.open)()
  (w.last().events.close)(4004, "removed")
  assert_true(w.cloud.removed())
  w.rt.advance(600_000)
  assert_eq(w.socks.length(), 1)
  assert_eq(
    w.presence[w.presence.length() - 1],
    "false removed from its workspace; enroll it again to bring it back false",
  )
  // (enrolled again: cloud.json changed)
  w.cloud.update(st => st.remove("removed_at"))
  w.rt.advance(10)
  assert_eq(w.socks.length(), 2)
  (w.last().events.unexpected)(404)
  w.rt.advance(10)
  assert_true(w.cloud.removed())
  assert_eq(w.cloud.state.unwrap().get("removed_code"), Some(Json::number(404.0)))
}

///|
test "the roster said last stays reached a minute after its socket ended, unless a new one comes" {
  let w = world()
  w.rt.advance(10)
  let s = w.last()
  (s.events.open)()
  (s.events.message)("{\"type\":\"state\",\"peers\":[]}")
  assert_true(w.plane.reached)
  (s.events.close)(1001, "")
  w.rt.advance(59_000)
  assert_true(w.plane.reached)
  w.rt.advance(1_000)
  assert_false(w.plane.reached)
  assert_true(w.cloud.peers_current)
}

///|
test "the ways are told still.fail's plane as the socket opens and as they change, each once" {
  let w = world()
  w.rt.advance(10)
  let s = w.last()
  ignore(
    add_relay(w.parts.ways, "w1", "https://own.example", Some("an agent")),
  ) catch {
    _ => ()
  }
  (s.events.open)()
  let ways_put = s.sent.filter(t => t.contains("ways.put"))
  assert_eq(ways_put.length(), 1)
  assert_true(ways_put[0].contains("https://own.example"))
  w.cloud.tell()
  assert_eq(s.sent.filter(t => t.contains("ways.put")).length(), 1)
  ignore(set_way(w.parts.ways, "w1", "lan", false)) catch {
    _ => ()
  }
  assert_eq(s.sent.filter(t => t.contains("ways.put")).length(), 2)
}

///|
test "Comma's plane signs in its own tag in still.fail's headers and is told no ways" {
  let w = world(provider=Comma)
  w.rt.advance(10)
  let s = w.last()
  assert_eq(s.url, "wss://app.still.fail/v1/comma/stations/connect")
  assert_eq(
    s.headers.get("x-stillfail-signature"),
    Some("sig(comma-station-connect-v1:https://app.still.fail:\{station_id}:0)"),
  )
  ignore(add_relay(w.parts.ways, "w1", "https://own.example", None)) catch {
    _ => ()
  }
  (s.events.open)()
  assert_eq(s.sent.filter(t => t.contains("ways.put")).length(), 0)
  // (a device tool asked of it: none run here, said so)
  (s.events.message)("{\"type\":\"tool\",\"id\":\"t1\",\"request\":{}}")
  assert_true(s.sent[s.sent.length() - 1].contains("unavailable"))
}

///|
/// The socket closed as the shell's `ws.next` says its end (`@host_world.ws_close_of`, what `host_ws` tells).
fn World::ended_by(self : World, frame : Json) -> Unit {
  let (code, reason) = @host_world.ws_close_of(frame)
  (self.last().events.close)(code, reason)
}

///|
test "the plane's Close frames as the shell says them: 4000 three times waits a minute, 4004 removes, none is neither" {
  let w = world()
  w.rt.advance(10)
  for wait in [1000, 2000, 0] {
    (w.last().events.open)()
    w.ended_by({ "end": true, "code": 4000, "reason": "replaced" })
    w.rt.advance(wait)
  }
  assert_eq(
    w.presence[w.presence.length() - 1],
    "false \{conflict_error} (still.fail cloud closed the presence socket (4000 replaced)) true",
  )
  w.rt.advance(59_999)
  assert_eq(w.socks.length(), 3)
  w.rt.advance(1)
  assert_eq(w.socks.length(), 4)
  (w.last().events.open)()
  w.ended_by({ "end": true, "code": 4004, "reason": "removed" })
  assert_true(w.cloud.removed())
  w.rt.advance(600_000)
  assert_eq(w.socks.length(), 4)
  // (an end with no code, 1005: neither replaced nor removed, tried again a second later)
  let w = world()
  w.rt.advance(10)
  (w.last().events.open)()
  w.ended_by({ "end": true })
  w.rt.advance(1000)
  assert_eq(w.socks.length(), 2)
  assert_false(w.cloud.removed())
  assert_eq(w.presence[w.presence.length() - 1], "false still.fail cloud closed the presence socket (1005) false")
}
