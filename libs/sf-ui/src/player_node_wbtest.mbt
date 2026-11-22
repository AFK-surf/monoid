// Tests for single-layer iOS 27 Liquid Glass floating surfaces in `player_node.mbt`:
// 1. Non-embedded desktop & phone video players use `ViewerDark` (`@glass.liquid_viewer_dark_glass`)
//    with outside-only `glass_control_shadow()`, zero extra solid ground fills on the glass shell,
//    and degrade cleanly to `media_dark_ground` + hairline edge under `MBUI_GLASS=solid`.
// 2. Non-embedded audio players use theme-adaptive `Floating` (`@glass.liquid_floating_glass`).
// 3. Auto-hidden / dismissed player controls emit zero hidden glass instances and zero shadows.
// 4. Failed and ended cards (`night_card_node`) use liquid glass with `glass_overlay_shadow()`.
// 5. Embedded players (`embedded == true`) emit zero liquid glass instances.

///|
fn player_glass_tester(
  narrow : Bool,
  kind : String,
  dark : Bool,
  solid : Bool,
  embedded? : Bool = false,
  pin? : @player.MediaStatus,
  list? : Array[String] = ["E1.mp4", "E2.mp4"],
) -> @ui.Tester {
  let (w, h, platform) = if narrow { (390.0, 844.0, 1) } else { (1280.0, 800.0, 0) }
  set_viewer_host(viewer_host_default())
  set_words(fn(key, args) {
    args.fold(init=test_words.get(key).unwrap_or(key), fn(said, a) { said.replace_all(old="{" + a.0 + "}", new=a.1) })
  })
  let name = if kind == "audio" { "song.m4a" } else { "E1.mp4" }
  let siblings : Array[ViewerEntry] = list.map(fn(n) { { name: n, size: 1.0, mtime: 0.0, mime: "", kind, dir: false } })
  let file = film(name, kind~)
  let t = @ui.Tester::new(fn(c) { begin(c) |> ignore }, w~, h~, dark~, platform~)
  set_dark(Some(dark))
  @ui.set_glass_solid(if solid { Some(true) } else { None })
  match pin {
    Some(s) => playing_for("k").media.pin(s)
    None => ()
  }
  @ui.set_view_app(
    fn(root) {
      root.box(fn(n) {
        n.grow(Is(1.0)) |> ignore
        let m = player_opened(n, "k", file, fn() { siblings })
        player_node(
          n,
          m,
          file,
          fn() { n.window() },
          back_label=fn() { "影片" },
          on_back=fn() {  },
          still=fn() { "" },
          flying=fn() { false },
          going=fn() { false },
          move_beside=fn() { None },
          list=fn() { playlist_for(file, siblings) },
          on_go=fn(_) {  },
          embedded~,
        )
        |> ignore
      })
      |> ignore
    },
    theme=ui_theme_now,
  )
  t.draw()
  t
}

///|
fn liquid_blurs(t : @ui.Tester) -> Array[Double] {
  t.drawn_instances().filter(fn(a) { a.length() > 22 && a[5] == 6.0 }).map(fn(a) { a[7] })
}

///|
test "player_node video controls use ViewerDark liquid glass with outside shadow and degrade cleanly under MBUI_GLASS=solid" {
  for narrow in [false, true] {
    for dark in [false, true] {
      let t = player_glass_tester(narrow, "video", dark, false)
      let glass = t.drawn_glass()
      let liquid = glass.filter(fn(g) { g.4 == 6 })
      // Phone has top 48pt capsule + bottom card (2); desktop has viewer_bar pills + bottom control bar (>= 2).
      let expected_min = if narrow { 2 } else { 2 }
      assert_true(liquid.length() >= expected_min, msg="narrow=\{narrow} dark=\{dark} liquid=\{liquid.length()}")
      assert_true(has_outside_shadow(t), msg="narrow=\{narrow} dark=\{dark} outside shadow")
      // Every bottom/top player glass instance over video uses ViewerDark (blur = 4.0).
      let blurs = liquid_blurs(t)
      assert_true(blurs.iter().all(fn(b) { (b - 4.0).abs() < 0.01 }), msg="narrow=\{narrow} dark=\{dark} blurs=\{Repr(blurs)}")
      // Solid fallback: 0 liquid glass instances, solid media_dark_ground drawn.
      let ts = player_glass_tester(narrow, "video", dark, true)
      assert_eq(ts.drawn_glass().length(), 0, msg="narrow=\{narrow} dark=\{dark} solid glass count")
      assert_true(
        ts.drawn_rects().iter().any(fn(r) { r.4 == media_dark_ground }),
        msg="narrow=\{narrow} dark=\{dark} solid ground fallback",
      )
    }
  }
  @ui.set_glass_solid(None)
  set_dark(None)
}

