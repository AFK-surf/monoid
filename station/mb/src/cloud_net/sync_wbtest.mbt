// Bringing the stations level (follow_ways, follow_marks) on a clock of the test's own: a peer that cannot be reached
// is tried again 5 s later, doubling to ten minutes, and the two come level once it answers; one from before is left
// be until this station's record changes again. And what holds the peers to their relays (PeerRelays), what keeps the
// endpoint on them (keep_relays) and what gathers notices (Notifier).

///|
let me_id : String = "aa".repeat(32)

///|
let peer_b : String = "bb".repeat(32)

///|
fn base_state(peers : Array[String]) -> Json {
  {
    "origin": "https://app.still.fail",
    "station": Json::string(me_id),
    "workspace": "w1",
    "workspace_name": "W1",
    "name": "here",
    "relay_url": "https://r1.still.fail",
    "relay_urls": ["https://r1.still.fail", "https://r2.still.fail"],
    "stillfail_relays": ["https://r1.still.fail", "https://r2.still.fail"],
    "grant_keys": {},
    "peers": Json::array(peers.map(p => { "id": Json::string(p) })),
    "revocations": [],
  }
}

///|
fn times_asked(trace : Json, asked : String) -> Array[Int64] {
  array_of(Some(trace))
  .unwrap_or([])
  .filter_map(t => match field(t, "request") {
    Some(r) if text_of(field(r, "method")) == Some(asked) => Some(num(field(t, "t")))
    _ => None
  })
}

///|
test "a peer that is down is tried again sooner at first, doubling, and brought level once it answers" {
  let peer_state = base_state([me_id])
  let kept : Json = {
    "w1": { "relays": [{ "url": "https://own.example" }], "off": [], "at": 50, "station": me_id },
  }
  let c : Json = {
    "op": "follow",
    "follow": "ways",
    "state": base_state([peer_b]),
    "kept": kept.stringify(),
    "peers": {
      "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb": {
        "state": with_station(peer_state, peer_b),
        "delay": 10,
        "down": [[0, 40_000]],
        "home": "w1",
      },
    },
    "events": [],
    "until": 200_000,
  }
  let out = follow_case(c)
  let gets = times_asked(field(out, "trace").unwrap(), "ways.get")
  // (asked at 0; failed at 10: again at 5 010, 15 020, 35 030 (down still), 75 040: answered)
  assert_eq(gets, [0L, 5010L, 15020L, 35030L, 75040L])
  let puts = times_asked(field(out, "trace").unwrap(), "ways.put")
  assert_eq(puts, [75050L])
  assert_eq(
    field(field(out, "peers").unwrap(), peer_b).unwrap().stringify(),
    "{\"w1\":{\"relays\":[{\"url\":\"https://own.example\"}],\"off\":[],\"at\":50,\"station\":\"\{me_id}\"}}",
  )
  assert_eq(num(field(out, "waiting")), 0L)
}

///|
test "the waits double up to ten minutes" {
  let c : Json = {
    "op": "follow",
    "follow": "marks",
    "state": base_state([peer_b]),
    "peers": {
      "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb": { "state": base_state([me_id]), "delay": 0, "down": [[0, 100_000_000]], "home": "w1" },
    },
    "events": [{ "at": 1, "do": "mark", "name": "here" }],
    "until": 3_000_000,
  }
  let out = follow_case(c)
  let gets = times_asked(field(out, "trace").unwrap(), "stationMarks.get")
  let gaps = []
  for i in 1..<gets.length() {
    gaps.push(gets[i] - gets[i - 1])
  }
  assert_eq(gaps.length() > 8, true)
  assert_eq(gaps[0:7].to_owned(), [
    5000L, 10000L, 20000L, 40000L, 80000L, 160000L, 320000L,
  ])
  assert_true(gaps[7:].iter().all(g => g == 600_000L))
}

///|
test "a station from before is left be until this station's record changes again" {
  let c : Json = {
    "op": "follow",
    "follow": "ways",
    "state": base_state([peer_b]),
    "peers": {
      "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb": { "state": base_state([me_id]), "delay": 5, "before": true, "home": "w1" },
    },
    "events": [{ "at": 1000, "do": "add", "ws": "w1", "url": "https://own.example" }],
    "until": 100_000,
  }
  let out = follow_case(c)
  assert_eq(times_asked(field(out, "trace").unwrap(), "ways.get"), [0L, 1000L])
}

///|
test "no roster current, nothing is asked; a rig asks no marks" {
  let c : Json = {
    "op": "follow",
    "follow": "ways",
    "state": base_state([peer_b]),
    "peersCurrent": false,
    "peers": { "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb": { "state": base_state([me_id]), "home": "w1" } },
    "events": [{ "at": 10, "do": "roster", "peersCurrent": true }],
    "until": 1000,
  }
  let out = follow_case(c)
  assert_eq(times_asked(field(out, "trace").unwrap(), "ways.get"), [10L])
  let rig_state = object_copy(base_state([peer_b]))
  rig_state["rig"] = pending_self
  let c2 : Json = {
    "op": "follow",
    "follow": "marks",
    "state": Json::object(rig_state),
    "peers": { "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb": { "state": base_state([me_id]), "home": "w1" } },
    "events": [],
    "until": 1000,
  }
  let out2 = follow_case(c2)
  assert_eq(times_asked(field(out2, "trace").unwrap(), "stationMarks.get"), [])
}

