// Ported from Kyant0/AndroidLiquidGlass (Apache-2.0): catalog/components/LiquidButton.kt. A capsule of glass 48 high,
// 16 in at each side, what it holds 8 apart in its middle: what is under it made vivid (vibrancy, a saturation of 1.5),
// blurred by 2 and bent along its rim by a lens 12 deep moving it by up to 24; its tint laid on by hue first, then at
// 75%; its surface colour over that; Backdrop's default highlight and shadow. Interactive (the catalog's default), a
// finger on it lights it where it is (InteractiveHighlight) and stretches it along the way it drags. What it is to the
// hand, the keys and a screen reader is mbui's headless button's: a press, Enter or Space, Activate.

///|
/// The glass of a LiquidButton (iOS 27 liquid glass): `tint` and `surface` its colours (clear: none).
fn button_glass(tint : Int64, surface : Int64) -> @paint.Glass {
  let d = is_dark()
  let tinted = tint != clear
  let glass_tint = if tinted {
    alpha(tint, 0.75)
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
    bezel=20.0,
    refraction=24.0,
    chroma=0.0,
    merge=0.0,
    adaptive=false,
    spot=None,
  )
}

///|
/// `top` laid over `base` (source over).
pub fn over(base : Int64, top : Int64) -> Int64 {
  let ta = (top & 0xFFL).to_double() / 255.0
  let ba = (base & 0xFFL).to_double() / 255.0
  let oa = ta + ba * (1.0 - ta)
  if oa <= 0.0 {
    return clear
  }
  let ch = fn(shift : Int) -> Int64 {
    let t = ((top >> shift) & 0xFFL).to_double()
    let b = ((base >> shift) & 0xFFL).to_double()
    ((t * ta + b * ba * (1.0 - ta)) / oa).round().to_int64().max(0L).min(255L)
  }
  (ch(24) << 24) | (ch(16) << 16) | (ch(8) << 8) | (oa * 255.0).round().to_int64()
}

///|
/// A glass ground drawn moved by (`dx`, `dy`) and `sx` × `sy` times as large about its middle, a capsule still, for a
/// box laid out `w` × `h`.
fn stretched(w : Double, h : Double, dx : Double, dy : Double, sx : Double, sy : Double) -> @view.GroundShape {
  if w <= 0.0 || h <= 0.0 || (dx == 0.0 && dy == 0.0 && sx == 1.0 && sy == 1.0) {
    return @view.ground_as_laid
  }
  let dw = w * (sx - 1.0)
  let dh = h * (sy - 1.0)
  let r = (h + dh) / 2.0
  { dx: dx - dw / 2.0, dy: dy - dh / 2.0, dw, dh, corners: Some((r, r, r, r)) }
}

