// Back on the wide frame, a node of the window's tree (sfdesk's wide_takes_back): off the tape (Large) the entry before in
// the history or a page popped, what is over the whole window put away, what is shown over it first; the history's entries
// made at their causes; whether the app takes back told the host as it changes; each at its event's moment, frames or
// none.

///|
/// How far apart the events of these come.
let wide_step_ms : Double = 16.0

///|
let chat_a : ChatRef = { station: "ws1/st1", session: "s-c1", title: "整理发布清单", station_name: "Willow" }

///|
let chat_b : ChatRef = { station: "ws1/st1", session: "s-c2", title: "首页的列表改成按天分组", station_name: "Willow" }

///|
let chat_c : ChatRef = { station: "ws1/st1", session: "s-c3", title: "", station_name: "Willow" }

///|
/// The source of the last made (wide_backs).
let wide_src : Ref[Source?] = Ref(None)

///|
/// 大屏 (a finger's, 1280 wide), chat A in view, its clock from `t0` on: `to(at)` takes it to `t0 + at`, frames every
/// 16 ms on the way (`framed`) or none.
fn wide_backs(framed : Bool) -> (@ui.Tester, Double, (Double) -> Unit) {
  new_run()
  let src = fixture("chat")
  wide_src.val = Some(src)
  open_chat(chat_a)
  let t = @ui.Tester::new(fn(c) { view(c, src) }, tree=app_tree(src), w=1280.0, h=840.0, platform=2)
  t.run_for(@ui.move_most_ms)
  let t0 = t.time() + between_frames_ms
  let to = fn(at : Double) {
    if framed {
      while t.time() + 16.0 < t0 + at {
        t.frame_at(t.time() + 16.0)
      }
    }
    t.advance(t0 + at - t.time())
  }
  (t, t0, to)
}

///|
/// The session of the chat on top (another page: its name).
fn top_session() -> String {
  match app.nav.top() {
    Chat(r) => r.session
    _ => "other"
  }
}

///|
/// 大屏, chat B opened over A (a person's act: an entry of the history), then back with no gesture at once; frames all
/// along (`framed`) or none: the chat on top and whether the host was told the app takes back as B came, the chat on top
/// just after back, before a frame.
fn wide_history_back(framed : Bool) -> (String, Bool, String) {
  let (t, t0, to) = wide_backs(framed)
  to(0.0)
  open_chat(chat_b)
  let came = (top_session(), t.takes_back())
  to(wide_step_ms * 3.0)
  t.back_raw(2, 0.0, t0 + wide_step_ms * 3.0)
  (came.0, came.1, top_session())
}

///|
test "大屏: another chat opened, then back at once, before a frame: the chat before it, as the history has it, as with frames all along" {
  let along = wide_history_back(true)
  assert_eq(wide_history_back(false), along)
  assert_eq(along, ("s-c2", true, "s-c1"))
}

///|
/// 大屏, A then B opened, the system's back gesture begun (its entry: A's) and, as it goes, C opened; gone through
/// (`through`) or called off; frames all along or none: the chat on top as it ends, before a frame.
fn wide_history_gesture(framed : Bool, through : Bool) -> String {
  let (t, t0, to) = wide_backs(framed)
  to(0.0)
  open_chat(chat_b)
  gesture(t, t0, to, wide_step_ms * 3.0, end=if through { 2 } else { 3 }, between=fn() { open_chat(chat_c) }) |> ignore
  top_session()
}

///|
test "大屏: back's entry chosen as its gesture begins: another chat opened as it goes, gone through, the one it began from (A); called off, the one opened stays; frames or none" {
  for framed in [false, true] {
    assert_eq(wide_history_gesture(framed, true), "s-c1", msg="framed \{framed}")
    assert_eq(wide_history_gesture(framed, false), "s-c3", msg="framed \{framed}")
  }
}

