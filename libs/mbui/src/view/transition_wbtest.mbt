// What moves only for a cause said (View::transitions_only, transition.mbt): what a show, a pick, an each said to pop
// out of the flow, and a height declared do there makes its way only inside `transition`; outside one, at once, nothing
// left on a way, no mark of it left set. Elsewhere as ever. At 7, 24, 60 and 120 frames a second.

///|
/// How a change of what a part holds is told: outside a transition, inside one (said within all, the part, or another
/// node), or inside one told in an outer batch (held till that is told whole).
priv enum Told {
  Plain
  Inside
  Within
  WithinOther
  InBatch
}

///|
/// `f` told as `how` says, the part `p` and another node `o`.
fn told(how : Told, p : View, o : View, f : () -> Unit) -> Unit {
  match how {
    Plain => f()
    Inside => transition(f)
    Within => transition(within=p, f)
    WithinOther => transition(within=o, f)
    InBatch => {
      @signals.start_batch()
      transition(f)
      @signals.end_batch()
    }
  }
}

///|
/// A part said `only` (or not) holding a show 30 tall over a line, its flag set at 60 as `how` says: whether what the
/// show made makes its way in.
fn show_way(period : Double, only : Bool, how : Told) -> Bool {
  let clock = Ref(0.0)
  let flag = @signals.signal(false)
  let made : Ref[View?] = Ref(None)
  let part : Ref[View?] = Ref(None)
  let other : Ref[View?] = Ref(None)
  let tree = Tree::new(time=fn() { clock.val }, fn(root) {
    root.box(fn(col) {
      col.box(fn(p) {
        part.val = Some(p)
        if only {
          p.transitions_only() |> ignore
        }
        p.show(fn() { flag.get() }, fn(s) {
          made.val = Some(s)
          s.box(fn(b) { b.height(Is(Some(30.0))) |> ignore }) |> ignore
        })
        p.box(fn(line) { line.height(Is(Some(40.0))) |> ignore }) |> ignore
      })
      |> ignore
      col.box(fn(o) {
        other.val = Some(o)
        o.height(Is(Some(10.0))) |> ignore
      })
      |> ignore
    })
    |> ignore
  })
  tree.frame(390.0, 844.0, now=0.0) |> ignore
  while clock.val + period <= 60.0 {
    clock.val += period
    tree.frame(390.0, 844.0, now=clock.val) |> ignore
  }
  clock.val = 60.0
  told(how, part.val.unwrap(), other.val.unwrap(), fn() { flag.set(true) })
  clock.val += period
  tree.frame(390.0, 844.0, now=clock.val) |> ignore
  let way = match made.val {
    Some(v) => v.comes_end() >= 0.0
    None => false
  }
  tree.dispose()
  way
}

///|
test "transition: a show where only a cause moves it makes its way only inside one" {
  for period in [1000.0 / 7.0, 1000.0 / 24.0, 1000.0 / 60.0, 1000.0 / 120.0] {
    assert_true(show_way(period, false, Plain), msg="at \{period}: not said so, it made no way")
    assert_true(!show_way(period, true, Plain), msg="at \{period}: outside a transition, it made its way")
    assert_true(show_way(period, true, Inside), msg="at \{period}: inside one, it made no way")
    assert_true(show_way(period, true, Within), msg="at \{period}: inside one within it, it made no way")
    assert_true(!show_way(period, true, WithinOther), msg="at \{period}: inside one within another, it made its way")
    assert_true(show_way(period, true, InBatch), msg="at \{period}: inside one told in a batch, it made no way")
    assert_true(!answer_marks_left(), msg="at \{period}: marks left set")
    assert_true(!transition_now(), msg="at \{period}: a transition left told")
  }
}

