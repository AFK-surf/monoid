// A name changed in its place (a chat's row's title, a file's name in its row): one field, one way of ending it, as a
// desktop's file manager has it. Enter keeps the new name, Escape lets it be, and leaving it (a press anywhere else, or
// the focus gone from it) keeps it too; a name kept is trimmed, and one empty or as it was lets it be.

///|
/// What of the name is picked as its field comes (inline_rename_node's `picks`): all of it (a chat's title), all but
/// its extension (a file's name: its stem, as a file manager picks it), or as the field holds it already.
#derive(Eq)
pub(all) enum RenamePick {
  NameWhole
  NameStem
  NameAsGiven
}

///|
/// A name changed in its place in `parent`: a box (`frame` its look, said by the caller: where it stands, its ground,
/// its line) holding a line to type in, editing `field` (its words the name as it was, `was`); the focus given to it
/// as it comes (View::focus_opens: after what opened it, a menu closing, has given back what it took), or as soon as it
/// takes input where something still going over it holds it from it first. What of the name is picked then: `picks`.
/// It ends once: Enter, a press outside it, or the focus gone from it keeps what it holds (`commit`, given it trimmed)
/// where that is not empty and not `was`, else lets it be (`cancel`); Escape lets it be. Its words `size_by` large on
/// a line of `line` (0: their own), in `colors_by` (the words', the placeholder's, the caret's); `label` what a screen
/// reader calls it. The field's node.
#callsite(autofill(loc))
pub fn inline_rename_node(
  parent : @view.View,
  field : @ui.Field,
  was : String,
  label : String,
  commit : (String) -> Unit,
  cancel : () -> Unit,
  picks? : RenamePick = NameAsGiven,
  frame? : (@view.View) -> Unit = fn(_) {  },
  size_by? : () -> Double = fn() { theme().t.ui },
  line? : Double = 0.0,
  colors_by? : () -> (Int64, Int64, Int64) = fn() {
    let p = theme().p
    (p.text, p.muted, p.accent)
  },
  loc~ : SourceLoc,
) -> @view.View {
  let done = Ref(false)
  let finish = fn(keep : String?) {
    guard !done.val else { return }
    done.val = true
    match keep.map(fn(w) { w.trim(chars=" \t\n").to_owned() }) {
      Some(w) if w != "" && w != was => commit(w)
      _ => cancel()
    }
  }
  match picks {
    NameWhole => field.pick(0, field.text().length())
    NameStem => {
      let name = field.text()
      let to = match name.rev_find(".") {
        Some(i) if i > 0 => i
        _ => name.length()
      }
      field.pick(0, to)
    }
    NameAsGiven => ()
  }
  let made : Ref[@view.View?] = Ref(None)
  parent.box(made_for=loc, fn(b) {
    frame(b)
    // (Escape lets it be before the field sees it)
    b.on_key(fn(k) {
      if k.code == @ui.key_escape && k.mods == 0 {
        finish(None)
        true
      } else {
        false
      }
    })
    |> ignore
    let typed = @ui.field(
      b,
      field,
      size_by~,
      label~,
      line~,
      max_lines=1,
      enter_sends=true,
      colors_by~,
      submitted=fn(words) { finish(Some(words)) },
    )
    typed.grow(Is(1.0)).basis(Is(Some(0.0))).shrink(Is(1.0)).min_width(Is(Some(0.0))) |> ignore
    made.val = Some(typed)
    // (the focus to it as it comes, once what opened it has given back what it took)
    b.focus_opens(typed) |> ignore
    // (where it cannot have it then, under what is still going over it (the menu that asked for it, as it closes):
    // as soon as it takes input, till it has had it once. Where it takes input as it is made, focus_opens gives it)
    let seen = Ref(false)
    let under = Ref(false)
    typed.reacts(fn() { typed.takes_input() }, fn(takes) {
      if !takes {
        under.val = true
      } else if under.val && !seen.val && !done.val && !@signals.untracked(fn() { typed.focused() }) {
        typed.ask_focus() |> ignore
      }
    })
    // (a press outside it ends it, even where what it went down on takes no focus; that press still reaches what it
    // went down on. The press that opened it came before it, so only later ones count)
    let opened = @signals.untracked(fn() { b.window_downs() })
    b.reacts(fn() { b.window_downs() }, fn(count) {
      if count > opened && !done.val {
        let (x, y) = b.window_down_point()
        let (left, top, w, h) = b.placed_window_now()
        if x < left || x >= left + w || y < top || y >= top + h {
          b.focus_let_go()
          finish(Some(field.text()))
        }
      }
    })
    // (left once it had the focus: kept as a press outside keeps it)
    typed.reacts(fn() { typed.focused() }, fn(on) {
      if on {
        seen.val = true
      } else if seen.val {
        finish(Some(field.text()))
      }
    })
  })
  |> ignore
  made.val.unwrap()
}
