// What the card to share is drawn with, as nodes of the window's tree: each look (the night's, share_looks', 千恋＊万花's
// share_senren_*) is a drawing of the `fleet` view in boxes, words, pictures and shapes of its own styles, made once as
// the look is chosen (share_poster_node) and never again for what the view says: what it says is bound to the nodes that
// show it (a box's style, words, shapes, what it is read out as: the `_by` of each), what comes and goes by it is a
// structure (Pen::show, Pen::each), and a change of a figure runs only the bindings that show it (each worked out of the
// view as a value of its own: by_value). A box (Pen) lays what it holds out as an old view's box of the same style did,
// the same flex beneath (@sf.style_node, what it gives way and grows by in a row, where it is put over what holds it, its
// shadow and how opaque it is): the looks keep their styles, now as a node's.

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
/// What `f` works out of the `fleet` view (and the words of the app's language), as a value of its own: worked out again
/// as what it reads changes, what reads it told only where it comes out otherwise, so a change of one figure runs only
/// what shows that figure.
fn[T : Eq] by_value(f : () -> T) -> () -> T {
  let c = @signals.computed(fn(_) { f() })
  fn() { c.get() }
}

///|
/// What `f` chooses of the look's own values (a style of a few, each a value of the look's: one object each), told only
/// where it chooses another.
fn[T] by_choice(f : () -> T) -> () -> T {
  // (a style of the look's has no equality of its own: the look's few are told apart by which object each is)
  let c = @signals.computed_ref(fn(_) { f() })
  fn() { c.get() }
}

///|
/// A box in it of `style` (laid out as an old view's box of it was: its size, its room, its ground and edge, its corner
/// and what it cuts, its shadow and how opaque it is), or of the style `style_by` works out of what the card says (its
/// layout as the style it first works out: what it changes of it is its look, its size, its room), what it holds made by
/// `inner` given it; put over it so far in from the edges said (`left`, `top`, `right`, `bottom`: out of its column or
/// row, View::over's `edges`), or as `edges_by` works them out of what the card says (View::over_at), drawn `tx`, `ty`
/// off where it is laid out; `flow`: a row that goes on to another line where what it holds has not the room,
/// `line_gap` between its lines. The box.
fn Pen::box(
  self : Pen,
  style? : @ui.Style,
  style_by? : () -> @ui.Style,
  left? : Double,
  top? : Double,
  right? : Double,
  bottom? : Double,
  edges_by? : () -> (Double?, Double?, Double?, Double?),
  tx? : Double = 0.0,
  ty? : Double = 0.0,
  flow? : Bool = false,
  line_gap? : Double = 0.0,
  inner : (Pen) -> Unit,
) -> Pen {
  let made : Ref[Pen?] = Ref(None)
  self.v.box(fn(b) {
    let p = self.dress(b, pen_style(style, style_by), left?, top?, right?, bottom?, edges_by?, tx~, ty~, flow~, line_gap~)
    inner(p)
    made.val = Some(p)
  })
  |> ignore
  made.val.unwrap()
}

///|
/// A box as Pen::box makes it, while `when` holds (what the card says: a part only some of its figures have), made as it
/// comes to and let go as it stops, at once (the picture as it is, no way in).
fn Pen::show(
  self : Pen,
  when : () -> Bool,
  style? : @ui.Style,
  style_by? : () -> @ui.Style,
  left? : Double,
  top? : Double,
  right? : Double,
  bottom? : Double,
  tx? : Double = 0.0,
  ty? : Double = 0.0,
  flow? : Bool = false,
  line_gap? : Double = 0.0,
  inner : (Pen) -> Unit,
) -> Unit {
  let style = pen_style(style, style_by)
  let when = by_value(when)
  self.v.show(at_once=true, when, fn(b) {
    inner(self.dress(b, style, left?, top?, right?, bottom?, tx~, ty~, flow~, line_gap~))
  })
}

///|
/// A box as Pen::box makes it for each of `items` (what the card says as many as it has: its kinds, models, days), by its
/// key (`key`: what it is of the card, its place in its order where nothing else names it), made as its key comes, kept
/// while it stays, let go as it goes, at once; each of the style `style_of` its item says, what it holds made by `row`
/// given it and its item as it is now; put over it so far in from its edges as `edges_of` says of its item as it is
/// now (Pen::box's `edges_by`).
fn[T : Eq, K : Hash + Eq] Pen::each(
  self : Pen,
  items : () -> Array[T],
  key : (T) -> K,
  style_of? : (T) -> @ui.Style,
  edges_of? : (T) -> (Double?, Double?, Double?, Double?),
  row : (Pen, () -> T) -> Unit,
) -> Unit {
  self.v.each(at_once=true, items, key, fn(b, item) {
    let it = fn() { item.get() }
    let style = match style_of {
      Some(f) => Some(by_value(fn() { f(it()) }))
      None => None
    }
    let edges_by = match edges_of {
      Some(f) => Some(fn() { f(it()) })
      None => None
    }
    row(self.dress(b, style, edges_by?), it)
  })
}

