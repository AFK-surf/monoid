// Design tokens, glass recipes, geometry constants and pure vector icon shapes for the
// controls & inputs family (Track A: icon button, button group, segmented control, text field,
// search bar, checkbox, radio group, stepper, chip, badge, count badge).
// All private items are prefixed with `ctrl_` to avoid symbol collisions across tracks.

// ---------------------------------------------------------------------------
// Button sizes (pt)
// ---------------------------------------------------------------------------

///|
let ctrl_btn_sm : Double = 36.0

///|
let ctrl_btn_md : Double = 44.0

///|
let ctrl_btn_lg : Double = 52.0

///|
let ctrl_group_pad : Double = 4.0

///|
let ctrl_group_item_gap : Double = 2.0

///|
let ctrl_divider_ratio : Double = 0.48

///|
let ctrl_hairline_w : Double = 1.0

// ---------------------------------------------------------------------------
// Segmented control sizes (pt)
// ---------------------------------------------------------------------------

///|
let ctrl_seg_pad : Double = 3.0

///|
let ctrl_seg_held_scale : Double = 1.06

///|
let ctrl_seg_px : Double = 12.0

// ---------------------------------------------------------------------------
// Input & search bar sizes (pt)
// ---------------------------------------------------------------------------

///|
let ctrl_input_h : Double = 44.0

///|
let ctrl_input_r : Double = 22.0

///|
let ctrl_input_px : Double = 11.0

///|
let ctrl_input_gap : Double = 8.0

///|
let ctrl_field_gap : Double = 6.0

///|
let ctrl_clear_size : Double = 22.0

///|
let ctrl_clear_icon_size : Double = 12.0

///|
let ctrl_search_icon_size : Double = 16.0

///|
let ctrl_search_trailing_gap : Double = 10.0

///|
let ctrl_input_focus_edge_w : Double = 1.5

// ---------------------------------------------------------------------------
// Selection controls sizes (pt)
// ---------------------------------------------------------------------------

///|
let ctrl_check_size : Double = 22.0

///|
let ctrl_check_radius : Double = 7.0

///|
let ctrl_check_gap : Double = 10.0

///|
let ctrl_radio_size : Double = 22.0

///|
let ctrl_radio_dot : Double = 8.0

///|
let ctrl_radio_row_gap : Double = 16.0

///|
let ctrl_radio_col_gap : Double = 10.0

///|
let ctrl_stepper_h : Double = 36.0

///|
let ctrl_stepper_btn_w : Double = 42.0

///|
let ctrl_stepper_gap : Double = 10.0

///|
let ctrl_stepper_val_min_w : Double = 28.0

///|
let ctrl_stepper_icon_size : Double = 14.0

///|
let ctrl_chip_h : Double = 32.0

///|
let ctrl_chip_r : Double = 16.0

///|
let ctrl_chip_px : Double = 12.0

///|
let ctrl_chip_pad_rm : Double = 4.0

///|
let ctrl_chip_rm_size : Double = 24.0

///|
let ctrl_chip_gap : Double = 6.0

///|
let ctrl_badge_h : Double = 24.0

///|
let ctrl_badge_r : Double = 12.0

///|
let ctrl_badge_px : Double = 10.0

///|
let ctrl_badge_gap : Double = 6.0

///|
let ctrl_badge_dot : Double = 6.0

///|
let ctrl_count_h : Double = 22.0

///|
let ctrl_count_r : Double = 11.0

///|
let ctrl_count_px : Double = 7.0

// ---------------------------------------------------------------------------
// Focus, opacity & typography
// ---------------------------------------------------------------------------

///|
let ctrl_focus_outset : Double = 3.0

///|
let ctrl_focus_w : Double = 2.0

///|
let ctrl_disabled_alpha : Double = 0.45

///|
let ctrl_press_glow_alpha : Double = 0.14

///|
let ctrl_hover_alpha : Double = 0.08

