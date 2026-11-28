// The bar told what it shows at the moment of what changed it (a page put on the stack, a place come in), whatever
// frames are drawn after: where it is at a moment a function of that moment and what was done, at 60 Hz, 120 Hz or in
// one jump; built again with nothing changed, its ways the same.

///|
/// Where the bar is at `t0 + 160` (the frames' clock) with a page put on the stack at `t0 + 10`, frames drawn at
/// `t0 +` each of `frames` between: when it set out going (from t0), how far shown and to where, the notch, the ball across, how far shown and its size.
fn bar_after_push(frames : Array[Double]) -> (Double, Double, Double, Double, Double, Double, Double) {
  let t = tester("home")
  let rest = bar_rest()
  if rest > t.time() {
    t.run_for(rest - t.time())
  }
  let t0 = t.time()
  t.advance(between_frames_ms)
  app.nav.push(Settings)
  for f in frames {
    t.frame_at(t0 + f)
  }
  t.frame_at(t0 + 160.0)
  let now = t.time()
  (
    bar.vis.start - t0,
    bar.vis.at(now).0,
    bar.vis.target,
    bar.k.at(now).0,
    bar.ball_x.at(now).0,
    bar.ball_alpha.at(now).0,
    bar.ball_scale.at(now).0,
  )
}

///|
test "bar: a page put on the stack between frames, the bar going from that moment: the same at a moment, whichever frames came between" {
  let one = bar_after_push([])
  let late = bar_after_push([40.0])
  let many = bar_after_push([11.0, 13.0, 16.0, 24.0, 33.0, 80.0])
  assert_eq((late, many), (one, one))
  // (going from the moment the page was put on: hidden by then, not there yet)
  assert_true((one.0 - between_frames_ms).abs() < 0.000001 && one.1 > 0.0 && one.1 < 1.0 && one.2 == 0.0, msg="\{Repr(one)}")
}

///|
test "bar: told the same again, at another moment, by a build or as the state is read again: its ways as they were" {
  let t = tester("home")
  let t0 = t.time()
  t.advance(between_frames_ms)
  app.nav.push(Settings)
  t.frame_at(t0 + 16.0)
  let ways = fn() {
    (bar.vis.start, bar.vis.from, bar.vis.target, bar.vis.dur, bar.k.to, bar.ball_x.to, bar.ball_alpha.start)
  }
  let first = ways()
  // (the same told again later, as a reaction or a build would)
  bar_tell(bar.told.unwrap(), t0 + 30.0)
  let again = ways()
  // (frames built on at other moments)
  t.frame_at(t0 + 40.0)
  t.frame_at(t0 + 41.0)
  assert_eq((again, ways()), (first, first))
  assert_eq(first.0, t0 + between_frames_ms)
}

///|
/// The tester at rest on the chats, and where it is from then (t0).
fn bar_at_rest() -> (@ui.Tester, Double) {
  let t = tester("home")
  let rest = bar_rest()
  if rest > t.time() {
    t.run_for(rest - t.time())
  }
  (t, t.time())
}

///|
/// bar_at_rest's with the bar's places four, each a slot of its own and no menu (the bars kept one bar of four): for
/// what is held of the ball across all four slots.
fn bar_four_at_rest() -> (@ui.Tester, Double) {
  let t = tester("home")
  bars_picked.set(Some(([["chats", "files", "profiles", "stations"]], 0)))
  t.draw()
  let rest = bar_rest()
  if rest > t.time() {
    t.run_for(rest - t.time())
  }
  (t, t.time())
}

///|
/// How lit place `key` of the bar is at `now` (1 lit, 0 not; -1 never told).
fn bar_lit(key : String, now : Double) -> Double {
  match bar.tints.get("bar:" + key) {
    Some(g) => g.at(now).0
    None => -1.0
  }
}

///|
/// A place of the bar in the fixture whose notch offers `action` ("plus": ＋, another action than the chats' 令; "":
/// none, the notch closed).
fn bar_place_with(action : String) -> String {
  let src = fixture("home")
  let ws = workspace_in_view(src).0.unwrap()
  let (sets, cur) = bars_in(src, ws.id)
  // (the bar shown's first, then the others')
  let places = sets[cur].copy()
  for set in sets {
    for p in set {
      if !places.contains(p) {
        places.push(p)
      }
    }
  }
  match places.iter().find_first(fn(p) { bar_action(src, ws, Some(p), bar_place_add(src, ws, Some(p))) == action }) {
    Some(p) => p
    None => @halt.saying("no place of the bar offers \"\{action}\"")
  }
}

