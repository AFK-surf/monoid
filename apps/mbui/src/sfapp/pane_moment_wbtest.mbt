// The wide frame off the tape as nodes of the window's tree (sfdesk's pane_view.mbt): its shell, row, column and page
// made once; the block's move committed at its cause, set out from where the move before had it then, whatever frames
// were drawn between; the tape left mid-move for a place with no sidebar of its own, the block closing from where the
// tape had it then.

///|
/// Where the block's move has it at `at` (how far across, the column), as committed.
fn fold_at(at : Double) -> (Double, Double) {
  @sfdesk.pane_fold_at(at).unwrap_or((-1.0, -1.0))
}

///|
/// The tree brought to `at` (what was told by then committed, at its moment).
fn bring(at : Double) -> Unit {
  match @ui.view_tree() {
    Some(tree) => tree.bring_to(at)
    None => ()
  }
}

///|
/// The sidebar folded (⌘\'s state) at `t0 + 10` between frames, `then` at `t0 + 120` while the block goes (opened
/// again, or shown a while), each told between frames; frames drawn at `t0 +` each of `frames` between: the column at
/// `t0 + 400`; where the move to the bar had the block at `t0 + 120` and where the next sets out from then.
fn pane_turned(frames : Array[Double], then : () -> Unit) -> (Double, (Double, Double), (Double, Double)) {
  let calls : Array[Made] = []
  let t = wide_tester(calls, mode="chat")
  let t0 = t.time()
  t.advance(between_frames_ms)
  @sfdesk.wide.folded.set(true)
  for f in frames {
    if f < 120.0 {
      t.frame_at(t0 + f)
    }
  }
  t.advance(t0 + 120.0 - t.time())
  bring(t0 + 120.0)
  let was = fold_at(t0 + 120.0)
  then()
  bring(t0 + 120.0)
  let from = fold_at(t0 + 120.0)
  for f in frames {
    if f > 120.0 {
      t.frame_at(t0 + f)
    }
  }
  t.frame_at(t0 + 400.0)
  match @sfdesk.pane_seen() {
    Some((_, col)) => (col, was, from)
    None => (-1.0, was, from)
  }
}

///|
test "大屏: the sidebar folded and opened again while the block goes: from where it is then, the same at a moment whichever frames came between" {
  let reopen = fn() { @sfdesk.wide.folded.set(false) }
  let one = pane_turned([], reopen)
  let many = pane_turned([12.0, 20.0, 40.0, 70.0, 100.0, 150.0, 210.0, 300.0], reopen)
  let late = pane_turned([115.0, 390.0], reopen)
  assert_eq((many, late), (one, one))
  let (col, was, from) = one
  // (set out back from where the fold had the block at that moment, its column on its way between)
  assert_eq(from, was)
  assert_true(was.1 > @sfdesk.rail_w && was.1 < col, msg="at the turn \{Repr(was)}, open \{col}")
}

///|
/// Where the block is drawn across and how wide: its ground (a node of the window's tree, among the tree's: as tall as
/// the window less its bars, at its left edge, the only ground there narrower than the window).
fn dock_drawn(t : @ui.Tester) -> (Double, Double) {
  match t.boxes_held().iter().find_first(dock_ground) {
    Some(b) => (b.x, b.w)
    None => (-1.0, -1.0)
  }
}

///|
/// Folded and at rest; shown a while at `t0 + 10`, let go again at `t0 + 120` while it comes (each told between
/// frames), frames at `t0 +` each of `frames` (before 120) between: how wide the block was drawn at `t0 + 120`; where
/// the move had its right margin, the page's move aside, the edge and the sidebar shown then and where the next sets
/// out from; how wide it is drawn at `t0 + 700`.
fn pane_peek_let_go(frames : Array[Double]) -> (Double, (Double, Double, Double, Double)?, (Double, Double, Double, Double)?, Double) {
  let calls : Array[Made] = []
  let t = wide_tester(calls, mode="chat")
  @sfdesk.wide.folded.set(true)
  t.run_for(@ui.move_most_ms)
  let t0 = t.time()
  t.advance(between_frames_ms)
  @sfdesk.wide.peeking.set(true)
  for f in frames {
    t.frame_at(t0 + f)
  }
  t.frame_at(t0 + 120.0)
  let mid = dock_drawn(t).1
  bring(t0 + 120.0)
  let was = @sfdesk.pane_reach_at(t0 + 120.0)
  @sfdesk.wide.peeking.set(false)
  bring(t0 + 120.0)
  let from = @sfdesk.pane_reach_at(t0 + 120.0)
  t.frame_at(t0 + 700.0)
  (mid, was, from, dock_drawn(t).1)
}

