// A card over what the pointer rests on (sfpages' hover, kit's hover_card, the web's Peeks.tsx Hover) as nodes of the
// window's tree: opened once a mouse's pointer has rested on what it is of hover_card_open_ms (carrying no press: one
// let go there rests from then), kept while the pointer is on that or on the card, closed hover_card_close_ms after it
// has left both; a finger, which rests on nothing, holds what it is of (its press's long press) to open it, and it stays
// till a press outside it and what it is of, or Escape. Closed at once by Escape, by a press outside both, and as what
// it is of takes input no more (said to take no press, leaving, under a modal layer: View::takes_input) or goes; kept
// open by the app (`held`), by none of these. Each
// of these at its cause's moment: a rest's end and a leave's a moment of the timeline said from the cause, the hand's
// state as it is then; nothing read of the hand or the clock as anything is made. Drawn in its layer (over all of the
// window) beside what it is of (View::beside: under it, at its start, 6 off), a small panel 320 wide (a tile: as wide as
// what it holds, 220 to 420), what it holds 10 in from its padding (or at it); grown out of that edge from .96 and
// clear over 160 ms as it comes, to .97 and clear over 90 ms as it goes, its ground first.

///|
/// How long a mouse's pointer rests on what a card is of before it opens, and how long after it has left both that
/// and the card it closes (Radix's HoverCard as Peeks.tsx sets it: sfpages' hover_open_ms, hover_close_ms).
pub let hover_card_open_ms : Double = 320.0

///|
pub let hover_card_close_ms : Double = 120.0

///|
/// How far a card is from what it is of.
let hover_card_offset : Double = 6.0

///|
/// How a card comes (pop_in: faded in, grown from .97, eased out over 140 ms) and goes (pop_out: to .97, eased to leave
/// over 100 ms), its ground first, then what it holds.
// kept across runs: a value (no field of it changes)
let hover_card_in : @motion.Trans = @motion.pop_in

///|
// kept across runs: a value (no field of it changes)
let hover_card_out : @motion.Trans = @motion.pop_out

///|
let hover_card_in_ms : Double = @motion.pop_ms

///|
pub let hover_card_out_ms : Double = @motion.pop_out_ms

///|
/// What is done with a card (hover_card_node's) by what it is of or by what is in it: opened as a finger's hold opens
/// it (`hold`: till a press outside it and what it is of, or Escape), closed (`close`), whether it is open now
/// (`open`, followed), and the card while it is made (`card`, followed: what is opened from what it holds stands beside
/// it, `Node(card)`).
pub struct HoverHand {
  hold : () -> Unit
  close : () -> Unit
  open : () -> Bool
  card : () -> @view.View?
}

