// The mesh's runtime on the test's clocks; station/test/mb-mesh-runtime.test.ts holds the same to the TypeScript.

///|
/// Runs `f` on a runtime of the test's, the clock moved on `ms` after it is set going.
fn on_clock(ms : Int, f : async (@effect.Runtime) -> Unit) -> Array[String] {
  let rt = @effect.Runtime::new()
  let errors = []
  ignore(rt.fork(() => f(rt) catch { e => errors.push(@mesh_runtime.message_of(e)) }))
  ignore(rt.run_ready())
  rt.advance(ms)
  errors
}

///|
fn o(fields : Array[(String, Json)]) -> Json {
  let m : Map[String, Json] = Map([])
  for f in fields {
    m[f.0] = f.1
  }
  Json::object(m)
}

///|
test "JavaScript's Number, String(n), trim and Math.round" {
  let n = @mesh_runtime.js_number
  assert_eq(n(""), 0.0)
  assert_eq(n("  \u{a0}\u{2028}"), 0.0)
  assert_eq(n("007"), 7.0)
  assert_eq(n("0x1F"), 31.0)
  assert_eq(n("0b101"), 5.0)
  assert_eq(n("0o17"), 15.0)
  assert_eq(n(" 1.5e3 "), 1500.0)
  assert_eq(n(".5"), 0.5)
  assert_eq(n("5."), 5.0)
  assert_eq(n("-Infinity"), @double.neg_infinity)
  assert_true(n("-0x1").is_nan())
  assert_true(n("1e").is_nan())
  assert_true(n("1_000").is_nan())
  assert_true(n(".").is_nan())
  assert_eq(@mesh_runtime.js_num(1.0e21), "1e+21")
  assert_eq(@mesh_runtime.js_num(-0.25), "-0.25")
  assert_eq(@mesh_runtime.js_round(-2.5), -2.0)
  assert_eq(@mesh_runtime.js_round(2.5), 3.0)
  assert_eq(@mesh_runtime.js_trim("\u{feff} a \u{3000}"), "a")
  assert_eq(@mesh_runtime.to_uint32(-1.0), 4294967295.0)
  assert_eq(@mesh_runtime.js_quote("a\"\u{0}"), "\"a\\\"\\u0000\"")
}

///|
test "the network's settings, and the bind's DSCP (#6871): a number passed on, anything else refused" {
  assert_eq(@mesh_runtime.congestion_of(None), "cubic")
  assert_eq(@mesh_runtime.congestion_of(Some(o([("network", o([("congestion", "bbr")]))]))), "bbr")
  assert_eq(@mesh_runtime.check_network(Some(Json::array([]))), Some("network: expected an object"))
  assert_eq(@mesh_runtime.check_network(Some(o([("congestion", Json::null())]))), Some("network.congestion: expected cubic or bbr"))
  assert_eq(@mesh_runtime.check_network(Some(Json::null())), None)
  let options = o([("alpns", Json::array(["a"])), ("bindAddr", "1.2.3.4:5")])
  let bound = @mesh_runtime.bind_station(options, None, Some("043"))
  assert_eq(bound, o([("alpns", Json::array(["a"])), ("dscp", 43.0)]))
  let bound = @mesh_runtime.bind_station(options, Some("0.0.0.0:7"), None)
  assert_eq(bound, o([("alpns", Json::array(["a"])), ("bindAddr", "0.0.0.0:7")]))
  // (what is 1 to 3 digits goes on to the bind, which takes only 1 to 63)
  assert_eq(@mesh_runtime.bind_station(options, None, Some("999")).as_object().unwrap().get("dscp"), Some(Json::number(999.0)))
  assert_false(@mesh_runtime.dscp_taken(Some(Json::number(999.0))))
  assert_false(@mesh_runtime.dscp_taken(Some(Json::number(0.0))))
  assert_true(@mesh_runtime.dscp_taken(Some(Json::number(63.0))))
  assert_true(@mesh_runtime.dscp_taken(None))
  for bad in ["", "4x", "1000", " 43", "-1", "1.5"] {
    let words = (try {
      ignore(@mesh_runtime.bind_station(options, None, Some(bad)))
      ""
    } catch {
      e => @mesh_runtime.message_of(e)
    })
    assert_eq(words, "STILLFAIL_MESH_DSCP must be a DSCP, 1 to 63, not \{@mesh_runtime.js_quote(bad)}")
  }
}

///|
test "a running endpoint follows the config's congestion controller, a refusal said and left" {
  let calls = []
  let fails = Ref(false)
  let f = @mesh_runtime.NetworkFollow::new(
    None,
    c => {
      calls.push("set \{c}")
      if fails.val {
        raise Failure("no")
      }
    },
    (level, words, _) => calls.push("\{level} \{words}"),
  )
  f.told(Some(o([("network", o([("congestion", "bbr")]))])))
  f.told(Some(o([("network", o([("congestion", "bbr")]))])))
  fails.val = true
  f.told(None)
  assert_eq(calls, [
    "set bbr", "info congestion controller for new connections", "set cubic", "warn congestion controller not changed",
    "info congestion controller for new connections",
  ])
}

///|
test "a station's LAN: its private addresses at its port, its neighbours, and whether it may reach them" {
  let ifaces = @mesh_runtime.interfaces_of_json(
    o([
      ("lo0", Json::array([o([("address", "127.0.0.1"), ("netmask", "255.0.0.0"), ("family", "IPv4"), ("internal", true)])])),
      ("en0", Json::array([o([("address", "192.168.1.23"), ("netmask", "255.255.255.0"), ("family", "IPv4"), ("internal", false)])])),
      ("bridge100", Json::array([o([("address", "192.168.64.1"), ("netmask", "255.255.255.0"), ("family", "IPv4"), ("internal", false)])])),
      ("utun4", Json::array([o([("address", "100.100.1.2"), ("netmask", "255.255.255.255"), ("family", "IPv4"), ("internal", false)])])),
      ("en1", Json::array([o([("address", "10.0.0.1"), ("netmask", "255.255.255.0"), ("family", "IPv4"), ("internal", false)])])),
    ]),
  )
  assert_eq(@mesh_runtime.lan_addrs(["[::]:7", "0.0.0.0:7777"], ifaces), ["192.168.1.23:7777", "10.0.0.1:7777"])
  assert_eq(@mesh_runtime.lan_addrs(["10.0.0.1:9"], ifaces), ["10.0.0.1:9"])
  assert_eq(@mesh_runtime.lan_addrs(["[::]:7"], ifaces), [])
  assert_eq(@mesh_runtime.tailnet_addrs(["0.0.0.0:7777"], ifaces), ["100.100.1.2:7777"])
  assert_eq(@mesh_runtime.lan_neighbours(ifaces), ["192.168.1.1", "10.0.0.2"])
  assert_true(@mesh_runtime.private_v4("172.31.0.1"))
  assert_true(@mesh_runtime.private_v4("10..0.1"))
  assert_false(@mesh_runtime.private_v4("172.32.0.1"))
  assert_true(@mesh_runtime.not_lan("ap1"))
  assert_false(@mesh_runtime.not_lan("ap"))
  let reach = []
  let errors = on_clock(0, _ => {
    reach.push(@mesh_runtime.lan_reach([], async fn(_) { None }))
    reach.push(@mesh_runtime.lan_reach(["a", "b"], async fn(ip) { if ip == "a" { Some("EHOSTUNREACH") } else { None } }))
    reach.push(@mesh_runtime.lan_reach(["a", "b"], async fn(_) { Some("EHOSTUNREACH") }))
    reach.push(@mesh_runtime.lan_reach(["a"], async fn(_) { Some("ENETDOWN") }))
  })
  assert_eq(errors, [])
  assert_eq(reach, [None, Some("granted"), Some("denied"), None])
}

