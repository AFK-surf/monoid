// A page's own head and the small parts of a page's cards and sections (page.mbt's own_head, action, icon_action,
// figures, loose; parts.mbt's copy_command, field) as nodes of
// the window's tree made once: laid out by the arrangement of the page they are in (look_node), what they say followed
// as it changes; their styles the old view's, the same (style_node).

///|
/// A page's own head (own_head's) in `parent`, in place of its title (page_node's `head`): its `mark` in its box (given
/// the box's side), its `name`, renamed by `rename` (said `rename_label`) while `renames` says it may be, `busy` while
/// it is saved; `tags` (its runtimes: what it is); `lines` of what it is and where; how it stands under them (`state`),
/// what it does at the end of its name's line (`actions`); `dot` (a state's: online, offline …; "" none) before its
/// first line, `state` only while `state_shown` says, what is wrong with it under all of them (`warnings`: its words,
/// red or else amber). Wide: its mark 32 on its name's line with a pencil and what it does after it, the lines under
/// them from the mark's start. Narrow: its mark, its name and what it does
/// in one line (what it does on back's line over it where the page puts back there: head_back_holds), the name a size
/// under the page's large title on as many lines as it takes, pressed to rename it; its tags and lines under them.
/// `mark_press`: its mark pressed to do something (what it is called, what is done: a station's managers pick its
/// mark), a block pressed as a whole (action_box_node); else nothing to press.
#callsite(autofill(loc))
pub fn own_head_node(
  parent : @view.View,
  mark : (@view.View, Double) -> Unit,
  name : () -> String,
  rename? : () -> Unit,
  renames? : () -> Bool = fn() { true },
  rename_label? : () -> String = fn() { "" },
  busy? : () -> Bool = fn() { false },
  tags? : (@view.View) -> Unit,
  lines? : () -> Array[String] = fn() { [] },
  state? : (@view.View) -> Unit,
  actions? : (@view.View) -> Unit,
  dot? : () -> String = fn() { "" },
  state_shown? : () -> Bool = fn() { true },
  warnings? : () -> Array[(String, Bool)] = fn() { [] },
  mark_press? : (() -> String, () -> Unit),
  loc~ : SourceLoc,
) -> Unit {
  let narrow = look_node(parent) is Narrow
  // (its mark in `holder`, in its box of `look`, `side` its side: pressed as a whole where it is pressed)
  let mark_in = fn(holder : @view.View, look : () -> @ui.Style, side : Double) {
    let drawn = fn(m : @view.View) {
      style_node(m, look)
      mark(m, side)
    }
    match mark_press {
      Some((label, press)) => action_box_node(holder, label, fn(_) { press() }, drawn) |> ignore
      None => holder.box(drawn) |> ignore
    }
  }
  let shown = fn() { lines().filter(fn(l) { l != "" }) }
  let line_look = fn() { if narrow { head_line_narrow } else { head_line } }
  // what is under its name: the first line (what it is), the others, its tags, how it stands
  let below = fn(b : @view.View) {
    b.show(fn() { shown().length() > 0 || dot() != "" }, fn(r) {
      style_node(r, fn() { head_line_row })
      r.show(fn() { dot() != "" }, fn(d) { state_dot_node(d, dot) })
      r.show(fn() { shown().length() > 0 }, fn(w) {
        w.grow(Is(1.0)).shrink(Is(1.0)).min_width(Is(Some(0.0))) |> ignore
        words_node(w, fn() { shown().get(0).unwrap_or("") }, line_look) |> ignore
      })
    })
    b.each(fn() { shown().mapi(fn(i, l) { (i, l) }).filter(fn(x) { x.0 > 0 }) }, fn(x) { x.0 }, fn(w, x) {
      words_node(w, fn() { x.get().1 }, line_look) |> ignore
    })
    match tags {
      Some(f) => f(b)
      None => ()
    }
    match state {
      Some(f) =>
        b.show(state_shown, fn(s) {
          style_node(s, fn() { head_state })
          // (going on in the next line where its line has not the room: head_state's flow)
          s.wraps(Is(Some(0.0))) |> ignore
          f(s)
        })
      None => ()
    }
    // (red where it does not work, else amber)
    b.each(fn() { warnings().mapi(fn(i, w) { (i, w) }) }, fn(x) { x.0 }, fn(w, x) {
      words_node(w, fn() { x.get().1.0 }, fn() { if x.get().1.1 { head_warn_red } else { head_warn_amber } }) |> ignore
    })
  }
  let end = fn(e : @view.View) {
    match actions {
      Some(f) =>
        e.box(fn(a) {
          style_node(a, fn() { head_actions })
          f(a)
        })
        |> ignore
      None => ()
    }
  }
  if narrow {
    let at_back = parent.lent(head_back_holds).unwrap_or(fn() { false })
    parent.box(made_for=loc, fn(h) {
      // (16 over what follows; under a state's line, its button's room is that room already)
      style_node(h, fn() { if state is None || !state_shown() { head_narrow.then(head_narrow_foot) } else { head_narrow } })
      h.box(fn(top) {
        style_node(top, fn() { head_top_narrow })
        mark_in(top, fn() { head_mark_narrow }, head_mark_narrow_side)
        top.box(fn(words) {
          style_node(words, fn() { pg_row_words }, in_row=true)
          words.shrink(Is(1.0)).min_width(Is(Some(0.0))) |> ignore
          // its name a size under the page's large title (its mark beside it: a phone's line), on as many lines as it
          // takes (an address broken after its @ and its dots, not inside a word of it), pressed to rename it
          let name_words = fn(n : @view.View) {
            words_node(n, fn() { name().replace_all(old="@", new="@\u{200B}").replace_all(old=".", new=".\u{200B}") }, fn() {
              head_name_lines
            })
            |> ignore
          }
          match rename {
            // (a button while it renames (button_while_node), seen fainter while pressed; else its words alone)
            Some(f) =>
              button_while_node(
                words,
                renames,
                fn() { if rename_label() == "" { name() } else { rename_label() } },
                fn(_) { f() },
                fn(n, pressed) {
                  if pressed {
                    n.alpha(By(fn() { if n.pressed() { head_pressed_alpha } else { 1.0 } })) |> ignore
                  }
                  name_words(n)
                },
              )
              |> ignore
            None => words.box(name_words) |> ignore
          }
          words.show(busy, fn(s) { spinner_node(s, size=spinner_inline) |> ignore })
        })
        |> ignore
        top.show(fn() { !at_back() }, end)
      })
      |> ignore
      below(h)
    })
    |> ignore
    return
  }
  parent.box(made_for=loc, fn(h) {
    style_node(h, fn() { head_wide })
    // its mark, its name and what it does on the name's line, the lines under them from the mark's start
    h.box(fn(row) {
      style_node(row, fn() { head_name_row })
      mark_in(row, fn() { head_mark_wide }, head_mark_wide_side)
      row.box(fn(l) {
        style_node(l, fn() { head_name_line.then(head_name_grow) }, in_row=true)
        l.shrink(Is(1.0)).min_width(Is(Some(0.0))) |> ignore
        // (short of room, its name is cut short, what follows it kept)
        words_node(l, name, fn() { head_name_wide }).shrink(Is(1.0)) |> ignore
        l.show(busy, fn(s) { spinner_node(s, size=spinner_inline) |> ignore })
        match rename {
          Some(f) => l.show(renames, fn(e) { icon_action_node(e, "edit", rename_label, f) |> ignore })
          None => ()
        }
      })
      |> ignore
      end(row)
    })
    |> ignore
    below(h)
  })
  |> ignore
}