///|
/// Where the bar is at `t0 + 160` with another place come in at `t0 + 10` (its notch's action another), frames drawn at
/// `t0 +` each of `frames` between: the notch's icon and how far its swap is and since when, how lit the place come in
/// and the chats, the ball across.
fn bar_after_place(place : String, frames : Array[Double]) -> (String, Double, Double, Double, Double, Double) {
  let (t, t0) = bar_at_rest()
  t.advance(between_frames_ms)
  if !@sfbase.go_place(place) {
    @halt.saying("not gone to \{place}")
  }
  for f in frames {
    t.frame_at(t0 + f)
  }
  t.frame_at(t0 + 160.0)
  let now = t.time()
  (m_face.val, bar.icon_swap.start - t0, bar.icon_swap.at(now).0, bar_lit(place, now), bar_lit("chats", now), bar.ball_x.at(now).0)
}

///|
test "bar: another place come in between frames, its notch's action another: the icon's swap, the places lit and the ball from that moment, whichever frames came between" {
  let place = bar_place_with("plus")
  let one = bar_after_place(place, [])
  let late = bar_after_place(place, [40.0])
  let many = bar_after_place(place, [11.0, 13.0, 16.0, 24.0, 33.0, 80.0])
  assert_eq((late, many), (one, one))
  assert_eq(one.0, "plus")
}

///|
/// Where the ball is at `t0 + 160` with the bar's places put in another order at `t0 + 10` (the place shown the same,
/// elsewhere in it), frames drawn at `t0 +` each of `frames` between: across, and since when it goes there.
fn bar_after_order(frames : Array[Double]) -> (Double, Double, Double) {
  let (t, t0) = bar_at_rest()
  let src = fixture("home")
  let ws = workspace_in_view(src).0.unwrap()
  let (sets, cur) = bars_in(src, ws.id)
  let turned = sets.copy()
  turned[cur] = sets[cur].rev()
  t.advance(between_frames_ms)
  bars_picked.set(Some((turned, cur)))
  for f in frames {
    t.frame_at(t0 + f)
  }
  t.frame_at(t0 + 160.0)
  (bar.ball_x.at(t.time()).0, bar.ball_x.to, bar.ball_x.set_at - t0)
}

///|
test "bar: its places put in another order between frames, the place shown the same: the ball off to it from that moment, whichever frames came between" {
  let one = bar_after_order([])
  let late = bar_after_order([40.0])
  let many = bar_after_order([11.0, 13.0, 16.0, 24.0, 33.0, 80.0])
  assert_eq((late, many), (one, one))
  assert_true((one.2 - between_frames_ms).abs() < 0.000001, msg="\{Repr(one)}")
}

///|
/// The bar told, on the chats in a window 466 wide, the system's bars `right` wide down its right side.
fn bar_width_beside(t : @ui.Tester, right : Int) -> Double {
  t.post(@hostapi.system_channel, "{\"bars\":{\"top\":0,\"bottom\":20,\"left\":0,\"right\":\{right}}}")
  t.run_for(@ui.move_most_ms)
  bar.told.unwrap().width
}

///|
test "bar: told the width of the box it is laid out in, the system's bar down the side taken off it; the window the same, that bar gone: wider" {
  new_run()
  let src = fixture("home")
  let t = @ui.Tester::new(fn(c) { view(c, src) }, tree=app_tree(src), w=466.0, h=678.0, platform=1)
  let beside = bar_width_beside(t, 84)
  let none = bar_width_beside(t, 0)
  assert_eq((beside, none), (466.0 - 84.0 - 44.0, 466.0 - 44.0))
  // (and laid out so: where the ball is, the place shown's, by that width)
  assert_eq(bar.width, none)
}

