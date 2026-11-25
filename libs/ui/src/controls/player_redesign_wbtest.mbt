// Wave 27 · Track V deterministic tests: full-bleed stage, per-gesture input dispatch,
// desktop clicks as taps (alone: controls; two: play/pause, back, on), controls never fading by themselves, subtitle laid==0 offset,
// touch AlongTime 3-gear VFR frame scrubbing & safe second-finger handoff, and Esc priority.

///|
/// A long rest of the hand: the controls never fade by themselves however long it is.
let long_rest_ms : Double = 10000.0

///|
/// Its controls hidden by a click or tap alone at (`x`, `y`), gone once a double tap's time and their fade have passed.
fn hide_by_tap(t : @ui.Tester, x : Double, y : Double) -> Unit {
  t.tap(x, y)
  t.run_for(@ui.double_tap_ms + @player.media_sleep_ms + 10.0)
}

///|
fn count_controls(t : @ui.Tester, op : Int, value? : String = "") -> Int {
  t
  .views()
  .filter(fn(s) {
    if !s.has_prefix("control ") {
      return false
    }
    if value == "" {
      let w = s.split(" ").to_array()
      w.length() > 2 && w[2] == op.to_string()
    } else {
      s.contains(" \{op} " + value)
    }
  })
  .length()
}

///|
fn count_play_pause(t : @ui.Tester) -> Int {
  t
  .views()
  .filter(fn(s) {
    let w = s.split(" ").to_array()
    w.length() > 2 && w[0] == "control" && (w[2] == "1" || w[2] == "2")
  })
  .length()
}

///|
fn vfr_frames(t : @ui.Tester, playing? : Bool = false) -> Unit {
  t.set_player(1, position=33.0, duration=10000.0, playing~)
  t.view_said("{\"view\":{\"view\":1,\"what\":1,\"text\":\"0,33,120,140\"}}") |> ignore
}

///|
test "wave27 V1/V3: ready static video passes assert_idle() with controls visible; Opening phase stays locked" {
  // Ready, paused static fixture: nothing pending, so assert_idle() passes immediately with controls visible.
  let t = player_tester(false, "a.mp4", [], [], [], pin={ ..pinned(2000.0), playing: false })
  t.host_says_finger(Some(false))
  t.draw()
  t.assert_idle()
  assert_true(t.query(Slider, label="web-pages.drive.player.position") is Some(_), msg="controls visible at rest")
  // Opening phase (state == 0): locked, a click alone does not hide them.
  let to = player_tester(false, "a.mp4", [], [], [], pin={ ..pinned(0.0), state: 0, playing: false })
  to.host_says_finger(Some(false))
  to.draw()
  hide_by_tap(to, 640.0, 400.0)
  assert_true(to.query(Slider, label="web-pages.drive.player.position") is Some(_), msg="Opening keeps controls visible")
}

///|
test "wave27 V3: controls never fade by themselves, Playing or Paused, mouse or touch, nor as the pointer leaves" {
  let sleep_ms = @player.media_sleep_ms
  for narrow in [true, false] {
    for is_playing in [true, false] {
      let t = player_tester(narrow, "a.mp4", [], [], [], pin={ ..pinned(2000.0), playing: is_playing })
      if !narrow {
        t.host_says_finger(Some(false))
      }
      t.draw()
      t.assert_idle()
      t.run_for(long_rest_ms)
      assert_true(
        t.query(Slider, label="web-pages.drive.player.position") is Some(_),
        msg="narrow=\{narrow} playing=\{is_playing}: still shown after a long rest",
      )
    }
  }
  // Pointer leaving the window: they stay
  let tl = player_tester(false, "a.mp4", [], [], [], pin=pinned(2000.0))
  tl.host_says_finger(Some(false))
  tl.draw()
  tl.move_to(640.0, 400.0)
  tl.draw()
  tl.move_to(-10.0, -10.0)
  tl.run_for(sleep_ms + 1.0)
  assert_true(tl.query(Slider, label="web-pages.drive.player.position") is Some(_), msg="pointer leaving keeps them")
}

