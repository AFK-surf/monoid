// Ported from Kyant0/AndroidLiquidGlass (Apache-2.0): catalog/destinations/ControlCenterContent.kt. The control
// center's glass: tiles 68 across (two of them and the 16 between for a wide or tall one), their corners half of that,
// what is under them made vivid and bent by a lens 24 deep moving it by up to 48 with depth, no shadow, their highlight
// Default along `angle` (the catalog's gravity's; 45 the top left's) falling off by 2, black at 5% over them; what a
// tile holds, capsules 56 across, white at 20% or the accent when on, the airplane's icon in white at 80%. A finger on a
// tile lights it where it is (InteractiveHighlight), as a LiquidButton's.

///|
/// A tile's glass (iOS 27 regular liquid glass).
fn tile_glass(angle : Double) -> @paint.Glass {
  ignore(angle)
  let d = is_dark()
  @paint.Glass::liquid(
    blur=2.1,
    tint=if d { 0x202020FFL } else { 0xFDFCFD67L },
    solid=over(colors().dialog_container, tile_container),
    saturation=1.0,
    rim=0.6,
    bezel=20.0,
    refraction=34.0,
    chroma=0.0,
    merge=0.0,
    adaptive=false,
    spot=None,
  )
}

///|
/// The airplane's icon (FlightIcon) in `parent`, `size` across, in `ink`.
#callsite(autofill(loc))
pub fn flight_icon(parent : @view.View, size : Double, ink : () -> Int64, loc~ : SourceLoc) -> Unit {
  parent.box(made_for=loc, fn(i) {
    i
    .width(Is(Some(size)))
    .height(Is(Some(size)))
    .shrink(Is(0.0))
    .lines_up(Is(Some(Middle)))
    .lies_along(Is(Middle))
    |> ignore
    // (the glyph 0.6 of the box and its line 0.84 of it: the icon, 0.8 of the box as the catalog paints it, kept in it)
    i.box(fn(w) { w.words(Is("✈"), look={ ..words_at(size * 0.6), line: size * 0.84 }).ink(By(ink)) |> ignore }) |> ignore
  })
  |> ignore
}

///|
/// A card of the control center's glass in `parent`, `w` × `h`, its corners `radius` (by default half its shorter
/// side's of a tile: 34), its highlight along `angle`; what it holds `content`'s. Read out a button named `label` and
/// lit by a finger where `press` is given (pressed, `press` is called); else read out a group named `label`. The node.
#callsite(autofill(loc))
pub fn liquid_card_node(
  parent : @view.View,
  w : Double,
  h : Double,
  label : () -> String,
  content? : (@view.View) -> Unit = fn(_) {  },
  radius? : Double = tile_size / 2.0,
  angle? : Double = 45.0,
  press? : () -> Unit,
  light? : InteractiveHighlight,
  loc~ : SourceLoc,
) -> @view.View {
  let ih = match light {
    Some(l) => l
    None => InteractiveHighlight::new()
  }
  let look = fn(c : @view.View) {
    ih.attach(c)
    c
    .width(Is(Some(w)))
    .height(Is(Some(h)))
    .shrink(Is(0.0))
    .radius(Is(radius))
    .glass(By(fn() { Some(tile_glass(angle)) }))
    |> ignore
    c.box(fn(ov) {
      ov
      .over(Is(true))
      .points(Is(false))
      .radius(Is(radius))
      .ground(Is(white))
      .alpha(By(fn() { clamp(ih.pressed(ov), 0.0, 1.0) * 0.14 }))
      |> ignore
    })
    |> ignore
    content(c)
  }
  match press {
    Some(f) =>
      @headless.button(made_for=loc, parent, label, fn(_) { f() }, fn(c, btn) {
        look(c)
        c.gesture(
          @ui.touch_slop(),
          press=fn(d) { ih.down(d.x, d.y, w, h) },
          tap=fn(_) {
            ih.up()
            btn.press()
          },
          drag=fn(d) {
            match d.kind {
              Down | Moved => ih.moved(d.x, d.y)
              Up => {
                ih.up()
                if d.x >= 0.0 && d.x <= d.w && d.y >= 0.0 && d.y <= d.h {
                  btn.press()
                }
              }
              Off => ih.up()
            }
          },
        )
        |> ignore
      })
    None =>
      parent.box(made_for=loc, fn(c) {
        look(c)
        c.says(By(fn() { Some(@view.said(Group, label=label())) })) |> ignore
      })
  }
}

///|
/// A control center tile in `parent`: a card 68 across holding the airplane's icon in white, 0.8 of it; pressed,
/// `press` is called. Read out a button named `label`. The node.
#callsite(autofill(loc))
pub fn liquid_control_tile_node(
  parent : @view.View,
  label : () -> String,
  press : () -> Unit,
  angle? : Double = 45.0,
  loc~ : SourceLoc,
) -> @view.View {
  liquid_card_node(loc~, parent, tile_size, tile_size, label, angle~, press~, content=fn(c) {
    c.lines_up(Is(Some(Middle))).lies_along(Is(Middle)) |> ignore
    flight_icon(c, tile_size * 0.8, fn() { white })
  })
}

///|
/// What a control center's tile holds that turns something on: a capsule 56 across, white at 20% or the accent while
/// `on`, the airplane's icon in white at 0.8 of it; pressed, `turn` is told what it turns to. Read out a switch named
/// `label`. The node.
#callsite(autofill(loc))
pub fn liquid_control_item_node(
  parent : @view.View,
  on : () -> Bool,
  turn : (Bool) -> Unit,
  label : () -> String,
  loc~ : SourceLoc,
) -> @view.View {
  @headless.toggle(made_for=loc, parent, Switch, label, on, turn, fn(c, sw) {
    c
    .width(Is(Some(tile_inner)))
    .height(Is(Some(tile_inner)))
    .shrink(Is(0.0))
    .radius(Is(tile_inner / 2.0))
    .lines_up(Is(Some(Middle)))
    .lies_along(Is(Middle))
    .ground(By(fn() { if sw.on() { colors().accent } else { tile_inactive } }))
    |> ignore
    flight_icon(c, tile_inner * 0.8, fn() { white })
    c.show(fn() { sw.focus_shown() }, fn(ring) {
      ring
      .over(Is(true))
      .margin(Is((-3.0, -3.0, -3.0, -3.0)))
      .radius(Is(tile_inner / 2.0 + 3.0))
      .edge(By(fn() { (2.0, white) }))
      |> ignore
    })
  })
}