///|
test "大屏: folded, shown a while and let go again while it comes: the block drawn between the two, set back from where it is then, the same whichever frames came between" {
  // the two ends: folded at rest, shown a while at rest
  let calls : Array[Made] = []
  let t = wide_tester(calls, mode="chat")
  @sfdesk.wide.folded.set(true)
  t.run_for(@ui.move_most_ms)
  let folded = dock_drawn(t).1
  // (shown a while, the block reaches past its column as far as the sidebar is wide: its right margin less it)
  let shown = folded + @sfdesk.wide.side_w.get()
  let one = pane_peek_let_go([])
  let many = pane_peek_let_go([12.0, 30.0, 60.0, 90.0, 110.0])
  assert_eq(many, one)
  let (mid, was, from, end) = one
  // (on its way out at the turn: drawn between folded and shown; the move back set out from where it was then)
  assert_true(mid > folded + 0.5 && mid < shown - 0.5, msg="at the turn \{mid}, folded \{folded}, shown \{shown}")
  assert_eq(from, was)
  assert_eq(end, folded)
}

///|
/// Folded and at rest; at moments of the tree's timeline (View::at_moment, each done as of its own moment): opened at
/// `t0 + 10`, the sidebar 40 wider at `t0 + 100` (no cause of a move: put where it goes), folded again at `t0 + 200`
/// while it opens. `stepping`: frames all along; else the host's clock straight on to `t0 + 900`, past where the
/// opening would have ended, what is due done there in its order. Where the folding back set out from (at `t0 + 200`),
/// where it has the block at `t0 + 900`, how wide the block is drawn then.
fn pane_dues(stepping : Bool) -> ((Double, Double)?, (Double, Double)?, Double) {
  let calls : Array[Made] = []
  let t = wide_tester(calls, mode="chat")
  @sfdesk.wide.folded.set(true)
  t.run_for(@ui.move_most_ms)
  let t0 = t.time()
  let n = @sfdesk.pane_node().unwrap()
  n.at_moment(t0 + 10.0, fn() { @sfdesk.wide.folded.set(false) }) |> ignore
  n.at_moment(t0 + 100.0, fn() { @sfdesk.wide.side_w.set(@sfdesk.wide.side_w.get() + 40.0) }) |> ignore
  n.at_moment(t0 + 200.0, fn() { @sfdesk.wide.folded.set(true) }) |> ignore
  if stepping {
    let mut f = 16.0
    while f < 900.0 {
      t.frame_at(t0 + f)
      f = f + 16.0
    }
  } else {
    // (the host's clock on to t0 + 900 at once, the tree brought there between frames: what is due done in its order,
    // each as of its own moment, the host's now past them all)
    t.advance(t0 + 900.0 - t.time())
    bring(t0 + 900.0)
  }
  t.frame_at(t0 + 900.0)
  (@sfdesk.pane_fold_from(), @sfdesk.pane_fold_at(t0 + 900.0), dock_drawn(t).1)
}

///|
test "大屏: what is due on the timeline done as of its own moment, the host's clock on past it or not: the fold back from the same place, the same at a moment" {
  let stepped = pane_dues(true)
  let jumped = pane_dues(false)
  assert_eq(jumped, stepped)
}

