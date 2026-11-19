// A message's picture coming in as a node of the window's tree (sfpages' image_reveal, as the web's msgImageWait and
// msgImageReveal): till its host says it is decoded, what it waits on (its likeness, else the neutral ground); from the
// moment it says so, brushed in from its top (an edge half its height deep going down it, in steps), blurred to sharp
// and from 1.04 its size to its own (reveal_ms, the ease out), what it waited on fading out behind it (from 800 ms, over
// 300). All of that is laid over the picture only while it goes: at its declared end (that moment on the timeline) it
// is let go, and a picture brushed in is the same nodes and bindings as one shown as it is (decoded as it was first
// made, or `held`: the device had it). Only a picture that comes (`comes`: of a message new while it is watched) is
// brushed in; any other waits as it does and is there whole from the moment it is decoded, what it waited on let go
// then: what was said before it was shown is simply there (motion.mbt's head).

///|
/// How a picture is in its reveal: waiting (not decoded), going (brushed in), or there (as it is).
#derive(Eq)
priv enum RevealPhase {
  Waiting
  Going
  There
}

///|
/// A picture `key` (as it changes) `w()` by `h()` in `parent` (bound: the width it is given changing as the window does
/// changes its size, never its nodes, nor how it is coming in), covering it (`cover`, else contained in it), brushed in from
/// the moment its host says it is decoded; `likeness` what it waits on ("" the neutral ground; a field of a few colours,
/// a ThumbHash's, decoded once at the least size: reveal_likeness_px); `held` one the device
/// had (a decode away): as it is, no brushing; `comes`, read the moment it is decoded: whether it is brushed in then
/// (else there whole at once). `start_crop`: covering it from its start (its top, or its left), not its middle (a tall one
/// at the chat's least width, a wide strip at its least height: an old view's FitCoverFrom(0, 0), View::image_covers_at;
/// bound, as its data says it).
/// `flies`: made in a change in which it is sent, the picture flies from where it stood then, as its caller says of its
/// box (View::flies_in: its way, where from, how late its rise is, how far it goes and what leads it, with what else
/// of the same send flies), drawn on the way as it is at rest, covering the box the way has, rounded `corner` (its
/// frame's: what cuts it at rest cuts it nowhere on the way).
/// `decoded_for`: the longer side it is decoded for (the largest it is drawn at, bound), so a size that changes asks no
/// other decode; none: as it is laid out. The node.
#callsite(autofill(loc))
pub fn image_reveal_node(
  parent : @view.View,
  key : () -> String,
  likeness : () -> String,
  w : () -> Double,
  h : () -> Double,
  cover? : Bool = true,
  decoded_for? : () -> Double,
  held? : () -> Bool = fn() { false },
  comes? : () -> Bool = fn() { true },
  start_crop? : () -> Bool = fn() { false },
  flies? : ((@view.View) -> Unit)? = None,
  corner? : Double = 0.0,
  loc~ : SourceLoc,
) -> @view.View {
  parent.box(made_for=loc, fn(b) {
    // (its size, its likeness, where it is cut from and the pixels it is decoded at, kept as one value as it comes to
    // another: what is bound to them worked out again only then, not each time what they are read of is told anew, a
    // message's file said again with its size the same: value_kept)
    let kept = value_kept(b, fn() {
      let (w, h) = (w(), h())
      let px = match decoded_for {
        Some(side) => reveal_px(side(), side(), b.pixel_scale())
        None => reveal_px(w, h, b.pixel_scale())
      }
      (w, h, likeness(), start_crop(), px)
    })
    let w = fn() { kept().0 }
    let h = fn() { kept().1 }
    let likeness = fn() { kept().2 }
    let start_crop = fn() { kept().3 }
    let px = fn() { kept().4 }
    // (its size as it is made, said again as it comes to another: watched, nothing bound to it at rest)
    let (w0, h0) = @signals.untracked(fn() { (w(), h()) })
    b.width(Is(Some(w0))).height(Is(Some(h0))).clips(Is(true)) |> ignore
    b.reacts(fn() { (w(), h()) }, at_start=false, fn(size) { b.width(Is(Some(size.0))).height(Is(Some(size.1))) |> ignore })
    // (read only: its picture's node, made from the first, has its decode asked by what draws it as it comes to it, in
    // sight or outside its clip; one made and let go of before anything drew it, a page's list's block in one layout,
    // has nothing decoded)
    let ready = fn() { key() != "" && b.image_ready(key(), px()) }
    let phase = @signals.signal(Waiting)
    let way = @motion.NodeWay::new(0.0)
    // (the end of the way of the picture being brushed in, called off when it is given another)
    let ends : Ref[() -> Unit] = Ref(fn() {  })
    // (how far in, eased out, at the moment drawn: reveal's `e`)
    let e = fn() { @ui.Out.at(way.shown(b)) }
    // (the picture and what is laid over it all of its box, each a share of it: its size bound once, on it alone)
    b.box(fn(i) {
      i
      .width_share(Is(1.0))
      .height_share(Is(1.0))
      .image_covers(Is(cover))
      .image_contains(Is(!cover))
      .image_fades(Is(false))
      .scale(By(fn() { 1.0 + reveal_grow * (1.0 - e()) }))
      |> ignore
      // (its picture and where it is cut from, one binding set again as either comes to another)
      i.sets_together(
        fn() {
          (
            if key() == "" { None } else { Some((key(), "", px().to_int())) },
            if start_crop() { Some((0.0, 0.0)) } else { None },
          )
        },
        fn(now) { i.image(Is(now.0)).image_covers_at(Is(now.1)) |> ignore },
      )
      |> ignore
    })
    |> ignore
    // (flying in as a whole, what it waits on as it is decoded and the picture once it is: the box itself from the
    // first frame, never a frame with nothing on the way while it decodes)
    match flies {
      Some(fly) => fly(b.radius(Is(corner)))
      None => ()
    }
    // given a picture (as it is made, or another as its block shows another key): decoded already, or the device's,
    // there as it is; else waiting, what was brushing in for the one before let go at once
    b.reacts(key, fn(_) {
      (ends.val)()
      ends.val = fn() {  }
      if @signals.untracked(fn() { ready() || held() }) {
        way.put(1.0)
        phase.set(There)
      } else {
        way.put(0.0)
        phase.set(Waiting)
      }
    })
    // decoded, as its host says it: brushed in from that moment, over reveal_ms; what is laid over it let go of at
    // that way's declared end (a moment on the timeline), never by reading whether it still goes. One that does not
    // come there whole at that moment.
    b.reacts(ready, fn(r) {
      if r && @signals.untracked(fn() { phase.get() }) == Waiting && !@signals.untracked(comes) {
        way.put(1.0)
        phase.set(There)
      } else if r && @signals.untracked(fn() { phase.get() }) == Waiting {
        let from = b.cause_at()
        way.go_ms(b, 1.0, reveal_ms, ease=Linear)
        phase.set(Going)
        ends.val = b.at_moment(from + reveal_ms, fn() { phase.set(There) })
      }
    })
    // (all of it laid over the picture, in a layer of its own: nothing of the column's, so each is there at once)
    let layer = b.box(fn(l) { l.over(Is(true)).width_share(Is(1.0)).height_share(Is(1.0)) |> ignore })
    layer.pick(at_once=true, fn() { phase.get() }, fn(o, ph) {
      match ph {
        // (all of what it waits on)
        Waiting => reveal_wait_whole(o, likeness)
        Going => {
          // the frost over it, sharpening as it goes
          o.box(fn(f) {
            f
            .over(Is(true))
            .width(By(fn() { Some(w()) }))
            .height(By(fn() { Some(h()) }))
            .glass(By(fn() {
              let blur = reveal_blur * (1.0 - e())
              if blur > reveal_blur_least {
                Some(@ui.Glass::frosted(blur~, tint=0L, solid=0L, contained=true))
              } else {
                None
              }
            }))
            |> ignore
          })
          |> ignore
          // what it waited on: the edge, half its height deep, from above it to past its foot, in steps, fading out
          // from reveal_wait_after_ms over reveal_wait_out_ms; and all of it under the edge
          let band = fn() { h() * 0.5 }
          let step = fn() { band() / reveal_steps.to_double() }
          let p = fn() { way.shown(b) }
          let waited = fn() {
            1.0 - dmin(1.0, dmax(0.0, (p() * reveal_ms - reveal_wait_after_ms) / reveal_wait_out_ms))
          }
          let top = fn() { -band() + (h() + band()) * e() }
          // (its reveal_steps strips, made once with the layer: none comes or goes after)
          o.each(fn() { Array::makei(reveal_steps, fn(k) { k }) }, fn(k) { k }, at_once=true, fn(s, k) {
            let k = k.untracked()
            let y0 = fn() { top() + k.to_double() * step() }
            reveal_wait_strip(s, likeness, w, h, y0, fn() { y0() + step() }, fn() {
              (k.to_double() + 0.5) / reveal_steps.to_double() * waited()
            })
          })
          reveal_wait_node(o, likeness, w, h, fn() { top() + band() }, h, waited)
        }
        There => ()
      }
    })
    |> ignore
  })
}

