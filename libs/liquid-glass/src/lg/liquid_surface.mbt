// Ported from Kyant0/AndroidLiquidGlass (Apache-2.0): catalog/destinations/ProgressiveBlurContent.kt,
// AdaptiveLuminanceGlassContent.kt and MagnifierContent.kt. Three surfaces of glass over what a page holds: a band that
// blurs and tints what is under it fading out down its lower half (an alpha mask), a card whose glass follows how light
// what is under it is, and a lens over words that a finger drags.

///|
/// GLSL's smoothstep(`e0`, `e1`, `x`).
fn smoothstep(e0 : Double, e1 : Double, x : Double) -> Double {
  if e0 == e1 {
    return if x < e0 { 0.0 } else { 1.0 }
  }
  let t = clamp((x - e0) / (e1 - e0), 0.0, 1.0)
  t * t * (3.0 - 2.0 * t)
}

///|
/// How many bands of glass the progressive blur's mask is drawn in: its lower half's fade, a band a slice, each as seen
/// as the mask is at its middle.
let blur_slices : Int = 16

///|
/// A progressive blur in `parent` (ProgressiveBlurContent): a band 128 high across what holds it, what is under it
/// blurred by 4 with the tint over 80% of it (white, or grey in the dark), whole down its upper half and fading out to
/// nothing at its foot (smoothstep(h, h / 2, y), the catalog's AlphaMask shader); `words` in its middle. The node.
#callsite(autofill(loc))
pub fn liquid_progressive_blur_node(
  parent : @view.View,
  words? : () -> String = fn() { "alpha-masked progressive blur" },
  height? : Double = blur_band_h,
  loc~ : SourceLoc,
) -> @view.View {
  parent.box(made_for=loc, fn(b) {
    b.height(Is(Some(height))).lines_up(Is(Some(Middle))).lies_along(Is(Middle)) |> ignore
    let glass = fn() {
      let tint = alpha(colors().blur_tint, blur_band_tint)
      @paint.Glass::frosted(blur=blur_band_blur, tint~, solid=colors().blur_tint, contained=true)
    }
    // (its upper half whole, its lower half a slice at a time, each as the mask is at its middle)
    b.box(fn(top) {
      top.over(Is(true)).height(Is(Some(height / 2.0))).glass(By(fn() { Some(glass()) })) |> ignore
    })
    |> ignore
    let slice = height / 2.0 / blur_slices.to_double()
    for k in 0..<blur_slices {
      let y = height / 2.0 + k.to_double() * slice
      b.box(fn(s) {
        s
        .over(Is(true))
        .height(Is(Some(slice)))
        .offset(Is((0.0, y)))
        .glass(By(fn() { Some(glass()) }))
        .alpha(Is(smoothstep(height, height / 2.0, y + slice / 2.0)))
        |> ignore
      })
      |> ignore
    }
    b.box(fn(w) { w.words(By(words), look=words_at(type_body)).ink(By(fn() { colors().content })) |> ignore }) |> ignore
  })
}

///|
/// The glass of an adaptive surface over what is `lum` light (0 black, 1 white), `min_side` its shorter side
/// (flutter_liquid_glass size-responsive blur curve + iOS 27 light/dark adaptive color transfer).
pub fn adaptive_glass(lum : Double, min_side : Double) -> @paint.Glass {
  let smooth = fn(t : Double) {
    let u = clamp(t, 0.0, 1.0)
    u * u * (3.0 - 2.0 * u)
  }
  let blur = 2.1 +
    2.4 * smooth((min_side - 63.0) / 31.0) +
    1.1 * smooth((min_side - 94.0) / 24.0) +
    2.4 * clamp((min_side - 118.0) / 32.0, 0.0, 1.0)
  let is_light = lum > 0.5
  @paint.Glass::liquid(
    blur~,
    tint=if is_light { 0xFDFCFD67L } else { 0x202020FFL },
    solid=if is_light { white } else { black },
    saturation=1.0,
    rim=0.6,
    bezel=20.0,
    refraction=min_side / 2.0,
    chroma=0.0,
    merge=0.0,
    adaptive=false,
  )
}

