// A page's compact bar, the one every pushed page of the phone has (Android Parts.kt NavBar, web mobile/parts.css.ts
// mNavbar): back with where it goes, in the accent, at its start; a centred title (and a line under it, `sub`); what
// it does at its end. The back word, the title's first line and what is at the end share one 32 line at the bar's top,
// each in its middle; a title's second line hangs below it, the bar taller by it. (NavBar sets the title's line 30, 1
// higher, to stand on the back word's baseline, with 2 under it: on the Mac's text its letters then stood 1 over the
// back word's. Here the title's line is the 32 and nothing under it: the line under the title and the bar's height
// are NavBar's.) The title is in the middle of the bar inside its padding (16 at either end) and keeps 84 clear
// at either side.

///|
/// Back's word in a link's ink, its chevron the accent (490 C.accent).
// kept across runs: a value (no field of it changes)
let nav_back_words : @ui.TextStyle = @ui.text_style(size=Title, leading=Font, color=Link, wrap=false)

///|
// kept across runs: a value (no field of it changes)
let nav_title_words : @ui.TextStyle = @ui.text_style(size=Title, leading=Font, weight=Semibold, color=Fg, wrap=false)

///|
// kept across runs: a value (no field of it changes)
let nav_sub_words : @ui.TextStyle = @ui.text_style(size=Caption, leading=L4, color=Muted, wrap=false, w=Cut)

///|
/// The bar (nav_bar's) as nodes in `parent`: back to where `back` says (nav_back_node; none where it says nothing),
/// `title` in the middle (and `sub` under it where said), 84 clear of either side, cut short where it has less; what
/// `trailing` makes at its end, on back's 32 line; on the page's ground, from `top` above it down (the status bar's
/// height as it is). `back_most`: how wide back's word may be (nav_back's `max_w`), there whole or not at all.
#callsite(autofill(loc))
pub fn nav_bar_node(
  parent : @view.View,
  back : () -> String,
  title : () -> String,
  on_back : () -> Unit,
  sub? : () -> String = fn() { "" },
  top? : () -> Double = fn() { 0.0 },
  trailing? : (@view.View) -> Unit,
  trailing_shown? : () -> Bool,
  trailing_pill? : Bool = true,
  trailing_pad? : Double = 3.0,
  back_most? : () -> Double,
  loc~ : SourceLoc,
) -> Unit {
  parent.box(made_for=loc, fn(b) {
    b
    .padding(Is((nav_bar_x, nav_bar_top, nav_bar_x, nav_bar_foot)))
    .ground(By(fn() { theme().p.bg }))
    |> ignore
    // under the status bar
    b.box(fn(s) { s.height(By(fn() { Some(top()) })) |> ignore }) |> ignore
    b.box(fn(i) {
      i.lines_up(Is(Some(Middle))) |> ignore
      // the title, in the flow: as tall as its line makes the bar
      i.box(fn(col) {
        col
        .padding(Is((nav_title_x, 0.0, nav_title_x, 0.0)))
        .lines_up(Is(Some(Middle)))
        .shrink(Is(1.0))
        .min_width(Is(Some(0.0)))
        .max_width(Is(Some(1.0e9)), within=true)
        |> ignore
        col.box(fn(l) {
          // (no wider than the room between its sides: a long name is cut there, not centred past back and the end)
          l
          .height(Is(Some(nav_line_h)))
          .lies_along(Is(Middle))
          .clips(Is(true))
          .min_width(Is(Some(0.0)))
          .max_width(Is(Some(1.0e9)), within=true)
          |> ignore
          l.box(fn(w) {
            styled_words(w, title, fn() { nav_title_words }).cuts(Is(true)).min_width(Is(Some(0.0))) |> ignore
          })
          |> ignore
        })
        |> ignore
        col.show(fn() { sub() != "" }, fn(s) {
          s.offset(Is((0.0, -4.0))).clips(Is(true)).min_width(Is(Some(0.0))) |> ignore
          styled_words(s, sub, fn() { nav_sub_words }).cuts(Is(true)).min_width(Is(Some(0.0))) |> ignore
        })
      })
      |> ignore
      // back and what is at the end, on the 40pt capsule line at its top
      i.box(fn(e) {
        e.over(Is(true)).row(Is(true)).height(Is(Some(nav_line_h))).lines_up(Is(Some(Middle))) |> ignore
        // (back only where there is somewhere to go: a page with nowhere back, a pane's beside a list, has none, as
        // page_node's Back; a chevron saying nothing would be a press with no name and no way)
        e.show(fn() { back() != "" }, at_once=true, fn(k) { nav_back_pill_node(k, back, on_back, most?=back_most) })
        e.box(fn(gap) { gap.grow(Is(1.0)) |> ignore }) |> ignore
        match trailing {
          Some(f) => {
            let draw = fn(t : @view.View) {
              if trailing_pill {
                bar_pill_group_node(t, f, height=nav_line_h, pad=trailing_pad, gap=2.0) |> ignore
              } else {
                t.row(Is(true)).height(Is(Some(nav_line_h))).lines_up(Is(Some(Middle))) |> ignore
                f(t)
              }
            }
            match trailing_shown {
              Some(shown) => e.show(at_once=true, shown, draw)
              None => draw(e)
            }
          }
          None => ()
        }
      })
      |> ignore
    })
    |> ignore
  })
  |> ignore
}

///|
/// nav_bar_box's room (16 at either end, 2 over, 6 under; 48pt total matching the legacy 6+32+10 bar), the title's
/// clear of either side (nav_title_clear) and the line back, the title and what is at the end share (40pt matching
/// liquid glass back/trailing capsules).
let nav_bar_x : Double = 16.0

///|
let nav_bar_top : Double = 2.0

///|
let nav_bar_foot : Double = 6.0

///|
let nav_title_x : Double = 84.0

///|
let nav_line_h : Double = 40.0
