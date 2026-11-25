// Liquid Glass overlay recipes and solid-fallback edge tokens.

///|
/// Three-anchor continuous optical interpolation for iOS 27.0 in-place liquid-droplet popover morphing:
/// - `stage == 0.0`: bar-pill anchor (`a=0x67`, `blur=1.2`, `bezel=14`, `refr=20`, `rim=0.60`, `chroma=0`);
/// - `stage == 0.5`: mid-flight translucent droplet (`a=0x74`, `blur=6.0`, `bezel=18`, `refr=18`, `rim=0.68`, `chroma=0`);
/// - `stage == 1.0`: resting menu anchor, `liquid_panel_glass`'s recipe (`a=0x80`, `blur=14.0`, `bezel=20`, `refr=16`,
///   `rim=0.60`, `chroma=0`).
/// Light and dark share every anchor; only the tint's RGB (`0xFDFCFD` / `0x202020`) differs.
pub fn liquid_menu_morph_glass(
  stage : Double,
  solid? : Int64 = clear,
  dark? : Bool,
  merge? : Double = 0.0,
  layer? : Int = 0,
  break_gap? : Double = 0.0,
) -> @paint.Glass {
  let s = clamp(stage, 0.0, 1.0)
  let d = match dark {
    Some(v) => v
    None => is_dark()
  }
  let base_rgb = if d { 0x20202000L } else { 0xFDFCFD00L }
  let (a_f, blur, bezel, refraction, rim) = if s <= 0.5 {
    let u = s * 2.0
    (
      103.0 + (116.0 - 103.0) * u,
      1.2 + (6.0 - 1.2) * u,
      14.0 + (18.0 - 14.0) * u,
      20.0 + (18.0 - 20.0) * u,
      0.60 + (0.68 - 0.60) * u,
    )
  } else {
    let u = (s - 0.5) * 2.0
    (
      116.0 + (128.0 - 116.0) * u,
      6.0 + (14.0 - 6.0) * u,
      18.0 + (20.0 - 18.0) * u,
      18.0 + (16.0 - 18.0) * u,
      0.68 + (0.60 - 0.68) * u,
    )
  }
  let a = a_f.round().to_int64() & 0xFFL
  let resolved_solid = if solid != clear {
    solid
  } else if d {
    0x1C1C1EFFL
  } else {
    0xF7F7FAFFL
  }
  @paint.Glass::liquid(
    blur~,
    tint=base_rgb | a,
    solid=resolved_solid,
    saturation=1.0,
    rim~,
    bezel~,
    refraction~,
    chroma=0.0,
    merge~,
    layer~,
    break_gap~,
    adaptive=false,
  )
}

///|
/// Liquid glass material for floating panels (Menu, Popover, List, Disclosure).
/// The unified overlay recipe: symmetric 50% liquid glass (`0xFDFCFD80L` light / `0x20202080L` dark), `blur=14.0`,
/// `20/16` bevel refraction and no dispersion (`chroma=0`), the resting anchor of `liquid_menu_morph_glass`.
pub fn liquid_panel_glass(solid? : Int64 = clear) -> @paint.Glass {
  let d = is_dark()
  @paint.Glass::liquid(
    blur=14.0,
    tint=if d { 0x20202080L } else { 0xFDFCFD80L },
    solid=if solid != clear { solid } else if d { 0x1C1C1EFFL } else { 0xF7F7FAFFL },
    saturation=1.0,
    rim=0.6,
    bezel=20.0,
    refraction=16.0,
    chroma=0.0,
    merge=0.0,
    adaptive=false,
  )
}

///|
/// Liquid glass material for modal dialogs and dialog shells.
/// The unified overlay recipe with a deeper bevel: symmetric 50% liquid glass (`0xFDFCFD80L` light / `0x20202080L`
/// dark), `blur=14.0`, `22/18` bevel refraction, `rim=0.65`, no dispersion. Secondary words on it in the dark take
/// the controls' `dialog_lead` ink (muted three quarters of the way to the words' own), which keeps >= 4.5:1.
pub fn liquid_dialog_glass(solid? : Int64 = clear) -> @paint.Glass {
  let d = is_dark()
  @paint.Glass::liquid(
    blur=14.0,
    tint=if d { 0x20202080L } else { 0xFDFCFD80L },
    solid=if solid != clear { solid } else if d { 0x1C1C1EFFL } else { 0xF7F7FAFFL },
    saturation=1.0,
    rim=0.65,
    bezel=22.0,
    refraction=18.0,
    chroma=0.0,
    merge=0.0,
    adaptive=false,
  )
}

