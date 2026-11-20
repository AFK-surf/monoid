// Unit tests for pure Slack helpers: form encoding as URLSearchParams writes it, case-insensitive header lookup,
// HTTP dates as `Date.parse` takes them, event parsing, and text truncation. (Nothing here reaches the shell: a test
// of the package links no shell.)

///|
test "a form is written as URLSearchParams writes it" {
  assert_eq(
    form_encoded([("a b", "x*y~z!"), ("k", "中\n&=")]),
    "a+b=x*y%7Ez%21&k=%E4%B8%AD%0A%26%3D",
  )
  assert_eq(form_encoded([]), "")
}

///|
test "a header is read by its name in any case, several joined" {
  let h = [("Date", "one"), ("x-oauth-scopes", "a"), ("date", "two")]
  assert_eq(header(h, "DATE"), Some("one, two"))
  assert_eq(header(h, "X-OAuth-Scopes"), Some("a"))
  assert_eq(header(h, "retry-after"), None)
}

///|
test "an HTTP date is taken as Date.parse takes it" {
  assert_eq(http_date("Tue, 17 Nov 2026 04:22:23 GMT"), Some(1794889343000.0))
  assert_eq(http_date("Sun, 06 Nov 1994 08:49:37 GMT"), Some(784111777000.0))
  assert_eq(http_date("nonsense"), None)
}

///|
test "an agent session's stop is taken only with its thread and a plain time" {
  let stop = (ts : String) => to_event(
    Some(
      jo([
        ("type", js("agent_session_stopped")),
        ("channel", js("C1")),
        ("thread_ts", js("10.0")),
        ("event_ts", js(ts)),
      ]),
    ),
    "UB",
    "B1",
  )
  assert_eq(
    stop("1794889343.000100").map(stringify),
    Some(
      "{\"type\":\"stop\",\"channel\":\"C1\",\"threadTs\":\"10.0\",\"ts\":\"1794889343.000100\"}",
    ),
  )
  assert_eq(stop("soon").map(stringify), None)
  assert_eq(stop("").map(stringify), None)
}

///|
test "chat.update's text is cut to 3,500 bytes as Slack counts them at a whole character, \"…\" after it" {
  assert_eq(update_text("短"), "短")
  let fits = "长".repeat(1166) + "aa"
  assert_eq(update_text(fits), fits)
  // (the rocket's four bytes after 3,495 would cross the 3,497 kept before "…")
  let long = "长".repeat(1165) + "🚀" + "长".repeat(1267)
  assert_eq(update_text(long), "长".repeat(1165) + "…")
  assert_eq(update_text("a".repeat(3501)), "a".repeat(3497) + "…")
  assert_eq(update_text("a".repeat(3496) + "🚀" + "b"), "a".repeat(3496) + "…")
  assert_eq(update_text("a".repeat(3493) + "🚀" + "b".repeat(9)), "a".repeat(3493) + "🚀" + "…")
  // `&`, `<` and `>` counted as Slack escapes them: five bytes and four
  assert_eq(update_text("&".repeat(700)), "&".repeat(700))
  assert_eq(update_text("&".repeat(701)), "&".repeat(699) + "…")
  assert_eq(update_text("<".repeat(875)), "<".repeat(875))
  assert_eq(update_text("<".repeat(876)), "<".repeat(874) + "…")
  assert_eq(update_text(">".repeat(876)), ">".repeat(874) + "…")
  // the shorter cut of a second try
  assert_eq(update_text("a".repeat(200), max_bytes=200), "a".repeat(200))
  assert_eq(update_text("a".repeat(201), max_bytes=200), "a".repeat(197) + "…")
  assert_eq(update_text("&".repeat(41), max_bytes=200), "&".repeat(39) + "…")
}