///|
/// A card holding what `body` makes, of node `anchor`, drawn in `layer` (the window's layer over all of it, a tip's:
/// its node as the card is first opened), opened and closed as the file's head says. `tile`: as wide as what it holds
/// (220 to 420), not 320; `padded`: what it holds 10 in from its padding, else at it (for rows to lie there); `side`,
/// `along`: where it stands of `anchor`; `along_offset`: that much further along its side (a card of words, its own
/// words starting where they start: sfpages' hover's `words_along`); `piece`: beside that piece of `anchor`, not all of
/// it (a link in its words: View::beside's). `held`: kept open meanwhile, whatever the pointer does, through a press
/// outside, Escape and its anchor taking no input (what was pressed in it opened something beside it the pointer goes
/// on to, a modal panel over its anchor, pressed in), as kit's hover_card's `held`; let go, as the pointer is then. A
/// row of it opening a menu beside it (submenu_row_node) holds it so while that is open, without being said.
/// `press`: what a press on `anchor` does, every input's (a tap, a click, Enter), `anchor` then taking presses;
/// `tapped`: what a finger's tap on `anchor` does in place of `press` (a station's card from the presenters, a finger
/// resting on nothing); said alone, `anchor` takes presses from a finger only, a mouse's press there what holds it's (a
/// bar dragging the window). A finger's long press on `anchor` opens the card whether it is pressed or not (kit's
/// hover_card: held_long of any trigger); one said neither answers a hold and nothing else (View::gesture's
/// hold alone): a tap, a click or a drag on it is what holds it's as ever (a row pressed to open, a bar dragged), the
/// finger its once held still that long; held by a finger, it is held to the room a press takes as anything pressed is
/// (t.audit()'s `room`): what it is put in gives it that room (a bar as high as a press's), not this part. Closed with the focus in
/// it, the focus goes back to `anchor` (where that takes it). `pointed`: a mouse's pointer on what it is of as that
/// says (a piece of `anchor`: a link of its words, @ui.runs_links' `pointed`), in place of on `anchor`, a press as it
/// goes down there not one outside; and nothing of the hand put on `anchor` (`press`, `tapped` and a finger's hold
/// none of its: what holds it says them, a finger's hold opening it by the hand's `hold`). `yields_to`: a mouse's pointer
/// on that or on what it holds (View::pointed_in) not on `anchor`, wherever it is within it: what beside `anchor`
/// reaches over it (a key's room over a tag, a press there that key's) answers there alone, its card the one that
/// opens (lit_within_node's). `owner`: what it is made
/// and let go with (a card of a piece of `anchor`, as that piece comes and goes), `anchor` where not said. The hand
/// the card is opened and closed by.
#callsite(autofill(loc))
pub fn hover_card_node(
  layer : TipLayer,
  anchor : @view.View,
  body : (@view.View) -> Unit,
  tile? : Bool = false,
  padded? : Bool = true,
  side? : @view.Side = Bottom,
  along? : @view.Along = Start,
  along_offset? : Double = 0.0,
  piece? : (Double, Double) -> (Double, Double, Double, Double)?,
  held? : () -> Bool = fn() { false },
  press? : () -> Unit,
  tapped? : () -> Unit,
  pointed? : () -> Bool,
  yields_to? : @view.View,
  owner? : @view.View,
  loc~ : SourceLoc,
) -> HoverHand {
  let owner = owner.unwrap_or(anchor)
  // (a row of it opening a menu beside it (submenu_row_node): its menu open, the card kept open as by `held`, the pointer
  // gone on to the menu, outside the card; as kit's hover_card was held by what opened from it)
  let row_open : @signals.Signal[@view.View?] = @signals.signal_by(None, same=same_view)
  let held = fn() { held() || row_open.get() is Some(_) }
  let open : @signals.Signal[Bool] = @signals.signal(false, same=fn(a, b) { a == b })
  // (opened by a finger's hold: stays till a press outside, Escape, or its anchor takes no input)
  let by_hand = Ref(false)
  // (the card's panel while it is made: what the pointer may be on)
  let card : @signals.Signal[@view.View?] = @signals.signal_by(None, same=fn(a, b) {
    match (a, b) {
      (None, None) => true
      (Some(x), Some(y)) => x.id() == y.id()
      _ => false
    }
  })
  // (how far it is in, and which way it goes: in as hover_card_in, out as hover_card_out)
  let way = @motion.NodeWay::new(0.0)
  // (what the card it opens holds made first, what it reads then waited for before it comes in: OpenGate; a card
  // made anew each time it opens from none)
  let gate : Ref[OpenGate] = Ref(OpenGate::new())
  // (the moment pending: its rest's end while closed, its leave's while open)
  let due : Ref[(() -> Unit)?] = Ref(None)
  let stop_due = fn() {
    match due.val {
      Some(s) => s()
      None => ()
    }
    due.val = None
  }
  let made = Ref(false)
  let holder_v : Ref[@view.View?] = Ref(None)
  let set_open : Ref[(Bool) -> Unit] = Ref(fn(_) {  })
  let make = fn() -> Bool {
    guard (layer.layer)() is Some(l) else { return false }
    let holder = l.box(made_for=loc, fn(h) { h.transitions_only().over(Is(true)) |> ignore }).lives_with(owner)
    holder_v.val = Some(holder)
    holder.on_key(fn(k) {
      if k.code == @ui.key_escape && open.untracked() && !@signals.untracked(held) {
        (set_open.val)(false)
        true
      } else {
        false
      }
    })
    |> ignore
    // (a press anywhere in the window but on the card or on what it is of: closed as it goes down, the press what it
    // lands on's as ever; the window's presses read only while it is open and not kept open, so a card shut again
    // follows none of them, and its coming to be read is no press)
    let downs_was : Ref[Int?] = Ref(None)
    holder.reacts(fn() { if open.get() && !held() { Some(holder.window_downs()) } else { None } }, at_start=false, fn(
      now,
    ) {
      let was = downs_was.val
      downs_was.val = now
      guard was is Some(_) && now is Some(_) else { return }
      // (kept open by the app: what the press lands on is what was opened from it)
      guard open.untracked() && !@signals.untracked(held) else { return }
      let (x, y) = holder.window_down_point()
      let on = fn(v : @view.View?) {
        match v {
          Some(p) =>
            match p.tree.target_at(x, y) {
              Pressed(id) | Dragged(id) => p.tree.holds(p.id(), id)
              _ => false
            }
          None => false
        }
      }
      let on_anchor = match pointed {
        Some(p) => @signals.untracked(p)
        None => on(Some(anchor))
      }
      if !(on(card.untracked()) || on_anchor) {
        (set_open.val)(false)
      }
    })
    holder.show(fn() { open.get() }, leave=hover_card_out_ms, fn(t) {
      card.set(Some(t))
      t.owns(fn() {
        match card.untracked() {
          Some(c) if c.id() == t.id() => card.set(None)
          _ => ()
        }
      })
      |> ignore
      let look = fn() {
        let p = way.shown(t)
        (if way.target() > 0.5 { hover_card_in } else { hover_card_out }).at(p, p)
      }
      small_panel_node(t)
      .beside(anchor.id(), side~, along~, offset=hover_card_offset, padding=8.0, piece?, along_offset~)
      .width(Is(if tile { None } else { Some(hover_card_px) }))
      .min_width(Is(if tile { Some(hover_tile_least_px) } else { None }))
      .max_width(By(fn() { Some(if tile { dmin(hover_tile_most_px, over_room(t).0 - 16.0) } else { over_room(t).0 - 16.0 }) }))
      .max_height(By(fn() { Some(dmax(0.0, over_room(t).1 - 16.0)) }))
      .alpha(By(fn() { look().alpha }))
      .scale(By(fn() { look().sx }), about=FromBeside, max_shift=pop_max_shift)
      .carries_until(fn() { way.ends_at() })
      .says(Is(Some(@view.said(Group))))
      // (closed with the focus in it: back to what it is of, not to what had it as it opened)
      .focus_returns()
      .opened_by(@view.ByNode(anchor.id()))
      // (a press on it its own, the pointer on it on it, a press there nothing outside it: a ground, the library's panels'
      // (ground_node), the arrow over it; what it holds that is pressed, the hand as ever)
      |> ground_node
      |> ignore
      // (its submenu rows' one open: row_open; their menus made in the card's own layer over the window, not in what
      // it scrolls, which would cut them and what takes their presses)
      t.lends(panel_submenus_lent, row_open) |> ignore
      t.lends(submenu_layer_lent, holder) |> ignore
      gate.val.collect(fn() {
      t.box(fn(b) {
        b.alpha(By(fn() { look().words })) |> ignore
        b.scrolls(@view.Scroll::new(), slop=@ui.touch_slop(), bar=@ui.tree_scroll_bar(), fn(s) {
          s.box(fn(inner) {
            inner.fills_across(Is(true)) |> ignore
            if padded {
              let p = @ui.Space::px(S2_5)
              inner.padding(Is((p, p, p, p))).gap(Is(@ui.Space::px(S2))) |> ignore
            }
            body(inner)
          })
          |> ignore
        })
        |> ignore
      })
      |> ignore
      })
      gate.val.seal(t)
    })
    true
  }
  set_open.val = fn(on : Bool) {
    stop_due()
    if !on {
      by_hand.val = false
    }
    if on == open.untracked() {
      return
    }
    if on && !made.val {
      made.val = make()
      guard made.val else { return }
    }
    if on {
      // (none made: made as it is opened, coming in once what it holds is: OpenGate; one still going, at once)
      if card.untracked() is None {
        gate.val = OpenGate::new()
      }
      gate.val.go(anchor, fn() { way.go_ms(anchor, 1.0, hover_card_in_ms, ease=Out) })
    } else {
      gate.val.stop()
      way.go_ms(anchor, 0.0, hover_card_out_ms, ease=Leave)
    }
    match holder_v.val {
      Some(h) if h.alive() => @view.transition(within=h, fn() { open.set(on) })
      _ => open.set(on)
    }
  }
  // (what decides it, as of each cause: a mouse's pointer on what it is of or on the card, a press held anywhere in
  // the window (View::window_held: one carried onto it from elsewhere, or one on it that is not its, a bar's dragging
  // the window, rests on nothing till it is let go, as kit's hover_card's `c.press().down`), whether it takes input, whether it is held open; one a mouse does not press (no `press`), by where the pointer is
  // within it, what a press there is for being another's)
  let takes = fn() { anchor.takes_input() }
  let state = fn() {
    let mouse = @ui.pointing() is Mouse
    let keep = held()
    // (closed, not kept open, no mouse's pointer to rest on it: nothing the window's presses or whether it takes input
    // would change, so neither is read, and a finger's press anywhere in the window wakes none of its kind)
    if !mouse && !keep && !open.get() {
      return (false, false, false, true, false)
    }
    let on_anchor = mouse &&
      (
        match pointed {
          Some(p) => p()
          None => anchor.pointed_in()
        }
      ) &&
      !yielded(yields_to)
    let on_card = mouse &&
      (
        match card.get() {
          Some(c) => c.pointed_in()
          None => false
        }
      )
    (on_anchor, on_card, anchor.window_held(), takes(), keep)
  }
  let rests_was = Ref(false)
  owner.reacts(state, fn(s) {
    let (on_anchor, on_card, pressed, takes, keep) = s
    let at = owner.cause_at()
    let rests = on_anchor && !pressed
    let rests_now = rests && !rests_was.val
    rests_was.val = rests
    // (taking no input: closed, unless kept open by the app (what it opened, a modal panel beside it, over its anchor))
    if !takes && !keep {
      (set_open.val)(false)
      return
    }
    if open.untracked() {
      // (opened by a finger, or kept open: none of the pointer's to close it)
      if by_hand.val || keep || on_anchor || on_card {
        stop_due()
      } else if due.val is None {
        // (left both: closed a while from now, the pointer as it is then)
        due.val = Some(
          owner.at_moment(at + hover_card_close_ms, fn() {
            due.val = None
            let (a, c, _, _, k) = @signals.untracked(state)
            if !(a || c || k || by_hand.val) {
              (set_open.val)(false)
            }
          }),
        )
      }
    } else if rests_now {
      // (rested on a while from now: opened then, the pointer as it is then)
      stop_due()
      due.val = Some(
        owner.at_moment(at + hover_card_open_ms, fn() {
          due.val = None
          let (a, _, p, t, _) = @signals.untracked(state)
          if a && !p && t {
            (set_open.val)(true)
          }
        }),
      )
    } else if !rests {
      stop_due()
    }
  })
  let hold = fn() {
    (set_open.val)(true)
    by_hand.val = true
  }
  // (a finger held on it long_press_ms opens the card, on any anchor, as kit's hover_card's held_long)
  let on_held = fn(_d : @view.Drag) {
    if @ui.pointing() is Finger {
      hold()
    }
  }
  match (press, tapped) {
    // (its pointer said: nothing of the hand put on it, what holds it says that)
    _ if pointed is Some(_) => ()
    // (said neither: a hold and nothing else (View::gesture's hold alone): a press or a drag on it what holds it's as
    // ever (a row pressed to open, a bar dragged), the finger its once held still that long)
    (None, None) => anchor.points(Is(true)).gesture(@ui.touch_slop(), hold=(@ui.long_press_ms, on_held)) |> ignore
    _ => {
      // (pressed: a tap, a click or Enter does `press` (a finger's tap `tapped` where it is said); a mouse's long press
      // is still a click as it is let go on it, as an icon button's)
      let pressed = fn() {
        match press {
          Some(f) => f()
          None => ()
        }
      }
      let tap = fn() {
        match (tapped, @ui.pointing()) {
          (Some(f), Finger) => f()
          _ => pressed()
        }
      }
      let held_now = Ref(false)
      let on_it = fn(d : @view.Drag) { anchor.finger_target(d.wx, d.wy) }
      // (said `press`, every input's; said `tapped` alone, a finger's only: a mouse's press there what holds it's as
      // ever, a bar's dragging the window, as the current input changes)
      if press is Some(_) {
        anchor.presses(Is(true)).on_press(pressed) |> ignore
      } else {
        anchor.presses(Is(true)).points(By(fn() { @ui.pointing() is Mouse })).on_press(pressed) |> ignore
      }
      anchor.gesture(
        @ui.touch_slop(),
        tap=fn(d) { if on_it(d) { tap() } },
        hold=(
          @ui.long_press_ms,
          fn(d) {
            held_now.val = true
            on_held(d)
          },
        ),
        drag=fn(d) {
          if !held_now.val {
            if d.kind == Up && @ui.pointing() is Mouse && on_it(d) {
              pressed()
            }
          } else if d.kind == Up || d.kind == Off {
            held_now.val = false
            if d.kind == Up && @ui.pointing() is Mouse && on_it(d) {
              pressed()
            }
          }
        },
      )
      |> ignore
    }
  }
  // (let go: nothing of it left pending)
  owner.owns(fn() {
    stop_due()
    way.put(0.0)
  })
  |> ignore
  { hold, close: fn() { (set_open.val)(false) }, open: fn() { open.get() }, card: fn() { card.get() } }
}

