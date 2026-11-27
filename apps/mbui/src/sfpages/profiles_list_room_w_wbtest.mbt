// High-density verification for profiles_list_node:
// - 390x844 phone screen fits >= 7 accounts in compact grouped cards without scrolling
// - Fixed-column quota slots align vertically across rows of the same provider
// - Multi-pool accounts (e.g. Gemini + Claude / GPT) render compactly without capsules
// - 320pt narrow width & 1.3x font scale pass `t.audit()` with 0 faults
// - No `" · "` middot concatenation in rendered metadata
// - Complete screen-reader `says()` for quota slots
// - Adjacent hairline separators fade smoothly on mouse hover and touch press-and-hold

///|
fn pl_test_quota_account(
  key : String,
  group : String,
  group_title : String,
  name : String,
  plan : String,
  w5h : Double,
  ww : Double,
) -> Json {
  {
    "key": Json::string(key),
    "station": "st1",
    "group": Json::string(group),
    "groupTitle": Json::string(group_title),
    "title": Json::string(name),
    "usable": true,
    "profile": {
      "id": Json::string(key),
      "name": Json::string(name),
      "runtime": Json::string(group),
      "planText": Json::string(plan),
      "access": { "kind": "subscription" },
      "quota": {
        "state": "ok",
        "windows": [
          { "label": "5 小时", "mark": "5H", "left": Json::number(w5h), "level": "ok", "refills": "2 小时后重置" },
          { "label": "每周", "mark": "W", "left": Json::number(ww), "level": if ww <= 15.0 { "amber" } else { "ok" }, "refills": "周一重置" },
        ],
      },
    },
  }
}

///|
fn pl_test_pooled_account(key : String, name : String) -> Json {
  {
    "key": Json::string(key),
    "station": "st1",
    "group": "antigravity",
    "groupTitle": "Antigravity",
    "title": Json::string(name),
    "usable": true,
    "profile": {
      "id": Json::string(key),
      "name": Json::string(name),
      "runtime": "antigravity",
      "planText": "Ultra",
      "access": { "kind": "subscription" },
      "quota": {
        "state": "ok",
        "windows": [
          { "label": "5 小时 · Gemini", "mark": "Gemini 5H", "scope": "gemini", "left": 88.0, "level": "ok", "refills": "3 小时后重置" },
          { "label": "每周 · Gemini", "mark": "Gemini W", "scope": "gemini", "left": 74.0, "level": "ok", "refills": "周一重置" },
          { "label": "5 小时 · Claude / GPT", "mark": "Claude / GPT 5H", "scope": "claude", "left": 42.0, "level": "ok", "refills": "1 小时后重置" },
          { "label": "每周 · Claude / GPT", "mark": "Claude / GPT W", "scope": "claude", "left": 10.0, "level": "amber", "refills": "周一重置" },
        ],
      },
    },
  }
}

///|
fn pl_test_key_account(key : String, name : String) -> Json {
  {
    "key": Json::string(key),
    "station": "st1",
    "group": "key",
    "groupTitle": "API Keys",
    "title": Json::string(name),
    "usable": true,
    "profile": {
      "id": Json::string(key),
      "name": Json::string(name),
      "runtime": "claude",
      "kindText": "API Key",
      "usesText": "Claude Code",
      "access": { "kind": "key" },
    },
  }
}

///|
fn pl_test_credits_account(key : String, name : String) -> Json {
  {
    "key": Json::string(key),
    "station": "st1",
    "group": "openai",
    "groupTitle": "OpenAI",
    "title": Json::string(name),
    "usable": true,
    "profile": {
      "id": Json::string(key),
      "name": Json::string(name),
      "runtime": "codex",
      "planText": "Team",
      "access": { "kind": "subscription" },
      "quota": {
        "state": "ok",
        "creditsText": "$42.50",
        "detail": "本月余额",
      },
    },
  }
}

