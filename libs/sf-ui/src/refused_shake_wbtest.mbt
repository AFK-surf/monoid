// A control pressed while it cannot be (refused_shake: the button, one as wide as where it is, send): shaken across where it is
// drawn and back exactly where it is laid out, its press not run, nothing asking a frame once it is still; none of it at
// work, under reduced motion, or for a press that went down elsewhere; felt as a refusal under a finger.

///|
/// Moments the tests here look at: a shake's first swing at its widest (refused_dx's), and past its end.
let refused_mid_ms : Double = 40.0

///|
let refused_past_ms : Double = 400.0

///|
/// A window holding the three, each pressed counting in `pressed`: the button "保存" (`busy`, disabled while `off`),
/// the button "继续" as wide as where it is (`across`, the same), send "发送" (ready while not `off`, starting while `busy`).
fn refused_case(off : @signals.Signal[Bool], busy : @signals.Signal[Bool], pressed : Ref[Int]) -> @ui.Tester {
  let t = @ui.Tester::new(fn(_c) {  }, w=400.0, h=400.0, platform=0)
  t.check_looks(false)
  set_dark(Some(false))
  @ui.set_tree_theme(ui_theme_now)
  @ui.set_view_app(fn(root) {
    root.box(fn(col) {
      col.width(Is(Some(300.0))).pad(Is(24.0)).gap(Is(24.0)).lines_up(Is(Some(Start))) |> ignore
      button_node(col, fn() { "保存" }, fn() { pressed.val += 1 }, busy=fn() { busy.get() }, disabled=fn() { off.get() })
      |> ignore
      button_node(col, fn() { "继续" }, fn() { pressed.val += 1 }, tone=Primary, across=true, busy=fn() { busy.get() }, disabled=fn() {
        off.get()
      })
      |> ignore
      send_button_node(col, fn() { "发送" }, fn() { !off.get() }, fn() { busy.get() }, fn() { pressed.val += 1 }) |> ignore
    })
    |> ignore
  })
  t.draw()
  t
}

///|
/// Where control `label` is drawn across now (its rect as a press finds it: where it is drawn, its offset with it).
fn refused_x(t : @ui.Tester, label : String) -> Double {
  match t.query(Button, label~) {
    Some(b) => b.rect.0
    None => -1.0
  }
}

///|
/// Each of the three tapped in turn as `off` and `busy` say, under a finger: where it was at rest, at its widest swing,
/// and past its end; the presses run, the haptics felt.
fn refused_taps(off : Bool, busy : Bool) -> (Array[(Double, Double, Double)], Int, Array[@ui.Haptic], Bool) {
  let pressed = Ref(0)
  let t = refused_case(@signals.signal(off), @signals.signal(busy), pressed)
  t.host_says_finger(Some(true))
  let got = []
  for label in ["保存", "继续", "发送"] {
    let rest = refused_x(t, label)
    let (x, y, w, h) = t.query(Button, label~).unwrap().rect
    t.tap(x + w / 2.0, y + h / 2.0)
    t.run_for(refused_mid_ms)
    let mid = refused_x(t, label)
    t.run_for(refused_past_ms)
    got.push((rest, mid - rest, refused_x(t, label) - rest))
  }
  let idle = t.idle_said() is None
  t.host_says_finger(None)
  (got, pressed.val, t.haptics(), idle)
}

///|
test "refused: a disabled button, wide button and send tapped shake across, then rest exactly where they are laid out" {
  let (got, pressed, haptics, idle) = refused_taps(true, false)
  let widest = refused_dx(refused_mid_ms / refused_ms)
  assert_true(widest > 2.0, msg="its first swing at \{widest}")
  for g in got {
    assert_true((g.1 - widest).abs() < 0.01, msg="its widest swing \{g.1}, refused_dx's \{widest}")
    assert_eq(g.2, 0.0)
  }
  assert_eq((pressed, haptics, idle), (0, [@ui.Reject, @ui.Reject, @ui.Reject], true))
}

///|
test "refused: at work (busy, a new chat being made) a press shakes none of them" {
  let (got, _, haptics, _) = refused_taps(true, true)
  assert_eq(got.map(fn(g) { (g.1, g.2) }), [(0.0, 0.0), (0.0, 0.0), (0.0, 0.0)])
  assert_eq(haptics, [])
}

///|
test "refused: enabled, a press runs and shakes nothing" {
  let (got, pressed, haptics, _) = refused_taps(false, false)
  assert_eq(got.map(fn(g) { (g.1, g.2) }), [(0.0, 0.0), (0.0, 0.0), (0.0, 0.0)])
  assert_eq((pressed, haptics), (3, []))
}