///|
/// A LiquidButton in `parent`, read out a button named `label`; pressed (by a tap, Enter or Space, a screen reader's
/// Activate), `press` is called. What it holds is `content`'s (by default its `label` in the catalog's 15 point words:
/// white where it is tinted, else the words' colour: the catalog's black, white in the dark). `tint`: its colour laid
/// on by hue and at 75% (clear: none); `surface`: a colour over its glass (clear: none); `flat`: content-layer fill
/// with no `Glass::liquid` (for inside Sheet / Dialog / Popover / Inspector surfaces, zero glass-on-glass);
/// `interactive`: lit and stretched by a finger on it. The node.
#callsite(autofill(loc))
pub fn liquid_button_node(
  parent : @view.View,
  label : () -> String,
  press : () -> Unit,
  content? : (@view.View) -> Unit,
  tint? : Int64 = clear,
  surface? : Int64 = clear,
  flat? : Bool = false,
  interactive? : Bool = true,
  disabled? : () -> Bool = fn() { false },
  light? : InteractiveHighlight,
  loc~ : SourceLoc,
) -> @view.View {
  @headless.button(made_for=loc, parent, label, fn(_) { press() }, disabled~, fn(b, btn) {
    let light = match light {
      Some(l) => l
      None => InteractiveHighlight::new()
    }
    light.attach(b)
    b
    .row(Is(true))
    .lines_up(Is(Some(Middle)))
    .lies_along(Is(Middle))
    .height(Is(Some(button_h)))
    .padding(Is((button_px, 0.0, button_px, 0.0)))
    .radius(Is(button_h / 2.0))
    .ground_drawn(By(fn() {
      if !interactive {
        return @view.ground_as_laid
      }
      let (w, h) = light.size.get()
      let (dx, dy, sx, sy) = light.stretch(b)
      stretched(w, h, dx, dy, sx, sy)
    }))
    .alpha(By(fn() { if btn.disabled() { 0.5 } else { 1.0 } }))
    |> ignore
    if flat {
      b
      .ground(By(fn() {
        if tint != clear {
          tint
        } else if surface != clear {
          surface
        } else if is_dark() {
          0xFFFFFF22L
        } else {
          0x00000012L
        }
      }))
      .edge(By(fn() {
        if tint != clear {
          (0.0, clear)
        } else if is_dark() {
          (0.5, 0xFFFFFF24L)
        } else {
          (0.5, 0x0000001AL)
        }
      }))
      |> ignore
    } else {
      b
      .shadow(Is(shadow_default))
      .glass(By(fn() { Some(button_glass(tint, surface)) }))
      |> ignore
    }
    b.show(fn() { btn.focus_shown() }, fn(ring) {
      ring
      .over(Is(true))
      .points(Is(false))
      .margin(Is((-3.0, -3.0, -3.0, -3.0)))
      .radius(Is(button_h / 2.0 + 3.0))
      .edge(By(fn() { (2.0, colors().accent) }))
      |> ignore
    })
    if interactive {
      // (a finger on it lights it from where it went down; a tap, or a drag let go still on it, presses it: Compose's
      // clickable beside InteractiveHighlight's own drag)
      b.gesture(
        @ui.touch_slop(),
        press=fn(d) { light.down(d.x, d.y, d.w, d.h) },
        tap=fn(_) {
          light.up()
          btn.press()
        },
        drag=fn(d) {
          match d.kind {
            Down | Moved => light.moved(d.x, d.y)
            Up => {
              light.up()
              if d.x >= 0.0 && d.x <= d.w && d.y >= 0.0 && d.y <= d.h {
                btn.press()
              }
            }
            Off => light.up()
          }
        },
      )
      |> ignore
      b.box(fn(ov) {
        ov
        .over(Is(true))
        .points(Is(false))
        .radius(Is(button_h / 2.0))
        .ground(Is(white))
        .alpha(By(fn() { clamp(light.pressed(ov), 0.0, 1.0) * 0.14 }))
        .ground_drawn(By(fn() {
          let (w, h) = light.size.get()
          let (dx, dy, sx, sy) = light.stretch(ov)
          stretched(w, h, dx, dy, sx, sy)
        }))
        |> ignore
      })
      |> ignore
    }
    // (what it holds moved and grown with its glass about its middle: the catalog's layer holds both)
    b.box(fn(c) {
      c
      .row(Is(true))
      .lines_up(Is(Some(Middle)))
      .gap(Is(button_gap))
      .offset(By(fn() {
        if interactive {
          let (dx, dy, _, _) = light.stretch(b)
          (dx, dy)
        } else {
          (0.0, 0.0)
        }
      }))
      .scale(By(fn() {
        if interactive {
          let (_, _, sx, sy) = light.stretch(b)
          (sx + sy) / 2.0
        } else {
          1.0
        }
      }))
      |> ignore
      match content {
        Some(f) => f(c)
        None =>
          c.box(fn(w) {
            w
            .words(By(label), look=words_at(15.0))
            .ink(By(fn() { if tint != clear { white } else { colors().content } }))
            |> ignore
          })
          |> ignore
      }
    })
    |> ignore
  })
}