///|
fn pl_open_tester(items : Array[Json], w~ : Double, h~ : Double, platform~ : Int, words_scale? : Double = 1.0) -> @ui.Tester {
  @sfbase.reset()
  reset()
  @settings.reset()
  @sf.presenters_reset()
  @sf.set_words(@sfbase.fill)
  let ws : Workspace = { id: "ws-pl-compact", name: "W", emoji: "", icon: "", email: "" }
  let src = @sfbase.made_source(
    topic=fn(name, _) {
      match name {
        "profiles" => Some({ "items": Json::array(items), "manages": true })
        "stations" => Some(Json::array([]))
        _ => None
      }
    },
  )
  let core = @sfbase.settings_core(src, ws)
  let here = fn() { @settings.here_of(core, ws.id, ws.name) }
  let frame = fn() -> PageFrame { { back: None, top: 0.0, foot: 0.0, named: false } }
  let t = @ui.Tester::new(fn(ctx) { @sf.begin(ctx) |> ignore }, w~, h~, platform~)
  t.set_font_scale(words_scale)
  @ui.set_view_app(fn(root) {
    @ui.set_tree_theme(@sf.ui_theme_now)
    root.box(fn(p) {
      p.width(Is(Some(w))).height(Is(Some(h))) |> ignore
      profiles_list_node(p, core, here, "", on_back=fn() {  }, frame~, width=fn() { w })
    })
    |> ignore
  })
  t.draw()
  t
}

///|
test "profiles_list: 390x844 fits >= 7 accounts, aligns quota columns, compacts multi-pool, has no middot, preserves a11y says" {
  let items : Array[Json] = [
    pl_test_quota_account("c1", "claude", "Claude", "Claude Alpha", "Max", 82.0, 65.0),
    pl_test_quota_account("c2", "claude", "Claude", "Claude Beta", "Pro", 91.0, 14.0),
    pl_test_quota_account("c3", "claude", "Claude", "Claude Gamma", "Max", 45.0, 50.0),
    pl_test_quota_account("c4", "claude", "Claude", "Claude Delta", "Pro", 70.0, 80.0),
    pl_test_quota_account("c5", "claude", "Claude", "Claude Epsilon", "Max", 60.0, 72.0),
    pl_test_credits_account("o1", "OpenAI Credits"),
    pl_test_key_account("k1", "Anthropic Key"),
    pl_test_pooled_account("a1", "Antigravity Pool"),
  ]
  let t = pl_open_tester(items, w=390.0, h=844.0, platform=2)
  assert_eq(t.audit(), [], msg="390x844 audit failed")

  // >= 7 accounts visible on first screen without scrolling
  let names = ["Claude Alpha", "Claude Beta", "Claude Gamma", "Claude Delta", "Claude Epsilon", "OpenAI Credits", "Anthropic Key"]
  let mut visible = 0
  for name in names {
    match t.find(name) {
      Some((_, y)) if y < 800.0 => visible += 1
      _ => ()
    }
  }
  assert_true(visible >= 7, msg="expected >= 7 accounts visible on 390x844, got \{visible}")

  // Fixed-column alignment: `5h` and `周` micro-capsule centers align vertically across rows of the same provider
  let w5h_cx = pl_slot_centers(t, "5h")
  let ww_cx = pl_slot_centers(t, "周")
  assert_true(w5h_cx.length() >= 5, msg="expected >= 5 `5h` marks, got \{w5h_cx.length()}")
  assert_true(ww_cx.length() >= 5, msg="expected >= 5 `周` marks, got \{ww_cx.length()}")
  for i in 1..<5 {
    assert_true((w5h_cx[i] - w5h_cx[0]).abs() <= 0.5, msg="5h column misaligned: \{Repr(w5h_cx)}")
    assert_true((ww_cx[i] - ww_cx[0]).abs() <= 0.5, msg="周 column misaligned: \{Repr(ww_cx)}")
  }

  // No `" · "` middot concatenation in any rendered word
  let middots = t.words().filter(fn(w) { w.0.contains(" · ") }).map(fn(w) { w.0 })
  assert_eq(middots, [], msg="unexpected middot concatenation: \{Repr(middots)}")

  // Complete screen-reader `says()` for quota slots
  t.set_a11y(true)
  t.draw()
  let a11y = t.a11y_said()
  assert_true(a11y.contains("5 小时") && a11y.contains("82%"), msg="expected full quota_said in a11y tree")

  // Multi-pool compact layout (check on a focused list so it is in view)
  let tp = pl_open_tester([pl_test_pooled_account("a1", "Antigravity Pool")], w=390.0, h=844.0, platform=2)
  assert_eq(tp.audit(), [], msg="multi-pool 390x844 audit failed")
  assert_true(tp.find("Gemini") is Some(_), msg="pool label Gemini shown")
  assert_true(tp.find("Claude / GPT") is Some(_), msg="pool label Claude / GPT shown")
  let p_5h = tp.words().filter(fn(w) { w.0 == "5h" })
  assert_eq(p_5h.length(), 2, msg="expected 2 pool 5h slots")
  assert_true((p_5h[0].1 - p_5h[1].1).abs() <= 0.5, msg="pool 5h slots aligned: \{Repr(p_5h)}")
}

