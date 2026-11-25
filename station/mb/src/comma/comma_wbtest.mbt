// Pure unit tests for station/mb/src/comma.

///|
test "day_key folds what is not of a date and pads short days" {
  assert_eq(day_key("2025-10-01"), "2025-10-01")
  assert_eq(day_key("2025-10-01T10:00"), "2025-10-01")
  assert_eq(day_key("2025"), "2025!!!!!!")
  assert_eq(day_key("ab+"), "~~+!!!!!!!")
}

///|
test "classify sorts a row's JSON by its day" {
  assert_eq(classify("{\"day\":\"2025-10-01\"}", false), (1, "2025-10-01"))
  assert_eq(classify("{\"day\":\"2025-10-01\"}", true), (4, "2025-10-01"))
  assert_eq(classify("{\"n\":1}", false), (2, ""))
  assert_eq(classify("{\"n\":1}", true), (5, ""))
  assert_eq(classify("5", false), (2, ""))
  assert_eq(classify("null", false), (3, ""))
  assert_eq(classify("{\"day\":5}", false), (3, ""))
  assert_eq(classify("{broken", false), (3, ""))
}

///|
test "iso_day says a moment's UTC day" {
  assert_eq(iso_day(0.0), "1970-01-01")
  assert_eq(iso_day(1700000000000.0), "2023-11-14")
  assert_eq(iso_day(951782400000.0), "2000-02-29")
  assert_eq(iso_day(-86400000.0), "1969-12-31")
}

///|
test "chat refs made and read" {
  assert_eq(chat_ref(12.0, None), "12")
  assert_eq(chat_ref(12.0, Some("st")), "12@st")
  assert_eq(chat_of("12@st"), Some((12.0, Some("st"))))
  assert_eq(chat_of("12"), Some((12.0, None)))
  assert_eq(chat_of("0"), None)
  assert_eq(chat_of("12@"), None)
  assert_eq(chat_of("x"), None)
  assert_eq(chat_of("5@a\nb"), None)
}

///|
test "a connect's line and its address" {
  assert_eq(comma_line("comma wss://c.example/x abcdefgh"), Some(("https://c.example", "abcdefgh")))
  assert_eq(comma_line("comma http://h:8080/ abcdefgh"), Some(("http://h:8080", "abcdefgh")))
  assert_eq(comma_line("comma https://h:443 abcdefgh"), Some(("https://h", "abcdefgh")))
  assert_eq(comma_line("comma ftp://h abcdefgh"), None)
  assert_eq(comma_line("comma https://h short"), None)
  assert_eq(
    connect_url("https://C.example//", "a b", Some("w 1"), "linux", "x64"),
    "wss://c.example/v1/connect?name=a+b&stillfail_workspace=w+1&os=linux&arch=x64",
  )
  assert_eq(connect_url("http://h:8080", "n", None, "darwin", "arm64"), "ws://h:8080/v1/connect?name=n&os=darwin&arch=arm64")
  assert_eq(connect_url("https://127.1", "n", None, "l", "x"), "wss://127.0.0.1/v1/connect?name=n&os=l&arch=x")
  assert_eq(mask_token("secret-1234"), "••••1234")
  assert_eq(mask_token("abc"), "••••")
  assert_eq(mask_token(""), "")
}

///|
test "base64 both ways, as node reads it" {
  let b = b"\x00\x01\x02hello\xff"
  assert_eq(base64(b), "AAECaGVsbG//")
  assert_eq(unbase64(base64(b)), b)
  assert_eq(unbase64("AA-_\nAA=="), b"\x00\x0f\xbf\x00")
}

///|
test "a connect's credentials, what makes its connection another" {
  let c : ScopedConnect = {
    connect: { id: "c", enabled: true, server: "https://s", token: "t", workspace: None, owner_email: None },
    scope: Some("w"),
    scope_version: 2,
  }
  assert_eq(credentials(c), Some("[\"https://s\",\"t\",null,\"w\",2,null]"))
  assert_eq(
    credentials({ ..c, connect: { ..c.connect, owner_email: Some("ada@example.test") } }),
    Some("[\"https://s\",\"t\",null,\"w\",2,\"ada@example.test\"]"),
  )
  assert_eq(credentials({ ..c, connect: { ..c.connect, token: "" } }), None)
}

///|
test "a Task's thread and a Message's ts" {
  assert_eq(thread_ts_of("task-1"), "2063246150.453823")
  assert_eq(seq_ts(12.0), "12.000000")
}

///|
test "rows as the indexes keep them" {
  let rows = stats_rows_of(
    {
      station: None,
      usage: @jsjson.parse(
        "{\"people\":{\"p\":{\"email\":\"a@x\"}},\"rows\":[{\"day\":\"2025-10-02\",\"session\":\"s\",\"person\":\"p\",\"runtime\":\"claude\",\"calls\":1},{\"day\":\"2025-09-01\",\"session\":\"old\",\"runtime\":\"x\"}]}",
      ),
      chats: [],
    },
    "2025-10-01",
  )
  assert_eq(rows.length(), 1)
  for _, row in rows {
    assert_eq(
      row.1,
      "{\"day\":\"2025-10-02\",\"session\":\"s\",\"thread\":null,\"person\":\"a@x\",\"personRef\":\"p\",\"account\":null,\"runtime\":\"claude\",\"model\":null,\"calls\":1,\"cost\":null}",
    )
  }
  let tasks = task_rows_of({
    station: Some("st"),
    usage: Null,
    chats: [
      @jsjson.parse(
        "{\"thread\":3,\"title\":\"T\",\"state\":\"need_human\",\"attention\":{\"kind\":\"need\",\"waitsFor\":[\" A@X \",\"a@x\",\"bad\"]},\"router\":true}",
      ),
    ],
  })
  assert_eq(
    tasks.get("3@st").map(r => r.1),
    Some(
      "{\"task\":\"3@st\",\"title\":\"T\",\"status\":\"needs_review\",\"surface\":\"unknown\",\"created_by\":null,\"created_at\":0,\"last_activity_at\":0,\"runtime\":null,\"model\":null,\"station\":\"st\",\"attention\":\"need\",\"waits_for\":[\"a@x\"],\"router\":true}",
    ),
  )
}

