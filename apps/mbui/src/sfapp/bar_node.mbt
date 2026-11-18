// The phone's bottom bar drawn as nodes of the window's tree (bar.mbt's model and its ways), in its glass's node
// (bar_glass_node: where it is laid out, what takes a finger on it): laid out where it is told (bar_tell: BarLaid), each
// of its numbers read where it is as each frame is drawn (View::drawn_while) while the ways it is drawn by go, where they
// went once they are there (the clock no longer followed); told again as the bar is told anew (bar_said). What moves is
// drawn so, nothing laid out for it (src/motion's rule): the bar going down and coming back, drawn up out from under a
// finger, the glass's top as the panel opens, the notch opening and its places moving with it, the action growing and
// its icon swapping, the ball, its lens, each place lighting up, a bar chosen landing.

///|
/// Said each time the bar is told what it goes by (bar_tell, bar_retell, bar_reset): its ways set out anew, what waits
/// on them told again (bar_node's said_moving).
// kept across runs: a count whose changes alone are read (what reads it read again), never its value
let bar_said : @signals.Signal[Int] = @signals.signal(0, same=fn(a, b) { a == b })

///|
/// The parts of the bar each drawn by ways of their own, told apart: what reads one part's ways is read again only as
/// its ways are told anew, not as another's are (the bar going down under a page wakes its holder alone).
priv enum BarPart {
  /// the bar shown and drawn up (vis, up): its holder
  Vis
  /// the notch, as the panel and the rise close it too (k, o, up, a bar chosen landing): the glass's notch, the action's
  /// disc, the places' places, a bar chosen landing
  Notch
  /// the panel alone (o, whether it is open, a bar chosen landing): the glass's top, its shadow, the panel's rows
  Panel
  /// the ball (where across and down, held, how faint and large): the ball, its lens
  Ball
  /// each place lit (tints)
  Tints
  /// the notch's icon and its swap
  Icon
}

///|
/// Each part said as it is told anew (bar_said_again), in BarPart's order.
// kept across runs: counts whose changes alone are read (what reads them read again), never their values
let bar_parts_said : Array[@signals.Signal[Int]] = [
  @signals.signal(0, same=fn(a, b) { a == b }),
  @signals.signal(0, same=fn(a, b) { a == b }),
  @signals.signal(0, same=fn(a, b) { a == b }),
  @signals.signal(0, same=fn(a, b) { a == b }),
  @signals.signal(0, same=fn(a, b) { a == b }),
  @signals.signal(0, same=fn(a, b) { a == b }),
]

///|
/// What each part's ways were last told, as text (bar_part_told), in BarPart's order.
// kept across runs: said again each time the bar is told (bar_said_again), emptied by bar_reset's
let bar_parts_told : Array[String] = ["", "", "", "", "", ""]

///|
fn BarPart::ord(self : BarPart) -> Int {
  match self {
    Vis => 0
    Notch => 1
    Ball => 2
    Tints => 3
    Icon => 4
    Panel => 5
  }
}

///|
/// Part `p` read as it is told anew (bar_parts_said).
fn bar_part_said(p : BarPart) -> Unit {
  bar_parts_said[p.ord()].get() |> ignore
}

///|
fn spr_told(s : Spr) -> String {
  "\{s.to} \{s.end()} \{s.set_at};"
}

///|
fn glide_told(g : Glide) -> String {
  "\{g.target} \{g.start} \{g.dur};"
}

///|
/// What part `p`'s ways are told now, as text: changed only as they are told anew.
fn bar_part_told(p : BarPart) -> String {
  let m = bar
  match p {
    Vis => glide_told(m.vis) + spr_told(m.up)
    Notch => {
      let swap = match m.swap {
        Some(s) => "\{s.i} \{s.ends}"
        None => ""
      }
      spr_told(m.k) + spr_told(m.o) + spr_told(m.up) + "\{m.mode.untracked()} " + swap
    }
    Ball =>
      spr_told(m.ball_x) +
      spr_told(m.ball_y) +
      spr_told(m.held) +
      glide_told(m.ball_alpha) +
      glide_told(m.ball_scale)
    Tints => {
      let out = StringBuilder()
      for id, g in m.tints {
        out.write_string(id)
        out.write_string(glide_told(g))
      }
      out.to_string()
    }
    Icon => m_face.val + " " + m.icon_was + " " + glide_told(m.icon_swap)
    Panel => {
      let swap = match m.swap {
        Some(s) => "\{s.i} \{s.ends}"
        None => ""
      }
      spr_told(m.o) + "\{m.mode.untracked()} " + swap
    }
  }
}

///|
/// The bar told anew: each part whose ways changed said, and the bar as a whole.
fn bar_said_again() -> Unit {
  for p in [Vis, Notch, Ball, Tints, Icon, Panel] {
    let told = bar_part_told(p)
    if told != bar_parts_told[p.ord()] {
      bar_parts_told[p.ord()] = told
      let s = bar_parts_said[p.ord()]
      s.set(s.untracked() + 1)
    }
  }
  bar_said.set(bar_said.untracked() + 1)
}