///|
/// The style said or worked out, as a closure (none: none said).
fn pen_style(style : @ui.Style?, style_by : (() -> @ui.Style)?) -> (() -> @ui.Style)? {
  match (style, style_by) {
    (_, Some(f)) => Some(by_value(f))
    (Some(s), None) => Some(fn() { s })
    (None, None) => None
  }
}

///|
/// Node `b` dressed as a box of `style` (Pen::box's): how it is laid out, as the style first says it.
fn Pen::dress(
  self : Pen,
  b : @view.View,
  style : (() -> @ui.Style)?,
  left? : Double,
  top? : Double,
  right? : Double,
  bottom? : Double,
  edges_by? : () -> (Double?, Double?, Double?, Double?),
  tx? : Double = 0.0,
  ty? : Double = 0.0,
  flow? : Bool = false,
  line_gap? : Double = 0.0,
) -> Pen {
  // (how it is laid out, as the style says it as it is made: a style worked out of the card changes its look, its size
  // and its room, never whether it is a row, how it gives way, its shadow or how opaque it is)
  let first = match style {
    Some(f) => Some(@signals.untracked(f))
    None => None
  }
  let base = match first {
    Some(s) => Some(s.base)
    None => None
  }
  let row = match base {
    Some(b) => b.row.unwrap_or(false)
    None => false
  }
  match (style, base) {
    // (a share of what holds it as its width: said as a share, the rest of the style as it says, style_node's)
    (Some(f), Some({ w: Some(@ui.Len::Pct(_)), .. })) => {
      let rest = fn() {
        let s = f()
        @ui.Style::{ ..s, base: @ui.Patch::{ ..s.base, w: None } }
      }
      @sf.style_node(b, rest, in_row=self.row)
      b.width_share(By(fn() {
        match f().base.w {
          Some(@ui.Len::Pct(p)) => p / 100.0
          _ => 1.0
        }
      }))
      |> ignore
    }
    (Some(f), _) => @sf.style_node(b, f, in_row=self.row)
    (None, _) => ()
  }
  pen_gives(b, self.row, base)
  match (style, base) {
    // (its shadow as the style says it, where it says one as it is made: one worked out of the card, another's)
    (Some(f), Some({ shadow: Some(_), .. })) =>
      b.shadow(By(fn() {
        match f().base.shadow {
          Some(sh) => {
            let (blur, dy) = sh.blur_y()
            let ink = match sh {
              Cast(_, _, k) => k
              _ => @ui.tree_theme().shadow
            }
            (blur, dy, ink)
          }
          None => (0.0, 0.0, 0L)
        }
      }))
      |> ignore
    _ => ()
  }
  match (style, base) {
    // (how opaque the style says it is, where it says so as it is made)
    (Some(f), Some({ opacity: Some(_), .. })) =>
      b.alpha(By(fn() {
        match f().base.opacity {
          Some(o) => o.value()
          None => 1.0
        }
      }))
      |> ignore
    _ => ()
  }
  match edges_by {
    Some(f) => b.over_at(By(by_value(f))) |> ignore
    None =>
      if left is Some(_) || top is Some(_) || right is Some(_) || bottom is Some(_) {
        b.over(Is(true), edges=(left, top, right, bottom)) |> ignore
      }
  }
  if tx != 0.0 || ty != 0.0 {
    b.offset(Is((tx, ty))) |> ignore
  }
  if flow {
    b.wraps(Is(Some(line_gap))) |> ignore
  }
  { v: b, row }
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
/// Words in runs (`@ui.span`s: a figure in another colour, larger, bolder) as `runs` works them out of what the card
/// says (and the app's words, in the language as it is), of `style` (or as `style_by` chooses among the look's styles,
/// laid out as `style` says), in face `face` (0: the app's): as wide as they say (`w`: filling their line, cut short on
/// it, so many points), wrapping or on one line as they say.
fn Pen::rich_by(
  self : Pen,
  runs : () -> Array[@ui.Run],
  style~ : @ui.TextStyle,
  style_by? : () -> @ui.TextStyle,
  face? : Int = 0,
) -> Unit {
  self.v.box(fn(w) { pen_words(w, self.row, runs, style, style_by, face) }) |> ignore
}

///|
/// Words as Pen::rich_by makes them, while `when` holds (what the card says), made as it comes to and let go as it stops,
/// at once.
fn Pen::show_rich(
  self : Pen,
  when : () -> Bool,
  runs : () -> Array[@ui.Run],
  style~ : @ui.TextStyle,
  style_by? : () -> @ui.TextStyle,
  face? : Int = 0,
) -> Unit {
  self.v.show(at_once=true, by_value(when), fn(w) { pen_words(w, self.row, runs, style, style_by, face) })
}

///|
/// Words as Pen::rich_by makes them for each of `items`, by its key (Pen::each's), as `runs` works them out of its item
/// as it is now, of `style` (or of the style `style_of` says of its key: which it is of the card).
fn[T : Eq, K : Hash + Eq] Pen::each_rich(
  self : Pen,
  items : () -> Array[T],
  key : (T) -> K,
  runs : (() -> T) -> Array[@ui.Run],
  style~ : @ui.TextStyle,
  style_of? : (K) -> @ui.TextStyle,
  face? : Int = 0,
) -> Unit {
  self.v.each(at_once=true, items, key, fn(w, item) {
    let style = match style_of {
      Some(f) => f(key(item.get()))
      None => style
    }
    pen_words(w, self.row, fn() { runs(fn() { item.get() }) }, style, None, face)
  })
}

///|
/// Node `w` as words (Pen::rich_by's), in what holds it (a row: `in_row`).
fn pen_words(
  w : @view.View,
  in_row : Bool,
  runs : () -> Array[@ui.Run],
  style : @ui.TextStyle,
  style_by : (() -> @ui.TextStyle)?,
  face : Int,
) -> Unit {
  let runs = by_value(fn() {
    let runs = runs()
    if face == 0 {
      runs
    } else {
      runs.map(fn(r) { if r.face is None { { ..r, face: Some(face) } } else { r } })
    }
  })
  let look = @ui.style_words(style)
  let said = style.base
  w.words_runs(By(runs)) |> ignore
  match style_by {
    Some(f) => {
      let st = by_choice(f)
      w.words_look(By(fn() { @ui.style_words(st()) })).ink(By(fn() { @ui.style_ink(st()) })) |> ignore
    }
    None => w.words_look(Is(look)).ink(Is(@ui.style_ink(style))) |> ignore
  }
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
}

///|
/// Words in runs said once (what no figure and no word of the app's is in: still.fail's name, a prompt), Pen::rich_by's.
fn Pen::rich(self : Pen, runs : Array[@ui.Run], style~ : @ui.TextStyle, face? : Int = 0) -> Unit {
  self.rich_by(fn() { runs }, style~, face~)
}

///|
/// Words `words` works out, of `style` (or as `style_by` chooses), in face `face` (0: the app's): Pen::rich_by's of one
/// run.
fn Pen::text_by(
  self : Pen,
  words : () -> String,
  style~ : @ui.TextStyle,
  style_by? : () -> @ui.TextStyle,
  face? : Int = 0,
) -> Unit {
  self.rich_by(fn() { [@ui.span(words())] }, style~, style_by?, face~)
}

///|
/// Words said once, Pen::text_by's.
fn Pen::text(self : Pen, words : String, style~ : @ui.TextStyle, face? : Int = 0) -> Unit {
  self.rich_by(fn() { [@ui.span(words)] }, style~, face~)
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
/// Picture as `key` says it, as what the card says changes (the week's busiest day's), `w` by `h` points: Pen::image's.
fn Pen::image_by(self : Pen, key : () -> String, w : Double, h : Double, at? : Double) -> Unit {
  let key = by_value(key)
  self.v.box(fn(i) {
    i
    .width(Is(Some(w)))
    .height(Is(Some(h)))
    .image(By(fn() { Some((key(), "", pen_image_most)) }))
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
/// Shapes as `shapes` works them out of what the card says, `w` by `h` points: Pen::shapes'.
fn Pen::shapes_by(self : Pen, shapes : () -> Array[@ui.Shape], w : Double, h : Double) -> Unit {
  let shapes = by_value(shapes)
  self.v.box(fn(s) { s.width(Is(Some(w))).height(Is(Some(h))).shapes(By(shapes)) |> ignore }) |> ignore
}

///|
/// It read out as `role` named as `label` works it out (a look's card: a picture, named by its look and its figures).
fn Pen::says(self : Pen, role : @view.Role, label : () -> String) -> Unit {
  let label = by_value(label)
  self.v.says(By(fn() { Some(@view.said(role, label=label())) })) |> ignore
}
