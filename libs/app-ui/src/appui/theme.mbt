// Colour: every colour of the library worked out in OKLCH (lightness, chroma, hue: steps of lightness look like steps,
// whatever the hue), from a brand's hue and chroma the app gives (`set_theme`), light and dark. A part reads its
// colours by role (`palette()`), where it is drawn, so a change of theme or of light and dark is followed.
//
// Dark is not light turned over: what floats (a menu, a popover, a dialog: `elevated`) is a step lighter than a card
// (`panel`), which is a step lighter than the page (`canvas`), so what lies over the page never melts into it. Each
// pair of words and what they lie on, each icon and each line, is at least what mbui's contrast audit asks
// (Tester::audit: words 4.5:1, icons 3:1, a line 1.25:1).

///|
/// A colour from OKLCH: lightness `l` (0 black to 1 white), chroma `c` (0 grey, about 0.37 the most sRGB shows), hue
/// `h_deg` in degrees, at `alpha`: OKLab, then linear sRGB, each channel held to what sRGB has, then sRGB's curve.
/// `0xRRGGBBAA`.
pub fn oklch(l : Double, c : Double, h_deg : Double, alpha? : Double = 1.0) -> Int64 {
  let h = h_deg * 3.141592653589793 / 180.0
  let a = c * @dmath.cos(h)
  let b = c * @dmath.sin(h)
  let l_ = l + 0.3963377774 * a + 0.2158037573 * b
  let m_ = l - 0.1055613458 * a - 0.0638541728 * b
  let s_ = l - 0.0894841775 * a - 1.2914855480 * b
  let lc = l_ * l_ * l_
  let mc = m_ * m_ * m_
  let sc = s_ * s_ * s_
  let r = 4.0767416621 * lc - 3.3077115913 * mc + 0.2309699292 * sc
  let g = -1.2684380046 * lc + 2.6097574011 * mc - 0.3413193965 * sc
  let bl = -0.0041960863 * lc - 0.7034186147 * mc + 1.7076147010 * sc
  let ch = fn(x : Double) -> Int64 {
    let x = clamp01(x)
    let v = if x <= 0.0031308 {
      12.92 * x
    } else {
      1.055 * @dmath.pow(x, 1.0 / 2.4) - 0.055
    }
    (v * 255.0).round().to_int64().max(0L).min(255L)
  }
  let al = (clamp01(alpha) * 255.0).round().to_int64()
  (ch(r) << 24) | (ch(g) << 16) | (ch(bl) << 8) | al
}

///|
/// What a theme is made from: the brand's hue and chroma (its accent, what is on, chosen, the thing to do), and the
/// hue and chroma its greys lean to (0: neutral).
#derive(Eq, Debug)
pub(all) struct Theme {
  accent_hue : Double
  accent_chroma : Double
  gray_hue : Double
  gray_chroma : Double
}

///|
/// The theme as it starts: an indigo accent over cool, barely tinted greys.
pub let default_theme : Theme = {
  accent_hue: 268.0,
  accent_chroma: 0.17,
  gray_hue: 265.0,
  gray_chroma: 0.006,
}

///|
/// The colours of the parts, by role.
#derive(Eq, Debug)
pub(all) struct Palette {
  dark : Bool
  /// the page
  canvas : Int64
  /// a card on the page
  panel : Int64
  /// what floats over the page: a menu, a popover, a dialog (dark: a step lighter than a card)
  elevated : Int64
  /// words
  ink : Int64
  /// quieter words: a note, a time
  muted : Int64
  /// what is quieter still and no words: a meta's icon
  faint : Int64
  /// a line between rows, a card's edge
  hairline : Int64
  /// a control's edge: a secondary button's, a checkbox's
  edge : Int64
  /// the brand's: what is on, chosen, the thing to do
  accent : Int64
  /// words and marks on the accent
  on_accent : Int64
  /// a soft ground of the accent (a tag), and the accent's words on it
  accent_soft : Int64
  accent_ink : Int64
  /// what cannot be undone
  destructive : Int64
  on_destructive : Int64
  /// laid over what is pointed at, and over what is pressed (a tint: its alpha says how much)
  hover : Int64
  press : Int64
  /// the ring round what has the keyboard's focus
  focus : Int64
  /// a switch's track off, a segmented control's track, and what moves on them
  track : Int64
  thumb : Int64
  knob : Int64
  /// the shadow under what floats
  shadow : Int64
}

///|
/// The palette `t` makes, light or dark.
pub fn Theme::palette(t : Theme, dark : Bool) -> Palette {
  let g = fn(l : Double) { oklch(l, t.gray_chroma, t.gray_hue) }
  let acc = fn(l : Double, c : Double) { oklch(l, c, t.accent_hue) }
  let ac = t.accent_chroma
  if dark {
    {
      dark: true,
      canvas: g(0.17),
      panel: g(0.205),
      elevated: g(0.245),
      ink: g(0.96),
      muted: g(0.74),
      faint: g(0.6),
      hairline: g(0.33),
      edge: g(0.38),
      accent: acc(0.56, ac),
      on_accent: 0xFFFFFFFFL,
      accent_soft: acc(0.3, ac * 0.45),
      accent_ink: acc(0.86, ac * 0.6),
      destructive: oklch(0.55, 0.19, 25.0),
      on_destructive: 0xFFFFFFFFL,
      hover: 0xFFFFFF10L,
      press: 0xFFFFFF1CL,
      focus: acc(0.66, ac),
      track: g(0.14),
      thumb: g(0.33),
      knob: g(0.93),
      shadow: 0x00000066L,
    }
  } else {
    {
      dark: false,
      canvas: g(0.975),
      panel: 0xFFFFFFFFL,
      elevated: 0xFFFFFFFFL,
      ink: g(0.21),
      muted: g(0.5),
      faint: g(0.62),
      hairline: g(0.89),
      edge: g(0.84),
      accent: acc(0.53, ac),
      on_accent: 0xFFFFFFFFL,
      accent_soft: acc(0.95, ac * 0.22),
      accent_ink: acc(0.45, ac),
      destructive: oklch(0.55, 0.2, 25.0),
      on_destructive: 0xFFFFFFFFL,
      hover: 0x0000000AL,
      press: 0x00000014L,
      focus: acc(0.6, ac),
      track: g(0.915),
      thumb: 0xFFFFFFFFL,
      knob: 0xFFFFFFFFL,
      shadow: 0x0000001FL,
    }
  }
}

