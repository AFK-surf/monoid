// A progress bar as nodes of the window's tree (progress's, @kit.progress with @kit.progress_look_of): how far, drawn
// to a value told anew over progress_ms on the ease-out, from where it is at that moment (from not known, there at once); while how far is not known, a
// piece 40% of it sweeping across, eased there and back once a period (a wait, View::cycle); becoming known, that
// piece's ends drawn into the part come over progress_known_ms (and back), each set out at its cause, sampled as each
// frame is drawn while it goes.

///|
/// A progress bar in `parent`, as wide as it is given, `h` high: how far `part` says (0 to 1; None: not known), on
/// `track` in `fill` (each as it changes). Read out as a progress bar, how far as a share and as a number of 100 (none
/// while it is not known), as the old one is (@kit.progress). `finishing`: what it counts is all there and what is done
/// with it last is under way (uploaded, being taken in): full, a soft light running along it once a period (still, full,
/// with motion reduced), never the not-known piece. The node.
#callsite(autofill(loc))
pub fn progress_node(
  parent : @view.View,
  part : () -> Double?,
  track : () -> Int64,
  fill : () -> Int64,
  h? : Double = 3.0,
  period? : Double = @motion.progress_sweep_ms,
  finishing? : () -> Bool = fn() { false },
  loc~ : SourceLoc,
) -> @view.View {
  // (how far, drawn to it as told; whether it is known, drawn into it as it becomes so: each from where it is, there
  // at once as it is made; finishing, all of it)
  // (each a motion's way: there at once with motion reduced, as the old one's Anim is)
  let told = fn() { if finishing() { Some(1.0) } else { part() } }
  let first = @signals.untracked(told)
  let at = @motion.NodeWay::new(first.unwrap_or(0.0))
  let known = @motion.NodeWay::new(if first is Some(_) { 1.0 } else { 0.0 })
  parent.box(made_for=loc, fn(bar) {
    bar
    .row(Is(true))
    .height(Is(Some(h)))
    .radius(Is(h / 2.0))
    .ground(By(track))
    // (its part cut to it at its round ends, as the old one's track cuts it: @kit.progress_look_of's clip)
    .clips(Is(true))
    |> ignore
    // (what it is to a screen reader the headless progress bar's, on this node: how far as a share and as a number of
    // 100, none while it is not known; finishing, read whole as it is drawn)
    @headless.progress(
      bar,
      fn() { part().map(fn(k) { k * 100.0 }) },
      fn(_, _) {  },
      finishing~,
      in_node=true,
      made_for=loc,
    )
    |> ignore
    bar.reacts(told, fn(p) {
      match p {
        Some(k) => {
          // (known, told anew: from where it is drawn; coming from not known, there at once, what ran along it drawn
          // into it, as the old one's part come is laid out as told and reshaped only while known)
          if @signals.untracked(fn() { known.target() }) >= 1.0 {
            at.go_ms(bar, k, @motion.progress_ms, ease=Out)
          } else {
            at.put(k)
          }
          known.go_ms(bar, 1.0, @motion.progress_known_ms, ease=InOut)
        }
        None => known.go_ms(bar, 0.0, @motion.progress_known_ms, ease=InOut)
      }
    })
    // (the part drawn, from `lo` to `hi` of the track, as of when it is drawn)
    let span = fn() -> (Double, Double) {
      let k = at.shown(bar)
      let b = known.shown(bar)
      if b >= 1.0 {
        return (0.0, k)
      }
      // (where the sweep is (motion reduced: 0.3 of the way), eased in and out; the piece from -40% to all the way
      // across)
      let f = if @ui.reduced_motion() {
        0.3
      } else {
        0.5 - 0.5 * @dmath.cos(3.141592653589793 * bar.cycle(period))
      }
      let start = -0.4 + 1.4 * f
      let s0 = if start > 0.0 { start } else { 0.0 }
      let s1 = if start + 0.4 > 1.0 { 1.0 } else { start + 0.4 }
      (s0 + (0.0 - s0) * b, s1 + (k - s1) * b)
    }
    // (in from the track's start as far as the part's start, then the part)
    bar.box(fn(before) {
      before.width_share(By(fn() { span().0 })) |> ignore
    })
    |> ignore
    bar.box(fn(piece) {
      piece
      .height(Is(Some(h)))
      .radius(Is(h / 2.0))
      .ground(By(fill))
      .width_share(By(fn() {
        let (lo, hi) = span()
        if hi > lo {
          hi - lo
        } else {
          0.0
        }
      }))
      |> ignore
    })
    |> ignore
    // (finishing: a light over the full part, a band a third as wide running across it once a period, faded in as it
    // comes on at the start and out as it leaves at the end; while it shows, a wait drawn by View::cycle, nothing of it
    // made else)
    bar.show(fn() { finishing() && !@ui.reduced_motion() }, at_once=true, fn(o) {
      o.over(Is(true)).row(Is(true)) |> ignore
      let wave = fn() -> (Double, Double, Double) {
        let f = bar.cycle(period)
        let start = -progress_wave_w + (1.0 + progress_wave_w) * f
        let lo = if start > 0.0 { start } else { 0.0 }
        let hi = if start + progress_wave_w < 1.0 { start + progress_wave_w } else { 1.0 }
        (lo, hi, @dmath.sin(3.141592653589793 * f))
      }
      o.box(fn(before) { before.width_share(By(fn() { wave().0 })) |> ignore }) |> ignore
      o.box(fn(band) {
        band
        .height(Is(Some(h)))
        .radius(Is(h / 2.0))
        .width_share(By(fn() {
          let (lo, hi, _) = wave()
          if hi > lo {
            hi - lo
          } else {
            0.0
          }
        }))
        .ground(By(fn() { alpha(0xFFFFFFFFL, progress_wave_light * wave().2) }))
        |> ignore
      })
      |> ignore
    })
  })
}

///|
/// A finishing bar's running light: how wide a share of it, and how bright at its brightest.
let progress_wave_w : Double = 0.35

///|
let progress_wave_light : Double = 0.45