///|
test "a traceparent is read as W3C says, and a route keeps no ids" {
  let t = "4bf92f3577b34da6a3ce929d0e0e4736"
  let s = "00f067aa0ba902b7"
  let p = @mesh_runtime.parse_parent(Some("00-\{t}-\{s}-01")).unwrap()
  assert_true(p.sampled)
  assert_eq(p.span, s)
  assert_false(@mesh_runtime.parse_parent(Some(" 00-\{t.to_upper()}-\{s}-0A ")).unwrap().sampled)
  assert_eq(@mesh_runtime.parse_parent(Some(" 00-\{t.to_upper()}-\{s}-0A ")).unwrap().trace, t)
  for bad in ["", "ff-\{t}-\{s}-01", "00-\{t}-\{s}-1", "00-00000000000000000000000000000000-\{s}-01", "00-\{t}-\{s}"] {
    assert_eq(@mesh_runtime.parse_parent(Some(bad)), None)
  }
  assert_eq(@mesh_runtime.route("/admin/api/threads/42/messages?limit=50"), "/admin/api/threads/:id/messages")
  assert_eq(@mesh_runtime.route("/admin/api/sessions/slack:T1:C1/files?name=a.pdf"), "/admin/api/sessions/:id/files")
  assert_eq(@mesh_runtime.route("/admin/api/workspaces/w1/members/m"), "/admin/api/workspaces/:id/members/:id")
}

///|
test "spans are batched: sent once EXPORT_MS after the first, 500 a batch, a failed one sent again at the next flush" {
  let sent = []
  let said = []
  let hr = Ref(0L)
  let rt = @effect.Runtime::new()
  let traces = @mesh_runtime.Traces::new(true, rt, () => hr.val, (level, words, _) => said.push("\{level} \{words}"))
  let failing = Ref(1)
  traces.export_to(async fn(batch) {
    if failing.val > 0 {
      failing.val -= 1
      raise Failure("down")
    }
    sent.push(batch.length())
  })
  let parent = @mesh_runtime.parse_parent(Some("00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01"))
  assert_true(traces.start(@mesh_runtime.parse_parent(Some("00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-00")), "x", 0L) is None)
  for i in 0..<1200 {
    let span = traces.start(parent, "00000000000000\{i % 10}\{i % 10}", 1000L).unwrap()
    hr.val += 5L
    traces.end(span, "GET /", [("http.response.status_code", Json::number(200.0))], false)
  }
  assert_eq(traces.spans.length(), 1200)
  rt.advance(2999)
  assert_eq(sent, [])
  rt.advance(1)
  // (the first batch failed: put back, the rest left for the next flush)
  assert_eq(sent, [])
  assert_eq(traces.spans.length(), 1200)
  rt.advance(3000)
  assert_eq(sent, [500, 500, 200])
  assert_eq(said, [])
  assert_eq(traces.spans.length(), 0)
  let span = traces.start(parent, "0000000000000001", 2L).unwrap()
  assert_eq(@mesh_runtime.traceparent(span), "00-4bf92f3577b34da6a3ce929d0e0e4736-0000000000000001-01")
  traces.end(span, "x", [], true)
  traces.close()
  rt.advance(10_000)
  assert_eq(sent, [500, 500, 200])
  inspect(
    @mesh_runtime.attribute("n", Json::number(1.0e21)).stringify(),
    content="{\"key\":\"n\",\"value\":{\"intValue\":\"1e+21\"}}",
  )
}

///|
test "internal root spans omit parentSpanId, set kind=1, respect tail_only + always_keep + slow_ms, and no-op when disabled" {
  let hr = Ref(0L)
  let rt = @effect.Runtime::new()
  let off = @mesh_runtime.Traces::new(false, rt, () => hr.val, (_, _, _) => ())
  assert_true(off.start_root("4bf92f3577b34da6a3ce929d0e0e4736", "0000000000000001", 1000L) is None)
  off.record_internal("4bf92f3577b34da6a3ce929d0e0e4736", "0000000000000001", 1000L, 2000L, "agent.open", [], false, always_keep=true)
  assert_eq(off.spans.length(), 0)
  off.close()

  let tail = @mesh_runtime.Traces::new(true, rt, () => hr.val, (_, _, _) => (), tail_only=true, slow_ms=1000)
  // 1. quick span with always_keep=true is kept, omits parentSpanId, kind=1, status=1
  let s1 = tail.start_root("4bf92f3577b34da6a3ce929d0e0e4736", "0000000000000001", 1000L).unwrap()
  hr.val += 10_000_000L // 10 ms
  tail.end_internal(s1, "agent.open", [("stillfail.runtime", Json::string("claude")), ("stillfail.take_across", Json::boolean(false))], false, always_keep=true)
  assert_eq(tail.spans.length(), 1)
  let rec1 = tail.spans[0].as_object().unwrap()
  assert_true(rec1.get("parentSpanId") is None)
  assert_eq(rec1.get("name"), Some(Json::string("agent.open")))
  assert_eq(rec1.get("kind"), Some(Json::number(1.0)))
  assert_eq(rec1.get("status"), Some(o([("code", Json::number(1.0))])))

  // 2. quick span with always_keep=false and slow_ms=500 is dropped (< 500ms)
  let s2 = tail.start_root("4bf92f3577b34da6a3ce929d0e0e4736", "0000000000000002", 2000L).unwrap()
  hr.val += 499_000_000L // 499 ms
  tail.end_internal(s2, "mcp.tool", [("stillfail.tool", Json::string("chat_post"))], false, always_keep=false, slow_ms=500)
  assert_eq(tail.spans.length(), 1)

  // 3. slow span (>= 500ms) with slow_ms=500 is kept even though default slow_ms=1000
  let s3 = tail.start_root("4bf92f3577b34da6a3ce929d0e0e4736", "0000000000000003", 3000L).unwrap()
  hr.val += 500_000_000L // 500 ms
  tail.end_internal(s3, "mcp.tool", [("stillfail.tool", Json::string("chat_post"))], false, always_keep=false, slow_ms=500)
  assert_eq(tail.spans.length(), 2)

  // 4. quick failed span with always_keep=false is kept with status.code=2
  tail.record_internal(
    "4bf92f3577b34da6a3ce929d0e0e4736",
    "0000000000000004",
    4_000_000_000L,
    4_010_000_000L,
    "replica.level",
    [("stillfail.target_kind", Json::string("s3")), ("error.type", Json::string("network"))],
    true,
    always_keep=false,
    slow_ms=500,
  )
  assert_eq(tail.spans.length(), 3)
  let rec4 = tail.spans[2].as_object().unwrap()
  assert_true(rec4.get("parentSpanId") is None)
  assert_eq(rec4.get("kind"), Some(Json::number(1.0)))
  assert_eq(rec4.get("status"), Some(o([("code", Json::number(2.0))])))
  tail.close()
}

