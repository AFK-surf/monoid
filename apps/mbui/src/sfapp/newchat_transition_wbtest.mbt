// Forward motion continuity tests for the node-based NewChat -> Chat transition (Small & Large screens),
// using Tester::sample_frames and MotionProbe checks to catch instant cuts, initial stalls, and height collapses.

///|
fn trans_word_alpha(t : @ui.Tester, text : String) -> Double {
  let mut best = 0.0
  for w in t.words() {
    if w.0 == text && w.5 > best {
      best = w.5
    }
  }
  best
}

///|
fn trans_word_alpha_near_x(t : @ui.Tester, text : String, x0 : Double) -> Double {
  let mut best = 0.0
  for w in t.words() {
    if w.0 == text && (w.1 - x0).abs() < 12.0 && w.5 > best {
      best = w.5
    }
  }
  best
}

///|
fn trans_word_pos(t : @ui.Tester, text : String) -> (Double, Double)? {
  let mut best : (Double, Double)? = None
  for w in t.words() {
    if w.0.contains(text) && w.5 > 0.05 {
      match best {
        None => best = Some((w.1, w.2))
        Some((bx, _)) => if w.1 > bx { best = Some((w.1, w.2)) }
      }
    }
  }
  best
}

///|
/// Find the drawn glass rectangle matching the composer box (wide enough and in the main pane, below the top bar).
fn trans_composer_glass_rect(t : @ui.Tester, min_x : Double, min_w : Double) -> (Double, Double, Double, Double)? {
  let mut best : (Double, Double, Double, Double)? = None
  for g in t.drawn_glass() {
    let (x, y, w, h, kind, _) = g
    if kind == 6 && x >= min_x && w >= min_w && y >= 100.0 && h >= 36.0 {
      match best {
        None => best = Some((x, y, w, h))
        Some((_, by, _, _)) => if y > by { best = Some((x, y, w, h)) }
      }
    }
  }
  best
}

///|
test "小屏 NewChat -> Chat: 顶栏取消平滑淡出、胶囊平滑淡出、欢迎场景平滑淡出、发送文字 40ms 后立即起飞" {
  let (t, _) = made_tester(390.0, 844.0, 2)
  let (_, y) = bar_places_at()
  t.tap(bar_action_x, y)
  t.run_for(@ui.move_most_ms)
  assert_true(app.nav.top() is NewChat)

  let words = "看下进度"
  t.tap_text("做任何事")
  t.type_text(words)
  t.draw()

  // Before send: 取消, Willow capsule, and scene title are fully visible.
  assert_true(trans_word_alpha(t, "取消") > 0.95)
  assert_true(trans_word_alpha(t, "Willow") > 0.95)
  assert_true(trans_word_alpha(t, "想让 agent 做什么？") > 0.95)
  let willow_x0 = match t.words().iter().find_first(fn(w) { w.0 == "Willow" && w.5 > 0.95 }) {
    Some(w) => w.1
    None => fail("Willow capsule not found before send")
  }

  tap_send(t)
  t.draw()
  assert_true(app.nav.top() is Chat(_))

  let samples = t.sample_frames(220.0, step=16.0, fn(tt, _) {
    (
      trans_word_alpha(tt, "取消"),
      trans_word_alpha_near_x(tt, "Willow", willow_x0),
      trans_word_alpha(tt, "想让 agent 做什么？"),
      trans_word_pos(tt, words).unwrap_or((0.0, 0.0)),
    )
  })

  let cancel_alpha = samples.map(fn(s) { (s.0, s.1.0) })
  let capsule_alpha = samples.map(fn(s) { (s.0, s.1.1) })
  let scene_alpha = samples.map(fn(s) { (s.0, s.1.2) })
  let (x0, y0) = samples[0].1.3
  let word_dist = samples.map(fn(s) {
    let (x, y) = s.1.3
    (s.0, ((x - x0) * (x - x0) + (y - y0) * (y - y0)).sqrt())
  })

  match @ui.check_smooth_fade(cancel_alpha, from=1.0, to=0.0) {
    Ok(_) => ()
    Err(e) => fail("取消 bar_out: \{e}")
  }
  match @ui.check_smooth_fade(capsule_alpha, from=1.0, to=0.0) {
    Ok(_) => ()
    Err(e) => fail("Willow choices_out: \{e}")
  }
  match @ui.check_smooth_fade(scene_alpha, from=1.0, to=0.0) {
    Ok(_) => ()
    Err(e) => fail("scene_out: \{e}")
  }
  // Sent words must start moving within 40ms after the 40ms flight delay (no 90ms dead stall).
  match @ui.check_no_stall(word_dist, delay_ms=40.0, start_window_ms=40.0, min_delta=1.5) {
    Ok(_) => ()
    Err(e) => fail("sent words flight: \{e}")
  }
}

