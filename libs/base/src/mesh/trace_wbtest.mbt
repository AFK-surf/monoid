// What the mesh tells of itself (trace.mbt): spans to a tracer of the test's, lines to a record of the test's. On the
// peer that answers by itself (stood_wbtest.mbt), the mesh on `[r1]` (bind_wbtest.mbt).

///|
/// A span as the test's tracer kept it.
priv struct Told {
  name : String
  parent : String?
  traceparent : String
  attrs : Array[(String, SpanValue)]
  mut failed : Bool
  mut ended : Bool
}

///|
fn Told::get(self : Told, key : String) -> SpanValue? {
  for one in self.attrs {
    if one.0 == key {
      return Some(one.1)
    }
  }
  None
}

///|
/// A tracer that keeps every span begun, each with a traceparent of its own (its number in each id).
fn traced(peer_key? : String = "peer") -> (Trace, Array[Told]) {
  let told : Array[Told] = []
  let trace : Trace = {
    peer_key,
    start: (name, parent) => {
      let n = told.length() + 1
      let traceparent = format_traceparent(Bytes::make(16, n.to_byte()), Bytes::make(8, n.to_byte()), true)
      let one : Told = { name, parent, traceparent, attrs: [], failed: false, ended: false }
      told.push(one)
      {
        traceparent: Some(traceparent),
        set: (key, value) => one.attrs.push((key, value)),
        own: (key, value) => one.attrs.push((key, value)),
        fail: () => one.failed = true,
        end: () => one.ended = true,
      }
    },
  }
  (trace, told)
}

///|
/// The spans named `name`.
fn named(told : Array[Told], name : String) -> Array[Told] {
  told.filter(one => one.name == name)
}

///|
/// A record that keeps its lines while `on`.
fn recorded() -> (Recorder, Ref[Bool], Array[String]) {
  let on = Ref(true)
  let lines : Array[String] = []
  ({ on: () => on.val, line: text => lines.push(text) }, on, lines)
}

///|
/// A mesh on `[r1]` telling the test's tracer and record.
fn Stood::telling(self : Stood, kept? : Map[String, Bytes] = Map([])) -> (Mesh, Array[Told], Ref[Bool], Array[String]) raise {
  let (trace, told) = traced(peer_key="device")
  let (recorder, on, lines) = recorded()
  let made = self.go(() => Mesh::make(
    self.shell.val.unwrap(),
    kept_store(kept),
    { alpn: "test/1", relays: [r1], relay_only: false, says: None, refusal: None },
    trace~,
    recorder~,
  ))
  guard made.poll() is Some(Succeeded(mesh)) else { fail("the mesh was not made") }
  (mesh, told, on, lines)
}

///|
test "a traceparent as W3C writes one; a place as the record names it; a failure in one short line; nothing told where nothing was given" {
  assert_eq(
    format_traceparent(Bytes::make(16, b'\xab'), Bytes::make(8, b'\x01'), true),
    "00-abababababababababababababababab-0101010101010101-01",
  )
  assert_eq(format_traceparent(Bytes::make(16, b'\x00'), Bytes::make(8, b'\x00'), false).has_suffix("-00"), true)
  assert_eq(peer_tag({ scope: "", peer }), "cdcdcdcd")
  assert_eq(peer_tag({ scope: "scopes-long", peer }).length(), 15)
  assert_eq(peer_tag({ scope: "ab", peer }), "ab/cdcdcdcd")
  assert_eq(said_short("  a\n  b\tc  "), "a b c")
  assert_eq(said_short("x".repeat(200)).length(), 118)
  let span = Span::none()
  (span.own)("k", Int(1L))
  (span.end)()
  assert_eq((Trace::none().start)("x", None).traceparent, None)
  assert_eq((Recorder::none().on)(), false)
  // A mesh given none: a link opens, nothing is asked of a tracer.
  let (stood, _) = Stood::with_peer()
  let mesh = stood.keeping(Map([]))
  ignore(stood.opened(mesh, Source::new().gives()))
}

