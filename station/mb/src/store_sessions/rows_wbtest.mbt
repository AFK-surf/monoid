///|
test "a row as rows.ts reads it" {
  let r : Map[String, Json] = {
    "key": "s",
    "scope": "all",
    "profile": "p",
    "profile_pinned": 1,
    "profiles": "[\"a\",\"\",3,\"b\"]",
    "fast": 0,
    "afresh": Json::null(),
    "context": "x",
    "running": 1,
    "came_from": "",
    "speed": "fast",
  }
  let s = to_session(r)
  inspect(
    field(s, "scope"),
    content=(
      #|Some(String(all))
    ),
  )
  inspect(
    field(s, "profiles"),
    content=(
      #|Some(Array([String(a), String(b)]))
    ),
  )
  inspect(field(s, "fast"), content="Some(False)")
  inspect(field(s, "afresh"), content="Some(Null)")
  inspect(field(s, "context"), content="Some(Null)")
  inspect(
    field(s, "speed"),
    content=(
      #|Some(String(fast))
    ),
  )
  inspect(field(s, "from"), content="None")
  inspect(
    parse_profiles(jstr("[]"), jstr("p"), true),
    content=(
      #|Array([String(p)])
    ),
  )
  inspect(parse_profiles(jstr("{"), jstr("p"), false), content="Null")
}

///|
test "a turn's summary in both words" {
  let t = to_turn_summary({
    "kind": "input",
    "declared": "need_decision",
    "about_thread": 1,
    "about_n": 2,
    "about_ts": Json::null(),
    "wait_watch": 0,
  })
  inspect(
    field(t, "declared"),
    content=(
      #|Some(String(block))
    ),
  )
  inspect(
    field(t, "ending"),
    content=(
      #|Some(String(need_help))
    ),
  )
  inspect(field(t, "about"), content="Some(Null)")
  inspect(field(t, "waitWatch"), content="Some(False)")
}

///|
test "a share's workspaces, those lapsed too" {
  let share = to_chat_share({
    "shared": "[{\"workspace\":\"a\",\"used\":5},{\"workspace\":\"b\"},{\"name\":\"c\"},null]",
    "write": 1,
    "by": "x",
    "at": 7,
  })
  inspect(
    js(share),
    content="{\"to\":[{\"workspace\":\"a\",\"name\":\"a\",\"used\":5},{\"workspace\":\"b\",\"name\":\"b\",\"used\":7}],\"write\":true,\"by\":\"x\",\"at\":7}",
  )
  inspect(
    live_share(share, 21600006.0),
    content=(
      #|Object({to: Array([Object({workspace: String(b), name: String(b), used: Number(7)})]), write: True, by: String(x), at: Number(7)})
    ),
  )
  inspect(live_share(share, 99999999.0), content="Null")
}

///|
test "JSON as JavaScript writes it" {
  inspect(
    js({ "b": 1, "10": 2, "2": [1.5, -0.0, 1.0e21] }),
    content="{\"2\":[1.5,0,1e+21],\"10\":2,\"b\":1}",
  )
  inspect(js_string(jnum(3.0)), content="3")
  inspect(
    js_string(Json::array([jnum(1.0), Json::null(), jstr("x")])),
    content="1,,x",
  )
  inspect(by_bytes("é", "z") > 0, content="true")
  inspect(
    js_sorted(["b", "a", "é", "B"]),
    content=(
      #|[B, a, b, é]
    ),
  )
}

///|
test "a hand-over's paths, surfaces and ts" {
  inspect(bump("171.9"), content="171.10")
  inspect(bump("a007"), content="a008")
  inspect(bump("x"), content="x1")
  inspect(bump("99"), content="100")
  inspect(
    moved_path(jstr("/there/rooms/a"), "/there/", "/here"),
    content=(
      #|String(/here/rooms/a)
    ),
  )
  inspect(
    moved_path(jstr("/there"), "/there", "/here"),
    content=(
      #|String(/here)
    ),
  )
  inspect(
    moved_path(jstr("/thereafter"), "/there", "/here"),
    content=(
      #|String(/thereafter)
    ),
  )
  inspect(moved_path(jnum(1.0), "/there", "/here"), content="Number(1)")
  inspect(path_join("/here/", "a/../b//c/"), content="/here/b/c/")
  inspect(surface_here("feishu:c1", { "c1": "c2" }), content="feishu:c2")
  inspect(surface_here("ember", { "c1": "c2" }), content="chat")
  inspect(surface_here("chat", { "c1": "c2" }), content="chat")
  inspect(
    after_of("dismissed", { "viewer": "v", "n": 3 }),
    content=(
      #|Array([String(v), Number(3)])
    ),
  )
  inspect(after_of("threads", { "id": 1 }), content="Null")
}

///|
test "an allowance's windows as an hour keeps them" {
  let w = hour_windows({
    "windows": [
      { "label": "5h", "usedPercent": 5, "resetsAt": 9 },
      { "label": "x" },
    ],
    "scoped": [{ "scope": "", "usedPercent": 1 }, 3],
  })
  inspect(
    js(Json::array(w)),
    content="[{\"label\":\"5h\",\"scope\":null,\"usedPercent\":5,\"resetsAt\":9,\"minutes\":null},{\"label\":\"\",\"scope\":null,\"usedPercent\":1,\"resetsAt\":null,\"minutes\":null}]",
  )
  inspect(checked_at({ "checkedAt": 5.5 }), content="Null")
  inspect(base_name("a\\b/c.html"), content="c.html")
  inspect(safe_id(jstr("a\u{0}b")), content="false")
}

///|
test "usage_files_of preserves first-seen order, overwrites duplicates in place, and scales linearly" {
  let rows : Array[Map[String, Json]] = [
    { "path": "/a.jsonl", "session": "s1", "offset": 10, "model": "m1", "speed": 1 },
    { "path": "/b.jsonl", "session": "s2", "offset": 20, "model": "m2", "speed": 2 },
    { "path": "/a.jsonl", "session": "s1", "offset": 99, "model": "m1b", "speed": 3 },
  ]
  let got = usage_files_of(rows)
  inspect(
    js(got),
    content="[[\"/a.jsonl\",{\"session\":\"s1\",\"offset\":99,\"model\":\"m1b\",\"speed\":3}],[\"/b.jsonl\",{\"session\":\"s2\",\"offset\":20,\"model\":\"m2\",\"speed\":2}]]",
  )
  let many : Array[Map[String, Json]] = []
  for i in 0..<2000 {
    many.push({ "path": "/p/\{i}.jsonl", "session": "s-\{i}", "offset": i, "model": "m", "speed": 0 })
  }
  many.push({ "path": "/p/42.jsonl", "session": "s-42", "offset": 9999, "model": "m-new", "speed": 1 })
  match usage_files_of(many) {
    Array(items) => {
      assert_eq(items.length(), 2000)
      inspect(
        js(items[42]),
        content="[\"/p/42.jsonl\",{\"session\":\"s-42\",\"offset\":9999,\"model\":\"m-new\",\"speed\":1}]",
      )
    }
    _ => abort("expected array")
  }
}
