// A panel's stage (the card to share) as nodes of the window's tree: the presenters' dialog layer
// (dialog_layer_node: a press beside what it shows closes it, as a dialog's does) dimmed by the stage's own night
// (stage_scrim); no panel round what it shows, no title drawn (said as its name alone) and no close button over it: a
// column in the window's middle, stage_margin and the system's bars clear of the window's edges, of what it holds and,
// stage_gap under it, what is chosen of it (`above`) over 关闭 and its foot's buttons, on the night (`on_night`). What
// it holds is laid out as wide as the panel says (its `w`: as wide as it is handed out, the same picture everywhere)
// and drawn smaller where the stage has not the room (stage_fit_node): as tall as that at the stage's width, giving
// way to the room the column leaves it under what is under it. Escape, back, 关闭 and a press beside it close it (its
// gone told); what its foot is given closes it as done.

///|
/// A stage `x` (of nodes: panel_nodes' `stage`) in `parent` while `open()` (going over pop_out_ms once not); `close`:
/// what its foot is given to close it (done); `cancel` as it is closed by 关闭, Escape, back or a press beside it.
/// `shown`, `gone`: as dialog_layer_node's.
fn stage_node(
  parent : @view.View,
  open : () -> Bool,
  x : PanelOf,
  close : () -> Unit,
  cancel : () -> Unit,
  shown? : () -> Unit = fn() {  },
  gone? : () -> Unit = fn() {  },
  covered? : () -> Bool = fn() { false },
) -> Unit {
  let nodes = x.nodes
  // (its night its own, whoever else dims what is under it (scrim_owner leaves a stage out): as kit's dialog draws a
  // stage's scrim)
  dialog_layer_node(parent, open, cancel, outside=true, scrim=fn() { stage_scrim }, night_with_ground=true, shown~, gone~, covered~, fn(across, layer, look, _veil) {
    // (its name as it is now: `live`'s first, said, never drawn)
    let title = fn() {
      match x.live {
        Some(f) => f().0
        None => x.title
      }
    }
    // (the room the stage has: the window less stage_margin and the system's bars round it)
    let room = fn() {
      let (ww, wh) = layer.window()
      let bars = @ui.system_bars()
      (ww - 2.0 * stage_margin - bars.left - bars.right, wh - 2.0 * stage_margin - bars.top - bars.bottom)
    }
    across.box(fn(d) {
      d
      // (as wide as what it holds is laid out where the stage has the room, else the stage)
      .width(By(fn() { Some(dmax(0.0, dmin(room().0, x.w))) }))
      .max_height(By(fn() { Some(dmax(0.0, room().1)) }))
      .gap(Is(stage_gap))
      .alpha(By(fn() { look().alpha }))
      .scale(By(fn() { look().sx }))
      .offset(By(fn() { (look().dx, look().dy) }))
      // (leaving layers with left_at >= 0.0 are hidden from semantics by the framework)
      .says(By(fn() { Some(@view.said(Dialog, label=title())) }))
      // (a press on it its own: not beside it)
      .presses(Is(true))
      .on_press(fn() {  })
      |> ignore
      // what it holds: scrolled vertically at readable width when `stage_scroll` is given, else scaled to fit whole
      match x.stage_scroll {
        Some(sc) => stage_scroll_node(d, x.w, sc, x.stage_bg, fn() { look().words }, fn(b) { (nodes.body)(b, close) })
        None => stage_fit_node(d, x.w, fn() { look().words }, fn(b) { (nodes.body)(b, close) })
      }
      // under it: what is chosen of it over 关闭 and its foot's buttons, on the night
      d.box(fn(u) {
        style_node(u, fn() { stage_under })
        u.alpha(By(fn() { look().words })) |> ignore
        match x.above {
          Some(f) => f(u)
          None => ()
        }
        u.box(fn(f) {
          style_node(f, fn() { stage_foot })
          button_node(f, fn() { t("common.close") }, cancel, on_night=true) |> ignore
          match nodes.foot {
            Some(g) => g(f, close)
            None => ()
          }
        })
        |> ignore
      })
      |> ignore
    })
  })
}

///|
/// Preview slot for a scrollable stage: vertically centers short previews that hug their own height.
// kept across runs: a value (no field of it changes)
let stage_scroll_slot : @ui.Style = @ui.css("justify=JCenter w=Full")

