// The ways to a place and the choice among them (ways.mbt). On the peer that answers by itself (stood_wbtest.mbt),
// each way's dials and answers taking what the test says (`far.lag`), on the test's clock; the mesh on `[r1]`
// (bind_wbtest.mbt), keeping in a store of the test's (addrs_wbtest.mbt).

///|
let here : Place = { scope: "", peer }

///|
/// The way the place's requests go on: its link's pin ("main" for the endpoint's).
fn Mesh::on_way(self : Mesh) -> String {
  match self.current(peer) {
    Some(link) => link.pin.unwrap_or("main")
    None => "none"
  }
}

///|
/// The ways open to the place, by their pins, in the order they came.
fn Mesh::open_ways(self : Mesh) -> Array[String] {
  self.live_ways(here).map(way => way.link.pin.unwrap_or("main"))
}

///|
/// A link asked for with what its program says of the ways, run to rest; then `ms` more on the clock.
fn Stood::asked(self : Stood, mesh : Mesh, theirs? : Array[String], off? : Array[String], ms? : Int = 0) -> @effect.Fiber[Link] {
  let asking = self.go(() => mesh.link(peer, Source::new().gives(), theirs?, off?))
  if ms > 0 {
    self.rt.advance(ms)
  }
  asking
}

///|
/// The handle of the endpoint bound on `relay` alone.
fn Stood::endpoint_on(self : Stood, relay : String) -> Int raise {
  for handle, args in self.bound_as {
    if args is { "relayOnly": True, "relayUrls": [String(one)], .. } && one == relay && handle != 1 {
      return handle
    }
  }
  fail("no endpoint on \{relay}")
}

///|
test "the key of an endpoint on one relay alone is SHA-256 of the prefix, the device's key and the relay; it is bound on that relay alone, and one on the LAN on no relay with a key drawn for it" {
  let seed = Bytes::make(32, b'\x01')
  assert_eq(hex_of(pinned_key(relay_key_prefix, seed, r1)), "b5ca7d6e309f43cdba234267e99fe27a66f1040b8ca794c8de82924a49e72eb2")
  assert_eq(
    hex_of(pinned_key(b"app/relay-endpoint/1\x00", seed, r2)),
    "3bb8f09e9e0e6df98e0d6c6b80c632c98735843f06865091dad759503b38fed7",
  )
  assert_eq(relay_key(" https://r2.test "), r2)
  assert_eq(relay_key("https://r2.test:8443/x"), "https://r2.test:8443/x")
  let kept : Map[String, Bytes] = Map([])
  kept[addresses_key] = @utf8.encode("{\"\{peer}\":{\"lan\":[\"192.168.1.5:7000\"],\"tailnet\":[]}}")
  let (stood, _) = Stood::with_peer()
  let made = stood.go(() => Mesh::make(
    stood.shell.val.unwrap(),
    kept_store(kept),
    { alpn: "test/1", relays: [r1], relay_only: false, says: None, refusal: None },
    pinned_prefix=b"app/relay-endpoint/1\x00",
  ))
  guard made.poll() is Some(Succeeded(mesh)) else { fail("the mesh was not made") }
  let asking = stood.asked(mesh, theirs=["https://r2.test"], off=["direct"])
  assert_eq(ended_as(asking), "ok")
  // Off the endpoint, every relay on its own endpoint, and the LAN's addresses on theirs, all at once.
  assert_eq(stood.binds, [
    "{\"relayUrls\":[\"https://r1.test/\"],\"relayOnly\":false,\"lookup\":false}",
    "{\"relayUrls\":[\"https://r1.test/\"],\"relayOnly\":true,\"lookup\":false}",
    "{\"relayUrls\":[\"https://r2.test/\"],\"relayOnly\":true,\"lookup\":false}",
    "{\"relayUrls\":[],\"relayOnly\":false,\"lookup\":false}",
  ])
  assert_eq(hex_of(stood.bind_keys[2]), "3bb8f09e9e0e6df98e0d6c6b80c632c98735843f06865091dad759503b38fed7")
  assert_eq(stood.bind_keys[3], Bytes::make(32, b'\x07'))
  assert_eq(stood.addrs, [
    "{\"id\":\"\{peer}\",\"relays\":[\"https://r1.test/\"]}",
    "{\"id\":\"\{peer}\",\"relays\":[\"https://r2.test/\"]}",
    "{\"id\":\"\{peer}\",\"relays\":[],\"ips\":[\"192.168.1.5:7000\"]}",
  ])
  // The first let in is the link; the others ways beside it, in the order they came (the link's taken a step after
  // its dial ended).
  assert_eq((mesh.on_way(), mesh.open_ways()), (r1, [r2, "lan", r1]))
  // Nothing went on the endpoint.
  assert_eq(stood.times("iroh.connect 1"), 0)
}

