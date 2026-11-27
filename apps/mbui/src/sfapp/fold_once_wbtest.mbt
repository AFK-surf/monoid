// The block's way between open and folded (sfdesk's pane_view.mbt): each frame built once, the page getting wider or
// narrower telling nothing that reads only how tall its composer is (@motion.measured); the sidebar's rows and the
// chat's kept as they were built, what moves each frame building none of them again; the chat's old view laid out where
// the way ends and moved there by its node, built as a way sets off and at no other frame of it (page_pane.mbt
// pane_fold_held).

///|
test "大屏: on the block's way each frame built once, the lists' rows kept" {
  let calls : Array[Made] = []
  let t = wide_tester(calls, mode="chat")
  t.set_rows_on_pixels(true)
  t.run_for(kept_rows_still_ms)
  let t0 = t.time()
  t.advance(between_frames_ms)
  @sfdesk.wide.folded.set(true)
  // (its first frames building them once for all of its way)
  t.frame_at(t0 + 40.0)
  t.frame_at(t0 + 60.0)
  let on_way : Array[Int] = []
  for at in [80.0, 100.0, 120.0] {
    t.frame_at(t0 + at)
    on_way.push(t.frame_perf().passes)
  }
  assert_eq(on_way, [1, 1, 1])
}

///|
test "大屏: on the block's way a chat's column as wide as at either end, its words not laid out otherwise" {
  let calls : Array[Made] = []
  let t = wide_tester(calls, mode="chat-long")
  t.set_rows_on_pixels(true)
  t.run_for(kept_rows_still_ms)
  let line = "和首页那边的改动有关"
  let size = fn() {
    guard t.rect_of(line) is Some((_, _, w, h)) else { return (-1.0, -1.0) }
    (w, h)
  }
  let was = size()
  assert_true(was.0 > 0.0)
  let t0 = t.time()
  t.advance(between_frames_ms)
  @sfdesk.wide.folded.set(true)
  for at in [40.0, 80.0, 120.0, 200.0] {
    t.frame_at(t0 + at)
    assert_eq(size(), was)
  }
}

///|
test "大屏: folding to the board does not rebuild the old view on each frame" {
  let (t, _) = board_at("board-list", 1280.0, 800.0)
  t.click(Button, label="看板")
  let start = t.time()
  for after in [80.0, 100.0, 120.0] {
    t.frame_at(start + after)
    let p = t.frame_perf()
    assert_true(p.nodes <= 5, msg="at \{after}: \{p.nodes}, \{t.built_why()}")
  }
}

///|
test "大屏: the chats key pressed twice, the chat's old view built only as each way sets off, not at each frame" {
  let calls : Array[Made] = []
  let t = wide_tester(calls, mode="chat")
  t.set_rows_on_pixels(true)
  t.run_for(kept_rows_still_ms)
  let (x, y, w, h) = t.query(Button, label="对话").unwrap().rect
  let press = fn() { t.tap(x + w / 2.0, y + h / 2.0) }
  let t0 = t.time()
  // (pressed, and again as the sidebar is on its way to be shown a while: a double click; what the frame after each
  // press builds is that press's, every other frame of the ways builds nothing of the old view)
  let presses = [8.0, 88.0]
  let built : Array[String] = []
  let mut after_press = false
  for at = 16.0; at <= 480.0; at = at + 16.0 {
    for p in presses {
      if p > at - 16.0 && p <= at {
        t.advance(t0 + p - t.time())
        press()
        after_press = true
      }
    }
    t.frame_at(t0 + at)
    let why = t.built_why()
    if !after_press && why != "" && why != "the one before it laid out otherwise" {
      built.push("\{at}: \{why}")
    }
    after_press = false
  }
  assert_false(@sfdesk.wide.folded.get())
  assert_eq(built, [])
}

