// Wave 27 · Track V deterministic tests: full-bleed stage, per-gesture input dispatch,
// desktop click play/pause & 2000ms auto-fade with lock-release re-arm, subtitle laid==0 offset,
// touch AlongTime 3-gear VFR frame scrubbing & safe second-finger handoff, and Esc priority.

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
  // Ready, paused static fixture: idle_off uses later=true so assert_idle() passes immediately with controls visible.
  let t = player_tester(false, "a.mp4", [], [], [], pin={ ..pinned(2000.0), playing: false })
  t.host_says_finger(Some(false))
  t.draw()
  t.assert_idle()
  assert_true(t.query(Slider, label="web-pages.drive.player.position") is Some(_), msg="controls visible at rest")
  // Opening phase (state == 0): locked, never auto-fades past 2000ms + sleep_ms.
  let to = player_tester(false, "a.mp4", [], [], [], pin={ ..pinned(0.0), state: 0, playing: false })
  to.host_says_finger(Some(false))
  to.draw()
  to.run_for(player_desk_idle_ms + @player.media_sleep_ms + 500.0)
  assert_true(to.query(Slider, label="web-pages.drive.player.position") is Some(_), msg="Opening keeps controls visible")
}

///|
test "wave27 V3: desktop 2000ms auto-fade exact boundaries (1999ms / 2000ms / 2000+sleep_ms) in Playing and Paused, re-wake cancels old timer, pointer leave fades" {
  let sleep_ms = @player.media_sleep_ms
  let step_ms = 1.0
  for is_playing in [true, false] {
    let t = player_tester(false, "a.mp4", [], [], [], pin={ ..pinned(2000.0), playing: is_playing })
    t.host_says_finger(Some(false))
    t.draw()
    t.assert_idle()
    assert_true(t.query(Slider, label="web-pages.drive.player.position") is Some(_))
    // 1999ms: still visible
    t.run_for(player_desk_idle_ms - step_ms)
    assert_true(
      t.query(Slider, label="web-pages.drive.player.position") is Some(_),
      msg="playing=\{is_playing}: still visible at 1999ms",
    )
    // 2000ms: fade starts (awake becomes false), still fading until sleep_ms elapses
    t.run_for(step_ms)
    // 2000 + sleep_ms: completely hidden (faded = true, slider not pressable/visible)
    t.run_for(sleep_ms + step_ms)
    assert_true(
      t.query(Slider, label="web-pages.drive.player.position") is None,
      msg="playing=\{is_playing}: hidden at 2000+sleep_ms",
    )
  }
  // Re-wake at 1000ms cancels old 2000ms timer
  let tr = player_tester(false, "a.mp4", [], [], [], pin=pinned(2000.0))
  tr.host_says_finger(Some(false))
  tr.draw()
  tr.run_for(player_desk_idle_ms / 2.0)
  tr.move_to(640.0, 400.0)
  tr.draw()
  // Advance past old deadline (1000 + 1500 = 2500ms > 2000 + sleep_ms): still visible!
  tr.run_for(player_desk_idle_ms * 0.75)
  assert_true(tr.query(Slider, label="web-pages.drive.player.position") is Some(_), msg="re-wake cancelled old timer")
  // Advance remaining 500ms + sleep_ms: now hidden
  tr.run_for(player_desk_idle_ms * 0.25 + sleep_ms + step_ms)
  assert_true(tr.query(Slider, label="web-pages.drive.player.position") is None, msg="faded after refreshed deadline")
  // Pointer leaving window immediately fades unlocked controls
  let tl = player_tester(false, "a.mp4", [], [], [], pin=pinned(2000.0))
  tl.host_says_finger(Some(false))
  tl.draw()
  tl.move_to(640.0, 400.0)
  tl.draw()
  tl.move_to(-10.0, -10.0)
  tl.run_for(sleep_ms + 1.0)
  assert_true(tl.query(Slider, label="web-pages.drive.player.position") is None, msg="pointer leave fades immediately")
}