///|
/// A finger down on the bar's first place at 10, the window let go of in front at `lost` (or not), let go at 600 with no
/// move: whether the place under it was gone to (a tap) and the lens (held still) ever shown.
fn bar_held_then(lost : Double?) -> (Bool, Bool) {
  let (t, t0) = bar_at_rest()
  let (xs, y) = bar_places_at()
  let start = app.nav.top()
  let lens = Ref(false)
  t.app_state(true, true)
  t.advance(between_frames_ms)
  t.touch_at(0, xs[1], y, t0 + between_frames_ms)
  match lost {
    Some(at) => {
      t.advance(t0 + at - t.time())
      t.app_state(true, false)
    }
    None => ()
  }
  for at in [200.0, 300.0, 500.0] {
    t.frame_at(t0 + at)
    if bar.drag >= 0.0 {
      lens.val = true
    }
  }
  t.advance(t0 + 600.0 - t.time())
  t.touch_at(2, xs[1], y, t0 + 600.0)
  t.frame_at(t0 + 700.0)
  (app.nav.top() != start, lens.val)
}

///|
test "bar: held still on a place, let go without moving: the lens while held, then that place as a tap; called off first, nothing" {
  assert_eq(bar_held_then(None), (true, true))
  assert_eq(bar_held_then(Some(50.0)), (false, false))
}

///|
/// What a finger dragged on the bar from (`x0`, `y0`) to (`x1`, `y1`) felt, the bar at rest on the chats first.
fn bar_felt(x0 : Double, y0 : Double, x1 : Double, y1 : Double) -> Array[@ui.Haptic] {
  let (t, _) = bar_at_rest()
  let before = t.haptics().length()
  t.drag(x0, y0, x1, y1, steps=40)
  t.run_for(@ui.move_most_ms)
  let felt = t.haptics()
  felt[before:].to_owned()
}

///|
test "bar: felt as a finger takes the ball across, a tick at each place it gets to; held still or drawn up over its own place, nothing" {
  let (xs, y) = bar_places_at()
  assert_eq(bar_felt(xs[0], y, xs[2], y), [@ui.TextHandleMove, @ui.TextHandleMove])
  // (within the slop for longer than a hold: the ball taken as a held finger takes it, the lens over it; nothing felt,
  // as Comma's bar, whose lens lifts unfelt)
  assert_eq(bar_felt(xs[0], y, xs[0] + 10.0, y), [])
  assert_eq(bar_felt(xs[0], y, xs[0], y - 64.0), [])
}

///|
/// A moment between two frames (one each 16⅔ ms): what is told there is so from then, not from a frame.
let between_frames_ms : Double = 10.0

///|
/// How long a tap's finger is down.
let tap_held_ms : Double = 30.0

///|
/// First line where two drawlists differ, for diagnostics; empty when identical.
fn drawlist_first_diff(got : String, want : String) -> String {
  if got == want {
    return ""
  }
  let a = got.split("\n").map(fn(s) { s.to_owned() }).to_array()
  let b = want.split("\n").map(fn(s) { s.to_owned() }).to_array()
  let n = if a.length() < b.length() { a.length() } else { b.length() }
  let diffs : Array[String] = []
  for i in 0..<n {
    if a[i] != b[i] {
      diffs.push("line \{i + 1}:\n  got : \{a[i]}\n  want: \{b[i]}")
      if diffs.length() >= 8 {
        break
      }
    }
  }
  if a.length() != b.length() {
    diffs.push("lengths: got=\{a.length()} want=\{b.length()}")
  }
  diffs.join("\n")
}

///|
/// Render Home at rest starting in `start_dark` from frame 0, then when `switch_theme` is true switch system dark to
/// `end_dark` while the bottom bar stays mounted; return its full drawlist.
fn bar_theme_switch_drawlist(start_dark : Bool, end_dark : Bool, switch_theme : Bool) -> String {
  new_run()
  let src = fixture(if start_dark { "home-dark" } else { "home" })
  let t = @ui.Tester::new(fn(c) { view(c, src) }, tree=app_tree(src), w=390.0, h=844.0, platform=2, dark=start_dark)
  (src.call)("prefs.set", { "appearance": Json::string("system") }, @sfbase.answer_unread)
  t.draw()
  t.run_for(@ui.move_most_ms)
  if switch_theme {
    t.set_dark(end_dark)
  }
  t.draw()
  t.run_for(@ui.move_most_ms)
  t.drawlist()
}