///|
/// What a picture waits on, all of it (reveal_wait_node's from its top to its foot, at once): its likeness laid over the
/// whole of the layer it is in, as big as the picture, else the neutral ground; as shares of that layer, so a size it
/// is given anew binds nothing here.
#callsite(autofill(loc))
fn reveal_wait_whole(o : @view.View, likeness : () -> String, loc~ : SourceLoc) -> Unit {
  o.width_share(Is(1.0)).height_share(Is(1.0)) |> ignore
  o.box(made_for=loc, fn(l) {
    l
    .over(Is(true))
    .width_share(Is(1.0))
    .height_share(Is(1.0))
    // (one decode of its likeness, as each strip of it takes: reveal_likeness_px)
    .image(By(fn() { if likeness() == "" { None } else { Some((likeness(), "", reveal_likeness_px)) } }))
    .image_fades(Is(false))
    |> ignore
    style_node(l, fn() { if likeness() == "" { reveal_ground } else { reveal_clear } })
  })
  |> ignore
}

///|
/// What a picture waits on, from `y0` to `y1` of it (as it is drawn: each on the screen's pixels, one meeting the next
/// with no seam), at `alpha`: its likeness (laid from the picture's top), else the neutral ground; over it.
#callsite(autofill(loc))
fn reveal_wait_node(
  parent : @view.View,
  likeness : () -> String,
  w : () -> Double,
  h : () -> Double,
  y0 : () -> Double,
  y1 : () -> Double,
  alpha : () -> Double,
  loc~ : SourceLoc,
) -> Unit {
  parent.box(made_for=loc, fn(s) { reveal_wait_strip(s, likeness, w, h, y0, y1, alpha, loc~) }) |> ignore
}