///|
test "two relays and a third, the endpoint's ways off: all raced, the quickest the link; past keep_ways the worst let go, closed retire_ms later, its endpoint with it" {
  let (stood, far) = Stood::with_peer()
  let mesh = stood.keeping(Map([]))
  far.lag[r1] = 180
  far.lag[r2] = 25
  far.lag[r3] = 100
  let asking = stood.asked(mesh, theirs=[r2, r3], off=["direct"], ms=25)
  assert_eq(ended_as(asking), "ok")
  assert_eq(mesh.on_way(), r2)
  stood.rt.advance(200)
  assert_eq(mesh.open_ways(), [r2, r3, r1])
  // A ping's first answer is not counted (warm); three more, and the others are compared: r1 the worst, let go.
  // (each tick is `tick_ms` after the pings of the one before were answered: the ways' fiber's every 5 180 ms)
  stood.rt.advance(3 * (tick_ms + 180))
  assert_eq(mesh.retiring.length(), 0)
  stood.rt.advance(tick_ms + 180)
  let retired = mesh.retiring.copy()
  assert_eq(retired.map(link => link.pin), [Some(r1)])
  assert_eq(mesh.open_ways(), [r2, r3])
  assert_true(mesh.live_ways(here).iter().all(way => way.link.samples >= min_samples))
  // Still open meanwhile: what is under way on it comes.
  assert_true(retired[0].usable())
  let r1_endpoint = stood.endpoint_on(r1)
  stood.rt.advance(retire_ms)
  assert_false(retired[0].usable())
  assert_eq(mesh.retiring.length(), 0)
  assert_eq(stood.times("iroh.close \{r1_endpoint}"), 1)
  assert_eq(stood.times("iroh.close \{stood.endpoint_on(r2)}"), 0)
  assert_eq(mesh.on_way(), r2)
  // What is measured: the link's way first, then the other, then the relay let go of with nothing counted.
  let measured = mesh.measured(peer)
  assert_eq(measured.map(m => (m.way, m.kind, m.active, m.samples > 0)), [
    (r2, "relay", true, true),
    (r3, "relay", false, true),
    (r1, "relay", false, false),
  ])
  assert_eq(measured[0].srtt, 25.0)
}

///|
test "requests move to a way clearly better only after min_samples, min_stay_ms and better_ticks in a row; one better by less than move_gain is never moved to" {
  let (stood, far) = Stood::with_peer()
  let mesh = stood.keeping(Map([]))
  far.lag[r1] = 10
  far.lag[r2] = 20
  let asking = stood.asked(mesh, theirs=[r2], off=["direct"], ms=20)
  assert_eq((ended_as(asking), mesh.on_way()), ("ok", r1))
  guard mesh.current(peer) is Some(first) else { fail("no link") }
  let told = stood.go(() => mesh.replaced(first))
  far.lag[r1] = 180
  far.lag[r2] = 25
  // Clearly better from its third counted ping on, but requests stay min_stay_ms where they went (at 10 ms), then
  // move only after better_ticks ticks in a row it was.
  let mut moved_at = None
  let mut most = 0
  while stood.rt.now() < 400_000L && moved_at is None {
    stood.rt.advance(500)
    if stood.rt.now() < (10 + min_stay_ms).to_int64() {
      assert_eq(mesh.live_ways(here)[1].better, 0)
    }
    if mesh.live_ways(here).length() > 1 && mesh.live_ways(here)[1].better > most {
      most = mesh.live_ways(here)[1].better
    }
    if mesh.on_way() == r2 {
      moved_at = Some(stood.rt.now())
    }
  }
  assert_eq(most, better_ticks - 1)
  guard moved_at is Some(at) else { fail("never moved") }
  assert_true(at >= (10 + min_stay_ms + (better_ticks - 1) * tick_ms).to_int64())
  assert_true(at <= (10 + min_stay_ms + (better_ticks + 1) * (tick_ms + 25)).to_int64())
  assert_eq(ended_as(told), "ok")
  assert_true(clearly_better(mesh.score_of(here, mesh.live_ways(here)[0]), mesh.score_of(here, mesh.live_ways(here)[1])))
  // The way before stays open beside it.
  assert_eq(mesh.open_ways(), [r1, r2])
  // Better by less than move_gain: never moved to.
  let (stood, far) = Stood::with_peer()
  let mesh = stood.keeping(Map([]))
  far.lag[r1] = 10
  far.lag[r2] = 20
  ignore(stood.asked(mesh, theirs=[r2], off=["direct"], ms=20))
  far.lag[r1] = 100
  far.lag[r2] = 80
  stood.rt.advance(2 * min_stay_ms)
  assert_eq(mesh.on_way(), r1)
  assert_eq(mesh.live_ways(here).map(way => way.better), [0, 0])
}

