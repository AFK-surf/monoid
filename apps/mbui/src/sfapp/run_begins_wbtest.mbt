// A run of the app begins at one moment (sf's run_begins.mbt): where it is begun before its Tester (new_run), at that
// moment, and not again as its Tester is made. Both halves at once, so that neither is mended without the other: what
// the run before left open is gone as the next begins, and what the next opened before its Tester is still there.

///|
/// The app on a phone's window over the made-up core's chats.
fn rb_tester() -> @ui.Tester {
  let src = fixture("chat")
  let t = @ui.Tester::new(fn(c) { view(c, src) }, tree=app_tree(src), w=390.0, h=844.0, platform=2)
  t.run_for(@ui.move_most_ms)
  t
}

///|
test "a run of the app begun before its Tester: the menu the run before left open gone as it begins, the one it opened before its Tester still open once it is made" {
  // (a run that leaves a menu open)
  new_run()
  let first = rb_tester()
  @sf.menu([Some(@sf.menu_item_of("上一次的菜单", fn() {  }))], from=@sf.at_point(100.0, 300.0))
  first.run_for(@ui.move_most_ms)
  assert_true(first.find("上一次的菜单") is Some(_), msg="the first run's menu drawn")
  // (the next begun before its Tester, a menu opened then)
  new_run()
  assert_false(@sf.presenting(), msg="gone as the next run begins")
  @sf.menu([Some(@sf.menu_item_of("这一次的菜单", fn() {  }))], from=@sf.at_point(100.0, 300.0))
  let next = rb_tester()
  assert_true(@sf.presenting(), msg="what this run opened before its Tester still presented")
  assert_true(next.find("这一次的菜单") is Some(_), msg="and drawn")
  assert_true(next.find("上一次的菜单") is None)
}

///|
/// How late the made-up core answers in rb_fixture_tester: switches_still_wbtest's.
let rb_core_late_ms : Double = 400.0

///|
/// `mode`'s app on `s` as switches_still_wbtest makes each screen's (fixture_app, then its Tester), over a core answering
/// rb_core_late_ms late, past its first answers and the 1200 ms the old tree's panel took to close (2000 ms in all).
fn rb_fixture_tester(mode : String, s : Screen) -> @ui.Tester {
  let src = @sffixture.round_trip(fixture_app(mode), rb_core_late_ms)
  let t = @ui.Tester::new(fn(c) { view(c, src) }, tree=app_tree(src), w=s.w, h=s.h, platform=s.platform)
  t.run_for(rb_core_late_ms * 5.0)
  t
}

///|
test "a fixture's run begun after another's: ⌘/'s panel it opens stays open, the run before's window's tree let go of before it opens" {
  // (小屏's run, ⌘/'s panel open in it, its window's tree still there as the next fixture is made)
  let first = rb_fixture_tester("keys-dialog", daily_small)
  let small_open = @sfdesk.wide.keys_open.get()
  first.run_for(@ui.move_most_ms)
  // (大屏's, made next as switches_still_wbtest makes each screen's: the run before's tree, following keys_open, put
  // up a panel of its own in this run's presenters and closed it, open said false, as it was let go)
  let next = rb_fixture_tester("keys-dialog", daily_large)
  let large = (@sfdesk.wide.keys_open.get(), @sf.presenting(), next.find(@sf.t("web-main.shortcuts.title")) is Some(_))
  assert_eq((small_open, large), (true, (true, true, true)), msg="小屏 ⌘/ open; 大屏 ⌘/ open, presented, drawn")
}