///|
/// The moment node `n` reads part `p`'s ways at, those it is drawn by ending at `until`: the moment it is drawn at while
/// they go, past every end (+inf: each where it went) once they are there, as the first frame after says; read again as
/// that part is told anew.
fn bar_moment(n : @view.View, p : BarPart, until : Double) -> Double {
  bar_part_said(p)
  n.drawn_while(fn(t) { t < until })
}

///|
/// Node `n` moved off where it is laid out by what `f` gives at the moment it is drawn at (View::moved_by: placed, pressed
/// and read out there, nothing laid out again), part `p`'s ways it goes by ending at `until`; asked again as that part
/// is told anew.
fn bar_moved(n : @view.View, p : BarPart, until : () -> Double, f : (Double) -> (Double, Double)) -> Unit {
  n
  .moved_by(
    fn(_, _, t) {
      bar_part_said(p)
      f(t)
    },
    fn(_, _) {
      bar_part_said(p)
      until()
    },
  )
  |> ignore
}

///|
/// Where the notch as drawn ends (BarModel::k_at: its spring's, the panel's and the rise's).
fn bar_k_until() -> Double {
  dmax(bar.k.end(), dmax(bar.o.end(), bar.up.end()))
}

///|
/// Where the ball as drawn ends (bar_ball_at: where it is, held, how big, how faint).
fn bar_ball_until() -> Double {
  let m = bar
  dmax(dmax(m.ball_x.end(), m.ball_y.end()), dmax(m.held.end(), dmax(m.ball_scale.end(), m.ball_alpha.end())))
}

///|
/// Where the place of tint `id` ends lighting up or going dim.
fn bar_tint_until(id : String) -> Double {
  match bar.tints.get(id) {
    Some(g) => g.end()
    None => -1.0
  }
}

///|
/// How lit the place of tint `id` is at moment `t` (its glide's, bar_tell's; none told yet: not).
fn bar_tint_at(id : String, t : Double) -> Double {
  match bar.tints.get(id) {
    Some(g) => g.at(t).0
    None => 0.0
  }
}

///|
/// A box `w` by `h` at (`x`, `y`) in `parent` (over all of it: View::over), made by `f`; it.
fn bar_at(
  parent : @view.View,
  x : () -> Double,
  y : () -> Double,
  w : () -> Double,
  h : () -> Double,
  f : (@view.View) -> Unit,
) -> @view.View {
  let made : Ref[@view.View?] = Ref(None)
  parent.box(fn(o) {
    o.over(Is(true)) |> ignore
    made.val = Some(
      o.box(fn(b) {
        b.width(By(fn() { Some(w()) })).height(By(fn() { Some(h()) })).offset(By(fn() { (x(), y()) })) |> ignore
        f(b)
      }),
    )
  })
  |> ignore
  made.val.unwrap()
}

///|
/// What the bar is laid out by as it was last told (BarLaid), or as none before it is.
fn bar_laid_now() -> BarLaid {
  bar_laid_told.get()
}

///|
/// The bar laid out as nothing told yet.
fn bar_laid_none() -> BarLaid {
  bar_laid({ shown: false, action: "", active: None, sets: [[]], cur: 0, width: 0.0 })
}

///|
/// How the bar is laid out as it was last told (bar_tell's: BarLaid), told again only as that changes, not as whether it
/// shows or what its notch offers does: what is laid out by it read again then alone.
// kept across runs: said again as the bar is told, put back by bar_reset
let bar_laid_told : @signals.Signal[BarLaid] = @signals.signal(bar_laid_none(), same=fn(a, b) { a == b })

///|
/// The bottom bar drawn in `g`, its glass's node (bar_glass_node: so what a press there goes to holds what it draws),
/// shown on a place's top page with nothing over it; going down out of the way as it is hidden,
/// taking nothing as it goes (View::show's `leave`). `ws`: the workspace in view.
fn bar_node(g : @view.View, src : Source, ws : () -> Workspace?) -> Unit {
  g.box(fn(b) {
    b.over(Is(true)) |> ignore
    bar_place_marks_node(b, src, ws)
    // (what waits on what moves told as the bar is told anew: when all of it is at rest, BarModel::rest)
    b.reacts(fn() { bar_said.get() }, fn(_) { b.said_moving("bar", "the bar's springs", fn(_) { bar.rest() }) })
    // (none before its width is known: it is first laid out where it goes, at once, bar_tell)
    b.show(at_once=true,
      fn() {
        match bar_told_now.get() {
          Some(t) => t.shown && t.width > 0.0
          None => false
        }
      },
      fn(holder) { bar_holder_node(holder, src, ws) },
      leave=bar_hide_ms,
    )
  })
  |> ignore
}