///|
test "a way turned off is closed at once, the link's too, whose place another way open takes; none open, the place is dialled anew on what is left" {
  let (stood, far) = Stood::with_peer()
  let mesh = stood.keeping(Map([]))
  far.lag[r1] = 10
  far.lag[r2] = 20
  ignore(stood.asked(mesh, theirs=[r2], off=["direct"], ms=20))
  assert_eq(mesh.on_way(), r1)
  guard mesh.current(peer) is Some(first) else { fail("no link") }
  let told = stood.go(() => mesh.replaced(first))
  let r1_endpoint = stood.endpoint_on(r1)
  mesh.set_ways(peer, off=["direct", "https://r1.test"])
  stood.run()
  assert_eq((mesh.on_way(), ended_as(told), mesh.open_ways()), (r2, "ok", [r2]))
  assert_true(far.closes.contains("\{far.conn_of(r1)} way turned off"))
  assert_eq(stood.times("iroh.close \{r1_endpoint}"), 1)
  // The last way turned off too: closed, and the place dialled anew; nothing is left to dial it on.
  mesh.set_ways(peer, off=["direct", r1, r2])
  stood.run()
  assert_true(far.closes.contains("\{far.conn_of(r2)} way turned off"))
  assert_eq(ended_as(stood.go(() => mesh.link(peer, Source::new().gives()))), "mesh: " + say("all_off"))
  // Turned on again: dialled on it.
  far.lag.clear()
  assert_eq(ended_as(stood.asked(mesh, off=["direct", r1])), "ok")
  assert_eq(mesh.on_way(), r2)
}

///|
test "at the addresses a peer said: dialled each on an endpoint of its own beside the relays while the endpoint's ways are off, and while its last dial there went unanswered given them" {
  let kept : Map[String, Bytes] = Map([])
  kept[addresses_key] = @utf8.encode("{\"\{peer}\":{\"lan\":[\"192.168.1.5:7000\"],\"tailnet\":[\"100.64.0.9:7000\"]}}")
  let (stood, far) = Stood::with_peer()
  let mesh = stood.keeping(kept)
  far.lag[r1] = 30
  far.lag["100.64.0.9:7000"] = 20
  far.lag["192.168.1.5:7000"] = 5
  ignore(stood.asked(mesh, off=["direct"], ms=30))
  assert_eq((mesh.on_way(), mesh.open_ways()), ("lan", ["lan", "tailnet", r1]))
  assert_true(stood.addrs.contains("{\"id\":\"\{peer}\",\"relays\":[],\"ips\":[\"100.64.0.9:7000\"]}"))
  // The tailnet turned off: its way closed, the LAN's stays.
  mesh.set_ways(peer, off=["direct", "tailnet"])
  stood.run()
  assert_eq(mesh.open_ways(), ["lan", r1])
  // With the endpoint's ways on: its dial given the addresses goes unanswered, and the next races the relays'
  // endpoints beside it. (What a way at an address answered says nothing of where the peer is: kept as it was.)
  assert_eq(@utf8.decode(kept.get(addresses_key).unwrap()).contains("100.64.0.9:7000"), true)
  kept[addresses_key] = @utf8.encode("{\"\{peer}\":{\"lan\":[\"192.168.1.5:7000\"],\"tailnet\":[\"100.64.0.9:7000\"]}}")
  let (stood, far) = Stood::with_peer()
  let mesh = stood.keeping(kept)
  far.deaf["main"] = ()
  let first = stood.asked(mesh, ms=connect_timeout_ms)
  assert_eq(ended_as(first), "mesh: " + say("no_answer"))
  assert_true(mesh.unanswered_straight(here))
  let second = stood.asked(mesh, ms=rebind_ms)
  assert_eq((ended_as(second), mesh.on_way()), ("ok", r1))
  assert_eq(far.dialled, ["main", "main", r1])
  // (the endpoint's dial goes on, unanswered, and fails in its time: nothing more is made of it)
  stood.rt.advance(connect_timeout_ms)
  assert_eq(mesh.on_way(), r1)
}