///|
test "player_node audio controls use theme-adaptive Floating liquid glass" {
  for narrow in [false, true] {
    for dark in [false, true] {
      let t = player_glass_tester(narrow, "audio", dark, false)
      let blurs = liquid_blurs(t)
      // Floating liquid glass uses blur = 2.1 (distinct from ViewerDark's 4.0).
      assert_true(blurs.iter().any(fn(b) { (b - 2.1).abs() < 0.01 }), msg="narrow=\{narrow} dark=\{dark} audio blurs=\{Repr(blurs)}")
      assert_true(has_outside_shadow(t), msg="narrow=\{narrow} dark=\{dark} audio outside shadow")
    }
  }
  @ui.set_glass_solid(None)
  set_dark(None)
}

///|
test "player_node embedded mode emits zero liquid glass instances" {
  for narrow in [false, true] {
    for kind in ["video", "audio"] {
      let t = player_glass_tester(narrow, kind, false, false, embedded=true)
      assert_eq(t.drawn_glass().length(), 0, msg="narrow=\{narrow} kind=\{kind} embedded glass count")
    }
  }
  @ui.set_glass_solid(None)
  set_dark(None)
}

///|
test "player_node hidden controls emit zero hidden glass instances" {
  // Phone playing: tap stage once to hide controls, wait past fade-out.
  let t = player_glass_tester(true, "video", true, false, pin=pinned(2000.0))
  assert_eq(t.drawn_glass().length(), 2, msg="phone visible controls glass count")
  t.tap(195.0, 422.0)
  t.run_for(playing_for("k").media.times().1 + 600.0)
  assert_eq(t.drawn_glass().length(), 0, msg="phone hidden controls must emit zero glass")
  assert_eq(outside_shadows(t).length(), 0, msg="phone hidden controls must emit zero shadows")
  // Desktop playing: click stage once to hide controls, wait past fade-out.
  let td = player_glass_tester(false, "video", true, false, pin=pinned(2000.0))
  let before_glass = td.drawn_glass().length()
  assert_true(before_glass >= 2, msg="desktop visible controls glass count")
  td.tap(640.0, 400.0)
  td.run_for(playing_for("k").media.times().1 + 600.0)
  // Bottom control bar is hidden; remaining glass count drops strictly.
  assert_true(td.drawn_glass().length() < before_glass, msg="desktop hidden bottom bar drops glass count")
  @ui.set_glass_solid(None)
  set_dark(None)
}

///|
test "player_node failed and ended cards use liquid glass with overlay shadow" {
  let failed_pin : @player.MediaStatus = { ..pinned(1000.0), state: -1, playing: false }
  let tf = player_glass_tester(true, "video", true, false, pin=failed_pin)
  assert_true(tf.drawn_glass().length() >= 3, msg="phone failed card adds glass surface: \{tf.drawn_glass().length()}")
  assert_true(outside_shadows(tf).iter().any(fn(s) { s == glass_overlay_shadow() }), msg="failed card uses glass_overlay_shadow")

  let te = player_glass_tester(true, "video", true, false, pin=pinned(10000.0, ended=true))
  assert_true(te.drawn_glass().length() >= 3, msg="phone ended card adds glass surface: \{te.drawn_glass().length()}")
  assert_true(outside_shadows(te).iter().any(fn(s) { s == glass_overlay_shadow() }), msg="ended card uses glass_overlay_shadow")

  @ui.set_glass_solid(None)
  set_dark(None)
}