///|
/// reveal_wait_node's strip in node `s` itself (one of an each's rows, or the box reveal_wait_node makes).
#callsite(autofill(loc))
fn reveal_wait_strip(
  s : @view.View,
  likeness : () -> String,
  w : () -> Double,
  h : () -> Double,
  y0 : () -> Double,
  y1 : () -> Double,
  alpha : () -> Double,
  loc~ : SourceLoc,
) -> Unit {
  let px_of = fn(y : Double) { (y * s.pixel_scale()).round() / s.pixel_scale() }
  let top = fn() { px_of(dmax(0.0, y0())) }
  let foot = fn() { px_of(dmin(h(), y1())) }
  s
  .over(Is(true))
  .width(By(fn() { Some(w()) }))
  .height(By(fn() { Some(dmax(0.0, foot() - top())) }))
  .offset(By(fn() { (0.0, top()) }))
  .clips(Is(true))
  .alpha(By(fn() { if foot() <= top() { 0.0 } else { alpha() } }))
  |> ignore
  // (its likeness laid from the picture's top: moved up as far as the strip is down)
  s.box(made_for=loc, fn(l) {
    l
    .width(By(fn() { Some(w()) }))
    .height(By(fn() { Some(h()) }))
    .offset(By(fn() { (0.0, -top()) }))
    // (each strip of it the one decode, not one for each size they are drawn at: reveal_likeness_px)
    .image(By(fn() { if likeness() == "" { None } else { Some((likeness(), "", reveal_likeness_px)) } }))
    .image_fades(Is(false))
    |> ignore
    style_node(l, fn() { if likeness() == "" { reveal_ground } else { reveal_clear } })
  })
  |> ignore
}

///|
/// How many pixels a message's picture `w` by `h` is decoded to on its longer side, at `scale` (reveal_px's).
fn reveal_px(w : Double, h : Double, scale : Double) -> Double {
  dmin(dmax(w, h) * scale, reveal_px_most)
}

///|
/// How long a picture takes to come in once decoded, how blurred it starts, how much larger, when what it waited on
/// starts fading and for how long, and in how many steps its edge is drawn (sfpages' image_reveal's).
pub let reveal_ms : Double = 1100.0

///|
let reveal_blur : Double = 14.0

///|
let reveal_blur_least : Double = 0.25

///|
let reveal_grow : Double = 0.04

///|
let reveal_wait_after_ms : Double = 800.0

///|
let reveal_wait_out_ms : Double = 300.0

///|
let reveal_steps : Int = 16

///|
let reveal_px_most : Double = 8192.0

///|
/// The most pixels a likeness is decoded to on its longer side: a field of a few colours (sfpages' image_wait_colours,
/// 32 on its longer side), the least size a decode is made at, so all of what waits draws the one decode however big
/// each strip of it is drawn (as each asked its own: the host held it twice through the way in).
let reveal_likeness_px : Int = 64

///|
// kept across runs: a value (no field of it changes)
let reveal_ground : @ui.Style = @ui.css("bg=Neutral")

///|
// kept across runs: a value (no field of it changes)
let reveal_clear : @ui.Style = @ui.css("bg=Clear")

///|
/// What `read` comes to, kept by node `v` as it comes to another value (View::reacts): what reads it is told only then,
/// not each time what `read` reads is told anew with it the same (a message's data said again, its size as it was).
pub fn[T : Eq] value_kept(v : @view.View, read : () -> T) -> () -> T {
  let kept = @signals.signal(@signals.untracked(read))
  v.reacts(read, fn(now) { kept.set(now) }, at_start=false)
  fn() { kept.get() }
}
