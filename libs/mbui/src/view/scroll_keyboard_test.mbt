// A plain column that scrolls (View::scrolls, a sheet's form), reaching the window's foot, the focus on a field low in
// it: the soft keyboard over the window's foot (Tree::drawn_by's `keyboard_inset`) covers the column's foot, and what
// the focus is on is brought, and kept, over the keyboard's top: the keyboard up as the focus comes, or coming up after
// it with nothing laid out reading it; never taken twice where what holds the column lays it out above the keyboard
// already; never pulled back where the hand scrolled the column after the focus came.

///|
/// The window, the keyboard's height, how tall each of the column's rows is and the row that is a field (720..780 in
/// the column, in sight with the keyboard down).
let sk_w : Double = 390.0

///|
let sk_h : Double = 844.0

///|
let sk_kb : Double = 300.0

///|
let sk_row : Double = 60.0

///|
let sk_field_row : Int = 12

///|
priv struct SkCase {
  tree : @view.Tree
  scroll : @view.Scroll
  kb : @signals.Signal[Double]
  field : Ref[@view.View?]
}

///|
/// A column as wide as the window that scrolls 30 rows 60 tall, row sk_field_row a field taking the focus; the keyboard
/// `kb` high at first; as tall as the window, or (`above`) as tall as the room over the keyboard, laid out so by what
/// holds it. Drawn once.
fn sk_case(kb? : Double = 0.0, above? : Bool = false) -> SkCase {
  let scroll = @view.Scroll::new()
  let kb = @signals.signal(kb, same=fn(a, b) { a == b })
  let field : Ref[@view.View?] = Ref(None)
  let tree = @view.Tree::new(fn(root) {
    root.tree.drawn_by(keyboard_inset=fn() { kb.get() })
    root.box(fn(o) {
      o
      .width(Is(Some(sk_w)))
      .height(By(fn() { Some(if above { sk_h - kb.get() } else { sk_h }) }))
      .scrolls(scroll, fn(held) {
        for i in 0..<30 {
          held.box(fn(r) {
            r.width(Is(Some(sk_w))).height(Is(Some(sk_row))) |> ignore
            if i == sk_field_row {
              field.val = Some(r)
              r.focusable(Is(true)) |> ignore
            }
          })
          |> ignore
        }
      })
      |> ignore
    })
    |> ignore
  })
  tree.frame(sk_w, sk_h) |> ignore
  { tree, scroll, kb, field }
}

///|
/// The field given the focus by the app, laid out after.
fn sk_focus(c : SkCase) -> Unit raise {
  guard c.field.val is Some(f) else { @halt.saying("no field") }
  assert_true(c.tree.focus_to(Some(f.id())), msg="the field took no focus")
  c.tree.frame(sk_w, sk_h) |> ignore
}

///|
/// Where the field's foot is drawn in the window.
fn sk_field_foot(c : SkCase) -> Double {
  guard c.field.val is Some(f) else { @halt.saying("no field") }
  let (_, y, _, h) = f.rect()
  y + h
}

///|
test "a column reaching the window's foot, the keyboard up, a field under it given the focus: brought over the keyboard's top" {
  let c = sk_case(kb=sk_kb)
  sk_focus(c)
  let foot = sk_field_foot(c)
  assert_true((foot - (sk_h - sk_kb)).abs() < 0.5, msg="the field's foot at \{foot}, the keyboard's top at \{sk_h - sk_kb}")
}

///|
test "a column reaching the window's foot, a field low in it given the focus, then the keyboard up with nothing laid out reading it: the field brought over the keyboard's top" {
  let c = sk_case()
  sk_focus(c)
  let before = sk_field_foot(c)
  assert_true((before - 780.0).abs() < 0.5, msg="in sight with the keyboard down: not moved, its foot at \{before}")
  c.kb.set(sk_kb)
  c.tree.frame(sk_w, sk_h) |> ignore
  let foot = sk_field_foot(c)
  assert_true((foot - (sk_h - sk_kb)).abs() < 0.5, msg="the field's foot at \{foot}, the keyboard's top at \{sk_h - sk_kb}")
  // (the keyboard down again: what shows stays where it was brought, nothing pulled)
  let at = c.scroll.at(c.tree)
  c.kb.set(0.0)
  c.tree.frame(sk_w, sk_h) |> ignore
  assert_true((c.scroll.at(c.tree) - at).abs() < 0.5, msg="scrolled to \{c.scroll.at(c.tree)} as the keyboard went, \{at} before")
}

///|
test "a column laid out above the keyboard by what holds it, a field low in it given the focus, then the keyboard up: brought to the column's foot, its room not taken twice" {
  let c = sk_case(above=true)
  sk_focus(c)
  c.kb.set(sk_kb)
  c.tree.frame(sk_w, sk_h) |> ignore
  let foot = sk_field_foot(c)
  assert_true((foot - (sk_h - sk_kb)).abs() < 0.5, msg="the field's foot at \{foot}, the column's at \{sk_h - sk_kb}")
}

///|
test "a column reaching the window's foot, a field low in it given the focus, the hand scrolling the column, then the keyboard up: not pulled back to the field" {
  let c = sk_case()
  sk_focus(c)
  // (dragged up 40 by a finger that rests before it lifts: no fling)
  let id = match c.tree.claimer_of(c.tree.claimers_at(195.0, 400.0), 0.0, -20.0) {
    Some(id) => id
    None => @halt.saying("not taken over")
  }
  let t0 = 1000.0
  c.tree.drag_at(id, Down, 195.0, 400.0, t0) |> ignore
  for i in 1..=4 {
    c.tree.drag_at(id, Moved, 195.0, 400.0 - 10.0 * i.to_double() - 20.0, t0 + 16.0 * i.to_double()) |> ignore
  }
  c.tree.drag_at(id, Moved, 195.0, 340.0, t0 + 400.0) |> ignore
  c.tree.drag_at(id, Up, 195.0, 340.0, t0 + 600.0) |> ignore
  c.tree.advance(t0 + 5000.0)
  c.tree.frame(sk_w, sk_h) |> ignore
  let by_hand = c.scroll.at(c.tree)
  assert_true(by_hand > 0.5, msg="the hand scrolled it nowhere")
  c.kb.set(sk_kb)
  c.tree.frame(sk_w, sk_h) |> ignore
  let then = c.scroll.at(c.tree)
  assert_true((then - by_hand).abs() < 0.5, msg="scrolled \{by_hand} by hand, then \{then} as the keyboard came up")
}