///|
test "the newer mark is kept by both, the older not given back" {
  let mine : Json = { "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa": { "name": "mine", "emoji": "", "icon": "", "at": 10 } }
  let theirs : Json = {
    "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa": { "name": "older", "emoji": "", "icon": "", "at": 5 },
    "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb": { "name": "peer", "emoji": "🚀", "icon": "", "at": 7 },
  }
  let c : Json = {
    "op": "follow",
    "follow": "marks",
    "state": base_state([peer_b]),
    "kept": mine.stringify(),
    "peers": {
      "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb": {
        "state": with_station(base_state([me_id]), peer_b),
        "kept": theirs.stringify(),
        "home": "w1",
      },
    },
    "events": [],
    "until": 1000,
  }
  let out = follow_case(c)
  let of = field(field(field(out, "mine").unwrap(), "w1").unwrap(), "of").unwrap()
  assert_eq(text_of(field(field(of, peer_b).unwrap(), "name")), Some("peer"))
  assert_eq(text_of(field(field(of, me_id).unwrap(), "name")), Some("mine"))
  let peer_of = field(
    field(field(field(out, "peers").unwrap(), peer_b).unwrap(), "w1").unwrap(),
    "of",
  ).unwrap()
  assert_eq(text_of(field(field(peer_of, me_id).unwrap(), "name")), Some("mine"))
}

// ── the peers' relays ──

///|
fn ways_with(off : Array[String]) -> (StateCloud, Ways) {
  let c = StateCloud::new(Some(base_state([peer_b])))
  let kept : Json = {
    "w1": {
      "relays": [{ "url": "https://own.example" }],
      "off": Json::array(off.map(Json::string)),
      "at": 5,
      "station": me_id,
    },
  }
  (c, Ways::new(c.view(), Kept::memory(text=kept.stringify()).0, () => 10L))
}

///|
test "a peer is held to the relays its workspaces turn off, public ones too where still.fail's are off" {
  let (_, ways) = ways_with(["ours"])
  let d = peer_disabled(ways, peer_b).unwrap()
  assert_eq(d.relays, ["https://r1.still.fail", "https://r2.still.fail"])
  assert_true(d.public)
  assert_eq(
    disabled_key(Some(d)),
    "[[\"https://r1.still.fail\",\"https://r2.still.fail\"],true]",
  )
  assert_true(peer_disabled(ways, "cc".repeat(32)) is None)
  assert_eq(wanted_relays(ways), ["https://own.example"])
  assert_true(ours_off(ways))
  let addr = station_addr(ways, peer_b)
  assert_eq(addr.relays, ["https://own.example"])
  assert_true(goes_through(Some("https://r1.still.fail/"), Some(addr.disabled_relays)))
  assert_false(goes_through(Some("https://own.example"), Some(addr.disabled_relays)))
  assert_false(goes_through(None, Some(addr.disabled_relays)))
}

///|
test "PeerRelays holds a peer before it is dialed, anew as the ways change, and lets go of one gone" {
  let rt = @effect.Runtime::new()
  let (c, ways) = ways_with([])
  let told = []
  let holding = {
    disabled_relays: async fn(peer : String, relays : Array[String], public : Bool) {
      @effect.sleep(5)
      told.push("\{js_slice(peer, 2)} \{relays.join(",")} \{public}")
    },
  }
  let p = PeerRelays::new(holding, ways, rt)
  let held = rt.fork(async fn() { p.hold(peer_b) })
  rt.advance(10)
  assert_true(held.is_done())
  assert_eq(told, ["bb  false"])
  assert_eq(p.held_of(peer_b), Some("[[],false]"))
  // (the same again: the endpoint is not asked)
  ignore(rt.fork(async fn() { p.hold(peer_b) }))
  rt.advance(10)
  assert_eq(told.length(), 1)
  ignore(set_way(ways, "w1", "https://r2.still.fail", false)) catch {
    _ => ()
  }
  rt.advance(10)
  assert_eq(told[1], "bb https://r2.still.fail false")
  // (out of every roster: let go, its set emptied)
  c.update(st => st["peers"] = [])
  rt.advance(10)
  assert_eq(told[2], "bb  false")
  assert_eq(p.held_of(peer_b), None)
  p.close()
}

///|
test "an endpoint from before holds none: said once, asked no more" {
  let rt = @effect.Runtime::new()
  let (_, ways) = ways_with([])
  let asked = Ref(0)
  let holding = {
    disabled_relays: fn(_p : String, _r : Array[String], _b : Bool) raise {
      asked.val += 1
      raise NetError("disabledRelays: no operation")
    },
  }
  let p = PeerRelays::new(holding, ways, rt)
  ignore(rt.fork(async fn() { p.hold(peer_b) }))
  rt.advance(1)
  assert_false(p.supported)
  ignore(rt.fork(async fn() { p.hold(peer_b) }))
  rt.advance(1)
  assert_eq(asked.val, 1)
}

///|
test "a front started anew is given every set again before anything goes through it" {
  let rt = @effect.Runtime::new()
  let (_, ways) = ways_with(["https://r1.still.fail"])
  let told = []
  let holding = {
    disabled_relays: fn(peer : String, relays : Array[String], _b : Bool) {
      told.push("\{js_slice(peer, 2)} \{relays.length()}")
    },
  }
  let p = PeerRelays::new(holding, ways, rt)
  ignore(rt.fork(async fn() { p.hold(peer_b) }))
  rt.advance(1)
  let restored = rt.fork(async fn() { p.restore() })
  rt.advance(1)
  assert_true(restored.is_done())
  assert_eq(told, ["bb 1", "bb 1"])
}

// ── the endpoint kept on the relays ──

