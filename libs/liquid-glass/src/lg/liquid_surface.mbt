// Ported from Kyant0/AndroidLiquidGlass (Apache-2.0): catalog/destinations/ProgressiveBlurContent.kt,
// AdaptiveLuminanceGlassContent.kt and MagnifierContent.kt. Three surfaces of glass over what a page holds: a band that
// blurs and tints what is under it fading out down its lower half (an alpha mask), a card whose glass follows how light
// what is under it is, and a lens over words that a finger drags.

///|
/// Which edge of a scroll viewport a `liquid_scroll_edge_node` softens.
#derive(Eq, Debug)
pub(all) enum ScrollEdgeSide {
  Top
  Bottom
}

///|
/// Native four-platform progressive variable-blur scroll-edge backdrop (`UIScrollEdgeEffect.soft`, `progressive=true`)
/// anchored to the `Top` or `Bottom` edge of `parent`.
///
/// Blurs and veils scrolled content smoothly over `fade_h` within a `base_h`-tall band, emits zero hidden glass
/// instances when `base_h(fill) <= 0.0`, and when `shield=true` (default) blocks click-through onto scrolled content
/// behind floating top/bottom bars without affecting hover.
#callsite(autofill(loc))
pub fn liquid_scroll_edge_node(
  parent : @view.View,
  base_h : (@view.View) -> Double,
  fade_h : (@view.View) -> Double,
  side? : ScrollEdgeSide = Top,
  bg? : () -> Int64,
  shield? : Bool = true,
  loc~ : SourceLoc,
) -> @view.View {
  let build_scrim = fn(scrim : @view.View) {
    scrim
    .width_share(Is(1.0))
    .height(By(fn() { Some(base_h(scrim)) }))
    .fades(
      By(fn() {
        match side {
          Top => (0.0, 0.0, 0.0, fade_h(scrim))
          Bottom => (0.0, fade_h(scrim), 0.0, 0.0)
        }
      }),
    )
    |> ignore
    scrim.box(fn(fill) {
      // Register fill in inputs_in via pointed() while keeping points=false when shield=true so Tree::target_at
      // visits fill and applies Node::covers to block click-through onto scrolled content without affecting hover.
      fill
      .width_share(Is(1.0))
      .height_share(Is(1.0))
      .glass(
        By(fn() {
          if base_h(fill) > 0.0 {
            let color = match bg {
              Some(f) => f()
              None => clear
            }
            Some(liquid_scroll_edge_glass(bg=color))
          } else {
            None
          }
        }),
      )
      .points(Is(false))
      |> ignore
      if shield {
        @signals.untracked(fn() { fill.pointed() }) |> ignore
      }
    })
    |> ignore
  }
  match side {
    Top =>
      parent.box(made_for=loc, fn(scrim) {
        scrim.over(Is(true)) |> ignore
        build_scrim(scrim)
      })
    Bottom =>
      parent.box(made_for=loc, fn(wrap) {
        wrap.over(Is(true)).points(Is(false)).lies_along(Is(End)) |> ignore
        wrap.box(build_scrim) |> ignore
      })
  }
}

///|
/// A progressive blur in `parent` (ProgressiveBlurContent): a band 128 high across what holds it, what is under it
/// blurred by 4 with the tint over 80% of it (white, or grey in the dark), whole down its upper half and fading out to
/// nothing at its foot via a single progressive frosted glass layer (`progressive=true`) masked by `fades`; `words` in
/// its middle. The node.
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
      @paint.Glass::frosted(
        blur=blur_band_blur,
        tint~,
        solid=colors().blur_tint,
        contained=false,
        progressive=true,
      )
    }
    b.box(fn(mask) {
      mask.over(Is(true)).fades(Is((0.0, 0.0, 0.0, height / 2.0))) |> ignore
      mask.box(fn(layer) {
        layer.over(Is(true)).glass(By(fn() { Some(glass()) })) |> ignore
      })
      |> ignore
    })
    |> ignore
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
    tint=if is_light { 0xFDFCFD67L } else { 0x20202067L },
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
    .shadow_outside(Is(true))
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
/// The magnifier's glass (iOS 27 clear loupe over 1.5× zoomed text).
fn magnifier_glass() -> @paint.Glass {
  @paint.Glass::liquid(
    blur=0.0,
    tint=0xFFFFFF00L,
    solid=colors().paper,
    saturation=1.0,
    rim=0.6,
    bezel=16.0,
    refraction=20.0,
    chroma=-0.06,
    merge=0.0,
    adaptive=false,
  )
}

///|
/// Split `s` on newlines, preserving empty lines (always at least one line).
fn loupe_split_lines(s : String) -> Array[String] {
  let out : Array[String] = []
  let buf = StringBuilder()
  for ch in s {
    if ch == '\n' {
      out.push(buf.to_string())
      buf.reset()
    } else {
      buf.write_char(ch)
    }
  }
  out.push(buf.to_string())
  out
}

