// A control's look as one statement over its states (@headless.ControlState): its ground, what washes over that ground
// (the hover's, the press's), its edge and how clear it is, each a @headless.StateStyle, and the theme's concentric
// focus ring while the keyboard's focus shows on it. In the place of a hover_ground_node, a focus_ring_node and an
// alpha bound to disabled said apart at every control: one control_look_node, the states read once.
//
// The hand as the theme answers it (lit_node's): a mouse rests and presses, a finger only presses. What a component says
// of the pointer is the tree's (View::pointed: never a finger's); read here as @ui.pointing says the hand is now, so a
// hover left over as the hand turns to a finger washes nothing.
//
// And an overlay's card (overlay_card_node): @headless.overlay's layer drawn as the library's small panel (its ground,
// line, shadow and corner), over a scrim while modal, so a panel, a menu or a card that floats is one stack's layer.

///|
/// A control's look in each of its states: its ground, what is washed over it (View::ground_over: 0 none), its edge
/// (width and ink: 0 wide none) and how clear it is, each by state; whether the theme's focus ring is drawn round it
/// while the keyboard's focus shows on it.
pub struct ControlLook {
  ground : @headless.StateStyle[Int64]
  ground_over : @headless.StateStyle[Int64]
  edge : @headless.StateStyle[(Double, Int64)]
  alpha : @headless.StateStyle[Double]
  focus_ring : Bool
}

///|
/// A control's look: `ground` (none by default), `ground_over` (the theme's hover wash where the hand is on it or the
/// focus shows on it, none disabled), `edge` (none), `alpha` (clear; `control_off_alpha` disabled or at work), and the
/// focus ring (`focus_ring`).
pub fn ControlLook::new(
  ground? : @headless.StateStyle[Int64] = @headless.StateStyle::new(base=0L),
  ground_over? : @headless.StateStyle[Int64],
  edge? : @headless.StateStyle[(Double, Int64)] = @headless.StateStyle::new(base=(0.0, 0L)),
  alpha? : @headless.StateStyle[Double] = @headless.StateStyle::new(
    base=1.0,
    disabled=control_off_alpha,
    busy=control_off_alpha,
  ),
  focus_ring? : Bool = true,
) -> ControlLook {
  let ground_over = match ground_over {
    Some(g) => g
    None => {
      let hover = @ui.tree_theme().color(Hover)
      @headless.StateStyle::new(base=0L, disabled=0L, busy=0L, pressed=hover, hovered=hover, focused=hover)
    }
  }
  { ground, ground_over, edge, alpha, focus_ring }
}

///|
/// How clear a control is while it is disabled or at work.
pub let control_off_alpha : Double = 0.45

///|
/// States `s` as the theme answers the hand now: a finger rests on nothing, so nothing is hovered under one.
pub fn control_state_seen(s : @headless.ControlState) -> @headless.ControlState {
  match @ui.pointing() {
    Mouse => s
    Finger => { ..s, hovered: false }
  }
}

///|
/// What `look` is in states `s` as the theme answers the hand (control_state_seen): its ground, its wash, its edge and
/// how clear it is.
pub fn ControlLook::at(self : ControlLook, s : @headless.ControlState) -> (Int64, Int64, (Double, Int64), Double) {
  let s = control_state_seen(s)
  (self.ground.resolve(s), self.ground_over.resolve(s), self.edge.resolve(s), self.alpha.resolve(s))
}

///|
/// `target` drawn as `look` says in the states `state` reads (a component's: Button::state and the others), each
/// property bound to what it reads, set again only where it comes out otherwise; the theme's focus ring round it where
/// the look draws one (`Is`, as it is made: no binding).
#callsite(autofill(loc))
pub fn control_look_node(
  target : @view.View,
  state : () -> @headless.ControlState,
  look : () -> ControlLook,
  loc~ : SourceLoc,
) -> Unit {
  let seen = fn() { control_state_seen(state()) }
  target
  .ground(By(fn() { look().ground.resolve(seen()) }), loc~)
  .ground_over(By(fn() { look().ground_over.resolve(seen()) }), loc~)
  .edge(By(fn() { look().edge.resolve(seen()) }), loc~)
  .alpha(By(fn() { look().alpha.resolve(seen()) }), loc~)
  |> ignore
  if @signals.untracked(look).focus_ring {
    target.focus_ring_theme(loc~) |> ignore
  }
}

