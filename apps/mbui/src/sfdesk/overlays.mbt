// What opens over the wide frame, drawn after it (the web's Radix portals): a right click's menu, the rail's and what
// it adds while it is changed, what comes and goes from the rail, 待处理's panel, ⌘K's switcher and
// ⌘/'s shortcuts over a scrim. Each is the library's (@sf.menu_node, @sf.panel_nodes, @sf.beside_panel_node: web/ui
// parts.tsx Menu, controls.css.ts popover and menuList), nodes of the window's tree over the shell's panels
// (overlays_node: taped_shell's, paned_shell's); a press outside one, or Esc, closes it. What is left of the old frame
// over it (overlays) is no part of these: the marks the system's bars' items are put beside, and an old view's field
// right clicked, whose editing the old frame does.

///|
/// What opens over the wide frame, in node `v` (a shell's, over its panels): a right click's menu (context_menu.mbt),
/// the rail's menu and what opens from the rail (rail_overlays_node.mbt), 待处理's panel (attention_node.mbt).
pub fn overlays_node(v : @view.View, src : Source) -> Unit {
  rail_overlays_node(v, src)
  attention_panel_node(v, src)
}

///|
/// What the old frame keeps over the wide frame (an island's): where what opens from the system's bars' items is put
/// beside (rail_native_marks), an old view's field right clicked and its editing done (context_fields).
pub fn overlays(c : @ui.Ctx) -> Unit {
  rail_native_marks(c)
  context_fields(c)
}