///|
// kept across runs: said by the app as it starts and as the person picks a brand colour
let theme_said : @signals.Signal[Theme] = @signals.signal(default_theme)

///|
// kept across runs: said by the app as it starts and as the person changes it (None: as the window is)
let dark_said : @signals.Signal[Bool?] = @signals.signal(None)

///|
/// The theme from now on.
pub fn set_theme(t : Theme) -> Unit {
  theme_said.set(t)
}

///|
/// Light or dark from now on (None: as the window is).
pub fn set_dark(dark : Bool?) -> Unit {
  dark_said.set(dark)
}

///|
/// Whether what is drawn now is drawn dark: the app's say, else the system's.
pub fn is_dark() -> Bool {
  match dark_said.get() {
    Some(d) => d
    None => @ui.system_dark()
  }
}

///|
/// The colours as a node is drawn now, read where they are drawn so they follow.
pub fn palette() -> Palette {
  theme_said.get().palette(is_dark())
}

///|
/// `share` of `a` over `b` as each is seen over anything (their colours weighed by how opaque each is): a ground going
/// from a see-through colour to a solid one passes through no darker one.
pub fn mix(a : Int64, share : Double, b : Int64) -> Int64 {
  let aa = (a & 0xFFL).to_double() / 255.0
  let ba = (b & 0xFFL).to_double() / 255.0
  let opacity = aa * share + ba * (1.0 - share)
  if opacity <= 0.0 {
    return 0L
  }
  let ch = fn(shift : Int) -> Int64 {
    let x = ((a >> shift) & 0xFFL).to_double() * aa
    let y = ((b >> shift) & 0xFFL).to_double() * ba
    ((x * share + y * (1.0 - share)) / opacity).round().to_int64().max(0L).min(255L)
  }
  (ch(24) << 24) | (ch(16) << 16) | (ch(8) << 8) | (opacity * 255.0).round().to_int64()
}

///|
/// `c` at `share` of its opacity.
pub fn alpha(c : Int64, share : Double) -> Int64 {
  let a = (c & 0xFFL).to_double() * share
  (c & 0xFFFFFF00L) | a.round().to_int64()
}

///|
/// `tint` (a colour with some alpha) laid over the opaque `under`: the colour seen.
pub fn over(tint : Int64, under : Int64) -> Int64 {
  let ta = (tint & 0xFFL).to_double() / 255.0
  let ch = fn(shift : Int) -> Int64 {
    let x = ((tint >> shift) & 0xFFL).to_double()
    let y = ((under >> shift) & 0xFFL).to_double()
    (x * ta + y * (1.0 - ta)).round().to_int64().max(0L).min(255L)
  }
  (ch(24) << 24) | (ch(16) << 16) | (ch(8) << 8) | (under & 0xFFL)
}

///|
/// mbui's theme in this library's colours: what of mbui is drawn by the theme (a field's words and caret, the focus a
/// Tester looks for) drawn in them. No corner ladder: corners are concentric, by `concentric_radius`.
pub fn ui_theme() -> @ui.Theme {
  let p = palette()
  let base = if p.dark { @ui.Theme::dark() } else { @ui.Theme::light() }
  {
    ..base,
    bg: p.canvas,
    surface: p.elevated,
    raised: p.elevated,
    card: p.panel,
    fg: p.ink,
    muted: p.muted,
    subtle: p.faint,
    faint: p.track,
    border: p.edge,
    line: p.hairline,
    field_hover: p.edge,
    accent: p.accent,
    accent_text: p.accent_ink,
    accent_bg: p.accent_soft,
    on_accent: p.on_accent,
    primary: p.accent,
    on_primary: p.on_accent,
    danger: p.destructive,
    on_danger: p.on_destructive,
    hover: p.hover,
    selected: p.accent_soft,
    focus: p.focus,
    shadow: p.shadow,
    thumb: p.knob,
    link: p.accent_ink,
    sidebar: p.canvas,
    list: p.panel,
    radius: control_radius,
    radius_lg: card_radius,
    radius_dialog: sheet_radius,
    font: Ui.size(),
    font_sm: Caption.size(),
    font_title: Title.size(),
    font_heading: Heading.size(),
    control_h: 28.0,
    focus_w: focus_ring_w,
    focus_gap: 0.0,
    corner_ladder: [],
    corner_fit: None,
    lit_apart: 0.0,
    lit_reach: 0.0,
  }
}

///|
/// How wide the focus ring is, out round a control's own edge, concentric with it.
pub let focus_ring_w : Double = 2.0

///|
/// `x` held between 0 and 1.
fn clamp01(x : Double) -> Double {
  if x < 0.0 {
    0.0
  } else if x > 1.0 {
    1.0
  } else {
    x
  }
}