///|
test "mesh.connect: the peer, who asked, the relays; how it went; its traceparent in the dial's first line; and the record's conn dial line" {
  let (stood, far) = Stood::with_peer()
  let (mesh, told, _, lines) = stood.telling()
  let asking = stood.go(() => mesh.link(peer, Source::new().gives(), asker="GET /x", traceparent="00-parent-01"))
  assert_eq(ended_as(asking), "ok")
  let connect = named(told, "mesh.connect")
  assert_eq(connect.length(), 1)
  let span = connect[0]
  assert_eq((span.parent, span.ended, span.failed), (Some("00-parent-01"), true, false))
  assert_eq(span.get("device"), Some(Str(peer)))
  assert_eq(span.get("asker"), Some(Str("GET /x")))
  assert_eq(span.get("relay"), Some(Str("none")))
  assert_eq(span.get("paths"), Some(Str("")))
  assert_true(span.get("onto_ms") is Some(Int(_)) && span.get("credential_ms") is Some(Int(_)))
  assert_eq(far.heard[0], "0 2 {\"credential\":\"c1\",\"traceparent\":\"\{span.traceparent}\"}")
  assert_eq(lines.filter(line => line.has_prefix("conn dial: ")), [
    "conn dial: #1 cdcdcdcd via=main onto=0ms credential=0ms dialled=0ms openBi=0ms sent=0ms total=0ms -> ok",
  ])
}

///|
test "mesh.connect failing: the error's type, the relays, the addresses given; the record says no-answer, then the endpoint bound anew and the next span says so" {
  let kept : Map[String, Bytes] = Map([])
  kept[addresses_key] = @utf8.encode("{\"\{peer}\":{\"lan\":[\"10.0.0.2:9\"],\"tailnet\":[]}}")
  let (stood, far) = Stood::with_peer()
  let (mesh, told, _, lines) = stood.telling(kept~)
  far.deaf["main"] = ()
  ignore(stood.asked(mesh, ms=connect_timeout_ms))
  let span = named(told, "mesh.connect")[0]
  assert_eq((span.failed, span.ended), (true, true))
  assert_eq(span.get("error.type"), Some(Str("mesh")))
  assert_eq(span.get("ips"), Some(Str("10.0.0.2:9")))
  assert_eq(
    lines.filter(line => line.has_prefix("conn dial: ")),
    ["conn dial: #1 cdcdcdcd via=main+addresses onto=0ms credential=0ms dialled=- openBi=- sent=- total=10000ms -> no-answer"],
  )
  // The next: the endpoint bound anew first, which the record says, and its span.
  far.deaf.clear()
  far.saying(",\"lan\":[\"10.0.0.2:9\"]")
  ignore(stood.asked(mesh, ms=10))
  assert_true(lines.contains("conn rebind: a dial unanswered, nothing open -> bound"))
  assert_eq(named(told, "mesh.connect")[1].get("rebound"), Some(Flag(true)))
}

///|
test "mesh.route as requests move: why, from where and to where, how each scored; mesh.race and mesh.hedge at a wake, each dial's first line under its span" {
  let (stood, far) = Stood::with_peer()
  let (mesh, told, _, _) = stood.telling()
  far.lag[r1] = 10
  far.lag[r2] = 20
  ignore(stood.asked(mesh, theirs=[r2], off=["direct"], ms=20))
  mesh.set_ways(peer, off=["direct", r1])
  stood.run()
  let route = named(told, "mesh.route")
  assert_eq(route.length(), 1)
  assert_eq(route[0].get("why"), Some(Str("lost")))
  assert_eq(route[0].get("to"), Some(Str(r2)))
  assert_true(route[0].get("from") is None || route[0].get("from") == Some(Str(r1)))
  // A wake races the link there: its new dial's first line under the race's span.
  far.lag.clear()
  mesh.wake(retry=true)
  stood.run()
  let race = named(told, "mesh.race")
  assert_eq(race.length(), 1)
  assert_true(far.heard.iter().any(line => line.contains(race[0].traceparent)))
  stood.rt.advance(probe_ms)
  assert_true(race[0].ended && race[0].get("race") is Some(Str("old" | "new")))
  // An opening under way is tried a second time under a hedge's span.
  let (stood, far) = Stood::with_peer()
  let (mesh, told, _, lines) = stood.telling()
  far.deaf["main"] = ()
  let asking = stood.asked(mesh)
  mesh.wake(away_ms=42_400L)
  stood.run()
  let hedge = named(told, "mesh.hedge")
  assert_eq((hedge.length(), hedge[0].get("relay")), (1, Some(Str("none"))))
  assert_true(lines.contains("conn network-change: told the main endpoint (the UI back after 42s), 0 link(s) open, 0 relay endpoint(s) not told"))
  stood.rt.advance(connect_timeout_ms)
  assert_eq((ended_as(asking), hedge[0].failed, hedge[0].ended), ("mesh: " + say("no_answer"), true, true))
}