///|
/// Time goes on, 100 ms at a time, until `holds` does, `within` ms at most: the time it came to.
fn Stood::until(self : Stood, within : Int, holds : () -> Bool) -> Int64 raise {
  let end = self.rt.now() + within.to_int64()
  while !holds() {
    guard self.rt.now() < end else { fail("not so within \{within} ms: \{self.said.length()} ops asked") }
    self.rt.advance(100)
  }
  self.rt.now()
}

///|
/// When each dial on the endpoint came.
fn Peer::main_dials(self : Peer) -> Array[Int64] {
  let out = []
  for i, way in self.dialled {
    if way == "main" {
      out.push(self.dials[i])
    }
  }
  out
}

///|
test "a way direct lost soon after requests moved to it, twice in a row: ways direct held off direct_hold_ms on a relay, then moved to again; the endpoint's way, its ways turned on again, dialled every redial_main_ms" {
  let (stood, far) = Stood::with_peer()
  let mesh = stood.keeping(Map([]))
  far.lag[r1] = 30
  far.lag[r2] = 40
  far.lag["main"] = 2
  far.direct["main"] = ()
  ignore(stood.asked(mesh, theirs=[r2], off=["direct"], ms=40))
  assert_eq(mesh.on_way(), r1)
  // Turned on again: the endpoint's way dialled at the ways' next tick, and moved to as soon as it answers clearly
  // quicker, direct.
  mesh.set_ways(peer, off=[])
  ignore(stood.until(5 * tick_ms, () => mesh.on_way() == "main"))
  assert_eq(far.main_dials().length(), 1)
  assert_true(far.main_dials()[0] <= (tick_ms + 100).to_int64())
  // Lost at once: requests go back to a relay at the next tick, one loss.
  far.end(far.conn_of("main"), "gone")
  ignore(stood.until(tick_ms + 200, () => mesh.on_way() != "main"))
  assert_eq(mesh.ways_at(here).losses, 1)
  assert_false(mesh.direct_held(here))
  // Dialled again redial_main_ms after the last, moved to, lost again: ways direct held off.
  ignore(stood.until(redial_main_ms + 5 * tick_ms, () => mesh.on_way() == "main"))
  let dials = far.main_dials()
  assert_eq(dials.length(), 2)
  assert_true(dials[1] - dials[0] >= redial_main_ms.to_int64())
  far.end(far.conn_of("main"), "gone")
  ignore(stood.until(tick_ms + 200, () => mesh.on_way() != "main"))
  assert_eq(mesh.ways_at(here).losses, 2)
  assert_true(mesh.direct_held(here))
  guard mesh.ways_at(here).held_until is Some(until) else { fail("not held") }
  assert_eq(until - stood.rt.now() <= direct_hold_ms.to_int64(), true)
  assert_true(until - stood.rt.now() > (direct_hold_ms - tick_ms).to_int64())
  // Held: the endpoint is not dialled, the requests stay on the relay.
  stood.rt.advance((until - stood.rt.now()).to_int() - 1)
  assert_eq((far.main_dials().length(), mesh.on_way() != "main"), (2, true))
  // The hold over: dialled again, moved to; and staying min_stay_ms, the count starts anew.
  ignore(stood.until(5 * tick_ms, () => mesh.on_way() == "main"))
  assert_eq(far.main_dials().length(), 3)
  stood.rt.advance(min_stay_ms + 2 * tick_ms)
  assert_eq((mesh.on_way(), mesh.ways_at(here).losses), ("main", 0))
}