///|
/// A card's width (sf's hover_card_w), and a tile's least and most (hover_tile_least, hover_tile_most), in points.
let hover_card_px : Double = match hover_card_w {
  Fixed(v) => v
  _ => 320.0
}

///|
let hover_tile_least_px : Double = match hover_tile_least {
  Fixed(v) => v
  _ => 220.0
}

///|
let hover_tile_most_px : Double = match hover_tile_most {
  Fixed(v) => v
  _ => 420.0
}

///|
/// Default hover panel open and close delays (ms).
pub let hover_panel_open_ms : Double = 180.0

///|
pub let hover_panel_close_ms : Double = 160.0

///|
/// Geometry and timing of a hover panel (hover_panel_node, hover_panel_old_hover): width, share of window height
/// (`tall`, 0 for natural height), placement relative to anchor (`side`, `along`, `offset`), and open/close delays.
pub(all) struct HoverPanelSpec {
  w : Double
  tall : Double
  side : @view.Side
  along : @view.Along
  offset : Double
  open_delay : Double
  close_delay : Double
}

///|
/// Default hover panel specification (420 wide, 65% window tall, Left/Middle, 8 pt offset, 180 ms open, 160 ms close).
pub fn hover_panel_spec(
  w? : Double = confirm_w,
  tall? : Double = 0.65,
  side? : @view.Side = Left,
  along? : @view.Along = Middle,
  offset? : Double = 8.0,
  open_delay? : Double = hover_panel_open_ms,
  close_delay? : Double = hover_panel_close_ms,
) -> HoverPanelSpec {
  { w, tall, side, along, offset, open_delay, close_delay }
}