///|
/// Matching caret stop X positions at 1× (`look`) and 1.5× (`look_15`) for one line via `@ui.glyph_cells`.
fn loupe_line_stops(
  line : String,
  look : @view.WordsLook,
  look_15 : @view.WordsLook,
) -> (Array[Double], Array[Double]) {
  let c1 = @ui.glyph_cells(line, look, 1.0)
  let c2 = @ui.glyph_cells(line, look_15, 1.0)
  let s1 : Array[Double] = [0.0]
  let s2 : Array[Double] = [0.0]
  let n = if c1.length() < c2.length() { c1.length() } else { c2.length() }
  for i in 0..<n {
    let (cx1, adv1) = c1[i]
    let (cx2, adv2) = c2[i]
    let x0_1 = cx1 - adv1 * 0.5
    let x1_1 = cx1 + adv1 * 0.5
    let x0_2 = cx2 - adv2 * 0.5
    let x1_2 = cx2 + adv2 * 0.5
    if x0_1 - s1[s1.length() - 1] > 1.0 {
      s1.push(x0_1)
      s2.push(x0_2)
    }
    s1.push(x1_1)
    s2.push(x1_2)
  }
  (s1, s2)
}

///|
/// Snap local pointer `(lx, ly)` to the nearest valid `(row, col, caret_x_1x, caret_x_15x)` character gap.
fn loupe_snap(
  lines : Array[String],
  lx : Double,
  ly : Double,
  line_h : Double,
  look : @view.WordsLook,
  look_15 : @view.WordsLook,
) -> (Int, Int, Double, Double) {
  let last_row = if lines.length() > 0 { lines.length() - 1 } else { 0 }
  let raw_row = (ly / line_h).floor().to_int()
  let row = if raw_row < 0 { 0 } else if raw_row > last_row { last_row } else { raw_row }
  let (s1, s2) = loupe_line_stops(lines[row], look, look_15)
  let mut best_col = 0
  let mut best_dist = (s1[0] - lx).abs()
  for i in 1..<s1.length() {
    let d = (s1[i] - lx).abs()
    if d < best_dist {
      best_dist = d
      best_col = i
    }
  }
  (row, best_col, s1[best_col], s2[best_col])
}

///|
/// Render multiline text as fixed-height rows so caret Y and 1.5× loupe Y align to the sub-pixel.
#callsite(autofill(loc))
fn loupe_render_lines(
  parent : @view.View,
  lines : Array[String],
  row_h : Double,
  look : @view.WordsLook,
  loc~ : SourceLoc,
) -> Unit {
  for line in lines {
    parent.box(made_for=loc, fn(r) {
      r.height(Is(Some(row_h))).lies_along(Is(Middle)) |> ignore
      r.box(fn(w) {
        w.words(Is(line), look~).ink(By(fn() { colors().content })) |> ignore
      })
      |> ignore
    })
    |> ignore
  }
}