///|
test "小屏 NewChat 3 行文本发送: 首帧输入框高度连续不塌陷，随后平滑回落至单行高度" {
  let (t, _) = made_tester(390.0, 844.0, 2)
  let (_, y) = bar_places_at()
  t.tap(bar_action_x, y)
  t.run_for(@ui.move_most_ms)
  assert_true(app.nav.top() is NewChat)

  t.tap_text("做任何事")
  t.type_text("第一行")
  t.key(@ui.key_code_enter, mods=@ui.mod_shift_key)
  t.type_text("第二行")
  t.key(@ui.key_code_enter, mods=@ui.mod_shift_key)
  t.type_text("第三行")
  t.run_for(@ui.move_most_ms)

  guard trans_composer_glass_rect(t, 0.0, 200.0) is Some(start_rect) else {
    fail("narrow 3-line composer glass rect not found before send")
  }
  guard trans_word_pos(t, "Willow") is Some((_, willow_pre_y)) else {
    fail("Willow capsule not found before 3-line send")
  }

  tap_send(t)
  t.draw()
  assert_true(app.nav.top() is Chat(_))

  let sampled = t.sample_frames(@ui.move_most_ms + 80.0, step=16.0, fn(tt, _) {
    (
      trans_composer_glass_rect(tt, 0.0, 200.0).unwrap_or((0.0, 0.0, 0.0, 0.0)),
      trans_word_pos(tt, "Willow").map(fn(p) { p.1 }),
    )
  })
  for s in sampled {
    let (dt, (_, wy_opt)) = s
    if dt <= 80.0 {
      if wy_opt is Some(wy) {
        assert_true(
          wy <= willow_pre_y + 1.0,
          msg="Willow capsule dropped into 3-line composer at t=\{dt}ms: pre=\{willow_pre_y}, got=\{wy}",
        )
      }
    }
  }
  let samples = sampled.map(fn(s) { (s.0, s.1.0) })

  match @ui.check_rect_continuity(samples, start_rect~, max_frame0_jump=2.5, max_step_jump=60.0) {
    Ok(_) => ()
    Err(e) => fail("narrow 3-line composer continuity: \{e}")
  }
  let end_h = samples[samples.length() - 1].1.3
  assert_true(
    start_rect.3 - end_h > 20.0,
    msg="expected 3-line composer (\{start_rect.3}) to collapse smoothly toward 1-line (\{end_h})",
  )
}

///|
test "大屏 NewChat -> Chat 发送: 输入框首帧保持 roomy 真实高度无砍顶、前 40ms 即开始平滑下落" {
  let (t, _) = made_tester(1280.0, 800.0, 0)
  t.run_for(@ui.move_most_ms)
  assert_true(app.nav.top() is NewChat)

  t.tap_text("做任何事")
  t.type_text("把发布说明写一下")
  t.draw()

  guard @sfpages.composer_node_box(@sfpages.new_chat_drafts + "ws1") is Some(start_rect) else {
    fail("wide NewChat composer box not found")
  }
  assert_true(start_rect.3 > 80.0, msg="expected roomy composer height > 80, got \{start_rect.3}")

  tap_send(t)
  t.draw()
  assert_true(app.nav.top() is Chat(_))

  let samples = t.sample_frames(@ui.move_most_ms + 40.0, step=16.0, fn(tt, _) {
    trans_composer_glass_rect(tt, 250.0, 300.0).unwrap_or((0.0, 0.0, 0.0, 0.0))
  })

  match @ui.check_rect_continuity(samples, start_rect~, max_frame0_jump=2.5, max_step_jump=80.0) {
    Ok(_) => ()
    Err(e) => fail("wide NewChat -> Chat composer morph: \{e}")
  }
  let ys = samples.map(fn(s) { (s.0, s.1.1) })
  match @ui.check_no_stall(ys, delay_ms=0.0, start_window_ms=40.0, min_delta=1.5) {
    Ok(_) => ()
    Err(e) => fail("wide composer drop stall: \{e}")
  }
  let end_rect = samples[samples.length() - 1].1
  assert_true(
    end_rect.1 > start_rect.1 + 100.0,
    msg="expected composer to land at foot: start=\{@ui.rect_text(start_rect)}, end=\{@ui.rect_text(end_rect)}",
  )
}

