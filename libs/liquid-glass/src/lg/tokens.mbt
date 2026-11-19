// Ported from Kyant0/AndroidLiquidGlass (Apache-2.0): the catalog's colours, sizes and type, light and dark, each as
// the catalog's own component or page writes it (LiquidButton.kt, LiquidToggle.kt, LiquidSlider.kt,
// LiquidBottomTabs.kt, DialogContent.kt, ControlCenterContent.kt, ProgressiveBlurContent.kt, MagnifierContent.kt),
// as the window's tree reads them. Colours are 0xRRGGBBAA; a Compose `Color(0xFFrrggbb).copy(a)` is rrggbb at a × 255.

///|
/// Light or dark as the app says (None: as mbui's window is, its theme's `dark`).
// kept across runs: said by the app as it starts and as the person changes it
let dark_said : @signals.Signal[Bool?] = @signals.signal(None)

///|
/// Light or dark from now on (None: as the window is).
pub fn set_dark(dark : Bool?) -> Unit {
  dark_said.set(dark)
}

///|
/// Whether what is drawn now is drawn dark (the catalog's `!isSystemInDarkTheme()` turned round): the app's say, else
/// the window's.
pub fn is_dark() -> Bool {
  match dark_said.get() {
    Some(d) => d
    None => @ui.tree_theme().dark
  }
}

///|
/// The catalog's colours in one look (light or dark).
pub(all) struct Colors {
  /// LiquidSlider's, LiquidBottomTabs', DialogContent's, ControlCenterContent's accentColor
  accent : Int64
  /// LiquidToggle's accentColor
  toggle_on : Int64
  /// LiquidToggle's and LiquidSlider's trackColor
  track : Int64
  /// LiquidBottomTabs' containerColor
  container : Int64
  /// DialogContent's containerColor
  dialog_container : Int64
  /// DialogContent's dimColor
  scrim : Int64
  /// DialogContent's, ProgressiveBlurContent's, MagnifierContent's contentColor
  content : Int64
  /// LiquidBottomTabs' lens's idle surface (Black or White at 10%)
  lens_idle : Int64
  /// ProgressiveBlurContent's tintColor
  blur_tint : Int64
  /// MagnifierContent's backgroundColor at 90%
  paper : Int64
}

///|
/// The light look's colours.
pub let light : Colors = {
  accent: 0x0088FFFFL,
  toggle_on: 0x34C759FFL,
  track: 0x78787833L,
  container: 0xFAFAFA66L,
  dialog_container: 0xFAFAFA99L,
  scrim: 0x29293A3BL,
  content: 0x000000FFL,
  lens_idle: 0x0000001AL,
  blur_tint: 0xFFFFFFFFL,
  paper: 0xFFFFFFE6L,
}

///|
/// The dark look's colours.
pub let dark : Colors = {
  accent: 0x0091FFFFL,
  toggle_on: 0x30D158FFL,
  track: 0x7878805CL,
  container: 0x12121266L,
  dialog_container: 0x12121266L,
  scrim: 0x1212128FL,
  content: 0xFFFFFFFFL,
  lens_idle: 0xFFFFFF1AL,
  blur_tint: 0x808080FFL,
  paper: 0x121212E6L,
}

///|
/// The colours as a node is drawn now (light or dark: is_dark), read where they are drawn so they follow.
pub fn colors() -> Colors {
  if is_dark() {
    dark
  } else {
    light
  }
}

///|
/// White, as a thumb's surface at rest and an accent button's words are.
pub let white : Int64 = 0xFFFFFFFFL

///|
/// Black, a pressed bottom tab lens's 3% surface is of.
pub let black : Int64 = 0x000000FFL

///|
/// Nothing at all.
pub let clear : Int64 = 0x00000000L

///|
/// ControlCenterContent's containerColor: black at 5%.
pub let tile_container : Int64 = 0x0000000DL

///|
/// ControlCenterContent's inactiveItemColor: white at 20%.
pub let tile_inactive : Int64 = 0xFFFFFF33L

///|
/// ControlCenterContent's dimColor: black at 40% (the page under the control center).
pub let tile_dim : Int64 = 0x00000066L