///|
/// Shared visual surface of a hover panel: matches panel_node's small panel shell (width, height, padding, corner,
/// ground, edge, shadow, clips, pop_in/pop_out FromBeside, title bar, and non-scrolling body column with panel_in_lend
/// so an inner panel_list_node virtualizes on its own).
#callsite(autofill(loc))
fn hover_panel_surface(
  t : @view.View,
  holder : @view.View,
  anchor_id : @view.NodeId,
  opened : @view.Opener?,
  title : String,
  body : (@view.View, () -> Unit) -> Unit,
  spec : HoverPanelSpec,
  way : @motion.NodeWay,
  gate : Ref[OpenGate],
  row_open : @signals.Signal[@view.View?],
  close : () -> Unit,
  loc~ : SourceLoc,
) -> Unit {
  let look = fn() {
    let p = way.shown(t)
    (if way.target() > 0.5 { hover_card_in } else { hover_card_out }).at(p, p)
  }
  let live = fn() { !t.leaving() }
  t
  .beside(anchor_id, side=spec.side, along=spec.along, offset=spec.offset, padding=8.0, holds_side=true)
  .width(Is(Some(spec.w)))
  .max_width(By(fn() { Some(dmax(0.0, over_room(t).0 - 16.0)) }))
  .max_height(By(fn() { Some(dmax(0.0, over_room(t).1 - 16.0)) }))
  .height(By(fn() {
    if spec.tall > 0.0 {
      Some(dmin(spec.tall * over_room(t).1, dmax(0.0, over_room(t).1 - 16.0)))
    } else {
      None
    }
  }))
  .padding(Is((panel_pad, panel_pad, panel_pad, panel_pad)))
  .radius(Is(r_menu))
  .ground(By(fn() { panel_ground() }))
  .edge(By(fn() { (1.0, panel_edge()) }))
  .shadow(By(fn() { float_shadow() }))
  .clips(Is(true))
  .alpha(By(fn() { look().alpha }))
  .scale(By(fn() { look().sx }), about=FromBeside, max_shift=pop_max_shift)
  .carries_until(fn() { way.ends_at() })
  .hides(By(fn() { t.leaving() }))
  .in_use(By(live))
  .says(Is(Some(@view.said(Dialog, label=title))))
  .focus_returns()
  |> ground_node
  |> ignore
  match opened {
    Some(o) => t.opened_by(o) |> ignore
    None => ()
  }
  t.lends(panel_submenus_lent, row_open) |> ignore
  t.lends(submenu_layer_lent, holder) |> ignore
  gate.val.collect(fn() {
    if title != "" {
      t.box(made_for=loc, fn(h) {
        style_node(h, fn() { panel_part_in(panel_pad, 0.0) })
        h.margin(Is((-panel_pad, -panel_pad, -panel_pad, 0.0))).alpha(By(fn() { look().words })) |> ignore
        h.box(fn(b) {
          style_node(b, fn() { panel_head_box })
          words_node(b, fn() { title }, fn() { panel_title }) |> ignore
        })
        |> ignore
      })
      |> ignore
    }
    let over = if title != "" { 0.0 } else { panel_pad }
    t.box(made_for=loc, fn(b) {
      b
      .grow(Is(1.0))
      .basis(Is(Some(0.0)))
      .min_height(Is(Some(0.0)))
      .margin(Is((-panel_pad, -over, -panel_pad, -panel_pad)))
      |> ignore
      b.box(fn(col) {
        style_node(col, fn() { panel_grows.then(panel_part_in(over, panel_pad)) })
        col.grow(Is(1.0)).alpha(By(fn() { look().words })) |> ignore
        panel_in_lend(col, Wide, text_in, sides=panel_pad, small=true)
        body(col, close)
      })
      |> ignore
    })
    |> ignore
  })
  gate.val.seal(t)
}

