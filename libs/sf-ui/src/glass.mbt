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
/// The bar's ball held (the lens over the places, iOS 26's tab bar's): liquid glass, nearly clear, its rim bending
/// the places under it; a touch of the page's paper so it reads as glass in both themes.
fn glass_lens() -> @ui.Glass {
  let t = theme()
  @ui.Glass::liquid(
    blur=0.0,
    tint=alpha(t.p.raised, if t.dark { 0.04 } else { 0.08 }),
    solid=over(t.p.bg, alpha(t.p.raised, 0.72)),
    bezel=16.0,
    refraction=12.0,
    chroma=0.08,
    adaptive=false,
  )
}

///|
/// A control's knob held (a switch's, a segmented choice's thumb: iOS 26's): the bar's lens, its rim narrower and
/// bending less, as small as it is.
pub fn glass_knob() -> @ui.Glass {
  { ..glass_lens(), bezel: 7.0, refraction: 5.0 }
}

///|
/// AndroidLiquidGlass’s LiquidToggle material. The white surface recedes through its press spring.
fn backdrop_toggle(press : Double) -> @ui.Glass {
  let p = dclamp(press, 0.0, 1.0)
  @ui.Glass::backdrop_lens(height=5.0 * p, amount=10.0 * p, blur=8.0 * (1.0 - p),
    tint=alpha(0xFFFFFFFFL, 1.0 - p), solid=0xFFFFFFFFL, highlight=p, ambient=true, dispersion=true)
}

///|
/// AndroidLiquidGlass’s LiquidSlider material (used by the model effort slider).
fn backdrop_slider(press : Double) -> @ui.Glass {
  let p = dclamp(press, 0.0, 1.0)
  @ui.Glass::backdrop_lens(height=10.0 * p, amount=14.0 * p, blur=8.0 * (1.0 - p),
    tint=alpha(0xFFFFFFFFL, 1.0 - p), solid=theme().p.raised, highlight=p, ambient=true, dispersion=true)
}

///|
/// The bottom bar's lifted selection lens while held: clear Backdrop lens with dispersion, depth effect and inner
/// shadow (its outer shadow is `tab_lens_raised`).
pub fn backdrop_tab(press : Double) -> @ui.Glass {
  let p = dclamp(press, 0.0, 1.0)
  let idle = if theme().dark { 0xFFFFFFFFL } else { 0x000000FFL }
  let tint = over(alpha(idle, 0.1 * (1.0 - p)), alpha(0x000000FFL, 0.03 * p))
  @ui.Glass::backdrop_lens(
    height=12.0 * p,
    amount=18.0 * p,
    blur=0.0,
    tint~,
    solid=theme().p.raised,
    highlight=p,
    dispersion=true,
    depth_effect=true,
    inner_shadow=8.0 * p,
  )
}

///|
/// The shadow under the bottom bar's lens (LiquidBottomTabs' Shadow: Backdrop's own, a blur of radius 24, a
/// deviation of 12, 4 down, black at 10%): the lens's look fades it in with the lens as it is pressed.
pub let tab_lens_raised : Raised = { sigma: 12.0, dy: 4.0, color: 0x0000001AL }

///|
fn backdrop_track_ink() -> Int64 {
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

