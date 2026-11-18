// A choice that opens a menu of what it can be (chooser's) as a node of the window's tree: quiet words and a small
// chevron; pressed, its menu of choices beside it (menu_node, under it, its start at its start), the one chosen checked,
// on every screen as the old one's dropdown is (not the presenters' sheet on 小屏). Made in the layer of the panel it is
// in (offers_layer_lent, where what a field offers is made: nothing the panel cuts cuts it), else over the window.

///|
/// A choice in `parent` (chooser's, as a node): `words()` (12, quiet; the text's ink while the hand is on it, it has the
/// focus shown or its menu is open, the hover's ground under it then too) and a 12 chevron, 28 high, 8 in, 5 apart, the
/// theme's Lg round. Pressed (a tap, a click, Enter or Space with the focus on it, a screen reader's press), or Down with
/// the focus on it, its menu of `choices()` (each its value and its words) under it, 6 off, lined up with its start,
/// 220 wide at least, the one `chosen()` is checked; opened by a key, the focus on its first row. A choice chosen closes
/// it, then `choose` is given its value; Escape, back and a press outside close it alone, the focus back on the chooser.
/// Read out a button named by its words, expanded while its menu is open. `press`: what it does as it is pressed (or
/// Down given it), in place of opening a menu (a panel of its own it opens: chooser's `set_open(true)` with no entries).
/// While `disabled()`: no press nor the focus, never lit, read out so (the old one's look kept: not faded). Opened by a
/// finger with a field focused, that field keeps its keyboard (menu_node's `keep_field`).
#callsite(autofill(loc))
pub fn chooser_node(
  parent : @view.View,
  words : () -> String,
  choices : () -> Array[(String, String)],
  chosen : () -> String,
  choose : (String) -> Unit,
  press? : () -> Unit,
  disabled? : () -> Bool = fn() { false },
  loc~ : SourceLoc,
) -> @view.View {
  chooser_by(loc~, parent, words, choices, chosen, choose, false, press, disabled)
}

///|
/// chooser_node's choice round as a capsule, its words as far in as a plain one's (a notice's over the composer,
/// concentric in its round end, as the old one's `capsule` there): `disabled` as chooser_node's; its menu on `side` of
/// it (a notice's over the composer: over it).
#callsite(autofill(loc))
pub fn capsule_chooser_node(
  parent : @view.View,
  words : () -> String,
  choices : () -> Array[(String, String)],
  chosen : () -> String,
  choose : (String) -> Unit,
  disabled? : () -> Bool = fn() { false },
  side? : @ui.Side = Bottom,
  loc~ : SourceLoc,
) -> @view.View {
  chooser_by(loc~, parent, words, choices, chosen, choose, true, None, disabled, at_foot=false, side~)
}