///|
test "profiles_list: 320pt narrow and 1.3x font scale pass audit with 0 faults" {
  let items : Array[Json] = [
    pl_test_quota_account("c1", "claude", "Claude", "Very Long Account Name That Truncates Cleanly", "Max", 82.0, 65.0),
    pl_test_pooled_account("a1", "Antigravity Pool"),
    pl_test_credits_account("o1", "OpenAI Credits"),
    pl_test_key_account("k1", "Anthropic Key"),
  ]
  let t320 = pl_open_tester(items, w=320.0, h=640.0, platform=2)
  assert_eq(t320.audit(), [], msg="320pt audit failed")
  let t13 = pl_open_tester(items, w=390.0, h=844.0, platform=2, words_scale=1.3)
  assert_eq(t13.audit(), [], msg="390pt 1.3x font scale audit failed")
}

///|
test "profiles_list: grouped card hairlines fade smoothly on mouse hover and touch press-and-hold" {
  let items : Array[Json] = [
    pl_test_quota_account("c1", "claude", "Claude", "Row-A", "Max", 82.0, 65.0),
    pl_test_quota_account("c2", "claude", "Claude", "Row-B", "Pro", 74.0, 50.0),
    pl_test_quota_account("c3", "claude", "Claude", "Row-C", "Max", 61.0, 40.0),
  ]
  let rest_color = @sf.rule_color()
  let rest_alpha = (rest_color & 0xFFL).to_int()

  // Mouse hover on middle row fades both adjacent dividers (A|B and B|C)
  let tm = pl_open_tester(items, w=390.0, h=844.0, platform=0)
  let seps = sl_seps_drawn(tm)
  assert_eq(seps.length(), 2, msg="expected 2 profile group hairlines at rest, got \{seps.length()}")
  let y_ab = seps[0].0
  let y_bc = seps[1].0
  let (bx, by, bw, bh) = tm.rect_of("Row-B").unwrap()
  tm.move_to(bx + bw / 2.0, by + bh / 2.0)
  tm.run_for(@sf.dur_ms + 30.0)
  assert_eq(sl_sep_alpha_at(tm, y_ab), 0, msg="hover Row-B fades A|B")
  assert_eq(sl_sep_alpha_at(tm, y_bc), 0, msg="hover Row-B fades B|C")
  tm.move_to(4.0, 4.0)
  tm.run_for(@sf.dur_ms + 30.0)
  assert_eq(sl_sep_alpha_at(tm, y_ab), rest_alpha, msg="leaving Row-B restores A|B")
  assert_eq(sl_sep_alpha_at(tm, y_bc), rest_alpha, msg="leaving Row-B restores B|C")

  // Touch press-and-hold on middle row fades both adjacent dividers and restores on release
  let tf = pl_open_tester(items, w=390.0, h=844.0, platform=2)
  let fseps = sl_seps_drawn(tf)
  assert_eq(fseps.length(), 2, msg="touch expected 2 profile hairlines")
  let (fbx, fby, fbw, fbh) = tf.rect_of("Row-B").unwrap()
  tf.press_at(fbx + fbw / 2.0, fby + fbh / 2.0)
  tf.run_for(@sf.dur_ms + 30.0)
  assert_eq(sl_sep_alpha_at(tf, fseps[0].0), 0, msg="touch hold Row-B fades A|B")
  assert_eq(sl_sep_alpha_at(tf, fseps[1].0), 0, msg="touch hold Row-B fades B|C")
  tf.release(4.0, 4.0)
  tf.run_for(@sf.dur_ms + 30.0)
  assert_eq(sl_sep_alpha_at(tf, fseps[0].0), rest_alpha, msg="touch release restores A|B")
  assert_eq(sl_sep_alpha_at(tf, fseps[1].0), rest_alpha, msg="touch release restores B|C")
}