///|
/// 大屏, A, then B and C opened one after another (two acts), frames all along or none: the tops of the history's entries
/// (before, now), and the chat on top after back twice with no frame between.
fn wide_entries(framed : Bool) -> ((Array[String], String), String) {
  let (t, t0, to) = wide_backs(framed)
  to(0.0)
  open_chat(chat_b)
  to(wide_step_ms * 3.0)
  open_chat(chat_c)
  let name = fn(p : Page) {
    match p {
      Chat(r) => r.session
      _ => "other"
    }
  }
  let (before, now) = @sfbase.history_tops()
  let entries = (before.map(name), now.map(name).unwrap_or(""))
  to(wide_step_ms * 6.0)
  t.back_raw(2, 0.0, t0 + wide_step_ms * 6.0)
  t.back_raw(2, 0.0, t0 + wide_step_ms * 6.0)
  (entries, top_session())
}

///|
test "大屏: two chats opened one after the other with no frame between: an entry each, as with frames; back twice, the first" {
  let along = wide_entries(true)
  assert_eq(wide_entries(false), along)
  assert_eq(along.0.1, "s-c3")
  assert_eq(along.0.0[along.0.0.length() - 2:].to_owned(), ["s-c1", "s-c2"])
  assert_eq(along.1, "s-c1")
}

///|
/// 中屏 on the tape (a finger's, the page in use), a station's screen opened over the whole window, then back with no
/// gesture at once; frames all along (`framed`) or none: whether the app takes back as it is opened, before a frame,
/// what is on top after back, the panel in use.
fn screen_closed(framed : Bool) -> (Bool, Bool, @sfdesk.TapePane) {
  let t = tape_chat(2, 690.0, 840.0, width="medium", height="medium")
  page_over(t, 690.0)
  let t0 = t.time() + between_frames_ms
  if framed {
    t.frame_at(t0)
  } else {
    t.advance(t0 - t.time())
  }
  @sfbase.open_page(Screen({ station: "ws1/st1", screen: "desktop", title: "Willow 的桌面", until_gone: false }))
  let taken = t.takes_back()
  if framed {
    t.frame_at(t0 + wide_step_ms)
    t.frame_at(t0 + wide_step_ms * 2.0)
  } else {
    t.advance(t0 + wide_step_ms * 3.0 - t.time())
  }
  t.back_raw(2, 0.0, t.time())
  (taken, app.nav.top() is Screen(_), @sfdesk.wide.tape_at.get())
}

///|
test "中屏: a station's screen over the whole window and back at once, before a frame: the screen put away, the page still in use, as with frames" {
  assert_eq(screen_closed(false), screen_closed(true))
  assert_eq(screen_closed(false), (true, false, @sfdesk.TapePane::Page))
}

///|
test "大屏: a question shown over the frame takes back first: closed, the chat opened still on top; back again, the history's" {
  let (t, _, _) = wide_backs(true)
  open_chat(chat_b)
  t.run_for(@ui.move_most_ms)
  @sf.confirm("删除", "删除这个对话？", "删除", fn() {  })
  t.run_for(@ui.move_most_ms)
  assert_true(@sf.presenting())
  t.back()
  t.run_for(@ui.move_most_ms)
  assert_false(@sf.presenting())
  assert_eq(top_session(), "s-c2")
  t.back()
  assert_eq(top_session(), "s-c1")
}

///|
test "大屏: a chat's menu shown in the sidebar takes back first: closed, the chat opened still on top; back again, the history's" {
  let (t, _, _) = wide_backs(true)
  open_chat(chat_b)
  t.run_for(@ui.move_most_ms)
  let (x, y, _, h) = t.rect_of("整理发布清单").unwrap()
  t.right_click(x + 4.0, y + h / 2.0)
  t.run_for(@ui.move_most_ms)
  assert_true(@sf.presenting(), msg="its menu")
  t.back()
  t.run_for(@ui.move_most_ms)
  assert_false(@sf.presenting())
  assert_eq(top_session(), "s-c2")
  t.back()
  assert_eq(top_session(), "s-c1")
}

///|
test "中屏: the settings' sidebar opened from the chats' (back the system's there): back the app's at once; back to the chats', the system's at once; no frame between" {
  let t = tape_chat(2, 690.0, 840.0, width="medium", height="medium")
  assert_eq(@sfdesk.wide.tape_at.get(), @sfdesk.TapePane::Side)
  assert_false(t.takes_back())
  @sfdesk.open_settings()
  assert_eq((@sfdesk.lit_place(), t.takes_back()), ("settings", true))
  @sfbase.go_place("chats") |> ignore
  assert_eq((@sfdesk.lit_place(), t.takes_back()), ("chats", false))
}