///|
/// Backdrop's Shadow.Default (Shadow.kt): radius 24, its offset a sixth of that down, black at 10%; drawn as mbui's
/// shadow by its deviation, half the radius (the blur's radius as a Gaussian's deviation, as still.fail's lens has it).
pub let shadow_default : (Double, Double, Int64) = (12.0, 4.0, 0x0000001AL)

///|
/// LiquidToggle's and LiquidSlider's thumb's Shadow: radius 4, black at 5%, a sixth of it down.
pub let shadow_thumb : (Double, Double, Int64) = (2.0, 4.0 / 6.0, 0x0000000DL)

///|
/// No shadow.
pub let shadow_none : (Double, Double, Int64) = (0.0, 0.0, 0x00000000L)

// Sizes (dp, mbui's points), each the catalog's.

///|
/// LiquidButton: 48 high, 16 in at each side, 8 between what it holds.
pub let button_h : Double = 48.0

///|
pub let button_px : Double = 16.0

///|
pub let button_gap : Double = 8.0

///|
/// LiquidToggle: its track 64 × 28, its thumb 40 × 24, 2 in, dragged 20 from end to end, 1.5 times as large held.
pub let toggle_w : Double = 64.0

///|
pub let toggle_h : Double = 28.0

///|
pub let thumb_w : Double = 40.0

///|
pub let thumb_h : Double = 24.0

///|
pub let toggle_pad : Double = 2.0

///|
pub let toggle_drag : Double = 20.0

///|
pub let thumb_held_scale : Double = 1.5

///|
/// LiquidSlider: its track 6 high.
pub let slider_track_h : Double = 6.0

///|
/// LiquidBottomTabs: 64 high, 4 in, its lens 56 high and 78 / 56 times as large held, its tabs 1.2 times.
pub let tabs_h : Double = 64.0

///|
pub let tabs_pad : Double = 4.0

///|
pub let tab_lens_h : Double = 56.0

///|
pub let tab_lens_held_scale : Double = 78.0 / 56.0

///|
pub let tab_held_scale : Double = 1.2

///|
/// DialogContent: 40 round it, its corners 48.
pub let dialog_inset : Double = 40.0

///|
pub let dialog_radius : Double = 48.0

///|
/// ControlCenterContent: a tile 68 across, 16 apart, its corners half of it; what a tile holds 56 across.
pub let tile_size : Double = 68.0

///|
pub let tile_gap : Double = 16.0

///|
pub let tile_inner : Double = 56.0

///|
/// AdaptiveLuminanceGlassContent: 160 across, its corners 24.
pub let adaptive_size : Double = 160.0

///|
pub let adaptive_radius : Double = 24.0

///|
/// MagnifierContent: the lens 128 × 96, 80 over the cursor; the cursor 4 × 24; its page 24 in, its corners 32.
pub let magnifier_w : Double = 128.0

///|
pub let magnifier_h : Double = 96.0

///|
pub let magnifier_over : Double = 80.0

///|
pub let cursor_w : Double = 4.0

///|
pub let cursor_h : Double = 24.0

///|
pub let page_pad : Double = 24.0

///|
pub let page_radius : Double = 32.0

///|
/// ProgressiveBlurContent: its band 128 high, blurred 4, the tint over 80% of it.
pub let blur_band_h : Double = 128.0

///|
pub let blur_band_blur : Double = 4.0

///|
pub let blur_band_tint : Double = 0.8

// Type (sp, mbui's points): the catalog's BasicText styles.

///|
/// Words `size` high at `weight`, on one line unless `wrap` (at most `lines` of them where `lines` > 0).
pub fn words_at(size : Double, weight? : Int = 400, wrap? : Bool = false, lines? : Int = 0) -> @view.WordsLook {
  { size, weight, line: size * 1.4, wrap, tracking: Points(0.0), balance: false, max_lines: lines }
}

///|
/// A button's, a dialog's buttons' and the luminance's words: 16.
pub let type_body : Double = 16.0

///|
/// A dialog's words: 15.
pub let type_dialog_text : Double = 15.0

///|
/// A dialog's title: 24, medium.
pub let type_title : Double = 24.0

///|
/// A tab's name: 12.
pub let type_tab : Double = 12.0

