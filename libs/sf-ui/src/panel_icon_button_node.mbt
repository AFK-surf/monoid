// A small panel's icon button (panel_icon_button's): the library's icon button (icon_button_node) at a panel's size,
// its tip in the layer the panel lends it.

///|
/// A small panel's icon button (panel_icon_button's: close, stop, a step) in `parent`: icon_button_node 24 across showing
/// icon `icon` (panel_icon_size), read out a button named `label` (as it changes), its tip in the layer the panel it is
/// in is lent (panel_tips_lent; none outside a panel); `press` done as it is pressed. The node.
#callsite(autofill(loc))
pub fn panel_icon_button_node(
  parent : @view.View,
  icon : String,
  label : () -> String,
  press : () -> Unit,
  loc~ : SourceLoc,
) -> @view.View {
  icon_button_node(loc~, parent, icon, label, press, tips?=panel_tips_of(parent), size=panel_icon_side, icon_size=panel_icon_size)
}

///|
/// How big a panel's icon button is (panel_icon_box's S6).
let panel_icon_side : Double = @ui.Space::px(S6)