///|
test "wave27 V3: chrome_locked keeps controls a click alone would hide, and they stay once it is released" {
  // 1. Tab focus in bottom bar holds them; leaving focus (to an outside button) leaves them shown
  set_viewer_host(viewer_host_default())
  set_words(fn(key, args) {
    args.fold(init=test_words.get(key).unwrap_or(key), fn(said, a) { said.replace_all(old="{" + a.0 + "}", new=a.1) })
  })
  let file_tab = film("a.mp4")
  let t = @ui.Tester::new(fn(c) { begin(c) |> ignore }, w=1280.0, h=800.0, platform=0)
  playing_for("k").media.pin(pinned(2000.0))
  @ui.set_view_app(fn(root) {
    root.box(fn(n) {
      n.grow(Is(1.0)) |> ignore
      let m = player_opened(n, "k", file_tab, fn() { [] })
      player_node(
        n,
        m,
        file_tab,
        fn() { n.window() },
        back_label=fn() { "影片" },
        on_back=fn() {  },
        still=fn() { "" },
        flying=fn() { false },
        going=fn() { false },
        move_beside=fn() { None },
      )
      |> ignore
      n.box(fn(out) {
        out.over(Is(true)).padding(Is((16.0, 400.0, 0.0, 0.0))) |> ignore
        out.box(fn(b) {
          b.width(Is(Some(80.0))).height(Is(Some(40.0))) |> ignore
          button_node(b, fn() { "外按钮" }, fn() {  }) |> ignore
        })
        |> ignore
      })
      |> ignore
    })
    |> ignore
  })
  t.host_says_finger(Some(false))
  t.draw()
  let mut focused_tl = false
  for _ in 0..<25 {
    t.tab()
    if t.focused().map(fn(s) { s.label }) == Some("web-pages.drive.player.position") {
      focused_tl = true
      break
    }
  }
  assert_true(focused_tl, msg="Tab reached timeline slider")
  t.run_for(long_rest_ms)
  assert_true(t.query(Slider, label="web-pages.drive.player.position") is Some(_), msg="bar_focused locks chrome")
  // Tab focus out of the bar to the outside button (pure unlock without clicking stage)
  let mut focused_out = false
  for _ in 0..<25 {
    t.tab()
    if t.focused().map(fn(s) { s.label }) == Some("外按钮") {
      focused_out = true
      break
    }
  }
  assert_true(focused_out, msg="Tab moved focus out of controls bar")
  t.draw()
  // Unlocked: still shown after a long rest
  t.run_for(long_rest_ms)
  assert_true(
    t.query(Slider, label="web-pages.drive.player.position") is Some(_),
    msg="unlocked: still shown after a long rest",
  )
  // 2. screen_reader_on, Buffering, Failed, Ended, near_top, near_foot, rates, listing, audio all lock chrome
  let ta = player_tester(false, "a.mp4", [], [], [], pin=pinned(2000.0))
  ta.host_says_finger(Some(false))
  ta.set_screen_reader(true)
  ta.draw()
  hide_by_tap(ta, 640.0, 400.0)
  assert_true(ta.query(Slider, label="web-pages.drive.player.position") is Some(_), msg="screen_reader_on locks chrome")
  for pin_case in [
    { ..pinned(2000.0), buffering: true },
    { ..pinned(2000.0), state: -1, playing: false },
    pinned(10000.0, ended=true),
  ] {
    let tp = player_tester(false, "a.mp4", [], [], [], pin=pin_case)
    tp.host_says_finger(Some(false))
    tp.draw()
    // (a stall locks only once it has waited)
    tp.run_for(long_rest_ms)
    hide_by_tap(tp, 640.0, 400.0)
    assert_true(tp.query(Slider, label="web-pages.drive.player.position") is Some(_), msg="phase lock holds chrome")
  }
  // near_top & near_foot
  let th = player_tester(false, "a.mp4", [], [], [], pin=pinned(2000.0))
  th.host_says_finger(Some(false))
  th.draw()
  th.move_to(640.0, 20.0)
  th.run_for(long_rest_ms)
  assert_true(th.query(Slider, label="web-pages.drive.player.position") is Some(_), msg="near_top locks chrome")
  th.move_to(640.0, 760.0)
  th.run_for(long_rest_ms)
  assert_true(th.query(Slider, label="web-pages.drive.player.position") is Some(_), msg="near_foot locks chrome")
  // rates menu open (modal menu covers slider in a11y tree; verify controls time text + menu stay visible, and closing menu leaves controls visible)
  let tm = player_tester(false, "a.mp4", [], [], [], keyed=true, pin=pinned(2000.0))
  tm.host_says_finger(Some(false))
  tm.draw()
  tm.click(Button, label="web-pages.drive.player.rate")
  tm.run_for(long_rest_ms)
  assert_true(speeds_open() && tm.find("0:02 / 0:10") is Some(_), msg="rates menu locks chrome")
  tm.key(@ui.key_escape)
  tm.draw()
  assert_true(tm.query(Slider, label="web-pages.drive.player.position") is Some(_), msg="controls still visible after closing rates menu")
  // listing open
  let tl = player_tester(false, "E1.mp4", ["E1.mp4", "E2.mp4"], [], [], pin=pinned(2000.0))
  tl.host_says_finger(Some(false))
  tl.draw()
  tl.click(Button, label="web-pages.drive.player.list")
  tl.run_for(long_rest_ms)
  assert_true(tl.query(Slider, label="web-pages.drive.player.position") is Some(_), msg="listing locks chrome")
  // bottom bar timeline drag (scrubbing_ui) locks chrome
  let ts = player_tester(false, "a.mp4", [], [], [], pin=pinned(2000.0))
  ts.host_says_finger(Some(false))
  ts.draw()
  let sl = ts.get(Slider, label="web-pages.drive.player.position").rect
  ts.press_at(sl.0 + sl.2 * 0.4, sl.1 + sl.3 / 2.0)
  ts.run_for(long_rest_ms)
  assert_true(ts.query(Slider, label="web-pages.drive.player.position") is Some(_), msg="scrubbing_ui locks chrome")
  ts.release(sl.0 + sl.2 * 0.4, sl.1 + sl.3 / 2.0)
  // audio stays visible
  let tau = player_tester(false, "song.mp3", [], [], [], kind="audio", pin=pinned(2000.0))
  tau.host_says_finger(Some(false))
  tau.draw()
  hide_by_tap(tau, 640.0, 400.0)
  assert_true(tau.query(Slider, label="web-pages.drive.player.position") is Some(_), msg="audio locks chrome")
}

///|
test "wave27 V3: desktop click alone shows or hides controls, a double click plays/pauses silently; Space / K silent; menu click closes menu only; Ended double click replays" {
  let sleep_ms = @player.media_sleep_ms
  let double_ms = @ui.double_tap_ms
  let t = player_tester(false, "E1.mp4", ["E1.mp4", "E2.mp4"], [], [], keyed=true)
  t.host_says_finger(Some(false))
  t.draw()
  t.set_player(1, position=2000.0, duration=10000.0, playing=true)
  t.draw()
  // Position stationary pointer on stage, then hide the controls by a click alone
  t.move_to(640.0, 400.0)
  t.draw()
  hide_by_tap(t, 640.0, 400.0)
  assert_true(t.query(Slider, label="web-pages.drive.player.position") is None, msg="controls hidden")
  // 1. A click alone while hidden: no play/pause; the controls come once a double click's time has gone with no second
  let c0 = count_play_pause(t)
  t.tap(640.0, 400.0)
  assert_eq(count_play_pause(t), c0, msg="a click alone never plays or pauses")
  t.run_for(double_ms - 1.0)
  assert_true(t.query(Slider, label="web-pages.drive.player.position") is None, msg="controls wait for a double click's time")
  t.run_for(1.0 + @player.media_wake_ms + 10.0)
  assert_true(t.query(Slider, label="web-pages.drive.player.position") is Some(_), msg="a click alone shows hidden controls")
  // ... and another alone hides them again
  t.tap(640.0, 400.0)
  t.run_for(double_ms + sleep_ms + 10.0)
  assert_eq(count_play_pause(t), c0, msg="a click alone never plays or pauses")
  assert_true(t.query(Slider, label="web-pages.drive.player.position") is None, msg="a click alone hides shown controls")
  // 2. A double click in the middle while hidden: pauses at its second, controls stay hidden, its feedback shown
  t.tap(640.0, 400.0)
  t.advance(double_ms / 4.0)
  t.tap(640.0, 400.0)
  assert_eq(count_play_pause(t), c0 + 1, msg="double click in the middle pauses")
  assert_true(t.find("android-misc.drive.player.paused") is Some(_), msg="center feedback shown")
  t.run_for(double_ms + 10.0)
  assert_true(t.query(Slider, label="web-pages.drive.player.position") is None, msg="double click does not wake controls")
  t.run_for(@player.media_note_ms)
  assert_true(t.find("android-misc.drive.player.paused") is None, msg="center feedback gone")
  // 3. Space and K while hidden: play/pause silently without waking controls
  let c1 = count_play_pause(t)
  t.key(@ui.key_space)
  assert_eq(count_play_pause(t), c1 + 1, msg="Space toggles play/pause")
  assert_true(t.query(Slider, label="web-pages.drive.player.position") is None, msg="Space does not wake hidden controls")
  t.key(@ui.key_of_char('k'))
  assert_eq(count_play_pause(t), c1 + 2, msg="K toggles play/pause")
  assert_true(t.query(Slider, label="web-pages.drive.player.position") is None, msg="K does not wake hidden controls")
  // Still hidden, then verify non-silent shortcut (J) wakes hidden controls
  assert_true(t.query(Slider, label="web-pages.drive.player.position") is None, msg="controls hidden before J")
  t.key(@ui.key_of_char('j'))
  t.draw()
  assert_true(t.query(Slider, label="web-pages.drive.player.position") is Some(_), msg="J wakes hidden controls")
  // Shift+Tab also wakes hidden controls
  hide_by_tap(t, 640.0, 400.0)
  assert_true(t.query(Slider, label="web-pages.drive.player.position") is None, msg="controls hidden before Shift+Tab")
  t.key(@ui.key_tab, mods=@ui.mod_shift_key)
  t.run_for(viewer_bar_ms + 10.0)
  assert_true(t.query(Slider, label="web-pages.drive.player.position") is Some(_), msg="Shift+Tab wakes hidden controls")
  // 4. Open listing, click stage: closes listing only (no play/pause, controls stay), and is no first of a double click
  t.click(Button, label="web-pages.drive.player.list")
  t.draw()
  let c3 = count_play_pause(t)
  t.tap(400.0, 400.0)
  assert_eq(count_play_pause(t), c3, msg="click with listing open closes listing without play/pause")
  t.advance(double_ms / 4.0)
  t.tap(640.0, 400.0)
  assert_eq(count_play_pause(t), c3, msg="the click after closing the listing is a first, not a second")
  t.advance(double_ms / 4.0)
  t.tap(640.0, 400.0)
  assert_eq(count_play_pause(t), c3 + 1, msg="a double click after closing the listing plays/pauses")
  // 5. Ended (no next): a double click in the middle replays (seek 0 + play)
  let te = player_tester(false, "only.mp4", ["only.mp4"], [], [])
  te.host_says_finger(Some(false))
  te.draw()
  te.set_player(1, position=10000.0, duration=10000.0, playing=false, ended=true)
  te.draw()
  let before_v = te.views().length()
  te.tap(640.0, 400.0)
  te.advance(double_ms / 4.0)
  te.tap(640.0, 400.0)
  let after = te.views()[before_v:].to_owned()
  assert_true(after.contains("control 1 3 0"), msg="Ended double click seeks to 0")
  assert_true(after.iter().any(fn(l) { l.has_prefix("control 1 1") }), msg="Ended double click plays")
}