///|
test "bar: switching system theme light <-> dark or accent while mounted updates the bottom bar glass, ball and action to match a fresh run" {
  for case in [(false, true), (true, false)] {
    let (from_dark, to_dark) = case
    let switched = bar_theme_switch_drawlist(from_dark, to_dark, true)
    let fresh = bar_theme_switch_drawlist(to_dark, to_dark, false)
    let diff = drawlist_first_diff(switched, fresh)
    assert_eq(diff, "", msg="home \{from_dark}->\{to_dark}:\n\{diff}")
  }
  // switching accent while the bottom bar is mounted updates the bar's tinted glass and action disc too
  new_run()
  let src = fixture("home")
  let t = @ui.Tester::new(fn(c) { view(c, src) }, tree=app_tree(src), w=390.0, h=844.0, platform=2)
  t.draw()
  t.run_for(@ui.move_most_ms)
  @sfbase.accent_preview(Some("blue"))
  t.draw()
  t.run_for(@ui.move_most_ms)
  let switched_accent = t.drawlist()
  new_run()
  @sfbase.accent_preview(Some("blue"))
  let src2 = fixture("home")
  let t2 = @ui.Tester::new(fn(c) { view(c, src2) }, tree=app_tree(src2), w=390.0, h=844.0, platform=2)
  t2.draw()
  t2.run_for(@ui.move_most_ms)
  t2.draw()
  t2.run_for(@ui.move_most_ms)
  let fresh_accent = t2.drawlist()
  @sfbase.accent_preview(None)
  let diff = drawlist_first_diff(switched_accent, fresh_accent)
  assert_eq(diff, "", msg="home accent orange->blue:\n\{diff}")
}

///|
test "bar: pressed bottom tab lens (slot 7 == -64.0) emits soft raised shadow in light and zero outer shadow in dark" {
  for dark in [false, true] {
    new_run()
    let src = fixture(if dark { "home-dark" } else { "home" })
    let t = @ui.Tester::new(fn(c) { view(c, src) }, tree=app_tree(src), w=390.0, h=844.0, platform=2, dark~)
    t.draw()
    t.run_for(@ui.move_most_ms)
    let expected_bar_shadow = @sf.tab_bar_shadow()
    let rest_shadows = t.drawn_shadows()
    assert_true(
      rest_shadows.iter().any(fn(s) {
        (s.5 - expected_bar_shadow.sigma).abs() < 0.01 &&
        s.6 == expected_bar_shadow.color
      }),
      msg="dark=\{dark}: regular bottom bar at rest must keep its outer shadow",
    )
    let (xs, y) = bar_places_at()
    t.press_at(xs[0], y)
    t.run_for(bar_hold_ms)
    t.run_for(@ui.move_most_ms)
    let mut saw_lens = false
    let mut lens_rect = (0.0, 0.0, 0.0, 0.0)
    for inst in t.drawn_instances() {
      if inst[5] == 6.0 && (inst[7] - -64.0).abs() < 0.01 {
        saw_lens = true
        lens_rect = (inst[0], inst[1], inst[2], inst[3])
      }
    }
    assert_true(saw_lens, msg="dark=\{dark}: pressed bottom tab must emit clear lens with slot 7 == -64.0 (role 4, no zoom of its own)")
    let pressed_shadows = t.drawn_shadows()
    assert_true(
      pressed_shadows.iter().any(fn(s) {
        (s.5 - expected_bar_shadow.sigma).abs() < 0.01 &&
        s.6 == expected_bar_shadow.color
      }),
      msg="dark=\{dark}: regular bottom bar must keep its outer shadow while tab is pressed",
    )
    let expected_lens_shadow = @sf.tab_lens_raised_for(dark)
    let lens_has_shadow = pressed_shadows.iter().any(fn(s) {
      (s.0 - lens_rect.0).abs() < 1.0 &&
      (s.1 - (lens_rect.1 + expected_lens_shadow.dy)).abs() < 1.0 &&
      (s.2 - lens_rect.2).abs() < 1.0 &&
      (s.3 - lens_rect.3).abs() < 1.0 &&
      (s.5 - expected_lens_shadow.sigma).abs() < 0.01 &&
      s.6 == expected_lens_shadow.color
    })
    if dark {
      assert_eq(
        pressed_shadows.length(),
        rest_shadows.length(),
        msg="dark=true: pressing bottom tab lens must not add any outer shadow (rest=\{rest_shadows.length()}, pressed=\{pressed_shadows.length()})",
      )
      assert_true(!lens_has_shadow, msg="dark=true: pressed bottom tab lens must have no outer shadow")
    } else {
      assert_eq(
        pressed_shadows.length(),
        rest_shadows.length() + 1,
        msg="dark=false: pressing bottom tab lens must emit 1 soft raised shadow (rest=\{rest_shadows.length()}, pressed=\{pressed_shadows.length()})",
      )
      assert_true(lens_has_shadow, msg="dark=false: pressed bottom tab lens must match tab_lens_raised_for(false)")
    }
    t.release(xs[0], y)
    t.run_for(@ui.move_most_ms)
  }
}