///|
/// The rail's chats key pressed on 大屏 over the new chat (platform 0, or 1 beside the system's bars), the sidebar
/// folded and then shown again: the new chat's old view is laid out anew at each width of both ways as before, not held
/// where the way ends as a chat's is (pane_fold_held), so its prompt goes with the pane and steps nowhere (the
/// Tester's sizes_steady, on the frames drawn along run_for at 60 and 120 fps).
fn fold_new_chat(platform : Int) -> Unit raise {
  // (made here, not by wide_tester: its file's motion is counted, this file's held to steady)
  new_run()
  let src = fixture("home")
  let t = @ui.Tester::new(fn(c) { view(c, src) }, tree=app_tree(src), w=1280.0, h=800.0, platform~)
  t.run_for(@ui.move_most_ms)
  let prompt = "想让 agent 做什么？"
  assert_true(t.rect_of(prompt) is Some(_), msg="no new chat: \{Repr(t.words())}")
  let keys = t.all(Button).filter(fn(b) { b.rect.0 < 70.0 })
  guard keys.search_by(fn(b) { b.label == "对话" || b.label == "全部对话" || b.label == "全部" }) is Some(i) else {
    fail("no chats' key in the rail: \{keys.map(fn(b) { b.label }).join(", ")}")
  }
  let (x, y, w, h) = keys[i].rect
  for folded in [true, false] {
    t.tap(x + w / 2.0, y + h / 2.0)
    t.run_for(@ui.move_most_ms)
    assert_eq((@sfdesk.side_folded(), t.rect_of(prompt) is Some(_)), (folded, true))
  }
}

///|
test "大屏: the chats key pressed twice over the new chat, its prompt going with the pane both ways" {
  fold_new_chat(0)
}

///|
test "大屏 beside the system's bars: the chats key pressed twice over the new chat, its prompt going with the pane both ways" {
  fold_new_chat(1)
}

///|
test "大屏窄宽节点对话页：折叠/展开左栏及对话↔Station切换中正文不重排折行且全程稳定" {
  new_run()
  let src = fixture("chat-long")
  open_chat({ station: "ws1/st1", session: "s-c1", title: "整理发布清单", station_name: "Willow" })
  // (w=960: pane=960-48-240=672 < 840 when open, 960-48=912 > 840 when folded — crosses the 840px wrap threshold)
  let t = @ui.Tester::new(fn(c) { view(c, src) }, tree=app_tree(src), w=960.0, h=800.0)
  t.run_for(@ui.move_most_ms)
  let line = "和首页那边的改动有关"
  let size = fn() {
    guard t.rect_of(line) is Some((_, _, w, h)) else { return (-1.0, -1.0) }
    (w, h)
  }
  let open_size = size()
  assert_true(open_size.0 > 0.0, msg="missing chat line at start")
  // Fold left sidebar: column holds target width from start of transition (zero mid-flight reflow)
  let t0 = t.time()
  t.advance(between_frames_ms)
  @sfdesk.wide.folded.set(true)
  t.frame_at(t0 + 40.0)
  let fold_size = size()
  assert_true(fold_size.0 > 0.0, msg="missing chat line mid-fold")
  for at in [80.0, 120.0, 200.0] {
    t.frame_at(t0 + at)
    assert_eq(size(), fold_size, msg="node chat reflowed mid-fold at \{at}")
  }
  t.run_for(@ui.move_most_ms)
  assert_eq(size(), fold_size, msg="node chat settled size differs from held target")
  // Unfold left sidebar back: holds open target width throughout transition
  let t1 = t.time()
  t.advance(between_frames_ms)
  @sfdesk.wide.folded.set(false)
  t.frame_at(t1 + 40.0)
  let unfold_size = size()
  assert_eq(unfold_size, open_size, msg="unfold target size mismatch")
  for at in [80.0, 120.0, 200.0] {
    t.frame_at(t1 + at)
    assert_eq(size(), unfold_size, msg="node chat reflowed mid-unfold at \{at}")
  }
  t.run_for(@ui.move_most_ms)
  // Switch 对话 (240) -> Station (280) -> 对话 (240) cleanly with sizes_steady
  t.click(Button, label="Station：Station")
  t.run_for(@ui.move_most_ms)
  t.click(Button, label="对话")
  t.move_to(500.0, 400.0)
  t.run_for(@ui.move_most_ms)
  if size().0 < 0.0 {
    t.tap_text("整理发布清单")
    t.run_for(@ui.move_most_ms)
  }
  assert_eq(size(), open_size, msg="node chat size after Station round-trip")
}

///|
/// Build a desktop Tester with optional `prefs.windowZoom` override for sidebar fold/unfold stability checks.
fn fold_steady_tester(
  inset : Bool,
  corner : Double,
  scale : Double,
  zoom_str : String,
  h? : Double = 800.0,
) -> (@ui.Tester, Source) {
  new_run()
  let base = fixture("chat")
  let src : Source = {
    ..base,
    topic_read: fn(name, params) {
      let st = base.topic(name, params).get().snapshot()
      if name == "prefs" && zoom_str != "100" {
        match st.value {
          Some(Object(m)) => {
            let m2 = m.copy()
            m2["windowZoom"] = Json::string(zoom_str)
            { ..st, value: Some(Json::object(m2)) }
          }
          _ => st
        }
      } else {
        st
      }
    },
  }
  let t = @ui.Tester::new(
    fn(ctx) { view(ctx, src) },
    tree=app_tree(src),
    w=1280.0,
    h~,
    platform=0,
    window_inset=inset,
    window_corner=corner,
    scale~,
  )
  t.set_rows_on_pixels(true)
  t.run_for(@ui.move_most_ms)
  (t, src)
}

