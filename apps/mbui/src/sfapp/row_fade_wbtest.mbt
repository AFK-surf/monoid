// The real chat row's selected ground after its page is left.

///|
fn fading_chat_row(on : @signals.Signal[Bool], builds : Ref[Int], shown? : @signals.Signal[Bool] = @signals.signal(true)) -> @ui.Tester {
  new_run()
  let src = fixture("home")
  let item = chat_item({
    "id": "fade-row",
    "station": "ws1/st1",
    "session": "s-c1",
    "title": "Fade row",
    "people": [
      { "id": "lin", "shown": { "name": "Lin", "display": "Lin", "mine": false } },
      { "id": "mo", "shown": { "name": "Mo", "display": "Mo", "mine": false } },
    ],
  })
  @sf.set_words(fill)
  let t = @ui.Tester::new(
    fn(c) {
      builds.val += 1
      @sf.begin(c) |> ignore
    },
    tree=fn(root) {
      @ui.set_tree_theme(@sf.ui_theme_now)
      let popup = root.box(fn(v) { v.over(Is(true)) |> ignore })
      let tips = @sf.TipLayer::new(fn() { Some(popup) })
      root.show(fn() { shown.get() }, at_once=true, fn(wrap) {
        wrap.width(Is(Some(390.0))) |> ignore
        @sfpages.chat_row_node(
          wrap,
          src,
          tips,
          fn() { item },
          "people",
          fn() { on.get() },
          Whole,
          fn() { 0 },
          list_ground=fn() { 0x123456FFL },
        )
        |> ignore
      })
    },
    w=390.0,
    h=200.0,
    platform=2,
  )
  t.set_frame_period(1000.0 / 120.0)
  t.draw()
  t
}

///|
fn fade_row_ground(t : @ui.Tester) -> Int64 {
  let ink = @sf.theme().p.selected & 0xFFFFFF00L
  let rects = t.drawn_rects().filter(fn(r) {
    r.2 == 390.0 && r.3 == @sfpages.touch_row_h && (r.4 & 0xFFFFFF00L) == ink
  })
  if rects.is_empty() { 0L } else { rects[0].4 }
}

///|
fn fade_row_rect(t : @ui.Tester) -> (Double, Double, Double, Double) {
  match t.query(Link, label="Fade row") {
    Some(s) => s.rect
    None => (-1.0, -1.0, -1.0, -1.0)
  }
}

///|
fn fade_rings(t : @ui.Tester, ground : Int64) -> Int {
  let ch = fn(v : Double) { (v * 255.0).round().to_int64() }
  t.drawn_instances().filter(fn(a) {
    a[5] == 0.0 && a[6] > 0.0 && a[2] == 20.0 && a[3] == 20.0 &&
    ((ch(a[12]) << 24) | (ch(a[13]) << 16) | (ch(a[14]) << 8) | ch(a[15])) == ground
  }).length()
}

///|
test "a real chat row's selected ground fades without rebuilding or laying out its contents" {
  let on = @signals.signal(true)
  let builds = Ref(0)
  let t = fading_chat_row(on, builds)
  let initial = fade_row_ground(t)
  assert_eq(initial, @sf.theme().p.selected)
  on.set(false)
  t.draw()
  t.run_for(@sfpages.left_lit_ms + @sfpages.left_fade_ms / 4.0)
  t.frame_at(t.time() + t.frame_period())
  let first = fade_row_ground(t)
  t.check_looks(false)
  let before = builds.val
  t.run_for(@sfpages.left_fade_ms / 4.0)
  let middle = fade_row_ground(t)
  let p = t.frame_perf()
  t.check_looks(true)
  assert_true(first != initial && middle != first && middle != 0L, msg="\{initial} -> \{first} -> \{middle}")
  assert_eq(builds.val - before, 0, msg="no frame of the fade builds; got \{builds.val - before}")
  assert_eq((p.passes, p.laid), (0, 0), msg="the last fade frame only paints")
}