///|
test "wave27 V3: chrome_locked holds controls across 2000ms and unlocking re-arms a full 2000ms deadline" {
  let sleep_ms = @player.media_sleep_ms
  // 1. Tab focus in bottom bar locks across 2000ms; leaving focus (to an outside button) re-arms a full 2000ms
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
  t.run_for(player_desk_idle_ms + sleep_ms + 500.0)
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
  // Unlock re-arms full 2000ms: still visible at 1999ms after unlock
  t.run_for(player_desk_idle_ms - 1.0)
  assert_true(
    t.query(Slider, label="web-pages.drive.player.position") is Some(_),
    msg="unlock must re-arm full 2000ms (still visible at 1999ms)",
  )
  t.run_for(1.0 + sleep_ms + 1.0)
  assert_true(
    t.query(Slider, label="web-pages.drive.player.position") is None,
    msg="faded after full 2000ms + sleep_ms from unlock",
  )
  // 2. screen_reader_on, Buffering, Failed, Ended, near_top, near_foot, rates, listing, audio all lock chrome
  let ta = player_tester(false, "a.mp4", [], [], [], pin=pinned(2000.0))
  ta.host_says_finger(Some(false))
  ta.set_screen_reader(true)
  ta.draw()
  ta.run_for(player_desk_idle_ms + sleep_ms + 500.0)
  assert_true(ta.query(Slider, label="web-pages.drive.player.position") is Some(_), msg="screen_reader_on locks chrome")
  for pin_case in [
    { ..pinned(2000.0), buffering: true },
    { ..pinned(2000.0), state: -1, playing: false },
    pinned(10000.0, ended=true),
  ] {
    let tp = player_tester(false, "a.mp4", [], [], [], pin=pin_case)
    tp.host_says_finger(Some(false))
    tp.draw()
    tp.run_for(player_desk_idle_ms + sleep_ms + 500.0)
    assert_true(tp.query(Slider, label="web-pages.drive.player.position") is Some(_), msg="phase lock holds chrome")
  }
  // near_top & near_foot
  let th = player_tester(false, "a.mp4", [], [], [], pin=pinned(2000.0))
  th.host_says_finger(Some(false))
  th.draw()
  th.move_to(640.0, 20.0)
  th.run_for(player_desk_idle_ms + sleep_ms + 500.0)
  assert_true(th.query(Slider, label="web-pages.drive.player.position") is Some(_), msg="near_top locks chrome")
  th.move_to(640.0, 760.0)
  th.run_for(player_desk_idle_ms + sleep_ms + 500.0)
  assert_true(th.query(Slider, label="web-pages.drive.player.position") is Some(_), msg="near_foot locks chrome")
  // rates menu open (modal menu covers slider in a11y tree; verify controls time text + menu stay visible, and closing menu leaves controls visible for a full 2000ms)
  let tm = player_tester(false, "a.mp4", [], [], [], keyed=true, pin=pinned(2000.0))
  tm.host_says_finger(Some(false))
  tm.draw()
  tm.click(Button, label="web-pages.drive.player.rate")
  tm.run_for(player_desk_idle_ms + sleep_ms + 500.0)
  assert_true(speeds_open() && tm.find("0:02 / 0:10") is Some(_), msg="rates menu locks chrome")
  tm.key(@ui.key_escape)
  tm.draw()
  assert_true(tm.query(Slider, label="web-pages.drive.player.position") is Some(_), msg="controls still visible after closing rates menu")
  // listing open
  let tl = player_tester(false, "E1.mp4", ["E1.mp4", "E2.mp4"], [], [], pin=pinned(2000.0))
  tl.host_says_finger(Some(false))
  tl.draw()
  tl.click(Button, label="web-pages.drive.player.list")
  tl.run_for(player_desk_idle_ms + sleep_ms + 500.0)
  assert_true(tl.query(Slider, label="web-pages.drive.player.position") is Some(_), msg="listing locks chrome")
  // bottom bar timeline drag (scrubbing_ui) locks chrome across 2000ms
  let ts = player_tester(false, "a.mp4", [], [], [], pin=pinned(2000.0))
  ts.host_says_finger(Some(false))
  ts.draw()
  let sl = ts.get(Slider, label="web-pages.drive.player.position").rect
  ts.press_at(sl.0 + sl.2 * 0.4, sl.1 + sl.3 / 2.0)
  ts.run_for(player_desk_idle_ms + sleep_ms + 500.0)
  assert_true(ts.query(Slider, label="web-pages.drive.player.position") is Some(_), msg="scrubbing_ui locks chrome")
  ts.release(sl.0 + sl.2 * 0.4, sl.1 + sl.3 / 2.0)
  // audio stays visible
  let tau = player_tester(false, "song.mp3", [], [], [], kind="audio", pin=pinned(2000.0))
  tau.host_says_finger(Some(false))
  tau.draw()
  tau.run_for(player_desk_idle_ms + sleep_ms + 500.0)
  assert_true(tau.query(Slider, label="web-pages.drive.player.position") is Some(_), msg="audio locks chrome")
}