///|
/// An interactive hover panel beside node `anchor`, lazily created in `layer` on first open (0 nodes while closed).
/// Opens after mouse rests on `anchor` for `spec.open_delay`; stays open while pointer is on `anchor` or panel, or
/// while `held()` is true (e.g. a search field focused or non-empty); closes `spec.close_delay` after pointer leaves
/// both and `!held()`. Escape, an outside press, or `anchor.takes_input()` becoming false closes it immediately
/// (unless a submenu inside it is open). When `pointed` is supplied, `anchor`'s gesture is untouched.
#callsite(autofill(loc))
pub fn hover_panel_node(
  layer : TipLayer,
  anchor : @view.View,
  title : String,
  body : (@view.View, () -> Unit) -> Unit,
  spec? : HoverPanelSpec = hover_panel_spec(),
  held? : () -> Bool = fn() { false },
  pointed? : () -> Bool,
  owner? : @view.View,
  loc~ : SourceLoc,
) -> HoverHand {
  let owner = owner.unwrap_or(anchor)
  let row_open : @signals.Signal[@view.View?] = @signals.signal_by(None, same=same_view)
  let open : @signals.Signal[Bool] = @signals.signal(false, same=fn(a, b) { a == b })
  let by_hand = Ref(false)
  let card : @signals.Signal[@view.View?] = @signals.signal_by(None, same=fn(a, b) {
    match (a, b) {
      (None, None) => true
      (Some(x), Some(y)) => x.id() == y.id()
      _ => false
    }
  })
  let way = @motion.NodeWay::new(0.0)
  let gate : Ref[OpenGate] = Ref(OpenGate::new())
  let due : Ref[(() -> Unit)?] = Ref(None)
  let stop_due = fn() {
    match due.val {
      Some(s) => s()
      None => ()
    }
    due.val = None
  }
  let made = Ref(false)
  let dismissed = Ref(false)
  let holder_v : Ref[@view.View?] = Ref(None)
  let set_open : Ref[(Bool) -> Unit] = Ref(fn(_) {  })
  let close_explicit : Ref[() -> Unit] = Ref(fn() {  })
  let make = fn() -> Bool {
    guard (layer.layer)() is Some(l) else { return false }
    let holder = l.box(made_for=loc, fn(h) { h.transitions_only().over(Is(true)) |> ignore }).lives_with(owner)
    holder_v.val = Some(holder)
    holder.on_key(fn(k) {
      if k.code == @ui.key_escape && open.untracked() && row_open.untracked() is None {
        (close_explicit.val)()
        true
      } else {
        false
      }
    })
    |> ignore
    let downs_was : Ref[Int?] = Ref(None)
    holder.reacts(fn() { if open.get() && row_open.get() is None { Some(holder.window_downs()) } else { None } }, at_start=false, fn(
      now,
    ) {
      let was = downs_was.val
      downs_was.val = now
      guard was is Some(_) && now is Some(_) else { return }
      guard open.untracked() && row_open.untracked() is None else { return }
      let (x, y) = holder.window_down_point()
      let on = fn(v : @view.View?) {
        match v {
          Some(p) =>
            match p.tree.target_at(x, y) {
              Pressed(id) | Dragged(id) => p.tree.holds(p.id(), id)
              _ => false
            }
          None => false
        }
      }
      let on_anchor = match pointed {
        Some(p) => @signals.untracked(p)
        None => on(Some(anchor))
      }
      if !(on(card.untracked()) || on_anchor) {
        (set_open.val)(false)
      }
    })
    holder.show(fn() { open.get() }, leave=hover_card_out_ms, fn(t) {
      t.owns(fn() {
        match card.untracked() {
          Some(c) if c.id() == t.id() => card.set(None)
          _ => ()
        }
      })
      |> ignore
      hover_panel_surface(
        t,
        holder,
        anchor.id(),
        Some(@view.ByNode(anchor.id())),
        title,
        body,
        spec,
        way,
        gate,
        row_open,
        fn() { (close_explicit.val)() },
        loc~,
      )
      card.set(Some(t))
    })
    true
  }
  set_open.val = fn(on : Bool) {
    stop_due()
    if !on {
      by_hand.val = false
    }
    if on == open.untracked() {
      return
    }
    if on && !made.val {
      made.val = make()
      guard made.val else { return }
    }
    if on {
      if card.untracked() is None {
        gate.val = OpenGate::new()
      }
      gate.val.go(anchor, fn() { way.go_ms(anchor, 1.0, hover_card_in_ms, ease=Out) })
    } else {
      gate.val.stop()
      way.go_ms(anchor, 0.0, hover_card_out_ms, ease=Leave)
    }
    match holder_v.val {
      Some(h) if h.alive() => @view.transition(within=h, fn() { open.set(on) })
      _ => open.set(on)
    }
  }
  let takes = fn() { anchor.takes_input() }
  let state = fn() {
    let mouse = @ui.pointing() is Mouse
    let sub = row_open.get() is Some(_)
    let keep = held() || sub
    if !mouse && !keep && !open.get() {
      return (false, false, false, true, false, false)
    }
    let on_anchor = mouse &&
      (
        match pointed {
          Some(p) => p()
          None => anchor.pointed_in()
        }
      )
    let on_card = mouse &&
      (
        match card.get() {
          Some(c) => c.pointed_in()
          None => false
        }
      )
    (on_anchor, on_card, anchor.window_held(), takes(), keep, sub)
  }
  let rests_was = Ref(false)
  let takes_was = Ref(true)
  owner.reacts(state, fn(s) {
    let (on_anchor, on_card, pressed, takes, keep, sub) = s
    let at = owner.cause_at()
    if !on_anchor && takes && takes_was.val {
      dismissed.val = false
    }
    takes_was.val = takes
    let rests = on_anchor && !pressed && !dismissed.val
    let rests_now = rests && !rests_was.val
    rests_was.val = rests
    if !takes && !sub {
      if on_anchor {
        dismissed.val = true
      }
      (set_open.val)(false)
      return
    }
    if open.untracked() {
      if by_hand.val || keep || on_anchor || on_card {
        stop_due()
      } else if due.val is None {
        due.val = Some(
          owner.at_moment(at + spec.close_delay, fn() {
            due.val = None
            let (a, c, _, _, k, _) = @signals.untracked(state)
            if !(a || c || k || by_hand.val) {
              (set_open.val)(false)
            }
          }),
        )
      }
    } else if rests_now {
      stop_due()
      due.val = Some(
        owner.at_moment(at + spec.open_delay, fn() {
          due.val = None
          let (a, _, p, t, _, _) = @signals.untracked(state)
          if a && !p && t && !dismissed.val {
            (set_open.val)(true)
          }
        }),
      )
    } else if !rests {
      stop_due()
    }
  })
  let hold = fn() {
    dismissed.val = false
    (set_open.val)(true)
    by_hand.val = true
  }
  close_explicit.val = fn() {
    let (on_a, _, _, _, _, _) = @signals.untracked(state)
    if on_a {
      dismissed.val = true
    }
    (set_open.val)(false)
  }
  let on_held = fn(_d : @view.Drag) {
    if @ui.pointing() is Finger {
      hold()
    }
  }
  if pointed is None {
    anchor.points(Is(true)).gesture(@ui.touch_slop(), hold=(@ui.long_press_ms, on_held)) |> ignore
  }
  owner.owns(fn() {
    stop_due()
    way.put(0.0)
  })
  |> ignore
  { hold, close: fn() { (close_explicit.val)() }, open: fn() { open.get() }, card: fn() { card.get() } }
}

