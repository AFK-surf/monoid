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

fn action_said(
  role : @view.Role,
  label : String,
  selected : Bool?,
  expanded : Bool?,
  check : @view.Check?,
) -> @view.Said {
  @view.said(role, label~, selected?, expanded?, check?)
}

///|
/// A block pressed as a whole in `parent`, laid out by `look` (given its node, as it is made: its ground, what it holds,
/// how it lights under the hand, by lit_node or the node's own `pressed`); named `label`, `press` done as it is pressed
/// (given its node: what it opens goes beside it). `selected`: one of several to choose between (@headless.choice),
/// read out selected while it says so. `expanded`: what it opens or shuts is open while it says so (a disclosure,
/// read out expanded). `on`: a toggle button, on while it says so (read out pressed: 全屏, 控制, the keyboard up).
/// `check`: checked state read out on a button (`On`/`Off`). `focusable`: false where the caller manages focus itself.
/// None of them: a button, `label_is` its name where it never changes (`label` is it: said once, no binding made for
/// it, @headless.button's), `in_node` the button `parent` itself (a row a list made: no box of its own). While
/// `disabled()`, taking no press nor the focus. `on_hold`: what a finger held on it long_press_ms does (a card of it
/// opened by the hand: HoverHand's `hold`), its letting go then no press; a mouse's long press still a click (a
/// button's or a toggle's: @headless.Hold's). The node.
#callsite(autofill(loc))
pub fn action_box_node(
  parent : @view.View,
  label : () -> String,
  press : (@view.View) -> Unit,
  look : (@view.View) -> Unit,
  selected? : () -> Bool,
  expanded? : () -> Bool,
  on? : () -> Bool,
  check? : () -> @view.Check,
  disabled? : () -> Bool,
  said_while_disabled? : Bool = true,
  focusable? : Bool = true,
  label_is? : String,
  in_node? : Bool = false,
  on_hold? : () -> Unit,
  loc~ : SourceLoc,
) -> @view.View {
  let hold = on_hold.map(fn(f) {
    @headless.Hold::new(@ui.touch_slop(), @ui.long_press_ms, fn() { @ui.pointing() is Finger }, on_hold=f)
  })
  let drawn = fn(v : @view.View) {
    focus_ring_node(v)
    look(v)
  }
  // (its node, for a toggle's press: what it opens goes beside it)
  let me : Ref[@view.View?] = Ref(None)
  match (in_node, selected, expanded, on, check, said_while_disabled) {
    (false, Some(chosen), None, None, None, true) =>
      @headless.choice(made_for=loc, parent, Button, label, chosen, press, disabled?, focusable~, fn(v, _) { drawn(v) })
    (false, None, Some(open), None, None, true) =>
      @headless.disclosure(made_for=loc, parent, label, open, press, disabled?, fn(v, _) { drawn(v) })
    (false, None, None, Some(now), None, true) =>
      @headless.toggle(made_for=loc, parent, Button, label, now, fn(_) { if me.val is Some(v) { press(v) } }, disabled?, hold?, focusable~, fn(v, _) {
        me.val = Some(v)
        drawn(v)
      })
    _ => {
      let static_able = disabled is None
      let v = @headless.button(
        made_for=loc,
        parent,
        label,
        press,
        disabled?,
        hold?,
        focusable~,
        label_is?=if static_able { Some(label_is.unwrap_or("")) } else { label_is },
        in_node~,
        fn(v, _) { drawn(v) },
      )
      if selected is Some(_) ||
        expanded is Some(_) ||
        check is Some(_) ||
        !said_while_disabled ||
        (static_able && label_is is None) {
        let role : @view.Role = Button
        v.says(By(fn() {
          if !said_while_disabled && disabled.map(fn(f) { f() }).unwrap_or(false) {
            None
          } else {
            Some(
              action_said(
                role,
                label(),
                selected.map(fn(f) { f() }),
                expanded.map(fn(f) { f() }),
                check.map(fn(f) { f() }),
              ),
            )
          }
        }))
        |> ignore
      }
      v
    }
  }
}

///|
/// A layout-only button anchor in `parent` for a host-drawn native control (e.g. macOS Liquid Glass): takes no mbui
/// press or keyboard focus, and exposes `Button` with `label` in the semantics tree so the host can place its control
/// over the node's bounds (`@ui.tree_read_out_id`). `look` lays out and registers the node. The node.
#callsite(autofill(loc))
pub fn host_button_anchor_node(
  parent : @view.View,
  label : () -> String,
  look : (@view.View) -> Unit,
  loc~ : SourceLoc,
) -> @view.View {
  let role : @view.Role = Button
  parent.box(made_for=loc, fn(v) {
    v.says(By(fn() { Some(action_said(role, label(), None, None, None)) })) |> ignore
    look(v)
  })
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