///|
test "a question card" {
  let card = @jsjson.parse("{\"type\":\"options\",\"options\":[{\"label\":\" a \"},{\"label\":\"b\",\"recommended\":true}]}")
  assert_eq(
    question_of(Some(card), "").map(stringify),
    Some(
      "{\"type\":\"question\",\"prompt\":\" a  / b\",\"choices\":[{\"id\":\"o1\",\"label\":\"a\"},{\"id\":\"o2\",\"label\":\"b\",\"recommended\":true}],\"multi_select\":false,\"allow_other\":true}",
    ),
  )
  assert_eq(question_of(Some(@jsjson.parse("{\"type\":\"text\"}")), "x") is None, true)
}

///|
test "stats_wire and task_wire format live and removed rows" {
  let removed_stats = stats_wire({
    key: "s1/2025-10-02",
    source: "stillfail",
    kind: "usage",
    rev: 7.0,
    removed: true,
    json: "",
  })
  assert_true(removed_stats is Some(_))
  assert_true(prop(removed_stats, "removed") is Some(Bool(true)))
  assert_eq(num_of(prop(removed_stats, "rev")), Some(7.0))
  assert_true(str_of(prop(removed_stats, "key")).unwrap_or("").has_prefix("sf1:"))

  let bad_stats = stats_wire({
    key: "k",
    source: "stillfail",
    kind: "usage",
    rev: 1.0,
    removed: false,
    json: "{broken",
  })
  assert_true(bad_stats is None)

  let removed_task = task_wire({
    key: "3@st",
    source: "stillfail",
    kind: "task",
    rev: 4.0,
    removed: true,
    json: "",
  })
  assert_eq(
    removed_task.map(stringify),
    Some("{\"thread\":\"3@st\",\"rev\":4,\"removed\":true}"),
  )
  let null_task = task_wire({
    key: "3@st",
    source: "stillfail",
    kind: "task",
    rev: 4.0,
    removed: false,
    json: "null",
  })
  assert_true(null_task is None)
}

///|
test "held_from parses epoch and clamps negative through" {
  assert_true(held_from(None) is None)
  assert_true(held_from(Some(jstr("bad"))) is None)
  assert_true(held_from(Some(@jsjson.parse("{\"epoch\":123}"))) is None)
  match held_from(Some(@jsjson.parse("{\"epoch\":\"ep-1\",\"through\":42}"))) {
    Some(h) => {
      assert_eq(h.epoch, Some("ep-1"))
      assert_eq(h.through, 42.0)
    }
    None => fail("expected Some(Held)")
  }
  match held_from(Some(@jsjson.parse("{\"epoch\":null,\"through\":-5}"))) {
    Some(h) => {
      assert_eq(h.epoch, None)
      assert_eq(h.through, 0.0)
    }
    None => fail("expected Some(Held)")
  }
}

///|
test "tasks Start/Task JSON roundtrip and js_order key sorting" {
  let st : Start = {
    requester: "u1",
    title: Some("Fix bug"),
    runtime: Some("claude"),
    model: None,
  }
  let rt = Start::of_j(Some(st.to_j()))
  assert_eq(rt.requester, "u1")
  assert_eq(rt.title, Some("Fix bug"))
  assert_eq(rt.runtime, Some("claude"))
  assert_eq(rt.model, None)

  let task = Task::of_j(
    @jsjson.parse(
      "{\"task\":\"t-9\",\"threadTs\":\"123.000001\",\"start\":{\"requester\":\"u2\"},\"fetched\":5,\"answered\":3,\"left\":true}",
    ),
  )
  assert_eq(task.task, "t-9")
  assert_eq(task.thread_ts, "123.000001")
  assert_eq(task.start.requester, "u2")
  assert_eq(task.fetched, 5.0)
  assert_eq(task.answered, 3.0)
  assert_true(task.left)

  // Array-index keys sorted ascending before string keys in insertion order.
  let ordered = js_order([("b", ji(1)), ("10", ji(2)), ("a", ji(3)), ("2", ji(4))])
  assert_eq(ordered.map(e => e.0), ["2", "10", "b", "a"])
}