///|
let bar_shadow_step_ms : Double = 1000.0 / 60.0

///|
test "bar: light tab lens outer shadow scales sigma, dy, and effective alpha continuously across lift and unlift" {
  if @ui.test_at_a_rate() {
    return
  }
  new_run()
  let src = fixture("home")
  let t = @ui.Tester::new(fn(c) { view(c, src) }, tree=app_tree(src), w=390.0, h=844.0, platform=2, dark=false)
  t.draw()
  t.run_for(@ui.move_most_ms)
  let rest_shadow_count = t.drawn_shadows().length()
  let expected = @sf.tab_lens_raised_for(false)
  let base_alpha = (expected.color & 0xFFL).to_double() / 255.0
  let (xs, y) = bar_places_at()
  // Trigger cross-tab tap in light mode so held lifts 0 -> 1 and settles back 1 -> 0
  t.tap(xs[2], y)
  let mut saw_mid_shadow = false
  let mut max_sigma = 0.0
  let mut max_dy = 0.0
  let mut prev_sigma = 0.0
  let mut prev_dy = 0.0
  let mut prev_alpha = 0.0
  for _ in 0..<48 {
    t.run_for(bar_shadow_step_ms)
    let h = dclamp(bar.held_at(t.time()), 0.0, 1.0)
    let mut lens_rect : (Double, Double, Double, Double)? = None
    for inst in t.drawn_instances() {
      // Role 4 encodes -(64.0 + 0.16 * p) in slot 7, spanning [-64.16, -64.0] during lift/unlift
      if inst[5] == 6.0 && inst[7] <= -63.99 && inst[7] >= -64.20 {
        lens_rect = Some((inst[0], inst[1], inst[2], inst[3]))
      }
    }
    let mut cur_sigma = 0.0
    let mut cur_dy = 0.0
    let mut cur_alpha = 0.0
    match lens_rect {
      Some(lr) =>
        for inst in t.drawn_instances() {
          if inst[5] == 2.0 &&
            (inst[0] - lr.0).abs() < 1.0 &&
            (inst[2] - lr.2).abs() < 1.0 &&
            (inst[3] - lr.3).abs() < 1.0 {
            cur_sigma = inst[7]
            cur_dy = inst[1] - lr.1
            cur_alpha = inst[11]
          }
        }
      None => ()
    }
    if cur_alpha > 0.0 {
      assert_true(
        (cur_sigma - expected.sigma * h).abs() < 0.35,
        msg="lens shadow sigma must scale with held: got=\{cur_sigma} expected=\{expected.sigma * h} h=\{h}",
      )
      assert_true(
        (cur_dy - expected.dy * h).abs() < 0.6,
        msg="lens shadow dy must scale with held: got=\{cur_dy} expected=\{expected.dy * h} h=\{h}",
      )
      assert_true(
        cur_alpha <= base_alpha + 0.005,
        msg="lens shadow alpha exceeded base: got=\{cur_alpha} base=\{base_alpha}",
      )
      if cur_sigma > 0.4 && cur_sigma < expected.sigma - 0.6 && cur_dy > 0.2 && cur_dy < expected.dy - 0.4 {
        saw_mid_shadow = true
      }
    }
    if cur_sigma > max_sigma {
      max_sigma = cur_sigma
    }
    if cur_dy > max_dy {
      max_dy = cur_dy
    }
    // Adjacent 60fps frames must transition smoothly with no binary pop
    assert_true(
      (cur_alpha - prev_alpha).abs() <= base_alpha * 0.45 + 0.005,
      msg="lens shadow alpha jumped between frames: prev=\{prev_alpha} cur=\{cur_alpha}",
    )
    if cur_alpha > 0.0 && prev_alpha > 0.0 {
      assert_true(
        (cur_sigma - prev_sigma).abs() <= 2.2,
        msg="lens shadow sigma jumped between frames: prev=\{prev_sigma} cur=\{cur_sigma}",
      )
      assert_true(
        (cur_dy - prev_dy).abs() <= 1.3,
        msg="lens shadow dy jumped between frames: prev=\{prev_dy} cur=\{cur_dy}",
      )
    }
    prev_sigma = cur_sigma
    prev_dy = cur_dy
    prev_alpha = cur_alpha
  }
  assert_true(saw_mid_shadow, msg="expected intermediate shadow sigma/dy frames during light lens lift/unlift")
  assert_true(max_sigma > expected.sigma * 0.85, msg="peak lens shadow sigma too low: \{max_sigma}")
  assert_true(max_dy > expected.dy * 0.85, msg="peak lens shadow dy too low: \{max_dy}")
  // Settled back at rest: held <= 0.001 -> zero outer lens shadows remain (tab 3 may also close the `+` notch shadow)
  t.run_for(@ui.move_most_ms)
  assert_true(bar.held_at(t.time()) <= 0.001, msg="bar.held_at must settle back to 0 at rest")
  let settled_shadows = t.drawn_shadows()
  assert_true(
    settled_shadows.length() <= rest_shadow_count,
    msg="settled light tab bar must not retain extra shadows (rest=\{rest_shadow_count}, settled=\{settled_shadows.length()})",
  )
  assert_true(
    !settled_shadows.iter().any(fn(s) { s.6 == expected.color }),
    msg="settled light tab bar must leave zero outer lens shadows",
  )
}

