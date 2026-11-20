// The cloud's dials on a clock of the test's own (FakeTime): direct TLS alone where no entry is named, the entry after
// one second, ten seconds for HTTP and twenty for a presence Upgrade shared by both, a cancel that owns only what is
// pending, a request given up that leaves its pool's dial be.

///|
priv struct Rig {
  time : FakeTime
  attempts : Array[(TlsSocket, TlsEvents)]
  destroyed : Array[Int]
  io : DialIO
}

///|
fn rig() -> Rig {
  let time = FakeTime::new()
  let attempts : Array[(TlsSocket, TlsEvents)] = []
  let destroyed = []
  let io = {
    after: time.after().after,
    tls: (host, port, _servername, events) => {
      let i = attempts.length()
      let s = { id: i, host, port, destroy: () => destroyed.push(i) }
      attempts.push((s, events))
      s
    },
  }
  { time, attempts, destroyed, io }
}

///|
let entry : CloudEntry = { origin: cloud_origin, host: "entry.test", port: 24443 }

///|
fn outcome(r : Result[TlsSocket, DialError]) -> String {
  match r {
    Ok(s) => "won \{s.id}"
    Err(e) => "\{e.message} [\{e.errors.join(", ")}]"
  }
}

///|
test "fast direct TLS keeps the canonical identity and never starts an entry" {
  let r = rig()
  let names = []
  let io = {
    after: r.io.after,
    tls: (h, p, servername, events) => {
      names.push(servername)
      (r.io.tls)(h, p, servername, events)
    },
  }
  let got = []
  ignore(dial_cloud(io, cloud_origin, Some(entry), http_budget, x => got.push(outcome(x))))
  (r.attempts[0].1.secure)()
  r.time.advance(20_000L)
  assert_eq(r.attempts.length(), 1)
  assert_eq(names, ["app.still.fail"])
  assert_eq(r.attempts[0].0.host, "app.still.fail")
  assert_eq(r.attempts[0].0.port, 443)
  assert_eq(got, ["won 0"])
  assert_eq(r.time.waits.length(), 0)
}

///|
test "the entry starts at one second, wins, and the direct one and its late success are let go" {
  let r = rig()
  let got = []
  ignore(dial_cloud(r.io, cloud_origin, Some(entry), http_budget, x => got.push(outcome(x))))
  r.time.advance(999L)
  assert_eq(r.attempts.length(), 1)
  r.time.advance(1000L)
  assert_eq(r.attempts.length(), 2)
  assert_eq((r.attempts[1].0.host, r.attempts[1].0.port), ("entry.test", 24443))
  (r.attempts[1].1.secure)()
  assert_eq(r.destroyed, [0])
  (r.attempts[0].1.secure)()
  assert_eq(got, ["won 1"])
  assert_eq(r.time.waits.length(), 0)
}

///|
test "a direct failure starts the entry at once; two that never answer share one deadline" {
  let r = rig()
  let got = []
  ignore(dial_cloud(r.io, cloud_origin, Some(entry), http_budget, x => got.push(outcome(x))))
  (r.attempts[0].1.error)("direct refused")
  assert_eq(r.attempts.length(), 2)
  r.time.advance(1000L)
  // (the hedge was called off: no third)
  assert_eq(r.attempts.length(), 2)
  r.time.advance(9_999L)
  assert_eq(got, [])
  r.time.advance(10_000L)
  assert_eq(got, [dial_timed_out + " []"])
  assert_eq(r.destroyed, [0, 1])
}

///|
test "both candidates failing say each one's words" {
  let r = rig()
  let got = []
  ignore(dial_cloud(r.io, cloud_origin, Some(entry), http_budget, x => got.push(outcome(x))))
  (r.attempts[0].1.error)("direct refused")
  (r.attempts[1].1.error)("entry reset")
  assert_eq(got, [dial_failed + " [direct refused, entry reset]"])
  assert_eq(
    failure_text({ message: dial_failed, errors: ["direct refused", "entry reset"] }),
    "direct refused; entry reset",
  )
  assert_eq(r.time.waits.length(), 0)
}