///|
test "chats already_said_j, Attachment::of_j, comma_connects and shown" {
  let err : Error = AlreadySaid({ id: "w1", thread: 7.0, n: 2.0, pending: 1.0 })
  assert_eq(
    already_said_j(err).map(stringify),
    Some("{\"id\":\"w1\",\"thread\":7,\"n\":2,\"pending\":1}"),
  )
  assert_true(already_said_j(fail_("other")) is None)

  let att = Attachment::of_j(@jsjson.parse("{\"path\":\"/tmp/a.png\",\"name\":\"a.png\",\"size\":1024}"))
  assert_eq(att.path, "/tmp/a.png")
  assert_eq(att.name, "a.png")
  assert_eq(att.size, 1024.0)

  let connects = comma_connects(
    @jsjson.parse(
      "{\"connects\":[{\"id\":\"c1\",\"kind\":\"comma\",\"comma\":{\"server\":\"https://c.ex\",\"token\":\"tok-1234\"},\"workspace\":\"ws1\",\"createdBy\":{\"id\":\" Peng@Example.COM \"}},{\"id\":\"s1\",\"kind\":\"slack\"},{\"id\":\"c2\",\"kind\":\"comma\",\"enabled\":false,\"comma\":{\"server\":\"https://c2.ex\",\"token\":\"abcd5678\"},\"createdBy\":{\"id\":\"local\"}}]}",
    ),
  )
  assert_eq(connects.length(), 2)
  assert_eq(connects[0].id, "c1")
  assert_true(connects[0].enabled)
  assert_eq(connects[0].workspace, Some("ws1"))
  assert_eq(connects[0].owner_email, Some("peng@example.com"))
  assert_eq(connects[1].id, "c2")
  assert_false(connects[1].enabled)
  assert_eq(connects[1].owner_email, None)

  let s = shown(@jsjson.parse("{\"comma\":{\"server\":\"https://c.ex\",\"token\":\"secret-9876\"}}"))
  assert_eq(
    stringify(s),
    "{\"name\":\"Comma\",\"team\":null,\"botImage\":null,\"comma\":{\"server\":\"https://c.ex\",\"token\":\"••••9876\"}}",
  )
  assert_eq(workspace_db_name("ws-1").length(), 64)
}

///|
fn test_io() -> Io {
  let seq = Ref(0)
  {
    now: () => 0.0,
    after: (_, _) => () => (),
    sleep: async fn(_) { () },
    turn: async fn() { () },
    random_hex: _ => "00",
    uuid: () => {
      seq.val += 1
      "u-\{seq.val}"
    },
    log: (_, _, _) => (),
    read_text: _ => None,
    write_private: async fn(_, _) { () },
    mkdir: async fn(_, _) { () },
    file_part: async fn(_, _, _) { None },
    open_db: (_, _) => raise fail_("no db in test"),
    platform: "darwin",
    arch: "arm64",
    hostname: "fallback-host",
    version: "0.1.0",
    words: Words::empty(),
    lang: () => "en",
  }
}

///|
fn test_store() -> SurfaceStore {
  {
    get_session: async fn(_) { Null },
    pending_count: async fn(_) { 0.0 },
    thread_at: async fn(_, _, _) { Null },
    leave_thread: async fn(_, _) { () },
    set_thread_links: None,
    handler: async fn(_) { () },
    book_person: None,
    book_known: None,
  }
}

///|
test "workspace_meta_of includes self, deduplicates, omits empty marks, and caps at 100 stations while keeping self" {
  let peers : Array[J] = []
  for i = 0; i < 120; i = i + 1 {
    peers.push(jobj([("id", jstr("peer_\{i}")), ("name", jstr("Station \{i}"))]))
  }
  peers.push(jobj([("id", jstr("peer_0")), ("name", jstr("Duplicate"))]))
  let m = jobj([
    ("workspace", jstr("ws_1")),
    ("workspace_name", jstr("Team")),
    ("name", jstr("SelfHost")),
    ("peers", Arr(peers)),
  ])
  let meta = workspace_meta_of(m, "self_id", "fallback-host")
  assert_eq(str_of(prop(Some(meta), "id")), Some("ws_1"))
  assert_eq(str_of(prop(Some(meta), "name")), Some("Team"))
  assert_eq(str_of(prop(Some(meta), "station")), Some("SelfHost"))
  assert_true(prop(Some(meta), "emoji") is None)
  assert_true(prop(Some(meta), "icon") is None)
  let stations = arr_of(prop(Some(meta), "stations")).unwrap()
  assert_eq(stations.length(), 100)
  assert_eq(stations.filter(s => str_of(prop(Some(s), "id")) == Some("peer_0")).length(), 1)
  assert_eq(stringify(stations[99]), "{\"id\":\"self_id\",\"name\":\"SelfHost\"}")

  // Self already in peers with outdated name, empty own name -> falls back to fallback_host; empty peer name -> id.
  let with_self = workspace_meta_of(
    @jsjson.parse(
      "{\"workspace\":\"ws_2\",\"workspace_name\":\"Lab\",\"workspace_emoji\":\"🧪\",\"workspace_icon\":\"glyph:beaker\",\"name\":\"\",\"peers\":[{\"id\":\"self_id\",\"name\":\"old-name\"},{\"id\":\"other\",\"name\":\"\"}]}",
    ),
    "self_id",
    "my-mac",
  )
  assert_eq(
    stringify(with_self),
    "{\"id\":\"ws_2\",\"name\":\"Lab\",\"station\":\"my-mac\",\"emoji\":\"🧪\",\"icon\":\"glyph:beaker\",\"stations\":[{\"id\":\"self_id\",\"name\":\"my-mac\"},{\"id\":\"other\",\"name\":\"other\"}]}",
  )
}