///|
/// Shared poster layout box inside a stage's `by_room`: laid out `most` wide out of flow, horizontally centered in
/// `room.width()`, scaled by `scale_fn` about its top center, with a companion spacer reserving `room.tall * across`.
/// Returns the measured poster node so callers can read `room.tall(whole)` directly.
#callsite(autofill(loc))
fn stage_poster_box(
  holder : @view.View,
  room : @view.Room,
  most : Double,
  scale_fn : (@view.View) -> () -> Double,
  body : (@view.View) -> Unit,
  loc~ : SourceLoc,
) -> @view.View {
  let made : Ref[@view.View?] = Ref(None)
  holder.box(made_for=loc, fn(b) {
    made.val = Some(b)
    b.over(Is(true), edges=(Some(0.0), Some(0.0), None, None)).width(Is(Some(most))) |> ignore
    body(b)
  })
  |> ignore
  let whole = made.val.unwrap()
  let across = fn() { dmin(1.0, room.width() / most) }
  whole.offset(By(fn() { ((room.width() - most) / 2.0, 0.0) })).scale(By(scale_fn(whole)), about=@view.Pivot::At(0.5, 0.0))
  |> ignore
  holder.box(fn(r) { r.height(By(fn() { Some(room.tall(whole) * across()) })) |> ignore }) |> ignore
  whole
}

///|
/// What a stage holds in `parent` (a column that gives it what it leaves under the rest), as opaque as `seen` says (its
/// words' way in, after the night's, as a dialog's are): made by `body` `most` wide,
/// whatever the stage's width, and drawn smaller from its top's middle where the stage has not that width, or not the
/// room for all of it down the column (as tall as it is at the stage's width, giving way to that room as the column lays
/// it out: View::by_room's height); its room as large as it is drawn, in the column's middle.
fn stage_fit_node(parent : @view.View, most : Double, seen : () -> Double, body : (@view.View) -> Unit) -> Unit {
  parent.by_room(fn(held, room) {
    let across = fn() { dmin(1.0, room.width() / most) }
    stage_poster_box(
      held,
      room,
      most,
      fn(whole) {
        fn() {
          let tall = room.tall(whole)
          match room.height() {
            Some(h) if tall > 0.0 => dmin(across(), h / tall)
            _ => across()
          }
        }
      },
      body,
    )
    |> ignore
  })
  .shrink(Is(1.0))
  .min_height(Is(Some(0.0)))
  .alpha(By(seen))
  |> ignore
}

///|
/// What a scrollable stage holds in `parent` (a column that gives it what it leaves under the rest): laid out `most`
/// wide, scaled horizontally only when the stage is narrower than `most`, and scrolled vertically inside a
/// `pane_corner` clipped viewport whenever taller than the room the column leaves it — keeping long lists readable
/// instead of shrinking them into a narrow strip. Short pictures hug their own height with zero scroll, while the slot
/// holds the highest height seen while open (monotonic non-shrinking) so switching provider filters to a shorter group
/// never shifts the controls below under the person's finger or pointer.
fn stage_scroll_node(
  parent : @view.View,
  most : Double,
  scroll : @view.Scroll,
  bg : (() -> Int64)?,
  seen : () -> Double,
  body : (@view.View) -> Unit,
) -> Unit {
  let peak_h : Ref[Double] = Ref(0.0)
  parent.by_room(fn(held, room) {
    let across = fn() { dmin(1.0, room.width() / most) }
    held.shrink(Is(1.0)).min_height(Is(Some(0.0))) |> ignore
    let whole_ref : Ref[@view.View?] = Ref(None)
    held.box(fn(slot) {
      style_node(slot, fn() { stage_scroll_slot })
      slot.shrink(Is(1.0)).min_height(Is(Some(0.0))) |> ignore
      // Outer rounded viewport clips both top and bottom smoothly while scrolling; keeping `.scrolls` on an inner child
      // places the vertical scroll container strictly between scrolled cards and this rounded frame (corners.mbt).
      slot.box(fn(frame) {
        frame.shrink(Is(1.0)).min_height(Is(Some(0.0))).radius(By(fn() { pane_corner * across() })).clips(Is(true))
        |> ignore
        match bg {
          Some(g) => frame.ground(By(g)) |> ignore
          None => ()
        }
        frame.box(fn(sc) {
          sc
          .shrink(Is(1.0))
          .min_height(Is(Some(0.0)))
          .scrolls(
            scroll,
            slop=@ui.touch_slop(),
            bar=@ui.tree_scroll_bar(),
            bar_clear=fn() { (pane_corner * across() / 2.0, pane_corner * across() / 2.0) },
            fn(content) { whole_ref.val = Some(stage_poster_box(content, room, most, fn(_) { across }, body)) },
          )
          |> ignore
        })
        |> ignore
      })
      |> ignore
      let whole = whole_ref.val.unwrap()
      // Monotonic unscaled peak height: hugs short previews on open (zero extra gap under short cards like share-pool),
      // scales cleanly with `across()` if the window narrows, and never shrinks when a filter switches to fewer rows so
      // bottom tabs & buttons stay stationary. Idempotent local Ref monotonic max; does not affect `whole`'s own layout.
      slot.height(By(fn() {
        let tall = room.tall(whole)
        if tall > peak_h.val {
          peak_h.val = tall
        }
        Some(peak_h.val * across())
      }))
      |> ignore
    })
    |> ignore
  })
  .shrink(Is(1.0))
  .min_height(Is(Some(0.0)))
  .alpha(By(seen))
  |> ignore
}