///|
/// The bar's panel in `holder` (its glass, the panel's rows over it as it opens), where it is told: going down out of
/// the way and back up, drawn up out from under a finger that has it, drawn so, laid out where it rests.
fn bar_holder_node(holder : @view.View, src : Source, ws : () -> Workspace?) -> Unit {
  let w = fn() { bar_laid_now().w }
  let panel = fn() { bar_laid_now().panel }
  let row_top = fn() { bar_laid_now().row_top }
  // (the glass's top laid out where the panel goes, drawn where it is as each frame is drawn: `drift` off that)
  let clip_top = fn() {
    bar_part_said(Panel) |> ignore
    bar_glass_top(bar_laid_now().reach, bar.o.to)
  }
  let drift = fn(t : Double) { bar_glass_top(bar_laid_now().reach, bar.o.at(t).0) - clip_top() }
  holder
  .width(By(fn() { Some(w()) }))
  .height(By(fn() { Some(panel()) }))
  .alpha(By(fn() { bar.vis.at(bar_moment(holder, Vis, bar.vis.end())).0 }))
  |> ignore
  bar_moved(holder, Vis, fn() { dmax(bar.vis.end(), bar.up.end()) }, fn(t) {
    let v = bar.vis.at(t).0
    let foot = 22.0 + nav_foot()
    let raised = bar_raise(holder.window().1, foot, panel(), status_top_now(holder.window().0)) * bar.up.at(t).0
    (0.0, (1.0 - v) * bar_drop - raised)
  })
  bar_shadow_node(holder, w, clip_top, panel, drift)
  // the action's own disc under the glass (the glass frosts it as it frosts the pages, its warmth round the notch,
  // fading down from it), and the glass with the notch cut into its top
  let disc_x = fn() { w() / 2.0 - drop / 2.0 }
  let disc_y = fn() { row_top() - lift - drop / 2.0 }
  let under = bar_at(holder, disc_x, disc_y, fn() { drop }, fn() { drop }, fn(d) {
    d
    .radius(Is(drop / 2.0))
    .ground(By(fn() {
      let t = @sf.theme()
      @sf.over(t.p.bg, @sf.alpha(t.p.accent, action_ink))
    }))
    |> ignore
  })
  bar_disc_look(under)
  bar_glass_capsule(holder, w, clip_top, panel, drift)
  // the action in the notch, accent glass, growing out of the bar as the notch opens about its middle, which comes up to
  // the bar's edge (laid out as it is open, drawn so); closing, it keeps the last action's icon as it shrinks. It is the
  // notch's key: pressed while the place has an action, taken only where the notch is drawn open at its moment
  // (closing, the panel up, what is under it the panel's); what it opens opened beside it
  let disc = bar_at(holder, disc_x, disc_y, fn() { drop }, fn() { drop }, fn(d) {
    d
    .radius(Is(drop / 2.0))
    .glass(Is(Some(@sf.glass_action().sharing())))
    .presses(By(fn() {
      match bar_told_now.get() {
        Some(t) => t.shown && t.action != ""
        None => false
      }
    }))
    .takes(fn(w, h, at) { if bar.drag < 0.0 && !bar.holds && bar.k_at(at) > 0.9 { [(0.0, 0.0, w, h)] } else { [] } })
    .on_press(fn() {
      match ws() {
        Some(w) => bar_action_run(src, w, d.cause_at())
        None => ()
      }
    })
    |> ignore
    bar_action_icons(d)
  })
  bar_disc_look(disc)
  // (what its action opens opened beside it: bar_action_run)
  bar_action_anchor.val = Some(disc)
  bar_ball_node(holder)
  bar_rows_node(holder, w)
  bar_places_node(holder, w, row_top)
  bar_lens_node(holder)
  bar_swap_node(holder, w, row_top, panel)
}

///|
/// The actions the notch has an icon for (bar_action's: 令, ＋).
// kept across runs: a table, never written
let bar_faces : Array[String] = ["ling", "plus"]

///|
/// The notch's icons in `d` (action_icon's: 令 40, any other 30, white, in its middle), one of each action's, made once
/// and drawn (and found on screen by what it draws) only while the action is it (m_face) or another swaps in for it
/// (icon_was; bar_tell: a short scale and fade, 300 ms on the bar's clock, linear; the one going out by 120 ms, the one
/// coming in from 60 ms): none made or let go as the action is another.
fn bar_action_icons(d : @view.View) -> Unit {
  let css : @ui.Ease = Out
  // (how it is drawn, as faint and as large, at node `n`'s moment: coming in, going out, or not there: None)
  let look = fn(n : @view.View, face : String) -> (Double, Double)? {
    bar_part_said(Icon) |> ignore
    let v = bar.icon_swap.at(bar_moment(n, Icon, bar.icon_swap.end())).0
    if face == m_face.val {
      let ms = v * 300.0
      if ms < 300.0 {
        Some((css.at(dclamp((ms - 60.0) / 180.0, 0.0, 1.0)), 0.5 + 0.5 * css.at(dclamp((ms - 60.0) / 240.0, 0.0, 1.0))))
      } else {
        Some((1.0, 1.0))
      }
    } else if face == bar.icon_was && v < 1.0 {
      let p = css.at(dclamp(v * 300.0 / 120.0, 0.0, 1.0))
      Some((1.0 - p, 1.0 - 0.5 * p))
    } else {
      None
    }
  }
  for face in bar_faces {
    d.box(fn(c) {
      c.over(Is(true)).lines_up(Is(Some(Middle))).lies_along(Is(Middle)) |> ignore
      let shown = fn() { look(c, face) }
      let i = @sf.icon_node(c, face, if face == "ling" { 40.0 } else { 30.0 }, Is(0xFFFFFFFFL), name_now=fn() {
        if shown() is Some(_) {
          face
        } else {
          ""
        }
      })
      i
      .alpha(By(fn() { shown().map(fn(s) { s.0 }).unwrap_or(0.0) }))
      .scale(By(fn() { shown().map(fn(s) { s.1 }).unwrap_or(1.0) }))
      |> ignore
    })
    |> ignore
  }
}