///|
/// The tops of the history's entries, by chat (another page: its name): before the one now, the one now.
fn entries_now() -> (Array[String], String) {
  let name = fn(p : Page) {
    match p {
      Chat(r) => r.session
      Settings | Setting(_) => "settings"
      _ => "other"
    }
  }
  let (before, now) = @sfbase.history_tops()
  (before.map(name), now.map(name).unwrap_or(""))
}

///|
/// 大屏, A then B opened, back by `how` (0: the shell's back, go_back, called as a page's bar calls it; 1: the stack's
/// own, back_pop; 2: the system's back, an event of the tree's), then forward (go_forward): the chat on top after back
/// and after forward, and the entries then, no frame between.
fn back_forward(how : Int) -> (String, String, (Array[String], String)) {
  let (t, t0, _) = wide_backs(false)
  open_chat(chat_b)
  match how {
    0 => @sfbase.go_back() |> ignore
    1 => @sfbase.back_pop()
    _ => t.back_raw(2, 0.0, t0)
  }
  let back = top_session()
  @sfbase.go_forward(wide_src.val.unwrap()) |> ignore
  (back, top_session(), entries_now())
}

///|
test "大屏: back then forward, no frame between, by the shell's back, the stack's own, the system's: forward to the chat back left" {
  let by_event = back_forward(2)
  assert_eq(by_event.1, "s-c2", msg="\{Repr(by_event)}")
  for how in [0, 1] {
    let got = back_forward(how)
    assert_eq(got.1, "s-c2", msg="how \{how}: \{Repr(got)}")
  }
  assert_eq(back_forward(0), by_event)
}

///|
test "大屏: the settings opened from a chat (another place, its pages), back and forward, no frame between: the entries and the page on top each way" {
  let (_, _, _) = wide_backs(false)
  let at_first = entries_now()
  @sfdesk.open_settings()
  let opened = entries_now()
  assert_eq(opened, ([..at_first.0, "s-c1"], "settings"))
  @sfbase.go_back() |> ignore
  assert_eq((entries_now(), top_session()), (at_first, "s-c1"))
  @sfbase.go_forward(wide_src.val.unwrap()) |> ignore
  assert_eq(entries_now(), opened)
  assert_true(@sfdesk.lit_place() == "settings")
}

///|
test "大屏: the chat on top opened again: no entry for it; another opened then, one entry, the chat before it" {
  let (_, _, _) = wide_backs(false)
  open_chat(chat_b)
  let was = entries_now()
  open_chat(chat_b)
  assert_eq(entries_now(), was)
  open_chat(chat_c)
  assert_eq(entries_now(), ([..was.0, "s-c2"], "s-c3"))
}

///|
/// 中屏 on the tape (a finger's), the page in use, chat B opened over it (the page's own stack: Nav::push_over), then
/// back by the stack's own (back_pop, as the shell calls it, no event of the tree's around it) and forward, no frame
/// between: the chat on top after back, after forward, and the entries then.
fn tape_back_forward() -> (String, String, (Array[String], String)) raise {
  new_run()
  let src = fixture("chat")
  open_chat(chat_a)
  let t = @ui.Tester::new(fn(c) { view(c, src) }, tree=app_tree(src), w=690.0, h=840.0, platform=2)
  say_room(t, "medium", "medium")
  t.run_for(@ui.move_most_ms)
  page_over(t, 690.0)
  open_chat(chat_b)
  assert_eq(app.nav.depth(), 3)
  @sfbase.back_pop()
  let back = top_session()
  @sfbase.go_forward(src) |> ignore
  (back, top_session(), entries_now())
}

///|
test "中屏: a chat opened over the page, the stack's own back then forward, no frame between: back to the one under it, forward to it again" {
  let got = tape_back_forward()
  assert_eq((got.0, got.1), ("s-c1", "s-c2"), msg="\{Repr(got)}")
}

