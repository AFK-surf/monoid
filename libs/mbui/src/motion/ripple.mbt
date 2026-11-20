// A press's ripple, as every Compose `clickable` on Android 12 and later draws it: Material 3's ripple() is Android's
// RippleDrawable, which is always its patterned style there (RippleDrawable FORCE_PATTERNED_STYLE; RippleAnimationSession,
// RippleShader). A soft disc of the content's colour (Compose's LocalContentColor: black unless said) at Material 3's
// pressed alpha (.1), from where the finger went down, drifting to the box's middle as it grows: its progress goes to .5
// over 450 ms (FastOutSlowIn) as the finger goes down, then on to 1 over 375 ms (linear) once it lifts and that way in
// is over (a tap however short shown whole first). The disc is at its alpha by progress .13 and fades from .4 to 1; its
// radius is 2.3 times the box's half diagonal and 10 more (Compose's bounded ripple, RippleShader.setRadius) times the
// progress, its edge soft from half that radius to half again (softCircle, blur 1: drawn here as the disc blurred, its
// middle where the edge's is). Its sparkles (white specks in the growing ring, on the clock's noise) are not drawn.
// While a finger is on it, the box it ripples sinks a little (drawn smaller about its middle, by a few points however
// large it is: press_sink), and springs back as it lifts (sf/motion.mbt kind 7, a control answering: pressed): a box
// that stands on a ground of its own (a button, a card: Ctx::own_ground), not a row lying in a list or a card, whose
// press is its ground lit (a row sunk in its card is drawn in from the card's edges, as if pressed out of it).
// Pressed by a pointer (keyboard and mouse: @ui.pointing), no disc: a pointer's press needs no telling where it landed,
// so the whole box is pressed at once, its ink over it evenly (pointer_veil_part of it) in over pointer_enter_ms and out
// over pointer_exit_ms once the button is up and that way in is over (a click however short shown whole), and a box on
// a ground of its own drawn a little smaller with it (pointer_sink_most at most; a row lying in a list or a card not).

///|
/// One press's ripple: where in its box the finger went down, how far it has gone (RippleShader's progress), when it
/// went down and whether it has lifted.
priv struct Ripple {
  x : Double
  y : Double
  progress : Anim
  at : Double
  mut lifted : Bool
  /// when the finger lifted
  mut lifted_at : Double
  /// on its way out (from .5, its way in over)
  mut leaving : Bool
}

///|
/// The ripples going, by the id of what was pressed (put back by layer.mbt's reset: a test that ended with one going
/// left it to the next Tester's box of the same id, its Anim not at rest, screens_wbtest's home-sheet, 2026-10-24).
let ripples : Map[Int, Array[Ripple]] = Map([])

///|
/// How long a ripple takes to its middle as the finger goes down.
pub let ripple_enter_ms : Double = 200.0

///|
/// How long it takes from there to gone once the finger lifts.
pub let ripple_exit_ms : Double = 150.0

///|
/// How long a tap's ripple lasts, shown whole: its way in, then out.
pub let ripple_tap_ms : Double = ripple_enter_ms + ripple_exit_ms

///|
/// One pointer's press of a box (no disc: see the file's head): how far its veil and sink are in (0 to 1), when the
/// button went down, when it went up and whether it is on its way out.
priv struct PointerPress {
  k : Anim
  at : Double
  mut lifted : Bool
  mut lifted_at : Double
  mut leaving : Bool
}

///|
/// The pointers' presses going, by the id of what was pressed (put back by layer.mbt's reset, as `ripples`).
let pointer_presses : Map[Int, PointerPress] = Map([])

///|
/// How long a pointer's press takes to show whole as the button goes down.
pub let pointer_enter_ms : Double = 70.0

///|
/// How long it takes from there to gone once the button is up (and its way in is over).
pub let pointer_exit_ms : Double = 160.0

///|
/// How long a click's press lasts, shown whole: its way in, then out.
pub let pointer_tap_ms : Double = pointer_enter_ms + pointer_exit_ms