///|
/// Lazy bridge state for hover panels opened from legacy Ctx views (mounted on window_root_at at stacked(0) on first
/// hover: 0 nodes at cold start).
priv struct HoverPanelOld {
  holder : @view.View
  mut key : String
  mut anchor : Anchor
  mut title : String
  mut body : (@view.View, () -> Unit) -> Unit
  mut spec : HoverPanelSpec
  mut held : () -> Bool
  on_anchor : @signals.Signal[Bool]
  open : @signals.Signal[Bool]
  card : @signals.Signal[@view.View?]
  anchor_v : Ref[@view.View?]
  row_open : @signals.Signal[@view.View?]
  way : @motion.NodeWay
  gate : Ref[OpenGate]
  due : Ref[(() -> Unit)?]
  dismissed : Ref[Bool]
  set_open : Ref[(Bool) -> Unit]
}

///|
// kept across runs: put back by hover_panel_old_reset (presenters_reset)
let hover_panel_old_at : Ref[HoverPanelOld?] = Ref(None)

///|
// kept across runs: put back by hover_panel_old_reset (presenters_reset)
let hover_panel_old_dismissed_key : Ref[String] = Ref("")

///|
fn hover_panel_old_reset() -> Unit {
  match hover_panel_old_at.val {
    Some(st) => {
      match st.due.val {
        Some(s) => s()
        None => ()
      }
      st.due.val = None
      st.way.put(0.0)
    }
    None => ()
  }
  hover_panel_old_at.val = None
  hover_panel_old_dismissed_key.val = ""
}