///|
let ctrl_type_body : Double = 15.0

///|
let ctrl_type_label : Double = 13.0

///|
let ctrl_type_caption : Double = 12.0

///|
let ctrl_type_chip : Double = 13.0

///|
let ctrl_type_seg : Double = 14.0

///|
let ctrl_type_badge : Double = 12.0

///|
let ctrl_type_count : Double = 12.0

///|
let ctrl_weight_semibold : Int = 600

// ---------------------------------------------------------------------------
// Colours (light & dark, WCAG >= 4.5:1 verified against solid fallbacks)
// ---------------------------------------------------------------------------

///|
fn ctrl_hover_ink() -> Int64 {
  if is_dark() {
    white
  } else {
    black
  }
}

///|
fn ctrl_divider_ink() -> Int64 {
  if is_dark() {
    0xFFFFFF29L
  } else {
    0x0000001FL
  }
}

///|
fn ctrl_muted_ink() -> Int64 {
  if is_dark() {
    0xC8C8CEFFL
  } else {
    0x1C1C1EFFL
  }
}

///|
fn ctrl_placeholder_ink() -> Int64 {
  if is_dark() {
    0x8E8E93FFL
  } else {
    0x6E6E73FFL
  }
}

///|
fn ctrl_input_edge_ink() -> Int64 {
  if is_dark() {
    0xFFFFFF26L
  } else {
    0x0000001CL
  }
}

///|
fn ctrl_clear_bg() -> Int64 {
  if is_dark() {
    0xFFFFFF29L
  } else {
    0x0000001CL
  }
}

///|
fn ctrl_clear_ink() -> Int64 {
  if is_dark() {
    0xF2F2F7FFL
  } else {
    0x3A3A3CFFL
  }
}

///|
fn ctrl_danger_ink() -> Int64 {
  if is_dark() {
    0xFF6961FFL
  } else {
    0xB42318FFL
  }
}

///|
fn ctrl_seg_thumb_idle() -> Int64 {
  if is_dark() {
    0x38383EFFL
  } else {
    0xFFFFFFFFL
  }
}

///|
fn ctrl_seg_inactive_ink() -> Int64 {
  if is_dark() {
    0xC8C8CEFFL
  } else {
    0x3A3A3EFFL
  }
}

///|
fn ctrl_check_border_ink() -> Int64 {
  if is_dark() {
    0xFFFFFF4DL
  } else {
    0x00000038L
  }
}

///|
fn ctrl_chip_selected_tint() -> Int64 {
  if is_dark() {
    0x0066D6FFL
  } else {
    0x0058CCFFL
  }
}

///|
/// Semantic tone palette for `liquid_badge_node`: (translucent_pill_bg, solid_bg, fg_ink, dot_ink).
/// Light/airy translucent capsule fills harmonized with surrounding Liquid Glass (WCAG >= 4.5:1).
fn ctrl_badge_palette(tone : LiquidTone) -> (Int64, Int64, Int64, Int64) {
  let d = is_dark()
  match tone {
    Neutral =>
      if d {
        (0x28282E9EL, 0x242428FFL, 0xF2F2F7FFL, 0xAEAEB2FFL)
      } else {
        (0xFFFFFFB8L, 0xF2F2F7FFL, 0x1C1C1EFFL, 0x6E6E73FFL)
      }
    Accent =>
      if d {
        (0x0E2E529EL, 0x132842FFL, 0x7CC4FFFFL, 0x4DA6FFFFL)
      } else {
        (0xE6F1FFC4L, 0xE6F1FFFFL, 0x004099FFL, 0x0070F3FFL)
      }
    Success =>
      if d {
        (0x0F331E9EL, 0x112E1CFFL, 0x6CE38DFFL, 0x34C759FFL)
      } else {
        (0xE6F7EBC4L, 0xE6F7EBFFL, 0x0B5320FFL, 0x248A3DFFL)
      }
    Warning =>
      if d {
        (0x3B290A9EL, 0x33240DFFL, 0xFFCC66FFL, 0xFF9F0AFFL)
      } else {
        (0xFFF4E0C4L, 0xFFF4E0FFL, 0x6E3B00FFL, 0xD97706FFL)
      }
    Danger =>
      if d {
        (0x4216199EL, 0x3B1618FFL, 0xFF8A8AFFL, 0xFF453AFFL)
      } else {
        (0xFFEBEBC4L, 0xFFEBEBFFL, 0x981B12FFL, 0xD92D20FFL)
      }
  }
}

