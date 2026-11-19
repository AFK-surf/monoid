// Ported from Kyant0/AndroidLiquidGlass (Apache-2.0): catalog/components/LiquidBottomTabs.kt and LiquidBottomTab.kt. A
// capsule of glass 64 high across what holds it (vivid, blurred by 8, a lens 24 deep bending by up to 24, the
// container's colour over it), its tabs side by side in it 4 in, each a column of what it holds 2 apart in its middle;
// over the chosen one a lens 56 high as wide as a tab. Held, the lens comes up (10 deep, bending by up to 14, the
// colours split, its highlight, shadow and InnerShadow of 8 with it) and grows to 78 / 56 of itself, the tabs to 1.2 of
// theirs and the bar by 16 across its width; dragged, it slides along the tabs (squeezed as it goes: velocity / 10) and
// the bar after it by up to 4 (eased out), and let go it settles on the nearest tab, which is chosen. A finger on it
// lights the bar where the lens is. What the bar is to the keys and a screen reader is mbui's headless radio group's, a
// tab list: a tab pressed is chosen, the arrow keys move among them.
//
// Under the catalog's lens are the tabs again in the accent (a second row, drawn into the lens's backdrop alone); here
// each tab is drawn in a colour going from its words' to the accent as far as the lens is over it.

///|
/// The bar's glass, lit by a finger at `spot` as far as `light` says.
fn tabs_glass(light : Double, spot : (Double, Double)?) -> @paint.Glass {
  let c = colors()
  @paint.Glass::backdrop_lens(
    height=24.0,
    amount=24.0,
    blur=8.0,
    tint=c.container,
    solid=alpha(c.container, 1.0 / 0.4),
    highlight=1.0,
    style=Some(Default),
    saturation=1.5,
    spot~,
    spot_alpha=light,
  )
}

///|
/// The lens's glass over the chosen tab, held `p`.
fn tab_lens_glass(p : Double) -> @paint.Glass {
  let p = clamp(p, 0.0, 1.0)
  let c = colors()
  @paint.Glass::backdrop_lens(
    height=10.0 * p,
    amount=14.0 * p,
    blur=0.0,
    tint=over(alpha(c.lens_idle, 1.0 - p), alpha(black, 0.03 * p)),
    solid=alpha(c.container, 1.0 / 0.4),
    highlight=p,
    style=Some(Default),
    dispersion=true,
    inner_shadow=8.0 * p,
  )
}

///|
/// Compose's EaseOut (CubicBezierEasing(0, 0, 0.58, 1)).
fn ease_out(x : Double) -> Double {
  (@motion.cubic_bezier(0.0, 0.0, 0.58, 1.0))(x)
}

///|
/// One tab of a LiquidBottomTabs (LiquidBottomTab) in `g`, `rg`'s item `index`, read out a tab named `label`: a column
/// of what `content` makes 2 apart in its middle, as wide as the bar's share of it; `content` given the ink to draw in
/// (the words' colour going to the accent as far as `lit` says the lens is over it). Grown by `scale`. The node.
#callsite(autofill(loc))
pub fn liquid_bottom_tab_node(
  g : @view.View,
  rg : @headless.RadioGroup[Int],
  index : Int,
  label : String,
  content : (@view.View, () -> Int64) -> Unit,
  lit : (@view.View) -> Double,
  scale : (@view.View) -> Double,
  loc~ : SourceLoc,
) -> @view.View {
  rg.item(made_for=loc, g, fn() { index }, fn() { label }, fn(t, it) {
    t.grow(Is(1.0)).radius(Is(tab_lens_h / 2.0)).lines_up(Is(Some(Middle))).lies_along(Is(Middle)) |> ignore
    // (what it holds grown about its middle, LiquidBottomTab's graphicsLayer: the tab's own box, where it is pressed,
    // as it is laid out)
    t.box(fn(f) {
      f.lines_up(Is(Some(Middle))).gap(Is(2.0)).scale(By(fn() { scale(f) })) |> ignore
      content(f, fn() {
        let c = colors()
        lerp_color(c.content, c.accent, clamp(lit(f), 0.0, 1.0))
      })
    })
    |> ignore
    // (the keyboard's focus on it: a ring in the accent round its capsule)
    t.show(fn() { it.focus_shown() }, fn(ring) {
      ring.over(Is(true)).radius(Is(tab_lens_h / 2.0)).edge(By(fn() { (2.0, colors().accent) })) |> ignore
    })
  })
}

///|
/// What a tab holds by default (BottomTabsContent's): the airplane's icon 28 across over its name in 12 point words.
pub fn tab_face(name : String) -> (@view.View, () -> Int64) -> Unit {
  fn(f, ink) {
    flight_icon(f, 28.0, ink)
    f.box(fn(w) { w.words(Is(name), look=words_at(type_tab)).ink(By(ink)) |> ignore }) |> ignore
  }
}