///|
fn hover_panel_old_ensure(
  key : String,
  anchor : Anchor,
  title : String,
  body : (@view.View, () -> Unit) -> Unit,
  spec : HoverPanelSpec,
  held : () -> Bool,
) -> HoverPanelOld? {
  match (hover_panel_old_at.val, @ui.view_tree()) {
    (Some(st), Some(t)) if st.holder.alive() && t.root_holds(st.holder.id()) => return Some(st)
    _ => hover_panel_old_at.val = None
  }
  let root = match (window_root_at.val, @ui.view_tree()) {
    (Some(r), Some(t)) if r.alive() && physical_equal(r.tree, t) => r
    _ => return None
  }
  let on_anchor : @signals.Signal[Bool] = @signals.signal(false, same=fn(a, b) { a == b })
  let open : @signals.Signal[Bool] = @signals.signal(false, same=fn(a, b) { a == b })
  let card : @signals.Signal[@view.View?] = @signals.signal_by(None, same=fn(a, b) {
    match (a, b) {
      (None, None) => true
      (Some(x), Some(y)) => x.id() == y.id()
      _ => false
    }
  })
  let anchor_v : Ref[@view.View?] = Ref(None)
  let row_open : @signals.Signal[@view.View?] = @signals.signal_by(None, same=same_view)
  let way = @motion.NodeWay::new(0.0)
  let gate : Ref[OpenGate] = Ref(OpenGate::new())
  let due : Ref[(() -> Unit)?] = Ref(None)
  let dismissed : Ref[Bool] = Ref(false)
  let set_open : Ref[(Bool) -> Unit] = Ref(fn(_) {  })
  let holder = root.box(fn(h) { h.transitions_only().over(Is(true)).stacked(Is(0)) |> ignore })
  let st : HoverPanelOld = {
    holder,
    key,
    anchor,
    title,
    body,
    spec,
    held,
    on_anchor,
    open,
    card,
    anchor_v,
    row_open,
    way,
    gate,
    due,
    dismissed,
    set_open,
  }
  let stop_due = fn() {
    match st.due.val {
      Some(s) => s()
      None => ()
    }
    st.due.val = None
  }
  holder.on_key(fn(k) {
    if k.code == @ui.key_escape && st.open.untracked() && st.row_open.untracked() is None {
      if st.on_anchor.untracked() {
        st.dismissed.val = true
      }
      (st.set_open.val)(false)
      true
    } else {
      false
    }
  })
  |> ignore
  let downs_was : Ref[Int?] = Ref(None)
  holder.reacts(fn() { if st.open.get() && st.row_open.get() is None { Some(holder.window_downs()) } else { None } }, at_start=false, fn(
    now,
  ) {
    let was = downs_was.val
    downs_was.val = now
    guard was is Some(_) && now is Some(_) else { return }
    guard st.open.untracked() && st.row_open.untracked() is None else { return }
    let (x, y) = holder.window_down_point()
    let on = fn(v : @view.View?) {
      match v {
        Some(p) =>
          match p.tree.target_at(x, y) {
            Pressed(id) | Dragged(id) => p.tree.holds(p.id(), id)
            _ => false
          }
        None => false
      }
    }
    if !(on(st.card.untracked()) || st.on_anchor.untracked()) {
      (st.set_open.val)(false)
    }
  })
  holder.show(fn() { st.open.get() }, leave=hover_card_out_ms, fn(wrap) {
    wrap.over(Is(true)) |> ignore
    let (av, opened) : (@view.View, @view.Opener?) = match st.anchor {
      Of(id) => (@ui.old_anchor(wrap, id, (0.0, 0.0, 0.0, 0.0)), Some(@view.ByOld(id)))
      Node(v) => (v, Some(@view.ByNode(v.id())))
      At(x, y, w, h) => (fixed_anchor(wrap, (x, y, w, h)), None)
      Unanchored => (fixed_anchor(wrap, (0.0, 0.0, 0.0, 0.0)), None)
    }
    st.anchor_v.val = Some(av)
    wrap.box(fn(t) {
      t.owns(fn() {
        match st.card.untracked() {
          Some(c) if c.id() == t.id() => st.card.set(None)
          _ => ()
        }
        st.anchor_v.val = None
      })
      |> ignore
      hover_panel_surface(
        t,
        holder,
        av.id(),
        opened,
        st.title,
        st.body,
        st.spec,
        st.way,
        st.gate,
        st.row_open,
        fn() {
          if st.on_anchor.untracked() {
            st.dismissed.val = true
          }
          (st.set_open.val)(false)
        },
      )
      st.card.set(Some(t))
    })
    |> ignore
  })
  st.set_open.val = fn(on : Bool) {
    stop_due()
    if on == st.open.untracked() {
      return
    }
    if on {
      if st.card.untracked() is None {
        st.gate.val = OpenGate::new()
      }
      st.gate.val.go(holder, fn() { st.way.go_ms(holder, 1.0, hover_card_in_ms, ease=Out) })
    } else {
      st.gate.val.stop()
      st.way.go_ms(holder, 0.0, hover_card_out_ms, ease=Leave)
    }
    if holder.alive() {
      @view.transition(within=holder, fn() { st.open.set(on) })
    } else {
      st.open.set(on)
    }
  }
  let state = fn() {
    let mouse = @ui.pointing() is Mouse
    let sub = st.row_open.get() is Some(_)
    let keep = (st.held)() || sub
    if !mouse && !keep && !st.open.get() {
      return (false, false, false, false)
    }
    let on_a = mouse && st.on_anchor.get()
    let on_c = mouse &&
      (
        match st.card.get() {
          Some(c) => c.pointed_in()
          None => false
        }
      )
    (on_a, on_c, holder.window_held(), keep)
  }
  let rests_was = Ref(false)
  holder.reacts(state, fn(s) {
    let (on_a, on_c, pressed, keep) = s
    let at = holder.cause_at()
    if !on_a && holder.tree.modal_stack() < 0 {
      st.dismissed.val = false
    }
    let rests = on_a && !pressed && !st.dismissed.val
    let rests_now = rests && !rests_was.val
    rests_was.val = rests
    if st.open.untracked() {
      if keep || on_a || on_c {
        stop_due()
      } else if st.due.val is None {
        st.due.val = Some(
          holder.at_moment(at + st.spec.close_delay, fn() {
            st.due.val = None
            let (a, c, _, k) = @signals.untracked(state)
            if !(a || c || k) {
              (st.set_open.val)(false)
            }
          }),
        )
      }
    } else if rests_now {
      stop_due()
      st.due.val = Some(
        holder.at_moment(at + st.spec.open_delay, fn() {
          st.due.val = None
          let (a, _, p, _) = @signals.untracked(state)
          if a && !p && !st.dismissed.val {
            (st.set_open.val)(true)
          }
        }),
      )
    } else if !rests {
      stop_due()
    }
  })
  holder.owns(fn() {
    stop_due()
    st.way.put(0.0)
    match hover_panel_old_at.val {
      Some(cur) if cur.holder.id() == holder.id() => hover_panel_old_at.val = None
      _ => ()
    }
  })
  |> ignore
  hover_panel_old_at.val = Some(st)
  Some(st)
}