///|
/// How far a box on a ground of its own is drawn smaller under a pointer's press, a share of it at most (as a finger's
/// sink, by press_sink across its longer side, no more than this).
pub let pointer_sink_most : Double = 0.01

///|
/// How much of the ink's alpha a pointer's press lays over the box, evenly.
pub let pointer_veil_part : Double = 0.8

///|
/// The ink a pointer's press lays over a box, whole (pointer_veil_part of `ink`'s alpha, in whole steps of 255).
pub fn pointer_veil(ink : Int64) -> Int64 {
  (ink & 0xFFFFFF00L) | ((ink & 0xFFL).to_double() * pointer_veil_part).round().to_int64()
}

///|
/// How far a box `w` by `h` is drawn smaller at most under a pointer's press, standing on a ground of its own.
pub fn pointer_sink(w : Double, h : Double) -> Double {
  dmin(pointer_sink_most, press_sink / dmax(dmax(w, h), 1.0))
}

///|
/// A ripple's colour: black at Material 3's pressed alpha (RippleDefaults: StateTokens.PressedStateLayerOpacity .1).
pub let ripple_ink : Int64 = 0x0000001AL

///|
/// How far past a box's half diagonal its ripple reaches (Compose's BoundedRippleExtraRadius, 10 dp).
let ripple_extra : Double = 10.0

///|
/// How soft a ripple's disc is, as a share of its radius: blurred so, its edge fades from about half its radius to
/// half again (RippleShader's softCircle, blur 1).
let ripple_soft : Double = 0.27

///|
/// How far below its disc a ripple's blur is put: not at all (the disc itself, not a shadow dropped under it).
let ripple_drop : Double = 0.0

///|
/// How far a box sinks under a finger: by so many points across its longer side, no more than so much of it (a
/// small button's).
pub let press_sink : Double = 4.0

///|
let press_sink_most : Double = 0.04

///|
/// The way down and back up: a spring with a little give.
// kept across runs: a value (no field of it changes)
let sink_spring : Spec = lift_spring

///|
/// The share of `p` between `a` and `b` (RippleShader subProgress).
fn sub_progress(a : Double, b : Double, p : Double) -> Double {
  (clamp(a, b, p) - a) / (b - a)
}