///|
test "with no entry a direct failure is the end, and a TLS that throws counts as one" {
  let r = rig()
  let got = []
  ignore(dial_cloud(r.io, cloud_origin, None, http_budget, x => got.push(outcome(x))))
  (r.attempts[0].1.error)("no route")
  assert_eq(got, [dial_failed + " [no route]"])
  let throwing = {
    after: r.io.after,
    tls: (_, _, _, _) => raise NetError("no TLS here"),
  }
  let got2 = []
  ignore(dial_cloud(throwing, cloud_origin, None, http_budget, x => got2.push(outcome(x))))
  assert_eq(got2, [dial_failed + " [no TLS here]"])
}

///|
test "a cancel destroys what is pending, once" {
  let r = rig()
  let got = []
  let cancel = dial_cloud(r.io, cloud_origin, Some(entry), upgrade_budget, x => got.push(
    outcome(x),
  ))
  r.time.advance(1500L)
  cancel()
  cancel()
  assert_eq(got, [dial_cancelled + " []"])
  assert_eq(r.destroyed, [0, 1])
  assert_eq(r.time.waits.length(), 0)
  // (a success after it is let go)
  (r.attempts[1].1.secure)()
  assert_eq(r.destroyed, [0, 1, 1])
}

///|
test "a presence Upgrade's twenty seconds: the socket is terminated and its dial cancelled" {
  let r = rig()
  let t = CloudTransport::new(() => Some(entry), r.io)
  let said = []
  let ws = {
    open: (_, _, _, _) => {
      said.push("opened")
      { send: _ => (), close: () => (), terminate: () => (), is_open: () => false }
    },
  }
  let events = {
    open: () => said.push("open"),
    message: _ => (),
    unexpected: _ => (),
    error: e => said.push("error: \{e}"),
    close: (code, _) => said.push("close \{code}"),
  }
  ignore(t.websocket("wss://app.still.fail/v1/stations/connect", Headers::new(), ws, events))
  assert_eq(t.pending_dials(), 1)
  r.time.advance(19_999L)
  assert_eq(said, [])
  r.time.advance(20_000L)
  assert_eq(t.pending_dials(), 0)
  // (the dial's own deadline, set first, is the one said: as `ws` is told the dial's error)
  assert_eq(said, ["error: " + dial_timed_out, "close 1006"])
  assert_eq(r.destroyed, [0, 1])
  assert_eq(r.time.waits.length(), 0)
}

///|
test "a presence socket had in time stops its deadline" {
  let r = rig()
  let t = CloudTransport::new(() => Some(entry), r.io)
  let said = []
  let over = []
  let ws = {
    open: (_, _, sock : TlsSocket?, ev : WsEvents) => {
      over.push(sock.map(s => s.host))
      (ev.open)()
      { send: _ => (), close: () => (), terminate: () => (), is_open: () => true }
    },
  }
  let events = {
    open: () => said.push("open"),
    message: _ => (),
    unexpected: _ => (),
    error: e => said.push("error: \{e}"),
    close: (code, _) => said.push("close \{code}"),
  }
  ignore(t.websocket("wss://app.still.fail/v1/stations/connect", Headers::new(), ws, events))
  r.time.advance(1000L)
  (r.attempts[1].1.secure)()
  assert_eq(over, [Some("entry.test")])
  assert_eq(said, ["open"])
  r.time.advance(60_000L)
  assert_eq(said, ["open"])
  assert_eq(r.time.waits.length(), 0)
}

///|
test "only still.fail's canonical origin with an entry named goes by it" {
  let r = rig()
  let named : Ref[CloudEntry?] = Ref(Some(entry))
  let t = CloudTransport::new(() => named.val, r.io)
  assert_true(t.eligible("https://app.still.fail/v1/me"))
  assert_false(t.eligible("https://app.still.fail/v1/me", provider=Comma))
  assert_false(t.eligible("https://comma.example/v1/me"))
  assert_false(t.eligible("https://app.still.fail:8443/"))
  named.val = None
  assert_false(t.eligible("https://app.still.fail/v1/me"))
  let refused = try {
    ignore(t.eligible("not a url"))
    false
  } catch {
    _ => true
  }
  assert_true(refused)
}

