// Phase 4 Anti-Silent-Snap gate (never listed in motion_counted or any *_known exemption table):
// 1. Failed message 重试 (MineUnsent -> MineTime): bubble settles smoothly across multiple frames without 1-frame snap.
// 2. Composer removing a file tile (alpha.txt out, beta.txt slides left): clean fade with zero words_over and smooth slide.
// 3. > 4 consecutive live messages arriving without interspersed agent replies (StageOrigin without chat_live_tail_most
//    truncation): 5th & 6th messages still animate smoothly without silent snap.

///|
fn p4_word_y(t : @ui.Tester, needle : String) -> Double? {
  for w in t.words() {
    if w.0.contains(needle) && w.5 > 0.02 {
      return Some(w.2)
    }
  }
  None
}

///|
fn p4_word_x(t : @ui.Tester, needle : String) -> (Double, Double)? {
  for w in t.words() {
    if w.0.contains(needle) && w.5 > 0.01 {
      return Some((w.1, w.5))
    }
  }
  None
}

///|
fn p4_step_dt(samples : Array[(Double, Double)]) -> Double {
  if samples.length() < 2 {
    return 1000.0
  }
  let span = samples[samples.length() - 1].0 - samples[0].0
  span / (samples.length() - 1).to_double()
}

///|
test "Phase 4 Anti-Silent-Snap: failed message retry keeps bubble stationary (equal 18pt height) and crossfades in place" {
  new_run()
  let clock : Ref[Double] = { val: 0.0 }
  fix_clock.val = Some(fn() { clock.val })
  let src = fixture("chat")
  open_chat({ station: "ws1/st1", session: "s-c1", title: "整理发布清单", station_name: "Willow" })
  let t = @ui.Tester::new(fn(c) { view(c, src) }, tree=app_tree(src), w=390.0, h=844.0, platform=2, words_over_held=true)
  t.set_rows_on_pixels(true)
  if !@ui.test_at_a_rate() {
    t.set_frame_period(1000.0 / 60.0)
  }
  t.run_for(@ui.move_most_ms)
  t.tap_text("发消息")
  t.type_text("这条会失败")
  tap_send(t)
  t.run_for(@ui.move_most_ms)
  let base_y = match p4_word_y(t, "这条会失败") {
    Some(y) => y
    None => fail("sent message bubble not visible before failure")
  }
  // 1) MineTime -> MineUnsent (async failure): zero vertical jump and right-aligned x anchor.
  let fail_ys : Array[(Double, Double)] = []
  let fail_unsent_xs : Array[(Double, Double, Double)] = []
  t.each_frame(Some(fn() {
    match p4_word_y(t, "这条会失败") {
      Some(y) => fail_ys.push((t.time(), y))
      None => ()
    }
    match p4_word_x(t, "未发送") {
      Some((x, a)) => fail_unsent_xs.push((t.time(), x, a))
      None => ()
    }
  }))
  fix_clock_set(clock, clock.val + fix_deliver_ms)
  t.draw()
  assert_true(t.find("未发送") is Some(_))
  t.run_for(@ui.move_most_ms)
  t.each_frame(None)
  let unsent_x = match p4_word_x(t, "未发送") {
    Some((x, _)) => x
    None => fail("未发送 not visible after failure settled")
  }
  for s in fail_ys {
    assert_true(
      (s.1 - base_y).abs() <= 0.5,
      msg="MineTime->MineUnsent: bubble shifted vertically to y=\{s.1} at t=\{s.0}, expected base_y=\{base_y}",
    )
  }
  for s in fail_unsent_xs {
    assert_true(
      (s.1 - unsent_x).abs() <= 1.0,
      msg="MineTime->MineUnsent: 未发送 drifted to x=\{s.1} (a=\{s.2}) at t=\{s.0}, expected resting x=\{unsent_x}",
    )
  }
  // 2) MineUnsent -> MineSending (retry tap): zero vertical jump, right-aligned x anchor, sequential crossfade.
  let retry_ys : Array[(Double, Double)] = []
  let retry_unsent_xs : Array[(Double, Double, Double)] = []
  let retry_unsent_fades : Array[(Double, Double)] = []
  let retry_sending_xs : Array[(Double, Double, Double)] = []
  let retry_overlaps : Array[String] = []
  t.each_frame(Some(fn() {
    match p4_word_y(t, "这条会失败") {
      Some(y) => retry_ys.push((t.time(), y))
      None => ()
    }
    let u = p4_word_x(t, "未发送")
    let s = p4_word_x(t, "正在发送")
    match (u, s) {
      (Some((ux, ua)), Some((sx, sa))) =>
        retry_overlaps.push("t=\{t.time()} u=(\{ux},\{ua}) s=(\{sx},\{sa})")
      _ => ()
    }
    match u {
      Some((x, a)) => {
        retry_unsent_xs.push((t.time(), x, a))
        if a > 0.01 && a < 0.99 {
          retry_unsent_fades.push((t.time(), a))
        }
      }
      None => ()
    }
    match s {
      Some((x, a)) => retry_sending_xs.push((t.time(), x, a))
      None => ()
    }
  }))
  t.tap_text("重试")
  t.run_for(@ui.move_most_ms)
  t.each_frame(None)
  let first_overlap = retry_overlaps.get(0).unwrap_or("")
  assert_true(
    retry_overlaps.is_empty(),
    msg="MineUnsent->MineSending: 未发送 and 正在发送 both visible on same frame (count=\{retry_overlaps.length()}, first=\{first_overlap})",
  )
  assert_true(retry_ys.length() >= 2, msg="expected >= 2 retry samples, got \{retry_ys.length()}")
  for s in retry_ys {
    assert_true(
      (s.1 - base_y).abs() <= 0.5,
      msg="MineUnsent->MineSending: bubble shifted vertically to y=\{s.1} at t=\{s.0}, expected base_y=\{base_y}",
    )
  }
  for s in retry_unsent_xs {
    assert_true(
      (s.1 - unsent_x).abs() <= 1.0,
      msg="MineUnsent->MineSending: leaving 未发送 drifted to x=\{s.1} (a=\{s.2}) at t=\{s.0}, expected x=\{unsent_x}",
    )
  }
  match p4_word_x(t, "正在发送") {
    Some((sending_x, _)) =>
      for s in retry_sending_xs {
        assert_true(
          (s.1 - sending_x).abs() <= 1.0,
          msg="MineUnsent->MineSending: entering 正在发送 drifted to x=\{s.1} (a=\{s.2}) at t=\{s.0}, expected x=\{sending_x}",
        )
      }
    None => ()
  }
  let dt = p4_step_dt(retry_ys)
  let need_fades = if dt <= 20.0 { 2 } else { 1 }
  assert_true(
    retry_unsent_fades.length() >= need_fades,
    msg="MineUnsent->MineSending: 未发送 vanished without fade frames @dt=\{dt}ms (got \{retry_unsent_fades.length()}, need \{need_fades})",
  )
  // 3) MineSending -> MineTime (retry delivered): fixture also starts agent activity below, sliding the list up;
  // verify under-line vertical geometry (y_under - y_bubble) matches across MineUnsent / MineSending / MineTime.
  let sending_dy = match (p4_word_y(t, "正在发送"), p4_word_y(t, "这条会失败")) {
    (Some(sy), Some(by)) => sy - by
    _ => fail("正在发送 or 这条会失败 missing before delivery")
  }
  fix_clock_set(clock, clock.val + fix_deliver_ms)
  t.draw()
  t.run_for(@ui.move_most_ms)
  assert_true(t.find("未发送") is None)
  assert_true(t.find("这条会失败") is Some(_))
  match (p4_word_y(t, "刚刚"), p4_word_y(t, "这条会失败")) {
    (Some(ty), Some(by)) => {
      let time_dy = ty - by
      assert_true(
        (time_dy - sending_dy).abs() <= 1.0,
        msg="MineSending->MineTime: under-line vertical offset changed from \{sending_dy} to \{time_dy}",
      )
    }
    _ => fail("刚刚 or 这条会失败 missing after delivery")
  }
  fix_clock.val = None
}

