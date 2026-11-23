// Window-level coordinator for transient overlays (hover cards, hover panels, standalone submenus, and tooltips):
// enforces strict mutual exclusion among L1 transient surfaces, clears external L2 tooltips when an L1 surface or
// modal presenter opens, and resolves the unified Z-order hover layer (page-level `stacked(0)` below presented
// modals, or each presented row's own hover layer above its modal body and below higher modals/tips).

///|
priv struct TransientSlot {
  id : Int
  holder : () -> @view.View?
  is_held : () -> Bool
  close : () -> Unit
}

///|
priv struct TransientTip {
  id : Int
  anchor : @view.View
  close : () -> Unit
}

///|
// kept across runs: put back as a run begins (on_reset) and per window (presented_windows.mbt)
let transient_seq : Ref[Int] = Ref(0)

///|
// kept across runs: put back as a run begins (on_reset) and per window (presented_windows.mbt)
let transient_active : Ref[TransientSlot?] = Ref(None)

///|
// kept across runs: put back as a run begins (on_reset) and per window (presented_windows.mbt)
let transient_tip_active : Ref[TransientTip?] = Ref(None)

///|
// kept across runs: put back as a run begins (on_reset) and per window (presented_windows.mbt)
let window_hover_at : Ref[@view.View?] = Ref(None)

///|
// kept across runs: put back as a run begins (on_reset) and per window (presented_windows.mbt)
let window_hover_root : Ref[(@view.View, SourceLoc)?] = Ref(None)

///|
// kept across runs: what each hover card/panel lends its body so embedded submenu rows belong to its scope
let transient_parent_lent : @view.Lent[Int] = @view.Lent::new()

///|
// kept across runs: what each presented row lends its body for hover overlays above that panel alone
let panel_hover_lent : @view.Lent[TipLayer] = @view.Lent::new()

///|
fn init {
  @ui.on_reset(fn() {
    transient_seq.val = 0
    transient_active.val = None
    transient_tip_active.val = None
    window_hover_at.val = None
    window_hover_root.val = None
  })
}

///|
/// Allocates a monotonically increasing transient overlay identifier within the current window.
fn transient_next_id() -> Int {
  transient_seq.val += 1
  transient_seq.val
}

///|
/// Closes the active L2 tooltip unless its anchor lives inside `holder`.
fn transient_clear_tip_outside(holder : @view.View?) -> Unit {
  match transient_tip_active.val {
    Some(tip) => {
      let inside = match holder {
        Some(h) if h.alive() && tip.anchor.alive() => h.tree.holds(h.id(), tip.anchor.id())
        _ => false
      }
      if !inside {
        transient_tip_active.val = None
        (tip.close)()
      }
    }
    None => ()
  }
}

///|
/// Claims the window's single active L1 transient slot for `id`, closing any previous L1 surface and any external L2 tooltip.
fn transient_claim(
  id : Int,
  holder : () -> @view.View?,
  is_held : () -> Bool,
  close : () -> Unit,
) -> Unit {
  match transient_active.val {
    Some(prev) if prev.id != id => {
      transient_active.val = None
      (prev.close)()
    }
    _ => ()
  }
  transient_clear_tip_outside(holder())
  transient_active.val = Some({ id, holder, is_held, close })
}

///|
/// Releases the window's active L1 transient slot if `id` currently holds it.
fn transient_release(id : Int) -> Unit {
  match transient_active.val {
    Some(cur) if cur.id == id => transient_active.val = None
    _ => ()
  }
}

///|
/// Dismisses any active L2 tooltip and any active L1 transient overlay when a modal presenter opens, except when the
/// L1 overlay is held open or the new presenter is anchored inside that L1 overlay (e.g. a picker opened from a hover card).
fn transient_dismiss_for_present(from : Anchor) -> Unit {
  transient_clear_tip_outside(None)
  match transient_active.val {
    Some(slot) => {
      let keep_held = @signals.untracked(slot.is_held)
      let from_inside = match (from, (slot.holder)()) {
        (Node(v), Some(h)) => h.alive() && v.alive() && h.tree.holds(h.id(), v.id())
        (At(x, y, w, h0), Some(h)) if h.alive() => {
          let cx = x + w / 2.0
          let cy = y + h0 / 2.0
          match h.tree.target_at(cx, cy) {
            Pressed(id) | Dragged(id) => h.tree.holds(h.id(), id)
            _ => false
          }
        }
        _ => false
      }
      if !keep_held && !from_inside {
        transient_active.val = None
        (slot.close)()
      }
    }
    None => ()
  }
}