///|
/// A disc in the notch (the action's, its ground under the glass): growing with the notch, fading while a finger has
/// the bar (disc_look's), as each frame is drawn.
fn bar_disc_look(d : @view.View) -> Unit {
  let look_at = fn(t : Double) {
    let k = bar.k_at(t)
    let visible = 1.0 - dclamp(bar.up.at(t).0, 0.0, 1.0)
    if k <= 0.001 {
      // (closed: not there)
      (0.0, 1.0, 0.0)
    } else if k < 1.0 {
      (dmin(1.0, k * 3.0) * visible, dmax(0.001, k), lift * (1.0 - k))
    } else {
      (visible, 1.0, 0.0)
    }
  }
  let look = fn() { look_at(bar_moment(d, Notch, bar_k_until())) }
  d.alpha(By(fn() { look().0 })).scale(By(fn() { look().1 })) |> ignore
  bar_moved(d, Notch, bar_k_until, fn(t) { (0.0, look_at(t).2) })
}

///|
/// The bar's shadow (bar_shadow's): a blurred rounded rectangle 4 lower, outside the glass's outline only (the glass
/// frosts nothing of it), none above its top (none in the notch or over the edge the action stands on), coming in down
/// its rounded ends from nothing at its top to whole a radius down, in bands; its top where the glass's is drawn.
fn bar_shadow_node(
  holder : @view.View,
  w : () -> Double,
  top : () -> Double,
  bottom : () -> Double,
  drift : (Double) -> Double,
) -> Unit {
  let h = fn() { bottom() - top() }
  let r = fn() { dmin(rad, h() / 2.0) }
  // (the room round it its blur reaches into)
  let room = 40.0
  let cast = fn(band : @view.View, from : () -> Double) {
    bar_at(band, fn() { room }, fn() { -from() }, w, h, fn(s) {
      s
      .radius(By(r))
      .shadow(By(fn() { (6.0, bar_shadow_y, @sf.alpha(0x000000FFL, if @sf.theme().dark { 0.45 } else { 0.16 })) }))
      .shadow_outside(Is(true))
      // (drawn with its band as the glass's top is, its foot where it is)
      .ground_drawn(
        By(fn() {
          let d = drift(bar_moment(s, Panel, bar.o.end()))
          { dx: 0.0, dy: 0.0, dw: 0.0, dh: -d, corners: None }
        }),
      )
      |> ignore
    })
    |> ignore
  }
  // its rounded ends' top, in bands, each as far in as the fade is there
  for k in 0..<bar_shadow_fade {
    let y0 = fn() { r() * k.to_double() / bar_shadow_fade.to_double() }
    let bh = fn() { r() / bar_shadow_fade.to_double() }
    bar_at(holder, fn() { -room }, fn() { top() + y0() }, fn() { w() + 2.0 * room }, bh, fn(band) {
      band
      .clips(Is(true))
      .alpha(Is((k.to_double() + 0.5) / bar_shadow_fade.to_double()))
      |> ignore
      bar_moved(band, Panel, fn() { bar.o.end() }, fn(t) { (0.0, drift(t)) })
      cast(band, y0)
    })
    |> ignore
  }
  // below that, whole
  bar_at(holder, fn() { -room }, fn() { top() + r() }, fn() { w() + 2.0 * room }, fn() { bottom() - top() - r() + room }, fn(
    band
  ) {
    // (its top drawn with the glass's, its foot where it is: cut past it as far less)
    band.clips(Is(true)).clips_past(By(fn() { -drift(bar_moment(band, Panel, bar.o.end())) })) |> ignore
    bar_moved(band, Panel, fn() { bar.o.end() }, fn(t) { (0.0, drift(t)) })
    cast(band, r)
  })
  |> ignore
}