///|
test "大屏: its shell, row, column and page made once: the same nodes as the sidebar folds, is shown a while and opens" {
  let calls : Array[Made] = []
  let t = wide_tester(calls, mode="chat")
  let ids = @sfdesk.pane_seen().unwrap().0
  @sfdesk.wide.folded.set(true)
  t.run_for(@ui.move_most_ms)
  assert_eq(@sfdesk.pane_seen().unwrap().0, ids)
  @sfdesk.wide.peeking.set(true)
  t.run_for(@ui.move_most_ms)
  assert_eq(@sfdesk.pane_seen().unwrap().0, ids)
  @sfdesk.wide.peeking.set(false)
  @sfdesk.wide.folded.set(false)
  t.run_for(@ui.move_most_ms)
  assert_eq(@sfdesk.pane_seen().unwrap().0, ids)
}

///|
/// On the tape, the page brought over at `t0 + 10` and 用量 gone to at `t0 + 100` while the tape goes (the frame off the
/// tape made then): where the tape had its block then (how far across, its column) and where the block's close sets out
/// from.
fn tape_left_for_usage(t : @ui.Tester) -> ((Double, Double), (Double, Double)) {
  let t0 = t.time()
  t.advance(between_frames_ms)
  @sfdesk.bring_page()
  t.frame_at(t0 + 40.0)
  t.advance(t0 + 100.0 - t.time())
  bring(t0 + 100.0)
  let (x, _) = @sfdesk.tape_along_at(t0 + 100.0)
  let col = match @sfdesk.tape_seen() {
    Some((_, _, _)) => @sfdesk.tape_col_now(t0 + 100.0)
    None => -1.0
  }
  @sfbase.go_place("usage") |> ignore
  bring(t0 + 100.0)
  ((x, col), fold_at(t0 + 100.0))
}

///|
test "中屏 to 用量 while the tape goes: the block closes from where the tape had it then; and again after the tape again" {
  let t = tape_chat(0, 720.0, 840.0)
  let (tape, from) = tape_left_for_usage(t)
  assert_false(@sfdesk.wide.tape.get())
  assert_eq(from, tape)
  // back to the chats (the tape again), the page brought over again, and 用量 once more mid-way: the same from there
  t.run_for(@ui.move_most_ms)
  @sfbase.go_place("chats") |> ignore
  t.run_for(@ui.move_most_ms)
  assert_true(@sfdesk.wide.tape.get())
  @sfdesk.wide.tape_ask.set(Some(@sfdesk.TapePane::Side))
  t.run_for(@ui.move_most_ms)
  let (tape, from) = tape_left_for_usage(t)
  assert_false(@sfdesk.wide.tape.get())
  assert_eq(from, tape)
}

///|
test "大屏: 侧栏折叠途中快速折返打开，前 2 帧平滑减速转向且最终完整展开" {
  let calls : Array[Made] = []
  let t = wide_tester(calls, mode="chat")
  let open_col = @sfdesk.pane_seen().unwrap().1
  @sfdesk.wide.folded.set(true)
  if !@ui.test_at_a_rate() {
    for _ in [0, 1, 2] {
      t.frame()
    }
    let col_mid = @sfdesk.pane_seen().unwrap().1
    assert_true(col_mid < open_col - 10.0, msg="folding mid-way: open=\{open_col}, mid=\{col_mid}")
    @sfdesk.wide.folded.set(false)
    t.frame()
    let col_f1 = @sfdesk.pane_seen().unwrap().1
    t.frame()
    let col_f2 = @sfdesk.pane_seen().unwrap().1
    // (velocity continuity: no snap-jump at reversal, smoothly turns back toward open_col)
    assert_true((col_f1 - col_mid).abs() < 45.0, msg="no jump on frame 1: mid=\{col_mid}, f1=\{col_f1}")
    assert_true(col_f2 > col_f1 - 15.0, msg="turning smoothly toward open: f1=\{col_f1}, f2=\{col_f2}")
  } else {
    t.run_for(@ui.input_step_ms * 3.0)
    @sfdesk.wide.folded.set(false)
  }
  t.run_for(@ui.move_most_ms)
  let end_col = @sfdesk.pane_seen().unwrap().1
  assert_true((end_col - open_col).abs() < 0.5, msg="fully reopened: open=\{open_col}, end=\{end_col}")
}

