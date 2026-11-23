// A small panel beside what opened it that leaves the window under it in use (the rail's 自定义侧边条, kit's popover
// with no modal layer: the rail's places moved and taken out while it shows), as nodes of the window's tree: no layer
// takes what is outside it, a press anywhere outside it and outside what it keeps open (`keeps`) closing it as it goes
// down, the press what it lands on's as ever; Escape and back closing it too, wherever the focus is. Grown out of its
// side as it comes, drawn back into it as it goes (pop_in, pop_out: drawn till its way out is over, pressed no more);
// what it holds laid out as a small panel's body is (panel_node's), scrolling where the window leaves it short.

///|
/// A panel in `parent` while `open()` (going over pop_out_ms once not), beside what `anchor` makes in its layer (`side`,
/// lined up `along` it, `offset` off it), `w` wide, read out a dialog named `label`; what it holds made by `body`.
/// `cancel` as a press outside it and outside `keeps()` (what it is about: a press there its own as ever, nothing closed),
/// Escape or back closes it. Its focus given it as it opens, back to what had it as it goes.
#callsite(autofill(loc))
pub fn beside_panel_node(
  parent : @view.View,
  open : () -> Bool,
  anchor : (@view.View) -> @view.View,
  w : Double,
  label : () -> String,
  body : (@view.View) -> Unit,
  cancel : () -> Unit,
  keeps? : () -> @view.View? = fn() { None },
  side? : @ui.Side = Bottom,
  along? : @ui.Along = Start,
  offset? : Double = panel_offset,
  loc~ : SourceLoc,
) -> Unit {
  parent.show(
    open,
    fn(layer) {
      let (enter, exit) = @signals.untracked(fn() { (pop_in_for(layer), pop_out_for(layer)) })
      let (look, live) = @motion.overlay_presence(layer, enter~, exit~)
      let panel : Ref[@view.View?] = Ref(None)
      layer
      .over(Is(true))
      // (leaving nodes with left_at >= 0.0 are hidden from semantics by the framework)
      .on_key(fn(k) {
        if k.code == @ui.key_escape && @signals.untracked(live) {
          cancel()
          true
        } else {
          false
        }
      })
      .takes_back(fn() {
        if @signals.untracked(live) {
          cancel()
        }
      })
      |> ignore
      // (a press anywhere in the window outside it and what it keeps open: closed as it goes down, the press what it
      // lands on's as ever, at that moment)
      layer.reacts(fn() { layer.window_downs() }, at_start=false, fn(_) {
        let (x, y) = layer.window_down_point()
        let on = fn(v : @view.View?) {
          match v {
            Some(p) if p.alive() =>
              match p.tree.target_at(x, y) {
                Pressed(id) | Dragged(id) | Hosted(id) => p.tree.holds(p.id(), id)
                _ => false
              }
            _ => false
          }
        }
        if @signals.untracked(live) && !on(panel.val) && !on(keeps()) {
          cancel()
        }
      })
      let at = anchor(layer)
      layer.box(made_for=loc, fn(p) {
        panel.val = Some(p)
        p
        .beside(at.id(), side~, along=view_along(along), offset~, padding=8.0, holds_side=true)
        .width(Is(Some(w)))
        .max_height(By(fn() { Some(dmax(0.0, over_room(layer).1 - 16.0)) }))
        |> small_panel_node
        |> ignore
        p
        .alpha(By(fn() { look().alpha }))
        .scale(By(fn() { look().sx }), about=FromBeside, max_shift=pop_max_shift)
        .says(By(fn() { Some(@view.said(Dialog, label=label())) }))
        // (a press on it its own: not outside it)
        |> ground_node
        |> ignore
        // (what it holds, as a small panel's body is: scrolling where the window leaves it short, out to its sides)
        p.box(fn(b) {
          let scroll = @view.Scroll::new()
          b
          .shrink(Is(1.0))
          .min_height(Is(Some(0.0)))
          .margin(Is((-panel_pad, 0.0, -panel_pad, 0.0)))
          .focusable(Is(true), keys=0, tab=false)
          |> ignore
          b.scrolls(scroll, slop=@ui.touch_slop(), bar=@ui.tree_scroll_bar(), fn(s) {
            s.box(fn(col) {
              style_node(col, fn() { held_in() })
              col.alpha(By(fn() { look().words })) |> ignore
              // (laid out as a small panel's body is: wide, its words a row's padding in)
              panel_in_lend(col, Wide, text_in, sides=panel_pad, small=true)
              body(col)
            })
            |> ignore
          })
          .clips(By(fn() { scroll.goes() }))
          .bounds_input(By(fn() { scroll.goes() }))
          |> ignore
          layer.focus_opens(b) |> ignore
        })
        |> ignore
      })
      |> ignore
    },
    leave=@motion.pop_out_ms,
  )
}