///|
/// Semantic tone palette for `liquid_count_badge_node`: (glass_tint, solid_bg, fg_ink).
fn ctrl_count_palette(tone : LiquidTone) -> (Int64, Int64, Int64) {
  let d = is_dark()
  match tone {
    Neutral =>
      if d {
        (0x48484EE0L, 0x48484EFFL, white)
      } else {
        (0x48484AE0L, 0x48484AFFL, white)
      }
    Accent => (0x0058CCE0L, 0x0058CCFFL, white)
    Success => (0x197B30E0L, 0x197B30FFL, white)
    Warning => (0x9A5B00E0L, 0x9A5B00FFL, white)
    Danger => (0xC92A2AE0L, 0xC92A2AFFL, white)
  }
}

// ---------------------------------------------------------------------------
// Glass recipes (iOS 27 @paint.Glass::liquid — single layer, zero glass-on-glass)
// ---------------------------------------------------------------------------

///|
fn ctrl_surface_glass(tint : Int64, surface : Int64, bezel? : Double = 18.0, refraction? : Double = 22.0) -> @paint.Glass {
  let d = is_dark()
  let tinted = tint != clear
  let glass_tint = if tinted {
    alpha(tint, 0.78)
  } else if d {
    0x202020FFL
  } else {
    0xFDFCFD67L
  }
  let solid = if tinted {
    tint
  } else if surface != clear {
    over(colors().dialog_container, surface)
  } else if d {
    0x1E1F24FFL
  } else {
    0xFAFAFAFFL
  }
  @paint.Glass::liquid(
    blur=2.1,
    tint=glass_tint,
    solid~,
    saturation=1.0,
    rim=0.6,
    bezel~,
    refraction~,
    chroma=0.0,
    merge=0.0,
    adaptive=false,
    spot=None,
  )
}

///|
fn ctrl_segmented_track_glass() -> @paint.Glass {
  let d = is_dark()
  @paint.Glass::liquid(
    blur=2.1,
    tint=if d { 0x1C1C20E0L } else { 0xF2F2F580L },
    solid=if d { 0x1E1F24FFL } else { 0xEEEEF2FFL },
    saturation=1.0,
    rim=0.55,
    bezel=16.0,
    refraction=20.0,
    chroma=0.0,
    merge=0.0,
    adaptive=false,
    spot=None,
  )
}

///|
fn ctrl_segmented_lens_glass(p : Double) -> @paint.Glass {
  let p = clamp(p, 0.0, 1.0)
  let c = colors()
  @paint.Glass::liquid(
    blur=0.0,
    tint=0xFFFFFF00L,
    solid=alpha(c.container, 1.0 / 0.4),
    saturation=1.0,
    rim=0.6 * p,
    bezel=12.0 * p,
    refraction=18.0 * p,
    chroma=-0.05 * p,
    merge=0.0,
    adaptive=false,
    spot=None,
  )
}

///|
fn ctrl_input_glass() -> @paint.Glass {
  let d = is_dark()
  @paint.Glass::liquid(
    blur=2.1,
    tint=if d { 0x1E1E24D8L } else { 0xFFFFFF99L },
    solid=if d { 0x1E1F24FFL } else { 0xFAFAFAFFL },
    saturation=1.0,
    rim=0.5,
    bezel=16.0,
    refraction=18.0,
    chroma=0.0,
    merge=0.0,
    adaptive=false,
    spot=None,
  )
}