///|
test "keep_relays: the wanted put in, the rest taken out; public relays only while none answers" {
  let rt = @effect.Runtime::new()
  let (_, ways) = ways_with([])
  let did = []
  let up = Ref(true)
  let endpoint = {
    insert_relay: fn(u : String) { did.push("+\{u}") },
    remove_relay: fn(u : String) { did.push("-\{u}") },
    keep: (us : Array[String]) => did.push("keep \{us.length()}"),
    home: () => Some("https://r2.still.fail/"),
    public_relays: fn(on : Bool) { did.push("public \{on}") },
    relay_status: () => Json::array([]),
    probe_relay: None,
  }
  let pinged = []
  let pinger = {
    ping: fn(u : String) {
      pinged.push(u)
      up.val
    },
    pinged: None,
  }
  let fiber = rt.fork(async fn() {
    keep_relays(endpoint, ways, pinger, bound=["https://r1.still.fail", "https://gone.example"])
  })
  rt.advance(1)
  assert_eq(did, [
    "+https://r2.still.fail", "+https://own.example", "-https://gone.example", "keep 3",
    "public false",
  ])
  // (the one homed on asked first)
  assert_eq(pinged, ["https://r2.still.fail"])
  up.val = false
  did.clear()
  rt.advance(relay_check_ms)
  assert_eq(did, ["public true"])
  assert_eq(pinged.length(), 1 + 6)
  up.val = true
  did.clear()
  rt.advance(relay_check_ms)
  assert_eq(did, ["public false"])
  did.clear()
  ignore(set_way(ways, "w1", "https://own.example", false)) catch {
    _ => ()
  }
  rt.advance(1)
  assert_eq(did, ["-https://own.example", "keep 2"])
  fiber.interrupt()
  rt.advance(1)
}

// ── the endpoint's own watch (relays.ts `PROBE`) ──

///|
/// What a watched endpoint's probes find (`through`: by relay, the rest `probe`) and its relays say now, which answer
/// their ping (`answering`), and what it was told: when it was probed, through which relay, and recovered.
priv struct Watched {
  rt : @effect.Runtime
  mut probe : Json
  mut status : Json
  mut through : Map[String, Json]
  answering : Array[String]
  up : Ref[Bool]
  probes : Array[Int64]
  probed_through : Array[String]
  recovered : Array[Int64]
  fiber : @effect.Fiber[Unit]
  /// When it last took a connection through a relay (`last_relay_reach`).
  reach : Ref[Int64?]
  /// Its cooldown as kept across processes (`load_recover`, `save_recover`), and each it was given.
  kept : Ref[(Int64, Int64)?]
  saved : Array[(Int64, Int64)?]
}

///|
let lost : Json = [{ "url": "https://r2.still.fail/", "connected": false, "access": "" }]

///|
let connected : Json = [{ "url": "https://r2.still.fail/", "connected": true, "access": "" }]

///|
let failed : Json = { "ok": false, "stage": "endpoint_failed" }

///|
let offline_found : Json = { "ok": false, "stage": "probe_offline" }

///|
/// The relays the watch asks in turn: the one homed on, still.fail's other, the workspace's own.
let relay_r2 = "https://r2.still.fail"

///|
let relay_r1 = "https://r1.still.fail"

///|
let relay_own = "https://own.example"

///|
/// A watched endpoint on one relay that answers its ping (the one homed on, `relay_r2`), the others not answering.
fn watched(probe : Json, status : Json) -> Watched {
  watched_on(probe, status, [relay_r2], [relay_own])
}

///|
/// A watched endpoint homed on `relay_r2`, kept on `relay_r1` and the workspace's `owns` too, those of `answering`
/// answering their ping.
/// `rt`: one another watch ran on before (a process after it), `kept` where its cooldown is kept, `start` the time to
/// start at.
fn watched_on(
  probe : Json,
  status : Json,
  answering : Array[String],
  owns : Array[String],
  rt? : @effect.Runtime = @effect.Runtime::new(),
  kept? : Ref[(Int64, Int64)?] = Ref(None),
  start? : Int = 0,
  through? : Map[String, Json] = Map([]),
) -> Watched {
  if start > 0 {
    rt.advance(start)
  }
  let c = StateCloud::new(Some(base_state([peer_b])))
  let ways_kept : Json = {
    "w1": {
      "relays": Json::array(owns.map(u => ({ "url": Json::string(u) } : Json))),
      "off": [],
      "at": 5,
      "station": me_id,
    },
  }
  let ways = Ways::new(c.view(), Kept::memory(text=ways_kept.stringify()).0, () => 10L)
  let probes = []
  let probed_through = []
  let recovered = []
  let up = Ref(true)
  let w : Ref[Watched?] = Ref(None)
  let endpoint = {
    insert_relay: fn(_ : String) {  },
    remove_relay: fn(_ : String) {  },
    keep: _ => (),
    home: () => Some("https://r2.still.fail/"),
    public_relays: fn(_ : Bool) {  },
    relay_status: () => w.val.unwrap().status,
    probe_relay: Some(fn(url : String) -> Json raise {
      let at = strip_slashes(url)
      assert_true([relay_r1, relay_r2, ..owns].contains(at))
      probes.push(rt.now())
      probed_through.push(at)
      let now = w.val.unwrap()
      match now.through.get(at).unwrap_or(now.probe) {
        String(words) => fail(words)
        found => found
      }
    }),
  }
  let pinger = {
    ping: fn(u : String) {
      up.val && w.val.unwrap().answering.contains(strip_slashes(u))
    },
    pinged: None,
  }
  let reach : Ref[Int64?] = Ref(None)
  let saved : Array[(Int64, Int64)?] = []
  let fiber = rt.fork(async fn() {
    keep_relays(
      endpoint,
      ways,
      pinger,
      on_unhealthy=() => recovered.push(rt.now()),
      last_relay_reach=() => reach.val,
      load_recover=async fn() { kept.val },
      save_recover=async fn(state) {
        saved.push(state)
        kept.val = state
      },
    )
  })
  let made = {
    rt,
    probe,
    status,
    through,
    answering,
    up,
    probes,
    probed_through,
    recovered,
    fiber,
    reach,
    kept,
    saved,
  }
  w.val = Some(made)
  rt.advance(1)
  made
}