///|
/// Compose's medium weight.
pub let weight_medium : Int = 500

///|
/// mbui's theme in the catalog's look: its words and accent, no corner ladder (the catalog's corners are its own:
/// capsules, a dialog's 48, a tile's 34).
pub fn ui_theme() -> @ui.Theme {
  let d = is_dark()
  let c = colors()
  let base = if d { @ui.Theme::dark() } else { @ui.Theme::light() }
  { ..base, fg: c.content, accent: c.accent, focus: c.accent, corner_ladder: [], corner_fit: None }
}

///|
/// `c` at `share` of its opacity.
pub fn alpha(c : Int64, share : Double) -> Int64 {
  let a = (c & 0xFFL).to_double() * clamp(share, 0.0, 1.0)
  (c & 0xFFFFFF00L) | a.round().to_int64()
}

///|
/// `x` held within `lo` … `hi` (Kotlin's coerceIn).
pub fn clamp(x : Double, lo : Double, hi : Double) -> Double {
  if x < lo {
    lo
  } else if x > hi {
    hi
  } else {
    x
  }
}

///|
/// `a` to `b` by `f` (Compose's lerp of floats).
pub fn lerp(a : Double, b : Double, f : Double) -> Double {
  a + (b - a) * f
}

///|
/// Compose's lerp of two colours (Color.kt: through Oklab, alpha straight), `f` of the way from `a` to `b`.
pub fn lerp_color(a : Int64, b : Int64, f : Double) -> Int64 {
  let (al, aa, ab) = oklab_of(a)
  let (bl, ba, bb) = oklab_of(b)
  let alpha_a = (a & 0xFFL).to_double() / 255.0
  let alpha_b = (b & 0xFFL).to_double() / 255.0
  let (r, g, bl2) = srgb_of(lerp(al, bl, f), lerp(aa, ba, f), lerp(ab, bb, f))
  let ch = fn(x : Double) -> Int64 { (clamp(x, 0.0, 1.0) * 255.0).round().to_int64() }
  (ch(r) << 24) | (ch(g) << 16) | (ch(bl2) << 8) | ch(lerp(alpha_a, alpha_b, f))
}

///|
fn to_linear(c : Double) -> Double {
  if c <= 0.04045 {
    c / 12.92
  } else {
    @dmath.pow((c + 0.055) / 1.055, 2.4)
  }
}

///|
fn to_gamma(c : Double) -> Double {
  if c <= 0.0031308 {
    c * 12.92
  } else {
    1.055 * @dmath.pow(c, 1.0 / 2.4) - 0.055
  }
}

///|
fn cbrt(x : Double) -> Double {
  if x < 0.0 {
    -@dmath.pow(-x, 1.0 / 3.0)
  } else {
    @dmath.pow(x, 1.0 / 3.0)
  }
}

///|
/// Oklab (Björn Ottosson's) of an 0xRRGGBBAA colour.
fn oklab_of(c : Int64) -> (Double, Double, Double) {
  let r = to_linear(((c >> 24) & 0xFFL).to_double() / 255.0)
  let g = to_linear(((c >> 16) & 0xFFL).to_double() / 255.0)
  let b = to_linear(((c >> 8) & 0xFFL).to_double() / 255.0)
  let l = cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b)
  let m = cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b)
  let s = cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b)
  (
    0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s,
    1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s,
    0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s,
  )
}

///|
/// sRGB (0-1 each) of an Oklab colour.
fn srgb_of(l : Double, a : Double, b : Double) -> (Double, Double, Double) {
  let l_ = l + 0.3963377774 * a + 0.2158037573 * b
  let m_ = l - 0.1055613458 * a - 0.0638541728 * b
  let s_ = l - 0.0894841775 * a - 1.2914855480 * b
  let (l3, m3, s3) = (l_ * l_ * l_, m_ * m_ * m_, s_ * s_ * s_)
  (
    to_gamma(4.0767416621 * l3 - 3.3077115913 * m3 + 0.2309699292 * s3),
    to_gamma(-1.2684380046 * l3 + 2.6097574011 * m3 - 0.3413193965 * s3),
    to_gamma(-0.0041960863 * l3 - 0.7034186147 * m3 + 1.7076147010 * s3),
  )
}
