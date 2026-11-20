// What opens over the wide frame, drawn after it (the web's Radix portals): the rail's menu and what
// it adds while it is changed, what comes and goes from the rail, 待处理's panel, ⌘K's switcher and
// ⌘/'s shortcuts over a scrim. Each is the library's (@sf.menu_node, @sf.panel_nodes, @sf.beside_panel_node: web/ui
// parts.tsx Menu, controls.css.ts popover and menuList), nodes of the window's tree over the shell's panels
// (overlays_node: taped_shell's, paned_shell's); a press outside one, or Esc, closes it. Under them the mark the system's
// bars' items are put beside (rail_native_marks_node). A right click's menu is the app's, over all of it (context_menu.mbt
// context_menu_node, sfapp's app_tree); an old view's field right clicked, whose editing the old frame does, the old
// frame's (context_fields, sfapp's view_in).

///|
/// What opens over the wide frame, in node `v` (a shell's, over its panels): the system's bars' mark
/// (rail_native_marks_node), the rail's menu and what opens from the rail (rail_overlays_node.mbt), 待处理's panel
/// (attention_node.mbt).
pub fn overlays_node(v : @view.View, src : Source) -> Unit {
  // (where what opens from the system's bars' items is put beside, under what opens from them)
  rail_native_marks_node(v)
  rail_overlays_node(v, src)
  attention_panel_node(v, src)
  side_tab_menu_node(v)
}

