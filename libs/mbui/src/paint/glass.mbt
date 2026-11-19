// Glass, as it is said (what is drawn of it, its capture and its run, is the host's: ui's glass.mbt).


///|
/// How a glass box looks. `blur` is CSS blur()'s deviation, in logical px;
/// `tint` is laid over the frost (its alpha how much); `saturation` as CSS
/// saturate(); `solid` is the ground drawn instead where the system asks for
/// less transparency (or MBUI_GLASS=solid).
#derive(Eq, Debug)
pub(all) struct Glass {
  blur : Double
  tint : Int64
  saturation : Double
  solid : Int64
  // the rim, frosted: a hairline inside the edge, light along the top and
  // left, less along the foot and right (white's alpha each)
  rim_edge : Double
  rim_lit : Double
  rim_back : Double
  // liquid
  liquid : Bool
  rim : Double
  bezel : Double
  refraction : Double
  chroma : Double
  merge : Double
  adaptive : Bool
  // frosted: frosts what the glass before it frosts (its capture), not what
  // has been drawn since
  shares_capture : Bool
  // frosted: frosts only what is under its own box, its edges carried on
  // past them (CSS backdrop-filter's), so nothing round it bleeds in at its
  // rim: a picture's frost (a message's image coming in)
  contained : Bool
  // liquid: where the pointer is over it, in points from its own top left (View::pointer_here's), a light drawn
  // there along its rim and over its face; None: none
  spot : (Double, Double)?
  // zero for the meniscus, one for Backdrop’s default highlight, two for ambient, three for plain
  backdrop_highlight : Int
  // a Backdrop lens's (Glass::backdrop_lens; none of the rest's): ColorFilter.kt colorControls' brightness and
  // contrast (its saturation `saturation`), Lens.kt's depthEffect, its highlight's angle (degrees) and falloff
  // (HighlightStyle.Default's), its tint laid on by hue first (LiquidButton's), how much its spot (`spot`) lights
  // (InteractiveHighlight's press, 0-1), its InnerShadow a whole radius lower (InnerShadow.kt's default), not a sixth
  brightness : Double
  contrast : Double
  depth_effect : Bool
  highlight_angle : Double
  highlight_falloff : Double
  tint_hue : Bool
  spot_alpha : Double
  inner_shadow_full : Bool
}

///|
/// The highlight round a Backdrop lens's rim (HighlightStyle.kt): Default white added, brightest along `angle`;
/// Ambient lit along one side, shaded along the other; Plain white at 38% all round.
#derive(Eq, Debug)
pub(all) enum BackdropHighlight {
  Default
  Ambient
  Plain
}

///|
/// Frosted glass: what is under it blurred by `blur` (CSS px), `tint` over it.
pub fn Glass::frosted(
  blur~ : Double,
  tint~ : Int64,
  solid~ : Int64,
  saturation? : Double = 1.0,
  rim_edge? : Double = 0.0,
  rim_lit? : Double = 0.0,
  rim_back? : Double = 0.0,
  shares_capture? : Bool = false,
  contained? : Bool = false,
) -> Glass {
  {
    blur,
    tint,
    saturation,
    solid,
    rim_edge,
    rim_lit,
    rim_back,
    liquid: false,
    rim: 0.0,
    bezel: 0.0,
    refraction: 0.0,
    chroma: 0.0,
    merge: 0.0,
    adaptive: false,
    shares_capture,
    contained,
    spot: None,
    backdrop_highlight: 0,
    brightness: 0.0,
    contrast: 1.0,
    depth_effect: false,
    highlight_angle: 45.0,
    highlight_falloff: 1.0,
    tint_hue: false,
    spot_alpha: 0.0,
    inner_shadow_full: false,
  }
}

///|
/// The same glass frosting what the glass painted before it in this frame frosts (its capture, at that glass's
/// blur), whatever has been drawn since, over that glass too: a ball over a bar, both of the page under them.
pub fn Glass::sharing(self : Glass) -> Glass {
  { ..self, shares_capture: true }
}