///|
/// An overlay (@headless.overlay) in `parent` drawn as the library's card: a layer filling `parent` over all of the
/// window where `parent` is the root's, over the theme's scrim where `scrim` (by default while modal: the scrim's own,
/// a press on it outside the card), the card in it the small panel (small_panel_node: its padding, corner, ground, line
/// and shadow), laid out at the layer's top as wide as it holds unless `place` puts it elsewhere (beside its anchor,
/// over the layer offset), and holding what `body` makes. What
/// would close it `on_dismiss` told, as the overlay's are (`modal`, `dismiss_on_escape`, `dismiss_on_outside`,
/// `inert`, `anchor`, `label`). The card's node.
#callsite(autofill(loc))
pub fn overlay_card_node(
  parent : @view.View,
  on_dismiss : (@headless.OverlayDismiss) -> Unit,
  body : (@view.View, @headless.Overlay) -> Unit,
  place? : (@view.View) -> Unit = fn(_) {  },
  modal? : Bool = false,
  scrim? : Bool = modal,
  dismiss_on_escape? : Bool = true,
  dismiss_on_outside? : Bool = true,
  inert? : () -> Bool = fn() { false },
  anchor? : @view.View,
  label? : () -> String,
  loc~ : SourceLoc,
) -> @view.View {
  let card : Ref[@view.View?] = Ref(None)
  parent.box(made_for=loc, fn(layer) {
    layer.over(Is(true), loc~).over_all(Is(true)) |> ignore
    let gone = fn() { inert() || layer.leaving() }
    if scrim {
      layer.box(made_for=loc, fn(s) {
        s
        .over(Is(true), loc~)
        .ground(By(fn() { if gone() { 0L } else { @ui.tree_theme().scrim } }), loc~)
        .scrim_under()
        |> ignore
      })
      |> ignore
    }
    card.val = Some(
      @headless.overlay(
        layer,
        on_dismiss,
        modal~,
        dismiss_on_escape~,
        dismiss_on_outside~,
        inert~,
        anchor?,
        label?,
        made_for=loc,
        fn(v, o) {
          small_panel_node(v) |> ignore
          place(v)
          body(v, o)
        },
      ),
    )
  })
  |> ignore
  card.val.unwrap()
}

///|
/// A full-window modal overlay layer in `node` (`@headless.overlay(..., modal=true, dismiss_on_outside=false,
/// in_node=true)`): registers `node` on the window tree's unified overlay stack (`@headless.overlays_open`) and wires
/// `.over(Is(true))`, modal input blocking, inert hiding, and Escape / system Back dismissal (`on_dismiss`).
/// - `dismiss_on_escape`: defaults to `true`; pass `false` for hosts that own Escape (e.g. Terminal / Browser), and
///   wire `takes_back` separately if needed.
/// - `auto_focus` / `first_takes`: defaults to `false`; set `auto_focus=true` (and optional `first_takes`) to focus
///   into the layer as it opens.
/// - `before_dismiss`: returns `true` to consume Escape / Back without calling `on_dismiss` (e.g. while busy).
/// - `on_key`: optional key handler receiving `(key, dismiss_escape)` so a fullscreen layer with extra shortcuts can
///   still route Escape through the overlay stack's topmost-layer check.
#callsite(autofill(loc))
pub fn fullscreen_overlay_node(
  node : @view.View,
  on_dismiss : () -> Unit,
  inert? : () -> Bool = fn() { false },
  dismiss_on_escape? : Bool = true,
  auto_focus? : Bool = false,
  first_takes? : (@view.Said) -> Bool,
  before_dismiss? : () -> Bool,
  on_key? : (@view.Key, () -> Bool) -> Bool,
  loc~ : SourceLoc,
) -> @view.View {
  let ov_ref : Ref[@headless.Overlay?] = Ref(None)
  @headless.overlay(
    node,
    fn(_) { on_dismiss() },
    fn(v, ov) {
      ov_ref.val = Some(ov)
      v.over(Is(true), loc~) |> ignore
    },
    modal=true,
    inert~,
    dismiss_on_escape~,
    dismiss_on_outside=false,
    auto_focus~,
    first_takes?,
    before_dismiss?=match before_dismiss {
      Some(f) => Some(fn(_) { f() })
      None => None
    },
    in_node=true,
    made_for=loc,
  )
  |> ignore
  if on_key is Some(handler) {
    let dismiss_escape = fn() {
      if dismiss_on_escape &&
        ov_ref.val is Some(ov) &&
        @signals.untracked(fn() { ov.is_top() }) {
        if before_dismiss is Some(f) && @signals.untracked(f) {
          return true
        }
        ov.dismiss(Escape)
        true
      } else {
        false
      }
    }
    node.on_key(fn(k) { handler(k, dismiss_escape) }) |> ignore
  }
  node
}
