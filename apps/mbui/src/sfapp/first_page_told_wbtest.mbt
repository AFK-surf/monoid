// How long the first page took from the splash, told to the host once a process (app.mbt's first_page_timing): not
// again as first_page_node is built anew (signed out and in again, the core started again), first_shown still true;
// and not at all where the person signed in meanwhile.

///|
/// The home fixture, its accounts none while `out` (signed out), its core failed while `failed`.
fn first_told_src(out : @signals.Signal[Bool], failed? : @signals.Signal[Bool] = @signals.signal(false)) -> Source {
  let base = fixture("home")
  {
    ..base,
    topic_read: fn(name, params) {
      if name == "accounts" && out.get() {
        return { value: Some(Json::array([])), error: None, version: 1 }
      }
      base.topic(name, params).get().snapshot()
    },
    fatal: fn() { if failed.get() { Some("the core failed") } else { (base.fatal)() } },
  }
}

///|
/// How long the app is away from its first page in these tests (failed, or signed out): longer than the first page's
/// wait, any of its timers left due meanwhile.
let first_told_away_ms : Double = first_page_ms * 5.0

///|
test "the first page's time told once: not again as it is built anew, the core failed and started again" {
  new_run()
  let told : Array[(Double, Double, Bool)] = []
  first_page_timing.val = Some(fn(shown, in_view, waited) { told.push((shown, in_view, waited)) })
  // (the splash begun at the start, as on a device: the home fixture's opens without one)
  splash_from.val = 0.0
  let failed = @signals.signal(false)
  let src = first_told_src(@signals.signal(false), failed~)
  let t = @ui.Tester::new(fn(c) { view(c, src) }, tree=app_tree(src), w=390.0, h=844.0, platform=2)
  t.run_for(first_page_ms + 100.0)
  assert_true(first_shown.get(), msg="shown")
  assert_eq(told.length(), 1)
  failed.set(true)
  t.run_for(first_told_away_ms)
  failed.set(false)
  t.run_for(first_page_ms + 100.0)
  assert_eq(told.length(), 1)
}

///|
test "the first page's time told once: not again as it is built anew, signed out and in again" {
  new_run()
  let told : Array[(Double, Double, Bool)] = []
  first_page_timing.val = Some(fn(shown, in_view, waited) { told.push((shown, in_view, waited)) })
  // (the splash begun at the start, as on a device: the home fixture's opens without one)
  splash_from.val = 0.0
  let out = @signals.signal(false)
  let src = first_told_src(out)
  let t = @ui.Tester::new(fn(c) { view(c, src) }, tree=app_tree(src), w=390.0, h=844.0, platform=2)
  t.run_for(first_page_ms + 100.0)
  assert_true(first_shown.get(), msg="shown")
  assert_eq(told.length(), 1)
  out.set(true)
  t.run_for(first_told_away_ms)
  out.set(false)
  t.run_for(first_page_ms + 100.0)
  assert_eq(told.length(), 1)
}

///|
test "a first page come after signing in: its time not told, the person's signing in in it" {
  new_run()
  let told : Array[(Double, Double, Bool)] = []
  first_page_timing.val = Some(fn(shown, in_view, waited) { told.push((shown, in_view, waited)) })
  splash_from.val = 0.0
  let out = @signals.signal(true)
  let src = first_told_src(out)
  let t = @ui.Tester::new(fn(c) { view(c, src) }, tree=app_tree(src), w=390.0, h=844.0, platform=2)
  t.run_for(first_told_away_ms)
  out.set(false)
  t.run_for(first_page_ms + 100.0)
  assert_true(first_shown.get(), msg="shown")
  assert_eq(told.length(), 0)
}