// ── the menu's glass (Comma Android's TabMenuMorphTest.kt, by the same numbers: a bar 50 high, a menu of five rows) ──

///|
/// The menu's glass from `t0` till it rests, sampled each 120th of a second: (seconds on, its height, its pinch).
fn morph_path(t0 : Double) -> Array[(Double, Double, Double)] {
  let menu = bar_menu
  let path = []
  let ends = menu.morph_ends()
  let mut i = 1
  while t0 + i.to_double() * 1000.0 / 120.0 <= ends + 1000.0 / 120.0 && i < 360 {
    let t = t0 + i.to_double() * 1000.0 / 120.0
    path.push(((t - t0) / 1000.0, menu.height_at(t), menu.pinch.value_at(t)))
    i = i + 1
  }
  path
}

///|
/// The menu's glass as at the start, a menu of five rows (256 high over a bar of 50).
fn morph_new() -> BarMenu {
  bar_menu.reset()
  bar_menu.rows = 5
  bar_menu
}

///|
test "bar menu glass: opening grows the bar into the menu with a little spring past it, and settles there; its pinch draws the bar in by a fifth at once and lets it out without passing its length" {
  let menu = morph_new()
  let full = menu.full()
  assert_eq(full, 256.0)
  menu.morph_open(1000.0)
  let path = morph_path(1000.0)
  let ends = menu.morph_ends()
  assert_eq((menu.height_at(ends), menu.progress_at(ends), menu.major_at(ends)), (full, 1.0, 1.0))
  let highest = path.fold(init=0.0, fn(a, p) { dmax(a, p.1) })
  assert_true(highest > full + 2.0 && highest < full + 12.0, msg="it springs a little past the menu: \{highest}")
  let near = path.iter().find_first(fn(p) { p.1 >= full - 1.0 }).unwrap()
  assert_true(near.0 < 0.25, msg="nearly there within a quarter of a second: \{near.0}")
  let mut peak = path[0]
  for p in path {
    if p.2 > peak.2 {
      peak = p
    }
  }
  assert_true((peak.2 - pinch_open).abs() < 0.015, msg="the pinch peaks at a fifth: \{peak.2}")
  assert_true((peak.0 - 0.08).abs() < 0.012, msg="about 80 ms in: \{peak.0}")
  assert_true(path.iter().all(fn(p) { p.2 >= 0.0 }), msg="never wider than the bar")
  bar_menu.reset()
}