///|
/// Three tiles 20 wide in a row of a part said to move only for a cause, each said to pop out of the flow; the first
/// taken out at 60 as `how` says: whether it is still there, leaving, and how far across the second is laid out then.
fn pop_way(period : Double, how : Told) -> (Bool, Double) {
  let clock = Ref(0.0)
  let items = @signals.signal(["a", "b", "c"])
  let rows : Map[String, View] = Map([])
  let part : Ref[View?] = Ref(None)
  let tree = Tree::new(time=fn() { clock.val }, fn(root) {
    root.box(fn(p) {
      part.val = Some(p)
      p.transitions_only().row(Is(true)) |> ignore
      p.each(fn() { items.get() }, fn(k) { k }, leave=200.0, pop_leave=true, fn(r, k) {
        rows[k.untracked()] = r
        r.width(Is(Some(20.0))).height(Is(Some(20.0))) |> ignore
      })
    })
    |> ignore
  })
  tree.frame(390.0, 844.0, now=0.0) |> ignore
  while clock.val + period <= 60.0 {
    clock.val += period
    tree.frame(390.0, 844.0, now=clock.val) |> ignore
  }
  clock.val = 60.0
  let p = part.val.unwrap()
  told(how, p, p, fn() { items.set(["b", "c"]) })
  clock.val += period
  tree.frame(390.0, 844.0, now=clock.val) |> ignore
  let first = rows["a"]
  let leaving = first.alive() && first.leaving()
  let (bx, _, _, _) = rows["b"].laid_window_now()
  tree.dispose()
  (leaving, bx)
}

///|
test "transition: what an each pops out of the flow fades where it stood, what stays laid out where it rests at once" {
  for period in [1000.0 / 7.0, 1000.0 / 24.0, 1000.0 / 60.0, 1000.0 / 120.0] {
    let (leaving, bx) = pop_way(period, Inside)
    assert_true(leaving, msg="at \{period}: inside a transition, the tile taken out did not stay leaving")
    assert_true(bx.abs() < 0.5, msg="at \{period}: the tile after it laid out at \{bx}, not where it rests")
    let (leaving, bx) = pop_way(period, Plain)
    assert_true(!leaving, msg="at \{period}: outside a transition, the tile taken out stayed leaving")
    assert_true(bx.abs() < 0.5, msg="at \{period}: outside a transition, the tile after it laid out at \{bx}")
    assert_true(!answer_marks_left(), msg="at \{period}: marks left set")
  }
}

///|
/// A pick of a part said to move only for a cause, leaving over 200 as what it shows changes at 60 as `how` says:
/// whether what it showed is still there, leaving.
fn pick_way(period : Double, how : Told) -> Bool {
  let clock = Ref(0.0)
  let which = @signals.signal(0)
  let made : Map[Int, View] = Map([])
  let part : Ref[View?] = Ref(None)
  let tree = Tree::new(time=fn() { clock.val }, fn(root) {
    root.box(fn(p) {
      part.val = Some(p)
      p.transitions_only() |> ignore
      p.pick(fn() { which.get() }, leave=200.0, fn(b, k) {
        made[k] = b
        b.box(fn(i) { i.height(Is(Some(20.0 + k.to_double() * 10.0))) |> ignore }) |> ignore
      })
    })
    |> ignore
  })
  tree.frame(390.0, 844.0, now=0.0) |> ignore
  while clock.val + period <= 60.0 {
    clock.val += period
    tree.frame(390.0, 844.0, now=clock.val) |> ignore
  }
  clock.val = 60.0
  let p = part.val.unwrap()
  told(how, p, p, fn() { which.set(1) })
  clock.val += period
  tree.frame(390.0, 844.0, now=clock.val) |> ignore
  let was = made[0]
  let leaving = was.alive() && was.leaving()
  tree.dispose()
  leaving
}

///|
test "transition: a pick that leaves over a time lets what it showed go at once outside one" {
  for period in [1000.0 / 7.0, 1000.0 / 24.0, 1000.0 / 60.0, 1000.0 / 120.0] {
    assert_true(pick_way(period, Inside), msg="at \{period}: inside a transition, what it showed did not fade out")
    assert_true(!pick_way(period, Plain), msg="at \{period}: outside a transition, what it showed stayed fading")
    assert_true(!answer_marks_left(), msg="at \{period}: marks left set")
  }
}