///|
test "大屏 W1: 非 Chat 主页在展开与收窄折页动画期高度满格、以终态宽随 col 连续滑动无 Δcol 跳变，中途拖边线连续接管" {
  let calls : Array[Made] = []
  let src_ref : Ref[Source?] = Ref(None)
  let t2 = wide_tester(calls, mode="chat", w=1440.0, h=900.0, before=fn(s) { src_ref.val = Some(s) })
  t2.host_says_finger(Some(false))
  let base = src_ref.val.unwrap()
  t2.run_for(@ui.move_most_ms)
  let w2 = @sfbase.workspace_in_view(base).0.unwrap()
  let check_slide = fn(tag : String, target_w : Double) -> (Double, Double) raise {
    let col = @sfdesk.pane_seen().unwrap().1
    match @sfdesk.pane_made_rect() {
      Some(((_, _, _, pane_h), (mx, _, mw, mh))) => {
        assert_true(pane_h > 400.0, msg="\{tag}: pane_h=\{pane_h}")
        assert_true((mh - pane_h).abs() < 1.0, msg="\{tag}: made height \{mh} != pane_h \{pane_h}")
        assert_true((mx - col).abs() < 1.0, msg="\{tag}: left edge \{mx} != col \{col}")
        assert_true((mw - target_w).abs() < 1.0, msg="\{tag}: width \{mw} != target_w \{target_w}")
        (col, mx)
      }
      None => fail("\{tag}: expected active made-once page")
    }
  }
  // 1. Expand direction: chats (col=296) -> stations (col=336, target_w=1104)
  @ui.view_tree().unwrap().event(t2.time(), fn() { @sfdesk.rail_go(t2.ctx(), base, w2, "stations") })
  t2.tree_frames_from_now()
  if !@ui.test_at_a_rate() {
    let t0 = t2.time()
    let mut prev : (Double, Double)? = None
    for pct in [0.0, 0.25, 0.5, 0.75, 1.0] {
      t2.frame_at(t0 + @ui.move_most_ms * pct)
      let (col, mx) = check_slide("expand pct=\{pct}", 1104.0)
      assert_true(col >= 295.0 && col <= 337.0, msg="expand pct=\{pct} col=\{col}")
      match prev {
        Some((pc, pm)) =>
          assert_true(((mx - pm) - (col - pc)).abs() < 1.0, msg="expand step delta matches col: dmx=\{mx - pm} dcol=\{col - pc}")
        None => ()
      }
      prev = Some((col, mx))
    }
  } else {
    t2.run_for(@ui.move_most_ms / 4.0)
    check_slide("expand mid", 1104.0) |> ignore
    t2.run_for(@ui.move_most_ms)
  }
  t2.run_for(@ui.move_most_ms)
  assert_true((@sfdesk.pane_seen().unwrap().1 - 336.0).abs() < 1.0, msg="settled at stations 280")
  check_slide("expand settled", 1104.0) |> ignore
  // 2. Shrink direction: stations (col=336) -> connects (bare, col=56, target_w=1384)
  @ui.view_tree().unwrap().event(t2.time(), fn() { @sfdesk.rail_go(t2.ctx(), base, w2, "connects") })
  t2.run_for(@ui.move_most_ms / 4.0)
  let mid_col = @sfdesk.pane_seen().unwrap().1
  assert_true(mid_col < 335.0, msg="started folding toward bare: mid_col=\{mid_col}")
  check_slide("shrink mid", 1384.0) |> ignore
  t2.run_for(@ui.move_most_ms)
  check_slide("shrink settled", 1384.0) |> ignore
  // 3. Place("remote") expand (bare -> 240, target_w=1144) and shrink (280 -> 240, target_w=1144): width always 1144
  @ui.view_tree().unwrap().event(t2.time(), fn() { @sfdesk.rail_go(t2.ctx(), base, w2, "remote") })
  t2.run_for(@ui.move_most_ms / 4.0)
  check_slide("remote expand mid", 1144.0) |> ignore
  t2.run_for(@ui.move_most_ms)
  check_slide("remote expand settled", 1144.0) |> ignore
  @ui.view_tree().unwrap().event(t2.time(), fn() { @sfdesk.rail_go(t2.ctx(), base, w2, "stations") })
  t2.run_for(@ui.move_most_ms)
  @ui.view_tree().unwrap().event(t2.time(), fn() { @sfdesk.rail_go(t2.ctx(), base, w2, "remote") })
  t2.run_for(@ui.move_most_ms / 4.0)
  check_slide("remote shrink mid", 1144.0) |> ignore
  t2.run_for(@ui.move_most_ms)
  // 4. Mid-fold sidebar edge drag: start chats (col=296) -> stations (col=336), press mid-fold at visible edge
  let edge_close_label = @sf.t("web-pages.workspace.resizeSidebar") + " · " + @sf.t("web-main.sidebar.close")
  @ui.view_tree().unwrap().event(t2.time(), fn() { @sfdesk.rail_go(t2.ctx(), base, w2, "chats") })
  t2.run_for(@ui.move_most_ms)
  @ui.view_tree().unwrap().event(t2.time(), fn() { @sfdesk.rail_go(t2.ctx(), base, w2, "stations") })
  t2.run_for(@ui.input_step_ms * 2.0)
  let col_before_down = @sfdesk.pane_seen().unwrap().1
  assert_true(col_before_down > 298.0 && col_before_down < 334.0, msg="strictly mid-fold: col=\{col_before_down}")
  let (ex, ey, ew, eh) = t2.query(Button, label=edge_close_label).unwrap().rect
  let (x, y) = (ex + ew / 2.0, ey + eh / 2.0)
  t2.touch_at(0, x, y, t2.time())
  assert_true(@sfdesk.wide.edge_held.get(), msg="edge held on mid-fold down")
  t2.frame()
  let col_at_down = @sfdesk.pane_seen().unwrap().1
  assert_true((col_at_down - col_before_down).abs() < 1.0, msg="no jump on mid-fold press down: before=\{col_before_down} at=\{col_at_down}")
  // Holding still for another frame must not drift toward target 336
  t2.frame()
  let col_held_still = @sfdesk.pane_seen().unwrap().1
  assert_true((col_held_still - col_at_down).abs() < 0.5, msg="no drift while held still: at=\{col_at_down} still=\{col_held_still}")
  // Drag past slop then +1px: visible column tracks exact 1px
  t2.advance(slow_drag_ms)
  t2.touch_at(1, x + 10.0, y, t2.time())
  t2.frame()
  let col_after_10 = @sfdesk.pane_seen().unwrap().1
  t2.advance(slow_drag_ms)
  t2.touch_at(1, x + 11.0, y, t2.time())
  t2.frame()
  let col_after_11 = @sfdesk.pane_seen().unwrap().1
  assert_true((col_after_11 - col_after_10 - 1.0).abs() < 0.5, msg="1px drag tracks 1px: after10=\{col_after_10} after11=\{col_after_11}")
  t2.advance(slow_drag_ms)
  t2.touch_at(2, x + 11.0, y, t2.time())
  assert_false(@sfdesk.wide.edge_held.get(), msg="edge released")
  // 5. Mid-fold cancel gesture (240->280): pressing down, dragging past slop, then cancelling restores wide.side_w
  @ui.view_tree().unwrap().event(t2.time(), fn() { @sfdesk.rail_go(t2.ctx(), base, w2, "chats") })
  t2.run_for(@ui.move_most_ms)
  @ui.view_tree().unwrap().event(t2.time(), fn() { @sfdesk.rail_go(t2.ctx(), base, w2, "stations") })
  let target_w_before_cancel = @sfdesk.wide.side_w.get()
  t2.run_for(@ui.input_step_ms * 2.0)
  let (cx, cy, cw, ch) = t2.query(Button, label=edge_close_label).unwrap().rect
  let (canc_x, canc_y) = (cx + cw / 2.0, cy + ch / 2.0)
  t2.touch_at(0, canc_x, canc_y, t2.time())
  assert_true(@sfdesk.wide.edge_held.get(), msg="held before cancel")
  t2.advance(slow_drag_ms)
  t2.touch_at(1, canc_x + 12.0, canc_y, t2.time())
  t2.frame()
  t2.touch_at(3, canc_x + 12.0, canc_y, t2.time())
  assert_false(@sfdesk.wide.edge_held.get(), msg="released on cancel")
  assert_true(
    (@sfdesk.wide.side_w.get() - target_w_before_cancel).abs() < 0.5,
    msg="cancel after drag restores saved side_w: got=\{@sfdesk.wide.side_w.get()} want=\{target_w_before_cancel}",
  )
  t2.run_for(@ui.move_most_ms)
  // 6. Mid-fold light tap without dragging toggles fold without jumping back
  @ui.view_tree().unwrap().event(t2.time(), fn() { @sfdesk.rail_go(t2.ctx(), base, w2, "chats") })
  t2.run_for(@ui.move_most_ms)
  @ui.view_tree().unwrap().event(t2.time(), fn() { @sfdesk.rail_go(t2.ctx(), base, w2, "stations") })
  t2.run_for(@ui.move_most_ms / 4.0)
  let (tx, ty, tw, th) = t2.query(Button, label=edge_close_label).unwrap().rect
  let (tap_x, tap_y) = (tx + tw / 2.0, ty + th / 2.0)
  let ttap = t2.time() + between_frames_ms
  t2.advance(ttap - t2.time())
  t2.touch_at(0, tap_x, tap_y, ttap)
  t2.touch_at(2, tap_x, tap_y, ttap)
  assert_true(@sfdesk.wide.folded.get(), msg="mid-fold light tap toggles folded")
  // 7. Pressing edge mid-fold (showing crossing 0: folding & unfolding) must not snap col or made-page width
  t2.run_for(@ui.input_step_ms * 2.0)
  let fold_col_before = @sfdesk.pane_seen().unwrap().1
  let fold_rect_before = @sfdesk.pane_made_rect().unwrap().1
  let edge_open_label = @sf.t("web-main.sidebar.open")
  let (fx, fy, fw, fh) = t2.query(Button, label=edge_open_label).unwrap().rect
  t2.touch_at(0, fx + fw / 2.0, fy + fh / 2.0, t2.time())
  t2.frame()
  let fold_col_after = @sfdesk.pane_seen().unwrap().1
  let fold_rect_after = @sfdesk.pane_made_rect().unwrap().1
  assert_true(fold_col_after <= fold_col_before + 1.0, msg="mid-collapse press does not snap open: before=\{fold_col_before} after=\{fold_col_after}")
  assert_true((fold_rect_after.2 - fold_rect_before.2).abs() < 1.0, msg="mid-collapse press keeps locked page width")
  t2.touch_at(3, fx + fw / 2.0, fy + fh / 2.0, t2.time())
  t2.run_for(@ui.move_most_ms)
  // Unfold mid-way (folded: true -> false): pressing & dragging edge past slop must NOT snap to full open, and cancel restores side_w
  @sfdesk.wide.folded.set(false)
  let unfold_w_before = @sfdesk.wide.side_w.get()
  t2.run_for(@ui.input_step_ms * 2.0)
  let unfold_col_before = @sfdesk.pane_seen().unwrap().1
  let (ux, uy, uw, uh) = t2.query(Button, label=edge_close_label).unwrap().rect
  let (unfold_x, unfold_y) = (ux + uw / 2.0, uy + uh / 2.0)
  t2.touch_at(0, unfold_x, unfold_y, t2.time())
  t2.frame()
  let unfold_col_after = @sfdesk.pane_seen().unwrap().1
  assert_true(
    unfold_col_after < 325.0 && unfold_col_after >= unfold_col_before - 1.0,
    msg="mid-unfold press does not snap to full open: before=\{unfold_col_before} after=\{unfold_col_after}",
  )
  t2.advance(slow_drag_ms)
  t2.touch_at(1, unfold_x + 12.0, unfold_y, t2.time())
  t2.frame()
  let unfold_col_drag = @sfdesk.pane_seen().unwrap().1
  assert_true(
    unfold_col_drag < 325.0 && unfold_col_drag >= unfold_col_after - 1.0,
    msg="mid-unfold drag past slop stays continuous and does not snap to full open: after=\{unfold_col_after} drag=\{unfold_col_drag}",
  )
  t2.touch_at(3, unfold_x + 12.0, unfold_y, t2.time())
  assert_true(
    (@sfdesk.wide.side_w.get() - unfold_w_before).abs() < 0.5,
    msg="mid-unfold cancel after drag restores saved side_w: got=\{@sfdesk.wide.side_w.get()} want=\{unfold_w_before}",
  )
  t2.run_for(@ui.move_most_ms)
  // 8. Mid-collapse reversal (showing ~0.5 -> 1.0): pressing & dragging edge past slop must NOT snap to full open
  let rev_w_before = @sfdesk.wide.side_w.get()
  @sfdesk.wide.folded.set(true)
  t2.run_for(@ui.move_most_ms / 3.0)
  @sfdesk.wide.folded.set(false)
  t2.run_for(@ui.input_step_ms)
  let rev_col_before = @sfdesk.pane_seen().unwrap().1
  let (rx, ry, rw, rh) = t2.query(Button, label=edge_close_label).unwrap().rect
  let (rev_x, rev_y) = (rx + rw / 2.0, ry + rh / 2.0)
  t2.touch_at(0, rev_x, rev_y, t2.time())
  t2.frame()
  let rev_col_after = @sfdesk.pane_seen().unwrap().1
  t2.advance(slow_drag_ms)
  t2.touch_at(1, rev_x + 12.0, rev_y, t2.time())
  t2.frame()
  let rev_col_drag = @sfdesk.pane_seen().unwrap().1
  assert_true(
    rev_col_drag < 325.0 && rev_col_drag >= rev_col_after - 1.0,
    msg="mid-collapse reversal drag past slop does not snap to full open: before=\{rev_col_before} after=\{rev_col_after} drag=\{rev_col_drag}",
  )
  t2.touch_at(3, rev_x + 12.0, rev_y, t2.time())
  assert_true(
    (@sfdesk.wide.side_w.get() - rev_w_before).abs() < 0.5,
    msg="mid-collapse reversal cancel restores saved side_w: got=\{@sfdesk.wide.side_w.get()} want=\{rev_w_before}",
  )
  t2.run_for(@ui.move_most_ms)
}