///|
test "bar menu glass: closing folds the menu back to the bar without dipping under it, pinched on the way; a glass still drawn in is not struck as hard again" {
  let menu = morph_new()
  menu.h.put(menu.full())
  menu.morph_close(1000.0)
  let path = morph_path(1000.0)
  let ends = menu.morph_ends()
  assert_eq((menu.height_at(ends), menu.pinch.value_at(ends)), (bar_track, 0.0))
  let lowest = path.fold(init=1000.0, fn(a, p) { dmin(a, p.1) })
  assert_true(lowest > bar_track - 1.0, msg="it does not dip visibly under the bar: \{lowest}")
  let most = path.fold(init=0.0, fn(a, p) { dmax(a, p.2) })
  assert_true((most - pinch_close).abs() < 0.015, msg="\{most}")
  // struck open, then closed at the height of the opening pinch
  let menu = morph_new()
  menu.morph_open(1000.0)
  let at = 1000.0 + 10.0 * 1000.0 / 120.0
  let drawn_in = menu.pinch.value_at(at)
  assert_true(drawn_in >= pinch_close, msg="already past what a close draws it in: \{drawn_in}")
  menu.morph_close(at)
  let later = morph_path(at).fold(init=0.0, fn(a, p) { dmax(a, p.2) })
  assert_true(later <= drawn_in + 0.000001, msg="it only lets out from there: \{later} from \{drawn_in}")
  bar_menu.reset()
}

///|
test "bar menu glass: a close during the opening turns the glass round from where it is, at the speed it has" {
  let menu = morph_new()
  menu.morph_open(1000.0)
  let at = 1000.0 + 8.0 * 1000.0 / 120.0
  let (turned, speed) = menu.h.at(at)
  assert_true(turned > bar_track + 20.0 && turned < menu.full() && speed > 0.0, msg="\{turned} \{speed}")
  menu.morph_close(at)
  assert_eq(menu.h.at(at), (turned, speed))
  assert_true(menu.height_at(at + 1000.0 / 120.0) > turned, msg="still on its way up for a moment")
  assert_eq(menu.height_at(menu.morph_ends()), bar_track)
  bar_menu.reset()
}

///|
test "bar menu glass: the tab row has gone before the rows are whole, and the glass is never empty; a glyph is zoomed only where the lens is over it" {
  assert_eq((tabs_opacity(0.0), tabs_opacity(0.6), rows_opacity(0.2), rows_opacity(0.9)), (1.0, 0.0, 0.0, 1.0))
  for step in 0..=20 {
    let p = step.to_double() / 20.0
    assert_true(tabs_opacity(p) + rows_opacity(p) > 0.3, msg="\{p}")
  }
  // (TabBarGeometryTest.kt: under the lens the whole zoom, past half a glyph beyond its edge none, in between smoothly)
  assert_eq(lens_glyph_zoom(0.0, 92.0, 1.0), lens_zoom)
  assert_eq(lens_glyph_zoom(46.0 + glyph_half, 92.0, 1.0), 1.0)
  assert_eq(lens_glyph_zoom(-200.0, 92.0, 1.0), 1.0)
  assert_eq(lens_glyph_zoom(0.0, 92.0, 0.0), 1.0)
  let edge = lens_glyph_zoom(46.0, 92.0, 1.0)
  assert_true((edge - (1.0 + (lens_zoom - 1.0) / 2.0)).abs() < 0.000001, msg="\{edge}")
  // (rows under a finger: a little to either side still picks, off the menu nothing)
  assert_eq(
    (bar_row_at(100.0, 8.0 + 48.0 * 2.0 + 1.0, 286.0, 5), bar_row_at(-20.0, 30.0, 286.0, 5), bar_row_at(-30.0, 30.0, 286.0, 5), bar_row_at(100.0, -1.0, 286.0, 5), bar_row_at(100.0, 255.0, 286.0, 5)),
    (2, 0, -1, -1, 4),
  )
}

///|
/// The bar's menu at `t0 + 400` with a finger down on the last slot at `t0 + 10`, up over the rows by `t0 + 200` and
/// still there, frames drawn at `t0 +` each of `frames` between (none at all between some): the glass's height and
/// pinch, where the indicator is and how much of it shows, the bottom row's rise and the top row's, how much of the tab
/// row shows.
fn menu_at_moment(frames : Array[Double]) -> (Double, Double, Double, Double, Double, Double, Double, Double) {
  let (t, t0) = bar_at_rest()
  let (xs, y) = bar_places_at()
  let (rx, rys) = menu_rows_at(5)
  let events = [(0, 10.0, xs[3], y)]
  for i in 1..=10 {
    let f = i.to_double() / 10.0
    events.push((1, 100.0 + i.to_double() * 10.0, xs[3] + (rx - xs[3]) * f, y + (rys[2] - y) * f))
  }
  let mut f = 0
  for e in events {
    let (kind, at, x, ey) = e
    while f < frames.length() && frames[f] <= at {
      t.frame_at(t0 + frames[f])
      f = f + 1
    }
    t.advance(t0 + at - t.time())
    t.touch_at(kind, x, ey, t0 + at)
  }
  while f < frames.length() {
    t.frame_at(t0 + frames[f])
    f = f + 1
  }
  t.frame_at(t0 + 400.0)
  let menu = bar_menu
  let now = t0 + 400.0
  let laid = bar_laid(bar.told.unwrap())
  let ind = menu.ind_at(now, bar_capsule_w(laid.w, bar.k_at(now)), bar_rest_selection(laid, laid.more_slot(), bar.k_at(now)))
  let out = (
    menu.height_at(now),
    menu.pinch.value_at(now),
    ind.t,
    ind.alpha,
    menu.row_at(4, now).0,
    menu.row_at(0, now).1,
    menu.tabs_shown_at(now),
    menu.hovered_row.to_double(),
  )
  t.touch_at(3, rx, rys[2], t0 + 410.0)
  out
}

