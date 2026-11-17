// One panel of nodes of the window's tree (panel_nodes) opened over another: only the topmost takes a press outside it,
// a press on it and Escape; the one under it sees none of them.

///|
/// A panel "下面" opened by nothing from 打开, its button 再开 opening over it a panel "上面" by nothing, whose foot's
/// button 上面的按钮 counts its presses in `pressed`: both in, at
/// the window of `at`.
fn one_over_another(at : (Int, Double, Double), pressed : Ref[Int]) -> @ui.Tester {
  let upper = fn() {
    panel_nodes(
      "上面",
      fn(v, _) { words_node(v, fn() { "上面的字" }, fn() { desk_muted }) |> ignore },
      foot=fn(v, _) { button_node(v, fn() { "上面的按钮" }, fn() { pressed.val = pressed.val + 1 }) |> ignore },
      from=Unanchored,
    )
  }
  let t = presenting_tester(at, fn(_) {
    panel_nodes(
      "下面",
      fn(v, _) {
        words_node(v, fn() { "下面的字" }, fn() { desk_muted }) |> ignore
        button_node(v, fn() { "再开" }, upper) |> ignore
      },
      from=Unanchored,
    )
  })
  open_it(t)
  t.run_for(@ui.move_most_ms)
  t.tap_text("再开")
  t.draw()
  come_to_rest(t)
  t
}

///|
/// The moment what was presented or let go last has come in or gone: a sheet's rest, then the longest move.
fn come_to_rest(t : @ui.Tester) -> Unit {
  let rest = presented_rest() - t.time()
  if rest > 0.0 {
    t.run_for(rest)
  }
  t.run_for(@ui.move_most_ms)
}

///|
/// Which of the two are shown: 下面's words, 上面's.
fn which_shown(t : @ui.Tester) -> (Bool, Bool) {
  (t.find("下面的字") is Some(_), t.find("上面的字") is Some(_))
}

///|
/// How one is over another: a panel of nodes over another, and what it is called.
let over_ways : Array[String] = ["nodes over nodes"]

///|
/// Where a press is outside both, at the window of `at`: over the top of the window, where no sheet nor dialog is.
fn outside_both(at : (Int, Double, Double)) -> (Double, Double) {
  let (_, w, _) = at
  (w / 2.0, 60.0)
}

///|
test "one panel over another, at Small with a finger and Large with a mouse: a press outside both closes the one over it alone" {
  for at in [phone, desk] {
    for way in over_ways {
      let name = way
      let pressed = Ref(0)
      let t = one_over_another(at, pressed)
      let both = which_shown(t)
      let (x, y) = outside_both(at)
      t.tap(x, y)
      come_to_rest(t)
      assert_eq((both, which_shown(t), pressed.val), ((true, true), (true, false), 0), msg="\{name} at \{Repr(at)}")
    }
  }
}

///|
test "one panel over another, at Small with a finger and Large with a mouse: its foot's button pressed, its alone, once; both stay" {
  for at in [phone, desk] {
    for way in over_ways {
      let name = way
      let pressed = Ref(0)
      let t = one_over_another(at, pressed)
      let foot = where_is(t, "上面的按钮")
      t.tap_text("上面的按钮")
      come_to_rest(t)
      assert_eq((which_shown(t), pressed.val), ((true, true), 1), msg="\{name} at \{Repr(at)}, the button at \{Repr(foot)}")
    }
  }
}

///|
test "one panel over another, at Small with a finger and Large with a mouse: Escape closes the one over it alone" {
  for at in [phone, desk] {
    for way in over_ways {
      let name = way
      let pressed = Ref(0)
      let t = one_over_another(at, pressed)
      t.key_named("esc") |> ignore
      come_to_rest(t)
      assert_eq((which_shown(t), pressed.val), ((true, false), 0), msg="\{name} at \{Repr(at)}")
    }
  }
}

///|
test "one panel over another, at Small with a finger: the system's back closes the one over it alone" {
  for way in over_ways {
    let name = way
    let pressed = Ref(0)
    let t = one_over_another(phone, pressed)
    t.back()
    come_to_rest(t)
    assert_eq((which_shown(t), pressed.val), ((true, false), 0), msg=name)
  }
}
