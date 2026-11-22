// An allowance's chips (quota_chip.mbt): what they say short of room.

///|
/// The quota line of a side column's row as nodes (nav_quota_chips_node) for `q`, in a row `w` wide (its provider's
/// widest its own), started with keyboard and mouse, drawn once. The Tester.
fn nav_quota_tester(q : Json, w : Double, h : Double) -> @ui.Tester {
  let t = @ui.Tester::new(fn(c) { begin(c) |> ignore }, w=640.0, h~, platform=0)
  @ui.set_view_app(fn(root) {
    @ui.set_tree_theme(ui_theme_now)
    root.box(fn(b) {
      b.width(Is(Some(w))) |> ignore
      let widest = nav_quota_room_node(b, Some(q))
      nav_quota_chips_node(b, fn() { Some(q) }, Side, fn() { widest })
    })
    |> ignore
  })
  t.draw()
  t
}

///|
test "multi-window model pools group each pool with a left group column and aligned short [5h] [W] capsules" {
  let q = Json::object({
    "state": "ok",
    "windows": [
      { "label": "5 小时 · Gemini", "mark": "Gemini 5H", "scope": "gemini", "left": 56.0, "level": "ok" },
      { "label": "每周 · Gemini", "mark": "Gemini W", "scope": "gemini", "left": 58.0, "level": "ok" },
      { "label": "5 小时 · Claude / GPT", "mark": "Claude / GPT 5H", "scope": "3p", "left": 100.0, "level": "ok" },
      { "label": "每周 · Claude / GPT", "mark": "Claude / GPT W", "scope": "3p", "left": 79.0, "level": "ok" },
    ],
  })
  let t = nav_quota_tester(q, 224.0, 200.0)
  let shown = t.words().filter(fn(w) { w.5 > 0.5 })
  let find_all = fn(mark : String) { shown.filter(fn(w) { w.0 == mark }) }
  let gemini = find_all("Gemini")[0]
  let claude_gpt = find_all("Claude / GPT")[0]
  let fives = find_all("5h")
  let weeks = find_all("W")
  assert_eq(fives.length(), 2)
  assert_eq(weeks.length(), 2)
  // Both 5h capsules align at the exact same X coordinate after the left group column
  assert_eq(fives[0].1, fives[1].1)
  assert_eq(gemini.2, fives[0].2)
  assert_eq(fives[0].2, weeks[0].2)
  assert_eq(claude_gpt.2, fives[1].2)
  assert_eq(fives[1].2, weeks[1].2)
  assert_true(claude_gpt.2 > gemini.2)
  assert_eq(t.squeeze_faults(), [])
  // Narrowest 180pt sidebar (row width 164pt): stacks the group title above the pair of short capsules
  let narrow = nav_quota_tester(q, 164.0, 200.0)
  let nshown = narrow.words().filter(fn(w) { w.5 > 0.5 })
  let nfind = fn(mark : String) { nshown.filter(fn(w) { w.0 == mark }) }
  let ng = nfind("Gemini")[0]
  let nfives = nfind("5h")
  let nweeks = nfind("W")
  assert_true(nfives[0].2 > ng.2)
  assert_eq(nfives[0].2, nweeks[0].2)
  assert_eq(narrow.squeeze_faults(), [])

  // Pro accounts add a third single-window Argon group (`Argon W`) after `Claude / GPT`, aligned in the same grid.
  let pro_q = Json::object({
    "state": "ok",
    "windows": [
      { "label": "5 小时 · Gemini", "mark": "Gemini 5H", "scope": "gemini", "left": 100.0, "level": "ok" },
      { "label": "每周 · Gemini", "mark": "Gemini W", "scope": "gemini", "left": 100.0, "level": "ok" },
      { "label": "5 小时 · Claude / GPT", "mark": "Claude / GPT 5H", "scope": "3p", "left": 100.0, "level": "ok" },
      { "label": "每周 · Claude / GPT", "mark": "Claude / GPT W", "scope": "3p", "left": 100.0, "level": "ok" },
      { "label": "每周 · Argon", "mark": "Argon W", "scope": "Argon", "left": 95.0, "level": "ok" },
    ],
  })
  let pt = nav_quota_tester(pro_q, 224.0, 240.0)
  let pshown = pt.words().filter(fn(w) { w.5 > 0.5 })
  let pfind = fn(mark : String) { pshown.filter(fn(w) { w.0 == mark }) }
  let pgemini = pfind("Gemini")[0]
  let pclaude = pfind("Claude / GPT")[0]
  let pargon = pfind("Argon")[0]
  let pfives = pfind("5h")
  let pweeks = pfind("W")
  assert_eq(pfives.length(), 2)
  assert_eq(pweeks.length(), 3)
  assert_eq(pfives[0].1, pfives[1].1)
  assert_eq(pfives[0].1, pweeks[2].1)
  assert_eq(pargon.2, pweeks[2].2)
  assert_true(pclaude.2 > pgemini.2)
  assert_true(pargon.2 > pclaude.2)
  assert_eq(pt.squeeze_faults(), [])
}