///|
/// Content-layer checkbox/radio fill colour (zero `Glass::liquid` so forms nest safely inside sheets & lists).
fn ctrl_check_bg(filled : Bool, tint : Int64) -> Int64 {
  if filled {
    if tint != clear {
      tint
    } else {
      ctrl_chip_selected_tint()
    }
  } else if is_dark() {
    0xFFFFFF18L
  } else {
    0xFFFFFFC8L
  }
}

///|
/// Subtle 0.5pt hairline edge for content-layer semantic badges.
fn ctrl_badge_edge_ink() -> Int64 {
  if is_dark() {
    0xFFFFFF24L
  } else {
    0x00000018L
  }
}

///|
let ctrl_badge_edge_w : Double = 0.5

// ---------------------------------------------------------------------------
// Pure vector icon shapes (@paint.shape_of)
// ---------------------------------------------------------------------------

///|
/// Vector `×` icon centered in a `size × size` box.
fn ctrl_close_shapes(size : Double, ink : Int64) -> Array[@paint.Shape] {
  let m = size * 0.28
  let hi = size - m
  let w = clamp(size * 0.14, 1.4, 2.2)
  [
    @paint.shape_of([([m, m, hi, hi], false)], stroke=ink, width=w),
    @paint.shape_of([([hi, m, m, hi], false)], stroke=ink, width=w),
  ]
}

///|
/// Vector magnifying glass icon centered in a `size × size` box.
fn ctrl_search_shapes(size : Double, ink : Int64) -> Array[@paint.Shape] {
  let cx = size * 0.43
  let cy = size * 0.43
  let r = size * 0.27
  let steps = 20
  let ring : Array[Double] = []
  let two_pi = 6.283185307179586
  for i in 0..<steps {
    let a = two_pi * i.to_double() / steps.to_double()
    ring.push(cx + r * @dmath.cos(a))
    ring.push(cy + r * @dmath.sin(a))
  }
  let diag = r * 0.7071067811865476
  let hx0 = cx + diag
  let hy0 = cy + diag
  let hx1 = size * 0.85
  let hy1 = size * 0.85
  let w = clamp(size * 0.11, 1.4, 2.0)
  [
    @paint.shape_of([(ring, true)], stroke=ink, width=w),
    @paint.shape_of([([hx0, hy0, hx1, hy1], false)], stroke=ink, width=w),
  ]
}

///|
/// Vector checkmark icon centered in a `size × size` box.
fn ctrl_check_shapes(size : Double, ink : Int64) -> Array[@paint.Shape] {
  let pts : Array[Double] = [
    size * 0.24,
    size * 0.52,
    size * 0.43,
    size * 0.71,
    size * 0.78,
    size * 0.30,
  ]
  [@paint.shape_of([(pts, false)], stroke=ink, width=clamp(size * 0.11, 1.8, 2.4))]
}

///|
/// Vector minus/indeterminate dash icon centered in a `size × size` box.
fn ctrl_minus_shapes(size : Double, ink : Int64) -> Array[@paint.Shape] {
  let y = size * 0.5
  let pts : Array[Double] = [size * 0.24, y, size * 0.76, y]
  [@paint.shape_of([(pts, false)], stroke=ink, width=clamp(size * 0.12, 1.6, 2.2))]
}

///|
/// Vector plus icon centered in a `size × size` box.
fn ctrl_plus_shapes(size : Double, ink : Int64) -> Array[@paint.Shape] {
  let c = size * 0.5
  let lo = size * 0.22
  let hi = size * 0.78
  let w = clamp(size * 0.12, 1.6, 2.2)
  [
    @paint.shape_of([([lo, c, hi, c], false)], stroke=ink, width=w),
    @paint.shape_of([([c, lo, c, hi], false)], stroke=ink, width=w),
  ]
}
