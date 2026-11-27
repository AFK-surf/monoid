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
      // what it holds: as tall as it is laid out at the stage's width, giving way to what the column leaves it
      stage_fit_node(d, x.w, fn() { look().words }, fn(b) { (nodes.body)(b, close) })
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
/// What a stage holds in `parent` (a column that gives it what it leaves under the rest), as opaque as `seen` says (its
/// words' way in, after the night's, as a dialog's are): made by `body` `most` wide,
/// whatever the stage's width, and drawn smaller from its top's middle where the stage has not that width, or not the
/// room for all of it down the column (as tall as it is at the stage's width, giving way to that room as the column lays
/// it out: View::by_room's height); its room as large as it is drawn, in the column's middle.
fn stage_fit_node(parent : @view.View, most : Double, seen : () -> Double, body : (@view.View) -> Unit) -> Unit {
  parent.by_room(fn(held, room) {
    // (laid out `most` wide over its room from its top, out of its flow: the room as tall as it is drawn, not as it is
    // laid out)
    let made : Ref[@view.View?] = Ref(None)
    held.box(fn(b) {
      made.val = Some(b)
      b.over(Is(true), edges=(Some(0.0), Some(0.0), None, None)).width(Is(Some(most))) |> ignore
      body(b)
    })
    |> ignore
    let whole = made.val.unwrap()
    // (how much smaller it is drawn at the stage's width, and in the room the column gave it)
    let across = fn() { dmin(1.0, room.width() / most) }
    let drawn = fn() {
      let tall = room.tall(whole)
      match room.height() {
        Some(h) if tall > 0.0 => dmin(across(), h / tall)
        _ => across()
      }
    }
    whole.offset(By(fn() { ((room.width() - most) / 2.0, 0.0) })).scale(By(drawn), about=@view.Pivot::At(0.5, 0.0)) |> ignore
    // (its room: as tall as it is drawn at the stage's width, given less by the column where it has not that)
    held.box(fn(r) { r.height(By(fn() { Some(room.tall(whole) * across()) })) |> ignore }) |> ignore
  })
  .shrink(Is(1.0))
  .min_height(Is(Some(0.0)))
  .alpha(By(seen))
  |> ignore
}
