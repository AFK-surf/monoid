// What the card to share is drawn with, as nodes of the window's tree: each look (the night's, share_looks', 千恋＊万花's
// share_senren_*) is a drawing of the `fleet` view in boxes, words, pictures and shapes of its own styles, made once as
// the card is (share_card_node), never built again each frame. A box (Pen) lays what it holds out as an old view's box
// of the same style did, the same flex beneath (@sf.style_node, what it gives way and grows by in a row, where it is
// put over what holds it, its shadow and how opaque it is): the looks keep their styles, now as a node's.

///|
/// A box of the card being made, a node of the window's tree (`v`), and whether it lays what it holds in a row (`row`:
/// how what it holds is laid out by their styles, @sf.style_node's `in_row`).
priv struct Pen {
  v : @view.View
  row : Bool
}

///|
/// The card made in node `v`, a column.
fn Pen::of(v : @view.View) -> Pen {
  { v, row: false }
}

///|
/// A box in it of `style` (laid out as an old view's box of it was: its size, its room, its ground and edge, its corner
/// and what it cuts, its shadow and how opaque it is), what it holds made by `inner` given it; put over it so far in from
/// the edges said (`left`, `top`, `right`, `bottom`: out of its column or row, View::over's `edges`), drawn `tx`, `ty`
/// off where it is laid out; `flow`: a row that goes on to another line where what it holds has not the room, `line_gap`
/// between its lines. The box.
fn Pen::box(
  self : Pen,
  style? : @ui.Style,
  left? : Double,
  top? : Double,
  right? : Double,
  bottom? : Double,
  tx? : Double = 0.0,
  ty? : Double = 0.0,
  flow? : Bool = false,
  line_gap? : Double = 0.0,
  inner : (Pen) -> Unit,
) -> Pen {
  let made : Ref[Pen?] = Ref(None)
  let base = match style {
    Some(s) => Some(s.base)
    None => None
  }
  let row = match base {
    Some(b) => b.row.unwrap_or(false)
    None => false
  }
  self.v.box(fn(b) {
    match style {
      // (a share of what holds it as its width: said as a share, the rest of the style as it says, style_node's)
      Some({ base: { w: Some(Pct(p)), .. } as q, .. } as s) => {
        let rest = { ..s, base: { ..q, w: None } }
        @sf.style_node(b, fn() { rest }, in_row=self.row)
        b.width_share(Is(p / 100.0)) |> ignore
      }
      Some(s) => @sf.style_node(b, fn() { s }, in_row=self.row)
      None => ()
    }
    pen_gives(b, self.row, base)
    match base {
      Some({ shadow: Some(sh), .. }) => {
        let (blur, dy) = sh.blur_y()
        let ink = match sh {
          Cast(_, _, k) => k
          _ => @ui.tree_theme().shadow
        }
        b.shadow(Is((blur, dy, ink))) |> ignore
      }
      _ => ()
    }
    match base {
      Some({ opacity: Some(o), .. }) => b.alpha(Is(o.value())) |> ignore
      _ => ()
    }
    if left is Some(_) || top is Some(_) || right is Some(_) || bottom is Some(_) {
      b.over(Is(true), edges=(left, top, right, bottom)) |> ignore
    }
    if tx != 0.0 || ty != 0.0 {
      b.offset(Is((tx, ty))) |> ignore
    }
    if flow {
      b.wraps(Is(Some(line_gap))) |> ignore
    }
    let p = { v: b, row }
    inner(p)
    made.val = Some(p)
  })
  |> ignore
  made.val.unwrap()
}

///|
/// How node `b` of a box (its style's `base`) gives way and grows in what holds it (a row: `in_row`), as an old view's
/// box did: along a row, all but one as wide as it says gives way where the row has not the room (its share of it, or
/// as wide as what it holds); down a column, one grown down it.
fn pen_gives(b : @view.View, in_row : Bool, base : @ui.Patch?) -> Unit {
  let (w, h, min_w) = match base {
    Some(p) => (p.w, p.h, p.min_w)
    None => (None, None, None)
  }
  let gives = if in_row {
    match w {
      Some(Fixed(px)) =>
        match min_w {
          Some(m) => match m.points() {
            Some(least) => least > 0.0 && least < px
            None => false
          }
          None => false
        }
      _ => true
    }
  } else {
    h is Some(Full | Grow(_))
  }
  if gives {
    b.shrink(Is(1.0)) |> ignore
  }
}