///|
test "a pacer lets two frames go before the round trip is known, then as many as the link takes" {
  let now = Ref(0.0)
  let p = @mesh_runtime.Pacer::new(() => now.val, start=Some(1_500_000.0))
  p.set_ceiling(4_000_000.0)
  assert_true(p.may())
  p.sent(1.0, 10_000.0)
  assert_true(p.may())
  p.sent(2.0, 10_000.0)
  assert_false(p.may())
  now.val = 20.0
  p.acked(2.0)
  assert_eq(p.rtt(), Some(20.0))
  assert_eq(p.unacked(), 0)
  // never lowered yet: up by START_UP, to the ceiling at most
  assert_eq(p.asked_rate(), Some(2_250_000.0))
  // (20 kB taken in at once: over the least span, 100 ms)
  assert_eq(p.through_rate(), 1_600_000.0)
}

///|
test "a pacer's 帧率 slots its frames, a late one letting the next come sooner" {
  let now = Ref(0.0)
  let p = @mesh_runtime.Pacer::new(() => now.val, fps=Some(50.0))
  assert_eq(p.wait(), 0.0)
  p.sent(1.0, 1.0)
  assert_eq(p.wait(), 10.0)
  now.val = 9.5
  assert_eq(p.wait(), 1.0)
  now.val = 25.0
  p.sent(2.0, 1.0)
  assert_eq(p.wait(), 10.0)
}

///|
test "a pacer decouples viewer_wait_ms from network RTT, caps at 100ms, ignores invalid waits, and decays after 10s" {
  let now = Ref(0.0)
  let p = @mesh_runtime.Pacer::new(() => now.val)
  let own = @mesh_runtime.own_rate(1920.0, 1080.0)
  p.set_ceiling(own)
  p.sent(1000.0, 10_000.0)
  now.val = 70.0
  p.acked(1000.0, viewer_wait_ms=60.0)
  assert_eq(p.rtt(), Some(10.0))
  assert_eq(p.viewer_wait(), 60.0)
  assert_eq(p.asked_rate(), Some(own))
  // In-flight window credits viewer_wait (60ms) + rtt (10ms) + queue_ms(10) (30ms) = 100ms.
  p.sent(2000.0, 10_000.0)
  p.sent(3000.0, 10_000.0)
  now.val = 170.0
  assert_true(p.may())
  assert_false(p.backlogged())
  now.val = 171.0
  assert_false(p.may())
  assert_true(p.backlogged())
  // Capped at viewer_hold_limit_ms (100ms).
  p.acked(3000.0, viewer_wait_ms=100.0)
  now.val = 300.0
  p.sent(4000.0, 10_000.0)
  now.val = 460.0
  p.acked(4000.0, viewer_wait_ms=150.0)
  assert_eq(p.viewer_wait(), @mesh_runtime.viewer_hold_limit_ms)
  // Bogus wait > total_trip or NaN is treated as 0 and ages out after rtt_window_ms.
  now.val = 11_000.0
  p.sent(5000.0, 10_000.0)
  now.val = 11_020.0
  p.acked(5000.0, viewer_wait_ms=50.0)
  assert_eq(p.viewer_wait(), 0.0)
  p.sent(6000.0, 10_000.0)
  now.val = 11_040.0
  p.acked(6000.0, viewer_wait_ms=@double.not_a_number)
  assert_eq(p.viewer_wait(), 0.0)
}

///|
test "a sizer asks the smaller picture once the link carries a quarter for DOWNSIZE_MS, and back" {
  let now = Ref(0.0)
  let z = @mesh_runtime.Sizer::new(() => now.val, { max_width: 1920.0, max_height: 1080.0 })
  let own = @mesh_runtime.own_rate(1920.0, 1080.0)
  assert_eq(z.step(own * 0.2, own * 0.2, 1920.0, 1080.0), None)
  now.val = 3000.0
  assert_eq(z.step(own * 0.2, own * 0.2, 1920.0, 1080.0), Some({ max_width: 1280.0, max_height: 720.0 }))
  assert_true(z.is_low())
  let small = @mesh_runtime.own_rate(1280.0, 720.0)
  assert_eq(z.step(small, small, 1280.0, 720.0), None)
  now.val = 6000.0
  assert_eq(z.step(small, small, 1280.0, 720.0), Some({ max_width: 1920.0, max_height: 1080.0 }))
  let whole = @mesh_runtime.Sizer::new(() => now.val, { max_width: 1920.0, max_height: 1080.0 }, quality=Some("original"))
  assert_eq(whole.step(1.0, 1.0, 1920.0, 1080.0), None)
}

///|
test "a still screen's picture goes again sharper, and a view's lateness is said once a second" {
  let s = @mesh_runtime.Sharpener::new()
  s.sent(0.0, Some(1_000_000.0))
  assert_eq(s.left(100.0), 150.0)
  assert_false(s.due(500.0, Some(1_100_000.0)))
  assert_true(s.due(500.0, Some(1_100_001.0)))
  assert_false(s.due(500.0, None))
  let now = Ref(1000.0)
  let l = @mesh_runtime.FrameLatency::new(() => now.val)
  l.sent(990_000.0)
  l.sent(995_000.0)
  l.sent(-5.0)
  now.val = 1010.0
  l.acked(995_000.0, 4.0)
  assert_eq(l.take(), Some((13.0, 5.0)))
  assert_eq(l.take(), None)
  now.val = 5000.0
  assert_eq(l.take(), None)
}

///|
test "the loop's stands are counted while something uses it, its tick stopped with the last" {
  let now = Ref(0.0)
  let tick : Ref[(() -> Unit)?] = Ref(None)
  let stall = @mesh_runtime.LoopStall::new(() => now.val, (_, f) => {
    tick.val = Some(f)
    () => tick.val = None
  })
  let a = stall.use_()
  let b = stall.use_()
  now.val = 50.0
  (tick.val.unwrap())()
  assert_eq(stall.stalled(), 40.0)
  now.val = 55.0
  assert_eq(stall.stalled(), 40.0)
  a()
  a()
  assert_true(tick.val is Some(_))
  b()
  assert_true(tick.val is None)
}