///|
test "mesh.path once a tick: a way first seen direct, its paths changing, its first ping missed; and the record's conn ways and dht lines, once a tick" {
  let (stood, far) = Stood::with_peer()
  let (mesh, told, on, lines) = stood.telling()
  stood.dht = Some({ "lines": [{ "at": 0, "text": "dht#1 lookup cdcdcdcd" }], "dropped": 2 })
  let link = stood.opened(mesh, Source::new().gives())
  stood.paths_of[link.conn_handle()] = [
    { "id": "1", "selected": true, "relay": Json::null(), "ip": "10.0.0.2:1", "rttMs": 3.4, "txPackets": 5, "lostPackets": 0 },
  ]
  stood.rt.advance(tick_ms)
  let path = named(told, "mesh.path")
  assert_eq(path.length(), 1)
  assert_eq(path[0].get("why"), Some(Str("paths")))
  assert_eq(path[0].get("way"), Some(Str("direct")))
  assert_eq(path[0].get("paths"), Some(Str("*10.0.0.2:1 3ms 5/0")))
  assert_eq(path[0].get("current"), Some(Flag(true)))
  stood.rt.advance(tick_ms)
  assert_eq(named(told, "mesh.path").length(), 1)
  stood.paths_of[link.conn_handle()] = [
    { "id": "1", "selected": false, "relay": Json::null(), "ip": "10.0.0.2:1" },
    { "id": "2", "selected": true, "relay": r1, "rttMs": 20, "txPackets": 9, "lostPackets": 1 },
  ]
  stood.rt.advance(tick_ms)
  let path = named(told, "mesh.path")
  assert_eq(path.length(), 2)
  assert_eq(path[1].get("before.paths"), Some(Str("*10.0.0.2:1 3ms 5/0")))
  // Its ping missed: told once, at the first.
  far.quiet = true
  stood.rt.advance(tick_ms + ping_timeout_ms)
  assert_eq(named(told, "mesh.path")[2].get("why"), Some(Str("missed")))
  // The record: each tick's ways, the DHT's lines once taken (and the shell told to keep none once it is off).
  assert_true(lines.iter().any(line => line.has_prefix("conn ways: cdcdcdcd main in=+0B out=+0B missed=0 [*10.0.0.2:1 3ms +5/0]")))
  assert_true(lines.contains("dht: dht#1 lookup cdcdcdcd (0ms before)"))
  assert_true(lines.contains("dht: 2 line(s) dropped for want of room"))
  on.val = false
  stood.rt.advance(2 * tick_ms)
  assert_eq(stood.dht_keeps[stood.dht_keeps.length() - 1], false)
}

///|
test "mesh.speed: each reply's speed through a relay told at most once every speed_said_ms for each peer and relay, with the way it came on" {
  let (stood, _) = Stood::with_peer()
  let (mesh, told, _, _) = stood.telling()
  let link = stood.opened(mesh, Source::new().gives())
  stood.paths_of[link.conn_handle()] = [{ "id": "0", "selected": true, "relay": r1, "rttMs": 30 }]
  mesh.note_speed(peer, r1, speed_min_bytes, 1000)
  mesh.note_speed(peer, r1, speed_min_bytes, 500)
  let speed = named(told, "mesh.speed")
  assert_eq(speed.length(), 1)
  assert_eq(speed[0].get("via"), Some(Str("r1.test")))
  assert_eq(speed[0].get("bps"), Some(Int(524288L)))
  assert_eq(speed[0].get("current"), Some(Flag(true)))
  assert_eq(speed[0].get("paths"), Some(Str("*r1.test 30ms 0/0")))
  stood.rt.advance(speed_said_ms)
  mesh.note_speed(peer, r1, speed_min_bytes, 2000)
  assert_eq(named(told, "mesh.speed").length(), 2)
}