///|
test "refused: under reduced motion the press is felt, nothing moves" {
  @ui.set_motion_chosen(Some(true))
  let (got, pressed, haptics, _) = refused_taps(true, false)
  @ui.set_motion_chosen(None)
  assert_eq(got.map(fn(g) { (g.1, g.2) }), [(0.0, 0.0), (0.0, 0.0), (0.0, 0.0)])
  assert_eq((pressed, haptics), (0, [@ui.Reject, @ui.Reject, @ui.Reject]))
}

///|
test "refused: a press that went down elsewhere and was let go on it, or moved off it, shakes nothing" {
  let pressed = Ref(0)
  let t = refused_case(@signals.signal(true), @signals.signal(false), pressed)
  @ui.set_pointing(Some(Mouse))
  let rest = refused_x(t, "保存")
  let (x, y, w, h) = t.query(Button, label="保存").unwrap().rect
  // (down in the window's empty corner, let go on it; then down on it, let go far off it: a drag, no tap of its)
  t.drag(390.0, 390.0, x + w / 2.0, y + h / 2.0)
  t.run_for(refused_mid_ms)
  let from_elsewhere = refused_x(t, "保存") - rest
  t.run_for(refused_past_ms)
  t.drag(x + w / 2.0, y + h / 2.0, x + w / 2.0, 380.0)
  t.run_for(refused_mid_ms)
  let moved_off = refused_x(t, "保存") - rest
  @ui.set_pointing(None)
  assert_eq((from_elsewhere, moved_off, pressed.val), (0.0, 0.0, 0))
  assert_eq(t.audit(), [])
}

///|
test "refused: its shake dies away by its own curve, at rest exactly at its start and end" {
  assert_eq((refused_dx(0.0), refused_dx(1.0), refused_dx(-0.5), refused_dx(1.5)), (0.0, 0.0, 0.0, 0.0))
  let mut most = 0.0
  for i in 1..<100 {
    let d = refused_dx(i.to_double() / 100.0).abs()
    if d > most {
      most = d
    }
  }
  assert_true(most <= refused_reach && most > 2.0, msg="its widest \{most}")
}

///|
test "refused: send pressed while it can go, its press disabling it (sent), shakes nothing" {
  let off = @signals.signal(false)
  let pressed = Ref(0)
  let t = @ui.Tester::new(fn(_c) {  }, w=200.0, h=160.0, platform=0)
  t.check_looks(false)
  set_dark(Some(false))
  @ui.set_tree_theme(ui_theme_now)
  @ui.set_view_app(fn(root) {
    root.box(fn(page) {
      page.pad(Is(24.0)).lines_up(Is(Some(Start))) |> ignore
      send_button_node(page, fn() { "发送" }, fn() { !off.get() }, fn() { false }, fn() {
        pressed.val += 1
        off.set(true)
      })
      |> ignore
    })
    |> ignore
  })
  t.draw()
  let rest = refused_x(t, "发送")
  let (x, y, w, h) = t.query(Button, label="发送").unwrap().rect
  t.tap(x + w / 2.0, y + h / 2.0)
  t.run_for(refused_mid_ms)
  let sent = refused_x(t, "发送") - rest
  t.run_for(refused_past_ms)
  // (and the next tap on it, now it cannot go, is refused)
  t.tap(x + w / 2.0, y + h / 2.0)
  t.run_for(refused_mid_ms)
  let refused = refused_x(t, "发送") - rest
  assert_eq((pressed.val, sent, refused != 0.0), (1, 0.0, true))
}

///|
test "refused: send drawn over what takes the press there (the field it stands in), pressed while it cannot go, shakes" {
  let pressed = Ref(0)
  let under = Ref(0)
  let t = @ui.Tester::new(fn(_c) {  }, w=400.0, h=200.0, platform=0)
  t.check_looks(false)
  set_dark(Some(false))
  @ui.set_tree_theme(ui_theme_now)
  @ui.set_view_app(fn(root) {
    root.box(fn(row) {
      row.width(Is(Some(320.0))).height(Is(Some(64.0))) |> ignore
      row.box(fn(g) {
        g
        .grow(Is(1.0))
        .presses(Is(true))
        .says(Is(Some(@view.said(Button, label="底"))))
        .on_press(fn() { under.val += 1 })
        |> ignore
      })
      |> ignore
      row.box(fn(o) {
        o.over(Is(true)).padding(Is((260.0, 12.0, 0.0, 0.0))) |> ignore
        send_button_node(o, fn() { "发送" }, fn() { false }, fn() { false }, fn() { pressed.val += 1 }) |> ignore
      })
      |> ignore
    })
    |> ignore
  })
  t.draw()
  let rest = refused_x(t, "发送")
  let (x, y, w, h) = t.query(Button, label="发送").unwrap().rect
  t.tap(x + w / 2.0, y + h / 2.0)
  t.run_for(refused_mid_ms)
  let mid = refused_x(t, "发送") - rest
  t.run_for(refused_past_ms)
  assert_eq((mid != 0.0, refused_x(t, "发送") - rest, pressed.val, under.val), (true, 0.0, 0, 1))
}
