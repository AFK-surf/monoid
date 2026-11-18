// A choice drawn as a button (chooser's `as_button`: a ghost button's size and words, the chooser's quiet ink, a
// chevron after its words) as a node of the window's tree, made once: pressed, its menu of choices beside it as
// chooser_node's is (menu_node, made in the layer of the panel it is in, else over the window), on `side` of it.

///|
/// A choice in `parent` drawn as a ghost button (chooser's `as_button`, as a node): `words()` in a button's words and
/// height, their ink quiet but while the hand is on it, it has the focus shown or its menu is open (the hover's ground
/// under it then, eased over dur_ms as a button's), a 16 chevron after them laid out by its ink; its words changed, its
/// ground and words going to where they are laid out as a button's. Pressed (a tap, a click, Enter or Space with the
/// focus on it, a screen reader's press), or Down with the focus on it, its menu of `choices()` (each its value and
/// its words) on `side` of it, 6 off, lined up with its start, 220 wide at least, the one `chosen()` checked; a choice
/// chosen closes it, then `choose` is given its value; Escape, back and a press outside close it alone. Read out a
/// button named by its words, expanded while its menu is open. `card_words`: in a card's foot corner, its words where
/// the card's begin (button_node's). The node.
#callsite(autofill(loc))
pub fn chooser_button_node(
  parent : @view.View,
  words : () -> String,
  choices : () -> Array[(String, String)],
  chosen : () -> String,
  choose : (String) -> Unit,
  side? : @ui.Side = Bottom,
  card_words? : Bool = false,
  loc~ : SourceLoc,
) -> @view.View {
  let menu = ChooserMenu::new(parent)
  let open = menu.open
  let by_key = menu.by_key
  let height = button_height()
  let b = @headless.disclosure(
    made_for=loc,
    parent,
    words,
    fn() { open.get() },
    fn(v) {
      by_key.val = v.focus_shown()
      open.set(!open.untracked())
    },
    fn(v, _) {
      let lit = fn() { lit_node(v) || open.get() }
      let hand = @motion.NodeWay::new(if @signals.untracked(lit) { 1.0 } else { 0.0 })
      v.reacts(lit, fn(on) { hand.go_ms(v, if on { 1.0 } else { 0.0 }, dur_ms) })
      let ink = fn() { if lit() { theme().p.text } else { theme().p.muted } }
      let padx = if card_words { card_foot_words_in(height) } else { button_padx }
      v
      .row(Is(true))
      .height(Is(Some(height)))
      .padding(Is((padx, 0.0, padx, 0.0)))
      .lines_up(Is(Some(Middle)))
      .radius(Is(height / 2.0))
      .ground(By(fn() { alpha(theme().p.hover, hand.shown(v)) }))
      |> ignore
      menu.keys(v, fn() { true }, fn() {
        by_key.val = true
        open.set(true)
      })
      // (what it holds in its middle, as a button's: the old one's justify=JCenter)
      v.box(fn(s) { s.grow(Is(1.0)) |> ignore }) |> ignore
      let w = v.box(fn(w) {
        w
        .words(By(words), look={ size: theme().t.ui, weight: if theme().touch { 600 } else { 500 }, line: theme().t.ui_line, wrap: false, tracking: @view.letters_own, balance: false, max_lines: 0 })
        .ink(By(ink))
        |> ignore
      })
      // (its chevron after its words, the gap a button's between them, laid out by its ink: button's end_icon)
      v.box(fn(g) { g.width(By(fn() { Some(if theme().touch { 8.0 } else { 6.0 }) })) |> ignore }) |> ignore
      let (ink_l, ink_r) = match icon_numbers("chevron-down") {
        Some(d) => @ui.shapes_ink_in(icon_shapes(d, button_icon / 24.0, 0x000000FFL), button_icon)
        None => (0.0, 0.0)
      }
      icon_node(v, "chevron-down", button_icon, By(ink)).margin(Is((-ink_l, 0.0, -ink_r, 0.0))) |> ignore
      v.box(fn(s) { s.grow(Is(1.0)) |> ignore }) |> ignore
      // (its words changed: its ground from the shape it had, its words from where they were, together)
      let m = @motion.moves_for(v, words, spec=button_reshape)
      m.reshapes(v)
      m.moves_with(w)
    },
  )
  // (its menu made as it opens, in the layer, living as long as the choice does: ChooserMenu::menu)
  menu.menu(b, choices, chosen, choose, side, true, loc~)
  b
}