///|
test "a view's frames, its clip and its look, as the wire has them" {
  assert_eq(@mesh_runtime.frame(16, b"ab"), b"\x10\x00\x00\x00\x02ab")
  assert_eq(@mesh_runtime.video_payload(true, 258.9, b"z"), b"\x01\x00\x00\x00\x00\x00\x00\x01\x02z")
  assert_eq(@mesh_runtime.clip_payload(Text("é"), flags=Some(1)), b"\x01\x01\xc3\xa9")
  assert_eq(@mesh_runtime.parse_clip(b"\x01\x01\xc3\xa9"), Some((Text("é"), true)))
  assert_eq(@mesh_runtime.parse_clip(b"\x00\x02"), None)
  assert_eq(@mesh_runtime.parse_clip(b"\x00\x09\x00"), None)
  let look = @mesh_runtime.parse_look(
    @utf8.encode("{\"region\":{\"x\":0.9,\"y\":-1,\"w\":0.001,\"h\":0.5},\"maxWidth\":99999}"),
    { max_width: 1920.0, max_height: 1080.0 },
  )
  assert_eq(look, Some((Some({ x: 0.9, y: 0.0, w: 0.02, h: 0.5 }), { max_width: 8192.0, max_height: 1080.0 })))
  assert_eq(@mesh_runtime.parse_look(b"[]", { max_width: 1.0, max_height: 2.0 }), Some((None, { max_width: 1.0, max_height: 2.0 })))
  assert_eq(@mesh_runtime.parse_look(b"3", { max_width: 1.0, max_height: 2.0 }), None)
  assert_eq(@mesh_runtime.parse_window_pick(o([("t", "window")])), Whole)
  assert_eq(@mesh_runtime.parse_window_pick(o([("t", "window"), ("id", 0.0)])), NotOne)
  assert_eq(
    @mesh_runtime.parse_input(o([("t", "pointer"), ("kind", "down"), ("x", 2.0), ("y", 0.5), ("buttons", -1.0)])),
    Some(o([("t", "pointer"), ("kind", "down"), ("x", 1.0), ("y", 0.5), ("buttons", 7.0)])),
  )
  assert_eq(@mesh_runtime.said_word(Some(Json::string("  i\u{0}Phone\u{200b} ")), 80), Some("iPhone"))
  assert_eq(@mesh_runtime.said_word(Some(Json::string("\u{e0001}")), 80), None)
  let a = @mesh_runtime.asked(o([("codecs", Json::array(["vp9", "jpeg", "h265"])), ("peek", true), ("control", true), ("fps", 60.0)]))
  assert_eq(a.as_object().unwrap().get("codecs"), Some(Json::array(["h265", "jpeg"])))
  assert_eq(a.as_object().unwrap().get("control"), Some(Json::boolean(false)))
  assert_eq(a.as_object().unwrap().get("fps"), None)
}

///|
test "frames come whole across a stream's pieces; one too large, or cut, fails" {
  let said = []
  let errors = on_clock(0, _ => {
    let chunks = [b"\x10\x00", b"\x00\x00\x01a\x11", b"\x00\x00\x00\x00"]
    let at = Ref(0)
    let read = async fn() -> Bytes? {
      if at.val < chunks.length() {
        at.val += 1
        Some(chunks[at.val - 1])
      } else {
        None
      }
    }
    let f = @mesh_runtime.FrameIn::new(read)
    while f.next() is Some((kind, payload)) {
      said.push("\{kind}:\{payload.length()}")
    }
    let g = @mesh_runtime.FrameIn::new(async fn() { None }, carry=b"\x10\xff\xff\xff\xff")
    ignore(g.next())
  })
  assert_eq(said, ["16:1", "17:0"])
  assert_eq(errors, ["screen frame too large"])
}

///|
test "the locks' tells: a head moved told its workspace's members, a person's log its person" {
  let heads : Map[String, Json] = Map([("", o([("seq", 1.0), ("hash", "h")]))])
  let cloud = []
  let chain = []
  let told = []
  let stop = @mesh_runtime.tell_locks(
    {
      memberships: () => [("home", true), ("w", false)],
      head: ws => heads.get(ws.unwrap_or("")),
      force_word: _ => "",
      listen_cloud: f => {
        cloud.push(f)
        () => cloud.clear()
      },
      listen_chains: f => {
        chain.push(f)
        () => chain.clear()
      },
      kept: g => if g == "p" { Some([o([("ws", "person:ada")])]) } else { None },
    },
    (event, data, of, to) => told.push("\{event} \{data.stringify()} \{of.replace_all(old="\u{0}", new="|")} \{to.stringify()}"),
  )
  cloud[0]()
  heads["w"] = o([("seq", 2.0), ("hash", "x")])
  heads[""] = o([("seq", 2.0), ("hash", "i")])
  cloud[0]()
  chain[0]("p")
  chain[0]("q")
  stop()
  assert_eq(cloud.length(), 0)
  assert_eq(told, [
    "lock {\"workspace\":\"home\",\"head\":{\"seq\":2,\"hash\":\"i\"}} lock|home {\"workspace\":\"home\"}",
    "lock {\"workspace\":\"w\",\"head\":{\"seq\":2,\"hash\":\"x\"}} lock|w {\"workspace\":\"w\"}",
    "person {\"genesis\":\"p\",\"length\":1} person|p {\"subs\":[\"ada\"]}",
  ])
}

///|
test "the device tools: only a gateway's, of this station's workspace, each op answered once" {
  let said = []
  let d : @mesh_runtime.ToolsDeps = {
    enabled: () => true,
    workspace: () => Some("w"),
    removed: () => false,
    gateway_keys: () => ["g"],
    run: async fn(op, _, _) { if op == "bad" { Err(("not_found", "no")) } else { Ok(Json::string(op)) } },
    said: (_, words, _) => said.push(words),
  }
  assert_eq(@mesh_runtime.tools_refusal(d, "x"), Some("not a gateway of this station's control plane"))
  let replies = []
  let errors = on_clock(0, _ => {
    let w = o([("workspace", "w")])
    replies.push(@mesh_runtime.tools_answer(d, Some(o([("op", "a"), ("context", w)])), () => None).stringify())
    replies.push(@mesh_runtime.tools_answer(d, Some(o([("op", "bad"), ("context", w)])), () => None).stringify())
    replies.push(@mesh_runtime.tools_answer(d, Some(o([("op", "a")])), () => None).stringify())
    replies.push(@mesh_runtime.tools_answer(d, None, () => None).stringify())
    replies.push(@mesh_runtime.tools_answer(d, Some(o([("op", "a"), ("context", w)])), () => Some("station removed")).stringify())
  })
  assert_eq(errors, [])
  assert_eq(replies, [
    "{\"ok\":true,\"result\":\"a\"}", "{\"ok\":false,\"error\":{\"code\":\"not_found\",\"message\":\"no\"}}",
    "{\"ok\":false,\"error\":{\"code\":\"forbidden\",\"message\":\"the request is for another workspace than this station's\"}}",
    "{\"ok\":false,\"error\":{\"code\":\"invalid_request\",\"message\":\"a request names its op\"}}",
    "{\"ok\":false,\"error\":{\"code\":\"forbidden\",\"message\":\"station removed\"}}",
  ])
  assert_eq(said, ["device tool", "device tool"])
  assert_eq(@mesh_runtime.tools_status([]), o([("state", "idle")]))
  assert_eq(
    @mesh_runtime.tools_status([o([("endedAt", 1.0), ("startedAt", 2.0), ("declared", "block"), ("need", "a key")])]),
    o([("state", "need_human"), ("summary", "a key")]),
  )
  assert_eq(@mesh_runtime.encode_uri_component("a b/é"), "a%20b%2F%C3%A9")
}