///|
/// A LiquidBottomTabs in `parent`: a tab for each of `labels` (what each holds `faces`'s, by default tab_face), the one
/// `selected` says chosen; chosen by a press, the arrow keys, or the lens dragged and let go over it, `select` is told
/// which. Read out a tab list named `label`. As wide as what holds it gives it, 64 high. `drag` and `light`: its lens's
/// way and its light, where its caller holds them (a picture of it held). The node.
#callsite(autofill(loc))
pub fn liquid_bottom_tabs_node(
  parent : @view.View,
  labels : Array[String],
  selected : () -> Int,
  select : (Int) -> Unit,
  label? : String = "",
  faces? : Array[(@view.View, () -> Int64) -> Unit],
  drag? : DampedDrag,
  light? : InteractiveHighlight,
  loc~ : SourceLoc,
) -> @view.View {
  let count = labels.length()
  let last = if count > 1 { (count - 1).to_double() } else { 0.0 }
  let first = @signals.untracked(selected).to_double()
  let dd = match drag {
    Some(d) => d
    None => DampedDrag::new(first, lo=0.0, hi=last, held_scale=tab_lens_held_scale)
  }
  let ih = match light {
    Some(l) => l
    None => InteractiveHighlight::new()
  }
  let current = Ref(@signals.untracked(selected))
  let pulled = @motion.NodeWay::new(0.0)
  let pulled_by = Ref(0.0)
  let last_x = Ref(0.0)
  @headless.radio_group(made_for=loc, parent, fn() { label }, selected, select, kind=Tab, fn(g, rg) {
    dd.attach(g)
    ih.attach(g)
    g.height(Is(Some(tabs_h))).padding(Is((tabs_pad, tabs_pad, tabs_pad, tabs_pad))) |> ignore
    // (chosen by what is not the lens: a tab pressed, the keys, its caller; the lens sent there as by a hand)
    g.reacts(at_start=false, selected, fn(i) {
      if i != current.val {
        current.val = i
        dd.animate_to(i.to_double())
      }
    })
    g.by_room(fn(inner, room) {
      let w = fn() { room.width() + 2.0 * tabs_pad }
      let tab_w = fn() { (w() - 2.0 * tabs_pad) / count.to_double() }
      // (the bar after the lens as it is pulled: 4 at most, eased out, either way)
      let panel = fn(n : @view.View) {
        let ww = w()
        if ww <= 0.0 {
          return 0.0
        }
        let f = clamp(pulled.shown(n) / ww, -1.0, 1.0)
        let s = if f < 0.0 { -1.0 } else if f > 0.0 { 1.0 } else { 0.0 }
        4.0 * s * ease_out(f.abs())
      }
      let lit = fn(n : @view.View, i : Int) { clamp(1.0 - (dd.value(n) - i.to_double()).abs(), 0.0, 1.0) }
      let grown = fn(n : @view.View) { lerp(1.0, tab_held_scale, dd.pressed(n)) }
      inner.box(fn(bar) {
        bar
        .over(Is(true))
        .width(By(fn() { Some(w()) }))
        .height(Is(Some(tabs_h)))
        .margin(Is((-tabs_pad, -tabs_pad, 0.0, 0.0)))
        .radius(Is(tabs_h / 2.0))
        .shadow(Is(shadow_default))
        .glass(By(fn() {
          let p = ih.pressed(bar)
          let spot = if p > 0.0 {
            Some(((dd.value(bar) + 0.5) * tab_w() + tabs_pad + panel(bar), tabs_h / 2.0))
          } else {
            None
          }
          Some(tabs_glass(p, spot))
        }))
        .ground_drawn(By(fn() {
          let ww = w()
          let s = lerp(1.0, 1.0 + 16.0 / ww, dd.pressed(bar))
          stretched(ww, tabs_h, panel(bar), 0.0, s, s)
        }))
        |> ignore
      })
      |> ignore
      inner.box(fn(row) {
        row.row(Is(true)).height(Is(Some(tab_lens_h))).offset(By(fn() { (panel(row), 0.0) })) |> ignore
        for i, name in labels {
          let face = match faces {
            Some(fs) => fs.get(i).unwrap_or(tab_face(name))
            None => tab_face(name)
          }
          liquid_bottom_tab_node(row, rg, i, name, face, fn(n) { lit(n, i) }, grown) |> ignore
        }
      })
      |> ignore
      inner.box(fn(lens) {
        let size = fn() {
          let (sx, sy) = dd.jelly(lens, 10.0)
          (tab_w() * sx, tab_lens_h * sy)
        }
        lens
        .over(Is(true))
        .width(By(fn() { Some(size().0) }))
        .height(By(fn() { Some(size().1) }))
        .radius(By(fn() { size().1 / 2.0 }))
        .offset(By(fn() {
          let (lw, lh) = size()
          (dd.value(lens) * tab_w() + panel(lens) + (tab_w() - lw) / 2.0, (tab_lens_h - lh) / 2.0)
        }))
        .shadow(By(fn() {
          let (s, dy, ink) = shadow_default
          (s, dy, alpha(ink, dd.pressed(lens)))
        }))
        .glass(By(fn() { Some(tab_lens_glass(dd.pressed(lens))) }))
        |> ignore
        // (held, dragged and let go by a finger: the lens's own, over the tabs; its tabs are pressed round it)
        let stopped = fn() {
          let to = clamp(dd.target().round(), 0.0, last)
          let i = to.to_int()
          current.val = i
          dd.animate_to(to)
          if i != selected() {
            select(i)
          }
          pulled_by.val = 0.0
          pulled.go(lens, 0.0, @motion.spring(ratio=1.0, stiffness=300.0, threshold=0.5)) // det-ok(motion-spring): LiquidBottomTabs.kt offsetAnimation, ported 1:1
          ih.up()
        }
        lens.gesture(
          @ui.touch_slop(),
          press=fn(d) {
            last_x.val = d.wx
            ih.down(d.x, d.y, w(), tabs_h)
            dd.press()
          },
          tap=fn(_) { stopped() },
          drag=fn(d) {
            match d.kind {
              // (from where it went down: the slop before a drag is the drag's too, as Compose's overSlop)
              Down => ()
              Moved => {
                let dx = d.wx - last_x.val
                last_x.val = d.wx
                let tw = tab_w()
                if tw > 0.0 {
                  dd.update_value(clamp(dd.target() + dx / tw, 0.0, last))
                }
                pulled_by.val = pulled_by.val + dx
                pulled.put(pulled_by.val)
              }
              Up | Off => stopped()
            }
          },
        )
        |> ignore
      })
      |> ignore
    })
    |> ignore
  })
}