///|
test "CommaSurface sends stillfail_workspace on connect, pushes deduped updates, omits when out of scope, and cleans up on close" {
  let rt = @effect.Runtime::new()
  let io = test_io()
  let tasks = CommaTasks::new("/tmp/comma-tasks-wbtest.json", io, rt)
  let sent : Array[J] = []
  let sock : Socket = {
    id: 1,
    send: text => sent.push(parse_json(text)),
    on_close: _ => () => (),
  }
  let current : Ref[J?] = Ref(
    Some(
      @jsjson.parse(
        "{\"id\":\"ws_1\",\"name\":\"Alpha\",\"station\":\"mac-1\",\"emoji\":\"🚀\",\"icon\":\"glyph:rocket\",\"stations\":[{\"id\":\"st_1\",\"name\":\"mac-1\"}]}",
      ),
    ),
  )
  let notify : Ref[(() -> Unit)?] = Ref(None)
  let unsubscribed = Ref(0)
  let surface = CommaSurface::new(
    {
      connect: "cm",
      server: "http://127.0.0.1",
      token: "salix_conn_test123",
      name: "Alpha · mac-1",
      workspace: Some("ws_1"),
      owner_email: None,
      tasks,
      store: test_store(),
      models: () => [],
      lang: Some("en"),
      stats: None,
      chats: None,
      previous_exited: async fn() { () },
      in_scope: () => true,
      workspace_meta: Some(() => current.val),
      on_workspace_meta_change: Some(cb => {
        notify.val = Some(cb)
        () => {
          notify.val = None
          unsubscribed.val += 1
        }
      }),
      owner_active_at: None,
      on_owner_active_change: None,
    },
    io,
    rt,
  )
  let metas = () => sent.filter(f => str_of(prop(Some(f), "type")) == Some("metadata"))
  surface.socket_ = Some(sock)
  surface.connect_metadata()
  assert_eq(metas().length(), 1)
  assert_eq(
    prop(prop(Some(metas()[0]), "capabilities"), "stillfail_workspace").map(stringify),
    current.val.map(stringify),
  )

  // Unchanged metadata pushes nothing.
  (notify.val.unwrap())()
  assert_eq(metas().length(), 1)

  // Updated metadata pushes a new metadata frame on the same socket.
  current.val = Some(
    @jsjson.parse("{\"id\":\"ws_1\",\"name\":\"Alpha Renamed\",\"station\":\"mac-1\",\"stations\":[{\"id\":\"st_1\",\"name\":\"mac-1\"}]}"),
  )
  (notify.val.unwrap())()
  assert_eq(metas().length(), 2)
  let ws_meta = prop(prop(Some(metas()[1]), "capabilities"), "stillfail_workspace")
  assert_eq(ws_meta.map(stringify), current.val.map(stringify))
  assert_true(prop(ws_meta, "emoji") is None)
  assert_true(prop(ws_meta, "icon") is None)

  // Closed unsubscribes and resets state.
  let saved_cb = notify.val.unwrap()
  surface.closed()
  assert_eq(unsubscribed.val, 1)
  assert_true(notify.val is None)
  saved_cb()
  assert_eq(metas().length(), 2)

  // Out of scope omits stillfail_workspace and ignores notifications.
  let sent2 : Array[J] = []
  let sock2 : Socket = { id: 2, send: text => sent2.push(parse_json(text)), on_close: _ => () => () }
  let cb2 : Ref[(() -> Unit)?] = Ref(None)
  let unsub2 = Ref(0)
  let surface2 = CommaSurface::new(
    {
      connect: "cm2",
      server: "http://127.0.0.1",
      token: "salix_conn_test123",
      name: "one",
      workspace: Some("ws_1"),
      owner_email: None,
      tasks,
      store: test_store(),
      models: () => [],
      lang: Some("en"),
      stats: None,
      chats: None,
      previous_exited: async fn() { () },
      in_scope: () => false,
      workspace_meta: Some(() => current.val),
      on_workspace_meta_change: Some(cb => {
        cb2.val = Some(cb)
        () => unsub2.val += 1
      }),
      owner_active_at: None,
      on_owner_active_change: None,
    },
    io,
    rt,
  )
  surface2.socket_ = Some(sock2)
  surface2.connect_metadata()
  let metas2 = () => sent2.filter(f => str_of(prop(Some(f), "type")) == Some("metadata"))
  assert_eq(metas2().length(), 1)
  assert_true(prop(prop(Some(metas2()[0]), "capabilities"), "stillfail_workspace") is None)
  (cb2.val.unwrap())()
  assert_eq(metas2().length(), 1)
  surface2.closed()
  assert_eq(unsub2.val, 1)
}