///|
test "a device's line over the mesh that never ends is answered once TOOLS_LINE_MS are up" {
  let replies = []
  let rt = @effect.Runtime::new()
  let d : @mesh_runtime.ToolsDeps = {
    enabled: () => true,
    workspace: () => Some("w"),
    removed: () => false,
    gateway_keys: () => ["gateway"],
    run: async fn(_, _, _) { Ok(Json::null()) },
    said: (_, _, _) => (),
  }
  let (a, b) = @door.pair("gateway", "station", alpn=@mesh_runtime.tools_alpn)
  ignore(rt.fork(() => @mesh_runtime.serve_tools(d, b, rt) catch { _ => () }))
  ignore(rt.fork(() => {
    let s = (a.open_bi)()
    (s.write)(b"{\"op\":\"a\"")
    replies.push(@door.Reader::new(s).line().unwrap().stringify())
  } catch { _ => () }))
  ignore(rt.run_ready())
  rt.advance(@mesh_runtime.tools_line_ms - 1)
  assert_eq(replies, [])
  rt.advance(1)
  assert_eq(replies, ["{\"ok\":false,\"error\":{\"code\":\"invalid_request\",\"message\":\"tools request timed out\"}}"])
}

///|
test "a file's bytes are read as they are sent, opened at the first and closed after the last" {
  let content = b"0123456789"
  let log = []
  let errors = on_clock(0, _ => {
    let open = async fn() -> @mesh_runtime.FileReading {
      log.push("open")
      {
        read_at: async fn(at, length) {
          let from = at.to_int()
          let to = if from + length > content.length() { content.length() } else { from + length }
          log.push("read \{from} \{length}")
          @door.own(content[from:to])
        },
        close: async fn() { log.push("close") },
      }
    }
    let p = @mesh_runtime.file_bytes(open, 2L, 6L)
    while (p.next)() is Some(b) {
      log.push(@utf8.decode_lossy(b[:]))
    }
    ignore(@mesh_runtime.file_bytes(open, 3L, 3L))
    let short = @mesh_runtime.file_bytes(open, 8L, 20L)
    while (short.next)() is Some(_) {

    }
  })
  assert_eq(errors, ["the file got shorter while it was sent"])
  assert_eq(log, ["open", "read 2 4", "2345", "close", "open", "read 8 12", "read 10 10", "close"])
  let more = on_clock(0, _ => {
    ignore(@mesh_runtime.read_bytes(@mesh_runtime.one_bytes(b"abc"), 2))
  })
  assert_eq(more, ["more came than was asked for"])
}

///|
test "a screen's id as its path has it, decoded as decodeURIComponent does" {
  assert_eq(@mesh_runtime.decode_uri_component("browser%3At1"), Some("browser:t1"))
  assert_eq(@mesh_runtime.decode_uri_component("%E4%BD%A0%F0%9F%98%80"), Some("你😀"))
  assert_eq(@mesh_runtime.decode_uri_component("%E0%A4"), None)
  assert_eq(@mesh_runtime.decode_uri_component("a%2"), None)
  assert_eq(@mesh_runtime.decode_uri_component("%ED%A0%80"), None)
  assert_eq(@mesh_runtime.decode_uri_component("%C0%80"), None)
  assert_eq(@mesh_runtime.lang_of_core([("StillFail-Lang", " EN-us ")]), "en")
  assert_eq(@mesh_runtime.lang_of_core([("stillfail-lang", "")]), "zh")
  let tr = (lang : String, key : String, args : Json) => "\{lang}:\{key}:\{args.stringify()}"
  assert_eq(@mesh_runtime.access_shown(Some(o([("capture", true), ("control", true)])), "en", tr), None)
  assert_eq(
    @mesh_runtime.access_shown(Some(o([("capture", true), ("control", false), ("asking", true)])), "en", tr),
    Some(
      o([
        ("capture", true),
        ("control", false),
        (
          "message",
          "en:station.screen.controlOff:{\"app\":\"still.fail Helper\"} en:station.screen.asking:{\"app\":\"still.fail Helper\"}",
        ),
        ("asking", true),
      ]),
    ),
  )
}

///|
test "a view of a screen not there is refused, said in the asker's language" {
  let written = []
  let finished = Ref(false)
  let stream : @door.Stream = {
    read: async fn() -> Bytes? { None },
    write: async fn(b) { written.push(@utf8.decode_lossy(b[:])) },
    finish: async fn() { finished.val = true },
    stopped: async fn() -> Int? { None },
    reset: async fn(_) {  },
    media_datagrams: None,
  }
  let hub : @mesh_runtime.ScreenHubPort = {
    get: _ => None,
    drive: (_, _, _, _) => (false, []),
    join: (_, _) => () => (),
    watch: _ => () => (),
    when_stopping: _ => () => (),
  }
  let errors = on_clock(0, rt => @mesh_runtime.answer_screen(
    hub,
    stream,
    b"",
    o([("method", "post"), ("path", "/admin/api/screens/desktop/view"), ("headers", o([("stillfail-lang", "en")])), ("screen", o([]))]),
    o([("role", "member")]),
    () => true,
    rt,
    (lang, key, _) => "\{lang} \{key}",
    (_, _, _, _) => (),
  ))
  assert_eq(errors, [])
  assert_eq(written, [
    "{\"status\":404,\"headers\":{\"content-type\":\"application/json\"}}\n", "{\"error\":\"en station.screen.notFound\"}",
  ])
  assert_true(finished.val)
}

///|
test "bare strips trailing slashes" {
  assert_eq(@mesh_runtime.bare("https://r///"), "https://r")
}