///|
test "wave27 V3: desktop hidden click / Space / K play-pause silently with 450ms feedback; far clicks fire twice; menu click closes menu without play/pause; Ended replays" {
  let sleep_ms = @player.media_sleep_ms
  let t = player_tester(false, "E1.mp4", ["E1.mp4", "E2.mp4"], [], [], keyed=true)
  t.host_says_finger(Some(false))
  t.draw()
  t.set_player(1, position=2000.0, duration=10000.0, playing=true)
  t.draw()
  // Position stationary pointer on stage, then let controls auto-fade out
  t.move_to(640.0, 400.0)
  t.draw()
  t.run_for(player_desk_idle_ms + sleep_ms + 10.0)
  assert_true(t.query(Slider, label="web-pages.drive.player.position") is None, msg="controls hidden")
  // 1. Click with stationary pointer while hidden: 0ms immediate pause, controls STAY hidden, 450ms feedback shown
  let c0 = count_play_pause(t)
  t.tap(640.0, 400.0)
  assert_eq(count_play_pause(t), c0 + 1, msg="click immediately pauses")
  assert_true(t.query(Slider, label="web-pages.drive.player.position") is None, msg="hidden click does not wake controls")
  assert_true(t.find("android-misc.drive.player.paused") is Some(_), msg="450ms center feedback shown")
  t.run_for(player_quiet_note_ms + 10.0)
  assert_true(t.find("android-misc.drive.player.paused") is None, msg="450ms center feedback gone")
  // 2. Space and K while hidden: play/pause silently without waking controls
  let c1 = count_play_pause(t)
  t.key(@ui.key_space)
  assert_eq(count_play_pause(t), c1 + 1, msg="Space toggles play/pause")
  assert_true(t.query(Slider, label="web-pages.drive.player.position") is None, msg="Space does not wake hidden controls")
  t.key(@ui.key_of_char('k'))
  assert_eq(count_play_pause(t), c1 + 2, msg="K toggles play/pause")
  assert_true(t.query(Slider, label="web-pages.drive.player.position") is None, msg="K does not wake hidden controls")
  // 3. Far-apart rapid clicks fire twice (not swallowed by View::twice)
  let c2 = count_play_pause(t)
  t.tap(400.0, 400.0)
  t.advance(@ui.double_tap_ms / 4.0)
  t.tap(700.0, 400.0)
  assert_eq(count_play_pause(t), c2 + 2, msg="far-apart rapid clicks both fire play/pause")
  // Let controls fade again, then verify non-silent shortcut (J) wakes hidden controls
  t.run_for(player_desk_idle_ms + sleep_ms + 10.0)
  assert_true(t.query(Slider, label="web-pages.drive.player.position") is None, msg="controls hidden before J")
  t.key(@ui.key_of_char('j'))
  t.draw()
  assert_true(t.query(Slider, label="web-pages.drive.player.position") is Some(_), msg="J wakes hidden controls")
  // Shift+Tab also wakes hidden controls
  t.run_for(player_desk_idle_ms + sleep_ms + 10.0)
  assert_true(t.query(Slider, label="web-pages.drive.player.position") is None, msg="controls hidden before Shift+Tab")
  t.key(@ui.key_tab, mods=@ui.mod_shift_key)
  t.run_for(viewer_bar_ms + 10.0)
  assert_true(t.query(Slider, label="web-pages.drive.player.position") is Some(_), msg="Shift+Tab wakes hidden controls")
  // 5. Open listing, click stage: closes listing only, 0 play/pause, twice_forgot so next click fires
  t.click(Button, label="web-pages.drive.player.list")
  t.draw()
  let c3 = count_play_pause(t)
  t.tap(400.0, 400.0)
  assert_eq(count_play_pause(t), c3, msg="click with listing open closes listing without play/pause")
  t.advance(@ui.double_tap_ms / 4.0)
  t.tap(400.0, 400.0)
  assert_eq(count_play_pause(t), c3 + 1, msg="twice_forgot lets immediate next click toggle play/pause")
  // 6. Ended (no next): single click replays (seek 0 + play)
  let te = player_tester(false, "only.mp4", ["only.mp4"], [], [])
  te.host_says_finger(Some(false))
  te.draw()
  te.set_player(1, position=10000.0, duration=10000.0, playing=false, ended=true)
  te.draw()
  let before_v = te.views().length()
  te.tap(640.0, 400.0)
  let after = te.views()[before_v:].to_owned()
  assert_true(after.contains("control 1 3 0"), msg="Ended click seeks to 0")
  assert_true(after.iter().any(fn(l) { l.has_prefix("control 1 1") }), msg="Ended click plays")
}