///|
test "a chat row keeps its colour, face rings, geometry and press as its selected ground fades" {
  let on = @signals.signal(true)
  let t = fading_chat_row(on, Ref(0))
  let initial = fade_row_ground(t)
  let rect = fade_row_rect(t)
  assert_eq((rect.2, rect.3), (390.0, @sfpages.touch_row_h))
  assert_eq(fade_rings(t, @sf.over(0x123456FFL, initial)), 2)
  on.set(false)
  let left_at = t.time()
  t.draw()
  t.run_for(@sfpages.left_lit_ms / 2.0)
  assert_eq(fade_row_ground(t), initial)
  t.run_for(@sfpages.left_lit_ms / 2.0 + @sfpages.left_fade_ms / 2.0)
  let at = t.time() - (left_at + @sfpages.left_lit_ms)
  let fraction = @motion.tween(@sfpages.left_fade_ms, ease=Leave).value_at(at, @sfpages.left_fade_ms, 1.0, 0.0, 0.0).0
  let ground = @sf.alpha(initial, fraction)
  assert_eq(fade_row_ground(t), ground)
  assert_eq(fade_rings(t, @sf.over(0x123456FFL, ground)), 2)
  assert_eq(fade_row_rect(t), rect)
  let (x, y) = t.find("Fade row").unwrap()
  t.press_at(x, y)
  t.run_for(@ui.tap_indication_ms)
  let pressed = @sf.alpha(@sf.theme().p.text, 0.05)
  assert_true(t.drawn_rects().iter().any(fn(r) { r.2 == rect.2 && r.3 == rect.3 && r.4 == pressed }))
  assert_eq(fade_rings(t, @sf.over(0x123456FFL, pressed)), 2)
  t.release(x, y)
  assert_true(app.nav.top() is Chat(_))
  t.run_for(@sfpages.left_fade_ms)
  assert_eq(fade_row_ground(t), 0L)
  assert_eq(fade_rings(t, 0x123456FFL), 2)
  assert_eq(fade_row_rect(t), rect)
}

///|
test "a chat row selected again cancels its old fade, and a later return starts its own" {
  let on = @signals.signal(true)
  let t = fading_chat_row(on, Ref(0))
  let initial = fade_row_ground(t)
  on.set(false)
  t.draw()
  t.run_for(@sfpages.left_lit_ms + @sfpages.left_fade_ms / 2.0)
  assert_true(fade_row_ground(t) != initial)
  on.set(true)
  t.draw()
  t.run_for(@sfpages.left_fade_ms)
  assert_eq(fade_row_ground(t), initial)
  on.set(false)
  t.draw()
  t.run_for(@sfpages.left_lit_ms / 2.0)
  assert_eq(fade_row_ground(t), initial)
  t.run_for(@sfpages.left_lit_ms / 2.0 + @sfpages.left_fade_ms)
  assert_eq(fade_row_ground(t), 0L)
}

///|
test "a chat row's fade respects reduced motion" {
  let on = @signals.signal(true)
  let t = fading_chat_row(on, Ref(0))
  t.set_reduce_motion(true)
  t.draw()
  on.set(false)
  t.draw()
  t.run_for(@sfpages.left_lit_ms + t.frame_period())
  assert_eq(fade_row_ground(t), 0L)
}

///|
test "a removed chat row does not leave the hold's wake behind" {
  let on = @signals.signal(true)
  let shown = @signals.signal(true)
  let t = fading_chat_row(on, Ref(0), shown~)
  on.set(false)
  t.draw()
  assert_true(t.wanted_after() < @double.infinity)
  shown.set(false)
  t.draw()
  assert_eq(t.wanted_after(), @double.infinity)
}

///|
test "a removed chat row is not built when its old fade would have ended" {
  let on = @signals.signal(true)
  let shown = @signals.signal(true)
  let t = fading_chat_row(on, Ref(0), shown~)
  on.set(false)
  let left_at = t.time()
  t.draw()
  t.run_for(@sfpages.left_lit_ms + @sfpages.left_fade_ms / 4.0)
  let end = left_at + @sfpages.left_lit_ms + @sfpages.left_fade_ms
  assert_true(end > t.time())
  shown.set(false)
  t.draw()
  t.frame_at(end)
  assert_eq(t.built_why(), "")
  assert_eq(t.wanted_after(), @double.infinity)
}