///|
test "the front's streams' socket beside its own, by that path's separator: a Windows path's too" {
  assert_eq(@mesh_runtime.streams_path_of("/d/run/front.sock", 7, 1), "/d/run/mesh-7-1.sock")
  assert_eq(@mesh_runtime.streams_path_of("/front.sock", 7, 2), "/mesh-7-2.sock")
  assert_eq(@mesh_runtime.streams_path_of("front.sock", 7, 3), "./mesh-7-3.sock")
  assert_eq(
    @mesh_runtime.streams_path_of("C:\\ProgramData\\stillfail\\run\\front.sock", 7, 4),
    "C:\\ProgramData\\stillfail\\run\\mesh-7-4.sock",
  )
  assert_eq(@mesh_runtime.streams_path_of("C:\\front.sock", 7, 5), "C:\\mesh-7-5.sock")
  assert_eq(@mesh_runtime.dirname("C:\\a\\b.sock"), "C:\\a")
  assert_eq(@mesh_runtime.dirname("/a/b\\c.sock"), "/a/b")
}

///|
test "a listener's next connection taken through a try that failed while it listens, none once it is gone or closed" {
  let rt = @effect.Runtime::new()
  let tries = []
  let pauses = Ref(0)
  let got = []
  // (the machine out of descriptors for a while, then a connection: taken after a pause)
  let answers : Array[Result[Int, Error]] = [
    Err(Failure("Too many open files (os error 24)")),
    Err(Failure("Software caused connection abort (os error 53)")),
    Ok(7),
    Err(Failure("no handle 12")),
  ]
  let accept = async fn() -> Int {
    tries.push(tries.length())
    match answers.remove(0) {
      Ok(n) => n
      Err(e) => raise e
    }
  }
  let pause = async fn() { pauses.val += 1 }
  ignore(rt.fork(() => {
    got.push(@mesh_runtime.accept_through(accept, pause~))
    // (closed here: `no handle`, the listener let go)
    got.push(@mesh_runtime.accept_through(accept, pause~))
  }))
  ignore(rt.run_ready())
  assert_eq(got, [Some(7), None])
  assert_eq(pauses.val, 2)
  assert_eq(tries.length(), 4)
  // closed meanwhile: no try after its pause
  let closed = Ref(false)
  let later = []
  ignore(rt.fork(() => later.push(
    @mesh_runtime.accept_through(
      async fn() -> Int { raise Failure("Too many open files (os error 24)") },
      closed=() => closed.val,
      pause=async fn() { closed.val = true },
    ),
  )))
  ignore(rt.run_ready())
  assert_eq(later, [None])
  // the default pause: accept_again_ms on the runtime's clock
  let waited = []
  let failed = Ref(false)
  ignore(rt.fork(() => waited.push(
    @mesh_runtime.accept_through(async fn() -> Int {
      if failed.val {
        return 3
      }
      failed.val = true
      raise Failure("Too many open files (os error 24)")
    }),
  )))
  ignore(rt.run_ready())
  rt.advance(@mesh_runtime.accept_again_ms - 1)
  assert_eq(waited, [])
  rt.advance(1)
  assert_eq(waited, [Some(3)])
  assert_true(@mesh_runtime.listener_gone(Failure("not a listening socket")))
  assert_false(@mesh_runtime.listener_gone(Failure("Too many open files (os error 24)")))
}

///|
test "where only the tail is kept: a failed or slow span, never a quick one that did not fail" {
  let hr = Ref(0L)
  let rt = @effect.Runtime::new()
  let parent = @mesh_runtime.parse_parent(Some("00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01"))
  let ended = (traces : @mesh_runtime.Traces, name : String, ms : Int64, failed : Bool) => {
    let span = traces.start(parent, "0000000000000001", 1000L).unwrap()
    hr.val += ms * 1_000_000L
    traces.end(span, name, [], failed)
  }
  let names = (traces : @mesh_runtime.Traces) => traces.spans.map(s => match s {
    { "name": String(n), .. } => n
    _ => ""
  })
  let tail = @mesh_runtime.Traces::new(true, rt, () => hr.val, (_, _, _) => (), tail_only=true)
  ended(tail, "quick", 20L, false)
  ended(tail, "failed", 20L, true)
  ended(tail, "almost", 999L, false)
  ended(tail, "slow", 1000L, false)
  assert_eq(names(tail), ["failed", "slow"])
  tail.close()
  let all = @mesh_runtime.Traces::new(true, rt, () => hr.val, (_, _, _) => ())
  ended(all, "quick", 20L, false)
  ended(all, "failed", 20L, true)
  assert_eq(names(all), ["quick", "failed"])
  all.close()
  let slower = @mesh_runtime.Traces::new(true, rt, () => hr.val, (_, _, _) => (), tail_only=true, slow_ms=5_000)
  ended(slower, "slow", 1000L, false)
  assert_eq(slower.spans.length(), 0)
  slower.close()
  let off = @mesh_runtime.Traces::new(false, rt, () => hr.val, (_, _, _) => ())
  assert_true(off.start(parent, "0000000000000001", 0L) is None)
}

///|
test "a batch that fails again is dropped, said once in 10 min; a 4xx is not sent again" {
  let said = []
  let hr = Ref(0L)
  let rt = @effect.Runtime::new()
  let traces = @mesh_runtime.Traces::new(true, rt, () => hr.val, (level, words, with_) => said.push("\{level} \{words} \{with_.stringify()}"))
  let calls = Ref(0)
  let error = Ref("still.fail cloud answered 503")
  traces.export_to(async fn(_) {
    calls.val += 1
    raise Failure(error.val)
  })
  let parent = @mesh_runtime.parse_parent(Some("00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01"))
  let one = () => {
    let span = traces.start(parent, "0000000000000001", 1000L).unwrap()
    hr.val += 5_000_000L
    traces.end(span, "GET /", [], false)
  }
  one()
  rt.advance(3000)
  rt.advance(3000)
  assert_eq(calls.val, 2)
  assert_eq(traces.spans.length(), 0)
  assert_eq(said, ["warn traces dropped {\"error\":\"still.fail cloud answered 503\",\"count\":1}"])
  said.clear()
  one()
  rt.advance(3000)
  rt.advance(3000)
  assert_eq(calls.val, 4)
  assert_eq(said, [])
  error.val = "still.fail cloud answered 413"
  one()
  one()
  rt.advance(3000)
  assert_eq(calls.val, 5)
  assert_eq(traces.spans.length(), 0)
  assert_eq(said, [])
  hr.val += 600_000_000_000L
  one()
  rt.advance(3000)
  assert_eq(calls.val, 6)
  assert_eq(said, ["warn traces dropped {\"error\":\"still.fail cloud answered 413\",\"count\":1}"])
  traces.close()
}

///|
test "an OTLP batch says what describes the station, an empty one left out" {
  assert_eq(@mesh_runtime.otlp_body("s1", []), @mesh_runtime.otlp_body("s1", [], resource=[]))
  let body = @json.parse(
    @mesh_runtime.otlp_body("s1", [], resource=[("service.version", "0.1.1"), ("host.arch", ""), ("", "x")]),
  )
  guard body is { "resourceSpans": [{ "resource": { "attributes": attributes, .. }, .. }], .. } else { fail("no resource") }
  inspect(
    attributes.stringify(),
    content="[{\"key\":\"service.name\",\"value\":{\"stringValue\":\"stillfail-mesh\"}},{\"key\":\"stillfail.station\",\"value\":{\"stringValue\":\"s1\"}},{\"key\":\"service.version\",\"value\":{\"stringValue\":\"0.1.1\"}}]",
  )
}