///|
test "CommaSurface quantizes stillfail_owner_active_at to 30s buckets and pushes updates only on bucket change" {
  let rt = @effect.Runtime::new()
  let io = test_io()
  let tasks = CommaTasks::new("/tmp/comma-tasks-active-wbtest.json", io, rt)
  let sent : Array[J] = []
  let sock : Socket = { id: 1, send: text => sent.push(parse_json(text)), on_close: _ => () => () }
  let active : Ref[Double?] = Ref(Some(1_795_200_012_345.0))
  let notify : Ref[(() -> Unit)?] = Ref(None)
  let unsubscribed = Ref(0)
  let surface = CommaSurface::new(
    {
      connect: "cm-active",
      server: "http://127.0.0.1",
      token: "salix_conn_test123",
      name: "Alpha · mac-1",
      workspace: Some("ws_1"),
      owner_email: Some("peng@example.com"),
      tasks,
      store: test_store(),
      models: () => [],
      lang: Some("en"),
      stats: None,
      chats: None,
      previous_exited: async fn() { () },
      in_scope: () => true,
      workspace_meta: None,
      on_workspace_meta_change: None,
      owner_active_at: Some(() => active.val),
      on_owner_active_change: Some(cb => {
        notify.val = Some(cb)
        () => {
          notify.val = None
          unsubscribed.val += 1
        }
      }),
    },
    io,
    rt,
  )
  let metas = () => sent.filter(f => str_of(prop(Some(f), "type")) == Some("metadata"))
  surface.socket_ = Some(sock)
  surface.connect_metadata()
  assert_eq(metas().length(), 1)
  assert_eq(
    prop(prop(Some(metas()[0]), "capabilities"), "stillfail_owner_active_at").map(stringify),
    Some("1795200000000"),
  )

  // Activity within the same 30s bucket sends no extra metadata frame.
  active.val = Some(1_795_200_029_999.0)
  (notify.val.unwrap())()
  assert_eq(metas().length(), 1)

  // Activity moving into the next 30s bucket pushes an updated frame.
  active.val = Some(1_795_200_035_000.0)
  (notify.val.unwrap())()
  assert_eq(metas().length(), 2)
  assert_eq(
    prop(prop(Some(metas()[1]), "capabilities"), "stillfail_owner_active_at").map(stringify),
    Some("1795200030000"),
  )

  surface.closed()
  assert_eq(unsubscribed.val, 1)
  assert_true(notify.val is None)
}

///|
test "OwnerActivity merges cross-station peer reads monotonically without re-gossiping" {
  let peer = OwnerActivity::new()
  let host = OwnerActivity::new()

  assert_true(peer.local_payload() is None)
  assert_eq(peer.record_local(Some("Peng@Example.com"), Some(1_795_200_012_345.0)), true)
  let wire = peer.local_payload()
  assert_true(wire is Some(_))

  assert_eq(host.merge_peer(wire, now=Some(1_795_200_020_000.0)), true)
  assert_eq(host.get(Some("peng@example.com")), Some(1_795_200_000_000.0))
  assert_eq(host.get(Some("other@example.com")), None)
  assert_eq(host.get(None), Some(1_795_200_000_000.0))
  assert_true(host.local_payload() is None)

  // Duplicate, older, or wildly future peer timestamps do not advance state.
  assert_eq(host.merge_peer(wire, now=Some(1_795_200_025_000.0)), false)
  assert_eq(
    host.merge_peer(
      Some(jobj([("at", Num(1_795_201_000_000.0)), ("byViewer", jobj([("peng@example.com", Num(1_795_201_000_000.0))]))])),
      now=Some(1_795_200_025_000.0),
    ),
    false,
  )
  assert_eq(host.get(Some("peng@example.com")), Some(1_795_200_000_000.0))

  // Unattributed peer activity (MoonBit station without viewer email) still advances owner lookup.
  assert_eq(
    host.merge_peer(Some(jobj([("at", Num(1_795_200_065_000.0))])), now=Some(1_795_200_070_000.0)),
    true,
  )
  assert_eq(host.get(Some("peng@example.com")), Some(1_795_200_060_000.0))
}

///|
test "CommaSurface advertises task_say_cas when chats enabled, validates expected_card_seq, and forwards flags" {
  let rt = @effect.Runtime::new()
  let io = test_io()
  let tasks = CommaTasks::new("/tmp/comma-tasks-closecard-wbtest.json", io, rt)
  let calls : Array[(String, String, Bool, Double?)] = []
  let sent : Array[J] = []
  let sock : Socket = { id: 1, send: text => sent.push(parse_json(text)), on_close: _ => () => () }
  let surface = CommaSurface::new(
    {
      connect: "cm-close",
      server: "http://127.0.0.1",
      token: "salix_conn_test123",
      name: "Alpha · mac-1",
      workspace: Some("ws_1"),
      owner_email: None,
      tasks,
      store: test_store(),
      models: () => [],
      lang: Some("en"),
      stats: None,
      chats: Some({
        read: async fn(_, _, _) { Null },
        say: async fn(ref_, text, _, _, _, close_card, expected_card_seq) {
          calls.push((ref_, text, close_card, expected_card_seq))
          jobj([("seq", ji(0))])
        },
      }),
      previous_exited: async fn() { () },
      in_scope: () => true,
      workspace_meta: None,
      on_workspace_meta_change: None,
      owner_active_at: None,
      on_owner_active_change: None,
    },
    io,
    rt,
  )
  // Capabilities include task_say_cas: 1 when chats is Some(_).
  assert_eq(num_of(prop(Some(surface.capabilities()), "task_say_cas")), Some(1.0))

  // Capabilities omit task_say_cas when chats is None.
  let no_chats = CommaSurface::new(
    {
      connect: "cm-no-chats",
      server: "http://127.0.0.1",
      token: "salix_conn_test123",
      name: "Alpha · mac-1",
      workspace: Some("ws_1"),
      owner_email: None,
      tasks,
      store: test_store(),
      models: () => [],
      lang: Some("en"),
      stats: None,
      chats: None,
      previous_exited: async fn() { () },
      in_scope: () => true,
      workspace_meta: None,
      on_workspace_meta_change: None,
      owner_active_at: None,
      on_owner_active_change: None,
    },
    io,
    rt,
  )
  assert_true(prop(Some(no_chats.capabilities()), "task_say_cas") is None)

  let errors : Array[String] = []
  let fiber = rt.fork(async fn() {
    surface.socket_ = Some(sock)
    ignore(
      surface.handle(
        "task.say",
        @jsjson.parse(
          "{\"task\":\"5\",\"text\":\"Skip deploy\",\"key\":\"k1\",\"requester\":\"Router\",\"close_card\":true,\"expected_card_seq\":9}",
        ),
      ),
    )
    ignore(
      surface.handle(
        "task.say",
        @jsjson.parse(
          "{\"task\":\"5\",\"text\":\"Proceed\",\"key\":\"k2\",\"requester\":\"Router\",\"expected_card_seq\":null}",
        ),
      ),
    )
    ignore(
      surface.handle(
        "task.say",
        @jsjson.parse(
          "{\"task\":\"5\",\"text\":\"Plain\",\"key\":\"k3\",\"requester\":\"Router\"}",
        ),
      ),
    )
    let bad_values = ["0", "-1", "1.5", "\"9\"", "true", "9007199254740992"]
    for bad in bad_values {
      let res = try {
        Ok(
          surface.handle(
            "task.say",
            @jsjson.parse("{\"task\":\"5\",\"text\":\"Proceed\",\"expected_card_seq\":\{bad}}"),
          ),
        )
      } catch {
        e => Err(message_of(e))
      }
      match res {
        Err(msg) => errors.push(msg)
        Ok(_) => errors.push("unexpected ok for \{bad}")
      }
    }
  })
  ignore(rt.run_ready())
  match fiber.poll() {
    Some(Succeeded(_)) => ()
    Some(Failed(e)) => fail("task.say failed: \{e}")
    _ => fail("task.say did not finish")
  }
  assert_eq(calls, [("5", "Skip deploy", true, Some(9.0)), ("5", "Proceed", false, None), ("5", "Plain", false, None)])
  assert_eq(errors.length(), 6)
  for msg in errors {
    assert_eq(msg, "expected_card_seq must be a positive integer")
  }
}