///|
test "nav_quota_chip_w is the width a small fill chip as nodes is laid out at, to the whole point: marked, unmarked, spent; keyboard and mouse and touch" {
  let chips : Array[(String, String, Bool)] = [
    ("Fable", "52%", false),
    ("", "100%", false),
    ("5H", "62%", false),
    ("每周", "95%", false),
    ("5h", "42m", true),
    ("每周", "2d", true),
  ]
  assert_true(chip_joined("每周", "剩 95%"))
  for platform in [0, 2] {
    let said : Array[Double] = chips.map(fn(_) { 0.0 })
    let made : Array[@view.View?] = chips.map(fn(_) { None })
    let t = @ui.Tester::new(fn(c) { begin(c) |> ignore }, w=640.0, h=300.0, platform~)
    @ui.set_view_app(fn(root) {
      @ui.set_tree_theme(ui_theme_now)
      let wide = nav_quota_chip_w(root)
      for i, chip in chips {
        let (mark, words, refill) = chip
        said[i] = wide(mark, words, refill)
        // (each in a row of its own as wide as what it holds)
        root.box(fn(r) {
          r.row(Is(true)) |> ignore
          made[i] = Some(
            fill_chip_node(r, fn() { if refill { 0 } else { 52 } }, fn() { if refill { "red" } else { "ok" } }, fn() { mark }, fn() {
              words
            }, small=true, label_muted=true, refill=fn() { refill }),
          )
        })
        |> ignore
      }
    })
    t.draw()
    for i, chip in chips {
      // (to the whole point past it: the room a line of them is laid out by)
      assert_eq(said[i], made[i].unwrap().rect().2.ceil(), msg="\{platform} \{Repr(chip)}: \{said[i]} \{Repr(made[i].unwrap().rect())}")
    }
  }
}

///|
test "spent windows show their own refill, including in marked and worded chips" {
  let spent : Json = { "label": "每周", "mark": "W", "left": 0, "level": "red", "refillShort": "2d", "refills": "2 天后刷新" }
  let live : Json = { "label": "5 小时", "mark": "5H", "left": 1, "level": "red", "refills": "42 分钟后刷新" }
  let unknown : Json = { "mark": "M", "left": 0, "level": "red", "refills": Json::null() }
  let q : Json = { "state": "ok", "windows": [live, spent, unknown] }
  assert_eq(quota_chips_said(Some(q)), "5h 1% W 2d M 0%")
  assert_eq(quota_worded(Some(spent), 1), ("每周", "2d"))
  assert_eq(quota_worded(Some(spent), 2), ("W", "2d"))
  assert_true(quota_is_refill(Some(spent)))
  assert_false(quota_is_refill(Some(live)))
  assert_false(quota_is_refill(Some(unknown)))
}