///|
/// 大屏, from chat A (workspace ws1), a chat opened from outside (a notification, a link: open_item) in workspace
/// `ws` at `station`/`session`, a chat opened over A first (`over`); then back (the system's) and forward (go_forward),
/// frames all along (`framed`) or none: the entries added by it, and after it, after back and after forward, the
/// workspace picked and the chat on top.
fn item_back_forward(framed : Bool, ws : String, station : String, session : String, over~ : Bool = false) -> (
  Int,
  Array[(String, String)],
) {
  let (t, t0, to) = wide_backs(framed)
  if over {
    @sfbase.open_page_over(Chat(chat_c))
  }
  to(wide_step_ms)
  let before = entries_now().0.length()
  @sfbase.open_item(wide_src.val.unwrap(), ws, station, session, None, None)
  let added = entries_now().0.length() - before
  let seen = [(app.picked.get(), top_session())]
  to(wide_step_ms * 3.0)
  t.back_raw(2, 0.0, t0 + wide_step_ms * 3.0)
  seen.push((app.picked.get(), top_session()))
  to(wide_step_ms * 5.0)
  @sfbase.go_forward(wide_src.val.unwrap()) |> ignore
  seen.push((app.picked.get(), top_session()))
  (added, seen)
}

///|
test "大屏: a chat of another workspace opened from outside, no frame between it, back and forward: one entry, back to A in its workspace, forward to it in its, as with frames" {
  let along = item_back_forward(true, "ws2", "ws2/st9", "s-x")
  assert_eq(item_back_forward(false, "ws2", "ws2/st9", "s-x"), along)
  assert_eq(along, (1, [("ws2", "s-x"), ("ws1", "s-c1"), ("ws2", "s-x")]))
}

///|
test "大屏: a chat of the same workspace opened from outside over a chat opened over another, no frame between: one entry, back to the one over, forward to it, as with frames" {
  let along = item_back_forward(true, "ws1", "ws1/st1", "s-c2", over=true)
  assert_eq(item_back_forward(false, "ws1", "ws1/st1", "s-c2", over=true), along)
  assert_eq(along.0, 1)
  assert_eq(along.1.map(fn(s) { s.1 }), ["s-c2", "s-c3", "s-c2"])
}

///|
/// 大屏, from chat A in ws1, the second workspace picked (pick_workspace: the page on top as it was), inside an event of
/// the window's tree (`in_event`: as what a node's press does is) or not; then back and forward, no frame between: the
/// entries added, and the workspace picked after it, after back, after forward.
fn picked_back_forward(in_event : Bool) -> (Int, Array[String]) {
  let (t, t0, _) = wide_backs(false)
  let before = entries_now().0.length()
  let pick = fn() { @sfbase.pick_workspace(wide_src.val.unwrap(), "ws2") }
  if in_event {
    @ui.view_tree().unwrap().event(t0, pick)
  } else {
    pick()
  }
  let added = entries_now().0.length() - before
  let seen = [app.picked.get()]
  t.back_raw(2, 0.0, t0)
  seen.push(app.picked.get())
  @sfbase.go_forward(wide_src.val.unwrap()) |> ignore
  seen.push(app.picked.get())
  (added, seen)
}

///|
test "大屏: another workspace picked, in an event of the tree's or not, no frame between it, back and forward: one entry, back to the first, forward to the second" {
  let alone = picked_back_forward(false)
  assert_eq(picked_back_forward(true), alone)
  assert_eq(alone, (1, ["ws2", "ws1", "ws2"]))
}

///|
/// Find the drawn node of the floating back hint badge by its drawn_as name.
fn back_hint_drawn() -> @view.Drawn? {
  guard @ui.view_tree() is Some(tree) else { return None }
  for d in tree.drawn() {
    if tree.drawn_name(d.id) == "/back-hint/" {
      return Some(d)
    }
  }
  None
}

///|
fn wide_desktop_pair() -> @ui.Tester {
  new_run()
  let src = fixture("chat")
  wide_src.val = Some(src)
  open_chat(chat_a)
  let t = @ui.Tester::new(fn(c) { view(c, src) }, tree=app_tree(src), w=1280.0, h=800.0, platform=0)
  t.run_for(@ui.move_most_ms)
  open_chat(chat_b)
  t.run_for(@ui.move_most_ms)
  t
}

