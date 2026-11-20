// An allowance's chips (quota_chip.mbt): what they say short of room.

///|
/// OpenCode Go's three windows, worded (a profile's row on a phone), in a line `room` wide.
fn worded_tester(room : Double) -> @ui.Tester {
  let q = Json::object({
    "state": "ok",
    "windows": [
      { "label": "5 小时", "mark": "5H", "left": 62.0, "level": "ok" },
      { "label": "每周", "mark": "W", "left": 95.0, "level": "ok" },
      { "label": "每月", "mark": "M", "left": 97.0, "level": "ok" },
    ],
  })
  let t = @ui.Tester::new(
    fn(c) {
      begin(c) |> ignore
      c.with_theme(ui_theme(), fn() { c.box(w=Px(room), fn() { quota_chips(c, Some(q), worded=true) }) |> ignore })
    },
    w=640.0,
    h=200.0,
    platform=2,
  )
  t.draw()
  t
}

///|
test "an allowance's windows in words: one way for them all, the longest that fits, each chip whole" {
  // (a phone's row: 326 was what cut all three to 5 小时剩…, 每周剩余…, 每月剩余…, 2026-10-31)
  let ways = [
    ["5h", "62%", "每周", "95%", "每月", "97%"],
    ["5h", "62%", "W", "95%", "M", "97%"],
  ]
  let said = []
  for room in [600.0, 326.0, 240.0, 170.0] {
    let t = worded_tester(room)
    // (the words drawn: the way the line says it, the others laid out nowhere)
    let shown = t.words().filter(fn(w) { w.5 > 0.5 }).map(fn(w) { w.0 })
    let way = ways.search(shown)
    assert_true(way is Some(_), msg="\{room}: \{Repr(shown)}")
    assert_eq(t.squeeze_faults(), [], msg=room.to_string())
    said.push(way.unwrap())
  }
  // as much as fits: wide, every word of it; narrow, the marks
  assert_eq(said[0], 0)
  assert_eq(said[3], 1)
}

///|
/// A Claude subscription's windows with its models' own weeks (present.ts: each its `scope`), in a line `room` wide:
/// worded (a profile's row), or by their marks on a line of their own (`lines`: a station's account).
fn own_tester(room : Double, worded : Bool) -> @ui.Tester {
  let q = Json::object({
    "state": "ok",
    "windows": [
      { "label": "5 小时", "mark": "5H", "left": 62.0, "level": "ok" },
      { "label": "每周", "mark": "W", "left": 19.0, "level": "amber" },
      { "label": "每周 · Fable", "mark": "Fable", "scope": "Fable", "left": 46.0, "level": "ok" },
      { "label": "每周 · Opus", "mark": "Opus", "scope": "Opus", "left": 8.0, "level": "red" },
      { "label": "每周 · Sonnet", "mark": "Sonnet", "scope": "Sonnet", "left": 100.0, "level": "ok" },
    ],
  })
  set_words(fn(key, args) {
    let said = if key == "web-main.quota.figure" { "剩 {left}%" } else { key }
    args.fold(init=said, fn(said, a) { said.replace_all(old="{" + a.0 + "}", new=a.1) })
  })
  let t = @ui.Tester::new(
    fn(c) {
      begin(c) |> ignore
      c.with_theme(ui_theme(), fn() {
        c.box(w=Px(room), fn() { quota_chips(c, Some(q), worded~, lines=!worded, small=!worded) }) |> ignore
      })
    },
    w=900.0,
    h=300.0,
    platform=2,
  )
  t.draw()
  t
}

///|
test "an account's windows and its models' own, five: where no line holds them the account's a line and its models' under it, every chip whole" {
  // (a phone's row cut all five to 5H …, W 1…, … …; a station's account's the same, 2026-11-10)
  for worded in [true, false] {
    let mut lined = 0
    for room in [900.0, 420.0, 342.0, 300.0, 240.0, 180.0, 130.0] {
      let t = own_tester(room, worded)
      let shown = t.words().filter(fn(w) { w.5 > 0.5 })
      // The long or short label appears exactly once.
      let at = fn(words : Array[String]) {
        match shown.filter(fn(w) { words.contains(w.0) }) {
          [w] => w
          found => @halt.saying("\{room}: one of \{Repr(words)}: \{Repr(found)} in \{Repr(shown.map(fn(w) { w.0 }))}")
        }
      }
      // every window said once, whole, within the line's room
      let week = at(["每周", "W"])
      let fable = at(["每周 Fable", "Fable"])
      let sonnet = at(["每周 Sonnet", "Sonnet"])
      assert_eq(t.squeeze_faults(), [], msg="\{worded} \{room}")
      assert_true(shown.iter().all(fn(w) { w.1 + w.3 <= room + 0.01 }), msg="\{worded} \{room}: past the line's end: \{Repr(shown)}")
      if fable.2 > week.2 {
        // (in lines: its models' own by the model, under the account's; the account's by their names where worded)
        lined += 1
        assert_eq([fable.0, sonnet.0], ["Fable", "Sonnet"], msg="\{worded} \{room}")
        assert_true(week.0.has_prefix(if worded { "每周" } else { "W" }), msg="\{worded} \{room}: \{week.0}")
        assert_true(sonnet.2 >= fable.2)
      } else {
        assert_true(sonnet.2 == week.2, msg="\{worded} \{room}: one line")
      }
    }
    assert_true(lined >= 2 && lined < 7, msg="\{worded}: in a line where it has the room, in lines where not: \{lined}")
  }
  set_words(fn(key, _) { key })
}

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
  for nav in [false, true] {
    let t = if nav {
      nav_quota_tester(q, 224.0, 200.0)
    } else {
      let t = @ui.Tester::new(
        fn(c) {
          begin(c) |> ignore
          c.with_theme(ui_theme(), fn() {
            c.box(w=Px(224.0), fn() { quota_chips(c, Some(q), lines=true, small=true) }) |> ignore
          })
        },
        w=640.0,
        h=200.0,
        platform=0,
      )
      t.draw()
      t
    }
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
  }
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
  for nav in [false, true] {
    let pt = if nav {
      nav_quota_tester(pro_q, 224.0, 240.0)
    } else {
      let pt = @ui.Tester::new(
        fn(c) {
          begin(c) |> ignore
          c.with_theme(ui_theme(), fn() {
            c.box(w=Px(224.0), fn() { quota_chips(c, Some(pro_q), lines=true, small=true) }) |> ignore
          })
        },
        w=640.0,
        h=240.0,
        platform=0,
      )
      pt.draw()
      pt
    }
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
      let t = @ui.Tester::new(
        fn(c) {
          begin(c) |> ignore
          c.with_theme(ui_theme(), fn() {
            c.box(dir=@ui.Dir::Column, gap=8.0, fn() {
              for i, item in cases {
                let (mark, words, small, label_muted, refill) = item
                c.box(dir=@ui.Dir::Row, name="qchip-\{i}", fn() {
                  fill_chip(c, if refill { 0 } else { 48 }, if refill { "red" } else { "ok" }, mark, words, small~, label_muted~, refill~)
                })
                |> ignore
              }
            })
            |> ignore
          })
        },
        w=640.0,
        h=300.0,
        platform~,
        dark~,
      )
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