///|
/// Horizontal center X of each quota micro-capsule matching `mark`: finds `mark` and its paired figure
/// on the same line (`(mark_left + fig_right) / 2.0`), which equals the equal-width capsule's center
/// under `chip_box` `align=ACenter`.
fn pl_slot_centers(t : @ui.Tester, mark : String) -> Array[Double] {
  let ws = t.words()
  let out : Array[Double] = []
  for w in ws {
    if w.0 != mark {
      continue
    }
    let mut best_right = w.1 + w.3
    let mut best_dx = 1.0e9
    for other in ws {
      if (other.2 - w.2).abs() <= 4.0 && other.1 > w.1 + w.3 - 0.5 {
        let dx = other.1 - (w.1 + w.3)
        if dx < best_dx {
          best_dx = dx
          best_right = other.1 + other.3
        }
      }
    }
    out.push((w.1 + best_right) / 2.0)
  }
  out
}

///|
test "profiles_list: missing leading 5h window aligns W and Fable columns vertically at 1.0x and 1.3x" {
  let row_full : Json = {
    "key": "ws1/s1/c-full",
    "station": "ws1/s1",
    "group": "claude",
    "groupTitle": "Claude",
    "usable": true,
    "title": "Claude Full",
    "profile": {
      "id": "c-full",
      "name": "Claude Full",
      "runtime": "claude",
      "planText": "Max",
      "access": { "kind": "subscription" },
      "quota": {
        "state": "ok",
        "windows": [
          { "label": "5 小时", "mark": "5H", "left": 100.0, "level": "ok" },
          { "label": "每周", "mark": "W", "left": 48.0, "level": "ok" },
          { "label": "Fable", "mark": "Fable", "left": 90.0, "level": "ok" },
        ],
      },
    },
  }
  let row_refill : Json = {
    "key": "ws1/s1/c-refill",
    "station": "ws1/s1",
    "group": "claude",
    "groupTitle": "Claude",
    "usable": true,
    "title": "Claude Refill",
    "profile": {
      "id": "c-refill",
      "name": "Claude Refill",
      "runtime": "claude",
      "planText": "Pro",
      "access": { "kind": "subscription" },
      "quota": {
        "state": "ok",
        "windows": [
          { "label": "5 小时", "mark": "5H", "left": 0.0, "refillShort": "42m", "level": "red" },
          { "label": "每周", "mark": "W", "left": 19.0, "level": "amber" },
          { "label": "Fable", "mark": "Fable", "left": 75.0, "level": "ok" },
        ],
      },
    },
  }
  let row_no_5h : Json = {
    "key": "ws1/s1/c-no5h",
    "station": "ws1/s1",
    "group": "claude",
    "groupTitle": "Claude",
    "usable": true,
    "title": "cuesurf4@proton.me",
    "profile": {
      "id": "c-no5h",
      "name": "cuesurf4@proton.me",
      "runtime": "claude",
      "planText": "Pro",
      "access": { "kind": "subscription" },
      "quota": {
        "state": "ok",
        "windows": [
          { "label": "每周", "mark": "W", "left": 0.0, "refillShort": "2d", "level": "red" },
          { "label": "Fable", "mark": "Fable", "left": 100.0, "level": "ok" },
        ],
      },
    },
  }
  let items = [row_full, row_refill, row_no_5h]
  for scale in [1.0, 1.3] {
    let t = pl_open_tester(items, w=390.0, h=844.0, platform=2, words_scale=scale)
    assert_eq(t.audit(), [], msg="missing-5h alignment audit failed at scale=\{scale}")
    let ww_cx = pl_slot_centers(t, "周")
    let fb_cx = pl_slot_centers(t, "Fable")
    assert_eq(ww_cx.length(), 3, msg="expected 3 周 marks at scale=\{scale}, got \{Repr(ww_cx)}")
    assert_eq(fb_cx.length(), 3, msg="expected 3 Fable marks at scale=\{scale}, got \{Repr(fb_cx)}")
    assert_true((ww_cx[2] - ww_cx[0]).abs() <= 0.5, msg="周 center misaligned for missing-5h row at scale=\{scale}: \{Repr(ww_cx)}")
    assert_true((ww_cx[1] - ww_cx[0]).abs() <= 0.5, msg="周 center misaligned for refill row at scale=\{scale}: \{Repr(ww_cx)}")
    assert_true((fb_cx[2] - fb_cx[0]).abs() <= 0.5, msg="Fable center misaligned for missing-5h row at scale=\{scale}: \{Repr(fb_cx)}")
    assert_true(t.find("42m") is Some(_), msg="refill 42m shown at scale=\{scale}")
    assert_true(t.find("100%") is Some(_), msg="100% shown at scale=\{scale}")
  }
}