///|
test "router_says_with enforces expected_card_seq CAS for replies, silent closes, and idempotent retries" {
  let rt = @effect.Runtime::new()
  let io = test_io()
  let card_body = @jsjson.parse(
    "{\"type\":\"options\",\"assignee\":\"ann@x\",\"options\":[{\"label\":\"Proceed\",\"action\":\"reply\"},{\"label\":\"Skip deploy\",\"action\":\"close\"}]}",
  )
  let pending_card : Ref[(Double, J)?] = Ref(Some((1.0, card_body)))
  let next_seq = Ref(1.0)
  let appended : Array[(Double, String)] = []
  let closed_calls : Array[(Double, String)] = []
  let close_succeeds = Ref(true)
  let once_rows : Map[String, (String, Double, Double, Double)] = {}
  let next_once_id = Ref(0)
  let remembered : Map[String, Double] = {}

  let hub : RouterHub = {
    get: async fn(sql, args) {
      if sql.contains("FROM comma_router_once WHERE key = ?") {
        let key = str_of(args.get(0)).unwrap_or("")
        match once_rows.get(key) {
          Some((id, thread, n, pending)) =>
            jobj([("id", jstr(id)), ("thread", Num(thread)), ("n", Num(n)), ("pending", Num(pending))])
          None => Null
        }
      } else if sql.contains("INSERT INTO comma_router_once") {
        next_once_id.val += 1
        let id = next_once_id.val.to_string()
        let key = str_of(args.get(0)).unwrap_or("")
        let thread = num_of(args.get(1)).unwrap_or(0.0)
        let n = num_of(args.get(2)).unwrap_or(0.0)
        once_rows[key] = (id, thread, n, 1.0)
        jobj([("id", jstr(id))])
      } else {
        Null
      }
    },
    all: async fn(sql, args) {
      if sql.contains("FROM comma_router_once o") {
        let key = str_of(args.get(1)).unwrap_or("")
        match once_rows.get(key) {
          Some((_, _, _, pending)) => [jobj([("pending", Num(pending)), ("session", Null)])]
          None => []
        }
      } else {
        []
      }
    },
    run: async fn(_, _) { () },
    thread_sessions: async fn(_) { [jobj([("session", jstr("a")), ("leftAt", Null)])] },
    get_session: async fn(key) { jobj([("key", jstr(key)), ("ws", jstr("ws_1"))]) },
    ws_of: async fn(_) { Some("ws_1") },
    deliver: async fn(_, _, _, _, _) { () },
    complete_router_write: async fn(id) {
      for k, v in once_rows {
        if v.0 == id {
          once_rows[k] = (v.0, v.1, v.2, 0.0)
          return true
        }
      }
      false
    },
    pending_card_header: async fn(_) {
      match pending_card.val {
        Some((n, card)) => Arr([jobj([("n", Num(n)), ("ts", jstr("\{n}.0"))]), card])
        None => Null
      }
    },
    close_card: async fn(_, _, n, option) {
      if !close_succeeds.val {
        return false
      }
      closed_calls.push((n, option))
      pending_card.val = None
      true
    },
    say: async fn(_, _, text, hooks) {
      match hooks {
        Some(h) => {
          (h.before)()
          next_seq.val += 1.0
          let n = next_seq.val
          appended.push((n, text))
          pending_card.val = None
          (h.inserted)(n)
          n
        }
        None => {
          next_seq.val += 1.0
          let n = next_seq.val
          appended.push((n, text))
          pending_card.val = None
          n
        }
      }
    },
  }

  let run_say = async fn(w : RouterSay) -> Result[Double, String] {
    try {
      Ok(router_says_with(hub, k => remembered.get(k), (k, n) => remembered[k] = n, Some("ws_1"), w, io))
    } catch {
      e => Err(message_of(e))
    }
  }

  let results : Array[Result[Double, String]] = []
  let fiber = rt.fork(async fn() {
    // 0: wrong seq fails with stale_card without appending
    results.push(
      run_say({
        thread: 10.0,
        text: "Proceed",
        key: "cm:wrong",
        requester: "Router",
        connect: "cm",
        close_card: false,
        expected_card_seq: Some(99.0),
      }),
    )
    // 1: matching seq keyed reply succeeds and clears pending card
    results.push(
      run_say({
        thread: 10.0,
        text: "Proceed",
        key: "cm:reply-1",
        requester: "Router",
        connect: "cm",
        close_card: false,
        expected_card_seq: Some(1.0),
      }),
    )
    // 2: idempotent retry with same key succeeds even after card is no longer pending
    results.push(
      run_say({
        thread: 10.0,
        text: "Proceed",
        key: "cm:reply-1",
        requester: "Router",
        connect: "cm",
        close_card: false,
        expected_card_seq: Some(1.0),
      }),
    )
    // 3: new key targeting already-answered card1 fails with stale_card
    results.push(
      run_say({
        thread: 10.0,
        text: "Proceed",
        key: "cm:reply-2",
        requester: "Router",
        connect: "cm",
        close_card: false,
        expected_card_seq: Some(1.0),
      }),
    )
    // 4: unkeyed reply targeting missing pending card fails with stale_card
    results.push(
      run_say({
        thread: 10.0,
        text: "Proceed",
        key: "",
        requester: "Router",
        connect: "cm",
        close_card: false,
        expected_card_seq: Some(1.0),
      }),
    )
    // Post card2 (seq 5), test unkeyed matching reply and card replacement
    pending_card.val = Some((5.0, card_body))
    // 5: unkeyed reply with matching seq succeeds
    results.push(
      run_say({
        thread: 10.0,
        text: "Unkeyed ok",
        key: "",
        requester: "Router",
        connect: "cm",
        close_card: false,
        expected_card_seq: Some(5.0),
      }),
    )
    // Post card3 (seq 8) for silent-close CAS tests
    pending_card.val = Some((8.0, card_body))
    // 6: stale card seq on close_card fails without closing card3
    results.push(
      run_say({
        thread: 10.0,
        text: "Skip deploy",
        key: "cm:close-stale",
        requester: "Router",
        connect: "cm",
        close_card: true,
        expected_card_seq: Some(1.0),
      }),
    )
    // 7: matching seq on close_card with non-close choice fails with choice mismatch
    results.push(
      run_say({
        thread: 10.0,
        text: "Proceed",
        key: "cm:close-mismatch",
        requester: "Router",
        connect: "cm",
        close_card: true,
        expected_card_seq: Some(8.0),
      }),
    )
    // 8: raced close_card (store returns false) fails with stale_card
    close_succeeds.val = false
    results.push(
      run_say({
        thread: 10.0,
        text: "Skip deploy",
        key: "cm:close-raced",
        requester: "Router",
        connect: "cm",
        close_card: true,
        expected_card_seq: Some(8.0),
      }),
    )
    close_succeeds.val = true
    // 9: matching seq + matching close choice closes card3 silently
    results.push(
      run_say({
        thread: 10.0,
        text: "Skip deploy",
        key: "cm:close-ok",
        requester: "Router",
        connect: "cm",
        close_card: true,
        expected_card_seq: Some(8.0),
      }),
    )
    // 10: idempotent retry of close_card with same key returns card3 seq
    results.push(
      run_say({
        thread: 10.0,
        text: "Skip deploy",
        key: "cm:close-ok",
        requester: "Router",
        connect: "cm",
        close_card: true,
        expected_card_seq: Some(8.0),
      }),
    )
    // 11: new key targeting closed card3 fails with stale_card
    results.push(
      run_say({
        thread: 10.0,
        text: "Skip deploy",
        key: "cm:close-after",
        requester: "Router",
        connect: "cm",
        close_card: true,
        expected_card_seq: Some(8.0),
      }),
    )
    // 12: without expected_card_seq, close_card on non-pending card preserves backward-compat 0.0
    results.push(
      run_say({
        thread: 10.0,
        text: "Skip deploy",
        key: "cm:legacy-close",
        requester: "Router",
        connect: "cm",
        close_card: true,
        expected_card_seq: None,
      }),
    )
  })
  ignore(rt.run_ready())
  match fiber.poll() {
    Some(Succeeded(_)) => ()
    Some(Failed(e)) => fail("router_says_with test failed: \{e}")
    _ => fail("router_says_with test did not finish")
  }
  assert_eq(results[0], Err("stale_card: the card is no longer pending"))
  assert_eq(results[1], Ok(2.0))
  assert_eq(results[2], Ok(2.0))
  assert_eq(results[3], Err("stale_card: the card is no longer pending"))
  assert_eq(results[4], Err("stale_card: the card is no longer pending"))
  assert_eq(results[5], Ok(3.0))
  assert_eq(results[6], Err("stale_card: the card is no longer pending"))
  assert_eq(results[7], Err("stale_card: choice does not match pending card"))
  assert_eq(results[8], Err("stale_card: the card is no longer pending"))
  assert_eq(results[9], Ok(8.0))
  assert_eq(results[10], Ok(8.0))
  assert_eq(results[11], Err("stale_card: the card is no longer pending"))
  assert_eq(results[12], Ok(0.0))
  assert_eq(appended, [(2.0, "Proceed"), (3.0, "Unkeyed ok")])
  assert_eq(closed_calls, [(8.0, "Skip deploy")])
}