///|
test "measured anew as asked: what was counted forgotten, every way pinged again; the mesh closed lets go of every endpoint of a way's own, and nothing runs after" {
  let (stood, far) = Stood::with_peer()
  let mesh = stood.keeping(Map([]))
  far.lag[r1] = 30
  far.lag[r2] = 40
  ignore(stood.asked(mesh, theirs=[r2], off=["direct"], ms=40))
  stood.rt.advance(5 * tick_ms)
  assert_true(mesh.measured(peer).iter().all(m => m.samples >= 2))
  mesh.remeasure()
  stood.run()
  assert_eq(mesh.measured(peer).map(m => m.samples), [0, 0])
  stood.rt.advance(1_000)
  assert_true(mesh.measured(peer).iter().all(m => m.samples >= min_samples))
  assert_eq(mesh.measured(peer).map(m => (m.way, m.active)), [(r1, true), (r2, false)])
  let endpoints = [1, stood.endpoint_on(r1), stood.endpoint_on(r2)]
  assert_eq(ended_as(stood.go(() => mesh.close())), "ok")
  for endpoint in endpoints {
    assert_eq(stood.times("iroh.close \{endpoint}"), 1)
  }
  assert_eq(mesh.pinned.length(), 0)
  let said = stood.said.length()
  stood.rt.advance(explore_ms)
  assert_eq(stood.said.length(), said)
}

///|
test "the endpoint's dial raced beside a relay's that won: counted as on the endpoint till it ends, and it alone says whether the endpoint is stuck or its addresses unanswered" {
  let kept : Map[String, Bytes] = Map([])
  kept[addresses_key] = @utf8.encode("{\"\{peer}\":{\"lan\":[\"192.168.1.5:7000\"],\"tailnet\":[]}}")
  let (stood, far) = Stood::with_peer()
  let mesh = stood.keeping(kept)
  far.deaf["main"] = ()
  far.lag[r1] = 10
  // (each link says the same addresses again: kept as they are)
  far.saying(",\"lan\":[\"192.168.1.5:7000\"]")
  assert_eq(ended_as(stood.asked(mesh, ms=connect_timeout_ms)), "mesh: " + say("no_answer"))
  assert_true(mesh.stuck && mesh.unanswered_straight(here))
  // Bound anew (stuck, nothing on it), then the endpoint and r1's own raced: r1 wins, the endpoint's goes on.
  let second = stood.asked(mesh, ms=10)
  assert_eq((ended_as(second), mesh.on_way()), ("ok", r1))
  assert_eq(far.dialled, ["main", "main", r1])
  assert_true(!mesh.stuck && mesh.unanswered_straight(here))
  assert_eq((mesh.dialling_main, mesh.idle()), (1, false))
  // Unanswered in its time, unconnected: the endpoint taken for stuck, its addresses kept as unanswered.
  stood.rt.advance(connect_timeout_ms)
  assert_eq(mesh.dialling_main, 0)
  assert_true(mesh.stuck && mesh.unanswered_straight(here))
  assert_eq(mesh.on_way(), r1)
}

///|
test "a peer's answer that came before its link was a way is heard as it becomes one: what it said kept, and its LAN dialled at once off the endpoint" {
  let values : Map[String, Bytes] = Map([])
  let (stood, far) = Stood::with_peer()
  let mesh = stood.keeping(values)
  far.saying(",\"lan\":[\"10.0.0.2:9\"]")
  assert_eq(ended_as(stood.asked(mesh, theirs=[r2], off=["direct"])), "ok")
  assert_eq(mesh.lan(peer), ["10.0.0.2:9"])
  assert_eq(text_of_kept(values), "{\"\{peer}\":{\"lan\":[\"10.0.0.2:9\"],\"tailnet\":[]}}")
  assert_true(far.dialled.contains("10.0.0.2:9"))
  assert_true(mesh.open_ways().contains("lan"))
}

///|
test "a wake races a way on a relay's own endpoint too, and tries an opening a second time, each on the ways allowed (never the endpoint's, turned off); and forgets what addresses were tried" {
  let (stood, far) = Stood::with_peer()
  let mesh = stood.keeping(Map([]))
  ignore(stood.asked(mesh, off=["direct"]))
  assert_eq((mesh.on_way(), far.dialled), (r1, [r1]))
  mesh.ways_at(here).tried["lan"] = "10.0.0.2:9"
  mesh.wake()
  stood.run()
  assert_eq(far.dialled, [r1, r1])
  assert_eq(mesh.ways_at(here).tried.length(), 0)
  // (the old one answered its probe: kept, the new one let go)
  stood.rt.advance(probe_ms)
  assert_eq(mesh.racing.length(), 0)
  // An opening under way, tried a second time beside its first: on r1's own endpoint again.
  let (stood, far) = Stood::with_peer()
  let mesh = stood.keeping(Map([]))
  far.deaf[r1] = ()
  let asking = stood.asked(mesh, off=["direct"])
  mesh.wake()
  stood.run()
  assert_eq((far.dialled, ended_as(asking)), ([r1, r1], "waiting"))
}