///|
test "wave27 V2: wide touch gets AlongTime without raising bottom bar; narrow mouse clicks as taps" {
  let sleep_ms = @player.media_sleep_ms
  // 1. Wide (1280x800) + Finger: single tap hides controls, horizontal drag enters AlongTime without waking bottom bar
  let tw = player_tester(false, "a.mp4", [], [], [], pin=pinned(5000.0))
  tw.host_says_finger(Some(true))
  tw.draw()
  tw.tap(640.0, 400.0)
  tw.run_for(playing_for("k").media.times().1 + sleep_ms + 20.0)
  assert_true(tw.query(Slider, label="web-pages.drive.player.position") is None, msg="wide touch tap hides controls")
  tw.press_at(400.0, 400.0)
  tw.move_to(430.0, 400.0)
  tw.move_to(530.0, 400.0)
  tw.draw()
  assert_true(told(tw, 9, value="1"), msg="wide touch horizontal drag enters scrub")
  assert_true(tw.query(Slider, label="web-pages.drive.player.position") is None, msg="AlongTime must not raise hidden bottom bar")
  tw.release(530.0, 400.0)
  assert_true(told(tw, 9, value="0"), msg="wide touch release ends scrub")
  // 2. Narrow (390x844) + Mouse: a click alone hides the controls, a double click in the middle plays/pauses
  let tn = player_tester(true, "a.mp4", [], [], [])
  tn.host_says_finger(Some(false))
  tn.draw()
  let c0 = count_play_pause(tn)
  tn.tap(195.0, 400.0)
  tn.run_for(@ui.double_tap_ms + sleep_ms + 20.0)
  assert_eq(count_play_pause(tn), c0, msg="narrow mouse click alone never plays/pauses")
  assert_true(tn.query(Slider, label="web-pages.drive.player.position") is None, msg="narrow mouse click alone hides controls")
  tn.tap(195.0, 400.0)
  tn.advance(@ui.double_tap_ms / 4.0)
  tn.tap(195.0, 400.0)
  assert_eq(count_play_pause(tn), c0 + 1, msg="narrow mouse double click plays/pauses")
}

///|
test "wave27 V1: cue_node paint-layer offset has laid == 0 on fade-out and mid-fade reversal, dual-line and listing zero overlap" {
  let sleep_ms = @player.media_sleep_ms
  let t = player_tester(false, "E1.mp4", ["E1.mp4", "E2.mp4"], [], [], keyed=true, pin=pinned(2000.0))
  t.host_says_finger(Some(false))
  playing_for("k").media.set_subtitle(true, [{ from: 0.0, to: 10000.0, text: "第一行字幕\n第二行字幕" }])
  t.draw()
  let y_up = t.find("第一行字幕").unwrap().1
  // A click alone hides the controls once a double click's time has gone (fade starts), then measure laid == 0
  t.tap(640.0, 400.0)
  t.run_for(@ui.double_tap_ms)
  t.tree_frames_from_now()
  t.run_for(sleep_ms / 2.0)
  for f in t.tree_frames() {
    assert_eq(f.laid, 0, msg="cue fade-out must have laid == 0: \{Repr(f)}")
  }
  let y_mid = t.find("第一行字幕").unwrap().1
  assert_true(y_mid > y_up + 5.0, msg="cue moved down mid-fade: y_up=\{y_up}, y_mid=\{y_mid}")
  // Reverse mid-fade by a key that wakes them (J) -> laid == 0 and moves back up smoothly
  t.key(@ui.key_of_char('j'))
  t.tree_frames_from_now()
  t.run_for(@player.media_wake_ms + 10.0)
  for f in t.tree_frames() {
    assert_eq(f.laid, 0, msg="cue mid-fade reversal must have laid == 0: \{Repr(f)}")
  }
  let y_back = t.find("第一行字幕").unwrap().1
  assert_true((y_back - y_up).abs() < 1.0, msg="cue returned smoothly to raised position: \{y_back} vs \{y_up}")
  // Open 选集 docked panel: BOTH lines' actual drawn right edges stay strictly left of docked panel (1280 - desk_panel_w)
  t.click(Button, label="web-pages.drive.player.list")
  t.draw()
  let list_left = 1280.0 - desk_panel_w
  for line in ["第一行字幕", "第二行字幕"] {
    match t.rect_of(line) {
      Some((rx, _, rw, _)) =>
        assert_true(rx + rw <= list_left, msg="cue line \{line} right edge \{rx + rw} must stay <= \{list_left}")
      None => fail("cue line \{line} must be drawn")
    }
  }
}