///|
/// How far a narrow own head's name is seen while it is pressed to rename it (head_name_press's pressed{opacity=O60}).
let head_pressed_alpha : Double = 0.6

///|
/// A button of a mark alone (icon_action's, as a node: a head's rename, check again, ⋯) in `parent`, said to be
/// `label`: as wide as the native input's hand needs (a finger's 44, a pointer's 32); `press` done as it is pressed,
/// while it is not `disabled`. The node.
#callsite(autofill(loc))
pub fn icon_action_node(
  parent : @view.View,
  icon : String,
  label : () -> String,
  press : () -> Unit,
  disabled? : () -> Bool = fn() { false },
  tips? : TipLayer,
  loc~ : SourceLoc,
) -> @view.View {
  icon_action_by(loc~, parent, icon, label, fn(_) { press() }, disabled, tips)
}

///|
/// What a page does from its bar (its `actions`: 添加) in `parent`, said to be `label`: laid out as the page is (its
/// look, the same for as long as the page is made: page_node makes it again as that changes), wide the quiet button,
/// its mark before its words; narrow its mark alone, round. `press` done as it is pressed. The node.
#callsite(autofill(loc))
pub fn page_action_node(parent : @view.View, icon : String, label : () -> String, press : () -> Unit, loc~ : SourceLoc) -> @view.View {
  match look_node(parent) {
    Wide => button_node(loc~, parent, label, press, tone=Ghost, icon~)
    Narrow => icon_button_node(loc~, parent, icon, label, press)
  }
}

///|
/// icon_action_node's button that opens what goes beside it (a ⋯'s menu): `open` given the button itself as it is
/// pressed, where it is placed then.
#callsite(autofill(loc))
pub fn icon_action_opens_node(
  parent : @view.View,
  icon : String,
  label : () -> String,
  open : (@view.View) -> Unit,
  disabled? : () -> Bool = fn() { false },
  tips? : TipLayer,
  loc~ : SourceLoc,
) -> @view.View {
  icon_action_by(loc~, parent, icon, label, open, disabled, tips)
}