///|
/// Find a sidebar label's drawn box (left of x < 240, and within 40pt of `near` when given so page headers sliding
/// across the pane cannot masquerade as the clipped sidebar row) and its first drawn glyph `(x, y, atlas_u)`.
fn sidebar_word_sample(
  t : @ui.Tester,
  label : String,
  near? : (Double, Double),
) -> ((Double, Double, Double, Double), (Double, Double, Double))? {
  let boxes = t.boxes_held()
  // Walk in reverse so the sidebar overlay (`sides`) is inspected before the page pane behind it.
  for i = boxes.length() - 1; i >= 0; i = i - 1 {
    let b = boxes[i]
    if b.text != label || b.x >= 240.0 {
      continue
    }
    match near {
      Some((nx, ny)) if (b.x - nx).abs() > 40.0 || (b.y - ny).abs() > 40.0 => continue
      _ => ()
    }
    let span_w = if b.w > 0.0 { b.w } else { 40.0 }
    let span_h = if b.h > 0.0 { b.h } else { 24.0 }
    for inst in t.drawn_instances() {
      if inst.length() > 15 &&
        (inst[5] == 1.0 || inst[5] == 7.0) &&
        inst[11] > 0.01 &&
        inst[0] >= b.x - 2.0 &&
        inst[0] <= b.x + span_w + 2.0 &&
        inst[1] >= b.y - 4.0 &&
        inst[1] <= b.y + span_h + 4.0 {
        return Some(((b.x, b.y, b.w, b.h), (inst[0], inst[1], inst[12])))
      }
    }
  }
  None
}

///|
fn assert_sidebar_pinned(
  tag : String,
  phase : String,
  step : Double,
  rest : ((Double, Double, Double, Double), (Double, Double, Double)),
  cur : ((Double, Double, Double, Double), (Double, Double, Double)),
) -> Unit raise {
  let ((rx, ry, _, _), (rgx, rgy, ru)) = rest
  let ((x, y, _, _), (gx, gy, u)) = cur
  assert_true(
    (x - rx).abs() <= 1.0e-5 && (y - ry).abs() <= 1.0e-5,
    msg="\{tag} \{phase} t=\{step}: box drifted dx=\{x - rx} dy=\{y - ry}",
  )
  assert_true(
    (gx - rgx).abs() <= 1.0e-5 && (gy - rgy).abs() <= 1.0e-5 && u == ru,
    msg="\{tag} \{phase} t=\{step}: glyph drifted/rephased dx=\{gx - rgx} dy=\{gy - rgy} u=\{u} vs \{ru}",
  )
}