///|
test "quota refill chips pass contrast and corner audits in light and dark" {
  let cases : Array[(String, String, Bool, Bool, Bool)] = [
    ("5h", "42m", false, true, true),
    ("每周", "2d", false, true, true),
    ("", "42m", true, true, true),
    ("5h", "18m", true, true, true),
    ("5h", "48%", false, true, false),
  ]
  for dark in [false, true] {
    set_dark(Some(dark))
    for platform in [0, 2] {
      let t = @ui.Tester::new(fn(c) { begin(c) |> ignore }, w=640.0, h=300.0, platform~, dark~, tree=fn(root) {
        @ui.set_tree_theme(ui_theme_now)
        root.box(fn(col) {
          col.gap(Is(8.0)) |> ignore
          for item in cases {
            let (mark, words, small, label_muted, refill) = item
            col.box(fn(r) {
              r.row(Is(true)) |> ignore
              fill_chip_node(
                r,
                fn() { if refill { 0 } else { 48 } },
                fn() { if refill { "red" } else { "ok" } },
                fn() { mark },
                fn() { words },
                small~,
                label_muted~,
                refill=fn() { refill },
              )
              |> ignore
            })
            |> ignore
          }
        })
        |> ignore
      })
      t.draw()
      let faults = t.audit()
      assert_eq(faults, [], msg="audit failed dark=\{dark} platform=\{platform}: \{Repr(faults)}")
    }
  }
  set_dark(None)
}

///|
test "quota_worded_node renders refill countdown icon and switches from full label to short mark when narrow" {
  let q = Json::object({
    "state": "ok",
    "windows": [
      { "label": "5 小时", "mark": "5H", "left": 0.0, "level": "red", "refillShort": "42m", "refills": "42 分钟后刷新" },
      { "label": "每周", "mark": "W", "left": 40.0, "level": "ok" },
      { "label": "每周 · Fable", "mark": "Fable", "scope": "Fable", "left": 80.0, "level": "ok" },
    ],
  })
  set_dark(Some(false))
  @ui.set_tree_theme(ui_theme_now)
  for room in [600.0, 200.0] {
    let t = @ui.Tester::new(fn(_c) {  }, w=640.0, h=200.0, platform=0)
    @ui.set_view_app(fn(root) {
      root.box(fn(w) {
        w.width(Is(Some(room))) |> ignore
        quota_worded_node(w, fn() { Some(q) })
      })
      |> ignore
    })
    t.draw()
    let shown = t.words().filter(fn(w) { w.5 > 0.5 }).map(fn(w) { w.0 })
    assert_true(shown.contains("5h"), msg="\{room}: \{Repr(shown)}")
    assert_true(shown.contains("42m"), msg="\{room}: \{Repr(shown)}")
    if room > 300.0 {
      assert_true(shown.contains("每周"), msg="\{room}: \{Repr(shown)}")
      assert_true(shown.contains("每周 Fable"), msg="\{room}: \{Repr(shown)}")
    } else {
      assert_true(shown.contains("W"), msg="\{room}: \{Repr(shown)}")
      assert_true(shown.contains("Fable"), msg="\{room}: \{Repr(shown)}")
    }
    let faults = t.audit()
    assert_eq(faults, [], msg="audit failed at \{room}: \{Repr(faults)}")
  }
  set_dark(None)
}

///|
fn count_subtree_nodes(v : @view.View) -> Int {
  v.kids().fold(init=1, fn(acc, k) { acc + count_subtree_nodes(k) })
}