///|
fn Watched::ticks(self : Watched, n : Int) -> Unit {
  for _ in 0..<n {
    self.rt.advance(relay_check_ms)
  }
}

///|
let minute : Int64 = 60_000L

///|
test "watch: not recovered in its first two minutes, then after 10, 20, 40 and 60 minutes; well after its cooldown, 10 again" {
  let w = watched(failed, lost)
  w.ticks(3)
  assert_eq(w.probes, [0L, 30_000L, 60_000L, 90_000L])
  assert_eq(w.recovered, [])
  w.ticks(1)
  assert_eq(w.recovered, [2L * minute])
  w.ticks(380)
  assert_eq(w.recovered, [2L * minute, 12L * minute, 32L * minute, 72L * minute, 132L * minute, 192L * minute])
  w.probe = { "ok": true }
  w.status = connected
  w.ticks(480)
  w.probe = failed
  w.status = lost
  w.ticks(2)
  assert_eq(w.recovered.length(), 6)
  w.ticks(1)
  assert_eq(w.recovered.length(), 7)
  w.ticks(20)
  assert_eq(w.recovered.length(), 8)
  assert_eq(w.recovered[7] - w.recovered[6], 10L * minute)
  w.fiber.interrupt()
  w.rt.advance(1)
}

///|
test "watch: a probe that cannot get on the relay never recovers it" {
  let w = watched({ "ok": false, "stage": "probe_offline" }, lost)
  w.ticks(60)
  assert_eq(w.probes.length(), 61)
  assert_eq(w.recovered, [])
  w.fiber.interrupt()
  w.rt.advance(1)
}

///|
test "watch: no relay answering: not probed, its failures so far forgotten" {
  let w = watched({ "ok": true }, connected)
  w.ticks(5)
  w.probe = failed
  w.status = lost
  w.ticks(2)
  w.up.val = false
  let probed = w.probes.length()
  w.ticks(10)
  assert_eq(w.probes.length(), probed)
  w.up.val = true
  w.ticks(2)
  assert_eq(w.recovered, [])
  w.ticks(1)
  assert_eq(w.recovered.length(), 1)
  w.fiber.interrupt()
  w.rt.advance(1)
}

///|
test "watch: a front from before, with no probe, is never recovered nor probed again" {
  let w = watched(Json::string("no operation probeRelay"), lost)
  w.ticks(20)
  assert_eq(w.probes, [0L])
  assert_eq(w.recovered, [])
  w.fiber.interrupt()
  w.rt.advance(1)
}

///|
test "watch: probed every fourth check while well, every check while on no relay or held off for another of its key" {
  let w = watched({ "ok": true }, connected)
  w.ticks(8)
  assert_eq(w.probes, [90_000L, 210_000L])
  w.status = [{ "url": "https://r2.still.fail/", "connected": true, "access": "", "conflict": true }]
  w.ticks(2)
  assert_eq(w.probes[2:].to_owned(), [270_000L, 300_000L])
  w.status = lost
  w.ticks(2)
  assert_eq(w.probes[4:].to_owned(), [330_000L, 360_000L])
  assert_eq(w.recovered, [])
  w.fiber.interrupt()
  w.rt.advance(1)
}

///|
test "watch: failing through one relay but reached through another never recovers it, and clears the failures so far" {
  let w = watched_on({ "ok": true }, connected, [relay_r2, relay_r1, relay_own], [relay_own])
  w.ticks(5)
  w.status = lost
  w.probe = failed
  w.ticks(2)
  assert_eq(w.recovered, [])
  w.probe = { "ok": true }
  w.through = Map::from_array([(relay_r2, failed)])
  let from = w.probed_through.length()
  w.ticks(20)
  assert_eq(w.probed_through[from:from + 4].to_owned(), [relay_r2, relay_r1, relay_r2, relay_r1])
  assert_eq(w.recovered, [])
  w.through = Map([])
  w.probe = failed
  w.ticks(2)
  assert_eq(w.recovered, [])
  w.ticks(1)
  assert_eq(w.recovered, [w.rt.now() - 1L])
  w.fiber.interrupt()
  w.rt.advance(1)
}

///|
test "watch: the first relay letting no probe on, the next two failing: recovered as through one" {
  let w = watched_on(failed, lost, [relay_r2, relay_r1, relay_own], [relay_own], through=Map::from_array([
    (relay_r2, offline_found),
  ]))
  w.ticks(3)
  // (past the one it could not get on, to two that answer)
  assert_eq(w.probed_through[0:3].to_owned(), [relay_r2, relay_r1, relay_own])
  assert_eq(w.recovered, [])
  w.ticks(1)
  assert_eq(w.recovered, [2L * minute])
  w.fiber.interrupt()
  w.rt.advance(1)
}