///|
test "Phase 4 Anti-Silent-Snap: composer removing alpha.txt fades cleanly without words_over while beta.txt slides smoothly" {
  let calls : Array[Made] = []
  let made : Ref[Source?] = Ref(None)
  let t = fake_core(calls, made~, platform=0)
  t.set_rows_on_pixels(true)
  if !@ui.test_at_a_rate() {
    t.set_frame_period(1000.0 / 60.0)
  }
  t.resize(1280.0, 844.0)
  t.run_for(@ui.move_most_ms)
  let src = made.val.unwrap()
  let wr = @sfbase.writing(src, "ws1/st1:s-c1")
  for name in ["alpha.txt", "beta.txt", "gamma.txt"] {
    @sfbase.writing_add(src, wr, "ws1/st1", name, b"release notes")
  }
  t.run_for(@ui.move_most_ms * 2.0)
  let alpha_at = cw_word(t, "alpha")
  let beta_at = cw_word(t, "beta")
  assert_true(alpha_at is Some(_) && beta_at is Some(_), msg="tiles not shown: \{Repr((alpha_at, beta_at))}")
  let (ax, _) = alpha_at.unwrap()
  let (bx, _) = beta_at.unwrap()
  assert_true(bx > ax + 40.0, msg="expected beta right of alpha: ax=\{ax}, bx=\{bx}")
  let alpha_fades : Array[(Double, Double)] = []
  let beta_xs : Array[(Double, Double)] = []
  t.each_frame(Some(fn() {
    match cw_word(t, "alpha") {
      Some((_, a)) if a > 0.01 && a < 0.99 => alpha_fades.push((t.time(), a))
      _ => ()
    }
    match cw_word(t, "beta") {
      Some((x, _)) => beta_xs.push((t.time(), x))
      None => ()
    }
  }))
  let (rx, ry, rw, rh) = t.query(Button, label=@sf.t("web-main.file.remove", args=[("name", "alpha.txt")])).unwrap().rect
  t.tap(rx + rw / 2.0, ry + rh / 2.0)
  t.run_for(@ui.move_most_ms * 2.0)
  t.each_frame(None)
  assert_true(cw_word(t, "alpha") is None, msg="alpha.txt still drawn after removal")
  match cw_word(t, "beta") {
    Some((end_bx, _)) => assert_true((end_bx - ax).abs() < 1.0, msg="beta.txt rests at \{end_bx}, expected \{ax}")
    None => fail("beta.txt gone after alpha removal")
  }
  let dt = p4_step_dt(beta_xs)
  let mut mid_frames = 0
  for s in beta_xs {
    if s.1 < bx - 1.0 && s.1 > ax + 1.0 {
      mid_frames += 1
    }
  }
  if dt <= 20.0 {
    assert_true(
      alpha_fades.length() >= 2,
      msg="alpha.txt vanished without intermediate fade frames @dt=\{dt}ms: \{Repr(alpha_fades)}",
    )
    assert_true(
      mid_frames >= 3,
      msg="beta.txt snapped @dt=\{dt}ms (mid=\{mid_frames}, ax=\{ax}, bx=\{bx})",
    )
  } else if dt <= 50.0 {
    assert_true(
      alpha_fades.length() >= 1 && mid_frames >= 2,
      msg="composer remove snapped @dt=\{dt}ms (fades=\{alpha_fades.length()}, mid=\{mid_frames})",
    )
  } else {
    assert_true(
      alpha_fades.length() >= 1 && mid_frames >= 1,
      msg="composer remove snapped @dt=\{dt}ms (fades=\{alpha_fades.length()}, mid=\{mid_frames})",
    )
  }
}

