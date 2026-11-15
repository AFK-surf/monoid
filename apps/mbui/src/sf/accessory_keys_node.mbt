// A row of keys over the soft keyboard (a terminal's; the mockup the user agreed, 2026-11-14): keys a phone's keyboard
// has not, each a cap 44 by 44 at least (what always shows is pressed in 44 × 44), on a band of the sidebar's ground.
// A key held (ctrl, alt) is a toggle, shown solid (the primary's) while it is; the rest are buttons. Where the window
// has not the room for all of them, the row scrolls across under a finger (the user, 2026-11-15: 「左右滑不动啥意思」;
// a list of them in a sheet was 「狗屎」), as a row of a table that is wider than its page does.

///|
/// A key of the row: what its cap says (or `icon` when non-empty), what a screen reader calls it, whether it is held
/// (a modifier's: None for a key that is only pressed), what pressing it does (or `press_from` when it opens a panel
/// beside itself).
pub(all) struct AccessoryKey {
  cap : String
  name : String
  held : (() -> Bool)?
  press : () -> Unit
  icon : String
  press_from : ((@view.View) -> Unit)?
}

///|
/// The row of `keys` in `parent`, at the foot of what holds it, with `trailing` keys pinned at its right end (按键,
/// 收起键盘) so they are always in reach without scrolling.
#callsite(autofill(loc))
pub fn accessory_keys_node(
  parent : @view.View,
  keys : Array[AccessoryKey],
  trailing? : Array[AccessoryKey] = [],
  loc~ : SourceLoc,
) -> Unit {
  parent.box(made_for=loc, fn(r) {
    r.row(Is(true)).lines_up(Is(Some(Middle))) |> ignore
    r.box(fn(s) {
      s.grow(Is(1.0)).shrink(Is(1.0)).min_width(Is(Some(0.0))) |> ignore
      s.scrolls(@view.Scroll::across(), slop=@ui.touch_slop(), fn(b) {
        b
        .row(Is(true))
        .gap(Is(accessory_gap))
        .padding(Is((accessory_side_in, accessory_gap, accessory_gap, accessory_gap)))
        |> ignore
        for k in keys {
          accessory_key_node(b, k)
        }
      })
      |> ignore
    })
    |> ignore
    if !trailing.is_empty() {
      r.box(fn(e) {
        e
        .row(Is(true))
        .lines_up(Is(Some(Middle)))
        .gap(Is(accessory_gap))
        .padding(Is((accessory_gap, accessory_gap, accessory_side_in, accessory_gap)))
        |> ignore
        for k in trailing {
          accessory_key_node(e, k)
        }
      })
      |> ignore
    }
  })
  |> ignore
}

///|
#callsite(autofill(loc))
fn accessory_key_node(parent : @view.View, k : AccessoryKey, loc~ : SourceLoc) -> Unit {
  let held = k.held.unwrap_or(fn() { false })
  let look = fn(b : @view.View) {
    b
    .min_width(Is(Some(accessory_key_w)))
    .padding(Is((if k.icon != "" { 0.0 } else { accessory_cap_in }, 0.0, if k.icon != "" { 0.0 } else { accessory_cap_in }, 0.0)))
    .height(Is(Some(accessory_key_h)))
    .radius(Is(accessory_corner))
    .lines_up(Is(Some(Middle)))
    .lies_along(Is(Middle))
    .ground(By(fn() {
      let p = theme().p
      let base = if held() { p.primary } else { p.raised }
      if lit_node(b) { over(base, p.hover) } else { base }
    }))
    |> ignore
    if k.icon != "" {
      icon_node(b, k.icon, 18.0, By(fn() { if held() { theme().p.on_primary } else { theme().p.text } })) |> ignore
    } else {
      b.box(fn(w) {
        w
        .words(Is(k.cap))
        .words_look(Is(@ui.style_words(accessory_words)))
        .ink(By(fn() { if held() { theme().p.on_primary } else { theme().p.text } }))
        |> ignore
      })
      |> ignore
    }
  }
  let btn : Ref[@view.View?] = Ref(None)
  let act = fn(b : @view.View) {
    match k.press_from {
      Some(f) => f(b)
      None => (k.press)()
    }
  }
  match k.held {
    Some(on) =>
      @headless.toggle(
        made_for=loc,
        parent,
        Button,
        fn() { k.name },
        on,
        fn(_) {
          match (k.press_from, btn.val) {
            (Some(f), Some(b)) => f(b)
            _ => (k.press)()
          }
        },
        fn(b, _) {
          btn.val = Some(b)
          look(b)
        },
      )
      |> ignore
    None => @headless.button(made_for=loc, parent, fn() { k.name }, act, fn(b, _) { look(b) }) |> ignore
  }
}

///|
/// The row's caps: 44 by 44 at least (what always shows is pressed in 44 × 44), 4 apart and 8 in from the band's ends.
let accessory_key_w : Double = 44.0

///|
let accessory_key_h : Double = 44.0

///|
/// How far in from a cap's sides its words are (a wide one's, esc's).
let accessory_cap_in : Double = 10.0

///|
let accessory_gap : Double = 4.0

///|
let accessory_side_in : Double = 8.0

///|
/// How tall the row is: a cap and the band round it.
pub let accessory_keys_h : Double = accessory_key_h + 2.0 * accessory_gap

///|
let accessory_corner : Double = 8.0

///|
// kept across runs: a value (no field of it changes)
let accessory_words : @ui.TextStyle = @ui.text_style(size=Meta, wrap=false)