///|
test "大屏 W2: Place(profiles) 切回 chats 通过外层事务原子落到 Chat，不把 Home 单独冲刷到栈顶" {
  new_run()
  let base0 = fixture("chat")
  let base : Source = {
    ..base0,
    topic_read: fn(name, params) {
      if name == "workspaceMarks" {
        {
          value: Some({
            "workspaces": { "ws1": { "chat": { "station": "ws1/st1", "key": "s-c1" } } },
          }),
          error: None,
          version: 1,
        }
      } else {
        base0.topic(name, params).get().snapshot()
      }
    },
  }
  open_chat({ station: "ws1/st1", session: "s-c1", title: "整理发布清单", station_name: "Willow" })
  let t = @ui.Tester::new(fn(c) { view(c, base) }, tree=app_tree(base), w=1440.0, h=900.0, platform=0)
  t.run_for(@ui.move_most_ms)
  let w = @sfbase.workspace_in_view(base).0.unwrap()
  @sfdesk.rail_go(t.ctx(), base, w, "profiles")
  t.run_for(@ui.move_most_ms)
  assert_true(app.nav.top() == Place("profiles"))
  let tops : Array[Page] = []
  let stop = @signals.effect(fn() { tops.push(app.nav.top()) })
  tops.clear()
  // Call rail_go directly without outer Tree::event batch to verify history_act itself is atomic
  @sfdesk.rail_go(t.ctx(), base, w, "chats")
  stop()
  assert_false(tops.contains(Home), msg="Home must not flush to stack top before Chat")
  assert_true(tops.iter().any(fn(p) { p is Chat(_) }), msg="observer must see target Chat directly")
  assert_true(app.nav.top() is Chat(_), msg="landed on Chat")
  t.run_for(@ui.move_most_ms)
}