///|
/// Report pointer hover on a legacy Ctx anchor for a hover panel keyed by `key`.
pub fn hover_panel_old_hover(
  key : String,
  anchor : Anchor,
  title : String,
  body : (@view.View, () -> Unit) -> Unit,
  spec? : HoverPanelSpec = hover_panel_spec(),
  held? : () -> Bool = fn() { false },
) -> Unit {
  if hover_panel_old_dismissed_key.val == "*" || hover_panel_old_dismissed_key.val == key {
    return
  }
  guard hover_panel_old_ensure(key, anchor, title, body, spec, held) is Some(st) else { return }
  if st.key != key {
    (st.set_open.val)(false)
    st.key = key
  }
  st.anchor = anchor
  st.title = title
  st.body = body
  st.spec = spec
  st.held = held
  st.on_anchor.set(true)
}

///|
/// Report pointer leave from the legacy Ctx anchor keyed by `key`.
pub fn hover_panel_old_leave(key : String) -> Unit {
  if hover_panel_old_dismissed_key.val == "*" || hover_panel_old_dismissed_key.val == key {
    hover_panel_old_dismissed_key.val = ""
  }
  match hover_panel_old_at.val {
    Some(st) if st.key == key => st.on_anchor.set(false)
    _ => ()
  }
}

///|
/// Close the active legacy Ctx hover panel (or only the one matching `key` if non-empty). Pass `dismiss=true` when
/// closing from a direct press on the anchor so resting the pointer there after the press does not immediately re-open
/// it until the pointer leaves.
pub fn hover_panel_old_close(key? : String = "", dismiss? : Bool = false) -> Unit {
  if dismiss {
    hover_panel_old_dismissed_key.val = if key == "" { "*" } else { key }
  }
  match hover_panel_old_at.val {
    Some(st) if key == "" || st.key == key => {
      if dismiss {
        st.dismissed.val = true
        st.on_anchor.set(true)
      } else if st.on_anchor.untracked() {
        st.dismissed.val = true
      }
      (st.set_open.val)(false)
    }
    _ => ()
  }
}