///|
test "to_event maps user messages, edits and app_mentions while filtering own bot and deletes" {
  let msg = to_event(
    Some(
      jo([
        ("type", js("message")),
        ("channel", js("C1")),
        ("ts", js("100.1")),
        ("user", js("U1")),
        ("text", js("hello")),
      ]),
    ),
    "UBOT",
    "BBOT",
  )
  assert_eq(str_of(at(msg, "type")), Some("message"))
  let inner = at(msg, "message")
  assert_eq(str_of(at(inner, "threadTs")), Some("100.1"))
  assert_eq(str_of(at(inner, "user")), Some("U1"))
  assert_eq(str_of(at(inner, "text")), Some("hello"))
  // own messages (by user or bot_id) and deletes are dropped
  assert_true(
    to_event(
      Some(jo([("type", js("message")), ("channel", js("C1")), ("ts", js("1")), ("user", js("UBOT")), ("text", js("hi"))])),
      "UBOT",
      "BBOT",
    )
    is None,
  )
  assert_true(
    to_event(
      Some(jo([("type", js("message")), ("subtype", js("bot_message")), ("bot_id", js("BBOT")), ("ts", js("1"))])),
      "UBOT",
      "BBOT",
    )
    is None,
  )
  assert_true(
    to_event(Some(jo([("type", js("message")), ("subtype", js("message_deleted")), ("ts", js("1"))])), "UBOT", "BBOT")
    is None,
  )
  // message_changed maps to changed with threadTs fallback to ts
  let edited = to_event(
    Some(
      jo([
        ("type", js("message")),
        ("subtype", js("message_changed")),
        ("channel", js("C1")),
        ("message", jo([("ts", js("200.2")), ("user", js("U2")), ("text", js("updated"))])),
      ]),
    ),
    "UBOT",
    "BBOT",
  )
  assert_eq(str_of(at(edited, "type")), Some("changed"))
  assert_eq(str_of(at(edited, "threadTs")), Some("200.2"))
  assert_eq(str_of(at(edited, "text")), Some("updated"))
}

///|
test "slack config, masking, api_base and connect helpers handle normal and edge inputs" {
  assert_eq(api_base(None), slack_api)
  assert_eq(api_base(Some("https://example.test/api/")), "https://example.test/api/")
  assert_eq(mask_value("xoxb-1234567890-abcdef"), "xoxb-…cdef")
  assert_eq(mask_value("short"), "••••")
  assert_true(connect_blocked("app.exe"))
  assert_true(connect_blocked("build.DMG"))
  assert_true(!connect_blocked("notes.txt"))
  let connects = slack_connects(
    Some(
      jo([
        (
          "connects",
          ja([
            jo([
              ("id", js("sl-1")),
              ("kind", js("slack")),
              ("enabled", Bool(true)),
              ("slack", jo([("appToken", js("xapp-1")), ("botToken", js("xoxb-1"))])),
            ]),
            jo([("id", js("fs-1")), ("kind", js("feishu")), ("enabled", Bool(true))]),
          ]),
        ),
      ]),
    ),
  )
  assert_eq(connects.length(), 1)
  assert_eq(connects[0].id, "sl-1")
  assert_eq(slack_credentials(connects[0]), Some("xapp-1\nxoxb-1"))
}

///|
test "slack manifest helpers enable socket mode and stop event idempotently" {
  let base = slack_manifest("Stillfail Bot")
  let with_sock = with_socket_mode(Some(base), true)
  assert_eq(at(at(Some(with_sock), "settings"), "socket_mode_enabled").map(stringify), Some("true"))
  // slack_manifest already includes agent_session_stopped, so with_stop_event is a no-op
  assert_true(with_stop_event(Some(base)) is None)
  // a socket-mode manifest without agent_session_stopped gets it and agent_view added
  let bare = jo([
    (
      "settings",
      jo([
        ("socket_mode_enabled", Bool(true)),
        ("event_subscriptions", jo([("bot_events", ja([js("app_mention")]))])),
      ]),
    ),
  ])
  let patched = with_stop_event(Some(bare))
  assert_true(patched is Some(_))
  assert_true(with_stop_event(patched) is None)
}

///|
fn fake_slack_client(rt : @effect.Runtime) -> SlackClient {
  SlackClient::new(
    {
      fetch: async fn(_meth, url, _headers, _body, _timeout_ms) {
        let body = if url.has_suffix("/auth.test") {
          "{\"ok\":true,\"team\":\"T\",\"team_id\":\"T1\",\"url\":\"https://t.slack.com/\",\"user_id\":\"UB1\",\"user\":\"bot\",\"bot_id\":\"B1\"}"
        } else if url.has_suffix("/apps.connections.open") {
          "{\"ok\":true,\"url\":\"wss://fake.slack/sock\"}"
        } else {
          "{\"ok\":true}"
        }
        { status: 200, headers: [], body: @utf8.encode(body), redirected: false }
      },
      now: () => rt.now().to_double(),
      sleep: async fn(ms) { @effect.sleep(ms) },
    },
  )
}

///|
fn fake_clock(rt : @effect.Runtime) -> Clock {
  {
    now: () => rt.now().to_double(),
    sleep: async fn(ms) { @effect.sleep(ms) },
    fork: f => rt.fork(f),
  }
}