///|
test "watch: the first relay letting no probe on, the next reaching the endpoint: its failures cleared" {
  let w = watched_on({ "ok": true }, connected, [relay_r2, relay_r1, relay_own], [relay_own])
  w.ticks(5)
  w.status = lost
  w.probe = failed
  w.through = Map::from_array([(relay_r2, offline_found)])
  w.ticks(2)
  assert_eq(w.recovered, [])
  w.through = Map::from_array([(relay_r2, offline_found), (relay_r1, { "ok": true })])
  w.ticks(1)
  w.through = Map::from_array([(relay_r2, offline_found)])
  w.ticks(2)
  assert_eq(w.recovered, [])
  w.ticks(1)
  assert_eq(w.recovered, [w.rt.now() - 1L])
  w.fiber.interrupt()
  w.rt.advance(1)
}

///|
test "watch: three relays failing in one check count once, on the same timeline" {
  let last = "https://d.example"
  let w = watched_on(failed, lost, [relay_r2, relay_r1, relay_own, last], [relay_own, last])
  w.ticks(3)
  assert_eq(w.probes, [0L, 0L, 0L, 30_000L, 30_000L, 30_000L, 60_000L, 60_000L, 60_000L, 90_000L, 90_000L, 90_000L])
  assert_eq(w.probed_through[0:4].to_owned(), [relay_r2, relay_r1, relay_own, last])
  assert_eq(w.recovered, [])
  w.ticks(1)
  assert_eq(w.recovered, [2L * minute])
  w.fiber.interrupt()
  w.rt.advance(1)
}

///|
test "watch: two relays staying bad while a third reaches the endpoint: asked next, failures cleared, never recovered" {
  let last = "https://d.example"
  let w = watched_on({ "ok": true }, lost, [relay_r2, relay_r1, relay_own, last], [relay_own, last])
  w.through = Map::from_array([(relay_r2, failed), (relay_r1, failed)])
  let from = w.probed_through.length()
  w.ticks(60)
  assert_eq(w.probed_through[from:from + 6].to_owned(), [relay_r2, relay_r1, relay_own, relay_r2, relay_r1, relay_own])
  assert_false(w.probed_through.contains(last))
  assert_eq(w.recovered, [])
  w.fiber.interrupt()
  w.rt.advance(1)
}

///|
test "watch: a relay the endpoint is connected to is asked before those it is not" {
  let status : Json = [
    { "url": relay_r2, "connected": false, "access": "" },
    { "url": relay_r1, "connected": false, "access": "" },
    { "url": relay_own, "connected": true, "access": "" },
  ]
  let w = watched_on({ "ok": true }, status, [relay_r2, relay_r1, relay_own], [relay_own])
  w.through = Map::from_array([(relay_r2, failed), (relay_r1, failed)])
  w.ticks(60)
  assert_true(w.probed_through.length() > 0)
  assert_true(w.probed_through.iter().all(r => r == relay_own))
  assert_eq(w.recovered, [])
  w.fiber.interrupt()
  w.rt.advance(1)
}

///|
test "watch: two relays failing across checks, the others letting no probe on: still counted and recovered" {
  let owns = ["https://c.example", "https://d.example", "https://e.example"]
  let w = watched_on(offline_found, lost, [relay_r2, relay_r1, ..owns], owns)
  w.through = Map::from_array([(relay_r2, failed), (owns[1], failed)])
  w.ticks(3)
  assert_eq(w.recovered, [])
  w.ticks(1)
  assert_eq(w.recovered, [2L * minute])
  w.fiber.interrupt()
  w.rt.advance(1)
}

///|
test "watch: one relay failing while the next three let no probe on, more left unasked: the next check asks the one left" {
  let owns = ["https://c.example", "https://d.example", "https://e.example"]
  let w = watched_on(offline_found, lost, [relay_r2, relay_r1, ..owns], owns)
  w.through = Map::from_array([(relay_r2, failed)])
  let from = w.probed_through.length()
  w.ticks(60)
  assert_eq(w.probed_through[from:from + 4].to_owned(), [relay_r2, relay_r1, owns[0], owns[1]])
  assert_eq(w.probed_through[from + 4:from + 8].to_owned(), [relay_r1, owns[0], owns[1], owns[2]])
  assert_eq(w.probes.length(), 61 * 4)
  assert_eq(w.recovered, [])
  w.fiber.interrupt()
  w.rt.advance(1)
}

///|
test "watch: one relay failing while no other answers its ping: counted, as with one relay" {
  let w = watched_on(failed, lost, [relay_r2], [relay_own])
  w.ticks(3)
  assert_eq(w.probes, [0L, 30_000L, 60_000L, 90_000L])
  assert_eq(w.recovered, [])
  w.ticks(1)
  assert_eq(w.recovered, [2L * minute])
  w.fiber.interrupt()
  w.rt.advance(1)
}

// ── notices ──