///|
fn sweep_step(t : @ui.Tester, dx : Double) -> Unit {
  t.advance(@ui.input_step_ms)
  t.wheel_with(640.0, 400.0, dx, 0.0, 0)
  t.draw()
}

///|
fn back_hint_audit(t : @ui.Tester) -> Array[String] {
  // Pre-existing main fault on Large pane_view: the sidebar drag edge (edge_node.mbt:37, asked at pane_view.mbt)
  // intentionally overlaps the sidebar and page pane by 6px (same exemption as experimental_wbtest.mbt &
  // station_move_wbtest.mbt).
  t
  .audit()
  .filter(fn(f) { !(f.contains("ui/src/controls/edge_node.mbt:") && f.contains("sfdesk/pane_view.mbt:")) })
}

///|
test "大屏: swipe-back hint follows across monotonically, retreats on reverse, turns accent at far, and does not eat hits" {
  let t = wide_desktop_pair()
  assert_eq(top_session(), "s-c2")
  assert_true(back_hint_drawn() is None, msg="absent before gesture")
  // (probe window drag / hit at the badge's future center before it shows)
  let probe_x = @sf.card_pad + @sf.float_button_side / 2.0
  let probe_y = 400.0
  let drag_before = t.drags_window_at(probe_x, probe_y)
  // (start gesture past wheel_back_slop=10: across = 20, then 40)
  sweep_step(t, -20.0)
  let a1 = back_hint_audit(t).join("; ")
  assert_eq(a1, "", msg="audit at across=20: \{a1}")
  let d1 = back_hint_drawn().unwrap()
  let cx1 = d1.x + d1.w / 2.0
  sweep_step(t, -20.0)
  let a2 = back_hint_audit(t).join("; ")
  assert_eq(a2, "", msg="audit at across=40: \{a2}")
  let d2 = back_hint_drawn().unwrap()
  let cx2 = d2.x + d2.w / 2.0
  assert_true(cx2 > cx1, msg="monotonic: \{cx2} > \{cx1}")
  // (reverse sweep: across drops back from 40 to 25 -> badge retreats)
  sweep_step(t, 15.0)
  let a3 = back_hint_audit(t).join("; ")
  assert_eq(a3, "", msg="audit on reverse: \{a3}")
  let d_rev = back_hint_drawn().unwrap()
  let cx_rev = d_rev.x + d_rev.w / 2.0
  assert_true(cx_rev < cx2, msg="retreats on reverse: \{cx_rev} < \{cx2}")
  // (advance past back_hint_far at steady speed for > dur_ms so ready_way completes without releasing)
  for _ in 0..<10 {
    sweep_step(t, -20.0)
  }
  let a4 = back_hint_audit(t).join("; ")
  assert_eq(a4, "", msg="audit at ready: \{a4}")
  let d_ready = back_hint_drawn().unwrap()
  let cx_ready = d_ready.x + d_ready.w / 2.0
  let max_cx = @sf.card_pad + @sf.corner_inset + @sf.float_button_side / 2.0 + 0.5
  assert_true(cx_ready > cx2 && cx_ready < max_cx, msg="past far and damped: \{cx_ready}")
  assert_eq(d_ready.glass.map(fn(g) { g.tint }), Some(@sf.theme().p.accent), msg="accent glass tint when ready")
  // (hit-testing / window drag at badge location unchanged)
  assert_eq(t.drags_window_at(probe_x, probe_y), drag_before, msg="drags_window_at unchanged under badge")
  // (let go via stillness: commits back to s-c1, badge fades out and leaves)
  t.run_for(@ui.move_most_ms)
  assert_eq(top_session(), "s-c1", msg="long swipe commits back")
  assert_true(back_hint_drawn() is None, msg="absent after fade out")
  assert_eq(back_hint_audit(t), [], msg="audit after fade out")
}