///|
test "wave27 V4: touch AlongTime VFR frame stepping, zero downgrade jump, empty-frame fallback, 10s fine gear, hysteresis, no DownClose, second-finger handoff" {
  // 1. VFR [0, 33, 120, 140]ms in gear 2: 8x1pt == 1x8pt, 33->120->33, <=1 haptic per event, downgrade to gear 1 zero backward jump
  let t = player_tester(true, "a.mp4", [], [], [])
  t.draw()
  vfr_frames(t, playing=false)
  t.draw()
  // Start at 33ms, drag right past touch_slop to lock AlongTime (no slop jump)
  t.press_at(100.0, 300.0)
  t.move_to(120.0, 300.0) // lock AlongTime at x=120, y=300 (scrub_pos = 33.0)
  assert_true(told(t, 3, value="33"), msg="locked at 33ms without slop jump")
  // Pull down 100pt (>= 96pt) to enter gear 2 (逐帧); top bar is visible so HUD clears top bar (y > 48pt)
  t.move_to(120.0, 400.0)
  t.draw()
  match t.find("逐帧") {
    Some((_, hud_y)) => assert_true(hud_y > @ui.Space::S12.px(), msg="HUD clears visible top bar: y=\{hud_y}")
    None => fail("gear 2 with real frames shows 逐帧")
  }
  // 8 x +1pt -> steps 1 frame from 33ms to 120ms
  let h0 = t.haptics().length()
  for k in 1..<=8 {
    t.move_to(120.0 + k.to_double(), 400.0)
  }
  t.draw()
  assert_true(told(t, 3, value="120"), msg="8x1pt steps 33->120ms")
  assert_eq(t.haptics().length(), h0 + 1, msg="exact 1 haptic on crossing 1 frame")
  // -8pt -> steps back 120->33ms
  t.move_to(120.0, 400.0)
  t.draw()
  assert_true(t.views().rev_iter().find_first(fn(l) { l.has_prefix("control 1 3 ") }) == Some("control 1 3 33"), msg="-8pt steps 120->33ms")
  // Single +16pt jumps 2 frames (33 -> 140ms) with at most 1 haptic for that event
  let h1 = t.haptics().length()
  t.move_to(136.0, 400.0)
  t.draw()
  assert_true(t.views().rev_iter().find_first(fn(l) { l.has_prefix("control 1 3 ") }) == Some("control 1 3 140"), msg="+16pt jumps 33->140ms")
  assert_eq(t.haptics().length(), h1 + 1, msg="multi-frame single event fires at most 1 haptic")
  // Step back to 120ms (-8pt), then pure vertical move back to gear 1 (dy = 50pt < 90pt): zero backward jump!
  t.move_to(128.0, 400.0)
  t.draw()
  assert_true(t.views().rev_iter().find_first(fn(l) { l.has_prefix("control 1 3 ") }) == Some("control 1 3 120"))
  t.move_to(128.0, 350.0)
  t.draw()
  assert_true(t.find("¼×") is Some(_), msg="downgraded to gear 1 (¼×)")
  assert_true(
    t.views().rev_iter().find_first(fn(l) { l.has_prefix("control 1 3 ") }) == Some("control 1 3 120"),
    msg="downgrading gear 2->1 must not jump backward from 120ms",
  )
  // Hysteresis check: at dy=39pt (> 38pt) stays in gear 1; at dy=37pt (< 38pt) drops to gear 0
  t.move_to(128.0, 339.0)
  t.draw()
  assert_true(t.find("¼×") is Some(_), msg="hysteresis keeps gear 1 at 39pt")
  t.move_to(128.0, 337.0)
  t.draw()
  assert_true(t.find("1×") is Some(_), msg="drops to gear 0 below 38pt")
  t.release(128.0, 337.0)

  // 2. Empty frame table degrades gear 2 to 微调 (no 帧)
  let te = player_tester(true, "a.mp4", [], [], [])
  te.draw()
  te.set_player(1, position=2000.0, duration=10000.0, playing=false)
  te.view_said("{\"view\":{\"view\":1,\"what\":1,\"text\":\"\"}}") |> ignore
  te.draw()
  te.press_at(100.0, 300.0)
  te.move_to(120.0, 300.0)
  te.move_to(120.0, 400.0)
  te.draw()
  assert_true(te.find("微调") is Some(_), msg="empty frame table shows 微调")
  assert_true(te.find(" 帧") is None, msg="empty frame table must not show frame count")
  te.release(120.0, 400.0)

  // 3. 10s short video in ¼× fine gear = 2.5s per 390pt screen width
  let ts = player_tester(true, "a.mp4", [], [], [])
  ts.draw()
  ts.set_player(1, position=0.0, duration=10000.0, playing=false)
  ts.draw()
  ts.press_at(10.0, 300.0)
  ts.move_to(30.0, 300.0) // lock AlongTime at x=30, pos=0
  ts.move_to(30.0, 350.0) // gear 1 (dy=50 >= 44)
  ts.move_to(30.0 + 390.0, 350.0) // +1 full screen width -> +2500ms
  ts.release(30.0 + 390.0, 350.0)
  assert_true(
    ts.views().rev_iter().find_first(fn(l) { l.has_prefix("control 1 3 ") }) == Some("control 1 3 2500"),
    msg="10s video in 1/4x gear moves 2500ms per screen width",
  )

  // 4. Lock AlongTime then drag down 200pt: zero accidental DownClose
  let backs : Array[Int] = []
  let td = player_tester(true, "a.mp4", [], [], backs)
  td.draw()
  td.press_at(100.0, 300.0)
  td.move_to(130.0, 300.0)
  td.move_to(130.0, 520.0)
  td.release(130.0, 520.0)
  assert_eq(backs.length(), 0, msg="AlongTime dragged down 200pt must never close")

  // 5a. Second-finger handoff (playing start): AlongTime -> 2nd finger lands -> scrub(false) strictly 1 & resumes play
  let th = player_tester(true, "a.mp4", [], [], [])
  th.draw()
  th.set_player(1, position=2000.0, duration=10000.0, playing=true)
  th.draw()
  let s0 = count_controls(th, 9, value="0")
  let p0 = count_controls(th, 1)
  th.touch_raw(0, 0, 100.0, 300.0, th.time())
  th.touch_raw(1, 0, 130.0, 300.0, th.time()) // lock AlongTime
  th.touch_raw(1, 0, 160.0, 300.0, th.time())
  assert_true(count_controls(th, 9, value="1") >= 1, msg="entered scrub")
  // Second finger lands -> pairs scrub_done() once, sends play (playing start), and hands off to MoveZoom
  th.touch_raw(0, 1, 220.0, 320.0, th.time())
  assert_eq(count_controls(th, 9, value="0"), s0 + 1, msg="2nd finger immediately pairs scrub(false) once")
  assert_eq(count_controls(th, 1), p0 + 1, msg="playing-start 2nd finger handoff resumes play")
  th.touch_raw(1, 1, 240.0, 340.0, th.time())
  th.touch_raw(2, 1, 240.0, 340.0, th.time())
  th.touch_raw(2, 0, 160.0, 300.0, th.time())
  assert_eq(count_controls(th, 9, value="0"), s0 + 1, msg="releasing both fingers must not call scrub(false) a second time")

  // 5b. Second-finger handoff (paused start): scrub(false) strictly 1 and must NOT send play command
  let thp = player_tester(true, "a.mp4", [], [], [])
  thp.draw()
  thp.set_player(1, position=2000.0, duration=10000.0, playing=false)
  thp.draw()
  let sp0 = count_controls(thp, 9, value="0")
  let pp0 = count_controls(thp, 1)
  thp.touch_raw(0, 0, 100.0, 300.0, thp.time())
  thp.touch_raw(1, 0, 130.0, 300.0, thp.time())
  thp.touch_raw(1, 0, 160.0, 300.0, thp.time())
  thp.touch_raw(0, 1, 220.0, 320.0, thp.time())
  assert_eq(count_controls(thp, 9, value="0"), sp0 + 1, msg="paused-start 2nd finger pairs scrub(false) once")
  assert_eq(count_controls(thp, 1), pp0, msg="paused-start 2nd finger handoff must not send play")
  thp.touch_raw(2, 1, 220.0, 320.0, thp.time())
  thp.touch_raw(2, 0, 160.0, 300.0, thp.time())
  assert_eq(count_controls(thp, 9, value="0"), sp0 + 1, msg="paused-start release must not call scrub(false) twice")
}

