// Words hidden where a picture is shared with names hidden (2026-11-17 用户：「打码用打码的样式，不要改账号名，看着很假」「参考
// 一下网上有没有好看点的马赛克」, then chose the dots of a spoiler, as Telegram hides one, over a blur): the words laid
// out as they are, so their line keeps its length and what follows them its place, drawn none, a field of fine dots
// in their box instead, a picture of its own (Role Image).

///|
/// Words made by `make` in a box of `parent`'s, dots in their place while `masked` says (none: the words alone, as
/// ever); the box giving way in its row as the words do.
#callsite(autofill(loc))
fn masked_words_box(
  parent : @view.View,
  masked : (() -> Bool)?,
  make : (@view.View) -> Unit,
  loc~ : SourceLoc,
) -> Unit {
  match masked {
    None => parent.box(made_for=loc, make) |> ignore
    Some(m) =>
      parent.box(made_for=loc, fn(h) {
        h.shrink(Is(1.0)).min_width(Is(Some(0.0))) |> ignore
        // (the words drawn none while it says so: their room as it was)
        h.box(fn(w) {
          make(w)
          w.alpha(By(fn() { if m() { 0.0 } else { 1.0 } })) |> ignore
        })
        |> ignore
        // (over them, a little past their ends, round as a small block, cut to it: its dots while it says so, none and
        // nothing read out otherwise)
        h.box(fn(k) {
          k
          .over(Is(true), edges=(Some(-mask_past), Some(0.0), Some(-mask_past), Some(0.0)))
          .radius(Is(mask_corner))
          .clips(Is(true))
          .says(By(fn() { if m() { Some(@view.said(Image, label=t("web-main.share.masked"))) } else { None } }))
          |> ignore
          k.box(fn(d) { d.shapes(By(fn() { if m() { spoiler_dots() } else { [] } })) |> ignore }) |> ignore
        })
        |> ignore
      })
      |> ignore
  }
}

///|
/// The dots from the words' top left, wider and taller than words on a row ever are (cut to them): spoiler_count of
/// them, each of a size and a strength of the ink of its own, strewn where a sequence of the same seed puts them (the
/// same picture every time).
fn spoiler_dots() -> Array[@ui.Shape] {
  let ink = theme().p.text
  let out : Array[@ui.Shape] = []
  let mut seed = 12345
  let next = fn() {
    seed = (seed * 1103515245 + 12345) % 2147483647
    if seed < 0 {
      seed = -seed
    }
    seed.to_double() / 2147483647.0
  }
  for _ in 0..<spoiler_count {
    let x = next() * spoiler_w
    let y = next() * spoiler_h
    let r = 0.45 + next() * 0.55
    let a = 0.25 + next() * 0.6
    let pts : Array[Double] = []
    for i in 0..<8 {
      let th = i.to_double() * @math.PI / 4.0
      pts.push(x + r * @dmath.cos(th))
      pts.push(y + r * @dmath.sin(th))
    }
    out.push(@ui.shape_of([(pts, true)], fill=alpha(ink, a)))
  }
  out
}

///|
/// How many dots, over how wide and how tall a field.
let spoiler_count : Int = 2200

///|
let spoiler_w : Double = 480.0

///|
let spoiler_h : Double = 24.0

///|
/// How far the dots reach past the words' ends, and the corner they are cut round by.
let mask_past : Double = 3.0

///|
let mask_corner : Double = 8.0
