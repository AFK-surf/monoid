// The library's mark saying what a thing is for (about's) as a node of the window's tree, made once: the info icon in
// a round 20 (about_box), the subtle ink's, the text's where the hand is on it; what it says its tip, under it, as the
// pointer rests on it, or as a finger taps it or it is pressed by a key or a screen reader (shown till the next tap,
// wherever it lands: on it again shuts it); read out a button by its name.

///|
/// The mark in `parent`, saying `words` in its tip (in `tips`), read out `label`. The node.
#callsite(autofill(loc))
pub fn about_mark_node(
  parent : @view.View,
  words : () -> String,
  label : () -> String,
  tips : TipLayer,
  loc~ : SourceLoc,
) -> @view.View {
  let in_back_bar = parent.lent(back_bar_lent).unwrap_or(false)
  if in_back_bar && !@glass.in_liquid_pill(parent) {
    let btn_v : Ref[@view.View?] = Ref(None)
    bar_pill_group_node(loc~, parent, height=pg_back_pill_h, pad=3.0, gap=0.0, adaptive=true, fn(pill) {
      btn_v.val = Some(about_mark_node(loc~, pill, words, label, tips))
    })
    |> ignore
    return btn_v.val.unwrap()
  }
  let press_ref : Ref[(Bool) -> Unit] = Ref(fn(_) {  })
  @headless.button(made_for=loc, parent, label, fn(_) { (press_ref.val)(false) }, fn(v, b) {
    let lit = fn() { b.focus_shown() || b.hovered() || b.pressed() }
    let side = if in_back_bar { 34.0 } else { @ui.Space::px(S5) }
    let icon_sz = if in_back_bar { 20.0 } else { about_icon }
    v
    .width(Is(Some(side)))
    .height(Is(Some(side)))
    .lines_up(Is(Some(Middle)))
    .lies_along(Is(Middle))
    .radius(Is(side / 2.0))
    |> ignore
    if in_back_bar {
      hover_ground_node(
        v,
        color=fn() {
          if b.pressed() {
            bar_pill_press_ink(solid=v.glass_solid())
          } else {
            @glass.liquid_pill_hover_ink(solid=v.glass_solid())
          }
        },
      )
      v.focus_ring(Is(Some((-1.5, -1.5, 0L)))) |> ignore
      bind_pill_press(v)
    }
    icon_node(
      v,
      "info",
      icon_sz,
      By(fn() { if in_back_bar || lit() { theme().p.text } else { theme().p.subtle } }),
      weighed=in_back_bar,
    )
    |> ignore
    let tip = tip_node(tips, v, words, side=Bottom)
    // (a finger's tap shows what it says till the next tap, wherever it lands; that one on it shuts it and no more: as
    // about's, about_open and tapped_anywhere; pressed by a key or a screen reader, the button's press: the same)
    let toggle = fn(tapped : Bool) {
      if (tip.opened)() {
        (tip.cancel)()
      } else {
        (tip.open)(tapped)
      }
    }
    press_ref.val = toggle
    v.gesture(@ui.touch_slop(), tap=fn(d) {
      if @ui.pointing() is Finger && v.finger_target(d.wx, d.wy) {
        toggle(true)
      }
    })
    |> ignore
  })
}