///|
/// The glass (bar_glass's) from `top` to `bottom`, `w` wide, the notch cut into its top where the notch is as each
/// frame is drawn (its outline the glass's and its edge's, the edge seen between its lips as they part; lit white at
/// 70%, 22% in the dark, 1 wide across the outline, under the glass's top), its top where the panel has it.
fn bar_glass_capsule(
  holder : @view.View,
  w : () -> Double,
  top : () -> Double,
  bottom : () -> Double,
  drift : (Double) -> Double,
) -> Unit {
  let h = fn() { bottom() - top() }
  let corner = fn() { dmin(rad, h() / 2.0) }
  // (the notch where it is drawn, and where its lips are then: none while its circle is not through the edge)
  let notch = fn(n : @view.View) {
    let (cy, r) = notch_at(bar.k_at(bar_moment(n, Notch, bar_k_until())))
    (cy, r, notch_lips(w(), cy, r))
  }
  bar_at(holder, fn() { 0.0 }, top, w, h, fn(g) {
    g
    .radius(By(corner))
    .glass(Is(Some(@sf.glass_bottom_bar())))
    // (its top where the panel has it as each frame is drawn, its foot where it is)
    .ground_drawn(
      By(fn() {
        let d = drift(bar_moment(g, Panel, bar.o.end()))
        { dx: 0.0, dy: d, dw: 0.0, dh: -d, corners: None }
      }),
    )
    .notch(
      By(fn() {
        match notch(g) {
          (cy, r, Some(_)) => (cy, r, fillet)
          (_, _, None) => (0.0, 0.0, 0.0)
        }
      }),
    )
    |> ignore
  })
  |> ignore
  // the notch's outline alone: the glass's outline grown by half the line, its line inside that, seen between the lips
  // and under the glass's top; its foot below the cut (else its bottom edge was a white line under the bar's middle)
  bar_at(holder, fn() { 0.0 }, fn() { top() + 0.5 }, w, h, fn(lips) {
    lips
    .clips(Is(true))
    .cut_across(
      By(fn() {
        match notch(lips).2 {
          Some((l, rr)) => Some((l, rr))
          None => Some((0.0, 0.0))
        }
      }),
    )
    |> ignore
    bar_moved(lips, Panel, fn() { bar.o.end() }, fn(t) { (0.0, drift(t)) })
    bar_at(lips, fn() { -0.5 }, fn() { -1.0 }, fn() { w() + 1.0 }, fn() { h() + 4.0 }, fn(edge) {
      edge
      .radius(By(fn() { corner() + 0.5 }))
      .edge(By(fn() { (1.0, @sf.alpha(0xFFFFFFFFL, if @sf.theme().dark { 0.22 } else { 0.7 })) }))
      .notch(
        By(fn() {
          let (cy, r, _) = notch(edge)
          (cy + 0.5, r - 0.5, fillet + 0.5)
        }),
      )
      // (no lips, no edge: nothing of it drawn)
      .alpha(By(fn() { if notch(edge).2 is Some(_) { 1.0 } else { 0.0 } }))
      |> ignore
    })
    |> ignore
  })
  |> ignore
}

///|
/// The ball as drawn at moment `t`: its middle, how wide and high (stretched by its speed toward where it goes, larger
/// as it is held), how faint, how large it is coming or going, how far it is held.
priv struct BallAt {
  cx : Double
  cy : Double
  sw : Double
  sh : Double
  alpha : Double
  scale : Double
  held : Double
}

///|
/// The ball at moment `t`.
fn bar_ball_at(t : Double) -> BallAt {
  let m = bar
  let held = m.held.at(t).0
  let (x, xv) = m.ball_x.at(t)
  let scale = 1.0 + 0.06 * held
  // (its way a frame at 60, as fast as it goes then: none at rest. Not cut to none within half a point of where it goes,
  // as the old view's was: a spring passing it there went on stretched the frame after, a jump each frame drew)
  let v = xv / 60.0
  let (stretch, lower) = @kit.speed_stretch(v)
  let bw = ball_size + stretch
  let bh = ball_size - lower
  let left = x - ball_size / 2.0 - (if v < 0.0 { stretch } else { 0.0 })
  {
    cx: left + bw / 2.0,
    cy: m.ball_y.at(t).0,
    sw: bw * scale,
    sh: bh * scale,
    alpha: m.ball_alpha.at(t).0,
    scale: m.ball_scale.at(t).0,
    held,
  }
}

///|
/// A capsule round the ball's middle in `parent`, `grow` times as large as the ball is drawn (its stretch and its
/// hold's), placed where the ball is as each frame is drawn, drawn as large and as faint as `look` has it; made by `f`.
fn bar_ball_capsule(
  parent : @view.View,
  grow : (BallAt) -> Double,
  alpha : (@view.View, BallAt) -> Double,
  f : (@view.View) -> Unit,
) -> Unit {
  let at = fn(n : @view.View) { bar_ball_at(bar_moment(n, Ball, bar_ball_until())) }
  parent.box(fn(o) {
    o.over(Is(true)) |> ignore
    o.box(fn(b) {
      b
      .width(Is(Some(ball_size)))
      .height(Is(Some(ball_size)))
      // (laid out where it goes, drawn where it is)
      .offset(By(fn() {
        bar_part_said(Ball) |> ignore
        (bar.ball_x.to - ball_size / 2.0, bar.ball_y.to - ball_size / 2.0)
      }))
      .alpha(By(fn() { alpha(b, at(b)) }))
      .scale(By(fn() { at(b).scale }))
      |> ignore
      bar_moved(b, Ball, bar_ball_until, fn(t) {
        let a = bar_ball_at(t)
        (a.cx - bar.ball_x.to, a.cy - bar.ball_y.to)
      })
      b.box(fn(s) {
        s.over(Is(true)) |> ignore
        // (as wide and as high as it is drawn about its middle, as round as the shorter)
        s
        .ground_drawn(
          By(fn() {
            let a = at(s)
            let k = grow(a)
            let (sw, sh) = (a.sw * k, a.sh * k)
            let r = dmin(sw, sh) / 2.0
            { dx: (ball_size - sw) / 2.0, dy: (ball_size - sh) / 2.0, dw: sw - ball_size, dh: sh - ball_size, corners: Some((r, r, r, r)) }
          }),
        )
        .radius(Is(ball_size / 2.0))
        |> ignore
        f(s)
      })
      |> ignore
    })
    |> ignore
  })
  |> ignore
}

