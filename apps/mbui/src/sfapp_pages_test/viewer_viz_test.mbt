// A picture and a visualization over the whole window, on a wide window, each opened its own way in (a picture pressed
// in its message, its tab over the whole window; a visualization's 全屏 under its page):
// what is open over the other, and what back closes.

///|
/// A window tall enough for a chat's last messages to show a picture and a visualization's page at once.
let viz_chat_h : Double = 2400.0

///|
/// The picture both ways in are tried with.
let viz_chat_picture : String = "compare.png"

///|
/// A chat with a visualization and pictures in its messages, a wide window (1280 across, a Mac's, `viz_chat_h` tall), at
/// its end: the tester, where its picture is drawn and where the visualization's 全屏 is (each None: not on the screen).
fn viz_chat() -> (@ui.Tester, (Double, Double)?, (Double, Double)?) {
  new_run()
  let src = fixture("chat-viz")
  open_chat({ station: "ws1/st1", session: "s-c1", title: "整理发布清单", station_name: "Willow" })
  let t = @ui.Tester::new(fn(c) { view(c, src) }, tree=app_tree(src), w=1280.0, h=viz_chat_h, platform=0)
  nav_rested(t)
  t.run_for(@ui.move_most_ms)
  let (picture, full) = seen_now(t)
  (t, picture, full)
}

///|
/// Where the picture is drawn and where the visualization's 全屏 is now (each None: not on the screen).
fn seen_now(t : @ui.Tester) -> ((Double, Double)?, (Double, Double)?) {
  let picture = match t.locate("img:" + viz_chat_picture) {
    [p, ..] => Some(p)
    [] => None
  }
  // (the whole screen, under its page: viz_full_at)
  (picture, viz_full_at(t, viz_views(t).0))
}

///|
/// Both on the screen, else the test says so.
fn both_seen(picture : (Double, Double)?, full : (Double, Double)?) -> ((Double, Double), (Double, Double)) raise {
  match (picture, full) {
    (Some(p), Some(f)) => (p, f)
    _ => fail("not both on the screen: the picture \{Repr(picture)}, the visualization's 全屏 \{Repr(full)}")
  }
}

///|
/// Closed by back: whichever is open.
fn back_closes(t : @ui.Tester) -> Unit {
  t.back()
  t.run_for(@ui.move_most_ms)
  t.run_for(@sfpages.reveal_ms)
  t.frame()
}

///|
/// Whether the visualization is over the whole window: on its own, or as its chat's tab (a wide window's: sfbase's
/// tab_full.mbt), not a file's.
fn viz_over() -> Bool {
  @sfbase.viz_full.get() is Some(_) ||
  (match @sfbase.tab_full.get() {
    Some(f) => @sfbase.view_tab_file(f.tab) is None
    None => false
  })
}

///|
/// Whether the picture is over the whole window: in the whole window's viewer (pressed: sfbase's opens_in_viewer), or
/// its tab's (sfbase's tab_full.mbt).
fn picture_over() -> Bool {
  if viewer.get() is Some(v) && v.file.name == viz_chat_picture {
    return true
  }
  match @sfbase.tab_full.get() {
    Some(f) =>
      match @sfbase.view_tab_file(f.tab) {
        Some(v) => v.file.name == viz_chat_picture
        None => false
      }
    None => false
  }
}

///|
/// A press at (`x`, `y`), the moves it sets off done: what it opens over the whole window.
fn press_over_all(t : @ui.Tester, x : Double, y : Double) -> Unit {
  t.tap(x, y)
  t.run_for(@ui.move_most_ms)
}

///|
/// The page under all of it as it stands: which, how deep.
fn page_now() -> (Page, Int) {
  (app.nav.top(), app.nav.depth())
}

///|
test "a wide window, a picture and a visualization's 全屏 both on the screen, each opening its own with nothing over it; a picture opened over all of it, the 全屏 under it opening nothing, back closing the picture, the page under it as it was" {
  let (t, picture, full) = viz_chat()
  let ((_, _), (fx, fy)) = both_seen(picture, full)
  let page = page_now()
  // (nothing over them: each opens its own)
  t.tap(fx, fy)
  t.frame()
  t.frame()
  assert_true(viz_over(), msg="the 全屏 there opens the visualization")
  back_closes(t)
  assert_true(!viz_over(), msg="closed again")
  let ((px, py), _) = both_seen(seen_now(t).0, seen_now(t).1)
  press_over_all(t, px, py)
  assert_true(picture_over(), msg="the picture there opens over the whole window")
  // (back, nothing pressed between: the picture closed, the page as it was)
  back_closes(t)
  assert_true(!picture_over(), msg="back: the picture no longer over the whole window")
  assert_true(page_now() == page, msg="back: the page as it was")
  // (opened again, the 全屏 where it is pressed under it)
  let ((px, py), (fx, fy)) = both_seen(seen_now(t).0, seen_now(t).1)
  press_over_all(t, px, py)
  assert_true(picture_over(), msg="opened again")
  t.tap(fx, fy)
  t.frame()
  t.frame()
  assert_true(!viz_over(), msg="under the picture: no visualization opened")
  // (the press the viewer's: on its ground, it closes the picture, as the whole window's viewer does; else back does)
  if picture_over() {
    back_closes(t)
  } else {
    t.run_for(@ui.move_most_ms)
  }
  assert_true(!picture_over() && !viz_over(), msg="the picture closed, nothing else opened")
  assert_true(page_now() == page, msg="the page as it was")
}

///|
test "a wide window, a picture and a visualization's 全屏 both on the screen; the visualization over the whole window, the picture under it opening nothing, back closing the visualization, the page under it as it was" {
  let (t, picture, full) = viz_chat()
  let ((px, py), _) = both_seen(picture, full)
  let page = page_now()
  // (nothing over it: the picture opens)
  press_over_all(t, px, py)
  assert_true(picture_over(), msg="the picture there opens over the whole window")
  back_closes(t)
  assert_true(!picture_over(), msg="closed again")
  // (the visualization, back with nothing pressed between: closed, the page as it was)
  let (_, (fx, fy)) = both_seen(seen_now(t).0, seen_now(t).1)
  t.tap(fx, fy)
  t.frame()
  t.frame()
  assert_true(viz_over(), msg="全屏: the visualization over the whole window")
  back_closes(t)
  assert_true(!viz_over(), msg="back: the visualization closed")
  assert_true(page_now() == page, msg="back: the page as it was")
  // (both where they are drawn now)
  let (picture, full) = seen_now(t)
  let ((px, py), (fx, fy)) = both_seen(picture, full)
  // (opened again, the picture where it is pressed under it)
  t.tap(fx, fy)
  t.frame()
  t.frame()
  assert_true(viz_over(), msg="opened again")
  press_over_all(t, px, py)
  assert_true(!picture_over(), msg="under the visualization: no picture opened")
  assert_true(viz_over(), msg="the visualization still over the whole window")
  back_closes(t)
  assert_true(!viz_over(), msg="back: the visualization closed")
  assert_true(!picture_over() && viewer.get() is None, msg="nothing else opened")
  assert_true(page_now() == page, msg="the page as it was")
}