///|
test "大屏: short swipe below back_hint_far cancels without navigating and hides hint after snap-back" {
  let t = wide_desktop_pair()
  assert_eq(top_session(), "s-c2")
  // (across = 35 < back_hint_far = 60)
  sweep_step(t, -20.0)
  sweep_step(t, -15.0)
  assert_true(back_hint_drawn() is Some(_), msg="hint visible during short swipe")
  assert_eq(back_hint_audit(t), [], msg="audit during short swipe")
  // (let go via stillness: cancels without navigating, badge snaps back off-edge)
  t.run_for(@ui.move_most_ms)
  assert_eq(top_session(), "s-c2", msg="short swipe does not navigate back")
  assert_true(back_hint_drawn() is None, msg="hint gone after snap back")
  assert_eq(back_hint_audit(t), [], msg="audit after snap back")
}

///|
test "大屏: non-gesture back navigates immediately without showing the swipe hint" {
  let t = wide_desktop_pair()
  assert_eq(top_session(), "s-c2")
  t.back()
  t.draw()
  assert_eq(top_session(), "s-c1")
  assert_true(back_hint_drawn() is None, msg="no hint for non-gesture back")
}

///|
test "大屏 (Android platform=2): predictive back does not draw our hint badge and still navigates on commit" {
  let (t, _, to) = wide_backs(true)
  to(0.0)
  open_chat(chat_b)
  t.run_for(@ui.move_most_ms)
  assert_eq(top_session(), "s-c2")
  let at = t.time()
  t.back_raw(0, 0.0, at)
  t.back_raw(1, 80.0, at + wide_step_ms)
  t.draw()
  assert_true(back_hint_drawn() is None, msg="Android predictive back draws no app hint")
  t.back_raw(2, 80.0, at + wide_step_ms * 2.0)
  assert_eq(top_session(), "s-c1", msg="Android predictive back still commits navigation")
}

///|
test "大屏: hint plays exit transition after release (fade+shrink on commit, slide back on cancel) before leaving" {
  // Commit path: ready release stays present on the next frame with 0 < alpha < 1, then leaves after run_for.
  let t = wide_desktop_pair()
  t.back_raw(0, 0.0, t.time())
  t.advance(wide_step_ms)
  t.back_raw(1, @sfdesk.back_hint_far + 20.0, t.time())
  t.draw()
  assert_true(back_hint_drawn() is Some(_), msg="hint drawn before commit release")
  t.advance(wide_step_ms)
  t.back_raw(2, @sfdesk.back_hint_far + 20.0, t.time())
  assert_eq(top_session(), "s-c1", msg="commit navigates back")
  t.advance(@ui.input_step_ms)
  t.draw()
  let mid_commit = match back_hint_drawn() {
    Some(d) => d
    None => fail("hint vanished immediately on commit release instead of fading out")
  }
  assert_true(mid_commit.alpha > 0.0 && mid_commit.alpha < 1.0, msg="commit exit alpha in (0, 1): \{mid_commit.alpha}")
  t.run_for(@ui.move_most_ms)
  assert_true(back_hint_drawn() is None, msg="hint gone after commit leave completes")
  // Cancel path: short release stays present on the next frame sliding back toward off-edge, then leaves after run_for.
  let t2 = wide_desktop_pair()
  t2.back_raw(0, 0.0, t2.time())
  t2.advance(wide_step_ms)
  t2.back_raw(1, @sfdesk.back_hint_far / 2.0, t2.time())
  t2.draw()
  let before_cancel = back_hint_drawn().unwrap()
  t2.advance(wide_step_ms)
  t2.back_raw(3, @sfdesk.back_hint_far / 2.0, t2.time())
  assert_eq(top_session(), "s-c2", msg="short release does not navigate")
  t2.advance(@ui.input_step_ms)
  t2.draw()
  let mid_cancel = match back_hint_drawn() {
    Some(d) => d
    None => fail("hint vanished immediately on cancel release instead of sliding back")
  }
  assert_true(
    mid_cancel.x < before_cancel.x && mid_cancel.x > -@sf.float_button_side,
    msg="cancel exit x between release (\{before_cancel.x}) and off-edge (\{-@sf.float_button_side}): \{mid_cancel.x}",
  )
  t2.run_for(@ui.move_most_ms)
  assert_true(back_hint_drawn() is None, msg="hint gone after cancel leave completes")
}