///|
test "wave27 V2: wide touch gets AlongTime without raising bottom bar; narrow mouse gets immediate click play/pause" {
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
  // 2. Narrow (390x844) + Mouse: single click immediately toggles play/pause (0ms)
  let tn = player_tester(true, "a.mp4", [], [], [])
  tn.host_says_finger(Some(false))
  tn.draw()
  let c0 = count_play_pause(tn)
  tn.tap(195.0, 400.0)
  assert_eq(count_play_pause(tn), c0 + 1, msg="narrow mouse click immediately plays/pauses")
}

///|
test "wave27 V1: cue_node paint-layer offset has laid == 0 on fade-out and mid-fade reversal, dual-line and listing zero overlap" {
  let sleep_ms = @player.media_sleep_ms
  let t = player_tester(false, "E1.mp4", ["E1.mp4", "E2.mp4"], [], [], pin=pinned(2000.0))
  t.host_says_finger(Some(false))
  playing_for("k").media.set_subtitle(true, [{ from: 0.0, to: 10000.0, text: "第一行字幕\n第二行字幕" }])
  t.draw()
  let y_up = t.find("第一行字幕").unwrap().1
  // Wait to 2000ms (fade starts), then measure laid == 0 during fade-out
  t.run_for(player_desk_idle_ms)
  t.tree_frames_from_now()
  t.run_for(sleep_ms / 2.0)
  for f in t.tree_frames() {
    assert_eq(f.laid, 0, msg="cue fade-out must have laid == 0: \{Repr(f)}")
  }
  let y_mid = t.find("第一行字幕").unwrap().1
  assert_true(y_mid > y_up + 5.0, msg="cue moved down mid-fade: y_up=\{y_up}, y_mid=\{y_mid}")
  // Reverse mid-fade by moving pointer -> laid == 0 and moves back up smoothly
  t.move_to(640.0, 400.0)
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
test "wave27 V4: touch single tap toggles awake in Paused too; touch Playing auto-fades at 3000ms while Paused stays" {
  let sleep_ms = @player.media_sleep_ms
  // Touch Paused: does NOT auto-fade, but single tap hides and shows
  let tp = player_tester(true, "a.mp4", [], [], [], pin={ ..pinned(2000.0), playing: false })
  tp.draw()
  tp.run_for(player_touch_idle_ms + sleep_ms + 500.0)
  assert_true(tp.query(Slider, label="web-pages.drive.player.position") is Some(_), msg="touch Paused does not auto-fade")
  tp.tap(195.0, 400.0)
  tp.run_for(playing_for("k").media.times().1 + sleep_ms + 20.0)
  assert_true(tp.query(Slider, label="web-pages.drive.player.position") is None, msg="touch Paused tap hides controls")
  tp.tap(195.0, 400.0)
  tp.run_for(playing_for("k").media.times().1 + @player.media_wake_ms + 20.0)
  assert_true(tp.query(Slider, label="web-pages.drive.player.position") is Some(_), msg="touch Paused tap brings controls back")
  // Touch Playing: auto-fades at 3000ms (still visible at 2999ms, hidden at 3000 + sleep_ms)
  let tplay = player_tester(true, "a.mp4", [], [], [], pin=pinned(2000.0))
  tplay.draw()
  tplay.run_for(player_touch_idle_ms - 1.0)
  assert_true(tplay.query(Slider, label="web-pages.drive.player.position") is Some(_), msg="touch Playing visible at 2999ms")
  tplay.run_for(1.0 + sleep_ms + 1.0)
  assert_true(tplay.query(Slider, label="web-pages.drive.player.position") is None, msg="touch Playing hidden at 3000+sleep_ms")
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
  // 2. Playing hidden state: brief buffering (< wait_ms) does NOT wake; > wait_ms wakes & locks; recovery re-arms full 2000ms
  let td = player_tester(false, "a.mp4", [], [], [])
  td.host_says_finger(Some(false))
  td.draw()
  let d_wait = playing_for("k").media.times().0
  td.set_player(1, position=2000.0, duration=10000.0, playing=true)
  td.draw()
  td.run_for(player_desk_idle_ms + sleep_ms + step_ms)
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
  // Recovery re-arms full 2000ms
  td.set_player(1, position=2000.0, duration=10000.0, playing=true, buffering=false)
  td.draw()
  td.run_for(player_desk_idle_ms - step_ms)
  assert_true(td.query(Slider, label="web-pages.drive.player.position") is Some(_), msg="still visible at 1990ms after buffering ends")
  td.run_for(step_ms + sleep_ms + step_ms)
  assert_true(td.query(Slider, label="web-pages.drive.player.position") is None, msg="faded after full 2000ms + sleep_ms")
}

///|
test "wave27 R1: mouse drag on timeline/volume does not permanently lock chrome; Tab focus on top back button locks and re-arms" {
  let sleep_ms = @player.media_sleep_ms
  let step_ms = 10.0
  // 1. Mouse press & drag on timeline slider and volume slider, then move pointer back to stage -> fades normally
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
  t.run_for(player_desk_idle_ms + sleep_ms + step_ms)
  assert_true(t.query(Slider, label="web-pages.drive.player.position") is None, msg="timeline mouse drag must not leave focus lock")
  // Wake and repeat with volume slider
  t.move_to(640.0, 420.0)
  t.run_for(@player.media_wake_ms + step_ms)
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
  t.run_for(player_desk_idle_ms + sleep_ms + step_ms)
  assert_true(t.query(Slider, label="web-pages.drive.player.position") is None, msg="volume mouse drag must not leave focus lock")
  // 2. Keyboard Tab focus on desktop top-bar back button locks chrome past 2000ms; blurring re-arms full 2000ms
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
  t.run_for(player_desk_idle_ms + sleep_ms + step_ms)
  assert_true(t.query(Slider, label="web-pages.drive.player.position") is Some(_), msg="keyboard focus on back button locks chrome")
  // Clear visible keyboard focus by clicking stage (pointer click clears focus_shown)
  t.move_to(640.0, 400.0)
  t.tap(640.0, 400.0)
  t.draw()
  t.run_for(player_desk_idle_ms - step_ms)
  assert_true(t.query(Slider, label="web-pages.drive.player.position") is Some(_), msg="still visible at 1990ms after blur")
  t.run_for(step_ms + sleep_ms + step_ms)
  assert_true(t.query(Slider, label="web-pages.drive.player.position") is None, msg="faded after full 2000ms + sleep_ms post-blur")
}

///|
test "wave27 R1: timeline disabled during fade-out does not call scrub_done for stage AlongTime scrub" {
  let sleep_ms = @player.media_sleep_ms
  let step_ms = 10.0
  let t = player_tester(true, "a.mp4", [], [], [])
  t.draw()
  t.set_player(1, position=2000.0, duration=10000.0, playing=true)
  t.draw()
  // Trigger fade-out at 3000ms, advance halfway through sleep_ms (fading, not yet faded=true)
  t.run_for(player_touch_idle_ms + sleep_ms / 2.0)
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
  assert_eq(count_play_pause(t), c0 + 1, msg="post-breakpoint click dispatches cleanly")

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
test "wave27 R1: plain set_a11y does not lock chrome; reactive set_screen_reader wakes faded controls without manual draw and re-arms 2000ms" {
  let sleep_ms = @player.media_sleep_ms
  let step_ms = 20.0
  // 1. Plain set_a11y(true) (non-screen-reader AX/UIA client) must NOT lock controls: fades normally at 2000ms
  let t = player_tester(false, "a.mp4", [], [], [], pin={ ..pinned(2000.0), playing: false })
  t.host_says_finger(Some(false))
  t.set_a11y(true)
  t.draw()
  t.run_for(player_desk_idle_ms + sleep_ms + step_ms)
  assert_true(t.query(Slider, label="web-pages.drive.player.position") is None, msg="plain set_a11y(true) must not prevent 2000ms auto-fade")
  // 2. On the same paused faded instance, set_screen_reader(true) without manual draw() wakes & locks via frame step
  t.set_screen_reader(true)
  t.run_for(@player.media_wake_ms + step_ms)
  assert_true(t.query(Slider, label="web-pages.drive.player.position") is Some(_), msg="set_screen_reader(true) proactively wakes faded controls")
  t.run_for(player_desk_idle_ms + sleep_ms + step_ms)
  assert_true(t.query(Slider, label="web-pages.drive.player.position") is Some(_), msg="set_screen_reader(true) keeps controls locked")
  // 3. Turn screen reader off: re-arms full 2000ms
  t.set_screen_reader(false)
  t.run_for(player_desk_idle_ms - 100.0)
  assert_true(t.query(Slider, label="web-pages.drive.player.position") is Some(_), msg="still visible at 1900ms after screen reader off")
  t.run_for(100.0 + sleep_ms + step_ms)
  assert_true(t.query(Slider, label="web-pages.drive.player.position") is None, msg="faded after full 2000ms + sleep_ms")
}

///|
test "wave27 R2: touch 2999ms single-tap hides without 3000ms idle inversion; 2999ms double-tap seeks and re-arms idle" {
  let sleep_ms = @player.media_sleep_ms
  let step_ms = 10.0
  // 1. Playing, visible, unlocked -> advance to 2999ms -> single tap -> crosses 3000ms & 3299ms+sleep_ms: stays hidden!
  let t = player_tester(true, "a.mp4", [], [], [], pin=pinned(2000.0))
  t.draw()
  let double_ms = playing_for("k").media.times().1
  t.run_for(player_touch_idle_ms - 1.0)
  assert_true(t.query(Slider, label="web-pages.drive.player.position") is Some(_), msg="visible at 2999ms before tap")
  t.tap(195.0, 400.0)
  // Cross 3000ms (old idle deadline was cancelled) and double_ms + sleep_ms (single tap hides)
  t.run_for(double_ms + sleep_ms + step_ms)
  assert_true(t.query(Slider, label="web-pages.drive.player.position") is None, msg="2999ms single-tap intent must stay hidden, never inverted")
  // 2. At 2999ms, double-tap on right third still seeks +15s and re-arms 3000ms idle (not permanently locked)
  let td = player_tester(true, "a.mp4", [], [], [])
  td.draw()
  td.set_player(1, position=2000.0, duration=30000.0, playing=true)
  td.draw()
  let d_double = playing_for("k").media.times().1
  td.run_for(player_touch_idle_ms - 1.0)
  let s0 = count_controls(td, 3) + count_controls(td, 11)
  td.tap(320.0, 400.0)
  td.run_for(d_double / 3.0)
  td.tap(320.0, 400.0)
  td.draw()
  assert_true(count_controls(td, 3) + count_controls(td, 11) > s0, msg="2999ms double-tap right third seeks ahead")
  td.run_for(player_touch_idle_ms + sleep_ms + step_ms)
  assert_true(td.query(Slider, label="web-pages.drive.player.position") is None, msg="2999ms double-tap re-arms idle and fades")
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
test "wave27 R3: playing tap + breakpoint cross restores 3000ms idle; lock engaging mid-double_ms preserves awake for full 3000ms" {
  let sleep_ms = @player.media_sleep_ms
  let step_ms = 10.0
  // 1. Playing single tap -> cross wide/narrow breakpoint within double_ms -> no further input: auto-fades at 3000ms + sleep_ms
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
  // No further input: idle timer was restored by cancel_stage_gesture, so controls fade after 3000ms + sleep_ms
  t.run_for(player_touch_idle_ms + sleep_ms + step_ms)
  assert_true(t.query(Slider, label="web-pages.drive.player.position") is None, msg="playing tap + breakpoint cross must restore 3000ms auto-fade")
  assert_eq(count_play_pause(t), pp0, msg="zero play/pause fired")
  assert_eq(count_controls(t, 3) + count_controls(t, 11), sk0, msg="zero seek fired")

  // 2. Playing single tap on visible bar -> at 100ms set_screen_reader(true) -> cross double_ms -> set_screen_reader(false) -> full 3000ms!
  let t2 = player_tester(true, "a.mp4", [], [], [], pin=pinned(5000.0))
  t2.draw()
  let d2 = playing_for("k").media.times().1
  t2.tap(195.0, 400.0)
  t2.run_for(d2 / 3.0)
  t2.set_screen_reader(true)
  t2.run_for(d2 + step_ms) // single-tap callback fires while chrome_locked() is true -> must NOT overwrite awake=false
  assert_true(t2.query(Slider, label="web-pages.drive.player.position") is Some(_), msg="controls remain locked while screen reader on")
  t2.set_screen_reader(false)
  t2.run_for(player_touch_idle_ms - 100.0)
  assert_true(t2.query(Slider, label="web-pages.drive.player.position") is Some(_), msg="still visible at 2900ms after unlock")
  t2.run_for(100.0 + sleep_ms + step_ms)
  assert_true(t2.query(Slider, label="web-pages.drive.player.position") is None, msg="faded after full 3000ms + sleep_ms")

  // 3. Playing single tap on visible bar -> lock engages at 100ms AND releases at 200ms (all within double_ms=300ms):
  // stale single-tap hide at 300ms must be invalidated by lock_epoch, keeping the full 3000ms deadline from 200ms!
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
  // Advance to 2900ms after unlock (~200ms + 2900ms = 3100ms; we already ran d3/3 + step_ms since unlock)
  let elapsed_since_unlock = d3 / 3.0 + step_ms
  t3.run_for(player_touch_idle_ms - 100.0 - elapsed_since_unlock)
  assert_true(t3.query(Slider, label="web-pages.drive.player.position") is Some(_), msg="still visible at 2900ms after mid-tap unlock")
  t3.run_for(100.0 + sleep_ms + step_ms)
  assert_true(t3.query(Slider, label="web-pages.drive.player.position") is None, msg="faded after full 3000ms + sleep_ms from unlock")

  // 4. Faded state 0ms tap -> 100ms set_screen_reader(true) -> 200ms set_screen_reader(false):
  // stale single-tap want_show at 300ms must NOT postpone the 200ms + 3000ms deadline to 3300ms!
  let t4 = player_tester(true, "a.mp4", [], [], [], pin=pinned(5000.0))
  t4.draw()
  let d4 = playing_for("k").media.times().1
  t4.run_for(player_touch_idle_ms + sleep_ms + step_ms)
  assert_true(t4.query(Slider, label="web-pages.drive.player.position") is None, msg="controls faded before 0ms tap")
  t4.tap(195.0, 400.0)
  t4.run_for(d4 / 3.0) // 100ms
  t4.set_screen_reader(true)
  t4.run_for(d4 / 3.0) // 200ms
  t4.set_screen_reader(false)
  // Advance to 2900ms after unlock (200ms + 2900ms = 3100ms): still visible
  t4.run_for(player_touch_idle_ms - 100.0)
  assert_true(t4.query(Slider, label="web-pages.drive.player.position") is Some(_), msg="faded-start: still visible at 2900ms after unlock")
  // Advance 100ms + sleep_ms + step_ms (200ms + 3000ms + sleep_ms, BEFORE 3300ms + sleep_ms!): already faded!
  t4.run_for(100.0 + sleep_ms + step_ms)
  assert_true(t4.query(Slider, label="web-pages.drive.player.position") is None, msg="faded-start: stale want_show must not postpone deadline to 3300ms")
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
