// A small panel's look (small_panel's) and its button (panel_button's) as nodes of the window's tree, made once, for a
// card a node draws itself beside what it tells of (a link's card over it: sfpages' web_peek_node); and whether a
// mouse is over a node or what it holds (an old view's `hovered` of a row with its keys in it), as the library says
// what answers the hand.

///|
/// Node `p` drawn as a small panel is (small_panel's): what it holds panel_pad in, r_menu round, on the panel's ground,
/// its line round it and its shadow under it, what reaches past its edge cut there. It.
pub fn small_panel_node(p : @view.View) -> @view.View {
  floating_host_lend(p)
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
/// A compact header/inline action button inside a floating panel or sheet with a full >=44pt press target
/// (`items.least`): the outer `@headless.button` keeps the transparent hit box while an inner 24pt full capsule
/// (`h=S6`, `radius=Full`, matching `panel_button_node`) carries the hover ground, words (`tone`), and optional
/// trailing `icon` (e.g. `"chevron-right"`). By default the capsule sits vertically centered inside the hit box;
/// pass `to_corner=true` when the button sits at a rounded top-right panel corner and needs a fixed 6pt top offset
/// across both mouse (36pt) and touch (44pt) hit targets.
#callsite(autofill(loc))
pub fn panel_link_button_node(
  parent : @view.View,
  label : () -> String,
  press : () -> Unit,
  tone? : PanelTone = Accent,
  icon? : String = "",
  to_corner? : Bool = false,
  loc~ : SourceLoc,
) -> @view.View {
  @headless.button(made_for=loc, parent, label, fn(_) { press() }, fn(v, b) {
    v
    .row(Is(true))
    .lines_up(Is(Some(if to_corner { Start } else { Middle })))
    .min_height(By(fn() { Some(theme().items.least) }))
    .focus_ring_theme()
    |> ignore
    if to_corner {
      v.padding(Is((0.0, 6.0, 0.0, 0.0))) |> ignore
    }
    let lit = fn() { b.hovered() || b.pressed() || b.focus_shown() }
    v.box(made_for=loc, fn(pill) {
      let pad = if icon != "" { (8.0, 0.0, 4.0, 0.0) } else { (10.0, 0.0, 10.0, 0.0) }
      pill
      .row(Is(true))
      .lines_up(Is(Some(Middle)))
      .gap(Is(2.0))
      .min_height(Is(Some(24.0)))
      .padding(Is(pad))
      .radius(By(fn() { @ui.tree_theme().corner(Full) }))
      |> ignore
      hover_ground_node(pill, lit=Some(lit))
      words_node(pill, label, fn() {
        match tone {
          Accent | Filled => panel_button_accent
          Quiet => if lit() { panel_button_words } else { panel_button_quiet }
          Plainly => panel_button_words
        }
      })
      |> ignore
      if icon != "" {
        icon_node(pill, icon, 12.0, By(fn() { theme().p.muted })) |> ignore
      }
    })
    |> ignore
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