///|
fn forward_hint_drawn() -> @view.Drawn? {
  guard @ui.view_tree() is Some(tree) else { return None }
  for d in tree.drawn() {
    if tree.drawn_name(d.id) == "/forward-hint/" {
      return Some(d)
    }
  }
  None
}

///|
test "大屏: swipe-forward hint slides from right edge monotonically, retreats on reverse, turns accent at far, does not eat hits, and navigates forward" {
  let t = wide_desktop_pair()
  assert_eq(top_session(), "s-c2")
  // (no forward history yet: left swipe does nothing and draws no hint)
  sweep_step(t, 20.0)
  sweep_step(t, 20.0)
  assert_true(forward_hint_drawn() is None, msg="no forward hint without forward history")
  t.run_for(@ui.move_most_ms)
  // (go back to s-c1 so s-c2 is in forward history)
  t.back()
  t.run_for(@ui.move_most_ms)
  assert_eq(top_session(), "s-c1")
  assert_true(forward_hint_drawn() is None, msg="absent before forward gesture")
  let probe_x = 1280.0 - @sf.card_pad - @sf.float_button_side / 2.0
  let probe_y = 400.0
  let drag_before = t.drags_window_at(probe_x, probe_y)
  // (left swipe past wheel_back_slop=10: across = 20, then 40; badge moves leftward so x decreases)
  sweep_step(t, 20.0)
  let a1 = back_hint_audit(t).join("; ")
  assert_eq(a1, "", msg="audit at across=20: \{a1}")
  let d1 = forward_hint_drawn().unwrap()
  let cx1 = d1.x + d1.w / 2.0
  sweep_step(t, 20.0)
  let a2 = back_hint_audit(t).join("; ")
  assert_eq(a2, "", msg="audit at across=40: \{a2}")
  let d2 = forward_hint_drawn().unwrap()
  let cx2 = d2.x + d2.w / 2.0
  assert_true(cx2 < cx1, msg="monotonic leftward from right edge: \{cx2} < \{cx1}")
  // (reverse sweep: dx < 0 reduces across from 40 to 25 -> badge retreats rightward)
  sweep_step(t, -15.0)
  let a3 = back_hint_audit(t).join("; ")
  assert_eq(a3, "", msg="audit on reverse: \{a3}")
  let d_rev = forward_hint_drawn().unwrap()
  let cx_rev = d_rev.x + d_rev.w / 2.0
  assert_true(cx_rev > cx2, msg="retreats rightward on reverse: \{cx_rev} > \{cx2}")
  // (advance past back_hint_far at steady speed for > dur_ms so ready_way completes)
  for _ in 0..<10 {
    sweep_step(t, 20.0)
  }
  let a4 = back_hint_audit(t).join("; ")
  assert_eq(a4, "", msg="audit at ready: \{a4}")
  let d_ready = forward_hint_drawn().unwrap()
  let cx_ready = d_ready.x + d_ready.w / 2.0
  let min_cx = 1280.0 - @sf.card_pad - @sf.corner_inset - @sf.float_button_side / 2.0 - 0.5
  assert_true(cx_ready < cx2 && cx_ready > min_cx, msg="past far and damped from right: \{cx_ready}")
  assert_eq(d_ready.glass.map(fn(g) { g.tint }), Some(@sf.theme().p.accent), msg="accent glass tint when ready")
  assert_eq(t.drags_window_at(probe_x, probe_y), drag_before, msg="drags_window_at unchanged under forward badge")
  // (let go via stillness: commits forward to s-c2, badge fades out and leaves)
  t.run_for(@ui.move_most_ms)
  assert_eq(top_session(), "s-c2", msg="long left swipe commits forward")
  assert_true(forward_hint_drawn() is None, msg="absent after fade out")
  assert_eq(back_hint_audit(t), [], msg="audit after fade out")
}