///|
test "2K (qhd): the most a view is asked at, more over 60 frames a second, at most max_rate" {
  assert_eq(@mesh_runtime.max_rate, 100_000_000.0)
  assert_eq(@mesh_runtime.rate_ceiling(1920.0, 1080.0, Some("original")), 1920.0 * 1080.0 * 20.0)
  assert_eq(@mesh_runtime.rate_ceiling(2560.0, 1440.0, Some("qhd")), 73_728_000.0)
  assert_eq(@mesh_runtime.rate_ceiling(2560.0, 1440.0, Some("qhd"), fps=Some(60.0)), 73_728_000.0)
  assert_eq(@mesh_runtime.rate_ceiling(2560.0, 1440.0, Some("qhd"), fps=Some(30.0)), 73_728_000.0)
  assert_eq(@mesh_runtime.rate_ceiling(1920.0, 1080.0, Some("hd"), fps=Some(90.0)), 1920.0 * 1080.0 * 16.0 * 1.25)
  assert_eq(@mesh_runtime.rate_ceiling(1920.0, 1080.0, Some("hd"), fps=Some(120.0)), 1920.0 * 1080.0 * 16.0 * 1.5)
  assert_eq(@mesh_runtime.rate_ceiling(2560.0, 1440.0, Some("qhd"), fps=Some(90.0)), 92_160_000.0)
  assert_eq(@mesh_runtime.rate_ceiling(2560.0, 1440.0, Some("qhd"), fps=Some(120.0)), @mesh_runtime.max_rate)
  assert_eq(@mesh_runtime.rate_ceiling(200.0, 100.0, Some("original"), fps=Some(120.0)), 1_000_000.0)
  assert_eq(@mesh_runtime.lan_rate, 25_000_000.0)
}

///|
test "2K (qhd) and 原画 are never made smaller; 高清 is" {
  let now = Ref(0.0)
  let asked : @mesh_runtime.Bounds = { max_width: 7680.0, max_height: 4320.0 }
  for quality in ["original", "qhd"] {
    let whole = @mesh_runtime.Sizer::new(() => now.val, asked, quality=Some(quality))
    for _ in 0..<100 {
      assert_eq(whole.step(1_000_000.0, 1_000_000.0, 3840.0, 2160.0), None)
      now.val += 100.0
    }
  }
  let hd = @mesh_runtime.Sizer::new(() => now.val, asked, quality=Some("hd"))
  let mut made : @mesh_runtime.Bounds? = None
  for _ in 0..<100 {
    if made is None {
      made = hd.step(1_000_000.0, 1_000_000.0, 3840.0, 2160.0)
    }
    now.val += 100.0
  }
  assert_eq(made, Some({ max_width: 1280.0, max_height: 720.0 }))
}

///|
/// A pacer whose round trip is 10 ms, its rate at `rate` and no higher, frames of `bytes` each 16 ms acknowledged 10 ms
/// on for 1.5 s, then one of `key` bytes as a key frame, never acknowledged: its rate each ms after that.
fn burst(rate : Double, bytes : Double, key : Double) -> (Array[Double], @mesh_runtime.Pacer, Ref[Double]) {
  let now = Ref(0.0)
  let pacer = @mesh_runtime.Pacer::new(() => now.val, start=Some(rate))
  pacer.set_ceiling(rate)
  let mut ts = 0.0
  let due : Array[(Double, Double)] = []
  while now.val < 1500.0 {
    while due.length() > 0 && due[0].0 <= now.val {
      pacer.acked(due.remove(0).1)
    }
    if now.val.to_int() % 16 == 0 && pacer.may() {
      ts += 1000.0
      pacer.sent(ts, bytes)
      due.push((now.val + 10.0, ts))
    }
    now.val += 1.0
  }
  while due.length() > 0 {
    pacer.acked(due.remove(0).1)
    now.val += 1.0
  }
  pacer.sent(ts + 1000.0, key, key=true)
  let rates = []
  let start = now.val
  while now.val < start + 1000.0 {
    pacer.may() |> ignore
    rates.push(pacer.asked_rate().unwrap())
    now.val += 1.0
  }
  (rates, pacer, now)
}

///|
test "a large picture after a dark scene lowers the rate by light_cut first; a key frame may wait key_queue_ms more" {
  assert_eq(@mesh_runtime.cut, 0.65)
  assert_eq(@mesh_runtime.light_cut, 0.8)
  assert_eq(@mesh_runtime.key_queue_ms, 25.0)
  let (rates, _, _) = burst(20_000_000.0, 3_000.0, 1_000_000.0)
  let steps : Array[Double] = []
  for r in rates {
    if !steps.contains(r) {
      steps.push(r)
    }
  }
  assert_eq(steps[0], 20_000_000.0)
  assert_eq(steps[1], 20_000_000.0 * @mesh_runtime.light_cut)
  let first = rates.search(steps[1]).unwrap()
  assert_eq(first.to_double(), 10.0 + 30.0 + @mesh_runtime.key_queue_ms + 1.0 + @mesh_runtime.hold_ms)
  assert_eq(steps[2], 20_000_000.0 * @mesh_runtime.light_cut * @mesh_runtime.cut)
}

///|
test "a key frame on the way may wait key_queue_ms more before a queue is taken to build; free asks nothing of the pace" {
  let now = Ref(0.0)
  let p = @mesh_runtime.Pacer::new(() => now.val, start=Some(10_000_000.0))
  p.sent(1000.0, 10_000.0)
  now.val = 20.0
  p.acked(1000.0)
  assert_eq(p.rtt(), Some(20.0))
  p.sent(2000.0, 500_000.0, key=true)
  p.sent(3000.0, 10_000.0)
  let edge = 20.0 + 20.0 + @mesh_runtime.queue_ms(20.0) + @mesh_runtime.key_queue_ms
  now.val = edge
  assert_false(p.backlogged())
  assert_true(p.free())
  assert_true(p.may())
  now.val = edge + 1.0
  assert_true(p.backlogged())
  assert_false(p.free())
  // (free asked again and again: the rate as it was)
  let (_, b, at) = burst(20_000_000.0, 3_000.0, 1_000_000.0)
  let rate = b.asked_rate()
  at.val += 5_000.0
  for _ in 0..<50 {
    assert_false(b.free())
  }
  assert_eq(b.asked_rate(), rate)
}