///|
/// chooser_node's choice; `capsule`: round as a capsule, its words as far in as a card's foot corner leaves them
/// (foot_chooser_node's: at a card's foot, as the old one is there), or where not `at_foot` as far in as a plain one's
/// (capsule_chooser_node's: the old one's `capsule` off a card's foot); `press`, `disabled`: chooser_node's.
#callsite(autofill(loc))
fn chooser_by(
  parent : @view.View,
  words : () -> String,
  choices : () -> Array[(String, String)],
  chosen : () -> String,
  choose : (String) -> Unit,
  capsule : Bool,
  press : (() -> Unit)?,
  disabled : () -> Bool,
  at_foot? : Bool = true,
  side? : @ui.Side = Bottom,
  loc~ : SourceLoc,
) -> @view.View {
  // (over all of the panel it is in, as what a field offers is: offers_layer_lent, a sheet's, a dialog's, a small
  // panel's; else over the window)
  let layer = match parent.lent(offers_layer_lent) {
    Some(l) => l
    None => parent.tree.root()
  }
  let open = @signals.signal(false, same=fn(a, b) { a == b })
  // (opened by the keyboard: its first row's the focus as it opens; by a finger with a field focused, that field keeps
  // its input method, menu_node's `keep_field`)
  let by_key = Ref(false)
  let keep_field = Ref(false)
  let opens = fn(b : @view.View, down : Bool) {
    match press {
      Some(f) => f()
      None => {
        by_key.val = down || b.focus_shown()
        keep_field.val = !by_key.val && @ui.pointing() is Finger && @ui.field_has_focus()
        open.set(down || !open.untracked())
      }
    }
  }
  let b = @headless.disclosure(
    made_for=loc,
    parent,
    words,
    fn() { open.get() },
    fn(b) { opens(b, false) },
    disabled~,
    fn(b, d) {
      let lit = fn() { !d.disabled() && (lit_node(b) || d.open() || d.focus_shown()) }
      b.on_key(fn(k) {
        if k.mods == 0 && k.code == @ui.key_code_down && b.focused() && !open.untracked() && !@signals.untracked(disabled) {
          opens(b, true)
          true
        } else {
          false
        }
      })
      |> ignore
      // (disabled while its menu is open: closed, as the old one's)
      b.reacts(disabled, fn(off) { if off { open.set(false) } })
      b
      .row(Is(true))
      .height(Is(Some(chooser_h)))
      .padding(By(fn() {
        let x = if capsule && at_foot { card_foot_words_in(chooser_h) } else { chooser_x }
        (x, 0.0, x, 0.0)
      }))
      .gap(Is(chooser_gap_in))
      // (a capsule: a pill as the app's others are, not a corner of its own its height comes to)
      .radius(By(fn() { if capsule { 1.0e6 } else { @ui.tree_theme().corner(Lg) } }))
      .lines_up(Is(Some(Middle)))
      .ground(By(fn() { if lit() { @ui.tree_theme().color(Hover) } else { 0L } }))
      |> ignore
      words_node(b, words, fn() { if lit() { chooser_words_lit } else { chooser_words } }) |> ignore
      icon_node(b, "chevron-down", chooser_chevron, By(fn() { if lit() { theme().p.text } else { theme().p.muted } }))
      |> ignore
      // (closed as it starts leaving, and as it is let go)
      b.on_leaving(fn() { open.set(false) }) |> ignore
      b.owns(fn() { open.set(false) }) |> ignore
    },
  )
  // (its menu made as it opens, in the layer, living as long as the chooser does; the focus given back to it as it goes.
  // What holds it in the layer made as it first opens, not with the chooser: made with it, as a card's choosers are
  // made in what is laid out by its room (View::by_room), it was made outside that room, and the tree laid out all of it
  // again in the same frame for it, a pass more for a menu not open (a vault's ask's three, opening a chat))
  let made = Ref(false)
  b.reacts(fn() { open.get() }, fn(on) {
    guard on && !made.val else { return }
    made.val = true
    chooser_menu_node(layer, b, open, by_key, keep_field, choices, chosen, choose, side~, loc~)
  })
  b
}

///|
/// What holds chooser `b`'s menu in `layer` (chooser_by's: as it first opens), living as long as `b` does, and its menu
/// while `open`: chooser_by's `by_key`, `choices`, `chosen`, `choose`; asked for at `loc` (the chooser's).
#callsite(autofill(loc))
fn chooser_menu_node(
  layer : @view.View,
  b : @view.View,
  open : @signals.Signal[Bool],
  by_key : Ref[Bool],
  keep_field : Ref[Bool],
  choices : () -> Array[(String, String)],
  chosen : () -> String,
  choose : (String) -> Unit,
  side? : @ui.Side = Bottom,
  loc~ : SourceLoc,
) -> Unit {
  let holder = layer.box(made_for=loc, fn(h) { h.over(Is(true)) |> ignore }).lives_with(b)
  holder.show(fn() { open.get() }, at_once=true, fn(m) {
    m.over(Is(true)).opened_by(@view.ByNode(b.id())) |> ignore
    let now = chosen()
    let items = choices().map(fn(c) {
      Some(menu_item_of(c.1, chosen=c.0 == now, fn() { choose(c.0) }))
    })
    menu_node(
      m,
      fn() { true },
      fn(_) { b },
      fn() { items },
      "",
      Start,
      chooser_menu_off,
      by_key.val,
      keep_field.val,
      fn(item) {
        open.set(false)
        (item.select)()
      },
      fn() { open.set(false) },
      min_w=chooser_menu_w,
      side~,
    )
  })
}

///|
/// chooser_box's height (h=S7), room at its sides (px=S2) and between its words and chevron (gap=S1_25).
let chooser_h : Double = 28.0

///|
let chooser_x : Double = 8.0

///|
let chooser_gap_in : Double = 5.0

///|
/// How far under it its menu is (dropdown's offset).
let chooser_menu_off : Double = 6.0