///|
test "pooled nav_quota_chips_node and quota_worded_node mount only active branch and match room_w=Some" {
  let pooled_q = Json::object({
    "state": "ok",
    "windows": [
      { "label": "5 小时 · Gemini", "mark": "Gemini 5H", "scope": "gemini", "left": 56.0, "level": "ok" },
      { "label": "每周 · Gemini", "mark": "Gemini W", "scope": "gemini", "left": 58.0, "level": "ok" },
      { "label": "5 小时 · Claude / GPT", "mark": "Claude / GPT 5H", "scope": "3p", "left": 100.0, "level": "ok" },
      { "label": "每周 · Claude / GPT", "mark": "Claude / GPT W", "scope": "3p", "left": 79.0, "level": "ok" },
    ],
  })
  // 1. nav_quota_chips_node: room_w=None vs room_w=Some at both wide (single-line) and narrow (multi-line)
  for w in [224.0, 164.0] {
    let mut nodes_by_room = 0
    let mut nodes_room_w = 0
    let t1 = @ui.Tester::new(fn(c) { begin(c) |> ignore }, w=640.0, h=200.0, platform=0)
    let mut b1 : @view.View? = None
    @ui.set_view_app(fn(root) {
      @ui.set_tree_theme(ui_theme_now)
      root.box(fn(b) {
        b.width(Is(Some(w))) |> ignore
        let widest = nav_quota_room_node(b, Some(pooled_q))
        nav_quota_chips_node(b, fn() { Some(pooled_q) }, Side, fn() { widest })
        b1 = Some(b)
      })
      |> ignore
    })
    t1.draw()
    nodes_by_room = count_subtree_nodes(b1.unwrap())
    let words1 = t1.words().filter(fn(x) { x.5 > 0.5 }).map(fn(x) { (x.0, x.1, x.2) })
    assert_eq(t1.audit(), [], msg="nav_quota by_room audit failed at \{w}")

    let t2 = @ui.Tester::new(fn(c) { begin(c) |> ignore }, w=640.0, h=200.0, platform=0)
    let mut b2 : @view.View? = None
    @ui.set_view_app(fn(root) {
      @ui.set_tree_theme(ui_theme_now)
      root.box(fn(b) {
        b.width(Is(Some(w))) |> ignore
        let widest = nav_quota_room_node(b, Some(pooled_q))
        nav_quota_chips_node(b, fn() { Some(pooled_q) }, Side, fn() { widest }, room_w=fn() { w })
        b2 = Some(b)
      })
      |> ignore
    })
    t2.draw()
    nodes_room_w = count_subtree_nodes(b2.unwrap())
    let words2 = t2.words().filter(fn(x) { x.5 > 0.5 }).map(fn(x) { (x.0, x.1, x.2) })
    assert_eq(t2.audit(), [], msg="nav_quota room_w audit failed at \{w}")
    assert_eq(words1, words2, msg="nav_quota words mismatch at \{w}")
    // Single active branch only: <= 55 nodes (before double-mount + unslimmed fill_chip was > 110)
    assert_true(nodes_by_room <= 55, msg="nav_quota by_room too many nodes at \{w}: \{nodes_by_room}")
    assert_true(nodes_room_w < nodes_by_room, msg="nav_quota room_w should skip by_room wrapper: \{nodes_room_w} vs \{nodes_by_room}")
  }

  // 2. quota_worded_node: room_w=None vs room_w=Some at wide (flat row) and narrow (grouped lines)
  for w in [600.0, 200.0] {
    let t1 = @ui.Tester::new(fn(c) { begin(c) |> ignore }, w=640.0, h=200.0, platform=0)
    let mut b1 : @view.View? = None
    @ui.set_view_app(fn(root) {
      @ui.set_tree_theme(ui_theme_now)
      root.box(fn(b) {
        b.width(Is(Some(w))) |> ignore
        quota_worded_node(b, fn() { Some(pooled_q) })
        b1 = Some(b)
      })
      |> ignore
    })
    t1.draw()
    let nodes_by_room = count_subtree_nodes(b1.unwrap())
    let words1 = t1.words().filter(fn(x) { x.5 > 0.5 }).map(fn(x) { (x.0, x.1, x.2) })
    assert_eq(t1.audit(), [], msg="quota_worded by_room audit failed at \{w}")

    let t2 = @ui.Tester::new(fn(c) { begin(c) |> ignore }, w=640.0, h=200.0, platform=0)
    let mut b2 : @view.View? = None
    @ui.set_view_app(fn(root) {
      @ui.set_tree_theme(ui_theme_now)
      root.box(fn(b) {
        b.width(Is(Some(w))) |> ignore
        quota_worded_node(b, fn() { Some(pooled_q) }, room_w=fn() { w })
        b2 = Some(b)
      })
      |> ignore
    })
    t2.draw()
    let nodes_room_w = count_subtree_nodes(b2.unwrap())
    let words2 = t2.words().filter(fn(x) { x.5 > 0.5 }).map(fn(x) { (x.0, x.1, x.2) })
    assert_eq(t2.audit(), [], msg="quota_worded room_w audit failed at \{w}")
    assert_eq(words1, words2, msg="quota_worded words mismatch at \{w}")
    // Single active branch only: <= 55 nodes (before double-mount + unslimmed fill_chip was > 110)
    assert_true(nodes_by_room <= 55, msg="quota_worded by_room too many nodes at \{w}: \{nodes_by_room}")
    assert_true(nodes_room_w < nodes_by_room, msg="quota_worded room_w should skip by_room wrapper: \{nodes_room_w} vs \{nodes_by_room}")
  }
}