///|
/// The ball under the places, stretched by its speed toward where it goes; its glass frosts what the bar's does (as it
/// fades and grows in or out, drawn so). Held, the lens over the places takes its place: it fades as the lens comes.
fn bar_ball_node(holder : @view.View) -> Unit {
  bar_ball_capsule(
    holder,
    fn(_) { 1.0 },
    fn(n, b) {
      let lensed = if n.glass_solid() { 0.0 } else { dmin(1.0, b.held) }
      b.alpha * (1.0 - lensed)
    },
    fn(g) {
      g
      .glass(Is(Some(@sf.glass_bar_ball().sharing())))
      .shadow(By(fn() { (4.0, 1.0, if @sf.theme().dark { 0x00000059L } else { 0x37352D33L }) }))
      |> ignore
    },
  )
}

///|
/// The ball in the finger: a lens of liquid glass over the places as it is held (as it grows), what is under its rim
/// bent; gone as it is let go. Where glass is solid there is nothing to bend: the ball alone.
fn bar_lens_node(holder : @view.View) -> Unit {
  holder.box(fn(b) {
    b.over(Is(true)) |> ignore
    b.show(at_once=true, fn() { !b.glass_solid() }, fn(on) {
      on.over(Is(true)) |> ignore
      let held = fn(n : @view.View) { bar.held.at(bar_moment(n, Ball, bar.held.end())).0 }
      bar_ball_capsule(
        on,
        fn(a) { 1.0 + lens_grow * a.held },
        fn(_, a) {
          if a.held > 0.01 && a.alpha > 0.0 {
            dmin(1.0, a.held) * a.alpha
          } else {
            0.0
          }
        },
        fn(g) {
          g
          .glass(By(fn() { Some(@sf.backdrop_tab(held(g))) }))
          .shadow(Is((@sf.tab_lens_raised.sigma, @sf.tab_lens_raised.dy, @sf.tab_lens_raised.color)))
          |> ignore
        },
      )
    })
  })
  |> ignore
}

///|
/// What the bar's places say of the workspace in view (read while the bar is: bar_place_marks_node): a station
/// in trouble, a remote agent lit, the stations at a glance and in words.
#derive(Eq)
priv struct BarPlaceMarks {
  trouble : Bool
  remote : Bool
  glance : @sf.GlyphCounts
  said : String
}

///|
/// None said yet.
// kept across runs: a value (no field of it changes)
let bar_place_marks_none : BarPlaceMarks = {
  trouble: false,
  remote: false,
  glance: { online: 0, dim: 0, failing: 0, working: 0, asleep: false, connecting: 0 },
  said: "",
}

///|
/// The bar's marks as the workspace in view last said them (bar_place_marks_node), what each place reads.
// kept across runs: said again as the bar is made (bar_place_marks_node)
let bar_place_marks : @signals.Signal[BarPlaceMarks] = @signals.signal(bar_place_marks_none, same=fn(a, b) { a == b })

///|
/// The bar's marks told in node `b` as the workspace in view `ws` says them (the chats' trouble, a remote agent, the
/// stations at a glance): read all along while the bar is there, shown or not.
fn bar_place_marks_node(b : @view.View, src : Source, ws : () -> Workspace?) -> Unit {
  b.reacts(
    fn() {
      match ws() {
        Some(w) => {
          let (glance, said) = stations_at_glance(src, w.id)
          {
            trouble: field(chats_topic(src, w.id).value, "trouble") is Some(Object(_)),
            remote: @sfpages.remote_agent_lit(src, w.id),
            glance,
            said,
          }
        }
        None => bar_place_marks_none
      }
    },
    fn(m) { bar_place_marks.set(m) },
  )
}

///|
/// What a screen reader says of place `key` (Station's, the stations in words).
fn bar_said_of(key : String) -> String {
  let said = if key == "stations" { bar_place_marks.get().said } else { "" }
  if said != "" {
    said
  } else {
    place_label(key)
  }
}

///|
/// Place `key`'s dot: a station in trouble (red) on Station's, a remote agent lit (the accent) on 远程's; none else.
fn bar_dot_of(key : String) -> Int64 {
  match key {
    "stations" => if bar_place_marks.get().trouble { @sf.theme().p.red } else { 0L }
    "remote" => if bar_place_marks.get().remote { @sf.theme().p.primary } else { 0L }
    _ => 0L
  }
}

///|
/// A place of the bar or the panel (place_at's) in `at`, its slot 48 high round its middle, as the library draws one
/// (@sf.bar_place_node): lit as far as `lit_at` has it as each frame is drawn, its dot, read out by its name.
fn bar_face_node(
  at : @view.View,
  key : String,
  part : BarPart,
  lit_at : (Double) -> Double,
  lit_until : () -> Double,
) -> Unit {
  @sf.bar_place_node(
    at,
    place_icon(key),
    if key == "stations" {
      Some(fn() { bar_place_marks.get().glance })
    } else {
      None
    },
    fn(n) { lit_at(bar_moment(n, part, lit_until())) },
    fn() { bar_dot_of(key) },
    fn() { bar_said_of(key) },
  )
}

