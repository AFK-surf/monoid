// The ways to the picture before and after as nodes of the window's tree
// (the way there 4): each there as what is beside the picture says, in and out as the bars are (or
// the hand is on it) from the moment that changes, on a motion's way; pressed (its press let go on it), done then.

///|
let viewer_steps_move_lent : @view.Lent[() -> Unit] = @view.Lent::new()

///|
/// Register a pointer-move callback on `parent` so moving over a visible step disc refreshes the viewer idle timer.
pub fn viewer_steps_on_move(parent : @view.View, on_move : () -> Unit) -> Unit {
  parent.lends(viewer_steps_move_lent, on_move) |> ignore
}

///|
/// The ways to the picture before and after in `parent` (a layer over the viewer's, all of its room), as the web's
/// fpStep has them: 40 discs of the canvas at 80% over a 12 blur, a shadow, 16 in from the sides (36 and 8 where `small`), in
/// the middle, a chevron in the words' ink; each while `before` and `after` say there is one. Each side shows while
/// `awake_for(dir)` (-1 before, 1 after) holds (or the hand stays on a visible disc: a mouse's pointer over it while
/// shown, or a press held on it), in over wake_ms and out over sleep_ms from where it is at the moment that changes
/// (at once with motion reduced), as far in as `shown` says of the node as it is drawn (the viewer's fade); taking a
/// press and readable by screen readers only while any of it shows (`takes`). Pressed (its press let go on it), `go`
/// (-1 the one before, 1 the one after) at that moment. Their tips in `tips`. The row's node.
#callsite(autofill(loc))
pub fn viewer_steps_node(
  parent : @view.View,
  before : () -> Bool,
  after : () -> Bool,
  awake_for : (Int) -> Bool,
  shown : (@view.View) -> Double,
  small : () -> Bool,
  go : (Int) -> Unit,
  tips : TipLayer,
  loc~ : SourceLoc,
) -> @view.View {
  parent.box(made_for=loc, fn(row) {
    row
    .over(Is(true))
    .row(Is(true))
    .lines_up(Is(Some(Middle)))
    .padding(By(fn() {
      let px = @ui.Space::px(if small() { S2 } else { S4 })
      (px, 0.0, px, 0.0)
    }))
    |> ignore
    let disc = fn() { @ui.Space::px(if small() { S9 } else { S10 }) }
    for side in [(before, -1, "chevron-left", "web-main.preview.prevKey"), (after, 1, "chevron-right", "web-main.preview.nextKey")] {
      let (there, dir, icon, label) = side
      if dir > 0 {
        row.box(fn(g) { g.grow(Is(1.0)) |> ignore }) |> ignore
      }
      // (as wide where there is none, the other in its place)
      row.box(fn(slot) {
        slot.width(By(fn() { Some(disc()) })).height(By(fn() { Some(disc()) })) |> ignore
        slot.show(there, fn(b) { step_disc(b, dir, icon, label, fn() { awake_for(dir) }, shown, disc, go, tips) })
      })
      |> ignore
    }
  })
}

///|
/// One way, in `slot` (all of it): see viewer_steps_node.
#callsite(autofill(loc))
fn step_disc(
  slot : @view.View,
  dir : Int,
  icon : String,
  label : String,
  awake : () -> Bool,
  shown : (@view.View) -> Double,
  disc : () -> Double,
  go : (Int) -> Unit,
  tips : TipLayer,
  loc~ : SourceLoc,
) -> Unit {
  // (mbui's headless button, its look this disc: pressed and read out only while any of it shows)
  let takes : Ref[() -> Bool] = Ref(fn() { false })
  @headless.button(made_for=loc, slot, fn() { t(label) }, fn(_) { go(dir) }, disabled=fn() { !(takes.val)() }, fn(b, _) {
    // (where the hand is on it, as a box's hovered look has it: its ground)
    let hot = fn() {
      match @ui.pointing() {
        Mouse => b.pointed()
        Finger => b.pressed()
      }
    }
    // (there while `awake` holds, or while still showing and the pointer stays on it, or while held down: a mouse's
    // button held down on it and moved off it stays, while a fully hidden disc never bounces back on a still pointer)
    let woke = fn() { awake() || ((takes.val)() && hot()) || b.pressed() }
    let seen = @motion.NodeWay::new(if @signals.untracked(woke) { 1.0 } else { 0.0 })
    b.reacts(woke, fn(on) { seen.go_ms(b, if on { 1.0 } else { 0.0 }, if on { wake_ms } else { sleep_ms }) })
    b
    .width(By(fn() { Some(disc()) }))
    .height(By(fn() { Some(disc()) }))
    .radius(By(fn() { disc() / 2.0 }))
    .lines_up(Is(Some(Middle)))
    |> ignore
    @glass.liquid_capsule_decorate(
      b,
      tone=ViewerClear,
      sharing=false,
      interactive=true,
      solid=fn() { theme().p.canvas },
      shadow=glass_control_shadow,
      solid_edge=@glass.liquid_solid_edge,
      clips=false,
    )
    .ground(By(fn() { if hot() { @ui.tree_theme().color(Hover) } else { 0L } }))
    .alpha(By(fn() { seen.shown(b) * shown(b) }))
    |> ignore
    // (taking a press and read out by screen readers only while any of it shows: on its way in, there, or on its way out)
    takes.val = fn() { seen.target() > 0.0 || seen.goes(b) }
    b
    .hides(By(fn() { !(takes.val)() }))
    .on_pointer_moved(fn() {
      if (takes.val)() {
        match b.lent(viewer_steps_move_lent) {
          Some(f) => f()
          None => ()
        }
      }
    })
    |> ignore
    // (its chevron in its middle)
    b.box(fn(g) { g.grow(Is(1.0)) |> ignore }) |> ignore
    b.box(fn(i) {
      i
      .width(Is(Some(viewer_step_icon)))
      .height(Is(Some(viewer_step_icon)))
      .shapes(Is(
        match icon_numbers(icon) {
          Some(d) => icon_shapes(d, viewer_step_icon / 24.0, 0x000000FFL)
          None => []
        },
      ))
      .drawn_as(Is("/icon/" + icon + "/"))
      .tint(By(fn() { theme().p.text }))
      |> ignore
    })
    |> ignore
    b.box(fn(g) { g.grow(Is(1.0)) |> ignore }) |> ignore
    tip_node(tips, b, fn() { t(label) }) |> ignore
  })
  |> ignore
}