///|
test "wave27 V4: touch single tap toggles awake in Paused and Playing; neither fades by itself" {
  let sleep_ms = @player.media_sleep_ms
  // Touch Paused: does NOT auto-fade, but single tap hides and shows
  let tp = player_tester(true, "a.mp4", [], [], [], pin={ ..pinned(2000.0), playing: false })
  tp.draw()
  tp.run_for(long_rest_ms)
  assert_true(tp.query(Slider, label="web-pages.drive.player.position") is Some(_), msg="touch Paused does not auto-fade")
  tp.tap(195.0, 400.0)
  tp.run_for(playing_for("k").media.times().1 + sleep_ms + 20.0)
  assert_true(tp.query(Slider, label="web-pages.drive.player.position") is None, msg="touch Paused tap hides controls")
  tp.tap(195.0, 400.0)
  tp.run_for(playing_for("k").media.times().1 + @player.media_wake_ms + 20.0)
  assert_true(tp.query(Slider, label="web-pages.drive.player.position") is Some(_), msg="touch Paused tap brings controls back")
  // Touch Playing: never fades by itself either; a tap hides it
  let tplay = player_tester(true, "a.mp4", [], [], [], pin=pinned(2000.0))
  tplay.draw()
  tplay.run_for(long_rest_ms)
  assert_true(tplay.query(Slider, label="web-pages.drive.player.position") is Some(_), msg="touch Playing still shown after a long rest")
  hide_by_tap(tplay, 195.0, 400.0)
  assert_true(tplay.query(Slider, label="web-pages.drive.player.position") is None, msg="touch Playing tap hides controls")
}

///|
test "wave27 V1: Esc closes rates/listing first, then single Esc leaves fullscreen and calls on_back" {
  let backs : Array[Int] = []
  let t = player_tester(false, "E1.mp4", ["E1.mp4", "E2.mp4"], [], backs, keyed=true)
  t.host_says_finger(Some(false))
  t.draw()
  // Open listing + rates: Esc closes rates first, then listing, then leaves in one Esc
  t.click(Button, label="web-pages.drive.player.list")
  t.click(Button, label="web-pages.drive.player.rate")
  t.draw()
  t.key(@ui.key_escape)
  t.draw()
  assert_false(speeds_open(), msg="1st Esc closes rates")
  assert_eq(backs.length(), 0)
  t.key(@ui.key_escape)
  t.draw()
  assert_false(player_listing("k"), msg="2nd Esc closes listing")
  assert_eq(backs.length(), 0)
  // Enter fullscreen, then single Esc leaves both fullscreen and player
  t.key(@ui.key_of_char('f'))
  t.draw()
  t.key(@ui.key_escape)
  t.draw()
  assert_eq(backs.length(), 1, msg="single Esc leaves fullscreen and calls on_back")
}

///|
test "wave27 R1: Buffering never raises chrome during AlongTime or brief stall; >wait_ms locks then re-arms 2000ms" {
  let sleep_ms = @player.media_sleep_ms
  let step_ms = 10.0
  // 1. AlongTime scrubbing with buffering=true on every sample: bottom bar stays hidden
  let t = player_tester(true, "a.mp4", [], [], [])
  t.draw()
  let wait_ms = playing_for("k").media.times().0
  t.set_player(1, position=2000.0, duration=10000.0, playing=true)
  t.draw()
  t.tap(195.0, 400.0)
  t.run_for(playing_for("k").media.times().1 + sleep_ms + step_ms)
  assert_true(t.query(Slider, label="web-pages.drive.player.position") is None, msg="controls hidden before AlongTime")
  t.press_at(100.0, 300.0)
  t.move_to(130.0, 300.0)
  t.set_player(1, position=2500.0, duration=10000.0, playing=false, buffering=true)
  t.run_for(wait_ms + step_ms)
  t.move_to(180.0, 300.0)
  t.draw()
  assert_true(t.query(Slider, label="web-pages.drive.player.position") is None, msg="buffering during AlongTime must not raise bottom bar")
  t.release(180.0, 300.0)
  // 2. Playing hidden state: brief buffering (< wait_ms) does NOT wake; > wait_ms wakes & locks; recovery hides them
  // again, as the tap left them
  let td = player_tester(false, "a.mp4", [], [], [])
  td.host_says_finger(Some(false))
  td.draw()
  let d_wait = playing_for("k").media.times().0
  td.set_player(1, position=2000.0, duration=10000.0, playing=true)
  td.draw()
  hide_by_tap(td, 640.0, 400.0)
  assert_true(td.query(Slider, label="web-pages.drive.player.position") is None, msg="controls hidden before brief stall")
  td.set_player(1, position=2000.0, duration=10000.0, playing=true, buffering=true)
  td.run_for(d_wait / 2.0)
  td.set_player(1, position=2000.0, duration=10000.0, playing=true, buffering=false)
  td.draw()
  assert_true(td.query(Slider, label="web-pages.drive.player.position") is None, msg="brief buffering < wait_ms must not wake controls")
  // Sustained buffering > wait_ms wakes & locks controls
  td.set_player(1, position=2000.0, duration=10000.0, playing=true, buffering=true)
  td.run_for(d_wait + @player.media_wake_ms + step_ms)
  assert_true(td.query(Slider, label="web-pages.drive.player.position") is Some(_), msg="buffering > wait_ms wakes and locks controls")
  // Recovery: back to hidden, as the tap left them
  td.set_player(1, position=2000.0, duration=10000.0, playing=true, buffering=false)
  td.run_for(@player.media_sleep_ms + step_ms)
  assert_true(td.query(Slider, label="web-pages.drive.player.position") is None, msg="hidden again after buffering ends")
}