///|
test "大屏: collapsing, unfolding and mid-fold reversing keeps Profiles sidebar text pinned with zero glyph drift or rephase" {
  let cases : Array[(String, Bool, Double, Double, String)] = [
    ("win-c16-s2-z100", true, 16.0, 2.0, "100"),
    ("win-c16-s2-z80", true, 16.0, 2.0, "80"),
    ("win-c16-s2-z90", true, 16.0, 2.0, "90"),
    ("win-c16-s2-z110", true, 16.0, 2.0, "110"),
    ("win-c26-s2-z110", true, 26.0, 2.0, "110"),
    ("fs-c0-s2-z100", false, 0.0, 2.0, "100"),
    ("fs-c16-s2-z100", false, 16.0, 2.0, "100"),
    ("win-c16-s1.5-z100", true, 16.0, 1.5, "100"),
  ]
  for c in cases {
    let (tag, inset, corner, scale, zstr) = c
    let (t, src) = fold_steady_tester(inset, corner, scale, zstr)
    let w = @sfbase.workspace_in_view(src).0.unwrap()
    @sfdesk.rail_go(t.ctx(), src, w, "profiles")
    t.run_for(@ui.move_most_ms)
    let rest = sidebar_word_sample(t, "概览").unwrap()
    let near = (rest.0.0, rest.0.1)
    // 1. Collapse (Open -> Folded): early frames must be visible and pinned
    let t0 = t.time()
    t.advance(between_frames_ms)
    @sfdesk.wide.folded.set(true)
    for step in [16.0, 32.0, 48.0, 64.0, 80.0, 96.0, 128.0] {
      t.frame_at(t0 + step)
      match sidebar_word_sample(t, "概览", near~) {
        Some(cur) => assert_sidebar_pinned(tag, "collapse", step, rest, cur)
        None => assert_true(step > 32.0, msg="\{tag} collapse t=\{step}: sidebar label missing unexpectedly")
      }
    }
    t.run_for(@ui.move_most_ms)
    // 2. Expand (Folded -> Open): late frames must be visible and pinned
    let t1 = t.time()
    t.advance(between_frames_ms)
    @sfdesk.wide.folded.set(false)
    for step in [64.0, 96.0, 128.0, 160.0, 200.0, 240.0, 280.0, 320.0] {
      t.frame_at(t1 + step)
      match sidebar_word_sample(t, "概览", near~) {
        Some(cur) => assert_sidebar_pinned(tag, "expand", step, rest, cur)
        None => assert_true(step < 200.0, msg="\{tag} expand t=\{step}: sidebar label missing unexpectedly")
      }
    }
    t.run_for(@ui.move_most_ms)
    assert_sidebar_pinned(tag, "expand-rest", 0.0, rest, sidebar_word_sample(t, "概览", near~).unwrap())
    // 3. Mid-collapse reversal (Open -> Folded -> Open)
    let t2 = t.time()
    t.advance(between_frames_ms)
    @sfdesk.wide.folded.set(true)
    t.frame_at(t2 + 32.0)
    t.frame_at(t2 + 64.0)
    t.advance(between_frames_ms)
    @sfdesk.wide.folded.set(false)
    for step in [80.0, 112.0, 160.0, 240.0] {
      t.frame_at(t2 + step)
      match sidebar_word_sample(t, "概览", near~) {
        Some(cur) => assert_sidebar_pinned(tag, "rev-open", step, rest, cur)
        None => assert_true(step < 160.0, msg="\{tag} rev-open t=\{step}: sidebar label missing unexpectedly")
      }
    }
    t.run_for(@ui.move_most_ms)
    // 4. Mid-expand reversal (Folded -> Open -> Folded, both mid-flight and in the final 1% where showing >= 0.99)
    for late in [false, true] {
      @sfdesk.wide.folded.set(true)
      t.run_for(@ui.move_most_ms)
      let t3 = t.time()
      t.advance(between_frames_ms)
      @sfdesk.wide.folded.set(false)
      let mut rev_at = 96.0
      if late {
        let mut found = false
        for probe = 160.0; probe <= 420.0; probe = probe + 4.0 {
          match @sfdesk.pane_reach_at(t3 + probe) {
            Some((_, _, _, sh)) if sh >= 0.99 && sh < 0.999999 => {
              rev_at = probe
              found = true
              break
            }
            _ => ()
          }
        }
        assert_true(found, msg="\{tag}: could not find showing >= 0.99 mid-expand moment")
      }
      t.frame_at(t3 + rev_at - 16.0)
      t.frame_at(t3 + rev_at)
      t.advance(between_frames_ms)
      @sfdesk.wide.folded.set(true)
      for delta in [16.0, 32.0, 48.0, 64.0] {
        let step = rev_at + delta
        t.frame_at(t3 + step)
        match sidebar_word_sample(t, "概览", near~) {
          Some(cur) => assert_sidebar_pinned(tag, "rev-close-\{late}", step, rest, cur)
          None => assert_true(delta > 32.0, msg="\{tag} rev-close-\{late} t=\{step}: sidebar label missing unexpectedly")
        }
      }
      t.run_for(@ui.move_most_ms)
    }
  }
}

