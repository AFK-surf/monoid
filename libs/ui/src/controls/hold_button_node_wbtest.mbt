// A button held to be done (hold_button_node): done once at its full length held, never by a press let go short of it
// or by its letting go after; done at once by the keys (no hold asked of them); done, its undo for a while, then itself.

///|
/// How long the hold here is to be held, a ms, past it held, past every way, its undo's time.
let hold_test_ms : Double = 800.0

///|
let a_ms : Double = 1.0

///|
let hold_past_ms : Double = 900.0

///|
let past_it_ms : Double = 1000.0

///|
let undo_test_ms : Double = 3000.0

///|
/// A hold button alone in a window 390 by 300 (`undo_ms` its undo's time, none at 0), how often it was done and undone.
fn hold_case(done : Ref[Int], undone : Ref[Int], undo_ms? : Double = 0.0) -> @ui.Tester {
  let t = @ui.Tester::new(fn(_c) {  }, w=390.0, h=300.0)
  t.check_looks(false)
  @ui.set_view_app(fn(root) {
    root.box(fn(b) {
      b.lines_up(Is(Some(Start))) |> ignore
      if undo_ms > 0.0 {
        hold_button_node(b, fn() { "按住删除" }, fn() { done.val += 1 }, hold_ms=hold_test_ms, undo=(fn() { undone.val += 1 }, undo_ms), undo_label=fn() {
          "撤销"
        })
        |> ignore
      } else {
        hold_button_node(b, fn() { "按住删除" }, fn() { done.val += 1 }, hold_ms=hold_test_ms) |> ignore
      }
    })
    |> ignore
  })
  t.draw()
  t
}

///|
test "a hold button held its length: done once at it, not before, and not again as it is let go; let go short of it, never done" {
  let done = Ref(0)
  let undone = Ref(0)
  let t = hold_case(done, undone)
  let (x, y) = t.find("按住删除").unwrap()
  t.press_at(x, y)
  t.run_for(hold_test_ms / 2.0)
  let half = done.val
  t.release(x, y)
  t.run_for(past_it_ms)
  let short = done.val
  t.press_at(x, y)
  t.run_for(hold_test_ms - 1.0)
  let before = done.val
  t.run_for(a_ms)
  let at_full = done.val
  t.run_for(hold_test_ms / 4.0)
  t.release(x, y)
  t.run_for(past_it_ms)
  assert_eq((half, short, before, at_full, done.val), (0, 0, 0, 1, 1))
}

///|
test "a hold button by the keys: done at once, read out a button by its name" {
  let done = Ref(0)
  let undone = Ref(0)
  let t = hold_case(done, undone)
  let named = t.semantics().filter(fn(n) { n.role == Button && n.label == "按住删除" }).length()
  t.key(@ui.key_tab)
  t.frame()
  t.enter()
  t.frame()
  assert_eq((named, done.val), (1, 1))
}

///|
test "a hold button done with an undo: 撤销 for its time, pressed undoes it at once; let be, itself again after" {
  let done = Ref(0)
  let undone = Ref(0)
  let t = hold_case(done, undone, undo_ms=undo_test_ms)
  let (x, y) = t.find("按住删除").unwrap()
  t.press_at(x, y)
  t.run_for(hold_past_ms)
  t.release(x, y)
  t.run_for(@ui.move_most_ms)
  let undo_shown = t.find("撤销") is Some(_)
  let (ux, uy) = t.find("撤销").unwrap_or((x, y))
  t.tap(ux, uy)
  t.run_for(@ui.move_most_ms)
  let back = t.find("按住删除") is Some(_)
  let (x2, y2) = t.find("按住删除").unwrap_or((x, y))
  t.press_at(x2, y2)
  t.run_for(hold_past_ms)
  t.release(x2, y2)
  t.run_for(undo_test_ms + @ui.move_most_ms)
  assert_eq((done.val, undone.val, undo_shown, back, t.find("按住删除") is Some(_), t.find("撤销") is None), (2, 1, true, true, true, true))
}

///|
test "a hold button held half its length: its fill drawn over half of it from its start, the words over it in the ground's ink" {
  let done = Ref(0)
  let undone = Ref(0)
  let t = hold_case(done, undone)
  let (x, y) = t.find("按住删除").unwrap()
  let red = theme().p.red
  let ground = t.drawn_rects().filter(fn(r) { r.4 != red })[0]
  t.press_at(x, y)
  t.run_for(hold_test_ms / 2.0)
  let fill = t.drawn_rects().filter(fn(r) { r.4 == red })
  let half = fill.length() == 1 && (fill[0].0 + fill[0].2 - (ground.0 + ground.2 / 2.0)).abs() < 1.0
  t.release(x, y)
  t.run_for(past_it_ms)
  assert_eq((half, t.drawn_rects().filter(fn(r) { r.4 == red }).length()), (true, 0), msg="\{Repr(fill)} ground \{Repr(ground)}")
}

///|
test "hold_button_node: 1.0x and 1.3x keep exact button_height; 2.0x scales height with zero fixed_outgrown or squeeze_faults" {
  let t = @ui.Tester::new(fn(_c) {  }, w=600.0, h=200.0, platform=0)
  t.check_looks(false)
  @ui.set_view_app(
    fn(root) {
      root.row(Is(true)).lines_up(Is(Some(Start))).padding(Is((20.0, 20.0, 20.0, 20.0))) |> ignore
      hold_button_node(root, fn() { "Hold to delete" }, fn() {  }) |> ignore
    },
    theme=ui_theme_now,
  )
  let h0 = button_height()
  t.draw()
  assert_eq(t.get(Button, label="Hold to delete").rect.3, h0, msg="1.0x height")
  assert_eq(t.fixed_outgrown(), [], msg="1.0x fixed_outgrown")
  assert_eq(t.squeeze_faults(), [], msg="1.0x squeeze_faults")
  t.set_font_scale(1.3)
  t.draw()
  assert_eq(t.get(Button, label="Hold to delete").rect.3, h0, msg="1.3x height")
  assert_eq(t.fixed_outgrown(), [], msg="1.3x fixed_outgrown")
  assert_eq(t.squeeze_faults(), [], msg="1.3x squeeze_faults")
  t.set_font_scale(2.0)
  t.draw()
  let h2 = t.get(Button, label="Hold to delete").rect.3
  assert_true(h2 > h0, msg="2.0x height grew: \{h2}")
  assert_eq(t.fixed_outgrown(), [], msg="2.0x fixed_outgrown")
  assert_eq(t.squeeze_faults(), [], msg="2.0x squeeze_faults")
}
