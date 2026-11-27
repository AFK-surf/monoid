// Words hidden where a picture is shared with names hidden (2026-11-17 用户：「打码用打码的样式，不要改账号名，看着很假」「参考
// 一下网上有没有好看点的马赛克」, then chose the dots of a spoiler, as Telegram hides one, over a blur): the words laid
// out as they are, so their line keeps its length and what follows them its place, drawn none, a field of fine dots
// in their box instead, a picture of its own (Role Image).

///|
/// Words made by `make` in a box of `parent`'s, dots in their place while `masked` says (none: the words alone, as
/// ever); the box giving way in its row as the words do.
#callsite(autofill(loc))
pub fn masked_words_box(
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
          k.show(at_once=true, m, fn(d) {
            d.over(Is(true), edges=(Some(0.0), Some(0.0), None, None)).row(Is(true)) |> ignore
            spoiler_tile_node(d, loc~)
            spoiler_tile_node(d, loc~)
            spoiler_tile_node(d, loc~)
            spoiler_tile_node(d, loc~)
            spoiler_tile_node(d, loc~)
            spoiler_tile_node(d, loc~)
            spoiler_tile_node(d, loc~)
            spoiler_tile_node(d, loc~)
          })
        })
        |> ignore
      })
      |> ignore
  }
}

///|
#callsite(autofill(loc))
fn spoiler_tile_node(parent : @view.View, loc~ : SourceLoc) -> Unit {
  parent.box(made_for=loc, fn(tile) {
    tile
    .width(Is(Some(spoiler_tile_w)))
    .height(Is(Some(spoiler_h)))
    .shrink(Is(0.0))
    .image(By(fn() { Some((spoiler_image_key(theme().p.text), "", 256)) }))
    .image_fades(Is(false))
    |> ignore
  })
  |> ignore
}

///|
/// A cached 4-bit indexed PNG tile of fine anti-aliased dots in `ink` (112 × 32 px for 64 × 24 pt, ~1.98 KB): shared
/// by every masked row in that theme instead of emitting thousands of vector polygons per row.
fn spoiler_image_key(ink : Int64) -> String {
  let key = "mem:sf-spoiler/\{ink}"
  if !@ui.has_image(key) {
    @ui.add_image(key, spoiler_tile_png(ink))
  }
  key
}

///|
fn spoiler_tile_png(ink : Int64) -> Bytes {
  let pw = spoiler_tile_pw
  let ph = spoiler_tile_ph
  let r_byte = ((ink >> 24) & 0xFFL).to_byte()
  let g_byte = ((ink >> 16) & 0xFFL).to_byte()
  let b_byte = ((ink >> 8) & 0xFFL).to_byte()
  let palette = FixedArray::make(16 * 3, b'\x00')
  let alphas = FixedArray::make(16, b'\x00')
  for i in 0..<16 {
    palette[i * 3] = r_byte
    palette[i * 3 + 1] = g_byte
    palette[i * 3 + 2] = b_byte
    alphas[i] = ((i * 230 + 7) / 15).to_byte()
  }
  let acc = FixedArray::make(pw * ph, 0.0)
  let sx = pw.to_double() / spoiler_tile_w
  let sy = ph.to_double() / spoiler_h
  let aa = 0.5 / sx
  let mut seed = 12345
  let next = fn() {
    seed = (seed * 1103515245 + 12345) % 2147483647
    if seed < 0 {
      seed = -seed
    }
    seed.to_double() / 2147483647.0
  }
  for _ in 0..<spoiler_tile_dots {
    let cx = next() * spoiler_tile_w
    let cy = next() * spoiler_h
    let rad = 0.45 + next() * 0.55
    let a = 0.25 + next() * 0.6
    let reach = rad + aa
    let x0 = ((cx - reach) * sx).floor().to_int()
    let x1 = ((cx + reach) * sx).ceil().to_int()
    let y0 = @cmp.maximum(0, ((cy - reach) * sy).floor().to_int())
    let y1 = @cmp.minimum(ph - 1, ((cy + reach) * sy).ceil().to_int())
    for py in y0..=y1 {
      let dy = (py.to_double() + 0.5) / sy - cy
      let dy2 = dy * dy
      for px_raw in x0..=x1 {
        let px = (px_raw % pw + pw) % pw
        let mut dx = (px.to_double() + 0.5) / sx - cx
        if dx > spoiler_tile_w * 0.5 {
          dx -= spoiler_tile_w
        } else if dx < -spoiler_tile_w * 0.5 {
          dx += spoiler_tile_w
        }
        let d2 = dx * dx + dy2
        if d2 < reach * reach {
          let dist = d2.sqrt()
          let cov = if dist <= rad - aa {
            1.0
          } else {
            let t = (reach - dist) / (2.0 * aa)
            if t < 0.0 { 0.0 } else if t > 1.0 { 1.0 } else { t }
          }
          let da = a * cov
          let idx = py * pw + px
          acc[idx] = acc[idx] + da * (1.0 - acc[idx])
        }
      }
    }
  }
  let indices = FixedArray::make(pw * ph, b'\x00')
  for i in 0..<(pw * ph) {
    let q = (acc[i] * 255.0 / 230.0 * 15.0).round().to_int()
    let clamped = if q < 0 { 0 } else if q > 15 { 15 } else { q }
    indices[i] = clamped.to_byte()
  }
  @pixels.png_indexed(pw, ph, palette, alphas, indices)
}

///|
/// Logical tile size (64 × 24 pt, tiled 8 across to cover 480 pt) and pixel size (112 × 32 px).
let spoiler_tile_w : Double = 64.0

///|
let spoiler_h : Double = 24.0

///|
let spoiler_tile_pw : Int = 112

///|
let spoiler_tile_ph : Int = 32

///|
let spoiler_tile_dots : Int = 294

///|
/// How far the dots reach past the words' ends, and the corner they are cut round by.
let mask_past : Double = 3.0

///|
let mask_corner : Double = 8.0