///|
test "大屏: Open <-> Peek interpolates smoothly without pinning, and Peek <-> Folded stays pinned" {
  let (tw, srcw) = fold_steady_tester(true, 16.0, 2.0, "110")
  let ww = @sfbase.workspace_in_view(srcw).0.unwrap()
  @sfdesk.rail_go(tw.ctx(), srcw, ww, "profiles")
  tw.run_for(@ui.move_most_ms)
  let open_w = sidebar_word_sample(tw, "概览").unwrap()
  let near_w = (open_w.0.0, open_w.0.1)
  tw.move_to(24.0, 200.0)
  let t0 = tw.time()
  tw.advance(between_frames_ms)
  @sfdesk.wide.folded.set(true)
  @sfdesk.wide.peeking.set(true)
  let mut saw_mid_x = false
  for step in [16.0, 32.0, 48.0, 64.0, 96.0, 144.0, 220.0] {
    tw.frame_at(t0 + step)
    let cur = sidebar_word_sample(tw, "概览", near=near_w).unwrap()
    if (cur.0.0 - open_w.0.0).abs() > 0.1 {
      saw_mid_x = true
    }
  }
  assert_true(saw_mid_x, msg="Open->Peek was wrongly pinned horizontally")
  tw.run_for(@ui.move_most_ms)
  let peek_w = sidebar_word_sample(tw, "概览", near=near_w).unwrap()
  // Peek -> Folded must stay pinned at peek_w (set peeking=false before moving pointer away so peek-away never fires)
  let t1 = tw.time()
  tw.advance(between_frames_ms)
  @sfdesk.wide.peeking.set(false)
  for step in [16.0, 32.0, 48.0, 80.0] {
    tw.frame_at(t1 + step)
    match sidebar_word_sample(tw, "概览", near=(peek_w.0.0, peek_w.0.1)) {
      Some(cur) => assert_sidebar_pinned("win-z110", "peek-collapse", step, peek_w, cur)
      None => assert_true(step > 32.0, msg="win-z110 peek-collapse t=\{step}: missing label")
    }
  }
  tw.run_for(@ui.move_most_ms)
  // Folded -> Peek must also stay pinned at peek_w
  let t2 = tw.time()
  tw.advance(between_frames_ms)
  @sfdesk.wide.peeking.set(true)
  for step in [80.0, 144.0, 220.0, 300.0] {
    tw.frame_at(t2 + step)
    match sidebar_word_sample(tw, "概览", near=(peek_w.0.0, peek_w.0.1)) {
      Some(cur) => assert_sidebar_pinned("win-z110", "peek-expand", step, peek_w, cur)
      None => assert_true(step < 220.0, msg="win-z110 peek-expand t=\{step}: missing label")
    }
  }
  tw.run_for(@ui.move_most_ms)
}

