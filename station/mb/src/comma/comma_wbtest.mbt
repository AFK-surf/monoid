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
test "CommaSurface forwards close_card flag from task.say to CommaChats.say" {
  let rt = @effect.Runtime::new()
  let io = test_io()
  let tasks = CommaTasks::new("/tmp/comma-tasks-closecard-wbtest.json", io, rt)
  let calls : Array[(String, String, Bool)] = []
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
        say: async fn(ref_, text, _, _, _, close_card) {
          calls.push((ref_, text, close_card))
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
  let fiber = rt.fork(async fn() {
    surface.socket_ = Some(sock)
    ignore(
      surface.handle(
        "task.say",
        @jsjson.parse(
          "{\"task\":\"5\",\"text\":\"Skip deploy\",\"key\":\"k1\",\"requester\":\"Router\",\"close_card\":true}",
        ),
      ),
    )
    ignore(
      surface.handle(
        "task.say",
        @jsjson.parse(
          "{\"task\":\"5\",\"text\":\"Proceed\",\"key\":\"k2\",\"requester\":\"Router\"}",
        ),
      ),
    )
  })
  ignore(rt.run_ready())
  match fiber.poll() {
    Some(Succeeded(_)) => ()
    Some(Failed(e)) => fail("task.say failed: \{e}")
    _ => fail("task.say did not finish")
  }
  assert_eq(calls, [("5", "Skip deploy", true), ("5", "Proceed", false)])
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