///|
test "slack socket pings every ping_ms and keeps alive on Pong and Ping frames" {
  let rt = @effect.Runtime::new()
  let queue : @effect.Queue[WsFrame?] = @effect.Queue::unbounded()
  let opens = Ref(0)
  let pings = Ref(0)
  let closes = Ref(0)
  let heard = Ref(0)
  let ws : WsIO = {
    open: async fn(_) {
      opens.val += 1
      {
        next: async fn() { queue.take() },
        send: _ => (),
        close: () => closes.val += 1,
        ping: Some(() => pings.val += 1),
      }
    },
  }
  let surface = SlackSurface::new(
    SurfaceOptions::new(
      "xapp-test",
      "xoxb-test",
      fake_slack_client(rt),
      fake_clock(rt),
      ws,
      Words::empty(),
      Ref("en"),
      (_, _, _, _) => (),
      async fn(_) { b"" },
      ping_ms=5000,
      stale_ms=20000,
      backoff_ms=1000,
      on_heard=() => heard.val += 1,
    ),
  )
  ignore(rt.fork(async fn() { surface.start(async fn(_) { () }) }))
  rt.advance(0)
  assert_eq(opens.val, 1)
  assert_eq(pings.val, 0)
  assert_eq(surface.socket(), (true, None))
  // Ping at 5s, answered by Pong -> refreshes liveness.
  rt.advance(5000)
  assert_eq(pings.val, 1)
  ignore(queue.try_offer(Some(Pong)))
  rt.advance(0)
  assert_eq(heard.val, 1)
  // Pings at 10s and 15s, answered by server Ping -> refreshes liveness.
  rt.advance(5000)
  assert_eq(pings.val, 2)
  rt.advance(5000)
  assert_eq(pings.val, 3)
  ignore(queue.try_offer(Some(Ping)))
  rt.advance(0)
  assert_eq(heard.val, 2)
  // Pings at 20s, 25s (answered by Pong), and 30s -> past stale_ms (20s) total, still healthy.
  rt.advance(5000)
  assert_eq(pings.val, 4)
  rt.advance(5000)
  assert_eq(pings.val, 5)
  ignore(queue.try_offer(Some(Pong)))
  rt.advance(0)
  assert_eq(heard.val, 3)
  rt.advance(5000)
  assert_eq(pings.val, 6)
  assert_eq(opens.val, 1)
  assert_eq(closes.val, 0)
  assert_eq(surface.socket(), (true, None))
  surface.stop()
  rt.advance(0)
}

///|
test "slack socket fails on stale silence after pings, closes, and reconnects" {
  let rt = @effect.Runtime::new()
  let opens = Ref(0)
  let pings = Ref(0)
  let closes = Ref(0)
  let queues : Array[@effect.Queue[WsFrame?]] = []
  let ws : WsIO = {
    open: async fn(_) {
      opens.val += 1
      let q : @effect.Queue[WsFrame?] = @effect.Queue::unbounded()
      queues.push(q)
      {
        next: async fn() { q.take() },
        send: _ => (),
        close: () => closes.val += 1,
        ping: Some(() => pings.val += 1),
      }
    },
  }
  let surface = SlackSurface::new(
    SurfaceOptions::new(
      "xapp-test",
      "xoxb-test",
      fake_slack_client(rt),
      fake_clock(rt),
      ws,
      Words::empty(),
      Ref("en"),
      (_, _, _, _) => (),
      async fn(_) { b"" },
      ping_ms=5000,
      stale_ms=20000,
      backoff_ms=1000,
    ),
  )
  ignore(rt.fork(async fn() { surface.start(async fn(_) { () }) }))
  rt.advance(0)
  assert_eq(opens.val, 1)
  assert_eq(surface.socket(), (true, None))
  // Pings at 5s, 10s, 15s go unanswered.
  rt.advance(5000)
  assert_eq(pings.val, 1)
  assert_eq(closes.val, 0)
  rt.advance(5000)
  assert_eq(pings.val, 2)
  assert_eq(closes.val, 0)
  rt.advance(5000)
  assert_eq(pings.val, 3)
  assert_eq(closes.val, 0)
  // At 20s (stale_ms), run_socket fails, closes the dead socket, and connect_loop backs off.
  rt.advance(5000)
  assert_eq(closes.val, 1)
  assert_eq(opens.val, 1)
  assert_eq(surface.socket(), (false, Some("slack socket said nothing for 20s")))
  // After backoff_ms (1000ms), connect_loop opens a fresh socket.
  rt.advance(1000)
  assert_eq(opens.val, 2)
  assert_eq(surface.socket(), (true, None))
  surface.stop()
  rt.advance(0)
}