///|
test "wave27 R1: mouse drag on timeline/volume does not permanently lock chrome; Tab focus on top back button locks" {
  let sleep_ms = @player.media_sleep_ms
  let step_ms = 10.0
  // 1. Mouse press & drag on timeline slider and volume slider, then a click alone on the stage still hides them
  let t = player_tester(false, "a.mp4", [], [], [], keyed=true, pin=pinned(2000.0))
  t.host_says_finger(Some(false))
  t.draw()
  match t.query(Slider, label="web-pages.drive.player.position") {
    Some(sl) => {
      let (rx, ry, rw, rh) = sl.rect
      let cx = rx + rw / 2.0
      let cy = ry + rh / 2.0
      t.press_at(cx, cy)
      t.move_to(cx + 40.0, cy)
      t.release(cx + 40.0, cy)
    }
    None => fail("timeline slider must exist")
  }
  t.move_to(640.0, 400.0)
  hide_by_tap(t, 640.0, 400.0)
  assert_true(t.query(Slider, label="web-pages.drive.player.position") is None, msg="timeline mouse drag must not leave focus lock")
  // Wake by a click alone and repeat with volume slider
  t.tap(640.0, 420.0)
  t.run_for(@ui.double_tap_ms + @player.media_wake_ms + step_ms)
  match t.query(Slider, label="web-pages.drive.player.volume") {
    Some(vol) => {
      let (rx, ry, rw, rh) = vol.rect
      let vx = rx + rw / 2.0
      let vy = ry + rh / 2.0
      t.press_at(vx, vy)
      t.move_to(vx - 20.0, vy)
      t.release(vx - 20.0, vy)
    }
    None => fail("volume slider must exist")
  }
  t.move_to(640.0, 400.0)
  hide_by_tap(t, 640.0, 400.0)
  assert_true(t.query(Slider, label="web-pages.drive.player.position") is None, msg="volume mouse drag must not leave focus lock")
  // 2. Keyboard Tab focus on desktop top-bar back button locks chrome; a click on the stage clears it and hides them
  t.key(@ui.key_tab)
  t.run_for(@player.media_wake_ms + step_ms)
  // Advance Tab until focused element is the top-bar back button ("影片")
  let mut on_back_btn = false
  for _ in 0..<24 {
    match t.query(Button, label="影片") {
      Some(b) if b.focused => {
        on_back_btn = true
        break
      }
      _ => {
        t.key(@ui.key_tab)
        t.draw()
      }
    }
  }
  assert_true(on_back_btn, msg="Tab must reach desktop top-bar back button")
  t.run_for(long_rest_ms)
  assert_true(t.query(Slider, label="web-pages.drive.player.position") is Some(_), msg="keyboard focus on back button locks chrome")
  // Clear visible keyboard focus by clicking stage (pointer click clears focus_shown): the lock gone, that click alone
  // hides the controls once a double click's time has gone
  t.move_to(640.0, 400.0)
  t.tap(640.0, 400.0)
  t.draw()
  t.run_for(@ui.double_tap_ms - step_ms)
  assert_true(t.query(Slider, label="web-pages.drive.player.position") is Some(_), msg="still visible before a double click's time")
  t.run_for(step_ms + sleep_ms + step_ms)
  assert_true(t.query(Slider, label="web-pages.drive.player.position") is None, msg="the click alone hid the controls post-blur")
}

///|
test "wave27 R1: timeline disabled during fade-out does not call scrub_done for stage AlongTime scrub" {
  let sleep_ms = @player.media_sleep_ms
  let step_ms = 10.0
  let t = player_tester(true, "a.mp4", [], [], [])
  t.draw()
  t.set_player(1, position=2000.0, duration=10000.0, playing=true)
  t.draw()
  // A tap alone starts the fade-out once a double tap's time has gone; halfway through sleep_ms (fading, not faded)
  t.tap(195.0, 400.0)
  t.run_for(@ui.double_tap_ms + sleep_ms / 2.0)
  let s0 = count_controls(t, 9, value="0")
  // Start AlongTime horizontal drag during the fade-out window and hold past fade completion
  t.press_at(100.0, 300.0)
  t.move_to(130.0, 300.0)
  t.move_to(170.0, 300.0)
  t.run_for(sleep_ms + step_ms)
  assert_eq(count_controls(t, 9, value="0"), s0, msg="timeline becoming disabled must not end AlongTime scrub while finger held")
  t.release(170.0, 300.0)
  assert_eq(count_controls(t, 9, value="0"), s0 + 1, msg="releasing finger ends AlongTime scrub exactly once")
}

///|
test "wave27 R1: crossing wide/narrow breakpoint mid-AlongTime and mid-2x-hold cleans up gesture state" {
  let step_ms = 10.0
  // 1. Mid-AlongTime resize 1280x800 -> 390x844
  let t = player_tester(false, "a.mp4", [], [], [])
  t.host_says_finger(Some(true))
  t.draw()
  t.set_player(1, position=2000.0, duration=10000.0, playing=true)
  t.draw()
  let s0 = count_controls(t, 9, value="0")
  t.press_at(400.0, 400.0)
  t.move_to(440.0, 400.0)
  t.move_to(440.0, 450.0) // gear 1 (¼×) so HUD label is unambiguous from bottom bar's 1× speed button
  t.draw()
  assert_true(t.find("¼×") is Some(_), msg="AlongTime HUD visible before breakpoint cross")
  t.resize(390.0, 844.0)
  t.draw()
  assert_true(t.find("¼×") is None, msg="AlongTime HUD cleared on breakpoint cross")
  assert_eq(count_controls(t, 9, value="0"), s0 + 1, msg="scrub(false) paired exactly once on breakpoint cross")
  // Subsequent gesture works cleanly under new pointer mode
  t.host_says_finger(Some(false))
  let c0 = count_play_pause(t)
  t.tap(195.0, 400.0)
  t.advance(@ui.double_tap_ms / 4.0)
  t.tap(195.0, 400.0)
  assert_eq(count_play_pause(t), c0 + 1, msg="post-breakpoint double click dispatches cleanly")

  // 2. Mid-2x-long-press resize 390x844 -> 1280x800
  let t2 = player_tester(true, "a.mp4", [], [], [])
  t2.draw()
  t2.set_player(1, position=2000.0, duration=10000.0, playing=true)
  t2.draw()
  t2.press_at(195.0, 400.0)
  t2.run_for(@ui.long_press_ms + step_ms)
  assert_true(told(t2, 4, value="2"), msg="entered 2x held speed")
  let before_v = t2.views().length()
  t2.resize(1280.0, 800.0)
  t2.draw()
  let after_v = t2.views()[before_v:].to_owned()
  assert_true(after_v.contains("control 1 4 1"), msg="2x speed restored to 1.0 on breakpoint cross")
}