///|
test "大屏: short left swipe below back_hint_far cancels without navigating forward and slides back off right edge" {
  let t = wide_desktop_pair()
  t.back()
  t.run_for(@ui.move_most_ms)
  assert_eq(top_session(), "s-c1")
  sweep_step(t, 20.0)
  sweep_step(t, 15.0)
  let before_cancel = forward_hint_drawn().unwrap()
  assert_eq(back_hint_audit(t), [], msg="audit during short forward swipe")
  // (wait for wheel_back_still_ms release + one frame: badge slides back rightward before leaving)
  t.advance(120.0 + @ui.input_step_ms)
  t.draw()
  assert_eq(top_session(), "s-c1", msg="short left swipe does not navigate forward")
  match forward_hint_drawn() {
    Some(mid) => assert_true(mid.x > before_cancel.x, msg="cancel exit slides rightward: \{mid.x} > \{before_cancel.x}")
    None => ()
  }
  t.run_for(@ui.move_most_ms)
  assert_true(forward_hint_drawn() is None, msg="forward hint gone after snap back")
}

///|
test "大屏: modal dialog blocks swipe-forward behind it" {
  let t = wide_desktop_pair()
  t.back()
  t.run_for(@ui.move_most_ms)
  assert_eq(top_session(), "s-c1")
  @sf.confirm("删除", "删除这个对话？", "删除", fn() {  })
  t.run_for(@ui.move_most_ms)
  assert_true(@sf.presenting())
  for _ in 0..<6 {
    sweep_step(t, 20.0)
  }
  assert_true(forward_hint_drawn() is None, msg="no forward hint behind modal")
  t.run_for(@ui.move_most_ms)
  assert_eq(top_session(), "s-c1", msg="modal prevents forward navigation")
}

///|
test "中屏 (tape): two-finger left swipe slides Side back to Page, and on Page with forward history navigates forward" {
  new_run()
  let src = fixture("chat")
  open_chat(chat_a)
  let t = @ui.Tester::new(fn(c) { view(c, src) }, tree=app_tree(src), w=690.0, h=840.0, platform=0)
  say_room(t, "medium", "medium")
  t.run_for(@ui.move_most_ms)
  // (starts on Side -> left swipe slides tape to Page)
  assert_eq(@sfdesk.wide.tape_at.get(), @sfdesk.TapePane::Side)
  for _ in 0..<8 {
    t.advance(@ui.input_step_ms)
    t.wheel_with(345.0, 420.0, 20.0, 0.0, 0)
    t.draw()
  }
  t.run_for(@ui.move_most_ms * 2.0)
  assert_eq(@sfdesk.wide.tape_at.get(), @sfdesk.TapePane::Page, msg="left swipe on Side brings Page over")
  // (open chat B over chat A on Page, swipe back to A, then swipe left to go forward to B)
  open_chat(chat_b)
  t.run_for(@ui.move_most_ms)
  assert_eq(top_session(), "s-c2")
  @sfbase.back_pop()
  t.run_for(@ui.move_most_ms)
  assert_eq(top_session(), "s-c1")
  for _ in 0..<6 {
    t.advance(@ui.input_step_ms)
    t.wheel_with(345.0, 420.0, 20.0, 0.0, 0)
    t.draw()
  }
  assert_true(forward_hint_drawn() is Some(_), msg="forward hint shown on tape Page")
  t.run_for(@ui.move_most_ms * 2.0)
  assert_eq(top_session(), "s-c2", msg="left swipe on tape Page navigates forward")
}

///|
test "小屏 (web/desktop): two-finger left swipe navigates forward with right-edge hint" {
  new_run()
  let src = fixture("chat")
  let t = @ui.Tester::new(fn(c) { view(c, src) }, tree=app_tree(src), w=420.0, h=800.0, platform=4)
  t.run_for(@ui.move_most_ms)
  open_chat(chat_a)
  t.run_for(@ui.move_most_ms)
  assert_eq(top_session(), "s-c1")
  @sfbase.back_pop()
  t.run_for(@ui.move_most_ms)
  assert_true(app.nav.top() == Home)
  for _ in 0..<6 {
    t.advance(@ui.input_step_ms)
    t.wheel_with(210.0, 400.0, 20.0, 0.0, 0)
    t.draw()
  }
  assert_true(forward_hint_drawn() is Some(_), msg="forward hint shown on narrow web window")
  t.run_for(@ui.move_most_ms * 2.0)
  assert_eq(top_session(), "s-c1", msg="left swipe on narrow web window navigates forward")
  assert_true(forward_hint_drawn() is None, msg="forward hint leaves after commit")
}