///|
/// The bar's places over the ball: each its slot round its middle, lit as far as it is as each frame is drawn, placed
/// where the notch has it as each frame is drawn (drawn, pressed and read out there; nothing laid out for it); none
/// while a bar chosen lands (bar_swap_node draws them coming down).
fn bar_places_node(
  holder : @view.View,
  w : () -> Double,
  row_top : () -> Double,
) -> Unit {
  let items = fn() { bar_laid_now().items }
  let slot = fn() { (w() - 2.0 * c0) / 3.0 }
  let bar_mid = fn() { row_top() + bar_track / 2.0 }
  holder.box(fn(row) {
    row.over(Is(true)) |> ignore
    row.alpha(By(fn() { if bar.swap_at(bar_moment(row, Panel, bar.o.end())) is Some(_) { 0.0 } else { 1.0 } })) |> ignore
    row.each(at_once=true, items, fn(k) { k }, fn(p, key) {
      let key = key.untracked()
      let x_at = fn(k : Double) {
        let items = items()
        bar_centres(w(), k, items.length())[items.search(key).unwrap_or(0)] - slot() / 2.0
      }
      bar_at(p, fn() {
          bar_part_said(Notch) |> ignore
          x_at(bar.k_end())
        }, fn() { bar_mid() - 24.0 }, slot, fn() { 48.0 }, fn(at) {
        bar_moved(at, Notch, bar_k_until, fn(t) { (x_at(bar.k_at(t)) - x_at(bar.k_end()), 0.0) })
        bar_face_node(at, key, Tints, fn(t) { bar_tint_at("bar:" + key, t) }, fn() { bar_tint_until("bar:" + key) })
      })
      |> ignore
    })
  })
  |> ignore
}

///|
/// The other bars, above this one, as the panel opens (rowsAlpha, rowsShift): each its places at rest across its row,
/// as faint and as low as the panel has them as each frame is drawn; none while it is closed, nor while a bar chosen
/// lands (bar_swap_node draws them going).
fn bar_rows_node(holder : @view.View, w : () -> Double) -> Unit {
  let slot = fn() { (w() - 2.0 * c0) / 3.0 }
  holder.box(fn(rows) {
    rows.over(Is(true)) |> ignore
    rows.show(at_once=true,
      fn() {
        bar.mode.get() || bar.o.to > 0.001 || bar_moment(rows, Panel, bar.o.end()) != @double.infinity
      },
      fn(open) {
        open.over(Is(true)) |> ignore
        let look_at = fn(t : Double) {
          let o = bar.o.at(t).0
          (if bar.swap_at(t) is Some(_) { 0.0 } else { rows_alpha(o) }, rows_shift(o, bar_laid_now().reach))
        }
        open.alpha(By(fn() { look_at(bar_moment(open, Panel, bar.o.end())).0 })) |> ignore
        bar_moved(open, Panel, fn() { bar.o.end() }, fn(t) { (0.0, look_at(t).1) })
        // (each other bar by its place among the bars, at its row: n from the top)
        let others = fn() { bar_laid_now().others.mapi(fn(n, i) { (n, i) }) }
        open.each(at_once=true, others, fn(ni) { ni.1 }, fn(r, ni) {
          r.over(Is(true)) |> ignore
          let i = ni.untracked().1
          let n = fn() { ni.get().0 }
          let set = fn() { bar_laid_now().sets.get(i).unwrap_or([]) }
          r.each(at_once=true, set, fn(k) { k }, fn(p, key) {
            let key = key.untracked()
            let x = fn() { bar_centres(w(), 0.0, set().length())[set().search(key).unwrap_or(0)] - slot() / 2.0 }
            let y = fn() { over + n().to_double() * bar_row + bar_row / 2.0 - 24.0 }
            bar_at(p, x, y, slot, fn() { 48.0 }, fn(at) {
              bar_face_node(at, key, Tints, fn(t) { bar_tint_at("row:" + key, t) }, fn() { bar_tint_until("row:" + key) })
            })
            |> ignore
          })
        })
      },
    )
  })
  |> ignore
}