///|
/// icon_action_node's button, `press` given the button itself: as wide as the native input's hand needs.
#callsite(autofill(loc))
fn icon_action_by(
  parent : @view.View,
  icon : String,
  label : () -> String,
  press : (@view.View) -> Unit,
  disabled : () -> Bool,
  tips : TipLayer?,
  loc~ : SourceLoc,
) -> @view.View {
  if parent.lent(back_bar_lent).unwrap_or(false) {
    let btn_v : Ref[@view.View?] = Ref(None)
    bar_pill_group_node(loc~, parent, height=pg_back_pill_h, pad=3.0, gap=0.0, fn(pill) {
      btn_v.val = Some(icon_button_by(loc~, pill, icon, label, press, tips, 34.0, 18.0, None, disabled))
    })
    |> ignore
    btn_v.val.unwrap()
  } else if native_input() is Finger {
    icon_button_by(loc~, parent, icon, label, press, tips, touch_target, touch_glyph, None, disabled)
  } else {
    icon_button_by(parent, icon, label, press, tips, icon_button_side, 16.0, None, disabled)
  }
}

///|
/// What a part does at its heading's end (action's, as a node: section_node's `ends`): wide, the quiet button with its
/// mark; narrow, the heading's trailing words in the link's ink, room round them for a finger, rippling as pressed; a
/// spinner in their place while it is `busy`; `bad`: one that takes something away, in the red. `press` done as it is
/// pressed, while it is not `disabled`.
#callsite(autofill(loc))
pub fn action_node(
  parent : @view.View,
  label : () -> String,
  press : () -> Unit,
  icon? : String = "",
  busy? : () -> Bool = fn() { false },
  disabled? : () -> Bool = fn() { false },
  bad? : Bool = false,
  loc~ : SourceLoc,
) -> Unit {
  match look_node(parent) {
    Wide => button_node(loc~, parent, label, press, tone=if bad { GhostDanger } else { Ghost }, icon~, busy~, disabled~) |> ignore
    Narrow =>
      parent.pick(fn() { if busy() { 0 } else if disabled() { 1 } else { 2 } }, fn(p, what) {
        match what {
          0 => spinner_node(p, size=spinner_inline) |> ignore
          _ =>
            p.box(fn(a) {
              style_node(a, fn() { pg_action })
              if what == 2 {
                pressed_node(a, press, Is(row_corner), Button, label)
              }
              words_node(a, label, fn() { if bad { pg_action_bad } else { pg_action_words } }) |> ignore
            })
            |> ignore
        }
      })
  }
}

///|
/// What a section holds that is neither rows nor a card (loose's, as a node: its chips, a field with its button) in
/// `parent`, what `body` makes in it 12 apart: narrow, as far in as the page's headings' words, 10 under it; wide, at
/// the column's edges.
#callsite(autofill(loc))
pub fn loose_node(parent : @view.View, body : (@view.View) -> Unit, loc~ : SourceLoc) -> Unit {
  let narrow = look_node(parent) is Narrow
  parent.box(made_for=loc, fn(b) {
    style_node(b, fn() { if narrow { pg_loose } else { wide_block } })
    body(b)
  })
  |> ignore
}

///|
/// What a page does at its head's end (`actions`: each its mark, what it is called and its press), in `parent`, by the
/// page's width: wide, side by side, each the quiet button with its mark and its words, each a spinner while `busy`;
/// narrow, each a button of its mark alone (icon_action_node), one spinner in their place while `busy`.
#callsite(autofill(loc))
pub fn head_actions_node(
  parent : @view.View,
  actions : Array[(String, () -> String, () -> Unit)],
  busy? : () -> Bool = fn() { false },
  loc~ : SourceLoc,
) -> Unit {
  parent.box(made_for=loc, fn(row) {
    row.row(Is(true)).lines_up(Is(Some(Middle))) |> ignore
    match look_node(row) {
      Wide => {
        row.gap(Is(head_actions_wide_gap)) |> ignore
        for a in actions {
          button_node(row, a.1, a.2, tone=Ghost, icon=a.0, busy~) |> ignore
        }
      }
      Narrow =>
        row.pick(busy, fn(p, busy) {
          p.row(Is(true)).gap(Is(head_actions_narrow_gap)).lines_up(Is(Some(Middle))) |> ignore
          if busy {
            spinner_node(p, size=spinner_inline) |> ignore
          } else {
            p.each_of(fn() { actions }, fn(e, a) { icon_action_node(e, a.0, a.1, a.2) |> ignore })
          }
        })
    }
  })
  |> ignore
}

///|
/// A head's actions apart: wide, its quiet buttons 8 (a head's row's gap=S2); narrow, its marks 12 (gap=S3).
let head_actions_wide_gap : Double = 8.0

///|
let head_actions_narrow_gap : Double = 12.0
