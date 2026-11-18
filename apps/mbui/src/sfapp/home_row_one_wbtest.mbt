// A chat's row changed on Home, its order as it was (its title renamed), tells that row alone:
// each row reads its chat by its name (sfpages' chats_pane_node: the rows kept by key), and the list's lines are worked
// out again only as a row or a day comes, goes or moves, not as a row's words do. On the workspace of real size, as a
// device holds it (real_size_wbtest.mbt's way), each write that wakes many readers counted (Tester::set_fanout_limit).

///|
test "a chat's row changed on Home wakes its own row alone, not every row the list shows" {
  let c = @sfrealsize.RealSizeChanging::new()
  let t = screen_in("home", home_again_window, "zh", changing=Some(c), moves_held=false)
  real_size_change_said()
  let ways = c.ways()
  guard ways.search_by(fn(w) { @sfrealsize.real_size_way(w.0, w.1) == "chats" }) is Some(at) else {
    fail("Home reads no list of all chats")
  }
  // (the list's first chat: its day, its key)
  guard @sfrealsize.real_size_value(ways[at].0, ways[at].1) is Some(Object(v)) &&
    v.get("days") is Some(Array(days)) &&
    days.get(0) is Some(Object(day)) &&
    day.get("daysAgo") is Some(ago) &&
    day.get("items") is Some(Array(items)) &&
    items.get(0) is Some(Object(item)) &&
    item.get("station") is Some(station) &&
    item.get("id") is Some(id) else {
    fail("the list has no chat")
  }
  let rows = days.fold(init=0, fn(n, d) {
    match d {
      Object(d) =>
        match d.get("items") {
          Some(Array(a)) => n + a.length()
          _ => n
        }
      _ => n
    }
  })
  assert_true(rows >= 30, msg="\{rows} rows")
  let said = "新的标题 42"
  let words : Json = Json::string(said)
  let delta : Json = [
    {
      "path": ["days"],
      "key": ["daysAgo"],
      "patch": ago,
      "ops": [
        {
          "path": ["items"],
          "key": ["station", "id"],
          "patch": [station, id],
          "ops": [{ "path": ["title"], "set": words }],
        },
      ],
    },
  ]
  t.set_fanout_limit(8)
  let f = real_size_change_frame(t, fn() { c.put(at, delta) })
  let faults = t.fanout_faults()
  println("HOMEROW frame \{Repr(f)} fanout \{Repr(faults)}")
  // (its new title shown in its row)
  assert_true(t.words().iter().any(fn(w) { w.0.has_prefix("新的标题") }), msg="\{Repr(t.words().map(fn(w) { w.0 }))}")
  // (nothing the list keeps, written as a row's words change, wakes more than one row's readers)
  assert_eq(faults.filter(fn(s) { s.contains("sidebar_node.mbt") }), [])
  // (made and let go: nothing, its rows and lines as they were)
  assert_eq((f.0, f.1), (0, 0))
  t.set_fanout_limit(0)
}