///|
test "a tailnet that never answered is not dialled again every explore_ms; one that answered since the last wake is" {
  let kept : Map[String, Bytes] = Map([])
  kept[addresses_key] = @utf8.encode("{\"\{peer}\":{\"lan\":[],\"tailnet\":[\"100.64.0.9:7000\"]}}")
  let (stood, far) = Stood::with_peer()
  let mesh = stood.keeping(kept)
  far.deaf["100.64.0.9:7000"] = ()
  far.saying(",\"tailnet\":[\"100.64.0.9:7000\"]")
  ignore(stood.asked(mesh, off=["direct"], ms=10))
  let tailnet = () => far.dialled.filter(way => way == "100.64.0.9:7000").length()
  assert_eq((mesh.on_way(), tailnet()), (r1, 1))
  stood.rt.advance(2 * explore_ms)
  assert_eq(tailnet(), 1)
  // It answers, is a way, and is lost: dialled again explore_ms after its last dial.
  far.deaf.clear()
  mesh.ways_at(here).tried.clear()
  ignore(stood.until(2 * tick_ms, () => mesh.open_ways().contains("tailnet")))
  ignore(stood.until(3 * tick_ms, () => mesh.ways_at(here).tailnet_answered))
  let dials = tailnet()
  far.end(far.conn_of("100.64.0.9:7000"), "gone")
  stood.rt.advance(explore_ms - 3 * tick_ms)
  assert_eq(tailnet(), dials)
  ignore(stood.until(explore_ms, () => tailnet() == dials + 1))
}

///|
test "the endpoint's relays' entries are ways of their own; where requests moved and how often, whether the ways are being measured, and a peer measured anew as asked" {
  let (stood, far) = Stood::with_peer()
  let entries : Array[RelayEntry] = [{ entry: "https://e1.test/", relay: r1 }]
  let mesh = stood.made([r1], binding={ lookup: false, takes: [], entries })
  assert_eq(ended_as(stood.go(() => mesh.remeasure_peer(peer))), "mesh: " + say("not_connected"))
  far.lag[r1] = 10
  far.lag["https://e1.test/"] = 20
  ignore(stood.asked(mesh, off=["direct"], ms=20))
  assert_eq((mesh.on_way(), mesh.open_ways()), (r1, [r1, "https://e1.test/"]))
  assert_eq(mesh.measured(peer).map(m => m.way), [r1, "https://e1.test/"])
  // An entry is no way while any of the endpoint's relays is off.
  assert_eq(mesh.ways_for({ scope: "", peer: "ee".repeat(32) }).length(), 2)
  assert_eq((mesh.moves(peer), mesh.moved(peer)), (0, None))
  mesh.set_ways(peer, off=["direct", r1])
  stood.run()
  assert_eq(mesh.ways_for(here), [])
  assert_eq(mesh.open_ways(), [])
  // Back on: r1 lost there, requests moved to the entry's way (no relay host to name: no path chosen here).
  let (stood, far) = Stood::with_peer()
  let mesh = stood.made([r1], binding={ lookup: false, takes: [], entries })
  far.lag[r1] = 10
  far.lag["https://e1.test/"] = 20
  ignore(stood.asked(mesh, off=["direct"], ms=20))
  far.end(far.conn_of(r1), "gone")
  ignore(stood.until(tick_ms + 200, () => mesh.on_way() == "https://e1.test/"))
  assert_eq((mesh.moves(peer), mesh.moved(peer)), (1, Some("direct")))
  assert_eq(relay_host("https://r2.test:8443/x"), "r2.test:8443")
  // Measured anew as asked: the ways not open dialled meanwhile.
  let measuring = stood.go(() => mesh.remeasure_peer(peer))
  assert_true(mesh.measuring(peer))
  stood.rt.advance(1_000)
  assert_eq((ended_as(measuring), mesh.measuring(peer)), ("ok", false))
  assert_true(mesh.open_ways().contains(r1))
}