///|
test "notices gather for a second, go out at most fifty a post, a post a workspace, the others dropped" {
  let time = FakeTime::new()
  let posts = []
  let parts = {
    last_turn_ended: _ => None,
    led: _ => false,
    session_ws: s => if s.has_prefix("j") {
      Some("w2")
    } else if s.has_prefix("x") {
      Some("w9")
    } else {
      None
    },
    subscribe: _ => fn() {  },
    read: (_, _, _) => (),
    lang: () => "en",
    enrolled: () => true,
    home: () => Some("w1"),
    member_of: ws => ws == "w1" || ws == "w2",
    post: (notices : Array[Json], ws : String?, done : (Result[Unit, String]) -> Unit) => {
      let to = ws.unwrap_or("home")
      posts.push("\{time.now} \{to} \{notices.length()}")
      done(Ok(()))
    },
    timers: time.after(),
    log: _ => (),
  }
  let n = Notifier::new(parts, 0L)
  let notice = (s : String) => Json::object({ "session": Json::string(s) })
  let batch = []
  for i in 0..<60 {
    batch.push(notice(if i % 3 == 0 { "j\{i}" } else { "h\{i}" }))
  }
  batch.push(notice("x1"))
  n.queue(batch)
  time.advance(999L)
  assert_eq(posts, [])
  time.advance(1000L)
  // (a post a workspace, in the order their first notices came)
  assert_eq(posts, ["1000 w2 17", "1000 home 33"])
  time.advance(2000L)
  assert_eq(posts[2:].to_owned(), ["2000 home 7", "2000 w2 3"])
  n.close()
}

///|
test "a turn is noticed once, a led chat's none; people's words and the station's ⚠️ are" {
  let time = FakeTime::new()
  let asked = []
  let tell : Ref[(StoreChange) -> Unit] = Ref(_ => ())
  let ended : Map[String, Int64] = { "s1": 50L, "s2": 60L, "old": -5L }
  let parts = {
    last_turn_ended: k => ended.get(k),
    led: k => k == "s2",
    session_ws: _ => None,
    subscribe: f => {
      tell.val = f
      fn() {  }
    },
    read: (op, _, _) => asked.push(op),
    lang: () => "zh",
    enrolled: () => true,
    home: () => Some("w1"),
    member_of: _ => true,
    post: (_, _, _) => (),
    timers: time.after(),
    log: _ => (),
  }
  let n = Notifier::new(parts, 0L)
  (tell.val)(SessionChanged("s1"))
  (tell.val)(SessionChanged("s1"))
  (tell.val)(SessionChanged("s2"))
  (tell.val)(SessionChanged("old"))
  assert_eq(asked, ["turnNotices"])
  let entry = (author : String, text : String) => {
    n: 1L,
    kind: "message",
    author_kind: author,
    text: Some(text),
    at: 5L,
  }
  (tell.val)(ThreadSaid(1L, [entry("agent", "hi")]))
  (tell.val)(ThreadSaid(1L, [entry("station", "fine")]))
  assert_eq(asked.length(), 1)
  (tell.val)(ThreadSaid(1L, [entry("person", "hi")]))
  (tell.val)(ThreadSaid(1L, [entry("station", "⚠️ stopped")]))
  assert_eq(asked, ["turnNotices", "saidNotices", "saidNotices"])
  n.close()
}

///|
test "sha256 as Node's" {
  assert_eq(
    @hash.sha256_utf8_hex(""),
    "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
  )
  assert_eq(
    @hash.sha256_utf8_hex("abc"),
    "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
  )
  assert_eq(
    @hash.sha256_utf8_hex("é🚀".repeat(40)).length(),
    64,
  )
}

///|
/// A JSON object's fields, copied (`{}` for what is none).
fn object_copy(j : Json) -> Map[String, Json] {
  match j {
    Object(m) => m.copy()
    _ => Map([])
  }
}

///|
/// A station's state as another station's (its id).
fn with_station(state : Json, id : String) -> Json {
  let m = object_copy(state)
  m["station"] = Json::string(id)
  Json::object(m)
}

///|
test "watch: two relays failing in one check while a third reaches the endpoint: cleared in that check, never counted" {
  let w = watched_on({ "ok": true }, lost, [relay_r2, relay_r1, relay_own], [relay_own], through=Map::from_array([
    (relay_r2, failed),
    (relay_r1, failed),
  ]))
  assert_eq(w.probed_through, [relay_r2, relay_r1, relay_own])
  assert_eq(w.probes, [0L, 0L, 0L])
  w.ticks(60)
  assert_eq(w.recovered, [])
  w.fiber.interrupt()
  w.rt.advance(1)
}

///|
test "watch: only two relays, both failing: counted, as no other was left to ask" {
  let w = watched_on(failed, lost, [relay_r2, relay_r1], [])
  w.ticks(3)
  assert_eq(w.probes, [0L, 0L, 30_000L, 30_000L, 60_000L, 60_000L, 90_000L, 90_000L])
  assert_eq(w.recovered, [])
  w.ticks(1)
  assert_eq(w.recovered, [2L * minute])
  w.fiber.interrupt()
  w.rt.advance(1)
}

///|
/// The time of the check just run (`ticks` leaves the runtime 1 ms after it).
fn Watched::checked(self : Watched) -> Int64 {
  self.rt.now() - 1L
}

///|
test "watch: a connection taken through a relay lately: not probed, never recovered; a minute without one, probed and recovered again" {
  let w = watched(failed, lost)
  w.ticks(4)
  assert_eq(w.recovered, [2L * minute])
  let from = w.probes.length()
  for _ in 0..<20 {
    w.reach.val = Some(w.checked())
    w.ticks(1)
  }
  assert_eq(w.probes.length(), from)
  w.ticks(1)
  assert_eq(w.probes.length(), from + 1)
  w.ticks(20)
  assert_eq(w.recovered.length(), 2)
  w.fiber.interrupt()
  w.rt.advance(1)
}

