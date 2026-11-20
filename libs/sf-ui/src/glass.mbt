// still.fail's glass (web mobile/styles/pages.css.ts and ui/styles/glass.ts), as
// @ui.Glass for a box's `glass=`. Haze's blur radius is cssBlur(px) = (px - 0.5) / 0.57735 dp, which RenderEffect
// takes as a deviation of px dp: CSS blur(px)'s, what @ui.Glass's blur is. Each has its solid ground for where the
// system asks for less transparency: what the glass would be with nothing under it (the page's paper under its tint).

///|
/// A bar at the top of a page over the list running under it (TopGlassBar; mGlass): the page's paper
/// at 70% over a 24px blur, no line along its foot: the frost alone sets it off (2026-10-24, asked).
pub fn glass_bar() -> @ui.Glass {
  let t = theme()
  @ui.Glass::frosted(blur=24.0, tint=alpha(t.p.bg, 0.7), solid=t.p.bg)
}

///|
/// The same glass as a band along the page's foot (Glass.kt glassFoot: a new chat's choices and composer stand on
/// it), no line.
pub fn glass_foot() -> @ui.Glass {
  glass_bar()
}

///|
/// A capsule floating over the list (mFloating, the composer's): `--raised` at 72% over a 20px
/// blur; `tint` for glass of another colour. Its breath of shadow is the box's (shadow 2, black at 30%, 0.5 down),
/// drawn outside it only.
pub fn glass_floating(tint? : Int64) -> @ui.Glass {
  let t = theme()
  let ground = alpha(tint.unwrap_or(t.p.raised), 0.72)
  @ui.Glass::frosted(blur=20.0, tint=ground, solid=over(t.p.bg, ground))
}

///|
/// The bottom bar's glass: iOS 27 regular liquid glass calibrated for 56pt controls (flutter_liquid_glass
/// ios27Light / ios27Dark: uniform 2.1pt Gaussian blur across center and rim, quarter-circle bevel refraction,
/// adaptive color transfer, inner bevel shadow, glint, and 0.75pt external contour); where glass is drawn solid,
/// its opaque ground.
pub fn glass_tab_bar(spot? : (Double, Double)? = None) -> @ui.Glass {
  let t = theme()
  // Neutral light/dark sentinel selects Apple iOS 27 ios27Light / ios27Dark color transfer model in kind == 6.
  let tint = if t.dark { 0x202020FFL } else { 0xFDFCFD67L }
  let solid = if t.dark { 0x1E1F24FFL } else { 0xFAFAFAFFL }
  @ui.Glass::liquid(
    blur=2.1,
    tint~,
    solid~,
    saturation=1.0,
    rim=0.6,
    bezel=20.0,
    refraction=28.0,
    chroma=0.0,
    merge=0.0,
    adaptive=false,
    spot~,
  )
}

///|
/// The bottom bar's shadow (kept for compatibility; prefer `tab_bar_shadow()` for light/dark separation).
pub let tab_bar_raised : Raised = { sigma: 12.0, dy: 4.0, color: 0x0000001AL }

///|
/// The bottom bar's shadow by theme: softer on light grounds, deeper on dark grounds so the capsule floats cleanly.
pub fn tab_bar_shadow() -> Raised {
  if theme().dark {
    { sigma: 12.0, dy: 5.0, color: 0x00000052L }
  } else {
    { sigma: 10.0, dy: 4.0, color: 0x00000018L }
  }
}

///|
/// The pill under the place shown inside glass: black at 7.1% on light grounds, white at 12% in the dark.
pub fn glass_selection() -> Int64 {
  if theme().dark {
    0xFFFFFF1FL
  } else {
    0x00000012L
  }
}

///|
/// The bar's ball held (the lens over the places, iOS 27 clear loupe): clear liquid glass, its rim bending the places
/// under it with subtle chromatic dispersion.
fn glass_lens() -> @ui.Glass {
  let t = theme()
  @ui.Glass::liquid(
    blur=0.0,
    tint=0xFFFFFF00L,
    solid=over(t.p.bg, alpha(t.p.raised, 0.72)),
    saturation=1.0,
    rim=0.6,
    bezel=16.0,
    refraction=12.0,
    chroma=-0.06,
    merge=0.0,
    adaptive=false,
  )
}

///|
/// A control's knob held (a switch's, a segmented choice's thumb): the bar's clear lens, its rim narrower and bending
/// less, as small as it is.
pub fn glass_knob() -> @ui.Glass {
  { ..glass_lens(), bezel: 7.0, refraction: 5.0 }
}

///|
/// Clear lifted liquid glass lens while a tab bar / segmented control thumb is held (iOS 27 clear loupe).
pub fn glass_tab_lens(press : Double) -> @ui.Glass {
  let p = dclamp(press, 0.0, 1.0)
  @ui.Glass::liquid(
    blur=0.0,
    tint=0xFFFFFF00L,
    solid=theme().p.raised,
    saturation=1.0,
    rim=0.6 * p,
    bezel=16.0 * p,
    refraction=24.0 * p,
    chroma=-0.06 * p,
    merge=0.0,
    adaptive=false,
  )
}

///|
/// Clear lifted liquid glass thumb while a toggle is held.
fn glass_toggle_lens(press : Double) -> @ui.Glass {
  let p = dclamp(press, 0.0, 1.0)
  @ui.Glass::liquid(
    blur=0.0,
    tint=0xFFFFFF00L,
    solid=0xFFFFFFFFL,
    saturation=1.0,
    rim=0.6 * p,
    bezel=8.0 * p,
    refraction=12.0 * p,
    chroma=-0.06 * p,
    merge=0.0,
    adaptive=false,
  )
}

///|
/// Clear lifted liquid glass thumb while a slider is held.
fn glass_slider_lens(press : Double) -> @ui.Glass {
  let p = dclamp(press, 0.0, 1.0)
  @ui.Glass::liquid(
    blur=0.0,
    tint=0xFFFFFF00L,
    solid=theme().p.raised,
    saturation=1.0,
    rim=0.6 * p,
    bezel=10.0 * p,
    refraction=14.0 * p,
    chroma=-0.06 * p,
    merge=0.0,
    adaptive=false,
  )
}

///|
/// The shadow under the bottom bar's lens (blur sigma 12, 4 down, black at 10%): the lens's look fades it in with
/// the lens as it is pressed.
pub let tab_lens_raised : Raised = { sigma: 12.0, dy: 4.0, color: 0x0000001AL }

///|
fn track_glass_ink() -> Int64 {
  if theme().dark { 0x7878805CL } else { 0x78787833L }
}

///|
/// How far a sheet reaches on under the window's foot (sheet_node's: its foot's corners out of sight).
let sheet_under : Double = pane_corner

///|
/// The scrim under a sheet at its fullest: black at 28%.
pub let sheet_scrim : Int64 = 0x00000047L

///|
/// A sheet over the page: the surface at 90% over a 28px blur (the scrim is drawn under it, so it is in
/// what the glass frosts, as on the web). 90%, not the 80% it was: what is written on a sheet keeps 4.5:1 whatever
/// lies under it (the accent's words, the weakest ink a sheet's words are in, over the page at its darkest, black: the
/// tint alone carries them), a sheet as tall as what it holds lying over any part of the page.
pub fn glass_sheet() -> @ui.Glass {
  let t = theme()
  @ui.Glass::frosted(blur=28.0, tint=alpha(t.p.canvas, sheet_tint), solid=t.p.bg)
}

///|
/// How much of a sheet's glass is its surface's colour (glass_sheet).
let sheet_tint : Double = 0.9

