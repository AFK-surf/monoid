// A small panel's look (small_panel's) and its button (panel_button's) as nodes of the window's tree, made once, for a
// card a node draws itself beside what it tells of (a link's card over it: sfpages' web_peek_node); and whether a
// mouse is over a node or what it holds (an old view's `hovered` of a row with its keys in it), as the library says
// what answers the hand.

///|
/// Node `p` drawn as a small panel is (small_panel's): what it holds panel_pad in, r_menu round, on the panel's ground,
/// its line round it and its shadow under it, what reaches past its edge cut there. It.
pub fn small_panel_node(p : @view.View) -> @view.View {
  corner_card_node(p, fn() { r_menu }, inset=fn() { panel_pad })
  p.padding(Is((panel_pad, panel_pad, panel_pad, panel_pad))) |> ignore
  @glass.liquid_panel_surface_decorate(
    p,
    radius=r_menu,
    solid=panel_ground,
    shadow=glass_overlay_shadow,
    solid_edge=fn() { (1.0, panel_edge()) },
    clips=true,
  )
}

///|
/// Node `v` as a ground (a panel's, a menu's, a sheet's, a card's): it takes a press, which is its own (not outside it,
/// nothing under it pressed), and is no control: nothing is done, the pointer over it the arrow (not the hand
/// Tree::cursor_of gives what does something pressed), and a ground (View::as_ground): no target of the room a press
/// takes, none it cuts. What it holds that is pressed is its own as ever, the hand over it. It.
pub fn ground_node(v : @view.View) -> @view.View {
  v.presses(Is(true)).on_press(fn() {  }).cursor(Is(Some(Arrow))).as_ground()
}

///|
/// A small panel's button (panel_button's) in `parent`, made once: a capsule 24 high, its words (`label` as it changes)
/// 500 at the meta size, the hover's ground where the hand is on it (lit_node); `tone` its look (Quiet: muted words,
/// the words' ink where the hand is on it; Accent: the accent's words; Filled: those on the accent's pale ground); read
/// out a button named by its words, `press` done as it is pressed. Its words changed (复制链接 to 已复制), its ground
/// and its words go together to where they are laid out (button_reshape, as panel_button's). The node.
#callsite(autofill(loc))
pub fn panel_button_node(
  parent : @view.View,
  label : () -> String,
  press : () -> Unit,
  tone? : PanelTone = Plainly,
  loc~ : SourceLoc,
) -> @view.View {
  @headless.button(made_for=loc, parent, label, fn(_) { press() }, fn(v, _) {
    style_node(v, fn() { if tone == Filled { panel_button_filled } else { panel_button_box } })
    v.focus_ring_theme() |> ignore
    let hot = fn() { lit_node(v) }
    // (its hovered{bg=Hover}: the hover's ground where the hand is on it; Filled's own ground kept)
    if tone != Filled {
      hover_ground_node(v)
    }
    let words = words_node(v, label, fn() {
      match tone {
        Accent | Filled => panel_button_accent
        Quiet => if hot() { panel_button_words } else { panel_button_quiet }
        Plainly => panel_button_words
      }
    })
    let m = @motion.moves_for(v, label, spec=button_reshape)
    m.reshapes(v)
    m.moves_with(words)
  })
}

///|
/// Whether a mouse is over `v` or over what it holds (hovered_node's, of all of it: an old view's `hovered` of a row,
/// its keys among what it holds), never a finger.
pub fn hovered_in_node(v : @view.View) -> Bool {
  @ui.pointing() is Mouse && v.pointed_in()
}

///|
/// Whether a mouse is over any block of the list's item `v` is a block of (@view.View::list_item_pointed: every slice of
/// a long message as one), never a finger.
pub fn hovered_item_node(v : @view.View) -> Bool {
  @ui.pointing() is Mouse && v.list_item_pointed()
}