///|
test "profiles_list: English keeps W and M short marks while Chinese renders 周 and 月" {
  let row_monthly : Json = {
    "key": "ws1/s1/c-m",
    "station": "ws1/s1",
    "group": "opencode",
    "groupTitle": "OpenCode",
    "usable": true,
    "title": "OpenCode Go",
    "profile": {
      "id": "c-m",
      "name": "OpenCode Go",
      "runtime": "opencode",
      "planText": "Go",
      "access": { "kind": "subscription" },
      "quota": {
        "state": "ok",
        "windows": [
          { "label": "5 小时", "mark": "5H", "left": 62.0, "level": "ok" },
          { "label": "每周", "mark": "W", "left": 19.0, "level": "amber" },
          { "label": "每月", "mark": "M", "left": 97.0, "level": "ok" },
        ],
      },
    },
  }
  let t = pl_open_tester([row_monthly], w=390.0, h=844.0, platform=2)
  let zh_words = t.words().map(fn(w) { w.0 })
  @sf.set_language(Some("en"))
  t.draw()
  let en_words = t.words().map(fn(w) { w.0 })
  @sf.set_language(None)
  assert_true(zh_words.contains("周") && zh_words.contains("月"), msg="expected 周 and 月 in zh, got \{Repr(zh_words)}")
  assert_true(en_words.contains("W") && en_words.contains("M"), msg="expected W and M in en, got \{Repr(en_words)}")
  assert_true(!en_words.contains("周") && !en_words.contains("月"), msg="unexpected Chinese marks in en: \{Repr(en_words)}")
}

///|
test "profiles_list: non-refill group measures compact column widths tightly and aligns vertically" {
  let items : Array[Json] = [
    pl_test_quota_account("g1", "codex", "ChatGPT", "ChatGPT A", "Pro", 82.0, 68.0),
    pl_test_quota_account("g2", "codex", "ChatGPT", "ChatGPT B", "Plus", 100.0, 94.0),
    pl_test_quota_account("g3", "codex", "ChatGPT", "ChatGPT C", "Pro", 71.0, 55.0),
  ]
  let t = pl_open_tester(items, w=390.0, h=844.0, platform=2)
  assert_eq(t.audit(), [], msg="compact non-refill group audit failed")
  let w5h_cx = pl_slot_centers(t, "5h")
  let ww_cx = pl_slot_centers(t, "周")
  assert_eq(w5h_cx.length(), 3, msg="expected 3 5h marks, got \{Repr(w5h_cx)}")
  assert_eq(ww_cx.length(), 3, msg="expected 3 周 marks, got \{Repr(ww_cx)}")
  for i in 1..<3 {
    assert_true((w5h_cx[i] - w5h_cx[0]).abs() <= 0.5, msg="5h center misaligned: \{Repr(w5h_cx)}")
    assert_true((ww_cx[i] - ww_cx[0]).abs() <= 0.5, msg="周 center misaligned: \{Repr(ww_cx)}")
  }
  let dx = ww_cx[0] - w5h_cx[0]
  assert_true(dx >= 52.0 && dx <= 78.0, msg="expected compact 5h->周 center stride in [52, 78]pt (tighter than hardcoded 88pt), got \{dx}")
}

