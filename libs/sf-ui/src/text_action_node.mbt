// What a page presses that is no button of the library's own look (文字操作与可按的块), as nodes of the window's
// tree, made once: words pressed to do something (显示全部 N 个, 换一个, 复制邀请, 复制验证码), and a block laid out by
// its page that is pressed as a whole (a card that leads somewhere, a capsule, one row picked of several, a head that
// opens what is under it). What each is to the hand, the keyboard and a screen reader is mbui's headless part's (a
// button; one of several to choose between, read out selected, @headless.choice; one that opens and shuts what it
// leads to, read out expanded, @headless.disclosure); here only their look, the page's own where it lays the block out.
// The keyboard's focus shown on each by the theme's ring.

///|
/// Words pressed to do something in `parent`: `words()` in `style()` (the link's words, Meta, where not said), in a box
/// `box()` says (none of its own where not said); named `label` (its words where not said), `press` done as it is
/// pressed; while `disabled()`, taking no press nor the focus, faded where `style` says so. The node.
#callsite(autofill(loc))
pub fn text_action_node(
  parent : @view.View,
  words : () -> String,
  press : () -> Unit,
  style? : () -> @ui.TextStyle = fn() { text_action_words },
  box? : () -> @ui.Style,
  label? : () -> String,
  disabled? : () -> Bool = fn() { false },
  loc~ : SourceLoc,
) -> @view.View {
  @headless.button(made_for=loc, parent, label.unwrap_or(words), fn(_) { press() }, disabled~, fn(b, _) {
    match box {
      Some(s) => style_node(b, s)
      None => ()
    }
    focus_ring_node(b)
    words_node(b, words, style) |> ignore
  })
}

///|
/// A block pressed as a whole in `parent`, laid out by `look` (given its node, as it is made: its ground, what it holds,
/// how it lights under the hand, by lit_node or the node's own `pressed`); named `label`, `press` done as it is pressed
/// (given its node: what it opens goes beside it). `selected`: one of several to choose between (@headless.choice),
/// read out selected while it says so. `expanded`: what it opens or shuts is open while it says so (a disclosure,
/// read out expanded). `on`: a toggle button, on while it says so (read out pressed: 全屏, 控制, the keyboard up).
/// None of them: a button, `label_is` its name where it never changes (`label` is it: said once, no binding made for
/// it, @headless.button's), `in_node` the button `parent` itself (a row a list made: no box of its own). While
/// `disabled()`, taking no press nor the focus. The node.
#callsite(autofill(loc))
pub fn action_box_node(
  parent : @view.View,
  label : () -> String,
  press : (@view.View) -> Unit,
  look : (@view.View) -> Unit,
  selected? : () -> Bool,
  expanded? : () -> Bool,
  on? : () -> Bool,
  disabled? : () -> Bool,
  label_is? : String,
  in_node? : Bool = false,
  loc~ : SourceLoc,
) -> @view.View {
  let drawn = fn(v : @view.View) {
    focus_ring_node(v)
    look(v)
  }
  // (its node, for a toggle's press: what it opens goes beside it)
  let me : Ref[@view.View?] = Ref(None)
  match (selected, expanded, on) {
    (Some(chosen), _, _) => @headless.choice(made_for=loc, parent, Button, label, chosen, press, disabled?, fn(v, _) { drawn(v) })
    (None, Some(open), _) => @headless.disclosure(made_for=loc, parent, label, open, press, disabled?, fn(v, _) { drawn(v) })
    (None, None, Some(now)) =>
      @headless.toggle(made_for=loc, parent, Button, label, now, fn(_) { if me.val is Some(v) { press(v) } }, disabled?, fn(v, _) {
        me.val = Some(v)
        drawn(v)
      })
    (None, None, None) => @headless.button(made_for=loc, parent, label, press, disabled?, label_is?, in_node~, fn(v, _) { drawn(v) })
  }
}

///|
/// The link's words (Meta, in the link's ink, one line).
// kept across runs: a value (no field of it changes)
let text_action_words : @ui.TextStyle = @ui.text_style(size=Meta, color=Link, wrap=false)

///|
/// action_box_node's block that is pressed only while `on()` says so (a step's card with a way to go by): a button
/// named `label` then (a disclosure, open while `expanded` says, where that is given), `press` done as it is pressed;
/// else a plain box, nothing to press and read out as what it shows (button_while_node's). Made anew, at once, as `on`
/// changes: `look` lays out either, given its node. `in_pick`: the pick's own node is the button (no box of its own
/// in it: a row of a list, a block of a page laid out in `parent` as it was before it was pressed), a button's alone.
#callsite(autofill(loc))
pub fn action_box_while_node(
  parent : @view.View,
  on : () -> Bool,
  label : () -> String,
  press : (@view.View) -> Unit,
  look : (@view.View) -> Unit,
  expanded? : () -> Bool,
  in_pick? : Bool = false,
  loc~ : SourceLoc,
) -> Unit {
  if !in_pick || expanded is Some(_) {
    button_while_node(loc~, parent, on, label, press, fn(v, _) { look(v) }, open?=expanded)
    return
  }
  parent.pick(loc~, on, at_once=true, fn(p, pressed) {
    if pressed {
      action_box_node(loc~, p, label, press, look, in_node=true) |> ignore
    } else {
      look(p)
    }
  })
}