///|
/// What is pressed as `id` rippled as Android's `clickable` ripples (see the file's head): drawn over what the box
/// holds, cut to its corners (`corner`), in `ink` (black at .1 by default). Called in the box's body, after what it
/// holds. `out_x`, `out_y`: its ground reaches that far past the box on each side (Controls.kt pressText: a text
/// button's ground round its words, laid out as the words alone), less than the box where they are below 0 (a card's
/// row clipped LIST_PAD in); `out_top`, `out_bottom` in place of `out_y` at that side. A press however short is shown
/// whole, a tap ended before the press shows in what scrolls too.
pub fn ripple(
  c : @ui.Ctx,
  id : Int,
  corner : Double,
  ink? : Int64 = ripple_ink,
  out_x? : Double = 0.0,
  out_y? : Double = 0.0,
  out_top? : Double,
  out_bottom? : Double,
) -> Unit {
  let top = out_top.unwrap_or(out_y)
  let bottom = out_bottom.unwrap_or(out_y)
  // (the box it is called in: what sinks)
  let holder = c.building()
  if @ui.pointing() is Mouse && ripples.get(id) is None {
    pointer_press(c, id, holder, corner, ink, out_x, top, bottom)
    return
  }
  let list = match ripples.get(id) {
    Some(l) => l
    None => []
  }
  let down = c.pressed(id)
  // a finger down on it, or a tap let go before the press showed: a ripple from where it went down (watched: what
  // takes the press is what `id` is drawn for)
  if c.watch_press(id) && !list.iter().any(fn(r) { !r.lifted }) {
    let (px, py, _) = c.pointer()
    // (where it is laid this frame; a list's row, laid as the list is, after its build: where it was laid last)
    let (bx, by) = match c.laid_rect(id) {
      Some((x, y, _, _)) => (x, y)
      None =>
        match c.rect_of(id) {
          Some((x, y, _, _)) => (x, y)
          None => (px, py)
        }
    }
    let p = Anim::new(0.0)
    p.name = "ripple"
    p.animate(c, 0.5, tween(ripple_enter_ms, ease=Out))
    list.push({ x: px - bx + out_x, y: py - by + top, progress: p, at: c.moment(), lifted: false, lifted_at: 0.0, leaving: false })
    ripples[id] = list
  }
  // let go (or the press taken by a scroll): on to its end from where its way in ended, once that is over (the way
  // in's own end brings the frame that sees it)
  for r in list {
    if !down && !r.lifted {
      r.lifted = true
      r.lifted_at = c.moment()
    }
    let out_at = if r.lifted_at > r.at + ripple_enter_ms { r.lifted_at } else { r.at + ripple_enter_ms }
    if r.lifted && !r.leaving && c.moment() >= out_at {
      r.leaving = true
      r.progress.animate(c, 1.0, tween(ripple_exit_ms, ease=Leave), start_at=out_at)
    } else if r.lifted && !r.leaving {
      // (what holds it built again at that moment, as it changes then: kept_part.mbt)
      c.shows_until(out_at)
    }
  }
  // those faded away let go, by their way out's declared end, before what is drawn of the rest (built again at that
  // end: Anim::over)
  list.retain(fn(r) { !r.leaving || !r.progress.over(c) })
  if list.length() == 0 {
    ripples.remove(id)
  }
  // a finger on it (its ripple not let go): sunk a little, back as it lifts
  let on = list.iter().any(fn(r) { !r.lifted })
  // (none asked of what no finger has been on: nothing to keep for every box that ripples)
  let sink_key = "\u{2}sink/\{id}"
  // (how far it is sunk read as it is drawn: told as it is built, @motion.told)
  if c.own_ground(holder) && (on || anims.contains(c.id(sink_key))) {
    let sunk = told(c, sink_key, if on { 1.0 } else { 0.0 }, spec=sink_spring)
    match c.laid_size(id) {
      Some((bw, bh)) if bw > 0.0 && bh > 0.0 => {
        let most = dmin(press_sink_most, press_sink / dmax(bw, bh))
        c.look_by(holder, fn() { @ui.look(scale=1.0 - most * sunk.get(c)) })
      }
      _ => ()
    }
  }
  if list.length() == 0 {
    return
  }
  // (laid out once at least: what it covers, its ground past it where it reaches out)
  guard c.laid_size(id) is Some((bw, bh)) else { return }
  let w = bw + 2.0 * out_x
  let h = bh + top + bottom
  let most = ((w * w + h * h).sqrt() / 2.0 + ripple_extra) * 2.3
  // (each disc built whole, its reach all of it about the box's middle, and drawn as far as its progress has it as it
  // is painted: a look scales its corner and its blur with it, so it is the disc that reach would build)
  let across = most * 2.0
  c.layer(fn() {
    over_box(c, w, h, out_x, top, corner, fn() {
      for r in list {
        let mut disc = -1
        c.layer(fn() {
          disc = c.box(
            w=Px(across),
            h=Px(across),
            radius=most,
            tx=w / 2.0 - most,
            ty=h / 2.0 - most,
            shadow=most * ripple_soft,
            shadow_y=ripple_drop,
            shadow_color=ink,
            fn() {  },
          )
        })
        |> ignore
        let progress = r.progress
        c.look_by(disc, fn() {
          let p = progress.get(c)
          let fade = sub_progress(0.0, 0.13, p).min(1.0 - sub_progress(0.4, 1.0, p))
          let ink_alpha = (ink & 0xFFL).to_double()
          if fade <= 0.0 || p <= 0.0 || ink_alpha <= 0.0 {
            return @ui.look(alpha=0.0)
          }
          // from the finger to the middle by progress .5: drawn smaller about the point that puts its middle there (a
          // move by a look would be on whole pixels, the disc's way is not)
          let k = clamp(0.0, 1.0, p * 2.0)
          let about = fn(to : Double, mid : Double) {
            if p >= 1.0 {
              0.5
            } else {
              ((to - mid * p) / (1.0 - p) - (mid - most)) / across
            }
          }
          // (its alpha as a colour has it: in whole steps of 255)
          let alpha = (ink_alpha * fade).round() / ink_alpha
          @ui.look(alpha~, scale=p, ox=about(mix(r.x, w / 2.0, k), w / 2.0), oy=about(mix(r.y, h / 2.0, k), h / 2.0))
        })
      }
    })
    |> ignore
  })
  |> ignore
}

