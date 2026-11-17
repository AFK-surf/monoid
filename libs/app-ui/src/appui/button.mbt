// The button: mbui's headless button (`@headless.button`: what it is to the hand, the keyboard and a screen reader)
// with this library's look. Three sizes (24, 28, 32 high), four intents; an icon before or after its words, or an
// icon alone (a square); its ground going to its lit one under the hand over 120 ms; drawn at 0.97 while it is held
// (none where motion is reduced: every way there at once); the focus ring 2 out round its own corner while the
// keyboard's focus is on it; half seen while it cannot be pressed; at work (`busy`) a turning ring in its middle, its
// words kept where they were (seen through), so it is as wide as it was and nothing beside it moves.
//
// Its padding is one step of the scale at each end. Where an icon leads (or ends) it, its box stands a step less in
// (`Space::less`): a line icon has room of its own round its strokes, so its ink then looks as far in as the words do
// at the other end. The step is taken by a margin below 0 on the icon in a room of its own that stands where the padding
// says (as mbui's gap rule 4 measures a button: by what it lays out, the room, its drawing past it on purpose), never by
// a padding unlike at the two ends.

///|
/// How big a button is.
#derive(Eq, Debug)
pub(all) enum ButtonSize {
  /// 24 high, a caption's words: a row's action, a toolbar's
  Xs
  /// 28 high: a card's actions, a form's
  Sm
  /// 32 high: a page's main action
  Lg
}

///|
/// What a press of it does, as it shows.
#derive(Eq, Debug)
pub(all) enum Intent {
  /// the thing to do: the accent's ground
  Primary
  /// beside it: the panel's ground, an edge
  Secondary
  /// quiet: no ground till the hand is on it
  Ghost
  /// what cannot be undone
  Destructive
}

///|
/// How tall it is.
pub fn ButtonSize::height(self : ButtonSize) -> Double {
  match self {
    Xs => 24.0
    Sm => 28.0
    Lg => 32.0
  }
}

///|
/// How far in its words stand from its ends.
pub fn ButtonSize::side(self : ButtonSize) -> Space {
  match self {
    Xs => S8
    Sm => S12
    Lg => S16
  }
}

///|
/// Its words' role.
pub fn ButtonSize::role(self : ButtonSize) -> TextRole {
  match self {
    Xs => Caption
    Sm | Lg => Ui
  }
}

///|
/// Its icon's size.
pub fn ButtonSize::icon(self : ButtonSize) -> Double {
  match self {
    Xs => 14.0
    Sm | Lg => 16.0
  }
}

///|
/// The gap between its icon and its words.
fn ButtonSize::gap(self : ButtonSize) -> Space {
  match self {
    Xs => S4
    Sm | Lg => S6
  }
}

///|
/// What an intent is drawn in, at rest and lit: (ground, edge, ink) each (0: no ground, no edge).
fn Intent::looks(self : Intent, p : Palette) -> ((Int64, Int64, Int64), (Int64, Int64, Int64)) {
  match self {
    Primary => ((p.accent, 0L, p.on_accent), (over(0xFFFFFF1FL, p.accent), 0L, p.on_accent))
    Destructive =>
      ((p.destructive, 0L, p.on_destructive), (over(0xFFFFFF1FL, p.destructive), 0L, p.on_destructive))
    Secondary => ((p.panel, p.edge, p.ink), (over(p.hover, p.panel), p.edge, p.ink))
    // (the ghost's ground is the hover's tint at none of its alpha at rest: a ground to the corner rule all the same)
    Ghost => ((alpha(p.hover, 0.0), 0L, p.ink), (p.hover, 0L, p.ink))
  }
}

///|
/// How long a ground takes to go to its lit one and back.
pub let lit_ms : Double = 120.0

///|
/// How long a press takes to draw it smaller, and to let it back.
pub let press_ms : Double = 90.0

///|
/// How big it is drawn while held.
pub let pressed_scale : Double = 0.97

///|
/// The curve a control's look answers the hand on: quick out, soft in.
pub let ease_answer : (Double) -> Double = @motion.cubic_bezier(0.2, 0.0, 0.0, 1.0)