///|
/// Registers the currently visible L2 tooltip so L1 overlays and presenters can dismiss it when external.
fn transient_tip_register(id : Int, anchor : @view.View, close : () -> Unit) -> Unit {
  transient_tip_active.val = Some({ id, anchor, close })
}

///|
/// Releases the L2 tooltip registration if `id` currently holds it.
fn transient_tip_release(id : Int) -> Unit {
  match transient_tip_active.val {
    Some(cur) if cur.id == id => transient_tip_active.val = None
    _ => ()
  }
}

///|
/// Lends `layer` (a modal presenter's own layer node) as the transient hover layer for its body so hover cards sit
/// inside its modal subtree (never blocked by its own modal), after its body (drawn above it, Escape handled first),
/// and strictly below higher presented serials and tips.
fn panel_hover_lend(layer : @view.View) -> Unit {
  layer.lends(panel_hover_lent, TipLayer::new(fn() { if layer.alive() { Some(layer) } else { None } })) |> ignore
}

///|
/// Lazily creates the page-level `stacked(0)` transient hover layer on first hover so non-hovering screens (such as
/// phones) pay zero node overhead on initial open.
fn window_hover_ensure(v : @view.View) -> @view.View? {
  match window_hover_at.val {
    Some(l) if l.alive() && v.tree.root_holds(l.id()) => Some(l)
    _ =>
      match window_hover_root.val {
        Some((root, loc)) if root.alive() && physical_equal(root.tree, v.tree) => {
          let l = root.box(made_for=loc, fn(l) { l.over(Is(true)).stacked(Is(0)) |> ignore })
          window_hover_at.val = Some(l)
          Some(l)
        }
        _ => None
      }
  }
}

///|
/// Resolves the unified transient hover layer for node `v`: inside a presented panel/sheet/dialog, that row's own
/// hover layer (above its modal body, below higher modals and tips); on the page, the window's `stacked(0)` hover
/// layer (above page content, below all presented modals and tips); `None` in standalone trees without `presented_nodes`.
pub fn transient_layer_of(v : @view.View) -> TipLayer {
  let panel_layer = v.lent(panel_hover_lent)
  TipLayer::new(fn() {
    match panel_layer {
      Some(l) =>
        match (l.layer)() {
          Some(_) as hit => return hit
          None => ()
        }
      None => ()
    }
    window_hover_ensure(v)
  })
}

///|
/// Clear gap between a trigger control and its floating overlay (`@ui.Space::S1_5`).
pub let floating_trigger_gap : Double = 6.0

///|
/// Outer-edge-to-outer-edge clear gap between a floating surface or side panel and a side-mounted secondary overlay
/// (`@ui.Space::S2`).
pub let floating_surface_gap : Double = 8.0

///|
/// Minimum safety inset between any floating overlay and the window viewport edges (`@ui.Space::S2`).
pub let floating_viewport_pad : Double = 8.0

///|
// kept across runs: what each floating surface or side panel lends its subtree so side-mounted overlays clear its outer edge
let floating_host_lent : @view.Lent[@view.View] = @view.Lent::new()

///|
/// Registers `surface` as the outer floating host for its subtree so side-mounted secondary overlays (`Left`/`Right`)
/// align to `surface`'s outer edge with `floating_surface_gap` clear space.
pub fn floating_host_lend(surface : @view.View) -> Unit {
  surface.lends(floating_host_lent, surface) |> ignore
}

///|
/// Resolves the optional outer host node and effective offset for a floating overlay placed on `side` of `anchor`.
fn floating_anchor_beside(anchor : @view.View, side : @view.Side, base_offset : Double) -> (@view.NodeId?, Double) {
  if side == Left || side == Right {
    match anchor.lent(floating_host_lent) {
      Some(h) if h.alive() => (Some(h.id()), dmax(base_offset, floating_surface_gap))
      _ => (None, base_offset)
    }
  } else {
    (None, base_offset)
  }
}

///|
/// Routes hover cards/panels that were given the global window tips layer (`window_tips()` / `panel_tips_of`) onto
/// `transient_layer_of(anchor)` while preserving explicit custom `TipLayer`s used by standalone tests.
fn transient_resolve_layer(layer : TipLayer, anchor : @view.View) -> @view.View? {
  let given = (layer.layer)()
  let is_window_tips = match (given, window_tips_at.val) {
    (Some(g), Some(wt)) => g.id() == wt.id()
    _ => false
  }
  if is_window_tips {
    match (transient_layer_of(anchor).layer)() {
      Some(l) => Some(l)
      None => given
    }
  } else {
    given
  }
}