///|
test "fill_chip_node mounts refresh icon on demand and layout recomputes on font scale change" {
  let refill_sig = @signals.signal(false)
  let left_sig = @signals.signal(50)
  let words_sig = @signals.signal("50%")
  let mut chip_v : @view.View? = None
  let t = @ui.Tester::new(fn(c) { begin(c) |> ignore }, w=640.0, h=200.0, platform=0)
  @ui.set_view_app(fn(root) {
    @ui.set_tree_theme(ui_theme_now)
    root.box(fn(r) {
      r.row(Is(true)) |> ignore
      chip_v = Some(
        fill_chip_node(
          r,
          fn() { left_sig.get() },
          fn() { if refill_sig.get() { "red" } else { "ok" } },
          fn() { "5h" },
          fn() { words_sig.get() },
          label_muted=true,
          refill=fn() { refill_sig.get() },
        ),
      )
    })
    |> ignore
  })
  t.draw()
  let nodes_normal = count_subtree_nodes(chip_v.unwrap())
  assert_eq(t.drawn_shapes().length(), 0)
  assert_eq(t.audit(), [])

  // Switching to refill mounts the refresh icon
  refill_sig.set(true)
  left_sig.set(0)
  words_sig.set("42m")
  t.draw()
  let nodes_refill = count_subtree_nodes(chip_v.unwrap())
  assert_true(t.drawn_shapes().length() > 0)
  assert_true(nodes_refill > nodes_normal, msg="expected refresh icon nodes: \{nodes_refill} vs \{nodes_normal}")
  assert_eq(t.audit(), [])

  // Switching back unmounts the refresh icon
  refill_sig.set(false)
  left_sig.set(50)
  words_sig.set("50%")
  t.draw()
  assert_eq(t.drawn_shapes().length(), 0)
  assert_eq(count_subtree_nodes(chip_v.unwrap()), nodes_normal)

  // Font scale 1.0x -> 1.3x recomputes memoized form in quota_worded_node
  let q_worded = Json::object({
    "state": "ok",
    "windows": [
      { "label": "5 小时", "mark": "5H", "left": 60.0, "level": "ok" },
      { "label": "每周", "mark": "W", "left": 40.0, "level": "ok" },
      { "label": "每周 · Fable", "mark": "Fable", "scope": "Fable", "left": 80.0, "level": "ok" },
    ],
  })
  let tw = @ui.Tester::new(fn(c) { begin(c) |> ignore }, w=640.0, h=200.0, platform=0)
  @ui.set_view_app(fn(root) {
    @ui.set_tree_theme(ui_theme_now)
    root.box(fn(b) {
      b.width(Is(Some(235.0))) |> ignore
      quota_worded_node(b, fn() { Some(q_worded) })
    })
    |> ignore
  })
  tw.draw()
  let shown_1x = tw.words().filter(fn(x) { x.5 > 0.5 }).map(fn(x) { x.0 })
  assert_true(shown_1x.contains("每周 Fable"), msg="1.0x should fit full label: \{Repr(shown_1x)}")
  tw.set_font_scale(1.3)
  tw.draw()
  let shown_13x = tw.words().filter(fn(x) { x.5 > 0.5 }).map(fn(x) { x.0 })
  assert_true(shown_13x.contains("Fable"), msg="1.3x should recompute to compact mark: \{Repr(shown_13x)}")
  assert_false(shown_13x.contains("每周 Fable"), msg="1.3x should no longer show full label: \{Repr(shown_13x)}")

  // Font scale 1.0x -> 1.3x recomputes memoized one/label_w in nav_quota_chips_node
  let pooled_q = Json::object({
    "state": "ok",
    "windows": [
      { "label": "5 小时 · Gemini", "mark": "Gemini 5H", "scope": "gemini", "left": 56.0, "level": "ok" },
      { "label": "每周 · Gemini", "mark": "Gemini W", "scope": "gemini", "left": 58.0, "level": "ok" },
      { "label": "5 小时 · Claude / GPT", "mark": "Claude / GPT 5H", "scope": "3p", "left": 100.0, "level": "ok" },
      { "label": "每周 · Claude / GPT", "mark": "Claude / GPT W", "scope": "3p", "left": 79.0, "level": "ok" },
    ],
  })
  let tn = @ui.Tester::new(fn(c) { begin(c) |> ignore }, w=640.0, h=240.0, platform=0)
  @ui.set_view_app(fn(root) {
    @ui.set_tree_theme(ui_theme_now)
    root.box(fn(b) {
      b.width(Is(Some(190.0))) |> ignore
      nav_quota_chips_node(b, fn() { Some(pooled_q) }, Side, fn() { nav_quota_room_node(b, Some(pooled_q)) })
    })
    |> ignore
  })
  tn.draw()
  let w1 = tn.words().filter(fn(x) { x.5 > 0.5 })
  let g1 = w1.filter(fn(x) { x.0 == "Gemini" })[0]
  let f1 = w1.filter(fn(x) { x.0 == "5h" })[0]
  assert_eq(g1.2, f1.2, msg="1.0x should lay out single line per pool")
  tn.set_font_scale(1.3)
  tn.draw()
  let w13 = tn.words().filter(fn(x) { x.5 > 0.5 })
  let g13 = w13.filter(fn(x) { x.0 == "Gemini" })[0]
  let f13 = w13.filter(fn(x) { x.0 == "5h" })[0]
  assert_true(f13.2 > g13.2, msg="1.3x should stack pool title above capsules: g=\{g13.2} f=\{f13.2}")
}