///|
test "wave27 R1: plain set_a11y does not lock chrome; reactive set_screen_reader shows hidden controls without manual draw while on" {
  let step_ms = 20.0
  // 1. Plain set_a11y(true) (non-screen-reader AX/UIA client) must NOT lock controls: a click alone hides them
  let t = player_tester(false, "a.mp4", [], [], [], pin={ ..pinned(2000.0), playing: false })
  t.host_says_finger(Some(false))
  t.set_a11y(true)
  t.draw()
  hide_by_tap(t, 640.0, 400.0)
  assert_true(t.query(Slider, label="web-pages.drive.player.position") is None, msg="plain set_a11y(true) must not lock controls")
  // 2. On the same paused hidden instance, set_screen_reader(true) without manual draw() wakes & locks via frame step
  t.set_screen_reader(true)
  t.run_for(@player.media_wake_ms + step_ms)
  assert_true(t.query(Slider, label="web-pages.drive.player.position") is Some(_), msg="set_screen_reader(true) proactively wakes hidden controls")
  hide_by_tap(t, 640.0, 400.0)
  assert_true(t.query(Slider, label="web-pages.drive.player.position") is Some(_), msg="set_screen_reader(true) keeps controls locked")
  // 3. Turn screen reader off: back to hidden, as the click left them
  t.set_screen_reader(false)
  t.run_for(@player.media_sleep_ms + step_ms)
  assert_true(t.query(Slider, label="web-pages.drive.player.position") is None, msg="hidden again after screen reader off")
}

///|
test "wave27 R2: cancel_stage_gesture clears pending single-tap across wide/narrow breakpoint" {
  let sleep_ms = @player.media_sleep_ms
  let step_ms = 10.0
  let t = player_tester(true, "a.mp4", [], [], [])
  t.draw()
  t.set_player(1, position=5000.0, duration=30000.0, playing=false)
  t.draw()
  let double_ms = playing_for("k").media.times().1
  let pp0 = count_play_pause(t)
  let sk0 = count_controls(t, 3) + count_controls(t, 11)
  // Single tap on phone, then immediately cross breakpoint into wide layout within twice_ms
  t.tap(195.0, 400.0)
  t.run_for(double_ms / 4.0)
  t.resize(1280.0, 800.0)
  t.host_says_finger(Some(true))
  t.draw()
  // Wait past twice_ms, then single tap center -> must NOT fire double-tap play/pause; toggles chrome off
  t.run_for(double_ms + step_ms)
  t.tap(640.0, 400.0)
  t.run_for(double_ms + sleep_ms + step_ms)
  assert_eq(count_play_pause(t), pp0, msg="post-breakpoint center tap must not fire stale double-tap play/pause")
  assert_true(t.query(Slider, label="web-pages.drive.player.position") is None, msg="post-breakpoint center tap hides chrome")
  // Single tap right third -> must NOT fire stale double-tap seek; toggles chrome back on
  t.tap(1100.0, 400.0)
  t.run_for(double_ms + @player.media_wake_ms + step_ms)
  assert_eq(count_controls(t, 3) + count_controls(t, 11), sk0, msg="post-breakpoint right tap must not fire stale double-tap seek")
  assert_true(t.query(Slider, label="web-pages.drive.player.position") is Some(_), msg="post-breakpoint right tap wakes chrome")
}

///|
test "wave27 R3: playing tap + breakpoint cross leaves the controls, firing nothing; a lock engaging mid-double_ms keeps them" {
  let step_ms = 10.0
  // 1. Playing single tap -> cross wide/narrow breakpoint within double_ms -> no further input: the tap forgotten
  let t = player_tester(true, "a.mp4", [], [], [])
  t.draw()
  t.set_player(1, position=5000.0, duration=30000.0, playing=true)
  t.draw()
  let double_ms = playing_for("k").media.times().1
  let pp0 = count_play_pause(t)
  let sk0 = count_controls(t, 3) + count_controls(t, 11)
  t.tap(195.0, 400.0)
  t.run_for(double_ms / 4.0)
  t.resize(1280.0, 800.0)
  t.host_says_finger(Some(true))
  t.draw()
  t.run_for(long_rest_ms)
  assert_true(t.query(Slider, label="web-pages.drive.player.position") is Some(_), msg="the tap forgotten across the breakpoint: still shown")
  assert_eq(count_play_pause(t), pp0, msg="zero play/pause fired")
  assert_eq(count_controls(t, 3) + count_controls(t, 11), sk0, msg="zero seek fired")

  // 2. Playing single tap on visible bar -> at 100ms set_screen_reader(true) -> cross double_ms -> off: still shown
  let t2 = player_tester(true, "a.mp4", [], [], [], pin=pinned(5000.0))
  t2.draw()
  let d2 = playing_for("k").media.times().1
  t2.tap(195.0, 400.0)
  t2.run_for(d2 / 3.0)
  t2.set_screen_reader(true)
  t2.run_for(d2 + step_ms) // single-tap callback fires while chrome_locked() is true -> must NOT overwrite awake=false
  assert_true(t2.query(Slider, label="web-pages.drive.player.position") is Some(_), msg="controls remain locked while screen reader on")
  t2.set_screen_reader(false)
  t2.run_for(long_rest_ms)
  assert_true(t2.query(Slider, label="web-pages.drive.player.position") is Some(_), msg="still shown after unlock")

  // 3. Playing single tap on visible bar -> lock engages at 100ms AND releases at 200ms (all within double_ms=300ms):
  // stale single-tap hide at 300ms must be invalidated by lock_epoch
  let t3 = player_tester(true, "a.mp4", [], [], [], pin=pinned(5000.0))
  t3.draw()
  let d3 = playing_for("k").media.times().1
  t3.tap(195.0, 400.0)
  t3.run_for(d3 / 3.0) // ~100ms
  t3.set_screen_reader(true)
  t3.run_for(d3 / 3.0) // ~200ms
  t3.set_screen_reader(false)
  t3.run_for(d3 / 3.0 + step_ms) // ~310ms: past 300ms single-tap deadline; bar MUST remain visible!
  assert_true(t3.query(Slider, label="web-pages.drive.player.position") is Some(_), msg="stale hide invalidated when lock engaged and released mid-double_ms")
  t3.run_for(long_rest_ms)
  assert_true(t3.query(Slider, label="web-pages.drive.player.position") is Some(_), msg="still shown long after mid-tap unlock")
}