///|
test "mesh peer SAY serializes, validates, and propagates expectedCardSeq and stale_card" {
  let req = peer_say_request("ws_1", {
    thread: 7.0,
    text: "Proceed",
    key: "cm:k1",
    requester: "Router",
    connect: "cm",
    close_card: false,
    expected_card_seq: Some(42.0),
  })
  assert_eq(num_of(prop(prop(Some(req), "say"), "expectedCardSeq")), Some(42.0))
  let parsed = parse_peer_say(req)
  assert_eq(parsed.thread, 7.0)
  assert_eq(parsed.text, "Proceed")
  assert_eq(parsed.key, "cm:k1")
  assert_eq(parsed.close_card, false)
  assert_eq(parsed.expected_card_seq, Some(42.0))

  // Omitted when expected_card_seq is None.
  let req_none = peer_say_request("ws_1", {
    thread: 7.0,
    text: "Proceed",
    key: "",
    requester: "Router",
    connect: "cm",
    close_card: true,
    expected_card_seq: None,
  })
  assert_true(prop(prop(Some(req_none), "say"), "expectedCardSeq") is None)
  let parsed_none = parse_peer_say(req_none)
  assert_eq(parsed_none.close_card, true)
  assert_eq(parsed_none.expected_card_seq, None)

  // Invalid expectedCardSeq values are rejected with "no such write".
  for bad in ["0", "-2", "1.5", "\"42\"", "true", "9007199254740992"] {
    let raw = @jsjson.parse("{\"say\":{\"thread\":7,\"text\":\"Proceed\",\"expectedCardSeq\":\{bad}}}")
    let err = try {
      ignore(parse_peer_say(raw))
      None
    } catch {
      e => Some(message_of(e))
    }
    assert_eq(err, Some("no such write"))
  }

  // Remote receiver returns stale_card when parsed expectedCardSeq does not match pending card.
  let rt = @effect.Runtime::new()
  let io = test_io()
  let hub : RouterHub = {
    get: async fn(_, _) { Null },
    all: async fn(_, _) { [] },
    run: async fn(_, _) { () },
    thread_sessions: async fn(_) { [jobj([("session", jstr("a")), ("leftAt", Null)])] },
    get_session: async fn(key) { jobj([("key", jstr(key))]) },
    ws_of: async fn(_) { Some("ws_1") },
    deliver: async fn(_, _, _, _, _) { () },
    complete_router_write: async fn(_) { true },
    pending_card_header: async fn(_) { Null },
    close_card: async fn(_, _, _, _) { false },
    say: async fn(_, _, _, hooks) {
      match hooks {
        Some(h) => (h.before)()
        None => ()
      }
      99.0
    },
  }
  let remote_err : Ref[String?] = Ref(None)
  let fiber = rt.fork(async fn() {
    ignore(
      router_says_with(hub, _ => None, (_, _) => (), Some("ws_1"), parsed, io) catch {
        e => {
          remote_err.val = Some(message_of(e))
          0.0
        }
      },
    )
  })
  ignore(rt.run_ready())
  match fiber.poll() {
    Some(Succeeded(_)) => ()
    Some(Failed(e)) => fail("remote peer SAY test failed: \{e}")
    _ => fail("remote peer SAY test did not finish")
  }
  assert_eq(remote_err.val, Some("stale_card: the card is no longer pending"))
}

