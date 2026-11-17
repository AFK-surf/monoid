// What is pressed in a page's list stays where it was (press_stays.mbt) when what it opens or shuts is made anew round
// it: the button itself let go as the press flips the branch it was made in (a pick's), held by what held it; and,
// shut near the foot with room kept under it, held where it was after the press's ways end, keys come at the foot
// taking that room before the list follows its foot again.

///|
priv struct GoneCase {
  tree : @view.Tree
  now : Ref[Double]
  keys : @signals.Signal[Array[Int]]
  /// each row's button, by its row, the one made last
  buttons : Map[Int, @view.View]
}

///|
/// A window 300 by 400 all of it a page's list of 12 rows, each its button (40) and, open, 300 under it. Where
/// `anew`, a row's button and what it opens are made in a pick of whether it is open, the button made anew as it is
/// pressed; else the button stays and only what is under it comes and goes.
fn gone_case(anew : Bool) -> GoneCase {
  let now = Ref(0.0)
  let buttons : Map[Int, @view.View] = Map([])
  let opened : Map[Int, @signals.Signal[Bool]] = Map([])
  let open_of = fn(k : Int) {
    match opened.get(k) {
      Some(o) => o
      None => {
        let o = @signals.signal(false, same=fn(a, b) { a == b })
        opened[k] = o
        o
      }
    }
  }
  let button = fn(b : @view.View, k : Int) {
    b.box(fn(p) {
      buttons[k] = p
      p
      .height(Is(Some(40.0)))
      .shrink(Is(0.0))
      .on_press(fn() { open_of(k).set(!open_of(k).untracked()) })
      .says(By(fn() { Some(@view.said(Button, label="row \{k}", expanded=open_of(k).get())) }))
      |> ignore
    })
    |> ignore
  }
  let row = fn(b : @view.View, k : Int) {
    if anew {
      b.pick(fn() { open_of(k).get() }, fn(p, is_open) {
        button(p, k)
        if is_open {
          p.box(fn(u) { u.height(Is(Some(300.0))).shrink(Is(0.0)) |> ignore }) |> ignore
        }
      })
    } else {
      button(b, k)
      b.box(fn(u) {
        u.height(By(fn() { if open_of(k).get() { Some(300.0) } else { Some(0.0) } })).shrink(Is(0.0)) |> ignore
      })
      |> ignore
    }
  }
  let keys = @signals.signal(Array::makei(12, fn(i) { i }))
  let tree = @view.Tree::new(
    fn(root) {
      root.box(fn(win) {
        win.grow(Is(1.0)).min_height(Is(Some(0.0))) |> ignore
        win.scrolls_window(@view.Scroll::list(), fn() { keys.get() }, est=40.0, follows=fn() { true }, row) |> ignore
      })
      |> ignore
    },
    time=fn() { now.val },
  )
  tree.frame(300.0, 400.0, now=0.0) |> ignore
  { tree, now, keys, buttons }
}

///|
fn GoneCase::at(self : GoneCase, t : Double) -> Unit {
  self.now.val = t
  self.tree.frame(300.0, 400.0, now=t) |> ignore
}

///|
/// Row `k`'s button (the one made last) pressed at its middle at `t`, the frame drawn then.
fn GoneCase::press(self : GoneCase, k : Int, t : Double) -> Unit {
  let (x, y, w, h) = self.buttons[k].rect()
  self.now.val = t
  self.tree.press(x + w / 2.0, y + h / 2.0) |> ignore
  self.tree.frame(300.0, 400.0, now=t) |> ignore
}

///|
fn GoneCase::top_of(self : GoneCase, k : Int) -> Double {
  self.buttons[k].rect().1
}

///|
test "a page's list at its foot, a row's button made anew as it is pressed: it stays where it was, opened and shut, as the press's ways end" {
  for anew in [true, false] {
    let c = gone_case(anew)
    c.tree.wheel_at(150.0, 200.0, 0.0, 10000.0, 0, 50.0) |> ignore
    c.at(1000.0)
    let was = c.top_of(10)
    c.press(10, 2000.0)
    let opened = c.top_of(10)
    c.at(3000.0)
    let opened_end = c.top_of(10)
    c.press(10, 4000.0)
    let shut = c.top_of(10)
    c.at(5000.0)
    let shut_end = c.top_of(10)
    assert_eq((anew, opened, opened_end, shut, shut_end), (anew, was, was, was, was))
  }
}

///|
test "a page's list, a row near its foot opened, scrolled on and shut: held where it was after the press's ways end, keys come at its foot taking the room kept under it first, then followed again" {
  for anew in [true, false] {
    let c = gone_case(anew)
    c.tree.wheel_at(150.0, 200.0, 0.0, 10000.0, 0, 50.0) |> ignore
    c.at(1000.0)
    c.press(10, 2000.0)
    c.at(3000.0)
    // (scrolled on 100 into what it opened)
    c.tree.wheel_at(150.0, 200.0, 0.0, 100.0, 0, 3100.0) |> ignore
    c.at(4000.0)
    let was = c.top_of(10)
    c.press(10, 5000.0)
    let shut = c.top_of(10)
    // (the press's ways ended, held by it no more)
    c.at(6000.0)
    let let_go = c.top_of(10)
    // (a key come at its foot: it takes the room kept under the last, nothing over it moving)
    c.keys.set(Array::makei(13, fn(i) { i }))
    c.at(7000.0)
    let one_more = c.top_of(10)
    c.at(8000.0)
    let one_more_end = c.top_of(10)
    assert_eq((anew, shut, let_go, one_more, one_more_end), (anew, was, was, was, was))
    // (two more: past the room, its foot followed again, the last at the window's foot)
    c.keys.set(Array::makei(15, fn(i) { i }))
    c.at(9000.0)
    let (_, last_y, _, last_h) = c.buttons[14].rect()
    assert_eq((anew, last_y + last_h), (anew, 400.0))
  }
}

///|
test "a page's list, a row near its foot opened, scrolled on, shut and opened again: held where it was after the press's ways end, not jumping to the foot" {
  for anew in [true, false] {
    let c = gone_case(anew)
    c.tree.wheel_at(150.0, 200.0, 0.0, 10000.0, 0, 50.0) |> ignore
    c.at(1000.0)
    c.press(10, 2000.0)
    c.at(3000.0)
    c.tree.wheel_at(150.0, 200.0, 0.0, 100.0, 0, 3100.0) |> ignore
    c.at(4000.0)
    let was = c.top_of(10)
    c.press(10, 5000.0)
    c.at(6000.0)
    let shut_end = c.top_of(10)
    // (opened again: takes the room kept under it and extends past the window's foot, staying where it was after the press's ways end)
    c.press(10, 7000.0)
    let reopened = c.top_of(10)
    c.at(8000.0)
    let reopened_end = c.top_of(10)
    assert_eq((anew, shut_end, reopened, reopened_end), (anew, was, was, was))
  }
}