///|
/// Liquid glass: nearly clear, what is under it bent along its rim (a bezel
/// `bezel` wide moving it by up to `refraction` px, the colours split by
/// `chroma`), a light rim, text in it inked by what is under it
/// (`adaptive`); shapes of one `glass_group` within `merge` of each other
/// flow into one; `spot`, where the pointer is over it (points from its
/// top left), lights its rim and face round that point.
pub fn Glass::liquid(
  blur? : Double = 1.0,
  tint? : Int64 = 0xFFFFFF1AL,
  solid? : Int64 = 0xECECF0FFL,
  saturation? : Double = 1.3,
  rim? : Double = 0.55,
  bezel? : Double = 14.0,
  refraction? : Double = 9.0,
  chroma? : Double = 0.18,
  merge? : Double = 16.0,
  adaptive? : Bool = true,
  spot? : (Double, Double)? = None,
) -> Glass {
  {
    blur,
    tint,
    saturation,
    solid,
    rim_edge: 0.0,
    rim_lit: 0.0,
    rim_back: 0.0,
    liquid: true,
    rim,
    bezel,
    refraction,
    chroma,
    merge,
    adaptive,
    shares_capture: false,
    contained: false,
    spot,
    backdrop_highlight: 0,
    brightness: 0.0,
    contrast: 1.0,
    depth_effect: false,
    highlight_angle: 45.0,
    highlight_falloff: 1.0,
    tint_hue: false,
    spot_alpha: 0.0,
    inner_shadow_full: false,
  }
}


///|
/// A single rounded Backdrop lens (AndroidLiquidGlass's drawBackdrop) with Kyant’s circular refraction (Lens.kt: `height`
/// its refractionHeight, `amount` its refractionAmount, `depth_effect` its depthEffect, `dispersion` its
/// chromaticAberration), each corner its own where its box has them; what it sees made `saturation`, `brightness` and
/// `contrast` (ColorFilter.kt's colorControls: vibrancy() is a saturation of 1.5) before `tint` is laid over it, by hue
/// first where `tint_hue` (LiquidButton's tint: BlendMode.Hue, then the tint at its own alpha, 0.75 there); `spot`,
/// where a finger is on it (points from its top left), lit by `spot_alpha` (InteractiveHighlight's press: 8% white over
/// it all and 15% round the finger, as far as one and a half times its shorter side); `inner_shadow` the radius of its
/// InnerShadow (black at 15% times `highlight`, a sixth of the radius lower, the whole radius where
/// `inner_shadow_full`, InnerShadow.kt's default; 0 none); its highlight `highlight` strong (`style`: Default, unless
/// `ambient` says Ambient), a Default one brightest along `highlight_angle` (degrees: 45 the top left's and the foot
/// right's) and falling off as `highlight_falloff` says. As the renderers have them (glass.mbt's head says how they
/// are packed): saturation and contrast to a thousandth, brightness a 63rd, the angle a 126th of a turn, the falloff a
/// half; where it has a spot, it a 127th of its size across and down, how much a 63rd, and the shadow's radius in fours.
pub fn Glass::backdrop_lens(
  height~ : Double,
  amount~ : Double,
  blur~ : Double,
  tint~ : Int64,
  solid~ : Int64,
  highlight~ : Double,
  ambient? : Bool = false,
  dispersion? : Bool = false,
  inner_shadow? : Double = 0.0,
  style? : BackdropHighlight? = None,
  saturation? : Double = 1.0,
  brightness? : Double = 0.0,
  contrast? : Double = 1.0,
  depth_effect? : Bool = false,
  highlight_angle? : Double = 45.0,
  highlight_falloff? : Double = 1.0,
  tint_hue? : Bool = false,
  spot? : (Double, Double)? = None,
  spot_alpha? : Double = 0.0,
  inner_shadow_full? : Bool = false,
) -> Glass {
  let style = match style {
    Some(s) => s
    None => if ambient { Ambient } else { Default }
  }
  {
    ..Glass::liquid(blur~, tint~, solid~, saturation~, rim=highlight, bezel=height, refraction=amount,
      chroma=if dispersion { 1.0 } else { 0.0 }, merge=inner_shadow, adaptive=false, spot~),
    backdrop_highlight: match style {
      Default => 1
      Ambient => 2
      Plain => 3
    },
    brightness,
    contrast,
    depth_effect,
    highlight_angle,
    highlight_falloff,
    tint_hue,
    spot_alpha,
    inner_shadow_full,
  }
}
