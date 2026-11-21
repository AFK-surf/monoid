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