///|
test "watch: a connection taken through a relay clears the probes' failures so far" {
  let w = watched({ "ok": true }, connected)
  w.ticks(5)
  w.probe = failed
  w.status = lost
  w.ticks(2)
  w.reach.val = Some(w.checked())
  w.ticks(1)
  let probed = w.probes.length()
  w.ticks(2)
  assert_eq(w.probes.length(), probed + 2)
  assert_eq(w.recovered, [])
  w.ticks(1)
  assert_eq(w.recovered, [w.checked()])
  w.fiber.interrupt()
  w.rt.advance(1)
}

///|
test "watch: the cooldown outlives the process: the next keeps it past its first two minutes, then doubles it; a well probe after it clears it" {
  let first = watched(failed, lost)
  first.ticks(4)
  assert_eq(first.recovered, [2L * minute])
  assert_eq(first.saved, [Some((2L * minute, 10L * minute))])
  first.fiber.interrupt()
  // The front restarted: the next process, on the same clock, failing on.
  let next = watched_on(failed, lost, [relay_r2], [relay_own], rt=first.rt, kept=first.kept)
  let began = next.checked()
  next.ticks(19)
  assert_eq(next.recovered, [], msg="within the cooldown kept from the process before")
  next.ticks(1)
  assert_eq(next.recovered, [began + 20L * 30_000L])
  assert_true(next.recovered[0] >= 12L * minute)
  assert_eq(next.kept.val, Some((next.recovered[0], 20L * minute)))
  next.probe = { "ok": true }
  next.ticks(40)
  assert_eq(next.kept.val, None)
  assert_eq(next.saved, [Some((next.recovered[0], 20L * minute)), None])
  next.fiber.interrupt()
  next.rt.advance(1)
}

///|
test "watch: a connection through a relay past the cooldown clears what is kept" {
  let kept : Ref[(Int64, Int64)?] = Ref(Some((0L, 20L * minute)))
  let w = watched_on(failed, lost, [relay_r2], [relay_own], kept~, start=5 * 60_000 - 1)
  w.reach.val = Some(w.checked())
  w.ticks(1)
  assert_eq(w.kept.val, Some((0L, 20L * minute)))
  while w.checked() < 20L * minute {
    w.reach.val = Some(w.checked())
    w.ticks(1)
  }
  assert_eq(w.kept.val, None)
  assert_eq(w.saved, [None])
  assert_eq(w.recovered, [])
  w.fiber.interrupt()
  w.rt.advance(1)
}

///|
test "watch: a kept cooldown long over, or from the future, is not kept; one out of bounds is held to them" {
  let old = watched_on(failed, lost, [relay_r2], [relay_own], kept=Ref(Some((0L, 60L * minute))), start=121 * 60_000)
  old.ticks(4)
  assert_eq(old.recovered, [121L * minute + 2L * minute])
  old.fiber.interrupt()
  old.rt.advance(1)
  let ahead = watched_on(failed, lost, [relay_r2], [relay_own], kept=Ref(Some((10L * minute, 10L * minute))))
  ahead.ticks(4)
  assert_eq(ahead.recovered, [2L * minute])
  ahead.fiber.interrupt()
  ahead.rt.advance(1)
  let long = watched_on(failed, lost, [relay_r2], [relay_own], kept=Ref(Some((0L, 24L * 60L * minute))), start=60_000)
  long.ticks(120)
  assert_eq(long.recovered, [60L * minute])
  long.fiber.interrupt()
  long.rt.advance(1)
}

// ── concurrent RTT ranking (`relay_rank_ms`) ──

///|
let slow_home : String = "https://120.24.233.158"

///|
let fast_local : String = "https://34.146.162.106"

///|
let faster_new : String = "https://34.146.162.107"

///|
fn rank_state(relays : Array[String]) -> Json {
  {
    "origin": "https://app.still.fail",
    "station": Json::string(me_id),
    "workspace": "w1",
    "workspace_name": "W1",
    "name": "here",
    "relay_url": Json::string(relays[0]),
    "relay_urls": Json::array(relays.map(Json::string)),
    "stillfail_relays": Json::array(relays.map(Json::string)),
    "grant_keys": {},
    "peers": [],
    "revocations": [],
  }
}

///|
test "keep_relays: concurrent RTT ranking picks fastest relay over slow home, reuses it on steady ticks, and probes it first" {
  let rt = @effect.Runtime::new()
  let c = StateCloud::new(Some(rank_state([slow_home, fast_local])))
  let ways = Ways::new(c.view(), Kept::memory().0, () => 10L)
  let latencies : Map[String, Int] = Map::from_array([(slow_home, 200), (fast_local, 15)])
  let pinged_urls : Array[String] = []
  let reported : Array[(String, Int64)] = []
  let probed : Array[String] = []
  let status : Json = [
    { "url": slow_home, "connected": false, "access": "" },
    { "url": fast_local, "connected": false, "access": "" },
  ]
  let endpoint = {
    insert_relay: fn(_ : String) {  },
    remove_relay: fn(_ : String) {  },
    keep: _ => (),
    home: () => Some("\{slow_home}/"),
    public_relays: fn(_ : Bool) {  },
    relay_status: () => status,
    probe_relay: Some(fn(url : String) -> Json {
      probed.push(strip_slashes(url))
      { "ok": true }
    }),
  }
  let pinger = {
    ping: async fn(u : String) -> Bool {
      pinged_urls.push(u)
      @effect.sleep(latencies.get(u).unwrap_or(10))
      true
    },
    pinged: Some((u, ms) => reported.push((u, ms))),
  }
  let fiber = rt.fork(async fn() {
    keep_relays(endpoint, ways, pinger, on_unhealthy=() => ())
  })
  // Initial check: slow takes 2*200 = 400 ms, fast takes 2*15 = 30 ms.
  rt.advance(1000)
  assert_eq(reported, [(fast_local, 15L)])
  assert_eq(probed, [fast_local])
  // Steady-state 30 s tick: only pings fast_local, never pings slow_home.
  let before = pinged_urls.length()
  rt.advance(relay_check_ms)
  let steady = pinged_urls[before:].to_owned()
  assert_true(steady.length() > 0 && steady.iter().all(u => u == fast_local))
  assert_eq(reported.last(), Some((fast_local, 15L)))
  assert_eq(probed, [fast_local, fast_local])
  fiber.interrupt()
  rt.advance(1)
}