///|
/// Over it all, filling it (an old view's layer: a ground drawn over what it holds, what is laid over a picture), a
/// column; what it holds made by `inner`.
fn Pen::layer(self : Pen, inner : (Pen) -> Unit) -> Pen {
  let made : Ref[Pen?] = Ref(None)
  self.v.box(fn(b) {
    b.over(Is(true)) |> ignore
    let p = { v: b, row: false }
    inner(p)
    made.val = Some(p)
  })
  |> ignore
  made.val.unwrap()
}

///|
/// What is left of it along its row or column, and all of it across.
fn Pen::spacer(self : Pen) -> Unit {
  self.v.box(fn(b) { b.grow(Is(1.0)).basis(Is(Some(0.0))).shrink(Is(1.0)).fills_across(Is(true)) |> ignore }) |> ignore
}

///|
/// Words in runs (`@ui.span`s: a figure in another colour, larger, bolder), of `style`, in face `face` (0: the app's):
/// as wide as they say (`w`: filling their line, cut short on it, so many points), wrapping or on one line as they say.
fn Pen::rich(self : Pen, runs : Array[@ui.Run], style~ : @ui.TextStyle, face? : Int = 0) -> Unit {
  let runs = if face == 0 {
    runs
  } else {
    runs.map(fn(r) { if r.face is None { { ..r, face: Some(face) } } else { r } })
  }
  let look = @ui.style_words(style)
  let said = style.base
  let in_row = self.row
  self.v.box(fn(w) {
    w.words_runs(Is(runs)).words_look(Is(look)).ink(Is(@ui.style_ink(style))) |> ignore
    match said.w {
      Some(Full) | Some(Grow(_)) => {
        let k = match said.w {
          Some(Grow(k)) => k
          _ => 1.0
        }
        if in_row {
          w.grow(Is(k)).basis(Is(Some(0.0))).shrink(Is(1.0)) |> ignore
        } else {
          w.fills_across(Is(true)) |> ignore
        }
        if !look.wrap {
          w.allow_ellipsis(Is(true)) |> ignore
        }
      }
      Some(Cut) => w.cuts(Is(true)).min_width(Is(Some(0.0))).allow_ellipsis(Is(true)) |> ignore
      Some(Fixed(px)) => w.width(Is(Some(px))) |> ignore
      _ => if in_row && look.wrap { w.shrink(Is(1.0)) |> ignore }
    }
  })
  |> ignore
}

///|
/// Words of `style`, in face `face` (0: the app's): Pen::rich's of one run.
fn Pen::text(self : Pen, words : String, style~ : @ui.TextStyle, face? : Int = 0) -> Unit {
  self.rich([@ui.span(words)], style~, face~)
}

///|
/// Picture `key` (a picture the app has by it: `mem:`, nothing till it is given) `w` by `h` points: all of it filled
/// in, or (`at`) covering it, cut to it at that far down (0 its top, 1 its foot); nothing under it while it is on its
/// way, there whole once it is (a picture handed out is drawn whole).
fn Pen::image(self : Pen, key : String, w : Double, h : Double, at? : Double) -> Unit {
  self.v.box(fn(i) {
    i
    .width(Is(Some(w)))
    .height(Is(Some(h)))
    .image(Is(Some((key, "", pen_image_most))))
    .image_fades(Is(false))
    |> ignore
    match at {
      Some(a) => i.image_covers_at(Is(Some((0.5, a)))) |> ignore
      None => ()
    }
  })
  |> ignore
}

///|
/// The most pixels a look's picture is asked at: its whole width handed out (@sf.share_w_most at share_scale), and a
/// little more.
let pen_image_most : Int = 2048

///|
/// Shapes `w` by `h` points (@paint's outlines, filled and stroked), in their own terms from its top left.
fn Pen::shapes(self : Pen, shapes : Array[@ui.Shape], w : Double, h : Double) -> Unit {
  self.v.box(fn(s) { s.width(Is(Some(w))).height(Is(Some(h))).shapes(Is(shapes)) |> ignore }) |> ignore
}

///|
/// It read out as `role` named `label` (a look's card: a picture, named by its look and its figures).
fn Pen::says(self : Pen, role : @view.Role, label : String) -> Unit {
  self.v.says(Is(Some(@view.said(role, label~)))) |> ignore
}