///|
/// An adaptive surface in `parent` (AdaptiveLuminanceGlassContent): a card 160 across, its corners 24, its glass as
/// light as what is under it is (`luminance`, 0-1: what the catalog reads off its backdrop five by five, given here by
/// what draws it), its words saying so in black over what is light, white over what is dark. The node.
#callsite(autofill(loc))
pub fn liquid_adaptive_surface_node(
  parent : @view.View,
  luminance : () -> Double,
  size? : Double = adaptive_size,
  loc~ : SourceLoc,
) -> @view.View {
  parent.box(made_for=loc, fn(c) {
    c
    .width(Is(Some(size)))
    .height(Is(Some(size)))
    .shrink(Is(0.0))
    .radius(Is(adaptive_radius))
    .lines_up(Is(Some(Middle)))
    .lies_along(Is(Middle))
    .shadow(Is(shadow_default))
    .glass(By(fn() { Some(adaptive_glass(luminance(), size)) }))
    |> ignore
    c.box(fn(w) {
      w
      .words(
        By(fn() {
          let hundredths = (clamp(luminance(), 0.0, 1.0) * 100.0).round().to_int()
          let (whole, part) = (hundredths / 100, hundredths % 100)
          let pad = if part < 10 { "0" } else { "" }
          "luminance:\n\{whole}.\{pad}\{part}"
        }),
        look=words_at(type_body, wrap=true),
      )
      .words_centered(Is(true))
      .ink(By(fn() { if luminance() > 0.5 { black } else { white } }))
      |> ignore
    })
    |> ignore
  })
}

///|
/// The magnifier's glass (iOS 27 clear loupe).
fn magnifier_glass() -> @paint.Glass {
  @paint.Glass::liquid(
    blur=0.0,
    tint=0xFFFFFF00L,
    solid=colors().paper,
    saturation=1.0,
    rim=0.6,
    bezel=20.0,
    refraction=24.0,
    chroma=-0.06,
    merge=0.0,
    adaptive=false,
  )
}

///|
/// A magnifier in `parent` (MagnifierContent): `words` on a page (16, 24 in, its corners 32, the page's paper at 90%,
/// 24 round it), a cursor 4 × 24 in the accent at its middle, and over it a capsule lens 128 × 96 80 above the cursor,
/// both dragged by a finger on the lens, read out a group named `label`. The node.
#callsite(autofill(loc))
pub fn liquid_magnifier_node(
  parent : @view.View,
  words : () -> String,
  label? : () -> String = fn() { "Magnifier" },
  at? : (Double, Double) = (0.0, 0.0),
  loc~ : SourceLoc,
) -> @view.View {
  let (ax, ay) = at
  let moved = @signals.signal((ax, ay))
  let last = Ref((0.0, 0.0))
  parent.box(made_for=loc, fn(m) {
    m.padding(Is((page_pad, page_pad, page_pad, page_pad))).lines_up(Is(Some(Middle))).lies_along(Is(Middle)) |> ignore
    m.box(fn(page) {
      page
      .radius(Is(page_radius))
      .ground(By(fn() { colors().paper }))
      .padding(Is((page_pad, page_pad, page_pad, page_pad)))
      |> ignore
      page.box(fn(w) {
        w.words(By(words), look=words_at(type_body, wrap=true)).ink(By(fn() { colors().content })) |> ignore
      })
      |> ignore
    })
    |> ignore
    // (the cursor and the lens in the middle of it all, moved together by the finger)
    m.box(fn(o) {
      o.over(Is(true)).lines_up(Is(Some(Middle))).lies_along(Is(Middle)) |> ignore
      o.box(fn(cursor) {
        cursor
        .width(Is(Some(cursor_w)))
        .height(Is(Some(cursor_h)))
        .radius(Is(cursor_w / 2.0))
        .ground(By(fn() { colors().accent }))
        .offset(By(fn() { moved.get() }))
        |> ignore
      })
      |> ignore
    })
    |> ignore
    m.box(fn(o) {
      o.over(Is(true)).lines_up(Is(Some(Middle))).lies_along(Is(Middle)) |> ignore
      o.box(fn(lens) {
        lens
        .width(Is(Some(magnifier_w)))
        .height(Is(Some(magnifier_h)))
        .radius(Is(magnifier_h / 2.0))
        .shadow(Is(shadow_default))
        .glass(By(fn() { Some(magnifier_glass()) }))
        .offset(By(fn() {
          let (x, y) = moved.get()
          (x, y - magnifier_over)
        }))
        .says(By(fn() { Some(@view.said(Group, label=label())) }))
        .gesture(@ui.touch_slop(), press=fn(d) { last.val = (d.wx, d.wy) }, drag=fn(d) {
          match d.kind {
            Down => last.val = (d.wx, d.wy)
            Moved => {
              let (lx, ly) = last.val
              let (x, y) = moved.untracked()
              moved.set((x + d.wx - lx, y + d.wy - ly))
              last.val = (d.wx, d.wy)
            }
            Up | Off => ()
          }
        })
        |> ignore
      })
      |> ignore
    })
    |> ignore
  })
}