///|
test "nav_quota_room_node matches nav_quota_line_node and per-chip widths" {
  let flat_q = Json::object({
    "state": "ok",
    "windows": [
      { "label": "5 小时", "mark": "5H", "left": 100.0, "level": "ok" },
      { "label": "每周", "mark": "W", "left": 100.0, "level": "ok" },
      { "label": "每周 · Fable", "mark": "Fable", "scope": "Fable", "left": 0.0, "level": "red", "refillShort": "42m" },
    ],
  })
  let pooled_q = Json::object({
    "state": "ok",
    "windows": [
      { "label": "5 小时 · Gemini", "mark": "Gemini 5H", "scope": "gemini", "left": 56.0, "level": "ok" },
      { "label": "每周 · Gemini", "mark": "Gemini W", "scope": "gemini", "left": 100.0, "level": "ok" },
      { "label": "5 小时 · Claude / GPT", "mark": "Claude / GPT 5H", "scope": "3p", "left": 100.0, "level": "ok" },
      { "label": "每周 · Claude / GPT", "mark": "Claude / GPT W", "scope": "3p", "left": 79.0, "level": "ok" },
    ],
  })
  let bad_q = Json::object({
    "state": "error",
    "windows": [{ "label": "5 小时", "mark": "5H", "left": 50.0, "level": "ok" }],
  })
  let t = @ui.Tester::new(fn(c) { begin(c) |> ignore }, w=640.0, h=200.0, platform=0)
  let mut none_res : (Double, Array[Double]) = (-1.0, [])
  let mut bad_res : (Double, Array[Double]) = (-1.0, [])
  let results : Array[((Double, Array[Double]), Double, Array[Double])] = []
  @ui.set_view_app(fn(root) {
    @ui.set_tree_theme(ui_theme_now)
    none_res = nav_quota_room_node(root, None)
    bad_res = nav_quota_room_node(root, Some(bad_q))
    let chip = nav_quota_chip_w(root)
    for q in [flat_q, pooled_q] {
      let room = nav_quota_room_node(root, Some(q))
      let line_w = nav_quota_line_node(root, Some(q))
      let ws = match chip_field(Some(q), "windows") {
        Some(Array(a)) => a
        _ => []
      }
      let expect = ws.map(fn(w) { chip(quota_mark(Some(w)), quota_figure(Some(w)), quota_is_refill(Some(w))) })
      results.push((room, line_w, expect))
    }
  })
  t.draw()
  assert_eq(none_res, (0.0, []))
  assert_eq(bad_res, (0.0, []))
  assert_eq(results.length(), 2)
  for item in results {
    let ((line_w, widths), expect_line, expect_widths) = item
    assert_eq(line_w, expect_line)
    assert_eq(widths, expect_widths)
  }
}