///|
test "大屏侧栏 NewChat <-> Chat 双向切换: 输入框平滑往返变形无瞬移" {
  let (t, _) = made_tester(1280.0, 800.0, 0)
  t.run_for(@ui.move_most_ms)
  assert_true(app.nav.top() is NewChat)

  guard @sfpages.composer_node_box(@sfpages.new_chat_drafts + "ws1") is Some(new_rect) else {
    fail("wide NewChat composer box not found")
  }

  // Sidebar click: NewChat -> existing Chat
  t.tap_text("整理发布清单")
  t.draw()
  assert_true(app.nav.top() is Chat(_))

  let to_chat = t.sample_frames(@ui.move_most_ms + 40.0, step=16.0, fn(tt, _) {
    trans_composer_glass_rect(tt, 250.0, 300.0).unwrap_or((0.0, 0.0, 0.0, 0.0))
  })
  match @ui.check_rect_continuity(to_chat, start_rect=new_rect, max_frame0_jump=2.5, max_step_jump=80.0) {
    Ok(_) => ()
    Err(e) => fail("sidebar NewChat -> Chat morph: \{e}")
  }
  match @ui.check_no_stall(to_chat.map(fn(s) { (s.0, s.1.1) }), delay_ms=0.0, start_window_ms=40.0, min_delta=1.5) {
    Ok(_) => ()
    Err(e) => fail("sidebar NewChat -> Chat stall: \{e}")
  }

  let chat_rect = to_chat[to_chat.length() - 1].1
  assert_true(chat_rect.1 > new_rect.1 + 100.0)

  // Sidebar click: Chat -> NewChat
  t.tap_text("新建对话")
  t.draw()
  assert_true(app.nav.top() is NewChat)

  let to_new = t.sample_frames(@ui.move_most_ms + 40.0, step=16.0, fn(tt, _) {
    trans_composer_glass_rect(tt, 250.0, 300.0).unwrap_or((0.0, 0.0, 0.0, 0.0))
  })
  match @ui.check_rect_continuity(to_new, start_rect=chat_rect, max_frame0_jump=2.5, max_step_jump=80.0) {
    Ok(_) => ()
    Err(e) => fail("sidebar Chat -> NewChat morph: \{e}")
  }
  match @ui.check_no_stall(to_new.map(fn(s) { (s.0, s.1.1) }), delay_ms=0.0, start_window_ms=40.0, min_delta=1.5) {
    Ok(_) => ()
    Err(e) => fail("sidebar Chat -> NewChat stall: \{e}")
  }
}

///|
test "小屏 newChat.create 失败中途倒带: 场景与胶囊平滑恢复无跳变" {
  new_run()
  let base = fixture("home")
  let fail_create : Ref[(() -> Unit)?] = Ref(None)
  let src : Source = {
    ..base,
    call: fn(name, params, done) {
      if name == "newChat.create" {
        fail_create.val = Some(fn() { done(Err({ "message": Json::string("create failed") })) })
      } else {
        (base.call)(name, params, done)
      }
    },
  }
  let t = @ui.Tester::new(fn(c) { view(c, src) }, tree=app_tree(src), w=390.0, h=844.0, platform=2)
  let (_, y) = bar_places_at()
  t.tap(bar_action_x, y)
  t.run_for(@ui.move_most_ms)
  assert_true(app.nav.top() is NewChat)

  t.tap_text("做任何事")
  t.type_text("把发布说明写一下")
  t.draw()
  tap_send(t)
  t.draw()
  assert_true(app.nav.top() is Chat(_))

  // Advance mid-way into scene & choices fade out.
  let mid_ms = 60.0
  t.run_for(mid_ms)
  let mid_scene = trans_word_alpha(t, "想让 agent 做什么？")
  assert_true(mid_scene > 0.05 && mid_scene < 0.95, msg="expected mid fade, got \{mid_scene}")

  // Fail newChat.create mid-flight!
  guard fail_create.val is Some(reject) else { fail("newChat.create was not called") }
  reject()
  t.draw()
  assert_true(app.nav.top() is NewChat)

  let back_samples = t.sample_frames(180.0, step=16.0, fn(tt, _) {
    (trans_word_alpha(tt, "想让 agent 做什么？"), trans_word_alpha(tt, "Willow"))
  })
  // No jump at reversal frame 0, and smooth recovery back to 1.0.
  let f0_scene = back_samples[0].1.0
  let end_scene = back_samples[back_samples.length() - 1].1.0
  let end_capsule = back_samples[back_samples.length() - 1].1.1
  assert_true((f0_scene - mid_scene).abs() < 0.25, msg="scene jumped on reverse: mid=\{mid_scene}, f0=\{f0_scene}")
  assert_true(
    end_scene > 0.95,
    msg="scene did not recover to 1.0: mid=\{mid_scene}, f0=\{f0_scene}, end=\{end_scene}, choreo_end=\{@sfbase.fresh_choreo.val.ends_at()}, now=\{t.time()}",
  )
  assert_true(end_capsule > 0.95, msg="Willow capsule did not recover to 1.0: end=\{end_capsule}")
}