///|
/// A button in `parent`, called `label` (its words; an icon alone where `icon_only`, read out by them), `press` done as
/// it is pressed, of `intent` and `size`; `leading` / `trailing`: an icon before or after its words; `disabled` while
/// it cannot be pressed; `busy` while what it set going is at work (it takes no press then either). The node.
#callsite(autofill(loc))
pub fn button(
  parent : @view.View,
  label : () -> String,
  press : () -> Unit,
  intent? : Intent = Secondary,
  size? : ButtonSize = Sm,
  leading? : Icon,
  trailing? : Icon,
  icon_only? : Bool = false,
  disabled? : () -> Bool = fn() { false },
  busy? : () -> Bool = fn() { false },
  loc~ : SourceLoc,
) -> @view.View {
  let off = fn() { disabled() || busy() }
  @headless.button(made_for=loc, parent, label, fn(_) { press() }, disabled=off, fn(v, b) {
    let lit = @motion.eased_on(
      v,
      fn() { !off() && (b.hovered() || b.pressed()) },
      @motion.tween_to(duration=lit_ms, ease=ease_answer),
    )
    let held = @motion.eased_on(v, fn() { !off() && b.pressed() }, @motion.tween_to(duration=press_ms, ease=ease_answer))
    let now = fn() {
      let p = palette()
      let (rest, on) = intent.looks(p)
      let h = lit.shown(v)
      (mix(on.0, h, rest.0), on.1, on.2)
    }
    // (its words and icons seen through while it is at work: kept where they are, the ring over them)
    let ink = fn() { if busy() { alpha(now().2, 0.0) } else { now().2 } }
    let h = size.height()
    let side = size.side()
    v
    .row(Is(true))
    .lines_up(Is(Some(Middle)))
    .lies_along(Is(Middle))
    .height(Is(Some(h)))
    .shrink(Is(0.0))
    .radius(Is(control_radius))
    .ground(By(fn() { now().0 }))
    .alpha(By(fn() { if disabled() { 0.5 } else { 1.0 } }))
    .scale(By(fn() {
      if @ui.reduced_motion() {
        1.0
      } else {
        1.0 - (1.0 - pressed_scale) * held.shown(v)
      }
    }))
    .focus_ring(By(fn() { Some((focus_ring_w, 0.0, palette().focus)) }))
    |> ignore
    if intent == Secondary {
      v.edge(By(fn() { (1.0, now().1) })) |> ignore
    }
    if icon_only {
      // (a square, its icon in the middle)
      v.width(Is(Some(h))) |> ignore
      match leading {
        Some(i) => icon_node(v, i, size.icon(), ink) |> ignore
        None => ()
      }
    } else {
      let gap = size.gap().pt()
      let pulled = side.pt() - side.less().pt()
      v.padding(Is((side.pt(), 0.0, side.pt(), 0.0))).gap(Is(gap)) |> ignore
      match leading {
        Some(i) => icon_room(v, i, size.icon(), ink, (-pulled, 0.0, 0.0, 0.0))
        None => ()
      }
      text_node(v, label, size.role(), ink, weight=weight_medium) |> ignore
      match trailing {
        Some(i) => icon_room(v, i, size.icon(), ink, (0.0, 0.0, -pulled, 0.0))
        None => ()
      }
    }
    v.show(busy, at_once=true, fn(o) {
      o.over(Is(true)).row(Is(true)).lines_up(Is(Some(Middle))).lies_along(Is(Middle)) |> ignore
      spinner_node(o, size.icon(), fn() { now().2 }) |> ignore
    })
  })
}

///|
/// A ring three quarters round, turning once each 800 ms for as long as it shows, `side` across in `ink`: a wait
/// whose end is not known. The node.
#callsite(autofill(loc))
pub fn spinner_node(parent : @view.View, side : Double, ink : () -> Int64, loc~ : SourceLoc) -> @view.View {
  parent.box(made_for=loc, fn(s) {
    s.width(Is(Some(side))).height(Is(Some(side))).shrink(Is(0.0)) |> ignore
    s
    .shapes(By(fn() {
      let r = side / 2.0 - icon_stroke
      let pts : Array[Double] = []
      let steps = 24
      for k in 0..=steps {
        let a = 1.5 * 3.141592653589793 * k.to_double() / steps.to_double()
        pts.push(side / 2.0 + r * @dmath.cos(a))
        pts.push(side / 2.0 + r * @dmath.sin(a))
      }
      [@paint.shape_of([(pts, false)], stroke=ink(), width=icon_stroke)]
    }))
    .turn(By(fn() { s.cycle(800.0) * 2.0 * 3.141592653589793 }))
    |> ignore
  })
}

///|
/// The actions at a card's foot, `make` putting its buttons in, the main one first: in one line where they fit, and
/// where they do not, the ones after it go to the line over it (a row wrapping the other way, `View::wraps`'s
/// `reverse`), so the main action stays at the card's foot on its left, in the card's corner, concentric with it. It
/// keeps a step more room on its right, so what ends its line never lies in the card's other corner. The node.
#callsite(autofill(loc))
pub fn card_footer(parent : @view.View, make : (@view.View) -> Unit, loc~ : SourceLoc) -> @view.View {
  parent.box(made_for=loc, fn(r) {
    r
    .row(Is(true))
    .gap(Is(S6.pt()))
    .wraps(Is(Some(S6.pt())), reverse=true)
    .lines_up(Is(Some(Middle)))
    .padding(Is(pad(S0, S0, S6, S0)))
    |> ignore
    make(r)
  })
}

///|
/// A row of actions anywhere else (a toolbar, a form's foot), wrapping the other way as `card_footer` does. The node.
#callsite(autofill(loc))
pub fn action_row(
  parent : @view.View,
  make : (@view.View) -> Unit,
  gap? : Space = S8,
  loc~ : SourceLoc,
) -> @view.View {
  parent.box(made_for=loc, fn(r) {
    r.row(Is(true)).gap(Is(gap.pt())).wraps(Is(Some(gap.pt())), reverse=true).lines_up(Is(Some(Middle))) |> ignore
    make(r)
  })
}

///|
/// An icon in `parent` in a room of its own that stands where the padding says, the icon `pulled` out of it (a margin
/// below 0: left, top, right, foot) by the step its strokes' own room makes up for.
#callsite(autofill(loc))
fn icon_room(
  parent : @view.View,
  icon : Icon,
  side : Double,
  ink : () -> Int64,
  pulled : (Double, Double, Double, Double),
  loc~ : SourceLoc,
) -> Unit {
  parent.box(made_for=loc, fn(room) {
    room.row(Is(true)).lines_up(Is(Some(Middle))).shrink(Is(0.0)) |> ignore
    icon_node(room, icon, side, ink).margin(Is(pulled)) |> ignore
  })
  |> ignore
}
