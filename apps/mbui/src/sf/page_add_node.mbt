// What a page adds one more of (添加 station, 添加 Profile) at its title's end, as nodes: by the page's arrangement, the
// library's (a page's parts read it, look_node), never the page's own branch.

///|
/// What a page adds, named `label` as it is said now, at its title's line's end in `parent`: narrow a round ＋ (the
/// narrow title's), wide a quiet button with ＋ and its words; `open` given the button itself as it is pressed, where
/// what it opens goes beside it.
#callsite(autofill(loc))
pub fn page_add_node(parent : @view.View, label : () -> String, open : (@view.View) -> Unit, loc~ : SourceLoc) -> Unit {
  match look_node(parent) {
    Narrow => icon_button_opens_node(loc~, parent, "plus", label, open) |> ignore
    Wide => button_opens_node(loc~, parent, label, open, icon="plus") |> ignore
  }
}

///|
/// What a page does by a mark alone (分享) in the bar its frame lends it (`bar_actions`), named `label` as it is said
/// now: narrow, a phone's top bar, a round key as the settings' beside it there (round_key_node); wide, a pane's bar, the
/// icon button.
#callsite(autofill(loc))
pub fn bar_icon_node(
  parent : @view.View,
  icon : String,
  label : () -> String,
  press : () -> Unit,
  tips? : TipLayer,
  loc~ : SourceLoc,
) -> Unit {
  match look_node(parent) {
    Narrow => round_key_node(loc~, parent, icon, label, press)
    Wide => icon_button_node(loc~, parent, icon, label, press, tips?) |> ignore
  }
}