///|
test "Phase 4 Anti-Silent-Snap: 6 consecutive live messages past 4-item cap still animate smoothly without silent snap" {
  new_run()
  let clock : Ref[Double] = { val: 0.0 }
  fix_clock.val = Some(fn() { clock.val })
  let src = fixture("chat")
  open_chat({ station: "ws1/st1", session: "s-c1", title: "整理发布清单", station_name: "Willow" })
  let t = @ui.Tester::new(fn(c) { view(c, src) }, tree=app_tree(src), w=390.0, h=844.0, platform=2, words_over_held=true)
  t.set_rows_on_pixels(true)
  if !@ui.test_at_a_rate() {
    t.set_frame_period(1000.0 / 60.0)
  }
  t.run_for(@ui.move_most_ms)
  // Send 6 consecutive live messages without interspersed agent replies (locking StageOrigin > 4 invariant).
  let labels = ["一一", "先上屏", "作为文件", "先写一半", "先写的", "测试一下"]
  for i, label in labels {
    let idx = i + 1
    t.tap_text("发消息")
    t.type_text(label)
    let anchor_label = if idx >= 5 { Some(labels[i - 1]) } else { None }
    let base_y = match anchor_label {
      Some(prev) => p4_word_y(t, prev)
      None => None
    }
    let samples : Array[(Double, Double)] = []
    match anchor_label {
      Some(prev) =>
        t.each_frame(Some(fn() {
          match p4_word_y(t, prev) {
            Some(y) => samples.push((t.time(), y))
            None => ()
          }
        }))
      None => ()
    }
    tap_send(t)
    t.run_for(@ui.move_most_ms)
    t.each_frame(None)
    assert_true(t.find(label) is Some(_), msg="live message \{label} missing")
    match base_y {
      Some(by) => {
        assert_true(samples.length() >= 2, msg="msg #\{idx}: too few samples (\{samples.length()})")
        let end_y = samples[samples.length() - 1].1
        assert_true(
          by - end_y > 10.0,
          msg="msg #\{idx}: expected previous message to shift up > 10pt (base=\{by}, end=\{end_y})",
        )
        let dt = p4_step_dt(samples)
        let mut mid_frames = 0
        for s in samples {
          if s.1 < by - 1.0 && s.1 > end_y + 1.0 {
            mid_frames += 1
          }
        }
        let need = if dt <= 50.0 { 2 } else { 1 }
        assert_true(
          mid_frames >= need,
          msg="msg #\{idx} (past 4-item cap) snapped @dt=\{dt}ms (base=\{by}, end=\{end_y}, mid=\{mid_frames})",
        )
      }
      None => ()
    }
  }
  fix_clock.val = None
}