///|
test "bar menu: opened by a finger that goes on up to a row, each event at its own moment: the same at a moment whichever frames came between, or none" {
  let none = menu_at_moment([])
  let each = menu_at_moment(Array::makei(23, fn(i) { 15.0 + i.to_double() * 1000.0 / 60.0 }))
  let few = menu_at_moment([150.0, 333.0])
  assert_eq((each, few), (none, none))
  // (open, the finger on the third row, the indicator eased on to it)
  assert_true(none.0 > 250.0 && none.7 == 2.0 && none.3 > 0.9 && none.6 == 0.0, msg="\{Repr(none)}")
}

///|
test "bar menu: the lens a finger dragged to the last slot is what the indicator starts as: the same shape as the menu opens, clear, and grey by a third of the glass's growth" {
  let (t, t0) = bar_at_rest()
  let (xs, y) = bar_places_at()
  t.advance(between_frames_ms)
  t.touch_at(0, xs[2], y, t0 + between_frames_ms)
  for i in 1..=20 {
    let at = t0 + 300.0 + i.to_double() * 10.0
    t.advance(at - t.time())
    t.touch_at(1, xs[2] + (xs[3] - xs[2]) * i.to_double() / 20.0, y, at)
  }
  // (resting on the last slot from here: the menu once it has rested there 0.3 s, a moment of the bar's own; the lens
  // as it was a ms before)
  let l = bar_laid(bar.told.unwrap())
  let mut lens = bar_ball_shown_at(l, t.time())
  let mut lift = bar.lift_at(t.time())
  let mut steps = 0
  while !bar_menu.open.get() && steps < 400 {
    lens = bar_ball_shown_at(l, t.time())
    lift = bar.lift_at(t.time())
    t.frame_at(t.time() + 1.0)
    steps = steps + 1
  }
  let now = t.time()
  let rested = now - (t0 + 500.0)
  assert_true(bar_menu.open.get() && bar_menu.tracking, msg="open as the finger has rested, the finger its")
  assert_true(rested > menu_dwell_ms - 40.0 && rested <= menu_dwell_ms + 1.0, msg="rested \{rested} ms")
  assert_true(lift > 0.99, msg="lifted \{lift}")
  let (lcx, _, lsw, lsh) = lens
  let (x, top, w, h, grey, clear) = bar_ind_shown_at(l, now)
  assert_true(
    (x + w / 2.0 - lcx).abs() < 0.2 && (w - lsw).abs() < 0.2 && (h - lsh).abs() < 0.2 && (top + h / 2.0 - (l.row_top + bar_track / 2.0)).abs() < 0.2,
    msg="the indicator (\{x}, \{top}, \{w}, \{h}) starts as the lens (\{lcx}, \{lsw}, \{lsh})",
  )
  assert_true(grey < 0.01 && clear > 0.99 && bar_menu.carry > 0.99, msg="clear at first: grey \{grey} clear \{clear}")
  assert_eq(bar.pill_alpha_at(now), 0.0)
  // (grey by 35 % of the glass's growth, the lens gone)
  let mut at = now
  while bar_menu.progress_at(at) < lens_to_grey {
    at = at + 1.0
  }
  let (_, _, _, _, grey, clear) = bar_ind_shown_at(l, at)
  assert_true(grey > 0.99 && clear < 0.01, msg="grey \{grey} clear \{clear} at \{bar_menu.progress_at(at)}")
  t.touch_at(3, xs[3], y, at)
}