///|
test "keep_relays: preferred failure clears preferred, recovery re-ranks after relay_rank_ms, and new relay triggers re-rank" {
  let rt = @effect.Runtime::new()
  let c = StateCloud::new(Some(rank_state([slow_home, fast_local])))
  let ways = Ways::new(c.view(), Kept::memory().0, () => 10L)
  let latencies : Map[String, Int] = Map::from_array([
    (slow_home, 200),
    (fast_local, 15),
    (faster_new, 5),
  ])
  let down : Map[String, Bool] = Map([])
  let pinged_urls : Array[String] = []
  let reported : Array[(String, Int64)] = []
  let endpoint = {
    insert_relay: fn(_ : String) {  },
    remove_relay: fn(_ : String) {  },
    keep: _ => (),
    home: () => Some("\{slow_home}/"),
    public_relays: fn(_ : Bool) {  },
    relay_status: () => Json::array([]),
    probe_relay: None,
  }
  let pinger = {
    ping: async fn(u : String) -> Bool {
      pinged_urls.push(u)
      if down.get(u).unwrap_or(false) {
        return false
      }
      @effect.sleep(latencies.get(u).unwrap_or(10))
      true
    },
    pinged: Some((u, ms) => reported.push((u, ms))),
  }
  let fiber = rt.fork(async fn() {
    keep_relays(endpoint, ways, pinger)
  })
  rt.advance(1000)
  assert_eq(reported.last(), Some((fast_local, 15L)))
  // Fast relay goes down: steady tick falls back to slow_home and clears preferred.
  down[fast_local] = true
  rt.advance(relay_check_ms + 1000)
  assert_eq(reported.last(), Some((slow_home, 200L)))
  // Next tick re-ranks while fast_local is still down -> slow_home becomes preferred.
  rt.advance(relay_check_ms + 1000)
  assert_eq(reported.last(), Some((slow_home, 200L)))
  // Fast relay recovers, but before relay_rank_ms steady tick stays on slow_home.
  down[fast_local] = false
  let before = pinged_urls.length()
  rt.advance(relay_check_ms + 1000)
  assert_true(pinged_urls[before:].iter().all(u => u == slow_home))
  assert_eq(reported.last(), Some((slow_home, 200L)))
  // Advance past relay_rank_ms (20 ticks): re-ranks and switches back to fast_local.
  for _ in 0..<20 {
    rt.advance(relay_check_ms + 500)
  }
  assert_eq(reported.last(), Some((fast_local, 15L)))
  // Adding a new faster relay triggers re-rank on the next tick.
  ignore(add_relay(ways, "w1", faster_new, None)) catch {
    _ => ()
  }
  rt.advance(10)
  rt.advance(relay_check_ms + 1000)
  assert_eq(reported.last(), Some((faster_new, 5L)))
  fiber.interrupt()
  rt.advance(1)
}

///|
test "keep_relays: concurrent 5s rank timeout falls back to sequential check and preserves public relay semantics" {
  let rt = @effect.Runtime::new()
  let c = StateCloud::new(Some(rank_state([slow_home, fast_local])))
  let ways = Ways::new(c.view(), Kept::memory().0, () => 10L)
  let public_calls : Array[Bool] = []
  let reported : Array[(String, Int64)] = []
  let all_down = Ref(false)
  let slow_mode = Ref(true)
  let endpoint = {
    insert_relay: fn(_ : String) {  },
    remove_relay: fn(_ : String) {  },
    keep: _ => (),
    home: () => Some("\{slow_home}/"),
    public_relays: fn(on : Bool) { public_calls.push(on) },
    relay_status: () => Json::array([]),
    probe_relay: None,
  }
  let pinger = {
    ping: async fn(u : String) -> Bool {
      if all_down.val {
        return false
      }
      if slow_mode.val {
        // Slower than 5 s rank timeout, but succeeds in fallback sequential check.
        @effect.sleep(6_000)
        true
      } else {
        @effect.sleep(if u == fast_local { 15 } else { 200 })
        true
      }
    },
    pinged: Some((u, ms) => reported.push((u, ms))),
  }
  let fiber = rt.fork(async fn() {
    keep_relays(endpoint, ways, pinger)
  })
  // 5s rank timeout + 6s sequential 1st ping + 6s sequential 2nd ping = 17s.
  rt.advance(20_000)
  assert_eq(public_calls, [false])
  assert_eq(reported.last(), Some((slow_home, 6_000L)))
  // All relays down: public relays turned on.
  all_down.val = true
  rt.advance(relay_check_ms)
  assert_eq(public_calls, [false, true])
  // Relays recover fast: concurrent rank picks fast_local and turns public relays off.
  all_down.val = false
  slow_mode.val = false
  rt.advance(relay_check_ms + 1_000)
  assert_eq(public_calls, [false, true, false])
  assert_eq(reported.last(), Some((fast_local, 15L)))
  fiber.interrupt()
  rt.advance(1)
}