///|
test "valid_task_links validates Comma web and app URLs and rejects untrusted schemes" {
  let ok = valid_task_links(
    Some(
      @jsjson.parse(
        "{\"web\":\"https://app.comma.surf/#/tasks/wsp_1/grp1_2/cnv_3\",\"app\":\"comma://task?workspace=wsp_1&group=grp1_2&task=cnv_3\"}",
      ),
    ),
  )
  assert_eq(str_of(prop(ok, "web")), Some("https://app.comma.surf/#/tasks/wsp_1/grp1_2/cnv_3"))
  assert_eq(str_of(prop(ok, "app")), Some("comma://task?workspace=wsp_1&group=grp1_2&task=cnv_3"))
  let staging = valid_task_links(
    Some(
      @jsjson.parse(
        "{\"web\":\"https://app-staging.comma.surf/#/tasks/w1/g1/t1\",\"app\":\"comma-staging://task?workspace=w1&group=g1&task=t1\"}",
      ),
    ),
  )
  assert_eq(str_of(prop(staging, "app")), Some("comma-staging://task?workspace=w1&group=g1&task=t1"))
  assert_true(
    valid_task_links(Some(@jsjson.parse("{\"web\":\"http://app.comma.surf/x\",\"app\":\"file:///etc/passwd\"}"))) is None,
  )
  assert_true(
    valid_task_links(Some(@jsjson.parse("{\"web\":\"javascript:alert(1)\",\"app\":\"comma://evil?x=1\"}"))) is None,
  )
  assert_true(valid_task_links(Some(@jsjson.parse("{\"app\":\"comma://task\"}"))) is None)
  assert_true(valid_task_links(Some(@jsjson.parse("{\"app\":\"comma://task?x=1#frag\"}"))) is None)
}
