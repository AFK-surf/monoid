///|
/// What opens by `act` (after `before`, over fixture `mode`, on 小屏 or 大屏) where what `late` names comes
/// `open_late_ms` late, `gates` as open_whole_tester's: how long from the press its first words are seen in the window,
/// and the most bones any frame draws on the way, till `ms` after.
fn first_seen_after(
  wide : Bool,
  gates : Bool,
  mode : String,
  late : (String, Map[String, Json]) -> Bool,
  before : () -> Unit,
  act : (@ui.Tester, Source) -> Unit,
  ms~ : Double,
) -> (Double?, Int) {
  new_run()
  before()
  let src : Source = {
    ..round_trip_again(fixture(mode), 0.0, late=fn(name, params) { if late(name, params) { open_late_ms } else { 0.0 } }),
    reads_ahead: fn() { true },
    gates_opens: fn() { gates },
  }
  let (w, h) = if wide { (1280.0, 800.0) } else { (390.0, 844.0) }
  let t = @ui.Tester::new(fn(c) { view(c, src) }, tree=app_tree(src), w~, h~)
  t.draw()
  t.run_for(@ui.move_most_ms * 2.0)
  let was = t.words().map(fn(x) { x.0 })
  let t0 = t.time()
  act(t, src)
  let mut first : Double? = None
  let mut bones = 0
  while t.time() < t0 + ms {
    t.run_for(@ui.frame_period_default)
    bones = @cmp.maximum(bones, t.bones_drawn())
    if first is None &&
      t.words().iter().any(fn(x) { x.5 > 0.01 && x.2 < h && x.2 + x.4 > 0.0 && !was.contains(x.0) }) {
      first = Some(t.time() - t0)
    }
  }
  (first, bones)
}

///|
test "the chat's sheets made as nodes over a core 40 ms late, on 小屏 and 大屏: an agent's card and what is shared seen only once what they read is answered, no bones on the way" {
  let faults : Array[String] = []
  let on_chat = fn() { app.nav.replace_above(0, [Home, Chat(layer_chat)]) }
  for wide in [false, true] {
    let at = if wide { "大屏" } else { "小屏" }
    for gates in [false, true] {
      let cases : Array[(String, (Double?, Int))] = [
        (
          "Agent 卡",
          first_seen_after(wide, gates, "chat-opened", fn(n, _) { n == "agentCard" }, on_chat, fn(t, src) {
            @ui.view_tree().unwrap().event(t.time(), fn() { open_agent(src, layer_chat, "s-c1") })
          }, ms=@sf.open_hold_ms + @ui.move_most_ms),
        ),
        (
          "分享",
          first_seen_after(wide, gates, "home", fn(n, _) { n == "shareIn" }, fn() {  }, fn(t, _) {
            @ui.view_tree().unwrap().event(t.time(), fn() {
              share_in.shared.set(Some(@sffixture.fix_shared))
              share_in.env_taken.set(true)
            })
          }, ms=@sf.open_hold_ms + @ui.move_most_ms),
        ),
      ]
      for c in cases {
        let (what, (first, bones)) = c
        if bones > 0 {
          faults.push("\{at} \{what} gates \{gates}: \{bones} bones drawn")
        }
        match first {
          None => faults.push("\{at} \{what} gates \{gates}: never seen")
          Some(ms) if gates && ms < open_late_ms => faults.push("\{at} \{what}: seen \{ms} ms after the press, before what it reads")
          _ => ()
        }
      }
    }
  }
  assert_eq(faults, [])
}

///|
test "大屏 往来 over a core that never answers its letters: its bones shown open_hold_ms on, every frame keeping the corner rule (the Tester's own, as each is drawn)" {
  let on_chat = fn() { app.nav.replace_above(0, [Home, Chat(layer_chat)]) }
  for gates in [false, true] {
    let src_late = fn(n : String, _ : Map[String, Json]) { n == "chatLetters" }
    let (first, bones) = first_seen_after(true, gates, "settings", src_late, on_chat, fn(t, src) {
      @ui.view_tree().unwrap().event(t.time(), fn() { open_letters(src, layer_chat, 0.0) })
    }, ms=@sf.open_hold_ms + @ui.move_most_ms * 2.0)
    assert_true(first is Some(_), msg="gates \{gates}: never seen")
    assert_true(bones > 0, msg="gates \{gates}: no bones: the case shows nothing")
  }
}

///|
test "小屏 任务 over a core that answers its jobs 40 ms late, MBUI_OPEN_WHOLE off: the sheet rising on their bones goes on from as tall as it is seen to as tall as its jobs make it, at their answer, never a step" {
  let jobs_whole = fn(name : String, params : Map[String, Json]) { name == "chatJobs" && !params.contains("summary") }
  let on_chat = fn() { app.nav.replace_above(0, [Home, Chat(layer_chat)]) }
  // (each frame on the way judged as it is drawn: sizes_steady's, at every rate)
  let (first, bones) = first_seen_after(false, false, "settings", jobs_whole, on_chat, fn(t, src) {
    @ui.view_tree().unwrap().event(t.time(), fn() { open_chat_jobs(src, layer_chat) })
  }, ms=open_late_ms + @ui.move_most_ms * 2.0)
  assert_true(first is Some(_), msg="never seen")
  assert_true(bones > 0, msg="no bones: the case shows nothing")
}