///|
/// A real iOS-style optical text magnifier in `parent`: renders `words` line-by-line, snaps the accent caret to exact
/// `@ui.glyph_cells` character boundaries (never splitting a glyph), and floats a 156 × 64 clear refractive glass
/// capsule above the caret showing the exact characters around the caret magnified at 1.5×. Both the text area and the
/// loupe capsule accept drags (`gesture(2.0, ...)`).
#callsite(autofill(loc))
pub fn liquid_magnifier_node(
  parent : @view.View,
  words : () -> String,
  label? : () -> String = fn() { "Magnifier" },
  at? : (Double, Double) = (0.0, 0.0),
  loc~ : SourceLoc,
) -> @view.View {
  let line_h = 24.0
  let line_h_15 = 36.0
  let caret_w = 2.5
  let caret_h = 20.0
  let lens_w = 156.0
  let lens_h = 64.0
  let lens_r = 32.0
  let lens_above = 54.0
  let look = { ..words_at(type_body), line: line_h }
  let look_15 = { ..words_at(type_body * 1.5), line: line_h_15 }
  let lines = loupe_split_lines(@signals.untracked(words))
  let (ax, ay) = at
  let pos = @signals.signal(loupe_snap(lines, ax, ay, line_h, look, look_15))
  let lens_anchor = Ref((0.0, 0.0))
  let lens_start = Ref((0.0, 0.0))
  let update_at = fn(lx : Double, ly : Double) {
    pos.set(loupe_snap(lines, lx, ly, line_h, look, look_15))
  }
  parent.box(made_for=loc, fn(m) {
    m
    .padding(Is((page_pad, page_pad + 32.0, page_pad, page_pad)))
    .lines_up(Is(Some(Middle)))
    .lies_along(Is(Middle))
    |> ignore
    m.box(fn(page) {
      page
      .radius(Is(page_radius))
      .ground(By(fn() { colors().paper }))
      .padding(Is((page_pad, page_pad, page_pad, page_pad)))
      |> ignore
      page.box(fn(text_box) {
        text_box
        .gesture(
          2.0,
          press=fn(d) { update_at(d.x, d.y) },
          drag=fn(d) {
            match d.kind {
              Down | Moved => update_at(d.x, d.y)
              Up | Off => ()
            }
          },
        )
        |> ignore
        loupe_render_lines(text_box, lines, line_h, look)
        // Snapped character-boundary caret overlay
        text_box.box(fn(caret_layer) {
          caret_layer.over(Is(true)).points(Is(false)) |> ignore
          caret_layer.box(fn(cursor) {
            cursor
            .over(Is(true))
            .width(Is(Some(caret_w)))
            .height(Is(Some(caret_h)))
            .radius(Is(caret_w / 2.0))
            .ground(By(fn() { colors().accent }))
            .offset(By(fn() {
              let (row, _, cx, _) = pos.get()
              (cx - caret_w * 0.5, row.to_double() * line_h + (line_h - caret_h) * 0.5)
            }))
            |> ignore
          })
          |> ignore
        })
        |> ignore
        // Floating 156×64 1.5× optical loupe centered horizontally on the snapped caret, 54pt above it
        text_box.box(fn(lens_layer) {
          lens_layer.over(Is(true)).points(Is(false)) |> ignore
          lens_layer.box(fn(lens_wrap) {
            lens_wrap
            .over(Is(true))
            .points(Is(true))
            .width(Is(Some(lens_w)))
            .height(Is(Some(lens_h)))
            .radius(Is(lens_r))
            .shadow(Is(shadow_default))
            .shadow_outside(Is(true))
            .offset(By(fn() {
              let (row, _, cx, _) = pos.get()
              let lx = clamp(cx - lens_w * 0.5, -24.0, 440.0)
              let ly = row.to_double() * line_h + line_h * 0.5 - lens_above - lens_h * 0.5
              (lx, ly)
            }))
            .says(By(fn() { Some(@view.said(Group, label=label())) }))
            .gesture(
              2.0,
              press=fn(d) {
                let (row, _, cx, _) = pos.untracked()
                lens_anchor.val = (d.wx, d.wy)
                lens_start.val = (cx, row.to_double() * line_h + line_h * 0.5)
              },
              drag=fn(d) {
                match d.kind {
                  Down => {
                    let (row, _, cx, _) = pos.untracked()
                    lens_anchor.val = (d.wx, d.wy)
                    lens_start.val = (cx, row.to_double() * line_h + line_h * 0.5)
                  }
                  Moved => {
                    let (awx, awy) = lens_anchor.val
                    let (sx, sy) = lens_start.val
                    update_at(sx + (d.wx - awx), sy + (d.wy - awy))
                  }
                  Up | Off => ()
                }
              },
            )
            |> ignore
            // Clipped 1.5× zoomed text & caret layer (opaque paper backdrop hides original lines behind loupe;
            // `Scroll::across` declares this as a sliding optical viewport so full-width zoomed lines neither
            // ellipsize nor trigger squeeze clipping warnings)
            lens_wrap.box(fn(zoom_clip) {
              zoom_clip
              .over(Is(true))
              .points(Is(false))
              .radius(Is(lens_r))
              .clips(Is(true))
              .ground(By(fn() { colors().paper | 0xFFL }))
              |> ignore
              zoom_clip.scrolls(@view.Scroll::across(), fn(vp) {
                vp.over(Is(true)).points(Is(false)) |> ignore
                vp.box(fn(zoom_stage) {
                  zoom_stage
                  .over(Is(true))
                  .points(Is(false))
                  .width(Is(Some(1600.0)))
                  .height(Is(Some(lines.length().to_double() * line_h_15)))
                  .offset(By(fn() {
                    let (row, _, _, cx15) = pos.get()
                    (lens_w * 0.5 - cx15, lens_h * 0.5 - (row.to_double() * line_h_15 + line_h_15 * 0.5))
                  }))
                  |> ignore
                  loupe_render_lines(zoom_stage, lines, line_h_15, look_15, loc~)
                  zoom_stage.box(fn(zcaret) {
                    zcaret
                    .over(Is(true))
                    .points(Is(false))
                    .width(Is(Some(3.5)))
                    .height(Is(Some(30.0)))
                    .radius(Is(1.75))
                    .ground(By(fn() { colors().accent }))
                    .offset(By(fn() {
                      let (row, _, _, cx15) = pos.get()
                      (cx15 - 1.75, row.to_double() * line_h_15 + 3.0)
                    }))
                    |> ignore
                  })
                  |> ignore
                })
                |> ignore
              })
              |> ignore
            })
            |> ignore
            // Single-layer clear refractive glass cap over the 1.5× zoomed text
            lens_wrap.box(fn(glass_cap) {
              glass_cap
              .over(Is(true))
              .points(Is(false))
              .radius(Is(lens_r))
              .glass(By(fn() { Some(magnifier_glass()) }))
              |> ignore
            })
            |> ignore
          })
          |> ignore
        })
        |> ignore
      })
      |> ignore
    })
    |> ignore
  })
}