///|
test "wave27 R1: sparse Up slop, single diagonal haptic, wide DownClose hides bars, AlongTime safe area" {
  let sleep_ms = @player.media_sleep_ms
  let step_ms = 10.0
  // 1. Sparse Up without Moved: desktop mouse neither toggles play/pause; phone touch does not count as tap
  let td = player_tester(false, "a.mp4", [], [], [], pin=pinned(2000.0))
  td.host_says_finger(Some(false))
  td.draw()
  let c0 = count_play_pause(td)
  td.press_at(400.0, 400.0)
  td.release(400.0 + @ui.touch_slop() + 20.0, 400.0)
  assert_eq(count_play_pause(td), c0, msg="desktop sparse far Up must not toggle play/pause")

  let tp = player_tester(true, "a.mp4", [], [], [], pin={ ..pinned(2000.0), playing: false })
  tp.draw()
  tp.press_at(195.0, 400.0)
  tp.release(195.0 + @ui.touch_slop() + 20.0, 400.0)
  tp.run_for(playing_for("k").media.times().1 + sleep_ms + step_ms)
  assert_true(tp.query(Slider, label="web-pages.drive.player.position") is Some(_), msg="phone sparse far Up must not count as tap")

  // 2. Single diagonal Moved from gear 0 directly into gear 2 AND dx >= 8pt fires strictly 1 haptic
  let th = player_tester(true, "a.mp4", [], [], [])
  th.draw()
  vfr_frames(th, playing=false)
  th.draw()
  th.press_at(100.0, 300.0)
  th.move_to(120.0, 300.0) // lock AlongTime in gear 0 at x=120, y=300
  let h0 = th.haptics().length()
  th.move_to(120.0 + player_scrub_frame_px + 2.0, 300.0 + player_scrub_frame_up + 10.0)
  th.draw()
  assert_eq(th.haptics().length(), h0 + 1, msg="single diagonal gear0->gear2 + frame step must fire strictly 1 haptic")
  th.release(120.0 + player_scrub_frame_px + 2.0, 300.0 + player_scrub_frame_up + 10.0)

  // 3. Wide layout touch DownClose hides desktop bars
  let tw = player_tester(false, "a.mp4", [], [], [], pin=pinned(2000.0))
  tw.host_says_finger(Some(true))
  tw.draw()
  tw.press_at(640.0, 300.0)
  tw.move_to(640.0, 340.0) // DownClose
  tw.draw()
  assert_true(tw.query(Slider, label="web-pages.drive.player.position") is None, msg="wide touch DownClose hides desktop bottom bar")
  tw.release(640.0, 340.0)

  // 4. AlongTime HUD & 3pt progress line respect safe area room = (59.0, 34.0)
  let ts = player_tester(true, "a.mp4", [], [], [], pin={ ..pinned(2000.0), playing: false })
  set_viewer_host({ ..viewer_host(), room: fn() { (59.0, 34.0) } })
  ts.draw()
  // Hide bars so HUD sits at top safe area + S4 and 3pt line sits at bottom safe area + S2
  ts.tap(195.0, 400.0)
  ts.run_for(playing_for("k").media.times().1 + sleep_ms + step_ms)
  ts.press_at(100.0, 300.0)
  ts.move_to(130.0, 300.0)
  ts.draw()
  match ts.rect_of("1×") {
    Some((_, hy, _, _)) =>
      assert_true(hy >= 59.0 + @ui.Space::S4.px(), msg="HUD top y=\{hy} must clear safe area 59 + S4")
    None => fail("AlongTime HUD must be visible")
  }
  let has_safe_bar = ts
    .drawn_rects()
    .iter()
    .any(fn(r) {
      let (_, ry, _, rh, _) = r
      (rh - player_scrub_bar_h).abs() < 0.5 && ry + rh <= 844.0 - 34.0 - @ui.Space::S2.px() + 0.5
    })
  assert_true(has_safe_bar, msg="3pt progress line must clear bottom safe area 34 + S2")
  ts.release(130.0, 300.0)
}

///|
test "wave27 V5: desktop click hides the controls though the pointer moves on within a double click's time; a double click on a side jumps back or on" {
  let sleep_ms = @player.media_sleep_ms
  let double_ms = @ui.double_tap_ms
  let tt = player_tester(false, "a.mp4", [], [], [], pin=pinned(20000.0))
  tt.host_says_finger(Some(false))
  tt.draw()
  tt.move_to(640.0, 400.0)
  tt.draw()
  assert_true(tt.query(Slider, label="web-pages.drive.player.position") is Some(_), msg="controls shown")
  // A click, then the hand moving on within a double click's time: the click still hides them
  tt.tap(640.0, 400.0)
  tt.advance(double_ms / 4.0)
  tt.move_to(660.0, 400.0)
  tt.run_for(double_ms + sleep_ms + 10.0)
  assert_true(tt.query(Slider, label="web-pages.drive.player.position") is None, msg="the click hid the controls")
  // The hand moving over the stage after: they stay hidden (only a click shows them)
  tt.move_to(500.0, 300.0)
  tt.move_to(700.0, 450.0)
  tt.run_for(long_rest_ms)
  assert_true(tt.query(Slider, label="web-pages.drive.player.position") is None, msg="the pointer moving never shows them")
  // A double click on the left third: back by its nudge; on the right third: on by it
  let back = t(
    "android-misc.drive.player.back",
    args=[("n", (playing_for("k").media.nudge_ms() / 1000.0).to_int().to_string())],
  )
  tt.tap(200.0, 400.0)
  tt.advance(double_ms / 4.0)
  tt.tap(200.0, 400.0)
  tt.draw()
  assert_true(tt.find(back) is Some(_), msg="double click on the left: \{back}")
  tt.run_for(@player.media_note_ms + double_ms)
  let ahead = t(
    "android-misc.drive.player.ahead",
    args=[("n", (playing_for("k").media.nudge_ms() / 1000.0).to_int().to_string())],
  )
  tt.tap(1100.0, 400.0)
  tt.advance(double_ms / 4.0)
  tt.tap(1100.0, 400.0)
  tt.draw()
  assert_true(tt.find(ahead) is Some(_), msg="double click on the right: \{ahead}")
}