///|
/// A bar being chosen: the stack of bars slides down inside the closing glass, the chosen one into the bar's place,
/// what is not chosen cut off by the glass's edge. It starts as the rows and the bar were drawn (the rows' fade and
/// offset, each place as lit as it was) and comes to the bar's look as it lands, each frame as it is drawn; cut to the
/// glass as its top is drawn then, and to the panel's foot.
fn bar_swap_node(
  holder : @view.View,
  w : () -> Double,
  row_top : () -> Double,
  panel : () -> Double,
) -> Unit {
  let slot = fn() { (w() - 2.0 * c0) / 3.0 }
  let bar_mid = fn() { row_top() + bar_track / 2.0 }
  holder.box(fn(b) {
    b.over(Is(true)) |> ignore
    b.show(at_once=true,
      fn() {
        bar_part_said(Notch) |> ignore
        b.drawn_while(fn(t) { bar.swap_at(t) is Some(_) }) != @double.infinity
      },
      fn(on) {
        on.over(Is(true)) |> ignore
        let s = bar.swap.unwrap()
        let until = fn() { dmax(bar.o.end(), bar_k_until()) }
        let now_at = fn(t : Double) {
          let o = bar.o.at(t).0
          let st = s.t(o)
          let (xs, y) = swap_at(s, o, w(), bar.k_at(t), row_top())
          (o, st, xs, y - (over + s.n.to_double() * bar_row + bar_row / 2.0), s.drop * (1.0 - st), s.alpha + (1.0 - s.alpha) * st)
        }
        let now = fn(n : @view.View) { now_at(bar_moment(n, Notch, until())) }
        let was = fn(id : String) { s.lit.get(id).unwrap_or(0.0) }
        // (the glass's top as it is drawn at a moment: what is over it cut off)
        let top = fn(t : Double) { bar_glass_top(bar_laid_now().reach, now_at(t).0) }
        let window = fn(f : (@view.View, (Double) -> Double) -> Unit) {
          bar_at(on, fn() { 0.0 }, fn() { 0.0 }, w, panel, fn(foot) {
            foot.clips(Is(true)) |> ignore
            bar_at(foot, fn() { 0.0 }, fn() { 0.0 }, w, panel, fn(win) {
              win.clips(Is(true)) |> ignore
              bar_moved(win, Notch, until, fn(t) { (0.0, top(t)) })
              f(win, top)
            })
            |> ignore
          })
          |> ignore
        }
        // the rest, leaving: the rows not chosen and the bar as it was, sliding down
        window(fn(win, top) {
          let laid_others : Array[Int] = []
          for i in 0..<s.sets.length() {
            if i != s.cur {
              laid_others.push(i)
            }
          }
          for n, i in laid_others {
            if i != s.i {
              let set = s.sets[i]
              for j, key in set {
                let x = fn() { bar_centres(w(), 0.0, set.length())[j] - slot() / 2.0 }
                let y = fn() { over + n.to_double() * bar_row + bar_row / 2.0 - 24.0 }
                bar_at(win, x, y, slot, fn() { 48.0 }, fn(at) {
                  at
                  .alpha(By(fn() { now(at).5 }))
                  |> ignore
                  bar_moved(at, Notch, until, fn(t) {
                    let n = now_at(t)
                    (0.0, n.3 + n.4 - top(t))
                  })
                  bar_face_node(at, key, Notch, fn(_) { was("row:" + key) }, fn() { -1.0 })
                })
                |> ignore
              }
            }
          }
          let laid_items = s.sets[s.cur]
          for j, key in laid_items {
            let x = fn() {
              bar_part_said(Notch) |> ignore
              bar_centres(w(), bar.k_end(), laid_items.length())[j] - slot() / 2.0
            }
            let y = fn() { bar_mid() - 24.0 }
            bar_at(win, x, y, slot, fn() { 48.0 }, fn(at) {
              bar_moved(at, Notch, until, fn(t) {
                let laid = bar_centres(w(), bar.k_end(), laid_items.length())[j]
                (bar_centres(w(), bar.k_at(t), laid_items.length())[j] - laid, now_at(t).3 - top(t))
              })
              bar_face_node(at, key, Notch, fn(_) { was("bar:" + key) }, fn() { -1.0 })
            })
            |> ignore
          }
        })
        // the chosen bar, inside the closing glass too: landed, as the bar's places are drawn, lit as it comes when it
        // is the place shown (bar_tell)
        window(fn(win, top) {
          let items = s.sets[s.i]
          let active = match bar.told {
            Some({ active: Some(a), .. }) => a
            _ => ""
          }
          for j, key in items {
            let x = fn() {
              bar_part_said(Notch) |> ignore
              bar_centres(w(), bar.k_end(), items.length())[j] - slot() / 2.0
            }
            let y = fn() { bar_mid() - 24.0 }
            bar_at(win, x, y, slot, fn() { 48.0 }, fn(at) {
              at
              .alpha(By(fn() { now(at).5 }))
              |> ignore
              bar_moved(at, Notch, until, fn(t) {
                let n = now_at(t)
                let laid = bar_centres(w(), bar.k_end(), items.length())[j]
                let dx = if j < n.2.length() { n.2[j] - laid } else { 0.0 }
                (dx, n.3 + n.4 + over + s.n.to_double() * bar_row + bar_row / 2.0 - bar_mid() - top(t))
              })
              let end = if active == key { 1.0 } else { 0.0 }
              let from = was("row:" + key)
              bar_face_node(
                at,
                key,
                Notch,
                fn(t) {
                  let st = s.t(bar.o.at(t).0)
                  if st >= 1.0 {
                    end
                  } else if st <= 0.0 {
                    from
                  } else {
                    from + (end - from) * st
                  }
                },
                fn() { bar.o.end() },
              )
            })
            |> ignore
          }
        })
      },
    )
  })
  |> ignore
}