///|
/// Liquid glass material for detached floating sheets and action sheets.
/// Symmetric 80% dense liquid glass (`0xFDFCFDCCL` light / `0x202020CCL` dark), `blur=14.0`, `20/20` bevel refraction,
/// no dispersion: dense enough for multi-line forms and reading surfaces over vivid content while sharing the unified
/// overlay optical pipeline.
pub fn liquid_sheet_glass(solid? : Int64 = clear) -> @paint.Glass {
  let d = is_dark()
  @paint.Glass::liquid(
    blur=14.0,
    tint=if d { 0x202020CCL } else { 0xFDFCFDCCL },
    solid=if solid != clear { solid } else if d { 0x1C1C1EFFL } else { 0xF7F7FAFFL },
    saturation=1.0,
    rim=0.6,
    bezel=20.0,
    refraction=20.0,
    chroma=0.0,
    merge=0.0,
    adaptive=false,
  )
}

///|
/// Liquid glass material for floating island side drawers (`r=28pt`, 10pt outer margin).
/// Symmetric 80% dense liquid glass (`0xFDFCFDCCL` light / `0x202020CCL` dark), `blur=14.0`, `22/22` bevel refraction,
/// no dispersion.
pub fn liquid_drawer_glass(solid? : Int64 = clear) -> @paint.Glass {
  let d = is_dark()
  @paint.Glass::liquid(
    blur=14.0,
    tint=if d { 0x202020CCL } else { 0xFDFCFDCCL },
    solid=if solid != clear { solid } else if d { 0x1C1C1EFFL } else { 0xF7F7FAFFL },
    saturation=1.0,
    rim=0.6,
    bezel=22.0,
    refraction=22.0,
    chroma=0.0,
    merge=0.0,
    adaptive=false,
  )
}

///|
/// Liquid glass material for floating toast capsules (`blur=12.0`, symmetric 50% tint, `14/14` bevel, no dispersion).
pub fn liquid_toast_glass(solid? : Int64 = clear) -> @paint.Glass {
  let d = is_dark()
  @paint.Glass::liquid(
    blur=12.0,
    tint=if d { 0x20202080L } else { 0xFDFCFD80L },
    solid=if solid != clear { solid } else if d { 0x1E1F24FFL } else { 0xFAFAFAFFL },
    saturation=1.0,
    rim=0.6,
    bezel=14.0,
    refraction=14.0,
    chroma=0.0,
    merge=0.0,
    adaptive=false,
  )
}

///|
/// Liquid glass material for capsule surfaces (Tooltip, capsule overlays).
pub fn liquid_capsule_glass(solid? : Int64 = clear) -> @paint.Glass {
  let d = is_dark()
  @paint.Glass::liquid(
    blur=3.0,
    tint=if d { 0x20202067L } else { 0xFDFCFD67L },
    solid=if solid != clear { solid } else if d { 0x1E1F24FFL } else { 0xFAFAFAFFL },
    saturation=1.0,
    rim=0.6,
    bezel=16.0,
    refraction=24.0,
    chroma=0.0,
    merge=0.0,
    adaptive=false,
  )
}

///|
/// Progressive blur soft scroll-edge backdrop (iOS 26 `UIScrollEdgeEffect.soft`): progressive variable blur
/// across the host node's `View::fades` band (`blur=8.5`, `progressive=true`),
/// degrading to a solid `bg` alpha fade under `MBUI_GLASS=solid`.
///
/// When `pure=true` (default across all scroll-edge bars), emits zero tint (`tint=clear`, `saturation=1.0`) so
/// scrolled photos/videos/cards are never washed out by a light/dark scrim veil; bare text/icons rely on
/// `View::adaptive_ink` for contrast. When `pure=false` (explicit low-level opt-in), applies a 50% `bg` tint veil.
pub fn liquid_scroll_edge_glass(bg? : Int64 = clear, pure? : Bool = true) -> @paint.Glass {
  let resolved = if bg != clear {
    bg
  } else if is_dark() {
    0x121212FFL
  } else {
    0xFFFFFFFFL
  }
  @paint.Glass::frosted(
    blur=8.5,
    tint=if pure { clear } else { alpha(resolved, 0.50) },
    solid=resolved,
    saturation=if pure { 1.0 } else { 1.25 },
    progressive=true,
  )
}

///|
/// 1pt hairline border used when `MBUI_GLASS=solid` degrades a floating glass overlay to opaque solid.
pub fn liquid_overlay_solid_edge() -> (Double, Int64) {
  if is_dark() { (1.0, 0xFFFFFF24L) } else { (1.0, 0x00000018L) }
}

///|
/// Default panel / popover corner radius (pt) for `liquid_panel_shell_node`.
let ovl_popover_radius : Double = 22.0
