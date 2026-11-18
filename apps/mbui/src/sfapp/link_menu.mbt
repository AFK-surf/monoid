// A link held in a message: its own menu, open it or copy it, rather than the message's (picking its words) and rather
// than the link opening as the finger lifts; a tap stays the link's. The library's link menu (@sf.link_menu), presented
// as every menu is: from the foot on 小屏, under the line held on 中屏 and 大屏 (over it when there is no room below).

///|
/// The link's menu, open it or copy it, at `x` under (or over) the line from `top` to `bottom`: opened, as a tap on it
/// (a chat's link here, any other in the browser); copied, said so.
fn link_menu_at(href : String, x : Double, top : Double, bottom : Double) -> Unit {
  @sf.link_menu(href, from=At(x, top, 0.0, bottom - top), fn() { open_link(href) }, fn() {
    @sfbase.copy_out(href, said=tr("common.link.copied"))
  })
}