///|
test "a viewer's volume: read again, or set to a level; nothing else" {
  assert_eq(@mesh_runtime.parse_volume(o([("t", Json::string("volume"))])), Some(None))
  assert_eq(@mesh_runtime.parse_volume(o([("t", Json::string("volume")), ("level", Json::number(4.0))])), Some(Some(4.0)))
  for bad in [
    o([("t", Json::string("volume")), ("level", Json::number(-1.0))]),
    o([("t", Json::string("volume")), ("level", Json::number(1.5))]),
    o([("t", Json::string("volume")), ("level", Json::string("3"))]),
    o([("t", Json::string("scale")), ("percent", Json::number(100.0))]),
    Json::null(),
  ] {
    assert_eq(@mesh_runtime.parse_volume(bad), None)
  }
}

///|
test "answer_screen forwards quality and drives Pacer rate on JPEG views without triggering Sharpener keyframes" {
  let rt = @effect.Runtime::new()
  let opened_quality : Ref[String?] = Ref(None)
  let rates : Array[Double] = []
  let keyframes = Ref(0)
  let frame_seq = Ref(0)
  let closed = Ref(false)
  let frame_q : @effect.Queue[Bool] = @effect.Queue::unbounded()
  let in_q : @effect.Queue[Bytes?] = @effect.Queue::unbounded()
  let out_q : @effect.Queue[Bytes] = @effect.Queue::unbounded()
  let stop_d : @effect.Deferred[Int?] = @effect.Deferred::new()
  let stream : @door.Stream = {
    read: async fn() -> Bytes? { in_q.take() },
    write: b => ignore(out_q.try_offer(b)),
    finish: () => (),
    stopped: async fn() -> Int? { stop_d.wait() catch { _ => None } },
    reset: _ => (),
    media_datagrams: None,
  }
  let view : @mesh_runtime.ScreenViewPort = {
    next: async fn() -> @mesh_runtime.ScreenFrame? {
      if !frame_q.take() || closed.val {
        return None
      }
      frame_seq.val += 1
      let n = frame_seq.val
      let cfg : @mesh_runtime.FrameConfig? = if n == 1 {
        Some({ codec: "jpeg", width: 1280.0, height: 900.0, description: None, region: None })
      } else {
        None
      }
      Some({ config: cfg, key: true, ts: (n * 1000).to_double(), data: Bytes::make(60_000, b'\x01') })
    },
    next_audio: None,
    keyframe: () => keyframes.val += 1,
    input: async fn(_) { () },
    rate: Some(bps => rates.push(bps)),
    bounds: None,
    regions: None,
    video: None,
    why: None,
    close: () => {
      closed.val = true
      ignore(frame_q.try_offer(false))
    },
    set_clipboard: None,
    watch_clipboard: None,
    watch_cursor: None,
    cursor_image: None,
    watch_turn: None,
    watch_windows: None,
    window: None,
    reveal: None,
    watch_login: None,
    fill: None,
    watch_passkey: None,
    passkey: None,
    watch_child: None,
    set_clipboard_marked: None,
    watch_clipboard_marked: None,
    watch_pointer_lock: None,
    watch_mic: None,
    feed_mic: None,
  }
  let source : @mesh_runtime.ScreenSourcePort = {
    kind: "browser",
    title: () => "Tab",
    open: async fn(opts) {
      opened_quality.val = match opts {
        Object(m) =>
          match m.get("quality") {
            Some(String(q)) => Some(q)
            _ => None
          }
        _ => None
      }
      view
    },
    access: None,
    clipboard: None,
    reveal: false,
    peek: true,
    open_url: false,
    user_tab: false,
    sleeping: None,
    site: None,
    address: None,
    scale: None,
    set_scale: None,
    volume: None,
    set_volume: None,
    resolution: None,
    set_resolution: None,
  }
  let hub : @mesh_runtime.ScreenHubPort = {
    get: id => if id == "browser:t1" { Some(source) } else { None },
    drive: (_, _, _, _) => (true, []),
    join: (_, _) => () => (),
    watch: _ => () => (),
    when_stopping: _ => () => (),
  }
  let send_ack = (ts : Int64) => {
    let payload = @buffer.Buffer(size_hint=8)
    payload.write_uint64_be(ts.reinterpret_as_uint64())
    ignore(in_q.try_offer(Some(@mesh_runtime.frame(@mesh_runtime.kind_ack, payload.to_bytes()))))
  }
  ignore(
    rt.fork(async fn() {
      @mesh_runtime.answer_screen(
        hub,
        stream,
        b"",
        o([
          ("method", "POST"),
          ("path", "/admin/api/screens/browser%3At1/view"),
          ("headers", o([])),
          (
            "screen",
            o([
              ("maxWidth", Json::number(2560.0)),
              ("maxHeight", Json::number(1800.0)),
              ("codecs", Json::array([Json::string("jpeg")])),
              ("control", Json::boolean(true)),
              ("quality", Json::string("smooth")),
            ]),
          ),
        ]),
        o([("role", "member"), ("device", "d1"), ("name", "Alice")]),
        () => true,
        rt,
        (_, k, _) => k,
        (_, _, _, _) => (),
      )
    }),
  )
  // Frame 1: sent at t=0, acked at t=10ms (RTT=10ms).
  ignore(frame_q.try_offer(true))
  ignore(rt.run_ready())
  assert_eq(opened_quality.val, Some("smooth"))
  rt.advance(10)
  send_ack(1000L)
  ignore(rt.run_ready())
  // Congest: send frame 2 at t=10, hold 600ms, push frame 3 at t=610 to trigger pacer.may() hold, then ack f2 late at t=860.
  ignore(frame_q.try_offer(true))
  ignore(rt.run_ready())
  rt.advance(600)
  ignore(frame_q.try_offer(true))
  ignore(rt.run_ready())
  rt.advance(250)
  send_ack(2000L)
  ignore(rt.run_ready())
  rt.advance(10)
  send_ack(3000L)
  ignore(rt.run_ready())
  if !(rates.length() >= 2 && rates.last().unwrap_or(0.0) < rates[0]) {
    fail("expected congestion drop, got rates=\{rates}, frame_seq=\{frame_seq.val}")
  }
  let mut lowest = @double.infinity
  for r in rates {
    if r < lowest {
      lowest = r
    }
  }
  // Calm period > UP_AFTER_MS (1000ms) with no frames in flight, then prompt acks to climb back toward JPEG_RATE_CEILING.
  rt.advance(1_100)
  let mut next_ts = 4000L
  for _ in 0..<8 {
    ignore(frame_q.try_offer(true))
    ignore(rt.run_ready())
    rt.advance(10)
    send_ack(next_ts)
    ignore(rt.run_ready())
    next_ts += 1000L
    rt.advance(550)
  }
  assert_true(rates.last().unwrap_or(0.0) > lowest)
  for r in rates {
    assert_true(r <= 4_000_000.0)
  }
  // Still wait must not trigger Sharpener keyframe().
  rt.advance(2_000)
  assert_eq(keyframes.val, 0)
  ignore(in_q.try_offer(None))
  ignore(stop_d.succeed(None))
  rt.advance(50)
}