///|
test "大屏: collapsing and unfolding Chats, Files and Settings sidebars keeps action band and list rows pinned" {
  // h=750 also guards against `section_rows` flipping across the 720pt threshold mid-fold
  for cfg in [("win-c16-s2-z110", true, 16.0, 2.0, "110"), ("fs-c0-s2-z100", false, 0.0, 2.0, "100")] {
    let (tag, inset, corner, scale, zstr) = cfg
    let (t, src) = fold_steady_tester(inset, corner, scale, zstr, h=750.0)
    let w = @sfbase.workspace_in_view(src).0.unwrap()
    @sfdesk.rail_go(t.ctx(), src, w, "chats")
    t.run_for(@ui.move_most_ms)
    guard sidebar_word_sample(t, "新建对话") is Some(rest_new) else {
      fail("\{tag}: missing 新建对话; words=\{Repr(t.words())}")
    }
    let near_new = (rest_new.0.0, rest_new.0.1)
    guard sidebar_word_sample(t, "整理发布清单") is Some(rest_row) else {
      fail("\{tag}: missing 整理发布清单; words=\{Repr(t.words())}")
    }
    let near_row = (rest_row.0.0, rest_row.0.1)
    let t0 = t.time()
    t.advance(between_frames_ms)
    @sfdesk.wide.folded.set(true)
    for step in [16.0, 48.0, 80.0] {
      t.frame_at(t0 + step)
      match sidebar_word_sample(t, "新建对话", near=near_new) {
        Some(cur) => assert_sidebar_pinned(tag, "chats-collapse-band", step, rest_new, cur)
        None => assert_true(step > 16.0, msg="\{tag}: chats band missing at t=\{step}")
      }
      match sidebar_word_sample(t, "整理发布清单", near=near_row) {
        Some(cur) => assert_sidebar_pinned(tag, "chats-collapse-row", step, rest_row, cur)
        None => assert_true(step > 16.0, msg="\{tag}: chats row missing at t=\{step}")
      }
    }
    t.run_for(@ui.move_most_ms)
    let t1 = t.time()
    t.advance(between_frames_ms)
    @sfdesk.wide.folded.set(false)
    for step in [80.0, 144.0, 240.0] {
      t.frame_at(t1 + step)
      match sidebar_word_sample(t, "新建对话", near=near_new) {
        Some(cur) => assert_sidebar_pinned(tag, "chats-expand-band", step, rest_new, cur)
        None => assert_true(step < 144.0, msg="\{tag}: chats band missing at expand t=\{step}")
      }
      match sidebar_word_sample(t, "整理发布清单", near=near_row) {
        Some(cur) => assert_sidebar_pinned(tag, "chats-expand-row", step, rest_row, cur)
        None => assert_true(step < 144.0, msg="\{tag}: chats row missing at expand t=\{step}")
      }
    }
    t.run_for(@ui.move_most_ms)
    // Switch to Files sidebar and verify collapse/expand stays pinned too
    @sfdesk.rail_go(t.ctx(), src, w, "files")
    t.run_for(@ui.move_most_ms)
    guard sidebar_word_sample(t, "添加到收藏") is Some(rest_files) else {
      fail("\{tag}: missing 添加到收藏; words=\{Repr(t.words())}")
    }
    let near_files = (rest_files.0.0, rest_files.0.1)
    let t2 = t.time()
    t.advance(between_frames_ms)
    @sfdesk.wide.folded.set(true)
    for step in [16.0, 48.0, 80.0] {
      t.frame_at(t2 + step)
      match sidebar_word_sample(t, "添加到收藏", near=near_files) {
        Some(cur) => assert_sidebar_pinned(tag, "files-collapse", step, rest_files, cur)
        None => assert_true(step > 16.0, msg="\{tag}: files label missing at t=\{step}")
      }
    }
    t.run_for(@ui.move_most_ms)
    let t3 = t.time()
    t.advance(between_frames_ms)
    @sfdesk.wide.folded.set(false)
    for step in [80.0, 160.0, 240.0] {
      t.frame_at(t3 + step)
      match sidebar_word_sample(t, "添加到收藏", near=near_files) {
        Some(cur) => assert_sidebar_pinned(tag, "files-expand", step, rest_files, cur)
        None => assert_true(step < 160.0, msg="\{tag}: files label missing at expand t=\{step}")
      }
    }
    t.run_for(@ui.move_most_ms)
    // Switch to Settings sidebar and verify collapse/expand stays pinned (both back band and list rows)
    @sfdesk.open_settings()
    t.run_for(@ui.move_most_ms)
    guard sidebar_word_sample(t, "返回会话") is Some(rest_back) else {
      fail("\{tag}: missing 返回会话 in settings; words=\{Repr(t.words())}")
    }
    guard sidebar_word_sample(t, "星火工作室") is Some(rest_set) else {
      fail("\{tag}: missing 星火工作室 in settings; words=\{Repr(t.words())}")
    }
    let near_back = (rest_back.0.0, rest_back.0.1)
    let near_set = (rest_set.0.0, rest_set.0.1)
    let t4 = t.time()
    t.advance(between_frames_ms)
    @sfdesk.wide.folded.set(true)
    for step in [16.0, 48.0, 80.0] {
      t.frame_at(t4 + step)
      match sidebar_word_sample(t, "返回会话", near=near_back) {
        Some(cur) => assert_sidebar_pinned(tag, "settings-collapse-back", step, rest_back, cur)
        None => assert_true(step > 16.0, msg="\{tag}: settings back missing at t=\{step}")
      }
      match sidebar_word_sample(t, "星火工作室", near=near_set) {
        Some(cur) => assert_sidebar_pinned(tag, "settings-collapse-row", step, rest_set, cur)
        None => assert_true(step > 16.0, msg="\{tag}: settings row missing at t=\{step}")
      }
    }
    t.run_for(@ui.move_most_ms)
    let t5 = t.time()
    t.advance(between_frames_ms)
    @sfdesk.wide.folded.set(false)
    for step in [80.0, 160.0, 240.0] {
      t.frame_at(t5 + step)
      match sidebar_word_sample(t, "返回会话", near=near_back) {
        Some(cur) => assert_sidebar_pinned(tag, "settings-expand-back", step, rest_back, cur)
        None => assert_true(step < 160.0, msg="\{tag}: settings back missing at expand t=\{step}")
      }
      match sidebar_word_sample(t, "星火工作室", near=near_set) {
        Some(cur) => assert_sidebar_pinned(tag, "settings-expand-row", step, rest_set, cur)
        None => assert_true(step < 160.0, msg="\{tag}: settings row missing at expand t=\{step}")
      }
    }
    t.run_for(@ui.move_most_ms)
  }
}
