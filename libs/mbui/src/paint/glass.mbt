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
  // zero for the meniscus, one for Backdrop’s default highlight, two for ambient
  backdrop_highlight : Int
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
  }
}


///|
/// A single rounded Backdrop lens with Kyant’s circular refraction and optional dispersion.
pub fn Glass::backdrop_lens(
  height~ : Double,
  amount~ : Double,
  blur~ : Double,
  tint~ : Int64,
  solid~ : Int64,
  highlight~ : Double,
  ambient? : Bool = false,
  dispersion? : Bool = false,
) -> Glass {
  {
    ..Glass::liquid(blur~, tint~, solid~, saturation=1.0, rim=highlight, bezel=height,
      refraction=amount, chroma=if dispersion { 1.0 } else { 0.0 }, merge=0.0, adaptive=false),
    backdrop_highlight: if ambient { 2 } else { 1 },
  }
}