///|
/// A box 30 tall in a part said to move only for a cause, made 60 tall at 60 and said to resize as `how` says: whether
/// its height makes its way.
fn resize_way(period : Double, how : Told) -> Bool {
  let clock = Ref(0.0)
  let tall = @signals.signal(30.0)
  let made : Ref[View?] = Ref(None)
  let part : Ref[View?] = Ref(None)
  let tree = Tree::new(time=fn() { clock.val }, fn(root) {
    root.box(fn(col) {
      col.box(fn(p) {
        part.val = Some(p)
        p.transitions_only() |> ignore
        p.box(fn(b) {
          made.val = Some(b)
          b.height(By(fn() { Some(tall.get()) })) |> ignore
        })
        |> ignore
      })
      |> ignore
    })
    |> ignore
  })
  tree.frame(390.0, 844.0, now=0.0) |> ignore
  while clock.val + period <= 60.0 {
    clock.val += period
    tree.frame(390.0, 844.0, now=clock.val) |> ignore
  }
  clock.val = 60.0
  let p = part.val.unwrap()
  let b = made.val.unwrap()
  tree.event(60.0, fn() {
    told(how, p, p, fn() {
      tall.set(60.0)
      b.resizes() |> ignore
    })
  })
  clock.val += period
  tree.frame(390.0, 844.0, now=clock.val) |> ignore
  let way = b.comes_end() >= 0.0
  tree.dispose()
  way
}

///|
test "transition: a height declared where only a cause moves it goes its way only inside one" {
  for period in [1000.0 / 7.0, 1000.0 / 24.0, 1000.0 / 60.0, 1000.0 / 120.0] {
    assert_true(resize_way(period, Inside), msg="at \{period}: inside a transition, its height made no way")
    assert_true(!resize_way(period, Plain), msg="at \{period}: outside a transition, its height made its way")
    assert_true(!answer_marks_left(), msg="at \{period}: marks left set")
  }
}

///|
/// Two shows in a part said to move only for a cause, the first's flag set inside a transition and the second's
/// outside one after it, before the next frame: whether each makes its way in.
fn two_ways(period : Double) -> (Bool, Bool) {
  let clock = Ref(0.0)
  let a = @signals.signal(false)
  let b = @signals.signal(false)
  let made_a : Ref[View?] = Ref(None)
  let made_b : Ref[View?] = Ref(None)
  let tree = Tree::new(time=fn() { clock.val }, fn(root) {
    root.box(fn(col) {
      col.box(fn(p) {
        p.transitions_only() |> ignore
        p.show(fn() { a.get() }, fn(s) {
          made_a.val = Some(s)
          s.box(fn(x) { x.height(Is(Some(30.0))) |> ignore }) |> ignore
        })
        p.show(fn() { b.get() }, fn(s) {
          made_b.val = Some(s)
          s.box(fn(x) { x.height(Is(Some(30.0))) |> ignore }) |> ignore
        })
      })
      |> ignore
    })
    |> ignore
  })
  tree.frame(390.0, 844.0, now=0.0) |> ignore
  while clock.val + period <= 60.0 {
    clock.val += period
    tree.frame(390.0, 844.0, now=clock.val) |> ignore
  }
  clock.val = 60.0
  transition(fn() { a.set(true) })
  b.set(true)
  clock.val += period
  tree.frame(390.0, 844.0, now=clock.val) |> ignore
  let way = fn(v : Ref[View?]) {
    match v.val {
      Some(s) => s.comes_end() >= 0.0
      None => false
    }
  }
  let out = (way(made_a), way(made_b))
  tree.dispose()
  out
}

///|
test "transition: what changes outside one after it, before the next frame, is at once" {
  for period in [1000.0 / 7.0, 1000.0 / 24.0, 1000.0 / 60.0, 1000.0 / 120.0] {
    let (a, b) = two_ways(period)
    assert_true(a, msg="at \{period}: what the transition changed made no way")
    assert_true(!b, msg="at \{period}: what changed outside it after it made its way")
    assert_true(!answer_marks_left(), msg="at \{period}: marks left set")
  }
}