///|
test "profiles_list: pooled group with long refill countdown and cross-account pool names aligns at 1.0x and 1.3x" {
  let acct_gemini_only : Json = {
    "key": "ws1/s1/g-only",
    "station": "ws1/s1",
    "group": "antigravity",
    "groupTitle": "Google",
    "usable": true,
    "title": "gemini-only@gmail.com",
    "profile": {
      "id": "g-only",
      "name": "gemini-only@gmail.com",
      "runtime": "antigravity",
      "planText": "Pro",
      "access": { "kind": "subscription" },
      "quota": {
        "state": "ok",
        "windows": [
          { "label": "5 小时 · Gemini", "mark": "Gemini 5H", "scope": "gemini", "left": 76.0, "level": "ok" },
          { "label": "每周 · Gemini", "mark": "Gemini W", "scope": "gemini", "left": 68.0, "level": "ok" },
        ],
      },
    },
  }
  let acct_long_refill : Json = {
    "key": "ws1/s1/g-both",
    "station": "ws1/s1",
    "group": "antigravity",
    "groupTitle": "Google",
    "usable": true,
    "title": "zover.v@gmail.com",
    "profile": {
      "id": "g-both",
      "name": "zover.v@gmail.com",
      "runtime": "antigravity",
      "planText": "Ultra",
      "access": { "kind": "subscription" },
      "quota": {
        "state": "ok",
        "windows": [
          { "label": "5 小时 · Gemini", "mark": "Gemini 5H", "scope": "gemini", "left": 100.0, "level": "ok" },
          { "label": "每周 · Gemini", "mark": "Gemini W", "scope": "gemini", "left": 84.0, "level": "ok" },
          { "label": "5 小时 · Claude / GPT", "mark": "Claude / GPT 5H", "scope": "claude", "left": 0.0, "refillShort": "14h21m", "level": "red" },
          { "label": "每周 · Claude / GPT", "mark": "Claude / GPT W", "scope": "claude", "left": 49.0, "level": "ok" },
        ],
      },
    },
  }
  let items = [acct_gemini_only, acct_long_refill]
  for scale in [1.0, 1.3] {
    let t = pl_open_tester(items, w=390.0, h=844.0, platform=2, words_scale=scale)
    assert_eq(t.audit(), [], msg="pooled long-refill audit failed at scale=\{scale}")
    let w5h_cx = pl_slot_centers(t, "5h")
    let ww_cx = pl_slot_centers(t, "周")
    assert_eq(w5h_cx.length(), 3, msg="expected 3 pooled 5h marks at scale=\{scale}, got \{Repr(w5h_cx)}")
    assert_eq(ww_cx.length(), 3, msg="expected 3 pooled 周 marks at scale=\{scale}, got \{Repr(ww_cx)}")
    for i in 1..<3 {
      assert_true((w5h_cx[i] - w5h_cx[0]).abs() <= 0.5, msg="pooled 5h center misaligned at scale=\{scale}: \{Repr(w5h_cx)}")
      assert_true((ww_cx[i] - ww_cx[0]).abs() <= 0.5, msg="pooled 周 center misaligned at scale=\{scale}: \{Repr(ww_cx)}")
    }
    // Narrower `5h 76%` sits centered inside the wider equal-width capsule (pushed right of `5h ↻ 14h21m`'s left edge)
    let w5h_lefts = t.words().filter(fn(w) { w.0 == "5h" }).map(fn(w) { w.1 })
    assert_true(w5h_lefts[0] > w5h_lefts[2] + 4.0, msg="expected narrower `5h 76%` centered inside equal-width capsule at scale=\{scale}: \{Repr(w5h_lefts)}")
    assert_true(t.find("14h21m") is Some(_), msg="14h21m refill shown at scale=\{scale}")
  }
}