///|
test "config.json's cloudEntry is taken only whole and right" {
  assert_true(cloud_entry({ "x": 1 }) is None)
  let e = cloud_entry({
    "cloudEntry": { "origin": "https://app.still.fail", "host": "e.example", "port": 24443 },
  })
  assert_eq(e.map(x => (x.host, x.port)), Some(("e.example", 24443)))
  let bads : Array[Json] = [
    { "origin": "https://other.example", "host": "e", "port": 1 },
    { "origin": "https://app.still.fail", "host": "", "port": 1 },
    { "origin": "https://app.still.fail", "host": "e", "port": 0 },
    { "origin": "https://app.still.fail", "host": "e", "port": 65536 },
    { "origin": "https://app.still.fail", "host": "e", "port": 1.5 },
  ]
  for bad in bads {
    let refused = try {
      ignore(cloud_entry({ "cloudEntry": bad }))
      false
    } catch {
      _ => true
    }
    assert_true(refused)
  }
}

///|
test "closing the transport cancels its pending dials and takes no more" {
  let r = rig()
  let t = CloudTransport::new(() => Some(entry), r.io)
  let got = []
  ignore(t.dial(http_budget, x => got.push(outcome(x))))
  ignore(t.dial(http_budget, x => got.push(outcome(x))))
  t.close()
  assert_eq(got, [dial_cancelled + " []", dial_cancelled + " []"])
  ignore(t.dial(http_budget, x => got.push(outcome(x))))
  assert_eq(got.length(), 3)
  assert_eq(got[2], "cloud transport closed []")
}

///|
test "a request given up leaves its pool's dial be: the socket it makes serves the next" {
  let rt = @effect.Runtime::new()
  let r = rig()
  let timers = After::effect(rt)
  let io = { after: timers.after, tls: r.io.tls }
  let t = CloudTransport::new(() => Some(entry), io)
  let pool = Pool::new()
  let asked = []
  let http = {
    fetch: fn(req : HttpRequest) {
      asked.push("direct \{req.url}")
      { status: 200, body: "" }
    },
    over: fn(req : HttpRequest, s : TlsSocket) {
      asked.push("over \{s.id} \{req.url}")
      { status: 200, body: "ok" }
    },
  }
  let req = (url : String) => {
    url,
    http_method: "GET",
    headers: Headers::new(),
    body: None,
    timeout_ms: 30_000,
  }
  let first = rt.fork(async fn() { t.fetch(http, pool, req("https://app.still.fail/a")) })
  rt.advance(100)
  assert_eq(r.attempts.length(), 1)
  first.interrupt()
  rt.advance(100)
  // (the dial goes on: nobody's cancellation is its)
  assert_eq(t.pending_dials(), 1)
  (r.attempts[0].1.secure)()
  assert_eq(t.pending_dials(), 0)
  let second = rt.fork(async fn() { t.fetch(http, pool, req("https://app.still.fail/b")) })
  rt.advance(10)
  match second.poll() { Some(Failed(e)) => fail("failed: \{e}"); None => fail("not done"); Some(Interrupted) => fail("interrupted"); _ => () }
  assert_eq(r.attempts.length(), 1)
  let third = rt.fork(async fn() { t.fetch(http, pool, req("https://comma.example/c")) })
  rt.advance(10)
  assert_true(third.is_done())
  assert_eq(asked, ["over 0 https://app.still.fail/b", "direct https://comma.example/c"])
}

///|
test "an entry config.json names wrongly fails the dial and the request: no direct TLS in its place" {
  let r = rig()
  let t = CloudTransport::new(() => raise NetError("cloudEntry wrong"), r.io)
  let got = []
  ignore(t.dial(http_budget, x => got.push(outcome(x))))
  assert_eq(got, ["cloudEntry wrong []"])
  assert_eq(r.attempts.length(), 0)
  assert_eq(t.pending_dials(), 0)
  let said = try {
    ignore(t.eligible("https://app.still.fail/v1/x"))
    "eligible"
  } catch {
    e => error_words(e)
  }
  assert_eq(said, "cloudEntry wrong")
}