///|
/// `ripple`'s pointer's press (see the file's head): a press of `id` watched as a finger's is (a click let go before
/// it showed shown whole too), its way in from its moment, out from as the button is up or its way in is over,
/// whichever is later; what is drawn over the box (`holder`) as far as that way has it as each frame is painted.
fn pointer_press(
  c : @ui.Ctx,
  id : Int,
  holder : Int,
  corner : Double,
  ink : Int64,
  out_x : Double,
  top : Double,
  bottom : Double,
) -> Unit {
  let down = c.pressed(id)
  // the button down on it, or a click let go before its frame (watched: what takes the press is what `id` is drawn
  // for): its way in from where the one before had got to
  let now = pointer_presses.get(id)
  if c.watch_press(id) && (now is None || now.map(fn(p) { p.lifted }).unwrap_or(true)) {
    // (pressed again on its way out: in again from where that way has it, the same value going on)
    let k = match now {
      Some(p) => p.k
      None => {
        let k = Anim::new(0.0)
        k.name = "pointer press"
        k
      }
    }
    k.animate(c, 1.0, tween(pointer_enter_ms, ease=Out))
    pointer_presses[id] = { k, at: c.moment(), lifted: false, lifted_at: 0.0, leaving: false }
  }
  guard pointer_presses.get(id) is Some(p) else { return }
  // let go: out from then, or from its way in's end where that is later (the way in's own end brings the frame that
  // sees it)
  if !down && !p.lifted {
    p.lifted = true
    p.lifted_at = c.moment()
  }
  let out_at = dmax(p.lifted_at, p.at + pointer_enter_ms)
  if p.lifted && !p.leaving && c.moment() >= out_at {
    p.leaving = true
    p.k.animate(c, 0.0, tween(pointer_exit_ms, ease=Out), start_at=out_at)
  } else if p.lifted && !p.leaving {
    // (what holds it built again at that moment, as it changes then: kept_part.mbt)
    c.shows_until(out_at)
  }
  // gone by its way out's declared end (built again then: Anim::over)
  if p.leaving && p.k.over(c) {
    pointer_presses.remove(id)
    return
  }
  guard c.laid_size(id) is Some((bw, bh)) else { return }
  let k = p.k
  // (on a ground of its own: drawn smaller about its middle; a row lying in a list or a card, not)
  if c.own_ground(holder) {
    let most = pointer_sink(bw, bh)
    c.look_by(holder, fn() { @ui.look(scale=1.0 - most * k.get(c)) })
  }
  let w = bw + 2.0 * out_x
  let h = bh + top + bottom
  c.layer(fn() {
    over_box(c, w, h, out_x, top, corner, fn() {
      let veil = c.box(style=@ui.style(w=Full, h=Full, bg=Data(pointer_veil(ink))), fn() {  })
      c.look_by(veil, fn() { @ui.look(alpha=k.get(c)) })
    })
    |> ignore
  })
  |> ignore
}

///|
/// What a press draws over a box `w` by `h` (its ground past it by `out_x` each side, `top` over it), cut to its
/// corners `corner`: a ripple's discs, a pointer's veil.
fn over_box(c : @ui.Ctx, w : Double, h : Double, out_x : Double, top : Double, corner : Double, body : () -> Unit) -> Int {
  c.box(w=Px(w), h=Px(h), tx=-out_x, ty=-top, clip=true, radius=corner, body)
}
